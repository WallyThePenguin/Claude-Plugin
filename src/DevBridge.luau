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

-- Run-context banner prepended to a tool/luau/prompt result when a REAL PLAYTEST is active (IsRunning)
-- or this isn't the edit DataModel — the contexts where edit-style bridge builds/captures misbehave.
-- IMPORTANT: Team Create edit is GENUINE edit (it connects as a CLIENT, so IsServer=false/IsClient=true
-- with a collaborator LocalPlayer present, but IsEdit=true/IsRunning=false) and must NOT warn — an
-- earlier LocalPlayer-based signal false-positived on exactly that. The real "beware" signal is
-- IsRunning. Guards the /agent channel only; the deliberate /play (PlayBridge) flow is a separate stone.
-- Pure (flags in -> string out), unit-tested; "" = clean/edit (incl. Team Create).
function DevBridge.contextBanner(
	isEdit: boolean,
	isRunning: boolean,
	isServer: boolean,
	isClient: boolean
): string
	if isEdit and not isRunning then
		return ""
	end
	local why: { string } = {}
	if isRunning then
		table.insert(why, "a PLAYTEST is active")
	end
	if not isEdit then
		table.insert(why, "this is NOT the edit DataModel")
	end
	local role = if isServer and isClient
		then "server+client"
		elseif isServer then "server"
		elseif isClient then "client"
		else "unknown"
	return "[WARN run-context: "
		.. (if #why > 0 then table.concat(why, " + ") else "non-edit")
		.. " (role="
		.. role
		.. "). A playtest is live, so edit-style bridge builds aren't in the rendered view and captures "
		.. "show the play client; a GUI built in a server DataModel does NOT render. VERIFY with a capture "
		.. "you actually look at before trusting structure.]\n"
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
		buildGuides = deps.buildGuides,
		cameraRig = deps.cameraRig,
		learnings = deps.learnings,
	}
end

local function postResult(deps: any, id: number, result: any)
	result.id = id
	httpPostJson(sidecarUrl(deps) .. "/agent/result", result)
end

-- Read the live run context and render the warning banner (impure wrapper over the pure contextBanner).
local function runContextBanner(): string
	return DevBridge.contextBanner(
		RunService:IsEdit(),
		RunService:IsRunning(),
		RunService:IsServer(),
		RunService:IsClient()
	)
end

-- Run one command and POST its result. Total (caller pcall-wraps anyway).
local function handleCommand(deps: any, cmd: any)
	local kind = tostring(cmd.kind)
	local banner = runContextBanner()
	if kind == "tool" then
		local content, isError = Tools.dispatch(tostring(cmd.tool), cmd.input, toolContext(deps))
		if cmd.raw == true then
			-- Raw mode (the sidecar-side loop runner): post the tool's content UNSERIALIZED —
			-- a string, or the structured blocks array (text + base64 images) exactly as the
			-- in-Luau loop would hand it to the model. The banner rides as a separate field so
			-- the runner can prepend it as a text block.
			postResult(deps, cmd.id, {
				ok = not isError,
				isError = isError,
				content = content,
				banner = banner,
			})
			return
		end
		postResult(deps, cmd.id, {
			ok = not isError,
			result = banner .. DevBridge.serializeContent(content),
			logs = Logs.recent(40),
		})
	elseif kind == "narrate" then
		-- Live commentary channel: the sidecar loops post their decisions/stages here so the
		-- user can WATCH the factory think in Studio's Output window. Never fails.
		local text = "[Factory] " .. tostring(cmd.text or "")
		if cmd.warn == true then
			warn(text)
		else
			print(text)
		end
		postResult(deps, cmd.id, { ok = true, result = "narrated" })
	elseif kind == "luau" then
		local content, isError =
			Tools.dispatch("run_luau", { code = tostring(cmd.code) }, toolContext(deps))
		postResult(deps, cmd.id, {
			ok = not isError,
			result = banner .. DevBridge.serializeContent(content),
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
			deps.buildGuides,
			deps.cameraRig,
			deps.learnings,
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
			reply = banner .. result.reply,
			tools = result.tools,
			error = result.error,
		})
	elseif kind == "describe" then
		-- Everything the sidecar-side loop runner needs to BE the agent loop: the composed
		-- operating instructions (identical to what runLoop sends as the leading preamble),
		-- the full tool schema list, and the model/proxy settings. Localhost-only channel —
		-- the proxy key never leaves this machine.
		postResult(deps, cmd.id, {
			ok = true,
			instructions = AgentLoop.composeInstructions(
				deps.systemPrompt,
				deps.memory,
				deps.skills,
				deps.rubrics,
				deps.buildGuides,
				deps.learnings
			),
			tools = Tools.schemas(deps.config),
			baseUrl = deps.config:getBaseUrl(),
			proxyKey = deps.config:getProxyKey(),
			model = deps.config:getModel(),
			maxTokens = deps.config:getMaxTokens(),
			maxIterations = deps.config:getMaxIterations(),
			imagesKept = deps.config:getImagesKept(),
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

-- Start the bridge. No-op unless EDIT mode AND config.devBridge. Localhost-only, plugin-only. The loop
-- belongs to a generation: it checks `lifecycle.cancelled` each tick and exits when a hot-reload swaps in
-- a new generation, so reloads never leave a second loop polling.
function DevBridge.start(deps: any, lifecycle: any)
	if not RunService:IsEdit() then
		return
	end
	if not deps.config:getDevBridge() then
		return
	end
	task.spawn(function()
		print("[StudioAgent] dev bridge active (sidecar " .. sidecarUrl(deps) .. ")")
		while not lifecycle.cancelled do
			pcall(tick, deps)
			task.wait(deps.config:getDevBridgePollInterval())
		end
		print("[StudioAgent] dev bridge loop stopped (generation reloaded)")
	end)
end

return DevBridge
