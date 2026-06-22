--!strict
-- Relay: lets the agent work in the Play CLIENT view without switching to the Server view.
-- Accurate Play Solo runs SEPARATE per-context plugin copies (LIVE-VERIFIED 2026-06-18): a SERVER
-- copy whose in-session HttpService + Instance.new builds work, and a CLIENT copy that hosts the
-- panel the user sees in client view. A plugin in the CLIENT copy CAN call a server-created
-- RemoteFunction:InvokeServer and receive its return (proven). So:
--   * the SERVER copy hosts a RemoteFunction "StudioAgentRelay"; its OnServerInvoke runs the two
--     server-only operations on the authoritative server DM — the Anthropic HTTP send, and the
--     DataModel/HTTP/loop-spawning tool dispatches;
--   * the CLIENT copy's loop relays exactly those two through InvokeServer, and runs plugin-only
--     tools (update_tasks/remember/forget/skills) LOCALLY.
-- Plugin-only + ephemeral (created at play-start, discarded on Stop -> never saved), so it can never
-- leak to a published game. Falls back to today's "switch to the Server view" if the RF isn't found.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Relay = {}

-- The relay RemoteFunction name in ReplicatedStorage (replicates server->client during play).
local RELAY_RF_NAME = "StudioAgentRelay"
-- How long the client copy waits for the RF to replicate before falling back.
local WAIT_TIMEOUT = 10

-- Tools that touch ONLY plugin/panel state (no DataModel, no HTTP, no child loops) -> run LOCALLY in
-- the client copy. Everything else (DataModel/HTTP/dispatch tools) relays to the server copy.
local LOCAL_TOOLS: { [string]: boolean } = {
	update_tasks = true,
	remember = true,
	forget = true,
	use_skill = true,
	save_skill = true,
	delete_skill = true,
	use_rubric = true,
	evaluate = true,
	learn = true,
	unlearn = true,
	camera_focus = true,
	camera_orbit = true,
	camera_release = true,
}

-- "edit" | "serverplay" | "clientplay" | "other". IsEdit() FIRST: edit reports IsServer=true AND
-- IsClient=true, so it must be classified before the play checks.
function Relay.mode(): string
	if RunService:IsEdit() then
		return "edit"
	end
	if RunService:IsRunning() and RunService:IsStudio() then
		if RunService:IsServer() and not RunService:IsClient() then
			return "serverplay"
		end
		if RunService:IsClient() and not RunService:IsServer() then
			return "clientplay"
		end
	end
	return "other"
end

-- A tool relays to the server unless it is plugin/panel-state-only.
function Relay.shouldRelayTool(name: string): boolean
	return not LOCAL_TOOLS[name]
end

-- SERVER play copy: create the relay RemoteFunction and set its dispatcher. Total (never throws);
-- returns the RF, or nil on failure. Runs fresh each play start (fresh play DM each time).
function Relay.startHost(deps: any): any?
	-- Lazy require (Tools is already loaded by init time; avoids any load-order surprise).
	local Tools = require(script.Parent.Tools)

	local ok, rf = pcall(function()
		local existing = ReplicatedStorage:FindFirstChild(RELAY_RF_NAME)
		if existing ~= nil and existing:IsA("RemoteFunction") then
			return existing
		end
		local r = Instance.new("RemoteFunction")
		r.Name = RELAY_RF_NAME
		r.Parent = ReplicatedStorage
		return r
	end)
	if not ok or rf == nil then
		return nil
	end

	-- Server-side tool context = the server copy's own config/anthropic. update_tasks/remember/forget/
	-- skills never relay, so no taskList/memory/skills here (relayed dispatch nil-guards them like the
	-- subagent children already do).
	local serverToolContext = { config = deps.config, anthropic = deps.anthropic }

	local remote = rf :: RemoteFunction
	remote.OnServerInvoke = function(_player, request)
		-- Total: a thrown handler returns a structured error instead of erroring InvokeServer.
		local ok2, result = pcall(function()
			if type(request) ~= "table" then
				return { kind = "error", message = "relay: malformed request" }
			end
			if request.kind == "http" then
				return { kind = "http", result = deps.anthropic:sendMessage(request.opts) }
			elseif request.kind == "tool" then
				local content, isError =
					Tools.dispatch(request.name, request.input, serverToolContext)
				return { kind = "tool", content = content, isError = isError }
			end
			return {
				kind = "error",
				message = "relay: unknown request kind " .. tostring(request.kind),
			}
		end)
		if ok2 then
			return result
		end
		return { kind = "error", message = "relay handler error: " .. tostring(result) }
	end

	return remote
end

-- Interpret a raw InvokeServer outcome for the HTTP relay into an Anthropic.Result. Three cases:
--   * ok + {kind="http", result=<Result>}  -> the server's Result, passed straight through (so a
--     transient server-side HTTP failure still flows to Retry and is retried);
--   * ok + {kind="error", message}          -> the relay DELIVERED but the server op threw (a bug,
--     not transient): surface the real message as kind="relay" (Retry won't retry -> aborts cleanly);
--   * anything else (InvokeServer threw / RF gone / malformed) -> the relay TRANSPORT is broken, so
--     kind="context" gives the existing "switch to the Server view" guidance.
function Relay.unwrapHttp(ok: boolean, res: any): any
	if ok and type(res) == "table" and res.kind == "http" and type(res.result) == "table" then
		return res.result
	end
	if ok and type(res) == "table" and res.kind == "error" then
		return { ok = false, kind = "relay", message = "relay error: " .. tostring(res.message) }
	end
	return {
		ok = false,
		kind = "context",
		message = "relay unavailable — switch Studio to the Server view (Client/Server dropdown).",
	}
end

-- Interpret a raw InvokeServer outcome for the tool relay into (content, isError). A normal tool
-- error already arrives as {kind="tool", isError=true} (Tools.dispatch is total) and passes through;
-- an {kind="error"} envelope (server handler threw) surfaces the real message as an is_error result;
-- a broken transport falls back to the "switch to the Server view" guidance.
function Relay.unwrapTool(ok: boolean, res: any): (any, boolean)
	if ok and type(res) == "table" and res.kind == "tool" then
		return res.content, res.isError == true
	end
	if ok and type(res) == "table" and res.kind == "error" then
		return "relay tool error: " .. tostring(res.message), true
	end
	return "relay unavailable — switch Studio to the Server view to run this.", true
end

-- CLIENT play copy: find the relay RF (waits up to WAIT_TIMEOUT for it to replicate). Returns a
-- client table with `http`/`tool` (dot-called, no self), or nil if the RF never appeared (caller then
-- leaves the real anthropic in place so the existing client-context error guides the user).
function Relay.newClient(): any?
	local rf = ReplicatedStorage:WaitForChild(RELAY_RF_NAME, WAIT_TIMEOUT)
	if rf == nil or not rf:IsA("RemoteFunction") then
		return nil
	end
	local remote = rf :: RemoteFunction
	local client = {}

	-- HTTP relay -> an Anthropic.Result (see Relay.unwrapHttp for the success/error/transport cases).
	function client.http(opts: any): any
		local ok, res = pcall(function()
			return remote:InvokeServer({ kind = "http", opts = opts })
		end)
		return Relay.unwrapHttp(ok, res)
	end

	-- Tool relay -> (content, isError). See Relay.unwrapTool for the cases.
	function client.tool(name: string, input: any): (any, boolean)
		local ok, res = pcall(function()
			return remote:InvokeServer({ kind = "tool", name = name, input = input })
		end)
		return Relay.unwrapTool(ok, res)
	end

	return client
end

-- A relay-aware `anthropic` drop-in: Retry + Compactor only call `anthropic:sendMessage(opts)`, so we
-- only need sendMessage. It routes the call through the relay client's http(); the SERVER copy then
-- builds the body (model/max_tokens) and applies the empty-object {} encode fix.
function Relay.wrapAnthropic(client: any): any
	local wrapped = {}
	function wrapped.sendMessage(_self: any, opts: any): any
		return client.http(opts)
	end
	return wrapped
end

return Relay
