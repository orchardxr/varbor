/* MacVR's own unix calls, appended to Proton's table (unixlib_generated.h/.cpp). Plain fixed-size fields: the PE side
 * builds against mingw's headers and the unix side against Wine's. */
#pragma once
#include <stdint.h>

/* Import a DXMT shared texture (and its keyed mutex's MTLSharedEvent) by bootstrap name. */
struct macvr_dxmt_import_params
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
struct macvr_dxmt_wait_params
{
    uint64_t image;
    uint64_t value;
    uint32_t timeout_ms;
    int32_t result; /* 0 reached, 1 timeout, -1 no event */
    uint64_t wait_ns;
    uint32_t gpu;
};

/* After the runtime's call: disarms OpenComposite's sync; taken = its copy took it (the signal is coming). */
struct macvr_dxmt_end_params
{
    uint64_t image;
    int32_t taken;
};

/* CPU wait until the runtime's last armed copy of the image is done, before the image is written again. */
struct macvr_dxmt_idle_params
{
    uint64_t image;
    uint32_t timeout_ms;
    int32_t result; /* 0 idle, 1 timeout */
    uint64_t wait_ns;
};

struct macvr_dxmt_destroy_params
{
    uint64_t image;
};

/* Native runtime the unix side loaded (or would load), for the PE side's log. */
struct macvr_runtime_info_params
{
    char path[1024];
};
