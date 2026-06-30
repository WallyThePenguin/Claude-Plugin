# Build guide report: npc (v1.0)

Generated 2026-06-29 by the `train-recipe` factory (35 agents; 45 build-angled techniques → 25 steps /
3 tiers, 5 baseline / 13 good / 7 exceptional); targets the npc rubric (v1.0, 24 criteria). The guide
frames NPC AI as a LAYERED CONTROL STACK — SENSE → DECIDE → NAVIGATE → ACT re-run every tick — built
almost entirely in `run_luau` on top of a `spawn_rig` body.

> Tooling note the guide makes explicit: the stock `make_npc` *is the rubric's MEAN artifact* (straight-line
> `MoveTo` + omniscient distance check + one chase branch). The guide uses it only as a scaffold to
> overwrite — you clear the rubric by replacing that generated NpcAI script's body with the real
> perception/navigation/decision/coordination stack.

## Coverage
- Rubric criteria addressed: **24 / 24**
- Steps: 25 across 3 tiers (one criterion — the pathfinding follow-loop — gets two steps: rig setup that
  *feeds* the agent params, then the validated compute-and-follow loop itself)
- Uncovered criteria: none (coverage-fill rounds: 0)
- Completeness review: not run (the final review agent hit a session limit); coverage gate (24/24) is met.

## Build order (dependency-sound)
Bottom-up: (baseline) a PathfindingService compute-and-follow loop that routes around obstacles and
survives a moving/blocked world → earned perception (range → dot-product FOV cone → LOS raycast, never an
omniscient distance check) → an explicit prioritized FSM (Idle/Patrol/Investigate/Chase/Attack/Return,
states *command* the perception/navigation modules) → zone-leashed ambient wander. Then (good) graded
detection meter, last-known-position memory + investigate, turn/state hysteresis, event-gated repath,
stuck recovery, off-mesh links, target selection, anti-clump separation, utility AI, behavior-tree +
blackboard, combat spacing/kiting + connection cleanup, throttled AI budget, ambient barks/routines. Then
(exceptional) per-archetype perception tuning, coordination roles/slots + alert propagation, tactical
flanking with rated positions, boids flocking + spatial partition, server-authoritative scale architecture,
desync timing variance (react-before-think), and a debug visualization layer.

## 24 / 24 map (rubric criterion → guide step)
- npc-pathfinding-waypoint-follow-loop → `b1` (rig→agent-params) + `b2` (compute-and-follow loop)
- npc-perception-los-fov-range-occlusion → `b3`
- npc-decision-architecture-fsm-sized → `b4`
- npc-ambient-wander-zone-leashed → `b5`
- npc-graded-detection-meter-states → `g1`
- npc-last-known-position-memory-search → `g2`
- npc-state-hysteresis-smooth-turning → `g3`
- npc-repath-on-event-not-per-frame → `g4`
- npc-stuck-detection-recovery-timeout → `g5`
- npc-offmesh-traversal-links-arrival → `g6`
- npc-target-selection-interception-lead → `g7`
- npc-anti-clump-separation-spacing → `g8`
- npc-utility-ai-context-scoring → `g9`
- npc-behavior-tree-blackboard-event-driven → `g10`
- npc-combat-spacing-kiting-cleanup → `g11`
- npc-throttled-staggered-ai-budget → `g12`
- npc-ambient-believability-barks-routines → `g13`
- npc-per-archetype-perception-tuning → `e1`
- npc-coordination-roles-slots-alert-propagation → `e2`
- npc-tactical-flanking-rated-positions → `e3`
- npc-boids-flocking-spatial-partition → `e4`
- npc-server-authoritative-scale-architecture → `e5`
- npc-desync-timing-variance-react-before-think → `e6`
- npc-debug-visualization-layer → `e7`

## Provenance
- Sweep angles: workflow, killer-impl, pitfalls, video
- Techniques gathered: 45
- Coverage-fill rounds: 0
