# macvr TODO

Plan: [docs/porting-plan.md](docs/porting-plan.md)

## Status
- [x] Survey Monado / WiVRn / an earlier private Steam Link prototype (2026-10-24)
- [x] Porting plan for milestone 1
- [x] M1 step 0: pin versions (wivrn v26.9, monado f037264d, openxr-sdk 1.1.65), `scripts/patches.sh`
- [x] M1 step 1: Monado builds; in-process hello_xr on MoltenVK (Vulkan and Vulkan2, ~10 s, ~160-200 frames, clean exit)
- [x] M1 step 2: IOSurface ⇄ MoltenVK cross-process spike (203 PASS; spikes/iosurface/RESULTS.md; plan amended)
- [x] M1 step 3: Monado out-of-process: Mach side channel, own IOSurfaces, MTLSharedEvent sync; hello_xr arm64 + x86_64/Rosetta render (see Step 3 notes)
- [x] M1 step 4: WiVRn server builds/runs on macOS (patches/wivrn 0001-0003 (0004 in step 7), docs/wivrn.md; Bonjour, pairing, Quest connects)
- [x] M1 step 5: VideoToolbox encoder backend `videotoolbox` (readback; streams encoded in parallel; ffprobe-clean HEVC dump)
- [x] M1 step 6: headset check (2026-10-25): Alyx via the full stack "looks good" after the pacing fix. Agent check done: out-of-process hello_xr streams to the Quest at 90 fps (screencap build/logs/quest-hello-xr.png)
- [x] M1 step 7: zero-copy encode + measurements (MTLSharedEvent sync done in step 3)
  - [x] Stability/performance (2026-10-24): startup stall root-caused and fixed, IDR cap evaluated, GPU sync verified in
    WiVRn, latency breakdown logged, 5-min soak. WiVRn patch 0004, libmvt PTS timeline. See "Step 7 notes".
  - [x] Zero-copy encode (2026-10-24): WiVRn patch 0005, libmvt `mvt_create_input_buffer`/`mvt_metal_plane_texture`.
    Bit-exact against readback, encode call −0.3 ms, server CPU −3-5 points. See "Zero-copy notes".
- [x] M2 research + design: [docs/bridge-plan.md](docs/bridge-plan.md); feasibility spike spikes/bridge (ALL PASS)
- [x] M2 steps 1–5 (2026-10-24): `bridge/` (wineopenxr.dll + .so), Monado patch 0014; hello_xr.exe -g D3D11/Vulkan2/Vulkan and array/depth/time tests in the scratch prefix (docs/bridge-plan.md §0)
- [x] M3 prep (2026-10-24): OpenComposite (`openxr` cff07db + patches/opencomposite 0001-0004, llvm-mingw) on the bridge; OpenVR 2.15.6 D3D11 + Vulkan test apps render through it in the scratch prefix, Alyx's action manifest loads ([docs/m3-opencomposite.md](docs/m3-opencomposite.md))
- [x] M2 step 6 (FEX flavor, 2026-10-28, [docs/bridge-plan.md](docs/bridge-plan.md) §7a): universal (x86_64+arm64)
  `wineopenxr.so` + WiVRn client (`build-wivrn.sh --client-arm64`, lipo), x86_64 PE; on FEX Wine pairs the PE with
  `lib/wine/x86_64-windows/wineopenxr.so`, so MacVR installs the `.so` there and in `x86_64-unix`. hello_xr/array/time
  tests pass on FEX (DXMT; no arm64 DXVK), Alyx runs on all three tools. Alyx FEX vs Rosetta: 89.4 vs 87.1 fps, app CPU
  2.8 vs 4.5 ms p50, hlvr 394 vs 453 %, M2P 66.5 vs 75.5 (safe varies). Alyx 26227071 runs at 89 fps on FEX.
  Step 7 and M4 done (M3 Alyx, MacVR app below)
  - [x] Alyx moved to `notproton-fex` (2026-10-28): per-game CompatToolMapping, FEX prefix active, Rosetta prefix
    parked as `compatdata/546560.rosetta` (preview one as `546560.preview-20261028`). `scripts/alyx-runner.sh fex|rosetta`
    switches (one steam://exit, mapping, prefix swap, rescan). Check after the switch: FEX `fex-main1` 88.6 fps, M2P
    70.9, actual p50 62.4; Rosetta `ros-main1` 88.2 fps, M2P 73.4, actual p50 65.3 (build 25487405, 90 Hz, gate passed).
  - [x] CrossOver 26.3 release (2026-10-29, `notproton-26.3`, x86-only so Rosetta): its DXMT v0.72 has shared textures
    but no keyed mutex (`SharedResourceData` 108 bytes, no `mutex_handle`), so the bridge refused the device
    (`XR_ERROR_GRAPHICS_DEVICE_INVALID`, Alyx hung on OpenComposite's abort). Fixed: the bridge accepts the short layout
    and falls back to fence sync (game thread `ID3D11DeviceContext4::Signal`, the async worker, default mode 2, waits on
    the fence before the copy; `WINEOPENXR_DXMT_SYNC=fence` forces it, `cpu` is the old event-query spin). Alyx 90 Hz:
    26.3 fence `rel-fence1` 83.1 fps, M2P 69.9, actual p50 62.7, app CPU 16.2 (waits for the previous GPU frame at
    xrBeginFrame); 27 Rosetta forced cpu `ros27-cpusync1` 36 fps, forced fence `ros27-fence1` 77.2; keyed mutex (27)
    unchanged: FEX `fex-main2` 89.4 / M2P 66.2, Rosetta `ros-main2` 89.5 / 63.4. MacVR 7e9b30b9180c deployed (includes
    the system32 legacy-detection fix). `scripts/alyx-runner.sh release`; prefix parked as `546560.release`.
  - [x] First launch on a new runner has no VR (2026-10-29): `macvrreg.dll`, a builtin MacVR generates per user
    (`RunnerRegistration.swift`, placeholder from `bridge/src/macvrreg.*`) with our values as a `WINE_REGISTRY` script;
    wineboot applies it to every prefix it creates or updates (setupapi `register_fake_dll`), NotProton's templates
    included. Scratch: fresh `wineboot --init` prefixes on 26.3 Rosetta, 27 Rosetta and 27 FEX get all 4 values; rescan
    sees them as ok; mode switch regenerates; uninstall removes it. Real: 26.3 template + Alyx prefix removed, first
    launch built both and reached FOCUSED in VR (36 fps first run in the new prefix, 77 on the second). The app also
    installs runner files from its 5 s tick when a runner lacks them. Deployed in e1617c354bd0.
  - [ ] System-audio permission prompt breaks the first launch (2026-10-29): after deploying a new build and opening
    MacVR.app, macOS asked '"MacVR" would like access to record your system audio'. While it was pending the headset
    session didn't come up and Alyx, launched from Steam, failed with `VRInitError_Init_HmdNotFound (108)`. The app is
    ad-hoc signed, so every new build may count as a new app for TCC and ask again. To do: a stable signing identity;
    ask for the permission at app start (before the server/headset session) with a clear status; never let a pending or
    denied audio permission block the headset session (stream without audio instead).
  - [ ] MacVR's recommendation for new users (FEX vs Rosetta) in the app/docs; Alyx 26227071 still needs Rosetta's fix
    (1-2 fps there), so Alyx stays on 25487405 while Rosetta must keep working.
  - [x] Deploy the system32 legacy-detection fix (deployed 2026-10-29 with 7e9b30b9180c).
- [x] ~~M4 design (2026-10-24, [docs/m4-notproton.md](docs/m4-notproton.md))~~ superseded by the MacVR app: hook.sh sourced by a 5-hunk patch to NotProton's `run` (patches/notproton on a local snapshot repo), per-prefix install + `macvr-vr` record, WiVRn as LaunchAgent `org.macvr.wivrn`, 250820 guard; next: build helpers/hook, tests T0–T4 on scratch clones
- [x] M3: Half-Life: Alyx (2026-10-24/25, real prefix 546560): D3D11 on stock DXMT through OpenComposite → bridge → WiVRn
  → Quest; menu and game play, checked in the headset: "looks good" (2026-10-25). Fixes: OpenComposite 0005 (MinGW/MSVC struct-return
  ABI), WiVRn 0006 (recenter) / 0007 + Monado 0015 (pacing). `-vulkan` blocked: MoltenVK lacks `multiviewGeometryShader`
  (no CrossOver patches). See "M3 Alyx notes" and [docs/m3-opencomposite.md](docs/m3-opencomposite.md).
- [x] No VR is quiet (2026-10-26, OpenComposite patch 0007): with no server or no headset, `VR_IsHmdPresent` returns false
  and `VR_Init` returns `HmdNotFound` (108) in under 0.15 s, with no dialog. A lost runtime (server restart)
  sends VREvent_Quit instead of the modal "OpenComposite Error". If the game doesn't shut VR down within 10 s, the process exits
  (ini `runtimeLostExitSeconds`). Tested in a scratch prefix clone (no server / WiVRn-like listen-only socket / service
  killed mid-session). Deployed to Alyx 2026-10-26 (with 0008). See [docs/m3-opencomposite.md](docs/m3-opencomposite.md#no-vr-and-runtime-loss-2026-10-26).
- [ ] **Web overlays: SteamVR's vrwebhelper pipeline** (2026-10-26, [docs/web-overlays.md](docs/web-overlays.md)): Alyx's own
  interstitials page (`game/hlvr/webui`) rendered as on SteamVR. OpenComposite 0008-web-overlay-mailbox (replaces the
  text-only 0008, backup in build/backup): real `IVRMailbox` + `RegisterExternalWebRoot` over SteamVR's mailbox protocol;
  `macvr-broker` (ws://127.0.0.1:27062, started by the app with the server); `macvr-webhelper` (offscreen WKWebView,
  `window.VRHTML`, `vrwebui://` scheme handler, scene graph → quads); `CMacVRXR` (XR_EXTX_overlay session on WiVRn,
  one 2048² sRGB swapchain = the page texture, a quad per panel via `imageRect`). Verified headless: the page's real
  `ready`, Alyx's message sequence through OpenComposite in Wine, panel dumps (spinner arcs, ellipsis, "Press Trigger To
  Start"), overlay session + images against monado-service. Cost (loading screen, screen sharing off): helper ~3 %,
  WebContent ~2 %, WebKit GPU 8-13 % of a core; ~0.75 ms GPU copy per changed image.
  - [x] Headset check (2026-10-26): Alyx end to end through WiVRn; "Press Trigger To Start" size/position OK, LOADING
    with spinning arcs and dots good. Details and cost in the doc's Status.
  - [x] Fonts: Raju is Valve-encrypted (vrserver's `get_font` decrypts it); the page uses its Arial fallback. Decision
    (2026-10-26): leave it. A plain `raju-*.otf` in `~/Library/Application Support/macvr/fonts/` would be used.
  - [ ] Re-check the App Nap fix in a game (capture fell to ~2/s after minutes before it).
  - [ ] Render models (holograms, `play_space_center_feet` on every loading screen, the city map in a2+): parsed, not
    drawn. SteamVR's shaders are in `SteamVR/resources/shaders/vulkan` (SPIR-V); the uniform mapping is unknown.
- [x] Bridge DXMT path (2026-10-24): XR_KHR_D3D11_enable on stock DXMT (`CX_GRAPHICS_BACKEND=dxmt`), no CrossOver patch,
  no Monado patch. Alyx's menu renders with its 3D background in the headset (`build/logs/m3-alyx-dxmt-2.png`). See
  "DXMT bridge notes" and [docs/bridge-plan.md](docs/bridge-plan.md) §4a.

- [x] Bridge render-thread cost / async xrEndFrame (2026-10-25): per-frame bridge stats (`WINEOPENXR_STATS=1|2`) show
  the bridge costs 0.7 ms per frame on Alyx's frame thread (the old 1.5-2.6 / 11-16 ms figure was a timer that included
  the game's own work). Async worker (`WINEOPENXR_ASYNC=1|2`) brings that to 0.4 ms but doesn't change fps, 1% low or
  spikes, so it is off by default. Wine's D3DKMT keyed mutex needs acquire and release on the same thread, so both moved
  into the copy step. The frame-interval spikes are `xrWaitFrame` (Monado app pacer in WiVRn, waits 0 or 20-34 ms).
  See [docs/ab-alyx.md](docs/ab-alyx.md#bridge-render-thread-cost-and-async-xrendframe-2026-10-25), bridge-plan §4a.
  Done: see Frame pacing below (it was WiVRn's app pacer).

- [x] Frame pacing (2026-10-25): the `xrWaitFrame` 0/20-34 ms alternation was WiVRn's own app pacer
  (`server/driver/app_pacer.cpp`; Monado's `u_pacing_app` isn't used). A native app with a fixed 10 ms frame showed it too
  (56 fps). Causes: the raw per-frame compositor time (jumps 4-20 ms when the compositor wakes late), GPU time that counted
  `comp_multi`'s one-frame backpressure (feedback into "don't wait" mode), any lateness skipping a whole slot. WiVRn patch
  0007 + Monado patch 0015, in build/wivrn-next: Alyx 72 Hz 62-67 → 71-72 fps, 1% low 25 → 36-49, intervals > 20 ms
  168-283 → 8-43; 90 Hz 82.8 → 89.9 fps, 129 → 1. See [docs/ab-alyx.md](docs/ab-alyx.md#frame-pacing-2026-10-25),
  docs/wivrn.md 0007. Open: irregular compositor wakes. (Compositor latency: see "Motion-to-photon latency" below.)

- [x] Motion-to-photon latency (2026-10-25, WiVRn patch 0009, build/wivrn-next): the ~22 ms decoded>blit hold is the
  pacer's safe present>decoded (p99.5 of both eyes over 5000 frames + 1 ms) minus the actual arrival. The stock
  client holds an early frame until the slot whose display time matches the frame's label. The safe value is the
  real tail, not a bug: Wi-Fi network time swings (4.5 → 15 ms p50 for minutes at constant bitrate), Quest decode
  (2nd eye ~4 ms after the 1st), and the 55-s window keeps load/burst spikes for up to a minute (the 37-40 ms
  reading). Not caused by 0007/0015 or the clock domain (offset drift < 1 ms per 30 s and cancels). 0009 makes the
  estimate configurable and logs client misses (shown late / repeated / skipped). Defaults stay upstream's: no
  setting cuts latency without more late frames. Opt-in `WIVRN_PACER_WINDOW=500 WIVRN_PACER_PERCENTILE=99
  WIVRN_CLIENT_MARGIN_MS=2.5`: safe −5-8 ms, decoded>blit p50 −3-7 ms after a load, but 2-11 frames shown late per
  30 s (stock 0-1). A client-side fix (show the newest decoded frame, reprojected: ≈ −10-15 ms) is ruled out: the Quest client stays stock (2026-10-28). Details
  and measurements in docs/wivrn.md (0009) and Measurements below. Tried and dropped: user-interactive QoS on the
  compositor/encoder/sender/network threads (no measurable change).

- [x] Recenter for room-scale games (2026-10-24; confirmed working in Alyx, WiVRn patch 0006, build/wivrn-next). A Quest recenter (holding Meta) reaches the server, but WiVRn only recenters LOCAL spaces, and Alyx/OpenComposite uses STAGE, so nothing changes. SteamVR's "reset view" used to fix this. Fix done, not yet deployed: WiVRn patch 0006-recenter-stage re-origins STAGE to the current head pose on recenter (heading only, floor height kept; `WIVRN_RECENTER_STAGE=0` disables) and retries recenters for 2 s, which fixes the wake-time "failed to recenter local spaces". Offset math tested by `tests/wivrn/recenter_stage_test.cpp` (ALL PASS). Built in build/wivrn-next (`WIVRN_BUILD_DIR` in build-wivrn.sh). Details in [docs/wivrn.md](docs/wivrn.md) under 0006. Next: switch the server (server and Alyx restart), then holds Meta in Alyx and checks the log for `recentered stage`.

- [x] Audio (2026-10-25, WiVRn patch 0008-macos-coreaudio, build/wivrn-next; confirmed in the headset 2026-10-25): game audio
  goes to the Quest over WiVRn's normal audio stream and is muted on the Mac while the headset is connected. A Core Audio
  process tap (`CATapMutedWhenTapped`, private, macOS 14.2+) → a private aggregate device holding only that tap, with
  5 ms buffers (240 frames) → AudioConverter float32 → the headset's S16 format and rate → `audio_data` per buffer.
  - What is tapped (`WIVRN_AUDIO_TAP`, default `auto`): the connected OpenXR clients' PIDs (`LOCAL_PEERPID` on the IPC
    socket, else Monado's self-reported pid). If none of them has a CoreAudio process object, the tap is global minus the
    server itself. The target is re-checked every 0.5 s and changed in place (`kAudioTapPropertyDescription`, same UUID).
    Alyx: the client is `hlvr.exe` (wine loader pid), and it is the only process playing audio, so no
    process-group or child-process search is needed. `clients` = only clients (silent without one), `global`,
    `pid:N[,M]` (tests), `off`.
  - Why: Wine plays audio in the game process (winecoreaudio's unix side, in-process), the same process as the OpenXR
    client (bridge .so). The global fallback covers the time before the game opens audio and the Quest home, and it is
    what you get if a game plays audio from a helper process. Downside: with no game, all Mac audio (music,
    notifications) goes to the headset while it's connected.
  - Lifecycle: tap and aggregate created per session; IO starts on `resume` and stops on `pause` (headset gone), and
    the destructor destroys both. `MutedWhenTapped` unmutes as soon as reading stops. SIGTERM, SIGKILL and the
    session-end `execv` all gave Mac audio back within 1 s (coreaudiod drops a dead client's taps).
  - TCC: the first `AudioDeviceStart` on a tap asked "Terminal.app would like access to record your system audio"
    (answered with Allow). The grant goes to the responsible process (Terminal), so the bare CLI server needs no
    Info.plist, usage string or signature when started from Terminal. A LaunchAgent (M4) will need its own grant: an
    embedded `__TEXT,__info_plist` with `NSAudioCaptureUsageDescription` + signature, and a one-time Allow.
  - Verified: `build/tests/audio_tone` plays into Steam Streaming Speakers and records its loopback input. Tapped by
    pid, then global: server 200 packets/s, 48 kHz, -23.0 dBFS (= the tone), loopback 0.0707 → 0.0000 while tapped and back
    to 0.0707 within ~1 s after disconnect, SIGTERM or SIGKILL. The Quest logs "Speaker stream started". Alyx (auto): global →
    `clients: <pid> (hlvr.exe)` once the game opened audio, -20 to -26 dBFS rms, 0 send errors; back to global after quit.
  - Measurements: Mac side capture→send mean 5.0 ms (one buffer), max 5.1 ms (32 ms once at the tap switch), callback gap
    max 5.1 ms. Network adds ~2-4 ms. The Quest client's jitter buffer is 5-50 ms (it trims to 30 ms above 50), plus
    AAudio output. End-to-end is not measured. CPU (tone, no app): server +0.6 points (1.4 vs 0.8 %), coreaudiod +1.6
    points of one core.
  - Leftovers: no Quest mic on the Mac (needs a virtual input device); a listening test; the LaunchAgent TCC
    grant (M4); the client ignores the packet timestamp (as with PipeWire), so there is no A/V sync beyond its jitter
    buffer.
- [x] Matching x86_64 IPC client (2026-10-26): the bridge's `libopenxr_monado.dylib` is now WiVRn's `libopenxr_wivrn`
  built for x86_64 from the server's tree and `build/monado-snapshot` (`scripts/build-wivrn.sh --client-x86_64`, ~10 s;
  Rosetta ran it without delay). Tag v26.9, socket `wivrn/comp_ipc`, same `XRT_*` config and identical generated IPC
  files. `launchctl unsetenv IPC_IGNORE_VERSION` and the `monado_comp_ipc` symlink are gone (`wivrn-ipc-link.sh` is kept,
  marked obsolete).
  - IPC stamp (`scripts/ipc-stamp.sh`): tree `e9c9bc92…` + socket + tag, next to the server and the client. The start
    scripts publish the server's copy to `$TMPDIR/wivrn/ipc-stamp`. `wineopenxr.so` logs `ipc-stamp match` and refuses
    a mismatch (`WINEOPENXR_IGNORE_IPC_STAMP=1` overrides).
  - Proof (screen sharing off): Alyx via the new client logs `ipc-stamp match`, has no version-mismatch line in
    notproton-wine.log, and the hlvr.exe env has no `IPC_IGNORE_VERSION`. Server (low-latency env): 2×89.9–90.0 fps at
    ~25 Mbit/s, audio 200 packets/s from `hlvr.exe`, VR init 0 s, `alyx-save.sh` 62 s. The headset wasn't worn (Quest
    "Finding position in room" overlay), so the picture itself is unchecked.
  - TCC lesson: game processes must not read anything under `~/Documents`. The first stamp check read the server's
    stamp from the build dir, which caused Documents prompts for wine and Alyx and stalled VR init by 62 and 108 s
    until they were answered. Fixed by the `$TMPDIR` copy.
- [x] steam.exe vrclient route tested (2026-10-26), **not kept**: NotProton's steam.exe is a PE build, so its `getenv`
  has no `HOME` and it always deletes the prefix vrpath. That caused one OpenVR 110 dialog. It only works with
  `VR_PATHREG_OVERRIDE=Z:\...`, which `run` doesn't forward, and a global `launchctl setenv` was ruled out. The backup
  is restored and the read-only vrpath stays. Details in docs/m4-notproton.md §0 "vrclient route".
- [x] Bridge: NULL-instance functions without a runtime (2026-10-26). With no unixlib or no usable runtime,
  `xrGetInstanceProcAddr` refused everything and the static Khronos loader called NULL (crash dialog). Now
  `xrEnumerateInstanceExtensionProperties`, `xrEnumerateApiLayerProperties` and `xrCreateInstance` are always returned and
  report `XR_ERROR_RUNTIME_UNAVAILABLE`. Tested in the pathtest scratch prefix (no unixlib: −51, no crash; normal: 49
  extensions, ipc-stamp match). Deployed to Alyx (C:\macvr + system32). docs/bridge-plan.md §3.
- [x] OpenVR without a vrpath (2026-10-26): `VR_OVERRIDE` + `VR_CONFIG_PATH` + `VR_LOG_PATH` (all three needed, Windows
  `Z:\` paths, not unix) pointing at an OpenComposite copy outside the prefix,
  `~/Library/Application Support/macvr/opencomposite/`. steam.exe doesn't strip them (its conversion fails under NotProton).
  Works from `launchctl setenv` (global, lost on reboot), from the prefix's `HKCU\Environment` and from
  `HKLM\...\Session Manager\Environment`. **Alyx now uses the HKLM values, no vrpath, no launchctl variables.**
  M4 can write these three values per prefix instead of the read-only file. docs/m4-notproton.md §0 "VR_OVERRIDE route".
  - Follow-up: `install-vr-546560.sh`/`uninstall-vr-546560.sh` still install the read-only vrpath and in-prefix
    `C:\OpenComposite`; switch them to the outside copy + registry values.

- [x] **M4: MacVR app** (2026-10-26, [docs/macvr-app.md](docs/macvr-app.md)): `app/` Swift package (core + `macvr`
  CLI + menu-bar app), `scripts/build-app.sh`, installed as /Applications/MacVR.app. No login item, no launchctl env,
  no Steam restart, no backend forcing, no change to NotProton's `run`. On open: deploy the payload to
  `~/Library/Application Support/macvr/versions/<stamp>` (`current` symlink), add `wineopenxr.dll`/`.so` to every
  NotProton runner's `lib/wine/x86_64-*` (add-only, sha record), write `ActiveRuntime` + `VR_OVERRIDE`/`VR_CONFIG_PATH`/
  `VR_LOG_PATH` (HKLM Session Manager\Environment) into the prefix templates, then into game prefixes that miss them
  (skipped while a wineserver runs), start wivrn-server as the app's child. Bridge `.so` falls back to the client in
  `macvr/current/bridge/x86_64-unix`. Tested: 17 unit tests and scratch clones (idempotence, `wine reg query`, busy
  skip, runner-mode `xrCreateInstance` = 0, uninstall round trip). **Real install verified** (checked in the headset): Alyx
  started normally from Steam loads the runner's `wineopenxr.so`, the client and `vrclient_x64.dll` from
  `macvr/versions/…`, `ipc-stamp match`, 90 fps, audio tapped from hlvr.exe, OpenComposite shows the text-only "Press
  Trigger To Start" interstitial. Left:
  - [x] Legacy cleanup of 546560 (2026-10-28: files moved to macvr-backup, launch-option token removed): runs at the first rescan with Alyx quit (the running app retries
    every 60 s); the old `WINEDLLPATH` launch-option token goes once Steam is quit. That also ends the
    `C:\macvr\wineopenxr.env` logging.
  - [x] Deleted `~/Library/Application Support/macvr/opencomposite` (moved to Trash 2026-10-28; nothing referenced it).
  - [x] FEX flavor (2026-10-28): universal `.so` in `x86_64-unix` and `x86_64-windows` of every runner.
  - [x] VR game detection via appinfo + headset app list (2026-10-29): WiVRn patch 0010 lists installed Steam VR
    games (appinfo.vdf VR flags, type game/demo; SteamVR is a Tool) with cover-art icons and starts a pick with
    `/usr/bin/open steam://rungameid/<id>`; `macvr status` uses the same rule (`AppInfo.swift`, DLL heuristic only
    for apps missing from appinfo). Verified on this Mac with `list-apps` (only Alyx) and a scratch Steam tree; 4 unit
    tests. See [docs/wivrn.md](docs/wivrn.md) 0010. Left: check the list, icon and launch in the headset after
    deploying a server built with 0010 (build/wivrn-apps).
  - [ ] Quest client doesn't reconnect by itself after a server restart (WiVRn client).
  - [x] Main window + menu bar, user-added CrossOver bottles and Steam libraries (2026-10-29,
    [docs/macvr-app.md](docs/macvr-app.md#crossover-bottles-and-extra-steam-libraries-added-by-the-user)): bottles get the
    registry values plus `[Wine] "LibPath"` += `macvr/bottle-lib` (CrossOver overwrites WINEDLLPATH from
    `[EnvironmentVariables]`); CrossOver 26 bottles have an unlinked CurrentControlSet. hello_xr D3D11 (DXMT, DXVK) in a
    scratch bottle reached a running session. Not deployed yet.
  - [ ] Bridge: find CrossOver.app's MoltenVK (`lib64/libMoltenVK.dylib`; `moltenvk_path` only tries `lib/<arch>`), so
    `XRT_VK_GIPA_LIBRARY` is set in bottles too. Then a longer DXMT run in a bottle with a real VR game.
  - [ ] WiVRn's headset app list doesn't see added Steam libraries.
- [x] Linux comparison (2026-10-28 re-run on the fixed 1 Gbit path, [docs/linux-comparison.md](docs/linux-comparison.md)):
  stock Linux WiVRn 26.9 (flatpak, xrizer, native Alyx, fidelity 3, 90 Hz, same save) reads overlay M2P **63-74 ms
  with NVENC AV1 10-bit** and **70-79 ms with NVENC HEVC 10-bit**, vs the Mac's 88 (stock) / 85 ms (low-latency).
  0 % ping loss, 2-6 IDRs and 7-10 incomplete frames per 30 s, GPU 28 %. The 10-26 149 ms was the 100 Mbit link.
  - [ ] Find where the Mac loses ~10-15 ms vs Linux (compare per-stage: Linux has no 0004 breakdown; overlay
    Timings graphs show Predicted ~40 ms on Linux).
  - [ ] Re-check the Windows Air Link/Steam Link numbers, which used the same old 100 Mbit link.
## Decisions
- Decision (2026-10-29): main window + menu bar; users can add CrossOver bottles and extra Steam libraries.
- Decision (2026-10-28): main work and measurements on FEX (`notproton-fex`); finish each piece of work with a Rosetta
  check; both runners stay supported.
- Decision (2026-10-26): MacVR app: install-and-run, no edits by the user. Don't modify NotProton/CrossOver files, except
  adding our 2 bridge files to the runners (add-only). No login item or LaunchAgent, no global (launchctl) variables.
  Registry values go into the prefix template first, game prefixes only as a fallback. Don't set
  `CX_GRAPHICS_BACKEND`; document DXMT (preferred) / DXVK, D3DMetal unsupported. Quit stops the server.
- Decision (2026-10-24): don't patch any CrossOver/NotProton component (DXMT, DXVK, MoltenVK, Wine). Alyx under DXVK loses its menu background: CrossOver's MoltenVK geometry-shader emulation emits invalid Metal for 4 pipelines. So Alyx moves to stock DXMT, and the bridge gets a DXMT D3D11 path built on DXMT's stock shared textures. Changes go only in our code and our Monado patches.
- Decision (2026-10-24): no DXMT patches. Milestone 2 uses stock DXVK (D3D11→Vulkan via winevulkan→MoltenVK) and DXVK's existing interop (ID3D11VkInteropDevice1::CreateTexture2DFromVkImage etc., as Proton's wineopenxr does). This replaces the "stock DXMT + interop API" plan.
- D1 IOSurface Mach port as graphics buffer handle, IOSurface allocated by us with a real pixel format;
  D2 Mach side channel via bootstrap service (name derived from the socket path) + socket nonce;
  D3 MTLSharedEvent timeline semaphores (server exports, client imports), CPU wait as fallback; D4 pin wivrn tag = client APK, patches staged not committed;
  D5 VT encoder readback then zero-copy; D6 Linux-only server pieces ifdef'd. Details in plan.

## Open questions
- (resolved) Quest 3S runs WiVRn client 26.9 (versionCode 5527) → server pinned to v26.9, monado f037264d.

## Headset access
- Quest 3S on Wi-Fi. adb over TCP lasts until the Quest reboots; after a reboot re-enable it over USB (`adb tcpip 5555`).
- adb over the network: `adb connect <quest address>:5555`.
- If adb connect says "No route to host" while `nc -z` works, it's Local Network privacy on a stale adb server: `adb kill-server` and reconnect.

- Kept awake (2026-10-24): `am broadcast -a com.oculus.vrpowermanager.prox_close`, `svc power stayon true`,
  `settings put system screen_off_timeout 2147483647`. Undo: `...vrpowermanager.automation_disable`, `svc power stayon false`,
  reset screen_off_timeout (old value wasn't recorded; Quest default is in Settings > Display).

## Step 1 notes (2026-10-24)
Build and run commands are in [docs/build.md](docs/build.md). The short version: `scripts/patches.sh apply && scripts/build.sh && scripts/run-hello-xr.sh inproc 10`.

Our Monado patches, applied after WiVRn's 0001-0011:
- 0001 ipc client future: rename the static `wait()`, which clashes with `<sys/wait.h>` on macOS.
- 0002 c/multi: macOS has no `pthread_cond_clockwait`, so WiVRn patch 0001's wake wait uses `pthread_cond_timedwait_relative_np`.
- 0003 ipc server: the APPLE branch now builds `ipc_server_mainloop_linux.c`.
  - epoll is replaced by `poll()` in the mainloop and the per-client thread.
  - WiVRn 0002's `listen_socket` hook is kept.
- 0004 service: defines `int listen_socket = -1`. WiVRn 0002 only declares it as extern, which breaks a standalone monado-service.
- 0005 vk: portability enumeration (instance flag + extension) and `VK_KHR_portability_subset`.
  - Covers the comp_vulkan instance and the null/main compositor lists.
  - Also covers oxr `xrCreateVulkanInstanceKHR`/`DeviceKHR`.
  - `VK_ENABLE_BETA_EXTENSIONS` is set on OSX.
- 0006 vk: `VK_USE_PLATFORM_METAL_EXT` on Apple, which brings in `vkExportMetalObjectsEXT` and `has_EXT_metal_objects`.
- 0007 **IOSurface Mach port buffer handles (D1, in-process only)**:
  - On OSX, `xrt_graphics_buffer_handle_t` is now `mach_port_t` (`XRT_GRAPHICS_BUFFER_HANDLE_IS_MACH_PORT`).
  - Export: `VkExportMetalObjectCreateInfoEXT(IOSURFACE)`, then `vkExportMetalObjectsEXT`, then `IOSurfaceCreateMachPort` (`vk_get_native_handle_from_image`).
  - Import: `IOSurfaceLookupFromMachPort`, then `VkImportMetalIOSurfaceInfoEXT`. Memory is allocated normally.
  - `VK_EXT_metal_objects` replaces `VK_KHR_external_memory_fd` in the required lists.
  - Depth/stencil formats are not offered as swapchain formats.
  - The IPC send/receive of buffer handles is a stub that returns `XRT_ERROR_IPC_FAILURE` (D2 work).
- 0008 vk: chain `VkPhysicalDevicePortabilitySubsetFeaturesKHR`, as queried, into `vkCreateDevice`. Fixes VUID-imageViewFormatSwizzle on the no-alpha views.
- 0009 c/client: on OSX, drop the sync-fd extensions from the XR_KHR_vulkan_enable (v1) device list. MoltenVK lacks them; sync falls back to a CPU wait (D3).
- 0010 u_file: the runtime dir on OSX is `confstr(_CS_DARWIN_USER_TEMP_DIR)`. Before, it was a literal `~/.cache`, so bind failed.
- 0011 IOSurface: refuse array/cube images (array_size*faces > 1), because MoltenVK aborts inside Metal on them.

OpenXR-SDK patch 0001: hello_xr's Vulkan plugin enables portability enumeration (flag) and `VK_KHR_portability_subset`.

Decisions:
- **In-process mode needs buffer sharing too.** Monado's client compositor always imports the native compositor's images into the app's own VkDevice. So the "no export needed in-process" assumption was wrong, and part of D1 was pulled forward into step 1: the Vulkan side and the handle type, without the transport.
  - Step 3 is now D2 (Mach side channel in `ipc_message_channel_unix.c`) + D3 + depth/array handling.
- Standalone builds use two build dirs. `XRT_FEATURE_SERVICE=ON` turns the openxr dylib into an IPC client, so in-process needs its own build (`build/monado-inproc`).
- No `os_semaphore` on OSX. Nothing in Monado f037264d or the WiVRn v26.9 server uses it, and upstream already compiles it out on OSX.
- Thread names stay a no-op on OSX. macOS `pthread_setname_np` can only name the calling thread, and Monado names threads from the creator.
- Null compositor only. macOS has no window target, so the main compositor can't present. WiVRn brings its own target.

MoltenVK gaps found:
- No `VK_KHR_external_memory_fd`, `external_fence_fd` or `external_semaphore_fd`.
  - 1.4.2 has `VK_EXT_metal_objects`, `VK_EXT_external_memory_metal`, timeline semaphores and portability_subset (all subset features true except pointPolygons, samplerMipLodBias and tessellation isolines/point mode).
- Metal can't back depth/stencil textures with an IOSurface. It is an assertion: "IOSurface texture: cannot create ... depth ... textures". Array images abort too (spike).
- The SDK in /usr/local ships MoltenVK 1.2.11. Pin `VK_DRIVER_FILES` and never set `DYLD_LIBRARY_PATH=/usr/local/lib`.
- Remaining validation messages are upstream null-compositor issues (harmless):
  - `VK_GOOGLE_display_timing` without `VK_KHR_swapchain`.
  - `VK_KHR_get_surface_capabilities2` without `VK_KHR_surface`.

Service behaviour:
- `monado-service` listens on `$DARWIN_USER_TEMP_DIR/monado_comp_ipc`.
- hello_xr connects and gets through instance, system and session.
- (fixed in step 3) `xrCreateSwapchain` used to fail with "Can not send IOSurface Mach ports yet".
- The service exits cleanly when stdin closes, and unlinks the socket.
- For step 4: WiVRn's socket is `wivrn/comp_ipc`, so the `wivrn/` subdir must exist under that temp dir.

## Step 3 notes (2026-10-24)
Run: `scripts/run-oop.sh 10 -g Vulkan2` (details, env vars and the side-channel protocol in [docs/build.md](docs/build.md)).

Our Monado patches:
- 0012 **macos-mach-ipc-iosurface-mtlsharedevent**:
  - D1 amendment: `vk_image_allocator` creates the IOSurface itself and imports it with `VkImportMetalIOSurfaceInfoEXT`.
    - `IOSurfaceCreate` sets a real pixel format and bytes per row (64-byte aligned, then `IOSurfaceAlignProperty`).
    - The swapchain keeps the `IOSurfaceRef`; `vk_ic_get_handles` uses `IOSurfaceCreateMachPort`.
    - Formats: RGBA8/BGRA8 (+sRGB) 'RGBA'/'BGRA', RGBA16F 'RGhA', RGBA16 'l64r', A2B10G10R10 'l10r', R32F 'L00f', R5G6B5 'L565'.
    - Not offered: 3-channel formats, depth/stencil. Refused at create: array/cube/mipmapped.
  - D3: `xrt_graphics_sync_handle_t` is a `mach_port_t` on OSX (`XRT_GRAPHICS_SYNC_HANDLE_IS_MACH_PORT`).
    - The service's `comp_semaphore` creates a timeline semaphore with `VkExportMetalObjectCreateInfoEXT(SHARED_EVENT)`, then `-[MTLSharedEventHandle eventPort]` (SPI).
    - The client imports it with `newSharedEventWithMachPort:` (SPI) + `VkImportMetalSharedEventInfoEXT`, with `initialValue` = current `signaledValue`.
    - Import consumes the port, like an fd import.
    - `vk_metal_shared_event_supported()` checks `respondsToSelector` and `MONADO_MACOS_SYNC`.
    - If the client can't get a semaphore from the service, it falls back to a CPU wait instead of failing.
    - The client compositor waits for queue idle before destroying swapchains/semaphore (validation found in-flight destroys once there was no CPU wait).
  - D2: `ipc/shared/ipc_mach_apple.c`: bootstrap service + HELLO/nonce pairing.
    - `ipc_send/receive_handles_graphics_{buffer,sync}` send one OOL-ports Mach message, then the socket message.
    - Shared memory stays SCM_RIGHTS.
- 0013 **null-compositor-frame-dump-and-sync-stats** (test tooling):
  - `XRT_COMPOSITOR_NULL_DUMP(_FRAME)`: PNG straight from the swapchain IOSurfaces.
  - `MONADO_SYNC_STATS=1` latency lines.
  - Null compositor logs its commit count at exit.

Decisions:
- The pairing nonce goes on the socket as a 16-byte preamble (`'MVRM'`, version 1, nonce) before the first IPC call. This changes the wire protocol on macOS only; both ends come from our tree.
- Pending HELLOs expire after 10 s instead of using dead-name notifications. Paired clients are detected by socket close. Both channel ports are released in `ipc_message_channel_close`.
- Sync direction is the Monado default: the service creates the event, the client imports it. This is the reverse of the spike's direction; both work.
- The `MTLDevice` for the SPI import is `MTLCreateSystemDefaultDevice()`. Exporting MoltenVK's device trips VUID-VkExportMetalObjectsInfoEXT-pNext-06791, because the app owns the VkInstance.
- `-g Vulkan` (XR_KHR_vulkan_enable v1) uses the CPU-wait path. hello_xr's own device doesn't enable timelineSemaphore. That is expected and works.

Test results (M4 Max, macOS 27, MoltenVK 1.4.2 for the service):

| Client | -g Vulkan2 | -g Vulkan |
|---|---|---|
| arm64 (MVK 1.4.2) | renders, timeline-semaphore sync | renders, CPU wait |
| x86_64 Rosetta (SDK MVK 1.2.11, `scripts/build.sh x86_64`) | renders, timeline-semaphore sync | renders, CPU wait |

- Evidence: `build/logs/oop-frame-arm64-vulkan2.png`, `oop-frame-vulkan1.png`, `oop-frame-x86_64.png`.
  - Slate-grey clear, the blue/red/green hello_xr cubes in both eyes with a small parallax shift.
  - Some frames also show hello_xr's moving red slab.
- Validation (client and service): client clean. The service has only the 3 known upstream null-compositor messages (display_timing/surface_caps2).
- 30 s soak, then 2 reconnects, then a kill -9 of a client followed by a reconnect:
  - No errors or stalls. Service RSS 20 → 21 MB.
  - The service's Mach port-name count stays at 80–85 after each disconnect.
- In-process mode still works (it uses the same IOSurface allocation and shared-event semaphores in one process).

## Step 4/5 notes (2026-10-24, WiVRn)
Build/run in [docs/wivrn.md](docs/wivrn.md): `scripts/build-wivrn.sh --snapshot && scripts/run-wivrn.sh`.

Decisions:
- Monado for WiVRn comes from `build/monado-snapshot`, the staged `third_party/monado` index, so Monado work in progress doesn't leak into the build. Refresh it with `--snapshot`. Last refresh: with Monado patches 0012/0013.
- No fork for the session: the child aborts in `objc_initializeAfterForkError`. The Monado server runs on a thread, and the process re-execs itself after each session.
- MoltenVK has no multi-planar arrays, so the encode image is split into luma (R8/R16) and chroma (RG8/RG16) 3-layer images. The foveation shader is unchanged.
- Sleep is inhibited by a `caffeinate -i -w <pid>` child, not an in-process IOPMAssertion. This keeps CoreFoundation out of the main process.
- Pairing without UI: `--pairing` prints a PIN, and `adb shell am start -d "wivrn://:PIN@<mac-ip>:9757" -n org.meumeu.wivrn/.MainActivity`. The Quest is now paired (key in `~/.config/wivrn`).
- Darwin returns `AF_INET` peer addresses on dual-stack UDP sockets. They are mapped back to v4-mapped addresses; without this, the stream handshake was ignored.
- New test helper `tests/wivrn/xr_empty_frames.c`: a session with no layers. Combine it with `WIVRN_DEBUG_TEST_PATTERN=1` to stream a colour field.

Evidence:
- `dns-sd -L`: `<computer name>._wivrn._tcp` port 9757, TXT `protocol=fc26e619b7ab80f8 version=26.9 cookie=…`. The 26.9 client accepted the protocol.
- Test pattern seen on the Quest: build/logs/quest-screencap.png and quest-screenrecord.mp4 (the colour changes over time).
- hello_xr (Vulkan2, out-of-process, 2198×2302 swapchains) in the headset: build/logs/quest-hello-xr.png.
- `WIVRN_DUMP_VIDEO` stream: ffprobe reports `hevc Main 10 1152x1152 yuv420p10le pc/bt709`, 986 frames, 0 decode errors.

## Step 7 notes (2026-10-24, stability + performance)
Details in [docs/wivrn.md](docs/wivrn.md) ("Step 7 findings") and [docs/encoder.md](docs/encoder.md) (stall root cause,
IDR table). Sessions: `WIVRN_VT_LOG_TIMING=1 MONITOR=1 scripts/wivrn-session.sh <tag> <secs>`, then
`scripts/wivrn-session-summary.py build/logs/s7/<tag>.server.log`. Logs are in build/logs/s7.

- **Startup stall: root cause.** libmvt's prewarm frame had a `CLOCK_UPTIME_RAW` PTS. WiVRn's frames have Monado's
  `CLOCK_MONOTONIC` PTS, which on Darwin includes sleep: 2.7 days later here.
  - VT's CBR then generated filler for the whole gap: tens of GB, in the VT service (5.5 GB footprint, 13.6 GB peak).
  - Encodes took 30-700 ms for about 22 s.
  - The slow encodes made the compositor skip frame ids. The client reports skipped ids as lost, so each one
    triggered an IDR.
  - Ruled out:
    - VT hardware contention, power state, thermal: a parallel standalone encoder stayed at 2.4-3.4 ms during the stall.
    - Irregular frame gaps: up to 0.6 s gaps are harmless.
    - Encoder thread QoS: the threads were blocked waiting on the VT service.
- **Fixes:**
  - libmvt keeps its own VT PTS timeline: the caller's spacing, clamped to [1 ns, 4 frame intervals].
  - WiVRn patch 0004 marks skipped frame ids non-reference, so they no longer force IDRs. It also fixes the 2-element
    `non_ref_frames` vector from a brace-init in upstream `idr_handler.h`.
  - Result: 3/3 fresh sessions reach 90 fps within 0.3 s, with 1 IDR (start) and 0 IDR requests. Baseline: ~22 s at
    5-44 fps, ~30 IDRs, 108 encodes > 11 ms.
- **IDR size.** Per frame, only a temporary `ConstantBitRate` drop works. `idr_rate_scale` 0.5 gives 26× → 12.7× of
  the budget, at 42-46 dB (vs 53) for more than 0.5 s.
  - Changing `MinAllowedFrameQP` after creation is ignored.
  - `BaseFrameQP` disables rate control for the whole session.
  - LTR needs low-latency RC and still produced a keyframe.
  - Shipped off by default (`WIVRN_VT_IDR_RATE_SCALE`), because mid-stream IDRs are now rare (the 5-min soak had none).
- **GPU sync.** Already active in WiVRn: `comp_base` → `comp_semaphore` → MTLSharedEvent (patch 0012). hello_xr
  commits with a timeline semaphore (0.035-0.044 ms median); server commit to GPU done is 0.011-0.013 ms.
- **Latency.** The 80 ms prediction was the stall: the pacer uses the p99.5 of present>decoded over 5000 frames.
  Now the HEAD prediction is ~38 ms median, and present>decoded is 13-15 ms p50 (breakdown in Measurements).
  - `CLOCK_MONOTONIC` on Darwin has 1 µs resolution and follows NTP. Monado/WiVRn are consistent with each other,
    so it was not changed (follow-up below).

## Zero-copy notes (2026-10-24)
Details, design and the table in [docs/wivrn.md](docs/wivrn.md) ("Zero-copy encode").
- Each stream (left, right, alpha) of each compositor image is an IOSurface-backed `420f`/`xf20` CVPixelBuffer; its
  planes are Metal textures imported as R8/R16 + RG8/RG16 Vulkan images. `foveation.comp` gets per-stream image
  arrays on Apple (`WIVRN_ENCODE_IMAGE_PER_STREAM`), one dispatch as before.
- The VT encoder thread CPU-waits on the compositor's timeline semaphore value, then `mvt_encode_pixel_buffer_sync`.
- `WIVRN_VT_READBACK=1` = old path, `WIVRN_VT_VERIFY=1` = compare every frame with a readback.
- Test app: `build/tests/xr_empty_frames <s> --pattern [px/frame]` (panning or static high-detail pattern, 18.5 Mbit/s per
  eye when panning). `scripts/wivrn-session.sh` takes `HELLO_XR=`/`APP_ARGS=`; `tests/wivrn/compare_streams.py` compares dumps.
- Evidence: verify 0 differing frames (2351 pattern, 1518 hello_xr per stream); static-pattern decoded PSNR
  zero-copy vs readback Y 49.03 dB = readback vs readback 49.05 dB.

## Measurements
- **Where the Mac loses M2P vs Linux (2026-10-28, [docs/linux-comparison.md](docs/linux-comparison.md#where-the-mac-loses-time-2026-10-28)):**
  identical per-query trace on both (`patches/diag/wivrn-m2p-trace*.patch`, not installed; Linux build in the flatpak
  devel sandbox). The overlay value is the server's 1-s max of (pose time asked − headset production time), i.e. pose
  age + the app's horizon (app CPU + GPU + compositor term ≈ safe + render>display + app margin). Stock estimator:
  Mac 86.0 vs Linux 63.3 (+22.7): safe +7.5 (Quest HEVC decode tail vs AV1: p95 12.7 vs 6.7 ms; both-eye
  present>decoded p99.5 28.9 vs 20.3, medians equal), stale-pose spikes in the 1-s max +7.1 (19 of 30 windows in one
  run, 2 in another), app margin +2.5 (0007), app CPU +2.6 (Alyx D3D11 under Wine before the 2nd Submit; p95 11 ms puts
  40 % of frames in the pacer's no-wait branch), pose age +1.0. Low-latency estimator: Mac 72.6-74 vs Linux 65.3
  (gap 7-9 ms). Margin 1.5 A/B: no gain (75.8 vs 72.6). On AC power, screen sharing off.
  - [ ] Stale poses: they also hit Linux during packet loss (lin-hevc1: 20 of 30 windows), so most likely uplink
    stalls; log tracking-packet arrival next to the trace to confirm before touching `history.h`.
  - [x] Decode tail cause (2026-10-28): Linux NVENC HEVC shows the same Quest decode tail as the Mac (clean part: p95
    11.7-13.5, worst 2 % 15.5, 2nd eye +4.6 ms; Mac 11.7, 16.5, +4.1); frame-size shapes match. It is HEVC decode on
    the Quest, not VT's bitstream; VT rate-control tweaks are not indicated. AV1: p95 8.2, worst 11.0, +3.3.
  - [ ] Decode tail: A/B a lower client bitrate against the Quest's HEVC decode p95 (fewer bits is the server-side lever).
    Candidate: `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` in encoder/src/mvt.c (env opt-in, fall back if
    session creation fails), possibly AverageBitRate + DataRateLimits instead of ConstantBitRate. First check with a traced
    Linux HEVC run whether the tail is HEVC decode itself or our bitstream.
  - ~~Client that shows the newest decoded frame~~ dropped: the Quest client stays stock (decision 2026-10-28).
- [ ] **Alyx 26227071 + macOS 27.2: 1-2 fps under NotProton/DXMT (2026-10-28)**, VR and `-novr`, GPU idle, one core busy;
  not WiVRn/bridge/OpenComposite/controllers/shader cache/AVX. Mac rolled back to 25487405 (depot 546563 only, manifest
  1898649366808652836): 61 files, backed up outside the game dir
  (`files.txt`); undo = copy back or Steam "Verify". Steam still says 26227071, so a verify or the next update brings
  the slow build back. Linux 26227071 is fine. Find what in the new Windows build stalls under Wine/Rosetta.
- Rule (2026-10-26): macOS screen sharing shares the VT encoder, GPU and network. Before any timing or performance
  number, check `pgrep -x screensharingd` and label numbers "screen sharing on" if it is active. The 2026-10-25 latency
  and pacing numbers (0009 table, 85 vs 88 ms) were taken with it off.
- **Motion-to-photon latency (2026-10-25, WiVRn 0009):** Alyx s6/steamvr_quit, 90 Hz, fidelity 3 pinned, bridge stats
  on, Mac on Ethernet (underpowered adapter, battery draining), Quest on 5 GHz Wi-Fi, ~71 Mbit/s per eye. Same binary,
  estimator via env, interleaved; each run = server restart + Alyx reload + 20 s settle + 30 s
  (`tools/mql-ab/latrun.sh`, `latstats.py`; raw `build/lat/*`). Log columns are p50/p95 ms of stream 0; "both eyes"
  is the per-frame max of the two eyes from the diag dump; late / repeats per 30 s.

  | Run | estimator | safe | present>decoded | both eyes p50/p99.5 | decoded>blit | blit>display | shown late | repeats (stream 0) | game fps / 1 % low | client Stale |
  |---|---|---|---|---|---|---|---|---|---|---|
  | stock1 | p99.5/5000 +1 | 34.3 | 15.5/22.7 | 17.6/27.5 | 19.3/25.1 | 16.2/17.1 | 0 | 4 | 85.4 / 54.1 | 2 |
  | stock2 | p99.5/5000 +1 | 35.9 | 14.8/21.5 | 16.9/27.4 | 21.3/26.1 | 16.2/16.9 | 1 | 5 | 87.2 / 50.2 | 5 |
  | new1 | p99/500 +2.5 | 30.3 | 15.4/22.2 | 18.0/27.3 | 16.1/21.3 | 16.5/17.5 | 6 | 12 | 87.4 / 53.8 | 12 |
  | new2 | p99/500 +2.5 | 30.6 | 15.0/21.6 | 17.5/27.3 | 17.4/24.9 | 16.4/18.5 | 11 | 21 | 86.6 / 55.5 | 19 |
  | final (build/wivrn-next) | p99/500 +2.5 | 27.7 | 15.0/21.2 | - | 13.8/21.0 | 16.1/17.0 | 2 | 11 | 88.5 / 46.1 | 12 |

  - Before the work (old binary, task brief): safe 37-40, decoded>blit 21.8/27.2, overlay "estimated motion to photon"
    91 ms (`build/lat/base-quest.png`). The overlay was closed after the first client restart (it toggles with both
    thumbsticks), so there is no overlay reading after; it moves 1:1 with safe, so ≈ 83-86 ms is expected with the
    opt-in settings.
  - The stock runs were all within 55 s of an Alyx load, so stock's safe still held load spikes. In long steady play
    stock settles to ~29 ms (base1 recording, 300-420 s), close to the opt-in value.
  - Replay of 6 recordings (~30 min of feedback, `safesim.py`): a 10-s oracle saves ≤ 2.7 ms at the same miss rate;
    p99/500 +2.5 has fewer misses than stock in all 6 and a 0.3-4 ms lower safe in 5 (the gain comes after bursts).
  - Network 4.9 vs the earlier 2.1 ms: the earlier figure was the loading screen at low bitrate. Now ~71 Mbit/s per
    eye (client setting 200 Mbit/s total), and it swings with the Wi-Fi (same session: 4.5 → 15 ms at constant bitrate).
  - pre0007 / cand1 runs (`build/lat/`) are invalid: the Mac was power-limited at 6 % battery (Alyx 18 fps, GPU idle).
- 2026-10-25, headset check: Alyx (DXMT bridge + pacing fix 0007/0015, 90 Hz) "looks good".
- **Alyx A/B after pacing fix (2026-10-25, [docs/ab-alyx.md](docs/ab-alyx.md#ab-after-pacing-fix-2026-10-25)):** Metal HUD log for both, 30 s after 20 s settle + gpustress. 72 Hz: A 67.3/69.7 fps (lowest 1-s 57.8/66.1), B 72.0/72.0 (71.1/70.1); HUD GPU 8.55-8.69 vs 8.45-8.49 ms, P15 52-94 vs 87-88 %. 90 Hz: A 45.0/39.6 (half rate, GPU 8.3-8.7 ms), B 89.4/89.8. Runtime CPU A 72-78 % vs B 44-48 %; hlvr 294-304 vs 340-359 %. Quest had lost positional tracking (Guardian paused for A), so the head pose differed.
- **Alyx A/B vs the SteamVR/Steam Link reference stack (2026-10-24, [docs/ab-alyx.md](docs/ab-alyx.md)):** balcony save, 72 Hz, ~4.56 MP/eye base, fidelity 3, 30 s each: game 69.6 (A) vs 66.5 fps (B); HUD GPU 8.45 vs 13.95 ms; hlvr 303 vs 310 %, wineserver 47 vs 35 %, runtime 71 vs 47 % CPU; encode 7.6 ms vs 2.8/3.3 ms p50/p95; 52 vs 2×72 Mbit/s.
- **Alyx GPU bottleneck (2026-10-25, [docs/ab-alyx.md](docs/ab-alyx.md#gpu-bottleneck-2026-10-25)):** B's 13.95 ms HUD GPU time came from the GPU running at P1/P2 (338-618 MHz). At P15 the same work takes 8.2-8.7 ms (A: 8.45). Bridge copy 0.44 ms and WiVRn 0.15 ms per frame; the GPU is busy with the game. Keyed-mutex mode gives 69 fps at P2/P3 and 56-62 at P15. CPU-wait sync gives 72 at P15 but collapses to 37 at P1. Kept: OpenComposite 0006 (bounded copy, real refresh rate), bridge deferred imageRect copy, `C:\macvr\wineopenxr.env`, `WINEOPENXR_LOG`.
  - [ ] Bridge release spikes: copy submit + host xrReleaseSwapchainImage 1.5-2.6 ms on average, max 11-16 ms, on the game's render thread (move the host release off the game thread?).
  - [ ] msync "node memory pool exhausted" flood (~3.9 MB/s into notproton-run.log, +60 % hlvr / +80 % wineserver CPU vs WINEMSYNC=0). Not fps-limiting in the tests; report to NotProton.
  - [ ] GPU DVFS bistability: measure A's P-states (`build/ab/gpufreq`) to see whether A runs at low clocks too.
- **Zero-copy vs readback (2026-10-24):** 2-min sessions, same settings, p50/p95 ms per stream:

  | Session | encode call | GPU/fence wait | submit>encode | server CPU | server RSS |
  |---|---|---|---|---|---|
  | hello_xr readback | 2.95 / 3.34 | 0.62 / 4.12 | 0.11 / 0.21 | 16.6 % | 83 MB |
  | hello_xr zero-copy | 2.65 / 2.96 | 0.63 / 4.16 | 0.04 / 0.09 | 11.7 % | 67 MB |
  | pattern (18.5 Mbit/s) readback | 2.92 / 3.36 | 0.77 / 3.80 | 0.11 / 0.22 | 16.5 % | 85 MB |
  | pattern zero-copy | 2.64 / 2.95 | 0.82 / 4.09 | 0.05 / 0.10 | 13.9 % | 69 MB |

  Foveation GPU ~0.35-0.4 ms p50 in both modes. Client present>decoded p50: 13.1 → 12.8 (hello_xr), 16.8 → 15.8 (pattern).
- **Step 7 soak (2026-10-24):** 5 min, hello_xr (Vulkan2) in the Quest 3S. 2×1152×1152 HEVC Main10, 24.6 Mbit/s per
  eye, 90 Hz, `caffeinate -i`. Log build/logs/s7/soak2.*.
  - Both streams: 26,989 frames in 300.0 s = **89.98 fps**. 2 frame ids skipped by the compositor/app, 4 "not sent"
    on the client (same ids, both streams), 0 network losses.
  - Encode (copy + VT): p50 2.97 / p95 3.38 / p99 3.60 / max 14.5 ms; 3 frames over 11 ms.
  - IDRs: 1 (session start), 0 IDR requests.
  - Bitrate: 0.2 Mbit/s, because hello_xr's scene is nearly static. Not representative of games.
  - Server: 15% of one core on average (~14-23%), RSS 86 MB, flat.
  - VTEncoderXPCService: 5.5% CPU, RSS 32 MB. During the old stall it had a 5.5 GB footprint.
  - hello_xr: 9% CPU.
  - Same soak before patch 0004 (with the libmvt fix): 89.91 fps, 11 skipped ids → 7 IDRs, 6 IDR requests.
- **Latency** (p50/p95 ms, stream 0, from the client feedback, steady state; [docs/wivrn.md](docs/wivrn.md)):

  | present>encode | encode | network | decode | decoded>blit | blit>display | present>decoded |
  |---|---|---|---|---|---|---|
  | 2.9/4.9 | 3.7/4.5 | 3.3/4.3 | 3.3/3.8 | 6-11/9-13 | 16-17/17-21 | 13-15/16-20 |

  - Pacer safe present>decoded: 19-25 ms. Tracking latency: 2-4 ms.
  - Client HEAD prediction: ~38 ms median (34-44 ms pattern). Before the fix: 48-51 ms median, 80 ms cap.
- **GPU sync in WiVRn** (`MONADO_SYNC_STATS=1`, hello_xr at 90 fps):
  - Client commit with a timeline semaphore: median 0.035-0.044 ms, p99 0.11-0.28 ms.
  - Server commit to client GPU done: 0.011-0.013 ms, p99 0.03-0.10 ms.
- **IDR cap:** table in [docs/encoder.md](docs/encoder.md) ("Forced IDR size").
- M2 bridge (Rosetta client, CrossOver DXVK, 320×240 views, null compositor; p50/p99), details in docs/bridge-plan.md §0:
  - Generated thunk, loader → PE → unix → Monado: 0.2 µs.
  - `xrEndFrame` incl. DXVK flush + submission lock, no layers: 0.04–0.07 / 0.1 ms.
  - Client commit (sync-stats): D3D11 0.05–0.09 ms, Vulkan2 0.05–0.08 ms. Service commit → client GPU done: D3D11
    0.42–0.55 ms, Vulkan 0.08–0.13 ms.
  - Array split: release with 2 slice copies 0.18–0.28 / 0.63 ms; `xrEndFrame` with layer rewrite 0.10–0.15 ms.
  - XrTime ⇄ QPC: round trip exact over 100 000 values; calibration within ±50 ns.
- WiVRn + VT, Quest 3S client defaults (stream 2×1152×1152 HEVC Main10, 24.6 Mbit/s per eye, 90 Hz), 10-s server summaries:
  - Steady state with hello_xr: 89-90 fps per stream. VT encode call (copy + encode) p50 2.9 ms, p95 3.3 ms, max ≤ 14 ms.
  - Readback fence wait: 1.5-5.8 ms. It includes the compositor/foveation GPU work, because the encoder waits right after commit.
  - Client-side numbers: at that point the tracking pattern asked for the 80 ms cap. Explained and fixed in step 7 (startup stall); the client's feedback is now logged by the server.
- Step 3 out-of-process (`MONADO_SYNC_STATS`, 320×240 views, medians/p99; hello_xr ~20 fps paced by the null compositor):
  - arm64 timeline semaphore:
    - Client commit: 0.04–0.065 / 0.13–0.35 ms.
    - Service commit → client GPU done: 0.017–0.029 / 0.04–0.17 ms.
  - arm64 CPU wait: client commit 0.12–0.18 / 0.3–0.5 ms.
  - x86_64 Rosetta timeline semaphore: client commit 0.08 / 0.24 ms; service commit → GPU done 0.023 / 0.04 ms.
  - Commit means the client's `xrEndFrame` path from submit to IPC reply. For hello_xr's tiny scene the GPU work is done before the IPC message arrives.
- libmvt VT HEVC (M4 Max, 90 fps pacing, details in docs/encoder.md):
  - 2×1280×1344 Main10 (WiVRn Quest 3 default): 2.7 / 2.85 ms p50/p95, ~49-50 dB PSNR.
  - 2×1832×1920 at 50 Mbit/s each: 4.6 / 4.8 ms with the encoders in parallel, 10-13 ms one after the other.
  - Above ~5.3 MP per frame VT drops to a slow path (~45 fps).

- IOSurface spike: cross-process Mach round trip 4-7 µs; per-frame message 7-17 µs. Client blocks 0.6-0.8 ms per frame with CPU-wait sync vs 0.04-0.12 ms with MTLSharedEvent GPU wait.

- Windows comparison (2026-10-26, PC: the RTX 5070 Ti test PC, wired; same Quest 3S on 5 GHz Wi-Fi, same Alyx save s6/steamvr_quit, 90 Hz, fidelity 3, ~3.1k x 3.2k per eye):
  | | Air Link | Steam Link | WiVRn on Mac |
  |---|---|---|---|
  | end-to-end motion→photon p50 | 91.2 ms (Meta sensor_to_illumination; p95 94.5) | no number (SteamVR predicts 3–4 extra frames, Air Link 2) | 85–88 ms (WiVRn overlay estimate) |
  | encode / decode p50 | 2.9 / 5.0 ms | n/a | 3.2 / 7.6 ms |
  | bitrate | dynamic ~71 Mbit/s (max 90) | auto ~55 Mbit/s; fixed 200 never came up | ~150–200 Mbit/s |
  | fps / drops | 90 / 0 | 90 / 0 | 90 / ~0 |
  Different estimators, so read as "on par". Next: WiVRn 26.9 on the same PC under Linux for a like-for-like number.

## Known issues / follow-ups
- [x] Alyx Options → Performance page draws nothing (2026-10-29): mixed install from the 25487405 rollback, not
  OpenComposite/bridge. Content (depot 546561) is 26227071 and its `child02` layout uses
  `GameMenuOptionRenderingFoveatedTogglePanel`, which the rolled-back 25487405 `client.dll` doesn't have (the 26227071 one
  does); console.log: `Parsing error on panorama\layout\game_menus\child02.xml(244): ... unknown panel type`. The
  other `child02` pages (Preferences, Interface, Accessibility, Subtitles, Audio, Spectator) may be broken too; check in
  the headset. Fix options (game files): back to 26227071 binaries (from the backup
  or Steam Verify; fine on FEX, 1-2 fps on Rosetta), or also roll back 546561 to its 25487405 manifest (not in
  depotcache, id needed). No OpenComposite change. Details: docs/m3-opencomposite.md "Not done / open".
  Fixed 2026-10-29 (rolled back): content also at 25487405. Manifest 546561 = 1436897171613240821 (from a
  second Alyx install's 25487405 appmanifest, read only); instead of downloading 72 GB, the 10 differing paks
  (pak01_112/167/170/173/174/186/457, pak01_dir, shaders_vulkan_006/_dir) were cloned from that install. Ours
  backed up (`files.txt`). Launch check: 0 Panorama parse errors
  (13 before). Steam still records 26227071, so Verify/update brings it back. Headset check of the page pending.
- Server stuck after a network change (2026-10-24): when the Mac moved from Wi-Fi to Ethernet, the old session's UDP socket stayed bound to the Wi-Fi address and TCP 9757 stopped listening, so the client couldn't reconnect until the server was restarted. Fix: detect the dead client, end the session and listen again. 2026-10-29: Ethernet → Wi-Fi with no game running: the server kept listening on *:9757 and the Quest reconnected to the new address (sent via adb; the client doesn't follow by itself), so the hang may need an active session.
- Ethernet vs Wi-Fi (Mac side, Alyx loading screen, p50/p95 ms): network 2.1/3.3 vs 5.5/17.3; present>decoded 12.6/14.8 vs 14.1/28.8.
- (fixed by OpenComposite 0007, not deployed yet; 2026-10-25) A WiVRn server restart under a running Alyx makes OpenComposite show a modal "OpenComposite Error"
  (XR_ERROR_INSTANCE_LOST from xrLocateHandJointsEXT in GetSkeletalBoneData, BaseInput.cpp:2098) and hlvr hangs
  instead of exiting. Quit Alyx before restarting the server (`tools/mql-ab/latrun.sh` does).
- (2026-10-25) After a server restart the stock Quest client does not reconnect on its own (5/5 restarts, 60 s each):
  it sends `_wivrn._tcp` PTR queries every 5 s but never connects. `adb shell am start -d wivrn://<mac>:9757 ...` brings
  it back in ~1 s (wivrn-restart.sh, latrun.sh). Not investigated (client autoconnect setting or mDNS replies).
- (2026-10-25) On an underpowered adapter the Mac drains under Alyx (the M4 Max draws more): at 6 % battery macOS power-limits
  and Alyx drops to ~18 fps with the GPU idle. Measurements need a full-power charger.
- (done 2026-10-25, see Status "Audio") Audio: game audio played on the Mac, not the Quest.
- 2026-10-24: Rosetta hangs every newly built x86_64 Mach-O binary (state U, can't be killed). Binaries translated before the hang, including Wine, still run. Also stuck in state U: Time Machine `backupd` and `diskimagesiod`. The cause is likely a stuck Time Machine or disk-image I/O operation, not Rosetta itself. Fix: reboot. Until then: no new x86_64 builds (bridge .so, x86_64 Monado client for WiVRn).
- (2026-10-26: freshly built x86_64 binaries run fine again; the WiVRn x86_64 client loaded in 9 ms.)
- Rosetta stalled freshly built x86_64 executables for ~40 min on 2026-10-24 (state `U`); it cleared on its own. If `make` in spikes/bridge or a test hangs at launch, that's the cause.
- Bridge: Monado's suggested-GPU check fails across MoltenVK versions (1.2.10 vs 1.4.2 device UUIDs) and falls back
  to GPU 0. Fine on Apple Silicon; would need a LUID/registry-ID match on multi-GPU Macs.
- Bridge: no `XR_EXT_debug_utils` (needs a PE-side messenger that trampolines callbacks), no 32-bit, one instance,
  mipmapped/cube D3D11 swapchains refused, Vulkan apps get no array/depth fallback (Monado still refuses those).
- Bridge: depth submitted via `XR_KHR_composition_layer_depth` is dropped. Revisit with the Monado
  `MTLSharedTextureHandle` kind if WiVRn ever uses depth.
- Null compositor pacing burst: sometimes the multi-compositor loop commits thousands of frames within about 1 ms (1.7k–10k commits per 10 s run instead of ~200), then pauses.
  - Seen with both sync modes, harmless for hello_xr.
  - Suspected cause: fake pacer + WiVRn 0001's early wake. The loop spins while the wake time is "fuzzy in the past" (<1 ms).
  - Check the WiVRn pacer at step 4. Don't use the null compositor's commit count as an fps number.
- Depth/array swapchains are still refused on macOS (IOSurface limits). Next: MTLSharedTextureHandle ports with a kind tag (plan D1 amendment).
- Bootstrap namespace is per login session: run the service and its clients from the same session (not one over ssh and one in the GUI).
- MoltenVK multi-planar IOSurface: export creates the wrong chroma pitch and no pixel format, and import rejects standard 420v surfaces. Worked around for now; a local MoltenVK patch would let VT pool buffers be used directly.
- (done) WiVRn VT encoders run in parallel, and streams are clamped to 5.2 MP.
- (fixed, step 7) Slow warm-up of each WiVRn session: PTS clock mismatch → VT CBR filler (see Step 7 notes).
- (done) Zero-copy encode. Leftovers: VMA still binds unused memory to the imported plane images (~20 MB); ffmpeg can't
  decode VT HEVC dumps past frame 2048 (also with libmvt alone, the Quest decodes fine); x264 on Apple would now need
  per-stream images (see next item).
- WiVRn's x264 encoder on macOS would read plane aspects / array layer `stream_idx` of the per-stream luma image. It needs the
  `cbcr` path (layer 0) before use; x264 is built but not selected.
- No Quest microphone on the Mac, no input forwarding (uinput), no wivrnctl/dashboard on macOS.
- A forced mid-stream IDR is 23-26× the per-frame budget because VT keeps the P-frame QP.
  - Evaluated in step 7: `WIVRN_VT_IDR_RATE_SCALE` (off by default) halves it at a lasting quality cost.
  - VT has no intra refresh.
  - LTR refresh needs low-latency RC. Revisit if games show frequent loss IDRs.
- Monado's `os_monotonic_get_ns` on macOS is `CLOCK_MONOTONIC`. **Recommendation (evaluated 2026-10-24, not
  changed): switch it to `CLOCK_MONOTONIC_RAW` in a Monado patch, together with the two dependents below.**
  - Probe (arm64, M4 Max, macOS 27): `CLOCK_MONOTONIC` has 1 µs resolution and is 8.34 s behind `CLOCK_MONOTONIC_RAW`
    (NTP-adjusted). `CLOCK_MONOTONIC_RAW` has 41 ns steps, equals `mach_continuous_time` exactly (includes sleep), and
    costs 14 ns per call (MONOTONIC: 17 ns). `CLOCK_UPTIME_RAW` = `mach_absolute_time` excludes sleep (231,168 s apart).
  - MoltenVK 1.4.2's calibrateable time domains are only DEVICE and `CLOCK_MONOTONIC_RAW`. Monado's
    `vk_convert_timestamps_to_host_ns` asks for `CLOCK_MONOTONIC` on OSX, which MoltenVK doesn't offer, so GPU→host
    timestamp conversion can't work on macOS today. With the switch, `vk_time.c`'s `CPU_TIME_DOMAIN` must become
    `VK_TIME_DOMAIN_CLOCK_MONOTONIC_RAW_EXT` on OSX, and then it matches exactly.
  - `XR_KHR_convert_timespec_time` is defined on `CLOCK_MONOTONIC` timespecs. `time_state_from/to_timespec` use them
    unchanged, so after the switch they must convert MONOTONIC ⇄ RAW with a fresh paired sample. The bridge
    (`bridge/src/wineopenxr_unix.c`) samples `CLOCK_MONOTONIC` + `mach_continuous_time` around that call. It would keep
    working, and could drop the pairing (XrTime would be `mach_continuous_time` = CrossOver's QPC).
  - Nothing else depends on the clock: Monado patch 0002's wake wait is relative, libmvt keeps its own PTS timeline,
    WiVRn's headset clock offset is re-estimated continuously, and `std::chrono::steady_clock` is only used for local
    periods.
  - Gain: no NTP slew inside the pacer/latency maths (a slew of up to 500 ppm on a 1 µs clock), 25× finer timestamps,
    and working calibrated GPU timestamps. Never mix with `mach_absolute_time` / `CLOCK_UPTIME_RAW`.
- Real-content measurements are still missing: hello_xr streams only 0.2 Mbit/s. Repeat the soak with a game at M3.
  (Alyx 2026-10-24 only reached its black startup screen, also 0.2 Mbit/s.)
- (fixed 2026-10-26, see Status) Alyx: the bridge's x86_64 client had git tag `v25.1.0-macvr-standalone` vs WiVRn's
  `v26.9` and needed `IPC_IGNORE_VERSION=1` + the `monado_comp_ipc` symlink.
- (patch 0008, 2026-10-26; needs an Alyx check in the headset) Alyx: OpenComposite only logged SteamVR's interstitials (`hlvr/interstitials`
  mailbox, "Press Trigger To Start", loading screens), so those screens were black in the headset. 0008 draws them
  as a text quad (docs/m3-opencomposite.md "Interstitials").
- Alyx `-vulkan`: "Failed to initialize Vulkan", MoltenVK 1.2.10 (CrossOver) rejects `VkPhysicalDeviceMultiviewFeatures::
  multiviewGeometryShader` in `vkCreateDevice`. Not ours to patch (winevulkan/MoltenVK).
- OpenComposite's mingw-built test apps (`build/m3/tests`) share OpenComposite's ABI, so they can't catch MSVC ABI bugs;
  real games are MSVC. Before patch 0005 every struct-returning interface method (`GetEyeToHeadTransform`,
  `GetProjectionMatrix`, `Get*ZeroPose*`, `GetMatrix34TrackedDeviceProperty`, `GetCurrentFadeColor`, `GetHiddenAreaMesh`,
  `ComputeDistortion`) corrupted the caller.
- `compositor::encoder_work` starts a `std::async` thread per stream per frame. It's harmless at 90 fps; a pair of
  persistent encoder threads would be cleaner.

## DXMT bridge notes (2026-10-24)
- Why: under DXVK, CrossOver's MoltenVK geometry-shader emulation emits invalid Metal for 4 Alyx pipelines, so the menu
  background is missing. Patching any CrossOver/NotProton part is ruled out; Alyx moved to stock DXMT.
- DXMT in runner 27.0.0.41073 has no version string; `third_party/dxmt` (v0.80-339-ga148782, read-only) matches its
  imports (keyed mutex + D3DKMT shared-resource calls, `WMTBootstrapRegister/LookUp`).
- Mechanism (all in `bridge/`, no Monado/OpenComposite change): the unix side makes its own Vulkan device on CrossOver's
  MoltenVK (loaded from win32u's rpath if DXMT hasn't loaded it) for Monado. App images are DXMT
  `MISC_SHARED_KEYEDMUTEX` textures; gdi32 `D3DKMTQueryResourceInfo`/`OpenResource2`/`OpenKeyedMutex2` give the bootstrap
  names of the MTLSharedTexture and the mutex's MTLSharedEvent; the unix side imports them (`VkImportMetalTextureInfoEXT`,
  `VkImportMetalSharedEventInfoEXT`) and copies into Monado's IOSurface images at release, GPU-synced through the keyed
  mutex (game releases key 1 at V, copy waits V and signals V+1, bridge releases key 0 at V+1).
- Rejected: shared `ID3D11Fence` (DXMT's fence escape fails on CrossOver's D3DKMT, see spike); server-allocated
  MTLSharedTexture + faked `SharedResourceData` (writes DXMT internals, needs a WiVRn rebuild). Zero copy (Monado
  MTLSharedTexture kind + IPC swapchain import) stays a later option.
- Cost (hello_xr, 2 swapchains): release avg 0.38–0.44 ms (sync handoff 0.18, copy submit + host release 0.14,
  D3DKMT release rest); CPU-wait fallback `WINEOPENXR_DXMT_SYNC=cpu` 1.1 ms avg. `WINEOPENXR_STATS=1` prints these.
- Evidence: `bridge-hello_xr-d3d11-dxmt.png`, `bridge-hello_xr-d3d11-dxmt-cpu.png`, DXVK recheck
  `bridge-hello_xr-d3d11-dxvk-recheck.png`; Alyx in the headset `m3-alyx-dxmt-2.png` (menu scene + logo; a WiVRn
  lobby panel was overlaid at that moment), WiVRn 2×90 fps at ~17.5 Mbit/s.
- Open: one `wait_semaphore ... timed out > 100ms` in WiVRn during Alyx loading; the copy costs one extra full-frame GPU
  copy per eye; per-frame game-thread cost ~0.8 ms for Alyx's 2 swapchains (D3DKMT round trips through wineserver).

## M3 Alyx notes (2026-10-24)
Recipe and rollback: [docs/m3-opencomposite.md](docs/m3-opencomposite.md#half-life-alyx-2026-10-24).
- Step 1 (compat): Windows `hello_xr.exe -g D3D11` (scratch prefix) → bridge → existing x86_64 client → WiVRn server → Quest:
  90 fps, encode p50 2.7–2.8 ms (`WIVRN=1 scripts/run-bridge.sh`, screencap `build/logs/m3-alyx-step1-hello_xr-d3d11.png`).
  The client connects through `scripts/wivrn-ipc-link.sh` (`$TMPDIR/monado_comp_ipc` → `wivrn/comp_ipc`; both sides derive
  the Mach name from the realpath) + `IPC_IGNORE_VERSION=1`. No new x86_64 build was needed.
- Alyx D3D11 (startup screen, idle controllers, `caffeinate -i`, server default settings): 2 streams 90.0–90.1 fps,
  0.2 Mbit/s, encode p50 2.6–2.7 / p95 2.8–3.0 ms, gpu wait p50 0.3–1.8 ms; latency p50 present>decoded 10–14 ms;
  game shows 87–90 FPS (NotProton HUD). CPU: wivrn-server 16 %, hlvr.exe 113–118 % (1.6 GB RSS), wineserver 30 %.
  App swapchain 6224×3259 (both eyes in one texture). Headset frames black (`m3-alyx-d3d11-2/3.png`, YMAX 17).
- Alyx `-vulkan`: same 90 fps stream from OpenComposite's session, game stops at the Vulkan error dialog
  (`m3-alyx-vulkan-1.png` black).
- Steam never started SteamVR (250820): no `250820`/`vrstartup` in console_log for any of the 5 launches.

## M2 notes (2026-10-24)
Plan: [docs/bridge-plan.md](docs/bridge-plan.md). Spike: [spikes/bridge/RESULTS.md](spikes/bridge/RESULTS.md).
- D3D11 runs on CrossOver's bundled DXVK `cxaddon-1.10.3-1-25-g737aacd`, selected per game with the launch option
  `CX_GRAPHICS_BACKEND=dxvk %command%`. DXMT stays unpatched (third_party/dxmt is a read-only clone).
- The bridge is a builtin `wineopenxr.dll` + `wineopenxr.so` that thunks to our `libopenxr_monado` IPC client.
  D3D11_enable runs on vulkan_enable through DXVK's `IDXGIVkInteropDevice1`.
- Verified in NotProton's runner (scratch prefix only):
  - Our own builtin + unixlib loads from `WINEDLLPATH`.
  - winevulkan handles unwrap to CrossOver's MoltenVK 1.2.10 objects.
  - IOSurface `VkImage` + MTLSharedEvent timeline semaphore work on DXVK's device without `VK_EXT_metal_objects` enabled.
  - `CreateTexture2DFromVkImage` → D3D11 clear → locked signal on DXVK's queue: 200 frames pixel-exact, GPU done 0.15 ms
    p50 after submit.
- [x] M2 step 1: Monado GIPA-override patch, then load the x86_64 `libopenxr_monado` from the probe against `monado-service`.

## M2 steps 1–5 notes (2026-10-24)
Build/run: `scripts/build-bridge.sh && scripts/run-bridge.sh 10 build/bridge/openxr-sdk-win/src/tests/hello_xr/hello_xr.exe -g D3D11`
(details, all commands and the design decisions in [docs/bridge-plan.md](docs/bridge-plan.md) §0).

Our Monado patch:
- 0014 **oxr-vk-gipa-from-loaded-icd**: `oxr_vk_get_instance_proc_addr()` replaces the linked `vkGetInstanceProcAddr`
  in the state tracker. On Apple: `XRT_VK_GIPA_LIBRARY` (dlopen `RTLD_NOLOAD`), else `RTLD_DEFAULT`, else
  `libvulkan.1.dylib`. Also drops 0012's `vkExportMetalObjectsEXT` check before the MTLSharedEvent import (DXVK's
  device has no `VK_EXT_metal_objects`, the import works without it).

Evidence (build/logs/, all read back): `bridge-step1.png` (probe), `bridge-hello_xr-d3d11.png`,
`bridge-hello_xr-vulkan2.png`, `bridge-hello_xr-vulkan.png` (slate grey, cubes in both eyes), `bridge-array.png`
(2-layer swapchain: orange left, blue right), `bridge-xr_time_test.log`. 0 errors on both sides, timeline-semaphore sync
in every run.

Decisions:
- Our own builds in `build/bridge/` (service, x86_64 client, Windows SDK, bridge), and the service runs with
  `XDG_RUNTIME_DIR=build/bridge/rt`, so nothing collides with the WiVRn work or `build/monado`.
- The bridge-flavour client links with `-dead_strip_dylibs`: no Vulkan loader in the game process.
- Thunks are generated from xr.xml; handles pass through unchanged (both sides 64-bit, same layouts). Hidden:
  `XR_EXT_debug_utils` (host-ABI callback). One XrInstance at a time.
- `OXR_DEBUG_FORCE_TIMELINE_SEMAPHORES=1` always: DXVK enables timelines itself, our `xrCreateVulkanDeviceKHR` adds
  the feature, and MoltenVK accepts timeline semaphores on v1 devices that didn't enable it (hello_xr `-g Vulkan`).
- XrTime ⇄ QPC: one offset sampled at instance creation (tightest of 16 QPC brackets around a host
  `xrConvertTimespecTimeToTimeKHR`). CrossOver's QPC is `mach_continuous_time` (within 25–50 ns) and Monado's XrTime is
  `CLOCK_MONOTONIC`, both count sleep, so the offset can't drift. NotProton's ntdll needs no special handling.
- Step 5: D3D11 array swapchains are split into per-slice host swapchains with a copy at release; depth swapchains are
  bridge-local and their depth infos are dropped. The Monado `MTLSharedTextureHandle` kind is verified on MVK 1.2.10,
  1.2.11 and 1.4.2 (spikes/bridge RESULTS §5) but deferred: it would advertise depth to native clients (hello_xr in the
  WiVRn headset tests) and overlaps the WiVRn work.
- `winebuild --builtin` replaced by `bridge/tools/mark-builtin.py`; hello_xr's D3D11 plugin needs Microsoft
  DirectXMath, cloned read-only as `third_party/directxmath` (`apr2025`).

Needed for M3 (OpenComposite + Half-Life: Alyx):
- A bridge client for WiVRn: an x86_64 `libopenxr` from the WiVRn tree (same patch series, socket `wivrn/comp_ipc`)
  dropped next to `wineopenxr.so` (or `MACVR_OPENXR_RUNTIME`). The null-compositor service is only the test rig.
- (done 2026-10-24, [docs/m3-opencomposite.md](docs/m3-opencomposite.md)) OpenComposite built for Win64 with
  llvm-mingw. The release DLL is not usable: it lacks the OpenVR 2.15.6 interfaces current Alyx asks for
  (`IVRSystem_026`, `IVRCompositor_029`, `IVRInput_011`, `IVROverlay_028`); patch 0004 adds them.
  - Installed via `openvrpaths.vrpath`, or `VR_OVERRIDE`/`VR_CONFIG_PATH`/`VR_LOG_PATH`.
  - Per-eye D3D11 and Vulkan submits render through the bridge.
  - Vulkan games need `initUsingVulkan=true` in `opencomposite.ini`.
- Real-resolution numbers (2×~1830² at 72–90 Hz through WiVRn): the bridge adds flush + lock + one semaphore signal,
  but D3D11 service-commit → GPU-done is already 0.5 ms at 320×240, so measure DXVK's queue depth at Alyx's load.
- A real game prefix install (copy placeholder + json + registry key, `CX_GRAPHICS_BACKEND=dxvk %command%`)
  (step 7). The FEX flavor (step 6): done 2026-10-28.

## XR_KHR_metal_enable notes (2026-10-30, vrclient-native step 1)
- Monado patch 0017-khr-metal-enable: `XRT_HAVE_METAL` (default ON on Apple), a Metal client compositor
  (`compositor/client/comp_metal_client.m`: each native swapchain IOSurface wrapped with
  `newTextureWithDescriptor:iosurface:plane:`, commit signals the IPC timeline semaphore's MTLSharedEvent on the app's
  queue, CPU wait if the service has no shared semaphore), and the oxr side (`xrGetMetalGraphicsRequirementsKHR` returns
  the system default MTLDevice, `XrGraphicsBindingMetalKHR` queue must be on it, `XrSwapchainImageMetalKHR`). Formats
  are MTLPixelFormat values mapped from the native VkFormats: RGBA8/BGRA8 (+sRGB), RGB10A2, RGBA16Unorm/Float. No
  depth, MSAA, arrays or mips (IOSurface limits from 0007/0011/0012). Spec version 3, as in openxr-sdk 1.1.65. No WiVRn
  change needed: the WiVRn server and the x86_64/arm64 clients build with it.
- Test app `tests/metal-xr/xr_metal.m` (built by `scripts/build-wivrn.sh` as `build/tests/xr_metal [s]`): native arm64,
  side-by-side stereo swapchain, per-eye colour cycle + moving bar, one projection layer per frame.
- Verified against the standalone monado-service (null compositor, simulated HMD): 604 frames in 30 s (20 fps = the
  null compositor's rate), 0 errors, server commit->client GPU done (MTLSharedEvent) median 0.8 ms; the frame dump shows
  both eyes' content. `MONADO_MACOS_SYNC=cpu` falls back to the CPU wait, also 0 errors. hello_xr Vulkan unchanged.
- Not verified in the headset yet: the Quest sat on `com.oculus.os.vrlockscreen/.SensorLockActivity` after wake
  ("Launch is blocked because: a Reprojected OS dialog is currently showing"), so the WiVRn client never started, and the
  WiVRn server has no IPC service (Mach bootstrap name) without a connected headset. Retry with the headset unlocked:
  `adb reverse tcp:9757 tcp:9757` then `am start -a android.intent.action.VIEW -d wivrn+tcp://127.0.0.1:9757 -n
  org.meumeu.wivrn/.MainActivity`, then `XR_RUNTIME_JSON=build/wivrn/openxr_wivrn-dev.json build/tests/xr_metal 30`.

## Native macOS OpenComposite + Metal compositor (2026-10-30, vrclient-native step 2)
- `scripts/build-opencomposite.sh --macos` (after `patches.sh apply opencomposite` and `git submodule update --init
  --recursive third_party/opencomposite`): universal `build/oc-macos/vrclient.dylib` + universal
  `libopenxr_loader.dylib` (openxr-sdk 1.1.65, `@loader_path`), copied into `build/oc-macos/runtime/bin/osx64`.
  Links only system frameworks (no Vulkan loader; `-DOC_MACOS_VULKAN=ON` brings Vulkan textures back). The Windows
  DLL build is unchanged.
- Patches: 0009-macos-native-build (CMake APPLE branch, Mach-O resources, `_NSGetExecutablePath`, settings under
  `~/Library/Application Support/OpenVR`, MoltenVK portability in TemporaryVk), 0010-metal-compositor
  (`MetalCompositor` for `TextureType_Metal`, `TemporaryMetal` pre-submit session, `XR_KHR_metal_enable` binding =
  one MTLCommandQueue per device shared by session and compositors, `GetOutputDevice` returns the runtime's MTLDevice).
  Copies are blits (sRGB/linear twins through a `MUTABLE_FORMAT` view, `copyBoundsOnly` sub-rect, array slice = eye);
  a render pass handles shader bounds, MSAA resolve and formats the runtime lacks. Cubemaps not done.
- Test: `tests/openvr-metal/ovr_metal.mm` (dlopen + `VRClientCoreFactory`, scene app, WaitGetPoses/Submit) via
  `scripts/run-ovr-metal.sh [secs] [separate|sbs|array|msaa]` against monado-service (null compositor). Each mode:
  ~595 frames in 30 s (19.8 fps, the null compositor's rate), 0 errors with `MTL_DEBUG_LAYER=1`, frame dumps show
  both eyes.
- Open for the Wine vrclient bridge:
  - OpenComposite copies on its own queue, not the game's (`Texture_t` has no queue). Fine for the native test
    (committed before Submit, tracked textures), but DXMT must have committed the eye's command buffer before the
    bridge calls Submit, and untracked DXMT resources need an explicit MTLSharedEvent wait.
  - The x86_64 slice loads under Rosetta; it needs an x86_64 OpenXR client with 0017 (`build.sh x86_64` / the WiVRn
    x86_64 client). Keep `libopenxr_loader.dylib` next to `vrclient.dylib`.
  - OpenComposite logs to stdout and reads `opencomposite.ini` from the working directory on macOS.

## Wine vrclient bridge, Proton's vrclient on CrossOver (2026-10-30, vrclient-native step 3)
- `vrclient/`: Proton's vrclient_x64 (experimental_11.0, 7a94df4) in `vrclient/proton/` (import commit unmodified, our
  changes under `MACVR`), our code in `vrclient/src/` (MIT; `vrclient/LICENSE`). `scripts/build-bridge.sh vrclient`:
  vrclient_x64.dll (llvm-mingw, mingw headers + Wine's own headers and winecrt0 debug/unixlib from a sparse wine-11.0
  checkout in build/vrclient/wine) and a universal vrclient_x64.so (Wine headers, `-undefined dynamic_lookup` for
  ntdll.so), plus `tests/openvr-d3d11/ovr_d3d11_render.exe`.
- Path: openvr_api.dll -> C:\vrclient\bin\vrclient_x64.dll (builtin) -> vrclient_x64.so -> OpenComposite's
  vrclient.dylib (`MACVR_VRCLIENT_RUNTIME`, `PROTON_VR_RUNTIME`, or the runtime in
  ~/Library/Application Support/OpenVR/.openvr/openvrpaths.vrpath). No steam.exe registry handshake.
- D3D11 (DXMT): each eye is copied into a ring of 3 DXMT keyed-mutex shared textures, the unix side waits for the
  MTLSharedEvent on the CPU, OpenComposite gets the imported id<MTLTexture> as TextureType_Metal. CX 26.3's DXMT has
  no keyed mutexes: event query wait instead. Overlays the same, a ring per handle. DXVK textures keep Proton's
  IDXGIVkInteropSurface path, which the Metal-only OpenComposite can't take (needs `-DOC_MACOS_VULKAN=ON` and
  winevulkan handle unwrapping checked against CrossOver).
- `scripts/setup-vrclient-prefix.sh` (Proton's setup_openvr_paths; drops VR_OVERRIDE), `scripts/run-vrclient.sh`
  (staged outside ~/Documents, monado-service null compositor, `FEX=1` on a runner clone).
- Verified: 30 s, 601 frames at 20 fps (the null compositor's rate), 0 submit errors, both eyes in the frame dump, on
  CX 26.3 Rosetta (query sync), CX 27 Rosetta and CX 27 FEX (keyed mutex). Bridge per eye submit at 1832x1920,
  median/p99: 0.75/1.0 ms (26.3), 0.80/1.2 ms (27 Rosetta), 0.76/1.16 ms (27 FEX); almost all of it is the CPU wait
  for DXMT's GPU work (copy + the frame's rendering), the OpenComposite Submit is ~0.07 ms. Alyx's interfaces
  resolve, its actions.json loads (`ovr_d3d11_test.exe 200 C:\hlvr\cfg\actions.json`), a D3D11 overlay is accepted.
- Left before Alyx on this path:
  - A patched DXMT with native interop would drop the copy: `dxmt_native_interop()` in vrclient/src/dxmt_pe.c is the
    hook (probes a placeholder IID).
  - The x86_64 OpenXR client for WiVRn (Rosetta) and its arm64 one (FEX) next to OpenComposite, and MacVR.app
    adopting setup-vrclient-prefix.sh (runner install of vrclient_x64.dll/.so, macOS openvrpaths.vrpath).
  - Not checked: 32-bit vrclient.dll, Vulkan/D3D12 games, SetSkyboxOverride, IVRApplications launch helpers,
    RegisterSubprocess (stubbed: no ProcessWineUnixPid in CrossOver), overlay content (the null compositor's dump
    only shows the projection layer), the headset.
- GPU sync (step 3b): OpenComposite patch 0011 exports `oc_metal_submit_sync_begin/end` (thread-local, taken by the next
  `CopyToSwapchain`: `encodeWaitForEvent` before its blit, `encodeSignalEvent` after). Keyed mutex mode: the copy
  waits for DXMT's V and signals V + 1, the bridge releases key 0 at V + 1, so the game's next AcquireSync on the slot
  waits for OpenComposite's read (the ring fence). No CPU wait left on CX 27. Query mode (CX 26.3): the query wait
  stays; the blit signals a per-slot event that the slot's next copy waits for. No export, or
  `VRCLIENT_DXMT_GPU_SYNC=0`: the old CPU wait. Per-eye bridge cost median/p99 (ms, 1832x1920, 30 s, before -> after):
  27 Rosetta 1.14/2.5 -> 0.47/1.1, 27 FEX 1.10/2.3 -> 0.41/0.8; with `ovr_d3d11_render.exe 30 stress64` (~4 ms GPU per
  eye) 4.3/6.2 -> 0.48/1.1 and 4.3/5.7 -> 0.42/0.8; 26.3 unchanged (1.0/2.4 plain, 4.3/6.0 stress).
- Alyx on the bridge (2026-10-30, step 4, FEX, CX 27): `scripts/alyx-vrclient.sh on|service|off` (prefix + runner + macOS
  vrpath + `launchctl setenv XR_RUNTIME_JSON`, all backed up and restored; launch options untouched). Reaches the main
  menu in VR, 2 × 4 min stable at 20 fps (null compositor), 0 service errors, frame dumps show the menu in both eyes.
  Bridge per eye at 906x339: total median 0.30 ms, p99 1.6-5 ms (copy and OpenComposite Submit spikes).
  Fixed: vrclient_x64.dll's CodeView path pointed into ~/Documents, so Alyx's crash handler hit a TCC prompt and hung
  (now `/pdbaltpath:%_PDB%`); SetSkyboxOverride with DXMT textures (OpenComposite aborted on the D3D11 texture).
  Open: IVRInputInternal_002 has no Proton wrapper (Alyx gets NULL, the old path gets OpenComposite's); the 26283546
  Steam update had replaced only rendersystemdx11/renderingpipelines on top of the 25487405 rollback (VR_001 vtable
  mismatch: GetOutputDevice landed in an IVRInput wrapper, crash on every path); those two are back at 25487405,
  the 26283546 copies are kept outside the game dir. Not checked: Rosetta (needs a Steam restart), headset, real size.
- IVRInputInternal_002 (step 5): hand-written wrapper (`vrclient/src/inputinternal_pe.c` + `inputinternal_unix.cpp`,
  unix call `macvr_input_internal`, registered under `MACVR` in vrclient_generated.c). Not generatable: the interface
  isn't in any OpenVR SDK header. OpenComposite's definition (`OpenVRHeaders/custom_interfaces/IVRInputInternal_002.h`)
  is 20 placeholder `void UknFuncNNN()` methods that all abort, so the wrapper has 20 slots, each forwarding to the
  same native slot with the first three integer arguments, and logs the first call of each to VRCLIENT_LOG. Verified:
  `ovr_d3d11_render.exe` (now also asks for it) gets a wrapper on CX 27 FEX and CX 26.3 Rosetta; Alyx (FEX, monado-service)
  gets it (`IVRInputInternal_002 -> ... (native ...)`), reaches the main menu, and never calls a method of it.

## MacVR DXMT: zero-copy eye textures (2026-10-30, vrclient-native step 5)
- Version: CX 27.0.0.41073's runner README says "CrossOver Preview 20261015", matching
  ~/Downloads/crossover-sources-20261015.tar. Its `sources/dxmt/src` is identical to upstream 3Shain/dxmt `fb45156`
  (`v0.80-247-gfb45156`, 2026-09-30); only `.gitmodules` (CodeWeavers mirrors), two CI LLVM flags and
  build-arm64ec.txt's `-marm64x` differ. `third_party/dxmt` is pinned there. The FEX runner's x86_64 games load the
  ARM64EC DLLs (`lib/dxmt/aarch64-windows`, checked by mapped image size) and `aarch64-unix/winemetal.so`.
- `patches/dxmt/0001`: `IDXMTInteropSurface` (QI on a 2D texture: id<MTLTexture>, MTLDevice, format, size, usage) and
  `IDXMTInteropDevice` (QI on the device: `FlushRenderingCommands` -> DXMT's queue MTLSharedEvent + the value its
  committed work reaches, `SignalEvent`/`WaitEvent` on any id<MTLSharedEvent> in the immediate context's stream,
  `Lock/ReleaseSubmissionQueue` = the device mutex). C mirror: `vrclient/src/dxmt_interop.h`.
- Bridge (`dxmt_native_interop()`): lock, flush, OpenComposite's copy waits for DXMT's value and signals the bridge's
  own event (`macvr_dxmt_direct_begin`), Submit with the game's own texture, and if the copy took the sync DXMT's next
  work waits for that signal (`macvr_dxmt_direct_end` + `WaitEvent`), unlock. Copy path stays for stock DXMT (QI
  fails), `VRCLIENT_DXMT_DIRECT=0`, no `oc_metal_submit_sync`, MSAA, other slices, non-shader-readable/non-DEFAULT.
- Build/deploy: `scripts/build-dxmt.sh` (llvm-mingw, LLVM 15 and a Wine with ARM64EC import libs: from local.env, else
  fetched/built like DXMT's CI; ntdll.so/winemac.so from the runner). `scripts/make-macvr-dxmt-runner.sh create`
  clones the FEX runner (APFS) to `runners/crossover-27.0.0.41073-fex-macvrdxmt` and replaces lib/dxmt's
  d3d11/dxgi/d3d10core/winemetal(.dll, aarch64-unix .so); `remove` deletes it (only if it has `.macvr-dxmt`).
  nvapi64/nvngx, i386/x86_64 DLLs and x86_64-unix stay stock.
- Steam: `make-macvr-dxmt-runner.sh compat-tool` writes `compatibilitytools.d/notproton-fex-macvrdxmt-41073` (NotProton's
  `run` + toolmanifest unmodified, build `27.0.0.41073-fex-macvrdxmt`, flavor fex) and clones
  `notproton/bridge/wine/27.0.0.41073-fex` to the new build name (its `run` checks for it); NotProton then builds a
  template for the new build on first launch. Not installed yet: Steam has to restart to list it.
  `compat-tool-remove` / `remove` undo it.
- Measured (`run-vrclient.sh 30 ovr_d3d11_render.exe 30 plain|stress64 1832x1920`, FEX, 2 runs x 2 windows of 500
  eye submits, bridge total per eye median/p99 in ms): stock 0.41/0.76-1.19, MacVR 0.27/0.53-1.13; stress64 stock
  0.43-0.44/1.00-1.27, MacVR 0.28-0.29/0.92-1.17. The bridge-side copy drops from ~0.12 ms to ~0.01 ms (the flush);
  what's left is OpenComposite's Submit (~0.26 ms) and its spikes. All runs 600-601 frames, 0 submit/wait errors,
  0 service errors, the one known OpenComposite soft abort (string property 1001); frame dumps show both eyes with
  the bar on the same row. The MacVR runner with `VRCLIENT_DXMT_DIRECT=0` matches stock (0.41-0.42/1.1-1.2); msaa
  falls back to the copy as intended. Stock runner: same numbers as step 3b's medians, files untouched (14 Oct).
- Open: Alyx and the headset not run on it; Rosetta/x86_64 build not done (`build-dxmt.sh x86_64` written, untested);
  the per-eye DXMT `WaitEvent` stalls DXMT's queue for OpenComposite's copy (~GPU copy time, like Proton's shared
  VkQueue) - not measured on GPU; a never-executed OpenComposite copy after `taken` would hang DXMT's queue (same risk
  as the keyed mutex path); the null compositor's "layer commits" count varies 5k-15k between runs on both runners
  (pacing, not frames); DXMT's AGENTS.md forbids AI-generated contributions, so the patch is MacVR-local, not for
  upstream as is.

## Morning A/B: MacVR path vs vrclient path, real WiVRn server (prepared 2026-10-30)
A = MacVR's path (MacVR.app's payload and its own wivrn-server: Windows OpenComposite -> wineopenxr). B = the vrclient
path (vrclient_x64 -> native OpenComposite, Metal -> this tree's WiVRn client with Monado 0017 -> `build/wivrn` server,
started with MacVR.app's pacer env). Both servers come from the same WiVRn/Monado patches; 0017 only adds client code.
A's server uses MacVR's bundled MoltenVK, B's Homebrew's (scripts/env-macos.sh). B logs bridge stats every 500 submits
(VRCLIENT_STATS=1, cheap); A runs without wineopenxr stats. OpenComposite defaults on both (A's ini only has
`initUsingVulkan=false`). Checked tonight: `build/wivrn` server + both clients build (ipc-stamps equal), the server
starts and publishes `_wivrn._tcp` (accepts apps only once a headset connects; stopped again); `on wivrn` / `off`
round trip; `off` (and `check`) verifies MacVR's deployed payload and runner files against its own manifest/records.

One-time setup (worktree root):
```sh
caffeinate -dimsu &                       # whole session
pgrep -l screensharingd                   # must print nothing: no Screen Sharing (it shares the HW encoder/GPU)
tail -3 ~/Library/Application\ Support/Steam/logs/content_log.txt   # no download running
mkdir -p build/ab
clang -O2 -o build/ab/gpufreq tools/mql-ab/gpufreq.c -framework CoreFoundation -lIOReport
clang -O2 -fobjc-arc -o build/ab/gpustress tools/mql-ab/gpustress.m -framework Metal -framework Foundation
clang -O1 -o build/ab/xr_refresh tools/mql-ab/xr_refresh.c -Ithird_party/openxr-sdk/include -Ibuild/openxr-sdk/include \
  -I/usr/local/include -Lbuild/openxr-sdk/src/loader -lopenxr_loader -L/usr/local/lib -lvulkan \
  -Wl,-rpath,$PWD/build/openxr-sdk/src/loader -Wl,-rpath,/usr/local/lib
printf '{"file_format_version":"1.0.0","runtime":{"name":"Monado","library_path":"%s"}}\n' \
  "$HOME/Library/Application Support/macvr/current/server/libopenxr_wivrn.dylib" > build/ab/openxr_macvr.json
launchctl setenv MTL_HUD_LOG_ENABLED 1    # Metal HUD fps in the log (launch options already have MTL_HUD_ENABLED=1)
```

B, vrclient path (FEX first; Alyx's runner as `scripts/alyx-runner.sh` left it):
```sh
# MacVR.app must not run (own server, rescans prefixes)
scripts/alyx-vrclient.sh on wivrn
scripts/alyx-vrclient.sh wivrn            # terminal 2, foreground; PIN printed if the headset isn't paired
adb shell am start -a android.intent.action.VIEW -d "wivrn://<mac address>:9757" -n org.meumeu.wivrn/.MainActivity
XR_RUNTIME_JSON=$PWD/build/wivrn/openxr_wivrn-dev.json build/ab/xr_refresh 72
tools/mql-ab/vrab.sh b72-1                # loads s6/steamvr_quit, fidelity 3, kick, 30-s window, prints abstats
tools/mql-ab/vrab.sh b72-2
python3 tools/vconsole.py quit            # quit Alyx; then Ctrl-C the server in terminal 2
scripts/alyx-vrclient.sh off              # restores the prefix, runner, vrpath, launchd env; checks MacVR's payload
```
First look in the headset before measuring: both eyes, menu and balcony correct (B has never run on the headset).

A, MacVR path (restore is `off` above, nothing else):
```sh
open -a MacVR                             # starts its wivrn-server; reconnect the headset (same adb command)
XR_RUNTIME_JSON=$PWD/build/ab/openxr_macvr.json build/ab/xr_refresh 72
AB_WIVRN_LOG=~/Library/Logs/MacVR/wivrn-server.log tools/mql-ab/vrab.sh a72-1
AB_WIVRN_LOG=~/Library/Logs/MacVR/wivrn-server.log tools/mql-ab/vrab.sh a72-2
python3 tools/vconsole.py quit; osascript -e 'quit app "MacVR"'
```

Rosetta check afterwards (one window each): `scripts/alyx-runner.sh rosetta` (restarts Steam), then B as above with
labels `b72-rosetta` and A with `a72-rosetta`, then `scripts/alyx-runner.sh fex`.

End: `launchctl unsetenv MTL_HUD_LOG_ENABLED`, `scripts/alyx-vrclient.sh check`, quit caffeinate, headset back to
90 Hz (`build/ab/xr_refresh 90` against the running server) if wanted. Compare with docs/ab-alyx.md's B72 rows
(72.0 fps, lowest second 70-71, HUD GPU 8.45-8.5 ms). If the `.hud` files are empty, the launcher didn't get
MTL_HUD_LOG_ENABLED from launchd: restart Steam once and rerun.
