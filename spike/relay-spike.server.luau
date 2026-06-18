-- RELAY SPIKE (throwaway, NOT shipped) — Accurate-Play-Solo plugin topology + IPC feasibility probe.
-- Builds as its OWN plugin (RelaySpike.rbxm) so it never touches src/ or the real install.
-- Prints greppable [SPIKE ...] lines to the Output window. No model/tunnel needed — pure mechanics.
--
-- What it answers (filter Output by "[SPIKE"):
--   * how many plugin copies exist during Play and each copy's (IsEdit,IsRunning,IsServer,IsClient)
--   * whether plugin:SetSetting/GetSetting bridges copies bidirectionally in one Studio process
--   * whether the SERVER-context copy's HttpService + Instance.new build actually work in-session
--   * whether the SERVER copy keeps running while the user views the CLIENT
--   * whether a replicated RemoteFunction:InvokeServer() works from the CLIENT-context plugin thread
--   * whether a play-start-injected Script (Source set directly, no loadstring) runs server-side
--
-- After Play (F5): read Output; flip the Current: Client/Server dropdown a few times; press Stop;
-- inspect Explorer (ServerScriptService/Workspace/ReplicatedStorage) to confirm spike instances
-- auto-reverted (cleanup), then Ctrl+S and re-inspect (script-source-save leak check).

local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")

local isEdit = RunService:IsEdit()
local isRunning = RunService:IsRunning()
local isServer = RunService:IsServer()
local isClient = RunService:IsClient()

local role
if isEdit then
	role = "EDIT"
elseif isServer and not isClient then
	role = "SERVER"
elseif isClient and not isServer then
	role = "CLIENT"
else
	role = "BOTH"
end

-- Distinct per copy (GenerateGUID is local, needs no HttpEnabled).
local copyId = string.sub(HttpService:GenerateGUID(false), 1, 8)
local function log(msg)
	print(string.format("[SPIKE %s/%s] %s", role, copyId, msg))
end

log(
	string.format(
		"===== init IsEdit=%s IsRunning=%s IsServer=%s IsClient=%s PlaceId=%d GameId=%d =====",
		tostring(isEdit),
		tostring(isRunning),
		tostring(isServer),
		tostring(isClient),
		game.PlaceId,
		game.GameId
	)
)

----------------------------------------------------------------------------------------------------
-- PROBE: settings bridge (the prime candidate for a client<->server channel in one process).
-- Each copy announces itself, then polls for FRESH values written by OTHER copies this session.
----------------------------------------------------------------------------------------------------
local STAMP = os.time()
pcall(function()
	plugin:SetSetting("SPIKE_role_" .. role, STAMP .. "|" .. copyId)
end)

task.spawn(function()
	local OTHERS = { "EDIT", "SERVER", "CLIENT", "BOTH" }
	local announced = {}
	for _ = 1, 10 do
		task.wait(1)
		for _, r in OTHERS do
			if r ~= role and not announced[r] then
				local ok, v = pcall(function()
					return plugin:GetSetting("SPIKE_role_" .. r)
				end)
				if ok and type(v) == "string" then
					local ts = tonumber(string.match(v, "^(%d+)"))
					-- fresh (this session) AND written by a different copy => settings bridge works
					if ts and math.abs(STAMP - ts) <= 90 then
						announced[r] = true
						log("settings-bridge SEES copy " .. r .. " => " .. v)
					end
				end
			end
		end
	end
end)

----------------------------------------------------------------------------------------------------
-- SERVER play copy: this is the copy that (if it exists) could BE the relay — HTTP + build run here.
----------------------------------------------------------------------------------------------------
if role == "SERVER" then
	-- (a) HTTP from a SERVER-context plugin copy, in-session. example.com is reliable + non-roblox.
	task.spawn(function()
		pcall(function()
			HttpService.HttpEnabled = true
		end)
		local ok, res = pcall(function()
			return HttpService:RequestAsync({ Url = "https://example.com", Method = "GET" })
		end)
		if ok and type(res) == "table" then
			log(
				"HTTP server-copy ok Success="
					.. tostring(res.Success)
					.. " Status="
					.. tostring(res.StatusCode)
			)
		else
			log("HTTP server-copy FAILED: " .. tostring(res))
		end
	end)

	-- (b) loadstring-free build (the repo's proven playtest build path).
	task.spawn(function()
		local ok, err = pcall(function()
			local p = Instance.new("Part")
			p.Name = "SPIKE_ServerBuilt"
			p.Anchored = true
			p.Size = Vector3.new(4, 4, 4)
			p.Position = Vector3.new(0, 50, 0)
			p.Parent = Workspace
		end)
		log(
			"build server-copy "
				.. (ok and "ok (Workspace.SPIKE_ServerBuilt)" or ("FAILED: " .. tostring(err)))
		)
	end)

	-- (c) place a replicated RemoteFunction for the CLIENT copy to probe (C1).
	pcall(function()
		local rf = Instance.new("RemoteFunction")
		rf.Name = "SPIKE_RF"
		rf.OnServerInvoke = function(_player, payload)
			return { pong = true, side = "server", echo = payload }
		end
		rf.Parent = ReplicatedStorage
		log("placed SPIKE_RF in ReplicatedStorage (OnServerInvoke set)")
	end)

	-- (d) marker in ServerStorage (does NOT replicate) — client visibility control.
	pcall(function()
		local m = Instance.new("StringValue")
		m.Name = "SPIKE_SS_Marker"
		m.Value = copyId
		m.Parent = ServerStorage
	end)

	-- (e) inject a Script whose Source is set directly (no loadstring) — does it run server-side?
	task.spawn(function()
		local ok, err = pcall(function()
			local s = Instance.new("Script")
			s.Name = "SPIKE_Injected"
			s.Source = 'print("[SPIKE INJECTED] ALIVE IsServer="'
				.. '..tostring(game:GetService("RunService"):IsServer())'
				.. '.." IsRunning="..tostring(game:GetService("RunService"):IsRunning()))'
			s.Parent = ServerScriptService
		end)
		log(
			"inject-script "
				.. (ok and "parented (watch for [SPIKE INJECTED])" or ("FAILED: " .. tostring(err)))
		)
	end)

	-- (f) liveness heartbeat via settings — client reads this to see if SERVER keeps running while
	-- the user is on the CLIENT view.
	task.spawn(function()
		local n = 0
		while n < 120 do
			task.wait(1)
			n += 1
			pcall(function()
				plugin:SetSetting("SPIKE_HB", os.time() .. "|" .. n)
			end)
			if n % 3 == 0 then
				log("heartbeat n=" .. n)
			end
		end
	end)
end

----------------------------------------------------------------------------------------------------
-- CLIENT play copy: the panel lives here in client view. Can it reach the running SERVER?
----------------------------------------------------------------------------------------------------
if role == "CLIENT" then
	-- C1: does SPIKE_RF replicate to the client DM, and can the PLUGIN thread InvokeServer it?
	task.spawn(function()
		for _ = 1, 16 do
			local rf = ReplicatedStorage:FindFirstChild("SPIKE_RF")
			if rf then
				log(
					"C1 SPIKE_RF replicated to client DM; calling InvokeServer from plugin thread..."
				)
				local ok, res = pcall(function()
					return rf:InvokeServer({ op = "ping", from = "client-plugin" })
				end)
				if ok then
					local enc = pcall(function()
						return HttpService:JSONEncode(res)
					end)
					log(
						"C1 InvokeServer RETURNED ok="
							.. tostring(enc)
							.. " value="
							.. tostring(res)
					)
				else
					log("C1 InvokeServer FAILED: " .. tostring(res))
				end
				return
			end
			task.wait(0.5)
		end
		log("C1 SPIKE_RF NEVER replicated to client DM (not found after ~8s)")
	end)

	-- C2: can the client see the server-only ServerStorage marker? (expected NO -> isolation.)
	task.spawn(function()
		task.wait(2)
		local m = ServerStorage:FindFirstChild("SPIKE_SS_Marker")
		log("C2 ServerStorage/SPIKE_SS_Marker visible from client = " .. tostring(m ~= nil))
	end)

	-- liveness: is the SERVER heartbeat advancing (via settings) while I (client) am the active view?
	task.spawn(function()
		local prev
		for _ = 1, 12 do
			task.wait(1.5)
			local ok, v = pcall(function()
				return plugin:GetSetting("SPIKE_HB")
			end)
			if ok and type(v) == "string" and v ~= prev then
				log("server-HB advancing (read via settings): " .. v)
				prev = v
			end
		end
	end)
end

----------------------------------------------------------------------------------------------------
-- EDIT copy: does it persist while a playtest is running?
----------------------------------------------------------------------------------------------------
if role == "EDIT" then
	task.spawn(function()
		for _ = 1, 20 do
			task.wait(2)
			log("edit-tick IsRunning=" .. tostring(RunService:IsRunning()))
		end
	end)
end
