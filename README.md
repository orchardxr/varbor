# MacVR

[![Build](https://github.com/somsarashvili/macvr/actions/workflows/build.yml/badge.svg)](https://github.com/somsarashvili/macvr/actions/workflows/build.yml)

Windows PC VR games from Steam on an Apple Silicon Mac, streamed to a Meta Quest running the stock
[WiVRn](https://github.com/WiVRn/WiVRn) client. Games run under NotProton (Wine). MacVR adds the missing pieces:
an OpenXR bridge out of Wine, a macOS port of the WiVRn server with a VideoToolbox encoder, and a menu-bar app that
sets everything up.

## How it works

```
game → openvr_api.dll → OpenComposite (vrclient_x64.dll, OpenVR → OpenXR)
     → wineopenxr.dll + wineopenxr.so (bridge out of Wine)
     → libopenxr_monado.dylib (universal IPC client: x86_64 under Rosetta, arm64 under FEX)
     → wivrn-server (arm64, Monado + VideoToolbox HEVC, child of MacVR.app)
     → Wi-Fi → WiVRn client on the Quest
```

| Path | What |
|---|---|
| `app/` | MacVR.app (SwiftUI window + menu bar), the `macvr` CLI, the web-overlay broker/helper ([docs/macvr-app.md](docs/macvr-app.md), [docs/web-overlays.md](docs/web-overlays.md)) |
| `bridge/` | `wineopenxr` Wine builtin: PE side (llvm-mingw) + unix side ([docs/bridge-plan.md](docs/bridge-plan.md)) |
| `encoder/` | libmvt, the VideoToolbox HEVC encoder used by the WiVRn server ([docs/encoder.md](docs/encoder.md)) |
| `patches/` | Our changes to upstream projects, as patch series ([docs/build.md](docs/build.md)) |
| `third_party/` | Upstream projects as git submodules, pinned to the commits the patches apply to |
| `scripts/` | Build, patch and test scripts |
| `docs/` | Design notes and measurements; `TODO.md` is the running log |
| `spikes/`, `tests/`, `tools/` | Feasibility spikes, test programs, measurement tools |

Upstreams: [WiVRn](https://github.com/WiVRn/WiVRn) v26.9, [Monado](https://gitlab.freedesktop.org/monado/monado)
(WiVRn's pinned rev), [OpenComposite](https://gitlab.com/znixian/OpenOVR) (`openxr` branch),
[OpenXR-SDK-Source](https://github.com/KhronosGroup/OpenXR-SDK-Source) 1.1.65, plus the unpatched
[OpenVR SDK](https://github.com/ValveSoftware/openvr) 2.15.6 and [DirectXMath](https://github.com/microsoft/DirectXMath)
for test programs.

## Requirements

- Apple Silicon Mac. Developed on an M4 Max with macOS 27; the app targets macOS 14 or newer.
- Xcode (Swift 6 toolchain, `xcrun`), with the current macOS SDK.
- Homebrew: `cmake ninja pkg-config eigen jsoncpp molten-vk glib boost nlohmann-json openssl libarchive librsvg cli11 libpng x264`
  (x264 is optional: `WIVRN_USE_X264=OFF`).
- [LunarG Vulkan SDK](https://vulkan.lunarg.com/sdk/home#mac) 1.4.304 installed system-wide in `/usr/local` (universal
  loader, headers, glslc). The x86_64 IPC client needs its x86_64 slice.
- [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) (x86_64 ucrt, macOS universal build, e.g. `20260922`) for the
  Windows side. `scripts/lib/detect.sh` finds it through `LLVM_MINGW`, `scripts/local.env` (git-ignored, one line
  `LLVM_MINGW=<path>`), `x86_64-w64-mingw32-clang` on `PATH`, or `~/toolchains/llvm-mingw-*`.
- Steam for macOS with NotProton installed (its CrossOver-based runners, Rosetta or FEX). CrossOver bottles are
  supported too ([docs/macvr-app.md](docs/macvr-app.md)).
- A Meta Quest (tested: Quest 3S) with the stock WiVRn client 26.9 from the store, on the same network as the Mac.

## Build

```sh
git clone --recursive https://github.com/somsarashvili/macvr.git
cd macvr
scripts/patches.sh apply                  # reset each submodule to its pin, apply patches/<project>/* (staged)

scripts/build.sh openxr-sdk               # native loader + hello_xr (used by the server's test programs)
scripts/build-bridge.sh openxr-sdk-win    # Windows OpenXR loader, generated headers, Vulkan import lib
scripts/build-opencomposite.sh            # build/m3/oc/bin/vrclient_x64.dll
WIVRN_BUILD_DIR=$PWD/build/wivrn-next scripts/build-wivrn.sh --snapshot   # wivrn-server
scripts/build-wivrn.sh --client-x86_64    # IPC client for Rosetta runners
scripts/build-wivrn.sh --client-arm64     # IPC client for FEX runners
scripts/build-bridge.sh bridge            # wineopenxr.dll/.so + universal client in build/bridge/root
scripts/build-app.sh --test               # build/app/MacVR.app (runs the unit tests too)
```

`scripts/patches.sh status` shows each tree's pin and patch count; `scripts/patches.sh new <project> <name>` turns
work in progress in `third_party/<project>` into the next patch. Never commit inside `third_party/`. Details:
[docs/build.md](docs/build.md), [docs/wivrn.md](docs/wivrn.md).

CI ([.github/workflows/build.yml](.github/workflows/build.yml)) runs the same steps on a hosted macOS runner and
uploads `MacVR.app` as an artifact.

## Install and use

1. Copy `build/app/MacVR.app` to `/Applications` and open it. It deploys its payload, adds the bridge to every
   NotProton runner, fixes the prefix templates and game prefixes, and starts `wivrn-server` and the web-overlay broker.
   Nothing has to be edited by hand. `macvr status` (`MacVR.app/Contents/Helpers/macvr`) shows the same state.
2. Start the WiVRn client on the Quest and pair it with the Mac (it finds the server through Bonjour).
3. Launch the VR game from Steam with NotProton as its compatibility tool.

## Status and limitations

- Tested game: Half-Life: Alyx, on NotProton Rosetta and FEX runners, at 90 Hz
  ([docs/ab-alyx.md](docs/ab-alyx.md), [docs/linux-comparison.md](docs/linux-comparison.md)).
- Graphics APIs: D3D11 (DXMT or DXVK) and Vulkan. No D3D12 or OpenGL.
- OpenVR games only reach OpenXR through OpenComposite; SteamVR itself is not used.
- Work in progress: see [TODO.md](TODO.md).

## License

- Our own code (everything outside `patches/` and `third_party/`) is under the MIT license, see [LICENSE](LICENSE).
- The patch series follow their upstream's license, because they modify that code
  ([patches/LICENSE.md](patches/LICENSE.md)): `patches/wivrn/` and `patches/opencomposite/` are GPL-3.0,
  `patches/monado/` is BSL-1.0, `patches/openxr-sdk/` is Apache-2.0.
- `third_party/` submodules keep their own licenses.
- A built MacVR.app bundles separately licensed programs: the WiVRn server (GPL-3.0) and OpenComposite (GPL-3.0).
