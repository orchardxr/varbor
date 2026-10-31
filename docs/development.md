# Developing VarboR

## Repositories

The project is four repos under [orchardxr](https://github.com/orchardxr), each released and updated on its own:

| Repo | What | Installs as |
|---|---|---|
| [orchardxr/varbor](https://github.com/orchardxr/varbor) (this one) | the Wine bridges (vrclient, wineopenxr), runner and prefix setup, VarboR.app | VarboR.app |
| [orchardxr/wivrn-macos](https://github.com/orchardxr/wivrn-macos) | WiVRn server, VideoToolbox encoder, Monado patches, the OpenXR runtime, later the dashboard | an install tree with `lib/wivrn/libopenxr_wivrn.dylib`, `share/openxr/1/openxr_wivrn.json`, `share/wivrn/build-info` |
| [orchardxr/opencomposite-macos](https://github.com/orchardxr/opencomposite-macos) | native OpenComposite with the Metal compositor | `~/Library/Application Support/OpenComposite/runtime`; WiVRn registers it in the macOS `openvrpaths.vrpath` while its server runs |
| [orchardxr/varbor-engines](https://github.com/orchardxr/varbor-engines) | patched DXMT and ARM64EC DXVK per CrossOver build | GitHub releases `cx-<CrossOver version>`, downloaded by VarboR |

VarboR only reads the other installs (`app/Sources/VarborCore/Components.swift`: locations, version minimums,
release pages). The minimum versions VarboR needs are constants there.

## Layout

| Path | What |
|---|---|
| `app/` | VarboR.app (SwiftUI window + menu bar) and the `varbor` CLI ([varbor-app.md](varbor-app.md)) |
| `vrclient/` | Proton's vrclient_x64 (`proton/`, imported from experimental_11.0) built for CrossOver, our code in `src/` |
| `bridge/` | `wineopenxr` Wine builtin: PE side (llvm-mingw) + universal unix side ([bridge-plan.md](bridge-plan.md)); `varborreg.dll` |
| `patches/` | our changes to upstream submodules (only `openxr-sdk/` now) |
| `third_party/` | OpenXR-SDK-Source 1.1.65, OpenVR SDK 2.15.6, DirectXMath (headers, the Windows loader, test programs) |
| `scripts/` | build, prefix setup and test scripts |
| `tests/`, `spikes/`, `tools/` | the D3D11 OpenVR test program, bridge feasibility spikes, the Alyx VConsole helper |
| `docs/` | design notes and measurements; `TODO.md` is the running log |

## Toolchain

- Apple Silicon Mac; Xcode with the current macOS SDK (Swift 6 toolchain). The app targets macOS 14.
- Homebrew: `brew bundle` ([Brewfile](../Brewfile): cmake, ninja, vulkan-headers). The LunarG Vulkan SDK in
  `/usr/local` works too (`scripts/lib/detect.sh`: `VULKAN_INCLUDE`, `/usr/local/include`, Homebrew).
- [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) (x86_64 ucrt, macOS universal, e.g. `20260922`).
  `scripts/lib/detect.sh` finds it through `LLVM_MINGW`, `scripts/local.env` (git-ignored, one line
  `LLVM_MINGW=<path>`), `x86_64-w64-mingw32-clang` on `PATH`, or `~/toolchains/llvm-mingw-*`.
- `ccache` is used when installed.

## Build

```sh
git clone --recursive https://github.com/orchardxr/varbor.git
cd varbor
scripts/patches.sh apply                  # reset each submodule to its pin, apply patches/<project>/* (staged)
scripts/build-bridge.sh                   # openxr-sdk-win, then wineopenxr (build/bridge/root), then vrclient (build/vrclient/root)
scripts/build-app.sh --test               # build/app/VarboR.app, runs the unit tests
```

`scripts/build-bridge.sh openxr-sdk-win|bridge|vrclient` builds one part. The vrclient build fetches Wine's headers
(`WINE_TAG`, default wine-11.0, sparse) into `build/vrclient/wine` the first time.

## Patches

`scripts/patches.sh status` shows each tree's pin and patch count; `scripts/patches.sh new <project> <name>` turns
work in progress in `third_party/<project>` into the next patch. Never commit inside `third_party/`; a change goes
into `patches/<project>/`.

## Testing

- Unit tests: `cd app && swift test` (or `scripts/build-app.sh --test`). They run on scratch trees under the temp
  dir: prefixes, runners, bottles, fake WiVRn/OpenComposite/NotProton installs and a fake engines
  release.
- vrclient tests: `make -C vrclient test` (run by `scripts/build-bridge.sh vrclient`): the D3D11 engine classification
  and the native runtime lookup (`src/runtime.h`: `VARBOR_VRCLIENT_RUNTIME`, `PROTON_VR_RUNTIME`, the macOS
  `openvrpaths.vrpath`, then the standard OpenComposite install, since WiVRn registers it only while its server runs).
- Never run the CLI or the app from a build against your real setup by accident: set `VARBOR_SUPPORT`,
  `VARBOR_STEAM_ROOT`, `VARBOR_RUNNERS`, `VARBOR_LOG_DIR` and `VARBOR_NO_SYSTEM=1`. `app/Tests/scratch.sh` builds a scratch tree from real prefixes.
- Bridge rigs: `scripts/run-vrclient.sh` (an OpenVR program through vrclient and OpenComposite against monado-service's
  null compositor) and `scripts/run-bridge.sh` (an OpenXR program through wineopenxr). They take monado-service and
  OpenComposite from wivrn-macos and opencomposite-macos builds next to this checkout (`MONADO_BUILD`, `OC_RUNTIME`).
- `scripts/setup-vrclient-prefix.sh` sets one prefix up by hand, like the app does.

## CI

[.github/workflows/build.yml](../.github/workflows/build.yml) builds only the bridges and the app on a hosted macOS
runner (llvm-mingw, Homebrew's Vulkan headers, ccache), runs the unit tests and uploads `VarboR.app`.

## Releasing

Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in `app/Resources/Info.plist`, add notes as
`docs/releases/v<version>.md` (optional), commit, then push a tag `v<version>`. The CI build of the tag publishes the
release with `VarboR-<version>.zip`; installed apps pick it up through self-update (they take the `VarboR-*.zip`
asset).

## Measurements and history

[ab-alyx.md](ab-alyx.md), [linux-comparison.md](linux-comparison.md), [bridge-plan.md](bridge-plan.md),
[m4-notproton.md](m4-notproton.md), [porting-plan.md](porting-plan.md) and [TODO.md](../TODO.md) are kept as written,
from before the split: they cover the whole stack (WiVRn server and encoder included).
