#pragma once

#include <CoreVideo/CoreVideo.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mvt_encoder mvt_encoder;

typedef enum mvt_codec {
    MVT_CODEC_HEVC = 0,
    MVT_CODEC_H264 = 1,
} mvt_codec;

typedef enum mvt_rate_mode {
    MVT_RATE_IMMEDIATE = 0,
    // Hysteresis for callers that retune every frame: cuts below 85% apply after holding 40 ms,
    // otherwise a smoothed target is applied at most once a second when it moves >15% up or >5% down.
    MVT_RATE_SMOOTH = 1,
} mvt_rate_mode;

typedef struct mvt_params {
    uint32_t width;
    uint32_t height;
    double fps;
    uint32_t bitrate_bps;
    bool ten_bit;           // HEVC Main10, input 'xf20'/'x420' (10 bits MSB-aligned in 16, like P010)
    uint32_t slices;        // 0/1 = one slice per frame
    mvt_codec codec;
    bool full_range;        // WiVRn's compositor writes full-range BT.709 YCbCr
    double vbv_seconds;     // 0 = one frame interval; clamped to [1/fps, 0.25]
    bool keep_filler;       // CBR pads with filler NALs; dropped unless set
    bool prewarm;           // encode one throwaway frame at create so the first real frame is fast
    double idr_rate_scale;  // mid-stream forced IDR: ConstantBitRate x scale for that frame only (0 = off)
} mvt_params;

typedef struct mvt_frame {
    const uint8_t *data;    // Annex B access unit; VPS/SPS/PPS prepended on IDR
    size_t size;
    uint64_t pts_ns;
    bool is_idr;
    int32_t status;         // OSStatus; data is empty when non-zero or the frame was dropped
    uint64_t encode_ns;     // submit to output, measured by the library
} mvt_frame;

// Runs on VideoToolbox's callback thread in async mode; data is only valid during the call.
typedef void (*mvt_output_cb)(void *user, const mvt_frame *frame);

void mvt_params_default(mvt_params *p, uint32_t width, uint32_t height);

// Returns NULL on failure; *status (optional) receives the OSStatus.
mvt_encoder *mvt_encoder_create(const mvt_params *params, int32_t *status);
void mvt_encoder_destroy(mvt_encoder *enc);

// Pool of IOSurface-backed buffers in the session's preferred layout; render into these to avoid a copy.
CVPixelBufferPoolRef mvt_encoder_pixel_buffer_pool(mvt_encoder *enc);
// Buffer from the pool (+1 reference); NULL on failure.
CVPixelBufferRef mvt_encoder_create_pixel_buffer(mvt_encoder *enc);

// Zero-copy input: an IOSurface-backed, Metal-compatible bi-planar 4:2:0 buffer in the encoder's input format
// ('420f'/'xf20' full range, '420v'/'x420' video range; 10-bit is MSB-aligned in 16). +1 reference, NULL on failure.
// Any number of them can be fed to mvt_encode_pixel_buffer* of an encoder with the same size and format.
CVPixelBufferRef mvt_create_input_buffer(uint32_t width, uint32_t height, bool ten_bit, bool full_range);
// +1 id<MTLTexture> on one plane of pb's IOSurface, for VK_EXT_metal_objects import (VkImportMetalTextureInfoEXT):
// plane 0 R8Unorm/R16Unorm, plane 1 RG8Unorm/RG16Unorm (half size); shader read/write. NULL on failure.
void *mvt_metal_plane_texture(void *mtl_device, CVPixelBufferRef pb, int plane);
void mvt_metal_release(void *obj);

// pts_ns: host time of the frame in any monotonic clock (0 = now, CLOCK_UPTIME_RAW). VT's PTS follows its spacing,
// clamped to [1 ns, 4 frame intervals]: rate control sizes frames from the spacing, and CBR fills every gap with filler.
int32_t mvt_encode_pixel_buffer(mvt_encoder *enc, CVPixelBufferRef pb, uint64_t pts_ns, bool force_idr,
                                mvt_output_cb cb, void *user);

// Copies NV12 (or 16-bit MSB-aligned P010 when ten_bit; strides in bytes) into a pool buffer, then encodes.
int32_t mvt_encode_nv12(mvt_encoder *enc, const uint8_t *y, size_t y_stride, const uint8_t *uv, size_t uv_stride,
                        uint64_t pts_ns, bool force_idr, mvt_output_cb cb, void *user);

// Sync helpers: block until the frame is out. out->data stays valid until the next encode call on enc.
int32_t mvt_encode_pixel_buffer_sync(mvt_encoder *enc, CVPixelBufferRef pb, uint64_t pts_ns, bool force_idr,
                                     mvt_frame *out);
int32_t mvt_encode_nv12_sync(mvt_encoder *enc, const uint8_t *y, size_t y_stride, const uint8_t *uv,
                             size_t uv_stride, uint64_t pts_ns, bool force_idr, mvt_frame *out);

// Waits for every submitted frame's callback.
int32_t mvt_flush(mvt_encoder *enc);

// Takes effect on the next encode. Changing the rate never needs an IDR with VideoToolbox.
void mvt_set_bitrate(mvt_encoder *enc, uint32_t bitrate_bps, mvt_rate_mode mode);
void mvt_set_framerate(mvt_encoder *enc, double fps);
uint32_t mvt_get_bitrate(const mvt_encoder *enc);

typedef struct mvt_stats {
    uint64_t frames;
    uint64_t bytes;
    uint64_t filler_bytes;
    uint64_t idr_frames;
    uint64_t rate_changes;
} mvt_stats;
void mvt_get_stats(const mvt_encoder *enc, mvt_stats *out);

#ifdef __cplusplus
}
#endif
