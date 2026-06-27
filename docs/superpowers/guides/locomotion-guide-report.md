# Build guide report: locomotion (v1.0)

Generated 2026-06-27 by the `train-recipe` factory; targets the locomotion rubric (v1.1).

## Coverage
- Rubric criteria addressed: **16 / 16**
- Steps: 18 across 3 tiers
- Uncovered criteria: none

## Completeness review
- Killer systems covered: blend tree: warps by speed AND direction (not one forward loop), foot IK: feet plant on ground/slopes/steps, no skating, additive look-at / aim layered on locomotion, pelvis bias / hip sway / lean tied to gait phase and acceleration
- Killer systems missing: none
- Build order sound: True

### Assessment
COVERAGE: 16/16 rubric criteria covered. All four named KILLER SYSTEMS appear as explicit, mechanism-level build steps, and the build order is dependency-sound. If followed faithfully this guide produces an above-the-mean build that clears the rubric with margin.

KILLER SYSTEMS (all covered):
1. Blend tree (warps by speed AND direction) -> loco-good-2-blend-tree: commits BOTH axes to live velocity (localVel = HRP.CFrame:VectorToObjectSpace(AssemblyLinearVelocity); weight directions by clamping localVel.X strafe and localVel.Z fwd/back vs WalkSpeed AND crossfade idle@0->walk->run by speed/WalkSpeed), with Epsilon-clamped AdjustWeight. Object-space projection + dual-axis = full pass.
2. Foot IK (plant on ground/slopes/steps, no skating) -> loco-good-4-foot-ik: per-leg IKControl Type=Transform, ChainRoot=UpperLeg, EndEffector=Foot, downward raycast from animated hip, surface-normal align via CFrame.lookAt(hit.Position, hit.Position+hit.Normal), ~45deg reject, disable on jump/fall, SmoothTime. Extended vertically by loco-exc-4-hip-height-terrain (root drop from inter-foot delta).
3. Additive look-at / aim layered on locomotion -> loco-good-5-additive-aim: aim clip at Action priority over Movement-priority locomotion OR post-Animator post-multiply onto Waist.Transform/Neck.Transform on PreSimulation, restricted to UpperTorso/Head/UpperArms so legs keep walking; capture confirms gait never stops.
4. Pelvis bias / hip sway tied to gait phase and acceleration -> loco-exc-1-pelvis-sway: re-posed run (wider split, deeper hip drop, true airborne frame, arms in/behind) NOT a sped-up walk, plus post-Animator sinusoidal LowerTorso.Transform offset off normalized clip time (figure-8 in phase with footfalls) AND acceleration-reactive counter-rotation against the legs.

FULL 16/16 MAP (rubric criterion -> guide step):
- loco-state-machine -> loco-base-1 (R15 Motor6D substrate + explicit owned velocity-driven routing commitment, rejects WalkSpeed clip-swap) + loco-base-4 (LocalScript named exactly 'Animate' in StarterCharacterScripts, continuous velocity selection on PreSimulation).
- loco-living-idle -> loco-base-2 (idle authored FIRST as the v=0 node + base layer aim/lean ride on).
- loco-stride-locked-to-speed -> loco-good-3 (AdjustSpeed from the SAME live-velocity signal, EMPIRICALLY calibrated clipReferenceSpeed, clamp band [0.2,3.0] hit-tested, residual slip MEASURED in studs on a slope; even routes to foot-IK if slip persists at extremes -- exceeds pass gate).
- loco-directional-variant-set -> loco-good-1 (VectorToObjectSpace projection, enumerated forward/back/left/right/diagonal -> quadrant mapping, anti-moonwalk, symmetric stride).
- loco-per-part-easing -> loco-good-6 (BOTH accepted paths offered: authored Cubic In/Out easing + moving-holds OR >=2 region-targeted runtime overlays).
- loco-blend-tree-speed-and-direction [KILLER] -> loco-good-2.
- loco-foot-ik-terrain [KILLER] -> loco-good-4.
- loco-additive-lookat-aim [KILLER] -> loco-good-5.
- loco-fadetime-transitions -> loco-good-7 (continuity via continuous live-velocity re-weighting, not threshold swaps; + speed-scaled stop/settle + sign-flip reversal-through-intermediate for full marks).
- loco-pelvis-hip-sway-gait-phase [KILLER] -> loco-exc-1.
- loco-velocity-lean-additive -> loco-exc-2 (additive lean from dot/cross of velocity vs look, ~10deg cap math.rad(value*10), framerate-independent Lerp 1-0.001^dt, optional camera bank).
- loco-marker-synced-fx -> loco-exc-5 (Contact-frame keyframe markers + GetMarkerReachedSignal on the OWNED velocity-coupled layer so they stay locked under AdjustSpeed scaling, material-varied SFX).
- loco-accel-decel-momentum -> loco-exc-3 (runtime acceleration / dt-ramped 0..1 speedRatio FED into outputs; full-marks form shares ONE ramped ratio across blend axis AND velocity multiplier via TweenService:GetValue easing).
- loco-hip-height-terrain -> loco-exc-4 (root/hip vertical offset from inter-foot-IK-target delta, clamped, for bent knees on inclines/steps).
- loco-personality-cog -> loco-exc-6 (owned posture/COG layer across ALL speed states, reuses lean+pelvis; DELIBERATE named personality + foot-width + stomp/tiptoe + tone rationale for full marks).
- loco-retarget-rig-portability -> loco-exc-7 (signal-computed driver rig-portable by construction; HumanoidRigDescription >=15-joint mapping + R6/R15 direction-sign branch for full marks).

BUILD ORDER (sound -- dependencies precede dependents):
- Rig + architecture commitment (base-1) precedes everything; the LowerTorso/UpperTorso seam and Motor6D.Transform channel it confirms are exactly what hip-sway (exc-1) and additive-aim (good-5) later compose onto.
- Clips authored (base-2 idle, base-3 walk/run) BEFORE the controller that loads them (base-4) -- correct; you cannot LoadAnimation clips that do not exist.
- Directional clips (good-1) authored BEFORE the blend tree that weights them (good-2) -- correct dependency.
- The owned controller/hook (base-4) and the blend layer (good-2) precede every runtime layer that composes onto it: stride-lock (good-3), foot-IK (good-4), aim (good-5), transitions (good-7), and all exceptional post-Animator layers (exc-1,2,3,5,6). The guide repeatedly names the controller as 'the documented hook point all later layers compose onto'.
- Foot-IK (good-4) precedes its vertical extension hip-height-terrain (exc-4) -- exc-4 explicitly reuses the good-4 per-foot raycast/targets.
- Lean (exc-2) and pelvis-sway (exc-1) precede personality-cog (exc-6), which 'reuses the lean + pelvis-sway layers'.
- Acceleration signal (exc-3) is consumed by the accel-reactive parts of lean/pelvis -- minor note: exc-1/exc-2 already reference acceleration-reactivity while the momentum signal is formalized in exc-3, but since all three are post-Animator layers reading AssemblyLinearVelocity deltas the ordering is benign (the signal is trivially available wherever velocity is) and not a true broken dependency.
- Rig-portability (exc-7) last as a closure step over the already-signal-computed driver -- correct.

VERDICT: Clears the rubric at 16/16. The guide does not merely name systems -- it specifies the discriminating mechanisms each criterion grades (object-space velocity projection, IKControl Transform chains, priority/post-multiply additive aim, gait-phase LowerTorso sway) and pushes several criteria toward FULL marks rather than the bare pass gate (good-3 demands empirically-measured residual slip; good-2 commits both axes + Epsilon clamp; exc-3 shares one ramped ratio across blend AND velocity; exc-6 demands a named tone-justified personality; exc-7 adds RigDescription + R6/R15 sign branch). It explicitly forbids the FAIL conditions (WalkSpeed clip-swap, forward-clip-rotated moonwalk, sped-up-walk run, rigid hips, stop-the-walk aim). Above-the-mean is firmly established: the entire guide is built around an owned velocity-driven routing layer, which is the seam separating this from the free stock-Animate floor. No killer system is missing.

## Provenance
- Sweep angles: workflow, killer-impl, pitfalls, video
- Techniques gathered: 35
- Coverage-fill rounds: 0
