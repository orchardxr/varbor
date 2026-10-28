/* Unix side of wineopenxr: universal Mach-O (x86_64 slice for Rosetta runners, arm64 for FEX) loaded by Wine as the PE's
 * unixlib. */
#pragma once
#define XR_USE_GRAPHICS_API_VULKAN
#define XR_USE_TIMESPEC
#define XR_NO_PROTOTYPES
#include <time.h>
#include <vulkan/vulkan.h>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include <openxr/openxr_loader_negotiation.h>

#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))

typedef int NTSTATUS;
typedef NTSTATUS (*unixlib_entry_t)(void *);

#include "xr_thunks.h"
#include "xr_host_functions.h"
#include "unix_params.h"

extern struct host_functions host;
void host_load_functions(XrInstance instance);
void host_gipa(XrInstance instance, const char *name, PFN_xrVoidFunction *func);

NTSTATUS bridge_init(void *args);
NTSTATUS bridge_has_function(void *args);
NTSTATUS bridge_create_instance(void *args);
NTSTATUS bridge_destroy_instance(void *args);
NTSTATUS bridge_create_session(void *args);
NTSTATUS bridge_vk_unwrap(void *args);
NTSTATUS bridge_vk_suggested_device(void *args);
NTSTATUS bridge_time_sample(void *args);
NTSTATUS bridge_dxmt_create_device(void *args);
NTSTATUS bridge_dxmt_destroy_device(void *args);
NTSTATUS bridge_dxmt_import_image(void *args);
NTSTATUS bridge_dxmt_destroy_image(void *args);
NTSTATUS bridge_dxmt_copy(void *args);
const char *moltenvk_path(void);
