--!strict
-- Specs for the fakes themselves.
--
-- Testing test doubles is not busywork here: every other package's specs rest on these, so
-- a fake that lies quietly would make a whole suite green and wrong.

local FakeClock = require("../src/FakeClock")
local FakeSignal = require("../src/FakeSignal")
local FakeDataStore = require("../src/FakeDataStore")
local FakePlayers = require("../src/FakePlayers")
local FakeRemote = require("../src/FakeRemote")

return function(t)
	-- ---------------------------------------------------------------- clock

	t.test("clock advances and reports", function(expect)
		local clock = FakeClock.new(10)
		expect(clock.Now()).toBe(10)
		expect(clock.Advance(5)).toBe(15)
		expect(clock.Now()).toBe(15)
	end)

	t.test("clock fires delayed callbacks in time order", function(expect)
		local clock = FakeClock.new()
		local fired = {}
		clock.Delay(3, function()
			table.insert(fired, "third")
		end)
		clock.Delay(1, function()
			table.insert(fired, "first")
		end)
		clock.Advance(0.5)
		expect(#fired).toBe(0)
		clock.Advance(5)
		expect(fired).toEqual({ "first", "third" })
	end)

	t.test("a delayed callback may schedule another that is already due", function(expect)
		local clock = FakeClock.new()
		local count = 0
		local function tick()
			count += 1
			if count < 3 then
				clock.Delay(0, tick)
			end
		end
		clock.Delay(1, tick)
		clock.Advance(1)
		expect(count).toBe(3)
	end)

	-- Non-monotonic clocks are a real condition (see RateLimit), so the fake must be able
	-- to express one.
	t.test("clock can be set backwards", function(expect)
		local clock = FakeClock.new(100)
		clock.Set(50)
		expect(clock.Now()).toBe(50)
		expect(function()
			clock.Advance(-1)
		end).toThrow("cannot advance backwards")
	end)

	-- ---------------------------------------------------------------- signal

	t.test("signal fires every connected handler with the payload", function(expect)
		local signal = FakeSignal.new()
		local seen = {}
		signal:Connect(function(value)
			table.insert(seen, value)
		end)
		signal:Connect(function(value)
			table.insert(seen, value * 2)
		end)
		signal:Fire(3)
		expect(seen).toEqual({ 3, 6 })
	end)

	t.test("disconnected handlers stop receiving", function(expect)
		local signal = FakeSignal.new()
		local count = 0
		local connection = signal:Connect(function()
			count += 1
		end)
		signal:Fire()
		connection:Disconnect()
		signal:Fire()
		expect(count).toBe(1)
		expect(connection.Connected).toBe(false)
		expect(signal:Count()).toBe(0)
	end)

	t.test("Once fires exactly once", function(expect)
		local signal = FakeSignal.new()
		local count = 0
		signal:Once(function()
			count += 1
		end)
		signal:Fire()
		signal:Fire()
		expect(count).toBe(1)
	end)

	-- A handler disconnecting mid-fire must not cause the iteration to skip its
	-- neighbour, which is what happens if you mutate the list you are walking.
	t.test("a handler disconnecting during Fire does not skip others", function(expect)
		local signal = FakeSignal.new()
		local seen = {}
		local first
		first = signal:Connect(function()
			table.insert(seen, "a")
			first:Disconnect()
		end)
		signal:Connect(function()
			table.insert(seen, "b")
		end)
		signal:Fire()
		expect(seen).toEqual({ "a", "b" })
	end)

	-- ---------------------------------------------------------------- datastore

	t.test("datastore stores and retrieves", function(expect)
		local store = FakeDataStore.new()
		store:SetAsync("p1", { coins = 5 })
		expect(store:GetAsync("p1").coins).toBe(5)
		expect(store:GetAsync("missing")).toBeNil()
	end)

	-- The real service serialises, so a caller cannot hold a live reference. A fake that
	-- returns the same table would hide code that mutates what it believes is private.
	t.test("datastore hands back copies, not live references", function(expect)
		local store = FakeDataStore.new()
		store:SetAsync("p1", { coins = 5 })
		local got = store:GetAsync("p1")
		got.coins = 999
		expect(store:GetAsync("p1").coins).toBe(5)

		local source = { coins = 1 }
		store:SetAsync("p2", source)
		source.coins = 42
		expect(store:GetAsync("p2").coins).toBe(1)
	end)

	t.test("UpdateAsync sees the current value and returns the new one", function(expect)
		local store = FakeDataStore.new()
		store:Seed("p1", { coins = 5 })
		local result = store:UpdateAsync("p1", function(current)
			current.coins += 3
			return current
		end)
		expect(result.coins).toBe(8)
		expect(store:Peek("p1").coins).toBe(8)
	end)

	t.test("UpdateAsync returning nil aborts the write, as the real API does", function(expect)
		local store = FakeDataStore.new()
		store:Seed("p1", { coins = 5 })
		local result = store:UpdateAsync("p1", function()
			return nil
		end)
		expect(result).toBeNil()
		expect(store:Peek("p1").coins).toBe(5)
	end)

	-- This is the whole reason the fake exists: retry-with-backoff cannot be tested
	-- against the real service.
	t.test("FailNext fails exactly that many calls then recovers", function(expect)
		local store = FakeDataStore.new()
		store:Seed("p1", { coins = 1 })
		store:FailNext(2, "throttled")

		expect(function()
			store:GetAsync("p1")
		end).toThrow("throttled")
		expect(function()
			store:GetAsync("p1")
		end).toThrow("throttled")
		expect(store:GetAsync("p1").coins).toBe(1)
	end)

	t.test("FailAlways exercises the give-up path until stopped", function(expect)
		local store = FakeDataStore.new()
		store:FailAlways()
		expect(function()
			store:SetAsync("p1", 1)
		end).toThrow()
		store:StopFailing()
		store:SetAsync("p1", 1)
		expect(store:GetAsync("p1")).toBe(1)
	end)

	t.test("records every call, including the failures", function(expect)
		local store = FakeDataStore.new()
		store:FailNext(1)
		pcall(function()
			store:GetAsync("p1")
		end)
		store:SetAsync("p1", 1)
		local calls = store:Calls()
		expect(#calls).toBe(2)
		expect(calls[1].ok).toBe(false)
		expect(calls[2].method).toBe("SetAsync")
		expect(store:CallCount("SetAsync")).toBe(1)
	end)

	-- Seed and Peek must be invisible, or assertions on call counts become useless.
	t.test("Seed and Peek do not record calls", function(expect)
		local store = FakeDataStore.new()
		store:Seed("p1", 1)
		store:Peek("p1")
		expect(store:CallCount()).toBe(0)
	end)

	-- ---------------------------------------------------------------- players

	t.test("players fires PlayerAdded and PlayerRemoving", function(expect)
		local players = FakePlayers.new()
		local log = {}
		players.PlayerAdded:Connect(function(player)
			table.insert(log, `+{player.Name}`)
		end)
		players.PlayerRemoving:Connect(function(player)
			table.insert(log, `-{player.Name}`)
		end)

		local alice = players:Add("Alice", 100)
		expect(players:Count()).toBe(1)
		expect(players:GetPlayerByUserId(100)).toBe(alice)
		players:Remove(alice)
		expect(players:Count()).toBe(0)
		expect(log).toEqual({ "+Alice", "-Alice" })
	end)

	-- Matches the real service: the player is still listed while PlayerRemoving runs, so
	-- handlers that iterate players during removal behave the same way.
	t.test("PlayerRemoving fires while the player is still listed", function(expect)
		local players = FakePlayers.new()
		local alice = players:Add("Alice")
		local countDuring = -1
		players.PlayerRemoving:Connect(function()
			countDuring = players:Count()
		end)
		players:Remove(alice)
		expect(countDuring).toBe(1)
	end)

	t.test("Kick is recorded rather than acted on", function(expect)
		local players = FakePlayers.new()
		local alice = players:Add("Alice")
		alice:Kick("cheating")
		expect(alice.KickReasons).toEqual({ "cheating" })
	end)

	t.test("removing an unknown player is a no-op", function(expect)
		local players = FakePlayers.new()
		players:Remove({ Name = "Ghost", UserId = 1 } :: any)
		expect(players:Count()).toBe(0)
	end)

	-- ---------------------------------------------------------------- remotes

	t.test("remote event delivers client-to-server with the sender", function(expect)
		local remote = FakeRemote.event()
		local received = {}
		remote.OnServerEvent:Connect(function(player, amount)
			table.insert(received, { name = player.Name, amount = amount })
		end)
		remote:FireServer({ Name = "Alice", UserId = 1 }, 7)
		expect(#received).toBe(1)
		expect(received[1].name).toBe("Alice")
		expect(received[1].amount).toBe(7)
	end)

	t.test("remote event records server-to-client sends", function(expect)
		local remote = FakeRemote.event()
		local alice = { Name = "Alice", UserId = 1 }
		remote:FireClient(alice, "hit", 12)
		remote:FireAllClients("round-over")
		local sent = remote:Sent()
		expect(#sent).toBe(2)
		expect(sent[1].player).toBe(alice)
		expect(sent[1].args[1]).toBe("hit")
		expect(sent[2].player).toBe("all")
		remote:ClearSent()
		expect(#remote:Sent()).toBe(0)
	end)

	t.test("remote function invokes the bound handler and returns its result", function(expect)
		local remote = FakeRemote.func()
		remote.OnServerInvoke = function(player, a, b)
			return a + b, player.Name
		end
		local sum, name = remote:InvokeServer({ Name = "Alice", UserId = 1 }, 2, 3)
		expect(sum).toBe(5)
		expect(name).toBe("Alice")
	end)

	-- An unbound OnServerInvoke shows up in production as a mysterious client hang, so
	-- the fake surfaces it loudly instead.
	t.test("an unbound remote function errors", function(expect)
		local remote = FakeRemote.func()
		expect(function()
			remote:InvokeServer({ Name = "Alice", UserId = 1 })
		end).toThrow("OnServerInvoke is not bound")
	end)
end
