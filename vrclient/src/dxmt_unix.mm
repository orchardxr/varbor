/* Unix side of the DXMT submit path (dxmt_pe.c): imports DXMT's shared textures and keyed-mutex events from the
 * bootstrap namespace on the system default MTLDevice (the one OpenComposite's Metal session uses) and has
 * OpenComposite's copy wait for the events on its queue (oc_metal_submit_sync_begin), or waits for them on the CPU
 * with a runtime that lacks it. No Wine headers here: their BOOL clashes with Objective-C's. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <servers/bootstrap.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <stdio.h>
#include <time.h>

#include "varbor_unixlib.h"
#include "engine.h"

typedef int NTSTATUS;

@interface MTLSharedTextureHandle (VarborSPI)
- (instancetype)initWithMachPort:(mach_port_t)port;
@end

@protocol VarborMTLDeviceSPI <MTLDevice>
- (id<MTLSharedEvent>)newSharedEventWithMachPort:(mach_port_t)port;
@end

struct image
{
    id<MTLTexture> texture;
    id<MTLSharedEvent> event;
    /* Without a keyed mutex event: signalled by the runtime's copy, idle_value once the armed one is done */
    id<MTLSharedEvent> idle;
    uint64_t idle_value;
    uint64_t armed;
};

static id<MTLDevice> device;
static MTLSharedEventListener *listener;
static dispatch_once_t once;

static void (*oc_sync_begin)( void *wait_event, uint64_t wait_value, void *signal_event, uint64_t signal_value );
static int (*oc_sync_end)( void );

static bool gpu_sync(void)
{
    static dispatch_once_t resolve;
    dispatch_once( &resolve, ^{
        const char *env = getenv( "VRCLIENT_DXMT_GPU_SYNC" );
        if (env && !atoi( env )) return;
        oc_sync_begin = (decltype(oc_sync_begin))dlsym( RTLD_DEFAULT, "oc_metal_submit_sync_begin" );
        oc_sync_end = (decltype(oc_sync_end))dlsym( RTLD_DEFAULT, "oc_metal_submit_sync_end" );
        if (!oc_sync_end) oc_sync_begin = NULL;
    } );
    return oc_sync_begin != NULL;
}

/* For vk_unix.mm */
extern "C" void varbor_note( const char *msg );

extern "C" bool varbor_oc_sync( void (**begin)( void *, uint64_t, void *, uint64_t ), int (**end)( void ) )
{
    if (!gpu_sync()) return false;
    *begin = oc_sync_begin;
    *end = oc_sync_end;
    return true;
}

static int event_wait( id<MTLSharedEvent> event, uint64_t value, uint32_t timeout_ms )
{
    int result = 0;
    if (event.signaledValue < value)
    {
        dispatch_semaphore_t sem = dispatch_semaphore_create( 0 );
        [event notifyListener:listener atValue:value block:^(id<MTLSharedEvent> e, uint64_t v) {
            dispatch_semaphore_signal( sem );
        }];
        if (dispatch_semaphore_wait( sem, dispatch_time( DISPATCH_TIME_NOW, (int64_t)timeout_ms * NSEC_PER_MSEC ) ))
            result = event.signaledValue >= value ? 0 : 1;
        dispatch_release( sem );
    }
    return result;
}

static mach_port_t look_up( const char *name )
{
    mach_port_t port = MACH_PORT_NULL;
    if (bootstrap_look_up( bootstrap_port, name, &port ) != KERN_SUCCESS) return MACH_PORT_NULL;
    return port;
}

extern "C" NTSTATUS varbor_dxmt_import( void *args )
{
    struct varbor_dxmt_import_params *p = (struct varbor_dxmt_import_params *)args;
    struct image *img;
    mach_port_t port;

    p->image = p->texture = 0;
    dispatch_once( &once, ^{
        device = MTLCreateSystemDefaultDevice();
        listener = [[MTLSharedEventListener alloc] init];
    } );
    @autoreleasepool
    {
        port = look_up( p->texture_name );
        if (!MACH_PORT_VALID(port))
        {
            snprintf( p->info, sizeof(p->info), "bootstrap_look_up %s failed", p->texture_name );
            return 0;
        }
        MTLSharedTextureHandle *handle = [[MTLSharedTextureHandle alloc] initWithMachPort:port];
        id<MTLTexture> tex = handle ? [device newSharedTextureWithHandle:handle] : nil;
        [handle release];
        if (!tex)
        {
            snprintf( p->info, sizeof(p->info), "newSharedTextureWithHandle failed for %s", p->texture_name );
            return 0;
        }
        img = (struct image *)calloc( 1, sizeof(*img) );
        img->texture = tex;
        if (p->event_name[0])
        {
            port = look_up( p->event_name );
            if (MACH_PORT_VALID(port) && [device respondsToSelector:@selector(newSharedEventWithMachPort:)])
                img->event = [(id<VarborMTLDeviceSPI>)device newSharedEventWithMachPort:port];
            if (!img->event)
            {
                snprintf( p->info, sizeof(p->info), "keyed mutex event %s not importable", p->event_name );
                [tex release];
                free( img );
                return 0;
            }
        }
        else img->idle = [device newSharedEvent];
        snprintf( p->info, sizeof(p->info), "%s: %lux%lu MTLPixelFormat %lu, %s", p->texture_name,
                  (unsigned long)tex.width, (unsigned long)tex.height, (unsigned long)tex.pixelFormat,
                  img->event ? "event" : "no event" );
    }
    p->image = (uint64_t)(uintptr_t)img;
    p->texture = (uint64_t)(uintptr_t)img->texture;
    return 0;
}

extern "C" NTSTATUS varbor_dxmt_wait( void *args )
{
    struct varbor_dxmt_wait_params *p = (struct varbor_dxmt_wait_params *)args;
    struct image *img = (struct image *)(uintptr_t)p->image;
    uint64_t t0 = clock_gettime_nsec_np( CLOCK_UPTIME_RAW );
    bool gpu = p->gpu && gpu_sync();

    p->result = -1;
    p->gpu = 0;
    if (!img) return 0;
    if (gpu && img->event)
    {
        oc_sync_begin( (void *)img->event, p->value, (void *)img->event, p->value + 1 );
        p->gpu = 1;
        p->result = 0;
    }
    else if (gpu && img->idle)
    {
        img->armed = img->idle_value + 1;
        oc_sync_begin( NULL, 0, (void *)img->idle, img->armed );
        p->gpu = 1;
        p->result = 0;
    }
    else if (img->event) p->result = event_wait( img->event, p->value, p->timeout_ms );
    p->wait_ns = clock_gettime_nsec_np( CLOCK_UPTIME_RAW ) - t0;
    return 0;
}

extern "C" NTSTATUS varbor_dxmt_end( void *args )
{
    struct varbor_dxmt_end_params *p = (struct varbor_dxmt_end_params *)args;
    struct image *img = (struct image *)(uintptr_t)p->image;

    p->taken = oc_sync_end && oc_sync_end();
    if (img && img->armed)
    {
        if (p->taken) img->idle_value = img->armed;
        img->armed = 0;
    }
    return 0;
}

extern "C" NTSTATUS varbor_dxmt_idle( void *args )
{
    struct varbor_dxmt_idle_params *p = (struct varbor_dxmt_idle_params *)args;
    struct image *img = (struct image *)(uintptr_t)p->image;
    uint64_t t0 = clock_gettime_nsec_np( CLOCK_UPTIME_RAW );

    p->result = img && img->idle ? event_wait( img->idle, img->idle_value, p->timeout_ms ) : 0;
    p->wait_ns = clock_gettime_nsec_np( CLOCK_UPTIME_RAW ) - t0;
    return 0;
}

static struct
{
    id<MTLDevice> device;
    id<MTLSharedEvent> event;
    uint64_t value;
} direct;

extern "C" NTSTATUS varbor_dxmt_direct_begin( void *args )
{
    struct varbor_dxmt_direct_params *p = (struct varbor_dxmt_direct_params *)args;
    id<MTLDevice> device = (id<MTLDevice>)(uintptr_t)p->device;

    p->gpu = 0;
    p->signal_event = p->signal_value = 0;
    if (!gpu_sync() || !p->event || !device) return 0;
    if (direct.device != device)
    {
        [direct.event release];
        direct.device = device;
        direct.event = [device newSharedEvent];
        direct.value = 0;
    }
    if (!direct.event) return 0;
    p->signal_event = (uint64_t)(uintptr_t)direct.event;
    p->signal_value = ++direct.value;
    oc_sync_begin( (void *)(uintptr_t)p->event, p->value, (void *)direct.event, p->signal_value );
    static bool noted;
    if (!noted)
    {
        noted = true;
        varbor_note( "DXMT interop direct: the runtime reads the game's own MTLTexture" );
    }
    p->gpu = 1;
    return 0;
}

extern "C" NTSTATUS varbor_dxmt_direct_end( void *args )
{
    struct varbor_dxmt_direct_params *p = (struct varbor_dxmt_direct_params *)args;
    p->taken = oc_sync_end && oc_sync_end();
    return 0;
}

/* As wineopenxr's bridge_unsupported_device (bridge/src/dxmt_unix.m). */
extern "C" NTSTATUS varbor_unsupported_device( void *args )
{
    struct varbor_unsupported_device_params *p = (struct varbor_unsupported_device_params *)args;
    const char *dir = getenv( "STEAM_COMPAT_INSTALL_PATH" ), *slash;
    char game[256] = "This game", note[512];
    CFOptionFlags response = kCFUserNotificationDefaultResponse;
#ifdef __aarch64__
    const int arm64_wine = 1;
#else
    const int arm64_wine = 0;
#endif

    varbor_engine_description( getenv( "CX_GRAPHICS_BACKEND" ), arm64_wine, p->engine, sizeof(p->engine) );
    snprintf( note, sizeof(note), "the game's D3D11 runs on %s, neither DXMT nor DXVK: eye textures are not submitted",
              p->engine );
    varbor_note( note );
    if (dir && (slash = strrchr( dir, '/' )) && slash[1]) snprintf( game, sizeof(game), "%s", slash + 1 );
    @autoreleasepool
    {
        NSString *header = [NSString stringWithFormat:@"%s can't run in VR with this graphics backend", game];
        NSString *text = [NSString stringWithFormat:
            @"VarboR needs DXMT or DXVK, but the game's D3D11 runs on %s. The headset stays black.\n\n"
            @"In Steam, open the game's Properties → Compatibility and pick a VarboR compatibility tool (DXMT by default), "
            @"or set Graphics to DXMT, or add the launch option CX_GRAPHICS_BACKEND=dxmt %%command%%.\n\n"
            @"Run Anyway continues without VR video.", p->engine];
        CFUserNotificationDisplayAlert( 0, kCFUserNotificationCautionAlertLevel, NULL, NULL, NULL, (CFStringRef)header,
                                        (CFStringRef)text, CFSTR("Quit Game"), CFSTR("Run Anyway"), NULL, &response );
    }
    p->run_anyway = (response & 3) == kCFUserNotificationAlternateResponse;
    varbor_note( p->run_anyway ? "unsupported D3D11 engine: the user chose Run Anyway"
                               : "unsupported D3D11 engine: the user chose Quit Game" );
    return 0;
}

extern "C" NTSTATUS varbor_dxmt_destroy( void *args )
{
    struct varbor_dxmt_destroy_params *p = (struct varbor_dxmt_destroy_params *)args;
    struct image *img = (struct image *)(uintptr_t)p->image;
    if (!img) return 0;
    [img->texture release];
    [img->event release];
    [img->idle release];
    free( img );
    return 0;
}
