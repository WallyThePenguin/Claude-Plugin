# Animation importing — bring an existing animation into the editable workbench (design)

**Date:** 2026-06-22
**Status:** approved (v1 scope)

## Problem / goal
Today the agent can only AUTHOR animations keypose-by-keypose (`add_keyframe` → `AnimSaves/<clip>`). It
cannot bring in an animation it did NOT author — a published animation, an existing in-place
`KeyframeSequence`, or one a designer imported from FBX. **Goal:** a tool that imports an existing
animation into an editable clip at `rig/AnimSaves/<clip>` — the same slot agent-authored clips live in —
so `list_clip` / `capture_animation` / `evaluate` / refine / `export` / `learn` all work on it
immediately. This closes the loop on existing animations and feeds the training-corpus vision (import
real animations to study + grade against the rubrics).

## Feasibility (live-proven via the dev bridge, 2026-06-22)
`KeyframeSequenceProvider:GetKeyframeSequenceAsync("rbxassetid://507767714")` (the default R15 run) at
PluginSecurity in edit returned a real `KeyframeSequence` — **14 keyframes / 224 poses**. So importing by
id yields genuine editable keyframe data (not just playback). This is the Animation Editor's own import
path.

## Sources (v1)
One tool, **`import_animation(animation|source, rig?, clip?)`**:
- **By asset ID** — `rbxassetid://N` or a bare numeric `N` → `GetKeyframeSequenceAsync`. (Proven. Fails
  cleanly with a clear error if the asset is private/inaccessible.)
- **In-place** — a path to an existing `KeyframeSequence` instance (use it directly), or an `Animation`
  instance (resolve its `.AnimationId` → `GetKeyframeSequenceAsync`).
- **FBX/GLB (e.g. Quaternius)** — a plugin **cannot read an FBX file**; Studio's **3D Importer**
  (File ▸ Import 3D) is the only way to get one in, and it is a manual UI step. The v1 workflow:
  the USER runs the 3D Importer once (it drops an in-place rig + animation `KeyframeSequence`), then
  `import_animation` ingests that in-place result (the "in-place" source above). Documented in the tool
  description + the SystemPrompt "Animating" section. The plugin half is feasible; the file read is
  unavoidably manual.

## The retarget (the real work)
A source `KeyframeSequence`'s `Keyframe` holds a `Pose` tree where `Pose.Name` = the posed part's name
and `Pose.CFrame` = that joint's `Motor6D.Transform` (same semantics the agent's own clips use). To put
it on the TARGET rig, per source keyframe:
1. **Extract** a flat map `{ poseName → CFrame }` from the keyframe's `Pose` descendants.
2. **Rebuild** onto the target rig via the existing `AnimationClip.buildPoseTree(targetRig, map)` — it
   mirrors the target's Motor6D graph, pulling each target joint's CFrame from `map[jointName]` (identity
   when absent). This guarantees the output matches the TARGET rig's structure exactly.
3. **Assemble** a fresh `KeyframeSequence` under `targetRig/AnimSaves/<clip>` (preserve each source
   keyframe's `.Time`; copy the source `.Loop` and `.Priority`), via `ks:AddKeyframe` (required for
   length — the spike fact).

**v1 = joint-NAME-based retarget.** Clean for R15→R15 (the default-run pose names match the R15 rig
exactly; Studio's importer produces R15 names for R15-rigged FBX). Joints in the source with no
matching target joint are dropped; target joints with no source pose stay at rest. The tool **reports
joint-coverage** (matched / total target joints, plus the count of dropped source joints) so the agent
SEES how faithful the import is and can judge whether a retarget gap explains a bad capture.

**Out of scope for v1 (flagged v2):** cross-skeleton retargeting — differently-NAMED joints (a
name-map), T-pose↔A-pose orientation offsets, and proportion/scale compensation (true non-R15 FBX). v1
degrades gracefully + warns via the coverage report rather than silently producing garbage.

## Components (small, focused units)
- **`src/AnimationImport.luau`** (new) — source resolution + the retarget. PURE helper
  `coverage(sourceNames: { string }, targetNames: { string }) -> { matched: number, total: number, droppedSource: { string } }`
  (string-set logic, unit-testable). Impure orchestrator `importInto(sourceKS, targetRig, clipName) ->
  (text, ok)` (extract per-keyframe pose maps → `AnimationClip.buildPoseTree` → assemble + save) and
  `resolveSource(args) -> (KeyframeSequence?, errString?)` (asset id / KeyframeSequence path / Animation
  path). Reuses `AnimationClip.buildPoseTree` + the `AnimSaves` storage convention.
- **`src/Tools/Import.luau`** (new) — the `import_animation` tool descriptor (parent-only;
  **destructive=true** — it writes a clip; wrapped in a ChangeHistory recording like the other animation
  tools). Inputs: `animation` (asset id) OR `source` (instance path to a KeyframeSequence/Animation),
  `rig` (path or selection, like the other animation tools), `clip` (default derived from the source
  name or `"ImportedClip"`).
- **`src/AnimationImportSpec.luau`** (new) — pure spec for `coverage` (full match, partial match with
  dropped source joints, empty).
- **Wiring:** register in `Tools/init`; add `import_animation` to `RelaySpec` EXPECTED_RELAY (it is a
  DataModel write → relays by default, NOT in `Relay.LOCAL_TOOLS`); SystemPrompt "Animating" section
  gains an import paragraph (incl. the FBX-via-3D-Importer note).

## Data flow
`import_animation` → `resolveSource` (asset id → `GetKeyframeSequenceAsync`; KeyframeSequence path → use;
Animation path → `.AnimationId` → `GetKeyframeSequenceAsync`) → resolve target rig (path or selection) →
`importInto`: per source keyframe extract `{name→CFrame}` → `AnimationClip.buildPoseTree(targetRig, map)`
→ new Keyframe at the source time → `ks:AddKeyframe` → save under `AnimSaves/<clip>` → compute
`coverage` → return a summary (clip stats + matched/total joints + dropped source joints). Then
`list_clip` / `capture_animation` / `evaluate` / `export` operate on it as usual.

## Error handling
- `GetKeyframeSequenceAsync` failure (private/inaccessible asset, or a yield error) → a clear error
  naming the id and that the asset must be public or owned. (pcall-guarded; never throws.)
- Source resolves but has 0 keyframes → "the source animation has no keyframes."
- No target rig (no path + nothing selected, or the target has no Motor6D joints) → the same guidance the
  other animation tools give (`spawn_rig` or select a rig).
- 0 joints matched (totally different skeleton) → still writes the (empty-pose) clip but the coverage
  report flags `matched 0/N` so the agent knows the retarget failed and v2 cross-skeleton retarget is
  needed.

## Testing
- **Pure:** `AnimationImportSpec` — `coverage` over full-match / partial-match (some dropped source
  names) / empty inputs.
- **Static:** `selene` 0/0 + `stylua` + `rojo build` green; `RelaySpec` no-drift stays green (with
  `import_animation` added to EXPECTED_RELAY).
- **Live (bridge dogfood, after a USER restart):** spawn an R15 rig →
  `import_animation {animation:"rbxassetid://507767714"}` → `list_clip` (expect ~14 keyframes, coverage
  near-full on the R15 joints) → `capture_animation` → **LOOK** that it is the run cycle on the agent's
  rig (legs/arms swinging). Then optionally import an in-place KeyframeSequence path to confirm that
  source. **Verify by looking at the filmstrip, not coordinates.**

## Out of scope (YAGNI)
- Direct FBX/GLB file reading (impossible from a plugin — Studio's 3D Importer is the path).
- Cross-skeleton retarget: name-mapping, orientation (T/A-pose) offsets, proportion scaling (v2).
- Uploading/publishing the imported clip (the existing `export_animation` handoff covers publish).
- Trimming/blending/merging imported clips (the existing keyframe-edit tools already cover edits).
