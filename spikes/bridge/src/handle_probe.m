// Which Mach port kinds stock DXMT's import path (MTLSharedTextureHandle initWithMachPort:) accepts.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#include <mach/mach.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

@interface MTLSharedTextureHandle (SPI)
- (instancetype)initWithMachPort:(mach_port_t)port;
- (mach_port_t)createMachPort;
@end

static int g_fail;
#define CHECK(c, ...) do { printf("%s: ", (c) ? "PASS" : "FAIL"); printf(__VA_ARGS__); printf("\n"); if (!(c)) g_fail++; } while (0)

static IOSurfaceRef make_surface(int w, int h) {
	NSDictionary *p = @{
		(id)kIOSurfaceWidth : @(w), (id)kIOSurfaceHeight : @(h), (id)kIOSurfaceBytesPerElement : @4,
		(id)kIOSurfaceBytesPerRow : @(IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, w * 4)),
		(id)kIOSurfacePixelFormat : @((uint32_t)'BGRA'),
	};
	return IOSurfaceCreate((__bridge CFDictionaryRef)p);
}

static void fill_texture(id<MTLDevice> dev, id<MTLTexture> tex, uint32_t v) {
	id<MTLCommandQueue> q = [dev newCommandQueue];
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = tex;
	rp.colorAttachments[0].loadAction = MTLLoadActionClear;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	rp.colorAttachments[0].clearColor = MTLClearColorMake((v >> 16 & 255) / 255.0, (v >> 8 & 255) / 255.0, (v & 255) / 255.0, (v >> 24 & 255) / 255.0);
	id<MTLCommandBuffer> cb = [q commandBuffer];
	[[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
	[cb commit];
	[cb waitUntilCompleted];
}

// Case 1: IOSurface port -> initWithMachPort: -> newSharedTextureWithHandle: (child process, Metal may abort).
static void case_iosurface_port_as_shared_handle(void) {
	fflush(stdout);
	pid_t pid = fork();
	if (pid == 0) {
		@autoreleasepool {
			id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
			IOSurfaceRef s = make_surface(64, 32);
			mach_port_t port = IOSurfaceCreateMachPort(s);
			MTLSharedTextureHandle *h = [[MTLSharedTextureHandle alloc] initWithMachPort:port];
			printf("  handle=%p\n", h);
			id<MTLTexture> t = h ? [dev newSharedTextureWithHandle:h] : nil;
			printf("  texture=%p %lux%lu fmt=%lu iosurface=%p\n", t, t.width, t.height, (unsigned long)t.pixelFormat, t.iosurface);
			fflush(stdout);
			_exit(t ? 0 : 3);
		}
	}
	int st = 0;
	waitpid(pid, &st, 0);
	CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 3, "IOSurface Mach port rejected (expected)  by MTLSharedTextureHandle initWithMachPort: (status %#x)", st);
}

// Case 2: shared texture handle port -> IOSurfaceLookupFromMachPort.
static void case_shared_handle_port_as_iosurface(id<MTLDevice> dev) {
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:32 mipmapped:NO];
	d.storageMode = MTLStorageModePrivate;
	d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	id<MTLTexture> t = [dev newSharedTextureWithDescriptor:d];
	MTLSharedTextureHandle *h = [t newSharedTextureHandle];
	mach_port_t port = [h createMachPort];
	IOSurfaceRef s = IOSurfaceLookupFromMachPort(port);
	printf("  texture.iosurface=%p lookup=%p\n", t.iosurface, s);
	if (s) printf("  surface %zux%zu fmt=%#x bpr=%zu alloc=%zu planes=%zu\n", IOSurfaceGetWidth(s), IOSurfaceGetHeight(s), IOSurfaceGetPixelFormat(s), IOSurfaceGetBytesPerRow(s), IOSurfaceGetAllocSize(s), IOSurfaceGetPlaneCount(s));
	CHECK(s != NULL, "MTLSharedTextureHandle port usable as IOSurface port");
	if (s) CFRelease(s);
	mach_port_deallocate(mach_task_self(), port);
}

// Case 3: IOSurface-backed texture wrapped with newTextureWithDescriptor:iosurface:plane: and handed back out as a shared handle.
static void case_iosurface_texture_reexport(id<MTLDevice> dev) {
	IOSurfaceRef s = make_surface(64, 32);
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:32 mipmapped:NO];
	d.storageMode = MTLStorageModeShared;
	d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	id<MTLTexture> t = [dev newTextureWithDescriptor:d iosurface:s plane:0];
	fill_texture(dev, t, 0xff112233);
	IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
	uint32_t v = *(uint32_t *)IOSurfaceGetBaseAddress(s);
	IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
	CHECK(v == 0xff112233, "IOSurface texture render visible through IOSurface lock (%#x)", v);
	MTLSharedTextureHandle *h = nil;
	@try { h = [t newSharedTextureHandle]; } @catch (NSException *e) { printf("  exception %s\n", e.reason.UTF8String); }
	printf("  newSharedTextureHandle on IOSurface texture -> %p\n", h);
	CFRelease(s);
}

// Case 4: shared texture in a child (separate process, like the service), port sent back over a pipe-free route:
// the child registers nothing; we only verify the round trip within one process via port -> handle -> texture.
static void case_shared_handle_roundtrip(id<MTLDevice> dev) {
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:64 height:32 mipmapped:NO];
	d.storageMode = MTLStorageModePrivate;
	d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	id<MTLTexture> t = [dev newSharedTextureWithDescriptor:d];
	mach_port_t port = [[t newSharedTextureHandle] createMachPort];
	MTLSharedTextureHandle *h = [[MTLSharedTextureHandle alloc] initWithMachPort:port];
	id<MTLTexture> t2 = [dev newSharedTextureWithHandle:h];
	CHECK(t2 && t2.pixelFormat == MTLPixelFormatRGBA16Float && t2.width == 64,
	      "shared texture handle port round trip keeps format/size (fmt %lu)", (unsigned long)t2.pixelFormat);
}

int main(void) {
	@autoreleasepool {
		id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
		printf("arch: %s, device %s\n",
#if defined(__x86_64__)
		       "x86_64",
#else
		       "arm64",
#endif
		       dev.name.UTF8String);
		case_iosurface_port_as_shared_handle();
		case_shared_handle_port_as_iosurface(dev);
		case_iosurface_texture_reexport(dev);
		case_shared_handle_roundtrip(dev);
	}
	printf("%s\n", g_fail ? "SOME FAILED" : "ALL PASS");
	return g_fail ? 1 : 0;
}
