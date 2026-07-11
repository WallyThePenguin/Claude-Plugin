# The Pilot Doctrine — Claude conducts specialists; it does not hand-craft (user directive 2026-07-11)

## The thesis (user, verbatim intent)

Claude is a CODING agent with visual verification — not a Blender agent, not an engine agent.
Hand-crafting content (keypose-by-keypose animation, vertex-by-vertex meshes) is slow, expensive,
and quality-capped. The product direction: **a complex pipeline that Claude PILOTS** — wiring,
invoking, and verifying specialist generators — "utilizes all its connections and MCPs and tools
to basically make them, not have Claude do all the work itself."

## Why tonight's evidence supports it (measured)

- Hand-authoring: the snake-sword clip needed batch-pose tooling, verify-after-apply, track
  purges, and an oracle to stay honest — ~1 call/keypose AFTER the 18x batching fix, and the
  quality ceiling is hand-set Euler angles. The 2026-07-11 factory transcript measured 65% of
  all calls spent hand-posing before batching landed.
- Piloting: Pixal3D/TRELLIS.2 grew meshes Claude could never model (87s-40min/asset, local);
  Blender rigged them deterministically (headless script, zero interactive calls); Claude's
  irreplaceable contributions were the SEAMS (meshio skins, runtime-skinning gate G3, direction
  normalization) and the VERIFICATION (oracle checks, captures, the collapse catch).

## The role split

| Role | Owner | Examples |
|---|---|---|
| Generate content | Specialist models/tools | Gemini (images), Pixal3D (shape), TRELLIS.2 (texture), Blender (rig/retarget/cleanup), animation LIBRARIES (UAL2 CC0, mocap sets), future text-to-motion (MDM/MoMask class) |
| Wire + drive | Sidecar (deterministic code) | trellis.py, pixal3d.py, blenderbridge, meshio, ComfyUI /prompt |
| Pilot | Claude | choose tools/params per asset, sequence stages, diagnose failures, fix seams |
| Verify | Claude + the Oracle | oracle checks with magnitudes, capture filmstrips, reference comparison — the anti-Goodhart layer stays OURS |

MCP nuance (measured tonight): interactive MCPs (blender-mcp) are the WRONG shape for pipeline
stages — deterministic headless scripts beat them for batch legs. MCPs/connections earn their
place at INTERACTIVE surfaces, not inside the conveyor.

## The ANIMATION leg (the missing specialist — replaces hand-keyposing)

Sources on disk NOW: `~/Downloads/Universal Animation Library 2[Standard]` (Quaternius, CC0):
`UAL2_Standard.glb` = one GLB embedding the full named clip set (+ `_RM` root-motion variant,
FBX, .blend). `workspace.UAL2_Standard` rig fixture already imported (locomotion pilot;
DO NOT TOUCH per fixtures rule). Later sources: curated mocap (CMU/Bandai), text-to-motion.

Pipeline: **library clip -> Blender headless retarget -> glTF animation -> meshio v3 ->
KeyframeSequence -> oracle + filmstrip**.

1. meshio v3: parse glTF ANIMATIONS (clip names; per-joint TRS keyframe channels, sampled).
   Pure-stdlib, same pattern as tonight's skin extraction (v2).
2. Blender retarget leg (`blender_scripts/retarget_clip.py`): source UAL2 armature -> target
   skeleton (R15 proportions or a generated rig) via per-bone copy-rotation constraints +
   bake + glTF export. Deterministic bone-name MAP (UAL2 naming -> R15 Motor6D child names)
   lives in a versioned spec JSON, like the rig specs.
3. Luau: KeyframeSequence builder from sampled channels (the AnimationClip machinery already
   owns Pose trees; a Bone.Transform channel is the skinned-rig follow-up).
4. Verification unchanged: weapon_channel_of / clip_arc_of / clip_self_intersect + filmstrips —
   the oracle doesn't care who authored the clip. Claude fixes by ADJUSTING PARAMETERS
   (clip choice, retarget map, playback rate), not by re-posing joints.

First slice: list UAL2 clip names via meshio v3 -> pick one locomotion + one attack ->
retarget to the AgentRig -> land as AnimSaves clips -> suite + filmstrip. Hand-keyposing
remains ONLY for fixups the library lacks.

## What this changes for the factory

BUILD phases become pipeline invocations (POST /pipeline/asset style) instead of artisanal
tool spam; budgets shrink; the honest-FAIL/RETRO/MECHANIC loop is unchanged — it graded
artifacts, not authorship. The playbooks' "oracle measures sweep, not smoothness" rule ages
into "the oracle measures the pipeline's output; Claude tunes the pipeline."
