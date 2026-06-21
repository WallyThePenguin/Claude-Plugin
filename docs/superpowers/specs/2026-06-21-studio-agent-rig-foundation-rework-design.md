# Studio Agent — Rig Foundation Rework (design)

**Date:** 2026-06-21
**Status:** design approved in brainstorm; no code yet.
**Serves:** the Asset Creator rig/animation work — replaces the rig-editor's foundation (slices A+B) with a
**real native R15 rig** + the **correct edit-mode posing mechanism**, based on live findings proven this
session through the dev bridge. Directly answers the user's two calls: "this [placeholder] rig is shit" and
"you moved the whole object instead of the arm."
**Builds on:** slice A (`src/RigWorkbench.luau`, `src/RigTemplates.luau`), slice B
(`src/InverseKinematics.luau`, `src/IkChains.luau`), and the **dev bridge** (`src/DevBridge.luau` +
`scripts/studio-agent.ps1`), which made every fact below verifiable from the shell.
**Reads on:** the native rig+animation research
([`2026-06-20-native-rig-animation-research.md`](2026-06-20-native-rig-animation-research.md) §1, §4 — this
rework **resolves its LIVE-TEST #1** and corrects its §4.1 assumption). HANDOFF.md top blocks (dev bridge +
slice B).
**Memories:** `studio-agent-asset-creator-vision`, `studio-agent-training-vision`.

## Why (the live findings that force this)

Slice A spawned a **blocky programmatic placeholder** — a poor rig to animate. Slices A+B posed by writing
`Motor6D.Transform`, on the assumption (research §4.1) that it "applies live in edit." **Live testing via the
dev bridge proved that wrong** and surfaced the real mechanism:

1. **`Players:CreateHumanoidModelFromDescriptionAsync(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)`
   works at PluginSecurity in EDIT** (resolves research LIVE-TEST #1). Returns a real R15 rig — 15 MeshParts,
   Humanoid, Animate script, all 15 `*RigAttachment` **pairs**, but **zero Motor6Ds**. Default description =
   the R15 **block** body (blocky but standard — the Rig Builder's Block Rig).
2. **`Humanoid:BuildRigFromAttachments()` does NOT build the joints** (returns 0 — research's refutation
   confirmed). The 15 Motor6Ds must be built manually from the RigAttachment pairs.
3. **`Motor6D.Transform` alone does NOT move parts in static edit** (confirmed on placeholder AND native
   rig). The **correct** mechanism is: write `Transform`, then **`Animator:StepAnimations(0)`** (get-or-create
   the Humanoid's Animator). That moves a joint *relative* to the body — head/torso/other limbs stay put, and
   downstream parts follow their parent joint (verified: shoulder-rotation swings the whole arm; elbow-rotation
   bends only the forearm+hand). This is the Animation Editor's method (research §4.2).
4. **Setting part CFrames directly (the committed `3a10eab` "fix") rigidly drags the whole Motor6D assembly**
   — the anchored root jumped, the head dropped. It is **wrong** and must be reverted.
5. The native rig spawns at the **origin, half-buried in the baseplate** — it must be placed on the floor.

## Decisions (settled in brainstorm)

- **`spawn_rig` produces native R15 only:** `'block'` (default — `CreateHumanoidModelFromDescription` + built
  joints) or `'avatar'` (mesh via `CreateHumanoidModelFromUserIdAsync(userId)`). **Drop** the blocky
  placeholder, `RigTemplates`, and R6 spawn.
- **Color the `'block'` rig's parts distinctly by default** (flat palette, textures cleared) so poses are
  unambiguous in captures. `'avatar'` keeps its realistic appearance.
- **Posing = `Transform` + `Animator:StepAnimations`**, via a shared `RigWorkbench.applyPose(rig)` used by
  `ik_reach`/`pose_joint`/`reset_pose`.

## Components

| File | Change |
|---|---|
| `src/NativeRig.luau` | **NEW** — native spawn. `spawnBlock()`, `spawnAvatar(userId)` (default `userId = 1`). Shared helpers: `buildJoints(model)` (15 Motor6Ds from the R15 `*RigAttachment` map), `placeOnBaseplate(model)` (`PivotTo` so the lowest part sits ~0.5 above y=0), `anchorRoot(model)` (`HumanoidRootPart.Anchored = true`), `colorParts(model)` (clear `TextureID` + any `SurfaceAppearance`, flat distinct palette, `Material = SmoothPlastic`). Spawn fns YIELD (web-backed), like `capture`. |
| `src/RigWorkbench.luau` | Add **`applyPose(rig)`** (get-or-create Humanoid/AnimationController `Animator`, `pcall StepAnimations(0)`). `poseJoint`/`resetPose` call it after writing `Transform`. **Delete** `buildPlaceholder`/`loadNativeRig` + the `RigTemplates` require; `spawn(type, userId?)` delegates to `NativeRig`. |
| `src/InverseKinematics.luau` | **Revert** the direct part-CFrame loop (`3a10eab`); after writing `Transform` to the chain, call `RigWorkbench.applyPose(rig)`. |
| `src/RigTemplates.luau` | **Delete**. |
| `src/Tools/Rig.luau` | `spawn_rig` descriptor → `type` (`'block'` default / `'avatar'`) + `userId` (avatar). Updated description (native rig, no placeholder). |
| `src/RigWorkbenchSpec.luau` | Unchanged — its cases are pure pose-math (`rotationCFrame`/`applyRotation`); deleting `RigTemplates` doesn't touch it. |
| `src/InverseKinematicsSpec.luau` | Its DataModel cases (`resolveChain`/`reach`) call `RigWorkbench.spawn`, which is **now web-backed (yields)** — too heavy for an at-load self-test. **Move those two cases to the bridge dogfood** (spawn a native rig once, resolve + reach, assert the real hand position after `applyPose`). Keep the pure-math cases in the spec. |

### The R15 joint map (`buildJoints`)
For each `{joint, parentPartName, childPartName}`, find the `joint.."RigAttachment"` on each part, create a
`Motor6D` with `Part0 = parent`, `Part1 = child`, `C0 = parentAttachment.CFrame`, `C1 = childAttachment.CFrame`,
parented to `Part0`. The 15 entries (canonical R15 hierarchy):
`Root`(HumanoidRootPart→LowerTorso), `Waist`(LowerTorso→UpperTorso), `Neck`(UpperTorso→Head);
`Right/LeftShoulder`(UpperTorso→Upper Arm), `…Elbow`(Upper→Lower Arm), `…Wrist`(Lower Arm→Hand);
`Right/LeftHip`(LowerTorso→Upper Leg), `…Knee`(Upper→Lower Leg), `…Ankle`(Lower Leg→Foot).

### The posing mechanism (`applyPose`)
```
RigWorkbench.applyPose(rig):
  controller = rig:FindFirstChildOfClass("Humanoid") or rig:FindFirstChildOfClass("AnimationController")
  if controller == nil then return end            -- no Animator possible; Transform is still set
  animator = controller:FindFirstChildOfClass("Animator") or Instance.new("Animator", controller)
  pcall(function() animator:StepAnimations(0) end)
```
Every pose path becomes: **write `Motor6D.Transform` → `applyPose(rig)`**. `StepAnimations` re-solves the rig
from its current `Transform` values; the root stays fixed (anchored) and children follow their parents.

## Data flow

`spawn_rig {type="block"}` → native R15, 15 joints built, placed on the baseplate, parts distinctly colored,
root anchored → `get_rig` (gizmos; parts move via `applyPose`, so `Part1.Position` reflects the pose) →
`ik_reach`/`pose_joint` → `applyPose` makes it visible (body still, joints move) → `capture` reads cleanly.
`spawn_rig {type="avatar", userId=N}` → real mesh character, same joint-build/anchor/place, no recolor.

## Error handling

- `CreateHumanoid…Async` fails (no web / bad userId / yield blocked) → `spawn_rig` returns a clear string
  error (no silent fallback — the placeholder is gone). The error names the likely cause (HTTP/web access).
- `buildJoints` skips any joint whose parts or attachments are missing and reports the count built vs expected.
- A rig with no Humanoid/AnimationController → `applyPose` no-ops (the `Transform` is still written; note it in
  the tool result so the agent knows the pose won't be visible until a controller exists).
- `placeOnBaseplate` on a model with no parts → no-op; spawn still returns the model.

## Testing

- **Pure in-Studio spec cases:** the joint map is well-formed (15 unique joints, parent/child names valid R15);
  the palette has ≥15 distinct colors; the pose-math helpers (unchanged). `applyPose`/spawn are DataModel+web
  (yield) — not pure-unit-testable.
- **Live-verified via the dev bridge** (the now-fast path, and where every fact above was proven): `spawn_rig
  block` → `get_rig` → `ik_reach`/`pose_joint` → `capture`, **looked at** to confirm the body stays and only the
  posed chain moves. (The lesson from this session: a clear capture is the verification — coordinates alone are
  not.)
- Static gate: `selene` 0/0, `stylua`, `rojo build`.

## Composition with slice D

`applyPose` (Animator + `StepAnimations`) is exactly slice D's animation-playback primitive — `StepAnimations`
advances any *playing* AnimationTrack and applies it. This rework front-runs that machinery; slice D reuses
`applyPose`/the Animator (playing a registered `KeyframeSequence` instead of stepping a static pose).

## Scope / non-goals

- **Dropped:** R6 spawn, the programmatic placeholder, `RigTemplates`.
- **Unchanged:** `get_rig`/`pose_joint`/`reset_pose`/`ik_reach` stay **rig-agnostic** (still work on any Motor6D
  rig the user inserts, including R6 or a Rig-Builder rig). `IkChains` keeps its R6 presets (cheap; supports
  user-inserted R6).
- **Out (later):** wrist/hand-orientation control in IK (current IK is 2-bone, **position-only** — the wrist is
  free, so the hand follows the forearm); a non-default avatar-description builder; animation/keyframing
  (slice D); the Evaluate tool (slice E).
