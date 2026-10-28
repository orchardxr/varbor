/* PE side of wineopenxr: a Windows OpenXR runtime whose calls go to the unix side (wineopenxr.so). */
#pragma once
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winternl.h>
#include <d3d11_4.h>
#include <dxgi.h>

#define XR_USE_PLATFORM_WIN32
#define XR_USE_GRAPHICS_API_D3D11
#define XR_USE_GRAPHICS_API_VULKAN
#define XR_NO_PROTOTYPES
#define VK_USE_PLATFORM_WIN32_KHR
#include <vulkan/vulkan.h>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include <openxr/openxr_loader_negotiation.h>

#ifndef ARRAY_SIZE
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#endif

#include "xr_thunks.h"
#include "unix_params.h"

NTSTATUS wine_unix_call(enum unix_call code, void *args);
#define UNIX_CALL(name, args) wine_unix_call(unix_##name, args)

struct xr_function
{
    const char *name;
    PFN_xrVoidFunction func;
    const char *extension;
};

extern const struct xr_function pe_functions[];
extern const unsigned int pe_function_count;

/* Hand-written functions, wine_<name>, referenced from the generated table. */
#define WINE_XR(ret) ret XRAPI_CALL
WINE_XR(XrResult) wine_xrGetInstanceProcAddr(XrInstance, const char *, PFN_xrVoidFunction *);
WINE_XR(XrResult) wine_xrEnumerateInstanceExtensionProperties(const char *, uint32_t, uint32_t *, XrExtensionProperties *);
WINE_XR(XrResult) wine_xrEnumerateApiLayerProperties(uint32_t, uint32_t *, XrApiLayerProperties *);
WINE_XR(XrResult) wine_xrCreateInstance(const XrInstanceCreateInfo *, XrInstance *);
WINE_XR(XrResult) wine_xrDestroyInstance(XrInstance);
WINE_XR(XrResult) wine_xrCreateSession(XrInstance, const XrSessionCreateInfo *, XrSession *);
WINE_XR(XrResult) wine_xrDestroySession(XrSession);
WINE_XR(XrResult) wine_xrEnumerateSwapchainFormats(XrSession, uint32_t, uint32_t *, int64_t *);
WINE_XR(XrResult) wine_xrCreateSwapchain(XrSession, const XrSwapchainCreateInfo *, XrSwapchain *);
WINE_XR(XrResult) wine_xrDestroySwapchain(XrSwapchain);
WINE_XR(XrResult) wine_xrEnumerateSwapchainImages(XrSwapchain, uint32_t, uint32_t *, XrSwapchainImageBaseHeader *);
WINE_XR(XrResult) wine_xrAcquireSwapchainImage(XrSwapchain, const XrSwapchainImageAcquireInfo *, uint32_t *);
WINE_XR(XrResult) wine_xrWaitSwapchainImage(XrSwapchain, const XrSwapchainImageWaitInfo *);
WINE_XR(XrResult) wine_xrReleaseSwapchainImage(XrSwapchain, const XrSwapchainImageReleaseInfo *);
WINE_XR(XrResult) wine_xrEndFrame(XrSession, const XrFrameEndInfo *);
WINE_XR(XrResult) wine_xrWaitFrame(XrSession, const XrFrameWaitInfo *, XrFrameState *);
WINE_XR(XrResult) wine_xrBeginFrame(XrSession, const XrFrameBeginInfo *);
WINE_XR(XrResult) wine_xrEndSession(XrSession);
WINE_XR(XrResult) wine_xrGetVulkanInstanceExtensionsKHR(XrInstance, XrSystemId, uint32_t, uint32_t *, char *);
WINE_XR(XrResult) wine_xrGetVulkanDeviceExtensionsKHR(XrInstance, XrSystemId, uint32_t, uint32_t *, char *);
WINE_XR(XrResult) wine_xrGetVulkanGraphicsDeviceKHR(XrInstance, XrSystemId, VkInstance, VkPhysicalDevice *);
WINE_XR(XrResult) wine_xrGetVulkanGraphicsDevice2KHR(XrInstance, const XrVulkanGraphicsDeviceGetInfoKHR *, VkPhysicalDevice *);
WINE_XR(XrResult) wine_xrCreateVulkanInstanceKHR(XrInstance, const XrVulkanInstanceCreateInfoKHR *, VkInstance *, VkResult *);
WINE_XR(XrResult) wine_xrCreateVulkanDeviceKHR(XrInstance, const XrVulkanDeviceCreateInfoKHR *, VkDevice *, VkResult *);
WINE_XR(XrResult) wine_xrGetD3D11GraphicsRequirementsKHR(XrInstance, XrSystemId, XrGraphicsRequirementsD3D11KHR *);
WINE_XR(XrResult) wine_xrConvertWin32PerformanceCounterToTimeKHR(XrInstance, const LARGE_INTEGER *, XrTime *);
WINE_XR(XrResult) wine_xrConvertTimeToWin32PerformanceCounterKHR(XrInstance, XrTime, LARGE_INTEGER *);

/* DXVK's interop interface (dxvk/src/dxgi/dxgi_interfaces.h, 1.10). */
typedef struct IDXGIVkInteropDevice1 IDXGIVkInteropDevice1;
typedef struct IDXGIVkInteropDevice1Vtbl
{
    HRESULT(STDMETHODCALLTYPE *QueryInterface)(IDXGIVkInteropDevice1 *, REFIID, void **);
    ULONG(STDMETHODCALLTYPE *AddRef)(IDXGIVkInteropDevice1 *);
    ULONG(STDMETHODCALLTYPE *Release)(IDXGIVkInteropDevice1 *);
    void(STDMETHODCALLTYPE *GetVulkanHandles)(IDXGIVkInteropDevice1 *, VkInstance *, VkPhysicalDevice *, VkDevice *);
    void(STDMETHODCALLTYPE *GetSubmissionQueue)(IDXGIVkInteropDevice1 *, VkQueue *, uint32_t *);
    void(STDMETHODCALLTYPE *TransitionSurfaceLayout)(IDXGIVkInteropDevice1 *, IUnknown *, const VkImageSubresourceRange *,
                                                     VkImageLayout, VkImageLayout);
    void(STDMETHODCALLTYPE *FlushRenderingCommands)(IDXGIVkInteropDevice1 *);
    void(STDMETHODCALLTYPE *LockSubmissionQueue)(IDXGIVkInteropDevice1 *);
    void(STDMETHODCALLTYPE *ReleaseSubmissionQueue)(IDXGIVkInteropDevice1 *);
    void(STDMETHODCALLTYPE *GetSubmissionQueue1)(IDXGIVkInteropDevice1 *, VkQueue *, uint32_t *, uint32_t *);
    HRESULT(STDMETHODCALLTYPE *CreateTexture2DFromVkImage)(IDXGIVkInteropDevice1 *, const D3D11_TEXTURE2D_DESC1 *, VkImage,
                                                           ID3D11Texture2D **);
} IDXGIVkInteropDevice1Vtbl;
struct IDXGIVkInteropDevice1
{
    const IDXGIVkInteropDevice1Vtbl *lpVtbl;
};

/* The D3DKMT calls the DXMT path needs (gdi32; mingw has no d3dkmthk.h). */
typedef UINT D3DKMT_HANDLE;
typedef struct { LUID AdapterLuid; D3DKMT_HANDLE hAdapter; } D3DKMT_OPENADAPTERFROMLUID;
typedef struct { D3DKMT_HANDLE hAdapter; } D3DKMT_CLOSEADAPTER;
typedef struct
{
    union
    {
        D3DKMT_HANDLE hAdapter;
        void *pAdapter;
    };
    UINT Flags;
    D3DKMT_HANDLE hDevice;
    void *pCommandBuffer;
    UINT CommandBufferSize;
    void *pAllocationList;
    UINT AllocationListSize;
    void *pPatchLocationList;
    UINT PatchLocationListSize;
} D3DKMT_CREATEDEVICE;
typedef struct { D3DKMT_HANDLE hDevice; } D3DKMT_DESTROYDEVICE;
typedef struct
{
    D3DKMT_HANDLE hDevice;
    D3DKMT_HANDLE hGlobalShare;
    void *pPrivateRuntimeData;
    UINT PrivateRuntimeDataSize;
    UINT TotalPrivateDriverDataSize;
    UINT ResourcePrivateDriverDataSize;
    UINT NumAllocations;
} D3DKMT_QUERYRESOURCEINFO;
typedef struct
{
    D3DKMT_HANDLE hAllocation;
    const void *pPrivateDriverData;
    UINT PrivateDriverDataSize;
    UINT64 GpuVirtualAddress;
    ULONG_PTR Reserved[6];
} D3DDDI_OPENALLOCATIONINFO2;
typedef struct
{
    D3DKMT_HANDLE hDevice;
    D3DKMT_HANDLE hGlobalShare;
    UINT NumAllocations;
    D3DDDI_OPENALLOCATIONINFO2 *pOpenAllocationInfo2;
    void *pPrivateRuntimeData;
    UINT PrivateRuntimeDataSize;
    void *pResourcePrivateDriverData;
    UINT ResourcePrivateDriverDataSize;
    void *pTotalPrivateDriverDataBuffer;
    UINT TotalPrivateDriverDataBufferSize;
    D3DKMT_HANDLE hResource;
} D3DKMT_OPENRESOURCE;
typedef struct
{
    D3DKMT_HANDLE hDevice;
    D3DKMT_HANDLE hResource;
    const D3DKMT_HANDLE *phAllocationList;
    UINT AllocationCount;
} D3DKMT_DESTROYALLOCATION;
typedef struct
{
    D3DKMT_HANDLE hSharedHandle;
    D3DKMT_HANDLE hKeyedMutex;
    void *pPrivateRuntimeData;
    UINT PrivateRuntimeDataSize;
} D3DKMT_OPENKEYEDMUTEX2;
typedef struct { D3DKMT_HANDLE hKeyedMutex; } D3DKMT_DESTROYKEYEDMUTEX;
typedef struct
{
    D3DKMT_HANDLE hKeyedMutex;
    UINT64 Key;
    LARGE_INTEGER *pTimeout;
    UINT64 FenceValue;
} D3DKMT_ACQUIREKEYEDMUTEX;
typedef struct
{
    D3DKMT_HANDLE hKeyedMutex;
    UINT64 Key;
    UINT64 FenceValue;
} D3DKMT_RELEASEKEYEDMUTEX;

/* DXMT's private runtime data for shared textures (dxmt src/d3d11/d3d11_texture_device.cpp, SharedResourceData). Only
 * the name and the keyed mutex handle are read; the size is checked against what D3DKMT returns. */
struct dxmt_shared_resource_data
{
    char mach_port_name[54];
    D3D11_RESOURCE_DIMENSION dimension;
    union
    {
        D3D11_TEXTURE1D_DESC desc1d;
        D3D11_TEXTURE2D_DESC1 desc2d;
        D3D11_TEXTURE3D_DESC1 desc3d;
    } desc;
    D3DKMT_HANDLE mutex_handle;
};
