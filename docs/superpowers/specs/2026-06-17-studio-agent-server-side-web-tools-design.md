# Studio Agent — Server-Side Web Tools Design

- **Date:** 2026-06-17
- **Status:** Approved design (calls delegated to the implementer) — pending spec self-review, then
  implementation plan.
- **Relates to:** `HANDOFF.md`; the model-connection memory (`studio-agent-model-connection`). This
  lands BEFORE the SKILLS feature (it unblocks `research-a-topic` and upgrades the whole agent's web
  access).
- **Scope:** ONE feature — move the plugin's `web_fetch`/`web_search` from client-side HttpService
  egress to Anthropic's **server-side** web tools, removing the roblox.com block.

## Goal

Give the in-Studio agent **real, unrestricted web access** — including the Roblox documentation site
and dev forum — by switching `web_fetch`/`web_search` from the plugin's own `HttpService` (which Roblox
hard-blocks from `roblox.com` domains and forbids a `User-Agent` header on) to **Anthropic's
server-side web tools**, which execute on Anthropic's infrastructure and have no Roblox sandbox.

This was **empirically proven** (probe, 2026-06-17, against a local CLIProxyAPI v7.1.39 on the
subscription-OAuth path — the same image hecate runs):

- CLIProxyAPI **forwards** server-side tool definitions and returns the `server_tool_use` /
  `*_tool_result` blocks; the subscription path **supports** them (a bogus-tool 400 enumerated the
  supported set, which includes both web tools).
- `web_search_20250305` returned real `web_search_tool_result` blocks.
- `web_fetch_20250910` **successfully fetched `create.roblox.com`** — the exact domain the plugin's
  `HttpService` cannot reach — returning a `web_fetch_tool_result`.
- The newer **code-execution-backed `_20260209` "dynamic filtering" variants FAIL** with
  `code_execution_tool_result_error: "too_many_requests"` (code execution is quota-capped on this
  subscription account), so this feature uses the **direct** versions.

## Key decisions (settled by the probe + brainstorming; design calls delegated)

1. **Use the DIRECT server-tool versions:** `web_search_20250305` and `web_fetch_20250910` (declared as
   `{type, name}` entries with the `name`s kept as `web_search` / `web_fetch` for continuity). NOT the
   `_20260209` code-exec variants (they `too_many_requests` on the subscription).
2. **Server-side only — DELETE the client-side implementation.** Remove `Tools/Web.luau` (and its
   DDG-scrape / HTML-strip helpers) and `WebSpec.luau`. No config toggle, no fallback. (Accepted
   trade-off: if `baseUrl` is ever pointed at a proxy that does NOT support server tools, declaring
   them would 400 every request — but hecate AND the local proxy both support them, same image.)
3. **The plugin passes server-tool blocks through verbatim; it never dispatches them.** The agent loop
   already only collects `block.type == "tool_use"` for dispatch (`AgentLoop`/`Subagent`), and
   `server_tool_use` is a different type — so server tools are already ignored by the dispatch path,
   and the API-inserted `*_tool_result` blocks ride along in the assistant turn and are echoed back
   verbatim (the loop already does `messages << {role="assistant", content=data.content}`).
4. **`pause_turn` is the resume mechanism and is already handled.** If Anthropic's server-side loop
   pauses (hits its ~10-iteration cap mid-turn), the response is `stop_reason: "pause_turn"`; the loop
   already echoes the assistant turn and re-sends (without adding a user message), which resumes the
   server-side tools. No new resume logic needed.
5. **`isValidHistory` is already compatible.** `hasToolUse` matches only `type == "tool_use"`, so an
   assistant turn carrying `server_tool_use` + `*_tool_result` blocks does NOT trip the "tool_use must
   be followed by a tool_result user turn" rule, and strict alternation is unaffected (server tools
   live entirely inside one assistant turn).
6. **Subagents get server-side web too.** Read-only children include the server-tool entries in their
   `toolSchemas` (so `research-a-topic`'s `dispatch_subagents` fan-out searches the real web). Children
   already ignore `server_tool_use` (same `type=="tool_use"` collection), and the allowlist is moot for
   server tools (never dispatched) — inclusion is governed purely by what's in the child's tool schema.
7. **`max_uses` caps per turn** to bound quota/latency: declare `max_uses` on each server tool from
   Config (`webSearchMaxUses` / `webFetchMaxUses`, default 5 each). These REPLACE the now-removed
   client-side knobs `webSearchMaxResults` / `webFetchMaxChars`.

## Non-goals (YAGNI)

- No `serverSideWebTools` toggle / client-side fallback (decision 2 — replace and delete).
- No use of the code-execution-backed `_20260209` web tools, `code_execution`, `memory`, or
  `tool_search` server tools (out of scope; `_20260209` is quota-blocked anyway).
- No `allowed_domains` / `blocked_domains` filtering, no `user_location`, no citations wiring in v1
  (can be added later; the raw result text is enough).
- No re-plumbing of the Roblox-docs guidance beyond what's needed (the GitHub `creator-docs` mirror
  remains the recommended source for full doc *bodies* — see the JS-SPA caveat).

## Architecture

### The server-tool definitions

A small set of server-tool entries (just `{type, name}` — no `input_schema`, no `run` handler, since
Anthropic executes them):

```
web_search -> { type = "web_search_20250305", name = "web_search", max_uses = <config> }
web_fetch  -> { type = "web_fetch_20250910",  name = "web_fetch",  max_uses = <config> }
```

Held as a `SERVER_TOOLS` map (keyed by `name`) in `Tools/init.luau`, so both `schemas()` and
`schemasFor(names)` can emit them. `max_uses` is filled per request from Config.

### Touched modules

- **`src/Tools/init.luau`** —
  - Remove the `Web` require and its `descriptors` append loop.
  - Add the `SERVER_TOOLS` map. `Tools.schemas()` appends both server-tool entries after the custom
    registry tools; `Tools.schemasFor(names)` appends `SERVER_TOOLS[name]` for any requested name that
    is a server tool (so a subagent allowlisting `web_search`/`web_fetch` gets the server entries).
  - `max_uses` injected from `context.config` where schemas are built (see AgentLoop/Subagent below) —
    OR baked by a `Tools.schemas(config)` / `Tools.schemasFor(names, config)` signature that stamps
    `max_uses`. (Implementer's call; the simplest is to pass `config` into the schema builders.)
  - `Tools.dispatch` is unchanged — server tools never reach it (defensively, a stray `tool_use` named
    `web_search`/`web_fetch` would resolve to "unknown tool", which is fine: the model emits
    `server_tool_use`, not `tool_use`).
- **`src/AgentLoop.luau`** —
  - Build the tools list via `Tools.schemas(config)` so the server tools (with `max_uses`) are
    declared. No change to the dispatch loop (it already ignores `server_tool_use`).
  - **Minor UX:** in the content-block walk, add a branch for `block.type == "server_tool_use"` that
    emits a `status` (e.g. `"web_search: <query>"` / `"web_fetch: <url>"`) so the panel shows the agent
    is hitting the web. Optional but cheap; no effect on history.
- **`src/Subagent.luau` / `src/Tools/Subagents.luau`** — read-only children's `toolSchemas` include the
  server web tools (via `schemasFor`, stamped with `max_uses`). The `READ_ONLY` allowlist keeps
  `web_search`/`web_fetch` listed (harmless — gates nothing for server tools, but documents intent).
- **`src/SystemPrompt.luau`** — rewrite the **"# Web access and APIs"** section AND the matching lines
  in `SUBAGENT_BASE`:
  - Web tools now run on Anthropic's servers, so **there is no roblox.com block** — `web_fetch` CAN read
    `create.roblox.com` and `devforum.roblox.com`, and `web_search` searches the open web including
    Roblox sources.
  - **JS-SPA caveat:** a raw `web_fetch` of a `create.roblox.com/docs/...` page returns mostly page
    metadata (`og:`/meta), because the docs render their body via JavaScript. For full doc *bodies*,
    prefer the GitHub `creator-docs` raw mirror
    (`https://raw.githubusercontent.com/Roblox/creator-docs/main/content/en-us/...`) or the docs
    `llms.txt` index; `web_fetch` is excellent for the dev forum, MDN, GitHub, Stack Overflow, and
    general pages.
  - Drop the old "HttpService blocks roblox.com / don't set User-Agent" warnings (now irrelevant — the
    plugin no longer does the fetch).
  - Keep the tool-list one-liners for `web_fetch` / `web_search` (update the descriptions).
- **`src/Config.luau`** — remove `webFetchMaxChars` + `webSearchMaxResults` (and their getters +
  validation); add `webSearchMaxUses` (default 5) + `webFetchMaxUses` (default 5) with `>= 1` integer
  validation + getters.
- **Delete** `src/Tools/Web.luau` and `src/WebSpec.luau` (and remove any `WebSpec` reference from the
  in-Studio self-test runner, if one is wired).

### Data flow

```
model -> (declared tools include {type:"web_search_20250305", name:"web_search", max_uses:N})
       -> emits a `server_tool_use` block (name web_search, input {query})
       -> Anthropic EXECUTES the search server-side, inserts a `web_search_tool_result` block
          into the SAME assistant turn, and returns it (stop_reason end_turn, or pause_turn if it
          paused mid-loop)
   AgentLoop: walks content -> no `tool_use` blocks to dispatch -> echoes assistant content verbatim
              -> if pause_turn, re-send to resume; else terminal
              (server_tool_use block -> emit a "web_search: <query>" status; no history effect)

web_fetch is identical with a `web_fetch_tool_result` carrying the page content
   (create.roblox.com reachable — Anthropic's servers do the fetch, not Roblox HttpService)
```

## Correctness rules / edge cases

- **Verbatim echo is mandatory:** the assistant turn's `server_tool_use` + `*_tool_result` blocks MUST
  be echoed back unchanged on continuation (the loop already echoes `data.content` verbatim). The
  `web_search_tool_result` carries large `encrypted_content` — it rides in context and counts toward
  tokens; compaction (which operates on `conversation.messages`) handles long histories normally.
- **No local dispatch of server tools:** confirmed — `tool_use` collection matches only
  `type == "tool_use"`. If a future change ever broadened that, it would wrongly try to dispatch a
  server tool; keep the collection type-exact.
- **`pause_turn` resume:** already handled; do not add a user "continue" message (the API resumes from
  the trailing `server_tool_use`). Iteration-cap math is unaffected (a resume is one more iteration of
  the existing loop; `maxIterations` = 40 is ample).
- **Proxy dependency (accepted):** declaring an unsupported tool type 400s the whole request (proven by
  the control probe). hecate + the local proxy support these (same v7.1.39 image), so this is safe on
  the configured path; documented as the one risk of the no-fallback decision.
- **Sessions persistence:** server-tool result blocks are not images, so `MessageUtil.stripImages`
  leaves them; they save with the chat. Acceptable (text/data; `encrypted_content` is bounded by the
  result size). No special handling.
- **Playtest:** unlike the old client-side tools, server-side web tools do NOT use `HttpService`, so
  they are NOT subject to the "HttpService is server-only" playtest limit — but the model connection
  itself still is (the request to Anthropic goes over HttpService), so web access works wherever the
  agent can talk to Claude (edit / Server view), same as today.

## System prompt addition (summary)

Rewrite "# Web access and APIs": you have `web_fetch(url)` and `web_search(query)`, run on Anthropic's
servers (NOT your HttpService) — so they reach the whole web INCLUDING `roblox.com`: `web_fetch` can
read `create.roblox.com` docs and `devforum.roblox.com` threads, and `web_search` searches the open
web. Caveat: the Roblox docs site renders its body via JavaScript, so a raw `web_fetch` of a
`create.roblox.com/docs/...` page returns mostly metadata — for full doc bodies prefer the GitHub
`creator-docs` raw mirror or the docs `llms.txt` index; `web_fetch` is great for the dev forum, MDN,
GitHub, Stack Overflow, and general pages. Prefer reading the official docs over guessing an API. Mirror
the same update (minus the authoring nuance) in the read-only `SUBAGENT_BASE`.

## Testing

- **Static:** `selene src` (0 errors; the 1 known `CreateDockWidgetPluginGui` warning),
  `stylua --check src`, `rojo build` — and confirm no dangling references to the deleted
  `Tools/Web`/`WebSpec` modules or removed Config keys.
- **No new Spec module** — this feature deletes pure helpers (the DDG/HTML logic) rather than adding
  any; behavior is server-side and not unit-testable in-Studio. (Remove `WebSpec`.)
- **Adversarial review** (Workflow, like prior features) over the diff: focus on the tools-array
  assembly (server entries present + `max_uses` stamped, no client `web_*` left, no name collisions),
  the AgentLoop pass-through invariant (server_tool_use never dispatched; verbatim echo; pause_turn
  resume), `isValidHistory` against server-tool turns, the subagent schema wiring, and the Config
  add/remove.
- **Live-verify in Studio** (computer-use, NEW Baseplate, on the hecate tunnel — reconfirm the
  production path): the agent `web_search`es a current-info query and cites a result; `web_fetch`es a
  `create.roblox.com/docs/...` page (gets at least the metadata) AND the GitHub mirror of the same doc
  (gets the full body); `web_fetch`es a `devforum.roblox.com` thread (proves the old block is gone); a
  `dispatch_subagents` research fan-out uses web search inside the children. Confirm the panel shows the
  `web_search: …` / `web_fetch: …` status line.

## Rollout / ordering

1. `Config.luau` — swap the web knobs (`webSearchMaxUses`/`webFetchMaxUses` in, old two out).
2. `Tools/init.luau` — drop `Web`; add `SERVER_TOOLS`; thread `max_uses` into `schemas`/`schemasFor`.
3. Delete `Tools/Web.luau` + `WebSpec.luau`; remove any self-test wiring.
4. `AgentLoop.luau` — declare server tools (with config); add the `server_tool_use` status emit.
5. `Subagent`/`Tools/Subagents` — server web tools in children's schemas.
6. `SystemPrompt.luau` — rewrite the web section + the subagent lines.
7. Build + lint (confirm no dangling refs), adversarial-review Workflow, fix, rebuild, hand off for
   live-verify on the hecate tunnel.
8. THEN return to the SKILLS plan, with `research-a-topic` written against this real web access.
