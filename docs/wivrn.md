# WiVRn server on macOS

WiVRn v26.9 (`third_party/wivrn`, matching the Quest client 26.9) built natively with Xcode clang, MoltenVK 1.4.2
and a VideoToolbox encoder (libmvt, `encoder/`). The wire protocol is unchanged: the server publishes protocol hash
`fc26e619b7ab80f8`, and the 26.9 client accepts it.

## Build

Homebrew deps: `glib boost eigen nlohmann-json openssl libarchive librsvg cli11 libpng x264` (x264 is optional:
`WIVRN_USE_X264=OFF scripts/build-wivrn.sh`). Vulkan SDK 1.4.304 in `/usr/local` (headers, glslc).

```sh
scripts/patches.sh apply wivrn        # WiVRn patches (patches/wivrn/0001-0010), staged
scripts/build-wivrn.sh --snapshot     # snapshot the staged third_party/monado, configure + build
scripts/build-wivrn.sh                # incremental
WIVRN_BUILD_DIR=$PWD/build/wivrn-next scripts/build-wivrn.sh   # separate build dir (e.g. while build/wivrn is running)
scripts/build-wivrn.sh --client-x86_64   # x86_64 libopenxr_wivrn for the bridge (build/wivrn-client-x86_64/client)
scripts/build-bridge.sh bridge           # copies it + its ipc-stamp into build/bridge/root/x86_64-unix
```

- Monado is built from `build/monado-snapshot`, which `git checkout-index` exports from the **staged**
  `third_party/monado` (it includes our Monado patches but no unstaged work in progress). Pass
  `-DFETCHCONTENT_SOURCE_DIR_MONADO`, so WiVRn's own Monado patches are not applied a second time.
- `-C cmake/monado-macos.cmake` disables OpenGL/EGL/SDL/OpenCV etc. for Monado. WiVRn's `server/CMakeLists.txt`
  still forces its driver set.
- On Apple, these default OFF: nvenc, vaapi, Vulkan encode, pipewire, SolarXR, SteamVR lighthouse, wivrnctl,
  dashboard. `WIVRN_USE_VIDEOTOOLBOX` and `WIVRN_USE_COREAUDIO` default ON; `WIVRN_MVT_SOURCE_DIR` points at `encoder/`.
- Output: `build/wivrn/server/wivrn-server` and `build/wivrn/openxr_wivrn-dev.json` (IPC-client runtime
  `libopenxr_wivrn.dylib`). The script also builds `build/tests/xr_empty_frames` (see below).
- Logs: `build/logs/wivrn-{configure,build}.log` (client: `wivrn-client-x86_64-*.log`).
- `--client-x86_64` configures the same WiVRn tree with `WIVRN_BUILD_SERVER=OFF WIVRN_BUILD_SERVER_LIBRARY=ON`, x86_64,
  no arm64 Homebrew, `-dead_strip_dylibs`, and the same `build/monado-snapshot` (it never refreshes the snapshot). Its
  generated IPC files and `xrt_config_*.h` equal the server's; only `XRT_HAVE_HIDAPI` (server-side drivers) differs.
  Build time about 10 s.
- IPC stamp: `--snapshot` records `git write-tree` of the staged Monado index in `build/monado-snapshot/.snapshot-tree`.
  Every build writes `ipc-stamp` (tree, socket, git tag; `scripts/ipc-stamp.sh`) to `<build>/server/` or next to the
  client. After a `--snapshot` refresh, rebuild **both** the server and the client: the bridge refuses a mismatching
  pair. Server start scripts publish the stamp to `$(getconf DARWIN_USER_TEMP_DIR)wivrn/ipc-stamp`.

## Run

```sh
scripts/run-wivrn.sh [--pairing] [--no-encrypt]      # log: build/logs/wivrn-server.log
```

- Uses `scripts/env-macos.sh` (Homebrew MoltenVK) and `--no-manage-active-runtime`. OpenXR apps get
  `XR_RUNTIME_JSON=build/wivrn/openxr_wivrn-dev.json`.
- Discovery: Bonjour `_wivrn._tcp` under the computer name, TXT `protocol`/`version`/`cookie`. Check with
  `dns-sd -B _wivrn._tcp` and `dns-sd -L <name> _wivrn._tcp`. TCP/UDP port 9757.
- **Pairing:** with no known headset, or with `--pairing`, the PIN is printed on the terminal. There is no
  wivrnctl/D-Bus. Keys are stored in `~/.config/wivrn/`.
- Start the client from the Mac without touching the headset; the PIN goes in the URI's password field:
  ```sh
  adb shell am start -a android.intent.action.VIEW -d "wivrn://:PIN@<mac address>:9757" -n org.meumeu.wivrn/.MainActivity
  ```
  Once paired, `wivrn://<mac address>:9757` is enough.
- Then run an app:
  ```sh
  CLIENT_RUNTIME_JSON=$PWD/build/wivrn/openxr_wivrn-dev.json scripts/run-hello-xr.sh service 60 -g Vulkan2
  ```
  `build/tests/xr_empty_frames [s] [--swapchain]` is a minimal session that submits frames with no layers (or one
  untouched swapchain).
- The server and the apps must run in the same login session, because of Monado's Mach bootstrap service
  (`org.macvr.monado.<uid>.comp_ipc.<hash>`).
- Ctrl-C / SIGTERM quits.
- Env:
  - `WIVRN_VT_LOG_TIMING=1`: per-frame encode log. Without it, a summary per stream is logged every 10 s.
  - `WIVRN_DEBUG_TEST_PATTERN=1`: frames with no layers stream a colour-cycling field instead of black.
  - `WIVRN_DUMP_VIDEO=prefix`: dumps `prefix-N.h265`.
  - `WIVRN_VT_IDR_RATE_SCALE=0.5`: lower the CBR target for mid-stream IDRs (off by default, see docs/encoder.md).
  - `MONADO_SYNC_STATS=1`: GPU sync stats on both sides (also set it for the app).
  - `WIVRN_VT_READBACK=1`: the old readback encode path instead of zero-copy (fallback, comparisons).
  - `WIVRN_VT_VERIFY=1` (zero-copy only): also read every frame back and compare it with the IOSurface that VT
    encodes; the 10-s summary logs `verify: N frames, M differ from readback`.
  - `WIVRN_AUDIO_TAP=auto|clients|global|pid:N[,M]|off`: what the CoreAudio backend captures (see Audio).
  - `WIVRN_RECENTER_STAGE=0`: a recenter (holding the Quest's Meta button) only recenters LOCAL/LOCAL_FLOOR, as
    upstream. Default on: STAGE is recentered too (patch 0006).
  - `WIVRN_PACER_PERCENTILE` (99.5), `WIVRN_PACER_WINDOW` (5000 frames), `WIVRN_CLIENT_MARGIN_MS` (1, upstream):
    how the pacer's safe present>decoded is estimated (patch 0009). Defaults are upstream's. Lower latency, more
    late frames: `WIVRN_PACER_WINDOW=500 WIVRN_PACER_PERCENTILE=99 WIVRN_CLIENT_MARGIN_MS=2.5` (see 0009).
- Every 10 s the server logs, besides the per-stream VT summary (fps, Mbit/s, IDRs, encode p50/p95/max):
  - `latency ms p50/p95`: stream-0 breakdown from the client feedback: present>encode, encode, send, network,
    decode, decoded>blit, blit>display, present>decoded, display-predicted. Then the stream-0 client misses
    (`shown late`: first shown more than half a period after the predicted time; `repeated`: client renders that
    re-showed an old frame; `skipped`: decoded but never shown), the pacer's safe present>decoded with how it was
    computed (`p99.5 of 5000 + 1.0`, it drives the prediction) and render>display.
  - `tracking latency`: headset pose produced to received, and whether the clock offset is stable.

## Audio

Patch 0008. Game audio goes to the Quest over WiVRn's normal audio stream (`audio_stream_description` +
`audio_data`, which the client already plays), captured with a Core Audio process tap (macOS 14.2+, no driver).

- `server/audio/coreaudio_tap.mm` (ObjC++): a private `CATapDescription` with `CATapMutedWhenTapped`, and a private
  aggregate device whose only input is the tap (drift compensation on, 240-frame = 5 ms buffers).
- `server/audio/audio_coreaudio.cpp`: IOProc block on a serial dispatch queue → AudioConverter (tap float32 → S16 at
  the headset's channels/rate) → one `audio_data` per buffer (~200/s, 960 bytes at 48 kHz stereo). Created per
  session; IO runs between `resume` and `pause`. The Mac is muted only while the tap is read, so it plays again as soon
  as the headset disconnects, the server stops, or the process dies (checked with SIGTERM, SIGKILL, session-end execv).
- Target (`WIVRN_AUDIO_TAP`, default `auto`): the PIDs of the connected OpenXR clients (`wivrn_session::client_pids`:
  `LOCAL_PEERPID` on the IPC socket, else Monado's `client_state.pid`) if any of them has a CoreAudio process object.
  Otherwise everything except the server. Re-checked every 0.5 s, changed in place. Under Wine the game plays audio
  from its own process, which is also the OpenXR client: Alyx shows `tapping clients: <pid> (hlvr.exe)`.
  `clients` never falls back; `global`; `pid:N[,M]` taps fixed PIDs (tests); `off` disables the backend.
- No microphone: the server sends `microphone=false` (a Quest mic → macOS input needs a virtual device).
- Permission: the first tap read asks "Terminal.app would like access to record your system audio" (System
  Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only). It goes to the
  responsible app, so a server started from Terminal needs nothing else. Without it the tap delivers silence.
- Log: `CoreAudio speaker: started, tapping …` / `tapping …` on changes / `stopped, Mac output restored`, and every
  10 s `audio: packets/s kB/s frames/s, rms/peak dBFS, capture>send mean/max, callback gap max, send errors, tap …`.
- Test without a game: `build/tests/audio_tone 60 --device "Steam Streaming Speakers" --loopback "Steam Streaming
  Speakers"` plays a 440 Hz tone (-23 dBFS) into a virtual device and prints its loopback RMS each second. With the
  server on `WIVRN_AUDIO_TAP=pid:<tone pid>` (or `global`) and the Quest connected, the loopback drops to 0.0000 while
  the server logs ~200 packets/s at -23.0 dBFS, and it comes back when the headset disconnects.
- Cost: capture→send 5 ms (one buffer); the client adds its 5-50 ms jitter buffer and AAudio. Server +0.6 points CPU,
  coreaudiod +1.6 points.

### Measurement sessions

```sh
WIVRN_VT_LOG_TIMING=1 MONITOR=1 scripts/wivrn-session.sh soak 300   # fresh server + Quest client + hello_xr 300 s
scripts/wivrn-session-summary.py build/logs/s7/soak.server.log       # fps, skipped ids, encode pcts, IDRs, time to 90 fps
```

Other apps: `HELLO_XR=$PWD/build/tests/xr_empty_frames APP_ARGS="120 --pattern 2" scripts/wivrn-session.sh pat 120`
streams a panning high-detail pattern (~18.5 Mbit/s per eye instead of hello_xr's 0.2); `--pattern 0` is the same
pattern, static. `tests/wivrn/compare_streams.py A-0.h265 B-0.h265` matches frames of two `WIVRN_DUMP_VIDEO` dumps
and prints PSNR (ffmpeg can't decode these dumps past frame 2048, see follow-ups).

`wivrn-session.sh` refuses to start while Steam is downloading. Server lines are prefixed with epoch seconds,
which match `adb logcat -v epoch` (`<tag>.logcat`). `MONITOR=1` records CPU and RSS of the server, the
VTEncoderXPCService and hello_xr every 10 s.

## What the patches change (patches/wivrn)

**0001-macos-port**

- Build:
  - CMake defaults for Apple (above). avahi/libnotify are not required.
  - libmonado (Linux-only) is optional for the runtime manifest.
  - Global `VK_USE_PLATFORM_METAL_EXT`/`VK_ENABLE_BETA_EXTENSIONS`, which must match Monado's `struct vk_bundle`.
  - `common/utils/apple_compat.h` is force-included for C++23 sources and supplies `std::ranges::enumerate_view`,
    which Xcode's libc++ lacks.
  - No `zoned_time`: timestamps are written in UTC.
  - Smaller compile fixes: `sys_signame`, `int64_t` clamp, Linux input codes as constants.
- Sockets (`common/wivrn_sockets.cpp`):
  - `recvmmsg`/`sendmmsg` become `recvmsg`/`sendmsg` loops; a full interface queue (ENOBUFS) counts as packet
    loss.
  - `SO_NOSIGPIPE` replaces `MSG_NOSIGNAL`.
  - `SO_NREAD` replaces `MSG_TRUNC` peeking.
  - IPv6 multicast option names.
  - `IPV6_TCLASS` fallback for `set_tos`.
  - **Darwin reports IPv4 peers of a dual-stack UDP socket as `AF_INET`.** They are mapped back to `::ffff:a.b.c.d`.
    Without this, the stream handshake from the headset was ignored ("No handshake received from client").
- Service (`main.cpp` etc.):
  - `bonjour_publisher` (DNSServiceRegister, serviced from the GLib loop) replaces avahi.
  - No session D-Bus: the gdbus skeleton object stays as the state store and is not exported.
  - Applications are started with fork+exec, not systemd.
  - PIN on the terminal, plus a `--pairing` flag.
  - Hostname is left empty, so Bonjour uses the computer name.
  - Sleep is blocked by a `caffeinate -i -w <pid>` child (an IOPM assertion) while a headset is connected.
  - `_NSGetExecutablePath` replaces `/proc/self/exe`.
  - uinput is a stub that throws, which disables input forwarding.
  - No thread naming.
- **No fork for the session.** `fork()` without exec aborts in the child
  (`objc_initializeAfterForkError`, Swift class init from the mDNSResponder client in the parent). So the Monado
  server runs on a thread in the main process. When the session ends, the process `execv`s itself to start clean.
  `connection` is owned by that thread.
- Vulkan (`wivrn_vk_bundle`):
  - Portability enumeration.
  - `VK_KHR_portability_subset` with its queried features.
  - `VK_EXT_metal_objects` replaces `VK_KHR_external_memory_fd`, because Monado's swapchains are IOSurfaces.
- **Encode image** (`compositor.cpp`): MoltenVK refuses multi-planar images with more than 1 array layer
  ("Chroma-subsampled formats may only have one array layer"). On Apple, the 3-layer `G8_B8R8_2PLANE_420` /
  `G10X6…3PACK16` image is therefore split into two plain 3-layer images: R8/R16 luma and RG8/RG16 half-size chroma.
  - The foveation shader is unchanged: it uses the same R/RG 2D-array storage views.
  - `video_encoder::present_image` gets an optional `cbcr` image.
  - Patch 0005 replaces the 3-layer images with per-stream images (zero-copy).

**0002-videotoolbox-encoder**

- `encoder/video_encoder_vt.{h,cpp}`, encoder name `"videotoolbox"`.
  - Readback as in x264: copy the luma and chroma layer `stream_idx` into host buffers (8-bit NV12, or 16-bit
    MSB-aligned = `xf20`), then `mvt_encode_nv12_sync`.
  - The output is one Annex B access unit per frame, sent async. IDRs are flagged `prefer_control`.
  - IDRs come from `default_idr_handler`. Bitrate and framerate changes apply without an IDR.
- Auto-selection on Apple: HEVC if the client supports it, otherwise H.264 (VT has no AV1). 10-bit for HEVC.
- Each stream is clamped to ≤ 5.2 MP: aspect kept, 64-aligned, `check_video_size`.
- `compositor::encoder_work` encodes the streams **in parallel** when all of them are VideoToolbox (`std::async`
  for streams 1-2). Nothing on the wire changes.

**0003-macos-signals-kqueue**

Monado's IPC mainloop installs its own SIGINT/SIGTERM handlers, which replace GLib's. Without this patch, a SIGTERM
only ended the session and the server re-executed itself. The main loop now also watches the signals with kqueue
`EVFILT_SIGNAL`.

**0004-vt-stability-latency-stats** (step 7)

- `video_encoder_vt`:
  - Frame ids the compositor skipped (never encoded) are marked non-reference in the `default_idr_handler`. The
    client reports every id it did not receive as lost (`shard_accumulator`). Before, each skipped id forced an IDR,
    even though VT's next P frame only references the last encoded frame.
  - `WIVRN_VT_IDR_RATE_SCALE` sets libmvt's `idr_rate_scale`.
  - The 10-s summary also counts IDRs.
- `idr_handler.h`: `non_ref_frames{512, uint64_t(-1)}` was a 2-element vector (brace initialisation) until the first
  `reset()`. It is now 512 entries.
- `pacer`: 10-s latency breakdown log (see Run).
- `wivrn_session`: 10-s tracking latency and clock offset log.

**0005-vt-zero-copy** (step 7)

- Encode images on Apple: one luma (R8/R16) and one chroma (RG8/RG16, half size) image **per stream** (left,
  right, alpha) instead of two 3-layer images, because IOSurfaces can't be arrays. The alpha stream's images have
  its own (half-height) size.
  - Zero-copy (default when every stream uses VideoToolbox): each stream's pair is the two planes of an
    IOSurface-backed `420f`/`xf20` CVPixelBuffer (`mvt_create_input_buffer`). The planes are Metal textures
    (`mvt_metal_plane_texture` on the MTLDevice from `vkExportMetalObjectsEXT`) imported with
    `VkImportMetalTextureInfoEXT`.
  - Readback (`WIVRN_VT_READBACK=1`): the same per-stream images, plain VMA allocations.
- `foveation.comp` with `-DWIVRN_ENCODE_IMAGE_PER_STREAM` (set for Apple in CMake via `WIVRN_GLSL_DEFINES`):
  `image2D luma[3]`/`chroma[3]` instead of `image2DArray`, indexed by the dispatch's z (= stream). Same single
  dispatch; the descriptor bindings get 3 images. The alpha chroma store is bounds-checked, because Metal has
  no robust out-of-bounds stores. Linux keeps the array shader.
- `video_encoder::present_image` gets the stream's CVPixelBuffer. `video_encoder_vt` in zero-copy mode records
  the compositor's timeline semaphore value in `present_image` (no GPU work), and `encode()` CPU-waits for it on
  the encoder thread (`vkWaitSemaphores`), then calls `mvt_encode_pixel_buffer_sync`. No QFOT: the target queue
  is the compositor's.
- The 10-s summary adds the GPU wait (zero-copy) or readback fence wait, and compositor submit > encode start,
  per stream. The compositor logs its GPU time (layer squashing, foveation) p50/p95 every 10 s.
- `WIVRN_VT_VERIFY=1` (see Run).

**0006-recenter-stage** (2026-10-24)

- The Quest client streams poses in its STAGE space and forwards a recenter (Meta button held, also sent when the
  headset wakes) as the `recentered` tracking flag. Upstream only calls `xrt_space_overseer_recenter_local_spaces`,
  so apps on STAGE (OpenComposite, so Half-Life: Alyx) could not be recentered.
- Now, after the local recenter, the STAGE offset is set with `xrt_space_overseer_get/set_reference_space_offset`
  (b_space_overseer; STAGE is a null/offset space parented to root in WiVRn): origin moved under the head (x/z, the
  floor height y is kept), rotated about +Y to the head's heading (from the forward vector, so pitch/roll don't
  leak in; straight up/down falls back to the swing-twist yaw). It is absolute (head pose in root), not cumulative.
  Monado pushes `REFERENCE_SPACE_CHANGE_PENDING` for STAGE and LOCAL_FLOOR. Log:
  `recentered stage: origin (x, y, z) yaw D deg (was ...)`. Off with `WIVRN_RECENTER_STAGE=0`.
- "failed to recenter local spaces" (4 of 7 requests in build/logs/wivrn-server.log of the Alyx session): those requests were the ones sent
  when the headset woke (always followed by "user presence changed to true"). The head pose history still held
  the invalid poses of the sleeping headset (interpolation ANDs the flags of both samples), and the recenter even
  ran before that packet was fed to the HMD, so `recenter_local_spaces` found no valid view pose and returned
  `XRT_ERROR_RECENTERING_NOT_SUPPORTED`. The recenter now runs after `hmd.update_tracking` and is retried on each
  tracking packet for up to 2 s; the warning is logged only if it still fails. Side effect: those wake-time requests now succeed, so STAGE (like LOCAL on the Quest itself) is
  also re-origined each time the headset is put back on.
- The offset math is `server/driver/recenter_stage.h`; `tests/wivrn/recenter_stage_test.cpp` checks it (head ends up
  above the new origin facing -Z, gravity-aligned, floor height kept), build command in the file header.

**0007-app-pacer-stable-wake** (2026-10-25, with Monado patch 0015-multi-pacer-submit-point)

WiVRn replaces Monado's `u_pacing_app` with its own `server/driver/app_pacer.cpp` (so `U_PACING_APP_*` variables other
than `U_PACING_APP_MIN_MARGIN_MS` do nothing in WiVRn). It woke apps at erratic times, so at 72 Hz `xrWaitFrame`
alternated between returning at once and blocking 20-34 ms (Alyx: 62-66 fps, 170-280 frame intervals > 20 ms per 30 s;
a native test app with a fixed 10 ms frame: 56 fps). Changes:
- Compositor time: the raw `extra_ns` (display time minus the compositor's *actual* wake) drops by 4-20 ms whenever the
  compositor wakes late, and the app's wake target moved by as much, frame to frame. The pacer now follows its upper
  envelope: rises at most `WIVRN_PACER_COMP_RISE_MS` (1) per compositor frame, decays `WIVRN_PACER_COMP_DECAY_MS` (0.1).
  `WIVRN_PACER_COMP_ENVELOPE=0` restores the raw value.
- GPU time: measured from the frame's handoff to the compositor's wait thread, not from `xrEndFrame`'s start. That
  thread only takes the next frame after the previous one left the scheduled slot, so the old measure included this
  backpressure, which pushed the display time further out and held frames longer: a feedback loop into the "app-limited,
  don't wait" mode. Monado 0015 marks `U_TIMING_POINT_SUBMIT_END` at the handoff (Monado's own pacer ignores it).
- Late frames: a frame starting up to `WIVRN_PACER_LATE_TOLERANCE_MS` (default a quarter period) late keeps its display
  slot; before, any lateness moved it one slot and the next frame waited a full extra period.
- Default margin (`U_PACING_APP_MIN_MARGIN_MS`) 1.5 → 4 ms: with 1.5, 4-6 % of the compositor's frames found no new
  Alyx frame; with 4, 0.7 %.
Results and method in [ab-alyx.md](ab-alyx.md#frame-pacing-2026-10-25). Diagnostic trace patch (not installed):
`patches/diag/wivrn-app-pacer-trace*.patch` (`WIVRN_PACER_TRACE=<file>`), read with `tools/mql-ab/pacertrace.py` and
`pacerlatch.py`.

**0008-macos-coreaudio** (2026-10-25)

CoreAudio process-tap speaker backend (`WIVRN_USE_COREAUDIO`, OBJCXX enabled for `coreaudio_tap.mm`) and
`wivrn_session::client_pids()`. See Audio above.

**0009-pacer-safe-estimate** (2026-10-25)

`WIVRN_PACER_PERCENTILE` / `WIVRN_PACER_WINDOW` for the safe present>decoded estimate (upstream hard-codes p99.5 of
5000 frames; `WIVRN_CLIENT_MARGIN_MS` already existed), and the client-miss counters in the `latency` line. Defaults
unchanged. Diagnostic per-frame dump (not installed): `patches/diag/wivrn-feedback-dump.patch`
(`WIVRN_FEEDBACK_DUMP=<file>`, one line per feedback packet: all client timestamps, clock offset, desired present,
predicted display, compositor wake/submit), read with `tools/mql-ab/latstats.py`, `fbseries.py` (tail over time),
`safesim.py` (replays the recording through other estimator settings), `p2e.py` (present>encode split).
Runs: `tools/mql-ab/latrun.sh <label> <server dir> [VAR=..]` (quits Alyx, restarts the server, reconnects the Quest,
reloads the save, 20 s settle, 30 s window).

**0010-macos-steam-apps** (2026-10-29)

The headset's application list (stock client 26.9: `from_headset::get_application_list` → `to_headset::application_list`
{id, name} then one `application_icon` {id, PNG bytes} per app; tiles are square; `start_app{id}` → the server looks the
id up again in `list_applications()` and runs its `exec`). On Linux WiVRn reads Steam's `config/steamapps.vrmanifest`
(written by Steam for installed VR apps), Steam shortcuts with the OpenVR flag and `X-WiVRn-VR` desktop entries. macOS
Steam leaves the vrmanifest empty and the Linux Steam paths don't exist, so the list was empty. The patch
(`common/utils/steam_info.cpp`, `#ifdef __APPLE__`):
- Steam root `~/Library/Application Support/Steam`; launch command `/usr/bin/open`, so a pick runs
  `/usr/bin/open steam://rungameid/<appid>` (forked child, exits at once; Steam starts the game as from its library).
- What Steam would write to the vrmanifest: fully installed apps (appmanifest `StateFlags & 4`, every library in
  `steamapps/libraryfolders.vdf`) whose `appcache/appinfo.vdf` `common` has `openvrsupport`, `openxrsupport` or
  `onlyvrsupport`, or category 53/54 (VR supported / VR only), and type `game` or `demo`. SteamVR (250820) and the 360
  video player are `Tool`. `controllervr`/`playareavr` are not used: flat games (Dota 2, God of War) have them.
  The appinfo reader is upstream's icon reader, split into `read_appinfo()`; `read_dict` now skips float/int64 values
  instead of dropping the app.
- Icons: macOS Steam has no `steam/games/*.ico`; the server sends `appcache/librarycache/<id>/library_600x900.jpg`
  (else `header.jpg`), letterboxed into a square PNG (≤ 512 px) with ImageIO in `load_icon`. No artwork: the client's
  default icon.
- `list-apps` (`-DWIVRN_BUILD_TEST=ON`, `common/list-apps`) also prints each icon's size.
Checked against this Mac's Steam (`build/wivrn-apps/common/list-apps`): only `546560 Half-Life: Alyx`, `Exec=/usr/bin/open
steam://rungameid/546560`, 450×450 PNG (cover art centered); 250820 (SteamVR, a Tool), 228980 (redistributables) and the installed non-VR games left out.
With `HOME` on a scratch Steam tree (second library, The Lab with StateFlags 6, PAYDAY 2 downloading, Phasmophobia
with only `openxrsupport`, 360 video player installed): The Lab, Phasmophobia, Alyx; not PAYDAY 2, SteamVR, the
player. `steam://` resolves to /Applications/Steam.app (LaunchServices). Not checked yet: the list and a launch in the
headset.

How the prediction works and where the latency goes (Alyx, 90 Hz, 2×1152² HEVC at ~71 Mbit/s per eye, Mac on
Ethernet, Quest on 5 GHz Wi-Fi):
- `pacer::predict` (server/compositor/pacer.cpp) aims each frame at a client render slot C (phase-locked to the
  client's blit times) and wants it presented at C − safe; the display time given to the app (and written into the
  frame as `view_info.display_time`) is C + render>display. safe = percentile of (decoded − desired present) over
  the last `window` frames (the later of the two eyes; from the client feedback, via the clock offset) + margin.
- The stock client keeps the last 3 decoded frames per eye and at each render blits the one whose `display_time` is
  closest to its own predicted display time (`stream::common_frame`). The label is only used for this choice
  (reprojection uses the frame's pose). So an early frame waits for its slot: decoded>blit = safe − actual arrival.
  A frame that misses its slot costs a repeat of the previous frame and usually a skipped frame.
- The safe value is not inflated by a bug, our pacing fix or the clock: the clock offset (mean of 100 timesyncs)
  drifts ~33 ppm and moves < 1 ms per 30 s, and it cancels between prediction and measurement. It is the real tail
  of present>decoded (both eyes): p50 17-18, p99.5 27-29 ms in calm Wi-Fi; worst-2 % frames vs mean: present>encode
  +4 (compositor waiting for a late app frame up to its 3 ms wake margin), send +1 (the shared sender sends one eye
  after the other over the 1 GbE adapter), network +2, decode +2, and the second eye decodes ~4 ms after the first.
- Wi-Fi swings dominate. In one session network p50 went 4.5 → 15 ms (p95 7 → 24) for minutes at a constant
  71 Mbit/s, and safe followed (29 → 47 ms). Because the window is 55 s, safe also stays high for up to a minute
  after an Alyx load or a burst: `safe present>decoded 37-40` was such a period.
- An oracle that knows the next 10 s would save only ~2.7 ms of safe at the same miss rate, so the estimator is
  near its limit. Short windows follow the swings faster: live, `WIVRN_PACER_WINDOW=500 WIVRN_PACER_PERCENTILE=99
  WIVRN_CLIENT_MARGIN_MS=2.5` gives safe 27-31 vs 34-36 and decoded>blit p50 14-17 vs 19-21 ms right after a load,
  but 2-11 frames shown late and 11-21 repeats per 30 s (stock: 0-1 and 4-5). In long steady play stock settles to
  ~29 ms too, so there is no default that cuts latency without adding late frames.
- Tried and dropped: user-interactive QoS for the compositor, waiter, encoder, sender and network threads (Monado
  `u_try_to_set_realtime_priority_on_thread` is a no-op on macOS). No change in the compositor-wake or
  encoder-start tails (present>decoded p99.5 27.1/29.0 vs 27.8/29.5). Patch kept out of the tree.
- What would help: a client that shows the newest decoded frame (reprojected) instead of holding it for the
  predicted slot would make latency ≈ actual arrival (p50 ~18 instead of safe ~29-36 ms; −10-15 ms) and turn a late
  frame into one frame of extra latency instead of a repeat+skip. That needs a client build. On the stock client:
  a lower bitrate (client setting; 200 Mbit/s total now) shortens network and decode, and a cleaner/less busy Wi-Fi
  channel shrinks the tail.

## Step 7 findings (2026-10-24)

- **Startup stall: fixed** (root cause in docs/encoder.md). It was libmvt's prewarm PTS (`CLOCK_UPTIME_RAW`) against
  WiVRn's `CLOCK_MONOTONIC` PTS, which made VT generate gigabytes of CBR filler.
  - Before, the first ~22 s of each session ran at 5-44 fps with ~30 IDRs.
  - Now 3 of 3 fresh sessions run at 90 fps within 0.3 s, with 0 IDR requests.
- **GPU sync works.** WiVRn's compositor inherits `create_semaphore` from `comp_base`, which uses `comp_semaphore`
  and Monado patch 0012 (MTLSharedEvent). With `MONADO_SYNC_STATS=1`:
  - hello_xr logs "client commit (timeline semaphore)", median 0.035-0.044 ms.
  - The server logs commit to client GPU done in 0.011-0.013 ms, at 90 fps.
  - No change was needed.
- **Latency.** The 80 ms prediction came from the stall. The pacer's present>decoded estimate is the p99.5 over
  the last 5000 frames (~55 s), so 300-700 ms startup encodes pushed the prediction to `max_extrapolation_ns` (80 ms).
  - Client HEAD prediction, median (max): 48-51 ms (82) before, 38 ms (53-69) after.
  - Steady state p50/p95, ms (headset feedback):

    | present>encode | encode | network | decode | decoded>blit | blit>display | present>decoded |
    |---|---|---|---|---|---|---|
    | 2.9/4.9 | 3.7/4.5 | 3.3/4.3 | 3.3/3.8 | 6-11/9-13 | 16-17/17-21 | 13.1-15/16-20 |

  - Pacer safe present>decoded 19-25 ms, render>display 16-18 ms, tracking latency 2-4 ms.
  - Clock offset stable.
- **Clock note (not changed).** Monado's `os_monotonic_get_ns` uses `CLOCK_MONOTONIC`. On Darwin that is
  `gettimeofday() - boottime`, with 1 µs resolution. It includes sleep and follows NTP adjustments: it is 8 s apart
  from `mach_continuous_time` here. Every Monado/WiVRn timestamp uses that same function, so nothing is inconsistent.
  Libraries with their own clocks must not be mixed with it: VT PTS (fixed by the libmvt timeline), VK calibrated
  timestamps (`mach_absolute_time`), `std::chrono::steady_clock`. A switch to `CLOCK_MONOTONIC_RAW`
  (`mach_continuous_time`, ns) would be a Monado patch. It is left as a follow-up because nothing measured needs it.

## Zero-copy encode (step 7, 2026-10-24)

Patch 0005; design under "What the patches change". Option (b) of the IOSurface spike: a standard
`420f`/`xf20` surface with two Metal plane textures imported as R/RG images, so there is one shader change
(per-stream image arrays) and no MoltenVK-shaped surface.

**Correctness.**
- Bit-exact: `WIVRN_VT_VERIFY=1` compares every encoded IOSurface with the readback of the same images. In the pattern
  session (30 s) and in hello_xr (25 s), 0 of 2351 / 1518 frames per stream differed.
- Decoded streams: `xr_empty_frames --pattern 0` (static high-detail pattern), 20 s each, same settings
  (2×1152² Main10, 24.7 Mbit/s, 90 Hz). PSNR of decoded frames between runs, `compare_streams.py`, stream 0:
  zero-copy vs readback Y 49.03 / Cb 51.78 / Cr 51.93 dB, readback vs readback 49.05 / 51.73 / 51.87 dB.
  So the difference between the paths is the run-to-run encoder difference. The moving pattern gives ~30.8 dB for both
  pairs: at 18.5 Mbit/s the encode noise is larger than the frame matching can resolve.
- hello_xr in the headset: build/logs/zc/smoke-0-f600.png (cube on slate grey, as before).

**Measurements** (2-min sessions, Quest 3S, same settings, `caffeinate -i`, logs build/logs/s7/m-*; per stream p50/p95
in ms, CPU = `ps` average of the 10-s samples):

| Session | encode call | wait (GPU / readback fence) | submit>encode start | server CPU | VT service CPU | server RSS | present>decoded p50 | Mbit/s |
|---|---|---|---|---|---|---|---|---|
| hello_xr readback | 2.95 / 3.34 | 0.62 / 4.12 | 0.11 / 0.21 | 16.6 % | 6.1 % | 83 MB | 13.1 | 0.2 |
| hello_xr zero-copy | **2.65 / 2.96** | 0.63 / 4.16 | **0.04 / 0.09** | **11.7 %** | 5.3 % | **67 MB** | 12.8 | 0.2 |
| pattern readback | 2.92 / 3.36 | 0.77 / 3.80 | 0.11 / 0.22 | 16.5 % | 5.4 % | 85 MB | 16.8 | 18.5 |
| pattern zero-copy | **2.64 / 2.95** | 0.82 / 4.09 | **0.05 / 0.10** | **13.9 %** | 5.8 % | **69 MB** | 15.8 | 18.5 |

- Zero-copy saves the CPU copy into the VT pool buffer: −0.3 ms per encode call (−10 %), and 3-5 points of one core.
  The readback's own GPU copy doesn't show up in the wait: the wait is dominated by the compositor's GPU work
  (foveation p50 ~0.35-0.4 ms GPU, MoltenVK timestamps; p95 is noisy, 1-4 ms) and by when the encoder thread wakes.
- All four sessions: 89.9-90.0 fps, 2-8 skipped ids, 1-2 IDRs. present>decoded is client-measured and has
  run-to-run noise of about ±1 ms (pattern network p95 5.6-12.9 ms vs 6.7 ms).
- Encode call → VT output is ~2.6 ms in both modes; at this size it is VT time.

## Not done / follow-ups

- (done, patch 0005) Zero-copy encode.
- With zero-copy, VMA still allocates and binds Vulkan memory for each imported plane image, because Vulkan
  requires a bind; MoltenVK renders into the imported MTLTexture, so the allocation is unused. That is as much
  again as the surfaces: about 20 MB at 2×1152² 10-bit (2 compositor images × 3 streams).
- ffmpeg fails to decode VT HEVC dumps past POC 2048 ("Could not find ref with POC 2045"), also with libmvt alone
  (`mvt_test --frames 2300`), so it is not WiVRn's doing. The Quest's decoder is fine (no IDR requests in
  5-min soaks). Probably the long-term reference / POC LSB wrap of VT's infinite GOP; compare dumps below
  frame 2000.
- Microphone, input forwarding (uinput), wivrnctl/dashboard and the systemd/flatpak paths are off.
- The active-runtime management assumes XDG paths. `run-wivrn.sh` disables it.
- x264 on Apple would read the plane aspects of a non-planar image. It needs the same `cbcr` path as the VT
  encoder before it can be used.
