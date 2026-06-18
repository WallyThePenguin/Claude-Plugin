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
- **CRITICAL (found via live test 2026-06-17): the proxy STRIPS the client `system` field.** Every CLIProxyAPI Claude **subscription-OAuth** daemon — hecate's AND a fresh local one — replaces the client `system` with its own injected Claude Code system prompt (subscription access is gated behind the Claude Code identity; hecate additionally hardens this deliberately, as it circulates real money in another project). Proven with a codeword probe: a secret in `system` never reached the model; the same secret in a leading USER message did. **So the plugin's `SystemPrompt` AND cross-session memory are NOT sent via `system` — they are delivered as a LEADING user/assistant "preamble" prepended to the sent messages in `AgentLoop.runLoop` (`buildPreamble`/`withPreamble`); the `system` field is omitted.** (This means the plugin's authored system prompt did NOT reach the model before this fix — the agent ran on tool descriptions + Claude Code's prompt. Now live-verified: a fresh chat lists the plugin's own instruction sections AND recalls stored memory.) **The same delivery defect was found+fixed in two more send paths (commit `4895fa4`, via the shared `MessageUtil.withSystemPreamble`/`prependLeading`): `Subagent.luau` (children's `SUBAGENT_BASE`+role+OUTPUT CONTRACT, now seeded as a leading preamble — LIVE-VERIFIED: a 2-child fan-out returned terse structured reports) and `Compactor.luau` (`SUMMARY_SYSTEM`, now a leading preamble before the transcript). `AgentLoop` also gained an `isValidHistory` guard before each send (catches a stray pause_turn double-assistant). So ALL three send paths now deliver their system prompt via a leading message.** Note: proxy `docker-compose.yml` now maps host **8319** (not 8318) so a local daemon doesn't clash with the SSH tunnel on 8318.

## Module map (`src/`)
- `init.server.luau` — entry: toolbar button, dock widget, builds deps, mounts the panel (re-mounts on play-transition blanking), best-effort enables loadstring.
- `Config.luau` — typed `SetSetting`/`GetSetting` wrapper; defaults (baseUrl 8318, opus, maxTokens 8192, **maxIterations 20**, retry knobs).
- `Anthropic.luau` — HTTP client (`/v1/messages`, Bearer, bimodal RequestAsync error handling incl. `kind="context"` for the server-only HTTP error) + `ping`.
- `AgentLoop.luau` — the tool loop driving a `Conversation`; transient retry + backoff; rolls back to a pre-Send snapshot on any non-clean exit so history always ends on an assistant turn.
- `Conversation.luau` — running multi-turn message history (memory across sends) + load/clear.
- `Sessions.luau` — persist/list/load chats via `plugin:SetSetting` (survive restarts; images stripped on save via `MessageUtil`).
- `MessageUtil.luau` — pure message helpers (stripImages, promptTokensFromUsage, isValidHistory) shared by Sessions + Compactor.
- `Compactor.luau` / `CompactorSpec.luau` — context-window auto-compaction (image pruning + summarize-and-replace); the spec is an in-Studio self-test like `SerializeSpec`. `AgentLoop` prunes every iteration, compacts proactively at 80% of the window + reactively on a context-length 400, and tracks `Conversation.lastPromptTokens`.
- `Retry.luau` — `isTransient` + `sendWithRetry` (shared by `AgentLoop` and `Subagent`).
- `Subagent.luau` / `Tools/Subagents.luau` / `SubagentsSpec.luau` — the `dispatch_subagents` tool fans out parallel READ-ONLY children (`Subagent.run`, Sonnet, allowlisted toolset); `Tools.schemasFor`/the dispatch `allowedTools` allowlist enforce read-only + depth-1.
- `Tools/Web.luau` / `WebSpec.luau` — `web_fetch` (any non-roblox.com URL → text; `stripHtml`/`stripTags`) + `web_search` (DuckDuckGo HTML scrape, `parseDdg`); both read-only + in the subagent allowlist.
- `TaskList.luau` / `TaskListSpec.luau` / `Tools/Tasks.luau` — the `update_tasks` tool + the in-panel build checklist. `TaskList` (held in `deps.taskList`, NOT in the message history → survives re-mount + compaction) owns the list + the PURE `normalize`/`render`/`counts` (caps: `MAX_CONTENT=200`, `MAX_TASKS=50`; UTF-8-safe truncation; drops non-string content; declarative full-list replace). `Tools/Tasks.luau` is a thin wrapper over `context.taskList` (NOT in the subagent allowlist + nil-guarded for children). `AgentLoop` threads `taskList` into the tool context, emits a `tasks` event after an `update_tasks` batch, and snapshots/restores it in lockstep with the conversation rollback. `Widget` renders a collapsible reflowing checklist section (glyphs `○`/`◐`/`●`); `Sessions` persists it per chat.
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
· create_instance (loadstring-free building) ✅ · **VISION `capture` tool (image tool_result) ✅** (built clean, adversarially reviewed — 0 confirmed bugs) · **CONTEXT-WINDOW auto-compaction ✅** (image pruning + summarize-and-replace; adversarial review found+fixed 2 bugs; CompactorSpec self-test). **Both LIVE-VERIFIED in Studio** — capture: agent built a GUI + screenshotted it; compaction: `CompactorSpec` 12/12 + a forced low-threshold run fires the `[compacted…]` notice and the chat SURVIVES the limit (a 4th fix from that run strengthened the summary prompt to keep outstanding multi-step instructions; tiny-window summaries stay somewhat lossy under extreme settings, fine at production keep=6/800k). · **SUBAGENTS (`dispatch_subagents`) ✅** (feature #2 of capability parity — parallel READ-ONLY children on Sonnet, separate `Subagent.luau` runner, `Retry.luau` shared, allowlist at dispatch blocks writers + nesting). **LIVE-VERIFIED in Studio** — `SubagentsSpec` 6/6 + a real fan-out (3 parallel children scouted Workspace/Lighting/StarterGui and the parent synthesized; nothing mutated); adversarial review 0 confirmed bugs (a join-hang was caught + fixed pre-review). · **WEB ACCESS (`web_fetch` + `web_search`) ✅** (feature #3 — `Tools/Web.luau`: fetch any page as text / DuckDuckGo search; both read-only + in the subagent allowlist). **LIVE-VERIFIED** — `WebSpec` 6/6 + a real run (web_fetch'd example.com, web_search'd via DDG and parsed results). The live test caught two HARD Roblox HttpService limits (see gotchas): **roblox.com domains are blocked** (can't fetch create.roblox.com docs) and **the User-Agent header is forbidden** — both fixed/worked-around. · **TASK TRACKING (`update_tasks`) ✅** (feature #4 — a visible multi-step build checklist in the panel, mirroring TodoWrite: declarative full-list-replace tool; `TaskList.luau` state held in `deps` so it survives both the Play/Edit re-mount AND compaction (it's outside the message history); loop-owned `tasks` emit; subagent-isolated; session-persisted; collapsible reflowing panel section). **LIVE-VERIFIED in Studio** — `TaskListSpec` 16/16 + a real 4→5-step build where the checklist appeared and ticked pending→in_progress→completed live (correct glyphs: `○` grey / `◐` blue / `●` green), collapse/expand reflow, New chat clears, reopen-session restores statuses. Adversarial review (Workflow): 7 findings, 4 confirmed (all LOW), 3 correctly refuted — all 4 fixed (junk-content coercion, dropped-count inflation, transcript min-height clamp at small dock, taskList rollback desync). · **CROSS-SESSION MEMORY (`remember` + `forget`) ✅** (feature #5 — two scopes: `global` (every place) + per-`GameId` `game`; `Memory.luau` store persisted via `plugin:SetSetting`; FIFO-capped (25 × 240 chars), UTF-8-safe; parent-only tools; a panel Memory viewer with per-entry `✕`; `MemorySpec` 12/12). Adversarial review: 4 confirmed (2 MED + 2 LOW) all fixed (loadBucket id-sanitization + read-cap + de-dup; the hidden-transcript view trap; forget scope/id validation). **Recall required a delivery fix — see next.** · **SYSTEM-PROMPT + MEMORY DELIVERY via a leading message ✅ (critical fix, commit `cf9ccf7`)** — live-verify revealed the proxy STRIPS the client `system` field (see "The connection"), so recall (and the whole `SystemPrompt`) never reached the model. Now `AgentLoop` prepends the base `SystemPrompt` + recalled memory as a leading user/assistant preamble to the sent messages and omits `system`. **LIVE-VERIFIED in Studio via hecate**: a fresh chat recalled both stored facts (game UI + global preference) AND the agent now lists the plugin's own instruction sections (`# Tools`/`# Value encoding`/`# Memory across sessions`/…) — the authored system prompt reaches the model for the first time. · **PARALLEL WRITER SUBAGENTS (`dispatch_writers`) ✅ LIVE-VERIFIED** (the "go faster" feature — N writer children build INDEPENDENT regions of the DataModel at once; the speedup is overlapping LLM round-trips since writes are instant; stays an inside tool, no Roblox MCP/Team Create). `Tools/Writers.luau` reuses `Subagent.run` with a structured-only toolset (`create_instance`/`set_property` + reads, NO `run_luau`, depth-1) + `Tools/RegionGuard.luau` fencing each child to its region; `writerModel` Sonnet / `writerMaxParallel` 3. **Safe because** Luau is cooperatively scheduled and the structured writes are synchronous → per-call ChangeHistory recordings are atomic (can't overlap). Adversarial review (Workflow): 11 findings, 7 confirmed (2 HIGH + 1 MED + LOWs), 4 correctly refuted — all fixed: **dispatch_writers now ENFORCES region disjointness (rejects equal/nested) + breadth (rejects `game`/bare service)** up front; `create_instance` refuses on a nil recording; the create Parent-map + a non-Instance `set_property` Parent are guarded. **LIVE-VERIFIED in Studio** (fresh Baseplate): `WritersSpec` 8/8 + a real 2-region parallel build (the parent created StarterGui.Shop + StarterGui.Settings, dispatched two writers that built a shop UI and a settings UI IN PARALLEL, each confined to its region, parent verified both trees — and it applied the recalled global "dark Gotham" preference); plus a deliberate bad-region dispatch (two `game.Workspace` writers) was REJECTED with the "region too broad" error. Latest commit: `git log`.

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

### ~~3. SUBAGENTS / `dispatch_subagents`~~ ✅ DONE (feature #2 of capability parity)
Spec `docs/superpowers/specs/2026-06-16-studio-agent-subagents-design.md`; plan
`docs/superpowers/plans/2026-06-16-subagents.md`. Shipped: the parent calls `dispatch_subagents` →
spawns N **read-only** children in parallel via `task.spawn`, each a `Subagent.luau` ephemeral loop on
Sonnet with an allowlisted toolset; results return as one JSON tool_result. `Retry.luau` shares the
retry path with the parent loop. Read-only + **depth-1** enforced by an ALLOWLIST at `Tools.dispatch`
(`context.allowedTools`) — blocks writers AND `dispatch_subagents` (a destructive-flag check wouldn't,
since the tool is non-destructive). The DataModel-safety story: the parent yields inside dispatch while
children read, so it isn't writing (quiescent). Config: `subagentModel`/`subagentMaxParallel`(4)/
`subagentMaxIterations`(15). Live-verified (SubagentsSpec 6/6 + a 3-child fan-out) + review 0 bugs.

### 4. CAPABILITY PARITY — remaining features (the "everything you can do, inside Roblox" vision)
The user wants the in-Studio agent to be a full peer. Done: subagents (#2 ✅), web access (#3 ✅ —
UPGRADED 2026-06-17 to Anthropic SERVER-side web_search/web_fetch, which DO reach roblox.com — LIVE-VERIFIED; spec+plan `docs/superpowers/{specs,plans}/2026-06-17-*server-side-web-tools*`), **task tracking (#4 ✅ — `update_tasks`, live-verified;
spec/plan dated 2026-06-17)**, **cross-session memory (#5 ✅ — `remember`/`forget`, live-verified;
spec `docs/superpowers/specs/2026-06-17-studio-agent-cross-session-memory-design.md`, plan
`docs/superpowers/plans/2026-06-17-cross-session-memory.md`; required the `system`→preamble delivery
fix, see "The connection")**. Remaining: **skills** — reusable build recipes (own brainstorm→spec→plan).
Things that DON'T map to Roblox (skip): OS/computer-use (it acts via the DataModel API), raw git.

**SERVER-SIDE WEB TOOLS ✅ LIVE-VERIFIED (2026-06-17)** — `web_fetch`/`web_search` moved from client-side
HttpService (roblox.com-blocked) to Anthropic's DIRECT server-side tools (`web_search_20250305` /
`web_fetch_20250910`). Proven via a probe (CLIProxyAPI forwards server tools on the subscription path;
the code-exec `_20260209` variants `too_many_requests`, so use the direct versions) and LIVE-VERIFIED in
Studio on the hecate tunnel: the agent `web_fetch`ed create.roblox.com (metadata) + the GitHub mirror
(full body), `web_search`ed and cited URLs, and a `dispatch_subagents` research child ran its OWN
server-side `web_search` and cited a devforum.roblox.com URL. Spec `docs/superpowers/specs/
2026-06-17-studio-agent-server-side-web-tools-design.md`, plan `docs/superpowers/plans/
2026-06-17-server-side-web-tools.md`. Adversarial review (Workflow) found+fixed 1 MED bug: `Subagent.run`
lacked the parent loop's `pause_turn` handling, so a child mid-server-tool-turn returned prematurely —
now mirrors the parent (echo + resume). Integration was tiny because the loop already ignores
`server_tool_use` (collects only `tool_use`) and `isValidHistory`/`pause_turn` were already compatible.

**SKILLS ✅ LIVE-VERIFIED (2026-06-18) — the LAST capability-parity feature; ALL parity features now
DONE.** Spec `docs/superpowers/specs/2026-06-17-studio-agent-skills-design.md`, plan
`docs/superpowers/plans/2026-06-18-skills.md`. Named recipes the agent invokes via `use_skill(name,
args?)`, which returns the recipe TEXT the agent then executes with its existing tools (composes with
dispatch_writers/update_tasks/capture). New modules: `SkillCatalog.luau` (pure: normalize/validate/
render/catalog) + `SkillCatalogSpec.luau` (9 cases), `BuiltinRecipes.luau` (5: leaderstats, shop-gui,
r15-npc, datastore-save, parallel-zones), `BuiltinWorkingSkills.luau` (8 Studio-adapted ports:
brainstorm-a-build, plan-a-build, test-first, debug-systematically, review-my-build, gui-design-quality,
create-skill, research-a-topic), `SkillStore.luau` (merges built-ins + persisted USER skills, global-
scope, mirrors Memory), `Tools/Skills.luau` (use_skill/save_skill/delete_skill — 3 PARENT-ONLY
non-destructive tools). The catalog rides the LEADING PREAMBLE alongside SystemPrompt+memory (proxy
strips `system`); built-in names are RESERVED (save rejects a collision, delete refuses a built-in);
user skills persist via `plugin:SetSetting` (`StudioAgent_skills_user`), capped 20. Widget gained a
**Skills** viewer (built-ins read-only grouped by family + user skills with a ✕). NO Config changes (caps
are SkillCatalog constants). Adversarial review (Workflow): 1 LOW confirmed + fixed (`normalizeName`
re-strips a trailing dash after truncation). **LIVE-VERIFIED in Studio (hecate tunnel, fresh Baseplate):**
`SkillCatalogSpec` 9/9; the catalog renders in the panel (all 13 built-ins, two families); `use_skill
leaderstats {statNames:"Coins, Wins"}` loaded the recipe and the agent BUILT the LeaderstatsSetup Script
+ a playtest showed a working leaderboard with Wins+Coins; `save_skill` persisted a 'spinning-part' user
skill (shown under YOUR SKILLS); the ✕ deleted it. **All capability-parity features are now complete.**
Remaining roadmap: the client-side server RELAY (experimental); the CreateDockWidgetPluginGui deprecation.

**Delivery now consistent across all send paths (commit `4895fa4`):** `AgentLoop`, `Subagent`, and
`Compactor` all deliver their system prompt via a leading message (`MessageUtil.withSystemPreamble`/
`prependLeading`), since the proxy strips `system`. Subagent fix live-verified (2-child fan-out →
terse structured reports); compactor fix is static-verified (same proven primitive) but not yet
live-forced (needs a long session to trigger a compaction — verify summary quality next time).

### 5. Client-side RELAY (experimental)
Make the agent work in the Play **client** view without swapping. HTTP is server-only, so the
agent's HTTP + build tools must run server-side, reached via a `RemoteFunction` bridge from the
panel. **Verify the foundation FIRST** (these are unknown and may block it):
- Can a plugin, in client-view Play Solo, find + `:InvokeServer()` a RemoteFunction created by a server script?
- How does the relay server Script get into the Play Solo session without being saved to the published place? (Beware: `Archivable=false` excludes from Clone too, which may exclude it from the play session — TEST this.)
- The relay must run HTTP + `create_instance`/`set_property`/`get_*` server-side (NOT `run_luau` — loadstring is off in play). If feasible, the panel becomes a thin client over RemoteEvents.
If it hits a sandbox wall, fall back to the Server-view swap.

### 6. Smaller cleanups
- Resolve the `CreateDockWidgetPluginGui` deprecation (selene's 1 warning). Verify the current method name against create.roblox.com (the M9 plan claimed `CreateDockWidgetPluginGuiAsync`, unverified — confirm before switching).
- `create_instance` is one-instance-per-call (10 parts = ~10 calls); consider a batch variant if bulk-in-playtest gets heavy.

## Gotchas for the next session
- **Roblox HttpService limits (found via live test, invisible to static review):** (1) it **blocks roblox.com domains** — `RequestAsync` to create.roblox.com / devforum.roblox.com fails with "not allowed to access that Roblox resource", this still applies to the plugin's OWN HttpService calls (the Anthropic connection, the capture sidecar). **BUT `web_fetch`/`web_search` are NO LONGER client-side — as of 2026-06-17 they are Anthropic SERVER-side tools (`web_search_20250305`/`web_fetch_20250910`), executed on Anthropic's infra, so they DO reach create.roblox.com + the dev forum (LIVE-VERIFIED).** Caveat: create.roblox.com is a JS SPA, so a raw fetch returns mostly page metadata — use the GitHub creator-docs raw mirror (raw.githubusercontent.com/Roblox/creator-docs/...) for full doc bodies. (The client-side `Tools/Web.luau`/`WebSpec.luau` + the DDG-scrape path were DELETED.) (2) it **forbids setting the `User-Agent` header** ("Header 'User-Agent' is not allowed!") — don't set it; Roblox sends its own. DuckDuckGo's html endpoint works fine with Roblox's default UA.
- **Subagent read-only/depth-1 is an ALLOWLIST, not a destructive-flag check:** `Tools.dispatch` rejects a tool when `context.allowedTools` is set and the name isn't in it. A destructive-flag check would NOT work — `dispatch_subagents` is itself `destructive=false`, so only an allowlist (the 5 read tools) blocks both writers AND nesting. Children must always be dispatched with `allowedTools`. Also: pcall-wrap the WHOLE subagent worker (incl. `buildSubagent`) so the `while done<n` join can't hang on a throw.
- **Compaction rollback:** the abort/cancel rollback used an absolute message-count `snapshot`, but `Compactor.compact` shrinks the array — so AFTER a compaction the rollback must instead ensure the history ends on an assistant turn (the `compacted` flag + `rollback()` in `AgentLoop`), NOT count-truncate (which silently no-ops below the snapshot). `compact()` also validates the rebuilt history (`MessageUtil.isValidHistory`) before installing — a malformed kept tail → refuse, never ship a guaranteed 400.
- **Task-list rollback in lockstep:** `update_tasks` mutates `deps.taskList` IN PLACE and the panel re-renders mid-turn, so on a non-clean exit the loop must restore the taskList alongside the conversation (`taskSnapshot` captured at Send start; restored in `rollback()` AND the `AgentLoop.send` outer failsafe), else the panel (and a cancel-path save) desyncs from the rolled-back history + persisted blob. The iteration-cap path does NOT roll back (keeps progress, resumable), so it keeps the checklist too. `update_tasks` is parent-only: not in the subagent `READ_ONLY` allowlist, and children's tool context carries no `taskList`.
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
