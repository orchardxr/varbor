/* wineopenxr.dll: Windows OpenXR runtime that forwards to our Monado IPC client through the unixlib. Emulates
 * XR_KHR_D3D11_enable on XR_KHR_vulkan_enable with DXVK's interop, and XR_KHR_win32_convert_performance_counter_time on
 * XR_KHR_convert_timespec_time. See docs/bridge-plan.md. */
#include "wineopenxr_private.h"
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef NTSTATUS(WINAPI *unix_dispatcher_t)(UINT64, unsigned int, void *);
typedef NTSTATUS(WINAPI *query_vm_t)(HANDLE, const void *, int, void *, SIZE_T, SIZE_T *);

static UINT64 unixlib;
static unix_dispatcher_t *dispatcher;
static CRITICAL_SECTION lock;
static BOOL runtime_ok;

static const GUID IID_IDXGIVkInteropDevice1 = {0xe2ef5fa5, 0xdc21, 0x4af7, {0x90, 0xc4, 0xf6, 0x7e, 0xf6, 0xa0, 0x93, 0x24}};

#define MAX_IMAGES 8

struct session
{
    XrSession handle;
    ID3D11Device *d3d11;
    ID3D11DeviceContext *context;
    IDXGIVkInteropDevice1 *interop;
    /* DXMT: the bridge's own Vulkan device (unix side), guarded by queue_lock like DXVK's submission queue. */
    uint64_t dxmt_ctx;
    D3DKMT_HANDLE kmt_device;
    BOOL cpu_sync;
    /* CPU sync without a keyed mutex (DXMT before v0.80, CrossOver 26): the game signals fence_value at release,
     * the worker waits for it before the copy. */
    ID3D11DeviceContext4 *context4;
    ID3D11Fence *fence;
    UINT64 fence_value;
    HANDLE fence_event;
    CRITICAL_SECTION queue_lock;
    /* WINEOPENXR_ASYNC: a worker thread runs xrEndFrame's copies, host releases and the host xrEndFrame. 1: the next
     * xrWaitFrame waits for it, 2: the next xrBeginFrame does. */
    int async;
    HANDLE worker;
    SRWLOCK job_lock;
    CONDITION_VARIABLE job_cv;
    BOOL job_busy, worker_exit;
    XrResult job_result;
    struct end_job *job;
    struct session *next;
};

#define MAX_SLICES 4

struct swapchain
{
    XrSwapchain handle;
    struct session *session;
    enum { SWAPCHAIN_HOST, SWAPCHAIN_SPLIT, SWAPCHAIN_LOCAL, SWAPCHAIN_COPY } kind;
    uint32_t image_count;
    ID3D11Texture2D *textures[MAX_IMAGES]; /* what the app sees */
    uint32_t slices;
    XrSwapchain hosts[MAX_SLICES];
    ID3D11Texture2D *host_textures[MAX_SLICES][MAX_IMAGES]; /* split only */
    uint32_t acquired[MAX_IMAGES][MAX_SLICES];              /* FIFO of acquired indices, per slice */
    uint32_t acquired_head, acquired_count, next_local;
    /* copy (DXMT): the app's textures are DXMT shared textures, copied into the host images at release */
    uint64_t host_images[MAX_SLICES][MAX_IMAGES];
    uint64_t dxmt_images[MAX_IMAGES];
    IDXGIKeyedMutex *keyed[MAX_IMAGES];
    D3DKMT_HANDLE kmt_mutex[MAX_IMAGES];
    ID3D11Query *query;
    /* copy: a released image whose copy waits for xrEndFrame, which knows the part of it the layers show */
    BOOL pending, pending_keyed;
    UINT64 pending_fence;
    uint32_t pending_slot[MAX_SLICES];
    struct dxmt_copy_params pending_copy;
    struct swapchain *next;
};

/* One instance at a time, like Proton's wineopenxr. */
static struct
{
    XrInstance handle;
    BOOL d3d11, win32_time;
    LONGLONG qpc_freq, time_offset_ns;
    PFN_vkGetInstanceProcAddr vk_gipa;
    VkInstance vk_instance;
} inst;
static struct session *sessions;
static struct swapchain *swapchains;

struct stats;
static XrResult flush_copy(struct swapchain *sc, const int32_t (*rects)[4], struct stats *st);
static void drain(struct session *s);
static void start_worker(struct session *s);
static void stop_worker(struct session *s);

/* WINEOPENXR_LOG=<file>: append messages there instead of stderr (which NotProton's launcher drops). */
static FILE *log_file;

static BOOL CALLBACK open_log(INIT_ONCE *once, void *param, void **ctx)
{
    const char *path = getenv("WINEOPENXR_LOG");
    if (path) log_file = fopen(path, "a");
    return TRUE;
}

static void ERR(const char *fmt, ...)
{
    static INIT_ONCE once = INIT_ONCE_STATIC_INIT;
    char buf[2048];
    FILE *out;
    va_list ap;
    InitOnceExecuteOnce(&once, open_log, NULL, NULL);
    out = log_file ? log_file : stderr;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    fprintf(out, "wineopenxr: %s\n", buf);
    fflush(out);
}

NTSTATUS wine_unix_call(enum unix_call code, void *args)
{
    return unixlib ? (*dispatcher)(unixlib, code, args) : 0xc0000135 /* STATUS_DLL_NOT_FOUND */;
}

/* WINEOPENXR_STATS=1: per-frame times of the bridge, one line per 300 frames for the app's frame thread (a frame ends
 * at xrEndFrame) and one for the async worker (a frame is one xrEndFrame job). Frames whose bridge time is over
 * 6 ms are logged one by one. */
enum stat
{
    S_INTERVAL, S_WAIT, S_DRAIN, S_BEGIN, S_ACQUIRE, S_ACQ_SYNC, S_WAIT_IMAGE, S_RELEASE, S_END, S_GAME,
    S_KMT_ACQUIRE, S_COPY, S_FENCE, S_SUBMIT, S_HOST_RELEASE, S_KMT_RELEASE, S_HOST_END, S_WORK, S_LAG, S_COUNT
};
static const char *const stat_names[S_COUNT] = {
    "interval", "wait", "drain", "begin", "acquire", "acq_sync", "wait_img", "release", "end", "bridge",
    "kmt_acq", "copy", "fence", "submit", "host_rel", "kmt_rel", "host_end", "work", "lag"};
#define STAT_WINDOW 300

struct stats
{
    const char *name;
    LONGLONG cur[S_COUNT], v[S_COUNT][STAT_WINDOW], last;
    uint32_t n, logged;
};
static struct stats game_stats = {"frame thread"}, work_stats = {"worker"};
static int stats_on; /* 2: also one line per frame ("F interval wait+drain bridge" / "W work lag", ms) */
static LONGLONG stats_freq;

static LONGLONG now(void)
{
    LARGE_INTEGER t;
    QueryPerformanceCounter(&t);
    return t.QuadPart;
}

static void stat_add(struct stats *st, enum stat k, LONGLONG ticks)
{
    if (stats_on && st) st->cur[k] += ticks;
}

static int cmp_ll(const void *a, const void *b)
{
    LONGLONG x = *(const LONGLONG *)a, y = *(const LONGLONG *)b;
    return x < y ? -1 : x > y;
}

static double ms(LONGLONG ticks)
{
    return ticks * 1000.0 / stats_freq;
}

/* total: the stat that is this thread's bridge time per frame. */
static void stat_commit(struct stats *st, enum stat total)
{
    char line[1536];
    int len = 0;
    LONGLONG sorted[STAT_WINDOW], t = now();

    if (!stats_on) return;
    if (st == &game_stats)
    {
        st->cur[S_INTERVAL] = st->last ? t - st->last : 0;
        st->last = t;
        st->cur[S_GAME] = st->cur[S_BEGIN] + st->cur[S_ACQUIRE] + st->cur[S_WAIT_IMAGE] + st->cur[S_RELEASE] + st->cur[S_END];
    }
    if (stats_on == 2 && st == &game_stats)
        ERR("F %.3f %.3f %.3f", ms(st->cur[S_INTERVAL]), ms(st->cur[S_WAIT] + st->cur[S_DRAIN]), ms(st->cur[S_GAME]));
    else if (stats_on == 2)
        ERR("W %.3f %.3f", ms(st->cur[S_WORK]), ms(st->cur[S_LAG]));
    if (ms(st->cur[total]) > 6.0 && st->logged < 10)
    {
        len = snprintf(line, sizeof(line), "%s spike:", st->name);
        for (int k = 0; k < S_COUNT; k++)
            if (st->cur[k]) len += snprintf(line + len, sizeof(line) - len, " %s %.2f", stat_names[k], ms(st->cur[k]));
        ERR("%s", line);
        st->logged++;
    }
    for (int k = 0; k < S_COUNT; k++)
    {
        st->v[k][st->n] = st->cur[k];
        st->cur[k] = 0;
    }
    if (++st->n < STAT_WINDOW) return;

    len = snprintf(line, sizeof(line), "%s, %u frames, ms mean/p99/max:", st->name, STAT_WINDOW);
    for (int k = 0; k < S_COUNT; k++)
    {
        LONGLONG sum = 0;
        memcpy(sorted, st->v[k], sizeof(sorted));
        qsort(sorted, STAT_WINDOW, sizeof(*sorted), cmp_ll);
        for (int i = 0; i < STAT_WINDOW; i++) sum += sorted[i];
        if (!sum) continue;
        len += snprintf(line + len, sizeof(line) - len, " %s %.2f/%.2f/%.2f", stat_names[k], ms(sum) / STAT_WINDOW,
                        ms(sorted[STAT_WINDOW * 99 / 100]), ms(sorted[STAT_WINDOW - 1]));
    }
    {
        int over4 = 0, over20 = 0;
        for (int i = 0; i < STAT_WINDOW; i++)
        {
            over4 += ms(st->v[total][i]) > 4.0;
            over20 += ms(st->v[S_INTERVAL][i]) > 20.0;
        }
        len += snprintf(line + len, sizeof(line) - len, "; %s>4ms %d", stat_names[total], over4);
        if (st == &game_stats) snprintf(line + len, sizeof(line) - len, ", interval>20ms %d", over20);
    }
    ERR("%s", line);
    st->n = 0;
    st->logged = 0;
}

/* WINEOPENXR_* settings for games whose launcher passes no custom environment (NotProton): KEY=VALUE lines in
 * C:\macvr\wineopenxr.env, the environment wins. */
static void load_env_file(void)
{
    char line[256];
    FILE *f = fopen("C:\\macvr\\wineopenxr.env", "r");
    if (!f) return;
    while (fgets(line, sizeof(line), f))
    {
        char *eq = strchr(line, '=');
        line[strcspn(line, "\r\n")] = 0;
        if (!eq || strncmp(line, "WINEOPENXR_", 11)) continue;
        *eq = 0;
        if (!getenv(line))
        {
            *eq = '=';
            _putenv(line);
        }
    }
    fclose(f);
}

BOOL WINAPI DllMain(HINSTANCE dll, DWORD reason, void *reserved)
{
    if (reason == DLL_PROCESS_ATTACH)
    {
        HMODULE ntdll = GetModuleHandleA("ntdll.dll");
        query_vm_t query = (query_vm_t)GetProcAddress(ntdll, "NtQueryVirtualMemory");
        dispatcher = (unix_dispatcher_t *)GetProcAddress(ntdll, "__wine_unix_call_dispatcher");
        DisableThreadLibraryCalls(dll);
        InitializeCriticalSection(&lock);
        load_env_file();
        /* 1000 = MemoryWineLoadUnixLib (MemoryWineUnixFuncs before Wine 10) */
        if (!query || !dispatcher || query(GetCurrentProcess(), dll, 1000, &unixlib, sizeof(unixlib), NULL))
            unixlib = 0;
    }
    return TRUE;
}

static BOOL CALLBACK init_runtime(INIT_ONCE *once, void *param, void **ctx)
{
    struct init_params p = {0};
    LARGE_INTEGER f;
    QueryPerformanceFrequency(&f);
    stats_freq = f.QuadPart;
    stats_on = getenv("WINEOPENXR_STATS") ? atoi(getenv("WINEOPENXR_STATS")) : 0;
    if (!unixlib)
        ERR("no unixlib: wineopenxr.so must be next to wineopenxr.dll in WINEDLLPATH (<dir>/x86_64-unix, or the same dir under FEX)");
    else if (UNIX_CALL(init, &p) || XR_FAILED(p.result))
        ERR("%s", p.info);
    else
    {
        ERR("%s", p.info);
        runtime_ok = TRUE;
    }
    return TRUE;
}

static BOOL runtime_ready(void)
{
    static INIT_ONCE once = INIT_ONCE_STATIC_INIT;
    InitOnceExecuteOnce(&once, init_runtime, NULL, NULL);
    return runtime_ok;
}

static struct session *get_session(XrSession handle)
{
    struct session *s;
    EnterCriticalSection(&lock);
    for (s = sessions; s && s->handle != handle; s = s->next) {}
    LeaveCriticalSection(&lock);
    return s;
}

static struct swapchain *get_swapchain(XrSwapchain handle)
{
    struct swapchain *s;
    EnterCriticalSection(&lock);
    for (s = swapchains; s && s->handle != handle; s = s->next) {}
    LeaveCriticalSection(&lock);
    return s;
}

/* Host calls that may submit on DXVK's queue run inside its submission lock, after DXVK flushed the frame's work. */
static void d3d11_lock(struct session *s, BOOL flush)
{
    if (s && s->dxmt_ctx) EnterCriticalSection(&s->queue_lock);
    if (!s || !s->interop) return;
    if (flush) s->interop->lpVtbl->FlushRenderingCommands(s->interop);
    s->interop->lpVtbl->LockSubmissionQueue(s->interop);
}

static void d3d11_unlock(struct session *s)
{
    if (s && s->interop) s->interop->lpVtbl->ReleaseSubmissionQueue(s->interop);
    if (s && s->dxmt_ctx) LeaveCriticalSection(&s->queue_lock);
}

/*
 * Extensions
 */

static const XrExtensionProperties pe_extensions[] = {
    {XR_TYPE_EXTENSION_PROPERTIES, NULL, XR_KHR_D3D11_ENABLE_EXTENSION_NAME, XR_KHR_D3D11_enable_SPEC_VERSION},
    {XR_TYPE_EXTENSION_PROPERTIES, NULL, XR_KHR_WIN32_CONVERT_PERFORMANCE_COUNTER_TIME_EXTENSION_NAME,
     XR_KHR_win32_convert_performance_counter_time_SPEC_VERSION},
};
/* Host extension each PE extension is built on. */
static const char *const pe_extension_bases[] = {XR_KHR_VULKAN_ENABLE_EXTENSION_NAME, "XR_KHR_convert_timespec_time"};

static BOOL is_visible_host_extension(const char *name)
{
    for (unsigned int i = 0; i < VISIBLE_HOST_EXTENSION_COUNT; i++)
        if (!strcmp(visible_host_extensions[i], name)) return TRUE;
    return FALSE;
}

static XrResult host_extensions(XrExtensionProperties **out, uint32_t *count)
{
    struct xrEnumerateInstanceExtensionProperties_params p = {NULL, 0, count, NULL};
    if (!runtime_ready()) return XR_ERROR_RUNTIME_UNAVAILABLE;
    UNIX_CALL(xrEnumerateInstanceExtensionProperties, &p);
    if (XR_FAILED(p.result)) return p.result;
    *out = calloc(*count, sizeof(**out));
    for (uint32_t i = 0; i < *count; i++) (*out)[i].type = XR_TYPE_EXTENSION_PROPERTIES;
    p.propertyCapacityInput = *count;
    p.properties = *out;
    UNIX_CALL(xrEnumerateInstanceExtensionProperties, &p);
    if (XR_FAILED(p.result)) free(*out);
    return p.result;
}

WINE_XR(XrResult) wine_xrEnumerateInstanceExtensionProperties(const char *layer, uint32_t capacity, uint32_t *count,
                                                              XrExtensionProperties *props)
{
    XrExtensionProperties *host_props, list[512];
    uint32_t host_count, n = 0;
    XrResult r;

    if (layer) return XR_ERROR_API_LAYER_NOT_PRESENT;
    if (XR_FAILED(r = host_extensions(&host_props, &host_count))) return r;
    for (uint32_t i = 0; i < host_count && n < ARRAY_SIZE(list); i++)
    {
        if (is_visible_host_extension(host_props[i].extensionName)) list[n++] = host_props[i];
        for (unsigned int j = 0; j < ARRAY_SIZE(pe_extensions); j++)
            if (!strcmp(host_props[i].extensionName, pe_extension_bases[j])) list[n++] = pe_extensions[j];
    }
    free(host_props);

    *count = n;
    if (!capacity) return XR_SUCCESS;
    if (capacity < n) return XR_ERROR_SIZE_INSUFFICIENT;
    for (uint32_t i = 0; i < n; i++)
    {
        void *next = props[i].next;
        props[i] = list[i];
        props[i].next = next;
    }
    return XR_SUCCESS;
}

WINE_XR(XrResult) wine_xrEnumerateApiLayerProperties(uint32_t capacity, uint32_t *count, XrApiLayerProperties *props)
{
    struct xrEnumerateApiLayerProperties_params p = {capacity, count, props};
    if (!runtime_ready()) return XR_ERROR_RUNTIME_UNAVAILABLE;
    UNIX_CALL(xrEnumerateApiLayerProperties, &p);
    return p.result;
}

/*
 * Instance
 */

static LONGLONG qpc_to_ns(LONGLONG qpc)
{
    return qpc / inst.qpc_freq * 1000000000 + qpc % inst.qpc_freq * 1000000000 / inst.qpc_freq;
}

static LONGLONG ns_to_qpc(LONGLONG ns)
{
    return ns / 1000000000 * inst.qpc_freq + (ns % 1000000000 * inst.qpc_freq + 500000000) / 1000000000;
}

/* XrTime = QPC in ns + offset. Both clocks are monotonic and count sleep (Wine's QPC on macOS is
 * mach_continuous_time, Monado's XrTime CLOCK_MONOTONIC), so the offset is sampled once, with the tightest QPC
 * bracket around a host clock read. */
static XrResult calibrate_time(XrInstance instance)
{
    LONGLONG best = -1, qpc_vs_continuous = 0;
    LARGE_INTEGER freq, a, b;
    QueryPerformanceFrequency(&freq);
    inst.qpc_freq = freq.QuadPart;
    for (int i = 0; i < 16; i++)
    {
        struct time_sample_params p = {instance};
        QueryPerformanceCounter(&a);
        UNIX_CALL(time_sample, &p);
        QueryPerformanceCounter(&b);
        if (XR_FAILED(p.result)) return p.result;
        if (best < 0 || b.QuadPart - a.QuadPart < best)
        {
            best = b.QuadPart - a.QuadPart;
            inst.time_offset_ns = p.time - qpc_to_ns(a.QuadPart) - qpc_to_ns(best) / 2;
            qpc_vs_continuous = qpc_to_ns(a.QuadPart) + qpc_to_ns(best) / 2 - p.continuous_ns;
        }
    }
    if (getenv("WINEOPENXR_DEBUG"))
        ERR("XrTime = QPC + %lld ns, calibrated within +-%lld ns; QPC - mach_continuous_time = %lld ns",
            inst.time_offset_ns, qpc_to_ns(best) / 2, qpc_vs_continuous);
    return XR_SUCCESS;
}

WINE_XR(XrResult) wine_xrCreateInstance(const XrInstanceCreateInfo *info, XrInstance *instance)
{
    const char *names[256];
    XrInstanceCreateInfo ci = *info;
    BOOL d3d11 = FALSE, win32_time = FALSE, vk1 = FALSE;
    uint32_t n = 0;

    if (!runtime_ready()) return XR_ERROR_RUNTIME_UNAVAILABLE;
    if (inst.handle) return XR_ERROR_LIMIT_REACHED;
    if (info->enabledExtensionCount > ARRAY_SIZE(names) - 3) return XR_ERROR_LIMIT_REACHED;
    for (uint32_t i = 0; i < info->enabledExtensionCount; i++)
    {
        const char *e = info->enabledExtensionNames[i];
        if (!strcmp(e, XR_KHR_D3D11_ENABLE_EXTENSION_NAME))
            d3d11 = TRUE;
        else if (!strcmp(e, XR_KHR_WIN32_CONVERT_PERFORMANCE_COUNTER_TIME_EXTENSION_NAME))
            win32_time = TRUE;
        else if (!is_visible_host_extension(e))
            return XR_ERROR_EXTENSION_NOT_PRESENT;
        else
        {
            vk1 |= !strcmp(e, XR_KHR_VULKAN_ENABLE_EXTENSION_NAME);
            names[n++] = e;
        }
    }
    if (d3d11 && !vk1) names[n++] = XR_KHR_VULKAN_ENABLE_EXTENSION_NAME;
    /* xrGetVulkanGraphicsDevice2KHR goes through the v1 call, which takes the instance handle directly. */
    for (uint32_t i = 0; i < n && !vk1 && !d3d11; i++)
        if (!strcmp(names[i], XR_KHR_VULKAN_ENABLE2_EXTENSION_NAME)) names[n++] = XR_KHR_VULKAN_ENABLE_EXTENSION_NAME;
    if (win32_time) names[n++] = "XR_KHR_convert_timespec_time";
    ci.enabledExtensionCount = n;
    ci.enabledExtensionNames = names;

    struct create_instance_params p = {&ci, instance};
    UNIX_CALL(create_instance, &p);
    if (XR_FAILED(p.result)) return p.result;

    memset(&inst, 0, sizeof(inst));
    inst.handle = *instance;
    inst.d3d11 = d3d11;
    inst.win32_time = win32_time;
    if (win32_time && XR_FAILED(calibrate_time(*instance))) ERR("time calibration failed");
    return XR_SUCCESS;
}

WINE_XR(XrResult) wine_xrDestroyInstance(XrInstance instance)
{
    struct destroy_instance_params p = {instance};
    UNIX_CALL(destroy_instance, &p);
    if (XR_SUCCEEDED(p.result) && instance == inst.handle) memset(&inst, 0, sizeof(inst));
    return p.result;
}

WINE_XR(XrResult) wine_xrGetInstanceProcAddr(XrInstance instance, const char *name, PFN_xrVoidFunction *func)
{
    int lo = 0, hi = (int)pe_function_count - 1;
    const struct xr_function *f = NULL;

    if (!name || !func) return XR_ERROR_VALIDATION_FAILURE;
    *func = NULL;
    if (!strcmp(name, "xrGetInstanceProcAddr"))
    {
        *func = (PFN_xrVoidFunction)wine_xrGetInstanceProcAddr;
        return XR_SUCCESS;
    }
    while (lo <= hi && !f)
    {
        int mid = (lo + hi) / 2, c = strcmp(name, pe_functions[mid].name);
        if (!c) f = &pe_functions[mid];
        else if (c < 0) hi = mid - 1;
        else lo = mid + 1;
    }
    /* The loader calls these with a NULL instance and doesn't check for NULL; they report an unusable runtime. */
    if (f && (f->func == (PFN_xrVoidFunction)wine_xrEnumerateInstanceExtensionProperties ||
              f->func == (PFN_xrVoidFunction)wine_xrEnumerateApiLayerProperties ||
              f->func == (PFN_xrVoidFunction)wine_xrCreateInstance))
    {
        *func = f->func;
        return XR_SUCCESS;
    }
    if (!f || !runtime_ready())
    {
        if (getenv("WINEOPENXR_DEBUG")) ERR("no %s (%p, found %d)", name, instance, f != NULL);
        return XR_ERROR_FUNCTION_UNSUPPORTED;
    }

    if (f->extension && !strcmp(f->extension, XR_KHR_D3D11_ENABLE_EXTENSION_NAME))
    {
        if (!instance || instance != inst.handle || !inst.d3d11) return XR_ERROR_FUNCTION_UNSUPPORTED;
    }
    else if (f->extension && !strcmp(f->extension, XR_KHR_WIN32_CONVERT_PERFORMANCE_COUNTER_TIME_EXTENSION_NAME))
    {
        if (!instance || instance != inst.handle || !inst.win32_time) return XR_ERROR_FUNCTION_UNSUPPORTED;
    }
    else
    {
        struct has_function_params p = {instance, name};
        UNIX_CALL(has_function, &p);
        if (XR_FAILED(p.result) && getenv("WINEOPENXR_DEBUG")) ERR("host has no %s (%p): %d", name, instance, p.result);
        if (XR_FAILED(p.result)) return p.result;
    }
    *func = f->func;
    return XR_SUCCESS;
}

/*
 * Vulkan
 */

/* Names only the host side can use; winevulkan would reject them. */
static BOOL host_only_vk_extension(const char *name, size_t len)
{
    static const char *const prefixes[] = {"VK_EXT_metal_objects", "VK_EXT_metal_surface", "VK_KHR_portability_", "VK_MVK_"};
    for (unsigned int i = 0; i < ARRAY_SIZE(prefixes); i++)
        if (!strncmp(name, prefixes[i], strlen(prefixes[i]))) return TRUE;
    return len > 3 && !strncmp(name + len - 3, "_fd", 3);
}

static XrResult filtered_vk_extensions(BOOL device, XrInstance instance, XrSystemId system, uint32_t capacity,
                                       uint32_t *count, char *buffer)
{
    struct xrGetVulkanDeviceExtensionsKHR_params p = {instance, system, 0, count, NULL};
    char *host_list, *out, *s;
    size_t n = 0;

    if (device) UNIX_CALL(xrGetVulkanDeviceExtensionsKHR, &p);
    else UNIX_CALL(xrGetVulkanInstanceExtensionsKHR, &p);
    if (XR_FAILED(p.result)) return p.result;
    host_list = calloc(1, *count + 1);
    out = calloc(1, *count + 1);
    p.bufferCapacityInput = *count;
    p.buffer = host_list;
    if (device) UNIX_CALL(xrGetVulkanDeviceExtensionsKHR, &p);
    else UNIX_CALL(xrGetVulkanInstanceExtensionsKHR, &p);
    for (s = host_list; XR_SUCCEEDED(p.result) && *s;)
    {
        size_t len = strcspn(s, " ");
        if (!host_only_vk_extension(s, len))
        {
            if (n) out[n++] = ' ';
            memcpy(out + n, s, len);
            n += len;
        }
        s += len;
        s += strspn(s, " ");
    }
    free(host_list);
    if (XR_FAILED(p.result))
    {
        free(out);
        return p.result;
    }
    *count = (uint32_t)n + 1;
    if (capacity && capacity < *count) p.result = XR_ERROR_SIZE_INSUFFICIENT;
    else if (capacity) memcpy(buffer, out, n + 1);
    free(out);
    return p.result;
}

WINE_XR(XrResult) wine_xrGetVulkanInstanceExtensionsKHR(XrInstance instance, XrSystemId system, uint32_t capacity,
                                                         uint32_t *count, char *buffer)
{
    return filtered_vk_extensions(FALSE, instance, system, capacity, count, buffer);
}

WINE_XR(XrResult) wine_xrGetVulkanDeviceExtensionsKHR(XrInstance instance, XrSystemId system, uint32_t capacity,
                                                       uint32_t *count, char *buffer)
{
    return filtered_vk_extensions(TRUE, instance, system, capacity, count, buffer);
}

static XrResult suggested_device(XrInstance instance, XrSystemId system, VkInstance vk_instance, VkPhysicalDevice *out)
{
    PFN_vkEnumeratePhysicalDevices enumerate = NULL;
    VkPhysicalDevice devices[16];
    uint32_t n = ARRAY_SIZE(devices);
    HMODULE vulkan = LoadLibraryA("vulkan-1.dll");

    if (vulkan) enumerate = (PFN_vkEnumeratePhysicalDevices)GetProcAddress(vulkan, "vkEnumeratePhysicalDevices");
    if (!enumerate || enumerate(vk_instance, &n, devices) < 0) return XR_ERROR_RUNTIME_FAILURE;
    struct vk_suggested_device_params p = {instance, system, (uint64_t)(uintptr_t)vk_instance, n, (const uint64_t *)devices};
    UNIX_CALL(vk_suggested_device, &p);
    if (XR_SUCCEEDED(p.result)) *out = devices[p.index];
    return p.result;
}

WINE_XR(XrResult) wine_xrGetVulkanGraphicsDeviceKHR(XrInstance instance, XrSystemId system, VkInstance vk_instance,
                                                     VkPhysicalDevice *device)
{
    return suggested_device(instance, system, vk_instance, device);
}

WINE_XR(XrResult) wine_xrGetVulkanGraphicsDevice2KHR(XrInstance instance, const XrVulkanGraphicsDeviceGetInfoKHR *info,
                                                      VkPhysicalDevice *device)
{
    return suggested_device(instance, info->systemId, info->vulkanInstance, device);
}

/* Returns the app's names plus the runtime's, without duplicates; free() the result. */
static const char **merge_names(const char *const *app, uint32_t app_count, char *runtime, uint32_t *count)
{
    const char **names = calloc(app_count + strlen(runtime) / 2 + 2, sizeof(*names));
    uint32_t n = 0;
    for (uint32_t i = 0; i < app_count; i++) names[n++] = app[i];
    for (char *s = strtok(runtime, " "); s; s = strtok(NULL, " "))
    {
        uint32_t i;
        for (i = 0; i < n && strcmp(names[i], s); i++) {}
        if (i == n) names[n++] = s;
    }
    *count = n;
    return names;
}

WINE_XR(XrResult) wine_xrCreateVulkanInstanceKHR(XrInstance instance, const XrVulkanInstanceCreateInfoKHR *info,
                                                  VkInstance *vk_instance, VkResult *vk_result)
{
    VkInstanceCreateInfo ci = *info->vulkanCreateInfo;
    char exts[4096];
    uint32_t len;
    XrResult r = filtered_vk_extensions(FALSE, instance, info->systemId, sizeof(exts), &len, exts);
    if (XR_FAILED(r)) return r;
    PFN_vkCreateInstance create = (PFN_vkCreateInstance)info->pfnGetInstanceProcAddr(NULL, "vkCreateInstance");
    const char **names = merge_names(ci.ppEnabledExtensionNames, ci.enabledExtensionCount, exts, &ci.enabledExtensionCount);
    ci.ppEnabledExtensionNames = names;
    *vk_result = create(&ci, info->vulkanAllocator, vk_instance);
    free(names);
    if (*vk_result == VK_SUCCESS)
    {
        inst.vk_gipa = info->pfnGetInstanceProcAddr;
        inst.vk_instance = *vk_instance;
    }
    return XR_SUCCESS;
}

WINE_XR(XrResult) wine_xrCreateVulkanDeviceKHR(XrInstance instance, const XrVulkanDeviceCreateInfoKHR *info,
                                                VkDevice *vk_device, VkResult *vk_result)
{
    VkDeviceCreateInfo ci = *info->vulkanCreateInfo;
    VkPhysicalDeviceTimelineSemaphoreFeatures timeline = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES};
    VkBaseOutStructure *s;
    VkBool32 *flag = NULL, old = VK_FALSE;
    char exts[4096];
    uint32_t len;
    XrResult r = filtered_vk_extensions(TRUE, instance, info->systemId, sizeof(exts), &len, exts);
    if (XR_FAILED(r)) return r;
    if (!inst.vk_instance) return XR_ERROR_CALL_ORDER_INVALID;
    PFN_vkCreateDevice create = (PFN_vkCreateDevice)info->pfnGetInstanceProcAddr(inst.vk_instance, "vkCreateDevice");
    const char **names = merge_names(ci.ppEnabledExtensionNames, ci.enabledExtensionCount, exts, &ci.enabledExtensionCount);
    ci.ppEnabledExtensionNames = names;

    /* Monado's client compositor syncs with the service through a timeline semaphore. */
    for (s = (VkBaseOutStructure *)ci.pNext; s && !flag; s = s->pNext)
        if (s->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES)
            flag = &((VkPhysicalDeviceVulkan12Features *)s)->timelineSemaphore;
        else if (s->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES)
            flag = &((VkPhysicalDeviceTimelineSemaphoreFeatures *)s)->timelineSemaphore;
    if (flag)
    {
        old = *flag;
        *flag = VK_TRUE;
    }
    else
    {
        timeline.pNext = (void *)ci.pNext;
        timeline.timelineSemaphore = VK_TRUE;
        ci.pNext = &timeline;
    }
    *vk_result = create(info->vulkanPhysicalDevice, &ci, info->vulkanAllocator, vk_device);
    if (flag) *flag = old;
    free(names);
    return XR_SUCCESS;
}

/*
 * DXMT (CX_GRAPHICS_BACKEND=dxmt)
 *
 * Stock DXMT turns D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX textures into MTLSharedTextures and registers their Mach port
 * in the bootstrap namespace under a name it keeps in the D3DKMT resource's private runtime data; the keyed mutex's
 * MTLSharedEvent port is published the same way. The bridge reads both names through gdi32's D3DKMT calls (what
 * DXMT's own OpenSharedResource does) and the unix side imports them into its Vulkan device.
 */

static struct
{
    NTSTATUS(WINAPI *OpenAdapterFromLuid)(D3DKMT_OPENADAPTERFROMLUID *);
    NTSTATUS(WINAPI *CloseAdapter)(const D3DKMT_CLOSEADAPTER *);
    NTSTATUS(WINAPI *CreateDevice)(D3DKMT_CREATEDEVICE *);
    NTSTATUS(WINAPI *DestroyDevice)(const D3DKMT_DESTROYDEVICE *);
    NTSTATUS(WINAPI *QueryResourceInfo)(D3DKMT_QUERYRESOURCEINFO *);
    NTSTATUS(WINAPI *OpenResource2)(D3DKMT_OPENRESOURCE *);
    NTSTATUS(WINAPI *DestroyAllocation)(const D3DKMT_DESTROYALLOCATION *);
    NTSTATUS(WINAPI *OpenKeyedMutex2)(D3DKMT_OPENKEYEDMUTEX2 *);
    NTSTATUS(WINAPI *DestroyKeyedMutex)(const D3DKMT_DESTROYKEYEDMUTEX *);
    NTSTATUS(WINAPI *AcquireKeyedMutex)(D3DKMT_ACQUIREKEYEDMUTEX *);
    NTSTATUS(WINAPI *ReleaseKeyedMutex)(D3DKMT_RELEASEKEYEDMUTEX *);
} kmt;

static BOOL load_kmt(void)
{
    HMODULE gdi = LoadLibraryA("gdi32.dll");
#define K(n) if (!gdi || !(*(FARPROC *)&kmt.n = GetProcAddress(gdi, "D3DKMT" #n))) return FALSE;
    K(OpenAdapterFromLuid) K(CloseAdapter) K(CreateDevice) K(DestroyDevice) K(QueryResourceInfo) K(OpenResource2)
    K(DestroyAllocation) K(OpenKeyedMutex2) K(DestroyKeyedMutex) K(AcquireKeyedMutex) K(ReleaseKeyedMutex)
#undef K
    return TRUE;
}

static D3DKMT_HANDLE kmt_device_for(ID3D11Device *device)
{
    IDXGIDevice *dxgi = NULL;
    IDXGIAdapter *adapter = NULL;
    DXGI_ADAPTER_DESC desc;
    D3DKMT_OPENADAPTERFROMLUID open = {0};
    D3DKMT_CREATEDEVICE create = {0};
    HRESULT hr = ID3D11Device_QueryInterface(device, &IID_IDXGIDevice, (void **)&dxgi);
    if (SUCCEEDED(hr)) hr = IDXGIDevice_GetAdapter(dxgi, &adapter);
    if (SUCCEEDED(hr)) hr = IDXGIAdapter_GetDesc(adapter, &desc);
    if (adapter) IDXGIAdapter_Release(adapter);
    if (dxgi) IDXGIDevice_Release(dxgi);
    if (FAILED(hr)) return 0;
    open.AdapterLuid = desc.AdapterLuid;
    if (kmt.OpenAdapterFromLuid(&open)) return 0;
    create.hAdapter = open.hAdapter;
    NTSTATUS st = kmt.CreateDevice(&create);
    D3DKMT_CLOSEADAPTER close = {open.hAdapter};
    kmt.CloseAdapter(&close);
    return st ? 0 : create.hDevice;
}

/* Bootstrap names of a DXMT shared texture and of its keyed mutex's event; opens our own handle to the mutex. */
static HRESULT dxmt_shared_names(struct session *s, ID3D11Texture2D *texture, char *name, char *event_name,
                                 D3DKMT_HANDLE *mutex)
{
    struct dxmt_shared_resource_data data = {0};
    const UINT old_size = offsetof(struct dxmt_shared_resource_data, mutex_handle);
    D3DDDI_OPENALLOCATIONINFO2 alloc = {0};
    D3DKMT_QUERYRESOURCEINFO query = {s->kmt_device};
    D3DKMT_OPENRESOURCE open = {s->kmt_device};
    IDXGIResource *res;
    HANDLE share = NULL;
    HRESULT hr = ID3D11Texture2D_QueryInterface(texture, &IID_IDXGIResource, (void **)&res);

    if (SUCCEEDED(hr))
    {
        hr = IDXGIResource_GetSharedHandle(res, &share);
        IDXGIResource_Release(res);
    }
    if (FAILED(hr) || !share) return E_FAIL;
    query.hGlobalShare = (D3DKMT_HANDLE)(UINT_PTR)share;
    query.pPrivateRuntimeData = &data;
    query.PrivateRuntimeDataSize = sizeof(data);
    /* DXMT before keyed mutex support (CrossOver 26) ends the data before mutex_handle. */
    if (kmt.QueryResourceInfo(&query)
        || (query.PrivateRuntimeDataSize != sizeof(data) && query.PrivateRuntimeDataSize != old_size))
    {
        ERR("D3DKMTQueryResourceInfo: no DXMT runtime data (size %u, want %u)", query.PrivateRuntimeDataSize,
            (unsigned)sizeof(data));
        return E_FAIL;
    }
    open.hGlobalShare = query.hGlobalShare;
    open.NumAllocations = 1;
    open.pOpenAllocationInfo2 = &alloc;
    open.pPrivateRuntimeData = &data;
    open.PrivateRuntimeDataSize = query.PrivateRuntimeDataSize;
    if (kmt.OpenResource2(&open)) return E_FAIL;
    if (query.PrivateRuntimeDataSize == old_size) data.mutex_handle = 0;
    D3DKMT_DESTROYALLOCATION destroy = {s->kmt_device, open.hResource};
    kmt.DestroyAllocation(&destroy);
    data.mach_port_name[sizeof(data.mach_port_name) - 1] = 0;
    if (strncmp(data.mach_port_name, "DXMT_", 5))
    {
        ERR("unexpected shared resource name '%s'", data.mach_port_name);
        return E_FAIL;
    }
    strcpy(name, data.mach_port_name);
    event_name[0] = 0;
    *mutex = 0;
    if (data.mutex_handle)
    {
        char buf[54] = {0};
        D3DKMT_OPENKEYEDMUTEX2 om = {data.mutex_handle, 0, buf, sizeof(buf)};
        if (kmt.OpenKeyedMutex2(&om) || strncmp(buf, "DXMT_", 5))
        {
            ERR("D3DKMTOpenKeyedMutex2 failed");
            return E_FAIL;
        }
        buf[sizeof(buf) - 1] = 0;
        strcpy(event_name, buf);
        *mutex = om.hKeyedMutex;
    }
    return S_OK;
}

static HRESULT dxmt_create_texture(struct session *s, const D3D11_TEXTURE2D_DESC1 *desc1, ID3D11Texture2D **out)
{
    D3D11_TEXTURE2D_DESC desc;
    memcpy(&desc, desc1, sizeof(desc));
    desc.MiscFlags |= s->cpu_sync ? D3D11_RESOURCE_MISC_SHARED : D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX;
    return ID3D11Device_CreateTexture2D(s->d3d11, &desc, NULL, out);
}

/* Does the device share textures the DXMT way? */
static BOOL dxmt_probe(struct session *s)
{
    D3D11_TEXTURE2D_DESC1 desc = {16, 16, 1, 1, DXGI_FORMAT_R8G8B8A8_UNORM, {1, 0}, D3D11_USAGE_DEFAULT,
                                  D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE};
    ID3D11Texture2D *tex;
    char name[64], event_name[64];
    D3DKMT_HANDLE mutex = 0;
    BOOL ok;

    if (!load_kmt() || (!s->kmt_device && !(s->kmt_device = kmt_device_for(s->d3d11)))) return FALSE;
    if (FAILED(dxmt_create_texture(s, &desc, &tex))) return FALSE;
    ok = SUCCEEDED(dxmt_shared_names(s, tex, name, event_name, &mutex)) && (s->cpu_sync || event_name[0]);
    if (mutex)
    {
        D3DKMT_DESTROYKEYEDMUTEX d = {mutex};
        kmt.DestroyKeyedMutex(&d);
    }
    ID3D11Texture2D_Release(tex);
    return ok;
}

static void dxmt_create_fence(struct session *s)
{
    ID3D11Device5 *dev5;

    if (FAILED(ID3D11Device_QueryInterface(s->d3d11, &IID_ID3D11Device5, (void **)&dev5))) return;
    if (SUCCEEDED(ID3D11Device5_CreateFence(dev5, 0, D3D11_FENCE_FLAG_NONE, &IID_ID3D11Fence, (void **)&s->fence))
        && SUCCEEDED(ID3D11DeviceContext_QueryInterface(s->context, &IID_ID3D11DeviceContext4, (void **)&s->context4))
        && (s->fence_event = CreateEventW(NULL, FALSE, FALSE, NULL)))
    {
        ID3D11Device5_Release(dev5);
        return;
    }
    ID3D11Device5_Release(dev5);
    ERR("no D3D11 fence, CPU sync on the game thread");
    if (s->fence) ID3D11Fence_Release(s->fence);
    if (s->context4) ID3D11DeviceContext4_Release(s->context4);
    s->fence = NULL;
    s->context4 = NULL;
}

static XrResult dxmt_session_binding(XrInstance instance, XrSystemId system, struct session *s, XrGraphicsBindingVulkanKHR *vk)
{
    struct dxmt_create_device_params p = {instance, system};
    const char *sync = getenv("WINEOPENXR_DXMT_SYNC");
    BOOL ok;

    s->cpu_sync = sync && (!strcmp(sync, "cpu") || !strcmp(sync, "fence"));
    if (!(ok = dxmt_probe(s)) && !s->cpu_sync)
    {
        s->cpu_sync = TRUE;
        if ((ok = dxmt_probe(s))) ERR("DXMT without keyed mutex: fence sync");
        sync = "fence";
    }
    if (ok && sync && !strcmp(sync, "fence")) dxmt_create_fence(s);
    if (!ok)
    {
        struct unsupported_device_params q = {0};
        ERR("the D3D11 device is neither DXVK nor DXMT (CX_GRAPHICS_BACKEND=dxvk or dxmt)");
        UNIX_CALL(unsupported_device, &q);
        if (!q.run_anyway) TerminateProcess(GetCurrentProcess(), 0);
        return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    }
    UNIX_CALL(dxmt_create_device, &p);
    if (XR_FAILED(p.result))
    {
        ERR("DXMT session: %s", p.info);
        return p.result;
    }
    if (getenv("WINEOPENXR_DEBUG"))
        ERR("DXMT session (%s sync): %s", s->fence ? "fence" : s->cpu_sync ? "CPU" : "keyed mutex", p.info);
    InitializeCriticalSection(&s->queue_lock);
    s->dxmt_ctx = p.ctx;
    vk->instance = (VkInstance)(UINT_PTR)p.vk_instance;
    vk->physicalDevice = (VkPhysicalDevice)(UINT_PTR)p.vk_physical_device;
    vk->device = (VkDevice)(UINT_PTR)p.vk_device;
    vk->queueFamilyIndex = p.queue_family;
    vk->queueIndex = p.queue_index;
    return XR_SUCCESS;
}

static void dxmt_session_free(struct session *s)
{
    if (s->fence) ID3D11Fence_Release(s->fence);
    if (s->context4) ID3D11DeviceContext4_Release(s->context4);
    if (s->fence_event) CloseHandle(s->fence_event);
    s->fence = NULL;
    s->context4 = NULL;
    s->fence_event = NULL;
    if (s->dxmt_ctx)
    {
        struct dxmt_destroy_device_params p = {s->dxmt_ctx};
        UNIX_CALL(dxmt_destroy_device, &p);
        DeleteCriticalSection(&s->queue_lock);
        s->dxmt_ctx = 0;
    }
    if (s->kmt_device)
    {
        D3DKMT_DESTROYDEVICE d = {s->kmt_device};
        kmt.DestroyDevice(&d);
        s->kmt_device = 0;
    }
}

/*
 * Sessions
 */

WINE_XR(XrResult) wine_xrGetD3D11GraphicsRequirementsKHR(XrInstance instance, XrSystemId system,
                                                          XrGraphicsRequirementsD3D11KHR *req)
{
    XrGraphicsRequirementsVulkanKHR vk_req = {XR_TYPE_GRAPHICS_REQUIREMENTS_VULKAN_KHR};
    struct xrGetVulkanGraphicsRequirementsKHR_params p = {instance, system, &vk_req};
    IDXGIFactory1 *factory;
    IDXGIAdapter1 *adapter;
    DXGI_ADAPTER_DESC1 desc;

    if (!req || req->type != XR_TYPE_GRAPHICS_REQUIREMENTS_D3D11_KHR) return XR_ERROR_VALIDATION_FAILURE;
    UNIX_CALL(xrGetVulkanGraphicsRequirementsKHR, &p);
    if (XR_FAILED(p.result)) return p.result;
    /* One GPU: DXGI's first adapter is the one DXVK uses. */
    if (FAILED(CreateDXGIFactory1(&IID_IDXGIFactory1, (void **)&factory))) return XR_ERROR_RUNTIME_FAILURE;
    HRESULT hr = IDXGIFactory1_EnumAdapters1(factory, 0, &adapter);
    if (SUCCEEDED(hr))
    {
        hr = IDXGIAdapter1_GetDesc1(adapter, &desc);
        IDXGIAdapter1_Release(adapter);
    }
    IDXGIFactory1_Release(factory);
    if (FAILED(hr)) return XR_ERROR_RUNTIME_FAILURE;
    req->adapterLuid = desc.AdapterLuid;
    req->minFeatureLevel = D3D_FEATURE_LEVEL_11_0;
    return XR_SUCCESS;
}

WINE_XR(XrResult) wine_xrCreateSession(XrInstance instance, const XrSessionCreateInfo *info, XrSession *handle)
{
    XrSessionCreateInfo ci = *info;
    XrGraphicsBindingVulkanKHR vk = {XR_TYPE_GRAPHICS_BINDING_VULKAN_KHR};
    XrBaseInStructure *prev = NULL, *b;
    struct session *s = calloc(1, sizeof(*s));

    for (b = (XrBaseInStructure *)info->next; b; prev = b, b = (XrBaseInStructure *)b->next)
        if (b->type == XR_TYPE_GRAPHICS_BINDING_VULKAN_KHR || b->type == XR_TYPE_GRAPHICS_BINDING_D3D11_KHR) break;

    if (b && b->type == XR_TYPE_GRAPHICS_BINDING_D3D11_KHR)
    {
        const XrGraphicsBindingD3D11KHR *d3d = (const XrGraphicsBindingD3D11KHR *)b;
        uint32_t index, family;
        VkQueue queue;
        if (!inst.d3d11 || !d3d->device)
        {
            free(s);
            return XR_ERROR_GRAPHICS_DEVICE_INVALID;
        }
        s->d3d11 = d3d->device;
        ID3D11Device_AddRef(s->d3d11);
        ID3D11Device_GetImmediateContext(s->d3d11, &s->context);
        if (SUCCEEDED(ID3D11Device_QueryInterface(d3d->device, &IID_IDXGIVkInteropDevice1, (void **)&s->interop)))
        {
            s->interop->lpVtbl->GetVulkanHandles(s->interop, &vk.instance, &vk.physicalDevice, &vk.device);
            s->interop->lpVtbl->GetSubmissionQueue1(s->interop, &queue, &index, &family);
            vk.queueFamilyIndex = family;
            vk.queueIndex = index;
        }
        else
        {
            XrResult r = dxmt_session_binding(instance, info->systemId, s, &vk);
            if (XR_FAILED(r))
            {
                dxmt_session_free(s);
                ID3D11DeviceContext_Release(s->context);
                ID3D11Device_Release(s->d3d11);
                free(s);
                return r;
            }
        }
    }
    else if (b)
        vk = *(const XrGraphicsBindingVulkanKHR *)b;

    if (b)
    {
        vk.next = b->next;
        if (prev) prev->next = (const XrBaseInStructure *)&vk;
        else ci.next = &vk;
    }
    struct create_session_params p = {instance, &ci, b ? &vk : NULL, s->dxmt_ctx != 0, handle};
    d3d11_lock(s, FALSE);
    UNIX_CALL(create_session, &p);
    d3d11_unlock(s);
    if (prev) prev->next = b;

    if (XR_FAILED(p.result))
    {
        dxmt_session_free(s);
        if (s->interop) s->interop->lpVtbl->Release(s->interop);
        if (s->context) ID3D11DeviceContext_Release(s->context);
        if (s->d3d11) ID3D11Device_Release(s->d3d11);
        free(s);
        return p.result;
    }
    s->handle = *handle;
    if (s->dxmt_ctx) start_worker(s);
    EnterCriticalSection(&lock);
    s->next = sessions;
    sessions = s;
    LeaveCriticalSection(&lock);
    return XR_SUCCESS;
}

WINE_XR(XrResult) wine_xrDestroySession(XrSession handle)
{
    struct xrDestroySession_params p = {handle};
    struct session *s = get_session(handle), **ps;
    struct swapchain *sc;

    if (s) stop_worker(s);
    /* Swapchains the app left behind go first; ours hold the session. */
    while (s)
    {
        EnterCriticalSection(&lock);
        for (sc = swapchains; sc && sc->session != s; sc = sc->next) {}
        LeaveCriticalSection(&lock);
        if (!sc) break;
        wine_xrDestroySwapchain(sc->handle);
    }
    d3d11_lock(s, TRUE);
    UNIX_CALL(xrDestroySession, &p);
    d3d11_unlock(s);
    if (XR_FAILED(p.result) || !s) return p.result;
    EnterCriticalSection(&lock);
    for (ps = &sessions; *ps != s; ps = &(*ps)->next) {}
    *ps = s->next;
    LeaveCriticalSection(&lock);
    dxmt_session_free(s);
    if (s->interop) s->interop->lpVtbl->Release(s->interop);
    if (s->context) ID3D11DeviceContext_Release(s->context);
    if (s->d3d11) ID3D11Device_Release(s->d3d11);
    free(s);
    return XR_SUCCESS;
}

/*
 * Swapchains
 *
 * D3D11 sessions get three kinds:
 * - host: the runtime's IOSurface images wrapped as D3D11 textures (zero copy);
 * - split: arraySize > 1, which IOSurfaces can't back. The app renders into DXVK array textures; release copies each
 *   slice into its own host swapchain, and xrEndFrame points the layers at those;
 * - local: depth/stencil, which the runtime doesn't offer. Bridge-owned textures; depth layers are dropped at
 *   xrEndFrame, as nothing downstream reprojects with depth.
 */

static const struct
{
    DXGI_FORMAT dxgi;
    VkFormat vk;
} formats[] = {
    {DXGI_FORMAT_R8G8B8A8_UNORM, VK_FORMAT_R8G8B8A8_UNORM},
    {DXGI_FORMAT_R8G8B8A8_UNORM_SRGB, VK_FORMAT_R8G8B8A8_SRGB},
    {DXGI_FORMAT_B8G8R8A8_UNORM, VK_FORMAT_B8G8R8A8_UNORM},
    {DXGI_FORMAT_B8G8R8A8_UNORM_SRGB, VK_FORMAT_B8G8R8A8_SRGB},
    {DXGI_FORMAT_R16G16B16A16_FLOAT, VK_FORMAT_R16G16B16A16_SFLOAT},
    {DXGI_FORMAT_R16G16B16A16_UNORM, VK_FORMAT_R16G16B16A16_UNORM},
    {DXGI_FORMAT_R10G10B10A2_UNORM, VK_FORMAT_A2B10G10R10_UNORM_PACK32},
    {DXGI_FORMAT_R32_FLOAT, VK_FORMAT_R32_SFLOAT},
    {DXGI_FORMAT_B5G6R5_UNORM, VK_FORMAT_R5G6B5_UNORM_PACK16},
};

static const DXGI_FORMAT depth_formats[] = {DXGI_FORMAT_D32_FLOAT, DXGI_FORMAT_D16_UNORM, DXGI_FORMAT_D24_UNORM_S8_UINT,
                                           DXGI_FORMAT_D32_FLOAT_S8X24_UINT};

static DXGI_FORMAT vk_to_dxgi(int64_t vk)
{
    for (unsigned int i = 0; i < ARRAY_SIZE(formats); i++)
        if (formats[i].vk == vk) return formats[i].dxgi;
    return DXGI_FORMAT_UNKNOWN;
}

static VkFormat dxgi_to_vk(int64_t dxgi)
{
    for (unsigned int i = 0; i < ARRAY_SIZE(formats); i++)
        if (formats[i].dxgi == dxgi) return formats[i].vk;
    return VK_FORMAT_UNDEFINED;
}

static BOOL is_depth_format(int64_t dxgi)
{
    for (unsigned int i = 0; i < ARRAY_SIZE(depth_formats); i++)
        if (depth_formats[i] == dxgi) return TRUE;
    return FALSE;
}

WINE_XR(XrResult) wine_xrEnumerateSwapchainFormats(XrSession session, uint32_t capacity, uint32_t *count, int64_t *out)
{
    struct xrEnumerateSwapchainFormats_params p = {session, capacity, count, out};
    struct session *s = get_session(session);
    int64_t host[64 + ARRAY_SIZE(depth_formats)];
    uint32_t n = 0;

    if (!s || !s->d3d11)
    {
        UNIX_CALL(xrEnumerateSwapchainFormats, &p);
        return p.result;
    }
    p.formatCapacityInput = 64;
    p.formats = host;
    UNIX_CALL(xrEnumerateSwapchainFormats, &p);
    if (XR_FAILED(p.result)) return p.result;
    for (uint32_t i = 0; i < *count; i++)
    {
        DXGI_FORMAT f = vk_to_dxgi(host[i]);
        if (f != DXGI_FORMAT_UNKNOWN) host[n++] = f;
    }
    for (unsigned int i = 0; i < ARRAY_SIZE(depth_formats); i++) host[n++] = depth_formats[i];
    *count = n;
    if (!capacity) return XR_SUCCESS;
    if (capacity < n) return XR_ERROR_SIZE_INSUFFICIENT;
    memcpy(out, host, n * sizeof(*out));
    return XR_SUCCESS;
}

static D3D11_TEXTURE2D_DESC1 texture_desc(const XrSwapchainCreateInfo *info)
{
    D3D11_TEXTURE2D_DESC1 desc = {0};
    desc.Width = info->width;
    desc.Height = info->height;
    desc.MipLevels = info->mipCount;
    desc.ArraySize = info->arraySize * info->faceCount;
    desc.Format = (DXGI_FORMAT)info->format;
    desc.SampleDesc.Count = info->sampleCount;
    desc.Usage = D3D11_USAGE_DEFAULT;
    if (info->usageFlags & XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT) desc.BindFlags |= D3D11_BIND_RENDER_TARGET;
    if (info->usageFlags & XR_SWAPCHAIN_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT) desc.BindFlags |= D3D11_BIND_DEPTH_STENCIL;
    if (info->usageFlags & XR_SWAPCHAIN_USAGE_SAMPLED_BIT) desc.BindFlags |= D3D11_BIND_SHADER_RESOURCE;
    if (info->usageFlags & XR_SWAPCHAIN_USAGE_UNORDERED_ACCESS_BIT) desc.BindFlags |= D3D11_BIND_UNORDERED_ACCESS;
    if (info->faceCount == 6) desc.MiscFlags |= D3D11_RESOURCE_MISC_TEXTURECUBE;
    return desc;
}

/* Creates one host swapchain and wraps its images. */
static XrResult create_host_swapchain(struct session *s, const XrSwapchainCreateInfo *info, XrSwapchain *handle,
                                      uint32_t *count, ID3D11Texture2D **textures)
{
    XrSwapchainCreateInfo ci = *info;
    struct xrCreateSwapchain_params p = {s->handle, &ci, handle};
    XrSwapchainImageVulkanKHR images[MAX_IMAGES];
    D3D11_TEXTURE2D_DESC1 desc = texture_desc(info);

    ci.format = dxgi_to_vk(info->format);
    d3d11_lock(s, FALSE);
    UNIX_CALL(xrCreateSwapchain, &p);
    d3d11_unlock(s);
    if (XR_FAILED(p.result)) return p.result;

    for (uint32_t i = 0; i < MAX_IMAGES; i++) images[i] = (XrSwapchainImageVulkanKHR){XR_TYPE_SWAPCHAIN_IMAGE_VULKAN_KHR};
    struct xrEnumerateSwapchainImages_params e = {*handle, MAX_IMAGES, count, (XrSwapchainImageBaseHeader *)images};
    UNIX_CALL(xrEnumerateSwapchainImages, &e);
    for (uint32_t i = 0; XR_SUCCEEDED(e.result) && i < *count; i++)
    {
        HRESULT hr = s->interop->lpVtbl->CreateTexture2DFromVkImage(s->interop, &desc, images[i].image, &textures[i]);
        if (FAILED(hr))
        {
            ERR("CreateTexture2DFromVkImage failed: %#lx", hr);
            e.result = XR_ERROR_RUNTIME_FAILURE;
        }
    }
    return e.result;
}

static void destroy_swapchain(struct swapchain *sc)
{
    flush_copy(sc, NULL, NULL);
    d3d11_lock(sc->session, FALSE);
    for (uint32_t i = 0; i < MAX_IMAGES; i++)
    {
        struct dxmt_destroy_image_params d = {sc->session->dxmt_ctx, sc->dxmt_images[i]};
        D3DKMT_DESTROYKEYEDMUTEX dm = {sc->kmt_mutex[i]};
        if (sc->dxmt_images[i]) UNIX_CALL(dxmt_destroy_image, &d);
        if (sc->kmt_mutex[i]) kmt.DestroyKeyedMutex(&dm);
        if (sc->keyed[i]) IDXGIKeyedMutex_Release(sc->keyed[i]);
    }
    d3d11_unlock(sc->session);
    if (sc->query) ID3D11Query_Release(sc->query);
    for (uint32_t i = 0; i < sc->image_count; i++)
    {
        if (sc->textures[i]) ID3D11Texture2D_Release(sc->textures[i]);
        for (uint32_t s = 0; s < sc->slices; s++)
            if (sc->host_textures[s][i]) ID3D11Texture2D_Release(sc->host_textures[s][i]);
    }
    d3d11_lock(sc->session, TRUE);
    for (uint32_t s = 0; s < sc->slices; s++)
    {
        struct xrDestroySwapchain_params p = {sc->hosts[s]};
        if (sc->hosts[s]) UNIX_CALL(xrDestroySwapchain, &p);
    }
    d3d11_unlock(sc->session);
    free(sc);
}

/* DXMT: one host swapchain per slice (Vulkan images on the bridge's device) and one DXMT shared texture per image,
 * imported on the unix side. */
static XrResult create_copy_swapchain(struct session *s, const XrSwapchainCreateInfo *info, struct swapchain *sc)
{
    XrSwapchainCreateInfo slice = *info;
    D3D11_TEXTURE2D_DESC1 desc = texture_desc(info);
    XrResult r = XR_SUCCESS;

    slice.arraySize = 1;
    slice.format = dxgi_to_vk(info->format);
    slice.usageFlags |= XR_SWAPCHAIN_USAGE_TRANSFER_DST_BIT;
    sc->kind = SWAPCHAIN_COPY;
    sc->slices = info->arraySize;
    for (uint32_t i = 0; i < sc->slices && XR_SUCCEEDED(r); i++)
    {
        struct xrCreateSwapchain_params p = {s->handle, &slice, &sc->hosts[i]};
        XrSwapchainImageVulkanKHR images[MAX_IMAGES];
        uint32_t n = 0;
        d3d11_lock(s, FALSE);
        UNIX_CALL(xrCreateSwapchain, &p);
        d3d11_unlock(s);
        if (XR_FAILED(r = p.result)) break;
        for (uint32_t j = 0; j < MAX_IMAGES; j++) images[j] = (XrSwapchainImageVulkanKHR){XR_TYPE_SWAPCHAIN_IMAGE_VULKAN_KHR};
        struct xrEnumerateSwapchainImages_params e = {sc->hosts[i], MAX_IMAGES, &n, (XrSwapchainImageBaseHeader *)images};
        UNIX_CALL(xrEnumerateSwapchainImages, &e);
        if (XR_FAILED(r = e.result)) break;
        if (i && n != sc->image_count) r = XR_ERROR_RUNTIME_FAILURE;
        sc->image_count = n;
        for (uint32_t j = 0; j < n; j++) sc->host_images[i][j] = (uint64_t)(UINT_PTR)images[j].image;
    }
    for (uint32_t i = 0; i < sc->image_count && XR_SUCCEEDED(r); i++)
    {
        struct dxmt_import_image_params p = {s->dxmt_ctx};
        HRESULT hr = dxmt_create_texture(s, &desc, &sc->textures[i]);
        if (SUCCEEDED(hr)) hr = dxmt_shared_names(s, sc->textures[i], p.texture_name, p.event_name, &sc->kmt_mutex[i]);
        if (SUCCEEDED(hr) && !s->cpu_sync)
            hr = ID3D11Texture2D_QueryInterface(sc->textures[i], &IID_IDXGIKeyedMutex, (void **)&sc->keyed[i]);
        if (FAILED(hr))
        {
            ERR("DXMT shared texture %ux%u format %d: %#lx", info->width, info->height, (int)info->format, hr);
            r = XR_ERROR_RUNTIME_FAILURE;
            break;
        }
        if (s->cpu_sync) p.event_name[0] = 0;
        p.vk_format = slice.format;
        p.width = info->width;
        p.height = info->height;
        p.layers = info->arraySize;
        p.mips = info->mipCount;
        UNIX_CALL(dxmt_import_image, &p);
        if (XR_FAILED(r = p.result))
        {
            ERR("DXMT import: %s", p.info);
            break;
        }
        sc->dxmt_images[i] = p.image;
    }
    if (XR_SUCCEEDED(r) && s->cpu_sync)
    {
        D3D11_QUERY_DESC qd = {D3D11_QUERY_EVENT, 0};
        if (FAILED(ID3D11Device_CreateQuery(s->d3d11, &qd, &sc->query))) r = XR_ERROR_RUNTIME_FAILURE;
    }
    return r;
}

WINE_XR(XrResult) wine_xrCreateSwapchain(XrSession session, const XrSwapchainCreateInfo *info, XrSwapchain *handle)
{
    struct session *s = get_session(session);
    struct xrCreateSwapchain_params p = {session, info, handle};
    struct swapchain *sc;
    XrResult r = XR_SUCCESS;

    if (!s || !s->d3d11)
    {
        UNIX_CALL(xrCreateSwapchain, &p);
        return p.result;
    }
    if (dxgi_to_vk(info->format) == VK_FORMAT_UNDEFINED && !is_depth_format(info->format))
        return XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED;
    if (info->arraySize > MAX_SLICES || info->faceCount != 1) return XR_ERROR_FEATURE_UNSUPPORTED;

    sc = calloc(1, sizeof(*sc));
    sc->session = s;
    if (is_depth_format(info->format))
    {
        D3D11_TEXTURE2D_DESC1 desc1 = texture_desc(info);
        D3D11_TEXTURE2D_DESC desc;
        memcpy(&desc, &desc1, sizeof(desc));
        sc->kind = SWAPCHAIN_LOCAL;
        sc->image_count = 3;
        for (uint32_t i = 0; i < sc->image_count && SUCCEEDED(ID3D11Device_CreateTexture2D(s->d3d11, &desc, NULL, &sc->textures[i])); i++) {}
        if (!sc->textures[sc->image_count - 1]) r = XR_ERROR_RUNTIME_FAILURE;
        *handle = (XrSwapchain)sc;
    }
    else if (s->dxmt_ctx)
    {
        r = create_copy_swapchain(s, info, sc);
        *handle = sc->hosts[0];
    }
    else if (info->arraySize > 1)
    {
        XrSwapchainCreateInfo slice = *info;
        D3D11_TEXTURE2D_DESC1 desc1 = texture_desc(info);
        D3D11_TEXTURE2D_DESC desc;
        memcpy(&desc, &desc1, sizeof(desc));
        slice.arraySize = 1;
        sc->kind = SWAPCHAIN_SPLIT;
        sc->slices = info->arraySize;
        for (uint32_t i = 0; i < sc->slices && XR_SUCCEEDED(r); i++)
        {
            uint32_t n;
            r = create_host_swapchain(s, &slice, &sc->hosts[i], &n, sc->host_textures[i]);
            if (XR_SUCCEEDED(r) && i && n != sc->image_count) r = XR_ERROR_RUNTIME_FAILURE;
            sc->image_count = n;
        }
        for (uint32_t i = 0; i < sc->image_count && XR_SUCCEEDED(r); i++)
            if (FAILED(ID3D11Device_CreateTexture2D(s->d3d11, &desc, NULL, &sc->textures[i]))) r = XR_ERROR_RUNTIME_FAILURE;
        *handle = sc->hosts[0];
    }
    else
    {
        sc->kind = SWAPCHAIN_HOST;
        sc->slices = 1;
        r = create_host_swapchain(s, info, &sc->hosts[0], &sc->image_count, sc->textures);
        *handle = sc->hosts[0];
    }
    if (XR_FAILED(r))
    {
        destroy_swapchain(sc);
        *handle = XR_NULL_HANDLE;
        return r;
    }
    sc->handle = *handle;
    EnterCriticalSection(&lock);
    sc->next = swapchains;
    swapchains = sc;
    LeaveCriticalSection(&lock);
    return XR_SUCCESS;
}

WINE_XR(XrResult) wine_xrDestroySwapchain(XrSwapchain handle)
{
    struct xrDestroySwapchain_params p = {handle};
    struct swapchain *sc = get_swapchain(handle), **psc;

    if (!sc)
    {
        UNIX_CALL(xrDestroySwapchain, &p);
        return p.result;
    }
    drain(sc->session);
    EnterCriticalSection(&lock);
    for (psc = &swapchains; *psc != sc; psc = &(*psc)->next) {}
    *psc = sc->next;
    LeaveCriticalSection(&lock);
    destroy_swapchain(sc);
    return XR_SUCCESS;
}

WINE_XR(XrResult) wine_xrEnumerateSwapchainImages(XrSwapchain handle, uint32_t capacity, uint32_t *count,
                                                   XrSwapchainImageBaseHeader *images)
{
    struct xrEnumerateSwapchainImages_params p = {handle, capacity, count, images};
    struct swapchain *sc = get_swapchain(handle);

    if (!sc)
    {
        UNIX_CALL(xrEnumerateSwapchainImages, &p);
        return p.result;
    }
    *count = sc->image_count;
    if (!capacity) return XR_SUCCESS;
    if (capacity < sc->image_count) return XR_ERROR_SIZE_INSUFFICIENT;
    if (images->type != XR_TYPE_SWAPCHAIN_IMAGE_D3D11_KHR) return XR_ERROR_VALIDATION_FAILURE;
    for (uint32_t i = 0; i < sc->image_count; i++)
        ((XrSwapchainImageD3D11KHR *)images)[i].texture = sc->textures[i];
    return XR_SUCCESS;
}

WINE_XR(XrResult) wine_xrAcquireSwapchainImage(XrSwapchain handle, const XrSwapchainImageAcquireInfo *info, uint32_t *index)
{
    struct xrAcquireSwapchainImage_params p = {handle, info, index};
    struct swapchain *sc = get_swapchain(handle);
    LONGLONG t0 = now(), t1;
    uint32_t slot;

    if (!sc)
    {
        UNIX_CALL(xrAcquireSwapchainImage, &p);
        return p.result;
    }
    if (sc->acquired_count == MAX_IMAGES) return XR_ERROR_CALL_ORDER_INVALID;
    drain(sc->session);
    flush_copy(sc, NULL, &game_stats);
    slot = (sc->acquired_head + sc->acquired_count) % MAX_IMAGES;
    if (sc->kind == SWAPCHAIN_LOCAL)
    {
        *index = sc->acquired[slot][0] = sc->next_local;
        sc->next_local = (sc->next_local + 1) % sc->image_count;
        sc->acquired_count++;
        return XR_SUCCESS;
    }
    d3d11_lock(sc->session, FALSE);
    for (uint32_t s = 0; s < sc->slices && XR_SUCCEEDED(p.result); s++)
    {
        p.swapchain = sc->hosts[s];
        p.index = &sc->acquired[slot][s];
        UNIX_CALL(xrAcquireSwapchainImage, &p);
    }
    d3d11_unlock(sc->session);
    if (XR_FAILED(p.result)) return p.result;
    *index = sc->acquired[slot][0];
    sc->acquired_count++;
    /* The game's GPU work on this texture waits for our last copy out of it. Never blocks on the CPU: the copy's
     * D3DKMT release happened in flush_copy, which ran before (drain above). */
    t1 = now();
    if (sc->keyed[*index] && FAILED(IDXGIKeyedMutex_AcquireSync(sc->keyed[*index], 0, 1000)))
        ERR("keyed mutex AcquireSync failed");
    stat_add(&game_stats, S_ACQ_SYNC, now() - t1);
    stat_add(&game_stats, S_ACQUIRE, now() - t0);
    return XR_SUCCESS;
}

WINE_XR(XrResult) wine_xrWaitSwapchainImage(XrSwapchain handle, const XrSwapchainImageWaitInfo *info)
{
    struct xrWaitSwapchainImage_params p = {handle, info};
    struct swapchain *sc = get_swapchain(handle);
    LONGLONG t0 = now();

    if (sc && sc->kind == SWAPCHAIN_LOCAL) return XR_SUCCESS;
    for (uint32_t s = 0; s < (sc ? sc->slices : 1) && XR_SUCCEEDED(p.result); s++)
    {
        if (sc) p.swapchain = sc->hosts[s];
        UNIX_CALL(xrWaitSwapchainImage, &p);
    }
    stat_add(&game_stats, S_WAIT_IMAGE, now() - t0);
    return p.result;
}

/* DXMT: GPU sync through the texture's keyed mutex (game releases key 1 at fence V, our copy waits for V on the GPU
 * and signals V + 1, we release key 0 at V + 1 for the game's next AcquireSync), or a CPU wait on an event query.
 * The copy itself and the host release wait for flush_copy (xrEndFrame, or the swapchain's next acquire). */
static XrResult release_copy(struct swapchain *sc, const uint32_t *slot)
{
    struct session *s = sc->session;
    struct dxmt_copy_params c = {s->dxmt_ctx, sc->dxmt_images[slot[0]], sc->slices};
    BOOL keyed = sc->keyed[slot[0]] != NULL;
    LONGLONG t0 = now();

    for (uint32_t i = 0; i < sc->slices; i++) c.dst[i] = sc->host_images[i][slot[i]];
    if (keyed && FAILED(IDXGIKeyedMutex_ReleaseSync(sc->keyed[slot[0]], 1)))
    {
        ERR("keyed mutex ReleaseSync failed, copying without GPU sync");
        keyed = FALSE;
    }
    else if (s->fence)
    {
        ID3D11DeviceContext4_Signal(s->context4, s->fence, ++s->fence_value);
        sc->pending_fence = s->fence_value;
    }
    else if (sc->query)
    {
        ID3D11DeviceContext_End(s->context, (ID3D11Asynchronous *)sc->query);
        while (ID3D11DeviceContext_GetData(s->context, (ID3D11Asynchronous *)sc->query, NULL, 0, 0) == S_FALSE)
            SwitchToThread();
    }
    sc->pending_copy = c;
    sc->pending_keyed = keyed;
    memcpy(sc->pending_slot, slot, sizeof(sc->pending_slot));
    sc->pending = TRUE;
    sc->acquired_head = (sc->acquired_head + 1) % MAX_IMAGES;
    sc->acquired_count--;
    stat_add(&game_stats, S_RELEASE, now() - t0);
    if (getenv("WINEOPENXR_DXMT_DEFER") && !strcmp(getenv("WINEOPENXR_DXMT_DEFER"), "0"))
        return flush_copy(sc, NULL, &game_stats);
    return XR_SUCCESS;
}

/* rects: per slice x, y, width, height of what the frame's layers show (NULL or width 0: everything). Runs on the
 * app's thread, or on the session's worker (async). */
static XrResult flush_copy(struct swapchain *sc, const int32_t (*rects)[4], struct stats *st)
{
    struct session *s = sc->session;
    struct dxmt_copy_params *c = &sc->pending_copy;
    struct xrReleaseSwapchainImage_params p = {0, NULL};
    LONGLONG t0, t1, t2;

    if (!sc->pending) return XR_SUCCESS;
    sc->pending = FALSE;
    if (rects) memcpy(c->rect, rects, sizeof(c->rect));
    else memset(c->rect, 0, sizeof(c->rect));
    /* Wine's D3DKMT keyed mutex must be released by the thread that acquired it, so both happen here. The game's
     * ReleaseSync(1) at xrReleaseSwapchainImage made key 1 available with its fence value V. */
    t0 = now();
    c->wait_value = c->signal_value = 0;
    if (sc->pending_fence && ID3D11Fence_GetCompletedValue(s->fence) < sc->pending_fence)
    {
        ID3D11Fence_SetEventOnCompletion(s->fence, sc->pending_fence, s->fence_event);
        if (WaitForSingleObject(s->fence_event, 1000)) ERR("D3D11 fence %llu: timeout", sc->pending_fence);
    }
    sc->pending_fence = 0;
    if (sc->pending_keyed)
    {
        LARGE_INTEGER timeout = {.QuadPart = -10000000};
        D3DKMT_ACQUIREKEYEDMUTEX acq = {sc->kmt_mutex[sc->pending_slot[0]], 1};
        acq.pTimeout = &timeout;
        if (kmt.AcquireKeyedMutex(&acq))
        {
            ERR("D3DKMTAcquireKeyedMutex failed, copying without GPU sync");
            sc->pending_keyed = FALSE;
        }
        else
        {
            c->wait_value = acq.FenceValue;
            c->signal_value = acq.FenceValue + 1;
        }
    }
    stat_add(st, S_KMT_ACQUIRE, now() - t0);
    d3d11_lock(s, FALSE);
    t0 = now();
    UNIX_CALL(dxmt_copy, c);
    t1 = now();
    p.result = c->result;
    for (uint32_t i = 0; i < sc->slices && XR_SUCCEEDED(p.result); i++)
    {
        p.swapchain = sc->hosts[i];
        UNIX_CALL(xrReleaseSwapchainImage, &p);
    }
    d3d11_unlock(s);
    t2 = now();

    if (sc->pending_keyed)
    {
        D3DKMT_RELEASEKEYEDMUTEX rel = {sc->kmt_mutex[sc->pending_slot[0]], 0, c->signal_value};
        if (kmt.ReleaseKeyedMutex(&rel)) ERR("D3DKMTReleaseKeyedMutex failed");
    }

    stat_add(st, S_COPY, t1 - t0);
    stat_add(st, S_FENCE, c->fence_ns * stats_freq / 1000000000);
    stat_add(st, S_SUBMIT, c->submit_ns * stats_freq / 1000000000);
    stat_add(st, S_HOST_RELEASE, t2 - t1);
    stat_add(st, S_KMT_RELEASE, now() - t2);
    return p.result;
}

WINE_XR(XrResult) wine_xrReleaseSwapchainImage(XrSwapchain handle, const XrSwapchainImageReleaseInfo *info)
{
    struct xrReleaseSwapchainImage_params p = {handle, info};
    struct swapchain *sc = get_swapchain(handle);
    uint32_t *slot;

    if (!sc)
    {
        UNIX_CALL(xrReleaseSwapchainImage, &p);
        return p.result;
    }
    if (!sc->acquired_count) return XR_ERROR_CALL_ORDER_INVALID;
    slot = sc->acquired[sc->acquired_head];
    if (sc->kind == SWAPCHAIN_SPLIT)
        for (uint32_t s = 0; s < sc->slices; s++)
            ID3D11DeviceContext_CopySubresourceRegion(sc->session->context, (ID3D11Resource *)sc->host_textures[s][slot[s]], 0,
                                                      0, 0, 0, (ID3D11Resource *)sc->textures[slot[0]],
                                                      s /* slice s, mip 0 of 1 */, NULL);
    if (sc->kind == SWAPCHAIN_COPY) return release_copy(sc, slot);
    if (sc->kind != SWAPCHAIN_LOCAL)
    {
        d3d11_lock(sc->session, TRUE);
        for (uint32_t s = 0; s < sc->slices && XR_SUCCEEDED(p.result); s++)
        {
            p.swapchain = sc->hosts[s];
            UNIX_CALL(xrReleaseSwapchainImage, &p);
        }
        d3d11_unlock(sc->session);
    }
    sc->acquired_head = (sc->acquired_head + 1) % MAX_IMAGES;
    sc->acquired_count--;
    return p.result;
}

/* Points split swapchain sub-images at their slice's host swapchain. FALSE: the sub-image is a local swapchain. */
static BOOL fix_sub_image(XrSwapchainSubImage *sub)
{
    struct swapchain *sc = get_swapchain(sub->swapchain);
    if (!sc) return TRUE;
    if (sc->kind == SWAPCHAIN_LOCAL || sub->imageArrayIndex >= sc->slices) return FALSE;
    sub->swapchain = sc->hosts[sub->imageArrayIndex];
    sub->imageArrayIndex = 0;
    return TRUE;
}

#define MAX_LAYERS 16
#define MAX_VIEWS 4

struct frame_layers
{
    const XrCompositionLayerBaseHeader *headers[MAX_LAYERS];
    union
    {
        XrCompositionLayerProjection projection;
        XrCompositionLayerQuad quad;
        XrCompositionLayerCylinderKHR cylinder;
        XrCompositionLayerEquirect2KHR equirect2;
        XrCompositionLayerEquirectKHR equirect;
    } layers[MAX_LAYERS];
    XrCompositionLayerProjectionView views[MAX_LAYERS][MAX_VIEWS];
};

/* Copies of the app's layers with split/local swapchains resolved. Depth infos that name local swapchains are taken
 * out of the view chains. */
static BOOL rewrite_layers(struct session *s, const XrFrameEndInfo *info, struct frame_layers *out)
{
    BOOL any = FALSE;
    struct swapchain *sc;

    EnterCriticalSection(&lock);
    for (sc = swapchains; sc && (sc->session != s || sc->kind == SWAPCHAIN_HOST); sc = sc->next) {}
    LeaveCriticalSection(&lock);
    if (!sc || info->layerCount > MAX_LAYERS) return FALSE;

    for (uint32_t i = 0; i < info->layerCount; i++)
    {
        const XrCompositionLayerBaseHeader *h = info->layers[i];
        out->headers[i] = h;
        switch (h->type)
        {
        case XR_TYPE_COMPOSITION_LAYER_PROJECTION:
        {
            XrCompositionLayerProjection *p = &out->layers[i].projection;
            *p = *(const XrCompositionLayerProjection *)h;
            if (p->viewCount > MAX_VIEWS) break;
            for (uint32_t v = 0; v < p->viewCount; v++)
            {
                XrCompositionLayerProjectionView *view = &out->views[i][v];
                *view = p->views[v];
                fix_sub_image(&view->subImage);
                const XrCompositionLayerDepthInfoKHR *d = view->next;
                if (d && d->type == XR_TYPE_COMPOSITION_LAYER_DEPTH_INFO_KHR)
                {
                    XrSwapchainSubImage sub = d->subImage;
                    if (!fix_sub_image(&sub)) view->next = d->next;
                }
            }
            p->views = out->views[i];
            out->headers[i] = (const XrCompositionLayerBaseHeader *)p;
            any = TRUE;
            break;
        }
        case XR_TYPE_COMPOSITION_LAYER_QUAD:
            out->layers[i].quad = *(const XrCompositionLayerQuad *)h;
            fix_sub_image(&out->layers[i].quad.subImage);
            out->headers[i] = (const XrCompositionLayerBaseHeader *)&out->layers[i];
            any = TRUE;
            break;
        case XR_TYPE_COMPOSITION_LAYER_CYLINDER_KHR:
            out->layers[i].cylinder = *(const XrCompositionLayerCylinderKHR *)h;
            fix_sub_image(&out->layers[i].cylinder.subImage);
            out->headers[i] = (const XrCompositionLayerBaseHeader *)&out->layers[i];
            any = TRUE;
            break;
        case XR_TYPE_COMPOSITION_LAYER_EQUIRECT2_KHR:
            out->layers[i].equirect2 = *(const XrCompositionLayerEquirect2KHR *)h;
            fix_sub_image(&out->layers[i].equirect2.subImage);
            out->headers[i] = (const XrCompositionLayerBaseHeader *)&out->layers[i];
            any = TRUE;
            break;
        case XR_TYPE_COMPOSITION_LAYER_EQUIRECT_KHR:
            out->layers[i].equirect = *(const XrCompositionLayerEquirectKHR *)h;
            fix_sub_image(&out->layers[i].equirect.subImage);
            out->headers[i] = (const XrCompositionLayerBaseHeader *)&out->layers[i];
            any = TRUE;
            break;
        default:
            break;
        }
    }
    return any;
}

static void add_rect(int32_t (*rects)[MAX_SLICES][4], struct swapchain **scs, uint32_t *n, const XrSwapchainSubImage *sub)
{
    struct swapchain *sc = get_swapchain(sub->swapchain);
    uint32_t i, k = sub->imageArrayIndex;
    int32_t *r, x0, y0, x1, y1;
    const int32_t pad = 2;

    if (!sc || !sc->pending || k >= sc->slices) return;
    for (i = 0; i < *n && scs[i] != sc; i++) {}
    if (i == *n)
    {
        if (*n == MAX_LAYERS) return;
        scs[(*n)++] = sc;
        memset(rects[i], 0, sizeof(rects[i]));
    }
    r = rects[i][k];
    x0 = sub->imageRect.offset.x - pad;
    y0 = sub->imageRect.offset.y - pad;
    x1 = sub->imageRect.offset.x + sub->imageRect.extent.width + pad;
    y1 = sub->imageRect.offset.y + sub->imageRect.extent.height + pad;
    if (r[2] > 0)
    {
        x0 = min(x0, r[0]);
        y0 = min(y0, r[1]);
        x1 = max(x1, r[0] + r[2]);
        y1 = max(y1, r[1] + r[3]);
    }
    r[0] = max(x0, 0);
    r[1] = max(y0, 0);
    r[2] = x1 - r[0];
    r[3] = y1 - r[1];
}

/* The copies an xrEndFrame runs: each image released this frame, limited to the part the layers show. Swapchains no
 * layer names get a full copy. */
struct frame_copies
{
    struct swapchain *scs[MAX_LAYERS];
    int32_t rects[MAX_LAYERS][MAX_SLICES][4];
    uint32_t n;
};

static void collect_frame_copies(const XrFrameEndInfo *info, struct frame_copies *fc)
{
    fc->n = 0;
    for (uint32_t i = 0; i < info->layerCount; i++)
    {
        const XrCompositionLayerBaseHeader *h = info->layers[i];
        switch (h->type)
        {
        case XR_TYPE_COMPOSITION_LAYER_PROJECTION:
        {
            const XrCompositionLayerProjection *p = (const XrCompositionLayerProjection *)h;
            for (uint32_t v = 0; v < p->viewCount; v++) add_rect(fc->rects, fc->scs, &fc->n, &p->views[v].subImage);
            break;
        }
        case XR_TYPE_COMPOSITION_LAYER_QUAD:
            add_rect(fc->rects, fc->scs, &fc->n, &((const XrCompositionLayerQuad *)h)->subImage);
            break;
        case XR_TYPE_COMPOSITION_LAYER_CYLINDER_KHR:
            add_rect(fc->rects, fc->scs, &fc->n, &((const XrCompositionLayerCylinderKHR *)h)->subImage);
            break;
        case XR_TYPE_COMPOSITION_LAYER_EQUIRECT2_KHR:
            add_rect(fc->rects, fc->scs, &fc->n, &((const XrCompositionLayerEquirect2KHR *)h)->subImage);
            break;
        case XR_TYPE_COMPOSITION_LAYER_EQUIRECT_KHR:
            add_rect(fc->rects, fc->scs, &fc->n, &((const XrCompositionLayerEquirectKHR *)h)->subImage);
            break;
        default:
            break;
        }
    }
}

static void run_frame_copies(struct session *s, const struct frame_copies *fc, struct stats *st)
{
    struct swapchain *sc, *todo[64];
    uint32_t m = 0;

    for (uint32_t i = 0; i < fc->n; i++) flush_copy(fc->scs[i], fc->rects[i], st);
    EnterCriticalSection(&lock);
    for (sc = swapchains; sc && m < ARRAY_SIZE(todo); sc = sc->next)
        if (sc->session == s && sc->pending) todo[m++] = sc;
    LeaveCriticalSection(&lock);
    for (uint32_t i = 0; i < m; i++) flush_copy(todo[i], NULL, st);
}

static XrResult host_end_frame(struct session *s, const XrFrameEndInfo *info, struct stats *st)
{
    struct xrEndFrame_params p = {s ? s->handle : XR_NULL_HANDLE, info};
    LONGLONG t0;
    d3d11_lock(s, TRUE);
    t0 = now();
    UNIX_CALL(xrEndFrame, &p);
    stat_add(st, S_HOST_END, now() - t0);
    d3d11_unlock(s);
    return p.result;
}

/*
 * Async xrEndFrame (DXMT sessions, WINEOPENXR_ASYNC=1 or 2)
 *
 * The frame thread keeps the keyed-mutex handoff (release) and hands the rest of xrEndFrame to the session's worker:
 * the copies (GPU waits for the game's fence, signals ours), the host releases, the D3DKMT releases and the host
 * xrEndFrame, in this order. One job at a time. The next xrWaitFrame (1) or xrBeginFrame (2) and anything that
 * touches the swapchains (acquire, destroy, xrEndSession) wait for the job, so host calls keep the app's order and an
 * image is never acquired before its D3DKMT release; the GPU order comes from the keyed mutex's fence values.
 */
struct end_job
{
    XrFrameEndInfo info;
    struct frame_layers layers;
    struct frame_copies copies;
    LONGLONG queued;
};

/* A self-contained copy of the frame for the worker; FALSE when the app's structs carry chains it can't copy. */
static BOOL prepare_job(struct session *s, const XrFrameEndInfo *info, struct end_job *job)
{
    if (info->next || info->layerCount > MAX_LAYERS) return FALSE;
    job->info = *info;
    job->info.layers = NULL;
    if (info->layerCount)
    {
        if (!rewrite_layers(s, info, &job->layers)) return FALSE;
        for (uint32_t i = 0; i < info->layerCount; i++)
        {
            const XrCompositionLayerBaseHeader *h = job->layers.headers[i];
            if (h == info->layers[i] || h->next) return FALSE;
            if (h->type == XR_TYPE_COMPOSITION_LAYER_PROJECTION)
            {
                const XrCompositionLayerProjection *p = (const XrCompositionLayerProjection *)h;
                for (uint32_t v = 0; v < p->viewCount; v++)
                    if (p->views[v].next) return FALSE;
            }
        }
        job->info.layers = job->layers.headers;
    }
    collect_frame_copies(info, &job->copies);
    return TRUE;
}

static DWORD WINAPI worker_main(void *arg)
{
    struct session *s = arg;
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST);
    for (;;)
    {
        LONGLONG t0;
        XrResult r;
        AcquireSRWLockExclusive(&s->job_lock);
        while (!s->job_busy && !s->worker_exit) SleepConditionVariableSRW(&s->job_cv, &s->job_lock, INFINITE, 0);
        if (!s->job_busy)
        {
            ReleaseSRWLockExclusive(&s->job_lock);
            return 0;
        }
        ReleaseSRWLockExclusive(&s->job_lock);

        t0 = now();
        run_frame_copies(s, &s->job->copies, &work_stats);
        r = host_end_frame(s, &s->job->info, &work_stats);
        if (XR_FAILED(r)) ERR("async xrEndFrame: %d", r);
        stat_add(&work_stats, S_WORK, now() - t0);
        stat_add(&work_stats, S_LAG, now() - s->job->queued);
        stat_commit(&work_stats, S_WORK);

        AcquireSRWLockExclusive(&s->job_lock);
        if (XR_FAILED(r) && XR_SUCCEEDED(s->job_result)) s->job_result = r;
        s->job_busy = FALSE;
        ReleaseSRWLockExclusive(&s->job_lock);
        WakeAllConditionVariable(&s->job_cv);
    }
}

static int async_setting(void)
{
    const char *v = getenv("WINEOPENXR_ASYNC");
    return v ? atoi(v) : 0;
}

/* WINEOPENXR_ASYNC_RELOAD=1 (A/B tests): re-read WINEOPENXR_ASYNC from C:\macvr\wineopenxr.env every 300 frames. */
static int async_reload(void)
{
    char line[256];
    int mode = -1;
    FILE *f = fopen("C:\\macvr\\wineopenxr.env", "r");
    if (!f) return -1;
    while (fgets(line, sizeof(line), f))
        if (!strncmp(line, "WINEOPENXR_ASYNC=", 17)) mode = atoi(line + 17);
    fclose(f);
    return mode;
}

static void start_worker(struct session *s)
{
    int mode = async_setting();
    /* The fence wait belongs on the worker, so the game's next frame overlaps the GPU. */
    if (s->fence && mode < 1) mode = 2;
    if (mode < 1 || mode > 2 || (s->cpu_sync && !s->fence)) return;
    InitializeSRWLock(&s->job_lock);
    InitializeConditionVariable(&s->job_cv);
    if (!(s->job = calloc(1, sizeof(*s->job)))) return;
    if (!(s->worker = CreateThread(NULL, 0, worker_main, s, 0, NULL)))
    {
        free(s->job);
        s->job = NULL;
        return;
    }
    s->async = mode;
    if (getenv("WINEOPENXR_DEBUG")) ERR("async xrEndFrame, mode %d", mode);
}

static void drain(struct session *s)
{
    if (!s || !s->worker) return;
    AcquireSRWLockExclusive(&s->job_lock);
    while (s->job_busy) SleepConditionVariableSRW(&s->job_cv, &s->job_lock, INFINITE, 0);
    ReleaseSRWLockExclusive(&s->job_lock);
}

static void stop_worker(struct session *s)
{
    if (!s->worker) return;
    AcquireSRWLockExclusive(&s->job_lock);
    while (s->job_busy) SleepConditionVariableSRW(&s->job_cv, &s->job_lock, INFINITE, 0);
    s->worker_exit = TRUE;
    ReleaseSRWLockExclusive(&s->job_lock);
    WakeAllConditionVariable(&s->job_cv);
    WaitForSingleObject(s->worker, INFINITE);
    CloseHandle(s->worker);
    free(s->job);
    s->worker = NULL;
    s->job = NULL;
    s->async = 0;
}

WINE_XR(XrResult) wine_xrEndFrame(XrSession session, const XrFrameEndInfo *info)
{
    struct session *s = get_session(session);
    struct frame_layers layers;
    struct frame_copies copies;
    XrFrameEndInfo fixed;
    XrResult r;
    LONGLONG t0 = now();
    static int reload = -1;
    static uint32_t frames;

    if (reload < 0) reload = getenv("WINEOPENXR_ASYNC_RELOAD") && atoi(getenv("WINEOPENXR_ASYNC_RELOAD"));
    if (reload && s && s->dxmt_ctx && !(++frames % 300))
    {
        int mode = async_reload();
        if (mode >= 0 && mode <= 2 && mode != s->async)
        {
            drain(s);
            if (!s->worker && mode)
            {
                _putenv(mode == 1 ? "WINEOPENXR_ASYNC=1" : "WINEOPENXR_ASYNC=2");
                start_worker(s);
            }
            else
                s->async = mode;
            ERR("async mode %d", s->async);
        }
    }

    if (s && s->async && info)
    {
        drain(s);
        if (prepare_job(s, info, s->job))
        {
            AcquireSRWLockExclusive(&s->job_lock);
            r = s->job_result;
            s->job_result = XR_SUCCESS;
            s->job->queued = now();
            s->job_busy = TRUE;
            ReleaseSRWLockExclusive(&s->job_lock);
            WakeAllConditionVariable(&s->job_cv);
            stat_add(&game_stats, S_END, now() - t0);
            stat_commit(&game_stats, S_GAME);
            /* A failed host xrEndFrame shows up one frame late. */
            return XR_FAILED(r) ? r : XR_SUCCESS;
        }
    }

    if (s && s->dxmt_ctx && info)
    {
        collect_frame_copies(info, &copies);
        run_frame_copies(s, &copies, &game_stats);
    }
    if (s && s->d3d11 && rewrite_layers(s, info, &layers))
    {
        fixed = *info;
        fixed.layers = layers.headers;
        info = &fixed;
    }
    if (s)
        r = host_end_frame(s, info, &game_stats);
    else
    {
        struct xrEndFrame_params p = {session, info};
        UNIX_CALL(xrEndFrame, &p);
        r = p.result;
    }
    stat_add(&game_stats, S_END, now() - t0);
    stat_commit(&game_stats, S_GAME);
    return r;
}

WINE_XR(XrResult) wine_xrWaitFrame(XrSession session, const XrFrameWaitInfo *info, XrFrameState *state)
{
    struct xrWaitFrame_params p = {session, info, state};
    struct session *s = get_session(session);
    LONGLONG t0 = now(), t1;

    if (s && s->async == 1) drain(s);
    t1 = now();
    UNIX_CALL(xrWaitFrame, &p);
    stat_add(&game_stats, S_DRAIN, t1 - t0);
    stat_add(&game_stats, S_WAIT, now() - t1);
    return p.result;
}

WINE_XR(XrResult) wine_xrBeginFrame(XrSession session, const XrFrameBeginInfo *info)
{
    struct xrBeginFrame_params p = {session, info};
    struct session *s = get_session(session);
    LONGLONG t0 = now(), t1;

    if (s && s->async) drain(s);
    t1 = now();
    UNIX_CALL(xrBeginFrame, &p);
    stat_add(&game_stats, S_DRAIN, t1 - t0);
    stat_add(&game_stats, S_BEGIN, now() - t1);
    return p.result;
}

WINE_XR(XrResult) wine_xrEndSession(XrSession session)
{
    struct xrEndSession_params p = {session};
    drain(get_session(session));
    UNIX_CALL(xrEndSession, &p);
    return p.result;
}

/*
 * XR_KHR_win32_convert_performance_counter_time
 */

WINE_XR(XrResult) wine_xrConvertWin32PerformanceCounterToTimeKHR(XrInstance instance, const LARGE_INTEGER *counter,
                                                                  XrTime *time)
{
    if (instance != inst.handle || !inst.qpc_freq) return XR_ERROR_HANDLE_INVALID;
    if (counter->QuadPart <= 0) return XR_ERROR_TIME_INVALID;
    *time = qpc_to_ns(counter->QuadPart) + inst.time_offset_ns;
    return *time > 0 ? XR_SUCCESS : XR_ERROR_TIME_INVALID;
}

WINE_XR(XrResult) wine_xrConvertTimeToWin32PerformanceCounterKHR(XrInstance instance, XrTime time, LARGE_INTEGER *counter)
{
    if (instance != inst.handle || !inst.qpc_freq) return XR_ERROR_HANDLE_INVALID;
    if (time <= 0) return XR_ERROR_TIME_INVALID;
    counter->QuadPart = ns_to_qpc(time - inst.time_offset_ns);
    return counter->QuadPart > 0 ? XR_SUCCESS : XR_ERROR_TIME_INVALID;
}

/*
 * Exports
 */

__declspec(dllexport) XrResult WINAPI xrNegotiateLoaderRuntimeInterface(const XrNegotiateLoaderInfo *info,
                                                                         XrNegotiateRuntimeRequest *req)
{
    if (!info || !req || info->structType != XR_LOADER_INTERFACE_STRUCT_LOADER_INFO ||
        req->structType != XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST || info->minInterfaceVersion > 1 ||
        info->maxInterfaceVersion < 1 || info->minApiVersion > XR_MAKE_VERSION(1, 1, 0x3ff))
        return XR_ERROR_INITIALIZATION_FAILED;
    req->runtimeInterfaceVersion = 1;
    req->runtimeApiVersion = info->maxApiVersion < XR_CURRENT_API_VERSION ? info->maxApiVersion : XR_CURRENT_API_VERSION;
    req->getInstanceProcAddr = wine_xrGetInstanceProcAddr;
    return XR_SUCCESS;
}

/* DXVK's DxvkXrProvider adds these to the VkInstance/VkDevice it creates. Proton's semantics: space separated,
 * the count includes the terminator, and a short buffer only gets the count. */
static XrResult dxvk_extensions(BOOL device, uint32_t capacity, uint32_t *count, char *buffer)
{
    const char *names[] = {XR_KHR_VULKAN_ENABLE_EXTENSION_NAME};
    XrInstanceCreateInfo ci = {XR_TYPE_INSTANCE_CREATE_INFO};
    XrSystemGetInfo sgi = {XR_TYPE_SYSTEM_GET_INFO, NULL, XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY};
    XrInstance instance = inst.handle, temp = XR_NULL_HANDLE;
    XrSystemId system;
    char list[4096];
    uint32_t len;
    XrResult r;

    if (!runtime_ready()) return XR_ERROR_RUNTIME_UNAVAILABLE;
    if (!instance)
    {
        strcpy(ci.applicationInfo.applicationName, "wineopenxr");
        ci.applicationInfo.apiVersion = XR_MAKE_VERSION(1, 0, 0);
        ci.enabledExtensionCount = 1;
        ci.enabledExtensionNames = names;
        struct create_instance_params p = {&ci, &temp};
        UNIX_CALL(create_instance, &p);
        if (XR_FAILED(p.result)) return p.result;
        instance = temp;
    }
    struct xrGetSystem_params gs = {instance, &sgi, &system};
    UNIX_CALL(xrGetSystem, &gs);
    r = XR_SUCCEEDED(gs.result) ? filtered_vk_extensions(device, instance, system, sizeof(list), &len, list) : gs.result;
    if (temp)
    {
        struct destroy_instance_params d = {temp};
        UNIX_CALL(destroy_instance, &d);
    }
    if (XR_FAILED(r)) return r;
    *count = len;
    if (buffer && capacity >= len) memcpy(buffer, list, len);
    return XR_SUCCESS;
}

__declspec(dllexport) XrResult WINAPI __wineopenxr_GetVulkanInstanceExtensions(uint32_t capacity, uint32_t *count, char *buffer)
{
    return dxvk_extensions(FALSE, capacity, count, buffer);
}

__declspec(dllexport) XrResult WINAPI __wineopenxr_GetVulkanDeviceExtensions(uint32_t capacity, uint32_t *count, char *buffer)
{
    return dxvk_extensions(TRUE, capacity, count, buffer);
}
