# Milestone 3 preparation: OpenComposite on the bridge

Goal: Windows OpenVR games in a NotProton prefix run through OpenComposite (OpenVR → OpenXR), our bridge
(`wineopenxr.dll`/`.so`, [bridge-plan.md](bridge-plan.md)) and our native Monado. No SteamVR. Half-Life: Alyx runs (D3D11) to its startup screen, see
[Half-Life: Alyx](#half-life-alyx-2026-10-24).

## Status (2026-10-24)

| Check | Result | Evidence (build/logs/) |
|---|---|---|
| OpenComposite Win64 `vrclient_x64.dll` with llvm-mingw | builds, 5 staged patches | `m3-oc-build.log` |
| OpenVR D3D11 scene app (Valve `openvr_api.dll` 2.15.6, CrossOver DXVK) | 300 frames, 0 errors, pattern in both eyes | `m3-oc-ovr_d3d11.png`, `m3-oc-ovr_d3d11.log` |
| OpenVR Vulkan scene app (winevulkan, the Alyx `-vulkan` path) | 300 frames, 0 errors, pattern in both eyes | `m3-oc-ovr_vulkan.png`, `m3-oc-ovr_vulkan.log` |
| D3D11 app with `initUsingVulkan=true` | works (one ini serves both renderers) | `m3-oc-ovr_d3d11-initvk.png` |
| Legacy input (`GetControllerState[WithPose]`, roles, device classes) and IVRInput (manifest, boolean/vector1/pose/vibration) | no crash; simulated WMR and simple controllers | `m3-oc-ovr_d3d11-wmr.log`, `m3-oc-ovr_d3d11-simple.log` |
| Half-Life: Alyx's own `actions.json` + 18 binding files (copied read-only into the scratch prefix) | loads; poses and skeletons active, trigger/fire bound on WMR | `m3-oc-alyx-manifest-wmr*.log` |
| Runtime chosen by env vars only (`VR_OVERRIDE`, `VR_CONFIG_PATH`, `VR_LOG_PATH`, no vrpath file) | works | `m3-oc-ovr_d3d11-envvars.log` |

The PNGs are the null compositor's frame dump (frame 100, 320×240 per eye):
- D3D11 test: left eye orange with a green square at top left, right eye blue with a magenta square at top right,
  and a white bar across both.
- Vulkan test: left eye dark green with a yellow square, right eye purple with a cyan square, and the white bar.

In every run the client synced through the timeline semaphore and the service logged no errors. The exceptions are
`set_output is not implemented` lines: haptics sent to Monado's simulated controllers, which is expected.

## Build

We build from source. The official prebuilt (MSVC, `openxr` branch) can't be used, for two reasons:
- It stops at OpenVR SDK 2.5.1, and current Alyx needs 2.15.6 interfaces.
- It lacks the two Vulkan fixes Wine on macOS needs.

```sh
git submodule update --init --recursive third_party/opencomposite   # once
scripts/patches.sh apply opencomposite      # pin cff07db (2025-07-21, branch openxr = HEAD, what CI builds)
scripts/build-opencomposite.sh              # needs build/bridge/vulkan (scripts/build-bridge.sh openxr-sdk-win)
```

Outputs:
- `build/m3/oc/bin/vrclient_x64.dll` and `version.txt`.
- The test apps `build/m3/tests/ovr_d3d11_test.exe`, `ovr_vulkan_test.exe` and `openvr_api.dll`. They come from Valve's
  OpenVR SDK **v2.15.6** in `third_party/openvr`, a plain clone with no patches.

The DLL is statically linked (libc++, no MinGW runtime DLLs). It imports Wine-provided DLLs only: ucrt api-sets,
`dxgi`, `d3d11`, `d3dcompiler_47`, `vulkan-1`, `opengl32`, `shlwapi`.

Build pieces outside third_party:
- `bridge/opencomposite/mingw/atlbase.h`: a minimal `CComPtr`, because MinGW has no ATL.
- `bridge/opencomposite/mingw/oc_mingw_compat.h`: force-included. It adds the `CD3D11_VIEWPORT(tex, rtv)` helper.
- Flags `-DWIN32 -D_WIN32_WINNT=0x0A00`. OpenComposite tests `WIN32`, and strict `-std=c++20` MinGW doesn't define it.
- Vulkan headers and the `vulkan-1.dll` import library come from the bridge build. Upstream expects a bundled
  `libs/vulkan` that isn't in the repo.

Patches (`patches/opencomposite/`, staged, never committed):

| Patch | Why |
|---|---|
| 0001-mingw-build | Lets the MinGW build go through. `OC_VULKAN_INCLUDE_DIR`/`OC_VULKAN_LIBRARY` replace the missing `libs/vulkan`; the C# RuntimeSwitcher is MSVC-only; `wstring` → `.c_str()` for libc++ fstreams; zero-arg `OOVR_ABORTF` → `OOVR_ABORT`; `<shlwapi.h>`. |
| 0002-log-stream-construct-on-first-use | The global `std::ofstream` log stream was used by other translation units' static initializers before it was constructed. With MinGW's init order, `DllMain` failed, so `VR_Init` returned 102 "vrclient Shared Lib Not Found". |
| 0003-vulkan-without-win32-memory-and-core-1-1 | First fix: `TemporaryVk` asked for `VK_KHR_external_memory_win32`, which winevulkan on MoltenVK doesn't have, so `vkCreateDevice` failed with -7. Now the extension is added only if the device supports it; nothing uses it. Second fix: `GetOutputDevice` called the core `vkGetPhysicalDeviceProperties2` on a Vulkan 1.0 instance and crashed in winevulkan's unix call. It now uses the KHR entry point, falling back to core. |
| 0004-openvr-sdk-2.15.6-interfaces | `IVRSystem_026`, `IVRCompositor_029`, `IVRInput_011`, `IVROverlay_028` and `IVRApplications_008` from OpenVR 2.15.6 (the header is Valve's, verbatim). New methods: `SetSDKVersion` (called by `openvr_api.dll` 2.15), `PollNextEventWithPoseAndOverlays`, `ComputeDistortionSet` (identity), eye-tracking/foveation (no data), `GetSubmitTexture`/subview overlays (fail softly), `RegisterSubprocess`. Also: the stub parser understands `enum class`; `SetWorkingPerimeter` takes const; stubs regenerate when the `GEN_INTERFACE` lists change; `IVRIPCResourceManagerClient_*` returns InterfaceNotFound instead of a "Missing interface" message box, which would hang. |
| 0005-msvc-aggregate-returns-on-mingw | MSVC passes a member function's hidden return pointer after `this` (and returns every user-defined type through it); MinGW's Itanium ABI passes it first. Alyx (MSVC) calling `GetEyeToHeadTransform` made OpenComposite write the matrix over its own `IVRSystem` object, and the next virtual call crashed in `vr.dll` (vtable = float 1.0). With `--msvc-aggregate-returns` (set by CMake for MinGW), `split_headers.py` declares struct-returning app-interface methods as `T *Name(T *_oc_ret, args...)`; the stub generator fills `*_oc_ret` and returns it, and FnTable entries stay plain C functions. |
| 0006-copy-submitted-bounds-and-runtime-refresh-rate | The D3D11 compositor copies only the submitted bounds, at the same position (the layer's imageRect shows only that part), instead of the whole texture per eye. Alyx submits one 5904x3092 two-eye texture, and each eye used to copy all of it. ini `copyBoundsOnly` (default true). `Prop_DisplayFrequency_Float` comes from XR_FB_display_refresh_rate (enabled when the runtime has it) instead of a fixed 90. ini `runtimeRefreshRate` (default true). See docs/ab-alyx.md "GPU bottleneck". |
| 0007-quiet-no-vr-and-runtime-loss | No VR is a quiet answer, not a message box, see [No VR and runtime loss](#no-vr-and-runtime-loss-2026-10-26). `VR_Init` returns `HmdNotFound` (108) when xrCreateInstance or xrGetSystem fails, and a retry works. A `Background` app gets `NoServerForBackgroundApp` (121) and other app types get `InvalidApplicationType` (130). `VR_IsHmdPresent` never aborts. `VR_GetVRInitErrorAsSymbol` is implemented. XR_ERROR_INSTANCE_LOST/SESSION_LOST in `OOVR_FAILED_XR_ABORT` mark the runtime lost instead of aborting. The frame, pose and input paths then return no-op values, VREvent_Quit is sent, and the process exits if VR isn't shut down within ini `runtimeLostExitSeconds` (default 10, 0 = never). `AcknowledgeQuit_UserPrompt` cancels that exit. |
| 0008-web-overlay-mailbox | Replaces the old 0008 (text-only interstitial panel drawn by OpenComposite, kept in `build/backup/opencomposite-0008-interstitials-textonly.patch`). `IVRMailbox` is a real mailbox client of `macvr-broker` (SteamVR's protocol on ws://127.0.0.1:27062, Winsock), `IVRControlPanel::RegisterExternalWebRoot(path)` registers the game's web UI there, and the fake `ready` is only used when no broker answers (upstream behaviour). Alyx's loading screens are its own web page rendered by MacVR's web helper: [web-overlays.md](web-overlays.md). ini `webOverlays` (default true). |

## Test

```sh
scripts/install-opencomposite.sh build/m3/pfx      # C:\OpenComposite + vrpath (see below)
P="PREFIX=$PWD/build/m3/pfx COPY_DLLS=1 DUMP_FRAME=100"
env $P SIMULATED_LEFT=wmr SIMULATED_RIGHT=wmr scripts/run-bridge.sh 20 build/m3/tests/ovr_d3d11_test.exe 300
printf 'initUsingVulkan=true\n' > build/m3/pfx/drive_c/OpenComposite/bin/opencomposite.ini
env $P scripts/run-bridge.sh 20 build/m3/tests/ovr_vulkan_test.exe 300
# Alyx's manifest (copy of game/hlvr/cfg/*.json into C:\alyxcfg):
env $P SIMULATED_LEFT=wmr SIMULATED_RIGHT=wmr scripts/run-bridge.sh 20 build/m3/tests/ovr_d3d11_test.exe 200 'C:\alyxcfg\actions.json'
```

Setup and environment:
- `build/m3/pfx` is an APFS clone of `build/bridge/pfx`.
- `run-bridge.sh` installs `wineopenxr` and the `ActiveRuntime` key as in M2, and starts the arm64 `monado-service`
  (null compositor plus frame dump).
- New options: `COPY_DLLS=1` (copies `openvr_api.dll` next to the exe) and the `SIMULATED_LEFT/RIGHT` service env.
- OpenComposite's log goes to `%LOCALAPPDATA%\OpenComposite\logs\opencomposite.log`.
- Rosetta was stuck for new x86_64 Mach-O binaries, so the existing `build/bridge` unix side was used unchanged.
  The new PE binaries were checked first with a trivial exe.

Findings:
- OpenComposite always starts a session at `VR_Init` on "temporary graphics": D3D11 by default, Vulkan with
  `initUsingVulkan`. On the first `Submit` it recreates the session with the game's device.
  - Both session sequences work through the bridge: one XrInstance, sequential sessions.
- **Vulkan games need `initUsingVulkan=true`.** Without it, `IVRSystem::GetOutputDevice(TextureType_Vulkan)` aborts
  with "Not using temporary Vulkan instance". That is upstream OpenComposite behaviour on Windows.
  - The abort is a message box, so a headless test hangs.
  - D3D11 games work with the setting too, so a prefix can always set it.
- Monado logs "Forcing timeline semaphores on, your app better have enabled them!" for Vulkan v1 sessions. Neither
  OpenComposite's temporary device nor the test's device enables `timelineSemaphore`. MoltenVK 1.2.10 accepts this
  (clean run), but it is a validation-level risk for Alyx `-vulkan`.
- OpenComposite's soft aborts seen with simulated devices:
  - `Prop_ModelNumber_String` on the HMD is unknown and returns empty.
  - The test manifest's pose binding without a matching source.
  - Neither one is fatal.

## No VR and runtime loss (2026-10-26)

Goal: OpenComposite can be installed in every prefix, the way Proton does it. A game that only probes for VR, with no server or
no headset, gets a quiet "no HMD". A runtime lost mid-game ends VR without a modal box. Patch 0007.

What the stack returns (wineopenxr → standalone Monado client):

| Case | Monado client | Result |
|---|---|---|
| No server (no socket, or a stale one) | `connect` fails (ENOENT/ECONNREFUSED) | xrCreateInstance `XR_ERROR_RUNTIME_UNAVAILABLE` (-51), ~20 ms |
| WiVRn running, no headset | WiVRn's socket listens all the time, but its Monado IPC server, and with it our Mach service, runs only during a headset session. `connect` succeeds (backlog), `bootstrap_look_up` fails with 1102 | same -51, ~20 ms, no wait |
| monado-service without devices | falls back to the simulated HMD | (no "no headset" case) |
| Server killed mid-session | `sendmsg` EPIPE (Wine ignores SIGPIPE) | xrWaitFrame `XR_ERROR_INSTANCE_LOST`; later calls `XR_ERROR_SESSION_LOST` |

XR_ERROR_FORM_FACTOR_UNAVAILABLE isn't reachable with our runtimes; it takes the same quiet path, checked in code only.

Measured with `ovr_d3d11_test.exe` (it now times the probe calls, retries a failed `VR_Init` and handles VREvent_Quit;
`OVR_TEST_IGNORE_QUIT=1` ignores Quit). Logs: `build/logs/m3-oc-novr-*.log`.

| Case | Before (0001-0006) | After (0007) |
|---|---|---|
| (a) no server | quiet; `VR_IsHmdPresent` 0; `VR_Init` 124 `Init_Internal` | `VR_IsHmdPresent` 0 in 0.13-0.9 s on the first call, 61-85 ms after that; `VR_Init` 108 `HmdNotFound` in 23-106 ms; retry 76 ms, also 108 |
| (b) WiVRn-like socket, no Mach service | same as (a) | same as (a): probe 33-130 ms, `VR_Init` 108 in 23-75 ms |
| (c) service SIGKILLed at frame ~200 | modal "OpenComposite Error" (`XrBackend.cpp:405 WaitForTrackingData`, XR_ERROR_INSTANCE_LOST); app hung until killed | one log line; VREvent_Quit at the next PollNextEvent; the app acked and `VR_Shutdown` took 17-18 ms; exit 0 |
| (c') same, app ignores Quit | (same hang) | the loop goes on with invalid poses, inactive actions and an 11 ms sleep in WaitGetPoses; the process ends 10.0 s after the loss (`TerminateProcess`, code 0) |
| normal run, Alyx manifest | ok | ok, unchanged (300 frames, 0 errors) |

The first `VR_IsHmdPresent` in a process costs 0.1-0.9 s (Wine loads `vrclient_x64.dll` and the OpenXR loader). After
that a probe costs 50-90 ms with a server and 60-130 ms without one; the range depends on load. There is no timeout
anywhere on these paths.

Why the process exits: once the runtime is gone, continuing is possible but useless for a VR game, and it can't
recover. SteamVR does the same: it kills an app that doesn't quit after VREvent_Quit. A game that calls `VR_Shutdown`
(to go on flat) or `AcknowledgeQuit_UserPrompt` is not killed. The log keeps the first failing call
(`OpenXR runtime lost (XrResult -13 in xrWaitFrame…)`), and every other XR failure still aborts as before.

Test harness: `scripts/run-bridge.sh` has `SERVICE=none|listen|monado`, `KILL_SERVICE=N`, `RT_DIR` and `BRIDGE_ROOT`.
Wine must not touch `~/Documents` (TCC prompt), so the runs used a prefix clone, the bridge root (with the standalone
`monado-x86_64` client) and the runtime dir under `~/Library/Application Support/macvr-test/`.

## Interstitials (2026-10-26)

Alyx doesn't draw its loading and "Press Trigger To Start" screens itself: it registers its web UI
(`IVRControlPanel_006::RegisterExternalWebRoot("<game>\hlvr\webui")`) and talks to that page through the
undocumented `IVRMailbox_001` (`hlvr/mailbox`, `hlvr/interstitials`). With stock OpenComposite those screens are black.
Since 2026-10-26 (patch 0008-web-overlay-mailbox) this goes the way SteamVR does it: OpenComposite is a client of
MacVR's mailbox broker, the page runs in MacVR's web helper and its scene graph is shown as overlay quads.
Everything is in [web-overlays.md](web-overlays.md).

OpenComposite side (0008):
- `RegisterMailbox(name)`: one WebSocket per mailbox to 127.0.0.1:27062 (`OC_MAILBOX_PORT` overrides), `mailbox_open
  <name>`; a reader thread queues the frames. `SendMessage(h, target, json)`: `mailbox_send <target> <json>`.
  `ReadMessage`: the next queued message (0), `BufferTooShort` (2) leaving it queued, or `NoMessage`.
- `RegisterExternalWebRoot(path)`: mailbox `vrclient/<pid>` (open for the life of the process; the broker tears the
  overlays down when it closes), `register_external_webroot` with the Windows path, `wine_get_unix_file_name` of it and
  of every drive root, then waits up to 15 s for the reply, as vrserver blocks until the page is loaded.
- No broker (connect refused within 300 ms) or `webOverlays=false`: logged once, mailboxes are pretend ones and the
  first `ReadMessage` returns upstream's fake `ready`, so the game goes on without loading screens.

Test without Alyx (scratch prefix `~/Library/Application Support/macvr-test/pfx`, broker running):
`OVR_TEST_INTERSTITIAL=1 OVR_TEST_PROMPT_FRAME=300 OVR_TEST_WEBROOT='Z:\Users\…\hlvr\webui' ovr_d3d11_test.exe 700`
(via `scripts/run-bridge.sh` with `PREFIX`, `BRIDGE_ROOT`, `RT_DIR` there). 2026-10-26: `RegisterExternalWebRoot` 149 ms
(page loaded), the page's real `ready` after 77 ms, the page logged `Begin loading: startup` / `Show message` / `End
loading`, and the overlay was destroyed when the test exited.

## Install recipe (what a NotProton integration automates)

The prefix is per game (`compatdata/<appid>/pfx`), so everything below is per game.

1. **OpenXR runtime (M2):**
   - Builtin `wineopenxr.dll` + `wineopenxr.so` staged in the runner's or NotProton's `x86_64-windows`/`x86_64-unix`
     (like `lsteamclient`), plus the placeholder `C:\windows\system32\wineopenxr.dll`.
   - `C:\windows\system32\wineopenxr.json` and
     `HKLM\SOFTWARE\Khronos\OpenXR\1\ActiveRuntime = C:\windows\system32\wineopenxr.json`.
2. **OpenComposite:** copy `vrclient_x64.dll` and `version.txt` to `C:\OpenComposite\bin\`. Optionally add
   `C:\OpenComposite\bin\opencomposite.ini`, the global config next to the DLL, with `initUsingVulkan=true`. A
   per-game ini can also go in the game's working directory.
3. **OpenVR runtime path:** pick one (both verified).
   - **File:** `drive_c/users/steamuser/AppData/Local/openvr/openvrpaths.vrpath` (`crossover` is a symlink to
     `steamuser`):
     ```json
     { "config": [ "C:\\OpenComposite\\config" ], "external_drivers": null, "jsonid": "vrpathreg",
       "log": [ "C:\\OpenComposite\\logs" ], "runtime": [ "C:\\OpenComposite" ], "version": 1 }
     ```
     `openvr_api.dll` loads `<runtime>\bin\vrclient_x64.dll`. The config and log dirs must exist.
   - **Env only:** `VR_OVERRIDE=C:\OpenComposite VR_CONFIG_PATH=C:\OpenComposite\config VR_LOG_PATH=C:\OpenComposite\logs`.
     When all three are set, `openvr_api` doesn't read the vrpath file (`vrpathregistry_public.cpp`). This works as a
     Steam launch option (`VR_OVERRIDE=... %command%`) or from NotProton's `run`. It's the most robust choice: nothing
     else can rewrite it.
4. **Env for the game:**
   - `CX_GRAPHICS_BACKEND=dxvk` for D3D11 games.
   - The bridge needs `monado-service` (or WiVRn) running on the same `XDG_RUNTIME_DIR`/socket as the bridge's client.
5. Nothing else: no SteamVR, no `vrclient` from Proton, no registry keys for OpenVR.

`scripts/install-opencomposite.sh <prefix>` does steps 2–3 (file variant) on a prefix clone. It never touches real
game prefixes.

## Steam and SteamVR under NotProton (read-only investigation)

What decides whether SteamVR starts for an OpenVR game:
1. **The game's own `VR_Init`.**
   - With SteamVR as the runtime, `openvr_api.dll` loads SteamVR's `vrclient_x64.dll`, which starts
     `vrstartup`/`vrserver`.
   - With OpenComposite as the runtime, nothing starts: OpenComposite talks only to the OpenXR loader path, here
     `wineopenxr`. This is the main lever, and it's fully under our control in the prefix.
2. **The prefix vrpath.**
   - On Linux, Proton's `steam.exe` helper writes the prefix's `openvrpaths.vrpath` (pointing at Proton's `vrclient`
     bridge) on every launch, and that is what makes Proton games find SteamVR.
   - NotProton has no such helper. Its `run` script (1914 lines) has no VR/OpenVR handling, and its overrides are
     only `steamclient`/`lsteamclient`.
   - The Alyx prefix (546560) has no `AppData/Local/openvr` at all. The SteamVR prefix (250820) has an empty one,
     created by `vrstartup.exe` when SteamVR was started as its own app on 2026-10-17.
   - So nothing would overwrite our prefix vrpath. The env-var variant avoids even that question.
3. **The Steam client (macOS).**
   - Its console log shows "Failed to init SteamVR because it isn't installed" at startup. The installed SteamVR
     (250820) is the Windows build, run through NotProton, and the mac client has no native runtime.
   - It also logs "Setting VR Path Registry runtime path to …/common/SteamVR", but the host registry
     `~/Library/Application Support/OpenVR/.openvr/openvrpaths.vrpath` is unchanged since Jan 2025. It still points
     at the deleted `SteamVR.app`.
   - Alyx's appinfo, parsed from `appcache/appinfo.vdf`:
     - The only Windows launch option is `game/bin/win64/hlvr.exe -vr -steam -noasserts -nopassiveasserts +map startup`,
       `type "vr"`, with no working directory.
     - `common/onlyvrsupport 1`, `openvrsupport 1`, `openvr_action_manifest_path game/hlvr/cfg/actions.json`.
   - Steam's logs show no automatic launch of 250820 tied to another app. The one SteamVR run was a manual
     `LaunchApp` of 250820 itself.
   - Not verified, because launching games was out of scope: whether the mac client, for a `type "vr"` launch, starts
     app 250820 through its compat tool. Check on the first real Alyx launch: grep `console_log.txt` for
     `GameAction [AppID 250820` / `vrstartup`.
   - If it does start it, the fallbacks are uninstalling SteamVR (250820 is not needed for M3) or blocking it in
     NotProton (refuse `run` for appid 250820 while a VR game runs).

## What Half-Life: Alyx will need

From the local install (read-only) and OpenComposite's history:
- **OpenVR 2.15 interfaces.** Alyx's `vr.dll` (build 25487405) asks for exactly one version each of:
  - `IVRSystem_026`, `IVRCompositor_029`, `IVRInput_011`, `IVROverlay_028`;
  - `IVRApplications_007`, `IVRChaperone_004`, `IVRRenderModels_006`, `IVROverlayView_003`, `IVRHeadsetView_001`;
  - `IVRInputInternal_002`, `IVRMailbox_001`, `IVRIPCResourceManagerClient_004`, `IXrProto_001`.

  Upstream OpenComposite (2.5.1) has none of the first four, so stock or prebuilt OpenComposite fails `VR_Init` on
  current Alyx. Patch 0004 adds them. `IXrProto_001` (upstream hack), `IVRMailbox_001` (dummy for HL:A) and
  `IVRIPCResourceManagerClient_*` (0004) are answered without the fatal message box.
- **Renderer:**
  - Windows Alyx defaults to D3D11 (`rendersystemdx11.dll`). That is our `CX_GRAPHICS_BACKEND=dxvk` path, so plan on
    D3D11 first.
  - `-vulkan` (`rendersystemvulkan.dll`, winevulkan → MoltenVK) needs `initUsingVulkan=true` and patch 0003, and has
    the timeline-semaphore caveat above. Linux reports prefer the D3D renderer under Proton with Monado.
- **Input:**
  - `actions.json` has 45 actions in 6 sets (boolean, vector1/2, pose, skeleton, vibration). It has 3 default
    bindings per controller type (main, `_left`, `_single`).
  - OpenComposite takes the first per type. On WMR it loads with warnings: dpad `thumbstick/touch` paths, and 3
    `*continuous` actions missing from the manifest.
  - Users with OpenComposite report A/X snap-turning on Quest. The fix is a custom binding file at
    `<working dir>\OpenComposite\oculus_touch.json`, or the OrionMoonclaw "priorities" fork.
  - Hand skeletons are estimated (OpenComposite `b4bef2a`).
- **Known cosmetic gaps** (Linux reports with OpenComposite and xrizer): grey or missing loading screens (compositor
  skybox/overlay), occasional stutter.
- **DXVK:** CrossOver's DXVK 1.10.3 must run Alyx's D3D11 renderer. That is untested and is the next M3 risk, separate
  from OpenComposite.
- **Headset session:** the Quest goes through WiVRn. Its controllers appear as `oculus/touch_controller`, which
  matches Alyx's `oculus_touch` bindings directly.

Sources for the community status: [VR on Linux game DB: Half-Life: Alyx](https://db.vronlinux.org/games/546560.html),
[VR on Linux wiki: OpenComposite](https://wiki.vronlinux.org/docs/fossvr/opencomposite/).

## Half-Life: Alyx (2026-10-24)

First run in the real prefix (`compatdata/546560`, compat tool `notproton-fex-rosetta-41073`, runner
`crossover-27.0.0.41073-fex`).

Result:
- **D3D11 works end to end.** Alyx under Steam (DRM) → OpenComposite → bridge → x86_64 Monado client → WiVRn → Quest,
  90 fps per stream. Alyx stops at its startup screen, "Press Trigger To Start", which is black in the headset and in the
  desktop mirror: SteamVR draws that text as an interstitial (`hlvr/interstitials` mailbox), and OpenComposite only logs
  it. Going on to the menu needs a trigger press, and the controllers were idle.
- **`-vulkan` fails in Alyx itself** ("Unable To Start Game: Failed to initialize Vulkan"). CrossOver's MoltenVK 1.2.10
  rejects `VkPhysicalDeviceMultiviewFeatures::multiviewGeometryShader` in `vkCreateDevice`. OpenComposite and the bridge
  were fine (`initUsingVulkan=true`, session at 90 fps).
- **No SteamVR launch.** None of the 5 launches started 250820 (`console_log.txt` has no `250820` or `vrstartup`).
- Evidence (build/logs/):
  - `m3-alyx-step1-hello_xr-d3d11.png`: Windows hello_xr through the bridge in the headset; slate-green scene with a
    blue cube in each eye.
  - `m3-alyx-d3d11-1.png`: before the fix, the WiVRn lobby ("Waiting for an application"). Alyx had crashed.
  - `m3-alyx-d3d11-2/3.png`, `m3-alyx-vulkan-1.png`: the Alyx stream, all black.
  - `m3-alyx-end-lobby.png`: the WiVRn client's "Computers" list after the server stopped.
- Measurements are in TODO.md, "M3 Alyx notes".

### DXMT (2026-10-24, current)

Under DXVK the menu background was missing: CrossOver's MoltenVK geometry-shader emulation emits invalid Metal for 4
Alyx pipelines. CrossOver parts stay unpatched (decision 2026-10-24), so Alyx now runs on stock DXMT and the bridge has a DXMT
D3D11 path ([bridge-plan.md](bridge-plan.md) §4a). Result: the menu renders with its 3D City 17 background in the
headset (`build/logs/m3-alyx-dxmt-2.png`), WiVRn 2×90 fps at ~17.5 Mbit/s, no bridge errors in the game log.
Launch option (set by hand): `WINEMSYNC=1 MTL_HUD_ENABLED=1 CX_GRAPHICS_BACKEND=dxmt WINEDLLPATH="<prefix>/drive_c/macvr" %command%`.
The install script now also backs up `C:\macvr` before overwriting it.

### Install (`scripts/install-vr-546560.sh`, rollback `scripts/uninstall-vr-546560.sh`)

What the script installs:
- `system32\wineopenxr.dll` (placeholder) and `system32\wineopenxr.json`;
  `HKLM\SOFTWARE\Khronos\OpenXR\1\ActiveRuntime = C:\windows\system32\wineopenxr.json`.
- **`C:\macvr\x86_64-windows\wineopenxr.dll` and `C:\macvr\x86_64-unix\{wineopenxr.so,libopenxr_monado.dylib,ipc-stamp}`**,
  copies of `build/bridge/root`. Since 2026-10-26 the client is WiVRn's own x86_64 `libopenxr_wivrn`
  (`scripts/build-wivrn.sh --client-x86_64`): same Monado tree, tag v26.9 and socket `wivrn/comp_ipc` as the server.
  - Not in `~/Documents`: the game runs as Steam.app for TCC, and that triggered a "Steam.app would like to access files
    in your Documents folder" prompt. It was declined, so a TCC denial is now recorded for Steam → Documents
    (`tccutil reset SystemPolicyDocumentsFolder com.valvesoftware.steam` clears it).
  - Not in `Program Files (x86)\Steam`: NotProton prunes that directory.
- `C:\OpenComposite\bin\{vrclient_x64.dll,version.txt,opencomposite.ini}` (`initUsingVulkan=false`; set it to `true` for
  `-vulkan`), plus `config` and `logs`.
- **`%LOCALAPPDATA%\openvr\openvrpaths.vrpath`, read-only (0444).**
  - NotProton's `steam.exe` shim runs Proton's `setup_vrpaths()` on every launch. With no host vrpath
    (`$HOME/.config/openvr/openvrpaths.vrpath`), it **deletes** the prefix file. With one, it rewrites it to
    `runtime C:\vrclient\` and unsets `VR_OVERRIDE`.
  - Wine won't delete or overwrite a read-only file, so ours survives. The first launch with a writable file failed
    with OpenVR error 110 ("installation path could not be located").
  - The Proton route (host file + `C:\vrclient`) was tested on 2026-10-26 and doesn't work under NotProton without a
    global env var, so the read-only file stays. See [m4-notproton.md](m4-notproton.md) §0 "vrclient route".
- Backups: `build/backup/546560/<time>/{system,user,userdef}.reg` and `build/backup/546560/localconfig.vdf`.
- **Current Alyx state (2026-10-26), differs from the script:** OpenComposite 0001-0008 and the bridge with the
  NULL-instance fix are installed (previous `vrclient_x64.dll`, `opencomposite.ini`, system32 bridge and the read-only
  vrpath backed up in `build/backup/546560/20261026-040953-oc0008/`; the script's own backup is `20261026-041000`). The
  prefix vrpath is **deleted**. OpenVR finds OpenComposite through `VR_OVERRIDE`/`VR_CONFIG_PATH`/`VR_LOG_PATH` in
  `HKLM\System\CurrentControlSet\Control\Session Manager\Environment`, pointing at the copy outside the prefix,
  `Z:\Users\<user>\Library\Application Support\macvr\opencomposite` (see m4-notproton.md §0 "VR_OVERRIDE route").
  The in-prefix `C:\OpenComposite` is unused. Rerunning the script rewrites the read-only vrpath; that is harmless
  (with all three variables set, `openvr_api` doesn't read it). Rollback of the env route: delete the three values and
  restore the vrpath from that backup with mode 444.

### Launch

1. Steam launch options for 546560, set in `userdata/<account id>/config/localconfig.vdf` while Steam was quit:
   (DXVK, before the DXMT switch) `CX_GRAPHICS_BACKEND=dxvk WINEDLLPATH="$HOME/Library/Application Support/Steam/steamapps/compatdata/546560/pfx/drive_c/macvr" %command%`.
   - NotProton's `run` appends env `WINEDLLPATH` after the runner's own dirs and passes it with `--env`. Other env
     vars don't reach the game: `open -a` starts it from launchd's environment.
2. Host side: nothing since 2026-10-26. The client and server come from the same WiVRn tree, so there is no
   `IPC_IGNORE_VERSION` and no `monado_comp_ipc` symlink. The server start scripts (`run-wivrn.sh`, `wivrn-session.sh`,
   `tools/mql-ab/{latrun,wivrn-restart}.sh`) publish the server's ipc-stamp to
   `$(getconf DARWIN_USER_TEMP_DIR)wivrn/ipc-stamp`. The bridge compares it with the client's and logs
   `ipc-stamp match (...)` to `C:\macvr\wineopenxr.log` (if `C:\macvr\wineopenxr.env` sets `WINEOPENXR_LOG`). A mismatch
   refuses the runtime (`IPC STAMP MISMATCH`, override `WINEOPENXR_IGNORE_IPC_STAMP=1`).
   - Game processes must not read anything under `~/Documents` (TCC prompt, the game blocks until it is answered). A
     first version of the stamp check read the server's stamp from the build dir: Wine and Alyx raised Documents
     prompts and VR init stalled 62/108 s. Fixed by the published copy.
3. `scripts/run-wivrn.sh`, then the Quest client (`adb shell am start ... wivrn://<mac address>:9757`), then
   `open steam://rungameid/546560`. For Vulkan, use `open "steam://run/546560//-vulkan/"` (Steam asks to confirm the
   argument) with `initUsingVulkan=true`.
4. Quit: `osascript -e 'quit app "Half-Life Alyx"'`. The game exits with status 0.

Prompts seen on the way:
- Steam's "Cloud Out of Date" (a save from another PC wasn't uploaded yet) came up on the first launch only. It was
  answered "Play anyway". No game was started, so no new save was written.
- A crash wrote `hlvr_*_accessviolation.mdmp` next to `hlvr.exe` (game behaviour). Two dumps are there from the pre-0005
  runs.

Logs:
- Game: `~/Library/Application Support/notproton/launchers/546560/notproton-wine.log` (DXVK and Monado client lines).
- NotProton: `compatdata/546560/notproton-run.log`.
- OpenComposite: `%LOCALAPPDATA%\OpenComposite\logs\opencomposite.log`.
- Server: `build/logs/wivrn-server.log`.

### Not done / open

- Quest Touch custom bindings (A/X snap turn): OpenComposite only reads `<cwd>\OpenComposite\oculus_touch.json`, and the
  cwd is the game install dir (`S:\steamapps\common\Half-Life Alyx`), outside the prefix. Skipped.
- OpenComposite soft aborts seen, none fatal:
  - unknown string property 1001 (HMD);
  - `/user/gamepad` handle;
  - skeleton/pose action origins;
  - `GetBindingVariant`, `ClearStageOverride`, `ComputeDistortion`;
  - Monado `get_reference_bounds_rect` NOT_IMPLEMENTED.
- Options → Performance page empty (2026-10-29): not OpenComposite. The install is mixed since the 25487405 rollback
  (binaries depot 546563 at 25487405, content depot 546561 still 26227071). The 26227071 `child02` layout's graphics
  page uses `GameMenuOptionRenderingFoveatedTogglePanel` (foveated rendering toggle, `vr_vrs`), which only the 26227071
  `client.dll` registers. Alyx's console.log at menu load: `[Panorama] ***** Parsing error on
  panorama\layout\game_menus\child02.xml(244): XML parsing error: Found unknown panel type: (name=GameMenuOptionRenderingFoveatedTogglePanel)`
  plus the same type in `game_menu_main.css`. The benchmark (`GetCompositorBenchmarkResults` → false) only selects the
  GPU level (`moddefaults.txt` fallback, as on SteamVR without a benchmark) and does not gate the page. Fix: make the
  install consistent (TODO.md, known issues).

## Next steps

1. With someone in the headset: press the trigger at "Press Trigger To Start", then check the menu, a level load and
   the hands/controllers (bindings: `oculus_touch`). Measure real-content encode then.
2. (done 2026-10-26) The bridge's x86_64 client is built from the WiVRn tree; `IPC_IGNORE_VERSION` and the socket
   symlink are gone.
3. (2026-10-26, patch 0008: SteamVR's web overlay pipeline, [web-overlays.md](web-overlays.md)) Interstitials and loading screens, see
   [Interstitials](#interstitials-2026-10-26).
4. `-vulkan` needs a MoltenVK with `multiviewGeometryShader`, or Alyx not requesting it. Out of scope for now.
5. If Alyx trips on more missing OpenVR methods, OpenComposite's log names them (`STUBBED`/`Soft Abort`).
