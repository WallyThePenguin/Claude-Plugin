# Studio Agent — Cross-Session Memory Design

- **Date:** 2026-06-17
- **Status:** Approved design (calls delegated to the implementer) — pending spec self-review, then
  implementation plan.
- **Relates to:** `HANDOFF.md`; the capability-parity roadmap (this is feature #5, after vision,
  compaction, subagents, web access, task tracking).
- **Scope:** ONE feature. Reusable build "skills"/recipes are a separate, later spec.

## Goal

Give the in-Studio agent **memory that persists across chat sessions** — distilled, durable knowledge
it writes during one chat and recalls automatically in later chats — the way Claude Code keeps memory
files, scoped to Roblox Studio. Two kinds of knowledge, kept separate:

- **Global** — reusable across every place the user opens: their preferences, build techniques that
  worked, general Roblox gotchas. Follows the *user*, not a place.
- **Per-game** — understanding of one specific place: its architecture, naming conventions, where
  systems live, decisions made. Meaningful only *in that place*.

Keeping both, separated, is the whole point: global-only would blend several games' architectures into
one misleading soup; per-game-only would forget a hard-won technique the moment a new place opens. This
mirrors the orchestrator's user-global + project memory split.

## Key decisions (settled in brainstorming; design calls delegated to the implementer)

1. **Two scopes, both injected.** `global` and `game` (per `game.GameId`). The agent picks the scope
   when remembering; both are recalled (injected into the system prompt) every send, under clear
   headers. Unsaved places have `GameId == 0` → a shared "unsaved" game bucket (documented quirk).
2. **State in a dedicated `Memory` module held in `deps`**, persisted via `plugin:SetSetting` (the same
   mechanism as `Config`/`Sessions`). `SetSetting` is per-install, so the global bucket is one key and
   each game is its own key — no cross-place leakage of game facts.
3. **Recall = always-on injection, not a search tool.** `Memory.promptBlock()` renders the (capped)
   entries and is appended to the base system prompt at the start of each Send. Simpler than an
   on-demand recall tool and matches the orchestrator's "MEMORY.md is always loaded" model. Caps keep
   the always-on cost bounded (~3k tokens worst case).
4. **Two tools: `remember` and `forget`.** `remember(text, scope?)` (scope defaults to `game`);
   `forget(scope, id)` removes one entry. Both `destructive = false` and **parent-only** — not in the
   subagent `READ_ONLY` allowlist, and a subagent's tool context carries no `memory` (read-only
   children must not mutate durable memory). Exactly the isolation pattern used by `update_tasks`.
5. **Memory writes are durable and immediate — NOT rolled back with the conversation.** Unlike
   `taskList` (turn-scoped UI state restored on a non-clean exit), a memory write goes straight to
   `SetSetting` and stays, even if the turn later errors or is cancelled. A remembered fact is still
   true regardless of whether the turn that wrote it completed cleanly — this mirrors how DataModel
   edits persist (undoable, not auto-reverted). Memory rides in the *system* prompt, not the message
   history, so compaction and conversation rollback never touch it.
6. **Caps + FIFO overflow, reported.** `MAX_ENTRIES = 25` per bucket, `MAX_TEXT = 240` chars per entry
   (UTF-8-safe truncation). When a bucket is full, adding drops the OLDEST entry (FIFO) and the tool
   result says so (never a silent loss). The agent is told to `forget` stale facts to make room
   deliberately.
7. **A Memory viewer in the panel** (transparency + control): a toggle (like History) listing both
   buckets read-only, each entry row with a small `✕` to forget it.

## Non-goals (YAGNI)

- No automatic distillation/summarization of memory (the agent decides what to remember, like the
  orchestrator). No background consolidation pass in v1.
- No semantic search / embeddings / recall tool — always-on injection with modest caps.
- No tags/categories beyond the two scopes; no priorities; no per-entry edit (forget + re-remember).
- No cross-game "list all games' memory" view — the viewer shows global + the current game only.
- No config knobs for the caps in v1 (module constants; can be promoted to `Config` later).

## Architecture

### New modules

- **`src/Memory.luau`** — the store + the pure helpers the tools and the spec share. One instance in
  `deps.memory`.
  - A `Bucket` is `{ entries: { Entry }, ... }` where `Entry = { id: number, text: string,
    createdAt: number }`. `id` is a small integer unique within the bucket (assigned as `maxExistingId
    + 1`, so no separate counter to persist; restarts at 1 after a clear).
  - **Pure helpers** (no `self`, no DataModel — directly unit-testable):
    - `Memory.normalizeText(text) -> string?` — trim; `nil` if empty/non-string; UTF-8-safe truncate
      to `MAX_TEXT`.
    - `Memory.addTo(entries, text, now) -> ({ Entry }, note: string)` — append a normalized entry
      (id = max+1, createdAt = now); FIFO-drop the oldest if over `MAX_ENTRIES`; return the new array +
      a summary note (incl. any "dropped oldest" notice). Invalid text → unchanged array + an error note.
    - `Memory.forgetFrom(entries, id) -> ({ Entry }, removed: boolean)`.
    - `Memory.renderBucket(entries) -> string` — `"#<id> <text>"` lines, or `"(none)"`.
  - **Pinned constants** (`Memory` module-level): `MAX_ENTRIES = 25`, `MAX_TEXT = 240`.
  - **Instance methods** (the live store; resolve the current game internally):
    - `Memory.new(plugin) -> Memory`.
    - `gameKey()` — `SETTING_PREFIX .. "memory_game_" .. tostring(game.GameId)`; `globalKey()` —
      `SETTING_PREFIX .. "memory_global"`. (`now()` is `os.time()`.)
    - `add(self, scope, text) -> string` — load the bucket for `scope` (`"global"` or `"game"`),
      `addTo`, persist, return the note. Unknown scope coerced to `"game"`.
    - `forget(self, scope, id) -> string` — load, `forgetFrom`, persist, return a confirmation.
    - `list(self, scope) -> { Entry }` — the bucket's entries (for the viewer).
    - `clear(self, scope)` — empty a bucket (used by the viewer if a bulk clear is added; not required).
    - `promptBlock(self) -> string` — render BOTH buckets under headers; `""` if both empty so nothing
      is injected when there's no memory.
  - Persistence: load reads `SetSetting(key)`; a missing/garbage value resolves to an empty bucket and
    is re-normalized defensively (an old/corrupt blob can never inject a malformed entry).
- **`src/Tools/Memory.luau`** — exports `descriptors` with `remember` and `forget` (same Descriptor
  shape as `Tasks`/`Subagents`/`Web`).
  - `remember.run(input, context)`: nil `context.memory` → error string (subagent). Else
    `context.memory:add(scope, text)` where `scope = input.scope` (default `"game"`); return the note.
  - `forget.run(input, context)`: `context.memory:forget(scope, id)`; return the confirmation.
  - Never throws (`Tools.dispatch` pcall-wraps as a backstop too).
- **`src/MemorySpec.luau`** — in-Studio self-test (mirrors `TaskListSpec`/`WebSpec`) over the PURE
  helpers ONLY (the bulk of the logic; no plugin shim needed): `normalizeText`
  (empty/non-string/whitespace/over-`MAX_TEXT` UTF-8 truncation), `addTo` (id = max+1, FIFO drop at
  `MAX_ENTRIES`+1 WITH a reported note, invalid-text rejected leaving the array unchanged), `forgetFrom`
  (hit removes + miss is a no-op), `renderBucket` (`"#<id> <text>"` format + `"(none)"` when empty).
  Returns `{ passed, total, failed }`. Scope-keying (per-`GameId` separation) and `SetSetting`
  persistence are instance concerns verified live in Studio, not in this pure spec.

### Touched modules

- **`src/Tools/init.luau`** — require `Memory`, append its descriptors (after `Tasks`).
- **`src/AgentLoop.luau`** —
  - `runLoop`/`AgentLoop.send` gain a `memory` parameter (threaded from the Widget via `deps`, after
    `taskList`).
  - `toolContext` gains `memory = memory`.
  - At the top of `runLoop`, compose the effective system prompt:
    `local sys = systemPrompt; if memory ~= nil then local block = memory:promptBlock(); if block ~= ""
    then sys = systemPrompt .. "\n" .. block end end` — and pass `sys` (not `systemPrompt`) to
    `Retry.sendWithRetry`. **No rollback handling for memory** (decision 5).
- **`src/init.server.luau`** — require `Memory`; add `memory = Memory.new(plugin)` to `deps`.
- **`src/UI/Widget.luau`** — pass `deps.memory` to `agentLoop.send`; add a **Memory** toggle button +
  a memory view (reusing the `scroller()`/`showSessions` pattern) listing both buckets with a per-entry
  `✕` forget; refresh the view after a `remember`/`forget`. The agent's live `remember`/`forget` happen
  through the tool; the panel re-renders the memory view if it is open (a `memory` event from the loop,
  optional) or on next open.
- **`src/SystemPrompt.luau`** — a "# Memory across sessions" section in `BASE` + the `remember`/`forget`
  tool lines. The SUBAGENT prompt is unchanged (children have no memory tools).
- **`src/Config.luau`** — no new keys (caps are `Memory` constants).

### Data flow

```
model → remember { text, scope="game" }
      → Tools.dispatch → Memory.run → context.memory:add("game", text)
          → load game bucket → addTo (id, FIFO cap) → SetSetting(gameKey)
          → returns a note (incl. any "dropped oldest")  -- tool_result
      → (optional) loop emits "memory" → Widget refreshes the viewer if open

Each Send:  runLoop composes  system = base .. memory:promptBlock()
            promptBlock renders:  "# Remembered (global)\n#1 ...\n# Remembered about this game\n#1 ..."

On Studio open / new place:  Memory.new resolves game.GameId; promptBlock loads that game's bucket
On a non-clean exit:  memory is NOT rolled back (durable, already persisted)
```

## UI

A **Memory** view toggled from the control row (alongside New chat / History), reusing the existing
scroller + show/hide pattern (`showSessions`-style). It shows two sections — **GLOBAL** and **THIS
GAME** — each listing its entries; every row shows the text and a small `✕` button that calls
`memory:forget(scope, id)` and refreshes the row list. Empty sections show "(none)". The view is about
transparency and control; the agent reads/writes memory through the tools and the always-on injection,
not this panel. The checklist's reflow machinery is independent — the Memory view, like the sessions
view, simply swaps with the transcript region (and the task checklist hides while it is shown, same as
in History).

## Correctness rules / edge cases

- **Total dispatch:** `remember`/`forget` never throw; a nil `memory` (subagent) or malformed input
  returns an `is_error` string.
- **Empty-object encoding:** `remember` always carries a non-empty `{text=...}` input; `forget` carries
  `{scope,id}`. Neither can serialize to `[]`, so the `JSONEncode({}) -> []` tool_use-input gotcha
  cannot fire.
- **UTF-8 truncation:** `normalizeText` truncates on a codepoint boundary (same helper shape as
  `TaskList`), so a stored fact is never invalid UTF-8 (which could break `JSONEncode` of the setting /
  the injected prompt).
- **Defensive load:** a missing/old/corrupt bucket blob resolves to empty and is re-normalized, so it
  can never inject a malformed entry into the prompt or the viewer.
- **Scope isolation:** game facts are keyed by `GameId`, so opening a different place injects a
  different game bucket; the global bucket is constant. No bleed.
- **Compaction / rollback independence:** memory is in the *system* prompt and persisted immediately,
  outside the message history — no compaction or conversation-rollback path touches it (decision 5).
- **Token cost:** `promptBlock` is injected every request. `MAX_ENTRIES`×`MAX_TEXT` per bucket bounds
  it (~25×240×2 ≈ 12KB ≈ 3k tokens worst case); `lastPromptTokens` (which the compactor reads) already
  counts system tokens, so the threshold accounts for memory.

## System prompt addition (summary)

A "# Memory across sessions" section: facts under the injected "Remembered" headers are recalled from
past chats. Use `remember` for DURABLE, reusable knowledge only — this game's architecture /
conventions / decisions → `scope="game"`; your preferences + reusable techniques and Roblox gotchas →
`scope="global"`. Keep each fact one concise sentence; don't remember the obvious, the ephemeral, or
something already visible in the DataModel. Use `forget` to drop a fact that's now wrong. Plus the
one-line `remember`/`forget` entries in the tools list.

## Testing

- **Static:** `selene src` (0 errors), `stylua --check src`, `rojo build` — as every feature.
- **`MemorySpec`** (in-Studio): the pure `normalizeText`/`addTo`/`forgetFrom`/`renderBucket` surface
  (the bulk of the logic, fully self-testable without a DataModel).
- **Adversarial review** (Workflow, like prior features) over the diff: focus on the AgentLoop
  system-prompt composition (no regression to send/retry/compaction), the FIFO/id logic, the
  SetSetting persistence + defensive load, the subagent-isolation invariant, and the Widget memory view.
- **Live-verify in Studio** (computer-use): `remember` a game fact + a global fact; start a NEW chat
  and confirm the agent recalls them (they're injected); open a DIFFERENT place and confirm the game
  fact is gone but the global one remains; `forget` one and confirm it's dropped; check the Memory
  viewer shows + `✕`-removes entries; confirm a turn that errors does NOT lose a just-remembered fact.

## Rollout / ordering

1. `Memory.luau` + `MemorySpec.luau` (pure core + persistence, test-first).
2. `Tools/Memory.luau` (`remember`/`forget`) + register in `Tools/init.luau`.
3. `AgentLoop.luau` threading + system-prompt composition.
4. `init.server.luau` deps.
5. `UI/Widget.luau` memory view + wiring.
6. `SystemPrompt.luau` guidance.
7. Build + lint, adversarial-review Workflow, fix, rebuild, hand off for live-verify.
