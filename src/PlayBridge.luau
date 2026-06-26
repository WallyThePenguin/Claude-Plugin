--!strict
-- PlayBridge: drive a Studio PLAYTEST from the shell over the sidecar /play channel (no F5, no desktop
-- control). LIVE-VERIFIED design: the plugin does NOT load inside a StudioTestService test, so the EDIT
-- generation handles `play start` by (1) injecting a server-poller Script + a client-handler LocalScript +
-- a RemoteEvent into the place, (2) task.spawn-ing StudioTestService:ExecutePlayModeAsync (which yields the
-- edit DM until the test ends), then cleaning the injected instances up. The injected SERVER poller polls
-- /play (in-test HTTP works once "Allow HTTP Requests" is on), drives the character (EquipTool/Move work
-- server-side), and relays capture (client-only) + act to the CLIENT handler over the RemoteEvent; `stop`
-- calls EndTest. A `playing` flag keeps the edit loop from competing while a test runs. Lifecycle-aware
-- (hot-reloads with Main). See docs/superpowers/specs/2026-06-26-play-mode-bridge-design.md.

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Relay = require(script.Parent.Relay)

local PlayBridge = {}

local RELAY_NAME = "StudioAgentPlayRelay"
local SERVER_NAME = "StudioAgentPlayServer"
local CLIENT_NAME = "StudioAgentPlayClient"

-- ---- the injected SERVER poller (runs in the test's server DM; HTTP works there) ----
local SERVER_SRC = [==[
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudioTestService = game:GetService("StudioTestService")
local base = "__BASE__"
local relay = ReplicatedStorage:WaitForChild("StudioAgentPlayRelay", 10)

local responses = {}
if relay then
	relay.OnServerEvent:Connect(function(_plr, reqId, result)
		responses[reqId] = result
	end)
end
local reqCounter = 0
-- Relay an action to the client and wait (up to 8s) for its response.
local function client(action, arg)
	if relay == nil then
		return "no relay"
	end
	reqCounter = reqCounter + 1
	local id = reqCounter
	relay:FireAllClients(id, action, arg)
	local deadline = os.clock() + 8
	while responses[id] == nil and os.clock() < deadline do
		task.wait(0.1)
	end
	local r = responses[id]
	responses[id] = nil
	return r or "client timeout"
end

local function post(id, ok, result)
	pcall(function()
		HttpService:RequestAsync({
			Url = base .. "/play/result",
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = HttpService:JSONEncode({ id = id, ok = ok, result = result }),
		})
	end)
end

while true do
	local ok, res = pcall(function()
		return HttpService:RequestAsync({ Url = base .. "/play/pending", Method = "GET" })
	end)
	if ok and res.Success then
		local cmd = nil
		pcall(function()
			cmd = HttpService:JSONDecode(res.Body)
		end)
		if type(cmd) == "table" and cmd.cmd ~= nil then
			if cmd.cmd == "stop" then
				post(cmd.id, true, "stopping")
				task.wait(0.2)
				pcall(function()
					StudioTestService:EndTest("stopped")
				end)
				return
			elseif cmd.cmd == "capture" then
				post(cmd.id, true, client("capture", nil))
			elseif cmd.cmd == "act" then
				post(cmd.id, true, client("act", cmd.arg))
			elseif cmd.cmd == "eval" then
				post(cmd.id, true, client("eval", cmd.arg))
			else
				post(cmd.id, false, "unknown play cmd: " .. tostring(cmd.cmd))
			end
		end
	end
	task.wait(0.4)
end
]==]

-- ---- the injected CLIENT handler (owns the character + the viewport) ----
local CLIENT_SRC = [==[
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local CaptureService = game:GetService("CaptureService")
local relay = ReplicatedStorage:WaitForChild("StudioAgentPlayRelay", 10)
local plr = Players.LocalPlayer

local function doCapture()
	local done = false
	pcall(function()
		CaptureService:CaptureScreenshot(function()
			done = true
		end)
	end)
	local deadline = os.clock() + 5
	while not done and os.clock() < deadline do
		task.wait(0.1)
	end
	return "captured"
end

local function doAct(verb)
	local char = plr.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if verb == "equip" then
		local backpack = plr:FindFirstChild("Backpack")
		local tool = backpack and backpack:FindFirstChildOfClass("Tool")
		if hum and tool then
			hum:EquipTool(tool)
			return "equipped " .. tool.Name
		end
		return "no humanoid/tool"
	elseif verb == "walk" then
		if hum and char and char.PrimaryPart then
			hum:Move(char.PrimaryPart.CFrame.LookVector, false)
			return "walking"
		end
		return "no humanoid"
	elseif verb == "walkstop" then
		if hum then
			hum:Move(Vector3.zero, false)
			return "stopped walking"
		end
		return "no humanoid"
	elseif verb == "activate" then
		local tool = char and char:FindFirstChildOfClass("Tool")
		if tool then
			tool:Activate()
			return "activated " .. tool.Name
		end
		return "no equipped tool"
	end
	return "unknown act: " .. tostring(verb)
end

if relay then
	relay.OnClientEvent:Connect(function(reqId, action, arg)
		local result
		if action == "capture" then
			result = doCapture()
		elseif action == "act" then
			result = doAct(arg)
		elseif action == "eval" then
			local fn, err = loadstring(tostring(arg))
			if fn then
				local ok, r = pcall(fn)
				result = "eval " .. tostring(ok) .. ": " .. tostring(r)
			else
				result = "eval compile error: " .. tostring(err)
			end
		else
			result = "unknown action: " .. tostring(action)
		end
		relay:FireServer(reqId, result)
	end)
end
]==]

-- Inject the relay + server + client scripts into the place (idempotent: remove any prior copies first).
local function injectTestScripts(base: string)
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local ServerScriptService = game:GetService("ServerScriptService")
	local StarterPlayer = game:GetService("StarterPlayer")
	local starterScripts = StarterPlayer:FindFirstChildOfClass("StarterPlayerScripts")
	PlayBridge.cleanupTestScripts()
	local relay = Instance.new("RemoteEvent")
	relay.Name = RELAY_NAME
	relay.Parent = ReplicatedStorage
	local server = Instance.new("Script")
	server.Name = SERVER_NAME
	server.Source = string.gsub(SERVER_SRC, "__BASE__", base)
	server.Parent = ServerScriptService
	if starterScripts ~= nil then
		local client = Instance.new("LocalScript")
		client.Name = CLIENT_NAME
		client.Source = CLIENT_SRC
		client.Parent = starterScripts
	end
end

function PlayBridge.cleanupTestScripts()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local ServerScriptService = game:GetService("ServerScriptService")
	local StarterPlayer = game:GetService("StarterPlayer")
	local starterScripts = StarterPlayer:FindFirstChildOfClass("StarterPlayerScripts")
	for _, pair in
		{
			{ ReplicatedStorage, RELAY_NAME },
			{ ServerScriptService, SERVER_NAME },
			{ starterScripts, CLIENT_NAME },
		}
	do
		local container = pair[1]
		if container ~= nil then
			local old = (container :: Instance):FindFirstChild(pair[2] :: string)
			if old ~= nil then
				old:Destroy()
			end
		end
	end
end

-- ---- impure HTTP (the edit loop) ----
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

-- ---- edit-side: handle `play start` (inject -> ExecutePlayModeAsync -> cleanup) ----
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
						injectTestScripts(base)
						-- POST the ack BEFORE the spawn: ExecutePlayModeAsync yields the whole edit DM, so
						-- a post after it would not flush until the test ends.
						httpPostJson(
							base .. "/play/result",
							{
								id = c.id,
								ok = true,
								result = "play starting (ExecutePlayModeAsync)",
							}
						)
						task.spawn(function()
							local StudioTestService = game:GetService("StudioTestService")
							local okRun, result = pcall(function()
								return (StudioTestService :: any):ExecutePlayModeAsync({
									studioAgentPlay = true,
								})
							end)
							playing = false
							PlayBridge.cleanupTestScripts()
							httpPostJson(base .. "/play/result", {
								id = c.id,
								ok = okRun,
								result = "test ended: " .. tostring(result),
							})
						end)
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

function PlayBridge.start(deps: any, lifecycle: any)
	-- Only the EDIT generation runs the loop; the plugin does not load inside the test (the injected
	-- scripts do the in-test work). serverplay/clientplay generations are a no-op here.
	if Relay.mode() == "edit" then
		PlayBridge.startEditLoop(deps, lifecycle)
	end
end

return PlayBridge
