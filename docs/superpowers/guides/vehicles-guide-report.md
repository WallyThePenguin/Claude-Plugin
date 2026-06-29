# Build guide report: vehicles (v1.0)

Generated 2026-06-29 by the `train-recipe` factory (27 agents; techniques across workflow/killer-impl/
pitfalls/video); targets the vehicles rubric (v1.0). The agent has no dedicated vehicle tool, so the guide
builds the whole thing from `create_instance`/`set_property` (chassis, wheels, constraints, attachments,
VehicleSeat, particles, sounds) and `run_luau` (network ownership, the per-frame raycast/force/grip/steer
loop, the speed-feedback loop, the server validator), verified with `capture`/`capture_angles`.

## Coverage
- Rubric criteria addressed: **17 / 17**
- Steps: 18 across 3 tiers (5 baseline / 6 good / 7 exceptional)
- Uncovered criteria: none (coverage-fill rounds: 0)

## Completeness review
- Killer systems covered: 5 / 5 (physics chassis + suspension, tuned drive/steer, grip/traction/drift,
  speed-sensation feedback, networked ownership).
- Review verdict: **COMPLETE** — all 17 rubric criteria covered as explicit build steps, build order sound
  (every dependent step names and follows its prerequisite); if followed it clears the rubric.

### Build order (dependency-sound)
The guide front-loads the three load-bearing commitments before any handling tuning: (baseline) heavy
chassis PrimaryPart + separate unanchored wheels with mass/CoM/collision-group treatment → a *named*
per-wheel suspension architecture (constraint axle OR raycast spring-damper) with bounded travel →
VehicleSeat as input source → driver network ownership on sit. Then (good) the tuned drive/steer model,
per-wheel lateral grip/traction, multi-channel speed sensation (FOV/camera/audio off AssemblyLinearVelocity),
slip-gated skid effects, counter-steer + chase camera. Then (exceptional) load-sensitive grip / weight
transfer, Pacejka slip-curve + friction circle, gearbox, braking-as-character, server ownership validation
+ multi-seat, and frame-rate-independent force integration. It names the real anti-patterns throughout
(CFrame-teleport/constant-velocity body; anchored parts can't receive ownership; VehicleSeat auto-drive
only detects rigidly-connected motors, so constraint/raycast cars read ThrottleFloat/SteerFloat by hand).

## 17 / 17 map (rubric criterion → guide step)
- veh-mass-com-collision-tuning → `b1` + `b2`
- veh-nonwheeled-aero → `b1` + `e7`
- veh-chassis-physics-suspension → `b3` + `g1`
- veh-suspension-architecture-robustness → `b3` + `g1`
- veh-drive-steer-model → `b4` + `g2` + `e3` + `e7`
- veh-network-ownership-responsive → `b5` + `e5`
- veh-suspension-contact-quality → `g1`
- veh-grip-traction-drift → `g3` + `e2`
- veh-speed-sensation-feedback → `g4` + `g6`
- veh-slip-gated-effects → `g5`
- veh-counter-steer-camera-feel → `g6`
- veh-load-sensitive-grip-weight-transfer → `e1`
- veh-friction-circle-pacejka → `e2`
- veh-drivetrain-gearbox → `e3` + `e4`
- veh-braking-drivetrain-character → `e4`
- veh-ownership-validation-multiseat → `e5`
- veh-framerate-independence → `e6`

## Provenance
- Sweep angles: workflow, killer-impl, pitfalls, video
- Coverage-fill rounds: 0
