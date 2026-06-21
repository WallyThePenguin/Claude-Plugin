# Studio Agent — Animation Engine (Slice D) design

**Date:** 2026-06-21
**Status:** design approved in brainstorming; ready for a writing-plans pass. **No code yet.**
**Serves:** Asset Creator sub-project #2 ("full animation application") — slice D of the rig editor (B=IK done,
C=drag posing later, D=this, E=Evaluate-vs-rubric next-after).
**Builds on:** the rig foundation rework (native R15 spawn + `RigWorkbench.applyPose`/`StepAnimations`), the
IK slice, the camera rig + capture pipeline (`CaptureCore`), and the native-rig-animation research
(`docs/superpowers/specs/2026-06-20-native-rig-animation-research.md`, §§3-4, 8).

---

## 0. Goal

Give the agent a **native, edit-mode animation engine**: author a clip as a flip-book of keyposes, preview it
as a filmstrip the agent can SEE and iterate on, and (lightly) attempt export — all without leaving Studio
edit mode and without uploading anything to preview.

The authoring loop: **pose the rig (existing `pose_joint`/`ik_reach`) → snapshot the current pose as a keyframe
at time t → repeat → preview the filmstrip → look → adjust a pose → re-snapshot → re-preview → export.** This is
the capture-and-refine ethos applied to motion, and it reuses every primitive already shipped.

---

## 1. Decisions (settled in brainstorming)

1. **Authoring model = flip-book keyposes.** The agent poses with the existing tools, then snapshots the whole
   current pose into a keyframe. Not direct curve/data authoring (that bypasses the pose-and-look loop).
2. **Clip storage = a real `KeyframeSequence` in `rig/AnimSaves/<clipName>`** — the official Animation Editor's
   own folder convention. Benefits: native + inspectable, persists with the place, undoable, and **the human can
   open the agent's clip directly in Roblox's Animation Editor to refine it.**
3. **Export (this slice) = light try + fallback.** `export_animation` attempts `AssetService:CreateAssetAsync(ks,
   Enum.AssetType.Animation, …)` and, on the expected "unsupported type" reject, returns the manual handoff (the
   clip is in AnimSaves → open the Animation Editor → Publish). It auto-upgrades for free if Roblox ever ships
   in-Studio animation support. **Full programmatic export is a dedicated later slice** (see §9).

---

## 2. Proven facts (the feasibility spike, 2026-06-21, via the dev bridge)

Run live against a real R15 rig before designing. **LIVE-TEST #2 (native edit-mode playback) PASSED:**

1. **Build a clip from the Motor6D graph:** a nested `Pose` tree rooted at `HumanoidRootPart` (each `Pose.Name`
   = the child part name, `Pose.CFrame` = that joint's `Motor6D.Transform`) registers as a valid clip.
   **`ks:AddKeyframe(kf)` is REQUIRED** — bare `kf.Parent = ks` left `track.Length = 0` (the load-bearing gotcha).
2. **Register locally, no upload:** `KeyframeSequenceProvider:RegisterKeyframeSequence(ks)` returns a content-hash
   id usable as an `Animation.AnimationId`. (`RegisterActiveKeyframeSequence` returned a null `active://0` handle —
   do NOT use it; the hash variant works.)
3. **Play + sample in edit:** `Animator:LoadAnimation(anim)` → `track:Play(0)` → set `track.TimePosition = t` →
   `Animator:StepAnimations(0)` evaluates the clip at `t` with **Roblox's own interpolation**. Right hand rose
   monotonically `3.05 → 3.61 → 4.34` across t=0→1; left (un-posed) hand stayed `2.83`. Two captures (t=0 vs t=1)
   visibly differed. **So the filmstrip is a deterministic scrub-and-sample — no hand-rolled interpolation.**
4. **Mode isolation:** after `track:Stop()` + destroying the temp Animator and clearing Transforms, a manual
   `pose_joint` moved the rig again — **tearing the track down returns control to manual posing** (resolves the
   §4.4 Animator-vs-Transform conflict by construction).

**Export landscape (verified read-only, 2026-06-21):** in-Studio `AssetService:CreateAssetAsync` still does NOT
support Animation (Model/Plugin/Mesh/Image only, as of the beta thread Apr 2025). **Open Cloud Assets API added
animation upload (as `.rbxm`) on 2025-10-23** — the reliable, *safe* (scoped API key, not the account cookie)
programmatic route, but it runs through the **sidecar** (the plugin's HttpService is firewalled from Roblox
domains) and has one unsolved wrinkle: producing a `.rbxm` of the KeyframeSequence from inside a plugin. Hence
export is its own slice (§9).

---

## 3. Architecture

A new pure-ish engine module + a thin tool module, plus reviving the dormant `capture_animation` stub. Mirrors
the existing rig stack (`RigWorkbench` + `Tools/Rig`).

### New modules
- **`src/AnimationClip.luau`** — the engine core (stateless; operates on rigs/clips in the DataModel):
  - `buildKeyframe(rig, time, transformsMap?) -> Keyframe` — the proven nested-`Pose`-tree construction from the
    rig's Motor6D graph; snapshots current `Motor6D.Transform` per joint unless `transformsMap` overrides.
  - `getOrCreateClip(rig, clipName) -> KeyframeSequence` — find/create `rig/AnimSaves/<clipName>` (AnimSaves
    Folder created if absent).
  - `snapshotKeyframe(rig, clipName, time) -> (text, ok)` — replace any keyframe at `time`, add a fresh one built
    from the current pose, via `ks:AddKeyframe`.
  - `removeKeyframe(rig, clipName, time)` / `clearClip(rig, clipName)` / `listClip(rig, clipName) -> text` (times,
    #posed joints per keyframe, length, loop, priority).
  - `register(ks) -> id` — `RegisterKeyframeSequence`.
  - Pure helpers (unit-testable): the Pose-tree builder over a synthetic joint map, time-key normalization
    (round + dedup), the list renderer.
- **`src/AnimationClipSpec.luau`** — in-Studio self-test for the pure parts (Pose-tree shape/names/CFrames over a
  synthetic graph, time-key normalization, list rendering, clear). No spawn/web. Run via a temporary
  `require(script.AnimationClipSpec).run()` in `init.server`, like the other specs.
- **`src/Tools/Animate.luau`** — descriptors `add_keyframe`, `list_clip`, `remove_keyframe`, `clear_clip`,
  `export_animation`. Thin wrappers over `AnimationClip` + the shared `resolveRig` (path or current selection)
  pattern from `Tools/Rig.luau`.

### Modified
- **`src/Tools/Capture.luau`** — replace the `runAnimation` stub with the real filmstrip (see §4.4). Reuses
  `CaptureCore` for all camera/trigger/fetch mechanics. Schema gains a `clip` input alongside the existing
  `animation` (one of the two identifies the source).
- **`src/Tools/init.luau`** — register the Animate descriptors (after `Ik`).
- **`src/SystemPrompt.luau`** — an "Animating" subsection: the flip-book loop and the rule that previewing tears
  its track down so posing/IK keep working; that clips live in AnimSaves and can be refined in the Animation
  Editor; that export currently lands on the manual handoff.
- **`src/Relay.luau` / `src/RelaySpec.luau`** — the DataModel-mutating animation tools relay by default (absent
  from `LOCAL_TOOLS`, like `pose_joint`/`create_instance`); `capture_animation` already relays. Add the new tool
  names where the spec enumerates the registry. No new local tools.

---

## 4. Tool surface + data flow

All tools share `resolveRig(args.rig)` (a dot-path or the current Studio selection) and a default clip name
`"AgentClip"`. DataModel edits are wrapped in a ChangeHistory recording (undoable), like the rig tools.

### 4.1 `add_keyframe {rig?, clip?, time}` (destructive, relays)
Resolve rig → `getOrCreateClip` → read every `Motor6D.Transform` (the current pose set by `pose_joint`/`ik_reach`)
→ `buildKeyframe(rig, time, current)` (replacing any keyframe already at `time`) → `ks:AddKeyframe`. Returns the
clip summary (name, #keyframes, sorted times, length). If `time` is omitted it appends after the last keyframe
(a small default gap, e.g. 0.5s; exact gap chosen in the plan).

### 4.2 `list_clip {rig?, clip?}` (read-only)
`listClip` → text: each keyframe's time + #posed joints (joints whose pose ≠ identity), plus clip length, loop,
priority. Friendly message if the clip/AnimSaves is absent.

### 4.3 `remove_keyframe {rig?, clip?, time}` / `clear_clip {rig?, clip?}` (destructive, relays)
Remove the keyframe nearest `time` (within a small epsilon) / remove all keyframes. Undoable. Returns the updated
summary.

### 4.4 `capture_animation {rig?, clip?|animation?, frames?, startTime?, endTime?, angle?}` (non-destructive, relays)
The revived filmstrip. Source = a working `clip` (AnimSaves KS → `register`) OR an `animation` (an asset id used
directly, or a path to a KeyframeSequence instance → `register`). Then:
1. **Save** the rig's current `Motor6D.Transform` map (to restore after).
2. Get-or-create a temp `Animator`; `LoadAnimation(anim)`; `track:Play(0)`; poll `track.Length > 0` (≤ ~4s).
3. Sample times = `startTime..endTime` (default `0..length`), `frames` evenly-spaced samples (default 8, capped
   at 20 like `capture_angles`).
4. **Save camera** (`CaptureCore.saveCamera`); frame the rig once from `angle` (a preset via
   `CaptureCore.frameCFrame` on the rig's bounding box) — the SAME fixed angle for every frame.
5. For each sample `t`: `track.TimePosition = t; animator:StepAnimations(0); CaptureCore.settle; triggerCapture`.
6. **Restore (always, pcall-protected):** `track:Stop()` + destroy the temp track/Animator (return manual
   control), restore the saved Transforms (so the working pose isn't left on the last frame), restore the camera.
7. `CaptureCore.fetchCaptures` → labeled blocks (each stamped `frame i/N @ t=…s`).

### 4.5 `export_animation {rig?, clip?}` (non-destructive)
Resolve the clip KS. `pcall(AssetService:CreateAssetAsync(ks, Enum.AssetType.Animation, {Name=…, Description=…}))`.
On success: return the new `AnimationId`. On the expected reject (or any error): return a clear **handoff note** —
the clip is saved at `rig/AnimSaves/<clip>`; open Avatar → Animation Editor, select the rig, load the clip, and
Publish; full programmatic Open Cloud export is the next slice. (The handoff is a SUCCESSFUL result, not isError.)

---

## 5. The §4.4 safety invariant (Animator vs Transform)

Static posing (slice A/B/this-slice authoring) writes `Motor6D.Transform` and applies it with
`StepAnimations(0)` and **no playing track**. Animated playback (preview) loads + plays a track, which OVERRIDES
manual Transform while it exists. **Rule: a track exists only inside `capture_animation`, and that tool tears it
down (Stop + destroy the temp Animator) and restores the saved Transforms before returning.** So authoring and
playback never coexist. `add_keyframe` snapshots the Transforms set by the manual pose path, which is valid
precisely because no track is playing at authoring time. Verified by the spike (step 4).

---

## 6. Error handling

- nil rig / no Motor6Ds → string error (isError), like the rig tools.
- preview/export on an **empty clip** (0 keyframes) → friendly error ("add keyframes first").
- preview with **no Humanoid/AnimationController** → can't get an Animator → error noting the rig needs one (native
  rigs have a Humanoid; a bare custom Motor6D model may need an AnimationController).
- `RegisterKeyframeSequence`/`LoadAnimation` failure, or `track.Length` stays 0 after the poll → string error;
  **camera + Transforms are restored in the pcall-protected finally** regardless (mirrors `capture_angles`).
- sidecar down for the filmstrip → `CaptureCore.fetchCaptures` returns its existing "sidecar not running" guidance.
- `export` `CreateAssetAsync` throwing → caught → the manual-handoff note (a success, not isError).
- All tools stay total (dispatch also wraps handlers in pcall).

---

## 7. Testing / verification

- **`AnimationClipSpec`** (in-Studio, pure): Pose-tree structure (correct nesting + names + CFrames over a
  synthetic joint graph), time-key normalization (round/dedup/replace), `listClip` rendering, `clearClip`.
- **Static:** `selene` 0/0, `stylua --check`, `rojo build` green at every task.
- **Bridge dogfood (the verification that matters — a clear filmstrip, not coordinates):** `spawn_rig` →
  `ik_reach` the right arm to pose A → `add_keyframe {time:0}` → repose to B → `add_keyframe {time:0.5}` →
  `list_clip` (2 keyframes, length 0.5) → `capture_animation` → **Read the frames and LOOK** (the arm sweeps A→B
  across frames; body/other limbs steady) → confirm a manual `pose_joint` still works after preview (control
  returned) → `export_animation` returns an AnimationId OR the handoff note → confirm the clip is visible under
  `rig/AnimSaves` (Animation-Editor-openable). Clean up the test rig; don't touch the user's `Rig`.
- **Adversarial-review Workflow** on the logic that can't be run locally (like prior slices).

---

## 8. File structure

| File | New/Mod/Del | Responsibility |
|---|---|---|
| `src/AnimationClip.luau` | **new** | Engine core: `buildKeyframe`, `getOrCreateClip`, `snapshotKeyframe`, `removeKeyframe`, `clearClip`, `listClip`, `register` + pure helpers. |
| `src/AnimationClipSpec.luau` | **new** | In-Studio self-test for the pure parts. |
| `src/Tools/Animate.luau` | **new** | Descriptors: `add_keyframe`, `list_clip`, `remove_keyframe`, `clear_clip`, `export_animation`. |
| `src/Tools/Capture.luau` | mod | `runAnimation` stub → the real scrub-and-sample filmstrip; add a `clip` input. |
| `src/Tools/init.luau` | mod | Register the Animate descriptors. |
| `src/SystemPrompt.luau` | mod | "Animating" subsection (flip-book loop, mode isolation, AnimSaves, export handoff). |
| `src/Relay.luau` / `src/RelaySpec.luau` | mod | Confirm animation writers relay by default; enumerate the new tool names. |

---

## 9. Non-goals / future

- **Full programmatic export** (the next slice): Open Cloud Assets API upload of the clip as `.rbxm` via the
  sidecar with a scoped API key — reliable + safe as of 2025-10-23, but needs a live-test of how a plugin produces
  a `.rbxm` of the KeyframeSequence (candidates: the sidecar builds the `.rbxm` from JSON pose data; a one-time
  "Save to File"; or an in-plugin serialization path). Slice D's `export_animation` is forward-compatible (same
  clip, just a different publish backend).
- **`CurveAnimation`** (smooth per-channel curves) — a fidelity upgrade after the legacy `KeyframeSequence` loop
  works (research §3.2).
- **Per-keyframe easing styles / hold/looping UX, multi-rig scenes, camera tracks** — later; v1 uses linear poses.
- **Hand/wrist orientation in IK** — tracked with slice B; orthogonal to this slice.

---

## 10. Source-of-truth references

- Native-rig-animation research: `docs/superpowers/specs/2026-06-20-native-rig-animation-research.md` (§§3-4, 8).
- Rig foundation rework: `docs/superpowers/specs/2026-06-21-studio-agent-rig-foundation-rework-design.md`.
- IK slice: `docs/superpowers/specs/2026-06-21-studio-agent-ik-grab-and-place-design.md`.
- Spike facts: §2 above (run live this session via `scripts/studio-agent.ps1`).
- Open Cloud animation upload (export slice): DevForum "Open Cloud Upload Support for More Asset Types"
  (2025-10-23); Assets API reference `create.roblox.com/docs/reference/cloud/assets/v1`.
