# SP5 — learnings retrieval upgrade (draft for user review)

Date: 2026-07-25. Status: **IMPLEMENTED phase 1** (same day — user green-lit after review;
`sidecar/lesson_retrieval.py` + knob wiring + archive spill live, 29+2 tests green, offline
A/B passed: one on-topic save_mesh lesson recovered, one off-topic wall-lintel lesson
displaced, 13/14 stable). Knob default stays `newest`; the flip gate is one live factory
cycle under `scored` per §3.4. Materials: the live machinery (`sidecar/factory.py` `_learned_block`,
`sidecar/forever.py` `_append_method_lessons`), the store (`sidecar/store/learnings/*.json`,
68 entries / 8 files today), and the 2026-07-16 memory-stack brainstorm
(`docs/superpowers/notes/2026-07-16-memory-stack-brainstorm-transcript.txt`).

## 1. Problem (with receipts)

The learnings loop WRITES well (RETRO tier-tagged lessons, SP2b) but RECALLS naively:

1. **Recency-only injection.** `_learned_block` takes `entries[-8:]` of factory-methods plus
   `entries[-6:]` of the family bucket. A gold `capture-confirmed` lesson from 20 cycles ago
   is invisible the moment 8 newer (possibly weaker) lessons land.
2. **The cap DELETES.** `_append_method_lessons` runs `del entries[:-MAX_METHOD_LESSONS]`
   (40). Lesson #41 permanently erases lesson #1 — the "get better across cycles instead of
   staying permanently dumb" charter (SP2) is structurally violated at the store layer.
3. **Tier is rendered, not used.** `[capture-confirmed]` labels ride the prompt, but selection
   ignores tier entirely: 33/40 factory-method entries are untagged legacy, and the 3
   capture-confirmed ones get no priority.
4. **No relevance matching.** A texture rung draws the same last-6 `weapons.json` lessons as a
   grip rung, even when the one texture lesson is older than the window.

## 2. Non-goals (doctrine)

- **No external memory infrastructure** — mem0/zep/memorygraph/OpenMemory/memtrace stay OUT
  per the SP4 tripwire ("no new memory infra unless a *logged stall* demands it" —
  2026-07-16 flagship spec §Non-goals). SP5 upgrades the EXISTING git-tracked JSON store.
- **No embeddings in phase 1.** No local encoder exists in the sidecar; API embeddings add a
  network dependency + cost to every cycle for a 68-entry corpus. Token-overlap scoring is
  sufficient at this scale; embeddings are a phase-2 option gated on measured retrieval misses
  (a logged stall, same tripwire pattern).
- **No LLM-in-the-loop selection.** Scoring must be pure, deterministic, unit-testable.

## 3. Design — scored retrieval over the existing store

One new pure module: `sidecar/lesson_retrieval.py`.

### 3.1 Scoring (pure function)

```
score(lesson, query_text) =
      W_MATCH  * jaccard(tokens(lesson.text), tokens(query_text))   # relevance
    + W_TIER   * tier_rank(lesson.tier)                             # verified truth first
    + W_RECENT * recency_frac(lesson.index, n_entries)              # newest still matters
```

- `tokens()`: lowercase, strip punctuation, drop a small stopword set, keep numbers
  (magnitudes are signal in this corpus). Computed at LOAD time — the store schema does
  not change and legacy entries need no migration.
- `tier_rank`: playtest-confirmed 1.0 · capture-confirmed 0.8 · symbolic-only 0.4 ·
  untagged 0.3 (legacy prudence — untagged ≠ untrue, but unverified).
- `recency_frac`: linear index position (newest = 1.0). No timestamps needed.
- Proposed starting weights: W_MATCH 0.5, W_TIER 0.3, W_RECENT 0.2 — chosen so a
  capture-confirmed on-topic lesson beats any untagged newest lesson, while two equally
  relevant lessons tie-break by tier then recency. Weights are constants at the top of the
  module; recalibration is a one-line diff.
- `query_text` = the rung's build prompt (family + rung title + description) — already in
  hand at both injection sites.
- **Anti-Goodhart guard:** the score deliberately EXCLUDES citation/usage counts — popularity
  feedback loops would let an early lesson entrench itself. Selection depends only on content,
  verification tier, and age.

### 3.2 The cap stops deleting — archive instead

`_append_method_lessons` overflow moves to `factory-methods-archive.json` (same shape) instead
of `del`. Retrieval scores ACTIVE + ARCHIVE together; the active file stays the fast recency
pool. Same pattern for family buckets if they ever hit a cap (none capped today). The loop
stops forgetting; the archive is git-tracked history like everything else.

### 3.3 Injection sites (budget unchanged)

`_learned_block(family)` gains a `query_text` parameter and picks top-8 (methods) + top-6
(bucket) BY SCORE instead of tail-slices. Token budget in the prompt is identical — the same
14 slots, better tenants. `forever.py`'s RETRO writer is untouched (write path stays).

### 3.4 Rollout (the SP1 pattern)

Env knob `STUDIO_AGENT_LESSON_RETRIEVAL=scored|newest`, default `newest` until one live A/B
factory cycle confirms the scored block reads sane, then flip the default and record it in
HANDOFF. The knob stays as the rollback lever.

## 4. Tests

`sidecar/test_lesson_retrieval.py` (pure, no Studio):
- tokenizer: punctuation/case/stopwords/numbers-kept.
- scoring: on-topic capture-confirmed old lesson OUTRANKS off-topic untagged newest (the
  headline case); tie-breaks (tier, then recency); empty query degrades to tier+recency.
- selection: top-K stability, K > corpus, corrupt entries skipped (fail-open like
  `load_mesh_ledger`).
- archive: overflow lands in the archive file verbatim; active file holds exactly the cap;
  retrieval sees both.

## 5. Acceptance (live)

1. A/B one factory cycle on a weapons rung: the scored block must contain ≥1 lesson the
   newest-K block missed, and every included lesson must read as on-topic to the rung.
2. The 40-cap overflow demonstrably lands in the archive (append 41+, diff the files).
3. No cycle-time regression (scoring 100 entries is microseconds; assert < 10ms in tests).

## 6. Phase 2 candidates (each behind evidence, not ambition)

- Embedding retrieval IF token-overlap logs misses (the tripwire pattern — a lesson that
  should have fired, didn't, and keyword overlap could not have matched it).
- Cross-bucket retrieval (a weapons rung borrowing an environment lesson) IF a concrete miss
  is logged.
- Auto-tiering legacy untagged entries by replaying their origin cycles — likely not worth
  it; they age out of relevance naturally under scoring.
