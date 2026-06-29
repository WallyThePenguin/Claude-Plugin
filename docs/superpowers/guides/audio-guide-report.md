# Build guide report: audio (v1.0)

Generated 2026-06-29 by the `train-recipe` factory (22 agents); targets the audio rubric (v1.0). Scope
correction baked in per the owner: the guide tells the agent to **CURATE Creator-Store/Toolbox asset ids
and WIRE/SCRIPT them** — selection + routing + scripting are the quality levers, not waveform authoring.

## Coverage
- Rubric criteria addressed: **12 / 12**
- Steps: 15 across 3 tiers (4 baseline / 7 good / 4 exceptional)
- Uncovered criteria: none (coverage-fill rounds needed: 0)

## Completeness review
- Killer systems covered (5 / 5):
  1. modern-audio-api-spatial-wiring → `audio-modern-graph-wiring` + `audio-distance-attenuation-shape`
  2. curated-library-layered-randomized-variation → `audio-curate-library-registry` + `audio-pooled-randomized-variation`
  3. dynamic-mixing-bus-with-sidechain-ducking-and-mastering → `audio-bus-tree-gain-staging` + `audio-sidechain-ducking-master-limiter`
  4. environmental-reverb-eq-occlusion-zones → `audio-reverb-zones-occlusion`
  5. event-synced-and-adaptive-layered-music → `audio-event-source-binding` + `audio-adaptive-stem-music`
- Killer systems missing: none
- Build order sound: True

### Assessment
COMPLETE — the guide maps cleanly onto all 12 rubric criteria, with each step naming the SPECIFIC named
mechanism its PASS gate demands (Wire SourceInstance/TargetInstance and the silent-node-without-Wire trap;
neutral gain staging into a Master→{Music,SFX,Ambience,UI,Voice} bus tree; 4–8 clip pools with ±5%
PlaybackSpeed jitter; a sidechained AudioCompressor with the music on Input and voice on the Sidechain pin
plus a master AudioLimiter; ONE AudioReverb retuned per zone with raycast EQ occlusion, not a reverb per
emitter; 4–8 sample-aligned stems on per-stem AudioFaders cross-faded by an intensity state machine). The
build order is dependency-sound: curate asset ids → stand up the AudioPlayer→Wire→Emitter→Listener→Output
graph → build the bus tree → layer the `good` systems → finish with the `exceptional` zone/stem/ambience
systems. If followed faithfully it produces an above-the-mean build that clears the rubric at 12/12.

## 12 / 12 map (rubric criterion → guide step)
- audio-modern-graph-spatial-wiring → `audio-modern-graph-wiring` (+ `audio-distance-attenuation-shape`)
- audio-mixing-bus-hierarchy-gain-staging → `audio-bus-tree-gain-staging`
- audio-curated-library-variation-de-repetition → `audio-curate-library-registry` + `audio-pooled-randomized-variation`
- audio-event-driven-source-bound-playback → `audio-event-source-binding`
- audio-sidechain-ducking-dynamic-mix → `audio-sidechain-ducking-master-limiter`
- audio-directional-volumetric-emission → `audio-directional-volumetric-emission` (+ `audio-distance-attenuation-shape`)
- audio-client-predicted-listener-placement → `audio-listener-placement-client-prediction`
- audio-interaction-group-isolation → `audio-multi-role-soundscape`
- audio-seamless-loop-craft → `audio-seamless-sustained-bed`
- audio-environmental-reverb-eq-zones → `audio-reverb-zones-occlusion`
- audio-adaptive-stem-layered-music → `audio-adaptive-stem-music`
- audio-layered-ambience-bed-randomized-oneshots → `audio-layered-ambience-system`

A closing step (`audio-verify-and-evaluate-loop`) bakes the capture → `evaluate(category='audio')` →
refine-fails-first loop into the guide itself — the project's iterate-via-capture north star, applied to
the five spine criteria.

## Provenance
- Sweep angles: workflow, killer-impl, pitfalls, video
- Techniques gathered: 45
- Coverage-fill rounds: 0
