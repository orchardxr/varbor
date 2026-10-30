/* D3D11 submits through stock DXMT (CX_GRAPHICS_BACKEND=dxmt), in place of Proton's IDXGIVkInteropSurface path.
 *
 * Stock DXMT turns SHARED(_KEYEDMUTEX) textures into MTLSharedTextures whose Mach port it registers in the bootstrap
 * namespace, under a name kept in the D3DKMT resource's private runtime data; the keyed mutex's MTLSharedEvent is
 * published the same way (see bridge/src/wineopenxr.c). Each eye has a small ring of such textures: the game's eye
 * texture is copied into one on the game's context, its keyed mutex release makes DXMT signal the event once the copy
 * is done, the unix side waits for that value on the CPU, and the native runtime gets the imported id<MTLTexture> as
 * TextureType_Metal. OpenComposite copies it on its own queue with nothing to wait on, hence the CPU wait; the ring
 * keeps the next frames' copies off a texture it may still be reading. DXMT without keyed mutexes (before v0.80):
 * plain SHARED textures and an event query wait. */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define COBJMACROS
#include <windows.h>
#include <d3d11_4.h>
#include <dxgi.h>

#include "vrclient_private.h"
#include "dxmt_kmt.h"
#include "macvr_pe.h"

WINE_DEFAULT_DEBUG_CHANNEL(vrclient);

#define RING 3
#define TARGETS 2

struct dxmt_slot
{
    ID3D11Texture2D *shared;
    IDXGIKeyedMutex *keyed;
    D3DKMT_HANDLE kmt_mutex;
    uint64_t image, mtl_texture;
};

struct dxmt_target
{
    D3D11_TEXTURE2D_DESC desc;
    struct dxmt_slot ring[RING];
    unsigned int next;
};

enum sync_mode { SYNC_UNKNOWN, SYNC_KEYED, SYNC_QUERY, SYNC_UNSUPPORTED };

static struct
{
    ID3D11Device *device;
    ID3D11DeviceContext *context;
    D3DKMT_HANDLE kmt_device;
    enum sync_mode mode;
    ID3D11Query *query;
    struct dxmt_target targets[TARGETS];
} dxmt;

static const GUID IID_IDXGIVkInteropSurface_ = {0x5546cf8c, 0x77e7, 0x4341, {0xb0, 0x5d, 0x8d, 0x4d, 0x50, 0x00, 0xe7, 0x7d}};

static FILE *log_file;

static BOOL CALLBACK open_log( INIT_ONCE *once, void *param, void **ctx )
{
    const char *path = getenv( "VRCLIENT_LOG" );
    if (path && *path) log_file = fopen( path, "a" );
    return TRUE;
}

void macvr_log( const char *fmt, ... )
{
    static INIT_ONCE once = INIT_ONCE_STATIC_INIT;
    char buf[1024];
    FILE *out;
    va_list ap;
    InitOnceExecuteOnce( &once, open_log, NULL, NULL );
    out = log_file ? log_file : stderr;
    va_start( ap, fmt );
    vsnprintf( buf, sizeof(buf), fmt, ap );
    va_end( ap );
    fprintf( out, "vrclient: %s\n", buf );
    fflush( out );
}

void macvr_log_runtime( BOOL loaded )
{
    struct macvr_runtime_info_params p = {{0}};
    VRCLIENT_CALL( macvr_runtime_info, &p );
    if (loaded) macvr_log( "native runtime %s", p.path );
    else macvr_log( "no native OpenVR runtime loaded (%s)", p.path[0] ? p.path : "none found" );
}

/* VRCLIENT_STATS=1: median / p99 / max of the bridge's share of each eye submit, per STAT_WINDOW submits. */
enum { ST_COPY, ST_WAIT, ST_SUBMIT, ST_TOTAL, ST_COUNT };
#define STAT_WINDOW 600
static const char *const stat_names[ST_COUNT] = {"copy", "wait", "submit", "total"};
static int stats_on = -1;
static LONGLONG qpc_freq;
static float stat_samples[ST_COUNT][STAT_WINDOW];
static unsigned int stat_count, stat_windows;

static LONGLONG now(void)
{
    LARGE_INTEGER t;
    QueryPerformanceCounter( &t );
    return t.QuadPart;
}

static int cmp_float( const void *a, const void *b )
{
    float x = *(const float *)a, y = *(const float *)b;
    return x < y ? -1 : x > y;
}

static void stats_add( const struct macvr_submit *s, LONGLONG end )
{
    char line[512];
    int len;
    if (stats_on < 0)
    {
        LARGE_INTEGER f;
        QueryPerformanceFrequency( &f );
        qpc_freq = f.QuadPart;
        stats_on = getenv( "VRCLIENT_STATS" ) && atoi( getenv( "VRCLIENT_STATS" ) );
    }
    if (!stats_on) return;
#define US(a, b) ((float)((b) - (a)) * 1e6f / (float)qpc_freq)
    stat_samples[ST_COPY][stat_count] = US( s->t_start, s->t_copied );
    stat_samples[ST_WAIT][stat_count] = US( s->t_copied, s->t_waited );
    stat_samples[ST_SUBMIT][stat_count] = US( s->t_waited, end );
    stat_samples[ST_TOTAL][stat_count] = US( s->t_start, end );
#undef US
    if (++stat_count < STAT_WINDOW) return;
    len = snprintf( line, sizeof(line), "stats %u submits (us):", STAT_WINDOW );
    for (int i = 0; i < ST_COUNT; i++)
    {
        qsort( stat_samples[i], STAT_WINDOW, sizeof(float), cmp_float );
        len += snprintf( line + len, sizeof(line) - len, " %s %.0f/%.0f/%.0f", stat_names[i],
                         stat_samples[i][STAT_WINDOW / 2], stat_samples[i][STAT_WINDOW * 99 / 100],
                         stat_samples[i][STAT_WINDOW - 1] );
    }
    macvr_log( "%s (median/p99/max, window %u)", line, ++stat_windows );
    stat_count = 0;
}

static struct
{
    NTSTATUS(WINAPI *OpenAdapterFromLuid)(D3DKMT_OPENADAPTERFROMLUID *);
    NTSTATUS(WINAPI *CloseAdapter)(const D3DKMT_CLOSEADAPTER *);
    NTSTATUS(WINAPI *CreateDevice)(D3DKMT_CREATEDEVICE *);
    NTSTATUS(WINAPI *DestroyDevice)(const D3DKMT_DESTROYDEVICE *);
    NTSTATUS(WINAPI *QueryResourceInfo)(D3DKMT_QUERYRESOURCEINFO *);
    NTSTATUS(WINAPI *OpenResource2)(D3DKMT_OPENRESOURCE *);
    NTSTATUS(WINAPI *DestroyAllocation)(const D3DKMT_DESTROYALLOCATION *);
    NTSTATUS(WINAPI *OpenKeyedMutex2)(D3DKMT_OPENKEYEDMUTEX2 *);
    NTSTATUS(WINAPI *DestroyKeyedMutex)(const D3DKMT_DESTROYKEYEDMUTEX *);
    NTSTATUS(WINAPI *AcquireKeyedMutex)(D3DKMT_ACQUIREKEYEDMUTEX *);
    NTSTATUS(WINAPI *ReleaseKeyedMutex)(D3DKMT_RELEASEKEYEDMUTEX *);
} kmt;

static BOOL load_kmt(void)
{
    HMODULE gdi = LoadLibraryA( "gdi32.dll" );
#define K(n) if (!gdi || !(*(FARPROC *)&kmt.n = GetProcAddress( gdi, "D3DKMT" #n ))) return FALSE;
    K(OpenAdapterFromLuid) K(CloseAdapter) K(CreateDevice) K(DestroyDevice) K(QueryResourceInfo) K(OpenResource2)
    K(DestroyAllocation) K(OpenKeyedMutex2) K(DestroyKeyedMutex) K(AcquireKeyedMutex) K(ReleaseKeyedMutex)
#undef K
    return TRUE;
}

static D3DKMT_HANDLE kmt_device_for( ID3D11Device *device )
{
    IDXGIDevice *dxgi = NULL;
    IDXGIAdapter *adapter = NULL;
    DXGI_ADAPTER_DESC desc;
    D3DKMT_OPENADAPTERFROMLUID open = {0};
    D3DKMT_CREATEDEVICE create = {0};
    D3DKMT_CLOSEADAPTER close;
    NTSTATUS status;
    HRESULT hr = ID3D11Device_QueryInterface( device, &IID_IDXGIDevice, (void **)&dxgi );

    if (SUCCEEDED(hr)) hr = IDXGIDevice_GetAdapter( dxgi, &adapter );
    if (SUCCEEDED(hr)) hr = IDXGIAdapter_GetDesc( adapter, &desc );
    if (adapter) IDXGIAdapter_Release( adapter );
    if (dxgi) IDXGIDevice_Release( dxgi );
    if (FAILED(hr)) return 0;
    open.AdapterLuid = desc.AdapterLuid;
    if (kmt.OpenAdapterFromLuid( &open )) return 0;
    create.hAdapter = open.hAdapter;
    status = kmt.CreateDevice( &create );
    close.hAdapter = open.hAdapter;
    kmt.CloseAdapter( &close );
    return status ? 0 : create.hDevice;
}

/* Bootstrap names of a DXMT shared texture and of its keyed mutex's event; opens our own handle to the mutex. */
static BOOL shared_names( ID3D11Texture2D *texture, char *name, char *event_name, D3DKMT_HANDLE *mutex )
{
    struct dxmt_shared_resource_data data = {{0}};
    const UINT old_size = offsetof( struct dxmt_shared_resource_data, mutex_handle );
    D3DDDI_OPENALLOCATIONINFO2 alloc = {0};
    D3DKMT_QUERYRESOURCEINFO query = {dxmt.kmt_device};
    D3DKMT_OPENRESOURCE open = {dxmt.kmt_device};
    D3DKMT_DESTROYALLOCATION destroy = {dxmt.kmt_device};
    IDXGIResource *res;
    HANDLE share = NULL;
    HRESULT hr = ID3D11Texture2D_QueryInterface( texture, &IID_IDXGIResource, (void **)&res );

    if (SUCCEEDED(hr))
    {
        hr = IDXGIResource_GetSharedHandle( res, &share );
        IDXGIResource_Release( res );
    }
    if (FAILED(hr) || !share) return FALSE;
    query.hGlobalShare = (D3DKMT_HANDLE)(UINT_PTR)share;
    query.pPrivateRuntimeData = &data;
    query.PrivateRuntimeDataSize = sizeof(data);
    if (kmt.QueryResourceInfo( &query )
        || (query.PrivateRuntimeDataSize != sizeof(data) && query.PrivateRuntimeDataSize != old_size))
        return FALSE;
    open.hGlobalShare = query.hGlobalShare;
    open.NumAllocations = 1;
    open.pOpenAllocationInfo2 = &alloc;
    open.pPrivateRuntimeData = &data;
    open.PrivateRuntimeDataSize = query.PrivateRuntimeDataSize;
    if (kmt.OpenResource2( &open )) return FALSE;
    if (query.PrivateRuntimeDataSize == old_size) data.mutex_handle = 0;
    destroy.hResource = open.hResource;
    kmt.DestroyAllocation( &destroy );
    data.mach_port_name[sizeof(data.mach_port_name) - 1] = 0;
    if (strncmp( data.mach_port_name, "DXMT_", 5 )) return FALSE;
    strcpy( name, data.mach_port_name );
    event_name[0] = 0;
    *mutex = 0;
    if (data.mutex_handle)
    {
        char buf[54] = {0};
        D3DKMT_OPENKEYEDMUTEX2 om = {data.mutex_handle, 0, buf, sizeof(buf)};
        if (kmt.OpenKeyedMutex2( &om ) || strncmp( buf, "DXMT_", 5 )) return FALSE;
        buf[sizeof(buf) - 1] = 0;
        strcpy( event_name, buf );
        *mutex = om.hKeyedMutex;
    }
    return TRUE;
}

static void destroy_slot( struct dxmt_slot *slot )
{
    struct macvr_dxmt_destroy_params d = {slot->image};
    D3DKMT_DESTROYKEYEDMUTEX dm = {slot->kmt_mutex};
    if (slot->image) VRCLIENT_CALL( macvr_dxmt_destroy, &d );
    if (slot->kmt_mutex) kmt.DestroyKeyedMutex( &dm );
    if (slot->keyed) IDXGIKeyedMutex_Release( slot->keyed );
    if (slot->shared) ID3D11Texture2D_Release( slot->shared );
    memset( slot, 0, sizeof(*slot) );
}

static BOOL create_slot( const D3D11_TEXTURE2D_DESC *desc, BOOL keyed, struct dxmt_slot *slot, BOOL quiet )
{
    struct macvr_dxmt_import_params p = {{0}};
    D3D11_TEXTURE2D_DESC d = *desc;

    d.MiscFlags = keyed ? D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX : D3D11_RESOURCE_MISC_SHARED;
    if (FAILED(ID3D11Device_CreateTexture2D( dxmt.device, &d, NULL, &slot->shared ))) goto fail;
    if (!shared_names( slot->shared, p.texture_name, p.event_name, &slot->kmt_mutex )) goto fail;
    if (keyed && (!p.event_name[0]
                  || FAILED(ID3D11Texture2D_QueryInterface( slot->shared, &IID_IDXGIKeyedMutex, (void **)&slot->keyed )))) goto fail;
    if (!keyed) p.event_name[0] = 0;
    VRCLIENT_CALL( macvr_dxmt_import, &p );
    if (!p.image)
    {
        if (!quiet) macvr_log( "DXMT import: %s", p.info );
        goto fail;
    }
    slot->image = p.image;
    slot->mtl_texture = p.texture;
    return TRUE;
fail:
    destroy_slot( slot );
    return FALSE;
}

/* What the future patched DXMT could offer instead of the copy: the texture's own id<MTLTexture> and a
 * MTLSharedEvent value that its rendering signals. Not used yet: logs once when a device has it. */
static const GUID IID_IMacVRDXMTInterop = {0x8e3d6a47, 0x2c1b, 0x4f0e, {0x9a, 0x51, 0x6d, 0x0b, 0x7c, 0x3e, 0x21, 0xa9}};

static BOOL dxmt_native_interop( IUnknown *texture )
{
    static BOOL logged;
    IUnknown *interop;
    if (FAILED(IUnknown_QueryInterface( texture, &IID_IMacVRDXMTInterop, (void **)&interop ))) return FALSE;
    IUnknown_Release( interop );
    if (!logged) macvr_log( "DXMT offers native Metal interop; not implemented yet, copying" );
    logged = TRUE;
    return FALSE;
}

static BOOL probe_device( ID3D11Device *device )
{
    D3D11_TEXTURE2D_DESC desc = {16, 16, 1, 1, DXGI_FORMAT_R8G8B8A8_UNORM, {1, 0}, D3D11_USAGE_DEFAULT,
                                 D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE};
    const char *sync = getenv( "VRCLIENT_DXMT_SYNC" );
    struct dxmt_slot slot = {0};
    D3D11_QUERY_DESC qd = {D3D11_QUERY_EVENT};

    dxmt.device = device;
    ID3D11Device_AddRef( device );
    ID3D11Device_GetImmediateContext( device, &dxmt.context );
    if (!load_kmt() || !(dxmt.kmt_device = kmt_device_for( device ))) goto unsupported;
    if (!(sync && !strcmp( sync, "query" )) && create_slot( &desc, TRUE, &slot, TRUE ))
    {
        destroy_slot( &slot );
        dxmt.mode = SYNC_KEYED;
        macvr_log( "DXMT device: keyed mutex sync (CPU wait on its MTLSharedEvent)" );
        return TRUE;
    }
    if (create_slot( &desc, FALSE, &slot, FALSE )
        && SUCCEEDED(ID3D11Device_CreateQuery( device, &qd, &dxmt.query )))
    {
        destroy_slot( &slot );
        dxmt.mode = SYNC_QUERY;
        macvr_log( "DXMT device without keyed mutexes: event query sync" );
        return TRUE;
    }
    destroy_slot( &slot );
unsupported:
    dxmt.mode = SYNC_UNSUPPORTED;
    macvr_log( "the D3D11 device is neither DXVK nor DXMT (CX_GRAPHICS_BACKEND=dxmt or dxvk): eye textures are not submitted" );
    return FALSE;
}

BOOL macvr_dxmt_texture( IUnknown *texture )
{
    IUnknown *dxvk;
    ID3D11Device *device;
    if (!texture) return FALSE;
    if (SUCCEEDED(IUnknown_QueryInterface( texture, &IID_IDXGIVkInteropSurface_, (void **)&dxvk )))
    {
        IUnknown_Release( dxvk );
        return FALSE;
    }
    if (dxmt.mode != SYNC_UNKNOWN) return TRUE;
    ID3D11Texture2D_GetDevice( (ID3D11Texture2D *)texture, &device );
    probe_device( device );
    ID3D11Device_Release( device );
    return TRUE;
}

static DXGI_FORMAT typed_format( DXGI_FORMAT f )
{
    switch (f)
    {
    case DXGI_FORMAT_R8G8B8A8_TYPELESS: return DXGI_FORMAT_R8G8B8A8_UNORM;
    case DXGI_FORMAT_B8G8R8A8_TYPELESS: return DXGI_FORMAT_B8G8R8A8_UNORM;
    case DXGI_FORMAT_B8G8R8X8_TYPELESS: return DXGI_FORMAT_B8G8R8X8_UNORM;
    case DXGI_FORMAT_R10G10B10A2_TYPELESS: return DXGI_FORMAT_R10G10B10A2_UNORM;
    case DXGI_FORMAT_R16G16B16A16_TYPELESS: return DXGI_FORMAT_R16G16B16A16_FLOAT;
    default: return f;
    }
}

static struct dxmt_slot *next_slot( uint32_t eye, const D3D11_TEXTURE2D_DESC *src )
{
    struct dxmt_target *t = &dxmt.targets[eye < TARGETS ? eye : 0];
    D3D11_TEXTURE2D_DESC want = {src->Width, src->Height, 1, 1, typed_format( src->Format ), {1, 0}, D3D11_USAGE_DEFAULT,
                                 D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE};
    struct dxmt_slot *slot;

    if (memcmp( &t->desc, &want, sizeof(want) ))
    {
        for (int i = 0; i < RING; i++) destroy_slot( &t->ring[i] );
        t->desc = want;
        macvr_log( "eye %u: %ux%u DXGI format %u (source %u, %u samples, %u slices), ring of %u", eye, want.Width,
                   want.Height, want.Format, src->Format, src->SampleDesc.Count, src->ArraySize, RING );
    }
    slot = &t->ring[t->next++ % RING];
    if (!slot->shared && !create_slot( &t->desc, dxmt.mode == SYNC_KEYED, slot, FALSE )) return NULL;
    return slot;
}

const void *macvr_load_texture_dxmt( uint32_t eye, const void *texture, uint32_t *flags, void *texture_out,
                                     struct macvr_submit *state, uint32_t array_index )
{
    const w_Texture_t *in = texture;
    w_VRTextureWithPose_t *out = texture_out;
    ID3D11Texture2D *src = in->handle;
    D3D11_TEXTURE2D_DESC desc;
    struct macvr_dxmt_wait_params w = {0};
    struct dxmt_slot *slot = NULL;
    UINT slice, sub, pose;

    state->slot = NULL;
    state->t_start = now();
    if (dxmt.mode != SYNC_KEYED && dxmt.mode != SYNC_QUERY) goto fail;
    dxmt_native_interop( in->handle );
    ID3D11Texture2D_GetDesc( src, &desc );
    if (!(slot = next_slot( eye, &desc ))) goto fail;

    slice = array_index != ~0u ? array_index : desc.ArraySize > 1 ? eye : 0;
    if (slice >= desc.ArraySize) slice = 0;
    sub = slice * desc.MipLevels;

    if (slot->keyed && FAILED(IDXGIKeyedMutex_AcquireSync( slot->keyed, 0, 1000 )))
    {
        macvr_log( "keyed mutex AcquireSync(0) failed" );
        goto fail;
    }
    if (desc.SampleDesc.Count > 1)
        ID3D11DeviceContext_ResolveSubresource( dxmt.context, (ID3D11Resource *)slot->shared, 0, (ID3D11Resource *)src,
                                                sub, typed_format( desc.Format ) );
    else
        ID3D11DeviceContext_CopySubresourceRegion( dxmt.context, (ID3D11Resource *)slot->shared, 0, 0, 0, 0,
                                                   (ID3D11Resource *)src, sub, NULL );
    if (slot->keyed)
    {
        LARGE_INTEGER timeout = {.QuadPart = -10000000};
        D3DKMT_ACQUIREKEYEDMUTEX acq = {slot->kmt_mutex, 1, &timeout};
        /* DXMT signals the event at the release's fence value once the copy is done. */
        if (FAILED(IDXGIKeyedMutex_ReleaseSync( slot->keyed, 1 )) || kmt.AcquireKeyedMutex( &acq ))
        {
            macvr_log( "keyed mutex hand-over failed" );
            goto fail;
        }
        state->fence = acq.FenceValue;
        state->t_copied = now();
        w.image = slot->image;
        w.value = acq.FenceValue;
        w.timeout_ms = 1000;
        VRCLIENT_CALL( macvr_dxmt_wait, &w );
        if (w.result) macvr_log( "MTLSharedEvent wait for %llu: %s", (unsigned long long)w.value,
                                 w.result > 0 ? "timeout" : "no event" );
    }
    else
    {
        ID3D11DeviceContext_End( dxmt.context, (ID3D11Asynchronous *)dxmt.query );
        ID3D11DeviceContext_Flush( dxmt.context );
        state->t_copied = now();
        while (ID3D11DeviceContext_GetData( dxmt.context, (ID3D11Asynchronous *)dxmt.query, NULL, 0, 0 ) == S_FALSE)
            SwitchToThread();
    }
    state->slot = slot;
    state->t_waited = now();

fail:
    pose = *flags & Submit_TextureWithPose;
    memcpy( out, in, pose ? sizeof(w_VRTextureWithPose_t) : sizeof(w_Texture_t) );
    /* A NULL Metal texture makes the unix side fail the Submit instead of the runtime aborting on a D3D11 one. */
    out->handle = state->slot ? (void *)(UINT_PTR)slot->mtl_texture : NULL;
    out->eType = TextureType_Metal;
    *flags = (*flags & ~(Submit_TextureWithMotion | Submit_VulkanTextureWithArrayData)) | pose;
    return out;
}

void macvr_free_texture_dxmt( struct macvr_submit *state )
{
    struct dxmt_slot *slot = state->slot;
    if (!slot) return;
    if (slot->keyed)
    {
        /* The game side's next AcquireSync(0) on this slot waits for nothing more: the copy is done. */
        D3DKMT_RELEASEKEYEDMUTEX rel = {slot->kmt_mutex, 0, state->fence};
        if (kmt.ReleaseKeyedMutex( &rel )) macvr_log( "D3DKMTReleaseKeyedMutex failed" );
    }
    stats_add( state, now() );
    state->slot = NULL;
}
