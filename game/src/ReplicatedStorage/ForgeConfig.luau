-- ForgeConfig: Forge Arena round/wave tuning (data only; no logic lives here).
return {
	WavesToWin = 3,
	IntermissionSeconds = 4,
	SpawnRadius = 40,
	EnemiesPerWave = function(wave: number): number
		return 2 + wave * 2 -- 4, 6, 8
	end,
	EnemyHealth = function(wave: number): number
		return 40 + wave * 20
	end,
}
