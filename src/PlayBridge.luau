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
--
-- AVATAR-RIG FIX (the solved blocker): under the Avatar Joint Upgrade (default-on May 2026) an R15
-- character spawns physically simulated -- AnimationConstraints + BallSocketConstraints, ZERO Motor6Ds --
-- and that physics IGNORES the classic Motor6D animation channel our KeyframeSequence/Pose clips drive, so
-- the bound use-animations never render in the Play Solo capture (the old "T-pose, motors=[]" symptom; the
-- rig was actually present, just the wrong joint type, and the custom web avatar additionally renders
-- splayed/unreadable). FIX: on `play start` the edit side forces StarterPlayer.LoadCharacterAppearance=false
-- (clean default blocky body + default anims; saved + restored around the test), and the in-test server
-- AUTO-CONVERTS each spawned character to a CLASSIC Motor6D rig (build the 15 Motor6Ds from the
-- RigAttachment pairs, then strip the AnimationConstraints + BallSocketConstraints) -- so our animations
-- apply + render and the player stays LocalPlayer.Character (the in-Tool runtime + equip still work). Live
-- diagnostics (server-side; the client `eval` path is dead -- loadstring is unavailable on the client):
-- `play sdiag` (joint/rig breakdown), `sanim` (playing tracks), `slog` (in-test errors), `sfix` (re-convert),
-- plus `act closecam`/`profilecam` framings.

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
local Players = game:GetService("Players")
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

-- ---- cursored log buffer (playtest_logs): every LogService line + ScriptContext stack traces ----
-- Absolute indices survive ring eviction, so `slog2 since=N` tails incrementally without loss.
local logBuf = {}
local logCount = 0
local logFirst = 1
local LOG_CAP = 400
local function pushLog(kind, text)
	logCount = logCount + 1
	logBuf[logCount] = "[" .. kind .. "] " .. text
	if logCount - logFirst + 1 > LOG_CAP then
		logBuf[logFirst] = nil
		logFirst = logFirst + 1
	end
end
pcall(function()
	game:GetService("LogService").MessageOut:Connect(function(msg, mtype)
		local kind = string.lower((string.gsub(tostring(mtype.Name), "^Message", "")))
		pushLog(kind, tostring(msg))
	end)
end)
pcall(function()
	-- Richer than MessageOut's error line: includes the script path and the full stack.
	game:GetService("ScriptContext").Error:Connect(function(message, stack, scriptInstance)
		local src = "?"
		pcall(function()
			src = scriptInstance:GetFullName()
		end)
		pushLog(
			"error+stack",
			tostring(message)
				.. " | script="
				.. tostring(src)
				.. " | stack: "
				.. string.gsub(tostring(stack), "\n", " <- ")
		)
	end)
end)
local function serverLogs(sinceArg)
	local since = tonumber(sinceArg) or 0
	local from = math.max(logFirst, math.floor(since) + 1)
	local lines = {}
	for i = from, logCount do
		if logBuf[i] ~= nil then
			table.insert(lines, "#" .. tostring(i) .. " " .. logBuf[i])
			if #lines >= 60 then
				break
			end
		end
	end
	if #lines == 0 then
		return "no new log lines (cursor=" .. tostring(logCount) .. ")"
	end
	local last = from + #lines - 1
	local more = if last < logCount
		then " — MORE available, call again with since=" .. tostring(last)
		else ""
	return table.concat(lines, "\n") .. "\n(cursor=" .. tostring(last) .. more .. ")"
end

-- ---- server-side eval (playtest_eval): loadstring in the play-server DM ----
-- The agent's generic probe: read/assert ANY server game state mid-playtest. Return values are
-- tostring'd; prints land in the log buffer (readable via playtest_logs).
local function serverEval(code)
	-- loadstring THROWS at call time when LoadStringEnabled is off (it is not nil) — guard the call.
	local okCompile, fn, cerr = pcall(loadstring, tostring(code), "=playtest_eval")
	if not okCompile then
		return "seval: loadstring unavailable ("
			.. tostring(fn)
			.. ") — playtest_eval needs the user to tick ServerScriptService.LoadStringEnabled in the "
			.. "Properties panel ONCE for this place (not scriptable; a manual toggle like 'Allow HTTP "
			.. "Requests'). Use playtest_logs / playtest_act / the predefined probes meanwhile."
	end
	if fn == nil then
		return "seval compile error: " .. tostring(cerr)
	end
	local results = { pcall(fn) }
	if not results[1] then
		return "seval runtime error: " .. tostring(results[2])
	end
	local parts = {}
	for i = 2, #results do
		table.insert(parts, tostring(results[i]))
	end
	if #parts == 0 then
		return "seval ok (no return values; prints land in playtest_logs)"
	end
	return "seval ok: " .. table.concat(parts, ", ")
end

-- ---- server-side rig helpers (the server DM sees the replicated joints) ----
local function firstPlayer()
	return Players:GetPlayers()[1]
end
-- Count every animatable joint kind (the Avatar Joint Upgrade swaps Motor6D -> AnimationConstraint).
local function countJoints(char)
	local m, ac, bsc, bone = 0, 0, 0, 0
	if char then
		for _, d in char:GetDescendants() do
			if d:IsA("Motor6D") then
				m += 1
			elseif d:IsA("AnimationConstraint") then
				ac += 1
			elseif d:IsA("BallSocketConstraint") then
				bsc += 1
			elseif d:IsA("Bone") then
				bone += 1
			end
		end
	end
	return m, ac, bsc, bone
end
local function countAttach(char)
	if not char then
		return -1, -1
	end
	local n, rigA = 0, 0
	for _, d in char:GetDescendants() do
		if d:IsA("Attachment") then
			n = n + 1
			if string.find(d.Name, "RigAttachment") then
				rigA = rigA + 1
			end
		end
	end
	return n, rigA
end
local function serverDiag()
	local plr = firstPlayer()
	if not plr then
		return "no player"
	end
	local char = plr.Character
	if not char then
		return "no character"
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local rig = hum and tostring(hum.RigType.Name) or "noHum"
	local app = "?"
	pcall(function()
		app = tostring(plr:HasAppearanceLoaded())
	end)
	local attach, rigA = countAttach(char)
	local hrp = char:FindFirstChild("HumanoidRootPart") ~= nil
	local m, ac, bsc, bone = countJoints(char)
	local animate = char:FindFirstChild("Animate") ~= nil
	return string.format(
		"char=%s motor6d=%d animConstraint=%d ballSocket=%d bone=%d rig=%s app=%s parts=%d attach=%d rigAttach=%d hrp=%s animate=%s",
		char.Name,
		m,
		ac,
		bsc,
		bone,
		rig,
		app,
		#char:GetChildren(),
		attach,
		rigA,
		tostring(hrp),
		tostring(animate)
	)
end
-- Read recent error/warning log lines (the red top-left text in the viewport).
local function serverLog()
	local LogService = game:GetService("LogService")
	local hist = {}
	pcall(function()
		hist = LogService:GetLogHistory()
	end)
	local lines = {}
	for i = #hist, math.max(1, #hist - 25), -1 do
		local e = hist[i]
		if e and (e.messageType == Enum.MessageType.MessageError or e.messageType == Enum.MessageType.MessageWarning) then
			table.insert(lines, "[" .. tostring(e.messageType.Name) .. "] " .. tostring(e.message))
			if #lines >= 8 then
				break
			end
		end
	end
	if #lines == 0 then
		return "no error/warning logs (server view)"
	end
	return table.concat(lines, " || ")
end
-- Report the player Animator's playing tracks (anims started client-side replicate to the server).
local function serverAnim()
	local plr = firstPlayer()
	local char = plr and plr.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local animator = hum and hum:FindFirstChildOfClass("Animator")
	if not animator then
		return "no animator"
	end
	local tracks = {}
	pcall(function()
		tracks = animator:GetPlayingAnimationTracks()
	end)
	local names = {}
	for _, t in tracks do
		table.insert(names, tostring(t.Animation and t.Animation.AnimationId or "?") .. "(" .. tostring(t.IsPlaying) .. ")")
	end
	return "playingTracks=" .. tostring(#tracks) .. " [" .. table.concat(names, ",") .. "]"
end
-- The canonical R15 joint tree: {jointName, parentPartName, childPartName}. Each part carries a
-- jointName.."RigAttachment"; the Motor6D lives in the parent (Part0).
local R15_JOINTS = {
	{ "Root", "HumanoidRootPart", "LowerTorso" },
	{ "Waist", "LowerTorso", "UpperTorso" },
	{ "Neck", "UpperTorso", "Head" },
	{ "RightShoulder", "UpperTorso", "RightUpperArm" },
	{ "RightElbow", "RightUpperArm", "RightLowerArm" },
	{ "RightWrist", "RightLowerArm", "RightHand" },
	{ "LeftShoulder", "UpperTorso", "LeftUpperArm" },
	{ "LeftElbow", "LeftUpperArm", "LeftLowerArm" },
	{ "LeftWrist", "LeftLowerArm", "LeftHand" },
	{ "RightHip", "LowerTorso", "RightUpperLeg" },
	{ "RightKnee", "RightUpperLeg", "RightLowerLeg" },
	{ "RightAnkle", "RightLowerLeg", "RightFoot" },
	{ "LeftHip", "LowerTorso", "LeftUpperLeg" },
	{ "LeftKnee", "LeftUpperLeg", "LeftLowerLeg" },
	{ "LeftAnkle", "LeftLowerLeg", "LeftFoot" },
}
-- Convert a (joint-upgraded) R15 character to a CLASSIC Motor6D rig: build the 15 Motor6Ds from the
-- RigAttachment pairs, then strip the AnimationConstraints + BallSocketConstraints (the physical joints
-- that override / ignore the Motor6D animation channel). Returns (builtCount, strippedCount).
local function convertToMotor6D(model)
	local built = 0
	for _, j in R15_JOINTS do
		local p0 = model:FindFirstChild(j[2])
		local p1 = model:FindFirstChild(j[3])
		if p0 and p1 and not p0:FindFirstChild(j[1]) then
			local a0 = p0:FindFirstChild(j[1] .. "RigAttachment")
			local a1 = p1:FindFirstChild(j[1] .. "RigAttachment")
			if a0 and a1 then
				local mo = Instance.new("Motor6D")
				mo.Name = j[1]
				mo.Part0 = p0
				mo.Part1 = p1
				mo.C0 = a0.CFrame
				mo.C1 = a1.CFrame
				mo.Parent = p0
				built += 1
			end
		end
	end
	local stripped = 0
	for _, d in model:GetDescendants() do
		if d:IsA("AnimationConstraint") or d:IsA("BallSocketConstraint") then
			d:Destroy()
			stripped += 1
		end
	end
	return built, stripped
end
-- VERIFY #4 hit detection: place workspace.TargetDummy in front of the player, trigger the swing (the client
-- requests a hit on the active window -> the server sweeps + damages), and report the dummy's Humanoid.Health
-- before/after (server-authoritative, so readable here).
local function serverHitTest()
	local plr = firstPlayer()
	local char = plr and plr.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local dummy = workspace:FindFirstChild("TargetDummy")
	local dhum = dummy and dummy:FindFirstChildOfClass("Humanoid")
	if not (hrp and dummy and dhum) then
		return "hit-test: need player HRP + workspace.TargetDummy w/ Humanoid (hrp="
			.. tostring(hrp ~= nil)
			.. " dummy="
			.. tostring(dhum ~= nil)
			.. ")"
	end
	;(dummy :: Model):PivotTo(
		CFrame.lookAt(
			(hrp :: any).Position + (hrp :: any).CFrame.LookVector * 3,
			(hrp :: any).Position
		)
	)
	task.wait(0.3)
	local before = (dhum :: Humanoid).Health
	client("act", "record")
	local after = (dhum :: Humanoid).Health
	return string.format(
		"TargetDummy Health: before=%.0f after=%.0f (delta=%.0f, max=%.0f)",
		before,
		after,
		before - after,
		(dhum :: Humanoid).MaxHealth
	)
end
-- VERIFY #5 NPC AI: sample workspace.EnemyNpc's NpcState + Health + the player's Health + their distance over
-- ~5s (the NPC AI is a SERVER script, so NpcState/Health are readable here). Shows chase (dist shrinks,
-- state=chase) then attack (playerHP drops, state=attack).
local function serverNpc()
	local plr = firstPlayer()
	if not plr then
		return "snpc: no player"
	end
	-- wait for a living player + its Humanoid.RootPart (robust vs the engine reassembling characters in Play)
	local phum, phrp = nil, nil
	local deadline = os.clock() + 6
	while os.clock() < deadline do
		local c = plr.Character
		phum = c and c:FindFirstChildOfClass("Humanoid")
		phrp = phum and (phum :: Humanoid).RootPart
		if phrp ~= nil then
			break
		end
		task.wait(0.2)
	end
	local npc = workspace:FindFirstChild("EnemyNpc")
	local nhum = npc and npc:FindFirstChildOfClass("Humanoid")
	local nhrp = npc and npc:FindFirstChild("HumanoidRootPart")
	if not (phrp and nhum and nhrp) then
		return "snpc: need a living player + workspace.EnemyNpc (phrp="
			.. tostring(phrp ~= nil)
			.. " nhum="
			.. tostring(nhum ~= nil)
			.. " nhrp="
			.. tostring(nhrp ~= nil)
			.. ")"
	end
	-- A workspace Humanoid model doesn't fully assemble (walk) in Play Solo, but the AI server script reads the
	-- HumanoidRootPart PART for distance + TakeDamage's the player -- so anchor the NPC in attack range and
	-- verify the AI's perception + attack (state -> attack, player Health drops).
	;(nhrp :: BasePart).Anchored = true
	;(npc :: Model):PivotTo(
		CFrame.new((phrp :: any).Position + (phrp :: any).CFrame.LookVector * 4 + Vector3.new(0, 0, 0))
	)
	task.wait(0.5)
	local lines, t0 = {}, os.clock()
	while os.clock() - t0 < 6 do
		local c = plr.Character
		local ph = c and c:FindFirstChildOfClass("Humanoid")
		local php = ph and (ph :: Humanoid).RootPart
		local dist = if php ~= nil
			then ((php :: any).Position - (nhrp :: any).Position).Magnitude
			else -1
		table.insert(
			lines,
			string.format(
				"%.1f:state=%s npcHP=%.0f playerHP=%.0f dist=%.1f",
				os.clock() - t0,
				tostring((npc :: Model):GetAttribute("NpcState")),
				(nhum :: Humanoid).Health,
				if ph ~= nil then (ph :: Humanoid).Health else 0,
				dist
			)
		)
		task.wait(1)
	end
	return table.concat(lines, " | ")
end
-- Fix the PLAYER's own character in place (keeps it as LocalPlayer.Character so the in-Tool runtime works).
local function serverFix()
	local plr = firstPlayer()
	local char = plr and plr.Character
	if not char then
		return "no character"
	end
	local m0, ac0, bsc0 = countJoints(char)
	local built, stripped = convertToMotor6D(char)
	local m1, ac1, bsc1 = countJoints(char)
	return string.format(
		"playerFix: before[m=%d ac=%d bsc=%d] built=%d stripped=%d after[m=%d ac=%d bsc=%d]",
		m0,
		ac0,
		bsc0,
		built,
		stripped,
		m1,
		ac1,
		bsc1
	)
end
-- AUTO-FIX: convert a character to a classic Motor6D rig as soon as it spawns. This is THE fix for the
-- avatar-rig blocker -- under the Avatar Joint Upgrade an R15 character spawns physically simulated
-- (AnimationConstraints + BallSocketConstraints, zero Motor6Ds), and the physics IGNORES the Motor6D
-- animation channel our clips drive, so they never render in the Play Solo capture. Converting to Motor6D
-- makes our KeyframeSequence/Pose animations apply + render. Idempotent.
local function fixCharacter(char)
	if char == nil then
		return
	end
	char:WaitForChild("HumanoidRootPart", 5)
	pcall(function()
		convertToMotor6D(char)
	end)
end
do
	local plr = firstPlayer()
	if plr then
		if plr.Character then
			task.spawn(fixCharacter, plr.Character)
		end
		plr.CharacterAdded:Connect(fixCharacter)
	end
	Players.PlayerAdded:Connect(function(p)
		p.CharacterAdded:Connect(fixCharacter)
		if p.Character then
			task.spawn(fixCharacter, p.Character)
		end
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
			end
			-- pcall-wrap EVERY other verb: a throwing handler must post an error, never kill the
			-- poller (a dead poller strands the whole test — even `stop` stops working).
			local okDispatch, dispatchErr = pcall(function()
				if cmd.cmd == "capture" then
					post(cmd.id, true, client("capture", nil))
				elseif cmd.cmd == "act" then
					post(cmd.id, true, client("act", cmd.arg))
				elseif cmd.cmd == "eval" then
					post(cmd.id, true, client("eval", cmd.arg))
				elseif cmd.cmd == "sdiag" then
					post(cmd.id, true, serverDiag())
				elseif cmd.cmd == "slog" then
					post(cmd.id, true, serverLog())
				elseif cmd.cmd == "sanim" then
					post(cmd.id, true, serverAnim())
				elseif cmd.cmd == "sfix" then
					post(cmd.id, true, serverFix())
				elseif cmd.cmd == "seval" then
					post(cmd.id, true, serverEval(cmd.arg))
				elseif cmd.cmd == "slog2" then
					post(cmd.id, true, serverLogs(cmd.arg))
				elseif cmd.cmd == "shit" then
					post(cmd.id, true, serverHitTest())
				elseif cmd.cmd == "snpc" then
					post(cmd.id, true, serverNpc())
				else
					post(cmd.id, false, "unknown play cmd: " .. tostring(cmd.cmd))
				end
			end)
			if not okDispatch then
				post(cmd.id, false, "play cmd '" .. tostring(cmd.cmd) .. "' threw: " .. tostring(dispatchErr))
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
	elseif verb == "camera" then
		local cam = workspace.CurrentCamera
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if cam and hrp then
			cam.CameraType = Enum.CameraType.Scriptable
			cam.CFrame = CFrame.lookAt(hrp.Position + hrp.CFrame.LookVector * 7 + Vector3.new(0, 1.5, 0), hrp.Position + Vector3.new(0, 1, 0))
			return "camera set"
		end
		return "no camera/char"
	elseif verb == "closecam" then
		-- 3/4 view from the rig's RIGHT (the sword side), full upper body so the arm + blade read clearly
		local cam = workspace.CurrentCamera
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if cam and hrp then
			cam.CameraType = Enum.CameraType.Scriptable
			local focus = hrp.Position + Vector3.new(0, 0.8, 0)
			cam.CFrame = CFrame.lookAt(focus + hrp.CFrame.LookVector * 5.5 + hrp.CFrame.RightVector * 3.5 + Vector3.new(0, 1, 0), focus)
			return "close camera set"
		end
		return "no char"
	elseif verb == "profilecam" then
		-- pure side profile from the rig's RIGHT, so the blade's up/down/forward direction is unambiguous
		local cam = workspace.CurrentCamera
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if cam and hrp then
			cam.CameraType = Enum.CameraType.Scriptable
			local focus = hrp.Position + Vector3.new(0, 0.5, 0)
			cam.CFrame = CFrame.lookAt(focus + hrp.CFrame.RightVector * 7, focus)
			return "profile camera set"
		end
		return "no char"
	elseif verb == "record" then
		-- VERIFY the #3 behavior state machine: equip + activate the Tool, then sample its ItemState
		-- attribute (set client-side by ItemBehaviorRuntime) for 3s and return the transition sequence.
		local backpack = plr:FindFirstChild("Backpack")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local tool = (char and char:FindFirstChildOfClass("Tool"))
			or (backpack and backpack:FindFirstChildOfClass("Tool"))
		if not (hum and tool) then
			return "record: no humanoid/tool"
		end
		if tool.Parent ~= char then
			hum:EquipTool(tool)
			task.wait(0.4)
		end
		tool:Activate()
		local samples, last, t0 = {}, nil, os.clock()
		while os.clock() - t0 < 3 do
			local st = tostring(tool:GetAttribute("ItemState"))
			if st ~= last then
				table.insert(samples, string.format("%.2f:%s", os.clock() - t0, st))
				last = st
			end
			task.wait(0.05)
		end
		-- Identity + config echo: WHICH tool ran, with WHAT timing attributes (diagnoses a clone
		-- that lost/never had its Behavior* attributes vs a runtime ignoring them). NOTE: no .Source
		-- reads here — runtime Source access needs PluginSecurity and would kill this handler.
		local cfg = string.format(
			" [tool=%s w=%s a=%s c=%s]",
			tool.Name,
			tostring(tool:GetAttribute("BehaviorWindup")),
			tostring(tool:GetAttribute("BehaviorActive")),
			tostring(tool:GetAttribute("BehaviorCooldown"))
		)
		return "ItemState " .. table.concat(samples, " -> ") .. cfg
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

-- Saved StarterPlayer.LoadCharacterAppearance, restored after the test. We force it OFF for the test so
-- the player spawns as the clean default blocky R15 (default animations, no custom costume) -- the custom
-- web avatar renders splayed/unreadable in the Play Solo capture even after the Motor6D conversion, so a
-- clean body is both the fix and a more readable self-verification subject.
local savedAppearance: boolean? = nil

-- Restore the StarterPlayer property we changed for the test (so the user's place config is unchanged).
-- NOTE (live-verified 2026-07-01): ServerScriptService.LoadStringEnabled is NOT SCRIPTABLE (reading it
-- throws even at PluginSecurity), so the plugin CANNOT gate it on for `seval` — playtest_eval needs the
-- user to tick it once in ServerScriptService's Properties (a manual per-place toggle, same class as
-- "Allow HTTP Requests"); serverEval returns a clear guarded message when it is off.
function PlayBridge.restoreStarterPlayer()
	if savedAppearance ~= nil then
		pcall(function()
			game:GetService("StarterPlayer").LoadCharacterAppearance = savedAppearance
		end)
		savedAppearance = nil
	end
end

-- Inject the relay + server + client scripts into the place (idempotent: remove any prior copies first).
local function injectTestScripts(base: string)
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local ServerScriptService = game:GetService("ServerScriptService")
	local StarterPlayer = game:GetService("StarterPlayer")
	local starterScripts = StarterPlayer:FindFirstChildOfClass("StarterPlayerScripts")
	PlayBridge.cleanupTestScripts()
	-- Force the clean default avatar for the test (saved/restored around the test).
	if savedAppearance == nil then
		savedAppearance = StarterPlayer.LoadCharacterAppearance
	end
	StarterPlayer.LoadCharacterAppearance = false
	local relay = Instance.new("RemoteEvent")
	relay.Name = RELAY_NAME
	relay.Parent = ReplicatedStorage
	local server = Instance.new("Script")
	server.Name = SERVER_NAME
	server.Source = string.gsub(SERVER_SRC, "__BASE__", base)
	server:SetAttribute("StudioAgentGenerated", true) -- identity marker: game_pull excludes on this
	server.Parent = ServerScriptService
	if starterScripts ~= nil then
		local client = Instance.new("LocalScript")
		client.Name = CLIENT_NAME
		client.Source = CLIENT_SRC
		client:SetAttribute("StudioAgentGenerated", true)
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
							PlayBridge.restoreStarterPlayer()
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
			-- Supervisor cadence (>= 1.5s), NOT the fast command-pull tick: a play start is a rare
			-- shell event, and this loop's GET counts against the shared HttpService budget.
			task.wait(deps.config:getSupervisorPollInterval())
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
