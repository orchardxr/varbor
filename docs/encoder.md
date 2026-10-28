# Encoder: libmvt (VideoToolbox HEVC/H.264)

`encoder/` builds `libmvt.a`, a small C library (header `encoder/include/mvt.h`, `extern "C"`) holding the
VideoToolbox session code from an earlier private prototype. It is the core of WiVRn's
`video_encoder_vt` backend (plan decision D5, step 5). Test harness: `tests/encoder/` (`run.sh`).

## API

| Call | What it does |
|---|---|
| `mvt_params_default(&p, w, h)` then `mvt_encoder_create(&p, &status)` | Hardware-only session. `p`: `width`, `height`, `fps`, `bitrate_bps`, `ten_bit` (HEVC Main10), `slices`, `codec` (`MVT_CODEC_HEVC` / `MVT_CODEC_H264`), `full_range` (default true), `vbv_seconds` (0 = one frame), `keep_filler`, `prewarm` (default true), `idr_rate_scale` (0 = off, see "Forced IDR size"). |
| `mvt_encoder_pixel_buffer_pool` / `mvt_encoder_create_pixel_buffer` | The session's IOSurface-backed, Metal-compatible pool (`420f`/`xf20` when full range). Render or copy into these buffers so VT doesn't have to copy. |
| `mvt_create_input_buffer(w, h, ten_bit, full_range)` | A standalone IOSurface-backed, Metal-compatible `420f`/`xf20` (`420v`/`x420`) CVPixelBuffer, for zero-copy rendering (WiVRn's encode images). |
| `mvt_metal_plane_texture(mtl_device, pb, plane)` / `mvt_metal_release` | +1 `MTLTexture` on one IOSurface plane (R8/R16 luma, RG8/RG16 half-size chroma, shader read/write), to import into Vulkan with `VkImportMetalTextureInfoEXT`. |
| `mvt_encode_pixel_buffer(enc, pb, pts_ns, force_idr, cb, user)` | Async: `cb(user, const mvt_frame*)` runs on VT's callback thread; `frame->data` is valid only during the call. |
| `mvt_encode_nv12(enc, y, y_stride, uv, uv_stride, ...)` | Copies NV12 (or P010-style 16-bit MSB-aligned when `ten_bit`) into a pool buffer, then encodes. |
| `mvt_encode_pixel_buffer_sync` / `mvt_encode_nv12_sync(..., mvt_frame *out)` | Blocks until the frame is out. `out->data` stays valid until the next encode call on that encoder. |
| `mvt_flush` | Waits for all callbacks. |
| `mvt_set_bitrate(enc, bps, MVT_RATE_IMMEDIATE / MVT_RATE_SMOOTH)` | Applied at the next encode. SMOOTH is a hysteresis for callers that retune every frame: cuts below 85% apply after holding 40 ms; otherwise a smoothed target (alpha 0.05/frame) is applied at most once a second when it is more than 15% above or 5% below the current rate. A rate change does not need an IDR. |
| `mvt_set_framerate` | Updates ExpectedFrameRate (only a hint: VT sizes frames from the PTS spacing). VBV is never changed after creation because that restarts rate control. |
| `mvt_get_stats` | Frames, bytes, dropped filler bytes, IDRs, rate changes. |

`mvt_frame`: `data`/`size` (Annex B access unit), `pts_ns`, `is_idr`, `status` (OSStatus), `encode_ns` (submit to output).

Session settings (same as the earlier prototype): RealTime, no frame reordering, PrioritizeEncodingSpeedOverQuality,
ProfileLevel Main/Main10 AutoLevel (H.264 High AutoLevel), MaxKeyFrameInterval 0x7fffffff (IDRs only through
ForceKeyFrame), ConstantBitRate **without** EnableLowLatencyRateControl, VBVBufferDuration = 1 frame (clamped to
[1/fps, 0.25 s]), BT.709 primaries/transfer/matrix, `NumberOfSlices` when `slices > 1`, PrepareToEncodeFrames.
`prewarm` encodes one black frame at creation and forces the next real frame to IDR. PTS: VT gets its own timeline. Each
step follows the spacing of the caller's timestamps (any monotonic clock; 0 = now), clamped to [1 ns, 4 frame
intervals]. The first frame after the prewarm is one frame interval later. Output: AVCC length prefixes rewritten to `00 00 00 01`, VPS/SPS/PPS (SPS/PPS
for H.264) from the format description prepended on every keyframe, filler NALs (HEVC 38, H.264 12) dropped, SEI kept.

## What WiVRn expects (checked in third_party/wivrn)

- **Streams**: the compositor encodes 3 array layers of one image: left, right (each
  `align(stream_eye_width/height, 64)`), and alpha (half height, only when the client wants alpha). Each layer has
  its own `video_encoder` (`stream_idx`). Client default `stream_scale` is 0.5 (0.3 with eye tracking) of the render
  size; render size = recommended × `resolution_scale` 1.2. Quest 3 (2064×2208): stream 1238×1325 → **1280×1344**
  per eye; with `stream_scale` 1.0 → 2496×2688.
- **Bitrate**: client default 50 Mbit/s total, split by area between streams (`split_bitrate`; alpha ×0.05, H.264
  ×2). Each encoder gets `settings.bitrate`; later changes come through `set_bitrate(total × bitrate_multiplier)`.
  `set_bitrate`/`set_framerate` are rare (settings changes, refresh-rate changes), not per frame.
- **Bitstream**: the client concatenates all shards of a frame and queues them as one MediaCodec input buffer
  (`android_decoder::push_data`); no codec-specific data is configured, so parameter sets must be in-band, Annex B,
  before the IDR slice. nvenc uses `repeatSPSPPS` + `NV_ENC_PIC_FLAG_OUTPUT_SPSPPS` and hands the whole frame to one
  `data` (one `SendData` per frame); x264 calls `SendData` per NAL. No AUD or SEI is needed. libmvt output matches
  the nvenc shape: one access unit per frame.
- **IDR**: infinite GOP; `default_idr_handler::get_type(frame_index)` says when to send an IDR (start, after
  loss feedback, after `reset()`), and frames are skipped (`should_skip`) until the client confirms it. IDR frames
  go over the reliable control channel (`data.prefer_control = true`).
- **Colour**: full range, BT.709. The compositor (`foveation.comp`) writes full-range BT.709 YCbCr of sRGB-encoded
  values; the client forces `eItuFull` + `eYcbcr709` in its sampler and ignores VUI. Use `full_range = true` (the
  default). ffprobe shows `color_range=pc, color_space=bt709` for libmvt output.
- **Profiles / bit depth**: the client sends `supported_codecs` and `bit_depth` (default 10). The server uses 10 bits
  for HEVC/AV1 unless H.264 or raw is involved or R16 images aren't supported. 10-bit images are
  `G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16`, which has the same layout as VT's `xf20` (16-bit little-endian, MSB-aligned).
  8-bit images are `G8_B8R8_2PLANE_420` = NV12 = `420f`. VT AutoLevel chose level 5.0 for 1280×1344 and 5.2 for
  1832×1920 and larger; the Quest 3's MediaCodec is set up with width/height only.

## Measurements (2026-10-24, M4 Max, macOS 27.0, `tests/encoder/run.sh` under `caffeinate -i`)

Synthetic NV12/P010 content: a panning sine plaid, a 16 px checkerboard, fixed fine texture, and a moving disc;
the streams differ by a parallax shift. 300 frames paced at 90 fps, a forced IDR at frame 120. Numbers are from two full runs (ranges where they differed). Latency is submit
to output callback (VT's `encode_ns`; the sync call adds about 0.01 ms). Each stream runs on its own thread (as
WiVRn's encoders would if they ran in parallel), unless the row says "sequential" (one thread encodes the streams
in turn, as `compositor::encoder_work` does today). PSNR is measured against the regenerated source after an
ffmpeg decode, at frames 150 and 299 (frame 1, right after the first IDR, is ~35-36 dB everywhere).

| Config | Target / stream | Output (+ dropped filler) | Latency p50 / p95 / p99 / max (ms) | PSNR Y / avg (dB) |
|---|---|---|---|---|
| 2× 1832×1920 Main, parallel | 50 Mbit/s | 37.5 (+16) Mbit/s | 4.61 / 4.78 / 4.87 / 7.5 | 47.5-48.1 / 48.6-49.1 |
| 2× 1832×1920 Main, sequential | 50 | 37.6 (+16) | s0 4.62-4.65 / 4.8; s1 5.4-6.5 / 8.1-8.3; **both 10.1-11.2 / 12.9-13.0 / 13.3 / 16** | (same stream) |
| 2× 1832×1920 Main10, parallel | 50 | 33.2 (+21) | 4.75 / 4.92 / 5.07 / 7.7 | 48.0-48.9 / 49.4-50.1 |
| 2× 1832×1920 Main, `mvt_encode_nv12` copy | 50 | 37.6 | call 4.75 / 4.90 (VT 4.61): copy ≈ 0.14 ms | — |
| 2× 1832×1920 Main, async callback | 50 | 37.5 | 4.52-4.63 / 4.64-5.5 / 4.8-7.5 / 8.7 | — |
| 2× 1832×1920 Main, 4 slices | 50 | 37.9 | 4.65 / 4.86 / 4.92 / 7.6 | — |
| 1× 3664×1920 Main | 100 | 73.1 (+32) | **13.0 / 14.9 / 16.6 / 22.3**: 300 frames took 6.8 s (~44 fps) | 47.5-48.1 / 48.6-49.1 |
| 2× 1280×1344 Main10 (WiVRn Quest 3 default) | 25 | 18.4 (+8) | 2.67 / 2.84 / 2.93 / 4.2 | 47.7-48.9 / 49.1-50.1 |
| 2× 1280×1344 Main10, sequential | 25 | 18.4 | both 5.3-5.6 / 7.4-7.5 / 7.9-8.0 / 10.8 | — |
| 2× 2496×2688 Main10 (Quest 3, stream_scale 1) | 100 | 52.8 (+59) | **12.0 / 14.2 / 15.4 / 21.7**: ~45 fps | 48.8-49.3 / 50.2-50.6 |
| 2× 1832×1920 H.264 High | 50 | 39.5 (+14) | 7.37 / 7.48 / 8.7 / 29.7 | 50.4-50.8 / 50.9-51.2 |

The validation passes for every config: frame count = 300, 2 keyframes, no ffmpeg decode errors for the full
stream or for the stream cut at the forced IDR (180 frames). The per-AU check in mvt_test (Annex B, VPS/SPS/PPS
before IRAP slices on IDR, none on P, no filler) has 0 failures.

Rate changes (1832×1920): IMMEDIATE 40 → 15 Mbit/s gives 1 change, and the output drops right away.
SMOOTH 40 → 60 gives 2 steps over about 2 s (by design).

Findings:
- **Per-frame size ceiling.** One HEVC session encodes about 1.1-1.2 ns/pixel up to 5.24 MP (2560×2048,
  2048×2560: 6.4 ms; 4096×1024: 5.3 ms; 2112×2112: 5.7 ms). From about 5.6 MP it switches to a slow path: 2304×2432
  11.1 ms, 2240×2560 11.3 ms, 1920×3200 11.6 ms, 1832×3664 12.7 ms. Slices don't help (3664×1920 with 2 slices:
  13.1 ms). The earlier prototype saw the knee near 7 MP for 1312×5248, so the knee may depend on shape. Keep each WiVRn
  stream at or below about 5.2 MP (e.g. clamp in `check_video_size`, like nvenc's `get_max_size`).
- **Two sessions run in parallel** at full speed (M4 Max: 2× 1832×1920 at 4.6 ms each, same as one).
  Encoded one after the other, they take 2.2-2.4× as long (10.1-11.2 ms p50), because the second session is slower when it
  starts right after the first.
- **Forced IDR mid-stream is ~23-26× the per-frame budget** (1832×1920 at 50 Mbit/s: 1.6-1.8 MB; 1280×1344 at
  25 Mbit/s: 0.8 MB). VT keeps the steady-state P-frame QP for the forced keyframe. The first IDR of a session is
  only 2-4×. `DataRateLimits` doesn't cap it. `MinAllowedFrameQP` set at creation does (QP 24: 4.7×), but it also caps
  P-frame quality (output fell to 9 Mbit/s). See "Forced IDR size" for what works per frame. WiVRn sends IDRs over
  TCP, and only at start or after a loss.
- **PTS gaps become CBR filler.** VT's CBR fills the whole PTS interval since the previous frame with filler NALs, in
  the VT service process (AppleVideoEncoder memset/memmove). A gap of 0.6 s is harmless (1.8 MB at 24.6 Mbit/s). A
  gap of days is not: see below.

## WiVRn startup stall (root cause, fixed 2026-10-24)

For the first ~22 s of every WiVRn session, encode calls took 30-700 ms and the client kept asking for IDRs.

- Cause: two clocks on one VT timeline. The prewarm frame was stamped with libmvt's `CLOCK_UPTIME_RAW`. WiVRn stamps
  its frames with Monado's `os_monotonic_get_ns()`, which is `CLOCK_MONOTONIC`. On Darwin that clock includes sleep:
  it was 231,159 s (2.7 days) ahead here. VT saw a 2.7-day PTS gap after the prewarm and started emitting CBR
  filler for it. That was tens of GB, dropped by libmvt but generated and copied by the VT service: its footprint was
  5.5 GB (13.6 GB peak). Encodes stayed slow until VT gave up on the backlog.
- The IDR storm was a consequence. A slow encode makes the compositor skip frame ids. The client reports every id it
  never received as lost (`shard_accumulator`), and each report forces an IDR. Frames are then skipped until the
  IDR is acknowledged.
- Evidence:
  - A standalone 2-stream encoder running in parallel during the stall stayed at 2.4-3.4 ms.
  - `sample` of the encoder threads: blocked on the VT callback.
  - `sample` of VTEncoderXPCService: AppleVideoEncoder in memset/memmove.
  - Standalone repro (prewarm, then `CLOCK_MONOTONIC` PTS): avg 65 ms per frame, 95 GB of filler in 180 frames.
    With the fix: 3.2 ms and 10 MB.
- Fix: the internal PTS timeline above. WiVRn patch 0004 also stops skipped frame ids from triggering IDRs.

## Forced IDR size (step 7 evaluation, 2026-10-24)

1152×1152 Main10 at 24.6 Mbit/s (Quest 3S session), synthetic content from `mvt_test`, forced IDR at frame 150.
Budget = 34.2 kB per frame. PSNR-Y is against the source; steady state is 53.6-53.8 dB.

| Per-frame option | IDR size | P frames after | PSNR-Y: IDR / +1 / +9 / +19 / +49 |
|---|---|---|---|
| none | 891 kB (26.0×) | max 1.5× | 52.3 / 52.9 / 53.0 / 53.5 / 54.2 |
| `MinAllowedFrameQP` 20-32, set for the IDR only | 891 kB (26.0×) | identical: ignored after creation | identical |
| `idr_rate_scale` 0.5 | 436 kB (12.7×) | max 5.4× (rate restore restarts RC) | 42.0 / 45.5 / 45.9 / 46.8 / 49.1 |
| `idr_rate_scale` 0.35 | 333 kB (9.7×) | max 4.7× | 40.1 / 42.9 / 43.5 / 45.1 / 47.9 |
| `idr_rate_scale` 0.25 | 270 kB (7.8×) | max 4.2× | 38.9 / 41.4 / 42.4 / 43.6 / 47.2 |
| `idr_rate_scale` 0.1 | 167 kB (4.8×) | max 2.9× | 37.0 / 38.7 / 40.9 / 42.4 / 46.2 |

- `idr_rate_scale` lowers `ConstantBitRate` for the forced IDR and restores it on the next frame. That is the only
  per-frame cap that works. Quality takes more than 50 frames (0.5 s) to come back on static content, and the restore
  causes a P-frame burst.
- `kVTEncodeFrameOptionKey_BaseFrameQP` must be set on every frame and turns rate control off, so it is no use for
  a per-IDR cap.
- LTR (`EnableLTR` + `ForceLTRRefresh` as a cheap loss recovery) is not available with our settings.
  `EnableLTR` returns -12900 (not supported) unless the session is created with `EnableLowLatencyRateControl`.
  Low-latency RC rejects `ConstantBitRate`, and there `ForceLTRRefresh` still produced a full keyframe (556 kB).
- Default: off. On this network the IDR is not the bottleneck: after the startup fix, a 5-minute soak had 1 IDR
  (session start). WiVRn exposes it as `WIVRN_VT_IDR_RATE_SCALE` for experiments.
- Session creation + prewarm: ~85 ms for the first session in a process, 15-35 ms for the next ones. With
  prewarm, the first real frame costs about the same as steady state.
- 10-bit costs ~0.15 ms more than 8-bit at 1832×1920. Filler dropped: with this content CBR pads 25-50% of the
  target. The output stays under the target and P-frame peaks stay at ≤ 3.1× budget.

## How `video_encoder_vt` should call it (step 5)

Model it on `video_encoder_x264` (readback). Base class arguments: `target_queue` = transfer or graphics family,
`std::make_unique<default_idr_handler>()`, `async_send = true` (as nvenc: `encode()` returns the frame as `data`).

- **Constructor**: `mvt_params_default(&p, settings.width, settings.height)`; `p.fps = settings.fps`,
  `p.bitrate_bps = settings.bitrate`, `p.ten_bit = settings.bit_depth == 10`, `p.codec` from `settings.codec` (h265 →
  HEVC, h264 → H264, av1/raw → throw). Keep `full_range = true` and 1 slice. `mvt_encoder_create`, and throw on
  NULL. Per slot, allocate a fence, a command buffer and a host-visible luma + chroma `buffer_allocation`, as x264 does,
  with 1 byte/sample for 8-bit and 2 for 10-bit.
- **`present_image(y_cbcr, sem, slot, frame_index)`**: the same as x264. Copy plane 0 and plane 1 of array layer
  `stream_idx` to the slot's buffers, wait on the compositor semaphore, signal the slot fence.
- **`encode(slot, frame_index)`**:
  1. Wait for the slot fence.
  2. `if (auto b = pending_bitrate.exchange(0)) mvt_set_bitrate(enc, b, MVT_RATE_IMMEDIATE);`
     `if (auto f = pending_framerate.exchange(0)) mvt_set_framerate(enc, f);` No `idr->reset()` is needed (x264/nvenc
     reset only because their reconfigure restarts the encoder).
  3. `force_idr = idr_handler.get_type(frame_index) == frame_type::i`.
  4. `mvt_encode_nv12_sync(enc, luma, row_bytes, chroma, row_bytes, os_monotonic_get_ns(), force_idr, &f)`.
  5. Return `data{.encoder = this, .span = {(uint8_t*)f.data, f.size}, .mem = nullptr, .prefer_control = f.is_idr}`.
     The span stays valid long enough because the base `encode()` calls `shared_sender->wait_idle(this)` before
     the next `encode()`. On error, log and return `{}`.
- **Registration**: add `encoder_vt = "vt"` next to the other names in `video_encoder.h`, a `WIVRN_USE_VT` branch in
  `video_encoder::create`, and the prober's `select_encoder` on Apple: `{encoder_vt, h265}` (or h264 when it is the
  only codec the client supports). Clamp the stream size to ≤ ~5.2 MP in `check_video_size`. In CMake,
  `add_subdirectory(<macvr>/encoder mvt)` and link `mvt`.
- **Parallelism**: `compositor::encoder_work` calls `encode()` for the streams one after the other, so sync encodes
  serialize (WiVRn's default Quest 3 size: 5.3-5.6 ms for both, which is fine at 90 fps; 1832×1920: 10-11 ms p50, 13 ms p95, which isn't).
  If needed, run each encoder's `encode()` on its own thread in `encoder_work` (the sender and `SendData` are already
  locked per encoder), or submit async from a per-encoder worker as soon as the readback fence signals.
- **Zero-copy (step 7, done 2026-10-24, WiVRn patch 0005)**: WiVRn's compositor renders each stream into the two
  planes of its own `mvt_create_input_buffer` (one per stream per compositor image, 6 in all). Each plane is a
  Metal texture (`mvt_metal_plane_texture`) imported as a plain R/RG Vulkan image, which is spike option (b): no
  MoltenVK-shaped surface is needed, and 10-bit `xf20` works the same way (R16/RG16 planes). The encoder waits on
  the compositor's timeline semaphore on its own thread, then calls `mvt_encode_pixel_buffer_sync`. Details and
  numbers in docs/wivrn.md ("Zero-copy encode").
