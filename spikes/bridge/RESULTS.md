# Spike: M2 bridge feasibility (Wine/CrossOver side), results

Plan: [docs/bridge-plan.md](../../docs/bridge-plan.md). Run on 2026-10-24: M4 Max, macOS 27, NotProton runner
`crossover-27.0.0.41073-fex` in Rosetta mode (`x86_64-unix`, Wine 11.17-based), throwaway prefix `build/pfx`. The prefix is
an APFS clone of NotProton's `notproton-template`; no game prefix or runner file was touched.

```sh
make                                   # needs Homebrew mingw-w64, the Vulkan SDK headers in /usr/local, generated OpenXR headers
CX_GRAPHICS_BACKEND=dxvk EXTRA_DLLPATH=$PWD/build/root ./run-wine.sh build/dxvk_interop_test.exe
./build/handle_probe_arm64; ./build/handle_probe_x86_64
```

- `WINEBUILD` is `bridge/tools/mark-builtin.py`, which writes the same "Wine builtin DLL" signature as
  `winebuild --builtin` (an x86_64 winebuild started hanging in Rosetta).
- `run-wine.sh` sets up the same environment as NotProton's `run` script: `CX_ROOT`, `WINELOADER`, `WINESERVER`,
  `WINEDLLPATH`, `CX_HOME` and `CX_GRAPHICS_BACKEND`.
  - It copies the builtin PE into the scratch prefix's `system32`. Wine only searches `WINEDLLPATH` for a builtin once it
    finds a placeholder there.

## 1. `vkprobe/`: the D3D11 path on stock DXVK (the M2 design), ALL PASS

`vkprobe.dll` is a builtin PE built with mingw and marked with `winebuild --builtin`. `vkprobe.so` is its x86_64 Mach-O
unixlib. `dxvk_interop_test.exe` drives them.

| Check | Result |
|---|---|
| Builtin PE + unixlib from our own directory (`WINEDLLPATH=<root>`, with `<root>/x86_64-windows/vkprobe.dll` and `<root>/x86_64-unix/vkprobe.so`), plus a placeholder in system32 | PASS. The PE side calls `NtQueryVirtualMemory(..., 1000 = MemoryWineLoadUnixLib)` and ntdll's `__wine_unix_call_dispatcher`. winecrt0 isn't needed. |
| `CX_GRAPHICS_BACKEND=dxvk` selects CrossOver's DXVK | PASS. The log shows `DXVK: cxaddon-1.10.3-1-25-g737aacd`. dxgi stays Wine's ("Adapter is not a DXVK adapter", harmless). |
| `QueryInterface(IDXGIVkInteropDevice1)` on the D3D11 device | PASS |
| Unwrap winevulkan's dispatchable handles in the unixlib | PASS. The lookup is `host = *(u64*)(((u64*)pe_handle)[1])` (client object → `unix_handle` → `vulkan_object.host_handle`). All four host handles start with the ICD magic `0x01CDC0DE`. |
| MoltenVK in the process | CrossOver's `lib/x86_64/libMoltenVK.dylib` (1.2.10, Vulkan 1.2.290), dlopen'ed by win32u. The unixlib finds it with `_dyld_get_image_name` and dlsyms `vkGetInstanceProcAddr` (`RTLD_NOLOAD`). There's no second MoltenVK and no Vulkan loader. |
| IOSurface-backed `VkImage` on **DXVK's** host VkDevice (`VkImportMetalIOSurfaceInfoEXT`) | PASS, even though DXVK did **not** enable `VK_EXT_metal_objects`; MoltenVK honours the import struct anyway. |
| Timeline `VkSemaphore` imported from an `MTLSharedEvent` (`VkImportMetalSharedEventInfoEXT`) on the same device | PASS. DXVK 1.10 enables `timelineSemaphore` itself. |
| `CreateTexture2DFromVkImage` → `ID3D11Texture2D` (B8G8R8A8) | PASS |
| D3D11 `ClearRenderTargetView`, then `FlushRenderingCommands` → `LockSubmissionQueue` → unix-side `vkQueueSubmit` on DXVK's host queue that signals the timeline semaphore → `ReleaseSubmissionQueue` | PASS. The MTLSharedEvent reaches the value, and the IOSurface holds the cleared pixel exactly. |
| 200 frames: clear → flush → locked signal → CPU wait on the event → IOSurface read | All pixel-exact. Flush + locked submit takes p50 0.018 / p99 0.030 ms; GPU done after submit is p50 0.15 / p99 0.47 ms. The first frame takes 1.7 + 3.7 ms. |

## 2. `src/handle_probe.m`: Mach port kinds (native, arm64 and x86_64), ALL PASS

- An IOSurface Mach port (`IOSurfaceCreateMachPort`) is **rejected** by `-[MTLSharedTextureHandle initWithMachPort:]`
  (nil handle).
- A `MTLSharedTextureHandle` port is an IOSurface port (`IOSurfaceLookupFromMachPort` works). The surface is opaque,
  though: 0×0, pixel format 0, 8336 bytes for 64×32 BGRA. CoreVideo/VT can't use it.
- `newSharedTextureHandle` on an IOSurface-backed texture returns nil.
- Consequence: the two buffer kinds in the D1 amendment (IOSurface vs MTLSharedTextureHandle) can't stand in for each
  other, and each needs its own kind tag.

## 3. `src/dxmt_import_test.cpp`: stock DXMT (out of scope since the switch to DXVK)

This was written before the direction change. It is kept for reference only; DXMT is not patched and not planned.

- **Textures work.** The test creates a private `MTLSharedTexture` through winemetal exports and bootstrap-registers its
  port. It then builds a local D3DKMT allocation whose private runtime data mimics DXMT's own `SharedResourceData`. Stock
  `ID3D11Device::OpenSharedResource` then imports the texture: two imports alias the same storage, and a 2-layer array
  works too.
- **The fence path fails.** A Wine sync object takes `D3DKMT_ESCAPE_UPDATE_RESOURCE_WINE` with `STATUS_INVALID_PARAMETER`.
- It depends on DXMT internals, and wineserver objects are needed at swapchain creation.

## 4. M2 step 1 probe: `xr_probe_test.exe` (2026-10-24), ALL PASS

`vkprobe.so` also loads the bridge-flavour x86_64 `libopenxr_monado.dylib` (`VARBOR_OPENXR_RUNTIME`, Monado patch
0014, `XRT_VK_GIPA_LIBRARY` = the MoltenVK image win32u loaded) and drives it on DXVK's unwrapped handles against our
arm64 `monado-service` (null compositor). Run steps are in [docs/bridge-plan.md](../../docs/bridge-plan.md) §0.

- XrInstance → session → `xrBeginSession` on DXVK's device in 6 ms (57 ms cold). Monado's suggested-GPU UUID check
  falls back to GPU 0 (MVK 1.2.10 vs the service's 1.4.2 UUIDs differ); harmless on one GPU.
- The 3 swapchain images (IOSurface `VkImage`s) wrap with `CreateTexture2DFromVkImage`; D3D11 `ClearView`s
  render into them; release + `xrEndFrame` run inside `FlushRenderingCommands` + `Lock/ReleaseSubmissionQueue`.
- Sync is the timeline semaphore after a fix in 0014: 0012's client import refused when `vkExportMetalObjectsEXT`
  wasn't loaded, which is the case on DXVK's device (no `VK_EXT_metal_objects`).
- 90 frames: release + `xrEndFrame` p50 0.07–0.22 ms; with flush + lock p50 0.20–0.37 ms.
- `build/logs/bridge-step1.png`: orange left eye, blue right eye, white bar.

## 5. `src/metal_texture_import.m`: MTLSharedTextureHandle into MoltenVK (step 5 check), ALL PASS

A private-storage `MTLTexture` from `newSharedTextureWithDescriptor:`, its handle through a Mach port round trip
(`createMachPort` / `initWithMachPort:` / `newSharedTextureWithHandle:`), imported with `VkImportMetalTextureInfoEXT`
(plane 0) into `vkCreateImage`, cleared by Vulkan on the last layer, read back from the exporter's texture by a
Metal blit.

| MoltenVK | Device | BGRA8 2-layer | RGBA8 sRGB 2-layer | D32 | D32 2-layer |
|---|---|---|---|---|---|
| CrossOver 1.2.10 (x86_64, in Wine) | DXVK's, no `VK_EXT_metal_objects` | PASS | PASS | PASS | PASS |
| SDK 1.2.11 (x86_64, native under Rosetta) | own, no `VK_EXT_metal_objects` | PASS | PASS | PASS | PASS |
| Homebrew 1.4.2 (arm64, native) | own, no `VK_EXT_metal_objects` | PASS | PASS | PASS | PASS |

The Wine run is `xr_probe_test.exe mti` (`PROBE_METAL_TEXTURE` in `vkprobe.so`, under DXVK's submission lock); the
native one `build/metal_texture_import_arm64 /opt/homebrew/opt/molten-vk/lib/libMoltenVK.dylib`. For 1.2.11, run
`build/metal_texture_import_x86_64 /usr/local/lib/libMoltenVK.dylib`.
