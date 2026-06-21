# Dev Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Claude Code drive the in-Studio plugin from the shell — execute exact tool calls / raw Luau (I'm the brain), drive the in-Studio agent with a prompt, read Output, and pull captures — all over the existing localhost sidecar, no computer-use.

**Architecture:** The sidecar (Python) gains an in-memory command/result/logs store. The plugin runs an EDIT-only poll loop (`DevBridge.luau`) that pushes recent `Logs` each tick and pulls a queued command: `tool` → `Tools.dispatch`, `luau` → the `run_luau` tool, `prompt` → `AgentLoop.send` on the shared conversation with a capturing callback. A PowerShell CLI (`studio-agent.ps1`) POSTs a command and polls the result.

**Tech Stack:** Python 3 (stdlib only, like the existing sidecar — Python IS runnable here, so the sidecar gets real tests), Luau (`--!strict`) for the plugin, PowerShell for the CLI. Plugin verification is `selene`/`stylua`/`rojo build` + the in-Studio `DevBridgeSpec`; the true end-to-end test is **dogfooding it to finish slice B**.

**Source of truth:** [`docs/superpowers/specs/2026-06-21-studio-agent-dev-bridge-design.md`](../specs/2026-06-21-studio-agent-dev-bridge-design.md).

---

## File structure

| File | New/Mod | Responsibility |
|---|---|---|
| `sidecar/bridge.py` | new | PURE in-memory `Store` (submit/take_pending/put_result/get_result/set_logs/get_logs), thread-safe. No HTTP — unit-tested. |
| `sidecar/test_bridge.py` | new | Plain-Python tests for `Store` (runnable: `python sidecar/test_bridge.py`). |
| `sidecar/server.py` | mod | Instantiate one `Store`; add `do_POST` + new GET routes; keep `GET /captures`. |
| `src/DevBridge.luau` | new | PURE helpers (`serializeContent`, `newResult`, `accumulate`) + the EDIT-only poll loop (`start`) with HTTP + dispatch. |
| `src/DevBridgeSpec.luau` | new | In-Studio self-test for the pure helpers (mirrors `RigWorkbenchSpec`). |
| `src/Config.luau` | mod | `devBridge` (default true) + `devBridgePollInterval` (1.5) — DEFAULTS, validators, getters. |
| `src/init.server.luau` | mod | `DevBridge.start(deps)` after deps are built. |
| `scripts/studio-agent.ps1` | new | CLI: `tool` / `luau` / `prompt` / `logs` / `capture`. |

### Reference signatures (from the codebase — match these exactly)

- `Tools.dispatch(name: string, input: any, context: any) -> (content, isError)` — `content` is a string or a blocks array; `context = {config, anthropic, taskList, memory, skills, rubrics, cameraRig}` ([Tools/init.luau](../../../src/Tools/init.luau)).
- `AgentLoop.send(anthropic, config, systemPrompt, conversation, taskList, memory, skills, rubrics, cameraRig, userText, cb, relay)` — `cb = {onEvent(event,data), shouldCancel()}`; events: `assistant_text`(string), `tool_result`({name,isError,text}), `error`({kind,message} or string), `done`({stop}) ([AgentLoop.luau](../../../src/AgentLoop.luau)).
- `Logs.recent(limit: number?, errorsOnly: boolean?) -> { {kind,text} }` ([Logs.luau](../../../src/Logs.luau)).
- HTTP: `HttpService:RequestAsync({Url, Method, Headers?, Body?})` in a `pcall`, check `res.Success`/`res.StatusCode`/`res.Body`, `HttpService:JSONDecode(res.Body)` (pattern from [CaptureCore.luau](../../../src/Tools/CaptureCore.luau)).
- `deps` (from init.server): `{config, anthropic, agentLoop, systemPrompt, conversation, sessions, taskList, memory, skills, rubrics, cameraRig, relay?}`.

---

## Task 1: Sidecar command/result/logs store (pure, tested)

**Files:**
- Create: `sidecar/bridge.py`
- Create: `sidecar/test_bridge.py`

- [ ] **Step 1: Write the test (`sidecar/test_bridge.py`)**

```python
"""Tests for the dev-bridge Store. Run: python sidecar/test_bridge.py (no pytest needed)."""
from bridge import Store


def test_submit_returns_increasing_ids():
    s = Store()
    assert s.submit({"kind": "tool", "tool": "x"}) == 1
    assert s.submit({"kind": "luau", "code": "y"}) == 2


def test_take_pending_returns_then_clears():
    s = Store()
    i = s.submit({"kind": "tool", "tool": "x"})
    cmd = s.take_pending()
    assert cmd["id"] == i and cmd["tool"] == "x"
    assert s.take_pending() is None  # slot cleared


def test_put_and_get_result():
    s = Store()
    s.put_result(7, {"ok": True, "result": "done"})
    assert s.get_result(7) == {"ok": True, "result": "done"}
    assert s.get_result(8) is None


def test_set_and_get_logs():
    s = Store()
    assert s.get_logs() == []
    s.set_logs([{"kind": "output", "text": "hi"}])
    assert s.get_logs() == [{"kind": "output", "text": "hi"}]


def test_submit_overwrites_single_slot():
    s = Store()
    s.submit({"kind": "tool", "tool": "a"})
    s.submit({"kind": "tool", "tool": "b"})
    assert s.take_pending()["tool"] == "b"  # latest wins (single-flight)


if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    passed = 0
    for fn in fns:
        try:
            fn()
            print(f"PASS {fn.__name__}")
            passed += 1
        except AssertionError as e:
            print(f"FAIL {fn.__name__}: {e}")
    print(f"{passed}/{len(fns)} passed")
    raise SystemExit(0 if passed == len(fns) else 1)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python sidecar/test_bridge.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'bridge'` (run from the `sidecar/` dir) or import error.

- [ ] **Step 3: Write `sidecar/bridge.py`**

```python
"""Dev-bridge state for the Studio Agent sidecar: a thread-safe in-memory command queue (single slot,
single-flight to match the agent loop), a results map, and the latest pushed Output logs. Pure stdlib."""

import threading


class Store:
    def __init__(self):
        self._lock = threading.Lock()
        self._counter = 0
        self._pending = None  # the one queued command, or None
        self._results = {}     # id -> result dict
        self._logs = []        # latest pushed log entries

    def submit(self, command: dict) -> int:
        """Queue a command (overwriting any unclaimed one — single-flight). Returns its id."""
        with self._lock:
            self._counter += 1
            cmd = dict(command)
            cmd["id"] = self._counter
            self._pending = cmd
            return self._counter

    def take_pending(self):
        """Return the queued command and clear the slot, or None if empty."""
        with self._lock:
            cmd = self._pending
            self._pending = None
            return cmd

    def put_result(self, command_id: int, result: dict):
        with self._lock:
            self._results[int(command_id)] = result

    def get_result(self, command_id: int):
        with self._lock:
            return self._results.get(int(command_id))

    def set_logs(self, lines: list):
        with self._lock:
            self._logs = lines or []

    def get_logs(self) -> list:
        with self._lock:
            return list(self._logs)
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd sidecar && python test_bridge.py` (or `python -m pytest sidecar/test_bridge.py -v` if pytest is present)
Expected: `5/5 passed`.

- [ ] **Step 5: Commit**

```bash
git add sidecar/bridge.py sidecar/test_bridge.py
git commit -m "feat: dev-bridge sidecar Store (command queue + results + logs) + tests" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Wire the store into the sidecar HTTP server

**Files:**
- Modify: `sidecar/server.py`

- [ ] **Step 1: Replace `sidecar/server.py` with the store-wired version**

```python
"""Studio Agent sidecar — localhost-only capture-file server + dev bridge.

GET  /captures?count=N&since=<epoch>[&b64=1]  -> {"images":[...],"returned":N,"shortfall":bool}
POST /agent      {"kind":"tool"|"luau"|"prompt", ...}     -> {"id":N}
GET  /agent/pending                                       -> the queued command (and clears it) or {}
POST /agent/result {"id":N, ...result}                    -> {"ok":true}
GET  /agent/result?id=N                                   -> the result, or {"status":"pending"}
POST /logs        {"lines":[...]}                          -> {"ok":true}
GET  /logs                                                 -> {"lines":[...]}

Bind is 127.0.0.1 ONLY — the only trust boundary. No auth. Pure standard library.
"""

import base64
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import capture
from bridge import Store

PORT = int(os.environ.get("SIDECAR_PORT", "8389"))
STORE = Store()


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, content_type: str, body: bytes):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code: int, obj):
        self._send(code, "application/json", json.dumps(obj).encode())

    def _read_json(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return None

    def do_GET(self):
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)

        if parsed.path == "/captures":
            return self._captures(qs)
        if parsed.path == "/agent/pending":
            return self._json(200, STORE.take_pending() or {})
        if parsed.path == "/agent/result":
            try:
                cid = int(qs.get("id", ["0"])[0])
            except ValueError:
                return self._json(400, {"error": "bad id"})
            result = STORE.get_result(cid)
            return self._json(200, result if result is not None else {"status": "pending"})
        if parsed.path == "/logs":
            return self._json(200, {"lines": STORE.get_logs()})
        return self._json(404, {"error": "not found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        body = self._read_json()
        if body is None:
            return self._json(400, {"error": "bad json"})

        if parsed.path == "/agent":
            kind = body.get("kind")
            if kind not in ("tool", "luau", "prompt"):
                return self._json(400, {"error": "kind must be tool|luau|prompt"})
            return self._json(200, {"id": STORE.submit(body)})
        if parsed.path == "/agent/result":
            cid = body.get("id")
            if not isinstance(cid, int):
                return self._json(400, {"error": "result needs an integer id"})
            STORE.put_result(cid, body)
            return self._json(200, {"ok": True})
        if parsed.path == "/logs":
            STORE.set_logs(body.get("lines", []))
            return self._json(200, {"ok": True})
        return self._json(404, {"error": "not found"})

    def _captures(self, qs):
        try:
            count = int(qs.get("count", ["1"])[0])
            since = float(qs.get("since", ["0"])[0])
        except ValueError:
            return self._json(400, {"error": "bad count/since"})
        try:
            pngs = capture.newest_captures(count, since_ts=since)
        except Exception as exc:  # noqa: BLE001
            return self._json(500, {"error": str(exc)})
        images = [base64.b64encode(p).decode("ascii") for p in pngs]
        self._json(200, {"images": images, "returned": len(images), "shortfall": len(images) < count})

    def log_message(self, *args):  # silence default stderr access logging
        pass


def main():
    print(f"Studio Agent sidecar listening on http://127.0.0.1:{PORT}")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Integration-test the routes against a live server**

Run (from `sidecar/`):
```bash
SIDECAR_PORT=8390 python server.py &   # background; use a spare port so it won't clash with the real sidecar on 8389
sleep 1
curl -s -XPOST localhost:8390/agent -d '{"kind":"tool","tool":"get_tree","input":{}}'   # -> {"id": 1}
curl -s localhost:8390/agent/pending                                                     # -> {"kind":"tool",...,"id":1}
curl -s localhost:8390/agent/pending                                                     # -> {}   (cleared)
curl -s -XPOST localhost:8390/agent/result -d '{"id":1,"ok":true,"result":"hi"}'         # -> {"ok": true}
curl -s "localhost:8390/agent/result?id=1"                                               # -> {"id":1,"ok":true,"result":"hi"}
curl -s "localhost:8390/agent/result?id=99"                                              # -> {"status":"pending"}
curl -s -XPOST localhost:8390/logs -d '{"lines":[{"kind":"output","text":"hi"}]}'        # -> {"ok": true}
curl -s localhost:8390/logs                                                              # -> {"lines":[{"kind":"output","text":"hi"}]}
kill %1
```
Expected: each line returns the commented JSON. (On Windows the Bash tool provides `curl`; `&`/`%1` work under Git Bash.)

- [ ] **Step 3: Commit**

```bash
git add sidecar/server.py
git commit -m "feat: dev-bridge sidecar routes (/agent, /agent/pending, /agent/result, /logs)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Config flags

**Files:**
- Modify: `src/Config.luau`

- [ ] **Step 1: Add the defaults**

In the `DEFAULTS` table (after the `cameraRigDebug = false,` line), add:

```lua
	-- Dev bridge (DevBridge.luau): lets Claude Code drive the plugin from the shell via the sidecar.
	-- EDIT-only + localhost-only, so default-on (nothing to toggle); set false to disable.
	devBridge = true,
	devBridgePollInterval = 1.5, -- seconds between bridge poll ticks
```

- [ ] **Step 2: Add the validators**

In `Config.set`, before the final `self._plugin:SetSetting(...)`, add two branches (after the `cameraRigDebug` branch):

```lua
	elseif key == "devBridge" then
		if type(value) ~= "boolean" then
			return false, "devBridge must be a boolean"
		end
	elseif key == "devBridgePollInterval" then
		if type(value) ~= "number" or value ~= value or value < 0.25 then
			return false, "devBridgePollInterval must be a number >= 0.25"
		end
```

- [ ] **Step 3: Add the getters**

After `Config.getCameraRigDebug`, add:

```lua
function Config.getDevBridge(self: Config): boolean
	return self:get("devBridge") :: boolean
end

function Config.getDevBridgePollInterval(self: Config): number
	return self:get("devBridgePollInterval") :: number
end
```

- [ ] **Step 4: Static-verify**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm ; echo done`
Expected: selene `0 errors, 0 warnings`; rojo build succeeds.

- [ ] **Step 5: Commit**

```bash
git add src/Config.luau
git commit -m "feat: Config devBridge + devBridgePollInterval flags" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: DevBridge pure helpers + spec

**Files:**
- Create: `src/DevBridge.luau`
- Create: `src/DevBridgeSpec.luau`

- [ ] **Step 1: Write `src/DevBridge.luau` with the pure helpers only**

```lua
--!strict
-- DevBridge: lets Claude Code (the shell) drive the plugin over the localhost sidecar instead of
-- computer-use. EDIT-only poll loop: each tick pushes recent Output logs and pulls one queued command —
-- `tool` (Tools.dispatch), `luau` (the run_luau tool), or `prompt` (AgentLoop.send on the shared
-- conversation). Pure helpers (serialize/accumulate) are unit-tested in DevBridgeSpec; the loop + HTTP
-- are live-verified. See the dev-bridge design spec. Localhost-only, plugin-only, never in a shipped game.

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Tools = require(script.Parent.Tools)
local AgentLoop = require(script.Parent.AgentLoop)
local Logs = require(script.Parent.Logs)

local DevBridge = {}

export type Result = { reply: string, tools: { any }, error: string?, done: boolean }

-- Tool/Luau content -> a string for the shell. A blocks array (e.g. capture's image) is summarized;
-- fetch the actual PNG via GET /captures.
function DevBridge.serializeContent(content: any): string
	if type(content) == "string" then
		return content
	end
	if type(content) == "table" then
		return "[non-text tool content (e.g. a viewport capture) — fetch it via GET /captures]"
	end
	return tostring(content)
end

function DevBridge.newResult(): Result
	return { reply = "", tools = {}, error = nil, done = false }
end

-- Fold one AgentLoop event into a prompt-mode result (used as the capturing callback's body).
function DevBridge.accumulate(result: Result, event: string, data: any)
	if event == "assistant_text" then
		local text = tostring(data)
		result.reply = if result.reply == "" then text else result.reply .. "\n" .. text
	elseif event == "tool_result" then
		local d = if type(data) == "table" then data else {}
		table.insert(result.tools, {
			name = tostring(d.name),
			isError = d.isError == true,
			text = tostring(d.text),
		})
	elseif event == "error" then
		result.error = if type(data) == "table" then tostring(data.message) else tostring(data)
		result.done = true
	elseif event == "done" then
		result.done = true
	end
end

return DevBridge
```

- [ ] **Step 2: Write `src/DevBridgeSpec.luau`**

```lua
--!strict
-- DevBridgeSpec: in-Studio self-test for the PURE DevBridge helpers. Run via temporarily adding
-- `require(script.DevBridgeSpec).run()` to init.server.luau, build, reopen Studio, read Output.

local DevBridge = require(script.Parent.DevBridge)

local M = {}

type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("serializeContent passes a string through", function()
		return DevBridge.serializeContent("hello") == "hello"
	end)

	add("serializeContent summarizes a blocks array", function()
		local s = DevBridge.serializeContent({ { type = "image" } })
		return string.find(s, "GET /captures", 1, true) ~= nil
	end)

	add("accumulate joins assistant_text and records tool_result", function()
		local r = DevBridge.newResult()
		DevBridge.accumulate(r, "assistant_text", "line1")
		DevBridge.accumulate(r, "assistant_text", "line2")
		DevBridge.accumulate(r, "tool_result", { name = "ik_reach", isError = false, text = "ok" })
		return r.reply == "line1\nline2"
			and #r.tools == 1
			and r.tools[1].name == "ik_reach"
			and r.tools[1].isError == false
			and not r.done
	end)

	add("accumulate marks done on done", function()
		local r = DevBridge.newResult()
		DevBridge.accumulate(r, "done", { stop = "end_turn" })
		return r.done and r.error == nil
	end)

	add("accumulate captures an error and marks done", function()
		local r = DevBridge.newResult()
		DevBridge.accumulate(r, "error", { kind = "busy", message = "agent already running" })
		return r.done and r.error == "agent already running"
	end)

	return cases
end

function M.run(): boolean
	local cases = buildCases()
	local passed = 0
	for _, c in ipairs(cases) do
		local ok, err = c.fn()
		if ok then
			passed += 1
			print("[DevBridgeSpec] PASS " .. c.name)
		else
			warn("[DevBridgeSpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[DevBridgeSpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
```

- [ ] **Step 3: Static-verify**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm ; echo done`
Expected: selene `0 errors, 0 warnings`; rojo build succeeds.

- [ ] **Step 4: Commit**

```bash
git add src/DevBridge.luau src/DevBridgeSpec.luau
git commit -m "feat: DevBridge pure helpers (serialize/accumulate) + spec" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: DevBridge poll loop + HTTP + dispatch

**Files:**
- Modify: `src/DevBridge.luau` (add the impure loop before `return DevBridge`)

- [ ] **Step 1: Add the HTTP helpers, dispatch, and `start` (insert before `return DevBridge`)**

```lua
-- ---- the impure poll loop (EDIT-only; live-verified) ----

local function sidecarUrl(deps: any): string
	return deps.config:getSidecarUrl()
end

-- GET a JSON object from the sidecar. Returns (table, nil) or (nil, errString). Never throws.
local function httpGetJson(url: string): (any?, string?)
	local ok, res = pcall(function()
		return HttpService:RequestAsync({ Url = url, Method = "GET" })
	end)
	if not ok then
		return nil, tostring(res)
	end
	local r = res :: any
	if not r.Success then
		return nil, "HTTP " .. tostring(r.StatusCode)
	end
	local okDecode, payload = pcall(function()
		return HttpService:JSONDecode(r.Body)
	end)
	if not okDecode then
		return nil, "bad json"
	end
	return payload, nil
end

-- POST a JSON body to the sidecar. Best-effort; returns nothing (failures are swallowed).
local function httpPostJson(url: string, body: any)
	pcall(function()
		HttpService:RequestAsync({
			Url = url,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = HttpService:JSONEncode(body),
		})
	end)
end

local function toolContext(deps: any): any
	return {
		config = deps.config,
		anthropic = deps.anthropic,
		taskList = deps.taskList,
		memory = deps.memory,
		skills = deps.skills,
		rubrics = deps.rubrics,
		cameraRig = deps.cameraRig,
	}
end

local function postResult(deps: any, id: number, result: any)
	result.id = id
	httpPostJson(sidecarUrl(deps) .. "/agent/result", result)
end

-- Run one command and POST its result. Total (caller pcall-wraps anyway).
local function handleCommand(deps: any, cmd: any)
	local kind = tostring(cmd.kind)
	if kind == "tool" then
		local content, isError = Tools.dispatch(tostring(cmd.tool), cmd.input, toolContext(deps))
		postResult(deps, cmd.id, {
			ok = not isError,
			result = DevBridge.serializeContent(content),
			logs = Logs.recent(40),
		})
	elseif kind == "luau" then
		local content, isError =
			Tools.dispatch("run_luau", { code = tostring(cmd.code) }, toolContext(deps))
		postResult(deps, cmd.id, {
			ok = not isError,
			result = DevBridge.serializeContent(content),
			logs = Logs.recent(40),
		})
	elseif kind == "prompt" then
		local result = DevBridge.newResult()
		local cb = {
			onEvent = function(event: string, data: any)
				DevBridge.accumulate(result, event, data)
			end,
			shouldCancel = function(): boolean
				return false
			end,
		}
		AgentLoop.send(
			deps.anthropic,
			deps.config,
			deps.systemPrompt,
			deps.conversation,
			deps.taskList,
			deps.memory,
			deps.skills,
			deps.rubrics,
			deps.cameraRig,
			tostring(cmd.prompt),
			cb,
			deps.relay
		)
		local deadline = os.clock() + 170
		while not result.done and os.clock() < deadline do
			RunService.Heartbeat:Wait()
		end
		if not result.done then
			result.error = "timed out waiting for the agent"
		end
		postResult(deps, cmd.id, {
			ok = result.error == nil,
			reply = result.reply,
			tools = result.tools,
			error = result.error,
		})
	else
		postResult(deps, cmd.id, { ok = false, error = "unknown command kind: " .. kind })
	end
end

-- One tick: push recent logs, then pull + run a queued command (if any).
local function tick(deps: any)
	httpPostJson(sidecarUrl(deps) .. "/logs", { lines = Logs.recent(80) })
	local pending = httpGetJson(sidecarUrl(deps) .. "/agent/pending")
	if type(pending) == "table" and type(pending.id) == "number" then
		handleCommand(deps, pending)
	end
end

-- Start the bridge. No-op unless EDIT mode AND config.devBridge. Localhost-only, plugin-only.
function DevBridge.start(deps: any)
	if not RunService:IsEdit() then
		return
	end
	if not deps.config:getDevBridge() then
		return
	end
	task.spawn(function()
		print("[StudioAgent] dev bridge active (sidecar " .. sidecarUrl(deps) .. ")")
		while true do
			pcall(tick, deps)
			task.wait(deps.config:getDevBridgePollInterval())
		end
	end)
end
```

- [ ] **Step 2: Static-verify**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm ; echo done`
Expected: selene `0 errors, 0 warnings`; rojo build succeeds.

- [ ] **Step 3: Commit**

```bash
git add src/DevBridge.luau
git commit -m "feat: DevBridge poll loop (tool/luau/prompt dispatch over the sidecar)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Wire into init.server

**Files:**
- Modify: `src/init.server.luau`

- [ ] **Step 1: Require DevBridge**

After `local Relay = require(script.Relay)` add:

```lua
local DevBridge = require(script.DevBridge)
```

- [ ] **Step 2: Start the bridge after the relay wiring**

After the `relayMode` block (the `if relayMode == "serverplay" ... end`) and before `local function ensureMounted()`, add:

```lua
-- Dev bridge: let Claude Code drive the plugin from the shell over the sidecar. EDIT-only + localhost-
-- only (DevBridge.start no-ops in play/published), default-on via config. Pass the shared deps so prompt
-- mode runs on the same conversation the panel shows.
DevBridge.start(deps)
```

- [ ] **Step 3: Static-verify**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm ; echo done`
Expected: selene `0 errors, 0 warnings`; rojo build succeeds.

- [ ] **Step 4: Commit**

```bash
git add src/init.server.luau
git commit -m "feat: start the dev bridge from init (edit-only)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: The `studio-agent.ps1` CLI

**Files:**
- Create: `scripts/studio-agent.ps1`

- [ ] **Step 1: Write `scripts/studio-agent.ps1`**

```powershell
# studio-agent.ps1 — drive the in-Studio plugin from the shell via the localhost sidecar (dev bridge).
# Usage:
#   .\studio-agent.ps1 tool <name> '<json-input>'   e.g. tool spawn_rig '{"type":"r15"}'
#   .\studio-agent.ps1 luau '<luau code>'
#   .\studio-agent.ps1 prompt '<text>'
#   .\studio-agent.ps1 logs
#   .\studio-agent.ps1 capture [outfile.png]
param(
    [Parameter(Mandatory = $true)][string]$Command,
    [string]$Arg1,
    [string]$Arg2
)
$ErrorActionPreference = "Stop"
$base = "http://127.0.0.1:8389"

function Submit-And-Wait($payload, $timeoutSec) {
    $body = $payload | ConvertTo-Json -Depth 20 -Compress
    $resp = Invoke-RestMethod -Method Post -Uri "$base/agent" -Body $body -ContentType "application/json"
    $id = $resp.id
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $r = Invoke-RestMethod -Method Get -Uri "$base/agent/result?id=$id"
        if ($r.PSObject.Properties.Name -contains "ok") { return $r }
    }
    return @{ ok = $false; error = "timed out waiting for a result (is Studio open with the bridge active?)" }
}

switch ($Command) {
    "tool" {
        $input = if ($Arg2) { $Arg2 | ConvertFrom-Json } else { @{} }
        $r = Submit-And-Wait @{ kind = "tool"; tool = $Arg1; input = $input } 30
        "ok=$($r.ok)"; $r.result; if ($r.error) { "ERROR: $($r.error)" }
    }
    "luau" {
        $r = Submit-And-Wait @{ kind = "luau"; code = $Arg1 } 30
        "ok=$($r.ok)"; $r.result; if ($r.error) { "ERROR: $($r.error)" }
    }
    "prompt" {
        $r = Submit-And-Wait @{ kind = "prompt"; prompt = $Arg1 } 180
        "ok=$($r.ok)"; "--- reply ---"; $r.reply
        if ($r.tools) { "--- tools ---"; $r.tools | ForEach-Object { "$($_.name) (isError=$($_.isError)): $($_.text)" } }
        if ($r.error) { "ERROR: $($r.error)" }
    }
    "logs" {
        $r = Invoke-RestMethod -Method Get -Uri "$base/logs"
        $r.lines | ForEach-Object { "[$($_.kind)] $($_.text)" }
    }
    "capture" {
        $out = if ($Arg1) { $Arg1 } else { Join-Path $env:TEMP "studio-agent-capture.png" }
        $r = Invoke-RestMethod -Method Get -Uri "$base/captures?count=1&b64=1"
        if ($r.returned -lt 1) { "no capture available — have the agent call capture/camera_focus first"; break }
        [IO.File]::WriteAllBytes($out, [Convert]::FromBase64String($r.images[0]))
        "saved $out"
    }
    default { "unknown command: $Command (use tool|luau|prompt|logs|capture)" }
}
```

- [ ] **Step 2: Smoke-test the CLI against a stub server (no Studio needed)**

Run (Bash tool):
```bash
cd sidecar && SIDECAR_PORT=8389 python server.py &
sleep 1
# pre-seed a result as if the plugin answered, then read it via the CLI's GET path:
curl -s -XPOST localhost:8389/agent -d '{"kind":"tool","tool":"ping","input":{}}' >/dev/null
curl -s localhost:8389/agent/pending >/dev/null
curl -s -XPOST localhost:8389/agent/result -d '{"id":1,"ok":true,"result":"pong"}' >/dev/null
powershell -File scripts/studio-agent.ps1 logs   # -> prints [] (no logs pushed) without error
kill %1
```
Expected: `studio-agent.ps1 logs` runs and prints nothing/empty without throwing (proves the CLI reaches the sidecar). Full `tool`/`prompt` paths need the plugin and are covered by the dogfood in Task 8.

- [ ] **Step 3: Commit**

```bash
git add scripts/studio-agent.ps1
git commit -m "feat: studio-agent.ps1 dev-bridge CLI (tool/luau/prompt/logs/capture)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Full verification + dogfood (finish slice B)

**Files:** none (verification only)

- [ ] **Step 1: Full static + sidecar tests**

Run:
```bash
cd sidecar && python test_bridge.py    # 5/5 passed
cd .. ; stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm
```
Expected: `5/5 passed`; selene `0 errors, 0 warnings`; rojo build succeeds.

- [ ] **Step 2: Build + install + (user) restart Studio**

Run `.\build.ps1` (installs to the Plugins folder). The sidecar must be running (`sidecar/dist/StudioAgentSidecar.exe` — REBUILD it first if `server.py`/`bridge.py` changed: `sidecar/build-exe.ps1`) and the tunnel up. The USER restarts Studio (its "Restart to update") on a fresh Baseplate so the new plugin + `DevBridge` load. Confirm Output shows `[StudioAgent] dev bridge active`.

- [ ] **Step 3: Dogfood — drive the bridge to verify itself**

Run (Bash/PowerShell):
```bash
powershell -File scripts/studio-agent.ps1 luau 'return 2+2'                  # -> ok=True, result mentions 4
powershell -File scripts/studio-agent.ps1 tool get_tree '{}'                 # -> ok=True, a Workspace tree
powershell -File scripts/studio-agent.ps1 logs                               # -> recent Output lines
```
Expected: each returns `ok=True` with real Studio data — proving Claude Code drives the plugin headlessly.

- [ ] **Step 4: Dogfood — finish slice B's live test through the bridge**

```bash
powershell -File scripts/studio-agent.ps1 tool spawn_rig '{"type":"r15"}'
powershell -File scripts/studio-agent.ps1 tool ik_reach '{"chain":"RightArm","target":{"x":1.5,"y":3.5,"z":2}}'   # read the residual line
powershell -File scripts/studio-agent.ps1 tool camera_focus '{"target":"Workspace.AgentRig_R15"}'
powershell -File scripts/studio-agent.ps1 capture                            # saves the PNG
```
Then Read the saved PNG and confirm: the right arm reaches the target, the elbow bends naturally, and the **pole sign** is correct (elbow back/down). If it bends the wrong way, flip the Z sign of `ARM_POLE`/`LEG_POLE` in `src/IkChains.luau`, rebuild, and re-test. Then fix the too-strict clamp tolerance in `src/InverseKinematicsSpec.luau` ("solve2Bone clamps…" — assert `s.upperDir:Dot(s.lowerDir) > 0.99` instead of `vClose(...,1e-2)`), and remove the temporary `require(script.InverseKinematicsSpec).run()` line from `init.server.luau`. Commit slice B as live-verified.

- [ ] **Step 5: Commit any dogfood fixes**

```bash
git add -A
git commit -m "fix: slice B live-verified via the dev bridge (pole sign + clamp tolerance)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-review (completed during plan authoring)

- **Spec coverage:** sidecar endpoints → Tasks 1–2; `DevBridge.luau` (tool/luau/prompt + poll + logs push) → Tasks 4–5; Config flags → Task 3; init wiring → Task 6; CLI (tool/luau/prompt/logs/capture) → Task 7; `DevBridgeSpec` → Task 4; security (edit-only/localhost) → Task 5 `start` guards + Task 2 bind; output contract → Task 5 `handleCommand`; dogfood/test → Task 8. All covered. (Deferred per spec "Out": auth, fresh-capture trigger, long-poll, playtest, deep queue — none implemented. The spec's optional "live-mirror prompt runs into the panel" is intentionally **not** in v1 — the conversation is shared so history carries, but the panel only re-renders on its own events; flagged as a follow-up, not a gap.)
- **Placeholder scan:** none; every code step is complete; the only "later" items are the spec's explicit non-goals.
- **Type/name consistency:** `Store` methods (`submit`/`take_pending`/`put_result`/`get_result`/`set_logs`/`get_logs`) match across `bridge.py`, `test_bridge.py`, and `server.py`. `DevBridge.serializeContent`/`newResult`/`accumulate`/`start` match across `DevBridge.luau`, `DevBridgeSpec.luau`, and the loop. Result shapes (`{ok,result,logs}` for tool/luau; `{ok,reply,tools,error}` for prompt) match between `handleCommand` and the CLI's printing. Routes match between `server.py`, `DevBridge.luau`, and `studio-agent.ps1` (all `http://127.0.0.1:8389`).
- **Known follow-ups (flagged, not silent):** rebuild `StudioAgentSidecar.exe` after the Python change (Task 8 Step 2); live-mirror prompt runs into the panel (deferred); the slice-B clamp-tolerance + temp-init-line cleanup ride in Task 8 Step 4.
