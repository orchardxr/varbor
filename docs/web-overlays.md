# Web overlays (SteamVR's vrwebhelper pipeline on macOS)

Half-Life: Alyx doesn't draw its loading screens ("LOADING", "Press Trigger To Start", chapter titles, tips, the
hologram map) itself. It ships them as a web page (`game/hlvr/webui`) and has SteamVR render it. MacVR does the same
thing SteamVR does, with the same messages, the same page and the same scene graph:

| SteamVR | MacVR | Where |
|---|---|---|
| vrclient `IVRControlPanel::RegisterExternalWebRoot`, `IVRMailbox` (IPC to vrserver) | OpenComposite patch 0008: WebSocket client to the broker | `patches/opencomposite/0008-web-overlay-mailbox.patch` |
| vrserver web server: mailboxes on `ws://localhost:27062`, `/fonts/get_font`, reads `vrwebui.config.json`, `create_overlays` to `vrwebhelper/main` | `macvr-broker` | `app/Sources/macvr-broker` |
| vrwebhelper (CEF): offscreen pages with `window.VRHTML`, scene graph to the compositor | `macvr-webhelper`: offscreen WKWebView | `app/Sources/macvr-webhelper` |
| vrcompositor scene graph: panels (rects of the page texture) as overlays in the standing universe | XR_EXTX_overlay session on WiVRn, one quad layer per panel | `app/Sources/CMacVRXR/mxr.c` |

MacVR.app starts `macvr-broker` next to `wivrn-server` (both its children); the broker starts `macvr-webhelper` when a
game registers a web root and the helper exits when the game is gone. Logs: `~/Library/Logs/MacVR/web-overlays.log`
(broker + helper, `[webhelper]` lines), the game side in OpenComposite's log.

## What happens (Alyx, startup)

1. Alyx (client.dll → vr.dll) registers mailbox `hlvr/mailbox`, then calls `RegisterExternalWebRoot("<game>\hlvr\webui")`
   (vr.dll calls `IVRControlPanel_006` vtable slot 26 with one string; checked in the disassembly).
2. OpenComposite opens `vrclient/<pid>` on the broker and sends `register_external_webroot` with the Windows path, its
   unix path (`wine_get_unix_file_name`) and the drive map (`S:` = the Steam library in NotProton prefixes,
   `dosdevices/s: -> ~/Library/Application Support/Steam`). It waits for the reply (vrserver also waits: "Waiting for
   %s to load", max 15 s).
3. The broker reads `vrwebui.config.json` (`interstitials`: `/interstitials.html`, type overlay, 2048x2048), names the
   web root after its last two path components (`hlvr/webui`, as vrserver), starts the helper and sends it
   `create_overlays`. The reply goes back when the helper reports `overlays_loaded`.
4. The page bootstraps only in an overlay (`VRHTML.Environment() == 2`), opens `hlvr/interstitials` and sends
   `{"type":"ready"}` to `hlvr/mailbox`. OpenComposite's `ReadMessage` returns it to the game: this is the real ready,
   the fake one is gone (it remains only when there is no broker, as upstream OpenComposite).
5. The game sends `set_paths`, `begin_loading`, `show_message`, `end_loading` to `hlvr/interstitials`; the page renders
   them and calls `VRHTML.UpdateSceneGraph(json)` on every change.
6. The helper turns the scene graph into quads and shows them; on game exit the `vrclient/<pid>` connection closes, the
   broker sends `destroy_overlays` and the helper quits.

## Broker (`macvr-broker`)

- WebSocket server on 127.0.0.1:27062 and [::1]:27062 (the page connects to `ws://localhost:27062`). Network.framework,
  no HTTP: pages are served by the helper's URL scheme handler.
- Text commands as SteamVR's: `mailbox_open <name>`, `mailbox_close <name>`, `mailbox_send <name> <json>`,
  `websocket_close`. A message goes to every connection that opened `<name>`.
- `web_server_mailbox`: `request_mailbox_registration_notification` → `mailbox_registered` (also later, when the
  mailbox opens), `request_mailbox_unavailable_notification` → `mailbox_unavailable`, `register_external_webroot`
  (ours: vrclient talks to vrserver over its IPC, `VRMsg_RegisterExternalWebRoot`), `overlays_loaded` (helper).
- Secret: vrserver rejects WebSocket requests without its secret (`?secret=` or the `x-steamvr-secret` header, which
  vrwebhelper adds) and checks the origin. We listen on loopback only and accept any or no secret.
- Messages to a mailbox nobody has opened are kept for 10 s and delivered when it opens (covers ordering races).
- Exits with its parent (the app), so the port is never left taken.

## Web helper (`macvr-webhelper`)

- One offscreen borderless window per overlay (never shown) holding a WKWebView of `pixel_size` CSS pixels. SPI:
  `_setOverrideDeviceScaleFactor: 1` (1 CSS px = 1 texel, as CEF in SteamVR) and `_setWindowOcclusionDetectionEnabled:
  NO` (an offscreen window counts as occluded and WebKit would stop animations and rendering: measured, 0 of 180
  snapshots changed without it). Transparent background (`drawsBackground = NO`), sRGB window color space.
- `WKUserScript` at document start defines `window.VRHTML`: `Environment()` → 2, `UpdateSceneGraph(json, retired)` →
  `WKScriptMessageHandler`, `VROverlay.ThisOverlayHandle()`, and `VRProperties` / `VRRenderModelsInternal` /
  `VRRenderModels` that throw (only an unused controller-transform component calls them; it catches). The page's
  console goes to the log.
- `vrwebui://<webroot name>/…` (`WKURLSchemeHandler`) serves the web root (`localization/hlvr_english.json` over XHR,
  CSS, SVG arcs). `/fonts/get_font?font=X`: from `~/Library/Application Support/macvr/fonts/X`, else
  `<webroot>/fonts/X`, but only plain OpenType/TrueType files (see Fonts). `/dashboard/localization/webhelper_*.json`
  (SteamVR's own strings) is a 404, which the page ignores.
- Scene graph → quads (`SceneGraph.swift`): transform (translation, rotation w x y z, scale), opacity, tint; panels
  give `uv_min`/`uv_max` × pixel size = the texture rect, `width`/`height` in metres (a missing one from the rect's
  aspect), `origin` (−1…1: the panel point at the node origin). The root is the standing universe = STAGE (Alyx's
  numbers are floor-relative: `y 1.8, z −2`). `parent-path`/`parent-id`, `target-dpi-panel-id`, curvature and the
  head-following transforms aren't used by Alyx and are logged once if seen.
- Pixels: `takeSnapshot` of each panel's rect at 30 Hz (`MACVR_WEB_FPS`), a third of that after 0.5 s without a change.
  Unchanged snapshots are dropped; changed ones are converted and staged (`mxr_upload`). A full 2048² CARenderer path
  isn't possible: WebKit's layers are remote (rendered in its GPU process), and a 2048² snapshot takes 10 ms vs 3-4 ms
  for a panel rect.
- Debug: `MACVR_WEB_DUMP=<dir>` writes each changed panel as PNG and the last scene graph JSON; `MACVR_WEB_NO_XR=1`
  skips the compositor (headless test).

## Compositor (`CMacVRXR/mxr.c`)

- The arm64 WiVRn client `libopenxr_wivrn.dylib` from the server's own build (payload `server/`, same ipc-stamp by
  construction), loaded with `dlopen` + `xrNegotiateLoaderRuntimeInterface` (no loader). Vulkan via MoltenVK
  (`XR_KHR_vulkan_enable2`, `VK_DRIVER_FILES` as the server).
- `XR_EXTX_overlay` session, `sessionLayersPlacement = 1` (above the game), STAGE space, `XR_KHR_composition_layer_
  color_scale_bias` when offered. Application name `MacVR web overlays` (the app doesn't count it as a game).
- One 2048² `R8G8B8A8_SRGB` swapchain = the page texture, as SteamVR's overlay texture. Each panel is an
  `XrCompositionLayerQuad` whose `subImage.imageRect` is the panel rect: SteamVR's model (panels are rects of one
  texture). Pose and size from the scene graph, `BLEND_TEXTURE_SOURCE_ALPHA`, color scale = (tint × opacity, opacity).
- A new swapchain image is produced only when a panel changed: the rects (+1 px for filtering) are copied from a
  host-visible staging buffer with `vkCmdCopyBufferToImage`. Otherwise the last image is resubmitted.
- Premultiplied alpha: WebKit's pixels are premultiplied in sRGB-encoded space; the swapchain is sRGB, so the runtime
  decodes per channel. Storing them as is would darken anti-aliased edges (decode(c·a) ≠ decode(c)·a). `mxr_upload`
  stores encode(decode(c/a)·a) (a 64K-entry LUT), which the compositor decodes to the correct linear premultiplied value.
- The session (and the XrInstance) exists only while there are panels, plus 1 s; without a headset session in WiVRn
  `xrCreateInstance` fails and is retried every 2 s.

## Status (2026-10-26)

- Alyx end to end (MacVR.app from /Applications, WiVRn, Quest 3S): OpenComposite registered `hlvr/webui` (page loaded
  in 0.47 s), the game read the page's real `ready`, the page received `set_paths`/`begin_loading`/`show_message`/
  `end_loading`, the overlay session opened on WiVRn and closed after `end_loading`, and the helper exited with the
  game. The user checked in the headset: "Press Trigger To Start" size and position OK; LOADING with spinning arcs and
  the animated dots good; only the font differs (Arial, accepted). Screencaps: `build/logs/web-overlay-alyx-load-*.png`,
  `web-overlay-alyx-loading-*.png` (head not facing the panel in those; the check is the user's).
- Headless panel dumps: `~/Library/Application Support/macvr-test/webui-dump/` (`*-over-grey.png`).
- Cost (screen sharing off): loading screen with spinner, about 23 panel changes/s. macvr-webhelper ~3 %, WebContent
  ~2 %, WebKit GPU process 8-13 % of one core; conversion 15-30 ms CPU per second; GPU copy ~0.35-0.75 ms per new
  image; snapshot latency 3-5 ms. Static panels: a third of the snapshots.
- Seen in the game: the capture rate fell to ~2/s and the overlay's XR frames to ~10/s after a few minutes (App Nap
  on the windowless helper). The helper now holds a `userInitiated | latencyCritical` activity; 30/s confirmed
  headless, not yet re-checked in a game.
- First overlay session in a WiVRn session: the first Mach pairing timed out once (`no HELLO for nonce`); the 2 s
  retry worked. Session creation ~1.4 s the first time (Vulkan device), 10 ms after.
- At Alyx's startup map the game sends `end_loading` 0.23 s after "Press Trigger To Start" (also in older OpenComposite
  logs), so that prompt is only visible on save loads, where the game waits for the trigger.

## Fonts

Alyx's `webui/fonts/raju-*.otf` (and SteamVR's own `motiva-sans-*.ttf`) are not plain font files: a 4-byte plaintext
size followed by 8-byte cipher blocks. vrserver's `get_font` decrypts them ("Invalid encrypted font file %s"). MacVR
doesn't decrypt them (that would mean extracting SteamVR's key; the user chose the fallback, 2026-10-26). The page then uses its CSS
fallback (`"Raju", "Arial"`), so the text is Arial, not Raju. A plain `raju-*.otf` put into
`~/Library/Application Support/macvr/fonts/` is used instead (served by the same `get_font` URL).

## Render models (holograms): not done

The page also emits `rendermodel` nodes (OBJ + DDS from `set_paths.models`, e.g. `play_space_center_feet.obj` on every
loading screen and the city hologram in a2+ maps) with tint, opacity (also negative), `fresnel {color, opacity,
strength}`, `wireframe`, `solid`, `culling`, `no-depth-write`, `texture-id` (a `texture` node's file name without
extension). They are parsed and counted in the log but not drawn. What's known for doing it SteamVR's way:
- vrcompositor draws them with D3D11 rasterizer states (wireframe = `FILL_WIREFRAME`, back/front culling) and its
  shaders `geom_fresnel_vs` + `distort_geom_fresnel_ps`; SteamVR ships SPIR-V builds in
  `SteamVR/resources/shaders/vulkan/` (`spirv-cross` decompiles them: per-vertex flat fresnel term
  `1 − pow(|dot(V, N)|, k)`, colour = texture × mix(colour A, colour B, fresnel), optional sRGB decode).
- Starting points in `vrcompositor.exe` (SteamVR as installed 2026-10): the rendermodel node's properties are parsed
  around 0x1400a3bc0-0x1400a3d80 (`texture-id`, `strength`, `wireframe`, `solid`, `culling`, `no-depth-write` string
  references), and drawn around 0x1400ec2f0-0x1400ec460 (`fresnel`, `culling`, `wireframe`).
- Missing: which scene-graph property feeds which uniform (needs vrcompositor's CRenderModel code), the blend state
  for negative opacities, and the render target (depth, format). Then: an OBJ/DDS (BC/DX10) loader and a projection
  layer (with depth) in the same overlay session.

## Tests

- `tests/webui/alyx_sequence.mjs [map]` (node ≥ 22, built-in WebSocket): plays the game's side (register web root,
  wait for ready, Alyx's logged messages) against the running broker. With `MACVR_WEB_NO_XR=1 MACVR_WEB_DUMP=<dir>`
  on a hand-started broker it's fully headless.
- `bridge/tests/ovr_d3d11_test.exe` with `OVR_TEST_INTERSTITIAL=1 OVR_TEST_WEBROOT=<path>`: the same through
  OpenComposite in Wine (RegisterMailbox, RegisterExternalWebRoot via slot 26, ReadMessage until ready).
- `build/tests/xr_overlay_quad <runtime.dylib> [s]` (`tests/webui/xr_overlay_quad.c`): one overlay quad, the
  compositor spike.
