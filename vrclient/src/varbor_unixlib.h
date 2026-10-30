/* VarboR's own unix calls, appended to Proton's table (unixlib_generated.h/.cpp). Plain fixed-size fields: the PE side
 * builds against mingw's headers and the unix side against Wine's. */
#pragma once
#include <stdint.h>

/* Import a DXMT shared texture (and its keyed mutex's MTLSharedEvent) by bootstrap name. */
struct varbor_dxmt_import_params
{
    char texture_name[64];
    char event_name[64];
    uint64_t image;   /* out: unix-side handle */
    uint64_t texture; /* out: the id<MTLTexture>, what TextureType_Metal submits carry */
    char info[256];
};

/* Before the runtime's call on the image. gpu: when OpenComposite has oc_metal_submit_sync_begin, arm its copy to wait
 * on the GPU for the image's event to reach value and signal value + 1 after it, or (no event) to signal the image's
 * own idle event; out: 1 when armed. Otherwise a CPU wait until the image's event reaches value. */
struct varbor_dxmt_wait_params
{
    uint64_t image;
    uint64_t value;
    uint32_t timeout_ms;
    int32_t result; /* 0 reached, 1 timeout, -1 no event */
    uint64_t wait_ns;
    uint32_t gpu;
};

/* After the runtime's call: disarms OpenComposite's sync; taken = its copy took it (the signal is coming). */
struct varbor_dxmt_end_params
{
    uint64_t image;
    int32_t taken;
};

/* CPU wait until the runtime's last armed copy of the image is done, before the image is written again. */
struct varbor_dxmt_idle_params
{
    uint64_t image;
    uint32_t timeout_ms;
    int32_t result; /* 0 idle, 1 timeout */
    uint64_t wait_ns;
};

struct varbor_dxmt_destroy_params
{
    uint64_t image;
};

/* VarboR DXMT interop (IDXMTInteropSurface): the runtime gets the game's own id<MTLTexture>. begin, before the
 * runtime's call: arms OpenComposite's copy to wait on the GPU for event >= value (DXMT's FlushRenderingCommands) and
 * to signal the bridge's own event for device at signal_value after it; gpu = 0 when OpenComposite lacks
 * oc_metal_submit_sync (or VRCLIENT_DXMT_GPU_SYNC=0), nothing armed. end, after it: taken = its copy took the sync,
 * so DXMT has to wait for signal_event >= signal_value before writing the texture again. */
struct varbor_dxmt_direct_params
{
    uint64_t device;
    uint64_t event;
    uint64_t value;
    uint32_t gpu;
    int32_t taken;
    uint64_t signal_event;
    uint64_t signal_value;
};

/* Vulkan images (DXVK's through IDXGIVkInteropSurface, or a Vulkan game's) as Metal textures for the runtime
 * (vk_unix.mm). Handles are the PE side's (winevulkan client) ones; the image is in TRANSFER_SRC_OPTIMAL with its
 * writes submitted to queue, which nobody else submits to until varbor_vk_end. begin hands over the image's own
 * MTLTexture (vkExportMetalObjectsEXT) or copies it into a ring slot of the target (copy = 1, or the runtime can't read
 * the image as is), signals the bridge's ready semaphore on queue and arms OpenComposite's copy to wait for it on the
 * GPU and to signal the done semaphore after it (no oc_metal_submit_sync: a CPU wait instead, and always the copy).
 * target: 0/1 eye, 2 overlay (target_id its handle). */
struct varbor_vk_begin_params
{
    uint64_t device, physical_device, queue, image;
    uint32_t queue_family, format, width, height, samples, slice, target;
    uint64_t target_id;
    uint32_t copy;
    uint64_t texture; /* out: id<MTLTexture>, 0 on failure */
    uint32_t path;    /* out: 1 direct, 2 copy */
    uint32_t gpu;     /* out: OpenComposite's copy syncs on the GPU */
    char info[256];
};

/* After the runtime's call: disarms OpenComposite's sync. Direct path with the sync taken: queue waits for
 * OpenComposite's copy before any later work on it, so the game can't write the image under the copy. */
struct varbor_vk_end_params
{
    int32_t taken;
};

/* Native runtime the unix side loaded (or would load), for the PE side's log. */
struct varbor_runtime_info_params
{
    char path[1024];
};

/* IVRInputInternal_002 (undocumented): slot index on the native object, the first three integer arguments after this,
 * the 64-bit return value. */
struct varbor_input_internal_params
{
    uint64_t u_iface;
    uint32_t index;
    uint64_t a, b, c;
    uint64_t _ret;
};
