<!-- Generated 2026-06-16 by the studio-agent-impl-plan ultracode workflow (19 Opus agents). -->
<!-- Source spec: docs/superpowers/specs/2026-06-16-studio-agent-cliproxyapi-design.md -->

# Studio Agent Plugin + Local CLIProxyAPI — Implementation Plan

## Cross-cutting decisions (module conventions, error handling, the exact connection contract, build/install loop)

### Repository layout (authoritative)

```
C:\Users\manso\Desktop\Claude-Plugin\
  rokit.toml                 # toolchain pins (repo root — all tool commands run here)
  selene.toml                # std = "roblox"
  stylua.toml                # tabs, width 100, AutoPreferDouble
  default.project.json       # Rojo project (repo root)
  build.ps1                  # build + install loop
  .gitignore                 # already covers *.rbxm, /sourcemap.json, proxy/auth/, proxy/data/, *.key, .env
  src/                       # all plugin Luau source (NO studio-agent/ subdirectory — see decision below)
    init.server.luau
    Config.luau
    Anthropic.luau
    Serialize.luau
    Decode.luau
    Session.luau
    SystemPrompt.luau
    Errors.luau              # M11
    Retry.luau               # M11
    Tools/
      init.luau
      RunLuau.luau
      Tree.luau
      Properties.luau
      Path.luau
      PropertyCatalog.luau
      Capture.luau           # M10, optional
    UI/
      Widget.luau
    Vendor/
      FiOne.luau             # vendored pure-Luau interpreter fallback for run_luau
  proxy/                     # M-pre infra (no Luau)
    config.example.yaml      # committed template (placeholder key)
    config.yaml              # gitignored (live key injected here)
    docker-compose.yml
    gen-key.ps1
    login.ps1
    verify.ps1
    README.md
```

**DECISION — drop the `studio-agent/` nesting.** The m1m2/m3m4/m5/m6/m7/m8m9/m11 clusters used a `studio-agent/src/...` prefix, but m0 placed everything at repo root and the reviewers verified builds against repo-root `default.project.json`. Use **repo root** as the single project root (`src/`, `default.project.json`, `rokit.toml` all at `C:\Users\manso\Desktop\Claude-Plugin\`). This keeps the rokit shim resolution simple (all tool commands run from the cwd whose `rokit.toml` lists the tools) and matches the `.gitignore` already present. Every `studio-agent/src/X` path below collapses to `src/X`.

### Rojo project file (the single most load-bearing artifact — verified by two reviewers)

`default.project.json` MUST be exactly:

```json
{ "name": "StudioAgent", "tree": { "$path": "src" } }
```

**Do NOT set `$className`.** Both reviewers empirically reproduced (rojo 7.5.1 AND 7.6.1) that `{ "$className": "Script", "$path": "src" }` and `{ "$className": "Folder", "$path": "src" }` both FAIL with: `ClassName for Instance "StudioAgent" was specified in both the project file ... and from the filesystem (as "Script"). If $className and $path are both set, $path must refer to a Folder.` Because `src/init.server.luau` makes Rojo infer the root as a `Script`, any explicit `$className` is a conflict. With `$path` only, the built `.rbxm` root is a single `Script` named `StudioAgent` (RunContext = Legacy/token 0) carrying `init.server.luau`'s source, with child ModuleScripts (`Config`, `Anthropic`, `Tools` Folder → `RunLuau`/`Tree`/`Properties`/..., `UI` Folder → `Widget`, etc.). Studio runs that root Script as the plugin main when the `.rbxm` is dropped in the Plugins folder.

### Require paths (built tree shape)

- Root Script = `StudioAgent` (init.server.luau). `script` inside it refers to that Script.
- `require(script.Config)`, `require(script.Anthropic)`, `require(script.Serialize)`, `require(script.Decode)`, `require(script.Session)`, `require(script.SystemPrompt)`, `require(script.Errors)`, `require(script.Retry)`.
- `require(script.UI.Widget)` (UI is a Folder).
- `require(script.Tools)` (Tools/init.luau is the Tools ModuleScript). Inside Tools: `require(script.RunLuau)`, `require(script.Tree)`, `require(script.Properties)`, `require(script.Path)`, `require(script.PropertyCatalog)`.
- From a tool module up to a sibling top-level module: `require(script.Parent.Parent.Serialize)` (Tool → Tools(self) → StudioAgent root → Serialize). Confirm this depth on first build.

### Toolchain pins (`rokit.toml`)

```toml
[tools]
rojo = "rojo-rbx/rojo@7.6.1"
selene = "Kampfkarren/selene@0.28.0"
stylua = "JohnnyMorganz/StyLua@2.1.0"
```

Use concrete semver (the `@7.x` wildcard notation does NOT resolve in rokit). Run `rokit install` (and `rokit trust` if prompted) from the repo root. The `~/.rokit/bin/*.exe` binaries are shims that exit 1 with "Failed to find tool ... in any project manifest" until a `rokit.toml` listing the tool exists in the cwd. Verify with `rojo --version` → `Rojo 7.6.1` **from the repo root**.

### Lint/format conventions

- `selene.toml`: `std = "roblox"`. Confirmed to resolve the bundled Roblox std offline (no `selene generate-roblox-std` network step needed) and to recognize the implicit `plugin` global with 0 warnings. **Selene exits 1 on WARNINGS, not just errors** — judge lint success by the "0 errors" line in output, never by process exit code. `build.ps1`'s `if ($?)` gate must guard ONLY the rojo build step, never lint.
- `stylua.toml`: `column_width = 100`, `indent_type = "Tabs"`, `quote_style = "AutoPreferDouble"`. `stylua --check src` exits 1 on diff (formatting needed), which is expected during development.

### The exact connection contract (every HTTP call to the proxy)

```
POST http://127.0.0.1:8317/v1/messages
Headers:
  Authorization: Bearer <proxyKey>      # NOT x-api-key — CLIProxyAPI inbound key uses Bearer
  anthropic-version: 2023-06-01
  content-type: application/json          # lowercase is valid; Roblox does NOT auto-set it
Body (JSON string, encoded exactly once):
  { model, max_tokens, system, tools, messages }   # omit system/tools when nil
Response: full body only (non-streaming). HttpService:RequestAsync.
  requestOptions.Timeout = 90 (seconds)   # bound the call so a hung proxy fails into Retry
```

- **model**: default `claude-opus-4-8`; `claude-sonnet-4-6` selectable; never Haiku.
- **max_tokens**: default **8192**. The subscription rolling window RESERVES `max_tokens` as potential output; large values 400 with an "out of extra usage" message (opus is heavier on the window than sonnet). Config clamps to ≤16384, defaults 8192. The ping smoke test uses 256.
- Send **no** `thinking`, `temperature`, `top_p`, `top_k`, or `budget_tokens` fields. Opus 4.8 runs with thinking OFF by default when the field is absent (the correct, non-400 path) and rejects temperature/top_p/budget_tokens with 400. The contract body is exactly `{model, max_tokens, system, tools, messages}` and nothing else.
- Do **not** set `tool_choice` (defaults to `auto`) — the model must freely choose structured tools vs run_luau.

### HttpService:RequestAsync error model (bimodal — verified against create.roblox.com)

This is the single most common source of bugs and is handled uniformly via `Errors.luau` (M11):
1. **Network failure / timeout / "Http requests are not enabled" → RAISES a Lua error.** Must be `pcall`-wrapped. The disabled-HTTP throw matches the string `Http requests are not enabled` (or `not enabled`) and is classified distinctly from a true network error so the UI shows "Enable Allow HTTP Requests in Game Settings > Security".
2. **Non-2xx (400/401/429/500/…) → returns `Success=false`, does NOT raise.** Inspect `res.Success`/`res.StatusCode`; parse `res.Body` as the Anthropic error envelope `{type:"error", error:{type, message}}`.
3. `JSONDecode` THROWS on non-JSON bodies (e.g. an HTML 502 from a gateway). **Every** error-body decode is `pcall`-wrapped with a raw-`res.Body` fallback. `JSONEncode` SILENTLY emits invalid JSON for nan/inf (it does NOT throw) — so the serializer MUST guarantee finite-only output; the only backstop is decode-side, never encode-side.

### Error taxonomy & retry (defined once in M11, referenced everywhere)

`Errors.Kind = { Transport, Timeout, HttpDisabled, HttpStatus, AnthropicError, UsageWindow, AuthError, BadRequest, ToolError, Decode }`. The subscription-window signal is detected by **case-insensitive message substring** (`{"out of extra usage", "extra usage", "rolling window"}`) matched against BOTH the decoded `error.message` AND (on decode failure) the raw lowercased body, BEFORE status-code mapping — because a plain 400 (bad schema) is permanent while the window-400 is transient. Status→retryable: 429/500/502/503/504/529 and thrown network/timeout errors → retryable; 400(non-usage)/401/403/404/413 → not retryable; **402 billing_error → not retryable** (surface "check subscription billing"); 502/503/504 labeled as gateway/proxy transient (distinct from Anthropic-native 500/504/529). **UsageWindow gets its own LOW retry cap (1 attempt) distinct from the generic transient cap (4)** — retrying it re-reserves `max_tokens` and worsens exhaustion; prefer surfacing "lower max_tokens / wait."

### Tool dispatch invariants (load-bearing for the Anthropic loop)

- Echo assistant `content` back **verbatim** — tool_use blocks must round-trip unchanged or the follow-up 400s ("tool_use ids without tool_result").
- For a turn with N tool_use blocks, dispatch ALL of them (an error/decline still yields a tool_result for THAT block, never aborts siblings) and reply with a **single** user message whose `content` lists every `tool_result` FIRST (ordered), each keyed by its `tool_use_id`, with `is_error` set on failures.
- `Tools.dispatch` ALWAYS returns `(content: string, isError: boolean)`. It wraps BOTH the tool `run` AND the `JSONEncode` of the result in one pcall — a serialization failure falls back to a safe textual rendering with `is_error=true`, so a tool_use is never orphaned.
- Loop terminates on **any `stop_reason ~= "tool_use"`** (never `== "end_turn"`). Branch: `tool_use`→continue; `end_turn`/`stop_sequence`→done; `max_tokens`→done **with a truncation warning** surfaced to the UI; `pause_turn`→resume by sending the assistant turn back unchanged; `refusal`→distinct error event. Pass `stop_reason` to `onDone` so the caller distinguishes clean end from truncation/refusal.
- On terminal loop-level (transport/usage) failure, surface the message and break; do NOT inject it as a tool_result. Message history must NOT be left with a trailing unanswered tool_use turn (discard the in-flight assistant turn or scope history per-run).
- The single-flight guard and the in-flight assistant turn are reset in an exception-safe wrapper: `task.spawn(function() running=true; local ok,err=pcall(runLoop,...); running=false; if not ok then onError(err) end end)`.

### Secret hygiene (cross-cutting)

- `proxyKey` lives ONLY in `plugin:SetSetting` (per-plugin `.json`) and in `proxy/config.yaml` (gitignored). Never in source, never in the committed `.rbxm`.
- Add `proxy/config.yaml` to `.gitignore` BEFORE generating the key (see M-pre fix). Ship `proxy/config.example.yaml` with a placeholder.
- No code path (onError, onIteration, transcript rows, debug prints) may include the `Authorization` header value or the full `proxyKey`. On HTTP error surface only `StatusCode` + a sanitized message.

### Build / install loop (`build.ps1`)

```powershell
rojo build default.project.json -o StudioAgent.rbxm
if ($?) {
  $dest = Join-Path $env:LOCALAPPDATA 'Roblox\Plugins\StudioAgent.rbxm'
  try { Copy-Item StudioAgent.rbxm $dest -Force }
  catch { Write-Host "Copy failed — close Studio and re-run."; throw }
}
```

The happy path is **close Studio → build+copy → reopen Studio** (live hot-reload of a manually copied `.rbxm` is inconsistent; Studio reliably loads plugins present at startup). Studio must have **Allow HTTP Requests** enabled (Game Settings → Security). `%LOCALAPPDATA%\Roblox\Plugins` already exists on this machine.

---

## Milestones

### M-pre: Local CLIProxyAPI

**Objective.** Stand up the official `eceasy/cli-proxy-api` container on Windows 11 + Docker Desktop, bound to loopback `127.0.0.1:8317`, authenticated against the user's Claude subscription via the one-time `--claude-login` OAuth flow, producing the exact connection contract the plugin consumes. Pure infra; no Luau.

**Files.**
- `proxy/config.example.yaml` — committed template. `host: "0.0.0.0"` (container-internal; loopback enforced by the compose port mapping, NOT by binding 127.0.0.1 inside the container which would break the mapping); `port: 8317`; `auth-dir: "/root/.cli-proxy-api"`; `api-keys: ["REPLACE_WITH_HEX_INBOUND_KEY"]`; `debug: false`; `logging-to-file: false` (stdout); `remote-management: { allow-remote: false, secret-key: "", disable-control-panel: true }`; `proxy-url: ""`; `request-retry: 3`. Empty `secret-key` disables the Management API (404 on management routes).
- `proxy/config.yaml` — **gitignored**; the live working copy created by `gen-key.ps1` from the example, with the real key injected.
- `proxy/docker-compose.yml` — service `cliproxy`, `image: eceasy/cli-proxy-api:<PINNED_TAG>` (see fix), `container_name: studio-agent-proxy`, `restart: unless-stopped`, `pull_policy: missing` (NOT `always`, to avoid silent drift), `ports: ["127.0.0.1:8317:8317"]`, volumes `./config.yaml:/CLIProxyAPI/config.yaml:ro` and `cliproxy-auth:/root/.cli-proxy-api`. Top-level `volumes: { cliproxy-auth: { name: cliproxy-auth } }` — **the explicit `name:` is mandatory** (see api_correction below).
- `proxy/gen-key.ps1` — on first run, copies `config.example.yaml` → `config.yaml`, then injects a 32-byte hex key into the gitignored copy and prints it once. `$bytes = New-Object byte[] 32; [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes); $key = -join ($bytes | %{ $_.ToString('x2') })`. Idempotent (no duplicate api-keys lines on re-run).
- `proxy/login.ps1` — `docker volume create cliproxy-auth` (idempotent) then `docker run --rm -it -p 127.0.0.1:54545:54545 -v "${PSScriptRoot}\config.yaml:/CLIProxyAPI/config.yaml:ro" -v cliproxy-auth:/root/.cli-proxy-api eceasy/cli-proxy-api:<PINNED_TAG> /CLIProxyAPI/CLIProxyAPI --claude-login --no-browser`. Uses `$PSScriptRoot` (not `${PWD}`) and quotes the volume spec so it is cwd-independent and space-safe.
- `proxy/verify.ps1` — acceptance gate (see Verification).
- `proxy/README.md` — operator runbook in order: gen-key → declare/create volume → login (one-time OAuth) → `docker compose up -d` → verify. Includes the connection contract block, the loopback-prefix security note ("never run a bare `-p 8317:8317`"), and troubleshooting (401 = wrong/missing key; empty model list / invalid_grant = token expired, re-run login; connection refused = container down/wrong binding; login hangs after browser approval = check `docker logs` that the in-container callback binds `0.0.0.0:54545`, fall back to native host login writing the token then mount it).

**Tasks.**
1. **T1** — Add `proxy/config.yaml` to `.gitignore` and write `proxy/config.example.yaml` with the confirmed schema. (Resolves the secret-leak by construction, BEFORE key generation.) Verify the binary parses the YAML (`docker run --rm -v "...config.yaml:...:ro" <img> /CLIProxyAPI/CLIProxyAPI --config ... --help`).
2. **T2** (dep T1) — Write `gen-key.ps1` (copy example→config.yaml, inject key, print once). Verify config.yaml's api-keys entry is a 64-char lowercase hex string echoed to stdout; re-run does not duplicate.
3. **T3** (dep T1) — Write `docker-compose.yml` with the explicit `name: cliproxy-auth` volume and `pull_policy: missing`. Verify `docker compose config` renders the loopback mapping and resolved volume name `cliproxy-auth`; `docker compose pull` resolves the pinned tag.
4. **T4** (dep T2,T3) — Write `login.ps1`; run it. Verify it prints a `console.anthropic.com` consent URL; after browser approval, exit 0 and `docker run --rm -v cliproxy-auth:/v alpine ls /v` shows a `claude-*.json` token. **During T4, `docker inspect` the image** to confirm there is no ENTRYPOINT (so the explicit `/CLIProxyAPI/CLIProxyAPI` path is required) and to record the digest + pin a concrete tag in compose + login.ps1. Confirm the in-container callback binds `0.0.0.0:54545`.
5. **T5** (dep T3,T4) — `docker compose up -d`. Verify `docker compose ps` shows the container running; logs show listening on `:8317` with no token errors; `docker volume inspect cliproxy-auth` shows the token; `Test-NetConnection 127.0.0.1 -Port 8317` succeeds.
6. **T6** (dep T5) — Write+run `verify.ps1` (the cluster acceptance gate; see Verification).
7. **T7** (dep T6) — Finalize `README.md` runbook; confirm `git status` shows no live secret staged (config.yaml gitignored, only config.example.yaml committed).

**Verification.** `verify.ps1` (use `curl.exe`, NOT the PowerShell `curl` alias):
1. Unauthenticated `GET /v1/messages` (the load-bearing security boundary) returns **401 OR 403** (both = gated). Also probe `GET /v1/models` unauthenticated; if it returns 200, **warn** (model listing ungated) rather than hard-fail.
2. `GET /v1/models` with `Authorization: Bearer $key` → 200 + non-empty JSON model list. Presence of `claude-opus-4-8`/`claude-sonnet-4-6` is a **warning, not a failure** (real proxies list dated IDs / opus-4-7).
3. `POST /v1/messages` with the Bearer key, `model=claude-opus-4-8`, `max_tokens=256`, one user message "Reply with the single word: ok" → `{type:"message", role:"assistant", content:[{type:"text",...}], stop_reason:"end_turn"}` with non-empty text. **This round-trip is the authoritative proof the default model works.**

---

### M0: Rojo skeleton + toolbar

**Objective.** A buildable Rojo skeleton that produces `StudioAgent.rbxm`, installs into `%LOCALAPPDATA%\Roblox\Plugins`, and shows a toolbar button that toggles a stub dock widget — proving the build/install loop on Windows.

**Files.**
- `rokit.toml`, `selene.toml`, `stylua.toml` — as in cross-cutting decisions (repo root).
- `default.project.json` — `{ "name": "StudioAgent", "tree": { "$path": "src" } }` (NO `$className`).
- `src/init.server.luau` — plugin entry. `local toolbar = plugin:CreateToolbar("Claude Agent")`; `local button = toolbar:CreateButton("StudioAgentToggle", "Open Claude Agent", "", "Claude")` (empty iconname = text-only); `button.ClickableWhenViewportHidden = true`; build the dock widget (sync form OK for M0 stub: `DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 320, 480, 260, 320)`, `plugin:CreateDockWidgetPluginGui("StudioAgentWidget", info)`, set `.Title`); `button.Click:Connect(function() widget.Enabled = not widget.Enabled; button:SetActive(widget.Enabled) end)`; `local Widget = require(script.UI.Widget); Widget.mount(widget)`; `print("[StudioAgent] M0 plugin loaded")` (sentinel). Construct once per session (guard against duplicate dock-widget id on reload).
- `src/UI/Widget.luau` — stub `function Widget.mount(gui) local f = Instance.new("TextLabel"); f.Size = UDim2.fromScale(1,1); f.Text = "Claude Agent (M0 stub)"; f.Parent = gui end; return Widget`. (`plugin` is NOT auto-passed to ModuleScripts.)
- `build.ps1` — as cross-cutting (try/catch on copy).
- `.gitignore` — already correct; do NOT overwrite (it ignores `*.rbxm`, `/sourcemap.json`, proxy auth/data, secrets).

**Tasks.**
1. **T1** — Write `rokit.toml`/`selene.toml`/`stylua.toml`; run `rokit install`. Verify `rojo --version` → `Rojo 7.6.1` **from repo root** (shims exit 1 without the manifest).
2. **T2** (dep T1) — Write `default.project.json` (`$path` only) and create `src/`. After T3, `rojo build default.project.json -o StudioAgent.rbxm` exits 0 and the file is non-empty.
3. **T3** (dep T2) — Write `src/init.server.luau` (toolbar + button + sync dock widget + Click toggle + `require(script.UI.Widget)` + sentinel) and `src/UI/Widget.luau` stub. Verify build exits 0; `selene src` reports **0 errors** (warnings OK); `stylua --check src` clean.
4. **T4** (dep T3) — Write `build.ps1`. Verify `Test-Path` of the installed `.rbxm` is True with current LastWriteTime.
5. **T5** (dep T4) — Manual Studio verification (Studio closed during copy, then reopen).

**Verification.** In Studio's PLUGINS ribbon: a "Claude Agent" toolbar with a "Claude" button is visible; clicking toggles a dock widget titled "Claude Agent" showing the M0 stub label; Output shows `[StudioAgent] M0 plugin loaded`. The built root is a single Script (RunContext present) — the button appearing is the real proof it executed. A CreateDockWidgetPluginGui deprecation **warning** in Output is acceptable (not a failure).

---

### M1: Config (typed persistence)

**Objective.** A typed wrapper over `plugin:SetSetting`/`GetSetting` that merges persisted values over hard defaults; single source of truth for `baseUrl`/`proxyKey`/`model`/`maxTokens`/`maxIterations` (and M11's `confirmDestructive`/retry knobs). Settings survive a Studio restart.

**Files.**
- `src/Config.luau` — returns a constructor. `DEFAULTS = { baseUrl="http://127.0.0.1:8317", proxyKey="", model="claude-opus-4-8", maxTokens=8192, maxIterations=12 }`. `MODELS = {"claude-opus-4-8","claude-sonnet-4-6"}` (never Haiku). `KEY_PREFIX = "StudioAgent_"`. `Config.new(plugin)` → self. `self:get(key)` → `plugin:GetSetting(KEY_PREFIX..key)`, falling back to `DEFAULTS[key]` when nil. `self:set(key, value)` validates (model ∈ MODELS; maxTokens clamp 1..16384 default 8192; maxIterations ≥1) then `plugin:SetSetting(...)`. `self:getAll()`, `self:isConfigured()` (`proxyKey ~= "" and baseUrl ~= ""`). Convenience getters used by later modules: `getBaseUrl/getProxyKey/getModel/getMaxTokens/getMaxIterations` (pin these exact names; M6 reads them). M11 adds defaults `confirmDestructive=true, retryMaxAttempts=4, retryBaseDelay=1.0, retryMaxDelay=30.0`.

**Tasks.**
1. **T1** (dep M0) — Implement `Config.luau` with DEFAULTS/MODELS/KEY_PREFIX/new/get/set/getAll/isConfigured + the `get*`-prefixed getters. `selene` clean.

**Verification.** Construct `Config`; `set('baseUrl', '...')` and `set('proxyKey', 'test123')`; `get` returns those; `get('model')` returns the default; an invalid model is rejected. (Run via a temporary dev hook in `init.server.luau` / a button that prints to Output — the command bar runs at a different identity than the plugin, so prefer in-plugin assertions.) Persistence is gated in M4-level UI verification (quit/reopen Studio).

---

### M2: Anthropic HTTP client + ping

**Objective.** `Anthropic.luau`'s HTTP layer: `request(body)` against `{baseUrl}/v1/messages` with the exact headers and bimodal error handling, plus a no-tools `ping()` that prints the assistant reply. Live round-trip depends on M-pre.

**Files.**
- `src/Anthropic.luau` (HTTP half) — `Anthropic.new(config)`. `self:request(body)` builds `requestOptions = { Url = config:getBaseUrl().."/v1/messages", Method = "POST", Headers = { ["Authorization"]="Bearer "..config:getProxyKey(), ["anthropic-version"]="2023-06-01", ["content-type"]="application/json" }, Body = HttpService:JSONEncode(body), Timeout = 90 }`. Guard: empty/nil proxyKey → return `{ok=false, kind="auth", message="proxy key not set"}` WITHOUT POSTing. `pcall(RequestAsync)`; on throw classify (HttpDisabled if message matches "not enabled", else Transport/Timeout) → `{ok=false, kind=...}`. On return: `res.Success==false` → pcall-decode `res.Body` as Anthropic error → `{ok=false, kind="http", status=res.StatusCode, message=decoded.error.message or res.Body}`; success → `{ok=true, data=JSONDecode(res.Body)}`. `self:sendMessage(opts)` assembles `{model, max_tokens, system?, tools?, messages}` (omit nil system/tools). `self:ping(promptText, onResult)` under `task.spawn`: sends one user message, concatenates `data.content[i].text` for text blocks, `print("[StudioAgent ping] "..text)`, calls `onResult`. **Never print `requestOptions`/Headers/the Bearer token.**

**Tasks.**
1. **T1** (dep M1) — Confirm/ensure Config getters exist.
2. **T2** (dep T1) — Implement `request(body)` with the exact requestOptions, proxyKey guard, pcall, Success branching, pcall-wrapped error-body decode, Timeout=90.
3. **T3** (dep T2) — Implement `sendMessage` + `ping` under `task.spawn`.

**Verification.**
- **Offline (provable now):** bad baseUrl → `{ok=false, kind="network"/"transport"}` with no stack trace; Headers table uses exactly `Authorization`/`anthropic-version`/`content-type`. `selene` clean.
- **Live (HARD-GATED on M-pre running + valid key):** trivial body returns `{ok=true}` with `.content`/`.stop_reason`; wrong key → 401 surfaced as an http error (not a throw); proxy stopped → transport error (not a hang). **Do NOT mark M2 done on offline checks alone** — the live ping is the acceptance anchor and requires M-pre.

---

### M3: Serialize (Luau → JSON-safe)

**Objective.** Pure module: walk any Luau value into a JSON-safe tagged-table form, finite-only output, with cycle/depth/key-count guards.

**Files.**
- `src/Serialize.luau` — `M.encode(value, opts?:{maxDepth?, maxTableKeys?})`. Tag scheme (`__t` discriminator, frozen as a shared doc comment identical in Serialize and Decode):
  - primitives passthrough; finite numbers passthrough.
  - non-finite number → `{__t="number", v="nan"|"inf"|"-inf"}` (JSONEncode silently emits invalid JSON for raw nan/inf — finite-only is mandatory; there is NO encode-side exception backstop).
  - `Instance` → `{__t="Instance", class, name, path=<array of child names from top-level DataModel child down>, display=GetFullName()}`. **Use an ordered array of names, NOT a dotted string** (GetFullName does not escape periods and has no `game.` prefix; dotted split breaks on names containing `.`). `display` is for human reference only.
  - `Vector3` → `{__t="Vector3", x,y,z}`; `Vector2` → `{__t="Vector2", x,y}`.
  - `CFrame` → `{__t="CFrame", c={v:GetComponents()}}` (12 floats, order x,y,z,R00,R01,R02,R10,R11,R12,R20,R21,R22 — confirmed identical to the 12-arg constructor).
  - `Color3` → `{__t="Color3", r=v.R, g=v.G, b=v.B}` (0..1).
  - `UDim2` → `{__t="UDim2", xs,xo,ys,yo}`; `UDim` → `{__t="UDim", s,o}`.
  - `EnumItem` → `{__t="EnumItem", enum=<bare type, strip a leading "Enum." from tostring(v.EnumType) via gsub("^Enum%.","")>, item=v.Name, value=v.Value}`.
  - `table` → cycle/depth-guarded recursive encode preserving array-vs-dict shape; **escape user tables**: if `rawget(t,"__t") ~= nil`, emit `{__t="table", v=<recursively-encoded t>}`.
  - Guards: depth > maxDepth (16) → `{__t="truncated", reason="maxDepth"}`; revisited identity → `{__t="cycle"}`; key count > maxTableKeys (5000) → `{__t="truncated", reason="maxKeys"}`. Non-string/number keys coerced to `tostring`. Normalize tables with non-contiguous integer keys to dicts with stringified keys (deterministic across the JSON boundary).

**Tasks.**
1. **T1** — Freeze the tag scheme as a byte-identical comment block in Serialize.luau and Decode.luau (incl. the `__t="table"` escape rule and the array-vs-dict normalization decision).
2. **T2** (dep T1) — Implement `encode` + typeof dispatch + number sentinels + Instance array-path descriptor + table walking + guards.

**Verification.** Encode `Vector3.new(1,2,3)`, `CFrame.new(1,2,3)*CFrame.Angles(.3,.4,.5)`, `Color3.fromRGB(255,0,0)`, `UDim2.new(0,300,1,0)`, `Enum.Material.Plastic`, `0/0`, `math.huge`, a cyclic table, a user table containing key `__t`, an Instance named `My.Part`, a holey/mixed table. `JSONEncode` each result without error; CFrame has a 12-element `c`; cyclic → `{__t="cycle"}`; `0/0` → `{__t="number",v="nan"}`; the EnumType-stored `enum` field equals `"Material"`. **Positive check:** feed `{x=0/0}` directly to JSONEncode and observe it returns a string containing the literal token `nan` (invalid JSON), then `JSONDecode` that string and confirm it ERRORS — proving why the sentinel is mandatory and the backstop is decode-side.

---

### M4: Decode (JSON-safe → typed Luau)

**Objective.** Inverse of Serialize: reconstruct typed values; resolve Instances by name-array; total (never throws).

**Files.**
- `src/Decode.luau` — `M.decode(value)`. For tables: if `v.__t` is a known tag, dispatch; else recursively decode (array+dict) to a plain table. Reconstructors: `number`→`0/0`/`math.huge`/`-math.huge`; `Vector3/Vector2`; `CFrame.new(table.unpack(v.c))`; `Color3.new`; `UDim2.new(xs,xo,ys,yo)`; `UDim.new(s,o)`; `EnumItem`→`resolveEnum(v.enum, v.item)` via `Enums[v.enum]:FromName(v.item)` in pcall (FromName is the documented resolver; defensively strip leading `Enum.`), nil on miss; `Instance`→`resolveInstance(v.path)`; `table`→`decode(v.v)` (unwrap escape, do NOT re-inspect inner `__t`); `cycle`/`truncated`→`{__decodeNote=reason}` placeholder.
  - `resolveInstance(path_array)`: first segment via `game:FindFirstChild(seg)` (**NOT `game:GetService` — it errors on garbage and creates services; FindFirstChild finds services AND non-service top-level children**); then `FindFirstChild` down the array, all pcall-guarded; returns the live Instance or nil (best-effort; first-sibling-match; documented as not-reconstruction).

**Tasks.**
1. **T1** (dep M3 T1) — (shared tag comment, already frozen).
2. **T2** (dep M3) — Implement `decode` + reconstructors + `resolveInstance` (FindFirstChild root, array path) + `resolveEnum` (FromName).
3. **T3 (SerializeSpec)** (dep M3,M4) — `src/SerializeSpec.luau` round-trip self-test: SAMPLES covering all types + edge cases (nan/inf/-inf, identity AND rotated CFrame, Color3.new vs fromRGB, nested array/dict, empty table, cyclic, over-maxDepth, Instance=Workspace, dotted-name Instance, user table with `__t` key). `deepEqual(a,b,eps)` with float epsilon (1e-5) for CFrame/Vector/Color/UDim, treating `0==-0`, and **special-casing non-finite numbers (both NaN ⇒ equal via `a~=a and b~=b`; inf==inf; -inf==-inf)** since `NaN ~= NaN`. `run()` does `encode → JSONEncode → JSONDecode → decode → deepEqual` per sample and prints PASS/FAIL.

**Verification.** Take the full `JSONEncode→JSONDecode` round-trip of the M3 samples through `Decode`: Vector3/Color3/UDim2/UDim/CFrame come back with correct `typeof`; CFrame components match within 1e-5; `Enum.Material.Plastic` resolves to the same EnumItem; Workspace's Instance descriptor resolves back to `game.Workspace`; a fabricated stale path returns nil without erroring; a user table with key `__t` round-trips to a plain table (NOT a typed value); the NaN sample passes via the special-cased deepEqual. `SerializeSpec.run()` returns `passed=true`, runtime < 1s.

---

### M5: Session env + run_luau

**Objective.** A persistent REPL environment surviving across `run_luau` calls, and the exec spine that runs Luau at PluginSecurity under a ChangeHistory recording, capturing output and serializing returns.

**Files.**
- `src/Session.luau` — `Session.env = {}` created ONCE at module load (state survives between calls; never recreate per call). `local realEnv = getfenv(0)` captured ONCE at load (do NOT call `getfenv(0)` inline in the metamethod). `Session.environment` = a fresh table with metatable: `__index` uses **explicit presence checks, never `or`** (`local v = rawget(Session.env,k); if v ~= nil then return v end; local c = captureGlobals[k]; if c ~= nil then return c end; return realEnv[k]`) so a persisted `false`/`0` is not shadowed by globals; `__newindex = function(_,k,v) rawset(Session.env,k,v) end`. `captureGlobals` overrides `print`/`warn`. A **single ordered capture buffer** of `{stream="stdout"|"stderr", text}` entries (preserves cross-stream chronology); `beginCapture()` clears it; `print`/`warn` shims tostring+concat args with `\t` between args, append one entry per call, then forward to the real `print`/`warn` captured at load; `takeCapture()` derives `{stdout, stderr, combined}` (newline-joined per call) and resets. `Session.reset()` = `table.clear(Session.env)`. `Session:execCapture(fn)` runs the chunk and returns `(ok, ...)`. Note `getfenv`/`setfenv` are deprecated (disable optimizations) — acceptable for a local-only plugin; downgrade confidence and verify at runtime.
- `src/Tools/RunLuau.luau` — `local Serialize = require(script.Parent.Parent.Serialize)`, `local Session = require(script.Parent.Parent.Session)`, `ChangeHistoryService`. `compile(src)` wraps loadstring with a distinctive chunkname (`loadstring(src, "=run_luau")`); the **abstraction point** that returns either `(fn, nil)` plus an env-setter, OR falls through to the vendored `src/Vendor/FiOne.luau` when `loadstring` is nil/returns-nil. `RunLuau.run(input:{code})`: (1) `chunk, err = compile(code)`; if not chunk → `{text="compile error: "..err, error=true}` (no ChangeHistory). (2) set env on chunk (setfenv for native path; FiOne's own env-injection API for the fallback). (3) `Session.beginCapture()`. (4) `rid = ChangeHistoryService:TryBeginRecording("run_luau")`; if `rid==nil` (recording in progress / solo playtest) → refuse the mutation with `{text="could not begin a change recording (another recording in progress or playtest)", error=true}` so the Ctrl+Z guarantee is never silently broken. (5) `results = table.pack(xpcall(chunk, function(e) return debug.traceback(tostring(e), 2) end))`. (6) `if rid then ChangeHistoryService:FinishRecording(rid, results[1] and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel) end`. (7) `cap = Session.takeCapture()`. (8) on ok → `Serialize.encode` the returns, return `{text=<json/compact rendering incl. stdout/stderr>, error=false}`; on error → `{text=<traceback verbatim + stderr>, error=true}`. (9) A module-level single-flight `Session.busy` guard refuses re-entrant `run` calls (a single chunk that yields keeps the recording open across the yield).

**Tasks.**
1. **T0 (probe — promoted to FIRST step)** — In the actual plugin (built+installed, NOT command bar), evaluate `print(type(loadstring), loadstring and loadstring("return 1"))`. **loadstring availability in plugins is unverified** (official docs say it's disabled by default and give no plugin exemption). If nil/returns-nil, the FiOne fallback is the REAL path and `compile()`/env-injection must target FiOne from the start.
2. **T1** — Implement `Session.luau` (`env`+`environment` with explicit-presence `__index`, captured `realEnv`, ordered capture buffer, print/warn shims, reset). Verify (via a dev hook in the plugin, not command bar): `Session.environment.workspace==workspace`, `.game==game`, `.Instance`/`.Enum`/`.task` non-nil at load; `Session.environment.foo=7` then `Session.env.foo==7`; a stored `false` reads back `false` (not nil); print capture works.
3. **T2** (dep T1) — Implement `RunLuau.luau` (compile abstraction, setfenv, ChangeHistory wrap with nil-rid refusal, xpcall+traceback, Serialize returns, busy guard). Verify: `run({code="local p=Instance.new('Part') p.Parent=workspace return p.Name"})` returns the serialized name, `error=false`, and a Part exists.
4. **T3** (dep T2) — Verify undo: the created Part is a single waypoint, Ctrl+Z removes it; FinishRecording uses Commit on success; nil rid (solo playtest) refuses cleanly. Also verify a yielding chunk (`task.wait(0.1) ...`) still commits one waypoint.
5. **T4** (dep T2) — Persistence + errors: two `counter=(counter or 0)+1 return counter` execs return 1 then 2; `error("boom")` and `return (nil).x` return `error=true` with a traceback whose **top frame references the user chunk** (verify level=1 vs 2 empirically via the `=run_luau` chunkname); invalid syntax returns a compile error with `error=true` and no ChangeHistory waypoint.
6. **T5 (FiOne fallback — REQUIRED, not deferred)** (dep T2) — Vendor `src/Vendor/FiOne.luau`; wire `compile()` to fall through when loadstring is unavailable. Verify the fallback honors `Session.env` persistence by running `counter=(counter or 0)+1 return counter` TWICE through the stubbed-FiOne path returning 1 then 2 (not just `return 1+1`).

**Verification.** (folded into tasks above; T2 build-and-run inside the real plugin is the authoritative confirmation of loadstring/setfenv/PluginSecurity behavior).

---

### M6: Agent loop

**Objective.** The manual Anthropic tool loop in `Anthropic.luau`: assemble `{model,max_tokens,system,tools,messages}`, POST, parse content blocks, dispatch tool_use, reply with tool_result, repeat until non-tool_use or iteration cap. For M6 the tools array is just `[run_luau]`.

**Files.**
- `src/Anthropic.luau` (loop half) — `M.runLoop(opts:{task, onEvent, shouldCancel})` runs synchronously (caller wraps in task.spawn). Builds `messages={{role="user", content=opts.task}}`; for `i=1..Config:getMaxIterations()`: assemble body, `M.request`; on error fire `onError`(with `kind`) and stop, leaving NO dangling assistant tool_use turn; append `{role="assistant", content=resp.content}` **verbatim**; branch on `stop_reason` per cross-cutting rules; if `tool_use`, dispatch **every** tool_use block via `Tools.dispatch` (errors still produce a tool_result for that block), assemble ONE user turn with all tool_result blocks first, continue. Fire `onEvent` for `assistant_text`/`tool_use`/`tool_result`/`iteration`/`status`/`done`/`error`. Check `shouldCancel()` before each request and each dispatch. `M.start(userPrompt, callbacks)` wraps `runLoop` in the exception-safe task.spawn single-flight wrapper. Helpers `collectText`/`collectToolUses`. Validate `resp.content` is a table before iterating.

**Tasks.**
1. **T1 (hard gate)** (dep M1,M5) — Confirm on disk: Config getter names and RunLuau.run return shape (`{text, error}`). If absent/divergent, STOP and flag the missing dependency; do not code against assumed shapes.
2. **T2** (dep T1) — `M.request` already from M2; confirm pcall + Success branching + pcall-decode + HttpDisabled distinction + Timeout.
3. **T3** (dep T2) — Implement `collectText`/`collectToolUses` + `runLoop` (verbatim assistant append, all-tool-use dispatch, single user turn with tool_results first, full stop_reason branching, cancel checks, iteration cap → onError).
4. **T4** (dep T1) — Wire `Tools.schemas()`/`Tools.dispatch` for run_luau (per-tool descriptor, pcall-wrapped run + encode, unknown→is_error, ALWAYS returns (string,bool)).
5. **T5** (dep T3,T4) — `M.start` exception-safe single-flight wrapper; default callbacks print to Output.
6. **T6 (milestone gate)** (dep T5) — Build/install; proxy up; key stored; HTTP enabled.

**Verification.**
- **Mechanical (must pass):** request body contains the run_luau schema with `input_schema.type=="object"`; a forced single tool_use produces a user turn with one tool_result matching the tool_use_id; a 2-tool turn where one errors still yields 2 tool_results (no 400); the terminal check is exactly `stop_reason ~= "tool_use"`; `max_tokens`/`refusal` also terminate (surface to onDone).
- **Behavioral (milestone):** `start("create a red part at 0,5,0")` → Claude emits a run_luau tool_use → Part exists at `(0,5,0)`, red → non-tool_use final message (onDone). Ctrl+Z removes it. Two quick `start` calls → "already running" not corruption. Studio stays responsive during the round-trip.

---

### M7: Structured tools (get_tree, search, get_properties, set_property)

**Objective.** Four read/write structured tools so Claude can inspect/mutate the DataModel without writing Luau, sharing a path resolver and a curated property catalog (there is NO reflection/GetProperties API at PluginSecurity — confirmed).

**Files.**
- `src/Tools/Path.luau` — `resolve(path):(Instance?, err?)`. First segment: `game`/`datamodel`→game; for service-like first segments use `game:FindService(seg)` inside pcall (**NOT GetService — it errors on garbage and creates services as a side effect**), falling back to `game:FindFirstChild(seg)`; `workspace` alias may use `GetService("Workspace")` (known-valid). Subsequent segments: `parent:FindFirstChild(seg)` (NEVER raw indexing). Case-sensitive; first-sibling-match; returns descriptive error on first miss. `fullPath(inst)` helper for echoing. Document the dotted-name and duplicate-sibling limitations.
- `src/Tools/PropertyCatalog.luau` — static `byClass` (Instance/BasePart/Part/MeshPart/Model/Folder/Decal/PointLight/...), each entry **tagged with its expected value type** so reads that return an unexpected Instance can be rejected. `get(inst)` unions names across the IsA chain, de-duped. `readOnly` set (`ClassName`, etc.). Cross-check exact API names (`MeshPart.TextureID` capital ID, `Decal.Color3`, `BasePart.Color`) against docs.
- `src/Tools/Tree.luau` — per-tool descriptors (NOT one per module — see fix). `get_tree.run(args:{path?, depth?=2, maxNodes?=500})`: depth+node-capped `{class, name, children}` tree; **omit per-node full paths** (structure implies path; include path only on the root; accumulate child paths during recursion if needed) to keep payloads lean; set `truncated=true` on cap. `search.run(args:{root?, name?, className?, maxResults?=100})`: BFS/GetDescendants; name = case-insensitive substring; className filter via `IsA`. **`IsA` returns false (does NOT throw) on an unknown className** — so an unknown className yields `{ok=true, results={}}`, NOT `{ok=false}` (validate up front or document the empty-result contract). input_schema `description` fields explicitly tell Claude paths are case-sensitive/dot-separated and to use run_luau for dotted/duplicate names.
- `src/Tools/Properties.luau` — `get_properties.run({path})`: only index properties on the instance's actual IsA chain; read via pcall; if a non-Instance-typed catalog entry returns an Instance (a same-named child shadowing the property), reject it; serialize via `Serialize.encode`; Parent/PrimaryPart (Instance-typed) serialized as path references. `set_property.run({path, name, value})`: reject `readOnly`; `RunService:IsEdit()` check (clear error if not edit mode); `pcall(Decode.decode)` the value BEFORE opening any recording (`{ok=false, error="value decode failed"}` on failure); `rid = TryBeginRecording("SetProperty "..name)`; if nil → `{ok=false}`; `pcall(function() inst[name]=decoded end)`; `FinishRecording(rid, ok and Commit or Cancel)`; echo back `Serialize.encode(inst[name])`.
- `src/Tools/init.luau` — registry: build `byName = name→descriptor` (each descriptor has its own `run`), NOT name→module (Tree/Properties each host two tools). `schemas()` → ordered `[{name, description, input_schema}]`. `dispatch(name, input, ctx)` → pcall-wrapped, ALWAYS `(string, bool)`; unknown → is_error.

**Tasks.**
1. **T1** (dep M0) — `Path.luau` (FindService+pcall root, FindFirstChild walk, array/dotted handling).
2. **T2** (dep M0) — `PropertyCatalog.luau` (type-tagged byClass, get, readOnly).
3. **T3** (dep T1) — `Tree.luau` (get_tree depth/node-capped, search with empty-result-on-unknown-className contract, per-tool descriptors, schema descriptions noting limitations).
4. **T4** (dep T1,T2,M3,M4) — `Properties.luau` (typed reads with child-shadow rejection, set_property with edit-mode check, pcall-Decode-before-recording, ChangeHistory Cancel/Commit, nil-rid handling).
5. **T5** (dep T3,T4,M6) — Extend `Tools/init.luau` to register `get_tree`/`search`/`get_properties`/`set_property` (+ keep `run_luau`); `schemas()` returns 5; JSONEncode the schemas array as valid Anthropic tools payload.

**Verification.** `resolve` returns Workspace/nested Part and a clear error on miss. `PropertyCatalog.get(part)` contains Name/Size/Anchored/CFrame; `readOnly.ClassName==true`. `get_tree` returns nested tree (truncated=false); `search(className="BasePart")` returns parts; `search(className="NotAClass")` returns `{ok=true, results={}}`; each result JSONEncodes. `get_properties` returns JSON-safe values; `set_property(Anchored=true)` sets it, `result.ok==true`, **programmatic undo** (`ChangeHistoryService:Undo()` then re-read) reverts and the Cancel path leaves no undo entry; `set_property(ClassName=...)` → readOnly `{ok=false}`; bad value → `{ok=false}` no partial change. `dispatch("does_not_exist",{})` → is_error.

---

### M8: SystemPrompt + tool schemas

**Objective.** Make the tool surface speakable to Claude (each tool's `input_schema` + uniform descriptor, registered in `Tools/init.luau`) and give an honest environment description with a read-vs-mutate tool-selection policy and serializer conventions.

**Files.**
- `src/SystemPrompt.luau` — returns `function SystemPrompt.build(opts:{model, maxIterations}?)` (interpolatable) or a string. Sections: (1) Identity — coding agent INSIDE Studio at PluginSecurity, tool calls execute in-process against the live DataModel, mutations are ChangeHistory-wrapped (Ctrl+Z), non-streaming. (2) Tool policy — reads prefer get_tree/get_properties/search; single known edit → set_property; multi-step/conditional/bulk/uncovered → run_luau (persistent REPL session). (3) Serializer conventions — **authored by reading the actual Serialize.luau, not just CLAUDE.md** (Instance path as name-array, Vector3 {x,y,z}, CFrame 12 floats in GetComponents order, Color3 0..1, UDim2/UDim, EnumItem "Enum.Material.Plastic", nan/inf sentinels with the exact spelling). (4) Doc pointers — `create.roblox.com/docs/llms.txt`; append `.md` to any API page. (5) Working rules — verify with a read after a mutate; keep run_luau snippets small; respect the iteration cap. (M11 appends is_error interpretation guidance.)
- `src/Tools/RunLuau.luau`, `Tree.luau`, `Properties.luau` — ADD `name`/`description`/`inputSchema` descriptor fields (bodies from M5/M7 unchanged). run_luau: `inputSchema={type="object", properties={code={type="string"}}, required={"code"}}`. get_tree/search/get_properties/set_property schemas per M7.
- `src/Tools/init.luau` — already the per-tool registry (M7). Confirm `schemas()` emits `{name, description, input_schema}` for all registered tools.

**Tasks.**
1. **T1** (dep M3,M4) — Write `SystemPrompt.luau` mirroring the ACTUAL serializer; expose `build(opts)`.
2. **T2** (dep M5,M7) — Add descriptor fields to each tool module (per-tool, uniform `run(input,ctx)->(text,isError)`).
3. **T3** (dep T2) — Confirm `Tools/init.luau` registry/`schemas()`/`dispatch` cover all tools.
4. **T4** (dep T1,T3,M6) — Update `runLoop` to source `system` from SystemPrompt and `tools` from `Tools.schemas()`, dispatching through the registry. No `tool_choice`.

**Verification.**
- **Mechanical:** `print(SystemPrompt.build())` contains "PluginSecurity", "ChangeHistory", "run_luau", "get_tree", "llms.txt"; `#Tools.schemas()` equals the registered count; each has `input_schema.type=="object"`; `dispatch("get_tree",{path="game.Workspace"})` returns non-empty; request body actually carries all N schemas. **Round-trip one of each serializer-documented type (CFrame, EnumItem, nan/inf) through Decode using exactly the literal SystemPrompt tells Claude to emit, and confirm it decodes.**
- **Behavioral (soft, do NOT gate the milestone):** `runLoop({task="list the children of game.Workspace"})` → Claude SHOULD pick get_tree/get_properties (if it over-uses run_luau, tune the SystemPrompt policy, never set tool_choice). `selene`/`stylua` clean.

---

### M9: UI Widget (dockable panel wired to the loop)

**Objective.** A dock panel — task input, scrolling transcript, status line, iteration counter, Start/Stop — driving the loop under task.spawn with a cooperative cancel flag, rendering loop callbacks. Toolbar button toggles it.

**Files.**
- `src/UI/Widget.luau` — `Widget.create(plugin, deps:{runLoop, systemPrompt, tools, config})`. Build `DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 320, 480, 280, 320)`; create via **`CreateDockWidgetPluginGuiAsync`** (the CURRENT method; CreateDockWidgetPluginGui is the deprecated/superseded one — do NOT frame async as a "fallback for older Studio"). Wrap only in pcall for genuine failures (duplicate id). `gui.Title="Studio Agent"`. UI tree parented to the gui: a root **Frame** (NOT a ScreenGui — a ScreenGui does not render in a dock widget), a `ScrollingFrame` transcript with `UIListLayout` + auto `CanvasSize` via `AbsoluteContentSize`, a multiline `TextBox` (input, `ClearTextOnFocus=false`), status `Label`, iteration `Label`, Start/Stop `TextButton`s. Methods: `appendTranscript(role, text)` (TextLabel row, TextWrapped, auto-height via TextBounds), `setStatus`, `setIteration(n,max)`, `setRunning(bool)`. Start handler: read input, call `deps.runLoop({task, onEvent=<map events to transcript/status/iteration>, shouldCancel=function() return cancelled end})` under task.spawn. Stop handler: `cancelled=true`, status "stopping after current step" (cooperative — RequestAsync cannot abort mid-flight). **Never put request headers/Authorization/proxyKey into any onEvent payload or transcript row.** Surface HTTP errors (Success=false / connection / HttpDisabled / max_tokens truncation) as visible error rows. Returns `{gui, ...methods}`. (M11 adds the destructive-confirm prompt + checkbox.)
- `src/init.server.luau` — EXTEND: `local widget = Widget.create(plugin, {runLoop=Anthropic.runLoop, systemPrompt=SystemPrompt, tools=Tools, config=config})`; `button.Click:Connect(function() widget.gui.Enabled = not widget.gui.Enabled; button:SetActive(widget.gui.Enabled) end)`; sync active state both ways via `widget.gui:GetPropertyChangedSignal("Enabled")`. Keep the M0 toolbar code.

**Tasks.**
1. **T1** (dep M8) — Implement `Widget.create` (Async dock gui, Frame-rooted UI tree, transcript/status/iteration/buttons, methods, event mapping, cooperative cancel, secret-safe rendering).
2. **T2** (dep T1) — Extend `init.server.luau` to instantiate the widget and toggle it; sync button active state.

**Verification.** Build/install/reload (proxy up). Clicking the toolbar button shows/hides the panel; the button highlight tracks visibility (incl. closing via the X). A read task ("how many parts under Workspace and their names") shows transcript rows + live iteration counter + status idle→running→done, and Claude uses a structured read tool. A build task ("make a 4x1x4 grey Part at origin") → run_luau → Part appears, Ctrl+Z removes it. Stop mid-run flips status to "stopping" and halts before the next request. **Unhappy path:** proxy stopped or blank proxyKey → an explicit error row (e.g. "request failed: <status>" / "no proxy key set"), NOT an indefinite "running"; confirm a forced error does not print the Bearer key.

---

### M10 (optional / deferred): Capture (screenshot sidecar)

**Objective.** Optional `capture` tool — a screenshot via an OS sidecar, deferred. Not on the critical path; implement only after M11 hardening if desired.

**Files.** `src/Tools/Capture.luau` — `capture` tool descriptor with a `destructive=false` flag, returning a deferred/sidecar-produced image reference (mechanism TBD: OS-level sidecar writing to a temp path the plugin surfaces). Register in `Tools/init.luau` when implemented.

**Tasks/Verification.** Deferred. When implemented: tool returns without blocking the loop; image artifact is produced and surfaced; `destructive=false` so it is never gated by the confirmation prompt.

---

### M11: Hardening

**Objective.** Harden along four axes via two new modules and surgical edits: (1) `Errors.luau` typed taxonomy + Claude-facing/human-facing rendering; (2) `Anthropic.luau` request wrapped in pcall + Retry with usage-window detection; (3) `Retry.luau` capped exponential backoff + jitter, classifier-driven; (4) destructive-op confirmation gate in the dispatcher prompting the user via the Widget.

**Files.**
- `src/Errors.luau` — `Kind` enum (cross-cutting), `ClassifiedError = {kind, httpStatus?, anthropicType?, message, retryable, userMessage}`. `classifyHttp(resp)`: pcall-decode body; match `USAGE_WINDOW_PATTERNS` (case-insensitive) against decoded `error.message` AND raw lowercased body BEFORE status mapping → `UsageWindow`/retryable; status map per cross-cutting (incl. 402 non-retryable; 502/503/504 gateway-transient). `classifyThrown(err)`: HttpDisabled if "not enabled", Timeout if "timeout"/"timed out", else Transport; all retryable. `classifyTool(name, ok, err)`: `ToolError`, retryable=false (Claude must change inputs). `toToolResultText(ce)` (model-actionable `ERROR [kind]: msg + hint`), `toUserStatus(ce)`.
- `src/Retry.luau` — `Policy={maxAttempts, baseDelay, maxDelay, factor, jitter}`, `DEFAULT={4,1.0,30.0,2.0,0.25}`. `computeDelay(attempt, policy)` = `min(maxDelay, baseDelay*factor^(attempt-1))` ±jitter, honoring an optional `retryAfterSeconds` override. `run(fn, opts:{policy, classify, onBackoff})` loops up to maxAttempts, `task.wait(computeDelay)` between retries (NEVER busy-wait), stops early on non-retryable. **UsageWindow uses a SEPARATE cap of 1 attempt** (re-reserving max_tokens worsens exhaustion) distinct from the generic transient cap.
- `src/Anthropic.luau` (EDIT) — wrap the single RequestAsync in `Retry.run(function() local ok, resp = pcall(RequestAsync, requestOptions); if not ok then return false, Errors.classifyThrown(resp) end; if not resp.Success then return false, Errors.classifyHttp(resp) end; return true, resp end, {...})`. `onBackoff` → statusCallback. On terminal failure: statusCallback(ce.userMessage), break the loop, do NOT inject as tool_result, do NOT leave a dangling tool_use turn. Read `retry-after`/`x-ratelimit-reset-after` from response headers **case-insensitively** (lowercase all header keys into a map) → `retryAfterSeconds`. Set `requestOptions.Timeout` (Config knob) so a hung proxy fails fast into Timeout.
- `src/Tools/init.luau` (EDIT) — per-tool `destructive` flag (run_luau=true, set_property=true; reads/capture=false). `dispatch(name, input, ctx)`: if `descriptor.destructive and Config.confirmDestructive and not ctx.confirm(name, input)` → is_error tool_result "User declined ...". Else pcall run+encode → tool_result; keep ChangeHistory Cancel/Commit with nil-rid handling (refuse or document-unrecorded). For multi-tool turns a decline/error on one block still produces its tool_result and never aborts siblings.
- `src/Tools/RunLuau.luau` (EDIT) — ensure the returned text includes the captured error message + traceback verbatim so Claude can self-correct.
- `src/Config.luau` (EDIT) — add `confirmDestructive=true`, retry knobs; flow knobs into `Retry.DEFAULT` override at loop construction.
- `src/UI/Widget.luau` (EDIT) — render `userMessage`/backoff status + retry countdown in transcript/status; implement `ctx.confirm(name, input)` as a Yes/No prompt that blocks the loop coroutine via a **BindableEvent** (preferred) with a confirmation **timeout defaulting to decline**, cancellable by Stop, resolving widget-close AND plugin-unload to decline; add a "Confirm destructive ops" checkbox bound to `Config.confirmDestructive`.
- `src/SystemPrompt.luau` (EDIT) — append: "Tool results may begin with `ERROR [kind]: <message>` — treat these as actionable: correct the code/arguments and try again; do not blindly repeat an identical failing call; for usage-window/transport errors the loop handles backoff, so do not spam retries."

**Tasks.**
1. **T1** — `Errors.luau` (taxonomy, three classifiers, renderers, message-first usage-window detection over decoded+raw body, 402, gateway codes). Verify: synthetic 400-usage → `usage_window`/retryable; 400-bad-schema → `bad_request`/not-retryable; 529 overloaded → retryable.
2. **T2** (dep T1) — `Retry.luau` (computeDelay capped+jitter+retryAfter override; run with task.wait; UsageWindow low cap). Verify in task.spawn: retryable-then-success on attempt 3 fires onBackoff twice with cumulative delay in band; always-retryable stops at maxAttempts returning the last ClassifiedError.
3. **T3** (dep T1,T2) — Edit `Anthropic.luau` (pcall+Retry wrap, classifyThrown/classifyHttp, onBackoff→status, terminal break with no dangling tool_use, case-insensitive retry-after, Timeout). **Decide UsageWindow policy: 1 bounded attempt then surface (per cross-cutting), and align T3 verification to expect one bounded backoff + clean terminal message.** Verify: forced 400 (huge max_tokens) → clear "usage window exhausted" message, bounded backoff, clean termination (no raw Lua error/hang); proxy killed → transport error retried then surfaced; fresh task after a mid-tool-loop failure → no 400 (no dangling tool_use).
4. **T4** (dep T1) — Edit dispatcher (uniform tool_result, classifyTool, destructive flags, ChangeHistory nil-rid handling). Verify: a deliberately broken run_luau (confirmDestructive off) → is_error tool_result with readable message → Claude issues a corrected call that succeeds (Part created); Ctrl+Z undoes; failing run_luau leaves no half-applied change; a 2-tool turn with one failure yields 2 tool_results.
5. **T5** (dep T4) — Implement destructive confirm in Widget (BindableEvent, timeout→decline, Stop-cancellable, close/unload→decline) + checkbox. Verify: "delete all parts" prompts Yes/No, loop pauses ("awaiting confirmation"); No → decline tool_result, loop continues without mutating; Yes → op runs + ChangeHistory records; checkbox off → no prompt.
6. **T6** (dep T3,T5) — Edit `Config.luau` (confirmDestructive + retry knobs persisted) and `SystemPrompt.luau` (is_error guidance); flow Config knobs into Retry. Verify: `confirmDestructive=false` persists across restart and suppresses prompts; the system prompt contains the ERROR paragraph; effective maxAttempts logged at loop start.
7. **T7** (dep T3,T4,T5,T6) — Integration build + selene/stylua + re-run all four acceptance paths against the live proxy.

**Verification.** `rojo build` succeeds; `selene` 0 errors; `stylua --check` clean. In Studio: (1) bad run_luau → Claude recovers and succeeds; (2) forced 400 → clear "usage window" message + bounded backoff + clean termination; (3) proxy killed mid-task → transport error retried then surfaced, no unhandled Lua error; (4) destructive confirm Yes/No both behave; no Bearer key ever appears in transcript/Output.

---

## Consolidated risks & open questions (deduped, each with a recommended resolution)

1. **loadstring availability at PluginSecurity is unverified** (official docs say disabled-by-default, no documented plugin exemption). → **Resolution:** Treat the FiOne/vLua fallback (M5 T5) as a REQUIRED, tested path, not defensive. Run the M5-T0 probe FIRST inside the real installed plugin; if loadstring is nil/returns-nil, target FiOne's env-injection from the start.
2. **CLIProxyAPI `eceasy:latest` tag drift** (third-party image; schema/paths/entrypoint can change). → **Resolution:** Pin a concrete tag + record the digest after M-pre T4's `docker inspect`; set `pull_policy: missing`.
3. **Docker named-volume namespacing** — Compose would name it `proxy_cliproxy-auth` while `login.ps1` uses the bare `cliproxy-auth`, splitting the OAuth token from where the server reads it. → **Resolution (api_correction):** Declare `volumes: { cliproxy-auth: { name: cliproxy-auth } }` in compose; both containers then resolve the same volume. Verify with `docker compose config` + `docker volume inspect`.
4. **OAuth callback port (54545) binding inside the headless container** — if it binds 127.0.0.1 internally, the published mapping won't catch the redirect and login hangs. → **Resolution:** Confirm via `docker logs` during T4 that the callback binds `0.0.0.0:54545`; document a native-host login fallback (write token, then mount).
5. **`config.yaml` secret leak** (live key in a tracked path). → **Resolution:** gitignore `proxy/config.yaml` and ship `config.example.yaml` BEFORE key generation; `gen-key.ps1` copies example→config.yaml and injects into the gitignored copy.
6. **Subscription-window 400 detection is message-substring based** (wording quoted from notes, unverified against this proxy; status could be 400 or 429). → **Resolution:** Centralize `USAGE_WINDOW_PATTERNS` in `Errors.luau`, match case-insensitively against decoded message AND raw body, and tune after first live observation. Do NOT rely on `error.type`.
7. **Retrying the usage-window burns more window** (each attempt re-reserves max_tokens). → **Resolution:** UsageWindow gets a low cap (1 attempt) distinct from the generic transient cap (4); prefer surfacing "lower max_tokens / wait." T3 verification asserts one bounded backoff, not multiple.
8. **HttpService:RequestAsync bimodal errors** (raises on network/timeout/HTTP-disabled; Success=false on non-2xx; JSONDecode throws on non-JSON). → **Resolution:** Uniform pcall + Success branching + pcall-wrapped decode + distinct HttpDisabled classification + Timeout=90, all in `request`/`Errors`.
9. **Multi-tool_use turn invariant** — all tool_results must come first and every tool_use needs exactly one tool_result, or the next request 400s. → **Resolution:** loop dispatches ALL blocks (errors still produce a tool_result), one user turn with tool_results ordered first.
10. **Dangling tool_use turn after a terminal loop error** poisons subsequent requests. → **Resolution:** discard the in-flight assistant turn or scope message history per-run; verify with proxy-kill-then-fresh-task.
11. **Cooperative-only Stop** (RequestAsync can't abort mid-flight). → **Resolution:** check `shouldCancel()` at step boundaries; status says "stopping after current step."
12. **Destructive-confirm could hang the agent coroutine.** → **Resolution:** BindableEvent block with a confirmation timeout→decline, Stop-cancellable, widget-close/plugin-unload→decline.
13. **getfenv/setfenv deprecated; setfenv may not redirect a FiOne closure.** → **Resolution:** keep setfenv for the native path (acceptable, local-only); `compile()` returns an env-setter so the fallback injects env via its own API; verify FiOne persistence with a counter, not `1+1`.
14. **No reflection API** → get_properties is only as complete as `PropertyCatalog`; bracket-indexing can return a same-named child instead of a property. → **Resolution:** documented curated subset (run_luau is the escape hatch in tool descriptions); type-tag catalog entries and reject unexpected-Instance reads.
15. **Path resolution: case-sensitive, dotted-name and duplicate-sibling ambiguity; GetService creates services and errors on garbage.** → **Resolution:** Instance descriptor uses a name-array (not dotted string); `resolveInstance` uses `FindFirstChild` at root; `Path.resolve` uses `FindService` + pcall; tool schema descriptions state the limitations.
16. **`IsA` returns false (not throws) on unknown className** — search verification was wrong. → **Resolution:** unknown className yields `{ok=true, results={}}`; update the contract/verification.
17. **TryBeginRecording nil (in-progress / solo playtest)** → unrecorded mutation breaks Ctrl+Z. → **Resolution:** refuse the mutation with an is_error result when rid==nil (run_luau and set_property), or explicitly document unrecorded.
18. **Module dependency sequencing** — M6/M7/M8/M9/M11 edit modules from earlier milestones; build them in order, hard-gate Config getter names + RunLuau return shape before coding against them.
19. **max_tokens window false-failures in verification.** → **Resolution:** ping/smoke tests use max_tokens=256; never bump max_tokens for M6.
20. **Whether to feed loop-level errors back to Claude** (open question). → **Resolution:** keep them loop-level (clean termination + UI message); revisit only if the agent's summarize-on-failure UX is wanted (costs a round-trip against the window).
21. **Should set_property support batch / get_properties include attributes** (open). → **Resolution:** single-property + reflected props for now; `GetAttributes()` and batch are cheap follow-ups, deferred.

## API confidence ledger (low/medium-confidence APIs to confirm against create.roblox.com during implementation)

| API | Confidence | Confirm during | Note / resolution |
|---|---|---|---|
| `loadstring` usable in a locally-installed unpublished plugin at PluginSecurity | **low/medium (downgraded)** | M5 T0 probe (in real plugin) | Docs say disabled-by-default, no plugin exemption. FiOne fallback is required, not defensive. |
| FiOne/vLua env-injection API shape | medium | M5 T5 | `compile()` must return an env-setter / accept env; verify persistence with a counter. |
| `getfenv(0)` / `setfenv` semantics + deprecation | medium | M5 T1 | Deprecated, disables optimizations; capture `realEnv` once; verify `workspace`/`game`/`Instance`/`Enum`/`task` non-nil at load. |
| `xpcall` traceback `level` (1 vs 2) pointing at user chunk | medium | M5 T4 | Use `=run_luau` chunkname; inspect top frame; adjust level empirically. |
| `tostring(EnumItem.EnumType)` returns bare "Material" vs "Enum.Material" | medium | M3 T2 / M4 T2 | Strip leading `Enum.` defensively; resolve via `Enums[type]:FromName(item)`. |
| `EnumItem` resolution path (`FromName` vs string-index) | medium | M4 T2 | `FromName` is the documented resolver; pcall-guard both; nil on miss. |
| OAuth callback port 54545 + in-container binding | medium | M-pre T4 | Confirm `0.0.0.0:54545` via `docker logs`; native-login fallback documented. |
| `eceasy/cli-proxy-api` ENTRYPOINT (explicit binary path needed?) | medium | M-pre T4 | `docker inspect`; drop explicit `/CLIProxyAPI/CLIProxyAPI` only if an ENTRYPOINT is added by a pinned image. |
| Unauthenticated status code (401 vs 403) on `/v1/messages` and whether `/v1/models` is gated | medium | M-pre T6 | Assert 401 OR 403; warn (not fail) if `/v1/models` is ungated. |
| CLIProxyAPI forwards `retry-after`/`x-ratelimit-reset-after` headers + their casing | **low** | M11 T3 | Case-insensitive lookup; exponential backoff is the fallback; confirm on first live observation. |
| Exact subscription-window message wording + HTTP status (400 vs 429) | medium | M11 T3 (first live) | Tune `USAGE_WINDOW_PATTERNS`; match decoded + raw body. |
| Whether CLIProxyAPI passes an absent `thinking` field through unchanged to Opus 4.8 | medium | M2/M6 (first live) | Contract omits it (correct, non-400 path); low practical risk. |
| `Vector2.new/.X/.Y` (not on the fetched doc page) | medium→ verify at runtime | M3 T2 | Symmetric with Vector3; round-trip in SerializeSpec. |
| Exact catalog property names (`MeshPart.TextureID`, `Decal.Color3`, `BasePart.Color`) | medium | M7 T2 | Cross-check spelling/casing against create.roblox.com when implementing PropertyCatalog. |

All high-confidence APIs (RequestAsync request/response shape + bimodal errors, JSONEncode/JSONDecode behavior, Plugin:CreateToolbar/CreateButton/SetSetting/GetSetting, CreateDockWidgetPluginGuiAsync + DockWidgetPluginGuiInfo.new 7-arg order, ChangeHistoryService TryBeginRecording/FinishRecording + FinishRecordingOperation Cancel=0/Commit=1/Append=2 + IsRecordingInProgress, FindFirstChild/GetChildren/GetDescendants/IsA, CFrame 12-arg ↔ GetComponents order, UDim2/UDim/Color3/Vector3 accessors, the Anthropic Messages tool loop + tool_result schema + stop_reason set, model ids, the Rojo `$path`-only project form) were verified by the cluster reviewers and need no re-confirmation, only correct use per the cross-cutting decisions above.