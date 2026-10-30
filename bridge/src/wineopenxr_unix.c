/* Loads our Monado OpenXR runtime (IPC client) directly, without a host loader, and makes winevulkan's handles
 * usable by it. */
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libgen.h>
#include <libproc.h>
#include <sys/stat.h>
#include <unistd.h>
#include <limits.h>
#include <pwd.h>
#include "wineopenxr_unix.h"

#ifdef __x86_64__
#define HOST_ARCH "x86_64"
#else
#define HOST_ARCH "aarch64"
#endif

static PFN_xrGetInstanceProcAddr runtime_gipa;
static XrResult init_result = XR_ERROR_RUNTIME_UNAVAILABLE;
static char init_info[512];
static pthread_once_t init_once = PTHREAD_ONCE_INIT;

void host_gipa(XrInstance instance, const char *name, PFN_xrVoidFunction *func)
{
    *func = NULL;
    if (runtime_gipa && XR_FAILED(runtime_gipa(instance, name, func)))
        *func = NULL;
}

static const char *loaded_moltenvk(void)
{
    for (uint32_t i = 0; i < _dyld_image_count(); i++)
        if (strstr(_dyld_get_image_name(i), "libMoltenVK")) return _dyld_get_image_name(i);
    return NULL;
}

/* CrossOver's MoltenVK. With DXMT nothing has loaded it yet, so load the file win32u.so would (its rpath
 * @loader_path/../../../lib/<arch>); a later winevulkan load then gets the same image. */
const char *moltenvk_path(void)
{
    const char *path = loaded_moltenvk();
    for (uint32_t i = 0; !path && i < _dyld_image_count(); i++)
    {
        const char *name = _dyld_get_image_name(i), *leaf = strrchr(name, '/');
        char buf[1024], real[PATH_MAX];
        if (!leaf || strcmp(leaf, "/win32u.so")) continue;
        snprintf(buf, sizeof(buf), "%.*s/../../../lib/%s/libMoltenVK.dylib", (int)(leaf - name), name, HOST_ARCH);
        if (realpath(buf, real) && dlopen(real, RTLD_NOW | RTLD_GLOBAL)) path = loaded_moltenvk();
    }
    return path;
}

static time_t read_stamp(const char *path, char *buf, size_t size)
{
    struct stat st;
    FILE *f;
    size_t n = 0;
    if ((f = fopen(path, "r")))
    {
        n = fread(buf, 1, size - 1, f);
        fclose(f);
    }
    buf[n] = 0;
    for (char *c = buf; *c; c++)
        if (*c == '\n') *c = ' ';
    return n && !stat(path, &st) ? st.st_mtime : 0;
}

/* The client's ipc-stamp must equal the running server's, else the two were built from
 * different Monado trees; a mismatch refuses the runtime unless WINEOPENXR_IGNORE_IPC_STAMP=1. The server's copy is
 * published to $DARWIN_USER_TEMP_DIR/wivrn/ipc-stamp by the server start: the build dir may be in ~/Documents, which a
 * game process must never touch (TCC prompt). A copy older than the server process is stale and only warned about. */
static int check_ipc_stamp(const char *client_lib, char *msg, size_t size)
{
    char client[256], server[256], path[PATH_MAX], name[64];
    const char *slash = strrchr(client_lib, '/');
    static int pids[8192];
    int count = proc_listallpids(pids, sizeof(pids));
    time_t server_start = 0, stamp_time;

    snprintf(path, sizeof(path), "%.*sipc-stamp", slash ? (int)(slash - client_lib + 1) : 0, client_lib);
    read_stamp(path, client, sizeof(client));
    for (int i = 0; i < count; i++)
    {
        struct proc_bsdinfo info;
        if (proc_name(pids[i], name, sizeof(name)) <= 0 || strcmp(name, "wivrn-server")) continue;
        if (proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info))
            server_start = info.pbi_start_tvsec;
        break;
    }
    if (!confstr(_CS_DARWIN_USER_TEMP_DIR, path, sizeof(path))) path[0] = 0;
    strncat(path, "wivrn/ipc-stamp", sizeof(path) - strlen(path) - 1);
    stamp_time = read_stamp(path, server, sizeof(server));

    if (!client[0]) snprintf(msg, size, "ipc-stamp: none next to the client");
    else if (!server[0]) snprintf(msg, size, "ipc-stamp: server published none (client %s)", client);
    else if (strcmp(client, server))
    {
        if (stamp_time < server_start)
        {
            snprintf(msg, size, "ipc-stamp: UNVERIFIED, server stamp predates the server (client %s)", client);
            return 1;
        }
        snprintf(msg, size, "IPC STAMP MISMATCH: client [%s] server [%s]; client and server come from different WiVRn builds",
                 client, server);
        return getenv("WINEOPENXR_IGNORE_IPC_STAMP") != NULL;
    }
    else if (stamp_time < server_start) snprintf(msg, size, "ipc-stamp: match, but server stamp predates the server (%s)", client);
    else snprintf(msg, size, "ipc-stamp match (%s)", client);
    return 1;
}

/* The "library_path" of an OpenXR runtime manifest, resolved against the manifest's dir. */
static int manifest_library(const char *json, char *out, size_t size)
{
    char buf[8192], dir[PATH_MAX];
    FILE *f = fopen(json, "r");
    size_t n;
    char *k, *q, *e;
    if (!f) return 0;
    n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = 0;
    if (!(k = strstr(buf, "\"library_path\"")) || !(k = strchr(k + 14, ':')) || !(q = strchr(k, '"'))
        || !(e = strchr(q + 1, '"')))
        return 0;
    *e = 0;
    if (q[1] == '/') snprintf(out, size, "%s", q + 1);
    else
    {
        snprintf(dir, sizeof(dir), "%s", json);
        snprintf(out, size, "%s/%s", dirname(dir), q + 1);
    }
    return 1;
}

/* Like the host OpenXR loader: XR_RUNTIME_JSON, then active_runtime.json in the XDG config dirs and
 * /usr/local/share. A runtime next to the .so (test rigs) comes first. */
static int find_runtime(char *path, size_t size)
{
    Dl_info dli;
    char self[1024], json[PATH_MAX];
    const char *home, *xdg = getenv("XDG_CONFIG_HOME"), *env = getenv("XR_RUNTIME_JSON");
    struct passwd *pw = getpwuid(getuid());

    if (dladdr((void *)find_runtime, &dli))
    {
        snprintf(self, sizeof(self), "%s", dli.dli_fname);
        snprintf(path, size, "%s/libopenxr_monado.dylib", dirname(self));
        if (!access(path, F_OK)) return 1;
    }
    if (env && manifest_library(env, path, size)) return 1;
    home = pw ? pw->pw_dir : getenv("HOME");
    const char *dirs[] = {xdg, home ? "~" : NULL, "/etc/xdg", "/usr/local/share", "/usr/share"};
    for (size_t i = 0; i < sizeof(dirs) / sizeof(*dirs); i++)
    {
        if (!dirs[i]) continue;
        if (!strcmp(dirs[i], "~")) snprintf(json, sizeof(json), "%s/.config/openxr/1/active_runtime.json", home);
        else snprintf(json, sizeof(json), "%s/openxr/1/active_runtime.json", dirs[i]);
        if (manifest_library(json, path, size)) return 1;
    }
    return 0;
}

static void load_runtime(void)
{
    char stamp_msg[320];
    char path[1024];
    const char *rt = getenv("MACVR_OPENXR_RUNTIME");
    if (!rt)
    {
        if (!find_runtime(path, sizeof(path)))
        {
            snprintf(init_info, sizeof(init_info), "no OpenXR runtime: install WiVRn (XR_RUNTIME_JSON or "
                     "~/.config/openxr/1/active_runtime.json)");
            return;
        }
        rt = path;
    }

    /* Monado must use the MoltenVK winevulkan already loaded; there is no Vulkan loader in this process. */
    const char *mvk = moltenvk_path();
    if (mvk) setenv("XRT_VK_GIPA_LIBRARY", mvk, 0);
    /* DXVK and our xrCreateVulkanDeviceKHR enable timelineSemaphore; MoltenVK always has it. */
    setenv("OXR_DEBUG_FORCE_TIMELINE_SEMAPHORES", "1", 0);

    if (!check_ipc_stamp(rt, stamp_msg, sizeof(stamp_msg)))
    {
        snprintf(init_info, sizeof(init_info), "%s", stamp_msg);
        return;
    }

    void *lib = dlopen(rt, RTLD_NOW | RTLD_LOCAL);
    if (!lib)
    {
        snprintf(init_info, sizeof(init_info), "dlopen %s: %s", rt, dlerror());
        return;
    }
    PFN_xrNegotiateLoaderRuntimeInterface negotiate =
        (PFN_xrNegotiateLoaderRuntimeInterface)dlsym(lib, "xrNegotiateLoaderRuntimeInterface");
    XrNegotiateLoaderInfo li = {XR_LOADER_INTERFACE_STRUCT_LOADER_INFO, XR_LOADER_INFO_STRUCT_VERSION, sizeof(li),
                                1, XR_CURRENT_LOADER_RUNTIME_VERSION, XR_MAKE_VERSION(1, 0, 0), XR_MAKE_VERSION(1, 1, 0x3ff)};
    XrNegotiateRuntimeRequest rr = {XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST, XR_RUNTIME_INFO_STRUCT_VERSION, sizeof(rr)};
    XrResult r = negotiate ? negotiate(&li, &rr) : XR_ERROR_RUNTIME_UNAVAILABLE;
    if (XR_FAILED(r) || !rr.getInstanceProcAddr)
    {
        snprintf(init_info, sizeof(init_info), "%s: negotiation failed (%d)", rt, r);
        return;
    }
    runtime_gipa = rr.getInstanceProcAddr;
    host_gipa(XR_NULL_HANDLE, "xrEnumerateInstanceExtensionProperties", (PFN_xrVoidFunction *)&host.xrEnumerateInstanceExtensionProperties);
    host_gipa(XR_NULL_HANDLE, "xrEnumerateApiLayerProperties", (PFN_xrVoidFunction *)&host.xrEnumerateApiLayerProperties);
    host_gipa(XR_NULL_HANDLE, "xrCreateInstance", (PFN_xrVoidFunction *)&host.xrCreateInstance);
    snprintf(init_info, sizeof(init_info), "runtime %s, MoltenVK %s, %s", rt, mvk ? mvk : "(not found)", stamp_msg);
    init_result = XR_SUCCESS;
}

NTSTATUS bridge_init(void *args)
{
    struct init_params *p = args;
    pthread_once(&init_once, load_runtime);
    p->result = init_result;
    snprintf(p->info, sizeof(p->info), "%s", init_info);
    return 0;
}

NTSTATUS bridge_has_function(void *args)
{
    struct has_function_params *p = args;
    PFN_xrVoidFunction f;
    host_gipa(p->instance, p->name, &f);
    p->result = f ? XR_SUCCESS : XR_ERROR_FUNCTION_UNSUPPORTED;
    return 0;
}

NTSTATUS bridge_create_instance(void *args)
{
    struct create_instance_params *p = args;
    if (!host.xrCreateInstance)
    {
        p->result = XR_ERROR_RUNTIME_UNAVAILABLE;
        return 0;
    }
    if (XR_SUCCEEDED(p->result = host.xrCreateInstance(p->info, p->instance)))
        host_load_functions(*p->instance);
    return 0;
}

NTSTATUS bridge_destroy_instance(void *args)
{
    struct destroy_instance_params *p = args;
    p->result = host.xrDestroyInstance(p->instance);
    return 0;
}

/* PE dispatchable handle -> struct vulkan_client_object { loader_magic; unix_handle } -> struct vulkan_object
 * { host_handle; ... }. The host object must carry MoltenVK's ICD magic. */
static uint64_t unwrap(uint64_t pe)
{
    if (!pe) return 0;
    uint64_t unix_obj = ((uint64_t *)(uintptr_t)pe)[1];
    uint64_t host_handle = unix_obj ? *(uint64_t *)(uintptr_t)unix_obj : 0;
    return host_handle && *(uint64_t *)(uintptr_t)host_handle == 0x01CDC0DE ? host_handle : 0;
}

NTSTATUS bridge_vk_unwrap(void *args)
{
    struct vk_unwrap_params *p = args;
    p->host = unwrap(p->handle);
    return 0;
}

static XrResult suggested_device(XrInstance instance, XrSystemId system, VkInstance host_instance, VkPhysicalDevice *dev)
{
    if (!host.xrGetVulkanGraphicsDeviceKHR) return XR_ERROR_FUNCTION_UNSUPPORTED;
    return host.xrGetVulkanGraphicsDeviceKHR(instance, system, host_instance, dev);
}

NTSTATUS bridge_vk_suggested_device(void *args)
{
    struct vk_suggested_device_params *p = args;
    VkInstance host_instance = (VkInstance)(uintptr_t)unwrap(p->pe_instance);
    VkPhysicalDevice dev;
    if (!host_instance)
    {
        p->result = XR_ERROR_GRAPHICS_DEVICE_INVALID;
        return 0;
    }
    if (XR_FAILED(p->result = suggested_device(p->instance, p->system, host_instance, &dev))) return 0;
    p->result = XR_ERROR_RUNTIME_FAILURE;
    for (uint32_t i = 0; i < p->count; i++)
        if (unwrap(p->pe_devices[i]) == (uint64_t)(uintptr_t)dev)
        {
            p->index = i;
            p->result = XR_SUCCESS;
        }
    return 0;
}

NTSTATUS bridge_create_session(void *args)
{
    struct create_session_params *p = args;
    XrGraphicsBindingVulkanKHR *b = p->binding;
    if (b && !p->host_handles)
    {
        b->instance = (VkInstance)(uintptr_t)unwrap((uint64_t)(uintptr_t)b->instance);
        b->physicalDevice = (VkPhysicalDevice)(uintptr_t)unwrap((uint64_t)(uintptr_t)b->physicalDevice);
        b->device = (VkDevice)(uintptr_t)unwrap((uint64_t)(uintptr_t)b->device);
        if (!b->instance || !b->physicalDevice || !b->device)
        {
            fprintf(stderr, "wineopenxr: graphics binding has handles that are not winevulkan/MoltenVK objects\n");
            p->result = XR_ERROR_GRAPHICS_DEVICE_INVALID;
            return 0;
        }
    }
    if (b)
    {
        /* Monado checks the session's device against the one it suggested, so make sure it suggested one. */
        VkPhysicalDevice dev;
        if (XR_FAILED(p->result = suggested_device(p->instance, p->info->systemId, b->instance, &dev))) return 0;
    }
    p->result = host.xrCreateSession(p->instance, p->info, p->session);
    return 0;
}

NTSTATUS bridge_time_sample(void *args)
{
    struct time_sample_params *p = args;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    p->monotonic_ns = ts.tv_sec * 1000000000ll + ts.tv_nsec;
    p->continuous_ns = (int64_t)(mach_continuous_time() * tb.numer / tb.denom);
    p->result = host.xrConvertTimespecTimeToTimeKHR ? host.xrConvertTimespecTimeToTimeKHR(p->instance, &ts, &p->time)
                                                    : XR_ERROR_FUNCTION_UNSUPPORTED;
    return 0;
}
