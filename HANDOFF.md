# Studio Agent — Session Handoff

**Read this first when continuing in a fresh session.** It captures the current state, every
decision made, and exactly what to do next. The full original design is in
`docs/superpowers/specs/2026-06-16-studio-agent-cliproxyapi-design.md` and the implementation plan
in `docs/superpowers/plans/2026-06-16-studio-agent-cliproxyapi-plan.md`; this file supersedes them
where they differ (the project evolved past the original 11 milestones).

## What this is
A Roblox Studio **plugin that hosts a Claude agent loop** — "Claude Code inside Studio." It talks
to Claude over `HttpService` and executes tools in-process at PluginSecurity. It's a working,
multi-session chat that builds/edits the DataModel (scripting, GUIs, rigs, animation), reads and
writes typed properties, runs and self-verifies code, and persists chat history.

## Build / test loop
```powershell
cd C:\Users\manso\Desktop\Claude-Plugin
.\build.ps1            # rojo build default.project.json -> StudioAgent.rbxm, copies to %LOCALAPPDATA%\Roblox\Plugins
selene src             # 0 errors expected (1 known warning: CreateDockWidgetPluginGui deprecated)
stylua src             # format; stylua --check src must be clean before committing
```
Toolchain via rokit (`rokit.toml`: rojo 7.6.1, selene 0.31.0, stylua 2.5.2). After building, the
user reopens Studio to load the new plugin. **You cannot run Studio here** — Luau using Roblox
datatypes/APIs can't be executed outside Studio, so the USER runs live tests and reports back; lean
on `selene`/`stylua`/`rojo build` for static verification and on adversarial-review workflows for
logic you can't run.

## The connection (critical — see memory `studio-agent-model-connection`)
The plugin reaches Claude through an **SSH tunnel to hecate's CLIProxyAPI** (NOT a local proxy):
```
plugin -> http://127.0.0.1:8318 -> ssh -L (devel@100.119.185.111, key ~/.ssh/d33kvr3_ed25519)
       -> remote 127.0.0.1:8390 -> socat container `studio-agent-fwd` on docker net hecate_hecate_net
       -> hecate llm-proxy:8317 (CLIProxyAPI v7.1.39) -> Anthropic (Claude subscription OAuth, mrdogsog@gmail.com)
```
- Open the tunnel with `proxy/tunnel.ps1` (must stay running). The remote socat forwarder auto-restarts.
- Proxy key = hecate's `CPAPI_INBOUND_KEY` (`61a47d18...`), entered in the panel's proxy-key field, stored via `plugin:SetSetting` (never in source). Model `claude-opus-4-8`, `max_tokens` 8192.
- **Gotcha:** CLIProxyAPI returns a transient `"unknown provider for model"` (502) right after a cold start / catalog refresh, then self-heals. The loop already classifies this + Overloaded/429/5xx as retryable. The local-proxy setup in `proxy/` (config + login.ps1) is a working fallback but cold proxies hit the transient bug; hecate's is always warm.

## Module map (`src/`)
- `init.server.luau` — entry: toolbar button, dock widget, builds deps, mounts the panel (re-mounts on play-transition blanking), best-effort enables loadstring.
- `Config.luau` — typed `SetSetting`/`GetSetting` wrapper; defaults (baseUrl 8318, opus, maxTokens 8192, **maxIterations 20**, retry knobs).
- `Anthropic.luau` — HTTP client (`/v1/messages`, Bearer, bimodal RequestAsync error handling incl. `kind="context"` for the server-only HTTP error) + `ping`.
- `AgentLoop.luau` — the tool loop driving a `Conversation`; transient retry + backoff; rolls back to a pre-Send snapshot on any non-clean exit so history always ends on an assistant turn.
- `Conversation.luau` — running multi-turn message history (memory across sends) + load/clear.
- `Sessions.luau` — persist/list/load chats via `plugin:SetSetting` (survive restarts; images stripped on save via `MessageUtil`).
- `MessageUtil.luau` — pure message helpers (stripImages, promptTokensFromUsage, isValidHistory) shared by Sessions + Compactor.
- `Compactor.luau` / `CompactorSpec.luau` — context-window auto-compaction (image pruning + summarize-and-replace); the spec is an in-Studio self-test like `SerializeSpec`. `AgentLoop` prunes every iteration, compacts proactively at 80% of the window + reactively on a context-length 400, and tracks `Conversation.lastPromptTokens`.
- `SystemPrompt.luau` — the brain: tool policy, value-encoding scheme, scripting/GUI/rig/animation patterns, verify-and-iterate, testing model.
- `Serialize.luau` / `Decode.luau` — Luau<->JSON tagged scheme (frozen comment block, byte-identical in both); Decode is total. `SerializeSpec.luau` is an in-Studio round-trip self-test.
- `Logs.luau` — LogService ring buffer (captures runtime errors, incl. during playtest).
- `Tools/init.luau` — registry + dispatch (total). Tools: `run_luau`, `get_tree`, `search`, `get_properties`, `set_property`, `get_output`, `create_instance`, `capture`. `dispatch(name,input,context)` now returns `Content = string | {blocks}` (string for most tools; an image-blocks array for `capture`) and threads a `context` ({config,anthropic}) so a tool can reach loop deps.
- `Tools/RunLuau.luau` (loadstring exec, ChangeHistory in edit / direct in play), `Tools/Tree.luau`, `Tools/Properties.luau`, `Tools/Path.luau`, `Tools/PropertyCatalog.luau`, `Tools/Output.luau`, `Tools/Create.luau`, `Tools/Capture.luau` (GETs the sidecar, returns an Anthropic image tool_result; all failures → string error).
- `UI/Widget.luau` — chat panel: scrolling transcript, message input, New chat, History (reopen saved sessions), proxy-key row, sidecar-token row (vision).
- `sidecar/` — Python screenshot sidecar for VISION (built, runs on 127.0.0.1:8389, token in `sidecar/.token`). **Wired into the `capture` tool** ✅ — the plugin GETs `?b64=1`, Bearer token, and forwards the PNG as a base64 image block.

## Status: everything below is DONE, built clean, committed, and user-verified in Studio
M-pre connection (tunnel) ✅ · M0 toolbar ✅ · M1 Config ✅ · M2 HTTP+ping ✅ · M3/M4 Serialize/Decode ✅
· M5 run_luau ✅ · M6 agent loop ("create a red part" works) ✅ · M7 structured tools ✅ · M8 SystemPrompt ✅
· M9 chat UI + session history ✅ · M12 conversation memory ✅ · M13 self-verify + playtest-aware ✅
· create_instance (loadstring-free building) ✅ · **VISION `capture` tool (image tool_result) ✅** (built clean, adversarially reviewed — 0 confirmed bugs) · **CONTEXT-WINDOW auto-compaction ✅** (image pruning + summarize-and-replace; adversarial review found+fixed 2 bugs; CompactorSpec self-test). **Both LIVE-VERIFIED in Studio** — capture: agent built a GUI + screenshotted it; compaction: `CompactorSpec` 12/12 + a forced low-threshold run fires the `[compacted…]` notice and the chat SURVIVES the limit (a 4th fix from that run strengthened the summary prompt to keep outstanding multi-step instructions; tiny-window summaries stay somewhat lossy under extreme settings, fine at production keep=6/800k). Latest commit: `git log`.

## Decisions made (authoritative)
1. **Tunnel to hecate, not a local proxy** — local/TemporalRift proxies hit the cold-start "unknown provider" bug; hecate's is always warm. Client stays base-URL configurable.
2. **Model: `claude-opus-4-8` default**, `max_tokens` 8192 (subscription window reserves max_tokens; large values 400).
3. **Playtest constraints (engine rules, verified empirically):**
   - `HttpService` is **server-only** → the agent works in edit and the Play **Server view**, NOT the client view.
   - `loadstring` is **disabled during a playtest** and `ServerScriptService.LoadStringEnabled` does not exist in this Studio version to re-enable it → `run_luau` can't build during a playtest. **`create_instance` + `set_property` + `get_*` are loadstring-free and ARE the way to build during a playtest.**
   - Self-testing works: `RunService:Run()`/`:Stop()` from the plugin drives an in-place sim (single context, HTTP + tools work); observe via `get_output`/`get_properties`. User confirmed this works.
4. **Client-side live operation: DECIDED to ATTEMPT a server relay LATER** (experimental). The user wants the capability (no Client/Server swapping) but accepts it's uncertain. For now, the **Server-view dropdown** is the workaround. See "Next: relay" below.
5. Dev-only Ping/run_luau debug boxes were removed from the panel (the agent covers usage).

## What to build NEXT (in order)
### ~~1. VISION — wire the `capture` tool~~ ✅ DONE
Wired exactly as planned: `Config.sidecarUrl`/`sidecarToken`, `Tools/Capture.luau` (RequestAsync GET,
Bearer token, `?b64=1`, returns an `{type="image",source={type="base64",media_type="image/png",data}}`
block), the dispatch contract extended to `Content = string | {blocks}` + a `context` arg, a
sidecar-token row in the Widget, and the `capture` tool documented in SystemPrompt. Built clean +
adversarially reviewed (0 confirmed bugs). **Still needs the user to live-verify in Studio:** start the
sidecar (`sidecar/run.ps1`), paste its token into the panel's "sidecar token" field + Save, then ask
the agent to build a GUI and call `capture` — confirm it sees the screenshot. Note from review: image
size is fine (Anthropic auto-resizes; base64 up to ~13.3MB accepted), so no downscaling needed.

### ~~2. CONTEXT-WINDOW auto-compaction~~ ✅ DONE
Keeps a long chat alive instead of dying at the 1M window. Spec:
`docs/superpowers/specs/2026-06-16-studio-agent-context-compaction-design.md`; plan:
`docs/superpowers/plans/2026-06-16-context-compaction.md`. Two mechanisms: always-on image pruning
(keep only the latest screenshot — `Compactor.pruneImagesKeepingLast`) and summarize-and-replace at
80% of the window (`Compactor.compact`: summarize older turns into one user turn, keep a verbatim
tail, history stays API-valid). New modules `MessageUtil`/`Compactor`/`CompactorSpec`;
`Conversation.lastPromptTokens`/`replaceMessages`; Config `contextWindow`/`compactThreshold`/
`keepRecentMessages`. Adversarial review found + fixed 2 real bugs (compaction-aware rollback;
validate-rebuilt-before-install). **Pending: user runs `CompactorSpec` in Studio (12 cases) + a
long-chat live test with a lowered threshold to force a compaction.**

### 3. SUBAGENTS / ultracode orchestration (feature #2 — feasibility brief done, ready to spec)
Let the in-Studio agent fan out subagents (parallel finders/verifiers/judges, like Claude Code's
Agent tool). The investigation (workflow `wf_696c655c-99a`, 5 agents) verdict: **feasible** —
model-driven `dispatch_subagents` tool; the hard constraint is the single shared DataModel + one
ChangeHistory stream → **parallel READERS / serial WRITERS**. Shape: each child is a fresh
`Conversation` running an extracted `runConversation` body with a scoped (read-only) toolset, returning
its terse final text as one tool_result (which also keeps heavy reads/images out of the parent's
window). Blockers, all fixable: the module-global `running` flag guards `send()` not `runLoop`; the
loop returns final text only via emit (use `collectText`); no toolset allowlist hook yet. Recommended
v1 defaults: edit-mode-first, READ-ONLY children (parent does writes), cap 3–4, readers on
`claude-sonnet-4-6` / parent+judge on opus, depth-1, concise per-child summaries. Note: a brief claim
that `Create.luau` has an "unconditional FinishRecording" corruption bug is OVERSTATED — `FinishRecording`
is already nil-guarded; the only real (minor) gap is that Create proceeds without a recording when it
can't open one (unlike RunLuau/Properties which refuse). Needs its own brainstorm → spec → plan.

### 4. Client-side RELAY (experimental)
Make the agent work in the Play **client** view without swapping. HTTP is server-only, so the
agent's HTTP + build tools must run server-side, reached via a `RemoteFunction` bridge from the
panel. **Verify the foundation FIRST** (these are unknown and may block it):
- Can a plugin, in client-view Play Solo, find + `:InvokeServer()` a RemoteFunction created by a server script?
- How does the relay server Script get into the Play Solo session without being saved to the published place? (Beware: `Archivable=false` excludes from Clone too, which may exclude it from the play session — TEST this.)
- The relay must run HTTP + `create_instance`/`set_property`/`get_*` server-side (NOT `run_luau` — loadstring is off in play). If feasible, the panel becomes a thin client over RemoteEvents.
If it hits a sandbox wall, fall back to the Server-view swap.

### 5. Smaller cleanups
- Resolve the `CreateDockWidgetPluginGui` deprecation (selene's 1 warning). Verify the current method name against create.roblox.com (the M9 plan claimed `CreateDockWidgetPluginGuiAsync`, unverified — confirm before switching).
- `create_instance` is one-instance-per-call (10 parts = ~10 calls); consider a batch variant if bulk-in-playtest gets heavy.

## Gotchas for the next session
- **Compaction rollback:** the abort/cancel rollback used an absolute message-count `snapshot`, but `Compactor.compact` shrinks the array — so AFTER a compaction the rollback must instead ensure the history ends on an assistant turn (the `compacted` flag + `rollback()` in `AgentLoop`), NOT count-truncate (which silently no-ops below the snapshot). `compact()` also validates the rebuilt history (`MessageUtil.isValidHistory`) before installing — a malformed kept tail → refuse, never ship a guaranteed 400.
- **Empty JSON objects:** Roblox `HttpService:JSONEncode({})` emits `[]`, but Anthropic needs a
  tool_use `input` to be an OBJECT. A no-arg tool call (capture / get_output with no args) decodes to
  an empty table and round-trips to `[]` → 400 `tool_use.input: Input should be an object`. Fixed
  generically in `Anthropic.encodeBody` (sentinel-string swap → splice back to `{}`); don't reintroduce
  a raw `JSONEncode(body)` for the request body. Verified against the live API ([] fails, {} 200s).
- **Windows PowerShell 5.1** (not Core): `RandomNumberGenerator.Fill` doesn't exist (use `Create().GetBytes`); no `&&`/ternary; `2>$null` not `2>/dev/null`.
- **SSH to remote runs cmd.exe** (Windows host `desktop-d33kvr3`): Unix commands fail; quoting `--format "table {{...}}"` through PowerShell→ssh→cmd breaks — keep remote commands simple or use plain `docker ps`.
- **Workflow subagents write files to disk** even when asked to return source only — prefer extracting from the returned schema result and writing yourself for determinism.
- LF→CRLF git warnings are benign on Windows.
- selene judges success by "0 errors" (it exits 1 on warnings too); `loadstring`/`setfenv` are deprecated but used intentionally.

## Restart the tunnel + sidecar before testing
- Tunnel: `proxy\tunnel.ps1` (or `ssh -i ~/.ssh/d33kvr3_ed25519 -N -L 8318:127.0.0.1:8390 devel@100.119.185.111`).
- Vision sidecar: `cd sidecar; .\run.ps1` (token printed + saved to `.token`).
