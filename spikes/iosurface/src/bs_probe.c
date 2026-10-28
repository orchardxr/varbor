/* Which bootstrap registration APIs work for an unprivileged, non-launchd process? */
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <servers/bootstrap.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
extern kern_return_t bootstrap_register2(mach_port_t bp, name_t service_name, mach_port_t sp, uint64_t flags);

static int g_fail;

static void result(const char *cs, int ok, const char *fmt, ...)
{
	char msg[256];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(msg, sizeof(msg), fmt, ap);
	va_end(ap);
	const char *tag = ok == 1 ? "PASS" : ok == 0 ? "FAIL" : ok == 2 ? "XFAIL" : "INFO";
	printf("%-5s %-34s %-14s %s\n", tag, cs, "bootstrap", msg);
	if (ok == 0)
		g_fail = 1;
}

typedef struct
{
	mach_msg_header_t h;
	uint32_t magic;
} ping_t;

typedef struct
{
	mach_msg_header_t h;
	uint32_t magic;
	mach_msg_trailer_t t;
} ping_rcv_t;

static int spawn_wait(char *const argv[])
{
	char path[1024];
	uint32_t n = sizeof(path);
	_NSGetExecutablePath(path, &n);
	pid_t pid;
	if (posix_spawn(&pid, path, NULL, NULL, argv, environ))
		return -1;
	int st;
	waitpid(pid, &st, 0);
	return WIFEXITED(st) ? WEXITSTATUS(st) : 100;
}

static int child_lookup(const char *name)
{
	mach_port_t sp;
	kern_return_t kr = bootstrap_look_up(bootstrap_port, name, &sp);
	if (kr != KERN_SUCCESS)
		return 2;
	ping_t m = {{MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0), sizeof(m), sp, MACH_PORT_NULL, 0, 1}, 0xC0FFEE};
	kr = mach_msg(&m.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(m), 0, MACH_PORT_NULL, 1000, MACH_PORT_NULL);
	return kr == KERN_SUCCESS ? 0 : 3;
}

static int child_register_and_exit(const char *name)
{
	mach_port_t rp;
	mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &rp);
	mach_port_insert_right(mach_task_self(), rp, rp, MACH_MSG_TYPE_MAKE_SEND);
	return bootstrap_register(bootstrap_port, (char *)name, rp) == KERN_SUCCESS ? 0 : 1;
}

static bool receive_ping(mach_port_t rp)
{
	ping_rcv_t m;
	kern_return_t kr = mach_msg(&m.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(m), rp, 2000, MACH_PORT_NULL);
	return kr == KERN_SUCCESS && m.magic == 0xC0FFEE;
}

int main(int argc, char **argv)
{
	if (argc == 3 && !strcmp(argv[1], "--lookup"))
		return child_lookup(argv[2]);
	if (argc == 3 && !strcmp(argv[1], "--register-exit"))
		return child_register_and_exit(argv[2]);

	char name[128];
	int pid = getpid();
	const char *apis[] = {"bootstrap_check_in", "bootstrap_register", "bootstrap_register2"};
	for (int api = 0; api < 3; api++) {
		snprintf(name, sizeof(name), "org.macvr.spike.probe.%d.%d", api, pid);
		mach_port_t rp = MACH_PORT_NULL;
		kern_return_t kr;
		if (api == 0) {
			kr = bootstrap_check_in(bootstrap_port, name, &rp);
		} else {
			mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &rp);
			mach_port_insert_right(mach_task_self(), rp, rp, MACH_MSG_TYPE_MAKE_SEND);
			kr = api == 1 ? bootstrap_register(bootstrap_port, name, rp) : bootstrap_register2(bootstrap_port, name, rp, 0);
		}
		if (kr != KERN_SUCCESS) {
			result(apis[api], api == 0 ? 2 : 0, "register failed: %d (%s)", kr, bootstrap_strerror(kr));
			continue;
		}
		char *av[] = {argv[0], "--lookup", name, NULL};
		int st = spawn_wait(av);
		bool got = st == 0 && receive_ping(rp);
		result(apis[api], got, "register ok; other process look_up=%s, message %s", st == 2 ? "FAILED" : "ok",
		       got ? "received" : "NOT received");
	}

	/* duplicate registration while the owner is alive */
	snprintf(name, sizeof(name), "org.macvr.spike.probe.dup.%d", pid);
	mach_port_t a, b;
	mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &a);
	mach_port_insert_right(mach_task_self(), a, a, MACH_MSG_TYPE_MAKE_SEND);
	mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &b);
	mach_port_insert_right(mach_task_self(), b, b, MACH_MSG_TYPE_MAKE_SEND);
	(void)bootstrap_register(bootstrap_port, name, a);
	kern_return_t kr = bootstrap_register(bootstrap_port, name, b);
	result("duplicate-name", kr != KERN_SUCCESS ? 1 : 0, "second bootstrap_register -> %d (%s)", kr,
	       kr ? bootstrap_strerror(kr) : "success: name hijackable!");

	/* name registered by a process that exited can be re-registered */
	snprintf(name, sizeof(name), "org.macvr.spike.probe.stale.%d", pid);
	char *av[] = {argv[0], "--register-exit", name, NULL};
	int st = spawn_wait(av);
	mach_port_t lp = MACH_PORT_NULL;
	kern_return_t lk = bootstrap_look_up(bootstrap_port, name, &lp);
	kr = bootstrap_register(bootstrap_port, name, b);
	result("stale-name-reuse", st == 0 && kr == KERN_SUCCESS ? 1 : 0,
	       "child registered (%d) and exited; look_up after exit -> %d; re-register -> %d (%s)", st, lk, kr,
	       kr ? bootstrap_strerror(kr) : "ok");
	return g_fail;
}
