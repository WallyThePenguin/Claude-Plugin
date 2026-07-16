-- ForgeRoundLoop: Forge Arena core loop - intermission -> wave -> clear -> ... -> victory.
-- P1 skeleton: placeholder enemies (no AI yet - P3 replaces the template via make_npc).
-- TEST ONLY: the workspace attribute ForgeTestAutoKill lets unmanned playtests verify progression.

local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("ForgeConfig"))
local template = ServerStorage:WaitForChild("ForgeEnemyTemplate")

local alive = 0

local function spawnPoint(i: number, count: number): CFrame
	local angle = (i / count) * math.pi * 2
	local r = Config.SpawnRadius
	return CFrame.new(math.cos(angle) * r, 4, math.sin(angle) * r)
end

local function spawnEnemy(cf: CFrame, wave: number)
	local enemy = template:Clone()
	local humanoid = enemy:WaitForChild("Humanoid") :: Humanoid
	humanoid.MaxHealth = Config.EnemyHealth(wave)
	humanoid.Health = humanoid.MaxHealth
	enemy:PivotTo(cf)
	enemy.Parent = Workspace
	alive += 1
	humanoid.Died:Connect(function()
		alive -= 1
		task.delay(2, function()
			enemy:Destroy()
		end)
	end)
	if Workspace:GetAttribute("ForgeTestAutoKill") then
		task.delay(1, function()
			if humanoid.Health > 0 then
				humanoid.Health = 0
			end
		end)
	end
end

local function runWave(wave: number)
	local count = Config.EnemiesPerWave(wave)
	print(("[Forge] wave %d: spawning %d enemies"):format(wave, count))
	for i = 1, count do
		spawnEnemy(spawnPoint(i, count), wave)
	end
	while alive > 0 do
		task.wait(0.25)
	end
	print(("[Forge] wave %d cleared"):format(wave))
end

while true do
	print(("[Forge] intermission (%ds)"):format(Config.IntermissionSeconds))
	task.wait(Config.IntermissionSeconds)
	for wave = 1, Config.WavesToWin do
		runWave(wave)
	end
	print("[Forge] VICTORY - all waves cleared")
	task.wait(6)
	print("[Forge] restarting loop")
end
