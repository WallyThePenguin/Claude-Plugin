--!strict
-- Specs for WaveTable, the difficulty curve.
--
-- Requires ArenaConfig directly, which works because ArenaConfig is pure data with no
-- requires of its own. So these specs assert against the REAL shipped numbers, not a
-- fixture that could drift from them -- if someone retunes the game and breaks the curve's
-- shape, this fails.

local WaveTable = require("../src/ReplicatedStorage/WaveTable")
local ArenaConfig = require("../src/ReplicatedStorage/ArenaConfig")

local WAVES = ArenaConfig.Waves

return function(t)
	t.test("wave 1 is the configured baseline", function(expect)
		local first = WaveTable.compose(1, WAVES)
		expect(first.wave).toBe(1)
		expect(first.count).toBe(WAVES.baseCount)
		expect(first.health).toBe(WAVES.baseHealth)
		expect(first.damage).toBe(WAVES.baseDamage)
		expect(first.elite).toBe(false)
	end)

	-- The curve is deliberately a SAWTOOTH, not a straight line: an elite wave is a spike,
	-- and the wave after it is easier than the spike was. That is the classic boss-then-
	-- breather rhythm and it is intended. So the property worth asserting is that the
	-- BASELINE rises -- each ordinary wave harder than the last ordinary wave.
	t.test("the ordinary-wave baseline rises monotonically", function(expect)
		local previous: number? = nil
		for wave = 1, WAVES.count do
			local current = WaveTable.compose(wave, WAVES)
			if not current.elite then
				if previous ~= nil then
					expect(current.health > previous).toBe(true)
				end
				previous = current.health
			end
		end
	end)

	t.test("an elite wave spikes above both of its neighbours", function(expect)
		local elite = WaveTable.compose(WAVES.eliteEvery, WAVES)
		local before = WaveTable.compose(WAVES.eliteEvery - 1, WAVES)
		local after = WaveTable.compose(WAVES.eliteEvery + 1, WAVES)
		expect(elite.elite).toBe(true)
		expect(after.elite).toBe(false)
		expect(elite.health > before.health).toBe(true)
		-- The breather: the wave after a spike really is easier than the spike.
		expect(elite.health > after.health).toBe(true)
	end)

	-- A longer fight is tense; a faster death is just unfair.
	t.test("health grows faster than damage", function(expect)
		local first = WaveTable.compose(1, WAVES)
		local last = WaveTable.compose(WAVES.count, WAVES)
		local healthRatio = last.health / first.health
		local damageRatio = last.damage / first.damage
		expect(healthRatio > damageRatio).toBe(true)
	end)

	t.test("speed is capped so enemies never outrun the player", function(expect)
		for wave = 1, 50 do
			local composition = WaveTable.compose(wave, WAVES)
			expect(composition.speed <= WAVES.maxSpeed).toBe(true)
		end
	end)

	t.test("elite waves land on the configured cadence", function(expect)
		expect(WaveTable.compose(WAVES.eliteEvery, WAVES).elite).toBe(true)
		expect(WaveTable.compose(WAVES.eliteEvery * 2, WAVES).elite).toBe(true)
		expect(WaveTable.compose(1, WAVES).elite).toBe(false)
	end)

	t.test("an elite wave trades headcount for threat", function(expect)
		local elite = WaveTable.compose(WAVES.eliteEvery, WAVES)
		local plain = WaveTable.compose(WAVES.eliteEvery - 1, WAVES)
		expect(elite.count <= plain.count).toBe(true)
		expect(elite.health > plain.health * 2).toBe(true)
		-- Never zero enemies, however aggressive the divisor.
		expect(elite.count >= 1).toBe(true)
	end)

	-- This is a PERFORMANCE bound, not a difficulty one: a wave of sixty NPCs tanks the
	-- server for everyone, which is a bug, not a challenge.
	t.test("concurrency never exceeds the performance ceiling", function(expect)
		for wave = 1, 100 do
			local composition = WaveTable.compose(wave, WAVES)
			expect(composition.concurrent <= WAVES.maxConcurrent).toBe(true)
			expect(composition.concurrent <= composition.count).toBe(true)
		end
	end)

	t.test("every stat stays a sane finite number deep into a run", function(expect)
		for wave = 1, 100 do
			local c = WaveTable.compose(wave, WAVES)
			expect(c.health == c.health).toBe(true) -- not NaN
			expect(c.health ~= math.huge).toBe(true)
			expect(c.health % 1 == 0).toBe(true)
			expect(c.damage % 1 == 0).toBe(true)
			expect(c.count % 1 == 0).toBe(true)
			expect(c.count >= 1).toBe(true)
		end
	end)

	t.test("rejects a non-positive or fractional wave number", function(expect)
		expect(function()
			WaveTable.compose(0, WAVES)
		end).toThrow("positive integer")
		expect(function()
			WaveTable.compose(1.5, WAVES)
		end).toThrow("positive integer")
	end)

	t.test("run() yields exactly the configured number of waves", function(expect)
		local run = WaveTable.run(WAVES)
		expect(#run).toBe(WAVES.count)
		expect(run[1].wave).toBe(1)
		expect(run[#run].wave).toBe(WAVES.count)
	end)

	-- Derived from compose() rather than restating the formula, so a curve change cannot
	-- silently desync the progress UI from what actually spawns.
	t.test("totalEnemies agrees with the sum of every wave", function(expect)
		local manual = 0
		for _, composition in WaveTable.run(WAVES) do
			manual += composition.count
		end
		expect(WaveTable.totalEnemies(WAVES)).toBe(manual)
	end)

	-- Spawn points
	t.test("spawn points sit on the requested circle", function(expect)
		local points = WaveTable.spawnPoints(8, 40, 4)
		expect(#points).toBe(8)
		for _, point in points do
			local distance = math.sqrt(point.X * point.X + point.Z * point.Z)
			expect(distance).toBeCloseTo(40, 1e-6)
			expect(point.Y).toBe(4)
		end
	end)

	-- Enemies appearing in identical spots every wave reads as scripted.
	t.test("the offset rotates the ring", function(expect)
		local a = WaveTable.spawnPoints(4, 40, 4, 0)
		local b = WaveTable.spawnPoints(4, 40, 4, 0.5)
		expect(a[1].X ~= b[1].X).toBe(true)
	end)

	t.test("spawn points handle the degenerate counts", function(expect)
		expect(#WaveTable.spawnPoints(0, 40, 4)).toBe(0)
		expect(#WaveTable.spawnPoints(1, 40, 4)).toBe(1)
		expect(function()
			WaveTable.spawnPoints(-1, 40, 4)
		end).toThrow("non-negative integer")
	end)

	-- Rewards
	t.test("a victory pays more than a defeat at the same depth", function(expect)
		local rewards = ArenaConfig.Rewards
		local won = WaveTable.reward(8, 60, true, rewards)
		local lost = WaveTable.reward(8, 60, false, rewards)
		expect(won > lost).toBe(true)
	end)

	-- Consolation must not compete with winning, or there is no reason to win.
	t.test("consolation never exceeds the victory bonus", function(expect)
		local rewards = ArenaConfig.Rewards
		local consolation = rewards.defeatBase + ArenaConfig.Waves.count * rewards.defeatPerWave
		expect(consolation < rewards.victory).toBe(true)
	end)

	t.test("rewards scale with depth and always come out as integers", function(expect)
		local rewards = ArenaConfig.Rewards
		local shallow = WaveTable.reward(1, 3, false, rewards)
		local deep = WaveTable.reward(6, 40, false, rewards)
		expect(deep > shallow).toBe(true)
		expect(shallow % 1).toBe(0)
		expect(deep % 1).toBe(0)
		-- forge-economy rejects fractional deltas outright, so this is load-bearing.
		expect(WaveTable.reward(0, 0, false, rewards) % 1).toBe(0)
	end)

	t.test("a run with nothing cleared still pays the base consolation", function(expect)
		local rewards = ArenaConfig.Rewards
		expect(WaveTable.reward(0, 0, false, rewards)).toBe(rewards.defeatBase)
	end)
end
