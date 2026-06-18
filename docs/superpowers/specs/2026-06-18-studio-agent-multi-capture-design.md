# Studio Agent — Multi-Image Viewport Capture (disk-reader) — Design

**Date:** 2026-06-18
**Status:** Approved design (pending spec review) → implementation plan next.
**Related:** memory `roblox-plugin-native-screenshot-infeasible`; deep-research report (wf_1bfc7e62-918);
spec `2026-06-18-studio-agent-client-relay-design.md` (the relay this builds beside).

## 1. Summary / Goal

Replace the whole-window `PrintWindow` capture with a **disk-reader** that serves the real, full-resolution
**viewport** PNGs Roblox writes when `CaptureService:CaptureScreenshot` fires, and add **multi-image
capture** so the agent can build and visually verify objects, assets, rigs, and art from multiple angles,
and review animations as a filmstrip.

Three tools (edit-mode only for v1):
- **`capture`** — single viewport shot at the current camera (replaces today's whole-window grab).
- **`capture_angles`** — orbit a target: N evenly-spaced framed angles (objects / assets / art).
- **`capture_animation`** — filmstrip: time-sampled frames of an existing/assembled animation from a fixed
  angle (review a motion; see a finished authored animation end-to-end).

## 2. Background / why this works

Empirically verified this session:
- `CaptureService:CaptureScreenshot(cb)` writes a full-res viewport PNG to
  `%LOCALAPPDATA%\Roblox\tmp-capture-storage\wob-<StudioPID><counter>` (confirmed: 1651×805 & 1935×805,
  24-bit PNG; one opened = the edit-mode Baseplate viewport; file mtimes matched the capture callbacks to
  the second; the dir is **session-scoped / low-noise**, named `wob-<PID>…`).
- A plugin **cannot** read that file silently — the only native plugin file-read is
  `StudioService:PromptImportFileAsync` + `File:GetBinaryContents()`, which needs a manual file-picker
  dialog. `rbxtemp → CreateEditableImageAsync` is blocked; `GetCaptureFilePathAsync` is RobloxScript-gated.
  So a **local helper must read the file** — but the helper collapses from a fragile Win32 window-grabber
  into "read the newest `wob` PNG" (it's already an encoded PNG; no re-encode).
- The sidecar has **no engine access** → all camera control + capture triggering is plugin-side Luau; the
  sidecar only reads bytes off disk. (This rules out any "sidecar-driven" capture.)

## 3. Anthropic image limits (verified — vision docs, 2026-06-18)

- **Token cost is patch-based:** `⌈width/28⌉ × ⌈height/28⌉` visual tokens per image.
- **Native resolution cap:** Opus 4.8 / 4.7 / Fable 5 / Mythos 5 → **4784 tokens, ≤2576 px long edge**
  (high-res, automatic); other models → 1568 tokens, ≤1568 px. Larger images are downscaled
  aspect-preserving before processing.
- **Images per request:** 100 (200k-context models) / **600** (others, incl. 1M-context) on the API;
  claude.ai is 20/message.
- **>20 images in one request → stricter per-image limit: each ≤2000 px on every side**, else
  `invalid_request_error` referencing "many-image requests". Our captures (≤1935 px wide) already satisfy
  this; a 4K-monitor viewport (~2560 px) would not.
- **Max image size:** 10 MB base64 (direct API). **Request size limit: 32 MB** (standard endpoints) — the
  real binding constraint: ~1 MB PNG ≈ 1.35 MB base64, so ~20 full-res captures ≈ 27 MB approaches the cap.

**Implication (the "no arbitrary cap" design):** send native res by default; auto-downscale once a batch
exceeds 20 images (also *required* by the many-image rule) or as the projected payload nears 32 MB; chunk
(return a partial + an explicit "request the next range/subset" notice) if even the floor won't fit. The
agent's *authored* animation smoothness is never capped — only how many stills are reviewed per call.

## 4. Architecture

All capture flows are: **plugin sets up the shot(s) → triggers `CaptureScreenshot` N times → sidecar
batch-reads the N newest `wob` PNGs (downscaling if asked) → returns N image blocks**. A shared Luau core
(`CaptureCore`) owns camera save/set/restore, orbit math, the trigger+await, and the sidecar fetch. The
three tools are thin wrappers differing only in *what varies between frames* (nothing / camera angle /
animation time). Approach 1 (plugin-orchestrated, one batch-fetch) per the brainstorm.

## 5. Components

- **`sidecar/capture.py`** — drop `PrintWindow`. Add:
  - `newest_captures(count, since_ts, max_px=None)` — glob `tmp-capture-storage/wob-*`, keep complete PNGs
    (ends with `IEND` chunk) with `mtime ≥ since_ts`, sort by mtime ascending, take the newest `count`;
    if `max_px` is set and a PNG's long edge exceeds it, downscale aspect-preserving (Pillow) before
    returning; poll up to a timeout for `count` complete files (captures may still be flushing).
- **`sidecar/server.py`** — new token-authed endpoint `GET /captures?count=N&since=<epoch>&max_px=<n>&b64=1`
  → `{ "images": [<base64 png>, …], "returned": N, "shortfall": bool }`. Remove/retire the `/screenshot`
  PrintWindow route (no fallback, per decision).
- **`src/Tools/CaptureCore.luau`** (new) —
  - `resolveTarget(input) → (centerCFrame, size)`: current Studio `Selection` (default) or an instance path;
    union bounding box (`Model:GetBoundingBox()` for models, extents for BaseParts/descendants).
  - `frameCFrame(center, size, yawDeg, pitchDeg, distScale) → CFrame`: deterministic orbit math (agent
    never writes a CFrame). Distance fits the bbox to the camera FOV with a margin.
  - `PRESETS`: `front/back/left/right/top/bottom/iso → (yaw,pitch)`.
  - `saveCamera()/restoreCamera(saved)`; `triggerCapture()` (wrap `CaptureScreenshot` callback as a yield +
    a render-settle frame); `fetchCaptures(count, since, maxPx, config) → {base64}` (HTTP to sidecar,
    same error pattern as today's `Capture.luau`).
- **`src/Tools/Capture.luau`** (reworked) — exports the three descriptors; delegates to `CaptureCore`.
- **`src/Tools/init.luau`** — register `capture_angles` + `capture_animation` beside `capture`.
- **`src/SystemPrompt.luau`** — short guidance: use `capture` (one shot), `capture_angles` (give a target +
  count; never compute camera math yourself), `capture_animation` (review a finished/existing animation as
  a filmstrip).
- **`src/CaptureSpec.luau`** (new) — orbit-math determinism, preset mapping, input validation, error paths
  (mirrors `RelaySpec`/`WritersSpec`).

## 6. Tool surface (agent-facing)

- **`capture`** — single viewport shot at the current camera (triggers one `CaptureScreenshot`, no camera
  move; i.e. the N=1 case of the shared core). No inputs (drops today's `window` param). Returns 1 image.
- **`capture_angles`** — orbit a target.
  - `target?` (instance path; default = current Studio `Selection`)
  - `count` (default 6)
  - `elevation?` (`low`/`eye`/`high` or degrees; default ~20°)
  - `distance?` (scale of the auto-fit; default 1.0)
  - `presets?` (`["front","left","top",…]`; when given, overrides even-orbit)
  - Returns N images, each preceded by a tiny text label ("angle 3/6 — 180°, high").
- **`capture_animation`** — filmstrip of an existing/assembled animation.
  - `rig` (instance path to the model with an `Animator`/`Humanoid`)
  - `animation` (an asset id **or** a `KeyframeSequence`/clip path — flexibility resolved by the spike)
  - `frames` (default 8)
  - `startTime?`/`endTime?` (default = full clip; the **zoom** lever for high-density review of a sub-range)
  - `angle?` (a preset or single orbit angle, fixed across frames)
  - Returns N time-sampled images, labeled with timestamps. **Edit-mode playback is a feasibility spike (§9).**

**No fixed numeric frame/angle cap.** The tool auto-downscales as the count rises and chunks at the API
ceiling (§3): native res by default; once `count > 20` (or projected payload nears 32 MB) it requests
`max_px ≤ 2000` (smaller if needed to fit the payload budget); if a range is still too dense at the floor,
it returns the frames that fit plus a notice telling the agent to narrow the `startTime/endTime` (animation)
or split the angle set, rather than erroring out.

## 7. Data flow (`capture_angles`, count = 8)

1. `resolveTarget(target)` → `(center, size)`.
2. `saveCamera()`; set `Workspace.CurrentCamera.CameraType = Scriptable`; `since = os.time() - margin`.
3. Loop i=1..8: `frameCFrame(center, size, yaw=i·45°, pitch=elevation, distScale)` → set `Camera.CFrame`
   → wait a render-settle frame → `triggerCapture()` (await callback).
4. `restoreCamera(saved)` — in a guard so a mid-loop error still restores it.
5. Compute `max_px` from `count` + projected payload; one `GET /captures?count=8&since=…&max_px=…` →
   8 base64 PNGs (mtime-sorted = capture order).
6. Return `[text "8 angles @ high elevation…", image, text "angle 2/8 — 45°", image, …]` as the
   `tool_result` content array (interleaved labels + images).

`capture_animation` is the same protocol with the loop varying animation `TimePosition` instead of the
camera, camera fixed at `angle`.

## 8. Error handling

Same string-error (`is_error=true`) fallback pattern as today's `Capture.luau`: sidecar down / bad token
(401) / HTTP disabled / non-2xx / server-only-context. Plus:
- Empty selection or unresolvable `target` → ask for a target.
- Target with no spatial bbox → error.
- `CaptureScreenshot` callback timeout → error.
- Sidecar returns fewer files than requested (`shortfall`) → return what arrived + a warning block.
- Camera **always** restored via the guard, even on failure.
- Animation playback failure in edit → error (and the spike decides whether the mode is edit-viable at all).

## 9. Testing & the one feasibility spike

- **Luau spec (`CaptureSpec`)** — orbit-math determinism (bbox + count + elevation → expected camera
  positions / look directions), preset→angle mapping, input validation, downscale/chunk decision, error
  paths; mock `CaptureScreenshot` + the HTTP fetch.
- **Sidecar (Python)** — `newest_captures` over a temp dir of fake PNGs/mtimes: count, `since` filter,
  incomplete-PNG skip, `max_px` downscale.
- **Spike (do FIRST in implementation):** confirm `capture_animation`'s edit-mode playback — can we drive
  an `Animator`/`AnimationTrack` `TimePosition` in edit and have the rig pose update for capture? If edit
  playback is unreliable, `capture_animation` drops to a playtest follow-up while `capture` +
  `capture_angles` ship for edit. Also confirm the end-to-end trigger→file→read latency/race.
- **Live verify** in a fresh Baseplate: single shot; `capture_angles` on a part (eyeball the framed angles);
  `capture_animation` on a rig.

## 10. Out of scope for v1 (YAGNI)

Explicit-CFrame camera, playtest contexts (relay/RemoteEvent injection), declarative pose batches,
`PrintWindow` retention, and the sidecar token/process-friction reduction (auto-token handshake,
bundled exe) — each a separate follow-up.
