# Studio Agent Plugin + Local CLIProxyAPI — Design Spec

**Date:** 2026-06-16
**Status:** Approved (design); ready for implementation planning

## 1. Goal

Build a Roblox Studio **plugin that hosts a Claude agent loop** (per the Build
Schematic in `CLAUDE.md`), but connect to Claude **exclusively through a local
[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) instance** that
authenticates with the user's **Claude subscription via OAuth** — not a
pay-per-token Anthropic API key.

The result: the user drives a Claude agent inside Studio that builds/edits the
DataModel, and the model calls are billed against their Claude subscription
through a proxy running on this machine.

## 2. Why this shape (decided, do not re-litigate)

- **Plugin-hosted agent loop**, tool calls executed in-process at PluginSecurity
  — unchanged from the Build Schematic. One Anthropic round-trip per *reasoning*
  step, not per tool.
- **CLIProxyAPI as the model endpoint.** It re-exposes a subscription OAuth
  credential as an **Anthropic-compatible** `/v1/messages` endpoint. The plugin's
  existing Anthropic Messages request/response shape works unchanged — no format
  translation.
- **Local proxy on this machine, no SSH tunnel.** Chosen over reusing hecate's
  remote proxy or a remote dedicated proxy. Simplest runtime: no tunnel, no
  remote dependency. The user does their own `--claude-login` locally.
- **Anthropic-native wire protocol, not OpenAI-compat.** hecate documented that
  CLIProxyAPI's OpenAI-compat path 400s on tool-calls-with-reasoning; the native
  `anthropic_messages` path is required for reliable tool use.
- **No streaming.** `HttpService:RequestAsync` returns the full body only.

### Reference: how hecate does it (validated by inspection 2026-06-16)

hecate's `llm-proxy` service runs CLIProxyAPI with a deliberately minimal config:
- `port: 8317`, `host: ""` (all interfaces inside the container)
- `auth-dir` points at a named volume holding the subscription OAuth token,
  written by an interactive `--claude-login` (no API keys in the config file)
- `api-keys: ["<inbound key>"]` — a low-value Bearer key callers must present;
  this is **not** the subscription token
- control panel disabled, logs to stdout
- Hermes calls it via the **native Anthropic Messages transport**, model
  `claude-opus-4-8`, `max_tokens` kept at **8192**.

Key gotcha hecate documented and we inherit: **the subscription rolling window
reserves the full `max_tokens` as potential output**, so large values (e.g.
64000) return `400 "You're out of extra usage..."` once the window is partly
spent. Keep `max_tokens` modest (8192 default).

## 3. Architecture

```
          ┌──────────────────────────────────────────────────────┐
          │              ROBLOX STUDIO (edit mode)                │
          │   ┌────────────────────────────────────────────────┐ │
          │   │           Studio Agent Plugin (Luau)            │ │
          │   │   UI Widget ─► Agent Loop ─► Tool Dispatcher    │ │
          │   │                  │               │              │ │
          │   │                  │               ▼ (PluginSecurity, │
          │   │                  │          run_luau / structured   │
          │   │                  │          tools, ChangeHistory)   │
          │   │      Serialize/Decode                            │ │
          │   └──────────────────┼───────────────────────────────┘ │
          │                      │ HttpService:RequestAsync         │
          └──────────────────────┼───────────────────────────────────┘
                                 │ HTTP (non-streaming)
                                 ▼
                  ┌───────────────────────────────────┐
                  │  Local CLIProxyAPI  127.0.0.1:8317 │
                  │  Anthropic-compat /v1/messages     │
                  │  Bearer inbound key gate           │
                  └───────────────┬───────────────────┘
                                  │ HTTPS, subscription OAuth
                                  ▼
                       ┌────────────────────────┐
                       │  Anthropic (Claude)     │
                       │  /v1/messages           │
                       └────────────────────────┘
```

Only one new component versus the Build Schematic: the **local CLIProxyAPI**
replaces the direct `plugin → api.anthropic.com` hop. The optional screenshot
sidecar (vision) is unchanged and still deferred (M10).

## 4. Components

### 4.1 Local CLIProxyAPI — `proxy/` (new)

Run on this machine via **Docker Desktop** (installed; Go is not, so we do not
build from source). Mirrors hecate's minimal posture.

Files:
- `proxy/config.yaml` — `port: 8317`, `auth-dir: /data/cli-proxy-api`,
  `api-keys: ["<INBOUND_KEY>"]` (rendered from env or written directly for a
  local-only instance), `remote-management.disable-control-panel: true`,
  `logging-to-file: false`.
- `proxy/docker-compose.yml` (or a `run.ps1`) — runs the upstream CLIProxyAPI
  image, publishes `127.0.0.1:8317:8317`, mounts a named volume for `auth-dir`.
- `proxy/README.md` — setup + verification steps.

Setup (one time):
1. Generate a random hex **inbound key** (no `|`). PowerShell:
   `-join ((1..48) | % { '{0:x}' -f (Get-Random -Max 16) })`. Put it in
   `config.yaml` / env.
2. Bring the container up once so the auth volume exists.
3. Run the interactive subscription login:
   `CLIProxyAPI -config <config> -claude-login` (callback on `localhost` — works
   directly since the browser is on this machine). Approve the Anthropic OAuth
   URL; the token persists in the volume.
4. Restart/serve: proxy listens on `127.0.0.1:8317`.

Verification (gates the rest of the build):
- `curl 127.0.0.1:8317/v1/models` → 401 without the key, model list with
  `Authorization: Bearer <key>`.
- A one-shot `POST /v1/messages` with a trivial prompt returns an assistant
  message.

### 4.2 Agent Plugin (Luau) — modules

Same module layout as the Build Schematic §8, with Config + the HTTP client
adjusted for the proxy connection:

- **Config** — persists via `plugin:SetSetting`/`GetSetting`:
  - `baseUrl` (default `http://127.0.0.1:8317`)
  - `proxyKey` (the Bearer inbound key; never in source)
  - `model` (default `claude-sonnet-4-6`; `claude-opus-4-8` selectable; **never
    Haiku** per hecate model policy for agent reasoning)
  - `maxTokens` (default `8192`)
  - `maxIterations` (loop cap)
- **Anthropic** (HTTP client + agent loop; kept provider-agnostic internally):
  - `POST {baseUrl}/v1/messages`
  - Headers: `Authorization: Bearer {proxyKey}`, `anthropic-version: 2023-06-01`,
    `content-type: application/json`
  - Body: `model`, `max_tokens`, `system`, `tools`, `messages` (unchanged from
    the standard Messages API)
  - Non-streaming; runs under `task.spawn`; iteration cap enforced.
- **Serialize / Decode / Session / SystemPrompt / Tools/ / UI/Widget** — exactly
  as the Build Schematic. No change driven by the proxy.

Because the client is just *base URL + auth header*, repointing at the remote
hecate tunnel or `api.anthropic.com` later is a settings change, not a rewrite.
The UI exposes only the cliproxyapi (local) connection.

## 5. Connection contract (exact)

```
POST http://127.0.0.1:8317/v1/messages
Authorization: Bearer <proxyKey>
anthropic-version: 2023-06-01
content-type: application/json

{ "model": "claude-sonnet-4-6", "max_tokens": 8192,
  "system": "...", "tools": [...], "messages": [...] }
```

Tool loop is the standard Anthropic loop: assistant returns `tool_use` blocks
with `stop_reason: "tool_use"`; reply with a user message of `tool_result`
blocks keyed by `tool_use_id`; repeat until a non-`tool_use` stop reason.

## 6. Milestones (revised from Build Schematic §9)

One task per implementation prompt; verify each before moving on.

- **M-pre (new):** Stand up the local CLIProxyAPI (`proxy/`). *Verify:* subscription
  login done; `/v1/models` returns models with the Bearer key; a one-shot
  `/v1/messages` answers. **Gates everything below.**
- **M0:** Rojo skeleton + `init.server.luau` that creates a toolbar button.
  *Verify:* button appears in Studio (build `.rbxm`, copy to the Plugins folder).
- **M1:** Config + **connection settings entry** (base URL, proxy key, model
  picker) via `SetSetting`/`GetSetting`. *Verify:* settings persist across Studio
  restarts.
- **M2:** Anthropic HTTP client; a "ping" (single message, no tools) **through the
  local proxy**, printed to Output. *Verify:* round-trip reply prints.
- **M3:** Serialize (Luau → JSON-safe). *Verify:* Instance/Vector3/CFrame/Color3/
  table encode correctly.
- **M4:** Decode (JSON → typed Luau). *Verify:* round-trips with Serialize.
- **M5:** Session env + `run_luau` (print capture, ChangeHistory wrap). *Verify:*
  exec creates a Part; Ctrl+Z undoes it; a session var persists to the next call.
- **M6:** Agent loop (tool_use dispatch + tool_result + iteration cap), tools =
  `[run_luau]`. *Verify:* "create a red part at 0,5,0" works end to end.
- **M7:** Structured tools: `get_tree`, `get_properties`, `set_property`,
  `search`. *Verify:* each individually.
- **M8:** SystemPrompt + full tool schemas registered. *Verify:* Claude picks
  structured tools for reads, `run_luau` otherwise.
- **M9:** UI Widget: task input, transcript, status, start/stop, iteration
  counter. *Verify:* full loop usable from the panel.
- **M10 (optional, deferred):** Screenshot sidecar + `capture` tool + camera
  framing; forward image blocks. *Verify:* Claude captures, "sees", verifies.
- **M11 (hardening):** Structured error feedback; **detect the subscription-window
  `400 "out of extra usage"` signal** → clear status + backoff/retry;
  destructive-op confirm; retry/backoff. *Verify:* a deliberately bad `run_luau`
  returns an error Claude recovers from; a forced 400 surfaces a clear message
  and backs off.

## 7. Constraints & gotchas

- **HTTP requests:** enable "Allow HTTP Requests" (Game Settings → Security).
  Localhost HTTP (`http://127.0.0.1:8317`) is permitted by Studio's HttpService.
- **`max_tokens` discipline:** keep at 8192 by default; bump to 16384 only for a
  deliberately long single output. Large values 400 on the subscription window.
- **`loadstring`:** a locally installed (unpublished) plugin can use it; the
  Build Schematic's FiOne/vLua fallback plan still applies for `run_luau`.
- **Key safety:** the proxy inbound key is stored via `plugin:SetSetting`, never
  in source, never published with the plugin. The subscription OAuth token lives
  only in the proxy's auth volume on this machine.
- **Blocking:** run the agent loop under `task.spawn`; cap iterations.
- **Proxy must be running** before the plugin can talk to Claude; the README
  documents starting it.

## 8. Out of scope (YAGNI)

- OpenAI-compatible endpoint path (Anthropic-native avoids tool-call 400s).
- Multi-provider selection UI (single local cliproxyapi connection).
- SSH-tunnel automation / remote proxy reuse (local proxy makes it moot; the
  client remains base-URL configurable if revisited).
- Vision/screenshots beyond the existing optional M10 sidecar.

## 9. References

- Build Schematic: project `CLAUDE.md` (architecture, tool schemas, serializer
  mapping, module layout).
- CLIProxyAPI: https://github.com/router-for-me/CLIProxyAPI
- hecate `llm-proxy` (inspected 2026-06-16): `~/Desktop/Project_Hecate/llm-proxy/`
  on the remote `devel@100.119.185.111` — config.template.yaml, README.md,
  `.env.example` "Hermes model endpoint via CLIProxyAPI" section.
- Anthropic Messages API: `POST /v1/messages`, `anthropic-version: 2023-06-01`,
  required `max_tokens`, tool_use/tool_result loop.
- Roblox agent docs: https://create.roblox.com/docs/llms.txt (append `.md` to any
  API page).
