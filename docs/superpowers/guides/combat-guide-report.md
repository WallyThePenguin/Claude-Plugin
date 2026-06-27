# Build guide report: combat (v1.0)

Generated 2026-06-27 by the `train-recipe` factory; targets the combat rubric (v1.0).

## Coverage
- Rubric criteria addressed: **29 / 29**
- Steps: 25 across 3 tiers
- Uncovered criteria: none

## Completeness review
- Killer systems covered: anticipation-and-impact-hitstop, directional-hit-reactions-and-knockback, marker-synced-active-frames-and-impact-fx, cancelable-combo-and-buffer-windows, attack-layered-over-locomotion
- Killer systems missing: none
- Build order sound: True

### Assessment
COVERAGE OF THE 5 KILLER SYSTEMS — all 5 appear as explicit, depth-committed build steps (not gestured at):

1. anticipation-and-impact-hitstop — COVERED by g1 + g3. g1 builds the timing-asymmetry skeleton (loaded windup accelerating from near-still, single readable peak CONTACT pose, follow-through drag, settle) and g3 fires a strength-SCALED hitstop off the Contact marker via AdjustSpeed DIP (not AdjustSpeed(0)) on attacker+victim tracks ONLY while camera/particles/world keep running, FireAllClients-synced, each client ramping only the track it owns. Both halves the rubric (anticipation-load-and-impact-hitstop) demands are present, including the world-keeps-moving failure-mode guard and the per-owner replication nuance.

2. directional-hit-reactions-and-knockback — COVERED by g4 (reaction half) + g6 (knockback half). g4 derives the front/side/back flinch from VectorToObjectSpace every hit, plays it ADDITIVELY at Action3 so it never cancels the attacker's swing, grades by force, brief/interruptible with fadeTime crossfade. g6 pushes the victim along the per-hit hit vector via ApplyImpulse / short-lived LinearVelocity+Attachment (modern movers, not BodyVelocity), advances the attacker to stay in combo range, applied SERVER-side and magnitude-bounded. Maps cleanly to directional-additive-hit-reaction + coherent-knockback-modern-mover.

3. marker-synced-active-frames-and-impact-fx — COVERED by b4 + b5 (active-frame half) + g7 (FX half). b4 bakes named HitStart/HitEnd/Contact/CancelOpen markers and forbids wait()/task.delay/track.Length gating; b5 gates the swept hitbox to the HitStart→HitEnd window (DEAD in windup/recovery), raycasts between previous/current attachment positions to defeat tunneling, with an alreadyHit dedup set; g7 fires the multi-channel stack (Enabled=false emitters + per-child :Emit, subtle spring camera shake, contact-point burst, Debris-clean) off the single Contact marker, client-side-immediate. Strong coverage of swept-active-frame-hitbox-no-touched + marker-synced-impact-fx-stack.

4. cancelable-combo-and-buffer-windows — COVERED by g8 + g9. g8 builds the connected pose-graph (clip N's final pose re-keyed identical to clip N+1's opening pose, proven by capture filmstrip across the cut, distinct silhouettes preserved, escalating finisher, arm-scoped over locomotion, and an explicit fadeTime crossfade fix to the stock no-fade runtime). g9 adds the buffered state machine (exactly ONE queued press cleared on every state change, auto-fired on the CancelOpen marker, debounce, and the DUAL reset: finisher+cooldown AND the task.spawn count-snapshot idle watcher). Directly satisfies combo-state-machine-with-input-buffering + connected-combo-chain-flowing-poses, including the marker-gated (not Length-math) requirement.

5. attack-layered-over-locomotion — COVERED by b2 + b6 (+ e8 at runtime). b2 authors the attack arm-scoped to ride over a lower-priority Movement layer and refuses to re-author walk/run as the deliverable; b6 makes four tracks coexist with explicit per-clip priority (attack Action4, hit-react Action3, dodge Action2, locomotion Movement), zero leg keyframes in the attack, AdjustWeight blend + non-zero fadeTime crossfade, and VERIFIES the move-while-swinging and flinch-doesn't-cancel outcomes rather than assuming them. e8 proves the runtime weighted-track coexistence on a live rig. Satisfies attack-layered-over-locomotion (and feeds the priority baseline the other killers depend on).

BUILD-ORDER SOUNDNESS — the order is sound; dependencies precede dependents at every load-bearing seam:
- Rig FIRST (b1) before any posing/code, with the correct Avatar-Joint-Upgrade Motor6D-vs-AnimationConstraint guard — the right base.
- Markers (b4) are authored BEFORE every consumer: the swept hitbox (b5), hitstop (g3), FX stack (g7), combo cancel window (g9), and server validation (e5) all read markers that b4 establishes.
- Hit detection (b5) precedes everything that fires "on a confirmed hit": hitstop (g3), knockback (g6), FX (g7).
- The priority-layering baseline (b6) precedes its dependents: the Action3 additive flinch (g4) and the attack-over-locomotion / runtime-blend work (e8) both rely on it; b6 is correctly positioned before them.
- The stance state machine (b3) precedes the combo state machine (g9), which extends it.
- Critically, the impact-bus refactor (e1) — which "replaces the independently-fired channels" — comes AFTER the independent channels it consolidates (b7 audio, g3 hitstop, g6 knockback, g7 FX). Refactoring after the parts exist is the correct sequencing.
- Defensive layer (e3), graded/poise reactions (e2), data-driven table (e6), enemy brain (e7), and the runtime IK/blend/foot-plant/secondary-motion stack (e8) all sit last and explicitly build on earlier seams (the cancelable-window machinery, the strength scalar, make_npc, the locomotion-driven legs). No dependent precedes its dependency.
Minor note (not a violation): b3 wires the state CHANNEL (ItemState attribute + StateChanged) and combat-stance gating before markers are baked in b4; the marker-driven TIMING is layered in at b4 and consumed downstream (g9, e5), so b3's pre-marker placement is fine because its gate is state-based ("in stance, not Stunned"), not marker-timed damage.

OVERALL — If followed faithfully, this guide produces an above-the-mean build that clears the rubric at full coverage. Every one of the 29 criteria has a corresponding build step that commits to the discriminating, above-generic axis the rubric keys on (markers-not-timers, active-frame-window-not-Touched, additive-Action3-not-cancel, strength-scaled-bus, server-authoritative consequence, runtime-blended-not-baked, poise/parry/lag-comp/data-table/behavior-brain at the exceptional ceiling). The guide also repeatedly bakes in self-rejection clauses ("reject your own output if…", "verify, don't assume", capture-and-confirm) that target the exact PARTIAL→PASS gaps the rubric warns about (e.g. world-keeps-moving during hitstop, flinch-doesn't-cancel-attacker, pose continuity proven on capture, dual combo reset, scope-honesty so steps don't over-claim IK they didn't build). The mapping is 1:1 across all 5 killer systems with both halves of each split system (reaction+knockback, active-frames+FX, pose-continuity+buffering, anticipation+hitstop) explicitly authored. No killer system is missing or merely gestured at, and the dependency ordering is correct.

## Provenance
- Sweep angles: workflow, killer-impl, pitfalls, video
- Techniques gathered: 45
- Coverage-fill rounds: 0
