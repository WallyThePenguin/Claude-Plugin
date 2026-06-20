# Studio Agent — Rig Workbench (design, slice A of the rig editor)

**Date:** 2026-06-20
**Status:** design approved in brainstorm; no code yet.
**Serves:** the Asset Creator animation work — **sub-project #2, slice A** ("full animation application"). The rig editor's foundation: see + set joints on a real rig. Aims to **beat the Modern Rig Editor plugin** (ref: devforum.roblox.com/t/modern-rig-editor-plugin/260728) — match its skeleton preview + joint manipulation, then exceed it via AI-driven posing and the rails to IK/animation/capture-evaluate it can't do.
**Builds on:** the spherical camera-lock rig (`src/CameraRig.luau`, inspect any pose) + `CaptureCore`. Edit-mode posing via `Motor6D.Transform` is confirmed viable in the memory `studio-agent-asset-creator-vision` (the keyframe→joint-pose approach).
**Memories:** `studio-agent-asset-creator-vision`, `studio-agent-training-vision`, `roblox-plugin-native-screenshot-infeasible`.

## Purpose

We can now inspect any object (camera rig), but there's no way to **see a rig's joints or pose them**. This adds the rig editor's foundation: spawn/load a real R6/R15 rig, **read + visualize its skeleton** (joints + bones), and **pose its joints** (set `Motor6D.Transform`), all agent-driven and inspected through the camera rig. It is the base every later slice builds on (IK, human drag, keyframe/animation, capture-evaluate).

## The bar (Modern Rig Editor) + how we beat it

Its features: create/edit/delete Motor6D joints, reposition joint centers, **real-time skeleton preview**, multi-joint select + symmetry, increments, alignment, undo/redo; R6/R15/Humanoid/AnimationController/custom. Its **gaps:** no IK, **no animation/keyframing** (rig-setup only), human-only, painful overlapping-part selection.

Slice A **matches** the skeleton preview + joint manipulation and **already exceeds** on the AI axis (the agent reads/poses rigs from commands — no plugin does this). Later slices take its open flanks: **IK** (B), **human drag** (C), **animation** (D), **capture→evaluate vs the locomotion rubric** (E).

## Scope

- **In:** `RigWorkbench` (read skeleton / draw gizmo overlay / pose `Motor6D.Transform` / reset) + `RigTemplates` (spawn a blocky humanoid placeholder rig) + tools (`spawn_rig`, `get_rig`, `pose_joint`, `reset_pose`, `show_skeleton`) + a pure-helper spec + wiring. Read/visualize/pose work on **any** Motor6D rig (real R6/R15 included).
- **Out (later slices):** IK / grab-and-place (B); Blender-style human cursor-drag (C); keyframes / animation playback / export (D); joint-**center** (C0/C1) editing & custom-rig *setup* / multi-limb procedural rigs (later); the Evaluate tool (E); a full byte-exact Roblox R15 *spawn* (operate-on-existing covers R15; the spawned rig is a placeholder, not a shippable character).

## Posing channel: `Motor6D.Transform` (settled)

Posing sets **`Motor6D.Transform`** (the per-joint animation offset the Animation Editor drives) — it applies **live in edit** (confirmed) and is exactly the channel animations use, so it's the right foundation for the animation slices. We do **not** edit joint *centers* (`C0`/`C1`) here — that's rig *setup* (the Modern Rig Editor's domain), needed only for building custom rigs, and comes with custom-rig support later. Standard R6/R15 already have correct centers; you pose them.

## Spawn: native Roblox rig via InsertService, placeholder fallback (UPDATED 2026-06-20)

**Update from the live test:** `spawn_rig('r15')` now loads the **native Roblox R15 Block Rig** via `InsertService:LoadAsset(16644810619)` → extract the Model → `:MakeJoints()` (the step the unbuilt native rigs were missing) → `:MoveTo` the baseplate. The programmatic blocky build below is the **fallback** when the load fails or no native asset id exists (r6). `RigBuilderService` was probed live and **does not exist** (no programmatic Rig Builder API), so InsertService is the native path. `get_rig`/`pose_joint` remain rig-agnostic and work on the native rig (Motor6D).

### Programmatic placeholder (fallback)

`spawn_rig` builds a simple **blocky humanoid** (HumanoidRootPart + Torso + Head + 2 arms + 2 legs, an R6-shaped layout) where each `Motor6D`'s `C0`/`C1` is **computed from the part positions we choose** — so the joints are correct by construction, with no risk of hand-authoring Roblox's exact matrices wrong. It is a placeholder rig for posing/animation testing (the user OK'd blocky placeholders), NOT a byte-exact Roblox R6. **Real** R6/R15 rigs (e.g. from Studio's Rig Builder) are handled by the rig-agnostic read/visualize/pose path — so R15 works immediately even though `spawn_rig` makes a placeholder. (A faithful R15 spawn is a later add.)

## Components

| File | Responsibility |
|---|---|
| `src/RigWorkbench.luau` | PURE helpers (`jointsOf(rig)` → Motor6D list; `jointWorldCFrame(m)` = `Part0.CFrame * C0`; `rotationCFrame(rx,ry,rz)`; `applyRotation(current, rot, relative)`) + methods (`readSkeleton`, `drawSkeleton`/`clearSkeleton`, `poseJoint`, `resetPose`). |
| `src/RigWorkbenchSpec.luau` | in-Studio self-test for the pure helpers (mirrors `CameraRigSpec`). |
| `src/RigTemplates.luau` | the blocky-humanoid spawn template (part sizes/offsets + joint definitions, correct-by-construction). |
| `src/Tools/Rig.luau` | the 5 tool descriptors. |
| wiring | `init.server` deps (`rigWorkbench = RigWorkbench.new()`), `AgentLoop` (thread into `toolContext`), `Tools/init` register, `SystemPrompt` ("Rigs & posing" section). Rig tools are DataModel edits → relayed in client-view like `create_instance` (NOT in `LOCAL_TOOLS`); edit-mode is the primary path. |

### Skeleton visualization
Draw a **`HandleAdornment` overlay** — a `SphereHandleAdornment` at each joint's world position + a `LineHandleAdornment` (or thin cylinder) per bone (Part0→Part1) — in a tagged container, rendering on top with **zero geometry clutter** (cleaner than the camera rig's real parts). Refreshed when posed; toggled by `show_skeleton`; auto-drawn by `get_rig`. (Fallback if adornment rendering is finicky: Neon part markers like the camera rig used — confirmed in the plan/live test.)

### Tool surface (parent-only; agent-facing)
- **`spawn_rig(type?)`** — build a blocky humanoid placeholder rig (`type` default "r6"), anchored, named, returned by path.
- **`get_rig(rig?)`** — read the skeleton: list joints (name, Part0, Part1, current Transform) + draw the skeleton gizmos. Defaults to the selection.
- **`pose_joint(rig, joint, rotation, relative?)`** — set `Motor6D.Transform` for the named joint to a rotation (degrees x/y/z); relative (accumulate) by default or absolute; redraw gizmos.
- **`reset_pose(rig)`** — clear every joint's `Transform` to identity.
- **`show_skeleton(rig, on)`** — toggle the gizmo overlay.

## Data flow

`spawn_rig("r6")` → a blocky dummy in Workspace. → `get_rig("Workspace.Dummy")` → the joint list + skeleton gizmos drawn (you SEE the joints). → `pose_joint("Workspace.Dummy", "Right Shoulder", {x=0,y=0,z=-60})` → the arm rotates live (you SEE it pose). → `camera_focus` + `camera_orbit` → inspect the pose from any angle. → `reset_pose` → back to neutral. Same flow on a **user-inserted R15** rig (read/visualize/pose are rig-agnostic).

## Error handling

`pose_joint` on an unknown joint → a helpful error listing the rig's joint names. `get_rig`/`pose_joint` with no rig + no selection → resolve-target error. A target with no Motor6Ds → "no joints found (is this a rig?)". `rigWorkbench` nil-guarded in `deps`/`toolContext` (edit / relay paths unchanged when absent). Gizmos are tagged + removed by `clearSkeleton`/`show_skeleton off` (transient, plugin-created).

## Testing

- **`RigWorkbenchSpec`** (pure): `rotationCFrame`/`applyRotation` (relative vs absolute; degrees→CFrame), `jointsOf` filtering (only Motor6Ds), joint-name lookup. Pattern = `CameraRigSpec`.
- **Static (here):** `selene` 0/0, `stylua --check`, `rojo build`.
- **Live (drive Studio via computer-use):** `spawn_rig r6` → a dummy appears; `get_rig` → skeleton gizmos at the joints; `pose_joint` an arm/leg → it visibly rotates; `camera_focus`+`orbit` → inspect; `reset_pose` → neutral; then repeat **read/visualize/pose on a real R15** dummy inserted via Studio's Rig Builder. (Studio restart needed to load the build — user does it; I drive the test.)

## Risks & mitigations

- **Spawn joint correctness:** sidestepped — we build the placeholder with C0/C1 computed from chosen part positions (correct by construction), not Roblox's exact matrices; real rigs use operate-on-existing.
- **Adornment rendering quirks:** Neon-part fallback (proven by the camera rig) if `HandleAdornment` is finicky; confirmed live.
- **Posing channel confusion:** `.Transform` (animation) not `C0` (setup) — documented in the tool + SystemPrompt so the agent poses, not re-rigs.
- **Undo/ChangeHistory:** posing/spawn are DataModel edits; wrap in a ChangeHistory recording like the other build tools so they're undoable (the Modern Rig Editor has undo too).

## Next (rig-editor slices, then the rest of full-animation)

B. IK grab-and-place (IKControl chains) — the Modern Rig Editor's #1 gap. C. Blender-style human cursor-drag posing (PluginMouse + handles; agent IK target + user drag). D. keyframe/animation engine (pose→keyframe→play as an edit-mode filmstrip; compose with the camera rig = `capture_animation` revived). E. the Evaluate tool (grade a built/animated rig against the locomotion rubric). Each its own spec→plan→build.
