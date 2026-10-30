
/* The D3DKMT calls the DXMT path needs (gdi32; mingw has no d3dkmthk.h), as in bridge/src/wineopenxr_private.h. */
#pragma once

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
