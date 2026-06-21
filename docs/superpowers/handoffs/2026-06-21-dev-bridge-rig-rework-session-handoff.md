# Studio Agent — Dev Bridge + Rig Rework session handoff (2026-06-21)

**Read this, then finish the ONE pending step: dogfood the rig rework via the dev bridge (Task 7 below).**
The whole session's work is committed + clean on `master`; Studio was just restarted with the rework build,
and the dev bridge + sidecar + tunnel are RUNNING.

## 0. THE BIG NEW THING: the dev bridge (use it — no more computer-use)

Claude Code now drives the in-Studio plugin **from the shell**, no computer-use, no manual typing. This is
how you do everything below.

```
powershell -File scripts/studio-agent.ps1 luau '<luau code>'        # run arbitrary Luau in Studio (PluginSecurity), get returns+output
powershell -File scripts/studio-agent.ps1 tool <name> '<json>'      # call a plugin tool exactly (e.g. spawn_rig, ik_reach, get_rig, capture)
powershell -File scripts/studio-agent.ps1 prompt '<text>'           # drive the in-Studio Claude agent end-to-end
powershell -File scripts/studio-agent.ps1 logs                      # read the plugin's Output
powershell -File scripts/studio-agent.ps1 capture [out.png]         # save the newest viewport PNG -> then Read it
```
- It works by the plugin polling the localhost **sidecar** (`sidecar/server.py`, port 8389) which I curl.
- **Spec/design:** `docs/superpowers/specs/2026-06-21-studio-agent-dev-bridge-design.md`, plan
  `docs/superpowers/plans/2026-06-21-dev-bridge.md`. Built + dogfooded this session.
- **The point (user's insight):** the bridge carries TOOL/LUAU RPC so CLAUDE CODE is the brain — the in-Studio
  Claude agent is the PRODUCT (for human Studio users), not a dependency for the dev loop.
- **Environment NOW:** sidecar running (`python server.py` started via PowerShell `Start-Process`, NOT the
  bundled exe — the exe is old code; if the sidecar dies, restart it the same way, kill any stray duplicates
  on 8389 first). Tunnel up (8318). Bridge active in Studio (confirmed: `logs` shows "dev bridge active").
- **Gotchas:** PowerShell 5.1 reads `.ps1` as ANSI → keep the CLI **ASCII-only**. The Bash tool's `python`
  fails in detached `run_in_background` (exit 127) — start the sidecar via PowerShell. A plugin CODE change
  still needs `.\build.ps1` + a **USER Studio restart** (the bridge can't hot-reload itself); the launcher's
  stale-path gotcha means the USER restarts (or click Studio's blue "Restart to update").

## 1. THE PENDING TASK — finish the rig-rework dogfood (Task 7 of the rework plan)

The rig foundation rework is implemented + static-verified + installed; Studio is restarted; `spawn_rig`
already works (`tool spawn_rig {"type":"block"}` → "spawned native R15 block rig at Workspace.AgentRig").
**Finish the live verification, and LOOK at the capture (a clear image is the verification — coordinates are
NOT; the user rightly hammered this):**
```
powershell -File scripts/studio-agent.ps1 tool get_rig '{"rig":"Workspace.AgentRig"}'      # expect 15 joints
# read the right shoulder, pick a reachable target near it, then:
powershell -File scripts/studio-agent.ps1 tool ik_reach '{"rig":"Workspace.AgentRig","chain":"RightArm","target":{"x":..,"y":..,"z":..}}'
powershell -File scripts/studio-agent.ps1 luau 'local c=workspace.AgentRig:GetPivot().Position local cam=workspace.CurrentCamera cam.CameraType=Enum.CameraType.Scriptable cam.FieldOfView=40 cam.CFrame=CFrame.lookAt(c+Vector3.new(5,1,7),c) return "cam"'
powershell -File scripts/studio-agent.ps1 tool capture '{}'
powershell -File scripts/studio-agent.ps1 capture C:/Users/manso/AppData/Local/Temp/verify.png   # then Read it
```
Confirm: a colored R15 rig standing on the baseplate, **only the right arm posed, body unmoved**. Restore the
camera (`luau 'workspace.CurrentCamera.CameraType=Enum.CameraType.Custom'`). Then do Task 7 Step 4 of the plan:
add a dated HANDOFF.md block (rework shipped + bridge-verified) and commit. **Don't delete the user's `Rig`
model** (their own Rig-Builder rig). Clean up `AgentRig`/`NativeR15Test` test rigs when done.

Plan: `docs/superpowers/plans/2026-06-21-rig-foundation-rework.md` (Tasks 1–6 ✅ committed; Task 7 = this).
Spec: `docs/superpowers/specs/2026-06-21-studio-agent-rig-foundation-rework-design.md`.

## 2. What the rework changed (committed)

- **`spawn_rig` → real native R15 only:** `type:"block"` (default — `Players:CreateHumanoidModelFromDescriptionAsync`
  + 15 Motor6Ds built from the `*RigAttachment` pairs, on the baseplate, root anchored, parts flat-colored so
  poses read in captures) or `type:"avatar"` (mesh from a `userId`, default 1). New `src/NativeRig.luau`
  (+ `NativeRigSpec`). The blocky placeholder + `RigTemplates` + R6 spawn are **deleted**.
- **Posing fixed:** `RigWorkbench.applyPose(rig)` = get-or-create the Humanoid/AnimationController Animator +
  `StepAnimations(0)`. `pose_joint`/`reset_pose`/`ik_reach` all write `Motor6D.Transform` then call `applyPose`.
  The old `ik_reach` "direct part-CFrame" fix (`3a10eab`) was REVERTED — it rigidly dragged the whole assembly.

## 3. KEY LIVE-LEARNED FACTS (don't re-derive — all bridge-verified this session)

1. **`CreateHumanoidModelFromDescriptionAsync(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)`
   works at PluginSecurity in EDIT** (resolves research LIVE-TEST #1). Real R15: 15 MeshParts + Humanoid +
   Animate + all 15 `*RigAttachment` **pairs**, but **0 Motor6Ds**. Default desc = the R15 **block** body.
2. **`Humanoid:BuildRigFromAttachments()` does NOT build joints** (returns 0). Build them from the attachment
   pairs (canonical R15 map in `NativeRig.JOINT_MAP`): Part0=parent, Part1=child, C0=parentAtt.CFrame,
   C1=childAtt.CFrame, Motor6D parented to Part0.
3. **`Motor6D.Transform` ALONE does not move parts in static edit.** The animation system applies it:
   `Animator:StepAnimations(0)` moves joints **relative to the body** (root + unposed limbs stay; children
   follow their parent). Verified: shoulder-rotation swings the whole arm; elbow-rotation bends only the
   forearm+hand. (This IS the Animation Editor's method — research §4.2.)
4. **Directly setting a part's CFrame rigidly drags the WHOLE Motor6D assembly** (even an anchored root jumps)
   — never do it. Use Transform + StepAnimations.
5. Native rig **spawns at the origin, buried in the baseplate** → `placeOnBaseplate` via `PivotTo`. Anchor the
   HumanoidRootPart so it stays pinned.
6. IK is **2-bone (shoulder+elbow), position-only** — the wrist is free, so the hand follows the forearm (no
   hand-orientation control yet; a later add).

## 4. Full session arc (all committed, `master`)

1. **Deep research** on native rigging/animation → `docs/superpowers/specs/2026-06-20-native-rig-animation-research.md`.
2. **Slice B (IK grab-and-place)** → spec `2026-06-21-studio-agent-ik-grab-and-place-design.md`, plan
   `2026-06-21-ik-grab-and-place.md`, implemented (8 tasks). IK math correct (residual 0.00); the edit-mode
   posing was wrong and is now fixed by the rework.
3. **Dev bridge** → built (8 tasks), dogfooded — the session's biggest win.
4. **Rig foundation rework** (this) → native R15 spawn + StepAnimations posing; Tasks 1–6 done, Task 7 pending.

## 5. Build / verify loop (you CANNOT run Luau locally)

`stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm` (selene must be 0/0).
`.\build.ps1` installs to the Plugins folder. **For DataModel/API behavior, use the DEV BRIDGE** (the new,
fast path) instead of guessing — and always Read the capture, don't trust coordinates alone.

## 6. NEXT after Task 7

Slice C (Blender-style drag posing — feeds `ik_reach`'s target), slice D (animation engine — reuses
`applyPose`/the Animator + a registered `KeyframeSequence` via `KeyframeSequenceProvider`; research §4), slice
E (Evaluate vs the Locomotion rubric). Optional: wrist/hand-orientation in IK; an `avatar`-mode default-userId
that's a clean R15.
