--!strict
-- ArenaConfig: every tuning number for Forge Arena, in one place.
--
-- PURE DATA. No requires, no services, no functions with logic in them. Two reasons:
--   * It lives in ReplicatedStorage so the client can read it -- the HUD needs wave counts
--     and the shop needs prices, and duplicating those numbers on the client is how they
--     drift apart.
--   * Config that imports code stops being config. If a value here needs a computation,
--     the computation belongs in WaveTable (pure, tested), not here.
--
-- Anything reusable across games lives in a forge-* package. What is left is this file:
-- decisions specific to Forge Arena.
--
-- SECURITY NOTE: everything here is readable by players. That is fine -- knowing an enemy
-- has 140 health does not let you exploit anything, because the server owns the damage.
-- Never put a threshold here whose secrecy is load-bearing.

return {
	Round = {
		-- One player can start a run. This is PvE: a solo run is a legitimate way to play,
		-- unlike a solo PvP match.
		minPlayers = 1,
		maxPlayers = 8,
		intermissionSeconds = 8,
		-- Ceiling on a whole run, not a wave. Generous: the wave logic ends a healthy run
		-- long before this. It exists so a stuck run cannot wedge the server forever.
		roundSeconds = 900,
		resultsSeconds = 10,
		-- PvE: the run ends when the arena empties out. Nobody left to fight for.
		abortBelowPlayers = 1,
	},

	Waves = {
		count = 8,
		-- Breather between waves. Long enough to reposition, short enough to keep tension.
		breatherSeconds = 6,
		-- Enemies in wave N = ceil(base * growth^(N-1)), capped. Exponential rather than
		-- linear so later waves feel like a different fight rather than the same one longer.
		baseCount = 3,
		countGrowth = 1.35,
		-- Concurrency cap. This is a PERFORMANCE bound, not a difficulty one: every live
		-- NPC costs pathfinding and replication, and a wave of 60 tanks the server for
		-- everyone. Difficulty past this point comes from stats, not headcount.
		maxConcurrent = 24,

		-- Enemy stats scale per wave. Health grows faster than damage: a longer fight is
		-- tense, a faster death is just unfair.
		baseHealth = 60,
		healthGrowth = 1.22,
		baseDamage = 8,
		damageGrowth = 1.08,
		baseSpeed = 10,
		speedGrowth = 1.03,
		maxSpeed = 22,

		-- Every Nth wave is an elite: fewer enemies, much tougher.
		eliteEvery = 4,
		eliteHealthMultiplier = 4,
		eliteDamageMultiplier = 1.6,
		eliteCountDivisor = 3,
	},

	Combat = {
		-- Arena footprint, used for spawn placement and movement plausibility bounds.
		arenaRadius = 58,
		spawnRadius = 46,
		-- Floor and ceiling for the Movement sanity check in forge-guard.
		minY = -25,
		maxY = 220,
		-- Highest legitimate player speed, including every sprint and knockback effect.
		-- forge-guard multiplies this by its own tolerance before flagging anything.
		maxPlayerSpeed = 24,
		respawnSeconds = 5,
	},

	Weapons = {
		-- Damage is what the SERVER applies. The client may show a number; it may not
		-- choose one.
		["ember-falchion"] = { range = 12, cooldown = 0.55, damage = 26 },
		["iron-cleaver"] = { range = 10, cooldown = 0.40, damage = 18 },
	},

	Rewards = {
		currency = "coins",
		perEnemy = 3,
		perWave = 25,
		-- Paid once for clearing every wave, on top of the per-wave rewards.
		victory = 200,
		-- Paid on a failed run so a bad night is not a total loss. Small on purpose:
		-- consolation should not compete with winning.
		defeatBase = 10,
		defeatPerWave = 8,
	},

	Net = {
		-- Per-player token buckets. A swing budget slightly above the fastest weapon's
		-- fire rate absorbs latency jitter without permitting a flood.
		swing = { rate = 3, burst = 5 },
		queue = { rate = 1, burst = 3 },
	},

	Guard = {
		-- Suspicion needed before a player is acted on, and how fast it bleeds off. Sized
		-- against forge-guard's arithmetic: decay applies BEFORE each report, so N
		-- weight-1 reports never reach a score of N.
		abuseThreshold = 12,
		abuseDecayPerSecond = 0.4,
	},

	Profile = {
		-- Bumped whenever the stored shape changes. forge-store's migrations run forward
		-- only, and a server must refuse data from a version it does not understand.
		schemaVersion = 1,
	},
}
