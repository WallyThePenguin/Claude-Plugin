# SP2 — the Roblox Oracle (phase 1) — design

Date: 2026-07-10. Status: approved (decisions made interactively across the 2026-07-10 session; gates delegated by the user — "do it for me"). Foundation docs: red-team `docs/superpowers/notes/2026-07-10-roblox-oracle-redteam.md` (six domain catalogs, ~120-assertion vocabulary, holes); SP1 spec/plan (the SDK loop this rides on).

## 1. Goal

A live symbolic assertion layer over the engine so the agent MEASURES instead of eyeballing screenshots: named deterministic checks (~50-token results) replace most measurement captures (~1.5k tokens each, unreliable for measurements). The memtrace PATTERN (query cheaply, never re-derive), not its architecture: live queries against the DataModel, never a cached index.

The user's bar: **the factories and forever sessions must get better across cycles instead of staying permanently dumb.** So the oracle is the assertion tools PLUS their coupling into the improvement loop (verification-tiered lessons, stochastic capture audits, gap-mining, blindspot manifests).

Phase 1 (this spec's build scope): the melee-weapon + animation vocabulary that kills the live pain observed in the SP1 A/B (badly-held sword, unverifiable swing) — semantic frames, grip/axis/intersection/clip checks — wired into the factory's melee-weapon and animation playbooks. The architecture serves all domains; GUI (`gui_layout_at` multi-resolution solve) is phase 2.

## 2. Design mandates (red-team-derived; spec-mandatory)

1. **Validity-domain tag** on every check (`EDIT_OK | PLAY_ONLY | EDIT_MISLEADS`) + required runtime twins; suites refuse green while an `EDIT_MISLEADS`-class check lacks its twin. Phase 1 ships EDIT_OK checks (incl. flip-book kinematic clip sampling); PLAY_ONLY twins are declared in the registry now, implemented phase 2+.
2. **Three-valued verdicts** `PASS | FAIL | UNKNOWN(reason)`; UNKNOWN never satisfies a suite; suite output counts UNKNOWNs as loudly as FAILs.
3. **Context argument** (`edit | server | client`) in the registry schema from day one; phase 1 executes `edit` only; GUI/camera checks in server context are hard errors (phase 2).
4. **Temporal + scale assertions** (`stable_over`, `load_scale_probe`, …) are registry-declared, phase 2+ implemented; the 3-tier doctrine (edit checks → play smoke → scaled probe) is written into the playbooks now.
5. **Raw magnitudes + verdict** in every result, never bare booleans; `oracle_cost_ms` on every result; `geometry ∈ {bbox, collision}` argument where it matters (render-mesh geometry is a declared hole in phase 1).
6. **Semantic frames — the phase-1 keystone (user's design, 2026-07-10): declare semantics at BUILD time, never infer at verify time.** Every asset carries a machine-readable semantic frame via native primitives — Attachments for points (`Semantic_Grip`, `Semantic_BladeTip`), attributes + CollectionService tags for directions and part roles (`SemanticFrame` JSON attribute holding e.g. `blade_dir`/`edge_dir` as Handle-local unit vectors; tags `hilt`/`blade`/`guard`/`pommel`) — governed by a per-family schema (melee: grip + blade_dir + edge_dir + tip; bow: grip + string_dir; …). The SAME frame is consumed by building (grip_tool aligns `Semantic_Grip` to the hand — mis-grips become impossible, not just detectable), verifying (grip/axis/arc checks = exact math against declarations), animating (arc checks sample the declared tip), and future imports (SP3: vision places annotations once per asset, then never again). **Anti-lie layer (mandatory):** `frame_consistent` cross-validates declarations against measured geometry (blade_dir aligns with the long axis of blade-tagged parts within tolerance; Semantic_BladeTip near the extremum along blade_dir; Semantic_Grip inside hilt-tagged geometry), plus the stochastic capture audit — declared truth, checked against measured truth, audited against seen truth.

## 3. Architecture

**All checks execute in plugin Luau, exposed as FOUR bridge tools** (not ~15 — schema weight; and not sidecar-side math — the sidecar lacks the live DataModel; snapshots would violate the live-queries principle):

- `oracle_check {check: string, args: object}` → one registry check. Result: `{check, verdict: PASS|FAIL|UNKNOWN, reason?, magnitudes: {...}, validity: EDIT_OK|.., cost_ms}`.
- `oracle_suite {family: string, target: string}` → runs the family's suite. Result: per-check results + `{passed, failed, unknown}` counts + **blindspot manifest** (`notAsserted`: rubric/schema items with no applicable check — all-green must be unreadable as "done") + frame-coverage report.
- `read_frame {target: string}` → the asset's semantic frame (declared points/dirs/roles + which schema fields are missing).
- `stamp_frame {target: string, frame: object}` → validates against the family schema and writes attachments/attributes/tags. Rejects unknown fields; reports what was stamped.

**New plugin modules** (house pattern, one responsibility each):
- `src/Tools/OracleFrames.luau` — family schemas (data), stamp/read/validate; `frame_consistent` lives here (it is frame-vs-geometry, not generic geometry).
- `src/Tools/OracleChecks.luau` — the check registry: `{name → {fn, validity, context, description, family_applicability}}`. Phase-1 checks (all EDIT_OK): `intersects`, `penetration_depth`, `gap_between` (bbox|collision via GetPartsInPart/bounding math), `axis_of`/`alignment` (returns dot + end-to-end skew in studs — scale-aware), `scale_ratio` (vs stored category norms), `grip_sane` (composite: weld aligns Semantic_Grip to hand attachment; blade_dir points out of fist; hand not inside blade geometry), `joint_census`/`rig_uniform`/`rig_channel_check` (Motor6D vs constraint T-pose trap), `clip_joint_mask`, `clip_arc_of` (flip-book kinematic posing over keyframes — samples the DECLARED Semantic_BladeTip: sweep degrees, plane normal, max reach), `clip_self_intersect` (penetration over sampled keyframes), `frame_consistent`, `anchored_ok`.
- `src/Tools/Oracle.luau` — the four tool definitions + suite runner + manifest assembly; registered in `Tools/init.luau`.

**Existing tool integration (build-time stamping):** `make_tool` auto-stamps what it can derive (Handle → grip candidate) and reports missing schema fields; `grip_tool` CONSUMES `Semantic_Grip` when present (alignment mode) and falls back to offsets when absent (compat), stamping the resulting grip back into the frame. `generate_mesh`/`author_mesh` report that stamping is required next.

**Factory coupling (`sidecar/factory.py` + `forever.py` — modifiable in SP2; the SP1 "untouched" constraint applied to `agent_loop.py` only and is retired for orchestrators):**
- melee-weapon + animation PLAYBOOKS: build procedure gains "stamp_frame before make_tool; grip via frame alignment"; verify procedure becomes ORACLE-FIRST — `oracle_suite` before any capture; captures become targeted taste checks on what the suite flags, plus final sign-off.
- VERIFY prompt: evidence MUST quote suite magnitudes (numbers, not adjectives).
- **Stochastic capture audit:** every Nth factory run (N=5, keyed on the run token) VERIFY runs in AUDIT MODE — full old-style capture review even when the suite is green; suite-vs-capture disagreements are filed to `factory/tooling-issues.json` as ORACLE BUGS (feeding MECHANIC; this is gap-mining).
- **Verification-tiered lessons:** RETRO's `FACTORY_RETRO_JSON` schema gains `tier: symbolic-only | capture-confirmed | playtest-confirmed` per lesson; `forever._append_lessons` stores it; `factory._learned_block` renders it; symbolic-only lessons are prefixed as such in prompts and can never be cited as settled method (prompt rule).

## 4. Data flow

BUILD: agent builds → `stamp_frame` (schema-guided) → `grip_tool` aligns to frame → `oracle_suite` self-check → sentinel. VERIFY: `oracle_suite` (numbers into evidence) → targeted captures only for suite-flagged items + aesthetics → sentinel with magnitudes. RETRO: lessons carry tiers. AUDIT runs add the capture comparison + oracle-bug filing. All results ride the existing bridge/tool_result path — image economics unchanged for the capture parts, replaced for the measurement parts.

## 5. Error handling

Checks never throw to the caller: internal errors → `UNKNOWN(internal: <msg>)` with cost_ms. Unknown check name / family → explicit error result listing available names (discoverability). `stamp_frame` validation failures name the offending field and the schema. Suites cap per-check time (2s soft) and report overruns as UNKNOWN(timeout) — the oracle must never wedge the single-slot bridge.

## 6. Testing

- Luau-side (cannot run outside Studio): (a) compile gating on the new modules via the existing hot-reload/compile-check path, (b) an in-registry `__selftest` check that builds known-good and known-bad fixtures in the live place (correct sword, 90°-rotated grip, blade-through-torso pose, mixed Motor6D/constraint rig), runs the relevant checks against each, asserts expected verdicts, and cleans up — invoked over the bridge (`oracle_check {check:"__selftest"}`) manually and by the acceptance demo.
- Python-side: `sidecar/test_factory.py`/`test_forever.py` additions for tier parsing, audit-mode selection (run_token % 5), and prompt-assembly containing the oracle-first blocks. Dependency-free script style, as always.

## 7. Acceptance (the user's bar, verified live)

1. A factory weapon-sword cycle where VERIFY's grip/animation verdict quotes oracle magnitudes in evidence.
2. A deliberately mis-gripped sword (grip rotated 90°) is caught TWICE: impossible to author via `grip_tool` frame alignment, AND `grip_sane` FAILs it (with the axis error in degrees) when authored by hand around the tools — no capture involved.
3. RETRO banks tier-tagged lessons; the suite output shows the blindspot manifest; an audit-mode run demonstrates the suite-vs-capture comparison path.
4. Two forever cycles consuming oracle results.

## 8. Non-goals (phase 1)

GUI/perf/net/streaming domains (registry declares them; phase 2+); PLAY_ONLY twins beyond declarations; render-mesh geometry checks; client-context runner; retrieval upgrades to the learnings store (SP5); any change to `sidecar/agent_loop.py` or `sdk_loop.py`.
