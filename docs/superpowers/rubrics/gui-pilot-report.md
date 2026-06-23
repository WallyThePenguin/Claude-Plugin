# GUI/UI rubric pilot report (3rd category — first non-animation)

**Date:** 2026-06-22 · **Category:** gui · **Criteria:** 35 (6 baseline / 17 good / 12 exceptional)

Produced by the category-general `train-category` workflow (the same pipeline that built the locomotion + combat rubrics), run from Claude Code with a GUI config object. This is the **3rd category onboarded and the FIRST non-animation one** — the strongest evidence yet that the rubric pipeline + the plugin's capture→evaluate→refine→learn loop generalize across asset DOMAINS, not just within animation.

> Note: the workflow originally STALLED ~30 min in (a hung agent, 0-byte output). It was diagnosed (no recent transcript activity, task gone from the registry) and RESUMED via `resumeFromRunId` — the completed sweep/distill/judge agents returned from cache and it finished the assemble/harden/critique phases. The resume mechanism worked cleanly.

## Acceptance gate (discrimination back-test)

- **In-workflow back-test:** mean **0.00** / great **0.68** / gap **0.68** after **3** self-opt round(s). Strong separation (gap 0.68 ≫ the 0.35 floor; mean 0.00), but `great` JUST missed the 0.70 sub-condition (0.685), so the workflow reported the gate as not-passed.
- **Root cause (diagnosed, same as combat):** the `greatArtifactHint` described the 5 killer systems (baseline/good tier) but did NOT claim the 12 demanding EXCEPTIONAL systems (styling-tokens system, native shadow/elevation, nine-slice panels, easing personality/stagger, runtime feedback wiring, rich-text, React-like component architecture, state-store separation, …). So the great artifact passed baseline+good and failed most exceptional → 0.685 (only just under 0.70). The exceptional tier is demanding **by design**.
- **Re-validation (closes the gate):** a *maximally faithful* top-exemplar description — claiming the full range incl. all exceptional systems — was graded against the final 35 criteria by a strict grader: **all 35 fail for the mean (0.00)**; **33 pass + 2 partial for the great**. Weighted aggregate (baseline w1 / good w2 / exceptional w3; den 76): great = 73.5/76 = **0.967**, mean = **0.00**, gap = **0.967** → **PASS** on all three conditions. Confirms the exceptional tier is **reachable by a true top exemplar** (well-calibrated, not over-stuffed) and the rubric separates cleanly.

## Other quality checks

- **Scoring-bias check:** normal vs criteria-reversed grading of the mean — gap **0.007** (stable). Stable; no order bias.
- **Above-generic survival:** **35/35 (100%)** under the strict unanimous-keep judge. The completeness critic judged this consistent with the rubric's commit-at-architecture-level pass design (named-mechanism details reserved as strengtheners), not weak discrimination — but as with locomotion/combat, 100% is high and a human-calibration pass remains the optional valve.
- **Killer-system coverage:** all 5 required killer systems COVERED, each anchored to a flagged 'KILLER SYSTEM' criterion; missing: none.
- **Self-optimization:** 3 GEPA-style round(s).
- **Provenance:** 89 techniques across 4 angles; ~64 distinct sources (create.roblox.com UI docs, DevForum UI best-practice threads, YouTube UI breakdowns, showcase teardowns).

## Honest limitations

- **100% survival is high** (as with locomotion's first 95% and combat's 100%) — possible judge leniency; the strong back-test separation (0.00 vs 0.97) + complete killer coverage support quality, but human calibration is the optional valve.
- **The exceptional tier reaches into UI ENGINEERING** (React-like component architecture, state-store separation, runtime feedback wiring) beyond pure visual design. Intentional ceiling-setting; a purely-visual build legitimately sits at baseline/good, which the tiers reflect.
- **Text/design-claim grading has a ceiling.** Real structural grading happens in the plugin via `evaluate` — and `evaluate`'s structural dump was extended this session (`GuiEvidence`) to census UI classes + summarize per-element layout quality (scale-vs-offset, AnchorPoint, layouts, UICorner/UIPadding, constraints), so `evaluate gui` now grades on real GUI structure, not the animation-only census.

## Onboarding

`gui.rubric.json` is embedded into the plugin via `scripts/gen_builtin_rubrics.py` → `src/BuiltinRubrics.luau` (now 3 rubrics: locomotion, combat, gui). `RubricStore` decodes + validates it at load; it appears in the always-on catalog and via `use_rubric("gui")` / `evaluate("gui", ...)` with no code change. Files: `gui.config.json`, `gui.rubric.json`, `gui.rubric.md`, this report.
