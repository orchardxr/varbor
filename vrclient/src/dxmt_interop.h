/* VarboR DXMT's Metal interop (orchardxr/varbor-engines: patches/dxmt/0001-d3d11-metal-interop.patch, src/d3d11/d3d11_interop.hpp), for C:
 * the counterpart of Proton's dxvk-interop.h. Handles are unix-side Objective-C pointers, unretained. */
#pragma once
#include <windows.h>

typedef struct DXMT_INTEROP_TEXTURE_INFO
{
    UINT64 Texture;
    UINT64 Device;
    UINT PixelFormat;
    UINT TextureType;
    UINT Usage;
    UINT Width;
    UINT Height;
    UINT Depth;
    UINT ArraySize;
    UINT MipLevels;
    UINT SampleCount;
    UINT D3D11Usage;
} DXMT_INTEROP_TEXTURE_INFO;

typedef struct IDXMTInteropDevice IDXMTInteropDevice;
typedef struct IDXMTInteropSurface IDXMTInteropSurface;

typedef struct IDXMTInteropDeviceVtbl
{
    HRESULT (STDMETHODCALLTYPE *QueryInterface)( IDXMTInteropDevice *This, REFIID riid, void **object );
    ULONG (STDMETHODCALLTYPE *AddRef)( IDXMTInteropDevice *This );
    ULONG (STDMETHODCALLTYPE *Release)( IDXMTInteropDevice *This );
    HRESULT (STDMETHODCALLTYPE *GetMetalDevice)( IDXMTInteropDevice *This, UINT64 *device );
    void (STDMETHODCALLTYPE *LockSubmissionQueue)( IDXMTInteropDevice *This );
    void (STDMETHODCALLTYPE *ReleaseSubmissionQueue)( IDXMTInteropDevice *This );
    HRESULT (STDMETHODCALLTYPE *FlushRenderingCommands)( IDXMTInteropDevice *This, UINT64 *event, UINT64 *value );
    HRESULT (STDMETHODCALLTYPE *SignalEvent)( IDXMTInteropDevice *This, UINT64 event, UINT64 value );
    HRESULT (STDMETHODCALLTYPE *WaitEvent)( IDXMTInteropDevice *This, UINT64 event, UINT64 value );
} IDXMTInteropDeviceVtbl;

struct IDXMTInteropDevice
{
    const IDXMTInteropDeviceVtbl *lpVtbl;
};

typedef struct IDXMTInteropSurfaceVtbl
{
    HRESULT (STDMETHODCALLTYPE *QueryInterface)( IDXMTInteropSurface *This, REFIID riid, void **object );
    ULONG (STDMETHODCALLTYPE *AddRef)( IDXMTInteropSurface *This );
    ULONG (STDMETHODCALLTYPE *Release)( IDXMTInteropSurface *This );
    HRESULT (STDMETHODCALLTYPE *GetDevice)( IDXMTInteropSurface *This, IDXMTInteropDevice **device );
    HRESULT (STDMETHODCALLTYPE *GetMetalTextureInfo)( IDXMTInteropSurface *This, DXMT_INTEROP_TEXTURE_INFO *info );
} IDXMTInteropSurfaceVtbl;

struct IDXMTInteropSurface
{
    const IDXMTInteropSurfaceVtbl *lpVtbl;
};

static const GUID IID_IDXMTInteropDevice = {0xee7b5b9d, 0xb703, 0x46a9, {0xac, 0x7f, 0x1c, 0xc1, 0xdd, 0xdd, 0x98, 0x8b}};
static const GUID IID_IDXMTInteropSurface = {0x0cccd1b1, 0x1a29, 0x44b5, {0xa0, 0x30, 0x04, 0xf2, 0x8f, 0xa3, 0xb3, 0x2b}};

/* MTLPixelFormat / MTLTextureType / MTLTextureUsage values the bridge checks */
#define VARBOR_MTL_TEXTURE_TYPE_2D 2
#define VARBOR_MTL_TEXTURE_TYPE_2D_ARRAY 3
#define VARBOR_MTL_TEXTURE_USAGE_SHADER_READ 1
