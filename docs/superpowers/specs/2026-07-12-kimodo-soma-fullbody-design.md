# Kimodo full-body animation via SOMA-77 (sword welded)

**Date:** 2026-07-12
**Status:** approved in chat (user picked SOMA-77; scope = full-body, sword welded, keep it simple)
**Depends on:** the working Kimodo install + `retarget.py` direction-FK + the grip fix (welded sword).

## Problem

The Kimodo clip landed on the rig but (1) the **hands and feet don't articulate** — they stay
rigid to the forearm/shin — and (2) the welded **sword clips through the body** on swings. The
user also asked whether to give the sword its own joint now, and whether to feed Kimodo the model
size / weapon geometry.

Root causes, from the code:
- The retarget chain (`KIMODO_SMPLX_CHAIN`) has **11 rows and omits the wrists and ankles**, so
  those joints never get a channel. The 22-joint `Kimodo-SMPLX-RP-v1` model has **no hand joints**
  past the wrist, so there is no source data to articulate the hand even if we added a row.
- Kimodo is text → generic SMPL-X human motion. It **cannot ingest a target rig or a weapon** — so
  "give Kimodo the weapon size" is not achievable at the generator; weapon-awareness must live at
  the QA/selection stage.

## Decisions

1. **Switch to `Kimodo-SOMA-RP-v1` (77 joints).** It has full finger + toe chains AND is the
   commercial/ship-legal license. One switch buys hand+wrist articulation and legal shipping.
2. **New SOMA-77 → R15 retarget chain** (`retarget.py`), 15 rows, same direction-matching FK:
   | R15 joint(s) | aimed along SOMA direction | rest-dir (tune live) |
   |---|---|---|
   | Root / Waist / Neck | Hips→Chest / Chest→Neck1 / Neck1→Head | (0,1,0) |
   | Shoulder / Elbow (L+R) | Arm→ForeArm / ForeArm→Hand | (0,-1,0) |
   | **Wrist (L+R) — NEW** | **Hand→HandMiddle1** | (0,-1,0) |
   | Hip / Knee (L+R) | Leg→Shin / Shin→Foot | (0,-1,0) |
   | **Ankle (L+R) — NEW** | **Foot→ToeBase** | (0,0,-1) |
   Chain defined by NAME against the SOMA77 bone order (name→index) so no magic-index errors; L/R
   mirror = swap Left/Right in the source names.
3. **Auto-detect** the skeleton by `posed_joints.shape[1]` (22 → old chain, 77 → SOMA). No new
   route param; old 22-joint clips keep working.
4. **Weapon clipping = QA/selection, not generation.** Reuse the Gemini video-review seam: render
   the retargeted clip on the rig WITH the sword, filmstrip → Gemini rejects clips where the blade
   crosses the torso. Plus prompt hints ("wide arc"). This is the honest home for "weapon context."
5. **`sidecar/kimodo.py`** managed-subprocess driver bakes the env-flag trio + the SOMA model so
   generation is one call.

## Non-goals (deferred, user's call)

- Sword as its own animatable joint — easy later (the grip is already a Motor6D; weapon-channel
  animation already exists). Welded is this sprint.
- Root translation / model-scale param — the direction-FK is proportion-independent, so size only
  matters for traveling locomotion (future) and clip extent (QA). Not needed now.
- Post-hoc collision-avoidance IK, and the in-Blender retarget pipeline (the `.blend` rig sets us
  up for both, later).

## Verification

TDD: synthetic 77-joint npz → assert the 15 channels emit incl. both wrists+ankles, and the wrist
channel aims the R15 hand onto the Hand→HandMiddle1 direction (catches index errors). Then the
real proof: generate a SOMA sword clip, land on the AgentRig, filmstrip, tune wrist/ankle signs by
eye, Gemini video-QA for clipping.

## Risk

The `.blend` rig is NOT consumed by Kimodo (common misconception) — it's the authoritative R15
skeleton for the retarget spec and the future Blender-cleanup rig. Wrist/ankle rest-axis signs are
the one thing that needs live tuning (per the repo's own "axis tuned live" history).
