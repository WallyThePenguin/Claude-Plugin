--!strict
-- Playtest: the agent's own runtime feedback loop — playtest_start/act/eval/logs/capture/status/stop.
--
-- WHY: gameplay used to ship verified only by "no errors in edit"; the PlayBridge machinery could
-- run a real playtest but ONLY from the shell. These descriptors register that machinery as agent
-- tools, so the agent itself can start a Play Solo test, drive the character, probe ANY server
-- state (loadstring eval), tail stack-traced logs incrementally, SEE the play client, and stop.
--
-- MECHANISM (live-verified 2026-07-01): the edit-DM plugin KEEPS RUNNING during an
-- ExecutePlayModeAsync test — so these handlers simply drive the existing sidecar /play channel
-- (POST /play {cmd,arg} -> poll /play/result?id=), the exact pipeline studio-agent.ps1 uses. The
-- edit-side PlayBridge loop handles `start` (arg="run" boots ExecuteRunModeAsync instead — server
-- sim only, no player; SP2d); the injected in-test server script handles the rest
-- (act/seval/slog2/sdiag/capture via its client relay). No new transport.
--
-- This is a Tools/ submodule; CaptureCore (image fetch) via script.Parent.CaptureCore.

local HttpService = game:GetService("HttpService")

local CaptureCore = require(script.Parent.CaptureCore)

local Playtest = {}

export type Content = string | { any }

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (Content, boolean),
}

local ACT_VERBS = {
	equip = true,
	walk = true,
	walkstop = true,
	activate = true,
	camera = true,
	closecam = true,
	profilecam = true,
	record = true,
}

local POLL_INTERVAL = 0.4
local START_READY_TIMEOUT = 25

local function sidecarUrl(context: any): (string?, string?)
	if context == nil or context.config == nil then
		return nil, "playtest: internal error (no config available)"
	end
	return context.config:getSidecarUrl(), nil
end

-- POST one command to the sidecar /play channel and wait for its result.
--   returns (resultText, isError)
local function playCommand(
	context: any,
	cmd: string,
	arg: any,
	timeoutSec: number
): (string, boolean)
	local base, cfgErr = sidecarUrl(context)
	if base == nil then
		return tostring(cfgErr), true
	end
	local body: { [string]: any } = { cmd = cmd }
	if arg ~= nil then
		body.arg = arg
	end
	local okPost, postRes = pcall(function()
		return HttpService:RequestAsync({
			Url = base .. "/play",
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = HttpService:JSONEncode(body),
		})
	end)
	if not okPost then
		return "playtest: could not reach the sidecar at "
			.. base
			.. " — is it running? ("
			.. tostring(postRes)
			.. ")",
			true
	end
	local response = postRes :: any
	if not response.Success then
		return "playtest: sidecar HTTP " .. tostring(response.StatusCode), true
	end
	local okId, posted = pcall(function()
		return HttpService:JSONDecode(response.Body)
	end)
	if not okId or type(posted) ~= "table" or posted.id == nil then
		return "playtest: sidecar returned no command id", true
	end
	local id = tostring((posted :: any).id)

	local deadline = os.clock() + timeoutSec
	while os.clock() < deadline do
		local okGet, res = pcall(function()
			return HttpService:RequestAsync({
				Url = base .. "/play/result?id=" .. id,
				Method = "GET",
			})
		end)
		if okGet and (res :: any).Success then
			local okDec, payload = pcall(function()
				return HttpService:JSONDecode((res :: any).Body)
			end)
			if okDec and type(payload) == "table" and (payload :: any).ok ~= nil then
				local p = payload :: any
				local text = tostring(p.result or p.error or "")
				return text, p.ok ~= true
			end
		end
		task.wait(POLL_INTERVAL)
	end
	return "playtest: timed out after "
		.. tostring(timeoutSec)
		.. "s waiting for '"
		.. cmd
		.. "' (is a test running? playtest_status tells you)",
		true
end

-- ---- playtest_start ----

local function runStart(input: any, context: any): (Content, boolean)
	local args = if type(input) == "table" then input else {}
	local mode = tostring(args.mode or "play")
	if mode ~= "play" and mode ~= "run" then
		return "playtest_start: unknown mode '" .. mode .. "' (use play|run)", true
	end
	local ack, ackErr = playCommand(context, "start", mode, 15)
	if ackErr then
		if string.find(ack, "unknown play cmd", 1, true) ~= nil then
			return "playtest_start: a playtest is already running (stop it first with playtest_stop)",
				true
		end
		return "playtest_start: " .. ack, true
	end
	-- The ack comes before the test boots. Poll in-test readiness (the injected server's sdiag):
	-- PLAY is ready once a spawned, Motor6D-converted character reports; RUN is ready as soon as
	-- the injected server poller answers at all (no player ever spawns).
	local deadline = os.clock() + START_READY_TIMEOUT
	local lastErr = "(no sdiag response yet)"
	while os.clock() < deadline do
		task.wait(2)
		local diag, diagErr = playCommand(context, "sdiag", nil, 8)
		if not diagErr then
			if mode == "run" then
				return "playtest RUNNING in RUN mode ("
					.. diag
					.. ") — server simulation only: "
					.. "real physics + Animators, NO player character; all edits revert on stop."
					.. "\nDrive it with playtest_eval / playtest_logs (playtest_act/playtest_capture "
					.. "need PLAY mode); ALWAYS playtest_stop when done.",
					false
			end
			if string.find(diag, "char=", 1, true) ~= nil then
				return "playtest RUNNING in PLAY mode — "
					.. diag
					.. "\nDrive it with playtest_act "
					.. "/ playtest_eval / playtest_logs / playtest_capture; ALWAYS playtest_stop "
					.. "when done.",
					false
			end
		end
		lastErr = diag
	end
	return "playtest_start: test acked but " .. (if mode == "run"
		then "the run-mode server poller"
		else "the character") .. " never reported ready (" .. lastErr .. ") — playtest_stop and retry, or check playtest_logs",
		true
end

-- ---- playtest_stop ----

local function runStop(_input: any, context: any): (Content, boolean)
	local out, isErr = playCommand(context, "stop", nil, 12)
	if isErr and string.find(out, "no active test", 1, true) ~= nil then
		return "playtest_stop: no playtest was running", false
	end
	if isErr then
		-- The in-test poller may be dead (a stranded test). RunService:Stop() from the edit DM is
		-- the programmatic Stop button (live-verified 2026-07-01): it ends the test, and the
		-- ExecutePlayModeAsync continuation then runs cleanup + config restore.
		local okStop = pcall(function()
			game:GetService("RunService"):Stop()
		end)
		if okStop then
			return "playtest_stop: in-test poller unresponsive ("
				.. out
				.. ") — force-stopped via RunService:Stop(); cleanup ran",
				false
		end
		return "playtest_stop: " .. out, true
	end
	return "playtest stopped (" .. out .. ")", false
end

-- ---- playtest_act ----

local function runAct(input: any, context: any): (Content, boolean)
	local args = if type(input) == "table" then input else {}
	local verb = tostring(args.verb or "")
	if not ACT_VERBS[verb] then
		local names = {}
		for v in ACT_VERBS do
			table.insert(names, v)
		end
		table.sort(names)
		return "playtest_act: unknown verb '"
			.. verb
			.. "' (use "
			.. table.concat(names, "|")
			.. ")",
			true
	end
	local out, isErr = playCommand(context, "act", verb, 30)
	return (if isErr then "playtest_act: " .. out else out), isErr
end

-- ---- playtest_eval ----

local function runEval(input: any, context: any): (Content, boolean)
	local args = if type(input) == "table" then input else {}
	if type(args.code) ~= "string" or args.code == "" then
		return "playtest_eval requires { code = <string> }", true
	end
	local out, isErr = playCommand(context, "seval", args.code, 30)
	-- The in-test poller posts ok=true even for eval failures; surface those as tool errors so the
	-- agent never mistakes an error/guidance string for the probe's return value.
	if
		not isErr
		and (
			string.find(out, "seval compile error", 1, true) ~= nil
			or string.find(out, "seval runtime error", 1, true) ~= nil
			or string.find(out, "seval: loadstring unavailable", 1, true) ~= nil
		)
	then
		return out, true
	end
	return (if isErr then "playtest_eval: " .. out else out), isErr
end

-- ---- playtest_logs ----

local function runLogs(input: any, context: any): (Content, boolean)
	local args = if type(input) == "table" then input else {}
	local since = if type(args.since) == "number" then math.floor(args.since) else 0
	local out, isErr = playCommand(context, "slog2", tostring(since), 15)
	return (if isErr then "playtest_logs: " .. out else out), isErr
end

-- ---- playtest_capture ----

local function runCapture(_input: any, context: any): (Content, boolean)
	local t0 = os.time()
	local out, isErr = playCommand(context, "capture", nil, 20)
	if isErr then
		return "playtest_capture: " .. out, true
	end
	-- The in-test client wrote the PNG; fetch it from the sidecar as an image block (t0-5 covers
	-- clock skew between Studio and the sidecar's file mtimes).
	local blocks, fetchErr = CaptureCore.fetchCaptures(1, t0 - 5, context.config)
	if blocks == nil then
		return "playtest_capture: captured but fetch failed: " .. tostring(fetchErr), true
	end
	local content: { any } = {
		{ type = "text", text = "playtest capture (the PLAY CLIENT's viewport):" },
	}
	for _, b in blocks do
		table.insert(content, b)
	end
	return content, false
end

-- ---- playtest_status ----

local function runStatus(_input: any, context: any): (Content, boolean)
	local out, isErr = playCommand(context, "sdiag", nil, 10)
	if isErr and string.find(out, "no active test", 1, true) ~= nil then
		return "no playtest is running (playtest_start begins one)", false
	end
	return (if isErr then "playtest_status: " .. out else "playtest RUNNING — " .. out), isErr
end

Playtest.descriptors = {
	{
		name = "playtest_start",
		description = "Start a REAL test session (no F5). mode='play' (default): full Play Solo — "
			.. "waits until the player character has spawned (auto-converted to a Motor6D rig, clean "
			.. "default avatar); drive it with playtest_act/playtest_eval/playtest_logs/"
			.. "playtest_capture. mode='run': RUN mode (ExecuteRunModeAsync) — the server simulation "
			.. "runs with real physics + Animators but NO player spawns; use it to observe rig-only "
			.. "animation/physics via playtest_eval/playtest_logs (act/capture are unavailable). The "
			.. "game's own scripts run for real in both; all in-test changes revert on stop. ALWAYS "
			.. "playtest_stop when done. Requires the vision sidecar.",
		inputSchema = {
			type = "object",
			properties = {
				mode = {
					type = "string",
					enum = { "play", "run" },
					description = "play (default) = Play Solo with a player character; "
						.. "run = server-only RUN mode (no player).",
				},
			},
		},
		destructive = true,
		run = runStart,
	},
	{
		name = "playtest_stop",
		description = "End the running playtest and restore the place config. Always call this when "
			.. "you are done testing.",
		inputSchema = { type = "object", properties = {} },
		destructive = false,
		run = runStop,
	},
	{
		name = "playtest_act",
		description = "Drive the playtest character: verb = equip (first Backpack tool) | walk | "
			.. "walkstop | activate (click the held tool) | camera|closecam|profilecam (frame the "
			.. "character for capture) | record (equip+activate, sample the tool's ItemState 3s).",
		inputSchema = {
			type = "object",
			properties = {
				verb = { type = "string", description = "One of the act verbs above." },
			},
			required = { "verb" },
		},
		destructive = false,
		run = runAct,
	},
	{
		name = "playtest_eval",
		description = "Run Luau on the PLAY SERVER mid-playtest and get the tostring'd return values "
			.. "— your generic probe for runtime game state (positions, Health, attributes, leaderstats"
			.. "…). Prints land in playtest_logs. Example: return workspace.EnemyNpc:GetAttribute("
			.. '"NpcState")',
		inputSchema = {
			type = "object",
			properties = {
				code = {
					type = "string",
					description = "Luau to run in the play-server DataModel.",
				},
			},
			required = { "code" },
		},
		destructive = true,
		run = runEval,
	},
	{
		name = "playtest_logs",
		description = "Tail the playtest's FULL log (prints, warnings, errors WITH script path + "
			.. "stack trace) as cursored lines. Pass since=<last cursor> to get only new lines; "
			.. "start with since=0. THE way to see why gameplay code is failing.",
		inputSchema = {
			type = "object",
			properties = {
				since = {
					type = "number",
					description = "Return lines after this cursor (default 0).",
				},
			},
		},
		destructive = false,
		run = runLogs,
	},
	{
		name = "playtest_capture",
		description = "Screenshot the PLAY CLIENT's viewport mid-playtest and SEE it (frame first "
			.. "with playtest_act camera/closecam/profilecam). This is what the player actually sees.",
		inputSchema = { type = "object", properties = {} },
		destructive = false,
		run = runCapture,
	},
	{
		name = "playtest_status",
		description = "Is a playtest running? Returns the in-test character/rig diagnostic when yes.",
		inputSchema = { type = "object", properties = {} },
		destructive = false,
		run = runStatus,
	},
}

return Playtest
