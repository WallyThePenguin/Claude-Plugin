# Environment/world-building rubric pilot report (4th category)

**Date:** 2026-06-22 · **Category:** environment · **Criteria:** 28 (3 baseline / 17 good / 8 exceptional)

Produced by the category-general `train-category` workflow (the same pipeline as locomotion/combat/gui), run from Claude Code with an environment config object. This is the **4th category and the 3rd distinct DOMAIN** — after animation (locomotion, combat) and 2D UI (gui), now 3D world art — broadening the proof that the rubric pipeline + the plugin's capture→evaluate→refine→learn loop generalize across asset domains.

## Acceptance gate (discrimination back-test)

- **PASSED in-workflow:** mean **0.00** / great **0.75** / gap **0.75** after **3** self-opt round(s). The FIRST category whose great cleared the 0.70 floor directly (locomotion needed self-opt rounds; combat + gui needed a faithful-exemplar re-validation because their great-hints under-claimed the exceptional tier). The environment great-hint claimed enough of the criteria range to pass without re-validation.
- **Scoring-bias check:** normal vs criteria-reversed grading of the mean — gap **0.000** (stable). No order bias.
- **Above-generic survival:** **28/30 (93%)** — the MOST discriminating of the four categories (2 candidates rejected; locomotion 76%, combat/gui 100%). The completeness critic flags 93% as 'somewhat loose' but the body is rich and well-laddered.
- **Killer-system coverage:** all 5 required killer systems covered; missing: none.
- **Self-optimization:** 3 GEPA-style round(s). The optimizer split/rewrote criteria; one rewrite produced an auto-generated `...-placeholder` id (a genuine, distinct scale/proportion criterion) which was RENAMED to `env-human-scale-proportion-standard` during onboarding for a clean id.
- **Provenance:** 75 techniques across 4 angles; ~41 distinct sources (create.roblox.com environmental-art curriculum, DevForum map-design + terrain threads, YouTube environment breakdowns, showcase teardowns).

## Honest limitations

- **93% survival** is still high-ish (though the best of the four). Possible mild judge leniency; the back-test PASS + complete coverage support quality; human calibration remains the optional valve.
- **The exceptional tier reaches into MESH/TEXTURE pipelines** (PBR SurfaceAppearance, trim sheets/tileables, stylized-foliage normal/roughness, custom terrain materials) that often require external DCC tools (Blender/Substance) beyond in-Studio building. Intentional ceiling-setting; a pure in-Studio build legitimately sits at baseline/good.
- **Text/design-claim grading has a ceiling.** Real grading happens in the plugin via `evaluate` (structural dump + design claim + optional captures). NOTE: `evaluate`'s structural dump is currently tuned for animation + GUI; a 3D-environment build-evidence gatherer (Part/Model/Material/Terrain/Lighting census) is a natural follow-up so `evaluate environment` grades on real structure (today it leans on the design claim + any captures).

## Onboarding

`environment.rubric.json` is embedded into the plugin via `scripts/gen_builtin_rubrics.py` → `src/BuiltinRubrics.luau` (now 4 rubrics: locomotion, combat, gui, environment). `RubricStore` decodes + validates it at load; it appears in the always-on catalog and via `use_rubric("environment")` / `evaluate("environment", ...)`. The 8192-token grade-call fix (shipped this session) covers this 28-criterion rubric. Files: `environment.config.json`, `environment.rubric.json`, `environment.rubric.md`, this report.
