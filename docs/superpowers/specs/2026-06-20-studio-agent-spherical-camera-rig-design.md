# Studio Agent — Spherical Camera-Lock Rig (design)

**Date:** 2026-06-20
**Status:** design approved in brainstorm; no code yet.
**Serves:** the north star (push the quality ceiling) via the **Asset Creator** capture→evaluate→refine loop. This is **sub-project #1 of "full animation application"** — the inspection/capture foundation every later piece (rig spawn + joint-pose driver, animation filmstrip, rig dissection, the Evaluate tool) builds on.
**Builds on:** the capture tools (`src/Tools/CaptureCore.luau` — `frameCFrame`/`setCamera`/`resolveTarget`/the sidecar pipeline). The written-down design is in the memory `studio-agent-asset-creator-vision`.
**Memories:** `studio-agent-asset-creator-vision`, `studio-agent-training-vision`, `studio-agent-north-star`, `roblox-plugin-native-screenshot-infeasible`.

## Purpose

The agent can capture stills (`capture`) and a one-shot orbit (`capture_angles`, which snapshots discrete preset angles then restores the camera). To *inspect and iterate on* a visual asset, the agent needs a **navigable, stateful** camera it drives with high-level relative commands and re-captures from anywhere — the "spherical camera-lock rig" from the asset-creator sketch. This is that: a camera locked aiming at a target, orbiting on a sphere (azimuth + elevation + radius), driven by relative moves, persisting between calls. It works on **any existing target** and is the lens every later animation/asset piece looks through.

## Scope

- **In:** a stateful `CameraRig` controller + 3 parent-only tools (`camera_focus`, `camera_orbit`, `camera_release`) + an optional **debug-gizmo mode** (Config flag, default off) + wiring + a pure-math spec self-test.
- **Out (later sub-projects):** spawning rigs, the keyframe→joint-pose driver, the animation filmstrip (`capture_animation`), rig-structure dissection, the Evaluate tool. Also out: client-view-play orbit (v1 targets EDIT + the Play Server view, matching the capture pipeline's edit-first nature); physical persistent rig instances (we use an invisible math controller — see §Form).

## Form: invisible math controller (settled)

No persistent physical rig parts. The controller moves the **real `Workspace.CurrentCamera`** (which *is* the editor viewport — already proven edit-viable per the memory), computing its CFrame from the spherical state via `CaptureCore.frameCFrame`. The sketch's `CONTAINER→RING→CAMERA` is the mental model, not literal instances. **You still watch everything live:** moving `CurrentCamera` swings your actual view; later, the joint-pose driver will move the real rig's joints, so you watch animations play in the viewport. The math only *computes* transforms; they're applied to real, rendered instances. **Debug mode** (§Debug) optionally draws gizmo parts so you can also see the rig's spherical structure.

## The spherical model

State per locked target: `{ center: Vector3, size: Vector3, azimuth: number (deg), elevation: number (deg), distScale: number }`.
- **azimuth** — horizontal orbit (yaw), wraps mod 360.
- **elevation** — vertical orbit (pitch), **clamped to [-89, 89]** to avoid the look-at gimbal at the poles ("birds-eye" = elevation ≈ 89).
- **distScale** — radius as a multiplier on `frameCFrame`'s auto-fit distance (1 = fit the bounding box; <1 closer/zoom-in; >1 farther/zoom-out). Clamped to a sane range (e.g. [0.2, 8]).
- Camera CFrame = `CaptureCore.frameCFrame(center, size, azimuth, elevation, distScale)` (reuses the proven framing; the rig never hand-writes CFrames).

Moves are **relative by default** (deltas applied to current state) or **absolute** (set the value) when `relative=false` — so "rise to birds-eye" is `camera_orbit(elevation=89, relative=false)` and "orbit left a bit" is `camera_orbit(azimuth=-30)` (relative).

## Components

| File | Responsibility |
|---|---|
| `src/CameraRig.luau` | Stateful controller. PURE helpers (`applyMove`, `clampElevation`, `wrapAzimuth`, `clampZoom`) split for unit-testing; instance methods `focus`/`orbit`/`release`/`state` touch `CaptureCore` + Workspace. Holds debug-gizmo refs. |
| `src/CameraRigSpec.luau` | In-Studio self-test for the pure spherical-state helpers (mirrors `SkillCatalogSpec`). |
| `src/Tools/CameraRig.luau` | The 3 tool descriptors (`camera_focus`/`camera_orbit`/`camera_release`), parent-only, non-destructive. |
| wiring | `Config` flag `cameraRigDebug`; `init.server` deps `cameraRig = CameraRig.new(plugin)`; `AgentLoop` `toolContext.cameraRig`; `Tools/init` registration; `SystemPrompt` "inspect visually" section. |

### `CameraRig.luau` (controller)
- `focus(target?)` → resolve the target (or current selection) via `CaptureCore.resolveTarget` → center/size; init `azimuth=35, elevation=20, distScale=1` (a ¾ view); **save the user's camera** (`CaptureCore.saveCamera`) on first focus; set the camera; (re)draw debug gizmos if on. Returns the new state.
- `orbit(dAzimuth?, dElevation?, dZoom?, absolute?)` → update state (relative add or absolute set), clamp/wrap, recompute via `frameCFrame`, `setCamera`; redraw gizmos if on. Requires a prior `focus` (else returns a "focus first" error). Returns the new state.
- `release()` → `CaptureCore.restoreCamera(saved)`, clear state + remove debug gizmos.
- `state()` → the current `{azimuth, elevation, distScale, target}` (for the tool result text).
- Pure helpers (no DataModel): `wrapAzimuth(a)`, `clampElevation(e)` → [-89,89], `clampZoom(z)` → [0.2,8], `applyMove(state, move)` → new state. These are what `CameraRigSpec` tests.

### `Tools/CameraRig.luau` (the agent's surface)
Each tool, after moving the camera, **captures** (reuses `CaptureCore.triggerCapture`/`settle`/`fetchCaptures`) and returns the image + a one-line state summary, so the agent sees where it landed (tight inspect loop). Parent-only (not in subagent allowlists; nil-guards `context.cameraRig`); non-destructive (camera move isn't a place-content edit).
- **`camera_focus(target?)`** — lock onto a target (path) or the current selection; frame it at a ¾ view; capture. *"Lock the camera onto X and show me."*
- **`camera_orbit(azimuth?, elevation?, zoom?, relative?)`** — move on the sphere (relative deltas by default; `relative=false` to set absolute values), re-aim at the locked center, capture. *"orbit left", "rise to birds-eye", "zoom out".*
- **`camera_release()`** — restore the user's pre-focus camera and remove any debug gizmos. *"give me my view back."*

## Debug mode

`Config.cameraRigDebug` (default **false**; settable via the panel/SetSetting like other config). When **on**, `focus`/`orbit` draw visualization gizmos under a tagged folder `Workspace/__StudioAgentCameraRig` (CollectionService-tagged for cleanup): a translucent **orbit sphere** (radius = the current orbit distance, centered on the target), a small **camera marker** at the computed camera position, and a **pivot marker** at the target center. Gizmos are refreshed each move and removed on `release` (or when debug is toggled off). When **off**, gizmos are never created → captures are clean. (Debug gizmos *will* appear in captures while on — that's the intended debug view.)

## Data flow

`camera_focus("Workspace.Dummy")` → controller locks, frames the dummy, sets `CurrentCamera` (your view swings to a ¾ shot), captures → agent sees the image + `{az 35, el 20, zoom 1.0}`. → `camera_orbit(elevation=89, relative=false)` → camera rises to birds-eye, captures the top-down. → `camera_orbit(azimuth=-90)` → orbits a quarter-turn left, captures. → `camera_release()` → your original view is back.

## Error handling

- `camera_orbit` before `camera_focus` → "lock onto a target first with camera_focus." `camera_focus` with no target + no selection → `CaptureCore.resolveTarget`'s error. Capture failures fall back to a string error (`isError`), exactly like `capture` (sidecar not running → the standard "start the sidecar" message). `cameraRig` is optional in `deps` and nil-guarded everywhere (edit / Server-view / relay paths unchanged when absent).

## Testing

- **`CameraRigSpec`** (pure, in-Studio): `wrapAzimuth` (370→10, -30→330), `clampElevation` (95→89, -120→-89), `clampZoom` (0→0.2, 99→8), `applyMove` relative vs absolute. Pattern = `SkillCatalogSpec`.
- **Static (here):** `selene src` 0/0, `stylua --check src`, `rojo build`.
- **Live (user, in Studio):** `camera_focus` on a part → view swings + a framed capture returns; `camera_orbit` relative + absolute (birds-eye) → view moves + captures; `camera_release` restores; toggling `cameraRigDebug` shows/hides the gizmos. (Sidecar must be running for the captures, same as `capture`.)

## Risks & mitigations

- **Gimbal at the poles:** elevation clamp to ±89 (never exactly 90).
- **Hijacked camera:** `focus` saves the user's camera; `camera_release` restores it; document it in the tool description + SystemPrompt so the agent releases when done.
- **Debug gizmos leaking into a save:** they're transient, tagged, parented under one folder, removed on release / debug-off; they're plugin-created so they don't persist unless the user saves with debug on (acceptable — debug is opt-in).
- **Reuse correctness:** all framing/camera/capture goes through the proven `CaptureCore` — the only new logic is the spherical *state* management (unit-tested) + gizmo drawing.

## Next (subsequent "full animation application" sub-projects)

2. Keyframe→joint-pose driver + rig spawn (the edit-mode animation engine). 3. Animation filmstrip capture (compose the camera rig + joint driver). 4. Rig dissection (PropertyCatalog rig classes). 5. The Evaluate tool (grade against the loaded rubric using these captures + structure). Each its own spec→plan→build.
