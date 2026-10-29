/* DXMT sessions, unix side. DXMT has no Vulkan device, so the bridge creates one on CrossOver's MoltenVK for Monado's
 * client compositor. The game renders into DXMT shared textures (MTLSharedTextureHandle ports that DXMT registers in
 * the bootstrap namespace); they are imported here with VkImportMetalTextureInfoEXT and copied into Monado's swapchain
 * images on our queue. The keyed mutex's MTLSharedEvent becomes a timeline semaphore, so the copy waits on the GPU. */
#define VK_USE_PLATFORM_METAL_EXT
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <servers/bootstrap.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "wineopenxr_unix.h"

@interface MTLSharedTextureHandle (MacvrSPI)
- (instancetype)initWithMachPort:(mach_port_t)port;
@end

@protocol MacvrMTLDeviceSPI <MTLDevice>
- (id<MTLSharedEvent>)newSharedEventWithMachPort:(mach_port_t)port;
@end

#define RING 16

struct dxmt_ctx
{
    PFN_vkGetInstanceProcAddr gipa;
    VkInstance instance;
    VkPhysicalDevice physical_device;
    VkDevice device;
    VkQueue queue;
    uint32_t family;
    id<MTLDevice> mtl;
    VkCommandPool pool;
    VkCommandBuffer cmd[RING];
    VkFence fence[RING];
    uint32_t next;
#define F(n) PFN_##n n;
    F(vkDestroyInstance) F(vkDestroyDevice) F(vkGetDeviceQueue) F(vkCreateImage) F(vkDestroyImage)
    F(vkGetImageMemoryRequirements) F(vkAllocateMemory) F(vkFreeMemory) F(vkBindImageMemory) F(vkCreateSemaphore)
    F(vkDestroySemaphore) F(vkCreateCommandPool) F(vkDestroyCommandPool) F(vkAllocateCommandBuffers)
    F(vkBeginCommandBuffer) F(vkEndCommandBuffer) F(vkResetCommandBuffer) F(vkCmdPipelineBarrier) F(vkCmdCopyImage)
    F(vkQueueSubmit) F(vkCreateFence) F(vkDestroyFence) F(vkWaitForFences) F(vkResetFences) F(vkDeviceWaitIdle)
    F(vkExportMetalObjectsEXT)
#undef F
};

struct dxmt_image
{
    VkImage image;
    VkDeviceMemory memory;
    VkSemaphore semaphore;
    uint32_t width, height, layers, mips;
};

static BOOL has_ext(const VkExtensionProperties *props, uint32_t n, const char *name)
{
    for (uint32_t i = 0; i < n; i++)
        if (!strcmp(props[i].extensionName, name)) return YES;
    return NO;
}

/* Monado's space-separated list, minus what MoltenVK doesn't have (there is no loader, so no portability_enumeration). */
static uint32_t filter_exts(char *list, const VkExtensionProperties *props, uint32_t n, const char **out, uint32_t max)
{
    uint32_t count = 0;
    for (char *s = strtok(list, " "); s && count < max; s = strtok(NULL, " "))
        if (has_ext(props, n, s)) out[count++] = s;
    return count;
}

static XrResult host_vk_exts(BOOL device, XrInstance instance, XrSystemId system, char **out)
{
    PFN_xrGetVulkanInstanceExtensionsKHR get =
        device ? (PFN_xrGetVulkanInstanceExtensionsKHR)host.xrGetVulkanDeviceExtensionsKHR : host.xrGetVulkanInstanceExtensionsKHR;
    uint32_t n = 0;
    XrResult r;
    if (!get) return XR_ERROR_FUNCTION_UNSUPPORTED;
    if (XR_FAILED(r = get(instance, system, 0, &n, NULL))) return r;
    *out = calloc(1, n + 1);
    if (XR_FAILED(r = get(instance, system, n, &n, *out))) free(*out);
    return r;
}

static void destroy_ctx(struct dxmt_ctx *c)
{
    if (c->device)
    {
        c->vkDeviceWaitIdle(c->device);
        for (uint32_t i = 0; i < RING; i++)
            if (c->fence[i]) c->vkDestroyFence(c->device, c->fence[i], NULL);
        if (c->pool) c->vkDestroyCommandPool(c->device, c->pool, NULL);
        c->vkDestroyDevice(c->device, NULL);
    }
    if (c->instance) c->vkDestroyInstance(c->instance, NULL);
    if (c->mtl) [c->mtl release];
    free(c);
}

static XrResult create_ctx(struct dxmt_create_device_params *p, struct dxmt_ctx *c)
{
    const char *mvk = moltenvk_path();
    void *lib = mvk ? dlopen(mvk, RTLD_NOW | RTLD_NOLOAD) : NULL;
    const char *names[64];
    VkExtensionProperties props[256];
    uint32_t n;
    char *list;
    XrResult r;
    VkResult vr;

    if (!lib || !(c->gipa = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vkGetInstanceProcAddr")))
    {
        snprintf(p->info, sizeof(p->info), "CrossOver's MoltenVK not found");
        return XR_ERROR_RUNTIME_FAILURE;
    }
    PFN_vkCreateInstance create_instance = (PFN_vkCreateInstance)c->gipa(NULL, "vkCreateInstance");
    PFN_vkEnumerateInstanceExtensionProperties enum_iexts =
        (PFN_vkEnumerateInstanceExtensionProperties)c->gipa(NULL, "vkEnumerateInstanceExtensionProperties");

    /* Monado checks its Vulkan requirements before it accepts a session. */
    XrGraphicsRequirementsVulkanKHR req = {XR_TYPE_GRAPHICS_REQUIREMENTS_VULKAN_KHR};
    if (XR_FAILED(r = host.xrGetVulkanGraphicsRequirementsKHR(p->instance, p->system, &req))) return r;

    if (XR_FAILED(r = host_vk_exts(FALSE, p->instance, p->system, &list))) return r;
    n = ARRAY_SIZE(props);
    enum_iexts(NULL, &n, props);
    VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "wineopenxr-dxmt", 1, "wineopenxr", 1, VK_API_VERSION_1_2};
    VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL, 0, &app};
    ici.ppEnabledExtensionNames = names;
    ici.enabledExtensionCount = filter_exts(list, props, n, names, ARRAY_SIZE(names));
    vr = create_instance(&ici, NULL, &c->instance);
    free(list);
    if (vr)
    {
        snprintf(p->info, sizeof(p->info), "vkCreateInstance: %d", vr);
        return XR_ERROR_RUNTIME_FAILURE;
    }

#define L(n) c->n = (PFN_##n)c->gipa(c->instance, #n);
    L(vkDestroyInstance)
    PFN_vkCreateDevice create_device = (PFN_vkCreateDevice)c->gipa(c->instance, "vkCreateDevice");
    PFN_vkEnumerateDeviceExtensionProperties enum_dexts =
        (PFN_vkEnumerateDeviceExtensionProperties)c->gipa(c->instance, "vkEnumerateDeviceExtensionProperties");
    PFN_vkGetPhysicalDeviceQueueFamilyProperties queue_props =
        (PFN_vkGetPhysicalDeviceQueueFamilyProperties)c->gipa(c->instance, "vkGetPhysicalDeviceQueueFamilyProperties");

    if (XR_FAILED(r = host.xrGetVulkanGraphicsDeviceKHR(p->instance, p->system, c->instance, &c->physical_device))) return r;

    VkQueueFamilyProperties qf[8];
    uint32_t qn = ARRAY_SIZE(qf);
    queue_props(c->physical_device, &qn, qf);
    for (c->family = 0; c->family < qn && !(qf[c->family].queueFlags & VK_QUEUE_GRAPHICS_BIT); c->family++) {}
    if (c->family == qn) return XR_ERROR_RUNTIME_FAILURE;

    if (XR_FAILED(r = host_vk_exts(TRUE, p->instance, p->system, &list))) return r;
    n = ARRAY_SIZE(props);
    enum_dexts(c->physical_device, NULL, &n, props);
    uint32_t count = filter_exts(list, props, n, names, ARRAY_SIZE(names) - 2);
    const char *extra[] = {"VK_KHR_portability_subset", "VK_EXT_metal_objects", "VK_KHR_timeline_semaphore"};
    for (uint32_t i = 0; i < ARRAY_SIZE(extra); i++)
    {
        uint32_t j;
        for (j = 0; j < count && strcmp(names[j], extra[i]); j++) {}
        if (j == count && has_ext(props, n, extra[i]) && count < ARRAY_SIZE(names)) names[count++] = extra[i];
    }
    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, c->family, 1, &prio};
    VkPhysicalDeviceVulkan12Features f12 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES};
    f12.timelineSemaphore = VK_TRUE;
    VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &f12, 0, 1, &qci};
    dci.enabledExtensionCount = count;
    dci.ppEnabledExtensionNames = names;
    vr = create_device(c->physical_device, &dci, NULL, &c->device);
    free(list);
    if (vr)
    {
        snprintf(p->info, sizeof(p->info), "vkCreateDevice: %d", vr);
        return XR_ERROR_RUNTIME_FAILURE;
    }

#undef L
#define L(n) c->n = (PFN_##n)c->gipa(c->instance, #n);
    L(vkDestroyDevice) L(vkGetDeviceQueue) L(vkCreateImage) L(vkDestroyImage) L(vkGetImageMemoryRequirements)
    L(vkAllocateMemory) L(vkFreeMemory) L(vkBindImageMemory) L(vkCreateSemaphore) L(vkDestroySemaphore)
    L(vkCreateCommandPool) L(vkDestroyCommandPool) L(vkAllocateCommandBuffers) L(vkBeginCommandBuffer)
    L(vkEndCommandBuffer) L(vkResetCommandBuffer) L(vkCmdPipelineBarrier) L(vkCmdCopyImage) L(vkQueueSubmit)
    L(vkCreateFence) L(vkDestroyFence) L(vkWaitForFences) L(vkResetFences) L(vkDeviceWaitIdle)
    L(vkExportMetalObjectsEXT)
#undef L
    c->vkGetDeviceQueue(c->device, c->family, 0, &c->queue);

    if (c->vkExportMetalObjectsEXT)
    {
        VkExportMetalDeviceInfoEXT dev = {VK_STRUCTURE_TYPE_EXPORT_METAL_DEVICE_INFO_EXT};
        VkExportMetalObjectsInfoEXT exp = {VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT, &dev};
        c->vkExportMetalObjectsEXT(c->device, &exp);
        c->mtl = [dev.mtlDevice retain];
    }
    if (!c->mtl) c->mtl = MTLCreateSystemDefaultDevice();

    VkCommandPoolCreateInfo pci = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, NULL,
                                   VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, c->family};
    VkCommandBufferAllocateInfo cai = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, 0,
                                       VK_COMMAND_BUFFER_LEVEL_PRIMARY, RING};
    VkFenceCreateInfo fci = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, NULL, VK_FENCE_CREATE_SIGNALED_BIT};
    if (c->vkCreateCommandPool(c->device, &pci, NULL, &c->pool)) return XR_ERROR_RUNTIME_FAILURE;
    cai.commandPool = c->pool;
    if (c->vkAllocateCommandBuffers(c->device, &cai, c->cmd)) return XR_ERROR_RUNTIME_FAILURE;
    for (uint32_t i = 0; i < RING; i++)
        if (c->vkCreateFence(c->device, &fci, NULL, &c->fence[i])) return XR_ERROR_RUNTIME_FAILURE;

    p->vk_instance = (uint64_t)(uintptr_t)c->instance;
    p->vk_physical_device = (uint64_t)(uintptr_t)c->physical_device;
    p->vk_device = (uint64_t)(uintptr_t)c->device;
    p->queue_family = c->family;
    p->queue_index = 0;
    snprintf(p->info, sizeof(p->info), "Vulkan device on %s, %u instance + %u device extensions", mvk,
             ici.enabledExtensionCount, count);
    return XR_SUCCESS;
}

NTSTATUS bridge_dxmt_create_device(void *args)
{
    struct dxmt_create_device_params *p = args;
    struct dxmt_ctx *c = calloc(1, sizeof(*c));
    @autoreleasepool
    {
        p->result = create_ctx(p, c);
    }
    if (XR_FAILED(p->result))
        destroy_ctx(c);
    else
        p->ctx = (uint64_t)(uintptr_t)c;
    return 0;
}

NTSTATUS bridge_dxmt_destroy_device(void *args)
{
    struct dxmt_destroy_device_params *p = args;
    if (p->ctx) destroy_ctx((struct dxmt_ctx *)(uintptr_t)p->ctx);
    return 0;
}

static mach_port_t look_up(const char *name)
{
    mach_port_t port = MACH_PORT_NULL;
    if (bootstrap_look_up(bootstrap_port, name, &port) != KERN_SUCCESS) return MACH_PORT_NULL;
    return port;
}

static void destroy_image(struct dxmt_ctx *c, struct dxmt_image *img)
{
    if (img->semaphore) c->vkDestroySemaphore(c->device, img->semaphore, NULL);
    if (img->image) c->vkDestroyImage(c->device, img->image, NULL);
    if (img->memory) c->vkFreeMemory(c->device, img->memory, NULL);
    free(img);
}

static XrResult import_image(struct dxmt_import_image_params *p, struct dxmt_ctx *c, struct dxmt_image *img)
{
    mach_port_t port = look_up(p->texture_name);
    if (!MACH_PORT_VALID(port))
    {
        snprintf(p->info, sizeof(p->info), "bootstrap_look_up %s failed", p->texture_name);
        return XR_ERROR_RUNTIME_FAILURE;
    }
    MTLSharedTextureHandle *handle = [[MTLSharedTextureHandle alloc] initWithMachPort:port];
    id<MTLTexture> tex = handle ? [c->mtl newSharedTextureWithHandle:handle] : nil;
    [handle release];
    if (!tex)
    {
        snprintf(p->info, sizeof(p->info), "newSharedTextureWithHandle failed for %s", p->texture_name);
        return XR_ERROR_RUNTIME_FAILURE;
    }

    VkImportMetalTextureInfoEXT import = {VK_STRUCTURE_TYPE_IMPORT_METAL_TEXTURE_INFO_EXT, NULL, VK_IMAGE_ASPECT_PLANE_0_BIT, tex};
    VkImageCreateInfo ci = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, &import};
    ci.imageType = VK_IMAGE_TYPE_2D;
    ci.format = (VkFormat)p->vk_format;
    ci.extent = (VkExtent3D){p->width, p->height, 1};
    ci.mipLevels = p->mips;
    ci.arrayLayers = p->layers;
    ci.samples = VK_SAMPLE_COUNT_1_BIT;
    ci.tiling = VK_IMAGE_TILING_OPTIMAL;
    ci.usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    VkResult vr = c->vkCreateImage(c->device, &ci, NULL, &img->image);
    [tex release];
    if (!vr)
    {
        VkMemoryRequirements req;
        c->vkGetImageMemoryRequirements(c->device, img->image, &req);
        VkMemoryAllocateInfo ai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, NULL, req.size, __builtin_ctz(req.memoryTypeBits)};
        vr = c->vkAllocateMemory(c->device, &ai, NULL, &img->memory);
        if (!vr) vr = c->vkBindImageMemory(c->device, img->image, img->memory, 0);
    }
    if (vr)
    {
        snprintf(p->info, sizeof(p->info), "vkCreateImage with VkImportMetalTextureInfoEXT: %d", vr);
        return XR_ERROR_RUNTIME_FAILURE;
    }

    if (p->event_name[0])
    {
        port = look_up(p->event_name);
        id<MTLSharedEvent> event = nil;
        if (MACH_PORT_VALID(port) && [c->mtl respondsToSelector:@selector(newSharedEventWithMachPort:)])
            event = [(id<MacvrMTLDeviceSPI>)c->mtl newSharedEventWithMachPort:port];
        if (!event)
        {
            snprintf(p->info, sizeof(p->info), "keyed mutex event %s not importable", p->event_name);
            return XR_ERROR_RUNTIME_FAILURE;
        }
        VkImportMetalSharedEventInfoEXT ev = {VK_STRUCTURE_TYPE_IMPORT_METAL_SHARED_EVENT_INFO_EXT, NULL, event};
        /* MoltenVK sets signaledValue to initialValue on import. */
        VkSemaphoreTypeCreateInfo type = {VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO, &ev, VK_SEMAPHORE_TYPE_TIMELINE,
                                          event.signaledValue};
        VkSemaphoreCreateInfo sci = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, &type};
        vr = c->vkCreateSemaphore(c->device, &sci, NULL, &img->semaphore);
        [event release];
        if (vr)
        {
            snprintf(p->info, sizeof(p->info), "timeline semaphore from MTLSharedEvent: %d", vr);
            return XR_ERROR_RUNTIME_FAILURE;
        }
    }
    img->width = p->width;
    img->height = p->height;
    img->layers = p->layers;
    img->mips = p->mips;
    return XR_SUCCESS;
}

NTSTATUS bridge_dxmt_import_image(void *args)
{
    struct dxmt_import_image_params *p = args;
    struct dxmt_ctx *c = (struct dxmt_ctx *)(uintptr_t)p->ctx;
    struct dxmt_image *img = calloc(1, sizeof(*img));
    @autoreleasepool
    {
        p->result = import_image(p, c, img);
    }
    if (XR_FAILED(p->result))
        destroy_image(c, img);
    else
        p->image = (uint64_t)(uintptr_t)img;
    return 0;
}

NTSTATUS bridge_dxmt_destroy_image(void *args)
{
    struct dxmt_destroy_image_params *p = args;
    struct dxmt_ctx *c = (struct dxmt_ctx *)(uintptr_t)p->ctx;
    if (!p->image) return 0;
    c->vkDeviceWaitIdle(c->device);
    destroy_image(c, (struct dxmt_image *)(uintptr_t)p->image);
    return 0;
}

/* Runs inside the PE side's queue lock, before the host xrReleaseSwapchainImage, which submits Monado's release
 * barrier and its timeline signal on the same queue. */
NTSTATUS bridge_dxmt_copy(void *args)
{
    struct dxmt_copy_params *p = args;
    struct dxmt_ctx *c = (struct dxmt_ctx *)(uintptr_t)p->ctx;
    struct dxmt_image *img = (struct dxmt_image *)(uintptr_t)p->image;
    uint32_t slot = c->next++ % RING;
    VkCommandBuffer cb = c->cmd[slot];
    VkImageMemoryBarrier bars[DXMT_MAX_SLICES + 1];

    uint64_t t0, t1;

    p->result = XR_ERROR_RUNTIME_FAILURE;
    if (p->slices > DXMT_MAX_SLICES || p->slices > img->layers) return 0;
    t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    c->vkWaitForFences(c->device, 1, &c->fence[slot], VK_TRUE, UINT64_MAX);
    p->fence_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0;
    c->vkResetFences(c->device, 1, &c->fence[slot]);
    c->vkResetCommandBuffer(cb, 0);
    VkCommandBufferBeginInfo bi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL, VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
    c->vkBeginCommandBuffer(cb, &bi);

    /* Monado's images are COLOR_ATTACHMENT_OPTIMAL between wait and release (XR_KHR_vulkan_enable). */
    bars[0] = (VkImageMemoryBarrier){VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL, 0, VK_ACCESS_TRANSFER_READ_BIT,
                                     VK_IMAGE_LAYOUT_GENERAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_QUEUE_FAMILY_IGNORED,
                                     VK_QUEUE_FAMILY_IGNORED, img->image,
                                     {VK_IMAGE_ASPECT_COLOR_BIT, 0, img->mips, 0, img->layers}};
    for (uint32_t s = 0; s < p->slices; s++)
        bars[s + 1] = (VkImageMemoryBarrier){VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                                             VK_ACCESS_TRANSFER_WRITE_BIT, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                                             VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_QUEUE_FAMILY_IGNORED,
                                             VK_QUEUE_FAMILY_IGNORED, (VkImage)(uintptr_t)p->dst[s],
                                             {VK_IMAGE_ASPECT_COLOR_BIT, 0, img->mips, 0, 1}};
    c->vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL,
                            p->slices + 1, bars);
    for (uint32_t s = 0; s < p->slices; s++)
        for (uint32_t m = 0; m < img->mips; m++)
        {
            uint32_t w = img->width >> m, h = img->height >> m;
            VkImageCopy region = {{VK_IMAGE_ASPECT_COLOR_BIT, m, s, 1}, {0, 0, 0},
                                  {VK_IMAGE_ASPECT_COLOR_BIT, m, 0, 1}, {0, 0, 0},
                                  {w ? w : 1, h ? h : 1, 1}};
            if (img->mips == 1 && p->rect[s][2] > 0)
            {
                region.srcOffset = region.dstOffset = (VkOffset3D){p->rect[s][0], p->rect[s][1], 0};
                region.extent = (VkExtent3D){p->rect[s][2], p->rect[s][3], 1};
            }
            c->vkCmdCopyImage(cb, img->image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, (VkImage)(uintptr_t)p->dst[s],
                              VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
        }
    for (uint32_t s = 0; s < p->slices + 1; s++)
    {
        VkImageLayout old = bars[s].oldLayout;
        bars[s].srcAccessMask = bars[s].dstAccessMask;
        bars[s].dstAccessMask = s ? VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT : 0;
        bars[s].oldLayout = bars[s].newLayout;
        bars[s].newLayout = old;
    }
    c->vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, NULL, 0, NULL,
                            p->slices + 1, bars);
    c->vkEndCommandBuffer(cb);

    VkPipelineStageFlags stage = VK_PIPELINE_STAGE_TRANSFER_BIT;
    VkTimelineSemaphoreSubmitInfo tl = {VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO, NULL, 1, &p->wait_value, 1,
                                        &p->signal_value};
    VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL, 0, NULL, &stage, 1, &cb};
    if (img->semaphore && p->wait_value)
    {
        si.pNext = &tl;
        si.waitSemaphoreCount = 1;
        si.pWaitSemaphores = &img->semaphore;
        si.signalSemaphoreCount = 1;
        si.pSignalSemaphores = &img->semaphore;
    }
    t1 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (!c->vkQueueSubmit(c->queue, 1, &si, c->fence[slot])) p->result = XR_SUCCESS;
    p->submit_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t1;
    return 0;
}

NTSTATUS bridge_unsupported_device(void *args)
{
    struct unsupported_device_params *p = args;
    const char *dir = getenv("STEAM_COMPAT_INSTALL_PATH"), *backend = getenv("CX_GRAPHICS_BACKEND"), *slash;
    char game[256] = "This game";
    CFOptionFlags response = kCFUserNotificationDefaultResponse;

    if (dir && (slash = strrchr(dir, '/')) && slash[1]) snprintf(game, sizeof(game), "%s", slash + 1);
    @autoreleasepool
    {
        NSString *header = [NSString stringWithFormat:@"%s can't run in VR with this graphics backend", game];
        NSString *text = [NSString stringWithFormat:
            @"MacVR needs DXMT or DXVK, but the game started with %s.\n\n"
            @"In Steam, open the game's Properties → Compatibility and set Graphics to DXMT or DXVK.\n\n"
            @"Run Anyway continues, and the game's VR start-up will fail.",
            backend && *backend ? backend : "Automatic (CrossOver's choice)"];
        CFUserNotificationDisplayAlert(0, kCFUserNotificationCautionAlertLevel, NULL, NULL, NULL, (__bridge CFStringRef)header,
                                       (__bridge CFStringRef)text, CFSTR("Quit Game"), CFSTR("Run Anyway"), NULL, &response);
    }
    p->run_anyway = (response & 3) == kCFUserNotificationAlternateResponse;
    return 0;
}
