#include "mvt.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <VideoToolbox/VideoToolbox.h>
#include <dispatch/dispatch.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct mvt_encoder {
    VTCompressionSessionRef session;
    mvt_params params;
    OSType pixel_format;

    uint8_t *out;
    size_t out_size, out_cap;

    uint64_t last_in_pts_ns, vt_pts_ns;
    bool force_next_idr;
    bool idr_override;

    uint32_t bitrate_bps;
    double avg_bps;
    uint64_t cut_since, applied_ns;
    uint32_t cut_bps;
    _Atomic uint32_t requested_bps;
    _Atomic int requested_mode;
    _Atomic bool rate_pending;

    double fps;
    _Atomic uint32_t requested_fps_milli;

    dispatch_semaphore_t sync_done;
    mvt_frame sync_frame;
    dispatch_group_t inflight;

    mvt_stats stats;
};

typedef struct pending {
    mvt_output_cb cb;
    void *user;
    uint64_t pts_ns;
    uint64_t submit_ns;
} pending;

static const uint8_t k_start_code[4] = { 0, 0, 0, 1 };

static uint64_t now_ns(void)
{
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static void out_append(mvt_encoder *e, const void *data, size_t len)
{
    if (e->out_size + len > e->out_cap) {
        size_t cap = e->out_cap ? e->out_cap : 1 << 20;
        while (cap < e->out_size + len) {
            cap *= 2;
        }
        uint8_t *p = realloc(e->out, cap);
        if (!p) {
            return;
        }
        e->out = p;
        e->out_cap = cap;
    }
    memcpy(e->out + e->out_size, data, len);
    e->out_size += len;
}

static OSStatus parameter_set(mvt_encoder *e, CMFormatDescriptionRef fmt, size_t i, const uint8_t **ps, size_t *len,
                              size_t *count, int *nal_header_len)
{
    if (e->params.codec == MVT_CODEC_H264) {
        return CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, i, ps, len, count, nal_header_len);
    }
    return CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, i, ps, len, count, nal_header_len);
}

static int append_parameter_sets(mvt_encoder *e, CMFormatDescriptionRef fmt)
{
    size_t count = 0;
    int nal_header_len = 4;
    if (!fmt || parameter_set(e, fmt, 0, NULL, NULL, &count, &nal_header_len) != noErr) {
        return 4;
    }
    for (size_t i = 0; i < count; i++) {
        const uint8_t *ps;
        size_t len;
        if (parameter_set(e, fmt, i, &ps, &len, NULL, NULL) == noErr) {
            out_append(e, k_start_code, 4);
            out_append(e, ps, len);
        }
    }
    return nal_header_len;
}

static bool is_filler(const mvt_encoder *e, uint8_t header)
{
    if (e->params.codec == MVT_CODEC_H264) {
        return (header & 0x1f) == 12;
    }
    return ((header >> 1) & 0x3f) == 38;
}

static void on_encoded(void *ref, void *frame_ref, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sample)
{
    mvt_encoder *e = ref;
    pending *p = frame_ref;
    mvt_frame f = { .pts_ns = p->pts_ns, .status = status };
    e->out_size = 0;

    if (status == noErr && sample) {
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
        bool keyframe = true;
        if (attachments && CFArrayGetCount(attachments) > 0) {
            CFDictionaryRef dict = CFArrayGetValueAtIndex(attachments, 0);
            keyframe = !CFDictionaryContainsKey(dict, kCMSampleAttachmentKey_NotSync);
        }
        CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sample);
        int len_size = 4;
        if (keyframe) {
            len_size = append_parameter_sets(e, fmt);
        } else if (fmt) {
            parameter_set(e, fmt, 0, NULL, NULL, NULL, &len_size);
        }

        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
        size_t total = 0;
        char *data = NULL;
        CMBlockBufferRef contiguous = NULL;
        if (block && !CMBlockBufferIsRangeContiguous(block, 0, 0)) {
            CMBlockBufferCreateContiguous(NULL, block, NULL, NULL, 0, 0, 0, &contiguous);
            block = contiguous;
        }
        if (block && CMBlockBufferGetDataPointer(block, 0, NULL, &total, &data) == noErr) {
            const uint8_t *d = (const uint8_t *)data;
            size_t pos = 0;
            while (pos + (size_t)len_size <= total) {
                uint32_t nal_len = 0;
                for (int i = 0; i < len_size; i++) {
                    nal_len = (nal_len << 8) | d[pos + i];
                }
                pos += (size_t)len_size;
                if (nal_len == 0 || pos + nal_len > total) {
                    break;
                }
                if (!e->params.keep_filler && is_filler(e, d[pos])) {
                    e->stats.filler_bytes += nal_len + 4;
                } else {
                    out_append(e, k_start_code, 4);
                    out_append(e, d + pos, nal_len);
                }
                pos += nal_len;
            }
        }
        if (contiguous) {
            CFRelease(contiguous);
        }
        f.is_idr = keyframe;
        f.data = e->out;
        f.size = e->out_size;
        e->stats.frames++;
        e->stats.bytes += e->out_size;
        e->stats.idr_frames += keyframe;
    }
    f.encode_ns = now_ns() - p->submit_ns;
    if (p->cb) {
        p->cb(p->user, &f);
    }
    free(p);
    dispatch_group_leave(e->inflight);
}

static void set_prop(VTCompressionSessionRef s, CFStringRef key, CFTypeRef value)
{
    OSStatus st = VTSessionSetProperty(s, key, value);
    if (st != noErr) {
        char name[128] = "";
        CFStringGetCString(key, name, sizeof(name), kCFStringEncodingUTF8);
        fprintf(stderr, "mvt: %s not accepted (%d)\n", name, (int)st);
    }
}

static void set_int(VTCompressionSessionRef s, CFStringRef key, int32_t v)
{
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt32Type, &v);
    set_prop(s, key, n);
    CFRelease(n);
}

static void set_double(VTCompressionSessionRef s, CFStringRef key, double v)
{
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberDoubleType, &v);
    set_prop(s, key, n);
    CFRelease(n);
}

// CBR without low-latency rate control: the hardware encodes frames up to ~7 Mpixel ~40% faster than with it
// (1024x4096 9.4 -> 5.4 ms on M4 Max), and CBR caps bursts.
static void apply_bitrate(mvt_encoder *e, uint32_t bps)
{
    set_int(e->session, kVTCompressionPropertyKey_ConstantBitRate, (int32_t)bps);
    e->bitrate_bps = bps;
    e->avg_bps = bps;
    e->cut_since = 0;
    e->applied_ns = now_ns();
    e->stats.rate_changes++;
}

// Every VT rate change restarts its rate control and the next frame bursts to 3-10x the per-frame budget, so a
// caller that retunes every frame is filtered.
static void smooth_bitrate(mvt_encoder *e, uint32_t bps)
{
    uint64_t now = now_ns();
    uint32_t cur = e->bitrate_bps;
    if ((uint64_t)bps * 20 < (uint64_t)cur * 17) {
        if (!e->cut_since) {
            e->cut_since = now;
            e->cut_bps = bps;
        }
        e->cut_bps = bps > e->cut_bps ? bps : e->cut_bps;
        if (now - e->cut_since >= 40000000ULL) {
            apply_bitrate(e, e->cut_bps);
            return;
        }
    } else {
        e->cut_since = 0;
    }
    e->avg_bps = e->avg_bps > 0 ? e->avg_bps + 0.05 * ((double)bps - e->avg_bps) : bps;
    if (!e->cut_since && now - e->applied_ns >= 1000000000ULL &&
        (e->avg_bps * 20 > cur * 23.0 || e->avg_bps * 20 < cur * 19.0)) {
        apply_bitrate(e, (uint32_t)e->avg_bps);
    }
}

static void update_rate(mvt_encoder *e)
{
    uint32_t req = atomic_load(&e->requested_bps);
    if (req) {
        if (atomic_load(&e->requested_mode) == MVT_RATE_SMOOTH) {
            smooth_bitrate(e, req);
        } else if (atomic_exchange(&e->rate_pending, false) && req != e->bitrate_bps) {
            apply_bitrate(e, req);
        }
    }
    uint32_t fps_milli = atomic_exchange(&e->requested_fps_milli, 0);
    if (fps_milli) {
        double fps = fps_milli / 1000.0;
        // VT sizes frames from PTS spacing and follows a cadence change within 1-2 s; ExpectedFrameRate is a hint.
        // VBV is left alone: changing it restarts rate control.
        if (fps > e->fps * 1.01 || fps < e->fps * 0.99) {
            e->fps = fps;
            set_int(e->session, kVTCompressionPropertyKey_ExpectedFrameRate, (int32_t)(fps + 0.5));
        }
    }
}

void mvt_params_default(mvt_params *p, uint32_t width, uint32_t height)
{
    memset(p, 0, sizeof(*p));
    p->width = width;
    p->height = height;
    p->fps = 90;
    p->bitrate_bps = 50000000;
    p->codec = MVT_CODEC_HEVC;
    p->full_range = true;
    p->slices = 1;
    p->prewarm = true;
}

static OSType pixel_format_for(const mvt_params *p)
{
    if (p->ten_bit) {
        return p->full_range ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                             : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
    }
    return p->full_range ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                         : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
}

static void fill_black(mvt_encoder *e, CVPixelBufferRef pb)
{
    CVPixelBufferLockBaseAddress(pb, 0);
    for (size_t plane = 0; plane < 2; plane++) {
        uint8_t *dst = CVPixelBufferGetBaseAddressOfPlane(pb, plane);
        size_t pitch = CVPixelBufferGetBytesPerRowOfPlane(pb, plane);
        size_t rows = CVPixelBufferGetHeightOfPlane(pb, plane);
        if (!e->params.ten_bit) {
            memset(dst, plane ? 128 : (e->params.full_range ? 0 : 16), pitch * rows);
            continue;
        }
        uint16_t v = plane ? 0x8000 : (e->params.full_range ? 0 : 64 << 6);
        for (size_t y = 0; y < rows; y++) {
            uint16_t *row = (uint16_t *)(dst + y * pitch);
            for (size_t x = 0; x < pitch / 2; x++) {
                row[x] = v;
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
}

mvt_encoder *mvt_encoder_create(const mvt_params *params, int32_t *status)
{
    OSStatus st = kVTParameterErr;
    mvt_encoder *e = NULL;
    if (!params || !params->width || !params->height || (params->ten_bit && params->codec == MVT_CODEC_H264)) {
        goto fail;
    }
    e = calloc(1, sizeof(*e));
    e->params = *params;
    if (e->params.fps <= 0) {
        e->params.fps = 90;
    }
    if (!e->params.bitrate_bps) {
        e->params.bitrate_bps = 50000000;
    }
    e->fps = e->params.fps;
    e->pixel_format = pixel_format_for(&e->params);
    e->sync_done = dispatch_semaphore_create(0);
    e->inflight = dispatch_group_create();

    const void *spec_keys[] = { kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder };
    const void *spec_values[] = { kCFBooleanTrue };
    CFDictionaryRef spec = CFDictionaryCreate(NULL, spec_keys, spec_values, 1, &kCFTypeDictionaryKeyCallBacks,
                                              &kCFTypeDictionaryValueCallBacks);
    int32_t pf = (int32_t)e->pixel_format;
    CFNumberRef pf_num = CFNumberCreate(NULL, kCFNumberSInt32Type, &pf);
    CFDictionaryRef iosurface = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                   &kCFTypeDictionaryValueCallBacks);
    const void *attr_keys[] = { kCVPixelBufferPixelFormatTypeKey, kCVPixelBufferIOSurfacePropertiesKey,
                                kCVPixelBufferMetalCompatibilityKey };
    const void *attr_values[] = { pf_num, iosurface, kCFBooleanTrue };
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, attr_keys, attr_values, 3, &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    CFRelease(pf_num);
    CFRelease(iosurface);
    CMVideoCodecType codec = e->params.codec == MVT_CODEC_H264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC;
    st = VTCompressionSessionCreate(NULL, (int32_t)e->params.width, (int32_t)e->params.height, codec, spec, attrs,
                                    NULL, on_encoded, e, &e->session);
    CFRelease(spec);
    CFRelease(attrs);
    if (st != noErr) {
        fprintf(stderr, "mvt: VTCompressionSessionCreate %ux%u failed: %d\n", e->params.width, e->params.height,
                (int)st);
        goto fail;
    }

    VTCompressionSessionRef s = e->session;
    set_prop(s, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    set_prop(s, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    set_prop(s, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue);
    CFStringRef profile = e->params.codec == MVT_CODEC_H264 ? kVTProfileLevel_H264_High_AutoLevel
                          : e->params.ten_bit                ? kVTProfileLevel_HEVC_Main10_AutoLevel
                                                             : kVTProfileLevel_HEVC_Main_AutoLevel;
    set_prop(s, kVTCompressionPropertyKey_ProfileLevel, profile);
    // Keyframes only on request (WiVRn's idr_handler, ForceKeyFrame).
    set_int(s, kVTCompressionPropertyKey_MaxKeyFrameInterval, 0x7fffffff);
    set_int(s, kVTCompressionPropertyKey_ExpectedFrameRate, (int32_t)(e->fps + 0.5));
    set_int(s, kVTCompressionPropertyKey_ConstantBitRate, (int32_t)e->params.bitrate_bps);
    // A short VBV keeps CBR frames near the per-frame budget; below ~0.25 s the hardware behaves the same.
    double vbv = e->params.vbv_seconds > 0 ? e->params.vbv_seconds : 1.0 / e->fps;
    vbv = vbv < 1.0 / e->fps ? 1.0 / e->fps : vbv > 0.25 ? 0.25 : vbv;
    set_double(s, kVTCompressionPropertyKey_VBVBufferDuration, vbv);
    set_prop(s, kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2);
    set_prop(s, kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2);
    set_prop(s, kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2);
    if (e->params.slices > 1) {
        set_int(s, CFSTR("NumberOfSlices"), (int32_t)e->params.slices);
    }
    VTCompressionSessionPrepareToEncodeFrames(s);
    e->bitrate_bps = e->params.bitrate_bps;
    e->avg_bps = e->bitrate_bps;
    e->applied_ns = now_ns();

    if (e->params.prewarm) {
        CVPixelBufferRef pb = mvt_encoder_create_pixel_buffer(e);
        if (pb) {
            fill_black(e, pb);
            mvt_frame f;
            mvt_encode_pixel_buffer_sync(e, pb, 0, true, &f);
            CVPixelBufferRelease(pb);
        }
        memset(&e->stats, 0, sizeof(e->stats));
        e->force_next_idr = true;
        e->last_in_pts_ns = 0;
    }
    if (status) {
        *status = noErr;
    }
    return e;

fail:
    if (status) {
        *status = st;
    }
    mvt_encoder_destroy(e);
    return NULL;
}

void mvt_encoder_destroy(mvt_encoder *e)
{
    if (!e) {
        return;
    }
    if (e->session) {
        VTCompressionSessionCompleteFrames(e->session, kCMTimeInvalid);
        dispatch_group_wait(e->inflight, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        VTCompressionSessionInvalidate(e->session);
        CFRelease(e->session);
    }
    if (e->sync_done) {
        dispatch_release(e->sync_done);
    }
    if (e->inflight) {
        dispatch_release(e->inflight);
    }
    free(e->out);
    free(e);
}

CVPixelBufferPoolRef mvt_encoder_pixel_buffer_pool(mvt_encoder *e)
{
    return e && e->session ? VTCompressionSessionGetPixelBufferPool(e->session) : NULL;
}

CVPixelBufferRef mvt_encoder_create_pixel_buffer(mvt_encoder *e)
{
    CVPixelBufferPoolRef pool = mvt_encoder_pixel_buffer_pool(e);
    CVPixelBufferRef pb = NULL;
    if (!pool || CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &pb) != kCVReturnSuccess) {
        return NULL;
    }
    return pb;
}

int32_t mvt_encode_pixel_buffer(mvt_encoder *e, CVPixelBufferRef pb, uint64_t pts_ns, bool force_idr,
                                mvt_output_cb cb, void *user)
{
    if (!e || !e->session || !pb) {
        return kVTParameterErr;
    }
    update_rate(e);
    if (!pts_ns) {
        pts_ns = now_ns();
    }
    // CBR emits filler for the whole PTS gap: a long gap (pause, or the caller's clock differing from the prewarm's)
    // made VT generate gigabytes of filler and stall for tens of seconds. So VT gets its own clamped timeline.
    uint64_t max_step = (uint64_t)(4e9 / e->fps);
    uint64_t step = e->last_in_pts_ns && pts_ns > e->last_in_pts_ns ? pts_ns - e->last_in_pts_ns
                    : e->last_in_pts_ns                             ? 1
                                                                    : (uint64_t)(1e9 / e->fps);
    e->vt_pts_ns += step < max_step ? step : max_step;
    e->last_in_pts_ns = pts_ns;

    // VT encodes a forced IDR at the P-frame QP (~26x the frame budget); MinAllowedFrameQP is ignored after creation.
    if (e->idr_override) {
        set_int(e->session, kVTCompressionPropertyKey_ConstantBitRate, (int32_t)e->bitrate_bps);
        e->idr_override = false;
    }
    if (force_idr && !e->force_next_idr && e->stats.frames > 0 && e->params.idr_rate_scale > 0) {
        set_int(e->session, kVTCompressionPropertyKey_ConstantBitRate, (int32_t)(e->bitrate_bps * e->params.idr_rate_scale));
        e->idr_override = true;
    }

    CFDictionaryRef opts = NULL;
    if (force_idr || e->force_next_idr) {
        const void *k[] = { kVTEncodeFrameOptionKey_ForceKeyFrame };
        const void *v[] = { kCFBooleanTrue };
        opts = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        e->force_next_idr = false;
    }
    pending *p = malloc(sizeof(*p));
    *p = (pending){ .cb = cb, .user = user, .pts_ns = pts_ns, .submit_ns = now_ns() };
    dispatch_group_enter(e->inflight);
    OSStatus st = VTCompressionSessionEncodeFrame(e->session, pb, CMTimeMake((int64_t)e->vt_pts_ns, 1000000000), kCMTimeInvalid,
                                                  opts, p, NULL);
    if (opts) {
        CFRelease(opts);
    }
    if (st != noErr) {
        // VT doesn't call back for a frame it rejected.
        free(p);
        dispatch_group_leave(e->inflight);
    }
    return st;
}

static int32_t copy_nv12(mvt_encoder *e, CVPixelBufferRef pb, const uint8_t *y, size_t y_stride, const uint8_t *uv,
                         size_t uv_stride)
{
    if (CVPixelBufferLockBaseAddress(pb, 0) != kCVReturnSuccess) {
        return kVTParameterErr;
    }
    const uint8_t *src[2] = { y, uv };
    size_t src_stride[2] = { y_stride, uv_stride };
    size_t row_bytes = (size_t)e->params.width * (e->params.ten_bit ? 2 : 1);
    for (size_t plane = 0; plane < 2; plane++) {
        uint8_t *dst = CVPixelBufferGetBaseAddressOfPlane(pb, plane);
        size_t pitch = CVPixelBufferGetBytesPerRowOfPlane(pb, plane);
        size_t rows = (plane ? (e->params.height + 1) / 2 : e->params.height);
        if (pitch == src_stride[plane]) {
            memcpy(dst, src[plane], pitch * rows);
        } else {
            for (size_t r = 0; r < rows; r++) {
                memcpy(dst + r * pitch, src[plane] + r * src_stride[plane], row_bytes);
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return noErr;
}

int32_t mvt_encode_nv12(mvt_encoder *e, const uint8_t *y, size_t y_stride, const uint8_t *uv, size_t uv_stride,
                        uint64_t pts_ns, bool force_idr, mvt_output_cb cb, void *user)
{
    CVPixelBufferRef pb = mvt_encoder_create_pixel_buffer(e);
    if (!pb) {
        return kCVReturnAllocationFailed;
    }
    int32_t st = copy_nv12(e, pb, y, y_stride, uv, uv_stride);
    if (st == noErr) {
        st = mvt_encode_pixel_buffer(e, pb, pts_ns, force_idr, cb, user);
    }
    CVPixelBufferRelease(pb);
    return st;
}

static void sync_cb(void *user, const mvt_frame *f)
{
    mvt_encoder *e = user;
    e->sync_frame = *f;
    dispatch_semaphore_signal(e->sync_done);
}

int32_t mvt_encode_pixel_buffer_sync(mvt_encoder *e, CVPixelBufferRef pb, uint64_t pts_ns, bool force_idr,
                                     mvt_frame *out)
{
    int32_t st = mvt_encode_pixel_buffer(e, pb, pts_ns, force_idr, sync_cb, e);
    if (st != noErr) {
        return st;
    }
    if (dispatch_semaphore_wait(e->sync_done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) != 0) {
        return kVTVideoEncoderNotAvailableNowErr;
    }
    if (out) {
        *out = e->sync_frame;
    }
    return e->sync_frame.status;
}

int32_t mvt_encode_nv12_sync(mvt_encoder *e, const uint8_t *y, size_t y_stride, const uint8_t *uv, size_t uv_stride,
                             uint64_t pts_ns, bool force_idr, mvt_frame *out)
{
    CVPixelBufferRef pb = mvt_encoder_create_pixel_buffer(e);
    if (!pb) {
        return kCVReturnAllocationFailed;
    }
    int32_t st = copy_nv12(e, pb, y, y_stride, uv, uv_stride);
    if (st == noErr) {
        st = mvt_encode_pixel_buffer_sync(e, pb, pts_ns, force_idr, out);
    }
    CVPixelBufferRelease(pb);
    return st;
}

int32_t mvt_flush(mvt_encoder *e)
{
    if (!e || !e->session) {
        return kVTParameterErr;
    }
    OSStatus st = VTCompressionSessionCompleteFrames(e->session, kCMTimeInvalid);
    dispatch_group_wait(e->inflight, DISPATCH_TIME_FOREVER);
    return st;
}

void mvt_set_bitrate(mvt_encoder *e, uint32_t bitrate_bps, mvt_rate_mode mode)
{
    atomic_store(&e->requested_mode, (int)mode);
    atomic_store(&e->requested_bps, bitrate_bps);
    atomic_store(&e->rate_pending, true);
}

void mvt_set_framerate(mvt_encoder *e, double fps)
{
    if (fps > 0) {
        atomic_store(&e->requested_fps_milli, (uint32_t)(fps * 1000 + 0.5));
    }
}

uint32_t mvt_get_bitrate(const mvt_encoder *e)
{
    return e->bitrate_bps;
}

void mvt_get_stats(const mvt_encoder *e, mvt_stats *out)
{
    *out = e->stats;
}
