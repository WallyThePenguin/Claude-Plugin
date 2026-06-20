# Studio Agent — Rig + Animation session handoff (2026-06-20)

**Read this, then start the next task: deep research on native rigging + animation in Luau (the exact
question is in §4 below — just run the `deep-research` skill with it).**

This handoff exists because the prior session's context window filled up. Everything below the
"current state" line is committed and clean; the work to continue is the rig-editor / animation slices
of the **Asset Creator** sub-project (#2, "full animation application"), aiming to **beat the Modern
Rig Editor plugin** (devforum 260728) and then exceed it via AI posing + IK + a keyframe engine +
capture→evaluate against the Locomotion rubric.

## 1. Current state (built, committed, clean)

Latest commit: **`730d076`** "fix: spawn_rig is programmatic; native rig load gated by InsertService
asset-trust". Working tree clean. `selene` 0/0, `stylua --check` clean, `rojo build` OK.

**SPHERICAL CAMERA-LOCK RIG** (sub-project #1) — DONE + LIVE-VERIFIED. `src/CameraRig.luau` +
`src/Tools/CameraRig.luau` + `src/CameraRigSpec.luau`. Tools: `camera_focus` / `camera_orbit`
(azimuth/elevation/zoom, relative or absolute) / `camera_release`. Invisible math controller moves the
real `Workspace.CurrentCamera`; optional debug gizmos (Config `cameraRigDebug`, default off) draw an
orbit sphere under `Workspace/__StudioAgentCameraRig`. This is how the agent inspects any pose.

**RIG WORKBENCH** (sub-project #2, slice A) — BUILT; R6 read/visualize/pose LIVE-VERIFIED. Five tools:
- `spawn_rig(type?, assetId?)` — builds a **programmatic blocky placeholder** rig (r6 default, or r15),
  correct-by-construction joints. `assetId` optionally loads a rig the USER OWNS via
  `InsertService:LoadAsset` (trusted assets only — see §2). It does NOT spawn the native Roblox rig.
- `get_rig(rig?)` — reads the Motor6D skeleton (joint names, Part0→Part1, posed?) + draws Neon gizmo
  markers (ball at each joint world pivot + a bone block). Rig-agnostic (works on any Motor6D rig).
- `pose_joint(rig?, joint, rotation{x,y,z}°, relative?)` — sets `Motor6D.Transform` (the animation
  channel; applies LIVE in edit). relative=accumulate (default) or absolute.
- `reset_pose(rig?)` — every joint's `.Transform` back to identity.
- `show_skeleton(rig?, on?)` — toggle the gizmo overlay.

Files: `src/RigWorkbench.luau` (stateless: jointsOf/findJoint/readSkeleton/drawSkeleton/clearSkeleton/
poseJoint/resetPose + pure rotationCFrame/applyRotation; loadNativeRig + buildPlaceholder + spawn),
`src/RigTemplates.luau` (r6 + r15 blocky templates, C0/C1 computed from chosen part positions),
`src/Tools/Rig.luau` (the 5 descriptors), `src/RigWorkbenchSpec.luau` (pure-helper tests). Wired into
`init.server` deps, `AgentLoop` toolContext, `Tools/init`, `SystemPrompt` ("Rigs & posing").
Spec: `docs/superpowers/specs/2026-06-20-studio-agent-rig-workbench-design.md`. Plan:
`docs/superpowers/plans/2026-06-20-rig-workbench.md`.

## 2. The hard constraints we VERIFIED LIVE (don't re-discover these)

- **`InsertService:LoadAsset` is asset-trust-gated.** Loading the official Roblox rig asset
  (16644810619) fails: **"Asset is not trusted for this place."** LoadAsset only loads assets OWNED by
  this place's creator (or otherwise trusted). So a plugin **cannot auto-spawn the native Roblox rig**
  from a hardcoded id. The hardcoded-id approach was tried and reverted in `730d076`.
- **`RigBuilderService` does NOT exist** (probed live). There is no programmatic "Rig Builder" service
  API. Studio's Avatar > Character > Rig Builder is built-in UI, not an exposed service.
- **`AnimationTrack.TimePosition` does not advance in EDIT mode** (verified earlier — this is why
  `capture_animation` was downgraded to a playtest follow-up). `Animator`/`AnimationTrack` playback
  does not evaluate in edit. Edit-mode animation MUST be driven by manually stepping `Motor6D.Transform`
  per frame.
- **Posing via `Motor6D.Transform` DOES apply live in edit** (verified — this is the foundation).
- The native art path that bypasses the trust gate: the USER generates a rig via Studio's
  **Avatar > Character > Rig Builder**, and the rig-agnostic `get_rig`/`pose_joint` operate on it.

## 3. The open questions the deep research must settle (why we're researching)

Before building slices B–E, we need facts (not guesses) on:
1. **Native-equivalent rig WITHOUT a trusted asset** — can we build a faithful R15/R6 from scratch with
   the exact part names/sizes + Motor6D C0/C1? Do the `HumanoidDescription` APIs
   (`Players:CreateHumanoidModelFromDescription`, `GetHumanoidDescriptionFromUserId`,
   `CreateHumanoidModelFromUserId`) work at PLUGIN security in EDIT mode? What does the built-in Rig
   Builder actually do under the hood? Can the user publish/own a rig so LoadAsset becomes trusted?
2. **Edit-mode playback** — confirm the strong hypothesis that the Animation Editor / Moon Animator
   play animations in edit by **manually stepping `Motor6D.Transform`** per frame from keyframe data.
3. **Programmatic save/export** — can `AssetService:CreateAssetAsync` publish a `KeyframeSequence` as an
   Animation asset, or is a manual upload dialog unavoidable? What can a plugin do without it?
   (`KeyframeSequenceProvider:RegisterKeyframeSequence`/`RegisterActiveKeyframeSequence` for local
   preview without uploading.)
4. **IK in edit** — `IKControl` (Type/EndEffector/ChainRoot/Pole/Target) + `AnimationConstraint` for
   grab-and-place posing without playtest.

## 4. NEXT TASK — run this deep research (copy/paste into the `deep-research` skill)

> How does native character RIGGING and ANIMATION work in Roblox Studio via Luau, specifically for
> building an in-Studio PLUGIN that spawns rigs and authors animations with an AI agent? Be concrete and
> code-level; cite Roblox creator docs (create.roblox.com / the creator-docs GitHub) and DevForum.
>
> Context/constraints already verified live: InsertService:LoadAsset of the official Roblox rig assets
> fails with "Asset is not trusted for this place"; there is NO RigBuilderService; AnimationTrack.
> TimePosition does not advance in EDIT mode. We need the correct native pipeline given these.
>
> Cover, with specifics:
> 1. RIG CREATION from a plugin in code — viable ways to get a native-equivalent R6/R15 rig WITHOUT a
>    trusted asset: building the skeleton from scratch (exact R15/R6 part names, sizes, and Motor6D
>    C0/C1 offsets); HumanoidDescription APIs (Players:CreateHumanoidModelFromDescription,
>    GetHumanoidDescriptionFromUserId, CreateHumanoidModelFromUserId) and whether they work at plugin
>    security in edit; what Studio's built-in Rig Builder does under the hood; publishing/owning a rig
>    asset so LoadAsset becomes trusted.
> 2. RIG STRUCTURE — the canonical R15 + R6 Motor6D skeletons (joint names: Root, Waist, Neck,
>    RightShoulder/Elbow/Wrist, RightHip/Knee/Ankle, etc.), how C0/C1 and Motor6D.Transform define and
>    pose joints, HumanoidRigType, and MeshPart-vs-block R15.
> 3. ANIMATION pipeline in Luau — KeyframeSequence, Keyframe, Pose (per-joint CFrame), Animation,
>    AnimationTrack, Animator:LoadAnimation; building a KeyframeSequence from joint poses
>    programmatically; KeyframeSequenceProvider:RegisterKeyframeSequence/RegisterActiveKeyframeSequence
>    for local preview without uploading; the newer curve-based animation / AnimationClip API.
> 4. EDIT-MODE posing + playback — confirm Motor6D.Transform posing applies live in edit; HOW the
>    Animation Editor / Moon Animator PLAY an animation in edit (manually stepping Motor6D.Transform per
>    frame from keyframe data?), and why AnimationTrack/Animator playback doesn't evaluate in edit.
> 5. SAVING/EXPORTING animations programmatically — publishing a KeyframeSequence as an Animation asset
>    (AssetService:CreateAssetAsync?), and what a plugin can vs cannot do without a manual upload dialog.
> 6. IK — IKControl (Type, EndEffector, ChainRoot, Pole, Target) and AnimationConstraint for
>    grab-and-place posing in edit.
> 7. How the built-in Animation Editor and Moon Animator 2 actually implement rig selection, posing,
>    keyframing, edit-mode playback, and export — which APIs.
>
> Conclude with a recommended ARCHITECTURE for an in-Studio AI rig+animation plugin that spawns a rig,
> poses joints, and builds + previews + exports an animation, all in EDIT mode — flagging which steps
> are impossible/manual and the best workaround for each.

After it returns: write the findings to `docs/superpowers/specs/2026-06-20-native-rig-animation-research.md`,
then proceed to slices B–E below with facts in hand. (Note: a deep-research workflow for exactly this
was started in the prior session and **stopped** before completing — nothing was saved; re-run it.)

## 5. Deferred slices (the rig-editor roadmap, after the research)

- **B. IK grab-and-place** (`IKControl` chains) — the Modern Rig Editor's #1 gap.
- **C. Blender-style human cursor-drag posing** (PluginMouse + handles; agent IK target + user drag) —
  banked in memory `studio-agent-asset-creator-vision`.
- **D. keyframe / animation engine** — pose→keyframe→play as an EDIT-MODE filmstrip (manually step
  `Motor6D.Transform` per frame); compose with the camera rig to revive `capture_animation`. Then
  export (per §3.3).
- **E. Evaluate tool** — grade a built/animated rig against the **Locomotion rubric** (already shipped
  via RubricStore; `use_rubric locomotion` returns 16 criteria). Closes the capture→evaluate→refine loop.

## 6. Testing reminders (don't get stuck here)

- **A running Studio does NOT hot-reload a local plugin** + `open_application`/the computer-use launcher
  hits a stale Studio path → **the USER must restart Studio** to load a new build; the assistant then
  drives the live test via computer-use over the hecate tunnel. Use a **fresh Baseplate**, not saved
  places (memory `test-sessions-use-new-experience`).
- You cannot run Luau here — lean on `selene`/`stylua`/`rojo build` + adversarial-review workflows for
  logic, then the user-restarts-Studio live test for anything DataModel/API.
- Known nit to fix when next live-testing: a `camera_focus` path-resolution hiccup (`game.Workspace`
  vs `Workspace`); the spawned placeholder sinks into the baseplate when posed (native rigs MoveTo
  (0,0,0); placeholder positions need tuning).
