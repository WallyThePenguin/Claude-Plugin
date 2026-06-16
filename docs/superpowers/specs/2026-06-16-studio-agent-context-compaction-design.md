# Studio Agent — Context-Window Auto-Compaction (Design)

- **Date:** 2026-06-16
- **Status:** Approved design — pending spec review, then implementation plan.
- **Relates to:** `HANDOFF.md`, `docs/superpowers/specs/2026-06-16-studio-agent-cliproxyapi-design.md`.
- **Scope:** ONE feature. The separate "subagent / ultracode orchestration" idea is a different spec.

## Problem

The agent loop (`AgentLoop.runLoop`) sends the full `Conversation.messages` history on every
turn. Two things end a long chat:

1. The **iteration cap** — already handled gracefully (the loop appends a "say continue" assistant
   turn instead of discarding the turn).
2. The **context window** — once the accumulated history exceeds the model's window
   (`claude-opus-4-8`, ~1,000,000 tokens) the proxy/API hard-rejects the request ("prompt is too
   long") and the turn dies with no recovery.

Vision chats hit (2) fastest: every `capture` screenshot is a heavy base64 image block retained in
live context. We want the chat to **keep going seamlessly** (auto-compact in place) rather than die.

## Goals

- Auto-compact **in place** when the context nears the window; the chat never "ends."
- **Always-on image pruning:** keep only the single most-recent screenshot in live context.
- **Correctness:** the message history stays Anthropic-API-valid at every step (starts on `user`,
  roles alternate, every `tool_use` has its `tool_result`, a Send happens on a `user`-terminated
  array).
- Lean on the **live DataModel as ground truth** so a lossy summary is safe (the agent can always
  re-query exact state via `get_tree` / `get_properties`).

## Non-goals (v1)

- Disk-saving captures.
- A multi-image "see the whole flow" mode (flip-book of keyposes for animation/rig work) — a real
  future need, explicitly deferred.
- A continuous, always-visible "build memory" panel — future.
- A separate pre-compaction Sessions snapshot — the DataModel + summary suffice; can be added later
  as a scrollback safety net.

## Baseline (how it works today)

- `Conversation` holds `messages` (array of `{role, content}`) + `title`, with
  `appendUserText` / `appendAssistant` / `appendToolResults` / `truncate` / `count` / `clear` /
  `load`.
- `AgentLoop.runLoop` loops up to `maxIterations`: send → read assistant content → if it contains
  `tool_use`, dispatch each tool, append `{assistant: content}` then `{user: toolResults}`, and
  loop; otherwise it's terminal. Each iteration's Send happens with `messages` ending on a `user`
  turn (the initial user text on iteration 1, a `tool_result` user turn afterwards).
- Every Anthropic response carries `usage` (`input_tokens`, `cache_read_input_tokens`,
  `cache_creation_input_tokens`) — already returned by the proxy (observed in the live ping).
- `Sessions.stripImages` already recursively replaces any `{type="image"}` block with a text
  placeholder before persisting (so saved sessions are small). This walker is reused below.

## Design

Two independent mechanisms.

### Mechanism 1 — Image pruning (always-on, no model call)

`Compactor.pruneImages(messages)` walks the whole history and keeps only the **single most-recent**
image block (the last one in message order), replacing every earlier image with
`{type="text", text="[earlier screenshot dropped to save context]"}`. Run at the **top of every
loop iteration**, before the Send, so the request always carries at most one screenshot. This is the
biggest lever for vision chats and is pure win — the agent re-captures (cheap) if it needs to look
again; the durable record of an old screenshot is the model's own prior textual observation of it.

Image blocks live inside `tool_result` content arrays (user messages), so the walker descends into
those. Pruning **mutates** the live `Conversation.messages` (the dropped pixels are gone for good —
intended).

### Mechanism 2 — Summarize-and-replace compaction

#### Token accounting

After each successful Send, the loop reads the response `usage` and computes the real prompt size:

```
lastPromptTokens = (input_tokens or 0)
                 + (cache_read_input_tokens or 0)
                 + (cache_creation_input_tokens or 0)
```

(The cached components still occupy the **window** even though they're cheaper in dollars, so they
must be included.) This is measured, not estimated.

`lastPromptTokens` is remembered **across turns** within a chat (stored on the `Conversation`, reset
on New chat / session load), so the proactive check works on the first Send of a follow-up turn —
not just mid-turn. The one case proactive can't see is a *cold* first Send that is already oversized
(e.g., reopening a very large saved session): that is covered by the **reactive** path below.

#### Trigger — proactive + reactive

- **Proactive (primary):** at the top of each iteration, if
  `lastPromptTokens ≥ contextWindow × compactThreshold` (defaults `1_000_000 × 0.8 = 800_000`),
  compact **before** sending — so the wall is never actually hit.
- **Reactive (safety net):** if a Send nonetheless fails with a context-length error (HTTP 400 whose
  message matches `prompt is too long` / `exceeds` / `maximum context`), classify it as
  **compact-and-retry** (NOT a transient blind retry, NOT an abort): run `compact`, then retry the
  same Send. Bounded to **one** compact-retry per Send to prevent loops; if it still fails, abort as
  today.

#### Rebuild algorithm (correctness-critical)

`Compactor.compact(anthropic, config, conversation)` replaces older history with a summary while
preserving every API invariant:

1. Target tail size = `keepRecentMessages` (default 6). Compute `j = n - keepRecentMessages + 1`.
2. **Walk `j` backward to the nearest `assistant` message.** Cutting at an `assistant` boundary is
   what guarantees we never split a `tool_use` / `tool_result` pair and that the kept tail joins
   cleanly after a `user` summary message.
3. `older = messages[1 .. j-1]`; `keptTail = messages[j .. n]`.
4. Summarize `older` (see below) into `summaryText`.
5. New history = `[ {role="user", content=summaryText} ] ++ keptTail`.
   - Validity: `user(summary) → assistant(…) → user(tool_result) → …` — starts on `user`,
     alternates, no dangling `tool_use`, and still ends on the same `user` turn the loop was about
     to send, so the loop continues without missing a beat.
6. **No-op guard:** if `j ≤ 2` (nothing meaningful older to summarize), skip compaction.
7. Replace `conversation.messages` in place with the new array.

#### Summarization call

`compact` makes one model call over `stripImages(older)` (images stripped — the model's earlier
*text* observations already captured what they showed, saving tokens) with a focused instruction:

> Summarize this conversation so it can be continued. Capture: the user's goal; what has been built
> or changed (with exact instance paths); key decisions and constraints; the current state; and the
> immediate next step. Be concise but complete. The live DataModel is the source of truth for exact
> values — record intent and paths, not every property.

The summarization input is ≤ `compactThreshold` of the window (~800k), which fits in 1M with room
for the summary output. The call reuses the existing `Anthropic` client (no tools, no streaming).

#### UX

When compaction runs, the panel shows a muted transcript row
`[compacted earlier history to free context]` and a `compacting…` status, then continues
seamlessly. The chat never dies. (Emitted via the existing `emit`/`onEvent` channel — a new event
or a reused `status` event.)

### Config additions

Added to `Config.DEFAULTS` with validation + getters (same pattern as the rest):

| key | default | meaning |
|-----|---------|---------|
| `contextWindow` | `1000000` | model window, tokens |
| `compactThreshold` | `0.8` | compact when prompt ≥ window × this (0 < x < 1) |
| `keepRecentMessages` | `6` | target verbatim tail length |

### Error handling

- Summarization-call failure: if the summary model call errors (transient/usage), `compact` returns
  `(false, reason)`. The loop then **falls back to truncation** (keep `keptTail`, prepend a minimal
  synthetic `user` "[earlier history dropped to fit context]" message) so the turn can still proceed
  rather than dying — degraded but alive. Surface a status note.
- Reactive path bounded to one compact-retry (above).
- All existing invariants (roll back to snapshot on non-clean exit) are unchanged for other error
  kinds.

## Module changes

- **New `src/Compactor.luau`** — `pruneImages(messages)`, `shouldCompact(lastPromptTokens, config)`,
  `compact(anthropic, config, conversation) -> (ok, reason)`, plus the boundary/validity helpers.
- **New `src/MessageUtil.luau`** — extract the recursive `stripImages` (currently local to
  `Sessions.luau`) here so `Sessions` and `Compactor` share one walker; add `promptTokensFromUsage`
  and any small message-shape helpers.
- **`src/Sessions.luau`** — use `MessageUtil.stripImages` instead of its local copy (behavior
  unchanged).
- **`src/AgentLoop.luau`** — track `lastPromptTokens` from each response's `usage`; at the top of
  each iteration call `Compactor.pruneImages` then `Compactor.shouldCompact` → `Compactor.compact`;
  add the reactive context-length classification + one compact-retry; emit compaction status.
- **`src/Config.luau`** — the three knobs above (DEFAULTS + validation + getters).
- **`src/UI/Widget.luau`** — render the compaction status/row.
- **`src/SystemPrompt.luau`** — optional one-line note that older history may be summarized, so the
  agent should re-query the DataModel rather than assume it remembers every detail verbatim.

## Testing

Mirrors the repo's existing in-Studio self-test pattern (`SerializeSpec.luau`):

- **New `src/CompactorSpec.luau`** — feeds synthetic message arrays through `pruneImages` and the
  `compact` **rebuild** (with the summarization call stubbed) and asserts the output is API-valid:
  starts on `user`, roles strictly alternate, no `tool_result` without a preceding `tool_use`, ends
  on the expected role, and ≤ 1 image block remains. Covers the boundary-walk edge cases (tail
  starts mid-pair; `j ≤ 2` no-op; tail already starts on `assistant`). This is the risky
  deterministic logic and needs no network.
- **Static:** `selene src` (0 errors) + `stylua --check src` + `rojo build`.
- **Adversarial review workflow** over the diff (Anthropic history-invariant correctness, token
  accounting, reactive-classification).
- **Live:** user runs a long vision chat and confirms it compacts and continues instead of erroring.

## Future extensions (seams preserved, not built now)

- Multi-image "see the whole flow" mode for animation/rig authoring (retain a small labeled set of
  keypose screenshots).
- Continuous "build memory" panel (Mechanism 2 variant C) — the summary already centralizes the
  running state, so a visible panel can read from it later.
- Optional pre-compaction Sessions snapshot for scrollback/recovery.
