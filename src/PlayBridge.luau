--!strict
-- PlayBridge: drive a Studio PLAYTEST from the shell over the sidecar /play channel (no F5). The EDIT
-- generation handles `start` (task.spawn StudioTestService:ExecutePlayModeAsync; a `playing` flag keeps it
-- from grabbing the in-test loop's commands). The serverplay/clientplay generation runs the in-test loop:
-- eval/capture/act/stop, with an idle auto-EndTest so a test can never strand the editor. Lifecycle-aware
-- (hot-reloads with Main). See docs/superpowers/specs/2026-06-26-play-mode-bridge-design.md.

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Relay = require(script.Parent.Relay)

local PlayBridge = {}

-- ---- pure (unit-tested) ----

-- Expand an `act` verb (+ optional arg) into a Luau snippet run in the play DM. Drives the local
-- character via the Humanoid/Tool API. Unknown verb -> nil. PURE.
function PlayBridge.actSnippet(verb: string, _arg: string?): string?
	if verb == "equip" then
		return [[
local p = game:GetService("Players").LocalPlayer
local char = p.Character
local hum = char and char:FindFirstChildOfClass("Humanoid")
local tool = p:FindFirstChild("Backpack") and p.Backpack:FindFirstChildOfClass("Tool")
if hum and tool then hum:EquipTool(tool) return "equipped " .. tool.Name end
return "no humanoid/tool to equip"]]
	elseif verb == "walk" then
		return [[
local p = game:GetService("Players").LocalPlayer
local hum = p.Character and p.Character:FindFirstChildOfClass("Humanoid")
if hum then hum:Move(p.Character.PrimaryPart and p.Character.PrimaryPart.CFrame.LookVector or Vector3.new(0,0,-1), false) return "walking" end
return "no humanoid"]]
	elseif verb == "stop" then
		return [[
local p = game:GetService("Players").LocalPlayer
local hum = p.Character and p.Character:FindFirstChildOfClass("Humanoid")
if hum then hum:Move(Vector3.new(0,0,0), false) return "stopped" end
return "no humanoid"]]
	elseif verb == "activate" then
		return [[
local p = game:GetService("Players").LocalPlayer
local char = p.Character
local tool = char and char:FindFirstChildOfClass("Tool")
if tool then tool:Activate() return "activated " .. tool.Name end
return "no equipped tool"]]
	end
	return nil
end

-- ---- impure HTTP (sidecar) ----

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
	local okD, payload = pcall(function()
		return HttpService:JSONDecode(r.Body)
	end)
	if not okD then
		return nil, "bad json"
	end
	return payload, nil
end

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

-- ---- edit-side: handle `start` ----

local playing = false

function PlayBridge.startEditLoop(deps: any, lifecycle: any)
	if not RunService:IsEdit() then
		return
	end
	local base = deps.config:getSidecarUrl()
	task.spawn(function()
		while not lifecycle.cancelled do
			if not playing then
				local cmd = httpGetJson(base .. "/play/pending")
				if type(cmd) == "table" and (cmd :: any).cmd ~= nil then
					local c = cmd :: any
					if c.cmd == "start" then
						playing = true
						task.spawn(function()
							local StudioTestService = game:GetService("StudioTestService")
							local okRun, result = pcall(function()
								return (StudioTestService :: any):ExecutePlayModeAsync({
									studioAgentPlay = true,
								})
							end)
							playing = false
							httpPostJson(base .. "/play/result", {
								id = c.id,
								ok = okRun,
								result = "test ended: " .. tostring(result),
							})
						end)
						httpPostJson(
							base .. "/play/result",
							{
								id = c.id,
								ok = true,
								result = "play starting (ExecutePlayModeAsync)",
							}
						)
					else
						httpPostJson(
							base .. "/play/result",
							{
								id = c.id,
								ok = false,
								error = "no active test — run `play start` first",
							}
						)
					end
				end
			end
			task.wait(deps.config:getDevBridgePollInterval())
		end
	end)
end

-- ---- in-test: poll + dispatch (Task 5 fills eval/capture/act; this skeleton PROBES then EndTests) ----

function PlayBridge.startTestLoop(deps: any, lifecycle: any, mode: string)
	local base = deps.config:getSidecarUrl()
	task.spawn(function()
		-- PROBE (resolves the client/server + DM-topology unknowns): report mode + whether THIS copy can
		-- reach the sidecar.
		local probeOk = httpGetJson(base .. "/play/pending") ~= nil
		httpPostJson(base .. "/logs", {
			lines = {
				{
					kind = "play-probe",
					text = ("[PlayBridge] mode=%s canPoll=%s server=%s client=%s"):format(
						mode,
						tostring(probeOk),
						tostring(RunService:IsServer()),
						tostring(RunService:IsClient())
					),
				},
			},
		})
		-- Idle auto-EndTest: end the test after ~30s with no command, so it never strands the editor.
		local deadline = os.clock() + 30
		while not lifecycle.cancelled and os.clock() < deadline do
			-- Task 5 replaces this body with the real eval/capture/act/stop dispatch.
			task.wait(0.5)
		end
		if mode == "serverplay" then
			pcall(function()
				(game:GetService("StudioTestService") :: any):EndTest("idle-timeout")
			end)
		end
	end)
end

function PlayBridge.start(deps: any, lifecycle: any)
	local mode = Relay.mode()
	if mode == "edit" then
		PlayBridge.startEditLoop(deps, lifecycle)
	elseif mode == "serverplay" or mode == "clientplay" then
		PlayBridge.startTestLoop(deps, lifecycle, mode)
	end
end

return PlayBridge
