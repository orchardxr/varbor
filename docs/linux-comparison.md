# Linux WiVRn 26.9 vs macOS WiVRn port (2026-10-26, re-run 2026-10-28)

Same Quest 3S (client WiVRn 26.9, Wi-Fi 5 GHz ch44; 160 MHz/2401 Mbps on 10-28), Half-Life: Alyx buildid 25487405 (Linux re-run: 26227071, see notes), save
`s6/steamvr_quit` (4558941 B, sha256 8fabf613…c8a0, identical on both), 90 Hz, `vr_fidelity_level_auto 0`,
`vr_fidelity_level 3` (renders 2198×2302 per eye on both: WiVRn recommends that size on both servers).

## Linux setup
- PC: CachyOS, kernel 7.3.0-5-cachyos, RTX 5070 Ti, NVIDIA 615.78.08, wired eno1 (Realtek RTL8125D, r8169).
- WiVRn: Flathub `io.github.wivrn.wivrn` 26.9 (user install, commit 61d58e18, "Update xrizer to 0.6"), stock config
  (no config.json), started with `systemd-run --user flatpak run --command=wivrn-server io.github.wivrn.wivrn`.
  Paired with `wivrnctl pair` PIN.
- Runtime: `~/.config/openxr/1/active_runtime.json` → flatpak `openxr_wivrn.json`; OpenVR layer: **xrizer 0.6**
  (`~/.config/openvr/openvrpaths.vrpath` written by wivrn-server). OpenComposite is shipped but not used.
- Alyx: **native Linux Vulkan build** in SteamLinuxRuntime_4 (not Proton; default compat tool would be
  proton-cachyos-10.0-20260320-slr-x86_64_v4). Launch options
  `PRESSURE_VESSEL_IMPORT_OPENXR_1_RUNTIMES=1 %command% -condebug -vconsole +vr_fidelity_level_auto 0 +vr_fidelity_level 3`.
- Encoder: **NVENC AV1 10-bit** (stock WiVRn picked AV1; the Mac uses HEVC 10-bit), streams 2×1152×1152 at
  98.7 Mbit/s + 1152×576 at 2.4 Mbit/s, 90 fps.
- Stock WiVRn has no per-frame latency log (our patch 0004) and no pacer tunables (our patch 0009), so only the
  client overlay's M2P estimate is comparable.

## Results (2026-10-28 re-run, PC on a 1 Gbit path)
Each Linux run: Alyx loaded from the save, >20 s settle, 30 s record at the same spot (balcony railing, headset at
rest). M2P = overlay "Estimated motion to photons latency", screenshots at 5/15/25 s of the record (plus one before it
for AV1).

| | Linux AV1 (stock) | Linux HEVC 10-bit | Mac, stock pacer | Mac, low-latency (patch 0009) | Windows Air Link |
|---|---|---|---|---|---|
| Overlay M2P | **63 / 73 / 74 ms** (pre-check 74) | **70 / 79 / 70 ms** | 88 ms | 85 ms | — |
| End-to-end sensor_to_illumination p50 | — | — | — | — | 91.2 ms |
| Encoder | NVENC AV1 10-bit | NVENC HEVC 10-bit | VideoToolbox HEVC 10-bit | same | Meta (H.264/HEVC) |
| Streams | 2×1152×1152 @ 98.7 Mbit/s + 1152×576 @ 2.4, 90 fps | same | 2 eyes, ~71 Mbit/s per eye (10-25) | same | dynamic ~71 Mbit/s |
| Incomplete frames / 30 s (client "not sent") | 10 ("no shard was received") | 7 (same kind); 4 in a run without overlay | — | — | — |
| IDR requests / 30 s (server) | 2 (1 per eye stream) | 4; 6 in a run without overlay | — | — | — |
| Ping Linux PC→Quest while streaming | 0 % loss / 150, RTT avg 3.8 ms (max 8.9) | 0 % / 150, avg 3.8 ms (max 8.3) | — | — | — |
| GPU busy / NVENC busy | 28 % / 12 % | 28 % / 14 % | — | — | — |

- Overlay graphs (`a-av1-15-ov.png`, `b-hevc-15-ov.png` in the session scratchpad `linux-bench/`): network flat at
  ~200 Mbit/s download in both (AV1 smoother, HEVC a bit noisier); Timings: Predicted ~40 ms, Blitted/Displayed
  ~20-25 ms, the stacked encode+send+receive+decode band ~10-15 ms, with a few isolated spikes to 50-55 ms; Defoveate
  1.1-1.5 ms; client CPU time 1.5-2 ms. HEVC's predicted line was still stepping down from ~55 to ~40 ms after the
  reconnect, so its early samples sit higher.
- Linux stock WiVRn reads **~70-75 ms, ~10-15 ms below the Mac** (85-88 ms) with the same Quest, client, save,
  90 Hz and fidelity 3. Codec barely matters (AV1 vs HEVC within the reading noise). Different estimator from Air Link's
  91.2 ms, so that column is not directly comparable.
- The 10-26 149 ms reading was entirely the 100 Mbit link: with it fixed there is no loss spiral (2-6 IDRs per 30 s
  instead of ~9/s, 0 % ping loss).
- Stock Linux WiVRn logs no per-stage latency breakdown (our patch 0004) and has no pacer tunables (0009), so only
  the overlay number compares; no Linux "low-latency" row.
- Caveats: Steam forced an Alyx update before launch (25487405 → 26227071, 44 MB); the Mac still runs 25487405.
  Game fps on Linux was not logged (GPU at 28 % suggests 90 fps was not GPU-bound). Headset pose in run (b) differs
  slightly from (a) (overlay was reopened in the headset).

## 10-26 attempt (invalid: 100 Mbit link)
- Overlay: **149 ms** (one reading during the lossy AV1 stream).
- Overlay on Linux: the Timings graph's predicted/displayed lines sat at ~150–300 ms, with spikes to 400–600 ms
  and a stall. The network graph swung a lot. Defoveate took 1–2.5 ms. The two eyes sometimes showed different moments.

## Why the Linux number is bad: the PC's network path
- Client logcat: ~228 of ~1800 frames in 10 s were incomplete ("frame N was not sent with 49 data shards, 42
  missing"). The server log shows "IDR frame needed" ~9×/s. Each loss forces an IDR, the large IDR frames get
  lost again, and the stream spirals. NVENC sessions averaged only ~15–21 fps per stream.
- Ping loss while streaming:
  - PC→Quest: 4.4%;
  - PC→Mac: 2%;
  - PC→router: 3%;
  - Mac→PC: 3.5%;
  - Mac→router: 0%;
  - Mac→Quest: 0%.

  With the stream stopped, everything was at 0%.
- Raw TCP (ssh, no stream running):
  - PC→Mac: ~73 Mbit/s;
  - Mac→PC: ~83 Mbit/s;
  - both NICs report 1000/full, while PC→lancache runs at 1 Gbps.

  Under that TCP load, PC→router RTT rose from 1.5 to 4.5 ms (max 18 ms), with 0.4% retransmits. Mac→router stayed at
  0.9 ms with no loss. So the PC side reaches the Mac/router side through a ~80–100 Mbit/s bottleneck, most likely a
  100 Mbit inter-switch link or a bad cable. WiVRn asks for ~200 Mbit/s (2×98.7 + 2.4).
- **Confirmed by the user (2026-10-26):** the cause is a 100 Mbit link between the PC and the router.
- **Fixed (2026-10-28):** the Linux PC ↔ another wired host now runs at 930–941 Mbit/s both ways (eno1 1000/full), and Mac (Wi‑Fi, 160 MHz) ↔ Linux PC at 420–910 Mbit/s. The Quest is on 160 MHz at 2401 Mbps. Ready for a valid Linux re-run.
- Quest Wi-Fi was healthy: Wi-Fi 6, 5220 MHz, RSSI −33, link 1200/1200 Mbit/s.
- The NIC itself looks clean:
  - Realtek RTL8125D on r8169, fw rtl8125d-1_0.0.7;
  - `ethtool -S` shows 0 tx/rx errors and 0 rx_missed;
  - fq_codel shows 0 drops;
  - ASPM is already off;
  - rings are at the 256 maximum.

  Turning EEE off (user, `sudo ethtool --set-eee eno1 eee off`) did not change the loss. CachyOS offers
  `linux-cachyos-r8125` 7.3.0-5 (Realtek's driver), which was not tried.
- **The Windows runs probably went through the same path**: Air Link (~71 Mbit/s) and Steam Link (capped ~55 Mbit/s,
  "bad link") were probably limited by it too.

## Other differences to remember for the redo
- Codec: Linux stock WiVRn picks AV1 on NVENC. To match the Mac, force HEVC 10-bit in
  `~/.var/app/io.github.wivrn.wivrn/config/wivrn/config.json`.
- Alyx on Linux is the native Vulkan build, not D3D11 under Wine. OpenVR→OpenXR goes through xrizer, not
  OpenComposite.
- Fidelity 3 gives 2198×2302 per eye on both. Mac's 6224×3259 is the swapchain allocated at the max level (1.416×).
- GPU was ~25% busy on the PC, so it was not a bottleneck.

## State left on the PC (after the 2026-10-28 re-run)
- The WiVRn flatpak stays installed (user). The server is stopped, the headset is paired (`known_keys.json` was
  rewritten on 10-28).
- Restored: Alyx's Linux launch options are empty again; `~/.config/openxr/1/active_runtime.json` and
  `~/.config/openvr/openvrpaths.vrpath` are deleted; no `config.json` in the flatpak's WiVRn config dir (as found).
- Alyx quit, Steam shut down (it was not running before). Alyx is now on buildid 26227071.
- ufw rules (persistent) stay. Undo with `sudo ufw delete allow 9757` and `sudo ufw delete allow 5353/udp`.
- Gotcha: killing a stale wivrn-server unlinks `/run/user/1000/wivrn/comp_ipc` even if a newer server created it, and
  the game then fails with `VRInitError_Init_VRServiceStartupFailed`. Stop every wivrn-server before starting one.
  Steam would not log in while the Plasma session was locked.

## Where the Mac loses time (2026-10-28)

Same Quest 3S (client 26.9, Wi-Fi, 160 MHz), save `s6/steamvr_quit`, 90 Hz, fidelity 3, headset at rest, 20 s
settle + 30 s record. Mac: M4 Max on Ethernet, **40 W charger, battery 100→99 %**, screen sharing off, Alyx rolled
back to 25487405 (see below). Linux: the Linux PC, wired, Alyx 26227071 native Vulkan via xrizer.

### What the overlay number is
"Estimated motion to photons latency" is computed by the **server** (`server/driver/tracking_control.cpp`) and sent in
`tracking_control.motions_to_photons`; the client only prints it. For every pose query of every device in a ~1-s window
it takes `at_ns − production_timestamp` (time the app asked the pose for − when the headset sampled the newest pose
used) and reports the **maximum**. So it is
- pose age at the query (headset → server, plus how fresh the history sample is), plus
- the app's prediction horizon: the display time `xrWaitFrame` gave the game minus the time of the query. With WiVRn's
  app pacer that is ≈ app CPU + app GPU + compositor term + app margin, and the compositor term is ≈ the pacer's
  `safe` present>decoded (both eyes, p99.5/5000 + 1 ms) + render>display (~16.5 ms).

Encode, network and decode enter only through `safe` (their tail, not their median). decoded>blit is the client's
hold of an early frame (= safe − actual arrival). The client's display-slot hold is therefore already inside `safe`.

### Method
Identical logging on both: stock v26.9 tree + `patches/wivrn` 0004 (pacer log hunks) + 0009 + `patches/diag/
wivrn-feedback-dump.patch` + `wivrn-m2p-trace.patch` (Mac on top of 0001-0009: `build/wivrn-m2p`; Linux
`wivrn-m2p-trace-stock.patch`, built in `flatpak run --devel io.github.wivrn.wivrn` with org.kde.Sdk//6.10 (user
install, no sudo; header-only deps in `~/m2p`) and run in the same sandbox in place of the stock server; the
flatpak's own client library stays). The trace's `M` line is the exact value the overlay shows, so no headset
interaction is needed. Runs: `tools/mql-ab/m2prun.sh` (Mac; gate: ≥ 80 fps, session FOCUSED, no Guardian dialog),
`tools/mql-ab/m2prun-linux.sh` (on the Linux PC), summaries `m2pstats.py`, `m2pmax.py` (what sets each 1-s max),
`latstats.py` (both-eye tails). Raw: `build/lat/mac-*`, `build/lat/linux/lin-*`.
Codec/bitrate: Mac HEVC 10-bit VideoToolbox, 2×1152² + 1152×576, target 98.8 Mbit/s/eye, **actual ~71 Mbit/s/eye**;
Linux stock picks **AV1 10-bit NVENC**, 2×1152² at 98.7 + 1152×576 at 2.4. Same resolution; the Mac sends less.

### Results
Overlay = mean (median) of the 30 values; the other rows are per-frame p50 (p95) in ms, stream 0 unless noted.

| | Mac stock (`mac-stock7`) | Linux stock (`lin-stock2`) | Mac − Linux | Mac low-lat (`mac-ll2`) | Linux low-lat (`lin-ll2`) |
|---|---|---|---|---|---|
| **Overlay M2P** | **86.0 (82.8)** | **63.3 (61.5)** | **+22.7** | **72.6 (69.5)** | **65.3 (63.3)** |
| per-query estimate (at − produced) | 67.3 (77.8) | 51.3 (60.6) | +16.0 | 64.3 (75.8) | 53.6 (61.0) |
| 1-s max − window median | 18.4 | 11.3 | +7.1 | 7.4 | 11.9 |
| windows set by a pose > 10 ms old | 19 of 30 | 0 of 30 | | 2 of 30 | 1 of 30 |
| head pose age | 3.3 (7.5), max 63 | 2.3 (4.9), max 11 | +1.0 | 3.1 (5.6) | 2.7 (5.1) |
| app horizon (xrWaitFrame return → display) | 63.7 (74.0) | 48.9 (57.5) | +14.8 | 61.6 (73.1) | 50.5 (58.7) |
| · app CPU (wake → xrEndFrame) | 4.1 (11.0) | 1.5 (1.6) | +2.6 | 3.5 (10.7) | 1.5 (1.6) |
| · app GPU (xrEndFrame → GPU done) | 10.7 (11.8) | 11.0 (11.2) | −0.3 | 10.4 | 11.0 |
| · compositor term | 44.8 (46.8) | 34.9 (35.2) | +9.9 | 43.7 | 36.5 |
| · app margin (`U_PACING_APP_MIN_MARGIN_MS`) | 4.0 (0007) | 1.5 (stock) | +2.5 | 4.0 | 1.5 |
| frames in pacer's "app-limited, no wait" branch | 1039 of 2633 | 311 of 2700 | | 701 | 194 |
| pacer safe present>decoded | 28.8 | 21.3 | +7.5 | 27.9 | 22.3 |
| present>decoded both eyes p50 / p99.5 | 16.9 / 28.9 | 17.1 / 20.3 | −0.2 / +8.6 | 16.3 / 26.8 | |
| encode | 3.3 (4.4) | 2.6 (3.6) | +0.7 | 3.3 | 2.6 |
| send | 0.2 (1.8) | 0.0 (0.0) | +0.2 (+1.8) | 0.1 (1.8) | 0.0 |
| network | 3.8 (6.6) | 3.2 (4.3) | +0.6 (+2.3) | 3.6 (5.2) | 3.4 |
| decode (Quest) | 7.9 (12.7) | 5.3 (6.7) | +2.6 (+6.0) | 7.7 (11.9) | 5.9 |
| second eye after first (mean) | 4.0 | 3.3 | +0.7 | 4.0 | |
| decoded>blit (client hold) | 13.8 | 6.9 | +6.9 | 13.4 | 8.6 |
| blit>display | 16.9 | 16.4 | +0.5 | 16.8 | 17.0 |
| shown late / repeats per 30 s (last 3 log windows) | 18 / 30 | 16 / 23 | | 21 / 19 | 8 / 19 |
| game fps | 87.4 | 90.0 | | 88.2 | 90.0 |

Mac low-latency `mac-ll1` (trace lost to a server re-exec, summary only): overlay 74.0 (69.7). A first Linux stock run
(`lin-stock1`, 77.4 (75.7)) had a client-side disturbance (safe rose to 33, 380 repeats in one 10-s window) and is not
used; Linux 10-28 overlay readings (63-74 AV1) agree with `lin-stock2`.

### Where the 22.7 ms (stock) go, ranked
1. **Compositor term +9.9 ms, almost all `safe` (+7.5).** The medians match (both-eye present>decoded 16.9 vs 17.1),
   the tail does not (p99.5 28.9 vs 20.3). The Mac's worst 2 % of frames: decode 13.6 ms (mean 9.5), network 6.6,
   send 1.7, second eye 5.7 ms later; Linux worst 2 %: decode 7.6, network 5.3, send 0. Largest single part: **Quest
   HEVC 10-bit decode** (p50 7.9, p95 12.7) vs AV1 (5.3 / 6.7) on Linux, at even lower bitrate. VT can't encode AV1 on
   the M4. Linux's own HEVC reading on 10-28 (70/79/70 vs AV1 63/73/74) is consistent with ~+5 ms from the codec.
2. **Stale poses in the 1-s max, +7.1 ms of overlay (run-dependent).** In `mac-stock7` 19 of 30 overlay values were
   set by a head query whose pose was 10-63 ms old (gaps of up to 70 ms between new head samples), so the overlay
   over-states the typical frame by 18 ms vs Linux's 11. `mac-ll2` had only 2 such windows. 10-s tracking latency is
   the same on both (1.8-2.0 ms), so these are tail events: either uplink stalls into the Mac (Quest → AP → en7) or the
   history lookup (10 samples per device in `history.h`) losing the needed future-time sample when the Mac's horizon
   varies more. Not yet separated.
3. **App margin +2.5 ms (our 0007 default 4 vs stock 1.5).** A/B `mac-ll-m15` (low-lat + margin 1.5): horizon p50
   −1.4 ms, but more app-limited frames (949 vs 701), fps 87.5, overlay 75.8 vs 72.6. Not a win: keep 4.
4. **App CPU +2.6 ms (p95 +9.4).** OpenComposite ends the frame at the second eye's `Submit`, so this is Alyx's D3D11
   work under Wine/Rosetta/DXMT before that (bridge share ~0.3 ms). Its long tail puts 40 % of Mac frames into the app
   pacer's "app-limited, no wait" branch (vs 11 % on Linux), which adds up to a period of horizon on those frames
   (horizon p95 +16.5).
5. **Pose age p50 +1.0 ms.**
6. Encode +0.7 (VT 3.3 vs NVENC 2.6), app GPU −0.3, blit>display +0.5: negligible. Game fps 87-88 vs 90 shows up as
   the CPU tail above, not as a separate term.

The estimator (0009) is the one Mac-side lever that works: low-latency settings bring the Mac from 86 to 72.6-74
(−12 ms; the Mac's 55-s window keeps the post-load tail) while doing nothing on Linux (63 → 65), where safe is already
21-22. With it, the Mac − Linux gap is **~7-9 ms**: safe +5.6, margin +2.5, app CPU +2.0, pose age +0.4.

### Fixes
- **Client: show the newest decoded frame, reprojected** (docs/wivrn.md 0009): removes decoded>blit (13.4-13.8 ms on
  the Mac, 7-9 on Linux) and makes the Mac's decode tail cost a frame of latency instead of raising `safe` for all
  frames. Largest available gain, but ruled out: the Quest client stays stock (decision 2026-10-28).
- **Codec/bitrate tail:** fewer bits (client bitrate setting) or a VT setting that shortens the Quest's HEVC decode
  (slices/tiles, lower peak) to cut the decode tail; to measure next (same scripts).
- **Stale-pose spikes:** log tracking packet arrival on the server next to the trace to tell uplink stalls from the
  history lookup; if it is the lookup, enlarge `history` beyond 10 samples (WiVRn patch).
- Kept as is: app margin 4 ms (A/B above), the low-latency estimator stays MacVR.app's default.

### Linux HEVC: is the decode tail the codec or VideoToolbox's bitstream? (2026-10-28)
`lin-hevc1`: same Linux build, `config.json` `{"bit-depth":10,"encoder":{"encoder":"nvenc","codec":"h265"}}` (server
log: `nvenc (h265 10-bit)`), stock estimator, 89.9 fps. `mac-hevc1`: Mac stock estimator, 89 fps. Both with
`WIVRN_DUMP_VIDEO`; frame sizes are the 30-s window's packets (ffprobe). Decode = client to_decoder → decoded, both
eyes; `tools/mql-ab/decodestats.py`. After ~5 s the Linux HEVC stream hit packet loss (IDRs on both streams, network
p95 17-58 ms, as in the 10-28 HEVC run), so its clean figures are the first 5 s of the window and the two 10-s server
windows before it.

| | Linux HEVC (clean part) | Linux HEVC (whole 30 s) | Mac HEVC `mac-hevc1` | Mac HEVC `mac-stock7` | Linux AV1 `lin-stock2` |
|---|---|---|---|---|---|
| decode p50 / p95 | 8.4 / 11.7 (server 10-s: 7.5/13.5, 7.3/13.0) | 9.2 / 22.4 | 7.6 / 11.7 | 7.7 / 11.9 | 6.2 / 8.2 |
| decode, worst 2 % (mean) | 15.5 | 31.5 | 16.5 | 16.7 | 11.0 |
| 2nd eye decoded after 1st (mean / p95) | 4.6 / 5.5 | 4.7 / 6.1 | 4.1 / 5.4 | 4.0 / 5.4 | 3.3 / 3.7 |
| network p50 / p95 | 3.2 / 5.0 | 3.6 / 35.8 | 3.9 / 7.4 | 3.7 / 6.4 | 3.6 / 4.8 |
| safe | 26.3-29.6 (10-s windows) | 49-58 | 27.0 | 28.8 | 21.3 |
| overlay M2P mean (median) | ~70 (first 6 s) | 112.3 (111.0) | 78.9 (76.0) | 86.0 (82.8) | 63.3 (61.5) |
| windows set by a pose > 10 ms old | | 20 of 30 | 10 of 30 | 19 of 30 | 0 of 30 |
| frame bytes mean / p95 / p99 / max | 127k / 188k / 220k / 259k | (same window) | 99k / 150k / 175k / 239k | | |
| p99/mean, max/mean, CV | 1.73, 2.0, 0.28 | | 1.77, 2.4, 0.32 | | |
| bitrate per eye, keyframes in 30 s | 92 Mbit/s, 1 | | 71 Mbit/s, 0 | | |

**Answer: it is HEVC decoding on the Quest, not the VideoToolbox bitstream.** With a clean network, NVENC HEVC on
Linux shows the Mac's decode tail (p95 ~12-13, worst 2 % 15-16 ms, second eye +4-5 ms) at 30 % more bits per frame;
the frame-size distributions have the same shape (VT's max/mean is a little higher, 2.4 vs 2.0). AV1 decodes
faster and flatter on the Quest (p95 8.2, worst 2 % 11.0, second eye +3.3). VideoToolbox rate-control changes
(low-latency RC, AverageBitRate + DataRateLimits) are therefore not expected to remove the tail; the remaining
levers are fewer bits per frame or a client that does not wait for the slowest eye. Linux HEVC at 92 Mbit/s also lost
packets twice (10-28 and here) where AV1 at ~98 did not.
Stale poses: `lin-hevc1` had 20 of 30 overlay windows set by a pose > 10 ms old during its loss phase, so these
follow network trouble on both systems, not a Mac-only lookup problem.

Controller state: all traced runs above (Mac and Linux) had the Quest controllers asleep (profile INVALID, only head
pose queries), so the comparisons are like-for-like; no row needed correcting.

### Alyx 26227071 on macOS 27.2: 1 fps (2026-10-28)
After Steam auto-updated Alyx on the Mac (17:40, 25487405 → 26227071) on top of macOS 27.2 (installed 00:58), Alyx ran
at 1-2 fps in VR and with `-novr` (GPU 0.1-0.3 ms, hlvr.exe on one core), with the known-good server
(`build/wivrn-next`) too. Ruled out: WiVRn/pacer/bridge (`xrWaitFrame` 0.1 ms, bridge 0.6 ms per frame), controllers /
hand tracking, Guardian, console spam, shader-cache rebuild (no MTLCompilerService CPU, DXMT cache unchanged over
4 min), `ROSETTA_ADVERTISE_AVX=0`. The Linux build of 26227071 is fine.
**Rollback (Mac):** `download_depot 546560 546563 1898649366808652836` in the Steam console (manifest from the 10-17
depotcache) → `Steam.AppBundle/Steam/Contents/MacOS/steamapps/content/app_546560/depot_546563`; the 61 files that
differ were backed up to `~/Library/Application Support/macvr-alyx-rollback/20261028-26227071/` (list in `files.txt`)
and replaced. hlvr.exe sha256 154e3e5a… (25487405) vs e34bbf37… (26227071). Result: 120 fps 2D, 86-90 fps VR. The
content depot 546561 was left at 26227071. Undo: copy the backup back over the game dir (or Steam "Verify integrity").
Steam still records buildid 26227071, so it won't re-download, but a verify or the next Alyx update will undo the
rollback.
**Under FEX it runs:** with `notproton-fex-41073` (arm64 Wine + FEX) the same 26227071 files give 89.4 fps in VR
(`build/lat/fex-26227071`), so the slowdown is Rosetta-specific. Rosetta vs FEX numbers: [bridge-plan.md](bridge-plan.md) §7a.

### Leftovers on the Linux PC
`~/m2p` (source, deps, build, outputs) and the user flatpak runtime `org.kde.Sdk//6.10` (1.1 GB; remove with
`flatpak uninstall --user org.kde.Sdk//6.10`). Otherwise restored as described above.
