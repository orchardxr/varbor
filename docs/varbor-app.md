# VarboR app (window + menu bar + CLI)

Goal: install VarboR.app, open it, launch VR games from Steam. The user edits nothing. VarboR provides what Proton
has and CrossOver lacks, and nothing else: it doesn't run or watch the WiVRn server, show pairing PINs, the headset
or the running game (the WiVRn dashboard does that, as on Linux), and it doesn't install or update WiVRn,
OpenComposite or NotProton.

```
OpenVR game -> openvr_api.dll -> C:\vrclient\bin\vrclient_x64.dll (the runner's builtin) -> vrclient_x64.so
            -> OpenComposite's vrclient.dylib (first runtime in ~/Library/Application Support/OpenVR/.openvr/openvrpaths.vrpath)
OpenXR game -> openxr_loader.dll -> ActiveRuntime = varbor\current\bridge\wineopenxr.json -> wineopenxr.dll/.so
            -> the host runtime (XR_RUNTIME_JSON, else active_runtime.json: WiVRn's libopenxr_wivrn.dylib)
```

## Build

```sh
scripts/build-app.sh [--test]        # build/app/VarboR.app, CLI at VarboR.app/Contents/Helpers/varbor
```

- Sources in `app/` (Swift package): `VarborCore` (all logic), `varbor` (CLI), `VarborApp` (SwiftUI `Window` +
  `MenuBarExtra`), `Tests/VarborCoreTests` (XCTest), `Tests/scratch.sh` (scratch tree from real prefixes).
- Payload in `Contents/Resources/payload/bridge`: `x86_64-windows/{wineopenxr.dll, vrclient_x64.dll, varborreg.dll}`,
  `x86_64-unix/{wineopenxr.so, vrclient_x64.so}` (universal x86_64 + arm64; the script refuses thin files) and
  `wineopenxr.json` (`"library_path": "x86_64-windows\\wineopenxr.dll"`). No server, no OpenComposite, no IPC client.
- `Info.plist`: bundle id `org.orchardxr.varbor`, a regular Dock app. Ad-hoc signed. The linker gets the current SDK
  version (`-platform_version`), or macOS draws the window in the legacy style.

## What the app does

No login item, no LaunchAgent, no global environment. On open:
1. If MacVR is running: nothing else, only the notice "Quit MacVR, then reopen VarboR". Otherwise migrate MacVR's
   state (below), once.
2. Deploy the payload into `versions/<stamp>` and switch `current` (atomic rename), unless it's current.
3. Runner files: add the bridge to every NotProton runner (VarboR runners included).
4. Rescan: the prefix templates first, then game prefixes and added bottles.
5. Check for a VarboR update and for engines releases (the only network calls besides an install).

While open, every 5 s: whether a NotProton game runs, new runners (then runner files + rescan), and a retry of the
rescan every 60 s while a prefix was busy and no game runs.

Window: Status (setup card; Components: NotProton, WiVRn, OpenComposite with version, notes and an Install/Update
button that opens that app's release page; Runners with their bridge files and VarboR runner; Prefixes count),
Games & Prefixes (per Steam game prefix with a "Use VarboR" switch, templates), Added by You (CrossOver bottles,
Steam libraries), Runners (each file), Logs. Menu: Show VarboR, setup state, Open VarboR Log, Rescan Games,
updates, About, Quit. Quitting undoes nothing: prefixes and runner files stay.

Backend note (About, `varbor status`): VR works with DXMT and DXVK (the game's NotProton compatibility settings);
DXMT is preferred. D3DMetal isn't supported. VarboR never sets `CX_GRAPHICS_BACKEND`. When a D3D11 game's device is
neither, the bridge's unix side asks with a native alert: Quit Game, or Run Anyway (XR_ERROR_GRAPHICS_DEVICE_INVALID).

## Runners

`RunnerInstall.swift`: into every `notproton/runners/crossover-*/CrossOver/lib/wine`:
`x86_64-windows/{wineopenxr.dll, vrclient_x64.dll, varborreg.dll}`, and each `.so` in both `x86_64-unix/` (Rosetta
pairs it with the PE) and `x86_64-windows/` (FEX finds the PE through NotProton's flat WINEDLLPATH entry and takes
the unixlib beside it). dyld picks the slice. Add only: a file whose sha isn't in our record (`state/runner-files`)
is left alone. Our outdated copies are replaced; files an earlier version installed that this one doesn't (MacVR's
`macvrreg.dll`, for example) are removed if their sha is still ours. NotProton's template identity doesn't see the
added files.

`varborreg.dll` is a registration-only builtin: wineboot applies its `WINE_REGISTRY` script (our registry values,
generated per user into `state/`) whenever it creates or updates a prefix, so NotProton's new templates start right.

## Prefixes

`Rescan.swift`, the way Proton prepares a prefix (and `scripts/setup-vrclient-prefix.sh` by hand):

| Where | What |
|---|---|
| `system.reg` `Software\Khronos\OpenXR\1` | `ActiveRuntime` = `Z:\…\varbor\current\bridge\wineopenxr.json` (XR_RUNTIME_JSON is ignored under Wine) |
| `user.reg` `Software\Wine\VR` | `state` = dword 1, `openvr_vulkan_instance_extensions` = `VK_KHR_surface` (what Proton's steam.exe writes; DXVK reads it) |
| `drive_c/vrclient/bin/vrclient_x64.dll` | placeholder openvr_api.dll loads; Wine runs the runner's builtin. `config/`, `logs/` beside it |
| `drive_c/users/<user>/AppData/Local/openvr/openvrpaths.vrpath` | runtime `C:\vrclient`, read-only (NotProton's steam.exe deletes a writable one) |

- Values MacVR set for its Windows OpenComposite path (`VR_OVERRIDE`, `VR_CONFIG_PATH`, `VR_LOG_PATH` in the HKLM or
  HKCU environment) are removed wherever they point into one of our support dirs, with or without a record (game
  prefixes cloned from an old template have none); openvr_api.dll would prefer them over openvrpaths.vrpath.
- Skipped while the prefix's wineserver runs (its lock in `/tmp/.wine-<uid>/server-<dev>-<inode>/`); NotProton's
  `flock` on `.notproton-prefix.lock` / `.notproton-template.lock` is held while writing.
- Minimal edits: only our lines change; a missing key block is inserted in Wine's tree order. A prefix that's already
  right isn't touched.
- Record `compatdata/<appid>/varbor-vr` (previous line per value, `vrpath|<user>` backups, `vrclient=ours`), backups in
  `varbor-backup/` (`system.reg.orig`, the last 3 copies, foreign vrpath files). Uninstall and exclusion restore
  from them.
- Excluded prefixes (`excluded-prefixes`, the "Use VarboR" switch, `varbor exclude`) are reverted on every rescan,
  because varborreg.dll re-adds the values when wineboot updates the prefix.
- CrossOver bottles (added by the user): same prefix values; the bridge goes to `varbor/bottle-lib/wine` and
  `cxbottle.conf` `[Wine] "LibPath"` gets that dir appended (CrossOver's `bin/wine` overwrites WINEDLLPATH). Record and
  backups live in `varbor/state/bottles/<name>-<hash>/`. CrossOver 26 bottles keep `CurrentControlSet` unlinked: the
  HKLM environment is resolved there. Protected paths (`varbor protect`) are never touched.

## Components

`Components.swift`, read-only, one place for locations, minimum versions (`minimumWiVRn`, `minimumOpenComposite`)
and release pages:
- NotProton: `notproton/install-build.json` (or NotProton.app's version), its runners, its tool registry.
- WiVRn for macOS: the tree behind `XR_RUNTIME_JSON` or `active_runtime.json` (`lib/wivrn/libopenxr_wivrn.dylib` ->
  the tree), else known prefixes (`VARBOR_WIVRN_PREFIX`, `/usr/local`, `/opt/wivrn`,
  `~/Library/Application Support/wivrn`); version from `share/wivrn/build-info` (`wivrn-macos=`), `share/wivrn/ipc-stamp`.
  The server sets the active runtime only when it runs from its configured prefix; until then: a warning.
- OpenComposite for macOS: the first runtime in the macOS `openvrpaths.vrpath` with `bin/osx64/vrclient.dylib` (what
  the vrclient bridge loads), `bin/osx64/version.txt`, and the `oc_metal_submit_sync` export the bridge's GPU sync needs.

## Engines (the VarboR runner)

`Engines.swift`, behind a small interface (`EngineSource`: `metadata(tag:)`, `download(tag:asset:to:)`;
`GitHubEngineSource` for orchardxr/varbor-engines, a fake one in the tests):
- A stock runner `crossover-<build>` (CrossOver version from the build name, stock DXMT version read from
  `lib/dxmt/*/d3d11.dll`, e.g. `v0.80-279-g8f06be3`) maps to the release `cx-<CrossOver version>`.
- `engines.json` (format 1): `crossover`, `stock_dxmt` (versions it fits), `engines` (informational),
  `archive` {`name`, `sha256`}, `files` {path under the runner's `CrossOver/` -> sha256}. Paths must be under `lib/`.
- Install (user action): download, check the archive sha, unpack, check every file against the list (nothing extra,
  no links), then a fresh APFS clone `crossover-<build>-varbor` with the files on top and a `.varbor` marker (tag,
  base, archive sha, file shas), swapped in for an earlier clone. One compat tool per NotProton tool of the stock build
  (`notproton-fex-41073` -> `notproton-fex-varbor-41073`, display name + " - VarboR"), with NotProton's `run` and
  `toolmanifest.vdf` unmodified, and a clone of NotProton's `bridge/wine/<build>`.
- NotProton deletes or hides compat tool dirs it didn't create unless its tool registry lists them, so "Add to
  NotProton…" (`varbor engines register`) appends our lines to `notproton/tools` after asking, keeping a backup in
  `state/backup/notproton-tools.orig`. Steam lists the tools after a restart.
- MacVR's earlier clones (`-macvr`, `-macvrdxmt`, `-macvrdxvk`) are not stock runners; VarboR leaves them alone.

## Layout

```
~/Library/Application Support/varbor/
  versions/<stamp>/bridge/...       stamp = sha256 of the payload's files
  current -> versions/<stamp>       previous -> the one before; others pruned
  state/                            runner-files, varborreg.dll, bottles/<id>/, backup/, engines/ (downloads, temporary)
  settings                          bottles, steam-libraries, protected-paths, excluded-prefixes (JSON arrays)
  bottle-lib/wine/x86_64-{windows,unix}/
~/Library/Logs/VarboR/varbor.log    every change; new at each app start, 9 previous runs kept
```

Nothing a game or Wine touches is under `~/Documents` (TCC prompts).

## From MacVR

MacVR 0.0.1-0.0.5 (`org.macvr.MacVR`, latest release v0.0.5 with `MacVR-0.0.5.zip`) bundled the WiVRn server and
the Windows OpenComposite. VarboR never quits or removes MacVR; the user uninstalls it. While MacVR runs, VarboR
(app and CLI) changes nothing and asks to quit MacVR and reopen VarboR. A MacVR.app still installed gets a notice
(opened again, it would undo VarboR's setup). At its first launch without MacVR running, VarboR:
1. renames `~/Library/Application Support/macvr` to `varbor`, leaving a `macvr` symlink for prefixes still pointing
   there, and `~/Library/Logs/MacVR` to `VarboR`;
2. on each prefix's next rescan: renames `macvr-vr`/`macvr-backup`, replaces values and vrpath files naming the old dir
   (they count as ours, so their recorded originals still restore), removes MacVR's VR_OVERRIDE & co., replaces
   `C:\OpenComposite` vrpath files, moves a bottle's LibPath entry, and drops MacVR's runner files (`macvrreg.dll`).

Self-update: MacVR's updater checks `somsarashvili/macvr` (GitHub redirects to orchardxr/varbor), takes the first
`.zip` asset and requires `MacVR.app` with id `org.macvr.MacVR` and the release's version, so it can't install a
VarboR release by itself. The transition:
1. Release **MacVR 0.0.6** (tag `v0.0.6`, `MacVR-0.0.6.zip`) from the MacVR code (a branch from `11aa529`), changed
   only in its updater: it also accepts a zip holding `VarboR.app` with id `org.orchardxr.varbor` (prefer the
   `VarboR-*.zip` asset), puts it next to itself as `VarboR.app` instead of over `MacVR.app`, quits itself and opens
   VarboR, which then migrates as above. Its release notes ask the user to delete MacVR.app. Keep v0.0.6 the latest release until MacVR users had a chance to update.
2. Release **VarboR 0.1.0** (`v0.1.0`, `VarboR-0.1.0.zip`). VarboR's updater takes only `VarboR-*.zip` and requires
   `org.orchardxr.varbor`.
3. Users still on 0.0.5 at that point get "the release zip has no matching MacVR.app" and download VarboR by hand
   (the release notes say so). Optionally, a VarboR release can carry, uploaded first, a `MacVR-<version>.zip` with
   the 0.0.6 updater stamped as that version: 0.0.5 installs it and it moves on to VarboR. v0.0.4's tag stays unused.

## CLI

```
varbor install [--payload <dir>]   deploy, runner files, rescan (the app does this at every open)
varbor status                      version, components, runner files, each prefix, VR games
varbor rescan
varbor uninstall                   revert prefixes + templates, remove runner files
varbor engines [status|check]      VarboR runner per stock runner (check asks GitHub)
varbor engines install|register <runner>
varbor bottle add|remove <path> | list
varbor library add|remove <path> | list
varbor protect add|remove <path> | list
varbor exclude add|remove <appid|dir> | list
```

Environment for tests: `VARBOR_SUPPORT` (also turns off the MacVR migration), `VARBOR_STEAM_ROOT`, `VARBOR_RUNNERS`,
`VARBOR_LOG_DIR`, `VARBOR_PAYLOAD`, `VARBOR_NO_SYSTEM=1`, `VARBOR_WIVRN_PREFIX`.

## Updates

At launch and every 6 hours the app asks the GitHub API for the latest release of orchardxr/varbor (no drafts or
pre-releases) and compares its tag with `CFBundleShortVersionString`. A newer one is offered once in an alert
(Install / Release Notes / Later, not while a game runs), as a toolbar button, a row on every page and a menu item.
Install downloads `VarboR-<version>.zip`, unpacks it with ditto, checks bundle id, version and signature, then a shell
waits for the app to quit, swaps the bundle (restoring the old one on failure), clears quarantine and opens it.
