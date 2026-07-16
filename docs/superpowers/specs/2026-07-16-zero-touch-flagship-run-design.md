# Zero-Touch Flagship Run — Design

Date: 2026-07-16. Status: approved in-session (the director-review arc). This run consumes the shelf; it does not grow it.

## Goal

Build ONE complete game from scratch with the minimum possible human touches — and MEASURE them.

The project metric, effective today: **interventions-per-game**, trending to zero across runs. This run establishes the baseline number. "Claude makes the game without me" is not a feature to build toward; it is this number going to zero with receipts.

## The metric

Every human touch is logged in `factory/intervention-ledger.json`, classified:

- `quality-catch` — human caught a defect the checks missed → residue MUST be a new oracle check or doctrine note
- `taste` — human defined or overrode "good" → residue MUST be a rubric/exemplar entry
- `platform-gate` — Roblox requires a human (security ticks, moderation approvals, Studio focus, account auth) → batched, counted separately, never eliminable
- `errand` — accounts / installs / keys
- `direction` — scope decisions (counted, not shamed)

**Standing rule: no intervention without residue.** Every touch must leave behind the check, rubric, tool, or doctrine that makes it the last touch of its kind. The same finger is never lifted twice.

## Concept (system-chosen default; a user veto costs 1 `taste` entry)

**FORGE ARENA** — round-based melee arena. The armory is GENERATED: conveyor weapons (text → mesh → painted texture → grip → durable asset), Kimodo swing sets per weapon, `bind_behavior` states, `bind_hitbox` damage, `make_npc` enemies scaling per wave, an articulated boss weapon (the snake-sword class). Between rounds: forge/shop meta (NEON GAUNTLET GUI lineage).

Chosen because it exercises the entire existing shelf (roadmap #1–#5, the conveyor, the animation leg, the oracle suite) and will expose the true gaps honestly — predicted: map/environment generation, audio, and the deferred mesh-scale contract (`task_22cf4d28`). Predictions are written down so the run can prove them wrong.

## Protocol

1. **Bootstrap (the user's one setup touch, class `platform-gate`):** start the sidecar (`scripts/studio-agent.ps1`), open Studio on a FRESH Baseplate experience (standing rule: never the user's saved places), plugin connected.
2. `game_pull` banking from the first commit — the `game/` tree in git is the record of progression.
3. Phases, each ending in RUNTIME evidence (playtest logs, oracle suite, captures) before the next begins:
   - P1 core loop skeleton — arena, rounds, spawn/kill/win (RoundLoop pattern exists)
   - P2 armory — minimum 3 conveyor weapons, gripped, swing clips, hitboxes
   - P3 enemies — NPC variety, scaling waves
   - P4 boss — articulated weapon, intro moment
   - P5 GUI/meta — HUD, between-round forge/shop
   - P6 polish — VFX/audio (expected to expose the stack's gaps; stalls here are the point)
   - P7 stranger playtest
4. Every stall or defect: ledger entry with class + residue action, before work proceeds.
5. **Success bar:** a stranger plays 10 minutes unprompted, and the user's honest read beats "generic AI game." Evaluation date per the director review: **2026-08-15.**

## Non-goals (the tripwire doctrine stands)

- No new memory infrastructure (memtrace, OpenMemory, mem0, zep) unless a *logged stall* demands it — SP4 trigger conditions are the gate.
- No conveyor upgrades unless a phase is blocked on one.
- Vault split / HANDOFF surgery rides in idle time, never on this run's critical path.
- Asset provenance cards (from the 2026-07-16 memory-stack brainstorm): good idea, adopted as a P2 pipeline step ONLY if it costs <1 hour — the conveyor manifests are already 80% of it.
