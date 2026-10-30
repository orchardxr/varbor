# VarboR

[![Build](https://github.com/orchardxr/varbor/actions/workflows/build.yml/badge.svg)](https://github.com/orchardxr/varbor/actions/workflows/build.yml)

Part of [orchardxr](https://github.com/orchardxr): vibe-coded support for VR on macOS: native and Windows games, on
Apple Silicon, streamed via WiVRn.

VarboR lets Windows VR games from Steam run on an Apple Silicon Mac under NotProton. On Linux, Proton brings the VR
pieces with it; CrossOver, which NotProton runs games on, doesn't have them. VarboR adds exactly those:

- the **OpenVR bridge** (Proton's `vrclient`, built for CrossOver), so OpenVR games reach OpenComposite;
- the **OpenXR bridge** (`wineopenxr`), so OpenXR games reach the WiVRn runtime;
- the **VarboR runner**: a copy of a NotProton runner with VarboR's DXMT (zero-copy eye textures) and an ARM64EC DXVK
  for FEX, as an extra Steam compatibility tool;
- the setup of every NotProton runner and game prefix, done again at every launch, so nothing has to be edited by hand.

The headset side is WiVRn, the same as on Linux: the game's frames go through OpenComposite (OpenVR games) or straight
to the WiVRn runtime (OpenXR games), and the WiVRn server streams them to the headset.

```
Windows OpenVR game -> vrclient bridge -> OpenComposite for macOS (Metal) -> WiVRn runtime -> WiVRn server -> headset
Windows OpenXR game -> wineopenxr bridge ------------------------------------^
```

The rest of the stack isn't Windows-only: native macOS OpenXR apps can use the WiVRn runtime directly (Metal or
Vulkan), and native Mac OpenVR games can use OpenComposite for macOS with Metal. Both are barely tested so far.

## Requirements

- An Apple Silicon Mac with macOS 14 or newer.
- Steam for macOS with [NotProton](https://github.com/NotProtonNot/NotProton) (its CrossOver runners, Rosetta or FEX).
- [WiVRn for macOS](https://github.com/orchardxr/wivrn-macos): the WiVRn server, its dashboard and the OpenXR runtime.
- [OpenComposite for macOS](https://github.com/orchardxr/opencomposite-macos): the OpenVR runtime, for OpenVR games.
- Any WiVRn-supported headset with the stock WiVRn app (tested on Quest 3S), on the same network as the Mac.

Each of these is a separate app that installs and updates itself. VarboR checks that they are there and new enough,
and links to their release pages when they aren't; it never installs or updates them.

## Install and use

1. Download `VarboR-<version>.zip` from the [latest release](https://github.com/orchardxr/varbor/releases/latest),
   unzip it, move `VarboR.app` to `/Applications` and open it.
2. The Status page shows what VarboR found: NotProton and its runners, WiVRn, OpenComposite, and the prefixes it set
   up. Install whatever it marks as missing.
3. Optional: under **Runners**, **Install Engines** builds the VarboR runner for a runner, and **Add to NotProton…**
   lists its tools in Steam (after a Steam restart). Pick "… - VarboR" in a game's Compatibility settings.
4. Start the WiVRn server (its dashboard shows the pairing PIN and the connected headset), then launch the VR game
   from Steam with a NotProton tool.

VarboR runs only while it's open: it sets things up at launch and again when runners or prefixes change. It updates
itself from GitHub releases. `VarboR.app/Contents/Helpers/varbor status` prints the same state in a terminal.

## What's supported

- Windows VR games from Steam under NotProton, OpenVR (through OpenComposite) and OpenXR.
- Graphics: D3D11 with DXMT or DXVK, set in the game's NotProton compatibility settings; DXMT is preferred. Vulkan
  games: OpenXR only so far. No D3D12, OpenGL or D3DMetal.
- CrossOver bottles and extra Steam libraries can be added by hand in the app.

## Status and limitations

- Tested game: Half-Life: Alyx, on NotProton's Rosetta and FEX runners.
- Work in progress; the running log is [TODO.md](TODO.md).
- SteamVR itself is not used: OpenVR games only see what OpenComposite provides.

## License

- Our own code (everything outside `patches/` and `third_party/`) is under the MIT license, see [LICENSE](LICENSE).
- `vrclient/proton/` is Proton's vrclient (BSD-3-Clause, with LGPL and JsonCpp parts: [vrclient/LICENSE](vrclient/LICENSE)); `patches/` follow
  their upstream's license ([patches/LICENSE.md](patches/LICENSE.md)); `third_party/` submodules keep their own.

## Links

- [orchardxr/wivrn-macos](https://github.com/orchardxr/wivrn-macos): WiVRn server, encoder, OpenXR runtime.
- [orchardxr/opencomposite-macos](https://github.com/orchardxr/opencomposite-macos): native OpenComposite with Metal.
- [orchardxr/varbor-engines](https://github.com/orchardxr/varbor-engines): VarboR's DXMT and DXVK builds per
  CrossOver version.
- [WiVRn](https://github.com/WiVRn/WiVRn), [OpenComposite](https://gitlab.com/znixian/OpenOVR),
  [Proton](https://github.com/ValveSoftware/Proton), [NotProton](https://github.com/NotProtonNot/NotProton).

## Development

Building, the repository layout, the patch workflow, CI and releases: [docs/development.md](docs/development.md).
How the app works: [docs/varbor-app.md](docs/varbor-app.md). The bridges: [docs/bridge-plan.md](docs/bridge-plan.md)
(wineopenxr) and [TODO.md](TODO.md) (vrclient, measurements).
