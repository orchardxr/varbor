/* M2 step 1: the x86_64 Monado IPC client (bridge flavour) inside the Wine process, on DXVK's unwrapped VkDevice. */
#define VK_USE_PLATFORM_METAL_EXT
#define XR_USE_GRAPHICS_API_VULKAN
#include <vulkan/vulkan.h>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include <openxr/openxr_loader_negotiation.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "probe.h"

typedef int NTSTATUS;

static PFN_xrGetInstanceProcAddr xr_gipa;
static XrInstance instance;
static XrSystemId system_id;
static XrSession session;
static XrSwapchain swapchain;
static XrSpace space;
static XrFrameState frame_state;
static XrView views[2];
static uint32_t width, height;

#define XF(name) PFN_##name name = NULL; xr_gipa(instance, #name, (PFN_xrVoidFunction *)&name)

static uint64_t now_ns(void)
{
    struct timespec t;
    clock_gettime(CLOCK_UPTIME_RAW, &t);
    return t.tv_sec * 1000000000ull + t.tv_nsec;
}

#define FAIL(...) do { snprintf(p->info, sizeof(p->info), __VA_ARGS__); p->status = 1; return 0; } while (0)
#define CHK(expr) do { XrResult _r = (expr); if (XR_FAILED(_r)) FAIL("%s failed: %d", #expr, _r); } while (0)

NTSTATUS xrprobe_init(void *a)
{
    struct xrprobe_init *p = a;
    const char *mvk = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++)
        if (strstr(_dyld_get_image_name(i), "libMoltenVK")) { mvk = _dyld_get_image_name(i); break; }
    if (!mvk) FAIL("no MoltenVK loaded");
    setenv("XRT_VK_GIPA_LIBRARY", mvk, 1);
    setenv("OXR_DEBUG_FORCE_TIMELINE_SEMAPHORES", "1", 1);
    const char *rt = getenv("MACVR_OPENXR_RUNTIME");
    void *lib = rt ? dlopen(rt, RTLD_NOW | RTLD_LOCAL) : NULL;
    if (!lib) FAIL("dlopen runtime %s: %s", rt ? rt : "(MACVR_OPENXR_RUNTIME unset)", dlerror());
    PFN_xrNegotiateLoaderRuntimeInterface negotiate = (PFN_xrNegotiateLoaderRuntimeInterface)dlsym(lib, "xrNegotiateLoaderRuntimeInterface");
    XrNegotiateLoaderInfo li = {XR_LOADER_INTERFACE_STRUCT_LOADER_INFO, XR_LOADER_INFO_STRUCT_VERSION, sizeof(li),
                                1, XR_CURRENT_LOADER_RUNTIME_VERSION, XR_MAKE_VERSION(1, 0, 0), XR_MAKE_VERSION(1, 1, 0x3ff)};
    XrNegotiateRuntimeRequest rr = {XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST, XR_RUNTIME_INFO_STRUCT_VERSION, sizeof(rr)};
    CHK(negotiate(&li, &rr));
    xr_gipa = rr.getInstanceProcAddr;

    XF(xrCreateInstance);
    const char *exts[] = {XR_KHR_VULKAN_ENABLE_EXTENSION_NAME};
    XrInstanceCreateInfo ici = {XR_TYPE_INSTANCE_CREATE_INFO};
    strcpy(ici.applicationInfo.applicationName, "xrprobe");
    ici.applicationInfo.apiVersion = XR_MAKE_VERSION(1, 0, 0);
    ici.enabledExtensionCount = 1;
    ici.enabledExtensionNames = exts;
    uint64_t t0 = now_ns();
    CHK(xrCreateInstance(&ici, &instance));
    XF(xrGetSystem); XF(xrGetVulkanGraphicsRequirementsKHR); XF(xrGetVulkanGraphicsDeviceKHR); XF(xrCreateSession);
    XF(xrEnumerateSwapchainFormats); XF(xrCreateSwapchain); XF(xrEnumerateSwapchainImages);
    XF(xrCreateReferenceSpace); XF(xrPollEvent); XF(xrBeginSession); XF(xrEnumerateViewConfigurationViews);
    XrSystemGetInfo sgi = {XR_TYPE_SYSTEM_GET_INFO, NULL, XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY};
    CHK(xrGetSystem(instance, &sgi, &system_id));
    XrGraphicsRequirementsVulkanKHR req = {XR_TYPE_GRAPHICS_REQUIREMENTS_VULKAN_KHR};
    CHK(xrGetVulkanGraphicsRequirementsKHR(instance, system_id, &req));
    VkPhysicalDevice suggested = VK_NULL_HANDLE;
    CHK(xrGetVulkanGraphicsDeviceKHR(instance, system_id, (VkInstance)(uintptr_t)p->host_instance, &suggested));
    if ((uint64_t)(uintptr_t)suggested != p->host_physdev) FAIL("runtime suggests physdev %p, DXVK uses %#llx", suggested, (unsigned long long)p->host_physdev);

    XrGraphicsBindingVulkanKHR gb = {XR_TYPE_GRAPHICS_BINDING_VULKAN_KHR};
    gb.instance = (VkInstance)(uintptr_t)p->host_instance;
    gb.physicalDevice = (VkPhysicalDevice)(uintptr_t)p->host_physdev;
    gb.device = (VkDevice)(uintptr_t)p->host_device;
    gb.queueFamilyIndex = p->queue_family;
    gb.queueIndex = p->queue_index;
    XrSessionCreateInfo sci = {XR_TYPE_SESSION_CREATE_INFO, &gb, 0, system_id};
    CHK(xrCreateSession(instance, &sci, &session));

    XrViewConfigurationView vcv[2] = {{XR_TYPE_VIEW_CONFIGURATION_VIEW}, {XR_TYPE_VIEW_CONFIGURATION_VIEW}};
    uint32_t n = 0;
    CHK(xrEnumerateViewConfigurationViews(instance, system_id, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 2, &n, vcv));
    width = p->width ? p->width : vcv[0].recommendedImageRectWidth;
    height = p->height ? p->height : vcv[0].recommendedImageRectHeight;

    int64_t formats[64];
    CHK(xrEnumerateSwapchainFormats(session, 64, &n, formats));
    int found = 0;
    for (uint32_t i = 0; i < n; i++) found |= formats[i] == VK_FORMAT_B8G8R8A8_UNORM;
    if (!found) FAIL("B8G8R8A8_UNORM not offered (%u formats)", n);
    XrSwapchainCreateInfo sc = {XR_TYPE_SWAPCHAIN_CREATE_INFO};
    sc.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
    sc.format = VK_FORMAT_B8G8R8A8_UNORM;
    sc.sampleCount = 1;
    sc.width = width * 2;
    sc.height = height;
    sc.faceCount = 1;
    sc.arraySize = 1;
    sc.mipCount = 1;
    CHK(xrCreateSwapchain(session, &sc, &swapchain));
    XrSwapchainImageVulkanKHR imgs[XRPROBE_MAX_IMAGES];
    for (int i = 0; i < XRPROBE_MAX_IMAGES; i++) imgs[i] = (XrSwapchainImageVulkanKHR){XR_TYPE_SWAPCHAIN_IMAGE_VULKAN_KHR};
    CHK(xrEnumerateSwapchainImages(swapchain, XRPROBE_MAX_IMAGES, &n, (XrSwapchainImageBaseHeader *)imgs));
    p->image_count = n;
    for (uint32_t i = 0; i < n; i++) p->images[i] = (uint64_t)(uintptr_t)imgs[i].image;
    p->width = width * 2;
    p->height = height;

    XrReferenceSpaceCreateInfo rsci = {XR_TYPE_REFERENCE_SPACE_CREATE_INFO, NULL, XR_REFERENCE_SPACE_TYPE_LOCAL};
    rsci.poseInReferenceSpace.orientation.w = 1;
    CHK(xrCreateReferenceSpace(session, &rsci, &space));

    for (uint64_t t = now_ns(); now_ns() - t < 5000000000ull;)
    {
        XrEventDataBuffer ev = {XR_TYPE_EVENT_DATA_BUFFER};
        if (xrPollEvent(instance, &ev) != XR_SUCCESS) { usleep(1000); continue; }
        if (ev.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED &&
            ((XrEventDataSessionStateChanged *)&ev)->state == XR_SESSION_STATE_READY)
        {
            XrSessionBeginInfo bi = {XR_TYPE_SESSION_BEGIN_INFO, NULL, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO};
            CHK(xrBeginSession(session, &bi));
            snprintf(p->info, sizeof(p->info), "runtime %s via MoltenVK %s; instance..begin %.1f ms; swapchain %ux%u, %u IOSurface images",
                     rt, mvk, (now_ns() - t0) / 1e6, width * 2, height, n);
            p->status = 0;
            return 0;
        }
    }
    FAIL("no XR_SESSION_STATE_READY");
}

NTSTATUS xrprobe_begin(void *a)
{
    struct xrprobe_frame *p = a;
    XF(xrWaitFrame); XF(xrBeginFrame); XF(xrAcquireSwapchainImage); XF(xrWaitSwapchainImage); XF(xrLocateViews);
    XF(xrPollEvent);
    XrEventDataBuffer ev = {XR_TYPE_EVENT_DATA_BUFFER};
    while (xrPollEvent(instance, &ev) == XR_SUCCESS) ev = (XrEventDataBuffer){XR_TYPE_EVENT_DATA_BUFFER};
    frame_state = (XrFrameState){XR_TYPE_FRAME_STATE};
    CHK(xrWaitFrame(session, NULL, &frame_state));
    CHK(xrBeginFrame(session, NULL));
    XrViewLocateInfo vli = {XR_TYPE_VIEW_LOCATE_INFO, NULL, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, frame_state.predictedDisplayTime, space};
    XrViewState vs = {XR_TYPE_VIEW_STATE};
    uint32_t n;
    views[0] = views[1] = (XrView){XR_TYPE_VIEW};
    CHK(xrLocateViews(session, &vli, &vs, 2, &n, views));
    uint32_t index;
    CHK(xrAcquireSwapchainImage(swapchain, NULL, &index));
    XrSwapchainImageWaitInfo wi = {XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO, NULL, XR_INFINITE_DURATION};
    CHK(xrWaitSwapchainImage(swapchain, &wi));
    p->index = index;
    p->status = 0;
    return 0;
}

NTSTATUS xrprobe_end(void *a)
{
    struct xrprobe_frame *p = a;
    XF(xrReleaseSwapchainImage); XF(xrEndFrame);
    uint64_t t0 = now_ns();
    CHK(xrReleaseSwapchainImage(swapchain, NULL));
    XrCompositionLayerProjectionView pv[2];
    for (int i = 0; i < 2; i++)
    {
        pv[i] = (XrCompositionLayerProjectionView){XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW};
        pv[i].pose = views[i].pose;
        pv[i].fov = views[i].fov;
        pv[i].subImage.swapchain = swapchain;
        pv[i].subImage.imageRect.offset.x = i * width;
        pv[i].subImage.imageRect.extent.width = width;
        pv[i].subImage.imageRect.extent.height = height;
    }
    XrCompositionLayerProjection proj = {XR_TYPE_COMPOSITION_LAYER_PROJECTION, NULL, 0, space, 2, pv};
    const XrCompositionLayerBaseHeader *layers[] = {(XrCompositionLayerBaseHeader *)&proj};
    XrFrameEndInfo fei = {XR_TYPE_FRAME_END_INFO, NULL, frame_state.predictedDisplayTime, XR_ENVIRONMENT_BLEND_MODE_OPAQUE,
                          frame_state.shouldRender ? 1 : 0, layers};
    CHK(xrEndFrame(session, &fei));
    p->end_ns = now_ns() - t0;
    p->status = 0;
    return 0;
}

NTSTATUS xrprobe_shutdown(void *a)
{
    XF(xrDestroySwapchain); XF(xrDestroySpace); XF(xrDestroySession); XF(xrDestroyInstance); XF(xrRequestExitSession);
    xrRequestExitSession(session);
    xrDestroySwapchain(swapchain);
    xrDestroySpace(space);
    xrDestroySession(session);
    xrDestroyInstance(instance);
    return 0;
}
