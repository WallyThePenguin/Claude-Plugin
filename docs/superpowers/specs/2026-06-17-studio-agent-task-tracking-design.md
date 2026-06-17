# Studio Agent — Task Tracking (`update_tasks`) Design

- **Date:** 2026-06-17
- **Status:** Approved design (calls delegated to the implementer) — pending spec self-review, then
  implementation plan.
- **Relates to:** `HANDOFF.md`; the capability-parity roadmap (this is feature #4, after vision,
  compaction, subagents, web access).
- **Scope:** ONE feature. Cross-session distilled memory and reusable skills are separate, later specs.

## Goal

Give the in-Studio agent a **visible, self-maintained checklist of multi-step build work**, shown in
the panel and updated live as the agent works — the way Claude Code's `TodoWrite` surfaces a plan and
its progress, scoped to Roblox Studio. The user sees *what the agent intends to do* and *how far it
has gotten*; the agent gets a lightweight planning anchor that survives a long, compacted session.

This is a **visibility + planning** feature, not a new build capability. The checklist does not touch
the DataModel; the agent still builds with the existing tools.

## Key decisions (settled in brainstorming; design calls delegated to the implementer)

1. **One tool, declarative full-list replace.** A single `update_tasks` tool takes the ENTIRE list
   every call (`{ tasks = [ { content, status }, ... ] }`) — not incremental add/complete/reorder
   ops. This mirrors `TodoWrite` exactly: no task IDs, no partial-update races, the model always
   states the whole intended state. An empty `tasks` array clears the checklist.
2. **State lives in a dedicated `TaskList` module, held in `deps`** (alongside `conversation`), NOT
   reconstructed from the message history. Two properties fall out for free:
   - It **survives the panel re-mount** that happens on every Play/Edit transition (the widget blanks
     and `init.server` re-mounts from `deps` — the conversation already relies on this; the checklist
     rides the same lifetime).
   - It **survives context compaction.** The checklist is *outside* the Anthropic message history, so
     `Compactor` summarizing older turns never strips it. (Reconstructing the list from the latest
     `update_tasks` tool_use in history would be fragile precisely because compaction can drop it.)
3. **The agent loop owns the UI signal** — consistent with how every other panel event is emitted.
   The tool mutates the provided `context.taskList` (a side effect on provided state, exactly like
   `set_property` mutates the DataModel) and stays free of UI concerns. `AgentLoop` threads the
   `taskList` into the tool context, and after a tool batch that ran `update_tasks` it
   `emit("tasks", taskList:snapshot())`. The Widget re-renders the checklist from that event.
4. **Subagent isolation.** `update_tasks` is `destructive = false` (no confirm gate) and is **NOT** in
   the subagent `READ_ONLY` allowlist, so children cannot mutate the parent's checklist. Independently,
   `Subagent.run` builds its tool context WITHOUT a `taskList`, so the tool would no-op for a child
   even if the allowlist missed it. Belt and suspenders — the checklist is a parent-only surface.
5. **Persistence with the session.** A checklist belongs to its chat. `Sessions.save/load` carry the
   normalized task array beside the messages, so reopening a saved session restores its checklist.
   Backward-compatible: a saved session with no `tasks` field loads as an empty list.
6. **Validation is strict (untrusted model output) but lenient where safe.** `tasks` must be an array;
   each item's `content` must be a non-empty string (trimmed, capped to keep panel rows sane); each
   item's `status` is coerced to `pending` when missing/unknown; the task COUNT is capped to bound the
   state and the UI. Multiple `in_progress` entries are allowed (not hard-failed); the system prompt
   instructs exactly one. The tool returns the NORMALIZED list plus a one-line count summary as its
   `tool_result`, so the model always sees the accepted state.

## Non-goals (YAGNI)

- No incremental ops (add one / complete one / reorder). Full-list replace covers everything.
- No `cancelled`/`blocked` statuses, no priorities, no due dates, no `activeForm`. Three statuses.
- No nested checklists / subtasks.
- No user-editable checklist (the user can't tick boxes). It reflects the agent's plan; the user
  drives via chat. (A future enhancement, not v1.)
- No dynamic injection of the current list into the system prompt each send. The tool_result echoes
  the accepted list, which keeps the model in sync; a stronger per-send reminder is possible later.

## Architecture

### New modules

- **`src/TaskList.luau`** — the state object + the pure validation/normalization the tool and the spec
  share. One instance lives in `deps.taskList`.
  - `TaskList.new()` → a fresh, empty list.
  - `TaskList.normalize(input) -> ({ Task }, summary: string)` — PURE. Takes the raw decoded tool
    input (`{ tasks = ... }` or a bare array — be tolerant) and returns the normalized task array plus
    a human/agent-readable summary line. No `self`, no DataModel — directly unit-testable.
    - A `Task` is `{ content: string, status: "pending" | "in_progress" | "completed" }`.
    - Rules: drop non-table items; `content` = trimmed `tostring`, dropped if empty, truncated to
      `MAX_CONTENT` chars; `status` lowercased and coerced to `pending` unless it is exactly
      `in_progress` or `completed`; keep at most `MAX_TASKS` items (excess dropped, noted in summary).
    - **Pinned constants** (`TaskList` module-level): `MAX_CONTENT = 200`, `MAX_TASKS = 50`.
  - `taskList:set(input)` → normalizes and replaces the held list IN PLACE; returns the summary
    string. (In place so any reference to the list stays valid, mirroring `Conversation.replaceMessages`.)
  - `taskList:snapshot()` → a fresh shallow copy of the list (`{ {content,status}, ... }`) for the UI
    event and for session save (a plain, JSON-safe array).
  - `taskList:load(tasks)` → replace from a persisted array (already-normalized; re-normalize
    defensively so a hand-edited/old blob can't inject a bad row).
  - `taskList:clear()` → empty the list.
  - `TaskList.counts(tasks)` → `{ total, completed, inProgress, pending }` (used by the summary and
    the panel header).
- **`src/Tools/Tasks.luau`** — exports `descriptors` with the single `update_tasks` descriptor (same
  shape as `Subagents`/`Web`). `run(input, context)`:
  - If `context.taskList == nil` → return an error string (e.g. a subagent context) — never throws.
  - Else `local summary = context.taskList:set(input)`; return `(normalizedListText .. "\n" ..
    summary, false)`. The normalized-list text is a compact numbered render (`1. [in_progress] Build
    the grid`) so the model re-reads the exact accepted state in its tool_result.
- **`src/TaskListSpec.luau`** — an in-Studio self-test module mirroring `WebSpec`/`SubagentsSpec`:
  exercises `TaskList.normalize`/`set`/`snapshot`/`counts` over good input, missing/unknown status,
  non-string content, over-long content (truncation), the count cap, the empty-clear case, a bare
  array vs `{tasks=...}`, and the summary/counts. Returns `{ passed, failed, lines }` like the others.

### Touched modules

- **`src/Tools/init.luau`** — require `Tasks`, append its descriptors to the registry (after
  `Subagents`). `update_tasks` is NOT added to any subagent allowlist.
- **`src/AgentLoop.luau`** —
  - `runLoop`/`AgentLoop.send` gain a `taskList` parameter (threaded from the Widget via `deps`).
  - `toolContext` gains `taskList = taskList`.
  - In the tool-dispatch loop, track whether any dispatched block was `update_tasks`; after the batch,
    `if tasksChanged and taskList then emit("tasks", taskList:snapshot()) end`. (One name check; no
    per-iteration emit when nothing changed.)
- **`src/Tools/Subagents.luau`** — unchanged behavior, but confirm `update_tasks` is absent from
  `READ_ONLY`. (No code change needed; called out so the invariant is explicit and tested.)
- **`src/UI/Widget.luau`** — render the checklist panel and wire its lifecycle (see UI below).
- **`src/Sessions.luau`** — `save(conversation, id, tasks)` stores `tasks`; `load` returns `tasks`
  (default `{}`). `tasks` is the already-JSON-safe `taskList:snapshot()`.
- **`src/init.server.luau`** — require `TaskList`; add `taskList = TaskList.new()` to `deps`.
- **`src/SystemPrompt.luau`** — a "Track multi-step work" section in `BASE` and the `update_tasks`
  line in the tools list. The SUBAGENT prompt is unchanged (children have no such tool).
- **`src/Config.luau`** — no new keys required (limits are module constants). If knobs are wanted
  later, `taskMaxItems`/`taskMaxContentChars` can be added; v1 keeps them as `TaskList` constants to
  avoid config churn.

### Data flow

```
model → update_tasks { tasks=[...] }
      → Tools.dispatch → Tasks.run(input, context)
          → context.taskList:set(input)            -- normalize + replace in place
          → returns normalized-list text + summary -- tool_result the model re-reads
      → AgentLoop: tasksChanged = true
      → after the tool batch: emit("tasks", taskList:snapshot())
          → Widget onEvent "tasks": renderChecklist(snapshot); relayout()
On New chat:     taskList:clear() + renderChecklist({}) + relayout()
On open session: taskList:load(data.tasks) + renderChecklist + relayout()
On done (save):  sessions:save(conversation, id, taskList:snapshot())
On re-mount:     Widget.mount renders deps.taskList:snapshot() (survives Play/Edit blank)
```

## UI

A collapsible checklist pinned between the control row and the transcript. It occupies **zero space
when the list is empty** and is hidden while the History (sessions) view is open — it describes the
active chat only.

- **Header bar** (always present when tasks exist, ~24px): `Tasks  {completed}/{total}` on the left,
  a collapse chevron (`▾` expanded / `▸` collapsed) on the right. Clicking toggles collapsed.
- **Body** (when expanded): one row per task (~20px), a status glyph + the (truncated) content:
  - `○` pending — muted grey.
  - `◐` in_progress — blue (the existing `YOU` accent), the "active" row.
  - `●` completed — dimmed green, content visually de-emphasized.
  - The body is a `ScrollingFrame` with a fixed MAX height; more tasks scroll internally.
  - **Pinned layout constants** (Widget-level): `HEADER_H = 24`, `ROW_H = 20`, `MAX_BODY = 140`,
    `GAP = 4` (px).
- **Layout / reflow.** The existing panel uses manual anchored positioning (header rows end at
  `TOP = 96`; the transcript flexes between `TOP` and the bottom input row). The checklist sits at
  `y = TOP`; the transcript's `Position.Y`/`Size.Y` are recomputed by an explicit `relayout()`:
  - `checkH = (#tasks == 0 or inSessionsView) and 0`
            `or HEADER_H + (collapsed and 0 or min(#tasks * ROW_H, MAX_BODY))`
  - transcript `Position.Y = TOP + checkH (+ gap)`, `Size.Y = 1, -(TOP + checkH + gap + INPUT_H + 4)`.
  - `relayout()` is called only at the moments the height can change (a `tasks` event, expand/collapse
    toggle, New chat, opening/closing the History view) — height is derived from task count + collapsed
    state, so there is no `AutomaticSize` reflow race and no continuous `AbsoluteSize` listener.
  - The `sessionList` scroller keeps its base geometry; the checklist is simply hidden when the
    sessions view is shown, so only the transcript region reflows.

## Correctness rules / edge cases

- **Total dispatch:** `Tasks.run` never throws; a nil `taskList` (subagent) or a malformed input
  returns an `is_error` string, never aborts the loop. `Tools.dispatch` already pcall-wraps the
  handler as a backstop.
- **Empty-object encoding:** N/A — `update_tasks` always carries a non-empty `input` (the `tasks`
  key), and `tasks = {}` JSON-encodes to `{"tasks":[]}` (the inner `[]` is a correct empty ARRAY), so
  the `JSONEncode({}) -> []` tool_use-input gotcha cannot fire here.
- **Snapshot isolation:** `snapshot()` returns a deep-enough copy (new outer array + new per-task
  tables) so a later `set()` can't mutate an already-emitted/saved snapshot.
- **Persistence compatibility:** `load` re-normalizes, so a corrupt/old/hand-edited `tasks` blob can
  never inject a malformed row into the live state or the UI.
- **Compaction independence:** the checklist is not in `conversation.messages`, so no compaction or
  rollback path touches it; no new invariant for `AgentLoop`'s snapshot/rollback logic.
- **Multiple `in_progress`:** allowed (rendered as multiple `◐`); the prompt asks for exactly one but
  the tool does not hard-fail, matching `TodoWrite`'s lenient acceptance.

## System prompt addition (summary)

A short "Track multi-step work" section: call `update_tasks` for builds of ~3+ steps so the user sees
the plan and live progress (skip it for trivial single-step asks); send the FULL list each call;
mark exactly ONE task `in_progress` at a time; mark a task `completed` IMMEDIATELY when its step is
done (don't batch); keep `content` short and outcome-shaped; it is a visibility aid — you still do the
work with the build tools. Plus the one-line tool entry in the tools list.

## Testing

- **Static:** `selene src` (0 errors), `stylua --check src`, `rojo build` — as every feature.
- **`TaskListSpec`** (in-Studio, runnable like `WebSpec`/`SubagentsSpec`/`CompactorSpec`): the pure
  normalization/validation/counts surface. This is the bulk of the logic and is fully self-testable
  without driving the UI.
- **Adversarial review** (Workflow, like prior features) over the diff: focus on the AgentLoop
  threading (no regression to the snapshot/rollback/compaction invariants), the Widget reflow math,
  the Sessions signature change (backward compat), and the subagent-isolation invariant.
- **Live-verify in Studio** (computer-use): ask the agent for a multi-step build, watch the checklist
  appear and tick through pending → in_progress → completed; toggle collapse; New chat clears it;
  reopen a saved session and confirm the checklist returns; confirm it survives a Play/Edit transition.

## Rollout / ordering

1. `TaskList.luau` + `TaskListSpec.luau` (pure core, test-first).
2. `Tools/Tasks.luau` + register in `Tools/init.luau`.
3. `AgentLoop.luau` threading + the `tasks` emit.
4. `init.server.luau` deps + `Sessions.luau` persistence.
5. `UI/Widget.luau` checklist render + reflow + lifecycle wiring.
6. `SystemPrompt.luau` guidance.
7. Build + lint, adversarial-review Workflow, fix, rebuild, hand off for live-verify.
