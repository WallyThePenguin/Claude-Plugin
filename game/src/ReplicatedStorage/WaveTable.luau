--!strict
-- WaveTable: what a given wave is made of.
--
-- Pure functions of (waveNumber, config). No requires, no services -- config arrives as a
-- parameter rather than being imported, which is the same layering rule the forge-*
-- packages follow and for the same reason: this is the part of the game with real
-- arithmetic in it, so it is the part most worth testing, and a spec can only run it if it
-- has no Roblox dependencies.
--
-- The difficulty curve lives here rather than in ArenaConfig because a curve is a
-- computation. Config holds the constants; this turns them into a wave.

export type Composition = {
	wave: number,
	count: number,
	health: number,
	damage: number,
	speed: number,
	elite: boolean,
	-- Concurrent spawn cap for this wave, after the performance ceiling is applied.
	concurrent: number,
}

export type WaveConfig = {
	count: number,
	baseCount: number,
	countGrowth: number,
	maxConcurrent: number,
	baseHealth: number,
	healthGrowth: number,
	baseDamage: number,
	damageGrowth: number,
	baseSpeed: number,
	speedGrowth: number,
	maxSpeed: number,
	eliteEvery: number,
	eliteHealthMultiplier: number,
	eliteDamageMultiplier: number,
	eliteCountDivisor: number,
	breatherSeconds: number,
}

local WaveTable = {}

--[[
	Compose wave `wave` (1-based).

	Growth is exponential rather than linear so later waves feel like a different fight,
	not the same fight for longer. Health grows faster than damage on purpose: a longer
	fight is tense, a faster death is just unfair.
]]
function WaveTable.compose(wave: number, config: WaveConfig): Composition
	assert(wave >= 1 and wave % 1 == 0, "wave must be a positive integer")

	local elite = config.eliteEvery > 0 and wave % config.eliteEvery == 0

	local count = math.ceil(config.baseCount * config.countGrowth ^ (wave - 1))
	local health = math.floor(config.baseHealth * config.healthGrowth ^ (wave - 1))
	local damage = math.floor(config.baseDamage * config.damageGrowth ^ (wave - 1))
	local speed = math.min(config.maxSpeed, config.baseSpeed * config.speedGrowth ^ (wave - 1))

	if elite then
		-- An elite wave trades headcount for threat: fewer enemies, much harder ones.
		-- Same wave length, completely different fight.
		count = math.max(1, math.ceil(count / config.eliteCountDivisor))
		health = math.floor(health * config.eliteHealthMultiplier)
		damage = math.floor(damage * config.eliteDamageMultiplier)
	end

	-- The concurrency cap is a PERFORMANCE bound, not a difficulty one. Past it, difficulty
	-- comes from stats rather than headcount -- a wave of sixty NPCs tanks the server for
	-- everyone, which is not challenge, it is a bug.
	local concurrent = math.min(count, config.maxConcurrent)

	return {
		wave = wave,
		count = count,
		health = health,
		damage = damage,
		speed = speed,
		elite = elite,
		concurrent = concurrent,
	}
end

--[[ Every wave in a run, for previews and for reasoning about the whole curve at once. ]]
function WaveTable.run(config: WaveConfig): { Composition }
	local out = {}
	for wave = 1, config.count do
		table.insert(out, WaveTable.compose(wave, config))
	end
	return out
end

--[[
	Total enemies in a full run. Used for progress UI and for sizing rewards, so it must
	agree exactly with what actually spawns -- hence deriving it from compose() rather than
	restating the formula.
]]
function WaveTable.totalEnemies(config: WaveConfig): number
	local total = 0
	for _, composition in WaveTable.run(config) do
		total += composition.count
	end
	return total
end

--[[
	Evenly spaced spawn points on a circle, as plain {X, Y, Z} tables.

	Plain tables rather than Vector3 so this stays runnable under Lune -- the caller turns
	them into CFrames. `offset` rotates the ring per wave so enemies do not appear in
	exactly the same spots every time, which reads as scripted.
]]
function WaveTable.spawnPoints(
	count: number,
	radius: number,
	height: number,
	offset: number?
): { { X: number, Y: number, Z: number } }
	assert(count >= 0 and count % 1 == 0, "count must be a non-negative integer")
	local points = {}
	local rotation = offset or 0
	for index = 0, count - 1 do
		local angle = (index / math.max(1, count)) * math.pi * 2 + rotation
		table.insert(points, {
			X = math.cos(angle) * radius,
			Y = height,
			Z = math.sin(angle) * radius,
		})
	end
	return points
end

--[[
	Coins earned for a run. Kept here beside the curve it depends on: a reward table that
	drifts from the difficulty curve is how an economy quietly inflates.

	`wavesCleared` is how many FULLY cleared, `enemiesKilled` the total across the run.
]]
export type RewardConfig = {
	perEnemy: number,
	perWave: number,
	victory: number,
	defeatBase: number,
	defeatPerWave: number,
}

function WaveTable.reward(
	wavesCleared: number,
	enemiesKilled: number,
	victory: boolean,
	config: RewardConfig
): number
	local total = enemiesKilled * config.perEnemy + wavesCleared * config.perWave
	if victory then
		total += config.victory
	else
		-- A bad night should not be a total loss, but consolation must not compete with
		-- winning or there is no reason to win.
		total += config.defeatBase + wavesCleared * config.defeatPerWave
	end
	-- Currency is integer-only: forge-economy rejects fractional deltas outright.
	return math.floor(total)
end

return WaveTable
