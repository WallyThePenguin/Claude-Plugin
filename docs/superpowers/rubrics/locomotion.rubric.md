# Locomotion Quality Rubric

**Module:** locomotion · **Version:** 1.0 · **Date:** 2026-06-20

**Back-test:** mean 0.00 / great 0.77 / gap 0.77 → PASS (after 1 optimization round(s)). **Above-generic survival:** 20/21.

> Produced by the `train-category` pipeline (research → above-generic judge → assemble → scoring-bias check → discrimination back-test → self-optimize → completeness critic). Grading is text/structure-level (rubric-first); live capture grading is the loop session.

## Baseline

### loco-state-machine

Locomotion is driven by a CONTINUOUS planar-velocity signal feeding a movement system, NOT a discrete WalkSpeed-threshold clip swap. The candidate must describe a runtime driver that reads the live Humanoid/root velocity vector (magnitude AND direction) and uses it to select/weight motion every frame — e.g. a blend tree keyed to planar velocity, or a velocity-projected weighting of tracks. Default Roblox 'Animate' swaps idle/walk/run on WalkSpeed alone and rotates the body to MoveDirection: that single-scalar, threshold-driven, direction-blind clip-swap is the FLOOR and earns nothing. To pass, the described architecture must (a) consume the velocity as a continuous quantity (not just cross a speed threshold) and (b) carry a DIRECTION component (strafe/forward axis), so the system has a 2D notion of movement rather than one forward loop scaled by speed.

- **Why above generic:** Default Roblox locomotion is a one-dimensional WalkSpeed-threshold clip swap with no concept of relative direction (hence the classic moonwalk on sideways input). A continuous, direction-aware velocity driver is the architectural floor every higher system (foot IK, lean, sway) layers onto, and it is exactly what generic/AI builds omit.
- **Pass:** The system is driven by continuous planar velocity with BOTH a magnitude (speed) response and a direction (forward/strafe) component — e.g. an explicit 2D/velocity-keyed blend tree.
- **Partial:** A continuous-velocity driver is described but only on the speed axis (no direction/strafe component), or only direction with no continuous speed response.
- **Fail:** Movement is a WalkSpeed-threshold or single-scalar clip swap, or a single forward loop scaled by speed with no direction component (the default architecture).
- **Evidence required:** A description or spec of a runtime driver that reads continuous planar velocity (both magnitude and a forward-vs-strafe direction component) to select or weight motion — e.g. a 2D/velocity-keyed blend tree or a velocity-projected track weighting. A pure WalkSpeed-threshold or forward-loop-scaled-by-speed description does NOT count.
- **Concrete fix:** Replace the WalkSpeed-threshold clip swap with a velocity-driven movement system: read the live planar velocity, decompose it into forward/strafe components, and feed that vector into a blend tree or per-frame track weighting so both speed AND direction drive the pose.
- **Exemplar refs:** https://github.com/Roblox/creator-docs/blob/main/content/en-us/tutorials/use-case-tutorials/animation/play-character-animations.md, https://www.youtube.com/watch?v=sr34MYv35XU

### loco-vertical-bob-keyposes

Body motion is modulated by a tracked GAIT-PHASE signal at runtime, not just played back from a static clip. The candidate must show that the system maintains a notion of where the character is in the step cycle (gait phase / cycle position) and uses it to drive body motion (e.g. pelvis/hip oscillation, sway, or weight bias keyed to that phase). Default Roblox plays a baked clip with a fixed internal rhythm and tracks no phase variable the rest of the system can read — that is the FLOOR and earns nothing. To pass, gait phase must be an explicit runtime input that something downstream (pelvis sway, hip bias, body bob, or an effect) is computed from, proving the body's vertical/positional motion is phase-coupled rather than a sealed playback.

- **Why above generic:** A baked default clip has no externally-readable phase, so nothing downstream can react to the step cycle — the body just slides through a fixed loop. Exposing gait phase as a live driver is what lets weight, sway, and effects couple to the actual footfalls, the systems-level move generic playback can't do.
- **Pass:** Gait phase is an explicit runtime signal and at least one body motion (pelvis/hip sway, bob, or weight bias) is driven from it.
- **Partial:** Some phase-coupled body motion is implied but the gait-phase signal itself is not clearly a runtime input (could be fully baked).
- **Fail:** Body motion is sealed in a baked clip with no runtime gait-phase signal driving anything downstream (the default).
- **Evidence required:** Description/spec showing a runtime gait-phase (cycle-position) signal that drives some body motion — e.g. pelvis/hip sway or bob computed from gait phase. A baked clip with no phase variable exposed does NOT count.
- **Concrete fix:** Track a gait-phase value at runtime (from cycle time or footfall detection) and drive pelvis/hip oscillation or body bob from it, so vertical/positional body motion is computed from the live step phase rather than sealed in the clip.
- **Exemplar refs:** https://create.roblox.com/docs/tutorials/use-case-tutorials/animation/create-an-animation, https://www.youtube.com/watch?v=6lGPvMLE8Oo

### loco-contralateral-swing

The upper body is driven by a runtime layer DISTINCT from the leg/locomotion cycle, so arms/torso/head can move independently of the gait (not a single sealed clip where every limb is locked to one timeline). Default Roblox swings the opposite arm as part of the same baked walk clip — one timeline, no separable upper-body control — and that is the FLOOR (earns nothing). To pass, the candidate must describe a separate upper-body driver: an additive/aim/look-at layer, a torso layer driven by a runtime input (e.g. acceleration or gait phase), or independently-weighted upper-body tracks — anything that lets the upper body deviate from the canned arm-leg opposition under runtime control.

- **Why above generic:** In the default walk the upper body is welded to the leg timeline; it can't aim, lean, or react. A separate runtime upper-body layer (additive aim/look-at or accel/phase-driven torso) is the systems move that decouples upper-body expression from the gait — absent from any single canned cycle.
- **Pass:** A runtime upper-body layer separate from the leg/locomotion cycle is described (additive aim/look-at, or accel/phase-driven torso/sway).
- **Partial:** Upper-body motion beyond the bare default is implied but it is not clearly a separable runtime layer (could be baked into the clip).
- **Fail:** Upper body is locked to the single baked locomotion timeline with no separable runtime control (the default contralateral swing, nothing added).
- **Evidence required:** Description/spec of an upper-body driver separate from the locomotion clip — an additive aim/look-at layer, a runtime-input-driven torso layer, or independently-weighted upper-body tracks. The baked arm-swing inside the walk clip does NOT count.
- **Concrete fix:** Add a runtime upper-body layer on top of locomotion (additive aim/look-at via IKControl/priority, or a torso layer driven by acceleration/gait phase) so the arms/torso/head can move independently of the leg cycle.
- **Exemplar refs:** https://devforum.roblox.com/t/need-help-with-getting-this-walk-animation-more-realistic/525518, https://www.youtube.com/watch?v=6lGPvMLE8Oo

### loco-seamless-loop

Continuity between motion states is achieved by CONTINUOUS runtime weight-blending across overlapping tracks, not by hard clip swaps (nor merely by toggling the Looping property). Default Roblox hard-swaps idle/walk/run and snaps directional clips, producing seams the engine's default cross-fade only partly hides; a forward-only set with Looping toggled is the FLOOR and earns nothing. To pass, the candidate must describe a system where adjacent motions co-exist and are blended by weight (a blend tree / per-frame weighting), so transitions and the cyclic wrap are continuous-by-construction rather than discrete swaps that must each be seam-matched by hand.

- **Why above generic:** Hard clip swaps are the structural source of locomotion pops; the default cross-fade only masks them. A weight-blended blend space makes motion continuous by construction across both the cyclic wrap and state changes — the systems answer to seams that generic builds never adopt.
- **Pass:** Continuity is delivered by continuous runtime weight-blending across overlapping tracks (blend tree / per-frame weighting).
- **Partial:** Some blending/cross-fading beyond the default is described but the system still hard-swaps between major states (mixed).
- **Fail:** Motion states are hard clip swaps (or only the Looping property is toggled) with no continuous weight-blend architecture (the default).
- **Evidence required:** Description/spec showing adjacent motions co-existing and combined by runtime weight (blend tree / per-frame AdjustWeight), so transitions are continuous. Toggling Looping, or hard clip swaps, does NOT count.
- **Concrete fix:** Replace hard clip swaps with a weight-blended blend space where neighboring speed/direction tracks overlap and are combined by per-frame weight, making the loop wrap and all state changes continuous instead of discrete.
- **Exemplar refs:** https://github.com/Roblox/creator-docs/blob/main/content/en-us/tutorials/use-case-tutorials/animation/create-an-animation.md, https://mocaponline.com/blogs/mocap-news/locomotion-animations-game-dev

### loco-living-idle

Idle is a DISTINCT runtime state in the locomotion system (its own driven branch at zero velocity), not the moving clip held still or a single sealed pose. Default Roblox has a stock idle clip; merely shipping that, or holding a forward walk frame when speed=0, is the FLOOR (earns nothing). To pass, the candidate must show the velocity/movement driver treats the at-rest condition as its own state that blends in/out continuously (idle@0 in the speed axis of the blend system) AND that some runtime layer remains active at rest — e.g. the additive aim/look-at still tracks, or accel-driven posture settles — so the standing character is part of the same systemic driver rather than a dead fallback clip.

- **Why above generic:** Default idle is a dead fallback clip disconnected from the movement system; nothing reacts at rest. Treating idle as the zero-velocity branch of the same blend system, with additive layers still live, is the systems move that keeps the standing character coherent with everything else — generic builds drop to a sealed loop.
- **Pass:** Idle is a distinct zero-velocity branch of the movement driver that blends continuously, and at least one runtime layer stays active at rest.
- **Partial:** Idle is a separate state but it is a sealed/standalone clip with no runtime layer active at rest, or it blends but no at-rest layer is described.
- **Fail:** No idle handling in the system, or idle is the default stock clip / a held moving frame disconnected from the driver.
- **Evidence required:** Description/spec showing idle as the zero-velocity state of the movement driver that blends in/out continuously, with at least one runtime layer (aim/look-at, accel-driven posture) still active at rest. A standalone stock idle clip or a held walk frame does NOT count.
- **Concrete fix:** Model idle as idle@0 in the speed axis of the blend system so it cross-blends with walk continuously, and keep the additive layers (aim/look-at, accel posture) running at rest so the standing character stays driven by the same system.
- **Exemplar refs:** https://devforum.roblox.com/t/idle-animation-feedback/1325333, https://www.youtube.com/watch?v=6lGPvMLE8Oo

## Good (above the mean)

### loco-stride-locked-to-speed

Foot skate is eliminated by a RUNTIME foot-grounding pass (foot IK) layered over the clip, not by clip authoring alone and not by AdjustSpeed cadence-matching (which stock Animate already does). The decisive, gradable mechanism: a runtime IK system (IKControl or Motor6D.Transform) that holds/plants the foot to a world point — including on slopes and steps — so the planted foot does not slide. Default Roblox has NO foot IK and visibly skates on slopes; that is the explicit MEAN failure. To pass, the candidate must describe foot IK that grounds the feet to actual surfaces (slopes/steps), which is precisely what removes the residual position-skate the default cannot fix.

- **Why above generic:** Foot sliding is the #1 tell of generic locomotion, and the default has no IK to fix the residual skate its canned stride leaves. A runtime foot-grounding pass that pins feet to real surfaces is the mechanism that actually kills the slide — present in top systems, absent from default Roblox.
- **Pass:** A runtime foot-grounding pass (foot IK) holds feet to real surfaces including slopes/steps, removing skate.
- **Partial:** Foot IK is described but flat-ground-only or without slope/step grounding (some skate on uneven terrain remains).
- **Fail:** No runtime foot grounding; feet skate (the default — AdjustSpeed cadence alone does not satisfy).
- **Evidence required:** Description/spec of a runtime foot-grounding pass (IKControl or Motor6D.Transform) that plants the foot to a world point including on slopes/steps so it does not slide. AdjustSpeed cadence-matching alone, or clip-authoring claims with no runtime grounding, do NOT count.
- **Concrete fix:** Add a runtime foot-IK pass (IKControl per foot, or Motor6D.Transform offsets) that locks the planted foot to its ground contact through the stance phase, eliminating the lateral skate the cadence-matched clip alone leaves.
- **Exemplar refs:** https://devforum.roblox.com/t/how-to-make-animation-consistent-with-walkspeed/2713407, https://mocaponline.com/blogs/mocap-news/locomotion-animations-game-dev

### loco-directional-variant-set

A full 8-way directional clip set exists for each speed state -- forward, back (backpedal), left/right strafe, AND all four 45-degree diagonals -- as DISTINCT authored clips, not a forward clip rotated or two cardinals blended. Each clip is tagged with its LinearVelocity/direction so the runtime selects by actual velocity with smooth blending between adjacent diagonals; no moonwalk and no popping at diagonal headings. Mere forward/back/left/right cardinal coverage with velocity tagging does NOT pass: that is exactly what default Roblox ships for free via Players.UseStrafingAnimation (4 quadrants + LinearVelocity attribute). To beat the floor the set must deliver authored diagonal clips that default Roblox does not provide.

- **Why above generic:** Generic packs ship one forward walk + one forward run and rotate the whole character toward MoveDirection, producing the classic moonwalk on sideways/back input. Roblox itself shipped strafing+backpedaling as a default upgrade BECAUSE forward-only is the baseline. Covering all quadrants (plus diagonals), tagged for velocity selection, is an asset-coverage requirement a rubric checks directly.
- **Pass:** Distinct authored clips cover forward/back/left/right (and diagonals) per speed state; tagged so runtime selects by velocity; no moonwalk on any input direction.
- **Partial:** Backpedal + strafe exist but diagonals missing, OR variants exist but selection is incomplete so some directions still moonwalk.
- **Fail:** Single forward clip rotated onto all movement; character moonwalks when not heading forward.
- **Evidence required:** Clip inventory showing all directional variants per speed; capture of movement in each of the 4-8 directions showing the correct facing-vs-movement decoupling (no moonwalk).
- **Concrete fix:** Author forward/back/left/right (+diagonal) clips per speed state; tag each with its LinearVelocity/direction; wire selection off actual velocity so the right variant plays per direction.
- **Exemplar refs:** https://devforum.roblox.com/t/default-r15-player-animations-now-include-strafing-and-backpedaling-beta/1999236, https://mocaponline.com/blogs/mocap-news/locomotion-animations-game-dev

### loco-per-part-easing

Different body regions are driven by SEPARATE runtime layers that run independently of the base locomotion clip — so a part can ease/settle/track on its own schedule rather than every joint following one shared clip timeline. Default Roblox interpolates one walk clip smoothly across all joints on a single timeline; that uniform smoothness is the FLOOR (earns nothing). To pass, the candidate must describe at least one body region under an independent runtime driver distinct from the leg cycle — e.g. an additive aim/look-at layer on the upper body, or an accel/gait-phase-driven pelvis/torso layer — so the system applies differentiated motion per region instead of a single sealed interpolation.

- **Why above generic:** A single clip interpolated across all joints can never give a region its own timing or settle behavior. Splitting the body into independently-driven runtime layers is the systems precondition for differentiated motion (eased extremities, phase-coupled hips, tracking head) that generic single-clip builds structurally cannot produce.
- **Pass:** At least one body region is driven by an independent runtime layer distinct from the base clip (e.g. additive aim plus an accel/phase-driven pelvis layer).
- **Partial:** A single extra layer is implied but it is not clearly independent of the base clip timeline.
- **Fail:** All joints follow one shared locomotion-clip timeline with no independent per-region runtime layer (the default).
- **Evidence required:** Description/spec of at least one body region driven by an independent runtime layer distinct from the base locomotion clip (additive aim/look-at, or accel/gait-phase pelvis/torso layer). A single uniformly-interpolated clip does NOT count.
- **Concrete fix:** Decompose the body into separately-driven layers — keep legs on the base locomotion clip, run the upper body on an additive aim/look-at layer and the pelvis/torso on an accel/gait-phase layer — so each region moves on its own runtime schedule.
- **Exemplar refs:** https://devforum.roblox.com/t/feedback-on-my-walk-animation/2781799, https://www.youtube.com/watch?v=TMeQQYcB2Cg

### loco-foot-lift-roll-splay

Feet conform to the actual ground at runtime via a foot-grounding (IK) pass, instead of skimming through a fixed canned path. The gradable mechanism is a runtime IK system (IKControl/AnimationConstraint or Motor6D.Transform) that plants the foot on the real surface — on slopes and steps, not just flat ground. Default Roblox plays a flat canned foot path that skates on slopes (the explicit MEAN failure) and earns nothing. To pass, the candidate must describe feet that are corrected to world geometry at runtime (slopes/steps), which is what stops the foot from clipping/floating/skimming over uneven ground.

- **Why above generic:** Canned feet float over slopes and skim flat across steps because the clip ignores the world. Runtime foot grounding that conforms feet to actual surfaces is the most-cited realism technique and is entirely absent from default Roblox.
- **Pass:** Runtime foot grounding conforms feet to real surfaces on slopes AND steps (not just flat ground).
- **Partial:** Foot grounding is described but limited to flat ground or without surface conforming on slopes/steps.
- **Fail:** Feet follow a flat canned path and skim/skate on slopes (no runtime grounding — the default).
- **Evidence required:** Description/spec of a runtime foot-grounding pass (IKControl/AnimationConstraint or Motor6D.Transform) that plants feet on real surfaces including slopes and steps. A flat canned foot path, or flat-ground-only correction, does NOT count.
- **Concrete fix:** Add runtime foot IK that raycasts to the ground and plants/aligns each foot to the real surface on slopes and steps, replacing the flat canned foot path that skims over uneven terrain.
- **Exemplar refs:** https://devforum.roblox.com/t/feedback-on-my-walk-animation/2781799, https://www.youtube.com/watch?v=6lGPvMLE8Oo

### loco-blend-tree-speed-and-direction

KILLER SYSTEM -- BLEND TREE. Locomotion warps continuously by speed AND direction through a blend space, not hard clip swaps: a 1D speed axis (idle@0 -> walk -> jog -> run) crossfades adjacent speed tiers, and a 2D direction axis weights/averages the 8 directional variants by the live move vector. Direction is computed by projecting Humanoid velocity into HumanoidRootPart object space (CFrame:VectorToObjectSpace(velocity); X=strafe, Z=fwd/back, normalized by WalkSpeed) or via dot products of MoveDirection vs Look/Right vectors with thresholds. Per-frame AdjustWeight sets each track's weight from that vector (clamp to a small Epsilon, never exactly 0, to dodge the zero-weight replication bug) and AdjustSpeed matches cadence; same-priority tracks combine by weight so multiple play at once for a continuous gait.

- **Why above generic:** This is the headline killer system. Generic systems hard-swap idle->walk->run on a speed threshold and snap between directions, causing visible pops, and have no notion of relative direction at all (moonwalk). A velocity-driven 1D-speed + 2D-direction blend space with weight-blended same-priority tracks is the AAA locomotion blend tree adapted to Roblox -- continuous, pop-free movement at any speed/direction. The object-space projection + dot-product classification + Epsilon clamp are the concrete, gradable mechanisms.
- **Pass:** Both axes present: speed crossfades idle->walk->run with no threshold pop; direction blends the variant set by object-space/dot-product weighting; AdjustWeight+AdjustSpeed driven per-frame by live velocity; weights Epsilon-clamped (not 0); transitions are continuous at all speeds and directions.
- **Partial:** One axis only (e.g. speed blends but direction hard-switches, or directional blending exists but speed tiers snap) OR weights hit exactly 0 (replication bug risk).
- **Fail:** Hard clip swaps at fixed speed/direction thresholds with visible pops; one forward loop scaled by speed; no relative-direction computation.
- **Evidence required:** Capture of acceleration through idle->walk->run and of a direction sweep showing no pops; code/spec showing VectorToObjectSpace or dot-product classification feeding per-frame AdjustWeight (Epsilon-clamped) and AdjustSpeed across same-priority tracks.
- **Concrete fix:** Build a 1D speed blend (crossfade adjacent tiers by weight) and a 2D direction blend (weight the 8 variants by object-space velocity); drive weights per-frame via AdjustWeight from VectorToObjectSpace(velocity)/WalkSpeed or dot products; clamp weights to a tiny Epsilon; AdjustSpeed each track to cadence; keep locomotion tracks same-priority so they combine.
- **Exemplar refs:** https://mocaponline.com/blogs/mocap-news/locomotion-animations-game-dev, https://www.youtube.com/watch?v=aP_VzBxrPOA, https://devforum.roblox.com/t/8-way-directional-movement-system-for-r6-1-animation/2656069

### loco-foot-ik-terrain

KILLER SYSTEM -- FOOT IK. Feet plant on the actual ground, slopes, and steps via runtime IK layered on top of the canned clip (no skating, no floating). Use engine-native IKControl (parented under Animator; Type Transform, EndEffector=foot, ChainRoot=upper-leg, Target=downward-raycast hit, optional Pole for knee direction) OR Motor6D.Transform offsets -- the clip carries style, the IK pass only corrects feet to the world. Align the foot to the ray's surface NORMAL so it sits flat on slopes/stairs, raycast from the ANIMATED hip world CFrame (Part0.CFrame*C0 accounting for .Transform, not the rest skeleton), reject planting past a max slope (~45deg via acos(Normal:Dot(yAxis))), and blend the overlay with Weight/SmoothTime per movement state (e.g. standing Weight~0.75/SmoothTime~0.01, moving Weight~0.45/SmoothTime~0.001) so feet lock when planted but stay natural while moving.

- **Why above generic:** Second killer system and the most-cited showcase realism technique. Baked clips float over slopes/stairs and skate on uneven ground; most generic locomotion has no IK at all. World-influenced foot planting -- raycast from the animation-driven hip, surface-normal alignment, slope reject, and per-state Weight/SmoothTime modulation (not on/off) -- is what separates animation that ignores the world from animation that responds to it. IKControl is the modern supported path; the additive-over-clip layering keeps motion expressive AND grounded.
- **Pass:** Feet conform to slopes/steps via IKControl or Motor6D.Transform layered over the clip; foot aligns to surface normal; raycast originates from animated hip; slope-angle reject present; Weight/SmoothTime modulated per movement state so no snap/lock while moving.
- **Partial:** Foot IK exists but is flat-ground-only or surface-normal alignment missing (feet clip slopes), OR IK toggles fully on/off causing snap, OR raycast uses rest skeleton not animated hip.
- **Fail:** No IK; canned feet float above slopes/steps and skate on uneven ground.
- **Evidence required:** Capture on a slope and on stairs showing both feet grounded and angled to the surface; IKControl instance dump (EndEffector/ChainRoot/Target/Pole) or Motor6D.Transform correction, plus the raycast-from-hip + slope-reject + per-state Weight/SmoothTime logic.
- **Concrete fix:** Add IKControl per foot under the Animator (Transform type, ChainRoot=upper leg, Target from a downward raycast off the animated hip CFrame); align EndEffector to the ray normal; reject surfaces past ~45deg; modulate Weight/SmoothTime by movement state; or apply equivalent Motor6D.Transform offsets as an additive layer over the clip.
- **Exemplar refs:** https://github.com/Roblox/creator-docs/blob/main/content/en-us/reference/engine/classes/IKControl.yaml, https://devforum.roblox.com/t/prototype-r15-animation-ikcontrol-footplant/2187090, https://devforum.roblox.com/t/free-r15-ikpf-system-inverse-kinematics-procedural-footplanting/706574

### loco-additive-lookat-aim

KILLER SYSTEM -- ADDITIVE LOOK-AT / AIM. An additive look-at/aim layer rides ON TOP of the running locomotion (head/torso/arms orient toward a target or aim direction) without stopping or replacing the gait. Implemented via an IKControl aim chain or via AnimationPriority (locomotion on Movement/Idle; the aim/action track on Action+ so the highest-priority track wins ONLY the conflicting limbs while the legs keep walking underneath; equal priorities blend by weight). AnimationConstraint can drive the aim joints procedurally (Kinematic snap or force-based with MaxForce/MaxTorque, applied as a deferred batch after PreSimulation).

- **Why above generic:** Third killer system. Generic code STOPS the walk track to play an action/aim then restarts it -- jarring and bug-prone -- because it doesn't use the priority ladder. Layering an additive aim/look-at over locomotion (via IKControl aim or the Core<Idle<Movement<Action priority order with equal-priority weight-blend) so only the upper body re-orients while the legs keep their gait is a top-studio touch absent from any single canned cycle.
- **Pass:** Upper body orients to a look/aim target while locomotion keeps running uninterrupted; achieved via IKControl aim chain or correct AnimationPriority layering (Movement under Action) / AnimationConstraint, so only conflicting limbs are overridden.
- **Partial:** Aim works but stops/restarts the walk track, OR overrides the whole body instead of just the upper limbs.
- **Fail:** No look-at/aim layer; or the gait is killed whenever the character looks/aims.
- **Evidence required:** Capture showing the character walking while the head/arms track a moving target without the legs stuttering; track-priority dump (locomotion=Movement, aim=Action+) or an IKControl aim chain / AnimationConstraint driving the upper body.
- **Concrete fix:** Add an IKControl aim chain for the head/arms OR play the aim track at Action priority over Movement-priority locomotion so it overrides only the conflicting limbs; for procedural aim use an AnimationConstraint (kinematic or force-based) layered over the clip; never Stop() the walk track to aim.
- **Exemplar refs:** https://github.com/Roblox/creator-docs/blob/main/content/en-us/reference/engine/classes/AnimationTrack.yaml, https://github.com/Roblox/creator-docs/blob/main/content/en-us/physics/constraints/animation.md, https://devforum.roblox.com/t/inverse-kinematics-control-instance-for-animation-is-now-in-beta/1999010

### loco-fadetime-transitions

State changes are CONTINUOUS runtime blends produced by the movement driver, not discrete clip swaps (and not merely the engine's default 0.1s cross-fade). Default Roblox hard-swaps idle/walk/run on WalkSpeed and instant-flips directional clips, relying only on the stock fade — that is the FLOOR (earns nothing). To pass, the candidate must describe a system where moving between speeds and/or directions happens by continuously re-weighting overlapping tracks driven by live velocity (a blend tree / per-frame weighting), so there is no discrete swap to snap — transitions, including direction changes, are absorbed by the blend space itself.

- **Why above generic:** Discrete clip swaps are the structural cause of transition snaps; the default fade only masks them and direction reversals still flip instantly. A velocity-driven blend space dissolves transitions into continuous re-weighting, so there is no discrete swap to hide — the systems answer generic builds never adopt.
- **Pass:** Transitions across speed AND direction are continuous re-weightings within a live-velocity blend space (no discrete swaps).
- **Partial:** Speed transitions blend continuously but direction changes still hard-swap (or vice versa).
- **Fail:** Transitions are discrete clip swaps relying on the engine's default fade (the default architecture).
- **Evidence required:** Description/spec showing transitions handled by continuous live-velocity re-weighting of overlapping tracks (blend tree / per-frame weighting), covering speed AND direction changes. A non-zero fadeTime, or hard swaps with the default fade, do NOT count.
- **Concrete fix:** Drive transitions through the blend space: re-weight overlapping speed/direction tracks per frame from live velocity so moving between states (including direction reversals) is a continuous blend rather than a discrete clip swap to fade over.
- **Exemplar refs:** https://github.com/Roblox/creator-docs/blob/main/content/en-us/reference/engine/classes/AnimationTrack.yaml, https://devforum.roblox.com/t/hyper-realistic-animations-opensource/2087876

## Exceptional (polish)

### loco-pelvis-hip-sway-gait-phase

KILLER SYSTEM -- PELVIS BIAS / HIP SWAY. The pelvis counter-rotates against the legs like a scale and sways tied to gait phase: the lifted-leg side pulls the opposite hip DOWN, hips straighten at Pass, flip at the next Contact, and a side-to-side sway layers on so a tracked hip traces a figure-8 (on R15 this is the LowerTorso joint). The bias/lean also responds to acceleration -- pelvis/hips lean forward on accel, into the curve on turns, back on hard stops -- and the run is re-posed (not a sped-up walk): wider foot split, legs reach further back, deeper Down drop, a true AIRBORNE frame (both feet off ground, only in a run), arms swing INWARD to balance the wider throw and a touch slower than 1:1 with leg speed so the body leads the arms.

- **Why above generic:** Fourth killer system. The R15 LowerTorso/UpperTorso split exists precisely to allow hip counter-rotation, but default and AI walks leave the hips rigid -- the figure-8 hip path tied to gait phase is a recognized pro tell. Tying the bias to acceleration (not baked into one clip) makes starts/stops/turns feel weighted. Re-posing the run with an airborne frame and inward/slower arms (vs the 'drag keyframes closer' shortcut) is beyond what generic run cycles attempt.
- **Pass:** Hip traces a figure-8 (counter-rotation + sway) keyed to gait phase via LowerTorso; pelvis bias responds to accel/turn/stop; run is distinctly re-posed with an airborne frame and inward, slightly-slower arms.
- **Partial:** Hip sway present but not phase-locked or not accel-responsive, OR run has wider stance but no true airborne frame / arms just sped up.
- **Fail:** Rigid hips (no counter-rotation/sway); run is just the walk played faster with no airborne frame.
- **Evidence required:** Hip-position trace over a cycle showing a figure-8; capture of a turn/hard-stop showing pelvis lean reacting to acceleration; run capture showing a frame with both feet off the ground and arms swinging inward.
- **Concrete fix:** Counter-rotate LowerTorso against the legs and add side-to-side sway keyed to gait phase (figure-8); drive an additive pelvis lean from acceleration/turn direction; re-pose the run from scratch with wider split, deeper drop, an airborne frame, and inward arms timed slightly behind the legs.
- **Exemplar refs:** https://www.youtube.com/watch?v=6lGPvMLE8Oo, https://devforum.roblox.com/t/r15-animations%F0%9F%93%9E/2879405

### loco-velocity-lean-additive

An additive velocity/acceleration-driven lean rides on top of locomotion at runtime (not baked into a clip): tilt the root + hips toward the move direction proportional to how far movement deviates from facing -- computed via dot/cross of velocity vs look vector -- capped around 10deg (math.rad(value*10)) and Lerp-smoothed (~0.2) so it eases in/out. Lean forward on acceleration, into the curve on turns, back on hard stops. Pair with a velocity-driven camera bank (roll proportional to RightVector:Dot(MoveDirection), Lerped each RenderStep ~0.075) so the view banks into strafes/turns.

- **Why above generic:** A working DevForum implementation drives root/hip rotation by velocity-vs-facing dot products, scales by math.rad(value*10) and Lerps at 0.2. An additive lean reacting to LIVE velocity (vs a static baked tilt) makes turns and starts/stops feel weighted, and a velocity-driven camera bank is a cheap high-perceived-quality game-feel layer -- both absent from any static cycle.
- **Pass:** Root/hip lean is computed from live velocity-vs-facing each frame, capped (~10deg) and Lerp-smoothed, leaning forward on accel / into turns / back on stops; optional camera bank tracks lateral movement.
- **Partial:** Lean exists but is baked into a clip (not velocity-driven) OR not smoothed/capped (snappy/overshoots), OR no camera bank where it would help.
- **Fail:** No additive lean; turns and starts/stops read weightless and flat.
- **Evidence required:** Capture of a turn and a hard stop showing the body lean reacting to velocity direction; code/spec showing dot/cross of velocity vs look vector feeding a capped, Lerp-smoothed root/hip rotation (and optionally camera roll).
- **Concrete fix:** Each frame, compute the deviation of velocity from facing via dot/cross, map to a capped (~10deg) rotation on the root/hips, Lerp toward it (~0.2); apply camera roll from RightVector:Dot(MoveDirection) Lerped each RenderStep.
- **Exemplar refs:** https://devforum.roblox.com/t/running-animation-tiltinglean/1876447, https://devforum.roblox.com/t/camera-tilt-based-on-movement/1895725

### loco-marker-synced-fx

A runtime CONTACT/gait-phase signal exists that downstream effects or systems can fire off — i.e. the system knows when each foot lands, exposed as a live event/phase rather than a fixed timer. Default Roblox exposes no such per-contact signal usable by the rest of the system; timer-based or absent footstep effects are the FLOOR (earns nothing). To pass, the candidate must show the locomotion system surfaces foot-contact / gait-phase as a runtime signal (keyframe markers + GetMarkerReachedSignal, or a footfall detection tied to gait phase) that something consumes and that stays correct as playback speed scales.

- **Why above generic:** Timer-fired effects drift the moment playback speed scales, and a sealed clip exposes no contact event at all. Surfacing foot-contact/gait-phase as a live runtime signal is the systems precondition for speed-correct footstep effects (and other phase-locked behavior) that generic builds lack.
- **Pass:** A runtime contact/gait-phase signal is exposed and consumed (markers+GetMarkerReachedSignal or phase-derived footfalls), staying synced under speed scaling.
- **Partial:** A gait-phase signal exists in the system but is not shown to drive any contact-synced effect/event.
- **Fail:** No runtime contact/gait-phase signal; effects would be timer-based or absent (the default sealed clip).
- **Evidence required:** Description/spec showing a runtime foot-contact / gait-phase signal that downstream logic can consume (keyframe markers + GetMarkerReachedSignal, or footfall detection from gait phase) and that stays synced under speed scaling. Timer-based or absent effects do NOT count.
- **Concrete fix:** Place named Contact markers on the gait clips and fire effects via GetMarkerReachedSignal (or derive footfalls from the tracked gait phase), so footstep SFX/VFX lock to actual contacts at any playback speed.
- **Exemplar refs:** https://github.com/Roblox/creator-docs/blob/main/content/en-us/animation/using.md

### loco-accel-decel-momentum

ACCELERATION is a tracked runtime input that drives motion — the system reads how the character is speeding up / slowing down / turning and feeds that into the pose (lean, pelvis bias, or a speed ramp), so starts/stops/turns read as weighted. Default Roblox snaps to full WalkSpeed and stops dead with no acceleration signal anywhere in the animation system; that is the FLOOR (earns nothing). To pass, the candidate must describe acceleration (or a derived momentum/speed-ratio) as a live driver that some motion is computed from, proving the system responds to momentum rather than only to instantaneous speed.

- **Why above generic:** Default movement has no acceleration concept in its animation — it teleports between speed and stop, the hallmark weightless feel. Making acceleration a live driver of lean/bias/ramp is what gives starts, stops, and turns their weight, and no canned clip can supply it.
- **Pass:** Acceleration (or a derived momentum/speed-ratio) is a tracked runtime input driving at least one motion (lean, pelvis bias, or speed ramp).
- **Partial:** Momentum/weighting is implied but driven only by instantaneous speed, not by an acceleration/delta term.
- **Fail:** No acceleration signal; movement snaps to speed and stops dead (the default).
- **Evidence required:** Description/spec showing acceleration (or a derived momentum/speed-ratio) tracked at runtime and driving some motion (lean, pelvis bias, or a movement-speed ramp). Instant snap-to-speed / dead-stop, or speed-only with no acceleration term, do NOT count.
- **Concrete fix:** Track acceleration (delta of velocity) or a ramped speedRatio at runtime and feed it into the pose — lean forward on accel, back on hard stops, into turns — and/or ramp the movement speed itself so starts and stops ease.
- **Exemplar refs:** https://devforum.roblox.com/t/creating-heavy-character-movement-beginner-tutorial-acceleration-and-deceleration/3157702, https://devforum.roblox.com/t/hyper-realistic-animations-opensource/2087876

### loco-hip-height-terrain

The rig RESPONDS TO TERRAIN GEOMETRY at runtime — the system reads the actual ground under the feet (slopes, steps, uneven surfaces) and adjusts the body so feet stay grounded, rather than playing a clip authored for flat ground. The gradable mechanism is a runtime terrain-aware pass: foot IK that conforms feet to slopes/steps (and ideally a complementary root/hip-height adjustment from the foot-height difference). Default Roblox is terrain-blind — it plays the flat clip and skates on slopes (the explicit MEAN failure) — and earns nothing. To pass, the candidate must describe the locomotion responding to real ground geometry at runtime (feet grounded on slopes/steps).

- **Why above generic:** A flat-authored clip ignores the world entirely — it floats and skates on any incline. Reading real ground geometry at runtime to keep feet grounded (foot IK, plus hip-height for both feet) is the terrain-responsive systems layer default Roblox completely lacks.
- **Pass:** The system responds to real terrain at runtime — feet are grounded on slopes/steps via foot IK; ideally root/hip height also adjusts to keep both feet planted.
- **Partial:** Foot grounding on terrain is described but with no complementary hip-height adjustment, so legs would lock/stretch on steep ground.
- **Fail:** Terrain-blind: flat clip plays regardless of ground, feet skate on slopes (the default).
- **Evidence required:** Description/spec of a runtime terrain-aware pass: foot IK conforming feet to slopes/steps (pass), and/or root/hip-height adjustment computed from the foot-height difference to keep both feet grounded (exceptional). A flat-ground clip with no terrain response does NOT count.
- **Concrete fix:** Add a runtime terrain-aware pass: foot IK that grounds each foot to the real surface on slopes/steps, and lower/raise the root from the two feet's height difference so both stay planted with natural knee bend.
- **Exemplar refs:** https://devforum.roblox.com/t/free-r15-ikpf-system-inverse-kinematics-procedural-footplanting/706574

### loco-personality-cog

Body posture (center-of-gravity / lean / pelvis bias) is a TUNABLE RUNTIME OFFSET LAYER applied on top of locomotion, not a fixed emotionally-neutral default. Default Roblox motion is centered and neutral with no posture offset anywhere in the system; that is the FLOOR (earns nothing). To pass, the candidate must describe a deliberate, runtime-driven posture layer — a lean and/or pelvis/COG bias driven by inputs like acceleration, turn direction, or gait phase — that shapes how the movement reads. (At the exceptional ceiling this bias is tuned to express a specific character/tone; at minimum it must be a real, present, runtime posture layer rather than baked-neutral motion.)

- **Why above generic:** Default locomotion is posture-neutral and centered — it has no lean, no COG bias, no character. A runtime posture-offset layer (accel/turn/phase-driven lean and pelvis bias) is what gives movement weight and, tuned further, identity — a high-ceiling craft move absent from generic builds.
- **Pass:** A real, runtime-driven posture/COG layer (accel/turn/phase-driven lean and/or pelvis bias) is applied over locomotion.
- **Partial:** Some posture offset is implied but it is baked/static rather than a runtime-driven layer, or it is present but generic-neutral.
- **Fail:** Emotionally-neutral, centered default motion with no posture/COG layer (the default).
- **Evidence required:** Description/spec of a runtime posture/COG layer — lean and/or pelvis/COG bias driven by acceleration, turn, or gait phase — applied over locomotion (pass). A consistent bias tied to an intended character/tone with rationale earns the exceptional ceiling. Baked-neutral, centered motion does NOT count.
- **Concrete fix:** Add a runtime posture-offset layer: drive a lean and pelvis/COG bias from acceleration/turn/gait-phase, and tune its direction and depth to express the game's intended movement character.
- **Exemplar refs:** https://www.youtube.com/watch?v=6lGPvMLE8Oo

### loco-retarget-rig-portability

The locomotion system is built as RUNTIME CORRECTION/ADDITIVE LAYERS DECOUPLED FROM THE BASE CLIP — style lives in the clip, while grounding (foot IK), posture (lean/pelvis bias), and aim run as separate runtime layers on top. This clip-agnostic layering is the precondition for portability: because the correction layers are computed from world/velocity (not hand-keyed into a specific clip set), the SAME layers ride over different clips/rigs. Default Roblox is a single sealed clip set with no separable correction layer; that is the FLOOR (earns nothing). To pass, the candidate must describe the locomotion as clip + independent runtime layers (foot IK / accel-driven posture / additive aim) rather than one baked, rig-specific clip set.

- **Why above generic:** A single sealed clip set is welded to one rig and one style — any new body type needs re-animation. Splitting locomotion into a style clip plus world/velocity-driven correction layers (foot IK, posture, aim) makes those layers clip- and rig-agnostic, the structural basis of reuse across rigs that generic single-clip builds can't offer.
- **Pass:** Locomotion is described as a base clip plus independent, world/velocity-driven runtime layers (foot IK, posture, aim) decoupled from the clip — the clip-agnostic basis for portability.
- **Partial:** One correction layer is decoupled but the rest of the system is still a sealed clip set, or layering is implied but not clearly clip-agnostic.
- **Fail:** A single baked, rig-specific clip set with no separable runtime correction layer (the default).
- **Evidence required:** Description/spec showing locomotion as a base clip PLUS independent runtime correction/additive layers (foot IK, accel/phase posture, additive aim) computed from world/velocity rather than baked per-clip — i.e. layers that could ride over different clips/rigs. (A HumanoidRigDescription/T-pose mapping or R6/R15 sign branch is additional credit.) A single baked, rig-specific clip set does NOT count.
- **Concrete fix:** Architect locomotion as a style clip plus decoupled runtime layers (foot IK, accel-driven posture, additive aim) computed from world/velocity, so the same correction layers apply across clips/rigs; add a HumanoidRigDescription mapping and R6/R15 sign handling for full retargeting.
- **Exemplar refs:** https://github.com/Roblox/creator-docs/blob/main/content/en-us/characters/adaptive-animation.md, https://www.youtube.com/watch?v=aP_VzBxrPOA
