# Building and running on macOS

Host: Apple Silicon, macOS 27, Homebrew `cmake ninja eigen jsoncpp molten-vk` (MoltenVK 1.4.2),
LunarG Vulkan SDK 1.4.304 in `/usr/local` (loader, headers, glslang, validation layers).

## Pinned sources

| Tree | Rev | Notes |
|---|---|---|
| `third_party/wivrn` | `v26.9` = `bbc6e4cc` | Assumed to match the Quest client APK |
| `third_party/monado` | `f037264d` | WiVRn v26.9's `monado-rev` |
| `third_party/openxr-sdk` | `release-1.1.65` = `a9f14c41` | hello_xr, loader, API layers |
| `third_party/opencomposite` | `cff07db7` (branch `openxr`) | OpenVR → OpenXR (M3) |
| `third_party/openvr` | `v2.15.6` = `09240643` | Valve's OpenVR SDK for the OpenComposite test apps, no patches |
| `third_party/directxmath` | `apr2025` = `56206b19` | Headers for the Windows hello_xr D3D11 plugin (M2), no patches |

All trees are git submodules at their upstream URLs; the pinned rev is the submodule commit recorded in this repo
(`git submodule status`). Clone with `--recursive` or run `git submodule update --init --recursive`. Never commit
inside `third_party/`: our changes are the patch files in `patches/<project>/`. To move a pin, check out the new
upstream commit in `third_party/<project>`, `git add third_party/<project>`, then `scripts/patches.sh apply`.

## Machine-specific values

Nothing machine-specific is hardcoded. `scripts/lib/detect.sh` finds it at run time:

| Value | Override | Detected as |
|---|---|---|
| Quest adb serial | `QUEST_SERIAL` | the only device in `adb devices` (fails if none or several) |
| Mac IP for `wivrn://` | `MAC_IP` | IPv4 address of the default-route interface |
| llvm-mingw root | `LLVM_MINGW` | `scripts/local.env` (git-ignored, `LLVM_MINGW=<path>`), `x86_64-w64-mingw32-clang` on `PATH`, newest `~/toolchains/llvm-mingw-*` |

Steam accounts are not configured: scripts and MacVR scan every `userdata/*/config/localconfig.vdf`.

## Patches

```sh
scripts/patches.sh apply            # reset every tree to its pin (hard reset + clean -fdx), apply all patches, staged
scripts/patches.sh apply monado     # one tree (monado requires wivrn to be at its pin)
scripts/patches.sh status
scripts/patches.sh reset [project]  # back to the pin, no patches
scripts/patches.sh new monado <name>  # export unstaged diff + untracked files as the next NNNN-<name>.patch, then stage it
```

For monado, WiVRn's own `third_party/wivrn/patches/monado/*` (0001–0011) are applied first, in glob
order, the same as WiVRn's `apply.sh`. Ours in `patches/monado/` come after them. Workflow: edit in
`third_party/<p>`, build, test, then `patches.sh new`. `git diff` then shows only unsaved work.

## Build

```sh
scripts/patches.sh apply
scripts/build.sh                    # or: scripts/build.sh monado monado-inproc openxr-sdk
scripts/build.sh x86_64             # optional: Rosetta client (build/monado-x86_64, build/openxr-sdk-x86_64)
```

That runs:

```sh
# Service build: monado-service + libopenxr_monado.dylib as an IPC client
cmake -S third_party/monado -B build/monado -G Ninja -C cmake/monado-macos.cmake -DXRT_FEATURE_SERVICE=ON
ninja -C build/monado
# In-process build: libopenxr_monado.dylib that contains the compositor
cmake -S third_party/monado -B build/monado-inproc -G Ninja -C cmake/monado-macos.cmake -DXRT_FEATURE_SERVICE=OFF
ninja -C build/monado-inproc
# OpenXR SDK: loader, API layers, hello_xr
cmake -S third_party/openxr-sdk -B build/openxr-sdk -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DBUILD_TESTS=ON -DBUILD_CONFORMANCE_TESTS=OFF -DDYNAMIC_LOADER=ON -DBUILD_WITH_SYSTEM_JSONCPP=OFF
ninja -C build/openxr-sdk
```

`cmake/monado-macos.cmake` is an initial cache. It mirrors the driver and feature set that WiVRn's
`server/CMakeLists.txt` forces, but keeps the `simulated` driver and the null compositor. It
turns off OpenGL/EGL/SDL/OpenCV/RealSense. It also points `U_GIT_TAG_CPP` at `cmake/u_git_tag.c`,
because WiVRn patch 0008 removes Monado's own `u_git_tag.c`.

A full build from scratch takes about 75 s.

## Run

The Vulkan environment is in `scripts/env-macos.sh`:

```sh
export VK_DRIVER_FILES=/opt/homebrew/opt/molten-vk/etc/vulkan/icd.d/MoltenVK_icd.json
export VK_LAYER_PATH=/usr/local/share/vulkan/explicit_layer.d
```

- Without `VK_DRIVER_FILES`, the loader picks the SDK's MoltenVK 1.2.11 in `/usr/local`.
- Do not set `DYLD_LIBRARY_PATH=/usr/local/lib`. dyld would then load the SDK's `libMoltenVK.dylib`
  by leaf name even when the Homebrew ICD json is selected.

### In-process hello_xr

```sh
scripts/run-hello-xr.sh inproc 10 -g Vulkan2      # or -g Vulkan
VALIDATE=1 scripts/run-hello-xr.sh inproc 10 -g Vulkan2
```

What the script does:
- Sets `XR_RUNTIME_JSON=build/monado-inproc/openxr_monado-dev.json`, `SIMULATED_ENABLE=1` and
  `XRT_COMPOSITOR_NULL=1`. macOS has no window target, so the null compositor is the only one.
- Runs hello_xr for N seconds, then sends Enter, which is a clean shutdown.
- `VALIDATE=1` adds `VK_LAYER_KHRONOS_validation`, the OpenXR `core_validation` layer, and the
  `api_dump` layer. The api_dump output is used to count `xrEndFrame` calls.
- Logs go to `build/logs/hello_xr-inproc.log` and `build/logs/hello_xr-inproc.xrdump.txt`.

### Service (out-of-process)

```sh
scripts/run-oop.sh 10 -g Vulkan2                 # or -g Vulkan; starts and stops monado-service itself
SYNC=cpu scripts/run-oop.sh 10                   # MTLSharedEvent off, CPU wait before each commit
VALIDATE=1 SERVICE_VALIDATE=1 scripts/run-oop.sh 8
ARCH=x86_64 scripts/run-oop.sh 10                # x86_64 hello_xr + client runtime under Rosetta
```

What `run-oop.sh` does:
- Starts `build/monado/src/xrt/targets/service/monado-service` with `XRT_COMPOSITOR_NULL=1 SIMULATED_ENABLE=1
  XRT_NO_STDIN=1` and waits for the socket.
- Runs `run-hello-xr.sh service N ...`, then stops the service with SIGINT.
- Sets `MONADO_SYNC_STATS=1`, so both sides print `sync-stats` lines every 100 frames.
- The null compositor writes committed frame `DUMP_FRAME` (default 60) to `build/logs/oop-frame.png`.
  Both eyes are side by side, read straight from the swapchain IOSurfaces.
- Logs: `build/logs/service-oop.log`, `build/logs/hello_xr-service.log`.

Running the service by hand:

```sh
source scripts/env-macos.sh
XRT_NO_STDIN=1 XRT_COMPOSITOR_NULL=1 SIMULATED_ENABLE=1 build/monado/src/xrt/targets/service/monado-service
scripts/run-hello-xr.sh service 5 -g Vulkan2      # in another shell
```

- The service exits cleanly when stdin closes. With `XRT_NO_STDIN=1` it stops on SIGINT/SIGTERM instead.
- The socket is `$(getconf DARWIN_USER_TEMP_DIR)monado_comp_ipc`, unless `XDG_RUNTIME_DIR` is set.
- The service and its clients must be in the same login session (bootstrap namespace). A service started
  from an ssh shell is invisible to GUI apps and the other way round.

### Environment variables (macOS additions)

| Variable | Side | Effect |
|---|---|---|
| `MONADO_MACOS_SYNC=cpu` | both | No MTLSharedEvent timeline semaphores; the client waits on the CPU before each commit. Default `auto`: GPU sync if the private selectors exist. A client with `auto` against a `cpu` service logs an error and falls back. |
| `XRT_IPC_MACH_SERVICE=<name>` | both | Override the bootstrap service name (default: derived from the socket path, see below). |
| `MONADO_SYNC_STATS=1` | both | Client: time spent in the commit path. Service: client commit to client GPU work done. |
| `XRT_COMPOSITOR_NULL_DUMP=<file.png>` | service | Null compositor writes one frame as PNG. |
| `XRT_COMPOSITOR_NULL_DUMP_FRAME=N` | service | Which committed frame to dump (default 60). |

### How the Mach side channel works

- Graphics buffers are IOSurface Mach ports; sync objects are MTLSharedEvent Mach ports. Neither can go through
  SCM_RIGHTS, so each IPC connection gets a Mach channel next to its unix socket (`ipc/shared/ipc_mach_apple.c`).
- The service checks in a per-user bootstrap service (`bootstrap_check_in`, fallback `bootstrap_register2`):
  `org.macvr.monado.<uid>.<socket basename>.<fnv1a32 of the socket's realpath, 8 hex>`.
  - It takes the socket path from `getsockname()` on the listening socket. A socket handed in via
    `listen_socket` (WiVRn) gets its own name too.
  - Example: `org.macvr.monado.501.monado_comp_ipc.42323fd1` (logged at startup as "Mach IPC: registered ..."); WiVRn's `wivrn/comp_ipc` → `org.macvr.monado.501.comp_ipc.<hash>`.
- Handshake:
  1. The client sends HELLO (receive port + random 64-bit nonce) to the service port.
  2. It writes `{'MVRM', 1, nonce}` (16 bytes) as the first bytes on the socket.
  3. The per-client server thread reads those 16 bytes, matches the nonce and replies HELLO_ACK with a
     per-connection receive port.
  - A client without the side channel is disconnected (bad magic). Unpaired HELLOs expire after 10 s.
- Each socket message that carries handles is preceded by exactly one Mach message on the channel: an OOL
  ports descriptor (COPY_SEND) plus a sequence number. Receivers own the rights they get. Shared memory stays an
  fd over SCM_RIGHTS.
- Client death: the per-client thread sees the socket close and destroys the receive right and the send right.
- Port counts in the service stay flat across reconnects and kill -9 of a client.

## Windows OpenXR bridge (M2)

```sh
scripts/build-bridge.sh                      # build/bridge/: monado-service, x86_64 client, hello_xr.exe, wineopenxr
scripts/run-bridge.sh 10 build/bridge/openxr-sdk-win/src/tests/hello_xr/hello_xr.exe -g D3D11
```

Everything else (prefix, registry, environment, tests, numbers) is in [bridge-plan.md](bridge-plan.md) §0.
