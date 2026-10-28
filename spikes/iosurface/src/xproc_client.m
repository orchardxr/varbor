/* Process B (client role): looks up the server's bootstrap service, renders a known pattern into a
 * ring of IOSurface-backed VkImages and signals an MTLSharedEvent-backed timeline semaphore. */
#import <Metal/Metal.h>
#include <servers/bootstrap.h>
#include <stdlib.h>
#include <string.h>
#include "vkutil.h"
#include "xproc.h"

@interface MTLSharedEventHandle ()
- (mach_port_t)eventPort;
@end

static char g_case[64];
static int g_fail;

static void result(const char *test, int ok, const char *fmt, ...)
{
	char msg[512];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(msg, sizeof(msg), fmt, ap);
	va_end(ap);
	const char *tag = ok == 1 ? "PASS" : ok == 0 ? "FAIL" : ok == 2 ? "XFAIL" : "INFO";
	printf("%-5s %-34s %-14s %s\n", tag, g_case, test, msg);
	fflush(stdout);
	if (ok == 0)
		g_fail = 1;
}

static int cmp_d(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return x < y ? -1 : x > y;
}

static void stat_line(const char *test, const char *what, double *v, int n)
{
	if (!n)
		return;
	qsort(v, n, sizeof(double), cmp_d);
	double s = 0;
	for (int i = 0; i < n; i++)
		s += v[i];
	result(test, 3, "%-30s n=%4d median=%8.1fus p99=%8.1fus mean=%8.1fus max=%8.1fus", what, n, v[n / 2],
	       v[(n * 99) / 100], s / n, v[n - 1]);
}

typedef struct slot
{
	shimg img;
	VkImageView view;
	VkDescriptorSet set;
	VkCommandBuffer cb;
	VkFence fence;
	bool busy;
	uint64_t t_submit;
} slot;

static vkctx c;
static slot slots[XP_RING];
static VkSemaphore sem;
static mach_port_t me, server;
static uint32_t W = 1024, H = 1024;
static uint64_t timeline;

#define MAXF 4096
static double lat[MAXF], sendcost[MAXF], render[MAXF];

static void record(slot *s, uint32_t frame)
{
	vkResetCommandBuffer(s->cb, 0);
	VkCommandBufferBeginInfo bi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
	vkBeginCommandBuffer(s->cb, &bi);
	cmd_barrier_all(s->cb);
	vkCmdBindPipeline(s->cb, VK_PIPELINE_BIND_POINT_COMPUTE, c.pipe_store);
	vkCmdBindDescriptorSets(s->cb, VK_PIPELINE_BIND_POINT_COMPUTE, c.layout_store, 0, 1, &s->set, 0, NULL);
	uint32_t pc[3] = {W, H, frame};
	vkCmdPushConstants(s->cb, c.layout_store, VK_SHADER_STAGE_COMPUTE_BIT, 0, 12, pc);
	vkCmdDispatch(s->cb, (W + 7) / 8, (H + 7) / 8, 1);
	cmd_barrier_all(s->cb);
	vkEndCommandBuffer(s->cb);
}

static VkResult submit(slot *s, uint64_t signal_value)
{
	VkTimelineSemaphoreSubmitInfo ts = {VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO,
	                                    .signalSemaphoreValueCount = 1, .pSignalSemaphoreValues = &signal_value};
	VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &s->cb};
	if (signal_value) {
		si.pNext = &ts;
		si.signalSemaphoreCount = 1;
		si.pSignalSemaphores = &sem;
	}
	vkResetFences(c.dev, 1, &s->fence);
	s->t_submit = now_ns();
	return vkQueueSubmit(c.q, 1, &si, s->fence);
}

static int g_released;

static bool wait_release(int ms, int *nlat)
{
	xp_rcv r;
	kern_return_t kr = xp_recv(me, &r, ms);
	if (kr != KERN_SUCCESS)
		return false;
	if (xp_type_of(&r) == XP_RELEASE && r.msg.m.slot < XP_RING) {
		slot *s = &slots[r.msg.m.slot];
		if (nlat && *nlat < MAXF)
			lat[(*nlat)++] = (r.msg.m.t_aux_ns - s->t_submit) / 1000.0;
		s->busy = false;
		g_released++;
	}
	return true;
}

static slot *acquire(int *idx, int *nlat)
{
	for (;;) {
		for (int i = 0; i < XP_RING; i++)
			if (!slots[i].busy) {
				*idx = i;
				return &slots[i];
			}
		if (!wait_release(5000, nlat))
			return NULL;
	}
}

static int run_phase(const char *name, uint32_t first_frame, int nframes, uint32_t flags, double hz)
{
	int nlat = 0, nsend = 0;
	uint64_t t0 = now_ns();
	uint64_t period = hz > 0 ? (uint64_t)(1e9 / hz) : 0;
	if (period)
		flags |= XPF_PACED;
	g_released = 0;
	for (int f = 0; f < nframes; f++) {
		uint32_t frame = first_frame + f;
		int i;
		if (period) {
			uint64_t due = t0 + (uint64_t)f * period, now = now_ns();
			if (due > now) {
				struct timespec ts = {0, (long)(due - now)};
				nanosleep(&ts, NULL);
			}
		}
		slot *s = acquire(&i, &nlat);
		if (!s) {
			result(name, 0, "timed out waiting for RELEASE");
			return 1;
		}
		double tr0 = now_us();
		record(s, frame);
		uint64_t value = (flags & XPF_GPU_WAIT) ? ++timeline : 0;
		VkResult vr = submit(s, value);
		if (!(flags & XPF_GPU_WAIT))
			vr = vr ? vr : vkWaitForFences(c.dev, 1, &s->fence, VK_TRUE, 5000000000ull);
		double tr1 = now_us();
		if (vr) {
			result(name, 0, "submit/wait %d", vr);
			return 1;
		}
		s->busy = true;
		xp_msg m = {.type = XP_FRAME, .slot = (uint32_t)i, .frame = frame, .flags = flags | XPF_VERIFY,
		            .value = value, .t_send_ns = now_ns()};
		double ts0 = now_us();
		kern_return_t kr = xp_send(server, &m, 0, MACH_PORT_NULL);
		double ts1 = now_us();
		if (kr) {
			result(name, 0, "send FRAME 0x%x", kr);
			return 1;
		}
		if (nsend < MAXF) {
			sendcost[nsend] = ts1 - ts0;
			render[nsend] = tr1 - tr0;
			nsend++;
		}
		while (wait_release(0, &nlat))
			;
	}
	while (g_released < nframes)
		if (!wait_release(5000, &nlat)) {
			result(name, 0, "timed out draining");
			return 1;
		}
	double secs = (now_ns() - t0) / 1e9;
	result(name, 3, "%d frames in %.3fs = %.1f fps (ring of %d, ports sent once, FRAME msg = slot+value)", nframes,
	       secs, nframes / secs, XP_RING);
	stat_line(name, "B: submit->A copy complete", lat, nlat);
	stat_line(name, flags & XPF_GPU_WAIT ? "B: record+submit" : "B: record+submit+CPU fence wait", render, nsend);
	stat_line(name, "B: mach_msg send FRAME", sendcost, nsend);
	return 0;
}

int main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IOLBF, 0);
	int nframes = 600;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--frames") && i + 1 < argc)
			nframes = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--size") && i + 1 < argc)
			sscanf(argv[++i], "%ux%u", &W, &H);
	}
	snprintf(g_case, sizeof(g_case), "xproc-client[%s]", xp_arch());

	char name[128];
	snprintf(name, sizeof(name), XP_SERVICE_FMT, getuid());
	uint64_t t0 = now_ns();
	kern_return_t kr = bootstrap_look_up(bootstrap_port, name, &server);
	uint64_t t1 = now_ns();
	result("lookup", kr == KERN_SUCCESS, "bootstrap_look_up(%s) -> %d in %.1fus", name, kr, (t1 - t0) / 1000.0);
	if (kr)
		return 1;
	mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &me);

	uint64_t nonce = ((uint64_t)arc4random() << 32) | arc4random();
	xp_msg hello = {.type = XP_HELLO, .nonce = nonce, .t_send_ns = now_ns()};
	snprintf(hello.info, sizeof(hello.info), "%s", xp_arch());
	kr = xp_send(server, &hello, MACH_MSG_TYPE_MAKE_SEND, me);
	xp_rcv r;
	kr = kr ? kr : xp_recv(me, &r, 5000);
	bool ok = kr == KERN_SUCCESS && xp_type_of(&r) == XP_HELLO_ACK && r.ack.m.nonce == nonce;
	uint64_t t2 = now_ns();
	mach_port_deallocate(mach_task_self(), server);
	server = ok ? r.ack.m.port.name : MACH_PORT_NULL;
	result("hello", ok, "HELLO(reply port + nonce) -> HELLO_ACK(per-client port 0x%x) round trip %.1fus", server,
	       (t2 - t1) / 1000.0);
	if (!ok)
		return 1;

	enum { NP = 2000 };
	static double rtt[NP];
	for (int i = 0; i < NP; i++) {
		xp_msg m = {.type = XP_PING, .t_send_ns = now_ns()};
		xp_send(server, &m, 0, MACH_PORT_NULL);
		if (xp_recv(me, &r, 2000) || xp_type_of(&r) != XP_PONG) {
			result("ping", 0, "no PONG");
			return 1;
		}
		rtt[i] = (now_ns() - r.msg.m.t_send_ns) / 1000.0;
	}
	stat_line("ping", "Mach round trip (PING/PONG)", rtt, NP);

	if (vk_init(&c, true)) {
		result("vk-init", 0, "failed");
		return 1;
	}
	printf("# client driver: %s\n", c.driver);

	double ta = now_us();
	mach_port_t ports[XP_RING + 1];
	double t_port = 0;
	for (int i = 0; i < XP_RING; i++) {
		slot *s = &slots[i];
		if (shimg_create(&c, VK_FORMAT_R8G8B8A8_UNORM, W, H,
		                 VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
		                     VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
		                 0, SHIMG_EXPORT, NULL, NULL, NULL, 0, &s->img)) {
			result("export-surfaces", 0, "shimg_create failed");
			return 1;
		}
		view_create(&c, s->img.img, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT, 0, &s->view);
		VkDescriptorSetAllocateInfo ai = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = c.dpool,
		                                  .descriptorSetCount = 1, .pSetLayouts = &c.dsl_store};
		vkAllocateDescriptorSets(c.dev, &ai, &s->set);
		VkDescriptorImageInfo ii = {.imageView = s->view, .imageLayout = VK_IMAGE_LAYOUT_GENERAL};
		VkWriteDescriptorSet wds = {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = s->set, .descriptorCount = 1,
		                            .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .pImageInfo = &ii};
		vkUpdateDescriptorSets(c.dev, 1, &wds, 0, NULL);
		VkCommandBufferAllocateInfo cai = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = c.pool,
		                                   .commandBufferCount = 1};
		vkAllocateCommandBuffers(c.dev, &cai, &s->cb);
		VkFenceCreateInfo fci = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
		vkCreateFence(c.dev, &fci, NULL, &s->fence);
		double tp = now_us();
		ports[i] = IOSurfaceCreateMachPort(s->img.surf);
		t_port += now_us() - tp;
	}
	VkCommandBuffer cb;
	cmd_begin(&c, &cb);
	for (int i = 0; i < XP_RING; i++)
		cmd_to_general(cb, slots[i].img.img, VK_IMAGE_ASPECT_COLOR_BIT);
	cmd_submit_wait(&c, cb);
	double tb = now_us();

	/* timeline semaphore backed by an exportable MTLSharedEvent */
	VkExportMetalObjectCreateInfoEXT exp = {VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECT_CREATE_INFO_EXT,
	                                        .exportObjectType = VK_EXPORT_METAL_OBJECT_TYPE_METAL_SHARED_EVENT_BIT_EXT};
	VkSemaphoreTypeCreateInfo tci = {VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO, .pNext = &exp,
	                                 .semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE, .initialValue = 0};
	VkSemaphoreCreateInfo sci = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, .pNext = &tci};
	VkResult vr = vkCreateSemaphore(c.dev, &sci, NULL, &sem);
	VkExportMetalSharedEventInfoEXT ese = {VK_STRUCTURE_TYPE_EXPORT_METAL_SHARED_EVENT_INFO_EXT, .semaphore = sem};
	VkExportMetalObjectsInfoEXT moi = {VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT, .pNext = &ese};
	if (!vr)
		c.exportMetal(c.dev, &moi);
	id<MTLSharedEvent> ev = ese.mtlSharedEvent;
	mach_port_t evport = MACH_PORT_NULL;
	if (ev) {
		/* bump the value so the server can check its import does not reset it */
		timeline = 5;
		ev.signaledValue = timeline;
		MTLSharedEventHandle *h = [ev newSharedEventHandle];
		evport = [h eventPort];
		mach_port_mod_refs(mach_task_self(), evport, MACH_PORT_RIGHT_SEND, 1);

		NSError *err = nil;
		NSData *d = [NSKeyedArchiver archivedDataWithRootObject:h requiringSecureCoding:YES error:&err];
		result("event-handle-coding", 3, "NSKeyedArchiver on MTLSharedEventHandle: %s",
		       d ? "archived (unexpected)" : err ? [[err localizedDescription] UTF8String] : "nil");
		[h release];
	}
	result("export-event", vr == VK_SUCCESS && ev && evport,
	       "timeline VkSemaphore -> vkExportMetalObjectsEXT -> MTLSharedEvent %p -> -[MTLSharedEventHandle eventPort] "
	       "(SPI) 0x%x",
	       ev, evport);
	ports[XP_RING] = evport;

	xp_surfaces sm = {0};
	sm.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
	sm.h.msgh_size = sizeof(sm);
	sm.h.msgh_remote_port = server;
	sm.h.msgh_id = XP_SURFACES;
	sm.body.msgh_descriptor_count = 1;
	sm.ports.address = ports;
	sm.ports.count = XP_RING + (evport ? 1 : 0);
	sm.ports.deallocate = FALSE;
	sm.ports.copy = MACH_MSG_PHYSICAL_COPY;
	sm.ports.disposition = MACH_MSG_TYPE_MOVE_SEND;
	sm.ports.type = MACH_MSG_OOL_PORTS_DESCRIPTOR;
	sm.type = XP_SURFACES;
	sm.w = W;
	sm.hgt = H;
	sm.vkformat = VK_FORMAT_R8G8B8A8_UNORM;
	sm.n_surfaces = XP_RING;
	sm.has_event = evport != MACH_PORT_NULL;
	sm.event_value = timeline;
	sm.t_send_ns = now_ns();
	double ts0 = now_us();
	kr = mach_msg(&sm.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(sm), 0, MACH_PORT_NULL, 2000, MACH_PORT_NULL);
	double ts1 = now_us();
	result("export-surfaces", kr == KERN_SUCCESS,
	       "%d x %ux%u RGBA8 via VkExportMetalObjectCreateInfoEXT: create+export %.1fus, IOSurfaceCreateMachPort %.1fus "
	       "total, OOL-ports send %.1fus",
	       XP_RING, W, H, tb - ta, t_port, ts1 - ts0);
	if (kr)
		return 1;

	/* server -> client direction: import the server-allocated surface and verify it */
	{
		xp_rcv rr;
		kr = xp_recv(me, &rr, 5000);
		bool rok = kr == KERN_SUCCESS && xp_type_of(&rr) == XP_SURFACES && rr.surf.m.ports.count == 1;
		char why[128] = "no XP_SURFACES from server";
		if (rok) {
			xp_surfaces *s = &rr.surf.m;
			mach_port_t p = ((mach_port_t *)s->ports.address)[0];
			double tl0 = now_us();
			IOSurfaceRef surf = IOSurfaceLookupFromMachPort(p);
			double tl1 = now_us();
			shimg im;
			rok = surf && shimg_create(&c, (VkFormat)s->vkformat, s->w, s->hgt,
			                           VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_SAMPLED_BIT, 0, SHIMG_IMPORT,
			                           surf, NULL, NULL, 0, &im) == VK_SUCCESS;
			double tl2 = now_us();
			if (rok) {
				buf b;
				buf_create(&c, (VkDeviceSize)s->w * s->hgt * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT, &b);
				VkCommandBuffer cb2;
				cmd_begin(&c, &cb2);
				VkBufferImageCopy reg = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
				                         .imageExtent = {s->w, s->hgt, 1}};
				vkCmdCopyImageToBuffer(cb2, im.img, VK_IMAGE_LAYOUT_GENERAL, b.b, 1, &reg);
				cmd_submit_wait(&c, cb2);
				for (uint32_t y = 0; rok && y < s->hgt; y++)
					for (uint32_t x = 0; x < s->w; x++) {
						uint8_t e[4];
						pattern(x, y, 77, e);
						if (memcmp((uint8_t *)b.map + (y * s->w + x) * 4, e, 4)) {
							snprintf(why, sizeof(why), "mismatch at (%u,%u)", x, y);
							rok = false;
							break;
						}
					}
				buf_destroy(&c, &b);
				shimg_destroy(&c, &im);
				if (rok)
					snprintf(why, sizeof(why), "%ux%u server-exported surface imported, pixel-exact (lookup %.1fus, "
					         "vk import %.1fus)", s->w, s->hgt, tl1 - tl0, tl2 - tl1);
			} else
				snprintf(why, sizeof(why), "lookup/import failed");
			if (surf)
				CFRelease(surf);
			mach_port_deallocate(mach_task_self(), p);
			vm_deallocate(mach_task_self(), (vm_address_t)s->ports.address, sizeof(mach_port_t));
		}
		result("reverse-import", rok, "%s", why);

		/* 2-layer MTLSharedTextureHandle from the server */
		kr = xp_recv(me, &rr, 5000);
		rok = kr == KERN_SUCCESS && xp_type_of(&rr) == XP_SHARED_TEX && rr.surf.m.ports.count == 1;
		snprintf(why, sizeof(why), "no XP_SHARED_TEX from server");
		if (rok) {
			xp_surfaces *s = &rr.surf.m;
			mach_port_t p = ((mach_port_t *)s->ports.address)[0];
			double tl0 = now_us();
			void *tex = mtl_shared_texture_from_port(c.mtl_device, p);
			VkImage img = VK_NULL_HANDLE;
			VkDeviceMemory mem = VK_NULL_HANDLE;
			rok = tex && image_from_mtltex(&c, tex, (VkFormat)s->vkformat, s->w, s->hgt, 2,
			                               VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_SAMPLED_BIT, &img,
			                               &mem) == VK_SUCCESS;
			double tl1 = now_us();
			if (rok) {
				buf b;
				buf_create(&c, (VkDeviceSize)s->w * s->hgt * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT, &b);
				VkCommandBuffer cb2;
				cmd_begin(&c, &cb2);
				VkBufferImageCopy reg = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 1},
				                         .imageExtent = {s->w, s->hgt, 1}};
				vkCmdCopyImageToBuffer(cb2, img, VK_IMAGE_LAYOUT_GENERAL, b.b, 1, &reg);
				cmd_submit_wait(&c, cb2);
				for (uint32_t y = 0; rok && y < s->hgt; y++)
					for (uint32_t x = 0; x < s->w; x++) {
						uint8_t e[4];
						pattern(x, y, 78, e);
						if (memcmp((uint8_t *)b.map + (y * s->w + x) * 4, e, 4)) {
							snprintf(why, sizeof(why), "layer 1 mismatch at (%u,%u)", x, y);
							rok = false;
							break;
						}
					}
				buf_destroy(&c, &b);
				if (rok)
					snprintf(why, sizeof(why), "%ux%u x2 layers, layer 1 pixel-exact (handle+import %.1fus)", s->w,
					         s->hgt, tl1 - tl0);
			} else
				snprintf(why, sizeof(why), "newSharedTextureWithHandle/import failed");
			if (img) {
				vkDestroyImage(c.dev, img, NULL);
				vkFreeMemory(c.dev, mem, NULL);
			}
			objc_release_obj(tex);
			mach_port_deallocate(mach_task_self(), p);
			vm_deallocate(mach_task_self(), (vm_address_t)s->ports.address, sizeof(mach_port_t));
		}
		result("reverse-sharedtex", rok, "%s", why);
	}

	/* 1) wait-before-signal: FRAME goes out first, GPU work + signal 30ms later */
	if (ev) {
		for (int f = 0; f < 5; f++) {
			slot *s = &slots[f % XP_RING];
			if (s->busy && !wait_release(5000, NULL)) {
				result("gpu-wait", 0, "timeout");
				return 1;
			}
			uint64_t value = ++timeline;
			uint32_t frame = 1000 + f;
			const uint64_t delay_ns = 30000000;
			xp_msg m = {.type = XP_FRAME, .slot = (uint32_t)(f % XP_RING), .frame = frame,
			            .flags = XPF_GPU_WAIT | XPF_DELAYED | XPF_VERIFY, .value = value, .t_send_ns = now_ns(),
			            .t_aux_ns = delay_ns};
			s->busy = true;
			xp_send(server, &m, 0, MACH_PORT_NULL);
			struct timespec sl = {0, (long)delay_ns};
			nanosleep(&sl, NULL);
			record(s, frame);
			submit(s, value);
			if (!wait_release(5000, NULL)) {
				result("gpu-wait", 0, "no RELEASE");
				return 1;
			}
		}
		result("gpu-wait", 1, "5 wait-before-signal frames released (server verifies)");
	}

	/* 2) D3 M1 baseline: CPU fence wait in B before FRAME, no shared semaphore */
	if (run_phase("cpu-wait", 2000, nframes, 0, 0))
		return 1;
	/* 3) GPU sync through the shared timeline semaphore */
	if (ev && run_phase("gpu-wait", 5000, nframes, XPF_GPU_WAIT, 0))
		return 1;
	/* 4) same at 90 Hz, so latencies are not inflated by queueing */
	if (run_phase("cpu-wait-90Hz", 10000, 180, 0, 90))
		return 1;
	if (ev && run_phase("gpu-wait-90Hz", 20000, 180, XPF_GPU_WAIT, 90))
		return 1;

	xp_msg bye = {.type = XP_BYE, .t_send_ns = now_ns()};
	xp_send(server, &bye, 0, MACH_PORT_NULL);
	vkDeviceWaitIdle(c.dev);
	for (int i = 0; i < XP_RING; i++) {
		vkDestroyFence(c.dev, slots[i].fence, NULL);
		vkDestroyImageView(c.dev, slots[i].view, NULL);
		shimg_destroy(&c, &slots[i].img);
	}
	vkDestroySemaphore(c.dev, sem, NULL);
	vk_fini(&c);
	return g_fail;
}
