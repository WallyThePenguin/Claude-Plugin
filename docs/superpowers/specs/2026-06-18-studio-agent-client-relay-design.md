# Studio Agent — Client-View Server Relay Design

- **Date:** 2026-06-18
- **Status:** Approved design (calls delegated to the implementer) — pending spec self-review, user
  review, then implementation plan.
- **Relates to:** `HANDOFF.md` (roadmap item #5 — "Client-side RELAY"); the connection findings in
  memory `studio-agent-model-connection`; the foundation research + the LIVE spike below.
- **Scope:** ONE feature — make the agent usable in the Play **client** view without manually
  switching to the Server view. Fallback (Server-view dropdown) stays as-is.

## Goal

Today the agent works in **edit** and in the Play **Server** view, but NOT the Play **client** view:
`HttpService` is server-only and the authoritative DataModel is the server's, so in client view the
plugin's Anthropic call fails (`kind="context"` → "switch to the Server view") and DataModel writes
would only touch the client replica. The user wants to stay in the normal **client** playtest view
(seeing their game as a player does) and still chat with the agent and have it build/edit.

The relay makes the **client-view panel functional** by routing the two server-only operations —
the Anthropic HTTP call and the DataModel/HTTP tool calls — to a tiny executor running in the
**play-session server**, reached over a `RemoteFunction`. Everything else (loop orchestration, UI,
and plugin-only state: Config/Sessions/Memory/Skills/TaskList/Compactor) stays in the client-view
plugin copy where it already works.

## Foundation — LIVE-VERIFIED by a throwaway spike (2026-06-18)

The prior research (`uncertain-needs-spike`) was settled by an autonomous probe plugin
(`spike/relay-spike.server.luau`, throwaway) run in a fresh Baseplate. **Every gating unknown
resolved as a PASS** (Output, `[SPIKE ...]` tags):

- **Topology.** Accurate Play Solo summons **separate plugin copies per context**, each a fresh
  script execution (distinct copy ids). Tuples observed:
  - EDIT: `IsEdit=true IsRunning=false IsServer=true IsClient=true`
  - SERVER play copy: `IsEdit=false IsRunning=true IsServer=true IsClient=false`
  - CLIENT play copy: `IsEdit=false IsRunning=true IsServer=false IsClient=true`
  - The real `[StudioAgent]` plugin ALSO loaded a Server copy AND a Client copy during play.
- **A SERVER-context plugin copy EXISTS and is fully powered in-session:** its
  `HttpService:RequestAsync` succeeded (`example.com` → `Success=true Status=200`), and
  `Instance.new("Part")` built (loadstring-free).
- **The client-view plugin CAN reach the server (the decisive result):**
  `ReplicatedStorage.SPIKE_RF:InvokeServer({...})` **from the CLIENT-copy plugin thread RETURNED
  the server's table value** (`ok=true`). The research had rated this "likely doesn't work" — it
  works.
- **The SERVER copy stays alive across the view switch:** its heartbeat kept advancing (n=3→…→120)
  while the active view was Client.
- **Settings are a second, bidirectional bridge:** `plugin:SetSetting`/`GetSetting` is shared across
  copies in the one Studio process, near-real-time, both directions (server↔client read each other).
- **Isolation confirmed (expected):** `ServerStorage` is NOT visible from the client copy (so a
  shared-instance bridge in ServerStorage does not work — but the replicated `RemoteFunction` does).
- **No pollution:** after Stop, an Explorer search for `SPIKE` returned **0 matches** — every
  play-session create (the RF, the built Part, an injected Script) was discarded with the play DM and
  never entered the edit DM. A relay created at play-start cannot leak into the saved place.

**Verdict: PRIMARY/STRONGER PASS — the relay is feasible.** We use the cleanest proven bridge:
`RemoteFunction:InvokeServer` from the client-view plugin (synchronous, returns a value). The
settings bridge is a documented backup mechanism but not used by this design.

## The model: a thin server executor; the loop stays client-side

The agent loop and all plugin-only state remain in the **client-view plugin copy** (where the user
is). Only the loop's two server-only choke points relay:

1. **Anthropic HTTP** — `Retry.sendWithRetry` calls `anthropic:sendMessage(opts)`; `Compactor`
   uses the same `anthropic`. In client-play we swap in a relay-aware `anthropic` whose
   `:sendMessage(opts)` does `relayRF:InvokeServer({kind="http", opts=opts})`; the server runs the
   real `anthropic:sendMessage(opts)` (it builds the body, applies the empty-object `{}` encode fix,
   and does `RequestAsync`) and returns the `Result`.
2. **Tool dispatch** — the loop calls `Tools.dispatch(name, input, ctx)`. In client-play, DataModel/
   HTTP/loop-spawning tools relay (`relayRF:InvokeServer({kind="tool", name, input})` → the server
   runs `Tools.dispatch` against the authoritative server DM and returns `(content, isError)`).
   Plugin-only tools run LOCALLY in the client copy (they touch panel/plugin state, not the DM/HTTP).

In **edit** and **Server-view play**, no relay is used — the loop runs exactly as today.

### Relay vs local tool split
- **RELAY to server** (touch the DataModel, HTTP, or spawn child loops):
  `create_instance`, `set_property`, `get_tree`, `search`, `get_properties`, `get_output`,
  `capture` (server-side sidecar GET), `run_luau` (relays, still fails with loadstring-off in play —
  consistent with today), `dispatch_subagents`, `dispatch_writers` (the WHOLE child fan-out runs
  server-side, where children's HTTP + DM tools work natively — this naturally avoids any recursive
  relay).
- **LOCAL in the client copy** (plugin/panel state only): `update_tasks` (mutates the in-panel
  checklist + emits the `tasks` UI event), `remember`/`forget` (cross-session memory via
  `plugin:SetSetting`), `use_skill`/`save_skill`/`delete_skill` (skill store + recipe text).
- Implemented as a small `LOCAL_TOOLS` set; `Relay.shouldRelayTool(name) = not LOCAL_TOOLS[name]`.
- `web_search`/`web_fetch` need NO handling: they are Anthropic **server-side** tools that ride in
  the HTTP response (`server_tool_use` + `*_tool_result`), so the HTTP relay carries them for free.

## Why this is safe (and cannot leak to production)

- **Plugin-only by construction.** The relay host is part of the plugin (`init.server.luau`), and
  plugins run ONLY in Studio (edit + Studio playtests), NEVER in a published game. The relay
  `RemoteFunction` therefore can exist only during a Studio play session — it is impossible for it to
  ship to a live server.
- **Ephemeral.** It is created at play-start in the play server DM and discarded on Stop (spike:
  0 matches after stop). It never enters the edit DM, so it is never saved/published.
- **Studio-gated host.** `Relay.startHost` runs only when `RunService:IsStudio() and IsRunning() and
  IsServer() and not IsClient()` — i.e. only the SERVER play copy in Studio.
- **Solo is single-client.** In solo playtest the only client is the developer. (Team Test would
  expose the relay to other team members on the same test — see Non-goals; the host could later gate
  on a solo check or verify the invoking player. Not in scope for v1.)

## Key decisions (settled in brainstorming; design calls delegated)

1. **Loop stays in the client copy; relay only the 2 choke points** (not "run the whole loop on the
   server + stream events back"). Rationale: minimal change (the loop already isolates HTTP via
   `anthropic:sendMessage` and tools via `Tools.dispatch`); plugin-only state stays where its
   `plugin` APIs work; no server→client event-streaming machinery needed.
2. **Bridge = a replicated `RemoteFunction`** named `StudioAgentRelay` in `ReplicatedStorage`, NOT the
   settings bridge. InvokeServer is synchronous, returns a value, and proven to work from the
   client-view plugin. (Settings remain a documented backup, unused here.)
3. **No injected relay Script.** The SERVER **plugin copy** itself sets `OnServerInvoke` and is the
   handler (the spike proved the plugin copy's HTTP + builds work in-session). This avoids the
   Script.Source-injection + script-source-save-leak concerns entirely (no Script is created).
4. **Per-copy wiring at init**, decided from `RunService` (each play copy runs init fresh — proven):
   - SERVER play copy → `Relay.startHost(deps)` (creates the RF, sets the dispatcher).
   - CLIENT play copy → build a `RelayClient` (find the RF) + wrap `deps.anthropic`; pass the relay to
     the loop. The client copy's panel then transparently relays.
   - EDIT / SERVER-view → no relay (today's behavior).
5. **Relay payload = the Luau `opts`/`input` tables over InvokeServer** (NOT pre-JSON-encoded on the
   client — that would re-introduce the `{}`→`[]` empty-object bug; the server's `Anthropic` does the
   encode). Empty tool inputs (`{}`) survive remote serialization fine (the `[]` issue is a
   JSONEncode artifact only).
6. **Graceful fallback.** If the relay RF can't be found (host not up / a sandbox regression), the
   wrapped `anthropic:sendMessage` returns a `Result {ok=false, kind="context", message=...}` and the
   relayed tool returns an is_error result — both telling the user to switch to the Server view. The
   feature degrades to exactly today's behavior; it never hard-crashes the loop.

## Non-goals (YAGNI)

- **No whole-loop-on-server / event streaming** (decision 1).
- **No Team Test hardening in v1** (per-player auth on the relay). Documented as a future option;
  the relay is Studio-play-only + ephemeral, so the exposure is bounded to a test session.
- **No making `run_luau` work in play** — loadstring is off in playtest regardless of view; relaying
  it yields the same failure. Building in play uses the structured tools (unchanged).
- **No new config knobs** unless live-verify shows a need (e.g. a relay timeout). Constants live in
  `Relay.luau`.
- **No change to edit / Server-view behavior** — the relay path is entirely gated on the client-play
  context.

## Architecture

### New modules
- **`src/Relay.luau`** — the whole relay (host + client + protocol), cohesive in one module:
  - Constants: `RELAY_RF_NAME = "StudioAgentRelay"`, `LOCAL_TOOLS` (the 6 plugin-only tool names),
    `WAIT_TIMEOUT` (find-the-RF seconds).
  - `Relay.mode(): "edit" | "serverplay" | "clientplay" | "other"` — from `RunService`. Check
    `IsEdit()` FIRST → `"edit"` (edit reports `IsServer=true AND IsClient=true`, so it must be
    distinguished before the play checks). Then `IsRunning() and IsStudio()` with
    `IsServer and not IsClient` → `"serverplay"`, `IsClient and not IsServer` → `"clientplay"`. The
    single source of truth for context.
  - `Relay.shouldRelayTool(name: string): boolean` — `not LOCAL_TOOLS[name]` (pure; spec-tested).
  - `Relay.startHost(deps)` — (server play copy) create the RF in `ReplicatedStorage`, set a
    **total (pcall-wrapped)** `OnServerInvoke(player, request)`:
    - `request.kind == "http"` → `return deps.anthropic:sendMessage(request.opts)` (the `Result`).
    - `request.kind == "tool"` → `local content, isError = Tools.dispatch(request.name, request.input,
      serverToolContext); return { content = content, isError = isError }`.
    - else → `{ error = "unknown relay request kind" }`.
    - `serverToolContext = { config = deps.config, anthropic = deps.anthropic }` (the server copy's
      own deps; dispatch_subagents/dispatch_writers read config/anthropic from here and run their
      children server-side). It carries NO `taskList`/`memory`/`skills` (those tools are LOCAL and
      never relay), matching how subagent children are already nil-guarded.
  - `Relay.newClient(): Client?` — (client play copy) `ReplicatedStorage:WaitForChild(RELAY_RF_NAME,
    WAIT_TIMEOUT)`. Returns `nil` if absent. The `Client` exposes:
    - `client:http(opts): Result` — `InvokeServer({kind="http", opts=opts})`, pcall-wrapped → on a
      thrown/absent-RF failure return `{ok=false, kind="context", message="relay unavailable — switch
      to the Server view"}`.
    - `client:tool(name, input): (Content, boolean)` — `InvokeServer({kind="tool", name, input})`,
      pcall-wrapped, unwrap `{content,isError}` → on failure return `("relay unavailable — switch to
      the Server view", true)`.
  - `Relay.wrapAnthropic(client, baseAnthropic)` — returns a table with `:sendMessage(opts) =
    client:http(opts)` (same interface `Retry`/`Compactor` expect; `baseAnthropic` kept only for a
    possible non-relay passthrough / ping).
- **`src/RelaySpec.luau`** — in-Studio self-test over the PURE/structural surface (mirrors the other
  Spec modules; no network): `shouldRelayTool` classification for every registered tool name (DM/HTTP/
  dispatch tools relay; the 6 plugin-only tools don't); the request-envelope shapes for http/tool;
  and the fallback `Result`/tool shapes when the client RF is nil. `Relay.mode()` is exercised only
  for its branch logic where a fake state can be injected (or documented as live-only).

### Touched modules
- **`src/init.server.luau`** — after building `deps`, branch on `Relay.mode()`:
  - `"serverplay"` → `Relay.startHost(deps)` (no panel work needed beyond today's; the server copy
    still mounts its own widget, but it's the relay host).
  - `"clientplay"` → `local client = Relay.newClient(); if client then deps.relay = client;
    deps.anthropic = Relay.wrapAnthropic(client, anthropic) end`. (If `client` is nil, leave deps as-is
    → the existing client-context error guides the user to the Server view.)
  - else → unchanged.
- **`src/AgentLoop.luau`** — accept an optional `relay` (thread it through `AgentLoop.send` →
  `runLoop` → `toolContext`). One branch at the dispatch site:
  ```lua
  local content, isError
  if relay ~= nil and Relay.shouldRelayTool(block.name) then
      content, isError = relay:tool(block.name, block.input)
  else
      content, isError = Tools.dispatch(block.name, block.input, toolContext)
  end
  ```
  The HTTP path needs NO change — `anthropic` is already the wrapped one when relaying (set in init).
  `Compactor.compact(anthropic, ...)` likewise uses the wrapped anthropic automatically.
- **`src/UI/Widget.luau`** — pass `deps.relay` as a new trailing arg to `deps.agentLoop.send(...)`
  (alongside the existing deps). No UI change; the panel is identical — it just works in client view.

### Data flow (client-view play)
```
user types in the CLIENT-copy panel → AgentLoop.send (client copy), anthropic = wrapped
  loop iteration:
    HTTP: Retry → wrappedAnthropic:sendMessage(opts)
        → relayRF:InvokeServer({kind="http", opts}) → [SERVER copy] anthropic:sendMessage → Result
    for each tool_use:
        shouldRelayTool? yes (e.g. create_instance) → relayRF:InvokeServer({kind="tool", name, input})
            → [SERVER copy] Tools.dispatch on the authoritative server DM → (content, isError)
        shouldRelayTool? no (e.g. update_tasks) → Tools.dispatch locally (mutates panel state)
  loop emits assistant_text / tool_result / tasks events LOCALLY → the client panel updates live
```

## Correctness rules / edge cases
- **Total host dispatcher:** `OnServerInvoke` is pcall-wrapped; a thrown handler returns a structured
  error rather than erroring the client's InvokeServer. The client `:http`/`:tool` are also
  pcall-wrapped (a dropped RF / mid-stop race → a clean fallback Result/is_error, never a loop crash).
- **RF lifecycle:** the server copy creates the RF on each play start (fresh play DM each time). The
  client copy `WaitForChild`s it (proven to replicate within ~1s). On Stop the play DM + RF are
  discarded (no leak — spike-verified). Cached references from before the play transition are invalid
  across the memory-isolated DMs (research) — the relay re-finds the RF per play; the host re-creates
  per play. Nothing is cached across the transition.
- **Empty tool input (`{}`):** sent as a Luau table over InvokeServer (preserved), and the SERVER's
  `Anthropic.encodeBody` applies the `{}` sentinel fix at the real JSON boundary. Do NOT pre-encode on
  the client.
- **pause_turn / server_tool_use:** unchanged. The HTTP relay returns the full `Result.data`
  (including any `server_tool_use` + `*_tool_result` blocks and `stop_reason="pause_turn"`); the
  client loop's existing echo+resume handling applies as-is.
- **dispatch_subagents / dispatch_writers under relay:** these relay as a single `tool` request; the
  SERVER copy runs the entire child fan-out (children's HTTP + structured writes are native there).
  `OnServerInvoke` may yield for the whole fan-out (RemoteFunction has no timeout) — acceptable.
- **Region guard / ChangeHistory:** writers still run server-side with their RegionGuard + per-call
  atomic recordings, exactly as today (just hosted in the server copy). Undo applies to the play
  session (discarded on stop regardless).
- **Compaction & rollback:** unchanged — they operate on the client copy's `conversation` and use the
  wrapped `anthropic` for the summarization HTTP. The leading-preamble delivery (proxy strips
  `system`) is unchanged: the preamble is built client-side and sent inside `opts.messages`, which the
  relay forwards verbatim.
- **Fallback parity:** if `Relay.newClient()` returns nil, the loop runs unwrapped and the existing
  `kind="context"` error ("switch to the Server view") fires — identical to today. The relay is purely
  additive.

## Risks to resolve in live-verify (research/spike could not)
- **Payload size over InvokeServer.** `opts.messages` (full history) and a `capture` image (base64,
  MBs) cross the in-process simulated network each time. Likely fine (memory, not a real socket), but
  verify a long/image-heavy turn doesn't hit a remote-argument limit. Mitigation if it does:
  JSON-encode `opts` to a string for transport and decode on the server BEFORE `sendMessage` (so the
  `{}` fix still runs server-side), and/or stream large tool_results via a different channel.
- **Latency/UX** of one InvokeServer per HTTP + per tool (should be sub-ms in-process; status events
  emit locally so the panel stays responsive).
- **Multiple play start/stop cycles** in one Studio session: confirm the host re-creates the RF and
  the client re-finds it each cycle (no stale handle).
- **Does the CLIENT-copy panel reliably mount + accept input in client view** (the existing
  DockWidget blanking/re-mount path) — confirm the panel is usable mid-playtest.

## Testing
- **Static:** `selene src` (0 errors), `stylua --check src`, `rojo build`.
- **`RelaySpec`** (in-Studio): `shouldRelayTool` classification across all tool names; request-envelope
  + fallback shapes; protocol round-trip shaping (pure).
- **Adversarial review (Workflow):** the relay/local tool split (any DM/HTTP tool wrongly run local,
  or any state tool wrongly relayed?); the host dispatcher totality + the client fallback (no path
  crashes the loop); the empty-object `{}` handling across the remote; pause_turn/server_tool_use
  pass-through; that the relay can NEVER exist outside a Studio play session (plugin-only + ephemeral);
  payload-size handling; RF lifecycle across stop/start.
- **Live-verify in Studio** (computer-use, fresh Baseplate, hecate tunnel up): enter Play, stay in the
  CLIENT view, and confirm the agent (a) answers a no-tool prompt (HTTP relay), (b) builds via
  `create_instance`/`set_property` and the parts appear in the running game, (c) `capture`s a
  screenshot, (d) runs a `dispatch_writers`/`dispatch_subagents` fan-out, all WITHOUT switching to the
  Server view; confirm `update_tasks`/`remember` still work (local); confirm Stop leaves no relay
  artifact in the edit DM; confirm the Server-view path still works (fallback parity).

## Rollout / ordering
1. `src/Relay.luau` (constants, `mode`, `shouldRelayTool`, `startHost`, `newClient`, `wrapAnthropic`)
   + `src/RelaySpec.luau`.
2. `src/AgentLoop.luau` — thread `relay`; add the dispatch branch.
3. `src/UI/Widget.luau` — pass `deps.relay` to `send`.
4. `src/init.server.luau` — per-copy wiring from `Relay.mode()`.
5. Build + lint + `RelaySpec`; adversarial-review Workflow; fix; rebuild; live-verify in Studio.
6. Update `HANDOFF.md` + memory.
