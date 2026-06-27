# Build guide report: environment (v1.0)

Generated 2026-06-27 by the `train-recipe` factory; targets the environment rubric (v1.0).

## Coverage
- Rubric criteria addressed: **28 / 28**
- Steps: 19 across 3 tiers
- Uncovered criteria: none

## Completeness review
- Killer systems covered: composition-sightlines-and-landmark-guided-flow, material-texture-and-pbr-surface-craft, lighting-atmosphere-and-mood, modular-kit-and-layered-set-dressing-density, scale-readability-and-performance-optimization
- Killer systems missing: none
- Build order sound: True

### Assessment
COMPLETE COVERAGE: 28/28. Every rubric criterion maps to at least one build-guide step, all five named killer systems appear as explicit build steps, and the build order is dependency-sound. If followed, this guide produces an above-the-mean build that clears the rubric.

KILLER-SYSTEM COVERAGE (5/5 named, plus the 2 other KILLER-tagged criteria the rubric carries):
- composition-sightlines-and-landmark-guided-flow -> g2 (explicit focal point, three depth planes Foreground/Midground/Background folders, scale-contrast anchors, WedgePart elevation + sightline blockers occluding-then-revealing the landmark). Satisfies env-composition-sightlines-landmark-flow.
- lighting-atmosphere-and-mood -> g6 (committed ClockTime ~17 + matched Sky, warm ColorShift_Top vs cool NON-black OutdoorAmbient, Atmosphere with Density/Haze/Offset/Color). Hits all three pass pillars of env-lighting-atmosphere-mood-system verbatim, with an explicit FAIL list.
- modular-kit-and-layered-set-dressing-density -> BOTH halves covered: kit half by b4 (kit seed) + g1 (apply kit, one-piece-at-a-time, delete greybox) -> env-modular-kit-grid-pivot-discipline; density half by g8 (three-axis RNG variation: orientation>=90deg + scale + per-instance tint, contextual clusters, negative space, no-three-in-a-row, detail at corners/T-junctions) -> env-varied-nonuniform-set-dressing-density.
- scale-readability-and-performance-optimization -> BOTH halves covered: scale half by b2 (5-stud-tall character as ruler, >=10-stud doorways/walls, 5-stud grid) -> env-human-scale-proportion-standard; perf half by g10 (CanCollide/CanTouch/CanQuery off on dressing, CastShadow off on small/distant props, shared mesh-ID instancing for one draw call, RenderFidelity, shadow-light budget, run_luau part-count profiling) -> env-performance-optimization-pass.
- material-texture-and-pbr-surface-craft -> e1 (hero SurfaceAppearance with full map set: ColorMap + OpenGL NormalMap explicitly NOT DirectX + grayscale RoughnessMap + BINARY MetalnessMap, <=1024, shared package), reinforced by b4 (first custom material), e3 (crafted foliage materials), e4 (MaterialService terrain override). Satisfies env-pbr-surfaceappearance-material-craft and the related material criteria.

The two additional KILLER-tagged rubric criteria beyond the 5 named (material-PBR = e1; performance = g10) are both covered, so nothing KILLER-tagged is missing.

FULL 28-CRITERION MAP (criterion -> step): greybox-gameplay-first->b2; reference-plan-eyelevel->b1+b3; asset-library-reusable-look->b4; composition-sightlines->g2; set-extension-beyond-bounds->g3; unified-palette-blur-test->g6+g7; lighting-atmosphere-mood->g6; sun-shadow-craft->g6+g9; post-processing-ordered-stack->g7; modular-kit-grid-pivot->b4+g1; varied-set-dressing-density->g8; surface-depth-relief->g5; human-scale-proportion->b2; terrain-contour-multimaterial->g3; part-blockout-terrain-normalize->g3(normalize pass); cliff-rock-layering-depth->g4; grass-decoration-foliage-grounding->g3; stylized-water-treatment->e4(+g3); wayfinding-zone-color-material->g1; performance-optimization->g10; fog-vs-atmosphere-depth-tool->e2; environmental-storytelling-wear-history->g8+e3; pbr-surfaceappearance-craft->e1; trim-sheets-tileables->b4+e1; stylized-foliage-pipeline->e3; foliage-fill-light->g9; organic-motion-volumetric-life->e2+e5; custom-terrain-material-override->e4. No criterion is unmapped.

BUILD ORDER IS SOUND - dependencies precede dependents, and the guide states the load-bearing ones explicitly:
- Sky-before-Atmosphere: g6 orders Sky (step 1) before Atmosphere (step 3) and explicitly warns 'the Atmosphere does NOTHING without a Sky'; e2 builds on this. Correct per the rubric.
- Greybox -> validate -> kit -> apply -> dress: b2 -> b3 -> b4 -> g1 -> g8, and g8 explicitly gates ('set-dress ONLY after structure, materials, and terrain already read correctly'). Correct.
- Terrain-before-grounding: g3 sculpts terrain then grounds foliage into it; g4 layers rockwork on it. Correct.
- Cross-step couplings are honored: e2 reads its depth falloff against the g2 backdrop geometry; e1 pairs PBR normals against the g5 relief geometry; e5 parents Clouds under the g3 Terrain. Correct.
- Lighting (g6) before post grade (g7) before exceptional volumetric life (e2/e5). Correct.

MINOR SEQUENCING OBSERVATION (not a gap, does not cost coverage): the g10 optimization pass sits before the Exceptional tier (e1-e5), which then adds hero SurfaceAppearances, particles, god-rays, and Clouds that g10's sweep did not see. The guide mitigates this in-place - e1 reuses ONE shared SurfaceAppearance/package to batch draw calls, and e2/e5 attach explicit performance gates to the volumetrics - so perf discipline is carried into the exceptional tier rather than going stale. A belt-and-suspenders improvement would be a one-line 'final optimization re-sweep after e5,' but it is not required to clear env-performance-optimization-pass, which grades the demonstrated discipline rather than a final part-count.

VERDICT: above-the-mean and clears the rubric at 28/28. The guide does not merely gesture at each system - it bakes in the exact discriminators the rubric checks (binary metalness, OpenGL-not-DirectX normals, non-black cool ambient, three-axis variation with no-three-in-a-row, shared-ID instancing, Sky-before-Atmosphere, occlude-then-reveal landmark, negative space around focal points) and the explicit FAIL conditions, so a faithful execution lands in PASS rather than PARTIAL on the hard criteria.

## Provenance
- Sweep angles: workflow, killer-impl, pitfalls, video
- Techniques gathered: 62
- Coverage-fill rounds: 0
