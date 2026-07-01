# Dev Ladder — script hands, loop integrity, playtest tools (2026-07-01)

## Why (the audit, condensed)

A 25-agent full-project audit (7 subsystem readers → 4 diagnostic lenses → 14/14 claims
adversarially verified TRUE) converged on three structural causes for "understands its
capabilities but sucks at development":

1. **The code substrate is disabled.** All game logic is authored by setting `.Source` to an
   escaped string (`SystemPrompt.luau:58`); there is no read/search/patch surface, and
   `PropertyCatalog.luau` doesn't even expose `Script` — the agent cannot read back code it
   wrote. LLMs are strongest at diff-editing readable source; the plugin forces blind whole-blob
   rewrites of code-in-string-in-JSON.
2. **The agent cannot observe a running game.** PlayBridge is live-verified but shell-only — not
   in the tool registry. `evaluate` grades edit-mode stills + prose claims (the 29/35 fake-done).
   Gameplay ships verified only by "no errors in the log".
3. **Loop economics.** Any error/cancel rolls the conversation back while DataModel edits persist
   (turn amnesia); `stop_reason=="max_tokens"` silently ends the turn mid-script; image pruning
   keeps exactly 1 screenshot (no before/after); compaction fires at 0.8×1,000,000 tokens — far
   past useful latency/cost.

This ladder fixes all three IN PLACE (the plugin's current architecture). The strategic
code-first inversion (game as a Rojo/filesystem project, Claude Code as builder, plugin as
eyes/hands/runtime-verifier) is a SEPARATE, later design.

## Phase 1 — script hands

New pure engine `src/ScriptEdit.luau` (+`ScriptEditSpec.luau`):
- `numberLines(source, startLine?, endLine?) -> string` — `N| ` prefixed window.
- `applyFind(source, find, replace, all?) -> (newSource?, err?)` — plain-text (no patterns);
  errors on 0 matches, or >1 match when `all` is false (uniqueness guard, mirrors Claude Code's Edit).
- `applyRange(source, startLine, endLine, replacement) -> (newSource?, err?)` — line-range splice.
- `grep(source, pattern, plain) -> { {line, text} }` — per-script matches, capped by caller.

New impure tool module `src/Tools/Scripts.luau` — 4 descriptors:
- `list_scripts { root?, limit? }` — every Script/LocalScript/ModuleScript under root (default:
  the standard containers), with path, class, lines, chars, Enabled/RunContext.
- `get_script { path, startLine?, endLine? }` — line-numbered source (windowed, ~200-line default)
  via `ScriptEditorService:GetEditorSource` (sees open-editor drafts).
- `edit_script { path, find?, replace?, all?, startLine?, endLine?, source? }` — three modes:
  find/replace (unique-match), line-range splice, whole-source write. After computing the new
  source: **compile check** via `loadstring` (compile only, never executed); on syntax error the
  edit is NOT applied and the error (with line) returns to the model. Writes via
  `ScriptEditorService:UpdateSourceAsync` (handles the >200K direct-.Source cap). Returns a
  numbered window around the change. In a playtest (loadstring unavailable) the check degrades
  to apply-without-check, flagged in the result.
- `grep_source { pattern, root?, plain?, maxResults? }` — `path:line: snippet` across all script
  sources (editor drafts), Lua patterns opt-in (`plain=false`), capped.

PropertyCatalog expansion (hand-curated v1; API-dump generation is a follow-up): BaseScript
(Enabled), Script (RunContext), LuaSourceContainer, Humanoid, ScreenGui, GuiObject core
(Frame/TextLabel/TextButton/TextBox/ImageLabel/ImageButton/ScrollingFrame), UIListLayout/UICorner,
Lighting, Workspace (Gravity/StreamingEnabled), Sound, SpawnLocation, Tool, Attachment.
NOTE: `Source` stays OUT of the catalog deliberately — script IO goes through the script tools
(protected: RobloxScriptSecurity read via plain .Source in some states; ScriptEditorService is
the sanctioned path).

Wiring: `Tools/init.luau` (require + append), Relay = RELAY (DataModel tools), `RelaySpec`
expected lists, SystemPrompt: the SCRIPTING pattern rewritten to "read before write; edit by
find/replace, not whole rewrites; grep before assuming; compile check catches syntax, playtest
catches behavior".

## Phase 2 — loop integrity

- **Preserve turns on abort/cancel** (`AgentLoop.luau`): `rollback()` no longer truncates to the
  pre-Send snapshot. If the history ends on a non-assistant turn, append an assistant note
  `"(turn interrupted: <why> — everything up to here is applied; say 'continue' to resume)"`;
  keep the TaskList as-is. The ONLY remaining truncate is the pre-send `isValidHistory` guard
  (protocol corruption = the one case where the history itself is the problem) and the outer
  pcall failsafe keeps its append-note behavior. Rationale: the iteration-cap path already
  proves this pattern; errors/cancels deserve the same.
- **`max_tokens` auto-continue**: a no-tool-use response with `stop_reason=="max_tokens"` appends
  the assistant turn + a user nudge `"(your output hit the token cap mid-stream — continue exactly
  where it cut off)"` and CONTINUES the loop (bounded by the iteration cap) instead of ending the
  turn with silently-truncated output.
- **Keep-K images**: `Compactor.pruneImagesKeepingLast(messages, keep)` gains a keep-count;
  config `imagesKept` (default 3, min 1) so before/after visual comparison works.
- **Compaction working-set budget**: `DEFAULTS.contextWindow` 1,000,000 → 200,000. Semantics
  change from "model window" to "working-set budget" (compact at 0.8×200k = 160k tokens): the
  uncached, non-streaming loop re-pays the full prompt every step, so a smaller resident set is
  strictly faster/cheaper; the true model window stays far larger, so compaction summaries have
  head-room. Configurable as before.

## Phase 3 — playtest as agent tools

PlayBridge's injected in-test scripts gain:
- a generic **`seval`** verb — server-side `loadstring` eval in the play-server DM (mirrors
  run_luau's serialize+print-capture contract, minimal version), replacing per-feature verbs as
  the agent's probe;
- a **cursored log buffer** — `LogService.MessageOut` + `ScriptContext.Error` (message + full
  stack) into a ring buffer with absolute indices; `slog2 {since}` returns `{lines, next}` so the
  agent can tail incrementally without loss (the old `slog` stays for the shell).

New `src/Tools/Playtest.luau` — descriptors that reuse the EXISTING sidecar `/play` channel
(the exact pipeline the shell uses — POST command, poll result):
- `playtest_start {}` / `playtest_stop {}` — edit-side (PlayBridge start/EndTest), returns fast.
- `playtest_act { verb, arg? }` — the existing act verbs (equip/walk/walkstop/activate/camera…).
- `playtest_eval { code }` — the new seval (server DM).
- `playtest_logs { since? }` — the cursored buffer, WITH stack traces.
- `playtest_capture {}` — the play-client screenshot, returned as image blocks (like capture).
- `playtest_status {}` — playing flag + basic in-test snapshot.

Relay: LOCAL (these are edit-plugin machinery driving the sidecar; they must never relay into a
play DM). SystemPrompt gains "# Testing gameplay for real" — after building gameplay, run a
playtest via these tools and verify with eval/logs/capture before claiming it works; `evaluate`'s
guidance points at runtime evidence for behavior categories.

## Oracles (charter discipline)

Per phase: `selene` 0/0 · `rojo build` green · the phase's Spec passes via the bridge ·
RelaySpec no-drift green · live dogfood of each new tool through the dev bridge in the open
place (Phase 3: a real agent-tool-driven playtest) · adversarial review of the full diff at the
end. Commits stay local on `master`, never pushed.
