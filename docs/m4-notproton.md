# Milestone 4 design: NotProton installs the VR bridge per game

Goal: when Steam launches a VR game through NotProton, the compat tool's `run` script:
- installs the bridge (`wineopenxr.dll`/`.so`, [bridge-plan.md](bridge-plan.md)) and OpenComposite
  ([m3-opencomposite.md](m3-opencomposite.md)) into that game's prefix;
- makes sure our native WiVRn server is running in the GUI session;
- keeps Steam from starting SteamVR (250820).

Non-VR games must see no change at all.

**Superseded (2026-10-26) by the VarboR app, [varbor-app.md](varbor-app.md):** no patch to `run`; bridge files in the
runners, registry values in the prefix templates and prefixes, the server as a child of the app.

Status (2026-10-24): design only, from a read-only survey. Nothing in NotProton, Steam or any prefix was changed.
*Verified* means read from files on this Mac. *Test* means the behaviour has to be confirmed by a run (§8).

## 0. What NotProton does today (read-only survey)

Installed files (NotProton.app 1.2.1, `install-build.json`):

| Path | Notes |
|---|---|
| `~/Library/Application Support/Steam/compatibilitytools.d/notproton-{preview,fex-rosetta,fex}-41073/` | `run` (1914 lines, `/bin/sh`), `toolmanifest.vdf` (`commandline "/run %verb%"`), `compatibilitytool.vdf`, `build`, `flavor`. The three `run` files are identical, sha256 `2461fa622ed4135d650132056045b457681af99ec61a7d8f7e77bcf9afbcd622`. Only `build`/`flavor` differ. |
| `~/Library/Application Support/notproton/` | `runners/crossover-27.0.0.41073[-fex]/`, `bridge/` (lsteamclient, `steam.exe`, steamclient DLLs, legacycompat, patched ntdll), `appinfo` (arm64; prints only `name`/`icon`/`clienticon`), `launchers/<appid>/<Game>.app`, `tools`. There is no `defaults-*` file today. |
| `notproton.dylib` (injected into Steam) | Hooks `CCompatManager::*` and `CAppManager::TerminateProcessByPid` (`notproton.log`). |

NotProton.app lists `notproton-*/run` as install content (`app.log`: `installContent=update([... "notproton-preview-41073/run" ...])`).
- **An edited `run` is overwritten** the next time the user clicks Install/Update in NotProton.app. §6 handles this.

Launch path in `run` (line numbers are for sha256 `2461fa62…`):

| Lines | What happens |
|---|---|
| 164–173 | Picks the Wine flavor: `wine_unix` = `x86_64-unix` (Rosetta) or `aarch64-unix` (FEX). |
| 189–217 | `defaults-<flavor>` whitelist. It sets `CX_GRAPHICS_BACKEND` only if the environment hasn't; `np_from_defaults KEY` tells the two apart. |
| 246 | `WINEDLLPATH=$CX_ROOT/lib/wine/x86_64-windows:$wine_unix[:$WINEDLLPATH]` |
| 288–292 | `app_id` resolved and logged. |
| 1415–1462 | Prefix lock (`.notproton-prefix.lock`, fd 8), `wineserver -k`, template seed, game drive, `import_prefix_settings`, fonts. |
| 913–990 | `import_prefix_settings`: builds a `.reg` file and runs **one** `wine reg import` per launch (line 962). |
| 1575–1647 | Steam bridge staging into `drive_c/Program Files (x86)/Steam`. Lines 1619–1625 **prune every other `*.dll`/`*.so`/`*.exe` there.** Line 1632 prepends that directory to `WINEDLLPATH`; line 1635 sets `WINEDLLOVERRIDES`. |
| 1664–1680 | Non-`waitforexitandrun` verbs (install scripts = `run`) exit here. |
| 1699–1843 | Per-game launcher bundle `notproton/launchers/<appid>/<Game>.app`. |
| 1877–1898 | **The game's environment is rebuilt from an explicit `--env` list.** Only `Steam*`, `CX_GRAPHICS*`, `D3DM_*`, `DXMT_*`, `DXVK_*`, `FEX_*`, `MTL_*`, `ROSETTA_*` and the fixed `WINE*`/`STEAM_COMPAT_*` variables pass. |
| 1904 | `open -n -W -a <launcher.app> --args "C:\Program Files (x86)\Steam\steam.exe" <game> …`: the game runs as a LaunchServices app in the GUI session, **not** as a child of `run`. |

Consequences:
- A launch option such as `VR_OVERRIDE=… %command%` reaches `run` but **not the game**. M3's env-only OpenVR variant
  only works if the `--env` list is extended (hunk H4 below).
- The game is wrapped by NotProton's `steam.exe` shim (`bridge/steam.exe`). It is built from Proton's steam_helper and
  contains `setup_vrpaths`, `setup_vr_registry`, `initialize_vr_data` and `load_vrclient`, plus the strings
  `PROTON_VR_RUNTIME`, `VR_OVERRIDE`, `VR_CONFIG_PATH`, `VR_LOG_PATH`, `VR_PATHREG_OVERRIDE`, `/.config` +
  `/openvr/openvrpaths.vrpath` and `C:\vrclient\` (*verified*, `strings`).
  - Same as Proton: the VR init thread (load SteamVR's vrclient, write `HKCU\Software\Wine\VR`) is gated on
    `PROTON_VR_RUNTIME` ("Linux OpenVR runtime is not available"). NotProton never sets it, and it isn't in the `--env` list.
    *Verified*: no `Software\Wine\VR` key in the user.reg of 546560, 250820 or a non-VR game's prefix.
  - `setup_vrpaths` converts `$HOME/.config/openvr/openvrpaths.vrpath`, which doesn't exist here, into the prefix's
    `%LOCALAPPDATA%\openvr\openvrpaths.vrpath`. Without it, it deletes the prefix file on every launch (*verified*
    2026-10-24, hence the read-only file in M3).

### vrclient route (tested 2026-10-26, not kept)

Goal: let `steam.exe` write the prefix vrpath the Proton way (`runtime C:\vrclient\`, `C:\vrclient` → OpenComposite)
instead of the read-only file. Setup: host `~/.config/openvr/openvrpaths.vrpath` (runtime = the prefix's
`drive_c/OpenComposite` as a unix path, config/log under `~/Library/Application Support/varbor/openvr`), prefix vrpath
made writable, `drive_c/vrclient -> OpenComposite`. Backup: `build/backup/546560/20261026-032143-vrclient/`.

Result: **steam.exe never sees the host file and deletes the prefix vrpath.** Alyx then stopped at a modal "SteamVR
initialization failed! VRInitError_Init_PathRegistryNotFound (110)".
- Cause (*verified* with a PE probe run in the 546560 prefix): `HOME` and `XDG_CONFIG_HOME` are not in the Windows
  environment under CrossOver's Wine, so `get_linux_vr_path()` returns "" and `setup_vrpaths` takes the delete branch.
  Proton's steam.exe is a winelib binary whose `getenv` reads the unix environment. NotProton's is a PE build of the
  same code (`strings`: `/openvr/openvrpaths.vrpath`, `C:\vrclient\`, `/bin/linux64/vrclient.so`), so its `getenv`
  reads the Windows environment.
  - The path would also be wrong: `read_text_file` passes the unix path to `CreateFileW`. Wine resolves `/Users/...`
    against the current drive, which is `S:` for a game, not `Z:`.
- With `VR_PATHREG_OVERRIDE='Z:\Users\<user>\.config\openvr\openvrpaths.vrpath'` the conversion works (steam.exe
  started alone with `cmd /c exit`, 2.3 s). It wrote `runtime [C:\vrclient\, C:\vrclient]` and config/log as `Z:\...`.
- But that variable can't reach the game cleanly. `run`'s `--env` list drops it, so a Steam launch option doesn't
  work. Only `launchctl setenv` would deliver it, and that's global for every LaunchServices app: the kind of workaround
  M3 just removed (`IPC_IGNORE_VERSION`).
- With the variable set, steam.exe also sets `PROTON_VR_RUNTIME` to the host runtime path, creates the volatile
  `HKCU\Software\Wine\VR` key, and starts `initialize_vr_data`, which dlopens `<runtime>/bin/linux64/vrclient.so`.
  That fails at once and is logged with WINEDEBUG=err ("Could not load libopenvr_api.so."). It is harmless, but noise.
- Other prefixes: without the variable nothing changes (HOME is unset, so they keep the delete branch). With it,
  every game's prefix vrpath would point at `C:\vrclient`. A prefix without `C:\vrclient` then fails OpenVR init the
  same way it does now with no file, and flat games don't read it. This was inferred from the code; no flat game was
  launched.
- Decision: restored the backup exactly (read-only vrpath, no host file, no `C:\vrclient`, registry files from the
  backup; my direct `wine` probes had switched the prefix locale to en-NZ). The read-only file stays the mechanism.
  M4's H4 (`--env` list) could carry `VR_PATHREG_OVERRIDE` if NotProton is ever patched; that is not ours to do.

### VR_OVERRIDE route (tested 2026-10-26, kept for Alyx)

Goal: OpenVR finds OpenComposite with no `openvrpaths.vrpath` in the prefix, from a copy outside the prefix:
`~/Library/Application Support/varbor/opencomposite/bin/{vrclient_x64.dll,version.txt,opencomposite.ini}` plus empty
`config/` and `logs/`. The prefix vrpath was deleted (backup with mode 444: `build/backup/546560/20261026-040953-oc0008/`).

- **All three variables are needed.** With only `VR_OVERRIDE` and no vrpath, Alyx failed with
  `VRInitError_Init_PathRegistryNotFound (110)`: `openvr_api` takes the env-only path only when `VR_OVERRIDE`,
  `VR_CONFIG_PATH` and `VR_LOG_PATH` are all set (M3's env test used all three too). When all three are set the vrpath file
  isn't read, so a leftover file is harmless.
- **Windows paths only.** `ovr_d3d11_test.exe` in the scratch prefix: `Z:\Users\...\varbor\opencomposite` gives
  `VR_IsRuntimeInstalled 1` and `VR_Init` 108 (OpenComposite loaded, no server); the unix form `/Users/.../opencomposite`
  gives `VR_IsRuntimeInstalled 0` and `VR_Init` 100 `InstallationNotFound` (Wine resolves `/Users/...` on the current drive).
- **steam.exe keeps it.** Proton's `convert_linux_vrpaths` clears `VR_OVERRIDE` only after a successful conversion; under
  NotProton it always fails (no `HOME`), so it only deletes the (absent) prefix vrpath and leaves the variables alone.
- Variants, each with Alyx launched by `scripts/alyx-save.sh`, no vrpath, everything else unchanged. Every one reached the
  save: `vrclient_x64.dll` mapped from `~/Library/Application Support/varbor/opencomposite/bin` (`lsof` on hlvr.exe),
  OpenComposite read that dir's `opencomposite.ini`, bridge `ipc-stamp match`, server 2x90 fps and audio 200 packets/s
  `tap clients: <pid> (hlvr.exe)`:

| Variant | Result |
|---|---|
| `launchctl setenv` (`VR_OVERRIDE` only) | 110 dialog, see above |
| `launchctl setenv` of all three | works. Global for every LaunchServices app, and lost on reboot (would need setting at login). Not kept. |
| prefix `HKCU\Environment` (all three, `wine reg add`) | works |
| prefix `HKLM\System\CurrentControlSet\Control\Session Manager\Environment` (all three) | works. **Kept for Alyx.** |

Wine builds each process's Windows environment from these keys, so the variables reach `steam.exe` and the game without
`run`'s `--env` list or anything global. NotProton's per-launch `reg import` left them in place. For M4 this replaces the
read-only vrpath: the per-prefix install writes three registry values (Windows paths to a shared copy outside the prefix)
instead of a file that `steam.exe` tries to delete. Registry backup before the change: `build/backup/546560/20261026-041651-envreg/`.

## 1. Detecting that a game wants VR

The detection runs in hunk H1 (after `run` line 292). It is evaluated only for `verb=waitforexitandrun`. Install
scripts come in as `run` and are never VR. The first rule that matches wins:

| # | Signal | Where | Result |
|---|---|---|---|
| 1 | Env `VARBOR_VR=0\|1` (Steam launch option `VARBOR_VR=1 %command%`) | `run`'s environment. Launch-option env reaches `run`, *verified* by a non-VR game's `VAR=1 … %command%` launch option in `localconfig.vdf`. | off / on |
| 2 | Per-game file `~/Library/Application Support/varbor/games/<appid>` | Keys `vr=on\|off`, optional `backend=dxvk\|dxmt\|keep`, `opencomposite=on\|off`, `headset_wait=<s>`. It lives outside compatdata, so it survives a prefix rebuild. | off / on |
| 3 | appinfo: the launch entry being run has `type "vr"` | `steamapps/../appcache/appinfo.vdf` (5 MB, binary v29). Our arm64 helper `varbor-appinfo <vdf> <appid>` prints `onlyvr=`, `openvr=`, and one `launch=<type>\t<exe>\t<args>` per Windows entry. The hook matches `$1` (the target exe) and the remaining args against those entries. Cached per appid in `varbor/cache/appinfo-<appid>` and keyed by the vdf mtime. | on if the matched entry is `type vr`, or if `onlyvrsupport=1` |
| 4 | appinfo `openvrsupport=1` without a `vr` launch match (hybrid game in desktop mode) | same | off (logged as a candidate) |
| 5 | `openvr_api.dll` or `openxr_loader.dll` under `$STEAM_COMPAT_INSTALL_PATH` (`find -maxdepth 5`) | game dir | **off**, log only: "VR-capable, opt in with VARBOR_VR=1" |
| 6 | appid 250820 | — | SteamVR policy, §4 |

*Verified* with a scratch parser (`appcache/appinfo.vdf`, read-only):
- 546560 Half-Life: Alyx: `onlyvrsupport 1`, `openvrsupport 1`, Windows launch 0 `game/bin/win64/hlvr.exe -vr -steam … type vr`.
- A non-VR control game: no VR keys, launches `type default`.
- 250820 SteamVR: Windows launch 0 `bin\win64\vrstartup.exe`.

Why rule 5 doesn't install anything: a passive install without a running server makes OpenComposite's
`xrCreateInstance` fail, and OpenComposite's abort is a message box that hangs (M3). Flat games that ship
`openvr_api.dll` must stay untouched.

The helper is a ~150-line C file (`notproton/tools/varbor-appinfo.c`), built arm64 by `scripts/build-notproton-vr.sh`.
NotProton's own `appinfo` can't be extended, and `/usr/bin/python3` needs the Command Line Tools, which a user
machine may lack.

FEX flavor: when `${wine_unix##*/}` is `aarch64-unix`, VR is refused with a log line and an alert for VR-only games,
until M2 step 6. Alyx is mapped to `notproton-fex-rosetta-41073` (`config.vdf` `CompatToolMapping "0"`), which uses
`x86_64-unix`.

## 2. Per-prefix install (idempotent, versioned)

### Deployed files (ours, outside Steam)

```
~/Library/Application Support/varbor/
  notproton/hook.sh                    sourced by the patched run (all logic lives here, §6)
  notproton/varbor-appinfo, varbor-vrstatus   arm64 helpers
  bridge/<stamp>/x86_64-windows/wineopenxr.dll   builtin-marked PE (bridge/tools/mark-builtin.py)
  bridge/<stamp>/x86_64-unix/wineopenxr.so
  bridge/<stamp>/x86_64-unix/libopenxr_wivrn.dylib   x86_64 IPC client from the WiVRn tree (TODO: build after the Rosetta reboot)
  bridge/<stamp>/wineopenxr.json, IPC_STAMP
  bridge/current -> <stamp>
  opencomposite/<oc-ver>/bin/{vrclient_x64.dll,version.txt}, opencomposite/current -> <oc-ver>
  wivrn/<stamp>/{wivrn-server,IPC_STAMP,wivrn-launch.sh}, wivrn/current -> <stamp>
  games/<appid>                         opt-in files (§1)
~/Library/LaunchAgents/org.varbor.wivrn.plist
~/Library/Logs/varbor/wivrn-server.log
```

`scripts/notproton-vr.sh deploy` copies these from `build/` and switches `current` atomically (`ln -sfn` + `mv`).
The hook resolves `current` to its real versioned path once per launch, so a deploy during a game never swaps files
under a running process.

### Per-prefix record

`$STEAM_COMPAT_DATA_PATH/varbor-vr`, written last, after everything else succeeded:

```
version=1
bridge=<stamp>        oc=<oc-ver>
dll_sha=<sha256 of the system32 copy>
prev_active_runtime=<value or "-">     (from system.reg before our first install)
vrpath=ours|foreign|none
```

### Steps

All steps run from `varbor_stage_prefix` (hunk H3), under NotProton's prefix lock. Each step compares with `cmp -s`
first, like `install_lsteamclient_trigger`, so a second launch changes nothing.

1. **Builtin and unixlib.** Prepend the resolved `bridge/<stamp>` to `WINEDLLPATH` after line 1632, so it
   ends up as `$prefix_steam:$varbor_bridge:$CX_ROOT/…`. Wine finds `<dir>/x86_64-windows/wineopenxr.dll`, and the
   unixlib is `<dir>/x86_64-unix/wineopenxr.so` (bridge-plan §3, *verified* in M2).
   - Do **not** stage into `Program Files (x86)/Steam`: lines 1619–1625 delete anything there that isn't in
     `bridge_files`.
   - The runner has no `wineopenxr` or `vrclient` of its own (*verified*), so the order can't shadow anything.
2. **system32 placeholder:** `cp -c` the builtin-marked `wineopenxr.dll` and `wineopenxr.json` to
   `pfx/drive_c/windows/system32/`.
   - Wine looks in the DLL path only once a same-named placeholder exists (bridge-plan §3), which is what
     `run-bridge.sh` does.
   - Choosing a system32 copy over a WINEDLLPATH-only install: the copy is the trigger, and the WINEDLLPATH copy is what
     loads.
3. **OpenXR runtime key**, through NotProton's own single `reg import` (hunk H2, `varbor_reg_lines`):
   ```
   [HKEY_LOCAL_MACHINE\Software\Khronos\OpenXR\1]
   "ActiveRuntime"="C:\\windows\\system32\\wineopenxr.json"
   ```
   - Before the first install, read the old value offline from `pfx/system.reg` with awk (the `plan_logpixels`
     pattern) and record it.
   - Re-asserted every VR launch at no extra cost: the import already runs every launch.
   - No `wineserver` restart is needed: the OpenXR loader reads the key at `xrCreateInstance`.
   - SteamVR's `installscript_817940.vdf` only adds a firewall entry and never touches this key (*verified*).
4. **OpenComposite:** `cp -c` `vrclient_x64.dll` and `version.txt` to `pfx/drive_c/varbor/opencomposite/bin/`, and
   create `config/` and `logs/`.
   - Using `C:\varbor\…` instead of M3's `C:\OpenComposite` means we own the whole tree, and uninstall is a single
     `rm -rf drive_c/varbor`.
   - Write `bin/opencomposite.ini` = `initUsingVulkan=true`. M3 verified that one ini serves both D3D11 and Vulkan games.
5. **OpenVR runtime path.** Two mechanisms:
   - **Primary: the file.** `pfx/drive_c/users/steamuser/AppData/Local/openvr/openvrpaths.vrpath` (`crossover` is a
     symlink to it), with `runtime`/`config`/`log` under `C:\varbor\opencomposite`.
     - Overwrite it only if it's absent or byte-identical to ours. A foreign file is backed up to
       `varbor-vr.vrpath.orig` and recorded `vrpath=foreign`.
     - The file is the primary because the env variant needs H4 and may be cleared by `steam.exe` (§0).
   - **Secondary: env.** H4 passes `VR_OVERRIDE`/`VR_CONFIG_PATH`/`VR_LOG_PATH`; the hook exports them with the same
     DOS paths. With all three set, `openvr_api` ignores the file (M3, *verified* with plain Wine). Whether they
     survive `steam.exe` is test T5. Keep them only if T5 passes. If it fails, the file still works.
6. **Graphics backend:** `CX_GRAPHICS_BACKEND=dxvk` when VR is on and the user didn't set it. "User set" means set
   in the environment, not by `np_from_defaults CX_GRAPHICS_BACKEND`. A per-game `backend=keep` skips this.
   - Set in H1, so the existing `CX_GRAPHICS*` passthrough at line 1878 carries it.
   - Native Vulkan VR games ignore the variable. Non-VR games are never touched.
7. **Runtime env for the unix side** (through H4):
   - `VARBOR_OPENXR_RUNTIME=<bridge/<stamp>>/x86_64-unix/libopenxr_wivrn.dylib`.
   - Optional `WINEOPENXR_DEBUG`, `MONADO_SYNC_STATS`.
   - Don't pass `XDG_RUNTIME_DIR`. Under `open` the game's env comes from launchd, so it's unset unless someone ran
     `launchctl setenv`. The hook warns if `launchctl getenv XDG_RUNTIME_DIR` is non-empty.
   - Note: bridge-plan §6 says the bridge clears `XDG_RUNTIME_DIR`, but `wineopenxr_unix.c` doesn't. Either add the
     `unsetenv` or fix the doc.
8. **Version check:** `bridge/<stamp>/IPC_STAMP` must equal `wivrn/current/IPC_STAMP` (§3).
   - On a mismatch, show an alert ("VR bridge and WiVRn server are from different builds, run
     `scripts/notproton-vr.sh deploy`") and exit 1 for VR-only games. For hybrid games, launch flat with VR off.
9. Write `varbor-vr` and log `=== varbor: VR bridge <stamp> + OpenComposite <ver> staged ===`.

Upgrade: when the record's `bridge`/`oc` differ from `current`, steps 2 and 4 replace the files, which `cmp` catches
anyway, and the record is rewritten. The registry and vrpath contents don't depend on the version.

## 3. WiVRn server in the GUI session

Constraint: the Monado client finds the service's Mach port with `bootstrap_look_up` on the per-login-session
bootstrap (patch 0012, name `org.macvr.monado.<uid>.<socket>.<fnv>`). The socket is
`$(getconf DARWIN_USER_TEMP_DIR)wivrn/comp_ipc` (patch 0010 + `XRT_IPC_MSG_SOCK_FILENAME "wivrn/comp_ipc"`). That
directory exists here (*verified*).

Steam, `run` and the game all live in the user's Aqua session. The game is started by LaunchServices (`open`), so it
is a launchd child in `gui/<uid>`.

| Option | Verdict |
|---|---|
| **LaunchAgent `org.varbor.wivrn`**, started on demand by the hook | **Recommended.** See below. |
| Spawn from `run` | Rejected. Steam's Stop kills `run`'s process group and children (`run` lines 395–398 say so), so the server would die with any game, or need a `setsid`/reparent dance like `run_rebuild`. One server for all games, its pairing keys and its log belong outside a game's lifetime. Local Network TCC would also be attributed to Steam. |
| launchd on-demand via `MachServices` | Possible later: 0012 already tries `bootstrap_check_in` before `bootstrap_register2`. But the name contains a hash of the socket path, and clients connect to the socket before the Mach lookup, so on-demand activation wouldn't trigger. Not now. |

Why the LaunchAgent:
- It runs in `gui/<uid>`, the same bootstrap namespace as the game.
- It works when started from ssh or an agent shell (`launchctl kickstart gui/501/…`), which today's
  `run-wivrn.sh` can't do (TODO: "Bootstrap namespace is per login session").
- WiVRn's self-`execv` after a session (macOS port, patches/wivrn 0001) keeps the pid, so launchd is fine with it.

`~/Library/LaunchAgents/org.varbor.wivrn.plist`:
- `ProgramArguments` = `varbor/wivrn/current/wivrn-launch.sh`. It sources the `env-macos.sh` equivalents
  (`VK_DRIVER_FILES` for Homebrew MoltenVK) and execs `wivrn-server --no-manage-active-runtime`.
- `LimitLoadToSessionType` `Aqua`, `ProcessType` `Interactive` (no App Nap or background QoS on the encoder),
  `RunAtLoad` false, `KeepAlive` false.
- Logs: `StandardOutPath`/`StandardErrorPath` `~/Library/Logs/varbor/wivrn-server.log`. The pairing PIN shows up
  there, so `notproton-vr.sh pair` tails it.
- Don't set `XDG_RUNTIME_DIR`.

`wivrn-server` links Homebrew dylibs by absolute path and `@rpath/libvulkan.1.dylib` with rpath `/usr/local/lib`
(*verified*, `otool`), so a copied binary still resolves. Whether the `.spv` shaders are embedded or read from the
build tree: test T2.

Hook sequence (H3, VR games only, before the launcher bundle):
1. Load the agent if needed: `launchctl print gui/$uid/org.varbor.wivrn >/dev/null 2>&1 || launchctl bootstrap gui/$uid
   ~/Library/LaunchAgents/org.varbor.wivrn.plist`.
2. Start it: `launchctl kickstart gui/$uid/org.varbor.wivrn`. Without `-k` this is a no-op if it's already running.
3. Wait up to 10 s for the socket (`[ -S "$sock" ]`).
4. Headset readiness: `varbor-vrstatus` (arm64, ~40 lines) does the same `bootstrap_look_up` as the client and prints
   `ready` or `no-service`.
   - Whether WiVRn registers the Mach service only once a headset session exists is **test T2**. If it does, a game
     started before the headset connects fails in `xrCreateInstance`.
   - So the hook polls `varbor-vrstatus` for `headset_wait` seconds (default 60), with an `osascript` dialog in the style
     of `show_alert`: "Start WiVRn on the Quest". Buttons: Wait / Launch anyway / Cancel.
5. Version match:
   - `IPC_STAMP` = `git -C third_party/monado write-tree` of the **staged** index that `build-wivrn.sh --snapshot`
     exports, plus the socket name.
   - That tree covers WiVRn's Monado patches and ours, i.e. everything that defines the IPC protocol, the Mach HELLO
     (`MACH_IPC_VERSION`) and the swapchain kinds.
   - `build-wivrn.sh` writes `build/wivrn/IPC_STAMP`. The x86_64 WiVRn-client build for the bridge (same snapshot)
     writes `build/bridge/root/IPC_STAMP`.
   - `deploy` refuses to install if the two differ. The hook re-checks (§2 step 8).
   - WiVRn-only server patches (`patches/wivrn`) don't change the stamp, so a server-only rebuild needs no bridge rebuild.

## 4. Keeping Steam from starting SteamVR

| Fact | Status |
|---|---|
| Alyx's only Windows launch entry is `type "vr"`, so no launch-option choice gives a non-VR entry. Launch options can't change the type. | *verified* (appinfo) |
| The mac client logs "Failed to init SteamVR because it isn't installed" at every start. It looks for the mac SteamVR app; only the Windows depot is installed. | *verified* (`console_log.txt`) |
| The only 250820 launches in the logs are a manual `LaunchApp` (2026-10-17, through `notproton-fex-41073/run waitforexitandrun …vrstartup.exe`) and install scripts. | *verified* |
| Alyx has never been game-launched (its `notproton-run.log` only has the install-script `run` verb). So what Steam does for a `type vr` launch on macOS is unknown. | **test T6** |
| `steam.exe` won't start SteamVR's vrclient without `PROTON_VR_RUNTIME`. | *verified* (strings + no `Wine\VR` keys); behaviour **T5** |
| Host `~/Library/Application Support/OpenVR/.openvr/openvrpaths.vrpath` still points at the deleted `SteamVR.app`. The stale LaunchAgent `com.valvesoftware.steamvr.ipctool` points at a missing binary. Neither one is read by a Windows `openvr_api` in a prefix. | *verified*; leave them |

Options, in order:
1. **Guard in `run` (in the patch, default on):** H1 checks `app_id = 250820`. If any varbor VR game is running
   (lock file `varbor/run/vr-session.<appid>`, created in H3 and removed after `wait` at line 1908 by hunk H5) or
   `VARBOR_BLOCK_STEAMVR=always` is set, it logs `=== varbor: refused SteamVR (250820) ===` and exits 0.
   - This runs before the prefix lock, so 250820's prefix is never touched.
   - `VARBOR_ALLOW_STEAMVR=1` as a launch option on SteamVR bypasses it.
   - This covers Steam starting 250820 through the compat tool. It costs nothing when Steam doesn't do that.
2. **Uninstall SteamVR (250820).** Nothing in M3/M4 needs it. It's the most robust, and the user can reinstall it.
   Recommend it if T6 shows Steam starting 250820 in a way the guard can't stop, e.g. a mac-native attempt with a dialog.
3. **Compat-tool mapping for 250820 → a stub tool** (`compatibilitytools.d/varbor-nosteamvr/run` = `exit 0`). Same
   effect as 1, but it needs NotProton's Steam hooks to accept a non-NotProton tool (unknown) and it's a Steam setting.
   Kept as a fallback only.
4. Stub `vrstartup.exe`: rejected. It modifies Steam content, and verify/update restores it.

## 5. Uninstall and rollback

- **Per prefix**, `scripts/notproton-vr.sh prefix-uninstall <compatdata>`, or automatic when a game turns VR off
  (`VARBOR_VR=0` or `vr=off` while a `varbor-vr` record exists):
  - Remove `system32/wineopenxr.{dll,json}`, but only if the dll's sha equals `dll_sha`.
  - `rm -rf drive_c/varbor`.
  - Remove the vrpath if it's ours, or restore `.orig`.
  - The registry change goes through H2 at the next launch: `"ActiveRuntime"="<prev>"`, or `"ActiveRuntime"=-` when
    the record says `-`. Then delete the record. Offline uninstall (no launch) runs the runner's `wine reg import` with
    the same lines; that is the only step that starts Wine.
- **Leftovers if only `run` is reverted:** with a key and a system32 copy left in the prefix but no WINEDLLPATH entry,
  Wine loads the system32 PE as a builtin without its unixlib. `xrNegotiateLoaderRuntimeInterface` must then fail
  cleanly: the PE side checks the `__wine_unix_call` status. Unit-test it (T4f). OpenXR games then behave as if no
  runtime were installed.
- **Global:** `scripts/notproton-vr.sh revert`:
  - restores the pristine `run` in each tool dir, only where the current sha equals our patched sha;
  - `launchctl bootout gui/$uid/org.varbor.wivrn`;
  - removes the plist and `~/Library/Application Support/varbor` (prompting first, because it holds the opt-in files).
- **Emergency:** NotProton.app → Install rewrites the pristine `run`. The hook file then simply isn't sourced.

## 6. Packaging as a patch to NotProton

NotProton isn't a git repo. It's three identical installed copies of one script, managed by NotProton.app.

**Plan: a local snapshot repo, so the existing `scripts/patches.sh` flow works unchanged.**
- `scripts/notproton-snapshot.sh` creates `third_party/notproton/` as a local git repo, read-only like the other
  third_party trees.
  - It contains the pristine `run` (plus `toolmanifest.vdf` for reference) copied from
    `compatibilitytools.d/notproton-preview-41073/`.
  - Each NotProton version is committed once (`np-1.2.1`, sha256 `2461fa62…`).
  - It refuses if the three tool dirs disagree or if the file already carries our marker (`# varbor:`).
  - Not pushed anywhere: NotProton is commercial, so the repo keeps only the diff with its minimal context.
- `patches/notproton/BASE` = that commit. `patches/notproton/0001-varbor-vr-hooks.patch` is created with
  `scripts/patches.sh new notproton varbor-vr-hooks`, staged, never committed (D4 style).
- `scripts/notproton-vr.sh install` checks each `compatibilitytools.d/notproton-*/run`:
  - pristine (sha == BASE's `run`): install the patched file;
  - already ours (sha == patched): no-op;
  - anything else (NotProton updated): stop, and tell the user to run `notproton-snapshot.sh` and rebase 0001.
  - It installs through `cp` to `run.varbor-new`, `chmod 755`, `sh -n`, then `mv -f` (atomic).
  - Pristine backups go to `varbor/notproton/backup/<tool>/run.<sha>`, never into the tool dir, because NotProton.app
    manages that dir.
  - `status` prints pristine/patched/foreign per tool. A Steam-start check (or the hook itself, by logging its
    version) shows when NotProton.app has reverted the file.

The patch stays tiny; all logic lives in `hook.sh`, which is ours and versioned in the repo as
`notproton/hook.sh`. The hunks:

| Hunk | Insertion point (pristine `run`) | Content |
|---|---|---|
| H1 | after line 292 (`echo "app_id=…"`) | Define no-op `varbor_reg_lines`, `varbor_stage_prefix` and `varbor_after_exit`. If `$HOME/Library/Application Support/varbor/notproton/hook.sh` is a regular file: `. "$hook" && varbor_detect \|\| echo "=== varbor: hook failed, launching without VR ===" >> "$log"`. `varbor_detect` does §1, the 250820 guard (§4) and `CX_GRAPHICS_BACKEND=dxvk`. Every hook function returns 0 except deliberate refusals (`set -e` is on). |
| H2 | line 954: `&& winebus_lines; } \` | `&& winebus_lines && varbor_reg_lines; } \` (§2 step 3, §5) |
| H3 | between line 1647 (`fi` closing bridge staging) and 1649 (`export WINEDEBUG`) | `varbor_stage_prefix \|\| exit 1`: §2 steps 1, 2, 4, 5 and 7–9, plus §3. It runs while the prefix lock (fd 8) is still held; line 1650 releases it. |
| H4 | line 1878, the `--env` regex | Add `VARBOR_\|WINEOPENXR_\|MONADO_\|VR_` to the group `(CX_GRAPHICS\|D3DM_\|…\|ROSETTA_)`. `VR_` matches `VR_OVERRIDE`/`VR_CONFIG_PATH`/`VR_LOG_PATH`; don't add `XR_` (`XR_RUNTIME_JSON` would be a unix path). |
| H5 | after line 1910 (`kill_wine_prefix`) | `varbor_after_exit`: remove `varbor/run/vr-session.<appid>`. It leaves the server running (an idle server costs ~0 CPU; `VARBOR_STOP_SERVER=1` boots it out). |

If NotProton changes the surrounding lines, the 3-line context of each hunk makes `git apply` fail loudly instead of
patching the wrong place.

## 7. Implementation order

1. Rosetta reboot, then build the x86_64 `libopenxr_wivrn.dylib` client and the `IPC_STAMP` plumbing in
   `build-wivrn.sh`/`build-bridge.sh`.
2. `notproton/tools/varbor-appinfo.c`, `varbor-vrstatus.c` (arm64), `notproton/hook.sh`, `scripts/notproton-vr.sh`,
   `scripts/notproton-snapshot.sh`, `notproton/org.varbor.wivrn.plist.in`.
3. The snapshot repo plus patch 0001.
4. Tests T1–T4 on scratch copies (no Steam).
5. Install the patched `run`, then T5–T7 with Steam.

## 8. Test plan

Scratch only until T5. Nothing writes to a real compatdata, a tool dir or NotProton's support dir. One exception: the
patched `run` always creates `notproton/launchers/<appid>/`, so the tests use the fake appid **4100000546**, and
cleanup removes `launchers/4100000546` and `launchers/4100000001`.

```sh
S="$HOME/Library/Application Support/Steam"; T=build/m4
mkdir -p $T/compatdata $T/tool
cp -cR "$S/steamapps/compatdata/546560"  $T/compatdata/4100000546      # APFS clone of the Alyx prefix (VR)
cp -cR "$S/steamapps/compatdata/<flat appid>" $T/compatdata/4100000001  # control: non-VR game prefix
cp "$S/compatibilitytools.d/notproton-fex-rosetta-41073/"{run,build,flavor,compatibilitytool.vdf,toolmanifest.vdf} $T/tool/
# patch $T/tool/run from third_party/notproton (staged 0001); the tool dir name only matters for prefix rebuilds
```

A small driver, `tests/notproton/run-scratch.sh`, sets what Steam would and then calls `$T/tool/run
waitforexitandrun <exe> [args]`:
- `STEAM_COMPAT_DATA_PATH`, `STEAM_COMPAT_INSTALL_PATH` (a scratch dir holding the test exe), `STEAM_COMPAT_APP_ID`,
  `STEAM_COMPAT_CLIENT_INSTALL_PATH`, `STEAM_COMPAT_LIBRARY_PATHS`.

| # | Test | Pass when |
|---|---|---|
| T0 | `git apply --check` of 0001 on the snapshot; `sh -n` and shellcheck on the patched `run` and `hook.sh`; `notproton-vr.sh status` on copies of the tool dirs | All clean. Status reports pristine, then patched, then foreign after a 1-byte edit. |
| T1 | `varbor-appinfo` against the real `appinfo.vdf` (read-only) | 546560 → `onlyvr=1`, `launch=vr game/bin/win64/hlvr.exe …`; the non-VR game → no VR; 250820 → SteamVR; a missing appid → empty, exit 0. |
| T2 | LaunchAgent alone: `notproton-vr.sh deploy`, `launchctl kickstart`, then native `hello_xr` from Terminal with `XR_RUNTIME_JSON=build/wivrn/openxr_wivrn-dev.json` | Socket present; `varbor-vrstatus` = `no-service` without a headset and `ready` with the Quest. This also records whether the Mach service exists before the headset connects. The server log shows the shaders loaded from the deployed copy. Repeat the kickstart from an ssh shell: same result. |
| T3 | VR install into the 4100000546 clone with `VARBOR_VR=1`, exe `build/m3/tests/ovr_d3d11_test.exe 300` + `openvr_api.dll`, `VARBOR_SERVER=null`. That hook test mode starts `build/bridge` monado-service with the frame dump, plus the current `libopenxr_monado` client, instead of WiVRn. | `notproton-run.log` shows the staged lines; OpenComposite log in `C:\varbor\opencomposite\logs`; frame-dump PNG with the M3 pattern; `system.reg` has `ActiveRuntime`; `varbor-vr` record written. |
| T4 | Idempotence and versioning on the same clone | (a) A second launch: `cmp` everywhere, no file mtimes change except the logs. (b) A new `bridge/<stamp>`: files replaced, record updated. (c) A deliberately mismatched `IPC_STAMP`: alert and exit 1, no launch. (d) `VARBOR_VR=0`: uninstall; `system.reg`/`user.reg` diff against the pre-T3 clone equals only Wine's timestamps. (e) A foreign vrpath is preserved as `.orig` and restored. (f) Revert only `run`, leave the prefix installed: the OpenVR test exits with an error, no hang. |
| T4c | Control: 4100000001 clone, no opt-in, `hello_xr.exe -g D3D11` as the exe | Hook logs `not VR`. No `wineopenxr` files, no `drive_c/varbor`, `system.reg` diff = timestamps only, `CX_GRAPHICS_BACKEND` as before (dxmt default), no `launchctl` calls (the launchd log shows no kickstart). |
| T5 | `steam.exe` interplay, inside T3's run (the shim is in the path) | The prefix vrpath is unchanged after the launch, i.e. `setup_vrpaths` with no Linux file leaves it alone. Separately, run with only the env variant (no file) to see whether `VR_OVERRIDE` survives `steam.exe`. Neither result blocks M4, because the file variant is primary. |
| T6 | Real Steam, patched `run` installed, the Quest on WiVRn: launch Alyx | Grep `logs/console_log.txt` for `GameAction [AppID 250820` / `vrstartup` and `notproton-run.log` for `varbor: refused SteamVR`; watch for any Steam "SteamVR" dialog. Alyx renders in the headset. |
| T7 | Control with real Steam: launch the non-VR game | Its `notproton-run.log` is the same as before apart from the `varbor: not VR` line. Same backend, same FPS, no server start. |

Cleanup: `rm -rf build/m4`, plus the `launchers/41000*` dirs, and `launchctl bootout` the agent if T2 loaded it.

## 9. Open questions

- Does the mac client do anything VR-specific for a `type vr` launch (T6)? It decides whether §4 option 1 is enough.
- WiVRn's Mach service lifetime relative to headset sessions (T2). It decides the headset-wait dialog.
- FEX flavor (M2 step 6): x86_64 PE in an arm64 Wine. Until then the hook refuses VR on `aarch64-unix`.
- NotProton.app's Install restores the pristine `run`. If upstream would accept a generic hook (`run` sourcing
  `~/Library/Application Support/notproton/hooks/*.sh` at H1/H2/H3/H5), the patch goes away entirely. Worth asking
  the author.
