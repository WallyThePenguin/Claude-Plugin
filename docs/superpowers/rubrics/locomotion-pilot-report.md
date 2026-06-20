# Locomotion Pilot — Report (v1.1)

**Date:** 2026-06-20 · **Runs:** wf_0408a43e-60f (v1) → judge-tightened resume (v1.1) · **Pipeline:** `train-category` (Claude Code)
**Spec:** `docs/superpowers/specs/2026-06-20-studio-agent-locomotion-pilot-design.md` · **Plan:** `docs/superpowers/plans/2026-06-20-locomotion-pilot.md`

## Verdict: PASS ✅ (v1.1, judge-tightened)

The pipeline produced a Locomotion rubric that discriminates mean from great AND self-sharpens. v1 passed but the above-generic judge was too lenient (95% survival); tightening it (concrete floor + unanimous-keep) cut survival to a calibrated 76% while *improving* separation. The keystone mechanism now enforces the floor.

## v1 → v1.1 (effect of tightening the judge)

| Metric | v1 (lenient) | v1.1 (strict) |
|---|---|---|
| Above-generic survival | 95% (20/21) | **76% (16/21)** |
| Criteria | 20 (5b/8g/7e) | 16 (2b/7g/7e) |
| Back-test gap | 0.77 | **0.82** |
| Killer systems | 4/4 | 4/4 |
| Optimization rounds | 1 | 3 |

## §12 acceptance gate

| Criterion | Result | Evidence |
|---|---|---|
| Discrimination back-test | **PASS** | mean 0.00 ≤ 0.5, great 0.82 ≥ 0.7, gap 0.82 ≥ 0.35 |
| Above-generic survival + coverage | **PASS** | 16/21 (76%); all 4 killer systems covered |
| Scoring-bias stability | **PASS** | normal 0.027 vs shuffled 0.014, gap 0.014 ≤ 0.10 |
| Self-optimization fired | **PASS** | 3 round(s) of reflective rewrite to reach separation |

## Back-test (per criterion, final round)

Every criterion fails the MEAN artifact. The GREAT artifact:

| Tier | Criterion | mean → great |
|---|---|---|
| baseline | loco-state-machine | fail → pass |
| baseline | loco-living-idle | fail → pass |
| good | loco-stride-locked-to-speed | fail → pass |
| good | loco-directional-variant-set | fail → partial |
| good | loco-per-part-easing | fail → pass |
| good | loco-blend-tree-speed-and-direction | fail → partial |
| good | loco-foot-ik-terrain | fail → pass |
| good | loco-additive-lookat-aim | fail → pass |
| good | loco-fadetime-transitions | fail → pass |
| exceptional | loco-pelvis-hip-sway-gait-phase | fail → pass |
| exceptional | loco-velocity-lean-additive | fail → partial |
| exceptional | loco-marker-synced-fx | fail → fail |
| exceptional | loco-accel-decel-momentum | fail → pass |
| exceptional | loco-hip-height-terrain | fail → pass |
| exceptional | loco-personality-cog | fail → pass |
| exceptional | loco-retarget-rig-portability | fail → pass |

## Empirical answers to spec §14 open questions

- **How many candidates/criteria?** 62 techniques → 21 candidates → 16 survived the strict judge → 16-criterion rubric.
- **Best exemplar-reference strategy?** The contrastive mean-vs-great pair discriminated strongly (gap 0.82); supports the contrastive pair over a single 'full-marks' reference.
- **Corpus-drift guard?** Untested (external exemplars only); validate in the loop session.
- **Small local helper model?** Not investigated (non-goal).

## Honest limitations (feed the loop session)

- **Non-separating criterion:** loco-marker-synced-fx — the design-stage GREAT text doesn't carry enough to pass; needs live-capture evidence (loop session).
- **Thin coverage:** additive look-at/aim rests on a single item (per the completeness critic); a few transition items are partially correlated (all key off the blend-space commitment).
- **Text-level grading ceiling (inherent):** rubric-first grades described behavior, not built structure — criteria demanding keyframe-level evidence can't be fully scored until the live capture→evaluate loop exists.
- **Judge calibration is iterative:** 95%→76% came from one tightening pass; further calibration (and the human checkpoint) refine it.

## Completeness critic — assessment

VERDICT: This rubric is ABOVE THE MEAN and effectively COMPLETE on the four mandated killer systems. All four are covered by dedicated, explicitly-labeled "KILLER SYSTEM" items with sharp pass/fail discriminators, and three of the four are reinforced by adjacent items that attack the same failure mode from a second angle. The 76% candidate survival rate is consistent with — and arguably validates — a rubric calibrated correctly: the gates are demanding enough to fail the ~quarter of builds that ship the stock single-loop default, while the architecture-level (not capture-required) pass bar keeps it from being impossibly strict. I would ship this rubric.

=== KILLER-SYSTEM COVERAGE ===

1. BLEND TREE (warps by speed AND direction) — COVERED, strongly.
   - Primary: `loco-blend-tree-speed-and-direction` (tier: good, explicitly "KILLER SYSTEM — BLEND TREE"). Nails BOTH axes: a speed axis (idle@0 -> walk -> jog -> run with crossfade, NOT threshold-swap) AND a direction axis (velocity projected into HRP object space via VectorToObjectSpace, or dot/cross of MoveDirection vs look/right). Correctly fails the single forward loop swapped by WalkSpeed, and correctly awards only PARTIAL to a single-axis-only blend (speed XOR direction). This is the exact "not one forward loop" requirement.
   - Reinforced by `loco-state-machine` (velocity-classifying routing layer, >1 target), `loco-directional-variant-set` (direction decoupled from facing via object-space velocity), and `loco-fadetime-transitions` (continuous velocity-weighted re-blend vs stock fixed-time fade). The "speed AND direction, not one loop" idea is attacked from four directions. No gap.

2. FOOT IK (plant on ground/slopes/steps, no skating) — COVERED, strongly.
   - Primary: `loco-foot-ik-terrain` (tier: good, "KILLER SYSTEM — FOOT IK"). Requires runtime, world-influenced grounding via IKControl (Type Transform; EndEffector=foot, ChainRoot=upper-leg, Target=downward-raycast hit) OR Motor6D.Transform. Fails "feet skate on slopes," awards partial to "feet snap to ground" with no IK/Transform path. Slopes AND steps both named.
   - The "no skating" half is double-covered: `loco-stride-locked-to-speed` (good) handles contact-phase skating via cadence coupling (AdjustSpeed ~ speed/baseline) OR a world-planting grounding pass; `loco-hip-height-terrain` (exceptional) covers vertical conform + the ceiling of root/hip offset from foot-IK height delta. Skating is addressed both at the cadence level and the world-plant level. No gap.

3. ADDITIVE LOOK-AT / AIM (layered on locomotion) — COVERED.
   - Primary and sole owner: `loco-additive-lookat-aim` (tier: good, "KILLER SYSTEM — ADDITIVE LOOK-AT / AIM"). The discriminator is exactly right: aim must be ADDITIVE/LAYERED (IKControl aim chain, AnimationConstraint, or AnimationPriority Movement-vs-Action+ layering) and explicitly must NOT stop/restart the walk; an aim that replaces the whole-body gait earns only partial. This is precisely "rides ON TOP of running locomotion without stopping the gait."
   - NOTE: this is the one killer system carried by a single item (the upper-body-overlay clause in `loco-per-part-easing` brushes it but is a weaker proxy). Covered, but the thinnest of the four — see "missing/notes" for the one refinement I'd suggest.

4. PELVIS BIAS / HIP SWAY / LEAN tied to gait phase AND acceleration — COVERED, strongly.
   - The killer system as written ("pelvis bias / hip sway / lean tied to gait phase AND acceleration") is split across three exceptional-tier items that together cover it fully:
     * `loco-pelvis-hip-sway-gait-phase` ("KILLER SYSTEM — PELVIS BIAS / HIP SWAY"): pelvis counter-rotation/sway DRIVEN BY gait phase (LowerTorso on R15) + acceleration-reactive bias; re-posed run vs sped-up walk. Fails rigid hips; partial for pelvis baked into a clip with no phase/accel coupling. This is the gait-phase half nailed.
     * `loco-velocity-lean-additive`: additive runtime lean driven by LIVE velocity/acceleration (dot/cross of velocity vs look), forward on accel / into turns / back on hard stops; baked tilt earns only partial. This is the acceleration/lean half nailed.
     * `loco-accel-decel-momentum`: makes acceleration a first-class runtime-tracked signal that FEEDS the locomotion (lean/pelvis/blend axis), explicitly failing the WalkSpeed snap. This is the connective tissue that ties "gait phase AND acceleration" together.
   - Further reinforced by `loco-personality-cog` (owned posture/COG/lean layer producing a movement signature). The single most demanding killer system is the best-covered. No gap.

=== CALIBRATION / SURVIVAL-RATE READ ===
- 15 items, well-tiered: 2 baseline (existence gates), 7 good (the craft middle, where all 4 killer-system primaries live), 6 exceptional (ceiling/personality). The four killer-system primaries are mostly tier "good" with the pelvis/lean cluster pushed to "exceptional" — appropriate, since hip-phase-coupled pelvis motion + accel-lean is genuinely harder than a 2D blend.
- Discriminators are uniformly architecture-level and self-contradiction-anchored ("a build whose OWN description says feet skate FAILS"), which is what makes a design-stage rubric gradable without capture. This is above the mean: most generated rubrics grade vibes; this one grades a single load-bearing commitment per item with an explicit FAIL example and a named ceiling.
- A 76% survival rate is healthy for a rubric whose baseline gates fail any build that ships the stock single-loop WalkSpeed-swap default. It is failing roughly the bottom quartile (the "AI did it" generic builds), not decimating the field — consistent with gates that are real but clear-able at the architecture-commitment stage. If the killer-system gates were toothless, survival would sit near 95%+; if they were capture-gated/impossible, it would crater well below 50%. 76% sits in the calibrated band. No evidence of a gate that is either a rubber stamp or a wall.

=== ASSESSMENT ===
Above the mean: YES. Complete on the four mandated killer systems: YES — each has a dedicated KILLER-SYSTEM-tagged item with a correct discriminator, and 3 of 4 are corroborated by neighbor items. The only thin spot is the additive look-at/aim, which rests on a single item; everything else is redundantly covered. One optional hardening (below) would close that. As-is, this rubric is complete and ship-ready.

## Provenance

- Sweep angles: critique, tutorial, video, showcase
- Techniques: 62; source URLs: 62
- v1: 77 agents/~2.9M tok; v1.1 resume: 83 agents/~2.7M tok (sweep cached)
