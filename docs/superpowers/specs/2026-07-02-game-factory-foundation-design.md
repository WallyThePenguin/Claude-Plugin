# Game Factory — Foundation (2026-07-02)

## Purpose

The user's mandate: make the agent LEARN to make games (models, weapons, systems — everything)
autonomously, compoundingly — not just take instructions. Weight fine-tuning is impossible
(settled), so all learning lives in ARTIFACTS. The flywheel: build → verify with ground truth →
extract capital → bank → repeat, where each iteration starts richer.

A 3-skeptic adversarial panel (2026-07-01, session artifact `tasks/w2rgad3e8.output`) reshaped
the design. Its binding verdicts, now locked in:

1. **Exemplars are the one HUMAN-GATED store.** The corpus is 100% self-minted today; feeding
   passed builds back as calibration anchors ratchets the grader to the agent's own mediocrity
   (negative compounding). Self-captures enter only as provisional/minority; the calibration
   spine is external clean-licensed material + the user's morning thumbs-up.
2. **Test-harness quarantine.** The RoundLoop VICTORY was TestAutoKill-driven — a probe asserting
   what the code does, not what the game should feel like. Reserved namespace `StudioAgentTest_*`
   (names AND attributes); a grep gate BLOCKS extraction/minting when a test symbol appears in an
   artifact. Behavior probes must be player-level (`playtest_act` input), not code assertions.
3. **Quarantine, don't degrade.** An iteration whose visual/playtest oracle was unavailable is
   UNVERIFIED, never PASSED. All extracted capital lands in STAGING with raw evidence attached;
   the live corpus/library ingests only via the human promotion pass. Taste criteria report
   UNGRADED, never PASS; an artifact with UNGRADED taste can't tier good+ or mint an exemplar.
4. **No unmanned first ascents.** A new curriculum rung needs one supervised session to build its
   probe/oracle; unattended batches run VARIATIONS of proven rungs. Curriculum edits are
   propose-only (human approves).
5. **Substrate-neutral capital.** The code-first inversion (path C) will replace the tool
   substrate; recipes denominated in tool invocations rot. So: modules as plain `.luau` files
   under git; recipes at engine-technique level; a staleness field naming the tool signatures a
   recipe depends on.
6. **Economics honesty.** Overnight batches are NOT real until the loop leaves the uncached Luau
   plugin (the path-C/sidecar-loop convergence). v1 = attended, measured iterations.

## This spec's scope: the two SUBSTRATE-NEUTRAL foundation pieces

(The factory workflow itself and the curriculum come after path-C design lands.)

### 1. Sidecar file store (`/store`) — unbounded, git-versioned knowledge

`sidecar/store.py`, storage at `sidecar/store/<kind>/<id>.json` (git-tracked — knowledge under
version control, diffable, revertable).

- Kinds (allowlist): `learnings`, `skills`, `staging`.
- Ids: `[a-z0-9-]{1,64}` (sanitized; traversal-proof by construction).
- API (mirrors the sidecar's existing style, stdlib-only):
  - `GET  /store/<kind>`            → `{"items":[{"id","size","mtime"}]}`
  - `GET  /store/<kind>/<id>`       → the JSON body (404 if absent)
  - `POST /store/<kind>/<id>`       → write body atomically (tmp+rename); `{"ok":true}`
  - `DELETE /store/<kind>/<id>`     → `{"ok":true,"existed":bool}`
- `test_store.py` covers: roundtrip, list, delete, bad kind, bad id, traversal attempts, atomicity
  (no partial file on simulated failure).

### 2. Unbounded learnings + durable skills

**Learnings** — the capped plugin-settings store becomes a RECENCY WINDOW, not the whole memory:
- `learn(category, text)` appends to the local bucket exactly as today (the always-on
  "# Priority learnings" preamble stays small and rides every send) AND appends
  `{id, text, createdAt}` to the sidecar archive `learnings/<category>.json` (never evicted).
  Local FIFO eviction no longer loses the lesson — it just rotates out of the always-on block.
  Sidecar-down → local behavior unchanged, note appended to the tool result (fail-open, honest).
- `unlearn(category, id)` removes locally AND tombstones in the archive (entry gains
  `retired=true` — history preserved for consolidation, hidden from recall).
- New tool **`recall_learnings(category, query?)`** reads the FULL archive (retired entries
  excluded), optional substring filter, capped render (~100 entries). This is the retrieval path:
  the preamble carries the recent window; recall reaches everything ever learned.
- Archive ids are namespaced from local ids (`os.time()*1000`-style unique) so archive identity
  never collides with the local rotating ids. The archive entry stores BOTH (`id` unique,
  `localId` best-effort) and unlearn matches on `localId` newest-first.

**Skills** — `save_skill` mirrors the skill to `skills/<name>.json`; `delete_skill` removes it;
on boot the SkillStore hydrates user skills from the sidecar when available (sidecar wins over
plugin settings; settings remain the offline cache). Unbounded count/size (settings cap applies
only to the cache copy).

**Wiring:** `recall_learnings` registered (RELAY class — it must run where learn/unlearn run);
RelaySpec updated; SystemPrompt: the Priority-learnings + Skills sections mention the archive +
recall path.

### 3. StudioAgentRuntime v0 — the hardest-compounding store

Extract the four stamped RUNTIME_SOURCE templates (`Tools/ItemAnim`, `Tools/ItemBehavior`,
`Tools/ItemHit` client+server, `Tools/Npc`) into **plain `.luau` files in the repo** at
`runtime/`:

- `runtime/BehaviorRuntime.luau` — the equip/anim/state machine (supersedes AnimRuntime when both present, as today)
- `runtime/AnimRuntime.luau` — anim-only runtime
- `runtime/HitClient.luau`, `runtime/HitServer.luau`
- `runtime/NpcAI.luau`
- `runtime/VERSION` (an integer, bumped on any runtime change)

Delivery: the sidecar serves `GET /runtime` → `{version, modules:{name: source}}` (same pattern
as `/reload`'s src read). A plugin `RuntimeInstaller` writes/updates
`ReplicatedStorage.StudioAgentRuntime` (a Folder of ModuleScripts + a `Version` IntValue) —
idempotent, skip-if-same-version. The bind_* tools call `ensureInstalled(context)` before binding.

The bind_* tools then write THIN launcher scripts (3–6 lines: wait for the runtime folder,
`require(...Runtime.X).attach(script.Parent)`) instead of full stamped sources; all tuning stays
in Attributes exactly as today (HitDamage/HitReach/HitCooldown, behavior durations, NPC config).
Launchers keep today's names (`ItemBehaviorRuntime`, `ItemHitClient`, `ItemHitServer`, `NpcAI`,
`ItemAnimRuntime`) so PlayBridge verbs and specs keep working. The modules expose
`attach(instance)` and contain the exact logic of the current templates (a mechanical extraction,
NOT a rewrite — behavior-preserving).

Why this compounds: every improvement to a runtime module upgrades EVERY future (and, after a
re-install, existing) build; the factory's step-4b deposits (new systems: projectiles, inventory,
shop) join the same library; the files are git-versioned and survive the path-C inversion
unchanged (they become the Rojo project's shared library).

Sidecar-down at bind time → the tools fall back to today's full-source stamping (the templates
stay in the repo as the fallback payload) so nothing hard-depends on the sidecar.

### Oracles

selene 0/0 · rojo green · `test_store.py` green · ScriptEdit/Relay/Compactor specs stay green ·
new `RuntimeInstallerSpec` (pure parts) · live: learn→archive→recall roundtrip via bridge;
save_skill→file; runtime install → bind_behavior/bind_hitbox/make_npc on a fresh item → the
EXISTING playtest verbs (`act record`, `shit`, `snpc`) re-verify items #3/#4/#5 behavior
end-to-end. Commits local `master`, never pushed. Adversarial review of the full diff at the end.

## Explicitly deferred (next sessions)

- The factory workflow + seeded curriculum (after path-C design).
- The path-C (code-first/Rojo) design session itself.
- External exemplar ingestion pipeline + the promotion UI (morning review works off the staging
  folder directly for now).
- Moving the agent loop into the sidecar (economics fix).
