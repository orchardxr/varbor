/* Unix side of the DXVK interop probe: unwraps winevulkan handles and works on DXVK's host VkDevice
 * through the MoltenVK that CrossOver's win32u already loaded. */
#define VK_USE_PLATFORM_METAL_EXT
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#include <vulkan/vulkan.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include "probe.h"

typedef int NTSTATUS;
typedef NTSTATUS (*unixlib_entry_t)(void *);

static PFN_vkGetInstanceProcAddr gipa;
static PFN_vkGetDeviceProcAddr gdpa;
static VkInstance host_instance;
static VkPhysicalDevice host_physdev;
static VkDevice host_device;
static VkQueue host_queue;
static IOSurfaceRef surface;
static id<MTLSharedEvent> event;
static VkSemaphore semaphore;

/* PE dispatchable handle -> struct vulkan_client_object { loader_magic; unix_handle } -> struct vulkan_object { host_handle; ... } */
static uint64_t unwrap(uint64_t pe)
{
    uint64_t unix_obj = ((uint64_t *)(uintptr_t)pe)[1];
    return *(uint64_t *)(uintptr_t)unix_obj;
}

static int is_icd_object(uint64_t host)
{
    return host && *(uint64_t *)(uintptr_t)host == 0x01CDC0DE;
}

static NTSTATUS probe_init(void *a)
{
    struct probe_init *p = a;
    const char *mvk = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++)
        if (strstr(_dyld_get_image_name(i), "libMoltenVK")) { mvk = _dyld_get_image_name(i); break; }
    void *h = mvk ? dlopen(mvk, RTLD_NOW | RTLD_NOLOAD) : NULL;
    gipa = h ? (PFN_vkGetInstanceProcAddr)dlsym(h, "vkGetInstanceProcAddr") : NULL;
    host_instance = (VkInstance)(uintptr_t)(p->host_instance = unwrap(p->pe_instance));
    host_physdev = (VkPhysicalDevice)(uintptr_t)(p->host_physdev = unwrap(p->pe_physdev));
    host_device = (VkDevice)(uintptr_t)(p->host_device = unwrap(p->pe_device));
    host_queue = (VkQueue)(uintptr_t)(p->host_queue = unwrap(p->pe_queue));
    int magic = is_icd_object(p->host_instance) && is_icd_object(p->host_physdev) && is_icd_object(p->host_device) &&
                is_icd_object(p->host_queue);
    gdpa = gipa ? (PFN_vkGetDeviceProcAddr)gipa(host_instance, "vkGetDeviceProcAddr") : NULL;
    snprintf(p->info, sizeof(p->info), "MoltenVK image %s, gipa %p, gdpa %p, ICD magic on all 4 host handles: %s",
             mvk ? mvk : "(not loaded)", gipa, gdpa, magic ? "yes" : "no");
    if (gipa)
    {
        PFN_vkGetPhysicalDeviceProperties props = (PFN_vkGetPhysicalDeviceProperties)gipa(host_instance, "vkGetPhysicalDeviceProperties");
        VkPhysicalDeviceProperties pr;
        props(host_physdev, &pr);
        size_t l = strlen(p->info);
        snprintf(p->info + l, sizeof(p->info) - l, "; host physdev '%s' driver %#x api %u.%u.%u", pr.deviceName, pr.driverVersion,
                 VK_VERSION_MAJOR(pr.apiVersion), VK_VERSION_MINOR(pr.apiVersion), VK_VERSION_PATCH(pr.apiVersion));
    }
    p->status = (gipa && gdpa && magic) ? 0 : 1;
    return 0;
}

#define DF(name) PFN_##name name = (PFN_##name)gdpa(host_device, #name)

static NTSTATUS probe_import_image(void *a)
{
    struct probe_image *p = a;
    DF(vkCreateImage); DF(vkGetImageMemoryRequirements); DF(vkAllocateMemory); DF(vkBindImageMemory);
    DF(vkCreateSemaphore);
    NSDictionary *props = @{
        (id)kIOSurfaceWidth : @(p->width), (id)kIOSurfaceHeight : @(p->height), (id)kIOSurfaceBytesPerElement : @4,
        (id)kIOSurfaceBytesPerRow : @(IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, p->width * 4)),
        (id)kIOSurfacePixelFormat : @((uint32_t)'BGRA'),
    };
    surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    VkImportMetalIOSurfaceInfoEXT import = {VK_STRUCTURE_TYPE_IMPORT_METAL_IO_SURFACE_INFO_EXT, NULL, surface};
    VkImageCreateInfo ci = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, &import};
    ci.imageType = VK_IMAGE_TYPE_2D;
    ci.format = VK_FORMAT_B8G8R8A8_UNORM;
    ci.extent = (VkExtent3D){p->width, p->height, 1};
    ci.mipLevels = 1;
    ci.arrayLayers = 1;
    ci.samples = VK_SAMPLE_COUNT_1_BIT;
    ci.tiling = VK_IMAGE_TILING_OPTIMAL;
    ci.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
               VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    VkImage image;
    VkResult r = vkCreateImage(host_device, &ci, NULL, &image);
    if (r) { snprintf(p->info, sizeof(p->info), "vkCreateImage %d", r); p->status = 1; return 0; }
    VkMemoryRequirements req;
    vkGetImageMemoryRequirements(host_device, image, &req);
    VkMemoryAllocateInfo ai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, NULL, req.size, __builtin_ctz(req.memoryTypeBits)};
    VkDeviceMemory mem;
    if ((r = vkAllocateMemory(host_device, &ai, NULL, &mem)) || (r = vkBindImageMemory(host_device, image, mem, 0)))
    { snprintf(p->info, sizeof(p->info), "alloc/bind %d", r); p->status = 1; return 0; }
    p->image = (uint64_t)(uintptr_t)image;

    /* Stands in for the MTLSharedEvent Monado's service exports for the client's timeline semaphore. */
    event = [MTLCreateSystemDefaultDevice() newSharedEvent];
    VkImportMetalSharedEventInfoEXT ev_import = {VK_STRUCTURE_TYPE_IMPORT_METAL_SHARED_EVENT_INFO_EXT, NULL, event};
    VkSemaphoreTypeCreateInfo type = {VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO, &ev_import, VK_SEMAPHORE_TYPE_TIMELINE, 0};
    VkSemaphoreCreateInfo si = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, &type};
    r = vkCreateSemaphore(host_device, &si, NULL, &semaphore);
    snprintf(p->info, sizeof(p->info), "IOSurface %u, image %#llx, mem %llu bytes type %u, timeline semaphore %d",
             IOSurfaceGetID(surface), (unsigned long long)p->image, (unsigned long long)req.size, ai.memoryTypeIndex, r);
    p->status = r ? 1 : 0;
    return 0;
}

static NTSTATUS probe_submit_signal(void *a)
{
    struct probe_submit *p = a;
    DF(vkQueueSubmit);
    VkTimelineSemaphoreSubmitInfo ts = {VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO, NULL, 0, NULL, 1, &p->value};
    VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, &ts};
    si.signalSemaphoreCount = 1;
    si.pSignalSemaphores = &semaphore;
    VkResult r = vkQueueSubmit(host_queue, 1, &si, VK_NULL_HANDLE);
    snprintf(p->info, sizeof(p->info), "vkQueueSubmit(signal %llu) on DXVK's host queue: %d", (unsigned long long)p->value, r);
    p->status = r ? 1 : 0;
    return 0;
}

static uint64_t now_ns(void)
{
    struct timespec t;
    clock_gettime(CLOCK_UPTIME_RAW, &t);
    return t.tv_sec * 1000000000ull + t.tv_nsec;
}

static NTSTATUS probe_wait_read(void *a)
{
    struct probe_read *p = a;
    uint64_t t0 = now_ns();
    while (event.signaledValue < p->value && now_ns() - t0 < 2000000000ull)
        usleep(100);
    p->waited_ns = now_ns() - t0;
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    p->pixel = *(uint32_t *)((char *)IOSurfaceGetBaseAddress(surface) + p->y * IOSurfaceGetBytesPerRow(surface) + p->x * 4);
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    p->status = event.signaledValue >= p->value ? 0 : 1;
    return 0;
}

int mti_run_cases(PFN_vkGetInstanceProcAddr, VkInstance, VkDevice, VkQueue);

/* Step 5 check on DXVK's device; the PE side holds the submission lock. Prints PASS/FAIL lines itself. */
static NTSTATUS probe_metal_texture(void *a)
{
    *(int32_t *)a = mti_run_cases(gipa, host_instance, host_device, host_queue);
    return 0;
}

NTSTATUS xrprobe_init(void *);
NTSTATUS xrprobe_begin(void *);
NTSTATUS xrprobe_end(void *);
NTSTATUS xrprobe_shutdown(void *);

const unixlib_entry_t __wine_unix_call_funcs[] = {probe_init, probe_import_image, probe_submit_signal, probe_wait_read,
                                                  xrprobe_init, xrprobe_begin, xrprobe_end, xrprobe_shutdown,
                                                  probe_metal_texture};
