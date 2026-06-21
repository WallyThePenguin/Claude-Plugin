# Studio Agent — Dev Bridge (design)

**Date:** 2026-06-21
**Status:** design approved in brainstorm; no code yet.
**Serves:** developer velocity — let **Claude Code (the shell)** drive the in-Studio plugin headlessly
(execute tools / Luau, read Output, pull captures) instead of pixel-driving the panel via computer-use.
Unblocks fast, deterministic live-testing of every slice (B–E and beyond). First dogfood: finish slice B's
pole-sign check.
**Builds on:** the existing **localhost sidecar** (`sidecar/server.py`, 127.0.0.1:8389, pure-stdlib HTTP —
already serves `GET /captures` and the plugin already GETs it via `HttpService`), `Tools.dispatch`
(`src/Tools/init.luau`), `AgentLoop.send` (`src/AgentLoop.luau`), and `Logs` (`src/Logs.luau`).
**Memories:** `studio-agent-status`, `studio-agent-model-connection` (the sidecar/transport facts).

## Why (and what this is NOT)

Two distinct things the plugin does: **(1) execute code inside Studio** at PluginSecurity (touch the
DataModel — `spawn_rig`, `ik_reach`, `run_luau`, `capture`…), which is **irreducible** (only in-Studio code
can do it); and **(2) the in-Studio Claude "brain"** (`AgentLoop` → the proxy → Claude) that reads a human's
prompt and decides which tools to call. **#2 is the product** — a human Roblox dev chats with Claude in
Studio to build their game. This bridge is **dev scaffolding for Claude Code**, not a replacement for the
product: for my own dev loop I already have a brain (me), so I mostly want **#1** — a way to execute exact
tool calls / Luau in Studio and read results — bypassing the in-Studio LLM (deterministic, fast, cheap). A
**thin prompt mode** is also kept, purely to test **the product's own reasoning** headlessly (e.g. after a
`SystemPrompt` change, confirm the agent still picks the right tools).

## The transport (settled)

The plugin's only outward channel is `HttpService` → the **sidecar** (already running, localhost,
plugin-trusted). The plugin **polls outbound** (no inbound server in the plugin); the sidecar is the only
listener and is bound to `127.0.0.1`. I drive everything by curling the sidecar from the shell.

```
me (shell) ──POST /agent {kind,…}──▶ sidecar 127.0.0.1:8389  ◀──GET /agent/pending── plugin poll loop (EDIT only)
me (shell) ◀──GET /agent/result?id── sidecar                 ──POST /agent/result──▶ (after execution)
me (shell) ◀──GET /logs──────────── sidecar  ◀──POST /logs (each tick)── plugin
me (shell) ◀──GET /captures──────── sidecar (existing; viewport PNGs on disk)
```

## Modes

1. **Tool RPC (primary):** `{kind:"tool", tool:"ik_reach", input:{…}}` → plugin runs
   `Tools.dispatch(tool, input, ctx)` → returns `{ok, result, logs}`. I supply the args; I'm the brain.
2. **Luau RPC (primary):** `{kind:"luau", code:"…"}` → mapped to the `run_luau` tool (loadstring at
   PluginSecurity, ChangeHistory in edit) → returns serialized returns + print/warn. The universal escape
   hatch — anything Studio can do.
3. **Prompt (thin):** `{kind:"prompt", prompt:"…"}` → `AgentLoop.send` on the **shared `deps.conversation`**
   (the panel chat — you watch it live) → returns `{ok, reply, tools:[{name,isError,text}], error}`.

## Components

| Unit | Responsibility |
|---|---|
| `sidecar/server.py` (extend) | Add an in-memory store: a 1-slot `pending` command, a `results` map (by id), `latest_logs`, an id counter. New routes: `POST /agent`→`{id}`, `GET /agent/pending` (returns + clears the slot), `POST /agent/result`, `GET /agent/result?id`, `POST /logs`, `GET /logs`. Keep `GET /captures`. Still pure-stdlib, 127.0.0.1-only, no auth (same trust as today). |
| `src/DevBridge.luau` (new) | The EDIT-only poll loop. Each tick (~1.5s, pcall-wrapped): `POST /logs {lines = Logs.recent(80)}`; `GET /agent/pending` → dispatch by kind. **tool/luau** = synchronous `Tools.dispatch` (luau → `run_luau`) → `POST /agent/result` immediately. **prompt** = `AgentLoop.send` with a capturing callback (accumulate `assistant_text`→reply, `tool_use`/`tool_result`→tools, `error`→error), wait for `done`/`error`, then POST. Builds the same `toolContext` from `deps` that `AgentLoop` does. |
| `src/Config.luau` (extend) | `devBridge` (default **true** — zero manual steps; safe because edit-only + localhost) and `devBridgePollInterval` (1.5s). Getters `getDevBridge()` / `getDevBridgePollInterval()`. |
| `src/init.server.luau` (wire) | After `deps`, call `DevBridge.start(deps)` **only if `RunService:IsEdit()`** and `config:getDevBridge()`. Pass `deps.conversation` (shared) for prompt mode. No-op in play/published. |
| `scripts/studio-agent.ps1` (new) | CLI: `tool <name> <json>`, `luau "<code>"`, `prompt "<text>"`, `logs`, `capture`. Each POSTs then polls `GET /agent/result?id` to completion (tool/luau timeout ~30s; prompt ~180s) and prints. `capture` GETs the newest `/captures` PNG and saves it to a temp file so Claude Code can Read it. |

## Output contract

- **tool/luau** → `{ id, ok:boolean, result:string, logs:[{kind,text}] }` (capture's image blocks serialize to
  `"[viewport captured — GET /captures]"`; I fetch the PNG separately). On throw/error → `{id, ok:false, error}`.
- **prompt** → `{ id, ok:boolean, reply:string, tools:[{name,isError,text}], error? }`.

## Data flow (finishing slice B with it)

```
studio-agent.ps1 tool spawn_rig '{"type":"r15"}'          -> ok, "spawned AgentRig_R15 at …"
studio-agent.ps1 tool ik_reach  '{"chain":"RightArm","target":{"x":1.5,"y":3.5,"z":2}}'
                                                          -> ok, "ik_reach: posed RightHand [RightShoulder, RightElbow] -> (…); residual 0.12 studs"
studio-agent.ps1 tool camera_focus '{"target":"Workspace.AgentRig_R15"}'   (auto-captures)
studio-agent.ps1 capture                                  -> saves newest PNG; Claude Code Reads it, confirms the elbow bend / pole sign
```
One round-trip each, deterministic, no clicking, no second LLM.

## Error handling (total — never break the loop)

- Sidecar down → the plugin's `HttpService` calls are pcall-wrapped; the tick no-ops, the plugin keeps
  running. The CLI surfaces a connection error and says to start the sidecar.
- Tool/Luau error → `Tools.dispatch` already returns `(errorString, true)`; posted as `{ok:false}` with the
  message. A thrown handler → caught, posted as `{ok:false, error}`.
- Loop busy (the panel or a prior bridge prompt is mid-run, prompt mode only) → `AgentLoop.send` emits a
  `busy` error → posted as `{ok:false, error:"agent already running"}`; I retry.
- A malformed pending command (missing fields) → posted as `{ok:false, error:"bad command"}`; never throws.
- The poll loop body is pcall-wrapped so any single bad tick is swallowed and the loop continues.

## Security

Edit-only (`DevBridge.start` returns immediately unless `RunService:IsEdit()` — never runs in a playtest or
a published game, and it's plugin code so it can't exist in a shipped game anyway). Localhost-only (the
sidecar binds `127.0.0.1`, identical trust boundary to today's capture serving). The RPC can run arbitrary
`run_luau` in Studio — intentional and powerful, but same-machine + loopback + edit-only + a `devBridge`
Config flag to disable. No auth (a loopback dev tool serving your own Studio).

## Testing

- `DevBridgeSpec` (in-Studio, pure helpers): the content→string serialization (string passthrough; blocks
  array → the capture note) and the prompt-mode event accumulation (events → `{reply, tools, error}`).
- Sidecar routes: curl-testable directly (POST a command, GET the result).
- `selene`/`stylua`/`rojo build` static gate.
- **Dogfood (the real end-to-end test):** Claude Code drives `studio-agent.ps1 tool …` to finish slice B's
  live grab-and-place + pole-sign check — the bridge proves itself by doing the job it was built for.

## Scope

- **In:** the sidecar endpoints, `DevBridge.luau` (tool/luau/prompt), the Config flag, init wiring, the CLI
  wrapper, a spec.
- **Out (v1, explicit non-goals):** auth / multi-client; a fresh-capture trigger without going through the
  `capture` tool (I drive `capture`/`camera_focus`); long-poll (short-poll is fine on loopback); driving
  during a playtest (edit-only — playtest would need the relay, a later add); a queue deeper than one pending
  command (single-flight matches the agent loop); streaming partial output (poll-to-completion).
