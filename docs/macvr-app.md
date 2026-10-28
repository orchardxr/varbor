# MacVR app (window + menu bar + CLI)

Goal: install MacVR.app, open it, launch VR games from Steam. The user edits nothing. Windows VR games run under
NotProton and reach the Quest through our WiVRn server:

game → `openvr_api.dll` → OpenComposite (`vrclient_x64.dll`) → `wineopenxr.dll` + `wineopenxr.so` (bridge) →
`libopenxr_monado.dylib` (universal IPC client: x86_64 under Rosetta, arm64 under FEX) → `wivrn-server` (arm64, child
of MacVR.app) → Quest.

Supersedes the per-launch hook design in [m4-notproton.md](m4-notproton.md): nothing in NotProton's `run` changes.

## Build

```sh
scripts/build-app.sh [--test]        # build/app/MacVR.app, CLI at MacVR.app/Contents/Helpers/macvr
```

- Sources in `app/` (Swift package): `MacVRCore` (all logic), `macvr` (CLI), `MacVRApp` (SwiftUI main `Window` + `MenuBarExtra`),
  `macvr-broker` + `macvr-webhelper` + `CMacVRXR` (web overlays, [web-overlays.md](web-overlays.md)),
  `Tests/MacVRCoreTests` (XCTest, `swift test` in `app/`), `Tests/scratch.sh` (scratch tree, below).
- The payload is copied into `Contents/Resources/payload`: `build/bridge/root` (x86_64 PE, universal x86_64+arm64
  `wineopenxr.so` and client, ipc-stamp; the script refuses thin files),
  `build/m3/oc/bin` (OpenComposite, `opencomposite.ini` = `initUsingVulkan=false`), `$WIVRN_BUILD_DIR/server`
  (default `build/wivrn-next`: `wivrn-server` + `ipc-stamp` + the arm64 client `libopenxr_wivrn.dylib` of the same
  build, for the web helper's overlay session). `Contents/Helpers`: `macvr`, `macvr-broker`, `macvr-webhelper`. The script refuses if the client's and the server's
  ipc-stamps differ. The runtime JSON is generated with `"library_path": "x86_64-windows\\wineopenxr.dll"`.
- Ad-hoc signed (`codesign -s -`): the server binary, the CLI, then the bundle.
- `Info.plist` (`app/Resources/Info.plist`): a regular Dock app (no `LSUIElement`; the Dock icon is drawn at launch),
  `NSAudioCaptureUsageDescription`,
  `NSLocalNetworkUsageDescription`, `NSBonjourServices` = `_wivrn._tcp`, bundle id `org.macvr.MacVR`.

## What the app does

No login item, no LaunchAgent, no global (launchctl) environment: all work happens when the user opens the app.
On open:
1. Deploy the bundled payload (below), unless that version is already current.
2. Runner files: add the bridge to every NotProton runner.
3. Rescan and fix: the prefix templates, then the game prefixes that need it.
4. Start `wivrn-server` as a child process, and `macvr-broker` (web overlays: SteamVR's mailbox server on
   127.0.0.1:27062, which starts `macvr-webhelper` when a game registers its web UI; [web-overlays.md](web-overlays.md)).
   The broker is restarted like the server and exits with the app. If another `wivrn-server` runs (a dev build from `scripts/run-wivrn.sh`),
   it doesn't start its own and shows "another wivrn-server is running".

While open, every 5 s: server state and the server log (headset session, connected OpenXR apps); a probe of each
connected game process (proof for the legacy cleanup, backend hint); a retry of the rescan every 60 s while a prefix
was busy or a legacy install waits, and only while no game runs. The server is restarted if it exits on its own, at
most 3 times in 5 minutes.

Main window (opens at launch, and again from the Dock icon or the menu's "Show MacVR"): stock SwiftUI, a
`NavigationSplitView` with a sidebar and grouped `Form` pages (rows: status dot + title, secondary subtitle, trailing
state / buttons / "…" menu with Reveal in Finder and Copy Path); the toolbar's refresh button is "Rescan Now" (a spinner
while working); an action's error shows on top of every page. Pages: **Status** (setup card: Ready / Setting Up /
Waiting / Needs Attention; server state with Start/Stop; headset; running VR games, backend hint, backend note),
**Games & Prefixes** (Steam game prefixes titled with the game name from the app manifest, and NotProton templates, from
all libraries; state ok / missing values / busy / legacy, "Added" for prefixes in an added library), **Added by You**
(CrossOver bottles with their state and backend warning, Steam libraries; "Add CrossOver Bottle…", "Add Steam
Library…", Remove in the "…" menu), **Runners** (per runner "n of m files ok" and its files), **Logs** (MacVR, WiVRn
server and web overlays logs with Open; Reveal Logs Folder). Sidebar badges count problems. Prefix states refresh after
every rescan and every 30 s while the window is shown. The binaries must record the current SDK (`LC_BUILD_VERSION
sdk`), or macOS draws the window in the legacy style instead of Liquid Glass: SwiftPM stamps the deployment target there,
so `scripts/build-app.sh` passes `-platform_version macos <minos> <xcrun --show-sdk-version>` to the linker.
Closing the window keeps the app, the menu-bar item and the server running. Quit (menu item, Cmd-Q, Dock) stops the
server (`applicationWillTerminate`).

Menu: Show MacVR, Server / Headset / Game status, a backend hint if a VR game runs with a backend other than DXMT or DXVK, setup
state, Start/Stop Server, Open Server Log, Open Web Overlays Log, Open MacVR Log, Rescan Games, About (with the backend note), Quit.
**Quit stops the server.** Nothing else is undone on quit: the prefixes and runner files stay, and without a server a
game's OpenVR init answers "no headset" quietly (OpenComposite 0007).

Backend note (shown in About and `macvr status`): *VR works with the DXMT and DXVK graphics backends (set in the
game's NotProton compatibility settings); DXMT is preferred. D3DMetal isn't supported.* MacVR doesn't set or force
`CX_GRAPHICS_BACKEND`: no launch options, no NotProton defaults file.

## Where things go (hierarchy)

1. **Bridge: the runners.** `wineopenxr.dll` (builtin-marked) goes to every runner's
   `~/Library/Application Support/notproton/runners/crossover-*/CrossOver/lib/wine/x86_64-windows/`, and the universal
   `wineopenxr.so` to both `.../x86_64-unix/` and `.../x86_64-windows/`. Only those 3 files per runner. Rosetta (x86_64
   Wine) pairs the dll with `x86_64-unix/wineopenxr.so`; FEX (arm64 Wine) finds the dll only through NotProton's flat
   WINEDLLPATH entry `lib/wine/x86_64-windows` and loads the `.so` beside it (how NotProton stages lsteamclient;
   [bridge-plan.md](bridge-plan.md) §3, §7a). dyld picks the matching slice, so neither Wine can load a wrong-arch copy.
   The files are added, never replaced: a file there whose sha isn't in our record (`macvr/state/runner-files`, path → sha)
   is left alone and logged. Our own outdated copies are replaced. Checked at every app open, so a runner update or a new
   runner gets them again. `macvr status` shows each `.so`'s slices (`ok (x86_64+arm64)`).
   - Wine pairs the named DLL with the `.so` it finds in its DLL path (the runner's `lib/wine` comes first), so no
     WINEDLLPATH, no Steam restart and no system32 copy is needed. Checked in a scratch clone: the bridge loaded with
     only the runner dirs on WINEDLLPATH, `ipc-stamp match`, `xrCreateInstance` = 0 against WiVRn. With the runner's
     `.so` moved away: `no unixlib`, `xrCreateInstance` = -51 (clean failure).
   - The `.so` loads the IPC client from `~/Library/Application Support/macvr/current/bridge/x86_64-unix/` when
     there is none next to it (bridge change in `wineopenxr_unix.c`), and reads the `ipc-stamp` beside it. Both
     slices use that one universal client; its two slices come from the same WiVRn build, so one stamp covers both.
   - Wine copies every runner builtin (ours too) into a new prefix's system32. A `system32\wineopenxr.dll` therefore
     counts as the legacy hand install only together with `system32\wineopenxr.json`.
   - NotProton's template identity (`template_identity` in `run`: `stat %d:%i:%c` of `CX_ROOT` plus shas of the
     loader, wineserver, wine.inf, ntdll and lsteamclient) doesn't see the added files: verified unchanged on a
     runner clone, so templates are not rebuilt.
2. **Registry: the prefix templates first.** `steamapps/compatdata/notproton-template/<runner_id>/pfx/system.reg` in
   every Steam library gets the values below. New game prefixes are cloned from the template, so they start right.
   NotProton rebuilds a template when its identity changes; the next app open writes the values again.
3. **Registry: individual game prefixes, as a fallback.** Prefixes created before MacVR was installed, or while the
   template was missing or rebuilt. The rescan checks every `compatdata/<appid>/pfx` and adds only missing or
   different values. A prefix that's already right is not touched at all (no file, no backup, no record).

Values (all in `system.reg`, one file per prefix):

| Key (as stored) | Value | Data |
|---|---|---|
| `Software\Khronos\OpenXR\1` | `ActiveRuntime` | `Z:\…\macvr\current\bridge\wineopenxr.json` |
| `System\ControlSet001\Control\Session Manager\Environment` | `VR_OVERRIDE` | `Z:\…\macvr\current\opencomposite` |
| same | `VR_CONFIG_PATH` | `Z:\…\macvr\openvr\config` |
| same | `VR_LOG_PATH` | `Z:\…\macvr\openvr\logs` |

- `XR_RUNTIME_JSON` is ignored under Wine (elevated token), so the registry key is the only way to pick the runtime.
- OpenVR needs all three `VR_*` variables, as Windows `Z:\` paths; with them it doesn't read a vrpath file
  (verified with Alyx by the other agent, 2026-10-26: HKLM Session Manager\Environment and HKCU\Environment both
  work, NotProton's per-launch `reg import` keeps them, `steam.exe` doesn't strip them). Wine stores
  `CurrentControlSet` as a link to `ControlSet001`, so the file edit goes to the `ControlSet001` block.
- Other modes (`macvr set openvr hkcu-env|vrpath|none`): `hkcu-env` writes the same `VR_*` to `user.reg`
  `Environment`; `vrpath` writes a read-only `%LOCALAPPDATA%\openvr\openvrpaths.vrpath` per profile instead
  (NotProton's `steam.exe` deletes a writable one at every launch). Switching modes reverts what the old mode wrote.

How the edit is done (`WineRegistry.swift`, `Rescan.swift`):
- Skipped while a wineserver runs for that prefix (its `lock` in `/tmp/.wine-<uid>/server-<dev>-<inode>/` is held:
  Wine would overwrite the file from memory on exit). Retried later.
- While writing, NotProton's own lock is held (`flock` on `compatdata/<appid>/.notproton-prefix.lock`, or
  `compatdata/.notproton-template.lock`; `run` takes them with `lockf -s -t 0`, which is flock). If `run` holds it,
  the prefix is skipped. A missing lock file is not created.
- Minimal edit: only our value lines change. A missing key block is inserted in Wine's tree order with
  `[key] <unix time>` + `#time=<filetime>`. Values are escaped like Wine does (`\\`, `\"`, `\xNNNN`).
  Written to a temp file in `pfx/`, then renamed, keeping the file mode.
- Backups in `compatdata/<appid>/macvr-backup/`: `system.reg.orig` (before our first edit), plus the last 3 timestamped
  copies.
- Record `compatdata/<appid>/macvr-vr` (or `notproton-template/<runner>/macvr-vr`), written only when we changed
  something: `reg|<file>|<key>|<name>=<previous line or ->`, `vrpath|<user>=…`, `legacy=present|removed:<dir>`.
  A previous value that already pointed into `macvr` (ours) or at the hand install's
  `C:\windows\system32\wineopenxr.json` is recorded as `-` (nothing to restore).

## Layout

```
~/Library/Application Support/macvr/
  versions/<stamp>/                 stamp = sha256 of the payload's files (same payload, same dir)
    bridge/x86_64-windows/wineopenxr.dll
    bridge/x86_64-unix/{wineopenxr.so, libopenxr_monado.dylib, ipc-stamp}   both universal (x86_64 + arm64)
    bridge/wineopenxr.json
    opencomposite/bin/{vrclient_x64.dll, version.txt, opencomposite.ini}
    server/{wivrn-server, ipc-stamp, libopenxr_wivrn.dylib}
    manifest.json                   file shas, install time, the build's manifest
  current -> versions/<stamp>       switched with rename(2) (atomic); previous -> the one before
  openvr/{config,logs}              VR_CONFIG_PATH, VR_LOG_PATH (outside versions/)
  state/                            runner-files, wivrn-server.pid, proven-<appid>, backup/
  settings                          openvr=<mode>, bottles=[…], steam-libraries=[…] (all optional)
  bottle-lib/wine/x86_64-{windows,unix}/   the bridge for CrossOver bottles ([Wine] LibPath)
  state/bottles/<name>-<hash>/      per bottle: macvr-vr record, macvr-backup/
~/Library/Logs/MacVR/macvr.log       every change the app or CLI made; new at each app start (MACVR_LOG_DIR overrides)
~/Library/Logs/MacVR/wivrn-server.log   new at each server start
~/Library/Logs/MacVR/web-overlays.log   broker and web helper, new at each server start
  each keeps its 9 previous runs as <name>.1.log (newest) … <name>.9.log (Log.rotate)
```

- Versions other than `current` and `previous` are pruned.
- Prefixes point at `current`, so an update needs no prefix rewrite. A running game keeps the files it loaded.
- **Server: copied** into the version. It links Homebrew dylibs by absolute path (`/opt/homebrew/opt/...`) and
  `@rpath/libvulkan.1.dylib` with rpath `/usr/local/lib`, so the copy resolves the same libraries. Its shaders are
  compiled in (`wivrn-server_shaders.cpp` includes the `.spv`), so nothing is read from the build tree. Homebrew
  (MoltenVK, glib, x264, …) and the Vulkan loader in /usr/local remain prerequisites.
- Nothing a game or Wine touches is under `~/Documents` (TCC prompts).

## Server

- `current/server/wivrn-server --no-manage-active-runtime` with `VK_DRIVER_FILES` = Homebrew MoltenVK (as
  `scripts/env-macos.sh`), `XRT_LOG=info`, and the low-latency env `WIVRN_PACER_WINDOW=500
  WIVRN_PACER_PERCENTILE=99 WIVRN_CLIENT_MARGIN_MS=2.5` (docs/wivrn.md, 0009). `DYLD_*` and `XDG_RUNTIME_DIR` are
  removed from its environment.
- After the socket `$(getconf DARWIN_USER_TEMP_DIR)wivrn/comp_ipc` appears, the server's ipc-stamp is published to
  `…/wivrn/ipc-stamp` (what `scripts/ipc-stamp.sh publish` does; the bridge wants it newer than the server).
- The app starts it as its own child, so macOS attributes the Core Audio tap (TCC "system audio recording") and Local
  Network access to MacVR.app. `macvr server start` (CLI) starts it detached in its own session (`POSIX_SPAWN_SETSID`);
  then the grant goes to the terminal app.
- Status comes from its log: `Client connected` (headset), `Session paused`/`Waiting for new connection` (headset
  gone), `[client_connected] Client N` + `application_name` + `pid` (games), and a new `WiVRn … starting` line
  (WiVRn re-execs itself after a headset session, same pid) resets it.
- After a server restart the stock Quest client doesn't reconnect by itself (known issue).
- The web helper's overlay session shows up in the server log as client `MacVR web overlays`; the status ignores it
  (not a game). `macvr server start` (CLI) doesn't start the broker.

## CrossOver bottles and extra Steam libraries (added by the user)

Settings (`settings`, one JSON array per key): `bottles`, `steam-libraries`. Both are part of every rescan, `status`
and `uninstall`. Paths under a protected tree (setting `protected-paths`, `macvr protect add <path>`, or `MACVR_PROTECTED_PATHS`,
colon-separated) are refused (also through symlinks) and skipped if put into the settings by hand. Use it for bottles
another tool manages.

**Extra Steam libraries**: `Steam.libraries` = the root, `libraryfolders.vdf`, then the added folders (the library root
or its `steamapps`; duplicates dropped). Remove forgets it and reverts its prefixes unless Steam itself lists the library.
(WiVRn's headset app list still reads only Steam's own libraries.)

**Bottles** (`Bottle.swift`): a 64-bit CrossOver bottle (`cxbottle.conf` + `system.reg`; `WineArch` win32 refused) runs
on CrossOver.app's Wine, which we don't modify, so per bottle:
- Registry: the same values as NotProton prefixes, same rules (skip while its wineserver runs, minimal edit, backups,
  record), but record and backups live in `macvr/state/bottles/<name>-<hash>/`, not in the bottle. No lock file.
- CrossOver 26.3 bottles keep `System\CurrentControlSet` as a real key, not a link to `ControlSet001` (NotProton's
  templates have the link). The HKLM environment values go to whichever of the two holds
  `Control\Session Manager\Environment` (`Rescan.resolve`); writing to ControlSet001 there is invisible to Windows.
- Bridge: `macvr/bottle-lib/wine/{x86_64-windows/{wineopenxr.dll,wineopenxr.so},x86_64-unix/wineopenxr.so}` (the runner
  files, copied from `current`, refreshed by sha). CrossOver's `bin/wine` **overwrites** `WINEDLLPATH` after applying
  `[EnvironmentVariables]` (line ~712: `$ENV{WINEDLLPATH}=$dll_path`), so a WINEDLLPATH there is useless. It builds the
  path from `[Wine] "LibPath"` (default `${CX_ROOT}/lib`): `<lib>/wine/x86_64-windows` and `<lib>/wine` per entry. MacVR
  sets `"LibPath" = "${CX_ROOT}/lib:<macvr>/bottle-lib"` (or appends to an existing value; previous line recorded),
  adding a `[Wine]` section at the end if needed. Resulting WINEDLLPATH (checked): `CX/lib/wine/x86_64-windows:
  <bottle-lib>/wine/x86_64-windows:CX/lib/wine/i386-windows:CX/lib/wine:<bottle-lib>/wine`. Wine finds the PE through the
  flat entry and loads the `.so` beside it (`lsof`: `bottle-lib/wine/x86_64-windows/wineopenxr.{dll,so}`). Wine's own
  `lib/wine` comes first; CrossOver.app ships no wineopenxr. `macvrreg.dll` isn't used for bottles.
- Backend: `[EnvironmentVariables] "CX_GRAPHICS_BACKEND"` (what CrossOver's GUI sets); missing (Auto) or not dxmt/dxvk
  shows a warning in the window, `status` and `bottle add`.
- Remove (window or `macvr bottle remove`) and `uninstall` revert registry and LibPath (byte-identical conf when we added
  the section) and delete the bottle's state dir; `uninstall` also deletes `bottle-lib`. A busy bottle is refused.
- Verified 2026-10-29 on a scratch `win10_64` bottle (CrossOver 26.3, deleted afterwards): `cmd /c echo %VR_OVERRIDE%`
  shows our path, `reg query` reads ActiveRuntime; hello_xr `-g D3D11` with `CX_GRAPHICS_BACKEND=dxmt` and `dxvk`
  (12 s each, real server): bridge `ipc-stamp match`, `xrCreateSession`, server "Started native session, 1 active app
  session(s)" (DXVK also logged compositor layer commits). The bridge logs `MoltenVK (not found)`: it looks for
  `lib/<arch>/libMoltenVK.dylib` (runner layout), CrossOver.app has `lib64/libMoltenVK.dylib` (follow-up in TODO).
  Remove and uninstall: cxbottle.conf byte-identical, no VR values left.

## Legacy hand install (Alyx, `scripts/install-vr-546560.sh`)

It left `C:\macvr`, `C:\OpenComposite`, `system32\wineopenxr.{dll,json}`, a read-only vrpath pointing at
`C:\OpenComposite`, and `WINEDLLPATH="<prefix>/drive_c/macvr"` in Alyx's launch options. The runner copy comes first
in Wine's DLL path, so the leftovers don't shadow the new path. They are removed only once the new path is proven:
- Proof: a connected OpenXR client (pid from the server log) has mapped a runner's `x86_64-unix/wineopenxr.so` and
  `macvr/.../libopenxr_monado.dylib` (`lsof`). The app then writes `state/proven-<appid>`.
- Then the next rescan (no game running) moves the files into `compatdata/<appid>/macvr-backup/legacy-<time>/`
  (not deleted) and records `legacy=removed:<dir>`. While Steam is quit, the legacy `WINEDLLPATH` token is removed
  from the launch options in every `userdata/*/config/localconfig.vdf` (backup in `state/backup/`), keeping the
  user's other tokens. Steam rewrites that file on exit, so this never runs while Steam is running.
- `macvr rescan --migrate-legacy` does it without the proof.
- `~/Library/Application Support/macvr/opencomposite` (an earlier manual setup) isn't used by the new layout; delete
  it by hand once no prefix points at it.

## CLI

```
macvr install [--payload <dir>]   deploy, runner files, rescan (the app does this at every open)
macvr status                      version, runner files, each prefix (ok / missing values / record / legacy / busy),
                                  VR games, legacy launch options, server, headset, games
macvr rescan [--migrate-legacy]
macvr uninstall                   revert prefixes + templates, remove runner files, stop our server
macvr server start|stop|status
macvr set openvr hklm-env|hkcu-env|vrpath|none
macvr bottle add|remove <path> | list     CrossOver bottles (refuses protected paths)
macvr library add|remove <path> | list    extra Steam library folders
macvr protect add|remove <path> | list    trees MacVR never modifies
```

Env for tests: `MACVR_SUPPORT`, `MACVR_STEAM_ROOT`, `MACVR_RUNNERS`, `MACVR_PAYLOAD`, `MACVR_NO_SYSTEM=1` (no Steam
checks), `MACVR_NO_SERVER=1` (the app starts neither wivrn-server nor the broker: a test instance next to the real app).

Uninstall: in every prefix and template, each managed value that still points into `macvr` is restored from the record
(or removed when the record says `-` or there is no record, as for prefixes cloned from our template). Our vrpath
files go, the record goes, and the runner files whose sha is still ours are deleted. A busy prefix makes it stop with
a message; run it again later. Legacy files are not restored. `~/Library/Application Support/macvr` itself is kept.

VR game detection (`status`; the headset's app list does the same in the server, WiVRn patch 0010, see
[wivrn.md](wivrn.md)): Steam's binary app info cache `appcache/appinfo.vdf` (`AppInfo.swift`, v40/v41): `common`
`openvrsupport` / `openxrsupport` / `onlyvrsupport` or category 53/54, type `game` or `demo` (SteamVR is a `Tool`).
Apps missing from the cache fall back to `openvr_api.dll` or `openxr_loader.dll` under the game dir (depth 6),
skipping Unreal's bundled `Engine/Binaries/ThirdParty` and `Engine/Plugins` (many flat UE games ship OpenXR there),
SteamVR (250820) and the redistributables. `status` prints the source (`appinfo onlyvrsupport` or the DLL path).
Not needed for setup: the registry values are harmless for flat games.

## Testing

Unit tests (`cd app && swift test`, 36 tests): launch-option merge/strip, localconfig.vdf edits (replace only the
value, insert into an app block or a new app block, remove), Wine registry edits (sorted block insert, value in an
existing block, delete back to byte-identical, escapes), install idempotence (second run: no file changes) and the
uninstall round trip (byte-identical tree) on a temp tree, an already-correct prefix left untouched, a previous value
restored, vrpath mode switch, runner add-only (foreign file kept; the `.so` in both dirs), Mach-O slice parsing, legacy
kept until proven, Wine's own system32 copy not taken for legacy, server-log parsing (the web overlays client isn't a
game), appinfo.vdf parsing (v41 string table and v40 inline keys, VR flags and categories, SteamVR
excluded as a Tool, truncated data) and `vrGames` (appinfo first, DLL only for apps missing from it); cxbottle.conf parsing and LibPath add/revert
(byte-identical, own LibPath kept), bottle add/rescan/uninstall round trip, remove, protected paths (also via symlink) and
32-bit refusal, unlinked CurrentControlSet, backend warning, settings lists, extra library discovery/removal/dedupe.

GUI check: `MACVR_SUPPORT=… MACVR_STEAM_ROOT=… MACVR_RUNNERS=… MACVR_NO_SYSTEM=1 MACVR_NO_SERVER=1
build/app/MacVR.app/Contents/MacOS/MacVR`, `screencapture -x`, then kill that pid.

Scratch tree (`app/Tests/scratch.sh setup`): APFS clones of the 546560 (VR, legacy install) and 1903340 (flat)
prefixes, the x86_64 template and the `crossover-27.0.0.41073-fex` runner under
`~/Library/Application Support/macvr-test/app`, with a fake Steam library. `eval "$(app/Tests/scratch.sh env)"`
points the CLI at it. Done 2026-10-26:
- `install`: 3 prefixes changed, runner clone got 2 files, template identity hash unchanged; a second `install`:
  0 changed, registry files byte-identical.
- `scratch.sh check-reg <prefix>`: the runner's `wine reg query` reads `ActiveRuntime` and `VR_OVERRIDE`, and
  `cmd /c echo %VR_OVERRIDE%` etc. shows all three in a Windows process.
- Busy: with `wineserver -p` holding the clone, the rescan skipped it ("busy, retry later"); after the server exited
  it was fine (Wine had written its in-memory registry back, which is why we skip).
- Runner mode load test (`xr_path_test.exe` in the 1903340 clone, only the runner dirs on WINEDLLPATH, support =
  the real `~/Library/Application Support/macvr`): see the hierarchy section.
- `uninstall`: template byte-identical to before; prefixes have our values gone (the 1903340 diff is only Wine's own
  timestamps from the test runs); runner files removed.

## Real install (2026-10-26, verified)

`build/app/MacVR.app` copied to /Applications and opened, with the dev server stopped and no game running:
- New version deployed; 4 runner files added (`crossover-27.0.0.41073` and `-fex`); both templates (`aarch64-unix`,
  `x86_64-unix`) and the 546560, 1903340 and 250820 prefixes updated; 546560's legacy install kept. A second rescan:
  0 changed. `wivrn-server` runs as a child of MacVR.app.
- The Quest connected (the first session dropped while the server re-exec'd; reconnecting with the `wivrn://` URI
  worked). Audio is tapped and flows, so the system-audio grant for MacVR is in place.
- Alyx started normally (`steam://rungameid/546560`). `lsof` on hlvr.exe: the runner's `lib/wine/x86_64-unix/wineopenxr.so`
  and `x86_64-windows/wineopenxr.dll`, `macvr/versions/<stamp>/bridge/x86_64-unix/libopenxr_monado.dylib`,
  `macvr/versions/<stamp>/opencomposite/bin/vrclient_x64.dll`. Bridge log: `ipc-stamp match`. Server: 90 fps per eye,
  ~21 Mbit/s, `tapping clients: <pid> (hlvr.exe)`. OpenComposite log: `Interstitial: show_message -> shown`
  ("Press Trigger To Start"). The user checked the start screen and the game in the headset.
- Fix found on the way: Wine overwrites the process's environment area, so `ps eww` shows nothing for game
  processes. The game probe now takes the appid from the mapped `compatdata/<appid>/` files and the backend from the
  runner's `lib/dxmt`, `lib/dxvk` or `apple_gptk` mappings. `macvr server status [--record-proof]` prints the probe.

## FEX and the universal bridge (2026-10-28)

Deployed to /Applications (old app kept in `~/Library/Application Support/macvr-test/MacVR.app.prev`; same server
binary and OpenComposite as before): version `4e235795eada`, 6 runner files (3 per runner), `rescan: 0 changed`.
The system32 legacy-detection fix above is in `build/app/MacVR.app` but not deployed yet.
- Scratch: runner clones of `crossover-27.0.0.41073` and `-fex` under `macvr-test/app/runners`, `install` → 6 files
  `ok (x86_64+arm64)`, second `install` → 0, `uninstall` removes exactly ours. hello_xr D3D11/DXMT through WiVRn on
  the clones at 90 Hz with `ipc-stamp match`: FEX, fex-rosetta and preview.
- Real: Alyx once on each tool (`lsof`): FEX loads `x86_64-windows/wineopenxr.so` (arm64 slice) + `lib/aarch64` MoltenVK,
  fex-rosetta and preview load `x86_64-unix/wineopenxr.so` (x86_64 slice); all with `macvr/current/.../libopenxr_monado.dylib`.
  Numbers in [bridge-plan.md](bridge-plan.md) §7a.
- A game moved to `notproton-fex` needs an aa64 prefix (NotProton offers a rebuild); the rebuilt template/prefix lacks
  our registry values until the next rescan (app open or `macvr rescan`), so the first launch after a switch has no VR.
