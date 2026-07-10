# Roblox Oracle — red-team stress test (2026-07-10)

Six parallel adversarial reviews of the SP2 "Roblox Oracle" concept (a live symbolic assertion layer over the engine), each assuming a maximally complex game. Produced during the 2026-07-10 design session; consumed by the future SP2 spec.

---

# DOMAIN: meta-adversary

# Attacking the Oracle: How a Live Symbolic Assertion Layer Lies

Frame: the oracle is a *witness*, not the truth. Every failure below is a case where the oracle returns green (or returns *something*) while the shipped game is broken — and where today's screenshot habit would either miss it too or cost 30x tokens to catch. Severity scale: **CRIT** (players see it immediately / progress-blocking), **HIGH** (visible or exploitable), **MED** (degrades over time or on some devices).

---

## 1. FAILURE CATALOG

### F1 — The edit-mode pose that physics destroys (unwelded sword) — **CRIT**
**What's wrong.** Agent builds a sword, positions blade+guard+hilt into a perfect assembly, welds nothing (or a WeldConstraint's Part1 is nil because a rename broke the reference). In edit mode `intersects(blade, guard) == touching`, `gap_between(hilt, guard) == 0.02`, `axis_of(blade) · up == 0.999`. All green. On play, physics steps: the unanchored blade separates from the hilt, falls through the baseplate, and the player holds a stick.
**Why the oracle lies.** Edit-mode CFrames are *authored positions*, not *constrained positions*. No solver has run. Geometry queries are answering "where did you put it," not "where will it stay." This is the single most dangerous class: every geometric assertion is EDIT-valid and PLAY-false simultaneously.
**Today.** A playtest screenshot catches it (blade missing) — for ~1500 tokens and only if the capture angle happens to show the hand.
**Countermeasure (spec-mandatory).** Every assertion carries a **validity-domain tag** (`EDIT_OK`, `PLAY_ONLY`, `EDIT_MISLEADS`). Geometric assembly checks on unanchored parts auto-escalate: the oracle must refuse to return plain PASS in edit mode for physics-class properties — it returns `PASS(edit) — REQUIRES runtime confirm` and the suite is not green until the runtime twin ran. Add `joint_integrity(model)` that verifies the *constraint graph* (every part reachable from the root via active Weld/Motor6D/WeldConstraint with non-nil Part0/Part1, no orphan unanchored parts), which IS edit-valid because it checks topology, not positions.

### F2 — The server oracle is blind to the client's game — **CRIT**
**What's wrong.** HUD is built by a LocalScript (as all client UI should be). The oracle runs via `run_luau` in the server/edit DataModel: `gui_overlap(healthbar, minimap)` returns "no such instance" → skipped → suite green. On a real client the healthbar covers the minimap. Same class: character position under client network ownership (server sees the ragdoll 3 studs from where the client renders it), client-side VFX, camera scripts, Animator replication.
**Why the oracle lies.** There is no single DataModel. The question "does the healthbar overlap the minimap" is only *defined* on a client replica. A server-context oracle answering GUI questions is answering questions about a world no player inhabits.
**Today.** Playtest screenshot catches GUI overlap — but only at one resolution, one moment.
**Countermeasure.** Every query takes a mandatory `context = edit | server | client(playerN)` argument; the SP2 spec must include a **client-side oracle runner** injected into playtests (a LocalScript agent that executes the same assertion vocabulary and reports back through the bridge). Any GUI/camera/character-position assertion issued in server context is a **hard error**, not a skip.

### F3 — Point-in-time queries miss drift, oscillation, and races — **HIGH**
**What's wrong.** (a) NPC pathfinding replans every 0.2s and oscillates between two waypoints — at any sampled instant `distance_to(npc, waypoint) < 5` passes; the NPC vibrates in place forever. (b) A vehicle's suspension is under-damped; at t=2s it sits at correct height (`gap_between(chassis, ground) ≈ 0.5` ✓); by t=60s accumulated solver drift has sunk a wheel through the terrain. (c) Loot spawner fires before the inventory DataStore module finishes loading — the agent's post-load query sees a populated inventory because *its own query* ran after everything settled; the race only bites players who join fast.
**Why the oracle lies.** A predicate over instantaneous state cannot represent a *trajectory* property. The oracle samples the one moment when the lie is locally true. Races are worse: the act of querying "after setup" selects the ordering that hides the bug.
**Today.** Screenshots are also point-in-time; catching oscillation needs `capture_animation` (many frames, huge tokens) and still won't see the DataStore race at all.
**Countermeasure.** First-class **temporal assertions**: `stable_over(expr, duration, tol)` (value stays within band), `settles(expr, target, deadline)`, `monotonic(expr, window)`, `oscillation(expr, window) → amplitude+freq`. Implemented as cheap Luau samplers (Heartbeat-driven, N samples, return summary stats — still ~50 tokens out). For races: `load_order(moduleA, before=moduleB)` and a spec rule that any spawn/init assertion must run with `join_simulation(early|late)` variants, not once.

### F4 — Epsilon traps: "not intersecting" at 1e-4, "aligned" at 0.9999 — **HIGH**
**What's wrong.** (a) Two wall panels coplanar within 0.0001 studs: `penetration_depth == 0.0001 < eps` → "fine." Players see full-screen z-fighting flicker, the most amateurish artifact in Roblox. (b) `axis_of(wall) · axis_of(adjacentWall) = 0.9998` → "parallel." Over a 200-stud fortress wall, that 1.1° error opens a visible 4-stud wedge gap at the far end. The dot-product epsilon is scale-blind.
**Why the oracle lies.** Booleans thresholded on fixed epsilons invert the failure mode: coplanarity is *bad* at tiny separations (z-fight) and alignment error is *bad* proportional to length. A single global epsilon cannot encode "0.0001 is a failure here and a pass there."
**Today.** Z-fighting is visible in a screenshot only if the camera flickers on that frame; skew of 1° is exactly what visual judgment is worst at.
**Countermeasure.** (1) Assertions return **raw magnitudes + verdict**, never bare booleans — the agent (and the learnings store) sees `depth=0.0001, verdict=ZFIGHT_RISK`. (2) Per-assertion **calibrated epsilon tables** in the spec (coplanar-but-not-identical range flagged as its own failure class `coplanar_zfight(a,b)`). (3) Alignment is reported as **end-to-end deviation in studs** (`skew_studs = length × sin θ`), so the check scales with the geometry it judges.

### F5 — Bounding box ≠ collision ≠ render mesh — **HIGH**
**What's wrong.** A CC0 tree MeshPart has one stray vertex 40 studs above the canopy; its bbox is a skyscraper. `intersects(tree, house)` fires false-positive; agent "fixes" it by moving the tree 30 studs, ruining the composition. Inverse case: rock MeshPart with `CollisionFidelity=Box` — `gap_between(rock, ground)` via collision geometry says 0.0, but the *render mesh* is concave and visibly floats on two contact corners. Skinned meshes are worst: bone deformation moves the rendered skin but ExtentsSize doesn't follow, so `arc_of(swordTip, clip)` computed from part extents measures a sword that isn't where the pixels are.
**Why the oracle lies.** There are three geometries per part (bbox, collision hull, render mesh) and they disagree by design. Any query that silently picks one answers a different question than the agent asked.
**Today.** Screenshot actually wins here — floating rocks are visible. This is a case where the oracle, naively built, is *worse* than today.
**Countermeasure.** Mandatory `geometry = bbox | collision | render` argument — no default; the spec forbids defaulting. Add `bbox_sanity(part) → ratio of bbox volume to render-mesh volume` to flag stray-vertex meshes on import. For render-geometry queries, implement raycast sampling against the visual mesh (`RaycastParams` + surface sampling) as the ground-truth path, with cost warnings (see F7). For skinned meshes: sample **bone/attachment world CFrames**, never part extents (`arc_of` must take an Attachment, not a Part).

### F6 — Streaming makes absence look like success — **CRIT**
**What's wrong.** StreamingEnabled experience. Client-context oracle asserts `anchored_ok(CastleGate)` — the gate isn't streamed in at the player's position → instance nil → the assertion "can't fail" → suite green. Meanwhile the actual bug is that the gate's model exceeds the streaming radius budget and *never streams in* for low-memory clients: players walk into an invisible wall (server collision) around a castle they cannot see.
**Why the oracle lies.** Vacuous truth. `nil` instances make every property predicate trivially non-failing unless the framework treats absence as its own verdict. And absence is itself sometimes the bug under test.
**Today.** Only catchable by a playtest screenshot *from a streaming-limited client* — which the current harness never emulates.
**Countermeasure.** **Three-valued logic is non-negotiable in the spec**: PASS / FAIL / `UNKNOWN(not_present)` — and UNKNOWN can never satisfy a suite. Add streaming-native vocabulary: `streamed_in(instance, atPosition, memBudget)`, `stream_radius_covers(model, gameplayArea)`, `persists(model)` (checks ModelStreamingMode=Persistent for gameplay-critical geometry). Suite runner must report the UNKNOWN count as loudly as failures.

### F7 — The oracle Heisenbugs the scene it measures — **MED→HIGH at scale**
**What's wrong.** On the 100k-part open world, agent calls `intersects(*, *)` region-wide, implemented as `GetPartsInPart` with PreciseConvexDecomposition across everything. The query itself hitches the server 400ms. Two lies follow: (1) the frame-time telemetry the agent gathers next shows a spike *the oracle caused*, and the agent "fixes" phantom perf problems; (2) under the hitch, physics steps get lumpy, and a `stable_over` vehicle check fails spuriously → agent chases a suspension bug that doesn't exist. Learnings store now contains a confidently-wrong method ("reduce suspension stiffness on large maps").
**Why the oracle lies.** Observation cost is not zero; on big scenes it's the dominant perturbation. A green/red verdict with no cost accounting is unfalsifiable — the agent can't distinguish "the game hitched" from "my question hitched it."
**Today.** N/A — today's approach can't ask scene-wide questions at all.
**Countermeasure.** (1) Every query returns `oracle_cost_ms` alongside the verdict; telemetry assertions automatically **exclude oracle-attributed frames**. (2) Two-tier execution: broadphase (spatial hash / bbox) always first, narrowphase only on candidates, hard candidate cap with `TRUNCATED` verdict rather than silent completeness. (3) Region-scoped required: no unbounded `*` queries — `intersections_in(region, filter, maxResults)`. (4) Time-slicing: heavy sweeps amortized over N Heartbeats, flagged as such so temporal assertions know the sample cadence.

### F8 — Edit-mode animation math vs the runtime Animator (the T-pose lie) — **CRIT**
**What's wrong.** Agent authors a sword swing, verifies in edit mode by evaluating keyframe Motor6D transforms mathematically: `arc_of(gripAttachment, clip)` sweeps 140°, `max_angular_velocity` in range, green. At runtime: the rig uses the Avatar Joint Upgrade (AnimationConstraints, not Motor6Ds — a failure this project has *already hit live*, see the dev-harness rig blocker), so the Motor6D channel is ignored and the character T-poses through combat. Second layer of the same lie: even on a correct rig, the runtime Animator **blends** the swing with the locomotion layer and priority rules — the pure-keyframe arc is not the played arc; a Movement-priority walk clip can dilute the Action-priority swing on shared joints if priorities are misconfigured.
**Why the oracle lies.** Keyframe data is *input* to an animation system with its own routing (rig channel compatibility) and mixing (priority/weight/fade). Evaluating the input proves nothing about the output.
**Today.** This is exactly what `capture_animation` exists for — dozens of frames, thousands of tokens, per iteration.
**Countermeasure.** Split the vocabulary explicitly: `clip_arc_of(...)` = EDIT_OK, math over keyframes, cheap, tagged "authoring-only"; `played_arc_of(attachment, animTrack, context=client)` = PLAY_ONLY, samples world CFrames per Heartbeat while the real Animator plays on the real rig. Plus `rig_channel_check(rig, clip)` (EDIT_OK: verifies clip joint targets exist as the rig's *actual* joint type) and `track_priority_audit(animator)` (PLAY_ONLY: reports simultaneous tracks, priorities, weights on shared joints). Spec rule: an animation is never "verified" by clip-space math alone.

### F9 — GUI green at one resolution, broken on the device matrix — **HIGH**
**What's wrong.** `text_truncated(questLabel) == false`, `gui_overlap(shopPanel, hud) == none`, `gui_offscreen(minimap) == false` — all evaluated on the Studio viewport at 1920×1080. On a 375×667 phone: the quest text wraps to 3 lines and clips, the shop panel (Scale-sized) collides with the thumbstick region, and a pixel-Offset minimap is half off-screen. Extra trap: AbsoluteSize/TextBounds are **stale or zero** if queried the same frame a GUI is created or before a UIListLayout pass — the oracle reads 0×0, "not truncated (vacuously)," green.
**Why the oracle lies.** GUI predicates are functions of (resolution, GuiInset, safe-area, font raster, layout-pass timing) — the oracle evaluated one point of a 2D+ input space and reported it as universal truth. The layout-timing trap is F6's vacuous-truth cousin inside a single frame.
**Today.** The agent screenshots one viewport; device coverage today is zero anyway.
**Countermeasure.** GUI assertions take a mandatory `viewport = {w,h}` and the runner sweeps a **device matrix** (desktop/tablet/phone presets — emulatable in edit mode by resizing the camera viewport or computing layout math against target resolutions). Layout-timing rule in spec: GUI queries auto-defer until `AbsoluteSize ≠ 0` and one RenderStepped has passed, else return `UNKNOWN(layout_pending)`. Add `touch_zone_clear(gui)` (no interactive element inside the reserved thumbstick/jump regions) and `safe_area_ok(gui)`.

### F10 — Green suite Goodharts the learning loop — **CRIT (meta)**
**What's wrong.** The nastiest failure isn't in the game — it's in `sidecar/store/learnings/`. Once assertions are cheap, the RETRO stage starts banking "method verified ✓ (12/12 asserts)" learnings. The sword whose 12 asserts passed is untextured gray plastic with default Material, the arena all asserts loved is a lightless gray box. Nothing failed because nothing *assertable* was wrong. Over weeks the curriculum optimizes toward the measurable: the factory gets superb at geometry topology and forgets it ever cared how things look — the exact "generic AI game" ceiling the north star exists to break. Worse: F4/F7-style confidently-wrong verdicts get banked as method-lessons and *auto-propagate* to future builds.
**Why the oracle lies.** It doesn't, locally — that's the trap. The lie is the implicit inference "all asserts green ⇒ artifact good," which the learning loop then compounds with interest. Assertion coverage silently becomes the definition of quality.
**Today.** Today's screenshot-everything approach, for all its cost, is *incorruptible on this axis* — the agent always looks.
**Countermeasure (spec-mandatory, multiple).** (1) **Verification-tier tagging on every learning**: `symbolic-only` vs `capture-confirmed` vs `playtest-confirmed`; symbolic-only learnings carry lower trust weight in RETRO and cannot graduate to "settled method" status. (2) **Stochastic capture audit**: 1-in-N completed tasks (spec picks N, e.g. 5) gets a full old-style screenshot review regardless of green suite — disagreements between capture and suite are themselves banked as *oracle bugs* and fed to the MECHANIC stage. (3) Suite results always include the **declared-blindspot manifest** (see Holes): "12/12 asserted PASS; NOT asserted: material, lighting, readability, silhouette" — the green banner is structurally impossible to read as "done." (4) Rubric items map explicitly to `assertable` vs `capture-verified`; the tiered rubric from the training architecture keeps aesthetic tiers capture-gated forever.

### F11 — Vocabulary gaps become systematic blind spots because the agent stops looking — **HIGH (meta)**
**What's wrong.** Concrete instance: the vocabulary has `gui_overlap` but nothing for *z-order*. A tooltip renders **behind** the panel it annotates (ZIndex/DisplayOrder bug). No assertion exists → no assertion fails → and because the oracle exists, the agent's policy has shifted to "screenshot only when an assertion fails." Every game shipped for a month has buried tooltips. The gap is invisible precisely because the whole class of check was never named — unlike a failing check, a missing check emits no signal.
**Why the oracle lies.** By omission, at the vocabulary level. A fixed vocabulary defines a fixed ontology of failure; everything outside it is unrepresentable, and the token-economics that motivated the oracle actively suppress the fallback behavior that used to catch it.
**Countermeasure.** (1) Vocabulary is **versioned and gap-mined**: every capture-audit discrepancy (F10.2) and every user bug report is triaged as "which missing assertion would have caught this" → new vocabulary entry, MECHANIC-style, with the same auto-revert discipline. (2) The spec ships with a **coverage map**: for each rubric category, which assertions apply; categories with <K applicable assertions are auto-flagged `capture-required`. (3) Cheap catch-all probes that don't need full vision: `render_hash(camera_pose)` — a downsampled luminance/color histogram (~50 tokens) diffed against "gray box" and "all black" signatures, so *some* pixel-derived signal survives even in symbolic mode.

---

## 2. CONSOLIDATED VOCABULARY (deduplicated)

**Structural / geometric (multi-geometry aware — `geometry ∈ {bbox, collision, render}` mandatory, no default):**
- `intersects(a, b, geometry) → {bool, depth, oracle_cost_ms}`
- `penetration_depth(a, b, geometry) → studs` (raw magnitude + verdict incl. `ZFIGHT_RISK` band)
- `coplanar_zfight(a, b) → {bool, separation}` — the F4 inversion, tiny-separation-is-bad
- `gap_between(a, b, geometry) → studs`
- `axis_of(part) / alignment(a, b) → {dot, skew_studs}` — scale-aware, reports end-to-end deviation
- `bbox_sanity(part) → bboxVol/renderVol ratio` — stray-vertex detector
- `intersections_in(region, filter, maxResults) → list|TRUNCATED` — bounded, broadphase-first
- `joint_integrity(model) → {orphan_parts[], nil_refs[], root_reachable}`
- `anchored_ok(model) → verdict` (+ "will scripts unanchor this" is a HOLE — see below)

**Temporal (Heartbeat samplers, summary-stats out):**
- `stable_over(expr, duration, tol) → {min, max, drift, verdict}`
- `settles(expr, target, deadline) → {settled_at|TIMEOUT, overshoot}`
- `monotonic(expr, window)` / `oscillation(expr, window) → {amplitude, freq}`
- `load_order(a, before=b) → verdict` + `join_simulation(early|late)` suite variants

**Animation (clip-space vs played-space split):**
- `clip_arc_of(attachment, clip) → {sweep_deg, max_ang_vel}` — EDIT_OK, tagged authoring-only
- `played_arc_of(attachment, track, context=client) → same, sampled live` — PLAY_ONLY
- `rig_channel_check(rig, clip) → {joint_type_mismatches[]}` — catches the Motor6D-vs-constraint T-pose
- `track_priority_audit(animator) → {concurrent_tracks, shared_joint_conflicts[]}`

**GUI (mandatory `viewport={w,h}`, device-matrix runner, layout-pass deferral):**
- `gui_overlap(a, b, viewport)` / `gui_offscreen(x, viewport)` / `text_truncated(label, viewport)`
- `z_order_ok(tooltip, above=panel)` — the F11 gap, named
- `touch_zone_clear(gui, viewport)` / `safe_area_ok(gui, viewport)`
- All GUI queries: auto-defer until AbsoluteSize≠0 + one render step, else `UNKNOWN(layout_pending)`

**Streaming / replication:**
- `streamed_in(instance, atPosition, memBudget) → PASS|FAIL|UNKNOWN`
- `stream_radius_covers(model, gameplayArea)` / `persists(model)` (ModelStreamingMode check)
- `replica_delta(instance, prop, server_vs_client) → magnitude` — quantifies F2 divergence

**Meta (the spec's real deliverables):**
- Three-valued verdicts everywhere: `PASS | FAIL | UNKNOWN(reason)`; UNKNOWN never satisfies
- Validity-domain tag on every assertion: `EDIT_OK | PLAY_ONLY | EDIT_MISLEADS`
- `oracle_cost_ms` on every result; telemetry auto-excludes oracle-attributed frames
- Suite result = verdicts **+ declared-blindspot manifest** (what was NOT asserted)
- `render_hash(camera_pose) → histogram` — 50-token gray-box/black-screen tripwire
- Client-context oracle runner (LocalScript agent) — F2 is unfixable without it

---

## 3. HOLES — fundamentally not symbolically verifiable

1. **Aesthetic quality** (materials, palette, lighting mood, composition, silhouette, "anime feel"). *Why:* these are judgments over the rendered image against a learned taste distribution; there is no engine property whose value is "looks good." The NEON GAUNTLET redesign happened because the user's eye said "bare bones," not because any property was wrong. *Mitigation:* keep capture in the loop for aesthetic rubric tiers permanently (F10.4); `render_hash` as a degenerate-case tripwire only; reference-first mandate stays image-based.
2. **Game feel / juice** (hit-stop timing feels right, camera shake reads as impact, swing has weight). *Why:* the numbers are checkable (`settles`, arc velocity) but the *thresholds* are perceptual and context-dependent — 80ms hit-stop is great for a hammer, mud for a dagger. *Mitigation:* bank per-category calibrated ranges in the quality-pack rubrics (human-tuned once, asserted forever) — turns a hole into a slowly-hardening floor.
3. **Fun, pacing, difficulty curve.** *Why:* emergent over minutes of real play against human skill models; no point or interval query touches it. *Mitigation:* scripted-bot playthrough telemetry (time-to-first-death, economy curve vs design intent) — telemetry-over-time narrows but never closes it; human playtest stays the gate.
4. **Netcode feel under real latency/jitter/loss.** *Why:* Studio playtest is localhost; `replica_delta` at 0ms RTT says nothing about 120ms-RTT rubber-banding, and Studio cannot honestly simulate adversarial packet timing. *Mitigation:* IncomingReplicationLag setting for crude lag injection + treat as HOLE beyond that; real verification needs a deployed test place with live telemetry.
5. **Cross-device rendering truth** (mobile shader tiers, quality-level LOD, font rasterization). *Why:* the oracle queries the DataModel; rendering differences live in the renderer per-platform, below any Luau-visible property. Device-matrix GUI math (F9) covers layout, not rasterization. *Mitigation:* device emulation captures for the layout half; accept the rasterization half as unverifiable until real-device telemetry exists.
6. **"Will a script change this later"** — anchored_ok, joint_integrity, any property assert is refutable by one line of game code running at t+10s. *Why:* verifying all reachable script behavior is static analysis of Turing-complete Luau — undecidable in general. *Mitigation:* temporal assertions during a real playtest window (`stable_over(anchored, 60s)`) convert the undecidable into the empirically-sampled; plus grep-level static heuristics (`scans_for_writes(prop, model)`) as a cheap tripwire, never a proof.
7. **Audio** (mix balance, ducking, spatialization correctness as *heard*). *Why:* IsPlaying/Volume/RollOff are assertable; whether the boss theme drowns the hit sounds is perceptual. *Mitigation:* assert the symbolic layer (right sound playing, volume within rubric band), gate mix quality on human review.

---

## 4. EDIT vs PLAY SPLIT

**Valid in edit mode (cheap, safe, extend the ~9-check doctrine):** `joint_integrity`, `bbox_sanity`, `rig_channel_check`, `clip_arc_of`, `alignment`/`axis_of` on **anchored** structural geometry, `intersects`/`gap_between` on **anchored** parts, all streaming *configuration* checks (`persists`, `stream_radius_covers` as math), GUI layout math against emulated viewports (with the layout-pass deferral rule), `load_order` as static require-graph analysis.

**Only meaningful at runtime:** everything temporal (`stable_over`, `settles`, `oscillation`), `played_arc_of`, `track_priority_audit`, `replica_delta`, `streamed_in` (actual client), `touch_zone_clear` on a real touch client, all Humanoid/character-dependent checks, any assertion about unanchored parts' *positions*, performance-adjacent anything.

**Edit mode actively MISLEADS (the `EDIT_MISLEADS` tag — the spec's most important list):**
- **Positions of unanchored/jointed assemblies** (F1): edit CFrames are authored fiction until the solver runs. Green here is worse than no check.
- **Clip-space animation math** (F8): provably correct keyframes + wrong rig channel = T-pose; the edit check *increases* false confidence.
- **GUI absolute geometry at Studio viewport size** (F9): a pass is a pass for exactly one device nobody plays on.
- **Server-context reads of client-owned state** (F2): character CFrames under client network ownership, LocalScript-created instances — edit/server answers are answers about the wrong world.
- **Anything a script mutates on run** (Hole 6): edit-mode property snapshots have zero warranty once `RunService.IsRunning()`.

**Spec rule binding it together:** the suite runner refuses to mark a task verified while any `EDIT_MISLEADS`-class assertion lacks its runtime twin, and refuses to mark it *done* while the blindspot manifest contains capture-gated rubric items that were never captured. The oracle's job is to make the agent's eyes cheap — never optional.

---

# DOMAIN: spatial-world

# 3D World & Spatial at Scale — Oracle Failure Catalog, Vocabulary, Holes, Edit/Play Split

## 1. FAILURE CATALOG

### F1 — The floating village
Terrain was resculpted (or `Terrain:FillRegion` re-run) after 40 buildings were placed by pivot. The terrain surface dropped 2–4 studs under a third of them. Every building is anchored, parented correctly, `get_tree` shows a perfect hierarchy, positions are "valid numbers." Players see houses hovering on air with visible dark undersides; NPCs pathfind under porches. **Why the backend lies:** placement scripts recorded success; nothing ever compared the model's lowest point to the ground beneath it. **Why today misses it:** a screenshot from the default 3/4 angle hides a 2-stud gap behind foliage; catching all 40 buildings needs dozens of captures at grazing angles (~30–50k tokens), and visual judgment can't distinguish a 0.3-stud float (fine) from a 2-stud float (broken).

### F2 — The buried spawn / geometry swallow
A `SpawnLocation` sits 1.5 studs inside a hillside after a terrain smooth pass, or a scattered-prop script sank 12 of 500 rocks fully under the terrain surface (wasted parts, streaming cost) and half-buried 8 trees to the canopy. Player spawns inside the hill: physics ejects them violently upward or the camera clips into voxels and shows the void. **Why the backend lies:** the SpawnLocation exists, is Enabled, has valid TeamColor; the props all "placed successfully." **Why today misses it:** buried geometry is by definition invisible in screenshots; you'd only catch it by playtesting the spawn and watching the ejection, one spawn at a time.

### F3 — The impassable doorway
Interior doorway opening measures 3.6 studs wide × 6.5 high. An R15 character's effective collision needs ~4.2 wide with controller skin; the player rubs and catches on the frame, and `PathfindingService` (AgentRadius 2) routes all 100 NPCs around the building entirely — they cluster at a wall, pathing "successfully" to a point they can't enter. **Why the backend lies:** the door model exists, hinges scripted, `CanCollide` correct on every part; nothing measures the *negative space*. **Why today misses it:** a screenshot of a doorway looks like a doorway. 3.6 vs 4.4 studs is invisible to visual judgment. Today's only catch is a live playtest walking a character through every door in the map.

### F4 — StreamingEnabled eats the bridge
`StreamingEnabled = true` for the open world. A canyon bridge is a plain Model (default `ModelStreamingMode.Default`, non-atomic). A client 800 studs away sees the far side of the canyon (terrain always streams) but the bridge's collision parts have streamed out. A player sniping from a cliff, or a projectile raycast on the client, or a returning player who fell behind the streamed radius, falls through where the bridge "is." Similarly: a kill volume, a door trigger, or a `PrimaryPart` referenced by a LocalScript streams out → client script errors, only for players beyond the radius. **Why the backend lies:** in edit mode, and on the *server*, everything is always loaded. Every check the agent runs today executes in a fully-loaded DataModel. **Why today misses it:** screenshots are taken by the plugin in edit mode or as the play-solo client standing *near* the content. The bug only exists for a client at distance — the exact condition the agent never occupies.

### F5 — Z-fighting on the plaza
Two floor slabs both at Y = 12.000, or a decorative trim quad coplanar with the wall behind it — 300 studs of coplanar overlapping faces. At mid-distance the plaza shimmers/flickers as the depth buffer coin-flips per pixel per frame. **Why the backend lies:** both parts have "correct" positions; nothing is intersecting in the volumetric sense (`GetPartsInPart` may not even flag surface-touching). **Why today misses it:** z-fighting is a *temporal* artifact — a single screenshot freezes one winner of the coin flip and can look completely clean. The agent would need video or many frames from the same camera, which the pipeline doesn't do.

### F6 — Hairline seams in the modular kit
A dungeon assembled from 4-stud modular wall tiles has cumulative float drift: segments 17–23 have 0.03–0.08 stud gaps. Interior light bleeds through as bright hairlines; at certain angles players see through the wall into the skybox; a rolled projectile with a small hitbox slips through. **Why the backend lies:** every tile is anchored, aligned to "the grid" in the script's own coordinates; 0.05 studs is below anything `get_properties` comparison would flag unless you know exactly which pair to diff. **Why today misses it:** hairline gaps render as sub-pixel at normal capture resolution/angles; the agent would only see them at raking camera angles it doesn't know to take.

### F7 — The disconnected nav mesh
A decorative boulder was moved 3 studs and now overlaps the only ramp between the market and the arena. Visually the map looks open — the boulder is *beside* the path to the eye — but the remaining gap is 3.1 studs (< agent diameter). Every NPC path from the north half to the south half returns `NoPath`; NPC AI falls back to idle; the world reads as dead. **Why the backend lies:** boulder placed successfully, all parts valid; pathfinding "works" (it correctly reports no path — but nothing *asks* it holistically). **Why today misses it:** the agent would need to notice, from screenshots, that NPCs aren't where they should be — a behavioral absence, near-invisible in stills. Token cost of visually auditing NPC distribution across an open world is absurd.

### F8 — Kill plane / water volume misregistration
The map got scaled 1.25× but the kill plane at Y = −50 didn't move; a new valley floor sits at Y = −54. Players walking downhill die mid-stride with no visual cause. Variant: `Terrain:FillRegion` water was re-run after a cave was carved and the water now floods the cave interior POI (or leaves a dry air-pocket hole in the lake that players fall through while "swimming"). **Why the backend lies:** the kill script fires exactly as written; the water voxels are exactly where the fill call put them. Both are *correct executions of stale coordinates*. **Why today misses it:** the kill plane is invisible; water-vs-interior overlap is inside geometry; screenshots show a normal lake and a normal valley.

### F9 — Scale drift (giant doors, dollhouse furniture)
A generated tavern has 11-stud doors, 1.5-stud-high tables, and stairs with 2.5-stud risers a Humanoid can't climb (> `maxSlopeAngle`-equivalent step). Every asset individually looks fine in its own capture; nothing establishes a common ruler. **Why the backend lies:** all sizes are legal; the build succeeded. **Why today misses it:** this is the documented weak spot — visual judgment from screenshots is unreliable for *measurements*, and without a character in frame there is no scale anchor. The stair-climbability failure additionally only manifests in play mode.

### F10 — The leaky interior (lighting + enclosure)
An interior room intended to be dark has one wall built from a 0.05-stud-thick panel and a 0.4-stud gap at the roofline. Voxel lighting (4-stud voxels) bleeds sunlight straight through the thin wall; the "dark dungeon" is dusk-lit gray, and the roofline gap paints a light stripe across the floor. **Why the backend lies:** the wall part exists and covers the opening geometrically to any hierarchy check; lighting is computed by the renderer, not queryable state. **Why today misses it:** a capture *would* show it — but only from inside the room, with the right Lighting time, and the agent must already suspect the room; auditing every interior visually is the token bonfire the oracle exists to avoid. The *causes* (thin walls, hull gaps) are fully symbolic even though the *symptom* is photometric.

## 2. REQUIRED VOCABULARY (per scenario)

- **F1:** `ground_clearance(part|model) → {gap: number, support: "terrain"|"part"|"void", contactFraction: 0..1}` — signed distance from the footprint's lowest points (multi-ray, not single pivot ray) to whatever is below; `contactFraction` = fraction of footprint rays that touch support within ε. Batch form: `ground_clearance_batch(tag|folder, tolerance) → {worstN: [...], histogram}`.
- **F2:** `penetration_depth(a, b|Terrain) → {depth: number, direction: Vector3}`; `spawn_clear(spawnLocation) → {groundGap, overheadClearance, slopeDeg, penetrating: bool, facingRayDist}`.
- **F3:** `opening_clearance(regionOrDoorModel) → {minWidth, minHeight, at: Vector3}` — measures the *negative space* of an aperture by ray/shape-cast sweep; `passage_clear(from, to, agentRadius, agentHeight) → pass/fail + chokepoint`.
- **F4:** `streaming_lint(root) → [{instance, issue}]` — flags gameplay-critical parts (spawns, kill volumes, script-referenced parts, walkable surfaces along POI routes) that are in non-Persistent/non-Atomic models under StreamingEnabled; `client_visible_at(instance, cameraPos) → bool` (runtime, client-side probe).
- **F5:** `coplanar_overlap(a, b, ε) → [{facePair, overlapArea, separation}]`; region batch: `zfight_candidates(region, ε) → worstN pairs`.
- **F6:** `gap_between(a, b) → {distance, axis}`; `seam_scan(modelSet|folder, maxGap) → [{pairs, gap, worldPos}]` — pairwise nearest-face scan over a modular kit; `hull_watertight(model, maxHole) → {sealed: bool, holes: [Vector3]}` (raycast flood from interior centroid).
- **F7:** `path_exists(a, b, agentParams) → {status, length, blockedNear: Vector3?}`; `reachability_matrix(POIs[], agentParams) → connectivity components + broken edges` — the killer query: one call replaces an afternoon of watching NPCs.
- **F8:** `volume_covers(killVolume|plane, walkableSurfaces) → {minClearance, violations: [Vector3]}`; `water_region_check(region) → {floodsPOIs: [...], airPockets: [Vector3]}` via `Terrain:ReadVoxels` occupancy diff against interior POI regions.
- **F9:** `scale_ratio(model, referenceRig|studs) → {heightRatio, doorFits: bool, stepMaxRise, counterHeightRatio}`; `proportion_report(model, categoryPrior) → deviations` (priors: door ≈ 7×4, table ≈ 3 high, riser ≤ 1.5, corridor ≥ 6 wide); `climbable(pathOrStairs, humanoidParams) → pass/fail + first failing step`.
- **F10:** `min_thickness(model|wallSet) → {thinnest, at}` (voxel-lighting rule: < ~1 stud leaks); `hull_watertight` (shared with F6); `enclosure_light_risk(room) → [{gapOrThinWall, worldPos}]` = composition of the two.

### Deduplicated vocabulary
| Assertion | Args | Returns | Catches |
|---|---|---|---|
| `intersects(a,b)` / `penetration_depth(a,b)` | parts/models/Terrain | bool / {depth, dir} | F2, prop overlap generally |
| `ground_clearance(x)` + `_batch` | model/tag, tol | {gap, support, contactFraction} / worstN+histogram | F1, F2 (float+bury, at scale) |
| `spawn_clear(spawn)` | SpawnLocation | ground/overhead/slope/penetration/facing | F2 |
| `opening_clearance(aperture)` | door/window/arch | {minW, minH, at} | F3 |
| `passage_clear(a,b,agent)` | points + agent dims | pass/fail + chokepoint | F3, F7 |
| `path_exists(a,b,agent)` | points + agent params | status/length/blockedNear | F7 |
| `reachability_matrix(POIs)` | POI list + agent | components + broken edges | F7 (holistic) |
| `gap_between(a,b)` | parts | {distance, axis} | F6 |
| `seam_scan(set, maxGap)` | folder/tag, tol | gap list w/ world positions | F6 |
| `hull_watertight(model)` | model, maxHole | sealed + hole positions | F6, F10 |
| `min_thickness(walls)` | model/set | thinnest + position | F10 |
| `coplanar_overlap(a,b,ε)` / `zfight_candidates(region)` | parts / region | face pairs + areas | F5 |
| `volume_covers(vol, surfaces)` | kill/water volume | minClearance + violations | F8 |
| `water_region_check(region)` | region3 | floods/air-pockets | F8 |
| `scale_ratio(model, ref)` / `proportion_report(model, prior)` | model + rig/priors | ratios + deviations | F9 |
| `climbable(path, humanoid)` | route + params | pass/fail + failing step | F9 |
| `streaming_lint(root)` | DataModel root | flagged instances + issue | F4 (static half) |
| `client_visible_at(x, pos)` | instance, camera pos | bool | F4 (runtime half) |
| `axis_of(part)` vs `facing(part)` | part, expected vector | angle error | spawn facing, prop orientation |
| `anchored_ok(model)` | model | unanchored-unwelded list | runtime-collapse precursor |

## 3. HOLES — what symbolic checks fundamentally cannot verify

1. **Aesthetic coherence / art direction.** Whether the biome blend, palette, silhouette language, and clutter density read as a *place* vs. programmer-art soup. No geometric predicate encodes taste. **Why:** the failure lives in gestalt perception, not in any measurable relation between instances. **Mitigation:** run the oracle *first* as a gate, then spend vision tokens only on rubric-scored captures of already-geometrically-sound scenes (this is exactly the quality-ceiling loop); keep captures low-res for composition judgment since measurements are now the oracle's job.
2. **Texture/material artifacts** — UV stretching on scaled MeshParts, tiling repetition visible at gameplay distance, normal-map seams. **Why:** the DataModel exposes the material *assignment*, not the *rendered result*; stretching is a function of UV layout inside the mesh asset, invisible to Luau. **Mitigation:** symbolic pre-filter (flag parts scaled non-uniformly > 2:1, flag > N-stud faces with tiling materials) to shortlist capture targets.
3. **Z-fighting severity.** `coplanar_overlap` finds every *candidate*, but whether it visibly flickers depends on camera distance, depth-buffer precision, and draw order — temporal render behavior. **Why:** the artifact exists only in the rasterizer across frames. **Mitigation:** treat every coplanar-overlap candidate as a build error and offset by 0.01 studs — fix unconditionally instead of verifying; this converts a hole into a lint rule.
4. **Streaming pop-in as *experienced*.** `streaming_lint` proves critical content persists, but whether the player *sees* ugly pop-in of non-critical scenery at their movement speed and real network conditions needs a moving client and frames over time. **Why:** it's a function of client bandwidth, replication scheduling, and motion — none queryable from a static DataModel. **Mitigation:** scripted playtest that teleport-sweeps a client along the main route logging `client_visible_at` for scenery sets at each waypoint — telemetry proxy, still blind to *how it looks*, but bounds the worst cases.
5. **Lighting mood and shadow artifacts.** `enclosure_light_risk` catches leak *causes*, but "is the dungeon atmospheric," shadow acne, over-dark playable areas — photometric. **Why:** Roblox exposes no queryable lightmap/voxel-light values to Luau. **Mitigation:** one interior capture per sealed room *after* hull checks pass (the oracle shrinks the capture set from "everywhere" to "one per room").
6. **Performance under load** — streaming memory on low-end devices, physics throughput with 100 NPCs crossing chunk seams, draw-call spikes in dense districts. **Why:** these are *time-series under load*, not assertions about state; edit-mode part counts only weakly predict runtime cost. **Mitigation:** static budget oracles (parts/region, triangles/region via ExtentsSize×density heuristics) as leading indicators + a soak playtest logging `Stats` service counters over minutes — telemetry, not assertion.
7. **Wayfinding / player readability** — can a new player *find* the objective; does the space funnel correctly. **Why:** it's a claim about human perception and behavior, not geometry; `reachability_matrix` proves a path exists, not that a player will discover it. **Mitigation:** heuristic proxies (sightline checks from spawn to first landmark via raycast; path-length ratios between intended and shortest routes) plus eventual human/telemetry data — accept this as the permanent human-in-the-loop residue.
8. **Collision-vs-render divergence on MeshParts.** A MeshPart with `CollisionFidelity=Box` around a hollow arch: the oracle's `passage_clear` (shape-cast against collision) says "blocked" while the *visual* mesh has a walkable opening — or the reverse (Hull says clear, render shows a wall). **Why:** the oracle necessarily measures collision geometry; the render mesh is a different shape the DataModel doesn't expose vertex-accurately (except via EditableMesh on owned assets). **Mitigation:** lint `CollisionFidelity` on any MeshPart that participates in a passage/enclosure check and demand `PreciseConvexDecomposition` or an explicit invisible collision cage there; where EditableMesh access exists, compare mesh AABB to collision AABB.

## 4. EDIT vs PLAY SPLIT

### Valid in edit mode (cheap, run always — these are the ~9-checks doctrine's new muscle)
All pure-geometry queries: `intersects`, `penetration_depth`, `ground_clearance(+batch)`, `gap_between`, `seam_scan`, `coplanar_overlap`/`zfight_candidates`, `opening_clearance`, `min_thickness`, `hull_watertight`, `volume_covers`, `water_region_check` (Terrain voxels are edit-readable), `scale_ratio`/`proportion_report`, `axis_of`/`facing`, `anchored_ok`, `streaming_lint` (it's a static config lint), and — importantly — `path_exists`/`reachability_matrix`/`passage_clear`: **`PathfindingService:ComputeAsync` works in edit mode**, so the entire nav-connectivity suite is an edit-mode check. `spawn_clear`'s geometric half (penetration, clearance, slope, facing) is edit-valid.

### Only meaningful at runtime
- **All StreamingEnabled behavior** (`client_visible_at`, pop-in sweeps): streaming only executes on a connected *client* in play mode; there is no edit-mode analogue at all.
- **Unanchored settle:** whether the physics step collapses, launches, or jitters loosely-stacked/welded geometry. `anchored_ok` predicts risk in edit; only stepped physics confirms outcome (compare snapshot of positions at t=0 vs t=3s: `settle_drift(model) → maxDisplacement`).
- **Touched/kill-volume firing:** `CanTouch`/`CanQuery`/overlap events need running scripts + physics. `volume_covers` proves geometry; only play mode proves the *script* kills.
- **Humanoid traversal:** `climbable` as a math check (riser heights vs step-up limits) is edit-mode; ground truth (does the character actually mount the stair, slide off the slope past `maxSlopeAngle`) is a play-mode walk-bot.
- **Spawn outcome:** actual character placement, ejection, camera state after `LoadCharacter`.
- **Script-driven placement:** any geometry positioned at runtime (procedural props, moving platforms, doors) — edit-mode oracle results describe a world that won't exist.

### Where edit mode actively MISLEADS (the dangerous quadrant)
1. **StreamingEnabled:** edit mode is a *fully loaded* DataModel — the one state a streaming client never sees. Every edit-mode geometric pass on a streaming game is silently conditioned on "…if it's loaded." Rule: any edit-mode PASS on a StreamingEnabled place must be paired with `streaming_lint` PASS, or it's unqualified.
2. **Unanchored geometry:** looks perfectly placed in edit; is a pile of rubble at t+1s. An edit-mode `ground_clearance = 0` on an unanchored decorative stack is a *lie about the future*.
3. **Runtime-repositioned instances:** doors scripted open, elevators, procedurally scattered loot — edit-mode seam/overlap checks validate the pre-script pose only.
4. **Collision flags vs visual:** `CanCollide=false` walls pass every visual capture and every "does a wall exist" tree check but are pass-through at runtime; conversely `CanCollide=true` invisible leftovers block players while every screenshot shows open space. (Oracle addendum: `collision_visual_consistent(region) → [{invisible-but-solid, visible-but-passthrough}]` — edit-checkable, catches both.)
5. **Terrain water:** edit-mode water voxels don't simulate buoyancy/currents; whether a Humanoid actually enters Swimming state in a shallow decorative pool is runtime-only.

**Operational rule for the agent:** oracle-gate everything in edit mode (pennies per check), enter play mode only to (a) validate the four runtime-only classes above via scripted probes, and (b) spend vision tokens exclusively on scenes that already hold a full edit-mode oracle PASS — screenshots demoted from measuring instrument to taste instrument.

---

# DOMAIN: animation-rig

# Roblox Oracle — Domain Report: Characters, Rigs & Animation

## 1. FAILURE CATALOG

### F1 — Weapon grip is welded to the wrong bone-space (the "backwards sword")
The tool's `Grip` CFrame (or Motor6D C0/C1 on a custom weld) is rotated 180° about Y, or the handle attachment's axis points down the blade instead of the hilt. `get_properties` shows a valid weld, valid CFrames, non-NaN, both parts anchored/unanchored correctly. `run_luau` confirms the weld exists and `Part0/Part1` are set. But the blade points INTO the character's forearm, or the gun is held by its barrel. The backend lies because a CFrame is just numbers — "grip exists, offset is (0.2, -0.5, 0)" is indistinguishable from correct without knowing which local axis of the mesh is "blade-forward." Screenshot catches it… if the camera angle happens to show the blade, and after ~1500 tokens the model still confuses "slightly angled" with "reversed." Player sees a warrior stabbing themselves with every swing.

### F2 — Animation plays, track reports Playing, character doesn't move (priority/rig-type mismatch)
`AnimationTrack.IsPlaying == true`, `TimePosition` advances, `Length` correct, no errors. But: (a) the track was loaded at `Core` priority and the default `Animate` script's idle at `Idle`+ overrides every joint it touches, OR (b) the clip animates Motor6D channels but the rig is an Avatar-Joint-Upgrade `AnimationConstraint` rig (the exact T-pose blocker already hit in this project), OR (c) the clip's joint names ("RightHand") don't match the rig's ("R_Hand") so retarget silently maps nothing. Every backend signal is green — the engine happily "plays" an animation that moves zero joints. Player sees a frozen T-pose gliding around. Screenshots catch a T-pose but cost a full playtest + capture cycle, and can't distinguish which of the three causes it is.

### F3 — Layered blend fights: the "walking while chopping" arm snap
An upper-body attack clip at `Action` priority is played over locomotion. Both tracks report Playing, correct weights, correct priorities. But the attack clip ALSO contains keyframes on `LowerTorso`/`Root` (the animator keyed the whole rig), so at Action priority it freezes the legs mid-stride — the character slides across the ground doing a moonwalk-chop. Or the reverse: the attack clip omits the torso, so the torso keeps its walk-sway and the sword arc gets an unintended twist. Backend truth: two tracks playing, weights sum fine. The lie is in WHICH joints each clip owns — invisible in any property. Catching it visually requires capture_animation across multiple frames while moving, the most expensive verification in the whole toolbox.

### F4 — Foot sliding / root-motion mismatch
Walk cycle authored at stride pace X, `Humanoid.WalkSpeed` set to Y ≠ X-equivalent. Everything is "correct": animation plays, speed is as configured, no clipping. But the feet skate over the ground like the character is on ice, or piston in place while barely moving. There is NO single-frame evidence — every screenshot of any individual frame looks perfect. Only the RELATIONSHIP between foot-contact world velocity and root world velocity over time reveals it. Today the agent would need a burst of captures and a judgment call ("do the feet look slidey?") — visually near-impossible to grade from stills.

### F5 — Limb self-clipping during motion (not in the rest pose)
Idle pose: clean. But at keyframe 0.4 of the sword swing, the right forearm passes through the chest; at the crouch pose, thighs interpenetrate the torso; the cape skinned-mesh dives through the back during the run cycle's extreme frame. Edit-mode tree is perfect, the clip's CFrames are valid, playtest runs errorless. Screenshots only catch it if capture fires on the exact offending frame from an angle where the intersection reads — a combinatorial capture problem (N frames × M angles). Player sees the hero's arm vanish into their ribcage every third swing.

### F6 — Motor6D vs AnimationConstraint half-rig (the zombie NPC)
A custom NPC rig was assembled by cloning parts of an R15 and hand-welding extras (armor, tail). Result: 14 joints are Motor6Ds, 2 are `WeldConstraint`s that SHOULD be Motor6Ds (or one leftover `AnimationConstraint` from an upgraded template). Rig validates: Humanoid present, all parts connected, no floating parts, physics stable. Animations play — and 14 of 16 joints animate while the tail stays rigid and the left pauldron stays welded to a torso frame it shouldn't. Backend says "rig connected, no errors." Player sees a creature whose tail is a plank. Ad-hoc `run_luau` could find it, but only if the agent already suspects it and writes the joint-census script from scratch each time.

### F7 — Ragdoll that becomes a soup or a statue
On death, Motor6Ds are destroyed and BallSocketConstraints swapped in. Backend: constraints created, limits set, character Dead, no errors. Failure modes invisible to properties: limits too loose → limbs spin 360° and the corpse folds into itself (soup); collision groups wrong → limbs collide with the torso and the body launches 40 studs into the air on the physics step (the classic ragdoll explosion); a missed neck motor → head stays rigidly upright on a limp body (statue-neck). One screenshot of a settled corpse can look fine while the 0.5s of launch was the broken part — it's a TRAJECTORY failure, not a pose failure.

### F8 — Animation events fire at the wrong moment
`GetMarkerReachedSignal("Hit")` fires — backend confirms the event fires, the damage code runs, hitbox activates. But the marker sits at t=0.15 while the blade visually connects at t=0.42: damage lands while the sword is still over the shoulder. Or the "Footstep" sound markers drift from actual foot-plants after the clip was re-timed. Every log line is green; the desync is between an event timestamp and a POSE, and no property query relates the two. Player feels the combat is "floaty" and can't say why — the worst kind of quality failure for the north-star goal.

### F9 — IK reaches the target by breaking the elbow
`IKControl` with target set; backend: `Enabled=true`, target valid, no errors, end-effector reaches the target (distance ≈ 0!). But the solver bent the elbow BACKWARD (hyperextension — no joint limits configured), or twisted the wrist 300°. The one number the agent would naively check — end-effector-to-target distance — is the one number that looks perfect. Only joint-angle plausibility exposes it. Player sees an arm folded like a broken umbrella whenever the NPC reaches for a lever.

### F10 — Cutscene camera + character desync
A cinematic plays: camera track (TweenService on Camera.CFrame) + character animation started together. Both complete, both report success. But the animation is 4.2s and the camera dolly 4.0s at a different ease — for the final 0.2s the camera stares at a wall while the character finishes the bow off-frame; or the subject drifts out of the camera frustum in the middle. Backend: both timelines "completed." The failure is a time-varying spatial relationship (subject inside frustum, subject occluded or not) that stills sample too sparsely and properties never encode.

### F11 — Scale/proportion drift after retarget or HumanoidDescription apply
Applying a `HumanoidDescription` or retargeting a clip to a custom rig silently changes `BodyHeightScale`/limb proportions; the grip weld authored for a 1.0-scale rig now buries the sword hilt inside a 1.3-scale hand, and the walk clip's stride no longer matches the longer legs (compound with F4). Every scale property individually is a legal value; the LIE is that the weld offset and the clip were authored against a different body. Nothing errors. Player sees a giant delicately pinching a toothpick-sword by its blade.

---

## 2. REQUIRED VOCABULARY

Per-scenario, then the deduplicated list.

| # | Assertion(s) that catch it |
|---|---|
| F1 | `axis_of(part, "blade"|"barrel"|"handle")` vs `facing_of(character)` → angle; `grip_sane(tool, character)` composite |
| F2 | `track_effect(track)` → set of joints whose transform actually changed after `Step`; `rig_kind(model)`; `clip_rig_match(clip, rig)` → unmapped-joint list; `priority_stack(humanoid)` → per-joint winning track |
| F3 | `clip_joint_mask(clip)` → joints keyed; `mask_overlap(clipA, clipB)` → contested joints + winner; `pose_delta(joint, withTrack, withoutTrack)` |
| F4 | `foot_slide(character, clip, duration)` → max ground-contact foot world-speed during stance phase (studs/s); `stride_speed(clip)` vs `Humanoid.WalkSpeed` ratio |
| F5 | `clip_self_intersect(rig, clip, samplesN)` → list of (t, partA, partB, penetration_depth); reuse `intersects`/`penetration_depth` sampled over keyframes |
| F6 | `joint_census(model)` → per-joint {type: Motor6D/AnimationConstraint/Weld/BallSocket, animatable: bool}; `rig_uniform(model)` → pass/fail + offenders |
| F7 | `ragdoll_settle(character, timeout)` → {max_root_speed, max_displacement, settle_time, final_pose_spread}; `constraint_limits_sane(character)` → joints with limits outside human-plausible ranges; `collision_matrix(model)` → self-colliding limb pairs |
| F8 | `marker_pose(clip, markerName)` → world pose of a named part at marker time; `event_pose_check(clip, marker, expr)` e.g. "blade tip within 3 studs of forward reach at 'Hit'"; `arc_of(tip, clip)` → sampled trajectory with per-t positions to correlate against marker t |
| F9 | `joint_angles(rig, t?)` → per-joint Euler/limit usage; `ik_plausible(ikControl)` → {reach_error, joints_beyond_limit[], hyperextended[]} |
| F10 | `in_frustum(subject, camera, t0..t1, samplesN)` → fraction of samples inside + first-exit t; `timeline_align(a_len, b_len, tolerance)`; `occluded(subject, camera, t)` via raycast |
| F11 | `scale_ratio(a, b)` (e.g. sword length : hand width, vs a stored norm); `grip_penetration(tool, hand)` → depth; `stride_speed` re-run post-retarget; `authored_scale_of(clip)` vs `rig_scale(model)` |

### Deduplicated vocabulary (characters/rigs/animation)

**Rig structure (mostly edit-mode)**
- `joint_census(model) → [{joint, type, part0, part1, animatable}]`
- `rig_uniform(model) → ok | offenders[]` — all animatable joints same mechanism
- `rig_kind(model) → "Motor6D" | "AnimationConstraint" | "mixed"`
- `clip_rig_match(clip, rig) → {mapped[], unmapped[]}` — joint-name coverage
- `constraint_limits_sane(character) → offenders[{joint, limit, plausible_range}]`
- `collision_matrix(model) → self_colliding_pairs[]`
- `anchored_ok(model) → offenders[]` (shared with other domains)

**Pose & geometry at a sampled time (edit or play; needs pose-stepping)**
- `intersects(a, b) → bool` / `penetration_depth(a, b) → studs` (shared primitive)
- `gap_between(a, b) → studs` (shared)
- `axis_of(part, semanticAxis) → unit vector` + `angle_between(v1, v2) → deg`
- `facing_of(character) → unit vector`
- `grip_sane(tool, character) → {axis_error_deg, hand_penetration, hilt_in_hand: bool}`
- `scale_ratio(a, b, dims) → ratio` vs stored category norms
- `joint_angles(rig) → per-joint angles + %-of-limit`

**Clip-static analysis (edit-mode, from KeyframeSequence/CurveAnimation data — no playback needed)**
- `clip_joint_mask(clip) → joints keyed`
- `mask_overlap(clipA, clipB) → contested joints + priority winner`
- `clip_length/markers(clip) → [{name, t}]`
- `authored_scale_of(clip)` (heuristic: bone offsets vs rig)

**Clip-sampled analysis (drive rig through poses; edit-mode via manual Transform stepping, or runtime)**
- `clip_self_intersect(rig, clip, N) → [(t, a, b, depth)]`
- `arc_of(partOrAttachment, clip, N) → [(t, worldPos)]` + derived `{max_reach, plane, sweep_deg}`
- `marker_pose(clip, marker, part) → worldCFrame`
- `event_pose_check(clip, marker, predicate) → pass/fail + measured values`
- `pose_delta(joint, clipA_at_t, clipB_at_t) → deg/studs`

**Runtime-only**
- `track_effect(track) → moved_joints[]` (needs live Animator stepping)
- `priority_stack(humanoid) → per-joint winning track`
- `foot_slide(character, seconds) → max stance-foot world speed`
- `stride_speed(clip) → implied studs/s` + `walkspeed_match(character) → ratio`
- `ragdoll_settle(character, timeout) → {max_speed, max_disp, settle_t}`
- `ik_plausible(ikControl) → {reach_error, violations[]}`
- `in_frustum(subject, camera, window, N) → coverage fraction + exits[]`
- `occluded(subject, camera, t) → bool`
- `timeline_align(lenA, lenB, tol) → drift`

---

## 3. HOLES — what symbolic checks fundamentally cannot verify

1. **Motion FEEL / weight / anticipation-follow-through.** A swing can pass every arc, timing, and clipping check and still read as weightless or robotic — ease curves, anticipation frames, overshoot. WHY a hole: "good animation" is a perceptual judgment over acceleration profiles with no ground-truth threshold; two clips with identical symbolic signatures can feel opposite. **Mitigation:** capture_animation strip (few frames) ONLY after all symbolic checks pass — vision as the last-mile judge, not the first filter; plus rubric priors from the training-vision corpus ("attack anticipation ≥ 15% of clip length" gives a crude symbolic proxy).

2. **Skinned-mesh deformation quality.** Bone transforms are queryable; the deformed SKIN is not — Luau cannot read post-skinning vertex positions, so candy-wrapper twists at the wrist, collapsing elbows, and bad weight-painting are invisible to any DataModel query. The bones can be perfect while the mesh looks melted. WHY: the failure lives in vertex-weight interpolation the engine computes on the GPU. **Mitigation:** screenshots at the extreme poses that symbolic checks identify (max joint angles from `joint_angles` tell you WHICH frames to capture — oracle narrows the capture set from N×M to ~3).

3. **Facial animation / emotional read.** FACS channel values are queryable, but "does this face read as angry or constipated" is not. **Mitigation:** vision on a single face close-up per expression; small fixed cost.

4. **Perceived sync of animation with SOUND and VFX.** `event_pose_check` verifies the marker aligns with the pose, but whether the whoosh sounds "on time" involves audio latency, VFX emitter warm-up, and human perception windows (~50-100ms) the DataModel doesn't model. **Mitigation:** symbolic alignment to within a budget (marker-to-pose < 0.05s) as a proxy; occasional human spot-check on flagship assets.

5. **Network-latency animation artifacts.** Replication delay, `AnimationTrack` starting on server vs client, interpolation snapping on other players' screens — a solo Studio playtest is single-client; the broken experience only exists on a second client with real latency. WHY: the failure is emergent from two machines + network, not present in any single DataModel. **Mitigation:** Studio multi-client test server (Start Server + 2 Players) with per-client `track_effect`/pose sampling and cross-client pose-divergence telemetry — partially symbolizable, but genuinely needs the multi-client run.

6. **Long-horizon animation-state-machine drift.** After 10 minutes of combat, a missed `track:Stop()` leaks tracks until priorities gridlock, or a state machine wedges in "attacking" forever. Any instantaneous check passes. WHY: it's a temporal-accumulation bug; the oracle sees snapshots. **Mitigation:** telemetry counters over a soak playtest (`active_track_count`, per-state dwell time) with threshold alarms — telemetry-over-time, not assertions.

7. **Uncanny-valley of PROCEDURAL motion (IK + ragdoll blends).** `ik_plausible` catches broken elbows but not "technically-legal yet creepy" solutions. **Mitigation:** tighter-than-physical joint budgets (human-motion capture ranges, not anatomical limits) encoded as category rubric constants; residual risk accepted.

---

## 4. EDIT vs PLAY split

**Valid and CHEAP in edit mode (prefer these — extends the ~9-check doctrine):**
- All rig-structure checks: `joint_census`, `rig_uniform`, `rig_kind`, `clip_rig_match`, `constraint_limits_sane`, `collision_matrix`, `anchored_ok`.
- All clip-static: `clip_joint_mask`, `mask_overlap`, `clip_length/markers`, `authored_scale_of`.
- Static geometry: `intersects`, `penetration_depth`, `gap_between`, `axis_of`, `grip_sane`, `scale_ratio` — on the REST pose.
- Clip-SAMPLED checks (`clip_self_intersect`, `arc_of`, `marker_pose`, `event_pose_check`, `joint_angles` at t) are edit-mode-ACHIEVABLE by manually applying keyframe transforms to Motor6D `Transform`/part CFrames (exactly the pose-verify skill's flip-book technique) — no physics needed since you're posing kinematically. This is the highest-value engineering target: it moves F1, F3, F5, F8, F11 entirely into edit mode.

**Runtime-only (physics/Animator/scripts must be live):**
- `track_effect`, `priority_stack` — the Animator's actual blend arbitration only exists in play (or with a live edit-mode Animator, which behaves differently for AnimationConstraint rigs).
- `foot_slide`, `walkspeed_match` — needs the Humanoid actually locomoting.
- `ragdoll_settle` — physics stepping, by definition.
- `ik_plausible` — IKControl solves only at runtime.
- `in_frustum`/`occluded`/`timeline_align` for cutscenes — camera scripts must run.
- Anything multiplayer (hole #5).

**Edit-mode state that actively MISLEADS about runtime (danger list):**
1. **The T-pose trap (proven in this project):** an edit-mode rig with Motor6Ds animates fine in the animation editor, but `play start` spawns the player with an Avatar-Joint-Upgrade constraint rig — edit-mode success predicts nothing. `rig_kind` must be asserted on the RUNTIME character, not the edit-mode template.
2. **Grip welds:** in edit mode the Tool isn't equipped; the grip weld doesn't exist yet. `grip_sane` on the unequipped tool checks the Grip CFrame's intent, but the actual `RightGrip` weld (created by the equip code) can differ. Must re-assert post-equip at runtime, or simulate equip in edit mode via the existing grip_tool machinery.
3. **Default Animate script:** absent in edit mode, so edit-mode `mask_overlap` against your custom clips misses the fight with the DEFAULT idle/walk clips that only load at spawn. The oracle needs a known-constant model of the default Animate clips' masks to run this check pre-play.
4. **HumanoidDescription/appearance scaling:** the edit-mode rig is scale 1.0; runtime `LoadCharacterAppearance` can rescale everything (the F11 trap). Any edit-mode `scale_ratio`/`grip_sane` pass is conditional on the harness's `LoadCharacterAppearance=false` convention holding — assert that convention itself at runtime.
5. **Anchored parts:** an anchored HumanoidRootPart makes edit-mode poses stable and runtime characters statues. `anchored_ok` semantics INVERT between modes — flag as mode-aware.
6. **Physics-dependent constraints (ragdoll BallSockets):** in edit mode they're inert decoration; limits that "look configured" may be non-functional (wrong attachment orientation) — only `ragdoll_settle` proves them.

**Recommended check ordering (cost ladder):** edit-mode structure → edit-mode clip-static → edit-mode flip-book sampled checks → single runtime playtest bundling ALL runtime assertions in one session (`track_effect` + `foot_slide` + `ragdoll_settle` + `ik_plausible` in one `play` run) → vision capture ONLY on frames/angles the symbolic layer flagged or on final sign-off. Expected effect: screenshots drop from the default verification to the exception path, and each capture is TARGETED (the oracle tells you which t and which angle).

---

# DOMAIN: combat-net

# Roblox Oracle — Domain Report: Combat, Physics & Networking

## 1. FAILURE CATALOG

### F1 — Hitbox welded to the wrong bone / stale offset after resize
The agent builds a sword with a Handle mesh and a separate invisible hitbox part welded on. Later it rescales the blade mesh 1.4x for visual punch but the hitbox weld's `C0` still describes the old geometry. Every backend check passes: the weld exists, the hitbox exists, `Touched`/spatial-query damage code runs, a stationary dummy standing *inside* the old hitbox volume takes damage in the test. In real play, hits connect ~2 studs behind the visible blade tip and whiff on anything at visual max range. The player experiences "my sword goes through them and nothing happens." Screenshots are useless — an invisible part can't be photographed, and even with hitbox-visualization enabled, judging a 0.8-stud offset from a 2D image is exactly the measurement failure screenshots have. Today the agent would need a capture with debug-visible hitboxes at multiple angles (~4500 tokens) and still guess.

### F2 — Damage validation window kills all hits above ~80ms ping
Server-authoritative melee: client fires `MeleeHit(target)`, server re-checks `(attackerRoot.Position - target.Position).Magnitude <= range`. Correct, secure, and it passes every Studio test — because Studio solo/local multi-client has ~0ms latency. On a real server, the attacker's position the server sees is 100–200ms stale relative to what the client saw when the swing landed; against any strafing target, the server-side distance check fails ~40% of the time. No error is ever thrown — the hit is *silently rejected by design*. Player experience: "half my hits don't register." No screenshot can ever catch this; today's approach would only find it if a human played on a live server and complained.

### F3 — Projectile visual arc diverges from server hit arc
Client renders the arrow with a local Beam/part animated at `gravity = 196.2 * 0.4` (a "feel" tweak the agent made to the client visualizer), while the server raycast-steps the authoritative trajectory with full gravity. Both scripts run clean; the server registers hits exactly where *its* math says; damage numbers appear. But the visual arrow lands 6 studs long of where damage happens. Players see arrows visibly striking enemies with no damage, and taking damage from arrows that visibly missed. Two independently-correct systems, one broken game. Screenshots of a single frame can't compare two trajectories; the agent today would have to capture an animation burst and eyeball two arcs (~10k tokens) and still couldn't measure divergence.

### F4 — Projectile tunneling through thin cover
Bullet speed 400 studs/s, hit detection via `.Touched` or per-Heartbeat position checks: at 60Hz the projectile moves 6.6 studs/step, so any wall under 6.6 studs thick is intermittently permeable. Geometry checks pass (the wall is sealed, `intersects` on the static map says no gaps), scripts error-free, and in Studio tests the agent shoots at a 10-stud-thick test block and it works. In the arena, players get shot through the 1-stud crates the map is full of. This is pure arithmetic that no image will ever reveal — the failure is probabilistic per-frame phase.

### F5 — Network ownership flapping makes the vehicle teleport-jitter
A jeep with working suspension, all constraints valid, drives perfectly in Studio solo (where the local client owns everything). Live, the server auto-assigns ownership by proximity: driver owns it, but a passenger-side unanchored decoration part (missed by the weld pass) keeps its own assembly, ownership of the two assemblies flips between driver/passenger/server every few seconds, and the jeep rubber-bands and yanks 2 studs sideways at each handoff. `anchored_ok`-style naive checks pass because the decoration IS welded — to the wrong assembly root, creating two assemblies where the agent believes there is one. Player experience: unplayable vehicle. Edit mode cannot show ownership at all; a screenshot shows a jeep that looks perfect.

### F6 — RemoteEvent contract drift silently zeroes damage
Client: `DealDamage:FireServer(hitPosition, targetHumanoid)`. Server (refactored two sessions ago): `onServerEvent(player, targetHumanoid, hitPosition)`. `targetHumanoid` on the server is now a `Vector3`; the handler does `if target and target:IsA("Humanoid")` — false — and returns. No error (defensive nil-check "worked"), no warning, no damage, ever. Every script analyzer is happy; the playtest the agent ran only checked "does the swing animation play." The player hits enemies forever with zero effect. Today's catch would require the agent to notice a missing health delta in a playtest log — plausible but only if it thinks to look; there is no named check that forces the question.

### F7 — Server trusts client-supplied hit position (exploit hole, invisible in all functional tests)
The hit-detection handler does `local dmgPos = args.position; if (dmgPos - victim.Position).Magnitude < 5 then victim:TakeDamage(dmg)` — validating the *client-claimed* position against the victim, never against the *attacker*. Functionally flawless with an honest client; every playtest passes; players are happy for weeks until one exploiter fires the remote in a loop with `position = victim.Position` and kills the whole server from spawn. Nothing visual, nothing behavioral in honest testing can catch this — only reading the trust structure of the handler. Today the agent has no systematic prompt to audit it; it would ship.

### F8 — Ragdoll corpse leaves a live invisible collision hull
On death the client disables Motor6Ds and ragdolls beautifully (verified by capture — it *looks* right, so today's visual pipeline signs off). But the ragdoll conversion ran client-side only; the server still has an upright frozen character with `HumanoidRootPart.CanCollide = true`. Server-side raycasts for OTHER players' shots hit an invisible standing capsule where the corpse fell; NPC pathfinding routes around a ghost. Players experience bullets stopping in mid-air over corpses. This is the nastiest class: the screenshot actively *confirms* the broken build, because the client and server disagree and screenshots only see the client.

### F9 — Vehicle stable in Studio, flips on first turn with passengers
Suspension tuned solo: spring stiffness/damping chosen against the empty chassis mass. Four players sit in it — `Humanoid` mass adds ~60+ per seat via SeatWeld into the assembly — CoM rises, springs compress to the bumpstops, and static stability factor drops below 1: it rolls at moderate turn speed. Every property is "valid," the solo playtest drives fine, screenshots show a good-looking jeep. The failure is a computable function of mass/CoM/track-width that nobody computed.

### F10 — Knockback silently no-ops because the root is anchored/massless
A cutscene system anchors `HumanoidRootPart` during boss intros and a bug leaves it anchored (or a "carry" system set `Massless = true` on root and never restored it). The knockback code `ApplyImpulse` executes without error, damage lands, the health bar moves — everything measurable by today's log-checking passes. The player just never moves when hit; combat feels dead. A screenshot of any single frame shows a fine scene; you'd need frame-diffed positions to notice nothing moved.

### F11 — StreamingEnabled: server-side hit geometry the client never sees (and vice versa)
Open world with `StreamingEnabled`. Server spawns cover walls mid-fight (siege event). Server raycasts collide with them; a far-ish client hasn't streamed them in, so players are blocked by and shot from behind *invisible* geometry. All server logic is correct; the client is rendering an honestly incomplete world. Edit mode is maximally misleading here — the edit DataModel always contains everything.

---

## 2. REQUIRED VOCABULARY (per scenario, then deduplicated)

| # | Oracle call | Catches |
|---|---|---|
| F1 | `hitbox_alignment(tool) → {offsetVec, tipGapStuds, bladeCoveragePct}` — compares hitbox part OBB against the visual mesh's render bounds via CFrame math | stale weld offsets, unscaled hitboxes |
| F1 | `swept_hit_coverage(clip, hitboxPart, dummyAt) → {framesIntersecting, firstHitKeyframe, maxPenetration}` — samples the animation's keyframes, poses the rig mathematically, sweeps the hitbox volume | "swing looks right but the hitbox never enters the dummy" |
| F2 | `hit_validation_margin(weaponRange, checkExpr) → {passesAtPing: {0:✓, 50:✓, 100:✗, 150:✗}, staleDistanceAt(ms)}` — replays the server check with target displaced by `speed × latency` | latency-blind validation windows |
| F2 | `latency_probe(remote) → {roundTripMs, serverReceiveDelayMs}` — runtime, uses a clock-sync ping remote | actual replication delay measurement |
| F3 | `trajectory_divergence(clientSimFn/params, serverSimFn/params, range) → {maxDivergenceStuds, landingDelta}` — integrates both trajectories numerically from their actual constants | client/server projectile mismatch |
| F4 | `tunneling_risk(speed, hz, map) → {stepStuds, thinnestObstacleOnLikelyPaths, permeable:[parts…]}` | fast-projectile step size vs obstacle thickness |
| F4 | `hit_method_audit(script) → {method: Touched|raycast|spatialQuery, continuous:bool}` | Touched-based detection on fast movers |
| F5 | `assembly_map(model) → {assemblies:[{root, parts[]}], strayAssemblies}` | parts welded into the wrong (or their own) assembly |
| F5 | `ownership_of(part) → {owner: server|player, isAuto}` (runtime) | who simulates what |
| F5 | `ownership_stability(assembly, seconds) → {transfers, owners[]}` (runtime) | ownership flapping |
| F6 | `remote_contract_check(remoteName) → {clientSignatures[], serverSignature, mismatch:{argIndex, expected, got}}` — static Luau scan of all FireServer/OnServerEvent sites | silent arg-order/type drift |
| F6 | `damage_pipeline_trace(action) → {clientFired✓, serverReceived✓, validationPassed✓/✗+reason, healthDelta}` (runtime) | any dead link in fire→receive→validate→damage |
| F7 | `trust_audit(remote) → {clientControlledInputs → sensitiveSinks}` — static taint: do client args reach `TakeDamage`/CFrame writes/currency without an attacker-anchored recomputation? | exploit surface |
| F7 | `remote_fuzz(remote, n) → {crashes, illegitimateStateChanges}` (runtime) — fires malformed/extreme args at the server handler | handler robustness |
| F8 | `cross_replica_diff(character, props=[CanCollide, Motor6D.Enabled, Anchored]) → {serverState, clientState, mismatches[]}` (runtime, needs both sims) | client-only ragdoll, server ghost hulls |
| F8 | `ragdoll_state(character, side) → {motorsDisabled, canCollideParts[], humanoidState}` | death-state correctness per replica |
| F9 | `assembly_mass(model, {withSeatedHumanoids:n}) → {mass, comHeight}` — humanoid mass added analytically | load-dependent mass |
| F9 | `rollover_factor(vehicle, load) → trackHalfWidth / comHeight` (static stability, <1.1 = flag) | flip-prone vehicles before any drive test |
| F9 | `suspension_margin(vehicle, load) → {springCompressionPctAtRest, bottomsOut:bool}` — spring equations, no sim needed | bottoming out under passengers |
| F10 | `impulse_effective(character) → {anchoredParts[], masslessRoot, platformStand, netMoveOnTestImpulse}` (runtime probe: apply known impulse, measure displacement next step) | silent knockback no-ops |
| F11 | `streaming_visibility(part, atDistance) → {withinStreamRadius, persistent, clientWouldHave:bool}` — computes against StreamingTargetRadius/ModelStreamingMode | invisible-to-client server geometry |
| F11 | `replication_visible(instance, clientSim) → bool` (runtime, multi-client) | ServerStorage/parenting mistakes, generic replication |
| — | `hit_reg_grid(weapon, dummyOffsets[]) → matrix of hit/miss at (distance, angle)` (runtime; uses TrainingDummy fixture) | end-to-end empirical hit envelope, catches F1/F2/F6 together in one cheap table |
| — | `collision_matrix_check(groupA, groupB, expected) → actual` | raycast filters / collision groups excluding the wrong things |
| — | `anchored_ok(model) → {unanchoredUnwelded[], anchoredThatShouldMove[]}` | falls-apart / frozen models |

**Deduplicated vocabulary (24):** `hitbox_alignment`, `swept_hit_coverage`, `hit_validation_margin`, `latency_probe`, `trajectory_divergence`, `tunneling_risk`, `hit_method_audit`, `assembly_map`, `ownership_of`, `ownership_stability`, `remote_contract_check`, `damage_pipeline_trace`, `trust_audit`, `remote_fuzz`, `cross_replica_diff`, `ragdoll_state`, `assembly_mass`, `rollover_factor`, `suspension_margin`, `impulse_effective`, `streaming_visibility`, `replication_visible`, `hit_reg_grid`, `collision_matrix_check`, `anchored_ok`.

The single highest-leverage composite is `hit_reg_grid` + `damage_pipeline_trace`: together they convert "does combat work?" from N screenshots into one ~80-token table with a named failing stage.

---

## 3. HOLES — not symbolically verifiable

1. **Real-internet latency behavior (jitter, packet loss, out-of-order).** Studio multi-client is loopback; `hit_validation_margin` models *constant* delay, but real feel-breakers are variance spikes. WHY a hole: the oracle can simulate a latency number, not a distribution it has never observed. *Mitigation:* an injectable artificial-delay shim on the remote layer (test at 50/100/200ms + jitter), plus live-server telemetry (hit-accept rate by ping bucket) once published.
2. **Combat "feel" — hit-stop, knockback weight, swing responsiveness.** All numbers can be in range and combat still feels like wet cardboard. WHY: feel is a perceptual judgment over timing curves with no ground-truth threshold. *Mitigation:* encode curated rubric numbers from reference games (e.g. "hit-stop 60–120ms, knockback 8–14 studs/s decaying over 0.3s") as oracle-checkable bands — shrinks but never closes the hole; final call is human/capture.
3. **Exploit creativity beyond taint analysis.** `trust_audit` catches "client says damage=999"; it cannot anticipate composed exploits (teleport + legitimate melee remote = kill-aura that passes every per-remote check). WHY: adversarial search space, not a property of any one handler. *Mitigation:* movement-plausibility invariants as *runtime telemetry* (max displacement/tick, damage/sec per player) rather than build-time asserts; standard exploit checklist as a curated rubric.
4. **Emergent physics chaos over time** — the corpse that vibrates itself through the floor after 30s, constraint explosions when two ragdolls interlock, slow NaN drift. WHY: point-in-time assertions can't cover a chaotic system's trajectory; the bug is *when*, not *whether*. *Mitigation:* cheap runtime *watchdogs* (any assembly velocity > X, any position.Y < killplane, any NaN CFrame → logged) running for the whole playtest — telemetry-over-time, oracle-shaped alerts, but must soak.
5. **Server performance at scale (100 NPCs, real players).** Heartbeat time, replication bandwidth, and memory growth degrade over minutes and with player count the agent cannot conjure. WHY: load is exogenous. *Mitigation:* synthetic load harness (spawn 100 NPC dummies, sample `Stats`/heartbeat delta over 3 min) — approximates, doesn't replace live telemetry.
6. **"Does the visual match the hit?" as perceived, post-everything.** Trajectory math can match and the *rendered* tracer (particle latency, interpolation smoothing) still lag the authoritative arc. WHY: the last mile is the renderer, which the oracle's math doesn't run. *Mitigation:* this is the one place capture_animation stays mandatory — but only *after* `trajectory_divergence` passes, so vision is a final confirmation, not a search tool.
7. **Whether a rejection is *correct* vs *unfair*.** The oracle can report "server rejected 12% of hits"; whether those were legit lag-comp saves or robbery requires the attacker's-eye view. *Mitigation:* record the client-claimed vs server-truth positions on every rejection; a human (or vision on the worst outlier) adjudicates a sample.

---

## 4. EDIT vs PLAY SPLIT

**Valid in edit mode (pure DataModel/math — run these first, always):**
`hitbox_alignment`, `swept_hit_coverage` (keyframe posing is math, no playback needed), `tunneling_risk`, `hit_method_audit`, `remote_contract_check`, `trust_audit`, `assembly_map`, `assembly_mass`/`rollover_factor`/`suspension_margin` (analytic, including simulated passenger load), `collision_matrix_check`, `anchored_ok`, `streaming_visibility` (computed from streaming settings), `hit_validation_margin` (replayed math against source-extracted range constants), `trajectory_divergence` (numeric integration of both scripts' constants).

**Runtime-only (physics stepped / scripts live / two sims exist):**
`ownership_of`, `ownership_stability`, `latency_probe`, `damage_pipeline_trace`, `remote_fuzz`, `cross_replica_diff`, `ragdoll_state` (post-death), `impulse_effective`, `replication_visible`, `hit_reg_grid`, all watchdogs/soak checks. Anything involving `Humanoid` state, `.Touched`, or actual replication is meaningless before play.

**Where edit mode actively LIES (must be flagged in the oracle's output, not just skipped):**
- **Anchoring:** scripts unanchor/anchor at runtime; `anchored_ok` in edit describes intent, not behavior. F10 is invisible in edit — the root gets anchored *by a script*. Edit result must carry a caveat when any script writes `.Anchored`.
- **One DataModel:** edit mode has no client/server split, so "the instance exists and the handler looks right" says nothing about replication direction, ServerStorage visibility, or F8-class divergence. Any edit-mode pass on replication-adjacent checks is a *lint*, not a verification.
- **Assembly & mass:** seated humanoids, equipped tools, and runtime welds change assemblies and mass. Edit-mode `rollover_factor` must be computed *with modeled load*, or it certifies a vehicle that flips.
- **Network ownership:** does not exist in edit; solo playtest is *also* misleading (local client owns nearly everything, hiding F5 entirely). Ownership checks need multi-client play, minimum two simulated players.
- **Latency:** zero in Studio even in play mode. Any hit-validation logic that "works in playtest" is unproven until run under injected delay — the playtest pass must be labeled "at 0ms" so it never gets banked as a general pass.
- **Avatar joints:** edit rigs may show Motor6Ds while runtime spawns constraint-based rigs (the already-solved T-pose trap generalizes: any per-joint assertion must state which rig flavor it inspected).
- **StreamingEnabled:** edit sees the whole world; every client-geometry assumption made in edit is unverified until a streaming client is observed or `streaming_visibility` is computed explicitly.

**Doctrine implication:** the edit-mode-first rule holds, but for this domain the edit checks are *necessary-not-sufficient* filters — the domain's defining bugs (F2, F5, F6-at-runtime, F8, F11) live exactly in the edit/play gap, so the oracle should emit a required **runtime follow-up list** with every edit-mode pass (e.g. `hitbox_alignment ✓ (edit) → requires hit_reg_grid (play, multi-client, +latency)` ) so a green edit run can never be mistaken for a verified combat system.

---

# DOMAIN: gui-ux

# GUI/UX at Scale — Oracle Domain Report

## 1. FAILURE CATALOG

### F1. The invisible-but-Visible button (transparency chain lie)
A tween-in was supposed to animate `TextTransparency 1→0` on the "CLAIM REWARD" button, but the script errored earlier (or the tween was created and never `:Play()`ed). Every backend check passes: `Visible=true`, correct Parent, correct Text, correct Size, ZIndex fine, the click handler is connected. The player sees an empty panel with a dead zone that responds to clicks they can't aim at. A screenshot *would* catch it — if the agent happens to screenshot this panel state, at this resolution, and correctly interprets "there is supposed to be a button here." Ad-hoc `run_luau` reading `Visible` returns `true` and lies. The same class covers: ancestor `CanvasGroup.GroupTransparency=1` left at 1, `ImageTransparency=1` on an ImageButton, a parent frame `BackgroundTransparency` irrelevant but `Visible=false` three ancestors up in a folder the agent didn't inspect.

### F2. Offset-sized panel devours the phone screen
Inventory panel authored on a 1920×1080 Studio viewport as `Size = UDim2.fromOffset(600, 800)` with `AnchorPoint (0.5,0.5)` center. On desktop it's a tidy 31%-wide panel. On a 667×375 landscape phone it is **wider and taller than the entire screen**: the close button is off-screen, the player is soft-locked in the inventory. Edit-mode `AbsoluteSize` reads back against the Studio viewport and looks perfect. Screenshots only test the one resolution the capture happened at. Today the agent would need a device-emulated screenshot per resolution (~1500 tokens × 5 devices × every UI iteration).

### F3. UIListLayout silently overflows its ScrollingFrame
Shop with 40 items in a `ScrollingFrame`; `AutomaticCanvasSize=None` and `CanvasSize` was hand-set when there were 12 items. Items 29–40 exist, are `Visible`, have prices and click handlers — but the canvas can't scroll to them. Backend inventory logic passes every test; the player literally cannot buy the endgame items. A screenshot of the shop shows a healthy scrolling list (the broken part is *below the fold* — the one place screenshots never look). Variant: `AutomaticCanvasSize=Y` but the list layout's `AbsoluteContentSize` isn't propagating because items use `AutomaticSize` and the double-measurement bug leaves canvas at 0 — everything collapses on first open only at runtime.

### F4. Localization expansion truncates the one word that matters
UI authored in English. German locale: "Buy" → "Kaufen", "Settings" → "Einstellungen" (+35–60% width typical). With `TextTruncate=AtEnd` the button reads "Einstell…"; worse, with `TextScaled` inside a 90px-wide button the effective rendered text drops to ~7px — technically not truncated, just unreadable. All backend checks pass because the source `Text` property is the English string; the swap happens inside the localization pipeline at render. Screenshots in the agent's default locale will *never* show it.

### F5. The phantom click-blocker (input eaten by an invisible layer)
A full-screen `Frame` with `BackgroundTransparency=1, Active=true` — a leftover modal dimmer, a tutorial overlay that never got destroyed, or a loading screen whose `Destroy()` sat after an erroring line — sits at higher ZIndex over the whole HUD. Every button underneath: exists, visible, handler connected, `Activated` fires when invoked via `run_luau` (programmatic firing bypasses input routing!). The player taps and *nothing happens*. This is the single most vicious class: **screenshots show a perfect UI** because the blocker is invisible, and naive Luau event-firing "verifies" the button works. Only hit-testing the actual input routing catches it.

### F6. Gamepad selection graph is a roach motel
Console player opens the settings menu. `GuiService.SelectedObject` lands on the first toggle; pressing down walks into the "Credits" button whose `NextSelectionDown` was never set and whose nearest-neighbor heuristic jumps to an off-screen element in a different ScreenGui (a hidden debug panel with `Selectable=true`). Selection vanishes; B doesn't close the menu because the modal never captured focus. Player is stuck. Zero backend errors. Screenshots can't show a *traversal* problem at all — it's a graph property, invisible in any single frame. Related: menu opens and **no** default selection is assigned, so gamepad users see a menu they cannot interact with, period.

### F7. Safe-area / topbar inset eats the objective tracker
Objective HUD anchored top-center with `IgnoreGuiInset=true` and `Position = UDim2.new(0.5,0,0,4)`. On desktop it happens to clear the topbar visually. On a notched phone the device safe-area inset plus the 58px unibar overlaps it: the quest text renders *underneath* Roblox's own topbar buttons, and the top 20px is inside the camera notch. `AbsolutePosition` in edit mode reports it inside bounds because edit mode has no notch and Studio's inset differs from device insets. Mirror case: element placed *respecting* the inset but a child badge with negative offset pokes into the reserved area, and on console the TV overscan-safe region clips it.

### F8. Touch controls and HUD fight over the same thumb-space
Mobile: the dynamic thumbstick zone (bottom-left ~⅓ of screen) and the jump button (bottom-right) are injected at runtime as `TouchGui`. The agent placed the ability bar bottom-center-left — in edit mode nothing else is there, so every overlap check against *authored* GUIs passes. At runtime on touch devices, the ability buttons sit inside the thumbstick capture zone: dragging to move fires abilities, tapping abilities moves the character. Screenshots taken in edit mode or desktop play mode never contain `TouchGui` at all.

### F9. ZIndex/DisplayOrder stack rot: tooltip under the shop
Tooltip ScreenGui `DisplayOrder=0`, shop ScreenGui `DisplayOrder=0`; within-order rendering falls back to instance order, which changed when a refactor moved the tooltip module's `Instance.new` earlier. Tooltips now render *behind* the shop panel — half-visible text bleeding around the panel edges. Every property individually is "correct"; the defect only exists in the *relative* ordering. Also in class: damage numbers behind the minimap, a modal's dimmer above its own dialog (dimmer dims the dialog it's meant to frame), `ZIndexBehavior=Sibling` assumptions broken by reparenting.

### F10. Billboard nameplates: unreadable at MaxDistance, clipped in the mesh
NPC health bars as `BillboardGui` with `Size` in studs (not offset): at 10 studs they're fine; at 60 studs they shrink below one pixel of text — technically rendering, effectively gone; the "100+ NPC" horde reads as naked models. Or `StudsOffset` puts the plate at the head origin of a *skinned* mesh whose visual head is 1.2 studs higher — plate renders inside the skull, z-fighting through the face. Or `AlwaysOnTop=true` on 100 overlapping plates turns a corridor fight into an unreadable wall of bars. Edit-mode properties all read plausibly; the failure is a function of camera distance and rig geometry.

### F11. Rich text renders its own tags
Damage popup builds `"<b>"..dmg.."</b>"` but a refactor set `RichText=false` (or an unclosed `<font color=` from string interpolation with a missing `>`). Player sees literal `<b>247</b>` floating over enemies. `Text` property checks pass — the string is exactly what the code wrote. Trivial to catch symbolically, expensive and luck-based to catch via screenshot (popups live ~0.6s; capture timing must be perfect).

### F12. AutomaticSize + constraint deadlock collapses a frame to zero
`AutomaticSize=XY` on a frame whose child has `Size = UDim2.fromScale(1,1)` (child sizes from parent, parent sizes from child) — circular; frame collapses to 0×0 at runtime but shows its authored size in edit mode until a layout pass invalidates it. Or `UIAspectRatioConstraint` + `UISizeConstraint.MaxSize` intersect at zero. The settings panel simply isn't there. All instances exist with correct properties.

---

## 2. REQUIRED VOCABULARY (per scenario)

| # | Assertion (args → return) |
|---|---|
| F1 | `gui_effectively_visible(gui) → {visible:bool, blockers:[{ancestor, reason:"Visible=false"\|"GroupTransparency=1"\|"TextTransparency=1"\|"clipped_by_ancestor"\|"offscreen"}]}` — walks the full ancestor chain: Visible, all transparency channels, CanvasGroup, ClipsDescendants intersection, screen bounds. |
| F2 | `gui_layout_at(guiRoot, resolutionSet=["360x640","667x375","1024x768","1920x1080","3840x2160"]) → per-resolution {absPos, absSize, onscreen_fraction, overflows_screen:bool}` — symbolic re-solve of the UDim2/anchor/constraint tree at hypothetical viewports. Plus `gui_offscreen(gui, resolution) → {fraction_offscreen, worst_edge}`. |
| F3 | `scroll_reachable(scrollingFrame) → {content_size, canvas_size, unreachable_px, unreachable_children:[names]}` — compares layout `AbsoluteContentSize` vs canvas; `list_overflow(layoutParent) → {fits:bool, overflow_px, clipped_children}` for non-scrolling containers. |
| F4 | `text_fits(label, {locale?, pseudoloc_expand?=1.4}) → {fits:bool, truncated:bool, effective_px_size, min_readable_ok:bool(≥9px), overflow_px}` — uses `GetTextBoundsAsync` with the localized/pseudo-expanded string at target resolution; `localization_sweep(guiRoot, locales) → [violations]` batch form. |
| F5 | `hit_test(screenPoint \| gui) → {topmost_active_gui, is_target:bool, occluders:[{gui, transparency, Active}]}` — resolves the real input-routing order (ZIndex/DisplayOrder/Active/Modal), i.e. `GetGuiObjectsAtPosition` semantics; `click_reaches(button) → bool` sugar that hit-tests the button's own center. |
| F6 | `selection_graph(screenGui) → {nodes, unreachable:[gui], escapes:[{from, dir, lands_in:otherGuiOrNil}], default_selection:guiOrNil, cycles_ok:bool}` — builds the gamepad nav graph from Selectable + NextSelection* + the engine's directional heuristic; `focus_trap_ok(modal) → {traps:bool, escape_routes}` |
| F7 | `safe_area_ok(gui, deviceProfile="iphone_notch"\|"console_overscan"\|...) → {violations:[{edge, px_into_reserved}]}` — checks bounds against a table of known worst-case insets + topbar geometry per `ScreenInsets` setting. |
| F8 | `touch_zone_conflict(guiRoot) → {conflicts:[{gui, zone:"thumbstick"\|"jump"\|"camera_drag", overlap_px}]}` — overlaps authored GUIs against the known runtime TouchGui geometry per device class; also `touch_target_size(button, resolution) → {px, meets_44px:bool}`. |
| F9 | `render_order(guiA, guiB) → {above:"A"\|"B", determined_by:"DisplayOrder"\|"ZIndex"\|"instance_order", fragile:bool}` (`fragile` = tie broken by instance order); `gui_overlap(a, b, resolution?) → {overlap_px, overlap_fraction, who_renders_on_top}` |
| F10 | `billboard_readability(bb, distances=[10,30,60]) → per-distance {projected_px_height, text_readable:bool}`; `billboard_embedded(bb) → {offset_vs_visual_bounds, inside_mesh:bool}` (uses rig visual bounding geometry, not attachment origin); `billboard_density(region) → {count, stacked_overlaps}` |
| F11 | `richtext_valid(label) → {ok:bool, errors:["unclosed <b>", "tags present but RichText=false"]}` — parse the tag grammar, cross-check `RichText` flag. |
| F12 | `layout_stable(guiRoot) → {cycles:[{a,b,reason:"AutomaticSize↔Scale circular"}], constraint_deadlocks:[{gui, solved_size}], zero_size:[gui]}` |

### Consolidated vocabulary (deduplicated)

**Visibility & geometry**
- `gui_effectively_visible(gui)` — full-chain visibility verdict with named blocker
- `gui_layout_at(root, resolutions[])` — symbolic multi-resolution layout solve (the workhorse; nearly every other check takes an optional `resolution` arg and routes through it)
- `gui_offscreen(gui, resolution)` / `gui_overlap(a, b, resolution)`
- `layout_stable(root)` — circular sizing / constraint deadlocks / zero-size

**Content**
- `text_fits(label, {locale, pseudoloc_expand})` + `localization_sweep(root, locales)`
- `richtext_valid(label)`
- `image_loaded(imageGui)` — asset id resolves + preload succeeds (catches broken/moderated ids symbolically)

**Stacking & input routing**
- `render_order(a, b)` — with `fragile` flag for instance-order ties
- `hit_test(point|gui)` / `click_reaches(button)`
- `touch_zone_conflict(root)` / `touch_target_size(button, resolution)`
- `safe_area_ok(gui, deviceProfile)`

**Navigation & focus**
- `selection_graph(screenGui)` — reachability, escapes, default selection
- `focus_trap_ok(modal)` — modal blocks background input AND is escapable

**Scrolling & lists**
- `scroll_reachable(scrollingFrame)` / `list_overflow(container)`

**3D-anchored UI**
- `billboard_readability(bb, distances[])` / `billboard_embedded(bb)` / `billboard_density(region)`

**Sweep form:** every assertion should have a `*_sweep(root)` batch variant returning only violations — the agent's default call is one sweep (~50–300 tokens) replacing five device screenshots (~7500 tokens).

---

## 3. HOLES — what symbolic checking fundamentally cannot verify

1. **Readability against the live 3D background.** White HUD text over a snow biome, health bar over lava. Contrast is WCAG math *only if you know the background* — and the background is a rendered 3D scene that changes per-frame per-camera. **Why a hole:** the oracle has no rasterized backdrop; the failing pixel values don't exist until render. **Mitigation:** enforce a symbolic *policy* instead — assert every HUD text has a backing panel/stroke/shadow (`text_has_backing(label)` is checkable), and reserve one cheap screenshot for scenes flagged as high-variance.

2. **Aesthetic quality & visual hierarchy.** Is the shop *ugly*? Does the eye land on the buy button first? Spacing rhythm, color harmony, "anime feel." **Why:** these are learned perceptual judgments with no closed-form predicate; symbolic proxies (alignment grids, spacing consistency `layout_rhythm(root)`) catch sloppiness but not badness. **Mitigation:** the project's quality-rubric + curated-reference approach — vision judged against references, but only *after* all oracle checks pass, so vision spends tokens on taste, never on measurement.

3. **Animation/tween feel.** The panel slides in — but does it overshoot nauseatingly, stutter, or finish before the player perceives it opened? Easing curves can be asserted (`tween_spec_ok`), *felt smoothness* cannot. **Why:** perception of motion is temporal + subjective; frame pacing depends on real device load. **Mitigation:** symbolic bounds (duration 0.15–0.5s, no position overshoot beyond X px via sampling the easing function — that part IS oracle-able) + occasional `capture_animation` for hero transitions only.

4. **Discoverability / comprehension.** Can a new player figure out that the glowing rune is the shop button? Is the tutorial understandable? **Why:** this is a property of a human mind meeting the UI, not of the DataModel. **Mitigation:** telemetry-over-time in real playtests (funnel: % of players who open the shop in first session); short-term, an LLM "naive player" pass over screenshots is a weak but nonzero proxy.

5. **Real device fragmentation.** Actual notch geometries, Android soft-key bars, console overscan variance, GPU-specific font rasterization, on-screen keyboard covering the input box being typed into. `safe_area_ok` uses a *table of known worst cases* — the table goes stale. **Why:** ground truth lives on hardware the sidecar doesn't have. **Mitigation:** maintain the device-profile table aggressively (it's small and public), treat it as worst-case-envelope, and accept residual risk; real-device smoke test before ship.

6. **Perceived input responsiveness under load.** Button responds in the oracle's hit-test, but at runtime a `RenderStepped` handler doing O(n²) work makes taps feel 150ms late. **Why:** it's a performance distribution, not a state predicate. **Mitigation:** runtime telemetry assertion — `input_latency_p95(button, window)` measured during scripted playtest is *semi*-symbolic and should exist, but it needs play mode + load simulation to mean anything.

7. **Image *content* correctness.** `image_loaded` proves the asset fetched; it cannot prove the sword icon isn't accidentally the potion icon (wrong id, right format). **Why:** content identity is visual. **Mitigation:** naming/manifest discipline (asset-id ↔ semantic-name registry the oracle can cross-check) shrinks this to genuine art errors, which get the rubric-vision pass.

8. **Rotated-element geometry.** `Rotation ≠ 0` GuiObjects render rotated but `AbsolutePosition/AbsoluteSize` stay axis-aligned — overlap and offscreen math on engine-reported bounds is simply wrong for them. **Why:** partially a hole in the engine's reporting, not in principle — the oracle *can* do the trig itself. **Mitigation:** oracle computes rotated OBBs internally; flag any check that fell back to engine AABBs on a rotated element as `low_confidence`.

---

## 4. EDIT vs PLAY split

### Valid in edit mode (cheap tier — run on every UI mutation)
- `layout_stable`, `richtext_valid`, `text_fits`/`localization_sweep` (`GetTextBoundsAsync` works in edit), `render_order`, `gui_overlap`, `gui_offscreen`, `list_overflow`, `image_loaded`, `selection_graph` (graph structure is static), `touch_target_size`, `safe_area_ok`, `touch_zone_conflict` (against the profile table), `gui_layout_at` — **the multi-resolution solve is the crown jewel of edit mode**: pure math over the UDim2 tree, no device emulation, no play session.

### Runtime-only (play tier — run once per feature, in scripted playtest)
- `hit_test` / `click_reaches` — real input routing needs `PlayerGui` + `BasePlayerGui:GetGuiObjectsAtPosition`; edit mode has no input pipeline.
- `scroll_reachable` with `AutomaticCanvasSize` — canvas is computed by runtime layout passes.
- `focus_trap_ok` / default-selection assignment — `GuiService.SelectedObject` behavior only exists live.
- `billboard_readability` / `billboard_embedded` — needs a camera and (for skinned meshes) a deformed rig.
- `gui_effectively_visible` for anything scripts animate — tween end-states, `CanvasGroup` fades.
- `input_latency_p95` and anything load-dependent.
- Anything touching `TouchGui` for real (vs. the profile-table approximation).

### Where edit-mode state actively LIES (the trap list — oracle should refuse or warn)
1. **StarterGui ≠ PlayerGui.** Edit mode inspects the template; runtime clones it, then scripts mutate, `ResetOnSpawn` wipes, and code often builds whole panels from nothing. An edit-mode pass on StarterGui verifies a UI *no player ever sees* in its final form. Any ScreenGui whose contents are script-generated must be verified in play mode, full stop — the oracle should detect "this tree is mostly built by scripts" (few authored children, LocalScripts present) and downgrade edit-mode verdicts to `unverified_at_runtime`.
2. **Studio viewport ≠ any device.** Edit-mode `AbsoluteSize/AbsolutePosition` reflect the current Studio panel size — an aspect ratio no player has. Raw Absolute* reads in edit mode are the #1 source of false confidence today; the oracle must *never* report edit-mode Absolute* directly, only through `gui_layout_at`'s symbolic solve.
3. **GuiInset differs.** Studio's edit-mode inset ≠ device topbar/safe-area; `IgnoreGuiInset` interactions look fine in edit and collide live (F7).
4. **`AutomaticSize` in edit mode shows the last-touched state,** not the state after a fresh runtime layout pass — the F12 collapse is invisible until play.
5. **No TouchGui, no gamepad, no locale** exist in edit mode — F4/F6/F8 all *pass vacuously* if checked naively against live edit-mode state; they must be checked against models/tables (locale expansion factors, nav-graph rules, touch-zone profiles), which is exactly what the oracle formalizes.

**Doctrine fit:** the edit-tier sweep above is ~a dozen assertions, all sub-second Luau, returning a violations list in tens of tokens — it extends the existing "~9 cheap edit-mode checks" into the GUI domain and reserves play mode + capture for the runtime-only list and the taste-tier vision pass.

---

# DOMAIN: sim-perf

# Simulation & Performance at Scale — Oracle Domain Analysis

## 1. FAILURE CATALOG

### F1 — The Touched storm from a resting hitbox
Agent gives every NPC a slightly-oversized invisible hitbox part (`CanCollide=false, CanTouch=true`) that interpenetrates the ground and the NPC's own legs. `Touched` fires per contact-pair per physics step: 100 NPCs × ~5 self/ground pairs × 240Hz internal contacts ≈ tens of thousands of events/sec, each running a Luau closure that early-returns after a tag check. Every backend check passes: hitbox exists, script connected, damage works when tested on one dummy. Screenshot: NPCs standing there, perfect. Player experience: server heartbeat drops to 20Hz, everyone rubber-bands, hit registration feels drunk. Today's approach cannot see this at all — the frame *looks* identical, and ad-hoc `run_luau` would have to know to instrument the signal.

### F2 — The repath wave stall
100 NPCs each call `PathfindingService:ComputeAsync` when their target moves >4 studs. The boss moves; all 100 invalidate simultaneously; pathfinding jobs queue and the server hitches 150–400ms in a wave, every ~2 seconds, forever. Every individual path returns `Enum.PathStatus.Success`. Every NPC eventually arrives. `get_tree` is pristine. A screenshot taken between waves shows a beautiful converging crowd. Player experience: metronomic full-game hiccups. Catching this today means playtesting while somehow measuring frame time — which the agent does by… taking more screenshots that can't show time.

### F3 — The zombie-Instance leak
NPC death handler does `model:Destroy()` but the per-NPC controller table holds `RunService.Heartbeat:Connect(...)` connections and a reference to the model in an upvalue. Destroyed-but-referenced Instances plus live connections accumulate: 3 NPCs/sec spawned in the horde mode → ~10k leaked connections and ~2GB Luau heap after 40 minutes. `get_tree` shows Workspace *clean* (models are unparented — the tree actively lies). All gameplay checks pass because each individual NPC lifecycle "works." Player experience: server slowly turns to syrup, then the instance dies and everyone is kicked. No screenshot can ever catch a leak; only a delta over cycles can.

### F4 — The 10k-part sword epidemic
The agent CSG-unions a "detailed" sword: 9,400 parts, 2.1M triangles, `CollisionFidelity=Default` (precise). It verifies the sword: welded, anchored correctly, grip aligned, looks great in `capture` — genuinely does. Then `make_npc` clones it into 120 enemy hands. Draw calls and physics broadphase explode; min-spec phone renders at 6 FPS; the *server* also pays because collision geometry is precise. Every edit-mode check on the sword passed, because the checks were about correctness, not budget. This is the signature degenerate-generation failure: locally perfect, globally fatal, invisible in any single screenshot on a dev-class GPU.

### F5 — Physics that never sleeps
A decorative market scene: 600 unanchored crates/barrels stacked with 0.01-stud interpenetrations from imprecise placement. The solver jitters them at sub-visible amplitude; nothing ever reaches sleep state. Physics step cost is that of 600 permanently-awake bodies plus their contact manifolds. Screenshot: a completely static, lovely market. `get_properties` shows plausible CFrames. `anchored_ok` naïvely passes ("props are supposed to be unanchored, they're physical!"). Player experience: 4ms of every frame burned on furniture, and one Touched-enabled crate makes it F1 too.

### F6 — The streaming mirage
`StreamingEnabled=true`. The agent builds a dense boss arena (40k instances in a 200-stud radius) verified entirely in edit mode — where **everything is always loaded**. On a min-spec client the area exceeds the streaming budget: floor parts near the fight stream out mid-combat, the player falls through geometry that "exists," and the boss visually teleports as its parts pop. Every `get_tree`/`get_properties`/edit screenshot confirms the arena is perfect, because in edit mode it is. This is the purest case of edit-mode state actively lying about runtime.

### F7 — The doorway funnel pileup
Level has a 3-stud-wide gate between spawn and objective. All 100 NPC paths individually compute `Success` — they even share ~90% of their waypoints. At runtime the crowd bodyblocks in the doorway: NPCs shove, Humanoid `MoveTo` timeouts fire, half the wave stands vibrating in a scrum while pathfinding recomputes (feeding F2). Each NPC in isolation navigates flawlessly, which is exactly what the agent tested. A single screenshot of the pileup is ambiguous ("crowd near door — intended?"), and judging clumping from pixels is the kind of measurement vision is worst at.

### F8 — RenderStepped remote firehose
Client HUD script fires a `RemoteEvent` with crosshair/aim state every `RenderStepped` (~240/sec on a good machine). In Studio playtest the loopback network makes this free and everything works. Live with 20 players: ~50KB/s/player inbound, replication queue backlog, remote delivery latency climbs to seconds, then throttling drops the *combat* remotes sharing the queue. Melee hits stop registering — but the damage code is provably correct. Nothing in a screenshot or tree walk distinguishes 1Hz from 240Hz remote traffic.

### F9 — The N=5 extrapolation trap
Agent live-verifies its NPC system with 5 NPCs: pathfinding, combat, animation all confirmed. Per-NPC cost is 0.9ms/frame server-side (full Humanoid, per-NPC Heartbeat closure, precise-collision accessories, individual `Animator`s). At the designed 100-NPC wave: 90ms/frame — a 10Hz server. Every check passed honestly at N=5. Superlinear terms (NPC-vs-NPC collision pairs ≈ O(n²) when clumped — see F7) make it worse than linear extrapolation predicts. Today the only way to catch it is running the full 100-NPC playtest and *noticing* sluggishness through screenshots, which cannot encode time.

### F10 — The missed-shot debris ocean
Projectiles that miss keep flying, hit nothing (`CanCollide=false` vs terrain due to a collision-group typo), and fall past the map, where `Workspace.FallenPartsDestroyHeight` doesn't apply because the agent parented them to a Folder with anchored=true at fire time under a certain code path. 30 projectiles/sec accumulate at y=-2000. Part count grows unboundedly; replication cost grows with it. Every fired-projectile test passed (the *hits* were what got tested). No one ever screenshots y=-2000.

---

## 2. REQUIRED VOCABULARY

Per-scenario, then deduplicated.

| # | Assertion (name, args → return) | Catches |
|---|---|---|
| F1 | `event_rate(signalPath \| "Touched:<part>", window_s)` → `{events_per_s, top_sources[]}` | Touched/Heartbeat/remote storms |
| F1 | `contact_pair_count(model \| region)` → `{pairs, worst_offenders[]}` | interpenetrating hitboxes before they storm |
| F2 | `frame_time(window_s)` → `{server_ms: {p50,p95,max}, spikes:[{t, ms, top_scripts[]}]}` | hitch waves with attribution |
| F2 | `pathfind_load(window_s)` → `{computes_per_s, avg_ms, queue_max, failures}` | repath storms |
| F3 | `leak_check(spawn_fn_tag, cycles)` → `{instances_delta, connections_delta, luau_heap_delta_mb}` — run N spawn/kill cycles, force GC, diff | zombie Instances, live connections |
| F3 | `connection_count(instance \| signal)` → `int` | orphaned listeners |
| F4 | `budget(model, category)` → `{parts, triangles, unions, meshes, collision_fidelity_histogram, verdict vs category budget}` | degenerate generated content, at author time |
| F4 | `scene_projection(prototype, n)` → `{total_parts, total_tris, est_drawcalls, verdict}` | "sword × 120" before cloning |
| F5 | `awake_bodies(region?)` → `{awake, sleeping, never_slept:[names], jitter_amplitude_max}` | non-sleeping physics soup |
| F5 | `penetration_pairs(region?)` → `[{a, b, depth}]` | the micro-overlaps causing it |
| F6 | `streaming_check(position, device_budget)` → `{instances_in_radius, est_stream_state, atomic_model_violations[], floor_holes_possible: bool}` | streaming mirage, in edit mode |
| F7 | `path_congestion(paths[] \| navmesh, agent_radius)` → `{choke_points:[{pos, width, paths_through}]}` — edit-mode geometric analysis | doorway funnels before runtime |
| F7 | `crowd_state(window_s)` → `{min_separation, clumped_count, moveto_timeouts_per_s, mean_speed_vs_walkspeed}` | runtime pileup (speed ratio ≪ 1 = bodyblocked) |
| F8 | `remote_traffic(window_s)` → `[{remote, fires_per_s, kb_per_s, direction}]` + verdict vs budget | firehose remotes |
| F9 | `load_scale_probe(spawn_fn_tag, counts=[5,25,100])` → `{per_agent_ms at each N, curve: linear\|superlinear, projected_frame_ms at target N}` | extrapolation trap, measured not guessed |
| F10 | `orphan_scan()` → `{parts_outside_bounds, unparented_but_referenced, count_trend_per_min}` | debris oceans, y=-2000 |
| F10 | `growth_watch(metric, window_s)` → `{slope_per_min, verdict: flat\|linear\|unbounded}` for parts/instances/memory | any unbounded accumulation |
| — | `unyielded_loop_scan(script)` → `[{line, loop_kind, yields: bool}]` — static Luau analysis | script exhaustion before it ever runs |
| — | `sim_health(window_s)` → one-call composite: `{server_fps, physics_ms, heartbeat_ms, memory_mb, instance_count, humanoid_count}` | cheap always-run smoke check |

**Deduplicated vocabulary (14):** `event_rate`, `contact_pair_count`, `frame_time`, `pathfind_load`, `leak_check`, `connection_count`, `budget`, `scene_projection`, `awake_bodies`, `penetration_pairs`, `streaming_check`, `path_congestion`, `crowd_state`, `remote_traffic`, `load_scale_probe`, `orphan_scan`, `growth_watch`, `unyielded_loop_scan`, `sim_health` — of which the load-bearing primitives are **`frame_time`, `leak_check`, `budget`, `load_scale_probe`, `event_rate`, `growth_watch`**; most others compose from them plus geometry queries the oracle already has (`penetration_depth`, `gap_between`).

Design note: performance assertions are unlike geometry assertions — they need a **window** (sample over N seconds) and a **budget table** (per-category, per-device-tier thresholds the agent maintains as data, not vibes). Returns should always be `{measured, budget, verdict, worst_offenders[]}` so the ~50-token reply is directly actionable.

---

## 3. HOLES — what symbolic checks fundamentally cannot verify

1. **Real min-spec device performance.** Studio on a dev PC measures *server* and *dev-client* cost. GPU draw-call throughput, fill rate, thermal throttling, and mobile memory kills are properties of hardware the sidecar doesn't have. `scene_projection` estimates correlate but cannot certify 30 FPS on a 2019 Android. *Mitigation:* conservative static budgets calibrated per device tier (the budget table is the proxy for the device), plus Roblox's own client telemetry once anything ships.
2. **Perceived smoothness vs measured frame time.** p95=16ms can still *feel* bad (irregular cadence, animation-time aliasing, camera micro-stutter). Hitch *perception* is a human/vision property. *Mitigation:* `frame_time` reporting variance and max-consecutive-bad-frames, not just percentiles; accept it's a proxy.
3. **Multi-hour degradation.** `leak_check` over 50 cycles catches structural leaks, but slow drips (fragmentation, once-a-match allocations, DataStore queue growth) only manifest over hours. The agent's loop cannot afford 4-hour soaks per iteration. *Mitigation:* `growth_watch` slope extrapolation ("+2MB/min ⇒ dead in ~4h") — extrapolation is a bet, but a stated, checkable one; plus periodic long-soak runs as a scheduled background job rather than per-change.
4. **Real network conditions.** Studio playtest is loopback: zero latency, zero loss, single machine's clock. Remote throttling, replication ordering under congestion, and lag-compensation feel cannot be observed. `remote_traffic` catches *rates* (F8) but not *behavior under 150ms jitter*. *Mitigation:* rate/bandwidth budgets as hard gates (the storm is catchable even if the feel isn't) + Studio's network-simulation settings where they exist + live-server telemetry as the eventual truth.
5. **Emergent crowd behavior quality.** `crowd_state` detects a *scrum* (speed ratio, separation), but "does the horde look menacing vs look like idiots washing-machining in a corner" is aesthetic judgment over motion. *Mitigation:* symbolic pre-filters (congestion, timeout rates) to make the *one* capture_animation spent on it likely to be the interesting one.
6. **Player-shaped load.** 100 scripted NPCs are deterministic; 20 humans all dogpiling one exploit corner, spamming one remote, or building 10k parts in a sandbox game are not. Load-scale probes sample the distribution the agent *imagines*. *Mitigation:* adversarial probe presets (everyone-in-one-spot, max-rate remote spam) as named oracle scenarios; still incomplete by nature.
7. **GC and engine-internal scheduling.** Luau GC pauses and engine job scheduling are observable only as their symptoms (frame spikes with no script attribution). Cannot be asserted on directly. *Mitigation:* `frame_time` distinguishing "attributed to script X" from "unattributed" — an unattributed spike pattern is itself a reportable signal meaning "engine-side, change allocation behavior."

---

## 4. EDIT vs PLAY SPLIT

**Valid in edit mode (cheap, run always, aligns with edit-mode-first doctrine):**
- `budget`, `scene_projection` — pure content math; **this is the highest-value edit check in the domain**: catch F4 at authoring time, before anything runs.
- `penetration_pairs`, `contact_pair_count` (geometric prediction), `path_congestion` (navmesh geometry), `streaming_check` (density vs budget), `unyielded_loop_scan` (static analysis), `orphan_scan` (bounds sweep), `connection_count` on edit-time state.

**Runtime-only (meaningless or unmeasurable without stepped physics / running scripts / spawned agents):**
- `frame_time`, `event_rate`, `pathfind_load`, `leak_check`, `awake_bodies`, `crowd_state`, `remote_traffic`, `load_scale_probe`, `growth_watch`, `sim_health`. All of F1–F3, F5, F7–F10 *manifest* only at runtime; the edit-mode analogs above are predictors, not proof.

**Where edit mode actively LIES (flag these hard):**
1. **Streaming (F6):** edit mode always has 100% of instances loaded. "I can see the floor in get_tree" is *anti-evidence* — the check that matters is the budget math, and a passing edit-mode existence check must never be accepted as verification of streamed-runtime presence.
2. **Unanchored stacks (F5):** physics isn't stepped in edit mode, so a doomed 600-part stack is perfectly still and `get_properties` shows stable CFrames. Stillness in edit mode says nothing about sleep state at runtime.
3. **Loopback network (F8):** Studio playtest itself half-lies — remotes are free. A *passing playtest* doesn't clear network assertions; only `remote_traffic` rate budgets do.
4. **Clean tree ≠ no leak (F3):** `get_tree` shows the DataModel, not the Luau heap. Destroy-without-disconnect leaves zero tree evidence. Tree cleanliness must never be cited as memory verification.
5. **N=5 runtime pass ≠ N=100 pass (F9):** even *play mode* lies if run at test scale. Any per-agent system's verification is incomplete without `load_scale_probe` at design-target N.

**Doctrine amendment this implies:** edit-mode-first stays, but the domain needs a third tier — edit checks (budgets/static) → play smoke (`sim_health`, seconds) → **scaled probe** (`load_scale_probe` + `leak_check` + `growth_watch`, tens of seconds at target N) — required whenever a change touches anything spawned in multiples, connected to high-frequency signals, or fired over the network.
