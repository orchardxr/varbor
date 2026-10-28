/* Shared between vkprobe.dll (PE) and vkprobe.so (unix). Fixed-width fields only. */
#pragma once
#include <stdint.h>

enum probe_call { PROBE_INIT, PROBE_IMPORT_IMAGE, PROBE_SUBMIT_SIGNAL, PROBE_WAIT_READ,
                  XRPROBE_INIT, XRPROBE_BEGIN, XRPROBE_END, XRPROBE_SHUTDOWN, PROBE_METAL_TEXTURE, PROBE_COUNT };

struct probe_init {
    uint64_t pe_instance, pe_physdev, pe_device, pe_queue;
    uint64_t host_instance, host_physdev, host_device, host_queue; /* out */
    int32_t status;
    char info[512];
};

struct probe_image {
    uint32_t width, height;
    uint64_t image; /* out: host VkImage, same value DXVK sees (non-dispatchable handles are not wrapped) */
    int32_t status;
    char info[256];
};

struct probe_submit {
    uint64_t value;
    int32_t status;
    char info[256];
};

struct probe_read {
    uint64_t value;
    uint32_t x, y;
    uint32_t pixel;      /* out, BGRA as read through the IOSurface */
    uint64_t waited_ns;  /* out */
    int32_t status;
};

#define XRPROBE_MAX_IMAGES 8

struct xrprobe_init {
    uint64_t host_instance, host_physdev, host_device;
    uint32_t queue_family, queue_index;
    uint32_t width, height;           /* in: per-eye size (0 = recommended); out: swapchain size */
    uint32_t image_count;             /* out */
    uint64_t images[XRPROBE_MAX_IMAGES]; /* out: host VkImages */
    int32_t status;
    char info[512];
};

struct xrprobe_frame {
    uint32_t index;   /* out (begin) */
    uint64_t end_ns;  /* out (end): release + xrEndFrame */
    int32_t status;
    char info[512];
};
