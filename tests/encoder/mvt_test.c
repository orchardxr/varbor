// mvt_test: paced synthetic encode through libmvt, bitstream checks, and PSNR against a decoded frame.
//   mvt_test encode [options]   writes <out>-s<N>.hevc (+ <out>-s<N>-from-idr.hevc starting at --idr-at)
//   mvt_test psnr [options] --stream N --frame K --yuv decoded.yuv   decoded = one yuv420p / yuv420p10le frame
// options: --width --height --streams --frames --fps --mbps (per stream) --ten-bit --slices --mode pool|copy|async
//          --sequential (one thread encodes the streams in turn, like WiVRn's encoder_work) --idr-at K --out prefix
//          --h264 --rate2 MBPS (switch at half time) --smooth (MVT_RATE_SMOOTH for --rate2)
#include "mvt.h"

#include <dispatch/dispatch.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct options {
    uint32_t width, height, streams, frames, slices, idr_at;
    double fps, mbps, rate2;
    bool smooth;
    bool ten_bit, sequential, h264;
    const char *mode, *out, *yuv;
    int stream, frame;
} options;

typedef struct stream_state {
    const options *o;
    int index;
    mvt_encoder *enc;
    uint8_t *y, *uv;
    size_t y_stride, uv_stride;
    FILE *file, *from_idr;
    double *call_ms, *vt_ms;
    size_t *sizes;
    uint64_t bytes;
    int idr_frames, bad_frames, failures;
    uint64_t submit_ns[1024];
    dispatch_semaphore_t async_done;
    CVPixelBufferRef pb;
    pthread_t thread;
} stream_state;

static int8_t g_sin[97], g_cos[61], g_u[53], g_v[71];

static void init_tables(void)
{
    for (int i = 0; i < 97; i++) {
        g_sin[i] = (int8_t)lrint(60 * sin(2 * M_PI * i / 97));
    }
    for (int i = 0; i < 61; i++) {
        g_cos[i] = (int8_t)lrint(60 * cos(2 * M_PI * i / 61));
    }
    for (int i = 0; i < 53; i++) {
        g_u[i] = (int8_t)lrint(50 * sin(2 * M_PI * i / 53));
    }
    for (int i = 0; i < 71; i++) {
        g_v[i] = (int8_t)lrint(50 * cos(2 * M_PI * i / 71));
    }
}

static inline uint32_t hash(uint32_t x, uint32_t y)
{
    uint32_t h = x * 374761393u + y * 668265263u;
    h = (h ^ (h >> 13)) * 1274126177u;
    return h ^ (h >> 16);
}

static inline int clamp8(int v)
{
    return v < 0 ? 0 : v > 255 ? 255 : v;
}

// Panning sine plaid + 16 px checkerboard + fixed fine texture + a moving disc; streams differ by a parallax shift.
static void gen_frame(int stream, int k, uint32_t w, uint32_t h, bool ten_bit, uint8_t *y, size_t y_stride,
                      uint8_t *uv, size_t uv_stride)
{
    int px = 4 * k + 7 * stream, py = 2 * k;
    int cx = (int)(w / 2 + (w / 3) * sin(k * 0.05)), cy = (int)(h / 2 + (h / 3) * cos(k * 0.037));
    int r2 = (int)(w / 12) * (int)(w / 12);
    for (uint32_t row = 0; row < h; row++) {
        int sy = (int)row + py;
        int dy = (int)row - cy;
        uint8_t *line8 = y + row * y_stride;
        uint16_t *line16 = (uint16_t *)line8;
        for (uint32_t col = 0; col < w; col++) {
            int sx = (int)col + px;
            int v = 128 + g_sin[sx % 97] * g_cos[sy % 61] / 60;
            v += ((sx >> 4) ^ (sy >> 4)) & 1 ? 25 : -25;
            v += (int)(hash((uint32_t)sx, (uint32_t)sy) & 15) - 8;
            int dx = (int)col - cx;
            if (dx * dx + dy * dy < r2) {
                v = 235 - (v >> 3);
            }
            v = clamp8(v);
            if (ten_bit) {
                line16[col] = (uint16_t)((v << 2 | v >> 6) << 6);
            } else {
                line8[col] = (uint8_t)v;
            }
        }
    }
    for (uint32_t row = 0; row < h / 2; row++) {
        uint8_t *line8 = uv + row * uv_stride;
        uint16_t *line16 = (uint16_t *)line8;
        int sy = (int)row + py / 2;
        for (uint32_t col = 0; col < w / 2; col++) {
            int sx = (int)col + px / 2;
            int u = clamp8(128 + g_u[(sx + sy / 3) % 53]);
            int v = clamp8(128 + g_v[(sy + 1000 - sx / 5) % 71]);
            if (ten_bit) {
                line16[2 * col] = (uint16_t)((u << 2 | u >> 6) << 6);
                line16[2 * col + 1] = (uint16_t)((v << 2 | v >> 6) << 6);
            } else {
                line8[2 * col] = (uint8_t)u;
                line8[2 * col + 1] = (uint8_t)v;
            }
        }
    }
}

static int nal_type(const options *o, uint8_t header)
{
    return o->h264 ? header & 0x1f : (header >> 1) & 0x3f;
}

// IDR: parameter sets before the first slice and IRAP slices; P: no parameter sets; never filler; Annex B only.
static bool check_au(const options *o, const mvt_frame *f)
{
    const uint8_t *d = f->data;
    size_t n = f->size;
    if (n < 5 || d[0] || d[1] || d[2] || d[3] != 1) {
        return false;
    }
    bool vps = o->h264, sps = false, pps = false, slice = false, ok = true;
    for (size_t i = 0; i + 4 < n; i++) {
        if (d[i] || d[i + 1] || d[i + 2] != 1) {
            continue;
        }
        int t = nal_type(o, d[i + 3]);
        i += 3;
        if (o->h264) {
            sps |= t == 7;
            pps |= t == 8;
            ok &= t != 12;
            if (t == 1 || t == 5) {
                ok &= f->is_idr ? (t == 5 && sps && pps) : t == 1;
                slice = true;
            }
        } else {
            vps |= t == 32;
            sps |= t == 33;
            pps |= t == 34;
            ok &= t != 38;
            if (t < 32) {
                ok &= f->is_idr ? (t >= 16 && t <= 21 && vps && sps && pps) : t < 16;
                slice = true;
            }
        }
    }
    if (!f->is_idr) {
        ok &= !sps && !pps;
    }
    return ok && slice;
}

static void record(stream_state *s, int k, const mvt_frame *f, double call_ms)
{
    if (f->status != 0 || !f->size) {
        s->failures++;
        return;
    }
    fwrite(f->data, 1, f->size, s->file);
    if (k >= (int)s->o->idr_at) {
        fwrite(f->data, 1, f->size, s->from_idr);
    }
    s->bytes += f->size;
    s->sizes[k] = f->size;
    s->idr_frames += f->is_idr;
    s->bad_frames += !check_au(s->o, f);
    s->vt_ms[k] = f->encode_ns / 1e6;
    s->call_ms[k] = call_ms;
}

typedef struct async_ctx {
    stream_state *s;
    int k;
} async_ctx;

static void async_cb(void *user, const mvt_frame *f)
{
    async_ctx *c = user;
    record(c->s, c->k, f, (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - c->s->submit_ns[c->k % 1024]) / 1e6);
    dispatch_semaphore_signal(c->s->async_done);
    free(c);
}

static void prepare(stream_state *s, int k)
{
    const options *o = s->o;
    if (!strcmp(o->mode, "copy")) {
        gen_frame(s->index, k, o->width, o->height, o->ten_bit, s->y, s->y_stride, s->uv, s->uv_stride);
        return;
    }
    s->pb = mvt_encoder_create_pixel_buffer(s->enc);
    if (!s->pb) {
        return;
    }
    CVPixelBufferLockBaseAddress(s->pb, 0);
    gen_frame(s->index, k, o->width, o->height, o->ten_bit, CVPixelBufferGetBaseAddressOfPlane(s->pb, 0),
              CVPixelBufferGetBytesPerRowOfPlane(s->pb, 0), CVPixelBufferGetBaseAddressOfPlane(s->pb, 1),
              CVPixelBufferGetBytesPerRowOfPlane(s->pb, 1));
    CVPixelBufferUnlockBaseAddress(s->pb, 0);
}

static void submit(stream_state *s, int k, uint64_t pts)
{
    const options *o = s->o;
    bool idr = k == (int)o->idr_at;
    mvt_frame f;
    if (o->rate2 > 0 && k >= (int)o->frames / 2) {
        mvt_set_bitrate(s->enc, (uint32_t)(o->rate2 * 1e6), o->smooth ? MVT_RATE_SMOOTH : MVT_RATE_IMMEDIATE);
    }
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (!strcmp(o->mode, "copy")) {
        int st = mvt_encode_nv12_sync(s->enc, s->y, s->y_stride, s->uv, s->uv_stride, pts, idr, &f);
        f.status = st;
        record(s, k, &f, (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6);
        return;
    }
    if (!s->pb) {
        s->failures++;
        if (!strcmp(o->mode, "async")) {
            dispatch_semaphore_signal(s->async_done);
        }
        return;
    }
    if (!strcmp(o->mode, "async")) {
        async_ctx *c = malloc(sizeof(*c));
        *c = (async_ctx){ s, k };
        s->submit_ns[k % 1024] = t0;
        if (mvt_encode_pixel_buffer(s->enc, s->pb, pts, idr, async_cb, c) != 0) {
            free(c);
            s->failures++;
            dispatch_semaphore_signal(s->async_done);
        }
    } else {
        int st = mvt_encode_pixel_buffer_sync(s->enc, s->pb, pts, idr, &f);
        f.status = st;
        record(s, k, &f, (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6);
    }
    CVPixelBufferRelease(s->pb);
    s->pb = NULL;
}

static uint64_t g_t0;

static void wait_until(uint64_t t)
{
    for (;;) {
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        if (now >= t) {
            return;
        }
        struct timespec ts = { 0, (long)(t - now) };
        nanosleep(&ts, NULL);
    }
}

static void *stream_thread(void *arg)
{
    stream_state *s = arg;
    const options *o = s->o;
    for (uint32_t k = 0; k < o->frames; k++) {
        uint64_t due = g_t0 + (uint64_t)(k * 1e9 / o->fps);
        prepare(s, (int)k);
        wait_until(due);
        submit(s, (int)k, due);
    }
    if (!strcmp(o->mode, "async")) {
        mvt_flush(s->enc);
        for (uint32_t k = 0; k < o->frames; k++) {
            dispatch_semaphore_wait(s->async_done, DISPATCH_TIME_FOREVER);
        }
    }
    return NULL;
}

static void *sequential_thread(void *arg)
{
    stream_state *s = arg;
    const options *o = s->o;
    for (uint32_t k = 0; k < o->frames; k++) {
        uint64_t due = g_t0 + (uint64_t)(k * 1e9 / o->fps);
        for (uint32_t i = 0; i < o->streams; i++) {
            prepare(&s[i], (int)k);
        }
        wait_until(due);
        for (uint32_t i = 0; i < o->streams; i++) {
            submit(&s[i], (int)k, due);
        }
    }
    return NULL;
}

static int cmp_double(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

static void percentiles(const char *name, double *v, size_t n, int skip)
{
    size_t m = n - (size_t)skip;
    double *c = malloc(m * sizeof(double));
    memcpy(c, v + skip, m * sizeof(double));
    qsort(c, m, sizeof(double), cmp_double);
    printf("    %-22s p50 %6.2f  p95 %6.2f  p99 %6.2f  max %6.2f ms  (first frame %.2f ms)\n", name, c[m / 2],
           c[(size_t)(m * 0.95)], c[(size_t)(m * 0.99)], c[m - 1], v[0]);
    free(c);
}

static int run_encode(const options *o)
{
    stream_state *s = calloc(o->streams, sizeof(stream_state));
    for (uint32_t i = 0; i < o->streams; i++) {
        mvt_params p;
        mvt_params_default(&p, o->width, o->height);
        p.fps = o->fps;
        p.bitrate_bps = (uint32_t)(o->mbps * 1e6);
        p.ten_bit = o->ten_bit;
        p.slices = o->slices;
        p.codec = o->h264 ? MVT_CODEC_H264 : MVT_CODEC_HEVC;
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        int32_t st;
        s[i].enc = mvt_encoder_create(&p, &st);
        if (!s[i].enc) {
            fprintf(stderr, "create failed: %d\n", st);
            return 1;
        }
        printf("stream %u: session + prewarm %.1f ms\n", i, (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6);
        s[i].o = o;
        s[i].index = (int)i;
        size_t bpp = o->ten_bit ? 2 : 1;
        s[i].y_stride = s[i].uv_stride = o->width * bpp;
        s[i].y = malloc(s[i].y_stride * o->height);
        s[i].uv = malloc(s[i].uv_stride * o->height / 2);
        char path[1024];
        const char *ext = o->h264 ? "h264" : "hevc";
        snprintf(path, sizeof(path), "%s-s%u.%s", o->out, i, ext);
        s[i].file = fopen(path, "wb");
        snprintf(path, sizeof(path), "%s-s%u-from-idr.%s", o->out, i, ext);
        s[i].from_idr = fopen(path, "wb");
        s[i].call_ms = calloc(o->frames, sizeof(double));
        s[i].vt_ms = calloc(o->frames, sizeof(double));
        s[i].sizes = calloc(o->frames, sizeof(size_t));
        s[i].async_done = dispatch_semaphore_create(0);
    }
    g_t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 20000000ULL;
    uint64_t start = g_t0;
    if (o->sequential) {
        pthread_t t;
        pthread_create(&t, NULL, sequential_thread, s);
        pthread_join(t, NULL);
    } else {
        for (uint32_t i = 0; i < o->streams; i++) {
            pthread_create(&s[i].thread, NULL, stream_thread, &s[i]);
        }
        for (uint32_t i = 0; i < o->streams; i++) {
            pthread_join(s[i].thread, NULL);
        }
    }
    double secs = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e9;
    int bad = 0;
    printf("%ux%u %s x%u streams%s, %u frames at %.0f fps (%.2f s), mode %s, %u slices, target %.1f Mbit/s per stream\n",
           o->width, o->height, o->h264 ? "H.264" : o->ten_bit ? "HEVC Main10" : "HEVC Main", o->streams,
           o->sequential ? " (sequential)" : "", o->frames, o->fps, secs, o->mode, o->slices ? o->slices : 1, o->mbps);
    for (uint32_t i = 0; i < o->streams; i++) {
        mvt_stats st;
        mvt_get_stats(s[i].enc, &st);
        double mbit = s[i].bytes * 8.0 / 1e6 / (o->frames / o->fps);
        size_t max_p = 0;
        for (uint32_t k = 1; k < o->frames; k++) {
            max_p = k != o->idr_at && s[i].sizes[k] > max_p ? s[i].sizes[k] : max_p;
        }
        double budget = o->mbps * 1e6 / 8 / o->fps;
        printf("  stream %u: %.1f Mbit/s (filler dropped %.1f Mbit/s), max P frame %zu B (%.1fx budget), IDR %d: "
               "first %zu B (%.1fx)",
               i, mbit, st.filler_bytes * 8.0 / 1e6 / (o->frames / o->fps), max_p, max_p / budget, s[i].idr_frames,
               s[i].sizes[0], s[i].sizes[0] / budget);
        if (o->idr_at < o->frames) {
            printf(", forced at %u %zu B (%.1fx)", o->idr_at, s[i].sizes[o->idr_at], s[i].sizes[o->idr_at] / budget);
        }
        printf("; bitstream check failures %d, encode failures %d\n", s[i].bad_frames, s[i].failures);
        if (o->rate2 > 0) {
            uint64_t half[2] = { 0, 0 };
            for (uint32_t k = 0; k < o->frames; k++) {
                if (k != o->idr_at && k) {
                    half[k >= o->frames / 2] += s[i].sizes[k];
                }
            }
            printf("    rate %.1f -> %.1f Mbit/s (%s) at frame %u: output %.1f -> %.1f Mbit/s, %llu rate changes, final %.1f\n",
                   o->mbps, o->rate2, o->smooth ? "smooth" : "immediate", o->frames / 2,
                   half[0] * 8.0 / 1e6 / (o->frames / 2 / o->fps), half[1] * 8.0 / 1e6 / (o->frames / 2 / o->fps),
                   (unsigned long long)st.rate_changes, mvt_get_bitrate(s[i].enc) / 1e6);
        }
        percentiles("encode call", s[i].call_ms, o->frames, 1);
        percentiles("VT submit->output", s[i].vt_ms, o->frames, 1);
        bad += s[i].bad_frames + s[i].failures + (s[i].idr_frames != 1 + (o->idr_at > 0 && o->idr_at < o->frames));
        fclose(s[i].file);
        fclose(s[i].from_idr);
        mvt_encoder_destroy(s[i].enc);
    }
    if (o->sequential && o->streams > 1) {
        double *sum = calloc(o->frames, sizeof(double));
        for (uint32_t k = 0; k < o->frames; k++) {
            for (uint32_t i = 0; i < o->streams; i++) {
                sum[k] += s[i].call_ms[k];
            }
        }
        percentiles("all streams in turn", sum, o->frames, 1);
        free(sum);
    }
    return bad ? 2 : 0;
}

static int run_psnr(const options *o)
{
    size_t w = o->width, h = o->height, bpp = o->ten_bit ? 2 : 1;
    uint8_t *y = malloc(w * h * bpp), *uv = malloc(w * h / 2 * bpp);
    gen_frame(o->stream, o->frame, o->width, o->height, o->ten_bit, y, w * bpp, uv, w * bpp);
    size_t plane[3] = { w * h, w * h / 4, w * h / 4 };
    size_t total = (plane[0] + plane[1] + plane[2]) * bpp;
    uint8_t *dec = malloc(total);
    FILE *f = fopen(o->yuv, "rb");
    if (!f || fread(dec, 1, total, f) != total) {
        fprintf(stderr, "cannot read %zu bytes from %s\n", total, o->yuv);
        return 1;
    }
    fclose(f);
    double peak = o->ten_bit ? 1023 : 255;
    double mse[3] = { 0 };
    size_t off = 0;
    for (int p = 0; p < 3; p++) {
        for (size_t i = 0; i < plane[p]; i++) {
            double src, d;
            if (p == 0) {
                src = o->ten_bit ? ((uint16_t *)y)[i] >> 6 : y[i];
            } else {
                size_t idx = 2 * i + (p - 1);
                src = o->ten_bit ? ((uint16_t *)uv)[idx] >> 6 : uv[idx];
            }
            d = o->ten_bit ? ((uint16_t *)(dec + off))[i] : dec[off + i];
            mse[p] += (src - d) * (src - d);
        }
        mse[p] /= plane[p];
        off += plane[p] * bpp;
    }
    double ps[3];
    for (int p = 0; p < 3; p++) {
        ps[p] = mse[p] > 0 ? 10 * log10(peak * peak / mse[p]) : 99;
    }
    double avg = 10 * log10(peak * peak / ((4 * mse[0] + mse[1] + mse[2]) / 6));
    printf("PSNR stream %d frame %d: Y %.2f U %.2f V %.2f avg %.2f dB\n", o->stream, o->frame, ps[0], ps[1], ps[2], avg);
    return 0;
}

int main(int argc, char **argv)
{
    options o = { .width = 1832, .height = 1920, .streams = 1, .frames = 300, .fps = 90, .mbps = 50,
                  .slices = 1, .idr_at = 120, .mode = "pool", .out = "out" };
    if (argc < 2) {
        fprintf(stderr, "usage: %s encode|psnr [options]\n", argv[0]);
        return 1;
    }
    for (int i = 2; i < argc; i++) {
        const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : "";
        if (!strcmp(a, "--ten-bit")) {
            o.ten_bit = true;
        } else if (!strcmp(a, "--sequential")) {
            o.sequential = true;
        } else if (!strcmp(a, "--smooth")) {
            o.smooth = true;
        } else if (!strcmp(a, "--rate2")) {
            o.rate2 = atof(v), i++;
        } else if (!strcmp(a, "--h264")) {
            o.h264 = true;
        } else if (!strcmp(a, "--width")) {
            o.width = (uint32_t)atoi(v), i++;
        } else if (!strcmp(a, "--height")) {
            o.height = (uint32_t)atoi(v), i++;
        } else if (!strcmp(a, "--streams")) {
            o.streams = (uint32_t)atoi(v), i++;
        } else if (!strcmp(a, "--frames")) {
            o.frames = (uint32_t)atoi(v), i++;
        } else if (!strcmp(a, "--slices")) {
            o.slices = (uint32_t)atoi(v), i++;
        } else if (!strcmp(a, "--idr-at")) {
            o.idr_at = (uint32_t)atoi(v), i++;
        } else if (!strcmp(a, "--fps")) {
            o.fps = atof(v), i++;
        } else if (!strcmp(a, "--mbps")) {
            o.mbps = atof(v), i++;
        } else if (!strcmp(a, "--mode")) {
            o.mode = v, i++;
        } else if (!strcmp(a, "--out")) {
            o.out = v, i++;
        } else if (!strcmp(a, "--yuv")) {
            o.yuv = v, i++;
        } else if (!strcmp(a, "--stream")) {
            o.stream = atoi(v), i++;
        } else if (!strcmp(a, "--frame")) {
            o.frame = atoi(v), i++;
        } else {
            fprintf(stderr, "unknown option %s\n", a);
            return 1;
        }
    }
    init_tables();
    if (!strcmp(argv[1], "encode")) {
        return run_encode(&o);
    }
    if (!strcmp(argv[1], "psnr") && o.yuv) {
        return run_psnr(&o);
    }
    fprintf(stderr, "bad command\n");
    return 1;
}
