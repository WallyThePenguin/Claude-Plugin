-- RoundLoop: server-authoritative wave-survival round loop.
-- Flow per wave: intermission -> spawn wave -> wait for all enemies dead -> next wave.
-- After the final wave: print VICTORY. Current wave is tracked on workspace attribute "CurrentWave".

local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local WaveConfig = require(ReplicatedStorage:WaitForChild("WaveConfig"))
local EnemyTemplate = ServerStorage:WaitForChild("EnemyTemplate")

local ARENA_CENTER = Vector3.new(0, 0, 0)
local SPAWN_RADIUS = 35 -- studs from center to ring enemies around
local SPAWN_HEIGHT = 3 -- lift so the enemy drops onto the floor cleanly

-- Reset the tracked wave counter for observers/GUIs.
Workspace:SetAttribute("CurrentWave", 0)

-- Spawn a single enemy from the template, configured for `wave`, at `position`.
local function spawnEnemy(wave: { [string]: number }, position: Vector3): Model
	local enemy = EnemyTemplate:Clone()
	enemy.Name = "Enemy"

	local humanoid = enemy:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.MaxHealth = wave.health
		humanoid.Health = wave.health
		humanoid.WalkSpeed = wave.walkSpeed
	end

	enemy.Parent = Workspace
	-- Test hook: when Workspace attribute TestAutoKill (seconds) is set, enemies self-destruct
	-- after that delay so the round loop can be verified in an unmanned playtest.
	local autoKill = Workspace:GetAttribute("TestAutoKill")
	if typeof(autoKill) == "number" and autoKill > 0 and humanoid then
		task.delay(autoKill, function()
			if humanoid.Parent ~= nil then
				humanoid.Health = 0
			end
		end)
	end
	-- PivotTo moves the whole welded model as one, keeping joints intact.
	enemy:PivotTo(CFrame.new(position + Vector3.new(0, SPAWN_HEIGHT, 0)))
	return enemy
end

-- Spawn the whole wave in a ring around the arena center; return the enemy list.
local function spawnWave(wave: { [string]: number }): { Model }
	local enemies = {}
	local count = wave.enemyCount
	for i = 1, count do
		local angle = (i / count) * math.pi * 2
		local offset = Vector3.new(math.cos(angle) * SPAWN_RADIUS, 0, math.sin(angle) * SPAWN_RADIUS)
		enemies[i] = spawnEnemy(wave, ARENA_CENTER + offset)
	end
	return enemies
end

-- Yield until every enemy in `enemies` has died (Humanoid.Died) or been removed.
local function waitForWaveCleared(enemies: { Model })
	local remaining = 0
	local finishedEvent = Instance.new("BindableEvent")

	local function onOneDown()
		remaining -= 1
		if remaining <= 0 then
			finishedEvent:Fire()
		end
	end

	for _, enemy in ipairs(enemies) do
		local humanoid = enemy:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			remaining += 1
			-- Count a death OR the model being destroyed as "down".
			local downed = false
			local function markDown()
				if not downed then
					downed = true
					onOneDown()
				end
			end
			humanoid.Died:Connect(markDown)
			enemy.AncestryChanged:Connect(function(_, parent)
				if parent == nil then
					markDown()
				end
			end)
		end
	end

	if remaining <= 0 then
		return -- nothing alive to wait on
	end

	finishedEvent.Event:Wait()
	finishedEvent:Destroy()
end

-- Main round loop.
local function runRound()
	for waveIndex, wave in ipairs(WaveConfig.Waves) do
		-- Intermission breather before this wave.
		task.wait(wave.intermission)

		Workspace:SetAttribute("CurrentWave", waveIndex)
		print(string.format("[RoundLoop] Wave %d starting: %d enemies (hp %d, ws %d)",
			waveIndex, wave.enemyCount, wave.health, wave.walkSpeed))

		local enemies = spawnWave(wave)
		waitForWaveCleared(enemies)

		print(string.format("[RoundLoop] Wave %d cleared.", waveIndex))
	end

	print("[RoundLoop] VICTORY - all waves survived!")
end

runRound()
