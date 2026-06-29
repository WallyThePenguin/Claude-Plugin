# Build guide report: camera (v1.0)

Generated 2026-06-29 by the `train-recipe` factory (22 agents); targets the camera rubric (v1.0). Because
a camera system is almost entirely runtime/render code, the guide builds it mostly with `run_luau` (writes
the camera LocalScript into the place) + `create_instance`/`set_property` (script container + a
Configuration of named tunables), verified visually with `capture` / `capture_angles`, with `make_npc` /
`make_tool` / `bind_hitbox` / `bind_behavior` supplying the gameplay events the reactive channels react to.

## Coverage
- Rubric criteria addressed: **13 / 13**
- Steps: 15 across 3 tiers (5 baseline / 5 good / 5 exceptional)
- Uncovered criteria: none (coverage-fill rounds needed: 0)

## Completeness review
- Killer systems covered (5 / 5):
  1. context-driven-camera-state-machine → `cam-g1-context-mode-state-machine`
  2. spring-damped-follow-with-look-ahead → `cam-e1-spring-follow-lookahead`
  3. reactive-fov-and-trauma-shake → `cam-e2-reactive-fov-trauma-shake`
  4. collision-and-occlusion-aware-framing → `cam-e4-collision-occlusion-framing`
  5. lock-on-and-cinematic-composition → `cam-e5-lockon-cinematic-composition`
- Killer systems missing: none
- Build order sound: True

### Assessment
COMPLETE — the guide maps onto all 13 rubric criteria, with each step naming the specific mechanism its
PASS gate demands. The build order is load-bearing and dependency-sound: (baseline) decide control mode →
take render-step ownership (CameraType.Scriptable + one `BindToRenderStep` at `RenderPriority.Camera`,
writing CFrame **and** Focus per frame) → a parameterized base follow → layered additive composition →
smooth the **intermediate** values (focus/zoom/shoulder/FOV) and derive the pose with `CFrame.lookAt`,
never the final CFrame; (good) context mode state machine that retargets one smoother → aim/follow
decoupling → movement-gated framing → directional impulse kick → per-axis asymmetric tuning; (exceptional)
dt-correct critically-damped spring follow + look-ahead → reactive FOV + trauma² Perlin shake → ≥3 stacked
reactive channels over one base → Popper-style collision/occlusion framing → lock-on two-target framing +
a distinct cutscene system. If followed it produces an above-the-mean build that clears the rubric 13/13.

## 13 / 13 map (rubric criterion → guide step)
- camera-renderstep-ownership-bind-contract → `cam-b1-decide-control-mode` + `cam-b2-renderstep-ownership-contract`
- camera-parameterized-rig-and-asymmetric-tuning → `cam-b3-parameterized-base-follow` + `cam-g5-asymmetric-per-axis-tuning`
- camera-layered-additive-composition → `cam-b4-layered-additive-composition`
- camera-smooth-intermediate-not-final-cframe → `cam-b5-smooth-intermediate-not-final`
- camera-context-driven-mode-state-machine → `cam-g1-context-mode-state-machine`
- camera-look-direction-body-decoupling → `cam-g2-look-body-decoupling`
- camera-first-person-liveliness-speed-gated → `cam-g3-movement-state-gated-framing`
- camera-directional-impulse-kick → `cam-g4-directional-impulse-kick`
- camera-framerate-independent-spring-follow-lookahead → `cam-e1-spring-follow-lookahead`
- camera-reactive-fov-and-trauma-shake → `cam-e2-reactive-fov-trauma-shake`
- camera-stacked-reactive-effects-at-thresholds → `cam-e3-stacked-reactive-channels`
- camera-collision-occlusion-aware-framing → `cam-e4-collision-occlusion-framing`
- camera-lockon-cinematic-composition → `cam-e5-lockon-cinematic-composition`

## Provenance
- Sweep angles: workflow, killer-impl, pitfalls, video
- Techniques gathered: 40
- Coverage-fill rounds: 0
