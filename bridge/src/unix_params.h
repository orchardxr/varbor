/* Parameters of the hand-written unix calls (UNIX_CALLS in make_openxr.py). Shared by both sides. */
#pragma once
#include <stdint.h>

struct init_params
{
    XrResult result;
    char info[512];
};

struct has_function_params
{
    XrInstance instance;
    const char *name;
    XrResult result;
};

struct create_instance_params
{
    const XrInstanceCreateInfo *info;
    XrInstance *instance;
    XrResult result;
};

struct destroy_instance_params
{
    XrInstance instance;
    XrResult result;
};

/* The PE side has already put an XrGraphicsBindingVulkanKHR with winevulkan handles in the chain; the unix side
 * unwraps them in place. */
struct create_session_params
{
    XrInstance instance;
    const XrSessionCreateInfo *info;
    XrGraphicsBindingVulkanKHR *binding;
    uint32_t host_handles; /* binding already holds host handles (DXMT sessions) */
    XrSession *session;
    XrResult result;
};

struct vk_unwrap_params
{
    uint64_t handle;
    uint64_t host; /* 0 when the handle doesn't lead to a MoltenVK object */
};

/* Index of the runtime's suggested device among the PE devices of the PE instance. */
struct vk_suggested_device_params
{
    XrInstance instance;
    XrSystemId system;
    uint64_t pe_instance;
    uint32_t count;
    const uint64_t *pe_devices;
    uint32_t index;
    XrResult result;
};

struct time_sample_params
{
    XrInstance instance;
    int64_t monotonic_ns;  /* CLOCK_MONOTONIC, Monado's clock */
    int64_t continuous_ns; /* mach_continuous_time, Wine's QPC source on macOS */
    XrTime time;
    XrResult result;
};

/* DXMT sessions: the unix side owns a Vulkan device on CrossOver's MoltenVK for Monado, imports DXMT's shared
 * textures and keyed-mutex events into it, and copies the game's images into Monado's. */
struct dxmt_create_device_params
{
    XrInstance instance;
    XrSystemId system;
    uint64_t ctx;
    uint64_t vk_instance, vk_physical_device, vk_device;
    uint32_t queue_family, queue_index;
    XrResult result;
    char info[256];
};

struct dxmt_destroy_device_params
{
    uint64_t ctx;
};

struct dxmt_import_image_params
{
    uint64_t ctx;
    char texture_name[64]; /* bootstrap name of DXMT's MTLSharedTextureHandle port */
    char event_name[64];   /* bootstrap name of the keyed mutex's MTLSharedEvent port, empty without one */
    int64_t vk_format;
    uint32_t width, height, layers, mips;
    uint64_t image;
    XrResult result;
    char info[256];
};

struct dxmt_destroy_image_params
{
    uint64_t ctx;
    uint64_t image;
};

/* Asks the user (native alert) what to do about a D3D11 device that is neither DXMT nor DXVK. */
struct unsupported_device_params
{
    uint32_t run_anyway; /* out */
};

#define DXMT_MAX_SLICES 4

/* Copies slice s of the source into layer 0 of dst[s]. wait/signal are keyed-mutex fence values (0: no wait). */
struct dxmt_copy_params
{
    uint64_t ctx;
    uint64_t image;
    uint32_t slices;
    uint64_t dst[DXMT_MAX_SLICES];
    int32_t rect[DXMT_MAX_SLICES][4]; /* x, y, width, height of mip 0 to copy; width 0: the whole image */
    uint64_t wait_value, signal_value;
    uint64_t fence_ns, submit_ns; /* out: ring fence wait, vkQueueSubmit */
    XrResult result;
};
