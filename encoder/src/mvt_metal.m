#include "mvt.h"

#import <Metal/Metal.h>

CVPixelBufferRef mvt_create_input_buffer(uint32_t width, uint32_t height, bool ten_bit, bool full_range)
{
    OSType pf;
    if (ten_bit)
        pf = full_range ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
    else
        pf = full_range ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CVPixelBufferRef pb = NULL;
    CVReturn r;
    @autoreleasepool {
        NSDictionary *attrs = @{
            (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
            (id)kCVPixelBufferMetalCompatibilityKey : @YES,
        };
        r = CVPixelBufferCreate(NULL, width, height, pf, (CFDictionaryRef)attrs, &pb);
    }
    if (r != kCVReturnSuccess || !CVPixelBufferGetIOSurface(pb)) {
        fprintf(stderr, "mvt: CVPixelBufferCreate %ux%u '%c%c%c%c' failed: %d\n", width, height, (pf >> 24) & 0xff,
                (pf >> 16) & 0xff, (pf >> 8) & 0xff, pf & 0xff, r);
        if (pb)
            CVPixelBufferRelease(pb);
        return NULL;
    }
    return pb;
}

void *mvt_metal_plane_texture(void *mtl_device, CVPixelBufferRef pb, int plane)
{
    IOSurfaceRef surf = CVPixelBufferGetIOSurface(pb);
    if (!surf || plane < 0 || (size_t)plane >= CVPixelBufferGetPlaneCount(pb))
        return NULL;
    size_t bpe = IOSurfaceGetBytesPerElementOfPlane(surf, plane);
    MTLPixelFormat fmt;
    switch (bpe) {
    case 1: fmt = MTLPixelFormatR8Unorm; break;
    case 2: fmt = plane == 0 ? MTLPixelFormatR16Unorm : MTLPixelFormatRG8Unorm; break;
    case 4: fmt = MTLPixelFormatRG16Unorm; break;
    default: return NULL;
    }
    @autoreleasepool {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt
                                                                                     width:CVPixelBufferGetWidthOfPlane(pb, plane)
                                                                                    height:CVPixelBufferGetHeightOfPlane(pb, plane)
                                                                                 mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
        d.storageMode = MTLStorageModeShared;
        return [(id<MTLDevice>)mtl_device newTextureWithDescriptor:d iosurface:surf plane:(NSUInteger)plane];
    }
}

void mvt_metal_release(void *obj)
{
    if (obj)
        [(id)obj release];
}
