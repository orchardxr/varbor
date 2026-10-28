# Half-Life: Alyx A/B: SteamVR reference stack vs macvr (2026-10-24)

Stack A ("reference", a separate private prototype): Windows Steam + SteamVR in a CrossOver bottle (Rosetta),
patched DXMT, vrlink → Steam Link VR on the Quest 3S.
Stack B ("macvr"): native Steam + NotProton (stock DXMT, msync) → OpenComposite → wineopenxr bridge → WiVRn server
(build/wivrn-next, VideoToolbox zero-copy) → WiVRn client 26.9.

## Method
- Same save `s6/steamvr_quit` (balcony), loaded hands-free (A: the reference stack's own save loader; B:
  `scripts/alyx-save.sh`). Unpaused, hlvr.exe activated (`lsappinfo front` = hlvr.exe in both).
- Shortened on request: one 30 s window per stack after ≥ 20 s settle (not 2 × 60 s).
- Recorder `tools/mql-ab/abrecord.sh <label> 30`, summary `tools/mql-ab/abstats.py build/ab/<label>`; raw files
  in `build/ab/` (`a.*`, `b.*`, screenshots `a-quest.png`, `b-quest.png`, `a-mac.png`, `b-mac.png`).
- Game fps: Metal HUD os_log (`MTL_HUD_LOG_ENABLED=1` prints `metal-HUD: <frame#>,…` once a second; the frame counter
  delta gives fps). GPU time: on-screen HUD snapshot only (the log's other fields are `<private>`).
- CPU: `ps` every 2 s (100 % = one core).
- Mac on Ethernet, Quest on Wi-Fi, `caffeinate -dimsu` running, no Screen Sharing session.
  The headset view is identical in both screencaps (same spot, same direction).

## Matched settings
| | A | B |
|---|---|---|
| Display refresh | 72 Hz (`steamvr.preferredRefreshRate`) | 72 Hz, requested with `build/ab/xr_refresh 72` (XR_FB_display_refresh_rate from an overlay session; server log `changed 90 -> 72`) |
| Base per-eye size | 2064×2208 (vrserver: "New result of GetRecommendedRenderTargetSize: 2064x2208", SteamVR 100 %) | WiVRn recommends 2198×2302; OpenComposite `supersampleRatio=0.949` → 2085×2184 (same pixel count ±0.1 %) |
| Alyx fidelity | `vr_fidelity_level_auto 0`, `vr_fidelity_level 3` (VConsole) | same |
| Alyx swapchain | — (vrlink) | 5904×3092 (both eyes, allocated at the max level = 1.416 × base, OpenComposite log) |
| Bitrate | vrlink adaptive | WiVRn client default (adaptive off), 2 streams |

## Results (30 s each)
| Metric | A reference | B macvr |
|---|---|---|
| Game fps (HUD counter) mean / min 1-s | **69.6** / 63.8 | **66.5** / 61.0 |
| HUD snapshot: fps, GPU, frame interval | 71.9, **8.45 ms**, 13.9 ms | 66.1, **13.95 ms**, 15.1 ms |
| hlvr.exe CPU mean / p95 | 303 / 317 % | 310 / 334 % |
| wineserver | 47 % | 35 % |
| Runtime CPU | vrserver 44 + vrcompositor 12 + vrmonitor 6 + vrwebhelper 4 + encoder helper 3 + VTEncoderXPC 2 = **71 %** | wivrn-server 40 + VTEncoderXPC 7 = **47 %** |
| Stream fps | 69.8 (only new frames are sent) | 72.0 per stream (compositor rate) |
| Encode | 7.60 ms per frame (one 4-band frame) | p50 2.84 / p95 3.26 ms per eye stream (parallel) |
| Bitrate | 52 Mbit/s (+20 filler dropped) | 2 × 71.8 Mbit/s |
| Latency figures | frame path avg 8.96 ms (max 13.3), 0 Bad link events | network p50 5.2 / p95 8.0 ms; present>decoded p50 17.6 / p95 26.2 ms |

## Caveats
- One 30 s window per stack; differences of ~1-2 fps are within run-to-run noise seen in the reference stack's notes.
- Not the same D3D11 layer: A runs the reference stack's patched DXMT (e.g. fast QPC for tier0, keyed-mutex changes), B runs
  CrossOver's stock DXMT plus the bridge's extra full-frame copy per eye. The GPU time gap (8.45 vs 13.95 ms, single
  HUD snapshots) is the main difference and is not yet explained.
- OpenComposite always reports `Prop_DisplayFrequency_Float` = 90 to Alyx; fidelity was pinned, so only Alyx's own
  frame budget logic could differ.
- Base sizes have the same pixel count but a slightly different aspect (2085×2184 vs 2064×2208).
- Game Mode showed On in B and Off in A (HUD).
- A had `MTL_HUD_ENABLED=1` in the environment of the whole bottle Steam (only hlvr.exe presented/logged HUD frames);
  B has it in Alyx's launch options.
- Latency numbers are each stack's own and not comparable (vrlink frame path vs WiVRn client feedback); Steam Link's
  ping is only logged with Bad link events (none occurred).
- `b.wivrn` includes one extra 10-s summary after the window.

## Changed and restored
- WiVRn refresh: 90 → 72 → 90 Hz (`build/ab/xr_refresh 90`, confirmed `now 90.0 Hz`, stream back at 90 fps).
- `compatdata/546560/.../OpenComposite/bin/opencomposite.ini`: `supersampleRatio=0.949` added, original restored
  (backup `build/ab/opencomposite.ini.orig`); Alyx relaunched, swapchain back to 6224×3259.
- Alyx `vr_fidelity_level_auto` set back to 1 in both stacks (not archived cvars).
- `launchctl setenv MTL_HUD_LOG_ENABLED 1` for B's launch, then unset.
- Reference stack and bottle configs untouched; bottle Steam/SteamVR quit (`steam.exe -shutdown`, `wineserver -k`),
  its encoder helper stopped. End state (per user): Alyx quit, native Steam idle, WiVRn server running, Quest in the WiVRn client lobby.

## GPU bottleneck (2026-10-25)
Stack B only, same save/spot/settings as above (72 Hz, fidelity 3, MSAA 4x, `supersampleRatio=0.949`). Tools:
`tools/mql-ab/gpurun.sh <label>` (abrecord window + 5-s `xctrace` Metal System Trace of all processes),
`gpuexport.sh` + `gputrace.py` (GPU busy time per process, hlvr.exe split into DXMT / bridge MoltenVK / HUD command
buffers), `gpufreq.c` (IOReport GPU/CPU P-state residency, no sudo), `gpustress.m` (compute load that kicks the GPU
clock up). Raw files: `build/ab/{g0,m2b,b0,b1,b3,b4,b4r,ms0,ms1,k1}.*`.

**GPU time per frame (trace, first session, 65.9 fps):** hlvr.exe DXMT work 12.6 ms (game + OpenComposite copies;
the copies ~0.75 ms, because OpenComposite copied the whole 5904x3092 two-eye texture once per eye), bridge copy 0.44 ms,
WiVRn compositor + VideoToolbox 0.15 ms, overlap of the game's work with WiVRn ~0.1 ms. The GPU was 85 % busy, almost
all of it Alyx's own render passes. Contention from the bridge or WiVRn isn't the gap.

**The 13.95 ms HUD GPU time is a GPU clock effect.** In that session the GPU ran at P1/P2 (338/618 MHz of 1578)
the whole time. In later sessions it ran at P15, and the same work took 8.2-8.7 ms/frame, the same as stack A's
8.45 ms. Instruments labels the state "Minimum/Maximum GPU Performance state due to active device conditions".
That label only names the DVFS state; nothing was induced (a compute stress reaches P12-P15 at any time). The state
is bistable and drifts between runs and Steam/Alyx restarts. A 5-s `gpustress` kick flips it to P15 for ~10-15 s.

| Run | Bridge sync | GPU P-state | Game fps |
|---|---|---|---|
| g0 (old code) | keyed mutex | P1/P2 | 65.9 |
| b0 / b1 / b3 | keyed mutex | P15 | 61.3 / 59.9 / 62.5 |
| k1 | keyed mutex | P2/P3 | 69.2 (kicked to P15: 56-62, back at P2/P3: 67-72) |
| b4r | CPU wait | P15 | 69.3 (72 steady in short samples) |
| ms1 / ms0 | CPU wait | P1 (94 %) | 37.3 / 37.6 (kicked to P15: 72) |

- Keyed-mutex mode (the default) is CPU-bound. It runs *faster* at low GPU clocks (67-72) than at P15 (56-62).
  Presumably this is the shared CPU/GPU power budget, with hlvr at ~300 % CPU under Rosetta. This was not measured
  directly; the CPU P-state residency was inconclusive.
- `WINEOPENXR_DXMT_SYNC=cpu` serialises CPU and GPU (the release spins until the eye is rendered). At P15 it gives
  72 fps, but the governor then decays to P1, and the release wait grows to 11.7 ms per eye (37 fps). Not usable as
  a default.
- MSAA 2x (`vr_msaa 2` + reload): 12.6 → 12.1 ms GPU, +3 fps; Alyx already runs 4x (`vr_msaa` 4, default 8). Stock
  DXMT doesn't create 8x textures on Apple GPUs, and the reference stack's DXMT patch clamps 8x to 4x, so both stacks render 4x.
  Its other DXMT patches (timestamps, D3D10 interfaces) only change what SteamVR's vrclient measures, not GPU
  work. No DXMT patch explains a GPU gap, so no diagnostic DXMT build was made.
- msync off (`WINEMSYNC=0`, launch option, restored): the "msync: warn: node memory pool exhausted" flood stops
  (~3.9 MB/s into `notproton-run.log` with msync on), hlvr 269 → 210 % and wineserver 24 → 13 % CPU at P1. fps is
  unchanged at both P-states (37.6 at P1, 72 after a kick).
- Real refresh rate (OpenComposite 0006): Alyx logs `Refresh Rate: 72.00 Hz` instead of 90. No measurable fps
  change at a pinned fidelity.
- Refresh chain: the client has a fixed preferred rate (no "requesting refresh rate" auto-adjust lines; 90 Hz on
  every (re)connect, `default_fps()`). `xr_refresh 72` changes the headset end to end (`dumpsys display`
  renderFrameRate 72, stream 72 fps). It stays at 72 across app sessions: with no session the server logs `request
  refresh rate: 0Hz` every 10 s, but 0 sends nothing. A headset reconnect resets it to 90.
- Bridge release cost (`WINEOPENXR_STATS`, keyed mutex): handoff 0.03 ms; copy submit + host
  `xrReleaseSwapchainImage` 1.5-2.6 ms on average, max 11-16 ms per 300 frames. **Corrected below:** that timer ran
  from each eye's release to the end of `xrEndFrame`, so it included the game's own work; the bridge's real cost is
  0.7 ms per frame and it is not the source of the spikes.

**Kept fixes (our code):**
- OpenComposite 0006: copies only the submitted bounds (`copyBoundsOnly`, default on), and reports the runtime's rate
  through XR_FB_display_refresh_rate (`runtimeRefreshRate`, default on).
- Bridge: the DXMT copy is deferred to `xrEndFrame` and limited to the layers' imageRect. It is now 2087x2186 instead
  of 5904x3092, and the bridge's GPU time drops from 29 to ~5 ms/s. `WINEOPENXR_DXMT_DEFER=0` restores the old
  behaviour.
- Bridge: `C:\macvr\wineopenxr.env` (WINEOPENXR_* lines). NotProton's launcher forwards only CX_/DXMT_/MTL_/... env,
  so WINEOPENXR_* never reached the game. Also new: `WINEOPENXR_LOG=<file>`, because the bridge's stderr is dropped.

Together these save ~0.8 ms GPU/frame, but fps doesn't move because the game isn't GPU-bound at either clock state.

**Remaining gap vs A:** within run-to-run noise: k1 69.2 / b4r 69.3 vs A 69.6. B's results depend on the GPU DVFS
state, which we don't control. Open items: the `xrWaitFrame` pacing spikes (next section); the msync node-pool flood (NotProton/Wine); and
whether A's GPU also sits at low clocks (A's P-states were not measured).

Changed and restored: WiVRn 90 → 72 → 90 Hz; `opencomposite.ini` (ini with test toggles, original restored);
`C:\macvr\wineopenxr.env`/`.log` (removed); `vr_msaa` 2 → 4, `vr_fidelity_level_auto` 0 → 1; launch option WINEMSYNC
1 → 0 → 1 (`localconfig.vdf` restored byte-identical from `build/ab/localconfig.vdf.orig`, `notproton-msync` restored);
launchctl MTL_HUD_LOG_ENABLED / WINEOPENXR_* unset and Steam restarted. Kept: the new `wineopenxr.dll` (system32 and
C:\macvr), `wineopenxr.so` and `vrclient_x64.dll` in the Alyx prefix. The previous files are in `build/ab/installed-orig/`.

## Bridge render-thread cost and async xrEndFrame (2026-10-25)
Same save/spot/settings (72 Hz via `xr_refresh 72`, fidelity 3 pinned, MSAA 4x, `supersampleRatio=0.949`), bridge
with per-frame stats (`WINEOPENXR_STATS=2`, docs/bridge-plan.md §4a). Tools: `tools/mql-ab/asyncrun.sh <label> <mode>`
(Alyx restart per mode), `asyncab.sh <label> <mode>...` (one Alyx session, `WINEOPENXR_ASYNC` switched live between
30-s windows, so all modes see the same session and GPU clocks), `bridgestats.py` (fps, 1% low = mean of the worst 1 %
intervals, spikes, bridge ms from the per-frame lines). Raw files: `build/ab/{s0,a1,a2,x-*,p-*}.*`, full bridge log
`build/ab/async-wineopenxr.log`.

**Where the frame-thread time goes (s0, sync):** the bridge's own time per frame is 0.7 ms mean, ~2 ms p99, max 5-9 ms
in 30 s: acquire 0.3 (host acquire, which waits for the compositor to free the image; the 5-9 ms maxima are there),
`xrEndFrame` 0.3 (host `xrEndFrame` 0.13, host releases 0.08-0.1, D3DKMT acquire + release 0.06, copy unix call 0.02 with
`vkQueueSubmit` 0.01 and no ring-fence wait), release 0.04, begin 0.04. None of it is near 11-16 ms.

**What the spikes are:** `xrWaitFrame`. The game's own frame (interval minus wait) is 8-12 ms, enough for 72 fps,
but the wait alternates between returning at once and blocking 20-34 ms (p99 30-33 ms). The frame intervals are
spread over 8-40 ms rather than quantised to 13.9/27.8 ms. Monado's app pacer (`u_pacing_app`, in the WiVRn server)
counts OpenComposite's whole frame as "draw" (OC calls `xrBeginFrame` right after `xrWaitFrame`), adds the GPU tail
and 2 ms of margin, and when that sum crosses one period it predicts a display time one or two periods later and
puts the app to sleep. One test with `U_PACING_APP_USE_MIN_FRAME_PERIOD=1` on the server (`p-*`, server log
`build/ab/p.wivrn-server.log`) was inconclusive: that session ran at P2/P3, 65 fps, 1% low 29, wait p99 26 ms. Pacing
is the next lead; it is not a bridge issue. **Corrected in "Frame pacing" below:** WiVRn uses its own app pacer, not
`u_pacing_app`, so that variable had no effect.

**Old vs new, one session, alternating windows (x-1..6, GPU P15 73-76 % in every window):**

| Window | Bridge | fps (HUD) | fps (frames) | 1% low | intervals >20 ms / >25 ms | bridge ms on frame thread mean/p99/max | worker ms mean/p99/max |
|---|---|---|---|---|---|---|---|
| x-1 | sync | 63.3 | 63.5 | 25.1 | 264 / 181 | 0.71 / 2.45 / 6.72 | - |
| x-4 | sync | 63.3 | 63.1 | 25.2 | 290 / 198 | 0.72 / 2.10 / 8.86 | - |
| x-2 | async 1 | 63.8 | 63.7 | 24.9 | 271 / 178 | 0.41 / 1.58 / 4.83 | 0.30 / 0.71 / 1.20 |
| x-5 | async 1 | 62.2 | 62.2 | 25.1 | 320 / 230 | 0.40 / 1.49 / 6.57 | 0.29 / 0.67 / 2.87 |
| x-3 | async 2 | 62.9 | 63.1 | 25.2 | 282 / 206 | 0.39 / 1.48 / 2.46 | 0.30 / 0.74 / 7.12 |
| x-6 | async 2 | 60.3 | 60.3 | 25.0 | 384 / 280 | 0.39 / 1.50 / 2.91 | 0.29 / 0.66 / 3.49 |

Separate sessions: s0 sync 58.8 fps (P15 73 %), a1 async 1 63.9 (P15 77 %), a2 async 2 66.2 (P2/P3), the
run-to-run noise the live A/B avoids. The fps drift down over the session (63 → 60) is the same in both modes.
Async halves the bridge's frame-thread time (0.7 → 0.4 ms) and removes its >4 ms frames, but fps, 1% low and spike
counts don't change. In mode 2 the worker's host `xrEndFrame` sometimes takes 6-7 ms (it runs beside the host
`xrWaitFrame` on the same IPC connection). Decision: `WINEOPENXR_ASYNC` stays available, default off.

Headset image (Quest screencap at the balcony, copyBoundsOnly + imageRect copy, both async 2 and sync):
`build/ab/async-quest.png`, `build/ab/sync-quest.png`. Both eyes complete and aligned, normal stereo offset, no
crop or shift; the two are identical.

Changed and restored: WiVRn 90 → 72 → 90 Hz (and one server restart with the pacer variable, then the standard
command again); `opencomposite.ini` (+`supersampleRatio=0.949`, original restored, `cmp` equal to
`build/ab/opencomposite.ini.orig`); `C:\macvr\wineopenxr.env`/`.log` removed; `vr_fidelity_level_auto` 0 → 1;
launchctl `MTL_HUD_LOG_ENABLED` set, then unset, Steam restarted both times. Installed: the new `wineopenxr.dll`
(system32, C:\macvr) and `wineopenxr.so` (async off by default, stats available); the previous files are in
`build/ab/installed-pre-async/`.

## Frame pacing (2026-10-25)
Same save/spot/settings (72 Hz via `xr_refresh 72`, fidelity 3 pinned, MSAA 4x, `supersampleRatio=0.949`, bridge sync
mode with `WINEOPENXR_STATS=2`). Tools: `tools/mql-ab/pacingrun.sh <label>` (asyncrun without the async switch, plus a
5-s `gpustress` kick 4 s before the window and the pacer-trace slice), `wivrn-restart.sh <build dir> <hz> [VAR=..]`
(server restart + Quest reconnect + refresh), `pacertrace.py` / `pacerlatch.py` for the diag server's trace
(`patches/diag/wivrn-app-pacer-trace*.patch`, `WIVRN_PACER_TRACE`), `xr_empty_frames` with `XR_EMPTY_WORK_MS` (fixed
CPU frame between `xrBeginFrame` and `xrEndFrame`, OpenComposite-style) and wait/interval stats at exit. Raw files:
`build/ab/{fp-*,pn-*,pf-*,pg-*,ph-*,pm4-*}.*`, headset `build/ab/pacing-quest.png`.

**Root cause: WiVRn's app pacer, not the bridge, OpenComposite or Alyx.** WiVRn uses its own
`server/driver/app_pacer.cpp`, not Monado's `u_pacing_app`, so the earlier `U_PACING_APP_USE_MIN_FRAME_PERIOD` test changed
nothing. A native arm64 app with a fixed 10 ms frame shows the same behaviour as Alyx (25 s, 72 Hz, old server):
56 fps, 344 intervals > 20 ms; even a 0 ms frame had 62-80. The per-frame trace shows three causes:
1. The wake target is `display - (cpu + gpu + compositor time + margin)`. The compositor time is the raw
   `extra_ns` of the last compositor frame, which is measured from the compositor's actual wake. It jumps 4-20 ms frame
   to frame (the compositor's wake interval varies 4-28 ms), and the app's wait jumps with it.
2. GPU time is counted from `xrEndFrame`, and it includes the wait for the previous frame to leave the scheduled slot
   (`comp_multi` waits for one frame at a time). Holding frames longer made the pacer think the app was slower, which
   moved display times out and held frames longer still, until `gpu > period` switched to "don't wait" mode (seen as
   tails of 10-55 ms with ~1 ms of real GPU work).
3. A frame late by even 0.01 ms moved to the next display slot, and the following frame then waited a whole extra
   period (the 16-20 ms waits after a 15-16 ms Alyx frame).

**Fix:** WiVRn patch 0007 + Monado patch 0015 (docs/wivrn.md): compositor-time envelope, GPU time from the handoff,
late tolerance of a quarter period, margin 4 ms. The bridge, OpenComposite and the client library are unchanged.

| Run (30 s) | Server | GPU P15 | fps | 1% low | intervals > 20 / > 25 ms | `xrWaitFrame` p99 / max ms |
|---|---|---|---|---|---|---|
| fp-base1 | old | 83 % | 66.6 | 26.4 | 168 / 139 | 22.9 / 52.8 |
| fp-base2 | old | 79 % | 62.4 | 25.1 | 283 / 190 | 31.9 / 34.9 |
| fp-new72a | new | 47 % (P2/P3 42 %) | 71.1 | 36.1 | 43 / 16 | 12.9 / 22.3 |
| fp-new72b | new | 87 % | 72.0 | 48.7 | 8 / 1 | 8.6 / 14.5 |
| fp-base90 (90 Hz) | old | 92 % | 82.8 | 34.1 | 129 / 58 | 16.9 / 22.8 |
| fp-new90 (90 Hz) | new | 97 % | 89.9 | 63.8 | 1 / 0 | 6.5 / 9.8 |

fps and 1% low come from the bridge's per-frame intervals (= game frames; Metal HUD logging was off). Intermediate builds
(diag server, trace on): GPU-time + envelope fixes only, 70.7 fps / 39 spikes (fp-fix1); + late tolerance 70.9-71.1 /
28-37 (fp-fix2, fp-fix1b), where 4-6 % of compositor frames repeated the previous Alyx frame; + margin 4 ms 71.9 / 15,
0.7 % repeats (fp-fix3). Native app, 72 Hz, new pacer: 0 ms frame 71.9 fps / 6 spikes, 8 ms 71.8 / 1, 10 ms 70.1 (that
app's 10 ms sleep really takes 11-16 ms, so it is at the limit). Most remaining spikes are real overruns (an Alyx frame
> period + margin), which cost one display slot; fp-new72a's extra spikes coincide with the GPU at P2/P3.
Headset image: `build/ab/pacing-quest.png` (balcony, both eyes complete).

Changed and restored: WiVRn 90 → 72 → 90 Hz, several server restarts (diag server `build/wivrn-diag`, old binary for
the 90 Hz baseline), now the standard command with the new `build/wivrn-next`; `opencomposite.ini` (+`supersampleRatio`,
`cmp` equal to `build/ab/opencomposite.ini.orig`); `C:\macvr\wineopenxr.env`/`.log` removed (log kept as
`build/ab/pacing-wineopenxr.log`); `vr_fidelity_level_auto` 0 → 1. Previous server binary and client dylib:
`build/backup/wivrn-next-pre-pacing/`.

Remaining: WiVRn's compositor latency (`extra`) is 45-110 ms depending on the session (its `safe present>decoded` is a
p99.5), so the predicted display time is far ahead (latency, not fps); the compositor's own wakes are irregular (4-28 ms
apart at 72 Hz), not investigated; the GPU DVFS state still varies between runs.

## A/B after pacing fix (2026-10-25)
Stack A as in the first A/B (reference bottle, patched DXMT, SteamVR + vrlink → Steam Link VR); stack B with the WiVRn
pacing fix (`build/wivrn-next`, 0007/0015), stock bridge settings (no `wineopenxr.env`, sync mode, stats off).

**Method.** Both stacks measured by the same wrapper (a scratch copy of `pacingrun.sh`'s tail): 20 s settle after the
save load (11 s idle, 5-s `gpustress` kick, 4 s), then 30 s of `abrecord.sh` + `gpufreq 30` + one Mac screenshot at
15 s (Metal HUD GPU time), summarised with `abstats.py`. Loads: B `scripts/alyx-save.sh`, A the reference stack's
reset and save-load scripts run in place with `MTL_HUD_ENABLED=1 MTL_HUD_LOG_ENABLED=1` in their
environment; B via launch option + `launchctl setenv MTL_HUD_LOG_ENABLED 1` and a native Steam restart. Fidelity
`vr_fidelity_level_auto 0` + `vr_fidelity_level 3` (VConsole) in every run. The Quest's display rate was checked after
each window (`dumpsys display` renderFrameRate) and no rate change was logged in any window. Raw files:
`build/ab/{a72-1,a72-2,a90-1,a90-2,b72-1..5,b90-1,b90-2}.*` (+ `-mac.png`).

**Settings.** 72 Hz: A `steamvr.preferredRefreshRate` 72 (bottle default); B `xr_refresh 72`. 90 Hz: B `xr_refresh 90`;
A needs the vrsettings file, so `steamvr.vrsettings` was backed up, `preferredRefreshRate` set to 90, SteamVR restarted
(the reference stack's restart script), and the file restored from the backup after the bottle was shut down (sha256
`b4f2a544…cb9cff`, byte-identical; SteamVR had also rewritten its `gpuSpeed*` history, which the restore reverts). Pixel
count: B `opencomposite.ini` `supersampleRatio=0.949` (2085×2184 vs A's 2064×2208). Mac on Ethernet, `caffeinate`.

The Metal HUD log has one line per second (frame counter; the other fields are `<private>`), so there are no
per-frame intervals: fps = counter delta, "1% low" = the lowest 1-s window, and intervals > 20 ms can't be counted
from it for either stack.

| Run | fps mean / lowest 1-s | HUD GPU ms (frame interval) | GPU P15 / low (≤ P2) / off | hlvr | wineserver | runtime CPU % | stream |
|---|---|---|---|---|---|---|---|
| A72-1 | 67.3 / 57.8 | 8.69 (14.24) | 52 / 0 / 8 % (P14 39) | 294 | 51 | 78 (vrserver 52, vrcompositor 12, vrmonitor 5, vrwebhelper 4, encoder 3, VTEnc 2) | 66.6 fps, 74 Mbit/s, encode 7.6 ms |
| A72-2 | 69.7 / 66.1 | 8.55 (14.22) | 94 / 0 / 5 % | 304 | 46 | 72 (45, 12, 6, 4, 3, 2) | 69.5 fps, 50 Mbit/s, 7.6 ms |
| B72-4 | 72.0 / 71.1 | 8.49 (13.89) | 87 / 1 / 11 % | 359 | 38 | 48 (wivrn-server 42, VTEnc 6) | 2 × 72.0 fps, 2 × 71 Mbit/s, 2.8/3.1 ms |
| B72-5 | 72.0 / 70.1 | 8.45 (13.86) | 88 / 1 / 11 % | 340 | 33 | 44 (38, 6) | 2 × 72.0 fps, 2 × 67 Mbit/s, 2.7/3.1 ms |
| A90-1 | 45.0 / 43.7 | 8.26 (22.22) | 69 / 2 / 25 % | 215 | 41 | 59 (40, 8, 5, 4, 1, 1) | 40.5 fps, 50 Mbit/s, 7.5 ms |
| A90-2 | 39.6 / 32.1 | 8.67 (26.82) | 14 / 2 / 24 % (P14 42, P12 11) | 270 | 43 | 74 (39, 13, 9, 8, 3, 2) | 38.5 fps, 8 Mbit/s, 8.3 ms |
| B90-2 | 89.4 / 88.0 | 8.48 (11.11) | 97 / 0 / 3 % | 425 | 43 | 55 (47, 8) | 2 × 90.0 fps, 2 × 70 Mbit/s, 2.8/3.3 ms |
| B90-1 | 89.8 / 86.8 | - | 97 / 0 / 3 % | 434 | 52 | 50 (43, 7) | 2 × 90.0 fps, 2 × 62 Mbit/s |

CPU % = mean of 2-s `ps` samples (100 % = one core). B encode = p50/p95 per eye stream; A encode = per frame.

- At 72 Hz B now holds 72.0 fps with a lowest second of 70-71; A gives 67-70 with dips to 58-66. GPU time per frame is
  the same (8.45-8.7 ms) and the GPU sat mostly at P15 in both (A72-1 partly at P14).
- At 90 Hz A drops to half rate (39-45 fps, HUD interval 22-27 ms, GPU still 8.3-8.7 ms), so it is not GPU-bound;
  vrcompositor logged 0 reprojected frames. B runs 89.4-89.8 fps.
- B uses more game CPU (hlvr 340-359 vs 294-304 % at 72 Hz; the game runs more frames) and less runtime CPU (44-48 vs
  72-78 %).

**Caveats.**
- The Quest lost positional tracking (dark room; "Finding position in room" Guardian dialog). It blocked app launches,
  so `setprop debug.oculus.guardian_pause 1` was set for the A runs and reset to 0 afterwards. The head pose differed:
  A's mirror shows the balcony railing up close, B's looks over the street (screenshots `*-mac.png`).
- b72-1..3 (72.0 / 72.0 / 72.4 fps) were recorded while the WiVRn activity wasn't focused (Guardian dialog on top, the
  client sent no feedback, 25 Mbit/s); they are left out of the table. b72-1's first try lost 72 Hz mid-window when the
  shell switched the display to 90 Hz; it was rerun. B90-1 ran in an already-loaded session (no reload).
- Two windows per stack at 72 Hz, two (A) / one fresh + one reused (B) at 90 Hz, 30 s each.
- The HUD GPU time is one screenshot per run.
- Game Mode was Off in both stacks.

Changed and restored: WiVRn 90 → 72 → 90 → 72 → 90 Hz (Quest at 90 at the end); `opencomposite.ini`
(+`supersampleRatio=0.949`, `cmp` equal to `build/ab/opencomposite.ini.orig`); `vr_fidelity_level_auto` 0 → 1 in both
stacks; launchctl `MTL_HUD_LOG_ENABLED` set, then unset, native Steam restarted; bottle `steamvr.vrsettings` (see
above); Quest `debug.oculus.guardian_pause` 1 → 0. Bottle Steam/SteamVR shut down (`steam.exe -shutdown`,
`wineserver -k`), encoder helper stopped.
