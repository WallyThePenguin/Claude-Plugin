--!strict
-- WaveConfig: data-only definition of the wave-survival rounds.
-- Consumed by ServerScriptService.RoundLoop.

export type Wave = {
	enemyCount: number, -- how many enemies to spawn this wave
	health: number, -- Humanoid.MaxHealth/Health for each enemy
	walkSpeed: number, -- Humanoid.WalkSpeed for each enemy
	intermission: number, -- seconds of breather BEFORE this wave spawns
}

local WaveConfig = {}

-- Ordered list of waves. Wave N == Waves[N].
WaveConfig.Waves = {
	{ enemyCount = 3, health = 50, walkSpeed = 10, intermission = 5 },
	{ enemyCount = 5, health = 75, walkSpeed = 13, intermission = 8 },
	{ enemyCount = 8, health = 120, walkSpeed = 16, intermission = 10 },
} :: { Wave }

-- Convenience: number of waves in the round.
WaveConfig.TotalWaves = #WaveConfig.Waves

return WaveConfig
