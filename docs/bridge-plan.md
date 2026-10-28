# Milestone 2 plan: Windows OpenXR bridge (NotProton → native Monado)

Goal: a Windows VR game runs in its own NotProton prefix (CrossOver-based, one prefix per game) and renders
D3D11 through **stock DXVK**. A Windows OpenXR runtime DLL with a unix side (the "bridge", in the style of
wineopenxr) passes the game's OpenXR calls to our native macOS Monado client. Frames and poses never go through
wineserver. Frames travel as IOSurface Mach ports, sync as MTLSharedEvent, and the IPC is Monado's socket plus the Mach
side channel from patch 0012.

Evidence for everything marked *verified* is in [spikes/bridge/RESULTS.md](../spikes/bridge/RESULTS.md) (2026-10-24).

## 0. Status (2026-10-24): M2 steps 1–5 run in the scratch prefix

Code: [bridge/](../bridge/) (our code), build `scripts/build-bridge.sh`, run `scripts/run-bridge.sh`. Monado patch
[0014](../patches/monado/0014-oxr-vk-gipa-from-loaded-icd.patch). Runner `crossover-27.0.0.41073-fex` in Rosetta mode,
prefix `build/bridge/pfx` (an APFS clone of NotProton's template), `CX_GRAPHICS_BACKEND=dxvk`, our arm64
`monado-service` with the null compositor. Nothing in the runner, NotProton or a game prefix was touched.

```sh
git clone --depth 1 -b apr2025 https://github.com/microsoft/DirectXMath third_party/directxmath   # once, for hello_xr's D3D11 plugin
scripts/patches.sh apply monado          # or have 0014 staged; the bridge client needs it
scripts/build-bridge.sh                  # monado-service, x86_64 client, Windows hello_xr, wineopenxr.dll/.so, tests
H=build/bridge/openxr-sdk-win/src/tests/hello_xr/hello_xr.exe
scripts/run-bridge.sh 10 $H -g D3D11     # also -g Vulkan2, -g Vulkan
scripts/run-bridge.sh 20 build/bridge/tests/xr_time_test.exe 300
DUMP_FRAME=100 scripts/run-bridge.sh 10 build/bridge/tests/xr_array_test.exe 200
# step 1 probe (spike): cd spikes/bridge && make && MACVR_OPENXR_RUNTIME=<x86_64 libopenxr_monado.dylib> \
#   CX_GRAPHICS_BACKEND=dxvk EXTRA_DLLPATH=$PWD/build/root ./run-wine.sh build/xr_probe_test.exe   (service running)
```

`run-bridge.sh` copies the placeholder `wineopenxr.dll` and `wineopenxr.json` into the prefix's system32, sets
`HKLM\SOFTWARE\Khronos\OpenXR\1\ActiveRuntime = C:\windows\system32\wineopenxr.json`, puts `build/bridge/root`
first in `WINEDLLPATH`, starts the service with its own `XDG_RUNTIME_DIR=build/bridge/rt` (so it never collides with
WiVRn or another `monado-service`), and writes the null compositor's frame to `build/logs/bridge-frame.png`.
`WINEOPENXR_DEBUG=1` logs unsupported lookups and the time calibration.

| Step | Result | Evidence (build/logs/) |
|---|---|---|
| 1 | Probe: D3D11 clears (DXVK) land in a Monado swapchain through the x86_64 client on DXVK's unwrapped device; timeline-semaphore sync | `bridge-step1.png` (orange/blue eyes, white bar) |
| 2 | `hello_xr.exe -g Vulkan2` and `-g Vulkan` through winevulkan | `bridge-hello_xr-vulkan2.png`, `bridge-hello_xr-vulkan.png` |
| 3 | `hello_xr.exe -g D3D11` on CrossOver's DXVK, with depth swapchains | `bridge-hello_xr-d3d11.png` |
| 4 | QPC ⇄ XrTime: round trip exact, calibration ±0–50 ns; Wine's QPC is `mach_continuous_time` (offset −25/−50 ns) | `bridge-xr_time_test.log` |
| 5 | 2-layer color + 2-layer depth swapchains (single-pass stereo) in D3D11 | `bridge-array.png` (orange left, blue right) |

All runs: 0 errors on both sides, client sync `timeline semaphore` (no CPU-wait fallback).

Per-frame overhead (M4 Max, Rosetta client, 320×240 views, null compositor at ~20 fps; p50/p99):
- One generated thunk (loader → PE → unix call → Monado, `xrGetInstanceProperties`): 0.2 / 0.2–0.3 µs.
- `xrEndFrame` without layers, with flush + submission lock: 0.04–0.07 / 0.09–0.12 ms.
- Client commit (Monado `sync-stats`, inside `xrEndFrame`): D3D11 0.05–0.09 / 0.25–0.45 ms, Vulkan2 0.05–0.08 /
  0.16–0.26 ms. Service commit → client GPU done: D3D11 0.42–0.55 ms, Vulkan 0.08–0.13 ms (DXVK's frame work is
  still on the queue when the semaphore is signalled behind it).
- Split arrays: `xrReleaseSwapchainImage` with 2 slice copies 0.18–0.28 / 0.63 ms, `xrEndFrame` with the layer
  rewrite 0.10–0.15 / 0.42–0.45 ms.
- Step 1 probe (D3D11 clear, release + `xrEndFrame` including flush and lock): 0.20–0.37 / 0.55–1.6 ms.
- `xrCreateInstance` → `xrBeginSession`: 6 ms warm, 57 ms on the first run after a build.

**DXMT (2026-10-24):** `XR_KHR_D3D11_enable` also works on stock DXMT (`BACKEND=dxmt`), see §4a. hello_xr `-g D3D11`:
`bridge-hello_xr-d3d11-dxmt.png` (keyed-mutex GPU sync) and `bridge-hello_xr-d3d11-dxmt-cpu.png`
(`WINEOPENXR_DXMT_SYNC=cpu`); DXVK re-checked (`bridge-hello_xr-d3d11-dxvk-recheck.png`). Half-Life: Alyx runs on it.

M3 preparation (OpenComposite on top of the bridge, OpenVR D3D11/Vulkan test apps): [m3-opencomposite.md](m3-opencomposite.md).

### How the bridge is built

- `bridge/make_openxr.py` generates the thunks from `third_party/openxr-sdk/specification/registry/xr.xml` (521 unix
  thunks, 534 `xrGetInstanceProcAddr` entries incl. aliases). Both sides are 64-bit with identical layouts and
  OpenXR handles pass through unchanged, so a generated thunk only packs arguments. Hand-written: instance/extension
  filtering, sessions, swapchains, frame end, the Vulkan and D3D11 graphics calls, time conversion (PE side,
  `src/wineopenxr.c`), and runtime loading, handle unwrapping, session binding (unix side, `src/wineopenxr_unix.c`).
- Extensions games see: the runtime's unprotected and Vulkan ones minus `XR_EXT_debug_utils` (its callback would be
  called with the host ABI), plus `XR_KHR_D3D11_enable` (when the runtime has `vulkan_enable`) and
  `XR_KHR_win32_convert_performance_counter_time` (on `convert_timespec_time`). The host instance gets
  `XR_KHR_vulkan_enable` for D3D11 and enable2 apps and `XR_KHR_convert_timespec_time` for the time extension.
- The unix side finds the loaded MoltenVK with `_dyld`, sets `XRT_VK_GIPA_LIBRARY` and
  `OXR_DEBUG_FORCE_TIMELINE_SEMAPHORES=1`, dlopens `libopenxr_monado.dylib` from its own directory
  (`MACVR_OPENXR_RUNTIME` overrides) and negotiates with it. No loader on either side.
- The client the bridge ships (`build/bridge/root/x86_64-unix/libopenxr_monado.dylib`) is, since 2026-10-26, WiVRn's
  own `libopenxr_wivrn` built for x86_64 from the server's WiVRn tree and `build/monado-snapshot`
  (`scripts/build-wivrn.sh --client-x86_64` → `build/wivrn-client-x86_64/client/`): same git tag (v26.9), same
  `XRT_*` feature set and socket `wivrn/comp_ipc` as the server, so neither `IPC_IGNORE_VERSION` nor a socket symlink
  is needed. It links with `-dead_strip_dylibs`, so it has no `libvulkan` dependency at all. The standalone client
  (`build/bridge/monado-x86_64`, tag v25.1.0-macvr-standalone, socket `monado_comp_ipc`) is only for the
  `monado-service` test rig; `scripts/run-bridge.sh` selects it with `MACVR_OPENXR_RUNTIME` unless `WIVRN=1`.
- IPC stamp (`scripts/ipc-stamp.sh`): the build writes `monado-tree=<git tree of the Monado source>`, `socket=` and
  `git-tag=` to `<server build>/server/ipc-stamp` and next to the client. Server start scripts publish the server's
  copy to `$(getconf DARWIN_USER_TEMP_DIR)wivrn/ipc-stamp`. At load, `wineopenxr.so` compares it with its client's
  (no reads under `~/Documents`, which would raise a TCC prompt in the game). On a match it logs `ipc-stamp match`;
  on a mismatch it refuses the runtime unless `WINEOPENXR_IGNORE_IPC_STAMP=1`. A copy older than the running
  `wivrn-server` is only warned about. `scripts/ipc-stamp.sh check` does the same comparison from the shell.
- PE side builds with llvm-mingw (`LLVM_MINGW`, see scripts/lib/detect.sh). `bridge/tools/mark-builtin.py` writes the
  builtin signature, so the build doesn't need a winebuild.
- Windows `hello_xr.exe`: OpenXR-SDK 1.1.65 with a static loader, D3D11 plugin enabled outside MSVC
  (`-DXR_USE_GRAPHICS_API_D3D11`, Microsoft DirectXMath `apr2025`, `bridge/tests/mingw_compat.h` force-included for
  `CD3D11_*` helpers and `<mutex>`), `vulkan-1.dll` import library from the SDK headers. No OpenXR-SDK patch.

### Decisions made while implementing

- **Vulkan apps (enable/enable2):** `xrCreateVulkanInstanceKHR`/`DeviceKHR` run on the PE side through the app's
  `pfnGetInstanceProcAddr` (winevulkan) with the runtime's filtered extension list; the device also gets
  `timelineSemaphore`. `xrGetVulkanGraphicsDevice2KHR` maps through the v1 call on the unwrapped instance and
  matches the result against the PE devices from `vulkan-1.dll`.
- **Monado's GPU check:** the service's suggested device UUID (MoltenVK 1.4.2) doesn't match CrossOver's 1.2.10
  UUID, so Monado logs "Did not find runtime suggested GPU, fall back to GPU 0". Harmless on one GPU.
- **`xrGetD3D11GraphicsRequirementsKHR`** returns DXGI adapter 0's LUID (what DXVK uses) and calls the runtime's
  Vulkan requirements, which Monado needs before session creation.
- **DXVK hook:** `__wineopenxr_GetVulkan{Instance,Device}Extensions` use Proton's semantics (count includes the
  terminator). Without an app instance they make a temporary one. DXVK then adds `VK_KHR_external_*` and
  `VK_KHR_timeline_semaphore` (verified in the DXVK log).
- **Swapchain kinds for D3D11 (step 5):** see §4 "Limits". `arraySize > 1` color swapchains are split into one host
  swapchain per slice plus a DXVK array texture per image; release copies each slice (`CopySubresourceRegion`),
  `xrEndFrame` rewrites the sub-images. Depth/stencil swapchains (`D32`, `D16`, `D24S8`, `D32S8`) are bridge-local
  DXVK textures; depth infos that name them are dropped from the views at `xrEndFrame`. Nothing downstream
  (null compositor, WiVRn) reprojects with depth.
- One XrInstance at a time (like Proton's wineopenxr); 64-bit games only.

## 1. Recommendations at a glance

| Question | Answer |
|---|---|
| D3D11 layer | CrossOver's bundled DXVK **`cxaddon-1.10.3-1-25-g737aacd`**, selected per game with `CX_GRAPHICS_BACKEND=dxvk`. It has `IDXGIVkInteropDevice1` and the `wineopenxr.dll` extension hook. Nothing to build or install. *Verified.* |
| Unix-side loading | Our own **builtin PE `wineopenxr.dll` + unixlib `wineopenxr.so`** (Wine 11 `MemoryWineLoadUnixLib`). This is the same mechanism as NotProton's `lsteamclient` and DXMT's `winemetal`. *Verified* with a probe DLL loaded from our own directory. |
| IOSurface ⇄ D3D11 | The unix side unwraps winevulkan's handles to DXVK's host `VkDevice`. Monado's client compositor imports the service's IOSurfaces there (`VkImportMetalIOSurfaceInfoEXT`). The PE side wraps each host `VkImage` with `CreateTexture2DFromVkImage`. *Verified* (pixel-exact). |
| Sync | `FlushRenderingCommands` → `LockSubmissionQueue` → Monado client submits on DXVK's queue (timeline semaphore imported from the service's MTLSharedEvent) → `ReleaseSubmissionQueue`. *Verified:* 200 frames, GPU done 0.15 ms p50 after submit. |
| Architecture | **(a) A wineopenxr-style thunk** over our host Monado OpenXR runtime (`libopenxr_monado.dylib`, IPC client). XR_KHR_D3D11_enable is emulated on XR_KHR_vulkan_enable. This is not (b) a custom runtime that links Monado's IPC client directly. |
| Monado changes | One small patch: on Apple, let the state tracker take `vkGetInstanceProcAddr` from the already-loaded MoltenVK rather than the linked Vulkan loader. Timeline semaphores for vulkan_enable v1 already exist (`OXR_DEBUG_FORCE_TIMELINE_SEMAPHORES`). |
| Host arch | One universal (x86_64 + arm64) `wineopenxr.so` and one universal WiVRn client for all flavors; the PE stays x86_64. Rosetta (`notproton-preview`, `notproton-fex-rosetta`) loads the x86_64 slice, FEX (`notproton-fex`) the arm64 slice. *Verified* (step 6, §7a). |

## 2. What NotProton ships (read-only survey)

Compat tools: `notproton-preview-41073` (CrossOver X86, Rosetta), `notproton-fex-rosetta-41073` and `notproton-fex-41073`
(CrossOver ARM64 build, Rosetta resp. FEX).
- Runners are copies of CrossOver build 27.0.0.41073 (2026-10-15) in `~/Library/Application Support/notproton/runners/`.
  ntdll says `wine-11.17-8910-g4683e69e153`.
- The `run` script picks `wine_unix=lib/wine/x86_64-unix` for Rosetta and `aarch64-unix` for FEX.
- It sets `WINEDLLPATH=$CX_ROOT/lib/wine/x86_64-windows:$wine_unix`.

D3D11 backends in each runner:
- `lib/dxmt/` (default): DXMT ≈ upstream v0.80+ from Sept/Oct 2026. Its winemetal export set is identical to upstream
  HEAD, and `d3d11.maxTessFactor` is present.
- `lib/dxvk/`: `d3d9/10/10_1/10core/11.dll`, no dxgi. The DXVK log reads `DXVK: cxaddon-1.10.3-1-25-g737aacd`, i.e.
  CodeWeavers' 1.10.3 fork (config options match the 1.10 line). dxgi stays Wine's ("Adapter is not a DXVK adapter",
  harmless).
- d3d11.dll contains the GUIDs `IDXGIVkInteropDevice`/`…Device1`/`IDXGIVkInteropSurface` and the `OpenXR:` provider
  strings (DXVK's `DxvkXrProvider`).
- Upstream DXVK 2.x needs Vulkan 1.3. Gcenx's dxvk-macOS is also 1.10-based. So the bundled build is the right one, and
  the interop interfaces have been in DXVK since 1.8 (CodeWeavers' OpenXR commit a3065fca).

Vulkan in the process:
- win32u.so dlopens `lib/x86_64/libMoltenVK.dylib` directly. That is MoltenVK **1.2.10** (`VK_EXT_metal_objects`,
  timeline semaphores, Vulkan 1.2.290). The FEX runner also has `lib/aarch64/libMoltenVK.dylib`.
- There is no Vulkan loader in the process, and it must stay that way: the bridge must not load a second MoltenVK.

Per-game selection:
- `run` accepts `CX_GRAPHICS_BACKEND=dxmt|dxvk|wined3d` from the environment, so the Steam launch option
  `CX_GRAPHICS_BACKEND=dxvk %command%` switches one game.
- The `defaults-<flavor>` files can also set it, but those are per tool flavor, not per game.
- *Verified:* setting the variable in the environment switches the scratch prefix to DXVK.
- The prefixes' system32 only hold Wine placeholder DLLs. NotProton stages its own builtins (lsteamclient) into the
  runner's `lib/wine/<arch>-windows|unix`, plus a placeholder in `syswow64`.

## 3. Loading the unix side

Wine 11.17 rules, from `dlls/ntdll/unix/loader.c` and `virtual.c`:
- A builtin PE found at `<dllpath>/x86_64-windows/foo.dll` gets `<dllpath>/x86_64-unix/foo.so` as its unixlib. If found
  at `<dllpath>/foo.dll`, the unixlib is the `.so` in the same directory.
- `NtQueryVirtualMemory(module, MemoryWineLoadUnixLib = 1000)` returns the `__wine_unix_call_funcs` table. Calls go
  through ntdll's exported `__wine_unix_call_dispatcher`.
- Wine only looks for a builtin in the DLL path once a placeholder of the same name exists in `system32`, or the DLL is
  already known.
- The PE has to carry the builtin marker (`winebuild --builtin`). It doesn't have to link winecrt0; the probe does the
  two calls itself.

Options:

| Option | Verdict |
|---|---|
| **A. Own builtin `wineopenxr.dll` + `wineopenxr.so`** | **Recommended.** *Verified* in NotProton's runner from our own directory. Changes nothing in CrossOver. The name `wineopenxr.dll` matters: DXVK's `DxvkXrProvider` loads that DLL and calls `__wineopenxr_GetVulkanInstanceExtensions`/`DeviceExtensions` to add the runtime's extensions to the VkInstance/VkDevice it creates. |
| B. Piggyback on winevulkan/winemetal unix tables | No. It means replacing CrossOver files, and there is no extension point. |
| C. Native PE talking Mach/IOSurface directly | Impossible. PE code can't make Mach or Objective-C calls. |
| D. Out-of-process helper (Windows or native) | No. It needs an extra hop for every frame and pose, plus handle passing. That is exactly what the unixlib avoids. |

ABI to match:
- Wine's unixlib protocol: an `NTSTATUS (*)(void *)` table plus the dispatcher, stable since Wine 7. The value 1000
  was called `MemoryWineUnixFuncs` before.
- Winevulkan's handle layout (`include/wine/vulkan_driver.h`, `struct vulkan_client_object` and
  `VULKAN_OBJECT_HEADER`). The bridge validates it at runtime with the ICD magic check (§4).
- Only 64-bit games: no `__wine_unix_call_wow64_funcs`.

Install:
- Dev / M2: `WINEDLLPATH=<bridge root>:…`, a placeholder copy in the prefix's system32, then the runtime registration:
  - `HKLM\Software\Khronos\OpenXR\1\ActiveRuntime` = `C:\windows\system32\wineopenxr.json`;
  - that json's `library_path` points at `wineopenxr.dll`.
- M4: NotProton stages the files like lsteamclient. That is a NotProton change the user makes; we only provide the files
  and the list.
- Rosetta (x86_64 Wine) pairs `lib/wine/x86_64-windows/wineopenxr.dll` with `lib/wine/x86_64-unix/wineopenxr.so`.
  FEX (arm64 Wine, arm64ec ntdll + `xtajit64.dll`) doesn't: it finds the x86_64 PE only through NotProton's flat
  WINEDLLPATH entry `lib/wine/x86_64-windows` and takes the unixlib from that same dir
  (`load_builtin_unixlib failed to load ".../x86_64-windows/wineopenxr.so"` with `+module`); a structured
  `<dir>/x86_64-windows` + `<dir>/aarch64-unix` pair isn't found either. NotProton stages its own lsteamclient the
  same way (x86_64 dll + arm64 .so flat in the prefix's Steam dir). So the same universal `.so` goes to both
  `x86_64-unix/` and `x86_64-windows/`; dyld picks the slice, and x86_64 Wine finds the `x86_64-unix` pair first.

### Loading by full path, without WINEDLLPATH (tested 2026-10-26)

Can a runtime JSON name the bridge by full `Z:\` path so WINEDLLPATH isn't needed? **No.** Runner 27.0.0.41073, scratch
prefix `~/Library/Application Support/macvr-test/pathtest` (no system32 placeholder, no ActiveRuntime), test
`xr_path_test.exe` (static Khronos loader: enumerate extensions, `xrCreateInstance`; or `direct <dll>`), `WINEDEBUG=+loaddll,+module`.

| Setup | Result |
|---|---|
| library_path `Z:\…\bridge\x86_64-windows\wineopenxr.dll` or `x86_64-windows\wineopenxr.dll` (relative to the JSON), WINEDLLPATH=`…\bridge` | PE `builtin`, unix init ran (`wineopenxr: runtime …/x86_64-unix/libopenxr_monado.dylib, … ipc-stamp match`), 49 extensions, `xrCreateInstance` = −51 (client: no socket). **No system32 placeholder needed.** |
| Same, no WINEDLLPATH entry | `find_builtin_dll looking for "wineopenxr.dll" … cannot find builtin library`, then the file is mapped and reported `builtin`, but there is no unixlib (`no unixlib`) |
| `.so` (and client) copied next to the `.dll`, no WINEDLLPATH | same, no unixlib |
| PE without the builtin marker, with or without WINEDLLPATH | loaded `native`, no unixlib |
| library_path `wineopenxr.dll` (bare), WINEDLLPATH, no placeholder | loader: `Failed to open dynamic library wineopenxr.dll … File not found` |
| `XR_RUNTIME_JSON` (Windows or unix path) | ignored by the loader: `Environment variable XR_RUNTIME_JSON is being ignored due to running from an elevated context`. Wine's token is high integrity; `PlatformUtilsGetSecureEnv` drops it. Only the registry `ActiveRuntime` works. |

Why: ntdll records a builtin's unixlib path only in `find_builtin_dll` (unix `loader.c`), which searches the dll paths
(the runner's `lib/wine` plus WINEDLLPATH) for the base name and pairs `<dir>/x86_64-windows/foo.dll` with
`<dir>/x86_64-unix/foo.so` (or a flat `<dir>/foo.so`). An explicit path goes through that search first. If it misses,
the file is mapped directly: it's flagged builtin but has no `.so`, so `MemoryWineLoadUnixLib` fails. A hit in the dll
path wins over the named file. ntdll.so has no other dll-path knob (only `WINEDLLPATH`).

So the unixlib needs a WINEDLLPATH entry (or files in the runner). The MacVR app now adds `wineopenxr.dll`/`.so` to the runners ([macvr-app.md](macvr-app.md)), and the `.so` loads the client from `~/Library/Application Support/macvr/current/bridge/x86_64-unix/` when there is none beside it. The registry key, not an env var, picks the runtime.
Recommended layout, `~/Library/Application Support/macvr/bridge/`: `x86_64-windows/wineopenxr.dll`,
`x86_64-unix/{wineopenxr.so,libopenxr_monado.dylib,ipc-stamp}`, `wineopenxr.json` with
`"library_path": "x86_64-windows\\wineopenxr.dll"`. Per prefix: `HKLM\SOFTWARE\Khronos\OpenXR\1\ActiveRuntime =
Z:\Users\<user>\Library\Application Support\macvr\bridge\wineopenxr.json`, and that directory in WINEDLLPATH (NotProton's
`run` appends env WINEDLLPATH after its own dirs). No system32 copy is needed.

Bridge bug found here (fixed 2026-10-26): without a unixlib, `wine_xrGetInstanceProcAddr` returned
`XR_ERROR_FUNCTION_UNSUPPORTED` for the global functions too, and the static loader called a NULL
`xrEnumerateInstanceExtensionProperties` (page fault at 0). Now `xrEnumerateInstanceExtensionProperties`,
`xrEnumerateApiLayerProperties` (now PE-side, `PE_MANUAL`) and `xrCreateInstance` are always handed out and return
`XR_ERROR_RUNTIME_UNAVAILABLE` when the runtime isn't usable. Retest with `xr_path_test.exe`: no unixlib → enumerate
returns 0 (the loader's own extension only), `xrCreateInstance` −51, no crash; with WINEDLLPATH → 49 extensions,
`ipc-stamp match`, −51 (no socket in the scratch rt dir). `ovr_d3d11_test.exe` through OpenComposite with no unixlib: `VR_Init`
108, no crash.

## 4. Interop: IOSurface swapchains as D3D11 textures

```
game D3D11 ──DXVK──▶ VkDevice (winevulkan client handle) ──unwrap──▶ host VkDevice (CrossOver MoltenVK 1.2.10)
                                                                       ▲
Monado client compositor (in wineopenxr.so) imports service IOSurface ─┘  → host VkImage (unwrapped, passes through)
PE: IDXGIVkInteropDevice1::CreateTexture2DFromVkImage(desc, VkImage) → ID3D11Texture2D handed to the game
```

- **Unwrapping:** a PE `VkInstance/VkPhysicalDevice/VkDevice/VkQueue` points at
  `struct vulkan_client_object { u64 loader_magic; u64 unix_handle; }`. `unix_handle` points at a struct that starts
  with `vulkan_object.host_handle`.
  - So `host = *(u64 *)((u64 *)pe)[1]`, read on the unix side (same address space).
  - Check that `*(u64 *)host == 0x01CDC0DE` (MoltenVK's dispatchable-object magic) and refuse otherwise. That catches a
    future layout change.
  - Non-dispatchable handles that DXVK sees (`VkImage`, `VkFormat` values) are host handles unchanged. `VkSemaphore`,
    `VkFence`, `VkDeviceMemory` and `VkCommandBuffer` are wrapped, but the bridge never hands those to PE code.
  - Proton's wineopenxr does the same unwrapping through Proton-only `__wine_get_native_*` exports. CrossOver's
    winevulkan exports none of them; `winevulkan.so` exports only its call tables.
- **Function pointers:** take `vkGetInstanceProcAddr` from the MoltenVK image that is already loaded: find it with
  `_dyld_get_image_name`, then `dlopen(path, RTLD_NOLOAD)`. Never use the Vulkan loader or a second MoltenVK.
- **Extensions:**
  - MoltenVK honours `VkImportMetalIOSurfaceInfoEXT`/`VkImportMetalSharedEventInfoEXT` even when `VK_EXT_metal_objects`
    isn't enabled on the device (*verified*: DXVK's enabled list doesn't have it).
  - winevulkan would reject that extension name in vkCreateDevice. So the bridge's
    `__wineopenxr_GetVulkan*Extensions` and `xrGetVulkan*ExtensionsKHR` drop host-only names: `VK_EXT_metal_objects`,
    `VK_KHR_portability_*`, `*_fd`.
  - Monado already assumes `has_EXT_metal_objects` on Apple (`vk_bundle_init.c`).
- **Wrapping:**
  - `CreateTexture2DFromVkImage` with `D3D11_TEXTURE2D_DESC1` (Usage DEFAULT, BindFlags RT|SRV, plus UAV if requested).
  - DXVK treats the image as `VK_IMAGE_LAYOUT_GENERAL` from `UNDEFINED`. Layouts are no-ops on Metal, and Monado's
    acquire/release barriers stay valid Vulkan.
  - Format map, DXGI ↔ Vulkan: only what Monado offers on macOS (RGBA8/BGRA8 ± sRGB, RGBA16F, RGB10A2,
    R32F, R5G6B5). `*_TYPELESS` app formats map to the UNORM image with `MUTABLE_FORMAT`; check this against DXVK view
    creation.
- **Limits to plan for:**
  - Monado on macOS refuses depth swapchains and `arraySize > 1` (IOSurface).
  - Many D3D11 OpenXR engines (Unity single-pass, UE) ask for one 2-layer array or a depth swapchain for
    `XR_KHR_composition_layer_depth`.
  - Fix in Monado (D1 amendment): those images are `MTLSharedTextureHandle` ports with a kind tag, imported
    with `VkImportMetalTextureInfoEXT`. *Verified* (spikes/bridge `metal_texture_import.m`): CrossOver's MoltenVK
    1.2.10 on DXVK's device (no `VK_EXT_metal_objects` enabled) and Homebrew 1.4.2 import shared-handle textures
    through a Mach port round trip, 2-layer BGRA8/sRGB arrays and D32 (single and 2-layer); Vulkan clears land in the
    exporter's texture. The SDK's 1.2.11 (x86_64) passes too.
  - **Decision (step 5): the bridge fallback now, the Monado kind later.** The bridge splits array swapchains into
    per-slice host swapchains (one `CopySubresourceRegion` per slice at release) and keeps depth swapchains local.
    It is D3D11-only and PE-side, and changes nothing for native apps. The Monado kind would advertise depth formats
    to every client (native hello_xr would start submitting depth layers in the WiVRn headset tests) and touches
    allocation, IPC import, the service compositor and the frame dump, which overlaps with the WiVRn work in progress.
    It becomes worth it for zero-copy arrays (UE/Unity single-pass at full resolution) or depth-based reprojection.
    Measured cost of the fallback at 320×240×2: release with 2 slice copies p50 0.18–0.28 ms, `xrEndFrame` with the
    layer rewrite p50 0.10–0.15 ms.
- **Native Vulkan games** (XR_KHR_vulkan_enable/2 through winevulkan): same unwrap, no DXVK. Images pass through as
  VkImage. The game's own queue submissions need no lock, but the extension-list filtering still applies.

## 4a. DXMT sessions (stock DXMT, no CrossOver patch)

Chosen per game with `CX_GRAPHICS_BACKEND=dxmt`. The PE side tries DXVK's `IDXGIVkInteropDevice1` first; if that QI
fails it probes for DXMT (a 16×16 shared texture whose D3DKMT runtime data names a `DXMT_shared_resource_*` port).

```
game D3D11 ─DXMT─▶ MISC_SHARED_KEYEDMUTEX texture (MTLSharedTexture, port registered in bootstrap by DXMT)
   gdi32 D3DKMTQueryResourceInfo/OpenResource2 → texture port name; D3DKMTOpenKeyedMutex2 → MTLSharedEvent port name
unix: bootstrap_look_up → initWithMachPort/newSharedTextureWithHandle → VkImportMetalTextureInfoEXT (bridge VkDevice)
      MTLSharedEvent → VkImportMetalSharedEventInfoEXT timeline semaphore
release: vkCmdCopyImage (wait V, signal V+1) → Monado's IOSurface image → host xrReleaseSwapchainImage (same queue)
```

- **Vulkan device:** the unix side creates its own instance/device on CrossOver's MoltenVK 1.2.10 (Vulkan 1.2,
  timeline semaphores, Monado's extensions filtered by what MoltenVK has, `VK_EXT_metal_objects`) and binds the session
  with those host handles (`create_session_params.host_handles`). MoltenVK is loaded from win32u's rpath
  (`lib/wine/x86_64-unix/../../../lib/x86_64`) when DXMT hasn't loaded it, so a later winevulkan load gets the same image.
  A per-session critical section plays the role of DXVK's submission lock.
- **Swapchains (`SWAPCHAIN_COPY`):** one host swapchain per slice (`TRANSFER_DST` added) and one DXMT texture per image
  (full array size). Depth stays bridge-local as before. Layers are rewritten like split swapchains.
- **Sync:** at acquire the bridge calls `IDXGIKeyedMutex::AcquireSync(0)` (DXMT encodes a GPU wait on the event). At
  release: `ReleaseSync(1)` (GPU signal V), `D3DKMTAcquireKeyedMutex(key 1)` → V, the copy waits for V on the GPU and
  signals V+1, then `D3DKMTReleaseKeyedMutex(key 0, V+1)`. No CPU wait on the game thread. `WINEOPENXR_DXMT_SYNC=cpu`
  uses `MISC_SHARED` + an event-query spin instead.
- **DXMT without keyed mutex (CrossOver 26.3, DXMT v0.72; 2026-10-29):** `SharedResourceData` ends before
  `mutex_handle` (108 bytes). The bridge accepts that size and uses fence sync: at release the game thread signals a
  local `ID3D11Fence` (`ID3D11DeviceContext4::Signal`, which flushes), and the copy waits for it on the CPU
  (`SetEventOnCompletion`) in the async worker, which is on by default (mode 2) in this mode. Alyx: 83 fps on 26.3
  vs 36 with the old event-query spin on the game thread; the keyed-mutex path stays at 89-90.
- **What it relies on in DXMT (read, not changed):** `SharedResourceData` starts with the 54-byte port name and ends with
  the keyed-mutex KMT handle (size checked at runtime); the keyed mutex's runtime data is the event's port name. Both are
  what DXMT's own `OpenSharedResource` reads, so they move only together with DXMT's cross-process sharing.
- **Not used:** shared `ID3D11Fence` (DXMT publishes its name with a Wine D3DKMT escape that fails on CrossOver, spike
  §3); server-allocated MTLSharedTexture opened by DXMT (needs faked runtime data and a server change). Zero copy would
  need a Monado `MTLSharedTextureHandle` buffer kind with client-side import (IPC `swapchain_import`).
- **Deferred copy (2026-10-25):** the release does only `IDXGIKeyedMutex::ReleaseSync(1)`. The D3DKMT acquire (key 1
  → fence V), the copy, the host release and the D3DKMT release (key 0, V+1) run at `xrEndFrame`, limited to the union
  of the imageRects the layers show (+2 px). They also run at the swapchain's next acquire or destroy, then with a
  full copy. `WINEOPENXR_DXMT_DEFER=0` copies at release, as before. Wine's D3DKMT keyed mutex must be released by the
  thread that acquired it (a release from another thread fails), so the D3DKMT acquire and release sit together.
- **Async xrEndFrame (2026-10-25, `WINEOPENXR_ASYNC`, default 0 = off):** a per-session worker thread (PE side, so the
  D3DKMT and unix calls stay as they are) runs xrEndFrame's copies, host releases, D3DKMT releases and the host
  `xrEndFrame`, in that order. The frame thread keeps the `ReleaseSync`, copies the frame (layers, views, the copy
  rects) into one job and returns. Ordering: one job at a time; `1` makes the next `xrWaitFrame` wait for it, `2`
  only the next `xrBeginFrame` (the host `xrWaitFrame` may run beside the worker's `xrEndFrame`, which the spec
  allows); acquire, swapchain destroy, `xrEndSession` and session destroy also wait. That wait is for the worker's
  CPU work only: the GPU order still comes from the keyed mutex's fence values (the game's next `AcquireSync(0)`
  waits for V+1 on the GPU). Frames whose structs carry `next` chains the job can't copy fall back to the synchronous
  path. A failed host `xrEndFrame` is returned by the next one. `WINEOPENXR_ASYNC_RELOAD=1` (tests) re-reads
  `WINEOPENXR_ASYNC` from `wineopenxr.env` every 300 frames, so modes can be compared within one session.
  Result in Alyx (docs/ab-alyx.md, "Bridge render-thread cost"): the bridge's frame-thread time drops from 0.7 to
  0.4 ms per frame, with no change in fps, 1% low or spikes, so it stays off.
- **Stats:** `WINEOPENXR_STATS=1` logs, per 300 frames, mean/p99/max of each part on the frame thread (`wait`,
  `drain`, `begin`, `acquire`/`acq_sync`, `wait_img`, `release`, `end`, `bridge` = the bridge's frame-thread total) and
  inside the copy (`kmt_acq`, `copy` = the unix call, `fence`/`submit` inside it, `host_rel`, `kmt_rel`, `host_end`),
  plus a worker line (`work`, `lag`). Frames over 6 ms are logged one by one. `=2` adds one line per frame
  (`F interval wait bridge`, `W work lag`) for `tools/mql-ab/bridgestats.py`.
- **Settings under NotProton:** its launcher forwards only some env prefixes, so the bridge also reads `WINEOPENXR_*`
  lines from `C:\macvr\wineopenxr.env` (the environment wins). `WINEOPENXR_LOG=<file>` sends messages to a file.
- **Cost** (M4 Max, hello_xr, 2 swapchains, `WINEOPENXR_STATS=1`): release avg 0.38–0.44 ms (keyed-mutex handoff 0.18,
  copy submit + host release 0.14, D3DKMT release the rest); CPU-wait mode 1.1 ms. Plus one GPU copy per image.
  In Alyx (72 Hz, 2 eye swapchains, sync mode): the bridge's frame-thread total is 0.7 ms mean, ~2 ms p99, 5–9 ms
  max per 30 s (acquire 0.3, `xrEndFrame` 0.3 of which host `xrEndFrame` 0.13, host releases 0.08–0.1, D3DKMT 0.06,
  copy unix call 0.02). The earlier "copy submit + host release 1.5–2.6 ms, max 11–16 ms" figure was measured from
  each eye's release to the end of `xrEndFrame`, so it included the game's own work in between.

## 5. Sync

The release path in Monado's client compositor (`comp_vk_client.c`):
- It submits its release command buffer on the app's queue.
- It then either submits a signal of the timeline semaphore (imported from the service's MTLSharedEvent, patch 0012) or,
  without timelines, a fence plus a CPU wait.
- With DXVK the app's queue is DXVK's queue, which DXVK's submission thread also uses.

The bridge therefore:
1. On `xrReleaseSwapchainImage`/`xrEndFrame`, calls `FlushRenderingCommands()` (immediate-context flush plus CS-thread
   sync) and then `LockSubmissionQueue()`. That one waits for DXVK's pending submissions.
2. Makes the host call. Monado submits after all of DXVK's work for the frame, so queue order guarantees the signal
   comes after rendering.
3. Calls `ReleaseSubmissionQueue()`.
4. Wraps every host call that can submit the same way: `xrAcquireSwapchainImage`, `xrReleaseSwapchainImage`,
   `xrEndFrame`, swapchain create/destroy. Proton's wineopenxr does the same.

Timeline semaphores:
- DXVK 1.10 enables `timelineSemaphore` when available (the log says `timelineSemaphore : 1`). Monado's vulkan_enable
  v1 path can't see that, so the bridge sets `OXR_DEBUG_FORCE_TIMELINE_SEMAPHORES=1` before loading the runtime, but
  only after checking the feature through the host `vkGetPhysicalDeviceFeatures2`.
- *Verified:* clear → flush → locked signal takes 0.018 ms on the CPU (p50). The MTLSharedEvent is done 0.15 ms p50 /
  0.47 ms p99 later.
- The CPU-wait fallback (`MONADO_MACOS_SYNC=cpu`) still works, but it blocks the game's thread inside the lock.

## 6. Bridge architecture

**(a) wineopenxr-style thunk (recommended).**
- `wineopenxr.dll` exports `xrNegotiateLoaderRuntimeInterface` and the two DXVK hooks. Its `xrGetInstanceProcAddr`
  returns thunks generated from `xr.xml` (openxr-sdk 1.1.65), in the style of Proton's `make_openxr`.
- `wineopenxr.so` dlopens our `libopenxr_monado.dylib` (IPC client, built from this tree) and negotiates with it
  directly. There's no host OpenXR loader.
- Most calls are 1:1 struct thunks. 64-bit only, so the layouts are identical and only handles and graphics structs
  need converting.
- The bridge implements these itself:
  - **XR_KHR_D3D11_enable:**
    - `xrGetD3D11GraphicsRequirementsKHR`: the adapter LUID comes from the host `VkPhysicalDeviceIDProperties` or from
      the DXGI adapter DXVK uses. Feature level 11_0.
    - Session create: `XrGraphicsBindingD3D11KHR.device` → QI `IDXGIVkInteropDevice1` → `GetVulkanHandles` +
      `GetSubmissionQueue1` → unwrap → `XrGraphicsBindingVulkanKHR`.
    - Swapchains: the host creates them, the PE side wraps the images, and `xrEnumerateSwapchainImages` returns
      `XrSwapchainImageD3D11KHR`.
  - **XR_KHR_win32_convert_performance_counter_time:**
    - Wine's QPC on macOS is `mach_continuous_time` in 100 ns ticks (10 MHz, from `dlls/ntdll/unix/sync.c`).
    - Monado's XrTime is `clock_gettime(CLOCK_MONOTONIC)` in ns (`os_time.h`), and that clock also runs during sleep.
    - Convert on the unix side by sampling both clocks in the call.
    - Check NotProton's patched ntdll and CrossOver for a different QPC source in step 4.
  - Extension list: advertise D3D11_enable, vulkan_enable/2 and win32_convert. Hide `XR_KHR_convert_timespec_time`
    and `XR_KHR_metal_enable`.
- **Threading:** unix calls run on the game's calling thread, which is fine for Monado's synchronous IPC client. Monado's
  own threads (if any) are plain pthreads that never enter PE code. No wineserver is involved per frame. The poses
  (`xrLocateSpace`, `xrLocateViews`) are plain struct copies.
- **IPC:** the Monado client in the game process does the 16-byte `'MVRM'` nonce preamble and the bootstrap HELLO itself.
  - The bootstrap lookup works from Wine processes (DXMT's shared resources and the probe both use the namespace).
  - Socket path: `confstr(_CS_DARWIN_USER_TEMP_DIR)`, so `TMPDIR`/`XDG_RUNTIME_DIR` from Wine don't matter unless set.
    The bridge clears `XDG_RUNTIME_DIR` before loading the runtime.
  - The service must run in the GUI login session that Steam runs in (bootstrap namespace).
  - Wire-protocol coupling: the bridge's runtime build and the service must come from the same patch series, because
    the protocol is macOS-only.
- Monado patch (done, 0014): `oxr_session_gfx_vk.c` and `oxr_api_system.c` called the **linked**
  `vkGetInstanceProcAddr` (the Vulkan loader); `vk_bundle_init.c` already takes it as a parameter.
  - In the game process that would load the SDK loader and call it with MoltenVK-created handles, which crashes.
  - `oxr_vk_get_instance_proc_addr()`: on Apple, if `XRT_VK_GIPA_LIBRARY` is set, dlopen that already-loaded image
    with `RTLD_NOLOAD` and use its `vkGetInstanceProcAddr`; otherwise `dlsym(RTLD_DEFAULT)`, then
    `libvulkan.1.dylib`. Other platforms keep the linked symbol. Native clients are unchanged (re-checked: arm64
    hello_xr out-of-process).
  - The same patch drops the `vkExportMetalObjectsEXT != NULL` check on the client's MTLSharedEvent import (from
    0012): DXVK's device doesn't enable `VK_EXT_metal_objects`, so the check forced the CPU-wait path although the
    import works.
  - With no reference to the loader left, the bridge flavor links with `-dead_strip_dylibs` and has no
    `libvulkan` dependency.

**(b) Custom runtime DLL whose unix side links Monado's IPC client directly** (`ipc_client` + `comp_vk_client`, no
state tracker):
- Rejected. It would reimplement the OpenXR state tracker: spaces, actions, sessions, frame timing: about 21 k lines of `state_trackers/oxr`.
- (a) gets all of that from `libopenxr_monado` unchanged.
- Both share the hard parts anyway: interop, sync, time and IPC.

## 7. M2 steps

| # | Step | Done when | Status |
|---|---|---|---|
| 1 | Monado patch: GIPA override (§6). Build x86_64 `libopenxr_monado` (bridge flavor). Extend the probe so `vkprobe.so` loads it, creates an XrInstance/session on DXVK's unwrapped device against a running `monado-service`, creates a swapchain and wraps it in D3D11. | The probe renders a D3D11 clear into a Monado swapchain; `XRT_COMPOSITOR_NULL_DUMP` PNG shows the colour. | Done (patch 0014, `bridge-step1.png`) |
| 2 | `wineopenxr` skeleton: builtin PE + unixlib, make with llvm-mingw + clang. Thunk generator from `xr.xml`. Negotiation, instance/system/session lifecycle, spaces, views, actions. | Khronos `hello_xr.exe` (Windows build, `-g Vulkan2`) runs in the scratch prefix, through winevulkan. | Done (`-g Vulkan` too) |
| 3 | XR_KHR_D3D11_enable over vulkan_enable + DXVK interop, the submission-lock wrapping, and the extension-list filtering. | `hello_xr.exe -g D3D11` in the scratch prefix with `CX_GRAPHICS_BACKEND=dxvk`: cubes in the dumped frame, GPU sync on (sync-stats). | Done |
| 4 | Time conversion (QPC ⇄ XrTime), measured against a game-like loop. Check NotProton's patched ntdll for its QPC source. | Predicted display time converts both ways within 1 µs. | Done (exact round trip; QPC = `mach_continuous_time`) |
| 5 | Array/depth swapchains: Monado `MTLSharedTextureHandle` kind + `VkImportMetalTextureInfoEXT` on MVK 1.2.10, or the bridge copy fallback. | `hello_xr.exe` with a 2-layer swapchain and a depth layer renders. | Done with the bridge fallback (`xr_array_test.exe`; hello_xr can't do arrays). MVK import verified for later. |
| 6 | FEX flavor: aarch64 `.so` + arm64 runtime, PE as x86_64 (or arm64x). | Step 3 passes on `notproton-fex-41073`. | Done 2026-10-28 (§7a): universal `.so` + client, x86_64 PE; DXMT only (no arm64 DXVK in the runner); Alyx runs |
| 7 | Install recipe for a real game prefix (only with the user's go-ahead), then one OpenXR D3D11 title in the headset through WiVRn. | User check. | Open |

## 7a. FEX flavor (step 6, 2026-10-28)

Build: `scripts/build-wivrn.sh --client-x86_64` and `--client-arm64` (same WiVRn tree and Monado snapshot, so both
write the same ipc-stamp; `-dead_strip_dylibs`, no `libvulkan`), then `scripts/build-bridge.sh bridge`: clang builds
`wineopenxr.so` with `-arch x86_64 -arch arm64`, the client is `lipo -create` of the two (`build/bridge/root/x86_64-unix/`),
and the make refuses if the two clients' stamps differ. The stamp is a text file next to the client, so the check is the
same for either slice. Source changes: the `.so` loads CrossOver's MoltenVK from `lib/<x86_64|aarch64>` per slice and
the IPC client always from `macvr/current/bridge/x86_64-unix/`. `scripts/build-bridge.sh monado-arm64` builds the
standalone arm64 client for the `monado-service` rig.

Run: `FEX=1 RUNNER_MODE=1 RUNNER_DIR=<runner copy with MacVR's runner files> BRIDGE_ROOT=<macvr/current/bridge>
scripts/run-bridge.sh ...` (arm64 `wine.app` + `wineserver-arm64`, the `aarch64-unix` template, `FEX_X87REDUCEDPRECISION=1`
as NotProton sets it). `RUNNER_MODE=1` reproduces MacVR's install (no system32 copy, ActiveRuntime by `Z:` path, only the
runner dirs on WINEDLLPATH); FEX needs it, see §3. Wine prefixes, roots and runner copies under
`~/Library/Application Support/macvr-test/` (never `~/Documents`).

Results (runner clones, `build/logs/bridge-*-fex*`, `bridge-hello_xr-universal-*.log`):
- FEX, monado-service rig: hello_xr `-g D3D11` on DXMT (cubes, `bridge-hello_xr-d3d11-dxmt-fex.png`), `-g Vulkan2` and
  `-g Vulkan`, `xr_time_test` (round trip exact, calibration ±50 ns, QPC − `mach_continuous_time` −58 ns),
  `xr_array_test` on DXMT: all pass, 0 errors, timeline-semaphore sync. `CX_GRAPHICS_BACKEND=dxvk` has no effect on
  FEX: the runner's `lib/dxvk` has no arm64 build, so d3d11 is wined3d and the bridge reports "neither DXVK nor DXMT".
  `lib/dxmt` has `aarch64-windows`/`aarch64-unix`.
- Through WiVRn (universal client, `ipc-stamp match`), hello_xr D3D11/DXMT at 90 Hz in all three modes: FEX (arm64
  slice, `lib/aarch64/libMoltenVK.dylib`), fex-rosetta and preview (x86_64 slice, `lib/x86_64`).
- Half-Life: Alyx on each tool (`lsof`): FEX maps `x86_64-windows/wineopenxr.so` (arm64 slice) and
  `lib/aarch64/libMoltenVK.dylib`; both Rosetta tools map `x86_64-unix/wineopenxr.so` (Rosetta AOT of the x86_64 slice).

Alyx, FEX vs Rosetta (`tools/mql-ab/m2prun.sh`, `build/wivrn-m2p` stock estimator, s6/steamvr_quit, 90 Hz, fidelity 3,
controllers asleep, gate passed every run, 40 W charger, 100→90 %, no screen sharing; build 25487405; hlvr CPU = `top`
of hlvr.exe over the 30-s window, 100 % = one core; raw `build/lat/{fex-stock*,ros-stock*,uni-*}`):

| | game fps | app CPU (xrWaitFrame→xrEndFrame) p50 / p95 | hlvr CPU | overlay M2P mean | safe p50 | app-limited frames |
|---|---|---|---|---|---|---|
| FEX `fex-stock1` | 88.8 | 2.8 / 11.1 | 400 % | 70.9 | 27.2 | 408 / 2673 |
| FEX `fex-stock2` | 89.8 | 2.8 / 4.5 | 397 % | 63.1 | 23.8 | 10 / 2703 |
| FEX `fex-stock3` | 89.5 | 2.6 / 4.0 | 390 % | 63.8 | 23.0 | 8 / 2694 |
| FEX `uni-fex` (universal build) | 89.5 | 2.9 / 5.2 | 387 % | 68.2 | 24.1 | |
| **FEX mean** | **89.4** | **2.8 / 6.2** | **394 %** | **66.5** | **24.5** | |
| fex-rosetta `ros-stock1` | 87.5 | 4.0 / 11.4 | 436 % | 76.4 | 27.5 | 1140 / 2635 |
| fex-rosetta `ros-stock2` | 83.9 | 6.4 / 11.4 | 482 % | 78.5 | 32.0 | 182 / 2536 |
| fex-rosetta `ros-stock3` | 89.0 | 3.2 / 5.3 | 443 % | 67.0 | 23.9 | 39 / 2682 |
| fex-rosetta `uni-fexrosetta` | 88.0 | 4.2 / 11.4 | 451 % | 79.9 | 34.3 | |
| **Rosetta mean** | **87.1** | **4.5 / 9.9** | **453 %** | **75.5** | **29.4** | |
| preview `uni-preview` | 87.6 | 5.2 / 11.5 | 442 % | 72.6 | 27.9 | |
| earlier Rosetta `mac-stock7` / `mac-hevc1` ([linux-comparison.md](linux-comparison.md)) | 87.4 / 87.2 | 4.1 / 11.0, 3.8 / 11.5 | | 86.0 / 78.9 | 28.8 / 27.0 | 1039 / 575 |

FEX is ahead on the CPU side in every pairing: −1.7 ms app CPU p50, a p95 that mostly stays at 4-5 ms instead of
11 ms, −13 % hlvr CPU, +2.3 fps. `safe` (encode/network/decode tail) moves 23-34 ms from run to run on both and drives
most of the M2P spread, so the M2P gap (−9 ms mean) is partly the network, not FEX.
Alyx's current build 26227071 (1-2 fps on Rosetta, [linux-comparison.md](linux-comparison.md)) runs normally on FEX:
`fex-26227071` 89.4 fps, app CPU 2.7 / 4.2, hlvr 393 %, M2P 66.9, safe 24.4. The game files were swapped back to
25487405 afterwards (copies of both sets in `~/Library/Application Support/macvr-alyx-rollback/`).

Switching a game between tools: NotProton refuses an x86_64 prefix on FEX (and the reverse) and offers a prefix
rebuild. For these tests the Rosetta prefix was moved aside (`compatdata/546560.rosetta-20261028`) and NotProton made a
fresh prefix from the matching template; `macvr rescan` then wrote the VR values (a rebuilt template loses them until
the next rescan or app open). A real switch is NotProton's "Rebuild Prefix" plus a MacVR rescan.

## 8. Risks

- **Winevulkan layout** is internal to Wine. The magic check makes a mismatch fail safely, not crash. CrossOver
  upgrades can still break it, so re-run the probe on every new runner.
- **Lock coverage:** a host call that submits on DXVK's queue outside `Lock/ReleaseSubmissionQueue` races DXVK's
  submission thread. That would show up as rare validation errors or MoltenVK crashes. Mitigation: wrap every host
  call that takes a swapchain or session.
- **MoltenVK 1.2.10 vs 1.4.2:**
  - The service uses Homebrew MVK 1.4.2. The game process uses CrossOver's 1.2.10.
  - IOSurface and shared-event imports work on 1.2.10 (*verified*). `VkImportMetalTextureInfoEXT` and multi-format
    views are not yet verified.
  - Two MoltenVKs in one process must never happen.
- **DXVK 1.10 limits:** it's the CodeWeavers fork, so DXVK-specific game bugs are CrossOver's. Some games may run better
  on DXMT in flat mode, so selection stays per game.
- **NotProton integration (M4)** needs NotProton to stage our files and a launch option or per-game default. Its
  defaults are per flavor today, so per-game backend selection needs a launch option or a NotProton feature.
- **Engines that need depth/array swapchains** depend on step 5.
- **32-bit VR games:** out of scope (no wow64 thunks).

## Appendix: DXMT findings (2026-10-24 spike)

Superseded by §4a for the texture path; DXMT is still not patched.
- DXMT's texture import goes through `MTLSharedTextureHandle initWithMachPort:`, which rejects IOSurface ports.
- A Monado-allocated MTLSharedTexture can be imported into stock DXMT. The bridge would fake DXMT's
  `SharedResourceData` in a local D3DKMT allocation and call `OpenSharedResource`; *verified*, including a 2-layer array.
- The matching fence path failed on the Wine D3DKMT escape. Both depend on DXMT internals and on wineserver objects at
  swapchain creation.
