# Studio Agent — Subagents (`dispatch_subagents`) Design

- **Date:** 2026-06-16
- **Status:** Approved design — pending spec self-review, then implementation plan.
- **Relates to:** `HANDOFF.md`; the subagent feasibility brief (workflow `wf_696c655c-99a`).
- **Scope:** ONE feature (feature #2 of the "capability parity" roadmap). Web access / task tracking /
  memory / skills are separate, later specs.

## Goal

Give the in-Studio agent the ability to **fan out read-only subagents** — independent Claude
conversations that explore, analyze, verify, or judge in parallel — the way Claude Code's Agent tool
does, scoped to Roblox Studio. The parent agent stays the sole builder; children multiply its reach
for read-heavy work (parallel finders, adversarial verify-after-build, K-way judge panels) and keep
their heavy reads/screenshots out of the parent's context window.

## Hard constraint (from the feasibility brief)

There is ONE shared DataModel and ONE `ChangeHistoryService` recording stream. Parallel **writers**
would corrupt undo grouping and race on shared state. Therefore: **parallel READERS, serial WRITER.**
v1 makes children **read-only**; the parent (already single-flighted) does every write.

## Key decisions (settled in brainstorming)

1. **Read-only children.** Children get only `get_tree`/`search`/`get_properties`/`get_output`/
   `capture`. The parent does all `run_luau`/`create_instance`/`set_property`.
2. **Model-driven.** The parent calls a `dispatch_subagents` tool; the model decides when/how to fan
   out. No deterministic Luau workflow engine (it would re-implement the loop for no benefit in a
   single-process/single-model/single-DataModel environment).
3. **Child model = `claude-sonnet-4-6`** (parent + any final judge stay Opus). Cheaper, far less
   subscription-usage-window pressure; finders/verifiers don't need Opus.
4. **Separate minimal child runner** (`Subagent.luau`), NOT a refactor of the just-stabilized
   `runLoop`. Children are ephemeral + read-only, so they need none of the parent's
   rollback/compaction/persistence/single-flight machinery. The genuinely-shared low-level retry path
   is factored into `Retry.luau` and used by both.
5. **Depth-1.** Children's toolset excludes `dispatch_subagents`, so no nested fan-out in v1 (bounds
   the usage-window blast radius).
6. Defaults (configurable): `subagentMaxParallel = 4`, `subagentMaxIterations = 15`.

## Baseline (relevant existing code)

- `runLoop` (`AgentLoop.luau:86`) is self-contained; `running` (module single-flight) guards only
  `AgentLoop.send`, NOT `runLoop` — children that call their own runner are unaffected.
- The dispatch context already threads `{config, anthropic}` to every tool
  (`AgentLoop.luau:112`, `Tools.dispatch(name,input,context)`), so a tool reaches the model client
  with no new plumbing (`Capture.luau` is the precedent).
- `Tools.dispatch` returns `Content = string | {blocks}`; a string result fits a tool_result.
- `Anthropic.sendMessage` already honors per-call `opts.model`/`opts.maxTokens`
  (`Anthropic.luau`), so a child on Sonnet is free.
- `isTransient` + `sendWithRetry` currently live as locals in `AgentLoop.luau`.
- Each tool Descriptor carries a `destructive` boolean; the read-only set is exactly the
  `destructive == false` tools.

## Design

### Component 1 — `src/Retry.luau` (extracted, no logic change)

Move `isTransient(res)` and `sendWithRetry(anthropic, config, opts, emit, cancelled)` out of
`AgentLoop` verbatim. `AgentLoop` requires them instead of defining locals (its only change). Both
the parent loop and the child runner use this one retry/backoff path. This keeps the transient-error
policy (Overloaded/429/5xx/transport/cold-proxy retryable; `out of extra usage` NOT retryable) in one
place.

### Component 2 — `src/Subagent.luau` (the child runner)

```
Subagent.run({
  anthropic, config,
  systemPrompt: string,        -- from SystemPrompt.buildSubagent(role, task)
  toolSchemas: { any },        -- the read-only subset (Tools.schemasFor(READ_ONLY))
  allowedTools: { [string]: true },-- the READ_ONLY set, passed into dispatch context for enforcement
  model: string,               -- subagentModel (sonnet)
  maxIterations: number,
  shouldCancel: () -> boolean,
}) -> { text: string, ok: boolean, capped: boolean }
```

A minimal loop: seed `messages = { {role="user", content=task} }`; up to `maxIterations`:
`Retry.sendWithRetry(...)` (with `model` in opts; `maxTokens` defaults to the config value) → on error
return `{text=<error string>, ok=false}`; read the assistant content; if it has `tool_use`, dispatch
each via `Tools.dispatch(name, input, { config = config, anthropic = anthropic, allowedTools = allowed })`,
append assistant + tool_result, loop; if no `tool_use`, the turn is terminal → return
`{text=<concatenated assistant text>, ok=true}`.
Hitting the cap returns the last assistant text + `capped=true`. Cancellation between steps returns
partial text. NO rollback/compaction/snapshot/Sessions — children are discarded on return.

`emit` is intentionally omitted (children are quiet); per-child progress goes to `print` (Output/Logs)
only, so child chatter never floods the parent transcript or persists into the parent Conversation.

### Component 3 — `src/Tools/Subagents.luau` (the `dispatch_subagents` tool)

Descriptor `destructive = false`. Input schema:

```
{ subagents: array of { role: string, prompt: string } }  -- required: subagents (min 1)
```

`run(input, context)`:
1. Resolve `config`, `anthropic` from `context`; validate `input.subagents` is a non-empty array.
2. Cap to `config:getSubagentMaxParallel()`; if truncated, include a `dropped` count in the result
   (NO silent caps).
3. Build the read-only `toolSchemas` (`Tools.schemasFor(READ_ONLY)`) + the `allowedTools` set once.
4. For each (capped) subagent, `task.spawn` a worker that calls `Subagent.run(...)` (child system
   prompt = `SystemPrompt.buildSubagent(role, prompt)`, model = `subagentModel`, maxIterations =
   `subagentMaxIterations`, shouldCancel = the parent's). Each worker is wrapped in `pcall` (a child
   throw → `{role, ok=false, text="subagent error: ..."}`), writes `results[i]`, and increments a
   `done` counter.
5. Join: `while done < n do task.wait() end` (no locks needed — Luau cooperative scheduling means
   worker writes never interleave mid-instruction). The parent loop is yielding here, so it is not
   writing → the DataModel is quiescent for the children's reads.
6. Return `encodeResult({ ok = true, count = n, dropped = d, results = results })` as a JSON string
   (mirror `Tree.luau`'s `encodeResult`; total — never throws).

`Subagent` is reached by a **lazy** `require` inside `run` (not at module load) to avoid a
require cycle (`Tools` ← `Subagents` ← `Subagent` ← `Tools`).

### Component 4 — `src/Tools/init.luau`

- `Tools.schemasFor(names: {string}) -> {any}`: `schemas()` filtered to the named tools (for the
  child toolset). `READ_ONLY = {"get_tree","search","get_properties","get_output","capture"}`.
- **Allowlist enforcement at dispatch:** `Tools.dispatch(name, input, context)` — if
  `context.allowedTools ~= nil` and `not context.allowedTools[name]`, return
  `("'"..name.."' is not permitted for this subagent", true)` WITHOUT running it. An allowlist (not a
  destructive-flag check) is required because `dispatch_subagents` is itself `destructive=false`: only
  an allowlist keeps a hallucinating child from (a) mutating via a writer tool OR (b) calling
  `dispatch_subagents` to nest. The child's `allowedTools` is exactly the `READ_ONLY` set, so both are
  blocked. Defense in depth on top of the already-filtered child schemas.
- Register `dispatch_subagents` in the concatenation block (parent-only; it is NOT in `READ_ONLY`, so
  children neither see it in their schemas nor can dispatch it → depth-1).

### Component 5 — `src/Config.luau`

| key | default | meaning |
|-----|---------|---------|
| `subagentModel` | `claude-sonnet-4-6` | model for children (must be an allowed MODEL) |
| `subagentMaxParallel` | `4` | max children per dispatch (excess truncated + reported) |
| `subagentMaxIterations` | `15` | per-child step cap |

`subagentModel` validates against the existing `MODELS` allowlist; the two numbers validate `>= 1`.

### Component 6 — `src/SystemPrompt.luau`

- **Parent prompt:** a "Fan out subagents" section teaching when to call `dispatch_subagents` — for
  read-heavy/parallelizable work: parallel finders over different areas, an adversarial read-only
  verifier AFTER the parent builds something, a K-way judge panel for a design call, broad
  exploration. Emphasize: children are READ-ONLY and you (the parent) do all building; pass each child
  a self-contained `prompt` and a short `role`; expect a terse text result back.
- **`SystemPrompt.buildSubagent(role, task) -> string`:** a focused child system prompt = the shared
  environment + addressing + value-encoding preamble (so children read the DataModel + decode tagged
  values correctly) + the role + an explicit OUTPUT CONTRACT: *"You are a READ-ONLY subagent. You
  cannot modify anything. Your FINAL message is your entire return value to the parent — make it terse,
  structured, and complete (the parent cannot see your tool calls or any screenshots you took). Do the
  task, then report."* To avoid duplicating the whole BASE prompt, factor the shared
  environment/value-encoding text into a constant both `build()` and `buildSubagent()` compose.

### Component 7 — `src/UI/Widget.luau`

Minimal: the existing `tool_use`/`tool_result` rendering already shows `[dispatch_subagents]` and the
result. Add nothing structural for v1; child progress is in the Output window (`print`). (A richer
per-child live panel is a future enhancement.)

## Data flow

```
parent loop --tool_use: dispatch_subagents{subagents:[{role,prompt}...]}-->
  Subagents.run --task.spawn N--> Subagent.run (each: sonnet, read-only toolset, own messages)
     child --Tools.dispatch(..., readOnly=true)--> get_tree/get_properties/capture (reads only)
     child terminal --> {role, text, ok, capped}
  join all --> JSON string {results:[...]} --tool_result--> parent loop continues (synthesizes)
```

## Error handling

- Per-child `pcall` isolation — one child's throw never aborts siblings or the join.
- Child iteration-cap → partial text + `capped=true` (never hangs).
- Child transient failure → retried via `Retry`; if exhausted → `ok=false` error text for that child;
  siblings + parent proceed.
- `out of extra usage` (subscription window) → not retried → `ok=false` for that child; the parent
  still receives the others. Capping at 4 + Sonnet children minimizes reaching it.
- Stop → the shared `shouldCancel` reaches every child; children exit at step boundaries and the
  dispatch returns partial results rather than hanging.
- `dispatch_subagents` itself is total (wrapped, JSON-encodes a result even on bad input) so the
  parent's tool_use always gets a tool_result.

## Testing

Mirrors the in-Studio self-test pattern (`SerializeSpec`/`CompactorSpec`):

- **New `src/SubagentsSpec.luau`** — covers the PURE pieces with no network:
  `Tools.schemasFor(READ_ONLY)` returns exactly the read-only set; `Tools.dispatch` with an
  `allowedTools` set REJECTS a tool outside it — both a writer (`create_instance`) AND
  `dispatch_subagents` (proving depth-1) — and ALLOWS a read tool (`get_tree`); the result-JSON
  aggregation/encode is well-formed; the cap/truncate math reports `dropped` correctly.
- **Static:** `selene` (0 errors) + `stylua --check` + `rojo build`.
- **Adversarial review workflow** over the diff: require-cycle safety (lazy require), the parallel
  join (no deadlock / returns after all children), read-only enforcement actually blocking writes, the
  child runner's terminal/cap/cancel correctness, and that children never mutate the parent
  Conversation.
- **Live test (Studio, via computer-use):** ask the agent to "fan out 3 subagents to analyze
  different parts of the Workspace and report" — confirm parallel children run, return terse results,
  the parent synthesizes, and nothing in the DataModel is mutated by a child.

## Non-goals (v1)

- Writer children / parallel building (unsafe on the shared DataModel).
- Nested fan-out (depth-1 only).
- A built-in synthesis/judge step (the parent model synthesizes the returned results itself).
- A rich per-child live UI panel (Output `print` suffices for v1).
- A concurrency semaphore beyond a hard cap (cap-and-truncate is enough at fan-out ≤ 4).
