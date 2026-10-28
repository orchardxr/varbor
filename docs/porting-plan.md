# Milestone 1 porting plan: Monado + WiVRn server on macOS

Goal: native `hello_xr` (Vulkan → MoltenVK) renders in the Quest through the stock WiVRn
client app. No headset needed until the final step.

## 1. Survey results (2026-10-24)

### Versions
- WiVRn upstream HEAD `75e2df57` (v26.9-89). Latest release **v26.9** (`bbc6e4cc`), which
  pins Monado `f037264d`. HEAD pins Monado `8b259763`.
- WiVRn's `protocol_version` is a hash over all packet serializers. The server rejects any
  mismatch, and HEAD's packets differ from v26.9. **The server must be built from the tag
  that matches the client APK on the Quest.** We assume v26.9 until we've checked the Quest.
- MoltenVK 1.4.2 (Homebrew), Vulkan loader 1.4.304 (LunarG SDK in /usr/local/lib), M4 Max.

### Monado: already exists
- Partial "OSX" bring-up upstream (MR !2672/!2679): `XRT_OS_OSX`/`XRT_OS_UNIX`, OBJC
  enabled, os_time (mach_time), u_file/u_debug/u_logging, prober, the openxr dylib
  exporting only `xrNegotiateLoaderRuntimeInterface`.
- All Linux-only deps sit behind `XRT_HAVE_LINUX`, which is off on Darwin. That covers
  udev, X11, Wayland, libdrm, dbus, v4l2, libbsd, and the drivers that need them
  (lh, vive, wmr, solarxr, libmonado, OpenVR state tracker).
- `xrt_graphics_buffer_handle_t` is `int` (fd) on OSX, marked as a hack. There is no
  IOSurface, Mach-port, XPC or Metal sharing anywhere.

### Monado: missing on macOS
| Area | File(s) | Problem |
|---|---|---|
| IPC server mainloop | `ipc/CMakeLists.txt:168-199` | No APPLE branch → `ipc_server` has no mainloop. |
| epoll | `ipc_server_mainloop_linux.c`, `ipc_server_per_client_thread.c:34` | Needs kqueue/poll. |
| Threads | `os_threading.h` | No `os_semaphore` on OSX (unnamed POSIX sems unsupported); `pthread_setname_np` is the 1-arg form. |
| Vulkan instance | vk_bundle / comp_vulkan | No `ENUMERATE_PORTABILITY_BIT` / `VK_KHR_portability_subset` → loader 1.4.304 hides MoltenVK. |
| Memory export | `vk_image_allocator.c:58`, `vk_compositor_flags.c:68,217`, `vk_bundle_init.c:342+` | Compiles as `OPAQUE_FD`; MoltenVK can't export or import fds. |
| Sync export | `vk_sync_objects.c` | `OPAQUE_FD` semaphores / `SYNC_FD` fences unsupported on MoltenVK. |
| Handle transport | `ipc_message_channel_unix.c` (SCM_RIGHTS), `xrt_handles.h` | Mach ports can't go through SCM_RIGHTS. |

### WiVRn server: missing on macOS
- Hard deps that are useless on macOS: avahi-client/glib, gdbus-codegen + session D-Bus
  (main.cpp throws without one), libnotify, systemd stubs (`start_systemd_unit.cpp`).
- Linux-only code:
  - `driver/wivrn_uinput.*` (used unconditionally in `wivrn_session.cpp:276`)
  - `pidfd.h`, `signalfd` in `main.cpp`
  - `sleep_inhibitor.cpp`, `hostname.cpp` (both D-Bus)
  - `active_runtime.cpp:55` (`/proc/self/exe`)
  - `common/utils/flatpak.*`
- Sockets (`common/wivrn_sockets.cpp`): `recvmmsg`/`sendmmsg`, `MSG_NOSIGNAL`, `MSG_TRUNC`
  on recvfrom.
- `utils/wivrn_vk_bundle.cpp:229` hard-requires `VK_KHR_external_memory_fd`.
- Encode image: a 3-layer multi-planar `G8_B8R8_2PLANE_420` image written as storage through
  R8/RG8 plane views (`compositor/compositor.cpp:90-135`). Whether MoltenVK supports this
  is unknown.
- Encoders: nvenc, vaapi, vulkan video, x264, raw. The interface (`encoder/video_encoder.h`)
  is two virtuals: `present_image(vk::Image, sem, slot, frame)` and `encode(slot, frame)`.
  x264 and raw already do GPU→host NV12 readback, which a VideoToolbox backend can copy.
- Audio is PipeWire only and can be cleanly disabled (`WIVRN_USE_PIPEWIRE=OFF`).
- The dashboard (Qt/KF6) and `wivrnctl` (D-Bus) are skipped.
- Discovery: the client does its own raw mDNS (`_wivrn._tcp`, TXT `protocol`/`version`/`cookie`),
  so Bonjour `DNSServiceRegister` is a drop-in. Manual IP entry on the client works
  without it.

### Reusable from an earlier private prototype
- Its VideoToolbox encoder: tuned VT HEVC session.
  - Settings: RealTime, no reordering, CBR *without* low-latency RC (≈40 % faster ≤7 MP),
    VBV, BT.709, `NumberOfSlices`, host-clock PTS, IDR on demand.
  - Bitrate-change hysteresis, Annex B conversion, filler-NAL drop, prewarm.
  - It is a standalone process; we extract the session code into a small C library.
- `tools/vtbench.c`, `tools/encoder_test.c`: VT benchmarks.
- Milestone 2 no longer patches DXMT (user decision 2026-10-24); it uses stock DXVK interop instead,
  see docs/bridge-plan.md. For reference only: Upstream DXMT already shares textures as `MTLSharedTextureHandle`
  Mach ports registered with `bootstrap_register` (`WMTBootstrapRegister`). That proves
  bootstrap Mach services work from inside a Wine process, which the M2 bridge depends on.

## 2. Key design decisions

### D1 — Buffer handle = IOSurface Mach port
On Apple, `xrt_graphics_buffer_handle_t` becomes `mach_port_t`: a send right made by
`IOSurfaceCreateMachPort`.
- Server side: `IOSurfaceLookupFromMachPort` → `VkImportMetalIOSurfaceInfoEXT`.
- Allocation: the image is created with `VkExportMetalObjectCreateInfoEXT(IOSURFACE)` and
  exported with `vkExportMetalObjectsEXT`.
- Why IOSurface rather than `MTLSharedTextureHandle`: VT encodes from it directly, CoreVideo
  wraps it, any GPU API (Metal, MoltenVK, DXMT, GL) can bind it, and its port is a plain
  send right with no XPC/NSCoding needed.
- `VK_EXT_external_memory_metal` (MTLTEXTURE handle type) is the fallback if MoltenVK's
  IOSurface import has format gaps.

### D2 — Handle transport = Mach side channel next to the unix socket
SCM_RIGHTS can't carry Mach ports.
- The server checks in a per-user bootstrap service `org.macvr.monado.<uid>` via
  `bootstrap_register`, as DXMT does.
- On connect, the client sends a Mach message carrying its own receive right, plus a
  nonce it also sent over the unix socket, which pairs the two channels.
- From then on, `ipc_send_handles_graphics_buffer` / `_sync` send the ports as an OOL port
  descriptor array next to the socket message.
- Shared memory (`xrt_shmem_handle_t`) stays an fd over SCM_RIGHTS (POSIX `shm_open` works
  on macOS).
- Frames never touch wineserver, so any Wine prefix's bridge can talk to the same server.

### D3 — Sync: CPU wait first, MTLSharedEvent later
- M1: no exportable sync. The client compositor already falls back to
  `XRT_GRAPHICS_SYNC_HANDLE_INVALID` plus a CPU fence wait before commit.
- Later: `MTLSharedEvent` via `VK_EXT_metal_objects` (`VkImportMetalSharedEventInfoEXT`)
  and timeline semaphores, with the event's Mach port sent like D2.

### D4 — Version pinning and patch layout
- `third_party/wivrn` is checked out at the client's tag; `third_party/monado` at that
  tag's `monado-rev`.
- WiVRn's own Monado patches are applied first, then ours. WiVRn is configured with
  `FETCHCONTENT_SOURCE_DIR_MONADO=third_party/monado`, so it does not re-fetch.
- `scripts/patches.sh {apply|reset|status|new <project> <name>}`:
  - `apply` resets to the pinned rev and runs `git apply --index` for each patch.
  - Patches are staged, never committed, so `git diff` shows only work in progress.
  - `new` exports that diff as the next numbered patch in `patches/<project>/`.
- Pinned revisions are the submodule commits of `third_party/<project>`.

### D5 — Encoder: VideoToolbox backend in two steps
1. `video_encoder_vt`: GPU→host NV12 readback (x264 pattern) → CVPixelBufferPool → VT.
   Session and rate control come from the earlier prototype.
2. Zero-copy: allocate WiVRn's encode image on an IOSurface (D1 machinery), then wrap the
   same IOSurface in a CVPixelBuffer, so there is no readback. If MoltenVK can't do
   multi-planar storage, use two planes (R8 + RG8 views into one IOSurface with plane
   offsets).

### D6 — Linux-only server pieces
Behind `#ifdef __APPLE__` or CMake options; not reimplemented unless needed.
- No D-Bus server (no wivrnctl/dashboard). The GLib main loop stays (Homebrew glib).
- Bonjour replaces avahi.
- Pairing PIN is shown in the terminal, not via libnotify.
- uinput gamepad off; IOPM assertion instead of sleep_inhibitor.
- `_NSGetExecutablePath` replaces `/proc/self/exe`; flatpak off.

### Amendments after step 2 spike (spikes/iosurface/RESULTS.md)
- **D1:**
  - We allocate the IOSurface ourselves, with a real pixel format, and import it with
    `VkImportMetalIOSurfaceInfoEXT`. MoltenVK's own export produces pixel format 0, so
    CoreVideo/VT reject it.
  - Depth formats and arrayLayers>1 on IOSurface abort the process inside Metal. In M1
    we advertise only colour formats with array size 1. Later, depth/array images go as
    `MTLSharedTextureHandle` Mach ports (private `createMachPort`/`initWithMachPort`, as DXMT
    does), with a kind tag on the handle.
- **D2:** `bootstrap_check_in` works unprivileged (fallback `bootstrap_register2`). Ports go in one
  OOL-ports message. Disconnects come from a dead-name notification. Verified with a Rosetta
  x86_64 client.
- **D3:** `MTLSharedEvent` GPU sync works across processes through private `eventPort` /
  `newSharedEventWithMachPort:`, so it moves into step 3; CPU wait stays as the fallback.
  - MoltenVK resets the event value on import, so pass the current value.
  - Use `CLOCK_UPTIME_RAW`/`MONOTONIC` across architectures.
- **D5:** zero-copy NV12 works today. Either use a MoltenVK-shaped NV12 IOSurface with R8/RG8
  plane views, or two Metal plane textures. WiVRn's 3-layer encode image becomes 3 surfaces.
  - Done (step 7, WiVRn patch 0005): the second option, one `420f`/`xf20` CVPixelBuffer per stream per compositor
    image, planes imported as R/RG images through `VkImportMetalTextureInfoEXT`; foveation writes per-stream image
    arrays. Readback stays as `WIVRN_VT_READBACK=1`.
- **Environment:** the loader defaults to the SDK's MoltenVK 1.2.11. Use
  `VK_DRIVER_FILES=/opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json` (1.4.2). Rosetta x86_64
  processes can only load the SDK's universal 1.2.11.

### Amendments after step 3 (Monado out-of-process, patches 0012–0013)
- **D1:**
  - Implemented as amended: `vk_image_allocator` allocates the IOSurface itself (real FourCC, aligned
    bytes per row), imports it, and keeps the `IOSurfaceRef` for `IOSurfaceCreateMachPort`.
  - Only formats with a CoreVideo FourCC are offered.
- **D2:**
  - Bootstrap name = `org.macvr.monado.<uid>.<socket basename>.<fnv1a32(realpath)>`. The service takes the path
    with `getsockname()`, so WiVRn's own `wivrn/comp_ipc` socket gets its own service.
  - The nonce goes on the socket as a 16-byte preamble before the first IPC call, so the socket protocol differs
    from Linux on macOS. A Wine/x86_64 bridge must link the same client code.
  - Every handle-carrying socket message is preceded by exactly one OOL-ports Mach message with a sequence
    number.
  - Unpaired HELLOs expire after 10 s, and paired channels are torn down on socket close. This replaces the
    no-senders notification from the spike.
- **D3:**
  - Done in step 3 rather than step 7. The service exports the MTLSharedEvent and the client imports it
    (Monado's `xrt_comp_create_semaphore` direction).
  - The client's import uses `MTLCreateSystemDefaultDevice()`.
  - `MONADO_MACOS_SYNC=cpu` or missing SPI selects the CPU wait, and a client falls back if the service refuses
    the semaphore.
  - Step 7 keeps only measuring on real workloads.

## 3. Work steps (each ends with something testable without the headset)

| # | Step | Done when |
|---|---|---|
| 0 | Pin versions. Confirm the Quest client version; check out the matching wivrn tag and monado rev; write `scripts/patches.sh`. | `patches.sh apply` reproduces a clean tree. |
| 1 | Monado builds on macOS (service + openxr dylib). Covers mainloop (kqueue), os_semaphore, thread names, portability enumeration. Use the `simulated` device, in-process first. | `monado-service` starts; OpenXR-SDK `hello_xr -g Vulkan` (MoltenVK) runs **in-process** against it with no errors. |
| 2 | Spike: IOSurface ⇄ MoltenVK. A standalone test exports a VkImage as IOSurface, sends the Mach port to a second process via bootstrap, imports it, reads back. Covers RGBA8/sRGB/NV12. | Pixel-exact readback in process B. |
| 3 | Monado out-of-process: D1 + D2 in xrt_handles, vk_image_allocator, vk_bundle probing, ipc message channel; sync per D3. | `hello_xr` as a separate process renders. The compositor's output is checked by dumping a frame to PNG. |
| 4 | WiVRn server builds and runs on macOS (D6, sockets, Bonjour, `wivrn_vk_bundle` ext requirements, encode image on MoltenVK). Encoder: x264 or raw first. | Server starts, advertises over mDNS (`dns-sd -B _wivrn._tcp`), and accepts a TCP connection. |
| 5 | `video_encoder_vt` (readback). Offline test harness feeds frames and dumps `.hevc`. | `ffprobe` shows a valid stream; encode time per frame is logged. |
| 6 | Headset: Quest client connects, hello_xr visible. **User check.** | User confirms the image in the headset. |
| 7 | Zero-copy encode image (MTLSharedEvent sync already done in step 3); measurements in TODO.md. | Latency/fps numbers recorded. |

## 4. Risks
- MoltenVK feature gaps: multi-planar storage images, `VK_EXT_metal_objects` IOSurface
  import for sRGB/NV12 formats, timeline semaphores, `shaderStorageImageWriteWithoutFormat`
  in WiVRn's YUV shaders. Step 2 spike exists to find these early.
- `bootstrap_register` is deprecated but still works for per-user services (DXMT relies
  on it). Fallback: a LaunchAgent plist with `MachServices`, plus `bootstrap_look_up`.
- Client/server version skew if the Quest auto-updates the WiVRn app. We record the
  protocol hash and re-pin on update.
- Monado compositor assumptions about Linux timing (`os_nanosleep`, frame pacing) on
  macOS; measured in step 7.
