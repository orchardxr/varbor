/* Unix side of the DXMT submit path (dxmt_pe.c): imports DXMT's shared textures and keyed-mutex events from the
 * bootstrap namespace on the system default MTLDevice (the one OpenComposite's Metal session uses) and waits for the
 * events on the CPU. No Wine headers here: their BOOL clashes with Objective-C's. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <servers/bootstrap.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <time.h>

#include "macvr_unixlib.h"

typedef int NTSTATUS;

@interface MTLSharedTextureHandle (MacvrSPI)
- (instancetype)initWithMachPort:(mach_port_t)port;
@end

@protocol MacvrMTLDeviceSPI <MTLDevice>
- (id<MTLSharedEvent>)newSharedEventWithMachPort:(mach_port_t)port;
@end

struct image
{
    id<MTLTexture> texture;
    id<MTLSharedEvent> event;
};

static id<MTLDevice> device;
static MTLSharedEventListener *listener;
static dispatch_once_t once;

static mach_port_t look_up( const char *name )
{
    mach_port_t port = MACH_PORT_NULL;
    if (bootstrap_look_up( bootstrap_port, name, &port ) != KERN_SUCCESS) return MACH_PORT_NULL;
    return port;
}

extern "C" NTSTATUS macvr_dxmt_import( void *args )
{
    struct macvr_dxmt_import_params *p = (struct macvr_dxmt_import_params *)args;
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
                img->event = [(id<MacvrMTLDeviceSPI>)device newSharedEventWithMachPort:port];
            if (!img->event)
            {
                snprintf( p->info, sizeof(p->info), "keyed mutex event %s not importable", p->event_name );
                [tex release];
                free( img );
                return 0;
            }
        }
        snprintf( p->info, sizeof(p->info), "%s: %lux%lu MTLPixelFormat %lu, %s", p->texture_name,
                  (unsigned long)tex.width, (unsigned long)tex.height, (unsigned long)tex.pixelFormat,
                  img->event ? "event" : "no event" );
    }
    p->image = (uint64_t)(uintptr_t)img;
    p->texture = (uint64_t)(uintptr_t)img->texture;
    return 0;
}

extern "C" NTSTATUS macvr_dxmt_wait( void *args )
{
    struct macvr_dxmt_wait_params *p = (struct macvr_dxmt_wait_params *)args;
    struct image *img = (struct image *)(uintptr_t)p->image;
    uint64_t t0 = clock_gettime_nsec_np( CLOCK_UPTIME_RAW );

    p->result = -1;
    if (!img || !img->event) return 0;
    p->result = 0;
    if (img->event.signaledValue < p->value)
    {
        dispatch_semaphore_t sem = dispatch_semaphore_create( 0 );
        [img->event notifyListener:listener atValue:p->value block:^(id<MTLSharedEvent> e, uint64_t v) {
            dispatch_semaphore_signal( sem );
        }];
        if (dispatch_semaphore_wait( sem, dispatch_time( DISPATCH_TIME_NOW, (int64_t)p->timeout_ms * NSEC_PER_MSEC ) ))
            p->result = img->event.signaledValue >= p->value ? 0 : 1;
        dispatch_release( sem );
    }
    p->wait_ns = clock_gettime_nsec_np( CLOCK_UPTIME_RAW ) - t0;
    return 0;
}

extern "C" NTSTATUS macvr_dxmt_destroy( void *args )
{
    struct macvr_dxmt_destroy_params *p = (struct macvr_dxmt_destroy_params *)args;
    struct image *img = (struct image *)(uintptr_t)p->image;
    if (!img) return 0;
    [img->texture release];
    [img->event release];
    free( img );
    return 0;
}
