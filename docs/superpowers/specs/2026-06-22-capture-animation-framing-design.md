# capture_animation framing — auto-fit to the swept pose extent (design)

**Date:** 2026-06-22
**Status:** approved (design B)
**Slice-D follow-up.** Source of the problem: `src/Tools/Capture.luau` `runAnimation` frames the
camera to the rig's RESTING bounding box (`rig:GetBoundingBox()` measured *before* playback) at a
hardcoded distance of `1`. Action poses (a punch, a jump split, a big arm swing) extend past that
resting box, so the filmstrip crops them — the agent can't fully see the pose it authored, which
defeats the look-and-iterate loop.

## Goal
`capture_animation` frames the WHOLE motion the first time, so a splayed/action pose is fully visible
without the agent having to notice the crop and retry. Keep a manual `zoom` knob for taste.

## Approach (B): auto-fit to the swept extent + a `zoom` multiplier
Add a cheap **measure pre-pass** that steps the clip through the same sample times the capture pass
will use, unions the rig's world bounding box across all those poses, and frames once to that union
(scaled by `zoom`). The measure pass only steps joints (`TimePosition = t; StepAnimations(0)`) and
reads part transforms — it takes NO screenshots, so it is cheap relative to the capture pass.

Rejected alternatives: **A** (a `zoom`/distance param only) leaves the notice-and-retry friction;
**C** (a bigger constant default distance) is a guess that still crops big poses and over-frames
subtle idles.

## Components

### `src/CaptureCore.luau` — a new PURE helper (unit-testable, no DataModel)
```
CaptureCore.unionAABB(boxes: { { pos: Vector3, size: Vector3 } }) -> (Vector3, Vector3)?
```
- Returns `(center, size)` of the world-axis-aligned union of the given `pos ± size/2` boxes, or
  `nil` for an empty list.
- Using `pos ± size/2` (axis-aligned, ignoring part orientation) is a deliberate slight OVER-size —
  the extra is exactly the framing headroom we want.
- Pure: no Instance reads — the caller collects `{pos, size}` from the rig's BaseParts and passes the
  list in, so the math is testable in `CaptureCoreSpec` without Studio.

### `src/Tools/Capture.luau` — `runAnimation`
- After the clip's length resolves and the sample window (`startT`/`endT`/`frames`) is computed, run a
  **measure pass**: for each sample time `t`, set `animTrack.TimePosition = t; animator:StepAnimations(0)`,
  collect `{pos = part.Position, size = part.Size}` for every `BasePart` under the rig, and accumulate
  into a running min/max (or collect per-frame and call `unionAABB` once on the union of all frames).
- Frame the camera to the swept `(center, size)` via the existing
  `CaptureCore.frameCFrame(center, size, preset.yaw, preset.pitch, zoom)` (the last arg is the distance
  scale — already supported, currently hardcoded `1`).
- **Fallback:** if the measure pass yields no parts/bounds (degenerate rig), fall back to today's
  `rig:GetBoundingBox()` framing so the tool never regresses to a worse state.
- The measure pass runs INSIDE the existing saved-transforms + saved-camera window that `runAnimation`
  already tears down and restores at the end (`restoreTransforms` + `RigWorkbench.applyPose` +
  `restoreCamera`), so there is no new state to leak and the working pose is restored exactly as today.

### Schema + description
- Add `zoom` (number, default **1.1**) to the `capture_animation` input schema and mention it in the
  tool description ("zoom: distance scale of the auto-fit; >1 pulls back, <1 pushes in").
- Default `1.1` gives a touch of headroom over the auto-fit; the auto-fit already sizes to the swept
  extent, so `1.1` is conservative (not a magic large constant).

## Data flow
`runAnimation` → resolve source/animator (unchanged) → load+play track, resolve length (unchanged) →
compute sample window (unchanged) → **measure pass: step each `t`, collect part AABBs, `unionAABB` →
swept (center,size)** → `frameCFrame(center, size, yaw, pitch, zoom)` → **capture pass: step each `t`,
capture (unchanged)** → restore transforms/pose/camera (unchanged) → fetch + assemble filmstrip
(unchanged).

## Error handling
- No new failure modes. The measure pass is wrapped by the same `pcall`-guarded restore flow; if it
  throws or finds no bounds, fall back to `GetBoundingBox()` framing (the current behavior).
- `zoom` is coerced like the other numeric args (`type(args.zoom) == "number" and > 0`, else default).

## Testing
- **Pure:** `CaptureCoreSpec` (create it if absent, or extend it) — `unionAABB` over a few boxes
  returns the correct center/size; an off-center + a splayed box widen the union; empty list → `nil`.
- **Static:** `selene` 0/0 + `stylua` + `rojo build` green.
- **Live (bridge dogfood, after a USER Studio restart):** `spawn_rig` → author a deliberately splayed
  keypose (e.g. `ik_reach` both arms wide + a leg out) at one time and a neutral pose at another →
  `add_keyframe` each → `capture_animation` → **LOOK**: the splayed pose is now fully in frame (vs.
  cropped at the old hardcoded distance `1`); confirm `zoom: 0.8` pushes in and `zoom: 1.5` pulls back;
  confirm the working pose is restored afterward.

## Out of scope (YAGNI)
- Per-frame camera tracking (one fixed frame for the whole strip stays — it's what makes a filmstrip
  readable).
- Oriented (non-axis-aligned) tight bounds — the axis-aligned over-approximation is preferred for
  framing headroom.
- Applying the swept-bounds auto-fit to `capture`/`capture_angles` (those frame a static target; only
  `capture_animation` sweeps time).
