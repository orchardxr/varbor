# Spike: cross-process frame sharing (IOSurface / MoltenVK / Mach) — results

Run with `./run.sh`. It builds everything, runs all cases and prints PASS/FAIL/XFAIL per case.
Logs go to `build/logs/`. Last run (2026-10-24, M4 Max, macOS 27): **203 PASS, 0 FAIL, 18 XFAIL**.
XFAILs are known limitations, documented below. They are not regressions.

Setup notes:
- Two MoltenVKs are installed:
  - Homebrew **1.4.2**: arm64 only.
  - LunarG SDK **1.2.11**: universal, at `/usr/local/lib`.
- **The loader picks the SDK 1.2.11 by default** (only `/usr/local/share/vulkan/icd.d` is on its search path).
  To get 1.4.2, set `VK_DRIVER_FILES=/opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json`. Monado/WiVRn launch scripts need the same.
- An x86_64 process under Rosetta can only use the SDK's universal 1.2.11.

| Program | Covers |
|---|---|
| `src/fmt_test.m` | Formats × {export, import}, NV12 variants, MTLSharedTextureHandle, 2-layer images, allocation benchmark. Each case runs in its own child process, because Metal asserts abort the process. |
| `src/bs_probe.c` | Bootstrap registration APIs for an unprivileged process. |
| `src/xproc_server.m` / `src/xproc_client.m` | Process A and process B. The client is built for both arm64 and x86_64. |

## 1. Formats (same results on arm64 with MVK 1.4.2 and on x86_64/Rosetta with MVK 1.2.11)

Image size is 250×130, so rows are padded (bpr ≠ w·bpe). Each check is listed below.

| Check | What it tests |
|---|---|
| xfer→surf | Vulkan copy, then read through IOSurface CPU lock. Pixel-exact. |
| surf→xfer | CPU write into the IOSurface, then Vulkan copy-out. Pixel-exact. |
| sampled | texelFetch, decoded. |
| color-att | Dynamic-rendering clear. |
| storage | imageStore. |

| Format | export (`VkExportMetalObjectCreateInfoEXT` + `vkExportMetalObjectsEXT`) | import (`IOSurfaceCreate` + `VkImportMetalIOSurfaceInfoEXT`) |
|---|---|---|
| R8G8B8A8_UNORM | PASS (all 5) | PASS (all 5) |
| R8G8B8A8_SRGB | PASS (all 5, storage too) | PASS |
| B8G8R8A8_SRGB | PASS | PASS |
| R16G16B16A16_SFLOAT | PASS | PASS |
| A2B10G10R10_UNORM | PASS | PASS |
| D32_SFLOAT | **XFAIL**: vkCreateImage succeeds, but the first use **aborts the process** (Metal assert "IOSurface texture: cannot create … depth"). | **XFAIL**, same abort. |
| 2-layer RGBA8 (multiview swapchain) | **XFAIL**: aborts ("IOSurface texture: must be MTLTextureType2D"). | n/a |
| D32 / 2-layer RGBA8 via **MTLSharedTextureHandle** | PASS: private shared texture → `createMachPort` → `initWithMachPort` + `newSharedTextureWithHandle` → `VkImportMetalTextureInfoEXT`. Pixel-exact, and also **cross-process into x86_64/Rosetta** (`reverse-sharedtex`). | |

Usage flags: color attachment, sampled, storage, transfer src and transfer dst are all supported on every
colour format. D32 has depth, sampled and xfer. MoltenVK creates the Metal texture lazily, so a bad combination
passes vkCreateImage and only dies on first use.

Export-created IOSurfaces have **pixelFormat 0** and use the deprecated `kIOSurfaceIsGlobal`. They work for
Vulkan/Metal, but CoreVideo/VT can't use them.

### NV12 (`G8_B8R8_2PLANE_420_UNORM`, MUTABLE_FORMAT|EXTENDED_USAGE, R8/RG8 plane views with `VkImageViewUsageCreateInfo(STORAGE)`)

| Case | Result |
|---|---|
| multiplanar **export** | XFAIL. MoltenVK builds the IOSurface with chroma element 2×2 and no plane bpr. IOSurface then computes a 128-byte chroma pitch, while Metal writes with 256. Rows land in the wrong place, there is no pixel format, and `CVPixelBufferCreateWithIOSurface` fails (-6680). |
| multiplanar import of a **standard** `420v`/`420f` IOSurface | XFAIL. `vkCreateImage` returns -3, because MoltenVK's `useIOSurface()` requires top-level bpe=6, element 2×2 and chroma-plane element 2×2. |
| multiplanar import of a **MoltenVK-compatible `420v` surface** (`surf_create_nv12(..., mvk_compat=true)` in `src/vkutil.m`) | **PASS**: per-plane transfer, **storage writes through R8/RG8 plane views**, `CVPixelBufferCreateWithIOSurface` (same base address, 125×65 chroma plane) and a **VTCompressionSession HEVC encode** of that buffer. The surface needs: top-level bpe 6 with 2×2 elements, chroma-plane element 2×2, and explicit plane bpr, offset and size plus `kIOSurfaceAllocSize`. |
| two images (R8 + RG8) via `VkImportMetalIOSurfaceInfoEXT` | XFAIL. That struct has no plane index. The R8 image imports (as plane 0), but RG8 fails the size check. |
| two images via Metal `newTextureWithDescriptor:iosurface:plane:` + `VkImportMetalTextureInfoEXT` | **PASS**: storage writes are pixel-exact, and the CVPixelBuffer and VT encode both work on a standard `420v` surface. |

## 2. Cross-process (A = arm64 server on MVK 1.4.2; B = arm64 on 1.4.2, **and x86_64 under Rosetta on 1.2.11**)

All of the following PASS for both client architectures.

**Bootstrap.**
- `bootstrap_check_in` works for an arbitrary name from an unprivileged, non-launchd process on macOS 27. So do `bootstrap_register` and `bootstrap_register2`. The server uses `check_in` because it is not deprecated.
- Registering a name that is already taken returns 1101.
- When the owning process dies, the name disappears (look_up returns 1102) and can be registered again.

**Handshake.**
1. B calls `bootstrap_look_up`.
2. B sends HELLO: its reply port (MAKE_SEND in the header) plus a nonce.
3. A replies with HELLO_ACK, carrying a per-client receive port.
4. A arms `MACH_NOTIFY_NO_SENDERS` on that port. It fired when B exited, which detects client death.

**Surfaces.**
- B sent 3 IOSurface ports plus the MTLSharedEvent port in **one OOL-ports descriptor**.
- A imported them (`IOSurfaceLookupFromMachPort` → `VkImportMetalIOSurfaceInfoEXT`).
- A verified **every frame pixel-exact**: 2×600 unpaced + 2×180 paced frames at 1024², 0 mismatches.
- In the reverse direction, the server exported and the client imported: pixel-exact. This is the direction Monado uses for swapchains.
- An imported surface keeps its contents after the client exits.

**Sync.**
- B side: timeline VkSemaphore + `VkExportMetalObjectCreateInfoEXT(SHARED_EVENT)` → `vkExportMetalObjectsEXT` → `[event newSharedEventHandle]` → `-[MTLSharedEventHandle eventPort]` (SPI).
- A side: `-[MTLDevice newSharedEventWithMachPort:]` (SPI) → `VkImportMetalSharedEventInfoEXT` timeline.
- **The GPU wait works across processes, with no CPU wait.** A submits wait-before-signal, and `vkQueueSubmit` returns in 0.03–0.6 ms. B signals 30 ms later. A's copy completes after 34–47 ms, and the pixels are the new frame. This held for all 5 frames on both client architectures.
- The public route does not work: `NSKeyedArchiver` refuses `MTLSharedEventHandle`. It only encodes through NSXPCCoder, which would need an NSXPCConnection.
- **Gotcha:** MoltenVK sets `signaledValue = initialValue` when it imports an event. The importer must pass the current `signaledValue` as `initialValue`, or it resets the client's timeline.

## 3. Measurements (medians; the machine had other build jobs running, so expect ±50 %)

| Item | Cost |
|---|---|
| `IOSurfaceCreate` 2048² RGBA / NV12 | 18 µs / 32 µs |
| vkCreateImage+alloc+bind+**export** 2048² | 19 µs |
| vkCreateImage+alloc+bind **import** | 0.5–2 µs (+ ~0.5 ms first submit: lazy MTLTexture creation + wake-up) |
| `IOSurfaceCreateMachPort` / `LookupFromMachPort` (same process) | 2.5 µs / 1 µs |
| `IOSurfaceLookupFromMachPort` cross-process 1024² | ~200–650 µs each (one-time) |
| Shared event SPI import + VkSemaphore | 9–27 µs |
| Mach PING/PONG round trip | 4–7 µs (arm64), 5–9 µs (Rosetta client) |
| FRAME message (slot + value) one-way at 90 Hz | 7–15 µs (arm64), 14–17 µs (Rosetta) |
| `mach_msg` send cost of FRAME | 0.5–2 µs (arm64), 0.7–5 µs (Rosetta) |
| Ring of 3, unpaced throughput | ~1300 fps through A, including A's per-frame CPU verify of 4 MB |

Paced at 90 Hz, from B's submit to A's copy being complete:

| Path | B blocked per frame | B submit → A copy done |
|---|---|---|
| CPU-wait (D3 M1: B waits on its fence, then sends) | 0.6–0.8 ms | ~0.8–1.1 ms |
| GPU-wait (shared timeline) | 0.04–0.12 ms | ~0.7–1.1 ms |

The GPU-wait path removes B's CPU stall. End-to-end latency is about equal for this small workload.

Per-frame overhead with ports sent once is effectively just one ~10 µs Mach message.

Timestamps across arm64/Rosetta must use `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` or `CLOCK_MONOTONIC` (Monado's `os_time` uses the latter, which is fine). Raw `mach_absolute_time` ticks differ, because the timebase is 125/3 on arm64 and 1/1 under Rosetta.

## 4. Recommendations

**D1: confirmed for colour swapchains, with two changes.**
1. **Allocate the IOSurface ourselves** (`IOSurfaceCreate` with a real pixel format and bpr), then **import** it. Don't rely on MoltenVK's export.
   - Import works for every colour format that export does.
   - It is the only working route for NV12, and the surface stays usable by CoreVideo/VT.
   - It avoids MoltenVK's deprecated `kIOSurfaceIsGlobal`.
   - Export stays a usable fallback for RGBA.
2. **IOSurface cannot carry depth/stencil or array (multiview) images.** Metal aborts the process instead of returning an error, so Monado must filter these out *before* vkCreateImage.
   - For M1: advertise only colour formats, with `arraySize == 1`, out-of-process.
   - Later: carry depth and arrays as **`MTLSharedTextureHandle` Mach ports** + `VkImportMetalTextureInfoEXT`. This uses SPI (`createMachPort`/`initWithMachPort`), the same as DXMT. It was verified pixel-exact cross-process into x86_64/Rosetta.
   - `xrt_graphics_buffer_handle_t` should stay a `mach_port_t`, plus a small kind tag (IOSurface vs shared texture).

**D2: confirmed. Use `bootstrap_check_in`, not `bootstrap_register`.**
- `bootstrap_check_in` is public, not deprecated, and works unprivileged on macOS 27. Fall back to `bootstrap_register2` only if it fails.
- The HELLO / per-client-port / nonce design works as specified.
- One OOL-ports descriptor per image batch is enough.
- Use `MACH_NOTIFY_NO_SENDERS` on the per-client port for disconnect detection.
- Rosetta x86_64 clients work unchanged, including via OOL port arrays.
- Bootstrap namespaces are per login session: an ssh session cannot see a GUI-session server.

**D3: can move MTLSharedEvent forward from "later" to milestone 3.** The GPU path works today on both architectures, using the timeline semaphore and the SPI `eventPort` / `newSharedEventWithMachPort:` pair (DXMT already uses this pair).
- Keep the CPU-wait fallback, gated on `respondsToSelector:`, for when the SPI disappears.
- Pass the current `signaledValue` as `initialValue` on import.
- Send the event port in the same OOL-ports batch.

**D5, side result.** Zero-copy NV12 is feasible today, with no MoltenVK patch. There are two options:
- **(a) MoltenVK-compatible `420v` IOSurface** plus one multi-planar VkImage with R8/RG8 storage views. This is WiVRn's existing shader path, and it is verified through VT HEVC encode.
- **(b) Standard `420v` surface plus two Metal-plane-texture imports.**

WiVRn's 3-layer encode image needs 3 surfaces, or 3 images.

A small upstream MoltenVK fix would make plain `420v` work. Its multi-planar `useIOSurface()` should:
- check plane element size 1×1,
- set `kIOSurfacePlaneBytesPerRow`, `kIOSurfacePlaneOffset` and `kIOSurfacePlaneSize`,
- set `kIOSurfacePixelFormat`.
