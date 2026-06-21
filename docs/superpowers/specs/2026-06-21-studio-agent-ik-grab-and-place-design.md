# Studio Agent — IK Grab-and-Place (design, slice B of the rig editor)

**Date:** 2026-06-21
**Status:** design approved in brainstorm; no code yet.
**Serves:** Asset Creator sub-project #2 ("full animation application"), **slice B**. Adds inverse
kinematics so the agent says *where* a limb's end goes and the solver poses the chain to reach it — the
**Modern Rig Editor plugin's #1 gap** (it has no IK at all; ref devforum 260728).
**Builds on:** slice A (`src/RigWorkbench.luau` — `jointsOf`/`findJoint`/`drawSkeleton`/`poseJoint`, posing
via `Motor6D.Transform` live in edit) + `src/RigTemplates.luau` (R6/R15 joint names) + the spherical camera
rig (`src/CameraRig.luau`, to inspect poses).
**Reads on:** the native rig+animation research
([`2026-06-20-native-rig-animation-research.md`](2026-06-20-native-rig-animation-research.md)) — §6 KILLED
`IKControl` for edit-mode use (per-frame runtime solver, no static `Solve()`), which is **why slice B builds
its own solver** writing `Motor6D.Transform`; §4.4 the Animator-overrides-Transform carry-forward.
**Memories:** `studio-agent-asset-creator-vision`, `studio-agent-training-vision`.

## Purpose

Slice A reads + poses **one joint at a time** (`pose_joint` rotates a joint by degrees). That's forward
kinematics — to put a hand on a doorknob the agent must hand-solve every joint angle up the arm. Slice B adds
**inverse** kinematics: name a chain and a target point/part, and the solver computes + writes the joint
rotations (`Motor6D.Transform`) down the chain so the end-effector reaches the target — **live in edit, on any
Motor6D rig**. This is "grab-and-place" posing for the agent (and, in slice C, for a user dragging a handle
that feeds the same solver).

## The bar (Modern Rig Editor) + how we beat it

The Modern Rig Editor has **no IK whatsoever** — it's joint-center setup + manual joint rotation only. Slice B
gives **AI-driven grab-and-place** with natural 2-bone limb bends + pole control on any Motor6D rig: the
editor's single biggest gap, closed and exceeded on the AI axis (no plugin lets you say "reach the right hand
to that point" in language).

## Why our own solver (not `IKControl`)

The research (§6) verified `IKControl` is a **continuous per-frame runtime solver** with **no static
`Solve()`** path; every claim that it works for static grab-and-place *in pure edit* or is reliably
driveable programmatically was **killed in verification**. `AnimationConstraint` was named as an alternative
but not characterized. So slice B implements IK itself and writes the **`Motor6D.Transform`** channel — the
one we already pose live in edit (slice A, verified). This sidesteps `IKControl`'s edit/runtime uncertainty
and the Animator-override hazard, fits the "AI sets the target → solver poses the joints" model, and reuses
slice A's exact posing primitive.

## Pose channel: `Motor6D.Transform` (settled, inherited from slice A)

A joint's **rest world pivot** is `Part0.CFrame * C0` (slice A's gizmo math). The Motor6D drives
`Part1.CFrame = Part0.CFrame * C0 * Transform * C1:Inverse()`. IK computes a desired world orientation per
bone and writes it as that joint's local **`.Transform`** — identical channel to `pose_joint`, in one
`ChangeHistoryService` recording (undoable). We do **not** touch `C0`/`C1` (joint centers = rig setup).

## Scope

- **In:** `InverseKinematics` (pure `solve2Bone` + `solveCCD` + rest→Transform conversion + a `reach` method
  that reads the rig, solves, writes `.Transform` down the chain) + `IkChains` (R6/R15 preset chain table) +
  `Tools/Ik.luau` (`ik_reach`) + a pure-helper spec + wiring. **Position reach** and **pole-vector control**.
  Targets = a world point **or** a part path. Presets **and** explicit effector+chainRoot (custom rigs).
- **Out (deferred, explicit non-goals):** look-at IK (head/torso facing — folds into slice D's additive
  layer or a later add); **anatomical joint limits** (per-joint clamp tables); full-body / multi-effector
  IK; foot-planting / ground-snap; the user cursor-drag (**slice C**, which will feed `ik_reach`'s target
  from a dragged handle); editing joint centers (`C0`/`C1`).

## Components (mirrors slice A's pure-module + spec + tool-descriptor pattern)

| File | Responsibility |
|---|---|
| `src/InverseKinematics.luau` | **PURE** solver math: `solve2Bone(rootPivot, len1, len2, target, pole)`, `solveCCD(jointPivots, target, iterations)`, and `transformFor(restJointWorld, c1, desiredPart1World)` (the rest→`.Transform` delta). Plus the stateful-but-thin `reach(rig, chainSpec, target, pole)` method: resolve the chain → solve → write each joint's `.Transform` in one recording → redraw gizmos. Stateless module like `RigWorkbench`. |
| `src/IkChains.luau` | Preset chain table per rig type: `RightArm/LeftArm/RightLeg/LeftLeg/Spine` → `{ jointNames, effectorPart, twoBone }`. R6 arms/legs are single-joint (CCD/aim); R15 limbs are 2-bone. Rig type detected via `Humanoid.RigType` then joint-name presence as fallback. `resolveChain(rig, spec)` returns `{ joints: {Motor6D}, effector: BasePart, twoBone: boolean }` from a preset **or** an explicit `effector`+`chainRoot` (walk Motor6D `Part0` links between them). |
| `src/InverseKinematicsSpec.luau` | In-Studio pure-helper self-test (mirrors `RigWorkbenchSpec`/`CameraRigSpec`). |
| `src/Tools/Ik.luau` | The `ik_reach` descriptor; `resolveRig` (path or selection) reused from the `Rig.luau` pattern. |
| wiring | `Tools/init` register; `SystemPrompt` "Rigs & posing" gains an IK paragraph; **`ik_reach` is a DataModel edit → relayed in client-view (NOT in `Relay.LOCAL_TOOLS`)**, like `pose_joint`. No new `init.server` dep — `Tools/Ik.luau` requires `InverseKinematics` directly (as `Tools/Rig.luau` requires `RigWorkbench`). |

## The solver (hybrid: analytic 2-bone + CCD)

**Dispatch:** the resolved chain is a 2-bone limb (`twoBone = true`) → analytic; otherwise (spine, R6
single-joint, custom/long chains) → CCD. Both produce per-joint `.Transform` writes.

### Analytic 2-bone (R15 arms/legs)
Root joint J1 (shoulder/hip), mid joint J2 (elbow/knee), effector part E (hand/foot). Rest bone lengths
`L1 = |J2pivot − J1pivot|`, `L2 = |Epoint − J2pivot|` (measured at rest). Given root pivot **S**, target **T**,
pole **P**:
1. `d = clamp(|T − S|, |L1−L2|+ε, L1+L2−ε)` — beyond reach ⇒ straighten (and report the clamp + residual).
2. Law of cosines for the shoulder and elbow interior angles; place the elbow in the plane spanned by
   `(T − S)` and the pole vector **P** (P fixes which way the elbow/knee points).
3. Desired world bone directions: upper bone aims `S → elbow`, lower bone aims `elbow → T`.
4. **Apply root-first** (so each joint sees its parent's updated frame): write J1's `.Transform` =
   `transformFor(restJ1World, J1.C1, desiredUpperWorld)`, which repositions the upper arm; **recompute** J2's
   `Part0.CFrame`; then write J2's `.Transform` for the lower bone. The rest→`.Transform` delta is
   `Transform = (Part0.CFrame * C0):Inverse() * desiredPart1World * C1` per joint.

**Pole vector:** default-derived per chain (elbows back/down, knees forward) so the agent can omit it; an
explicit `pole` world point overrides.

### CCD (spine, R6 single-joint, custom/long chains)
Iterate from the joint nearest the effector toward the chain root; each pass rotates that joint so the
effector swings toward the target, written as a `.Transform` delta; stop at a position tolerance or a max
(~10) iterations. Single-joint chains converge in one pass (degenerates to "aim the joint").

## Tool surface — `ik_reach`

`ik_reach { rig?, chain?, effector?, chainRoot?, target?, targetPart?, pole? }` — **destructive** (writes
`.Transform`), undoable.
- `rig` — instance path; omit to use the Studio selection (`resolveRig`).
- `chain` — a preset name (`RightArm`/`LeftArm`/`RightLeg`/`LeftLeg`/`Spine`), rig-type aware; **OR**
  `effector` + `chainRoot` — joint/part names for a custom chain.
- `target` — `{x,y,z}` world point; **OR** `targetPart` — a path to an instance (reach toward its position).
  Exactly one of `target`/`targetPart` is required.
- `pole` — optional `{x,y,z}` world point the elbow/knee points toward (2-bone only; default derived).
- Returns: a note (chain, resolved joints, target, "reached" vs "clamped at reach limit, residual N studs")
  + redraws the skeleton gizmos. The agent inspects with `camera_focus`/`camera_orbit`.

## Data flow

`spawn_rig("r15")` → `get_rig` (see joints + gizmos) → `ik_reach { chain="RightArm", target={x,y,z} }` → the
arm bends to reach, elbow oriented by the default pole (you SEE it) → `camera_focus`/`camera_orbit` to inspect
→ `ik_reach { chain="RightArm", targetPart="Workspace.Sword" }` to grab a part → `reset_pose` to clear. Same
flow on a user-inserted native R15 rig (the solver is rig-agnostic; presets resolve by joint name).

## Error handling (total, like slice A)

- No rig / nothing selected → "pass a rig path or select the rig."
- Unknown `chain` preset → list the available presets for the detected rig type.
- Explicit `effector`/`chainRoot` that don't connect via Motor6D links → name the gap.
- Neither `target` nor `targetPart` (or both) → state the requirement.
- `targetPart` path unresolved / not a BasePart → the path error.
- Target beyond reach → **not an error**: straighten the limb and report the clamp + residual distance.
- Degenerate chain (zero-length bone, missing Part0/Part1) → skip + note, never throw.

## Edit-mode / Animator interaction

IK writes `.Transform` in a `ChangeHistoryService` recording — identical to `pose_joint`, undoable. No
Animator exists in slice B, so the research §4.4 *Animator-overrides-Transform* conflict does not bite yet.
**Carry-forward (not v1 work):** when slice D adds an `Animator`/playback, IK posing must run with **no track
playing** (a stepping Animator overrides manual `.Transform`).

## Testing

- **`InverseKinematicsSpec` (in-Studio pure-helper):** (1) reachable 2-bone target — effector within
  tolerance; (2) over-extended target — limb straightens, clamp flag set; (3) pole vector flips the elbow to
  the correct side; (4) CCD converges on the 3-joint spine within tolerance; (5) explicit effector/chainRoot
  resolution returns the right joint list; (6) unknown preset errors; (7) `transformFor` round-trips (a known
  desired Part1 world → `.Transform` → reproduces that world).
- **Static:** `selene src` (0/0), `stylua --check src`, `rojo build`.
- **Live (user, fresh Baseplate, hecate tunnel):** `spawn_rig r15` → `ik_reach RightArm` to a point → confirm
  a natural elbow bend → `ik_reach` to a part → inspect via the camera rig → `reset_pose`. (Cannot run Luau
  here; lean on the spec + static checks + adversarial review, then the user live-tests.)

## Decisions settled in brainstorm (2026-06-21)

1. **Solver = hybrid** (analytic 2-bone for limbs + CCD for spine/custom) — best limb naturalness via the
   pole vector + generalizes to any Motor6D chain.
2. **API = presets + explicit fallback**, target a world point **or** a part.
3. **v1 scope = position reach + pole-vector control**; look-at IK and anatomical joint limits **deferred**.
4. Own solver, **not `IKControl`** (research §6).

## Non-goals (this slice)

Look-at IK; anatomical joint limits; full-body/multi-effector IK; foot-planting/ground-snap; cursor-drag
(slice C); joint-center (`C0`/`C1`) editing; animation/keyframing (slice D); exporting (research §5).
