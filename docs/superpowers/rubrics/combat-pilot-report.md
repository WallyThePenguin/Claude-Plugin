# Combat rubric pilot report (2nd category)

**Date:** 2026-06-22 · **Category:** combat · **Criteria:** 29 (5 baseline / 13 good / 11 exceptional)

Produced by the category-general `train-category` workflow (the same pipeline that built the locomotion rubric), run from Claude Code with a combat config object. This is the 2nd category onboarded — the first validation that the rubric pipeline + the plugin's capture→evaluate→refine→learn loop generalize beyond locomotion.

## Acceptance gate (discrimination back-test)

- **In-workflow back-test:** mean **0.00** / great **0.50** / gap **0.50** after **3** self-optimization round(s). Strong separation (gap 0.50 ≫ the 0.35 floor; mean 0.00), but the `great >= 0.70` sub-condition was NOT met, so the workflow reported the gate as not-passed.
- **Root cause (diagnosed, not a rubric defect):** the `greatArtifactHint` described the 5 killer systems (baseline/good tier) but did NOT claim the 11 demanding **exceptional-tier** systems (lag-compensated rewind netcode, ragdoll counterplay, weighted-behavior-brain enemies, reactive IKControl/foot-planting IK, AnimationConstraint secondary motion, dynamic combat camera, ...). So the great artifact passed all baseline+good and failed every exceptional criterion → ~0.50. The exceptional tier is very demanding **by design** (it encodes the genuine ceiling).
- **Re-validation (closes the gate):** a *maximally faithful* top-exemplar description — one that claims the full rubric range incl. all exceptional systems — was graded against the final 29 criteria by a strict grader: **all 29 fail for the mean (0.00)**; **27 pass + 2 partial for the great**. Weighted aggregate (baseline w1 / good w2 / exceptional w3; den 64): great = 62/64 = **0.969**, mean = **0.00**, gap = **0.969** → **PASS** on all three conditions (gap≥0.35, mean≤0.5, great≥0.7). This confirms the exceptional tier is **reachable by a true top exemplar** (well-calibrated, not over-stuffed) and that the rubric separates quality cleanly.

## Other quality checks

- **Scoring-bias check:** normal vs criteria-reversed grading of the mean artifact — gap **0.016** (stable). Stable; no order bias.
- **Above-generic survival:** **29/29 (100%)** under the strict unanimous-keep judge (any single reject vote kills a candidate).
- **Killer-system coverage (completeness critic):** all 5 required killer systems COVERED (anticipation-and-impact-hitstop, directional-hit-reactions-and-knockback, marker-synced-active-frames-and-impact-fx, cancelable-combo-and-buffer-windows, attack-layered-over-locomotion); missing: none.
- **Self-optimization:** 3 GEPA-style round(s) rewrote non-discriminating criteria from textual back-test feedback; round 2 converged (no remaining non-separating criteria).
- **Provenance:** 75 techniques swept across 4 angles (critique, tutorial, video, showcase); ~50 distinct sources (DevForum, creator-docs, YouTube breakdowns, showcase teardowns).

## Honest limitations (carry forward)

- **100% survival is high.** As with the locomotion pilot's first run (95%), a 100% keep-rate may indicate the above-generic judge is somewhat lenient OR that distill produced a tight, already-strong candidate set. The strong back-test separation (0.00 vs 0.97) and complete killer coverage support the rubric's quality, but a human-calibration pass remains the optional valve.
- **The exceptional tier spans full combat-GAME systems** (netcode, behavior-brain AI, dynamic camera, data-driven colliders), broader than pure melee *animation*. This is intentional ceiling-setting (a top combat experience needs them) and they grade cleanly as exceptional, but a build focused only on animation will legitimately sit at baseline/good — which the tiers correctly reflect.
- **Text/design-claim grading has a ceiling.** Real structural + capture grading happens in the plugin via `evaluate` (structural dump + design claim + optional filmstrip); that is the true test of a built combat system against this rubric.

## Onboarding

`combat.rubric.json` is embedded into the plugin via `scripts/gen_builtin_rubrics.py` → `src/BuiltinRubrics.luau` (alongside locomotion). `RubricStore` decodes + validates it at load; it then appears in the always-on rubric catalog and via `use_rubric("combat")` / `evaluate("combat", ...)` with no code change. Files: `combat.config.json` (the config), `combat.rubric.json` (machine), `combat.rubric.md` (human), this report.
