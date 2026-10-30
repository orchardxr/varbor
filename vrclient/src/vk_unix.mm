/* Unix side of the Vulkan submit path (vk_pe.c): Vulkan images on the game's device (DXVK's, or a Vulkan game's) as
 * Metal textures for OpenComposite's Metal compositor. CrossOver's winevulkan runs on MoltenVK without a loader, so
 * the host handles are MoltenVK's and its own exports are called directly, extension enabled on the device or not
 * (MoltenVK doesn't check): vkExportMetalObjectsEXT gives the image's MTLTexture and the MTLSharedEvents of two
 * timeline semaphores, `ready` (signalled on the game's queue after the image's writes, or after the bridge's copy)
 * and `done` (signalled by OpenComposite's copy, oc_metal_submit_sync). Each has a single signaller, so both only move
 * forward.
 *   direct: OpenComposite reads the game's image. Its copy waits for ready, signals done; once it took the sync the
 *           game's queue waits for done before any later work, so nothing writes the image under the copy.
 *   copy:   a vkCmdCopyImage (or resolve) into a ring slot of the target on the game's queue, then the same sync; a
 *           slot's next copy waits for its last done on the GPU. Overlays, images the runtime can't read as is, no
 *           VK_EXT_metal_objects texture, no oc_metal_submit_sync (CPU wait for ready instead), VRCLIENT_VK_DIRECT=0.
 * No Wine headers here: their BOOL clashes with Objective-C's. */
#define VK_USE_PLATFORM_METAL_EXT
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <vulkan/vulkan.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "varbor_unixlib.h"

typedef int NTSTATUS;

extern "C" bool varbor_oc_sync( void (**begin)( void *, uint64_t, void *, uint64_t ), int (**end)( void ) );

#define RING 3
#define OVERLAYS 16
#define TIMEOUT_NS 1000000000ull

#define VK_FUNCS \
    X(vkCreateSemaphore) X(vkQueueSubmit) X(vkExportMetalObjectsEXT) X(vkCreateImage) X(vkDestroyImage) \
    X(vkGetImageMemoryRequirements) X(vkAllocateMemory) X(vkFreeMemory) X(vkBindImageMemory) X(vkCreateCommandPool) \
    X(vkAllocateCommandBuffers) X(vkFreeCommandBuffers) X(vkBeginCommandBuffer) X(vkEndCommandBuffer) \
    X(vkCmdPipelineBarrier) X(vkCmdCopyImage) X(vkCmdResolveImage) X(vkGetPhysicalDeviceMemoryProperties) \
    X(vkWaitSemaphores)

static struct
{
    int loaded;
    char path[512];
#define X(n) PFN_##n n;
    VK_FUNCS
#undef X
} vk = {-1};

/* The MoltenVK winevulkan loaded: the one in the runner (CX_ROOT) if a Vulkan loader brought in another. */
static bool load_moltenvk( char *info, size_t size )
{
    const char *cx = getenv( "CX_ROOT"), *best = NULL;
    int best_score = -1;
    void *lib;

    if (vk.loaded >= 0) return vk.loaded;
    vk.loaded = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++)
    {
        const char *name = _dyld_get_image_name( i );
        int score;
        if (!name || !strstr( name, "libMoltenVK" )) continue;
        score = cx && *cx && !strncmp( name, cx, strlen( cx ) ) ? 2 : strstr( name, "/CrossOver/" ) ? 1 : 0;
        if (score > best_score)
        {
            best = name;
            best_score = score;
        }
    }
    if (!best || !(lib = dlopen( best, RTLD_NOW | RTLD_NOLOAD )))
    {
        snprintf( info, size, "MoltenVK is not loaded" );
        return false;
    }
    snprintf( vk.path, sizeof(vk.path), "%s", best );
#define X(n) vk.n = (PFN_##n)dlsym( lib, #n );
    VK_FUNCS
#undef X
    if (!vk.vkWaitSemaphores) vk.vkWaitSemaphores = (PFN_vkWaitSemaphores)dlsym( lib, "vkWaitSemaphoresKHR" );
#define X(n) if (!vk.n) { snprintf( info, size, "%s has no %s", best, #n ); return false; }
    VK_FUNCS
#undef X
    vk.loaded = 1;
    return true;
}

/* winevulkan's client handle -> host handle: vulkan_client_object.unix_handle points at the object's vulkan_object,
 * whose first member is the host handle (wine/vulkan_driver.h). */
template< typename T > static T host( uint64_t client )
{
    uint64_t object = client ? ((const uint64_t *)(uintptr_t)client)[1] : 0;
    return object ? (T)(uintptr_t)*(const uint64_t *)(uintptr_t)object : (T)0;
}

struct slot
{
    VkImage image;
    VkDeviceMemory memory;
    VkCommandBuffer cmd;
    id<MTLTexture> texture;
    uint64_t copied; /* ready value of its last copy */
    uint64_t done;   /* done value of the runtime's last copy from it */
};

struct target
{
    uint64_t id;
    VkFormat format;
    uint32_t width, height;
    struct slot ring[RING];
    unsigned int next;
};

static struct
{
    VkDevice device;
    VkPhysicalDevice physical_device;
    uint32_t family;
    VkSemaphore ready, done;
    id<MTLSharedEvent> ready_event, done_event;
    uint64_t ready_value, done_value;
    VkCommandPool pool;
    VkPhysicalDeviceMemoryProperties memory;
    struct target eyes[2], overlays[OVERLAYS];
} dev;

/* Between begin and end (the PE side's lock) */
static struct
{
    bool armed, direct;
    uint64_t done_value;
    struct slot *slot;
    VkQueue queue;
} cur;

static void (*oc_begin)( void *, uint64_t, void *, uint64_t );
static int (*oc_end)( void );

static VkSemaphore timeline( id<MTLSharedEvent> *event )
{
    VkExportMetalObjectCreateInfoEXT export_info = {VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECT_CREATE_INFO_EXT, NULL,
                                                    VK_EXPORT_METAL_OBJECT_TYPE_METAL_SHARED_EVENT_BIT_EXT};
    VkSemaphoreTypeCreateInfo type = {VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO, &export_info,
                                      VK_SEMAPHORE_TYPE_TIMELINE, 0};
    VkSemaphoreCreateInfo create = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, &type};
    VkExportMetalSharedEventInfoEXT shared = {VK_STRUCTURE_TYPE_EXPORT_METAL_SHARED_EVENT_INFO_EXT};
    VkExportMetalObjectsInfoEXT objects = {VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT, &shared};
    VkSemaphore sem = VK_NULL_HANDLE;

    *event = nil;
    if (vk.vkCreateSemaphore( dev.device, &create, NULL, &sem ) != VK_SUCCESS) return VK_NULL_HANDLE;
    shared.semaphore = sem;
    vk.vkExportMetalObjectsEXT( dev.device, &objects );
    *event = shared.mtlSharedEvent;
    return *event ? sem : VK_NULL_HANDLE;
}

static id<MTLTexture> image_texture( VkImage image )
{
    VkExportMetalTextureInfoEXT texture = {VK_STRUCTURE_TYPE_EXPORT_METAL_TEXTURE_INFO_EXT, NULL, image,
                                           VK_NULL_HANDLE, VK_NULL_HANDLE, VK_IMAGE_ASPECT_PLANE_0_BIT};
    VkExportMetalObjectsInfoEXT objects = {VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT, &texture};
    vk.vkExportMetalObjectsEXT( dev.device, &objects );
    return texture.mtlTexture;
}

static bool device_init( VkDevice device, VkPhysicalDevice physical_device, uint32_t family, char *info, size_t size )
{
    VkCommandPoolCreateInfo pool = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, NULL,
                                    VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, family};

    if (dev.device == device && dev.family == family) return dev.ready && dev.done && dev.pool;
    /* A new device (or queue family): the old one's objects went with it, or are leaked */
    memset( &dev, 0, sizeof(dev) );
    dev.device = device;
    dev.physical_device = physical_device;
    dev.family = family;
    vk.vkGetPhysicalDeviceMemoryProperties( physical_device, &dev.memory );
    dev.ready = timeline( &dev.ready_event );
    dev.done = timeline( &dev.done_event );
    if (!dev.ready || !dev.done)
    {
        snprintf( info, size, "no MTLSharedEvent from a timeline semaphore" );
        return false;
    }
    if (vk.vkCreateCommandPool( device, &pool, NULL, &dev.pool ) != VK_SUCCESS)
    {
        snprintf( info, size, "vkCreateCommandPool failed" );
        return false;
    }
    return true;
}

static VkResult submit( VkQueue queue, VkCommandBuffer cmd, VkSemaphore wait, uint64_t wait_value, VkSemaphore signal,
                        uint64_t signal_value )
{
    VkPipelineStageFlags stage = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
    VkTimelineSemaphoreSubmitInfo values = {VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO, NULL, wait ? 1u : 0u,
                                            &wait_value, signal ? 1u : 0u, &signal_value};
    VkSubmitInfo info = {VK_STRUCTURE_TYPE_SUBMIT_INFO, &values, wait ? 1u : 0u, &wait, &stage, cmd ? 1u : 0u, &cmd,
                         signal ? 1u : 0u, &signal};
    return vk.vkQueueSubmit( queue, 1, &info, VK_NULL_HANDLE );
}

static VkResult wait_ready( uint64_t value )
{
    VkSemaphoreWaitInfo info = {VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO, NULL, 0, 1, &dev.ready, &value};
    return vk.vkWaitSemaphores( dev.device, &info, TIMEOUT_NS );
}

static void destroy_slot( struct slot *s )
{
    if (s->copied) wait_ready( s->copied );
    if (s->cmd) vk.vkFreeCommandBuffers( dev.device, dev.pool, 1, &s->cmd );
    if (s->image) vk.vkDestroyImage( dev.device, s->image, NULL );
    if (s->memory) vk.vkFreeMemory( dev.device, s->memory, NULL );
    memset( s, 0, sizeof(*s) );
}

static bool create_slot( struct slot *s, const struct target *t )
{
    VkExportMetalObjectCreateInfoEXT export_info = {VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECT_CREATE_INFO_EXT, NULL,
                                                    VK_EXPORT_METAL_OBJECT_TYPE_METAL_TEXTURE_BIT_EXT};
    VkImageCreateInfo create = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, &export_info, 0, VK_IMAGE_TYPE_2D, t->format,
                                {t->width, t->height, 1}, 1, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_TILING_OPTIMAL,
                                VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
                                VK_SHARING_MODE_EXCLUSIVE, 0, NULL, VK_IMAGE_LAYOUT_UNDEFINED};
    VkCommandBufferAllocateInfo alloc_cmd = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, dev.pool,
                                             VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1};
    VkMemoryAllocateInfo alloc = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    VkMemoryRequirements req;
    uint32_t i;

    if (vk.vkCreateImage( dev.device, &create, NULL, &s->image ) != VK_SUCCESS) goto fail;
    vk.vkGetImageMemoryRequirements( dev.device, s->image, &req );
    for (i = 0; i < dev.memory.memoryTypeCount; i++)
        if ((req.memoryTypeBits & (1u << i))
            && (dev.memory.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) break;
    if (i == dev.memory.memoryTypeCount) goto fail;
    alloc.allocationSize = req.size;
    alloc.memoryTypeIndex = i;
    if (vk.vkAllocateMemory( dev.device, &alloc, NULL, &s->memory ) != VK_SUCCESS) goto fail;
    if (vk.vkBindImageMemory( dev.device, s->image, s->memory, 0 ) != VK_SUCCESS) goto fail;
    if (vk.vkAllocateCommandBuffers( dev.device, &alloc_cmd, &s->cmd ) != VK_SUCCESS) goto fail;
    if (!(s->texture = image_texture( s->image ))) goto fail;
    return true;
fail:
    destroy_slot( s );
    return false;
}

static struct target *target_for( uint32_t target, uint64_t id )
{
    struct target *t, *free_target = NULL;
    if (target < 2) return &dev.eyes[target];
    for (t = dev.overlays; t < dev.overlays + OVERLAYS; t++)
    {
        if (t->id == id && t->format) return t;
        if (!t->format && !free_target) free_target = t;
    }
    if (!free_target)
    {
        free_target = &dev.overlays[id % OVERLAYS];
        for (int i = 0; i < RING; i++) destroy_slot( &free_target->ring[i] );
        memset( free_target, 0, sizeof(*free_target) );
    }
    free_target->id = id;
    return free_target;
}

static void record_copy( struct slot *s, VkImage src, uint32_t slice, uint32_t width, uint32_t height, bool resolve )
{
    VkCommandBufferBeginInfo begin = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL,
                                      VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
    VkMemoryBarrier writes = {VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL, VK_ACCESS_MEMORY_WRITE_BIT,
                              VK_ACCESS_TRANSFER_READ_BIT};
    VkImageMemoryBarrier dst = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL, 0, VK_ACCESS_TRANSFER_WRITE_BIT,
                                VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                                VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, s->image,
                                {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    VkImageSubresourceLayers src_layers = {VK_IMAGE_ASPECT_COLOR_BIT, 0, slice, 1};
    VkImageSubresourceLayers dst_layers = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
    VkExtent3D extent = {width, height, 1};

    vk.vkBeginCommandBuffer( s->cmd, &begin );
    vk.vkCmdPipelineBarrier( s->cmd, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1,
                             &writes, 0, NULL, 1, &dst );
    if (resolve)
    {
        VkImageResolve region = {src_layers, {0, 0, 0}, dst_layers, {0, 0, 0}, extent};
        vk.vkCmdResolveImage( s->cmd, src, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, s->image,
                              VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region );
    }
    else
    {
        VkImageCopy region = {src_layers, {0, 0, 0}, dst_layers, {0, 0, 0}, extent};
        vk.vkCmdCopyImage( s->cmd, src, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, s->image,
                           VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region );
    }
    dst.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    dst.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    dst.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    dst.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    vk.vkCmdPipelineBarrier( s->cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, NULL,
                             0, NULL, 1, &dst );
    vk.vkEndCommandBuffer( s->cmd );
}

/* The runtime reads the game's image as is: one 2D (or the eye's slice of a 2D array) shader-readable texture */
static const char *direct_refusal( id<MTLTexture> tex, uint32_t slice, uint32_t target )
{
    if (tex.sampleCount > 1) return "multisampled";
    if (!(tex.usage & MTLTextureUsageShaderRead)) return "not shader-readable";
    if (tex.textureType == MTLTextureType2DArray ? slice != target : tex.textureType != MTLTextureType2D || slice)
        return "a slice the runtime doesn't read";
    return NULL;
}

extern "C" NTSTATUS varbor_vk_begin( void *args )
{
    struct varbor_vk_begin_params *p = (struct varbor_vk_begin_params *)args;
    VkImage image = (VkImage)(uintptr_t)p->image;
    VkDevice device = host<VkDevice>( p->device );
    VkQueue queue = host<VkQueue>( p->queue );
    VkPhysicalDevice physical_device = host<VkPhysicalDevice>( p->physical_device );
    const char *why = NULL;
    uint64_t ready;
    bool gpu;

    p->texture = 0;
    p->path = p->gpu = 0;
    p->info[0] = 0;
    memset( &cur, 0, sizeof(cur) );
    if (!device || !queue || !image)
    {
        snprintf( p->info, sizeof(p->info), "no Vulkan device, queue or image" );
        return 0;
    }
    if (!load_moltenvk( p->info, sizeof(p->info) )) return 0;
    if (!device_init( device, physical_device, p->queue_family, p->info, sizeof(p->info) )) return 0;
    gpu = varbor_oc_sync( &oc_begin, &oc_end );

    @autoreleasepool
    {
        id<MTLTexture> tex = image_texture( image );
        uint32_t slice = p->slice;
        if (slice == ~0u) slice = tex && tex.arrayLength > 1 && p->target < 2 ? p->target : 0;

        if (!tex) why = "no MTLTexture for the image";
        else if (p->copy) why = p->target < 2 ? "copy requested" : "overlay";
        else if (!gpu) why = "no oc_metal_submit_sync";
        else why = direct_refusal( tex, slice, p->target );

        if (!why)
        {
            ready = ++dev.ready_value;
            if (submit( queue, VK_NULL_HANDLE, VK_NULL_HANDLE, 0, dev.ready, ready ) != VK_SUCCESS)
            {
                snprintf( p->info, sizeof(p->info), "vkQueueSubmit (ready signal) failed" );
                return 0;
            }
            cur.done_value = ++dev.done_value;
            oc_begin( (void *)dev.ready_event, ready, (void *)dev.done_event, cur.done_value );
            cur.armed = cur.direct = true;
            cur.queue = queue;
            p->texture = (uint64_t)(uintptr_t)tex;
            p->path = 1;
            p->gpu = 1;
            snprintf( p->info, sizeof(p->info), "direct: the runtime reads the game's MTLTexture (%lux%lu MTLPixelFormat "
                      "%lu, VkFormat %u), synced on the GPU; MoltenVK %s", (unsigned long)tex.width,
                      (unsigned long)tex.height, (unsigned long)tex.pixelFormat, p->format, vk.path );
            return 0;
        }

        struct target *t = target_for( p->target, p->target_id );
        uint32_t layers = tex ? (uint32_t)tex.arrayLength : 1;
        if (slice >= layers) slice = 0;
        if (t->format != (VkFormat)p->format || t->width != p->width || t->height != p->height)
        {
            for (int i = 0; i < RING; i++) destroy_slot( &t->ring[i] );
            t->format = (VkFormat)p->format;
            t->width = p->width;
            t->height = p->height;
            t->next = 0;
        }
        struct slot *s = &t->ring[t->next++ % RING];
        if (!s->image && !create_slot( s, t ))
        {
            snprintf( p->info, sizeof(p->info), "copy (%s): no %ux%u VkFormat %u ring image", why, p->width,
                      p->height, p->format );
            return 0;
        }
        if (s->copied && wait_ready( s->copied ) != VK_SUCCESS)
        {
            snprintf( p->info, sizeof(p->info), "copy (%s): the slot's previous copy timed out", why );
            return 0;
        }
        record_copy( s, image, slice, p->width, p->height, p->samples > 1 );
        ready = ++dev.ready_value;
        if (submit( queue, s->cmd, s->done ? dev.done : VK_NULL_HANDLE, s->done, dev.ready, ready ) != VK_SUCCESS)
        {
            dev.ready_value--;
            snprintf( p->info, sizeof(p->info), "copy (%s): vkQueueSubmit failed", why );
            return 0;
        }
        s->copied = ready;
        if (gpu)
        {
            cur.done_value = ++dev.done_value;
            oc_begin( (void *)dev.ready_event, ready, (void *)dev.done_event, cur.done_value );
            cur.armed = true;
            cur.slot = s;
            p->gpu = 1;
        }
        else if (wait_ready( ready ) != VK_SUCCESS)
        {
            snprintf( p->info, sizeof(p->info), "copy (%s): CPU wait timed out", why );
            return 0;
        }
        p->texture = (uint64_t)(uintptr_t)s->texture;
        p->path = 2;
        snprintf( p->info, sizeof(p->info), "copy (%s): %ux%u VkFormat %u%s into a ring of %u (MTLPixelFormat %lu), "
                  "%s; MoltenVK %s", why, p->width, p->height, p->format, p->samples > 1 ? " resolved" : "", RING,
                  (unsigned long)s->texture.pixelFormat, gpu ? "synced on the GPU" : "CPU wait", vk.path );
    }
    return 0;
}

extern "C" NTSTATUS varbor_vk_end( void *args )
{
    struct varbor_vk_end_params *p = (struct varbor_vk_end_params *)args;

    p->taken = cur.armed && oc_end && oc_end();
    if (cur.armed)
    {
        /* An untaken done value is never signalled: hand it out again */
        if (!p->taken) dev.done_value--;
        else if (cur.direct) submit( cur.queue, VK_NULL_HANDLE, dev.done, cur.done_value, VK_NULL_HANDLE, 0 );
        else cur.slot->done = cur.done_value;
    }
    memset( &cur, 0, sizeof(cur) );
    return 0;
}
