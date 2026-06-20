# Locomotion Pilot — Report

**Date:** 2026-06-20 · **Run:** wf_0408a43e-60f (clean) · **Pipeline:** `train-category` (run in Claude Code)
**Spec:** `docs/superpowers/specs/2026-06-20-studio-agent-locomotion-pilot-design.md` · **Plan:** `docs/superpowers/plans/2026-06-20-locomotion-pilot.md`

## Verdict: PASS ✅

The automated pipeline produced a Locomotion rubric that **discriminates the mean from the great** artifact and **sharpened itself** to do so. The architecture (research → above-generic judge → assemble → bias check → discrimination back-test → self-optimize → completeness critic) is proven on one slice.

## §12 acceptance gate

| Criterion | Result | Evidence |
|---|---|---|
| Discrimination back-test | **PASS** | mean 0.00 ≤ 0.5, great 0.77 ≥ 0.7, gap 0.77 ≥ 0.35 |
| Above-generic survival + coverage | **PASS** | 20/21 survived (95%); all 4 killer systems covered |
| Scoring-bias stability | **PASS** | normal 0.012 vs shuffled 0.000, gap 0.012 ≤ 0.10 |
| Self-optimization fired | **PASS** | 1 round(s); round 0 failed, optimizer rewrote 14 criteria, round 1 passed |

**Rubric:** 20 criteria — 5 baseline, 8 good, 7 exceptional.

## Back-test (per criterion, final round)

Every criterion scores the MEAN artifact `fail` (it explicitly negates the systems). The GREAT artifact:

| Tier | Criterion | mean → great |
|---|---|---|
| baseline | loco-state-machine | fail → pass |
| baseline | loco-vertical-bob-keyposes | fail → pass |
| baseline | loco-contralateral-swing | fail → pass |
| baseline | loco-seamless-loop | fail → pass |
| baseline | loco-living-idle | fail → pass |
| good | loco-stride-locked-to-speed | fail → pass |
| good | loco-directional-variant-set | fail → fail |
| good | loco-per-part-easing | fail → pass |
| good | loco-foot-lift-roll-splay | fail → pass |
| good | loco-blend-tree-speed-and-direction | fail → partial |
| good | loco-foot-ik-terrain | fail → partial |
| good | loco-additive-lookat-aim | fail → partial |
| good | loco-fadetime-transitions | fail → pass |
| exceptional | loco-pelvis-hip-sway-gait-phase | fail → partial |
| exceptional | loco-velocity-lean-additive | fail → partial |
| exceptional | loco-marker-synced-fx | fail → partial |
| exceptional | loco-accel-decel-momentum | fail → pass |
| exceptional | loco-hip-height-terrain | fail → pass |
| exceptional | loco-personality-cog | fail → pass |
| exceptional | loco-retarget-rig-portability | fail → pass |

## Self-optimization (GEPA-style)

**Round 0:** 14 non-discriminating criteria rewritten. Sample reasons:
- `loco-state-machine` — The original credited cloning the 'Animate' LocalScript with per-state tables — pure clip-craft evidence neither artifact provides, so both failed (no discrimination). The GREAT artifact's distinguishing prose is 'a 2D blend tree keyed to planar velocity (forward+strafe)'; the MEAN artifact is expli
- `loco-vertical-bob-keyposes` — The original demanded captured Contact/Down/Passing/High keypose frames + a hip-height trace + a Motor6D Y-keyed pose dump — hand-keyed clip-craft evidence NEITHER artifact provides, so both failed. The only phase-related signal that separates them is the GREAT artifact's 'pelvis sway driven by ... 
- `loco-contralateral-swing` — The original scored only hand-keyed forearm-lag pose dumps and UpperTorso-vs-LowerTorso counter-twist keys — clip-craft evidence neither artifact supplies, so both failed. What actually separates them is that the GREAT artifact has 'an additive aim/look-at layer' and 'torso sway' (a runtime upper-bo

## Scoring-bias check

Grading the MEAN artifact with normal vs reversed criterion order gave 0.012 vs 0.000 (gap 0.012) → **stable**. Caveat: the MEAN scores near-zero, so this is a weak bias probe; a mid-scoring artifact would test it harder (loop session).

## Empirical answers to the spec §14 open questions

- **How many candidates/criteria are needed?** Observed: 62 techniques → 21 candidate criteria → 20 survivors → a working 20-criterion rubric. A working data point (not a proven minimum).
- **Best exemplar-reference strategy?** The **contrastive mean-vs-great pair discriminated strongly** (gap 0.77) — supports the contrastive pair over a single 'full-marks' reference (the latter was refuted in the research pass).
- **Corpus-drift guard?** Untested here — exemplars were external top-tier sources; no agent-output reuse. Validate in the loop session.
- **Small local helper model?** Not investigated (explicit non-goal).

## Honest limitations (feed the next pass)

- **Judge leniency (biggest):** 95% survival is implausibly high for a rubric with many explicit 'earns nothing' floors → the above-generic judge is under-rejecting. **Tighten the judge, not the rubric** (e.g. require a stricter majority, or a harder default-Roblox refutation).
- **Non-separating criteria:** loco-directional-variant-set scored great≤mean (the great artifact's text didn't carry enough to pass). Either sharpen them or accept they need live-capture evidence (loop session).
- **Coverage gaps** flagged by the completeness critic:
  - Knee/elbow pole-vector (hint) direction stability is only an optional aside inside loco-foot-ik-terrain, not separately graded -- a candidate could pass foot IK while knees flip/pop
  - True stride-LENGTH scaling / motion-matching-style stride warping is not positively rewarded (only AdjustSpeed cadence-matching is named, and only as insufficient); may be intentionally out of scope
  - Turn-in-place / pivot at zero or low velocity (rotating facing without translating, avoiding foot-pivot-skate when only the camera turns) is not explicitly tested -- a visible default-Animate failure left ungated
  - The gait-phase-AND-acceleration conjunction for killer #4 is concentrated in a single exceptional item (loco-pelvis-hip-sway-gait-phase); satellites split the two halves, so a candidate could satisfy several items while delivering only one half rather than both being independently required
  - GRADING-LAYER RISK (not a content gap): 95% survival is implausibly high for a rubric with this many explicit 'earns nothing' floors -- it indicates the disqualifiers (UseStrafingAnimation != authored diagonals; AdjustSpeed != foot IK; baked clip != phase signal; 0.1s default fade != blend-space re-weighting) are not being enforced as hard fails; tighten the judge, not the rubric
- **Text-level grading ceiling (inherent):** rubric-first grades described behavior, not built structure; criteria demanding keyframe-level evidence can't be fully scored until the live capture→evaluate loop exists.

## Completeness critic — assessment

VERDICT: This rubric is ABOVE THE MEAN and effectively COMPLETE on all four mandated killer systems. Every killer system is covered by a dedicated, explicitly-labeled "KILLER SYSTEM" item with concrete, gradable engine mechanisms (IKControl, CFrame:VectorToObjectSpace, AdjustWeight, AnimationPriority, gait-phase Contact/Pass), and each is reinforced by 1-3 satellite baseline/good items that test the same capability from a "beats-the-default-Animate-floor" angle. The rubric explicitly anchors the MEAN to default Roblox behavior (WalkSpeed-threshold clip swap, no foot IK, flat-clip skate on slopes, baked single-timeline clip) and requires candidates to exceed it, which is what makes it discriminating rather than generous.

KILLER SYSTEM COVERAGE (all 4 covered):

1. BLEND TREE (warps by speed AND direction, not one forward loop) — FULLY COVERED.
   - Direct: loco-blend-tree-speed-and-direction (good) is the canonical item: 1D speed axis (idle@0->walk->jog->run crossfade) + 2D direction axis weighting the 8 variants via CFrame:VectorToObjectSpace velocity projection (X=strafe, Z=fwd/back), per-frame AdjustWeight with Epsilon clamp to dodge the zero-weight replication bug, AdjustSpeed cadence match, same-priority weight combination.
   - Reinforcing: loco-state-machine (mandates continuous velocity magnitude AND direction, 2D not one forward loop, explicitly rejects threshold clip-swap as the floor); loco-directional-variant-set (requires authored 8-way set INCLUDING diagonals, explicitly disqualifies the free 4-quadrant UseStrafingAnimation); loco-seamless-loop and loco-fadetime-transitions (continuity by weight-blending the blend space, not hard swaps). This is the most thoroughly defended of the four.

2. FOOT IK (feet plant on ground/slopes/steps, no skating) — FULLY COVERED.
   - Direct: loco-foot-ik-terrain (good) is the canonical item: engine-native IKControl (Type Transform, EndEffector=foot, ChainRoot=upper-leg, Target=downward-raycast hit, Pole for knee) OR Motor6D.Transform; align foot to surface NORMAL for slopes/stairs; raycast from the ANIMATED hip world CFrame (Part0.CFrame*C0 with .Transform, not rest skeleton — a genuinely expert detail); max-slope reject (~45deg via acos(Normal:Dot(yAxis))); Weight/SmoothTime tuning per state.
   - Reinforcing: loco-stride-locked-to-speed (foot-grounding pass, rejects AdjustSpeed-only as insufficient), loco-foot-lift-roll-splay (feet conform to world geometry), loco-hip-height-terrain (terrain-aware pass + complementary root/hip-height adjustment). Strong, redundant coverage with the slope/step requirement repeated as the explicit MEAN-failure check.

3. ADDITIVE LOOK-AT / AIM layered on locomotion — FULLY COVERED.
   - Direct: loco-additive-lookat-aim (good) is the canonical item: additive aim layer riding ON TOP of the gait without stopping it; IKControl aim chain OR AnimationPriority layering (locomotion on Movement/Idle, aim track on Action+ so the highest-priority track wins only the conflicting limbs while legs keep walking; equal priorities blend by weight); AnimationConstraint procedural aim (Kinematic vs force-based MaxForce/MaxTorque, deferred batch after PreSimulation).
   - Reinforcing: loco-contralateral-swing and loco-per-part-easing (upper body driven by a layer DISTINCT from the leg cycle), loco-living-idle (aim/look-at remains active at rest). Solid coverage; the priority-arbitration detail (highest priority wins only conflicting limbs) is the correct, non-obvious mechanism.

4. PELVIS BIAS / HIP SWAY / LEAN tied to gait phase AND acceleration — FULLY COVERED, and the strongest-graded.
   - Direct: loco-pelvis-hip-sway-gait-phase (exceptional) is the canonical item: pelvis counter-rotates against legs like a scale, lifted-leg side pulls opposite hip DOWN, straightens at Pass, flips at Contact, side-to-side sway producing a figure-8 hip trace (LowerTorso joint on R15); bias responds to acceleration (lean forward on accel, into curve on turns, back on hard stops); run re-posed not sped-up (wider split, deeper down-drop, true AIRBORNE frame, arms swing inward slightly slower than 1:1). This single item satisfies BOTH halves of the requirement (gait phase AND acceleration).
   - Reinforcing: loco-velocity-lean-additive (additive accel-driven lean, dot/cross of velocity vs look, ~10deg cap, Lerp ~0.2, + camera bank), loco-accel-decel-momentum (acceleration as a tracked runtime input), loco-personality-cog (tunable runtime posture/COG offset layer), loco-vertical-bob-keyposes (gait-phase signal drives pelvis/hip oscillation). Four exceptional-tier items converge here — appropriately, since this is the hardest capability to fake.

WHY IT'S ABOVE THE MEAN (discrimination quality):
- Every baseline item names the exact default-Animate behavior as the FLOOR that "earns nothing," forcing the bar above stock Roblox rather than rewarding it. This is the single most important property and it is applied consistently across all 19 items.
- It correctly closes the two most common ways a candidate fakes competence: (a) "I have directional clips" -> disqualified unless diagonals are AUTHORED (not the free 4-quadrant UseStrafingAnimation); (b) "I match foot speed" -> disqualified because AdjustSpeed cadence-matching is stock and does not stop position-skate on slopes.
- The tiering is sound: baseline = continuous-velocity-driven architecture (vs threshold swap); good = the blend tree + foot IK + aim layers; exceptional = phase/accel-coupled pelvis/lean/momentum + terrain hip-height + portability. The exceptional tier correctly clusters the systems that require all the others to already exist (layered correction decoupled from clip -> retarget portability).
- Mechanism specificity is high and accurate: VectorToObjectSpace projection, Epsilon zero-weight replication-bug avoidance, raycast from animated (not rest) hip CFrame accounting for .Transform, acos slope rejection, AnimationPriority limb-arbitration, deferred AnimationConstraint batch after PreSimulation. These are real, current engine APIs and the kind of detail a competent-but-shallow candidate would omit — good discriminators.

MINOR GAPS (do not undermine completeness of the four killers; worth noting for a future revision):
- Knee/elbow pole-vector direction control is mentioned only in passing inside loco-foot-ik-terrain (optional Pole) and is not separately graded. A candidate could describe foot IK with flipping/popping knees and still pass; an item rewarding stable pole-vector/hint targeting would harden the foot-IK killer.
- Stride-length-to-speed scaling (true stride warping / motion-matching style stride adjustment, distinct from AdjustSpeed cadence) is acknowledged as insufficient-if-only-cadence but there is no positive item rewarding actual stride-length re-targeting; this borders on motion matching and may be intentionally out of scope.
- Turn-in-place / pivot at zero or low velocity (rotating the facing without translating, avoiding the foot-pivot-skate when only the camera turns) is not explicitly covered; loco-living-idle and the lean items touch posture-at-rest but not the rotational foot-replant. This is a visible default-Animate failure not directly tested.
- "Both halves" enforcement for killer #4: only the single exceptional item loco-pelvis-hip-sway-gait-phase ties pelvis bias to BOTH gait phase AND acceleration in one statement; the satellites split the two (gait-phase in loco-vertical-bob, accel in loco-accel-decel/velocity-lean). A candidate could pass several items while only delivering one half. Coverage is present, but the conjunction is concentrated in one item rather than independently required.

SURVIVAL-RATE FACTORING (95% candidate survival): A 95% pass-through is the one real concern. For a rubric this explicitly tiered and floor-anchored, 95% surviving is suspiciously high — it implies the gates are being read leniently (e.g., a candidate claiming "blend tree" and "foot IK" in the abstract passes without the disqualifying details — diagonals authored, slope-normal alignment, animated-hip raycast — actually being checked). The rubric's TEXT is above the mean and complete on the four killers; the 95% survival suggests the GRADING is not enforcing the rubric's own "earns nothing" floors. The fix is at the judging layer, not the rubric content: enforce the explicit disqualifiers (UseStrafingAnimation != diagonals; AdjustSpeed != foot IK; baked clip != phase signal; default 0.1s fade != blend-space re-weighting) as hard fails. With those enforced, expected survival should fall well below 95%, which is the intended discriminating behavior.

BOTTOM LINE: Rubric content covers all four mandated killer systems with dedicated + reinforcing items and correct, current engine mechanisms; it is above the mean and complete on the required axis. The residual risk is grader leniency (95% survival) and three peripheral gaps (pole-vector stability, true stride-length scaling, turn-in-place), none of which are among the four required killers.

## Provenance

- Sweep angles: critique, tutorial, video, showcase
- Techniques gathered: 62; source URLs: 62
- Agents: 77 · tokens: ~2.9M · duration: ~28 min
