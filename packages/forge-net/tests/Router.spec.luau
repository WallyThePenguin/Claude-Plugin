--!strict
-- Specs for Router.
--
-- These reach across the workspace by file path - `../../forge-guard/src/RateLimit` and
-- `../../forge-testkit/src/FakeRemote`. Lune requires are file paths, so this is a dev-time
-- reference, NOT a Forest dependency: nothing here appears in forge-net's forest.json, and
-- `.forestignore` keeps tests out of the published archive. It lets the specs prove the
-- real integration rather than a mock of it.

local Router = require("../src/Router")
local RateLimit = require("../../forge-guard/src/RateLimit")
local Validate = require("../../forge-guard/src/Validate")
local FakeRemote = require("../../forge-testkit/src/FakeRemote")
local FakeClock = require("../../forge-testkit/src/FakeClock")

local function player(name: string, userId: number)
	return { Name = name, UserId = userId }
end

local ALICE = player("Alice", 1)
local BOB = player("Bob", 2)

return function(t)
	t.test("dispatches a valid call to the handler", function(expect)
		local router = Router.new()
		local seen
		router:Route("Swing", {
			validate = Validate.tuple({ Validate.integer(1, 9) }),
			handler = function(p, slot)
				seen = { name = p.Name, slot = slot }
			end,
		})
		local ok = router:Dispatch("Swing", ALICE, 3)
		expect(ok).toBe(true)
		expect(seen.name).toBe("Alice")
		expect(seen.slot).toBe(3)
		expect(router:Stats("Swing").accepted).toBe(1)
	end)

	t.test("returns whatever the handler returned", function(expect)
		local router = Router.new()
		router:Route("Query", {
			handler = function()
				return "a", "b"
			end,
		})
		local ok, first, second = router:Dispatch("Query", ALICE)
		expect(ok).toBe(true)
		expect(first).toBe("a")
		expect(second).toBe("b")
	end)

	t.test("rejects a malformed payload without calling the handler", function(expect)
		local router = Router.new()
		local called = false
		router:Route("Swing", {
			validate = Validate.tuple({ Validate.integer(1, 9) }),
			handler = function()
				called = true
			end,
		})
		expect(router:Dispatch("Swing", ALICE, 99)).toBe(false)
		expect(router:Dispatch("Swing", ALICE, 0 / 0)).toBe(false)
		expect(router:Dispatch("Swing", ALICE)).toBe(false)
		expect(router:Dispatch("Swing", ALICE, 3, "extra")).toBe(false)
		expect(called).toBe(false)
		expect(router:Stats("Swing").rejectedInvalid).toBe(4)
	end)

	-- Rate BEFORE validate. If validation ran first, an attacker would still burn CPU on
	-- 500 malformed calls a second.
	t.test("checks rate before validating, so a flood costs nothing", function(expect)
		local clock = FakeClock.new()
		local router = Router.new()
		local validations = 0
		router:Route("Swing", {
			rateLimit = RateLimit.new({ rate = 1, burst = 1 }, clock.Now),
			validate = function()
				validations += 1
				return false, "always bad"
			end,
			handler = function() end,
		})

		-- First call is in budget, so it reaches validation and fails there.
		expect(router:Dispatch("Swing", ALICE, "junk")).toBe(false)
		-- Everything after is refused at the gate; the validator is never consulted.
		for _ = 1, 50 do
			router:Dispatch("Swing", ALICE, "junk")
		end
		expect(validations).toBe(1)

		local stats = router:Stats("Swing")
		expect(stats.rejectedInvalid).toBe(1)
		expect(stats.rejectedRate).toBe(50)
	end)

	t.test("rate limits per caller, not globally", function(expect)
		local clock = FakeClock.new()
		local router = Router.new()
		router:Route("Swing", {
			rateLimit = RateLimit.new({ rate = 1, burst = 1 }, clock.Now),
			handler = function() end,
		})
		expect(router:Dispatch("Swing", ALICE)).toBe(true)
		expect(router:Dispatch("Swing", ALICE)).toBe(false)
		-- Alice exhausting her budget must not affect Bob.
		expect(router:Dispatch("Swing", BOB)).toBe(true)
	end)

	t.test("budget refills over time", function(expect)
		local clock = FakeClock.new()
		local router = Router.new()
		router:Route("Swing", {
			rateLimit = RateLimit.new({ rate = 2, burst = 1 }, clock.Now),
			handler = function() end,
		})
		expect(router:Dispatch("Swing", ALICE)).toBe(true)
		expect(router:Dispatch("Swing", ALICE)).toBe(false)
		clock.Advance(0.5)
		expect(router:Dispatch("Swing", ALICE)).toBe(true)
	end)

	t.test("cost makes an expensive route weigh more", function(expect)
		local clock = FakeClock.new()
		local router = Router.new()
		local limiter = RateLimit.new({ rate = 1, burst = 10 }, clock.Now)
		router:Route("Cheap", { rateLimit = limiter, cost = 1, handler = function() end })
		router:Route("Expensive", { rateLimit = limiter, cost = 9, handler = function() end })
		expect(router:Dispatch("Expensive", ALICE)).toBe(true)
		-- Shared limiter: the expensive call drained the shared bucket.
		expect(router:Dispatch("Cheap", ALICE)).toBe(true)
		expect(router:Dispatch("Cheap", ALICE)).toBe(false)
	end)

	-- Roblox swallows an error thrown inside OnServerEvent, so without containment a
	-- failing handler is invisible for weeks.
	t.test("contains a throwing handler and reports it", function(expect)
		local errors = {}
		local router = Router.new({
			onError = function(_p, route, err)
				table.insert(errors, { route = route, err = err })
			end,
		})
		router:Route("Boom", {
			handler = function()
				error("kaboom")
			end,
		})
		expect(router:Dispatch("Boom", ALICE)).toBe(false)
		expect(#errors).toBe(1)
		expect(errors[1].route).toBe("Boom")
		expect(errors[1].err).toContain("kaboom")
		expect(router:Stats("Boom").errored).toBe(1)
		-- A later good call still works: one bad handler does not poison the router.
		router:Route("Fine", { handler = function() end })
		expect(router:Dispatch("Fine", ALICE)).toBe(true)
	end)

	t.test("onReject reports the kind, and the reason only to us", function(expect)
		local clock = FakeClock.new()
		local rejections = {}
		local router = Router.new({
			onReject = function(_p, _route, kind, reason)
				table.insert(rejections, { kind = kind, reason = reason })
			end,
		})
		router:Route("Swing", {
			rateLimit = RateLimit.new({ rate = 1, burst = 1 }, clock.Now),
			validate = Validate.tuple({ Validate.integer(1, 9) }),
			handler = function() end,
		})

		router:Dispatch("Swing", ALICE, 99) -- invalid
		router:Dispatch("Swing", ALICE, 5) -- rate
		expect(rejections[1].kind).toBe("invalid")
		expect(rejections[1].reason).toContain("arg 1")
		expect(rejections[2].kind).toBe("rate")
		-- No reason for a rate rejection: there is nothing an attacker could learn
		-- from it that they do not already know.
		expect(rejections[2].reason).toBeNil()
	end)

	t.test("Forget clears a player's budget across routes", function(expect)
		local clock = FakeClock.new()
		local router = Router.new()
		local limiter = RateLimit.new({ rate = 1, burst = 1 }, clock.Now)
		router:Route("A", { rateLimit = limiter, handler = function() end })
		router:Route("B", { rateLimit = limiter, handler = function() end })
		expect(router:Dispatch("A", ALICE)).toBe(true)
		expect(router:Dispatch("B", ALICE)).toBe(false)
		router:Forget(ALICE)
		expect(router:Dispatch("B", ALICE)).toBe(true)
	end)

	-- BindToClose: reject new work rather than start something that cannot finish,
	-- especially anything that was about to write to a datastore.
	t.test("Close rejects everything afterwards", function(expect)
		local kinds = {}
		local router = Router.new({
			onReject = function(_p, _route, kind)
				table.insert(kinds, kind)
			end,
		})
		local calls = 0
		router:Route("Save", {
			handler = function()
				calls += 1
			end,
		})
		expect(router:Dispatch("Save", ALICE)).toBe(true)
		expect(router:IsOpen()).toBe(true)
		router:Close()
		expect(router:IsOpen()).toBe(false)
		expect(router:Dispatch("Save", ALICE)).toBe(false)
		expect(calls).toBe(1)
		expect(kinds).toEqual({ "closed" })
	end)

	t.test("UnlimitedRoutes surfaces routes with no budget", function(expect)
		local clock = FakeClock.new()
		local router = Router.new()
		router:Route("Guarded", {
			rateLimit = RateLimit.new({ rate = 1 }, clock.Now),
			handler = function() end,
		})
		router:Route("Open", { handler = function() end })
		router:Route("AlsoOpen", { handler = function() end })
		expect(router:UnlimitedRoutes()).toEqual({ "AlsoOpen", "Open" })
		expect(router:Routes()).toEqual({ "AlsoOpen", "Guarded", "Open" })
	end)

	t.test("rejects duplicate routes and handler-less routes", function(expect)
		local router = Router.new()
		router:Route("A", { handler = function() end })
		expect(function()
			router:Route("A", { handler = function() end })
		end).toThrow("duplicate route A")
		expect(function()
			router:Route("B", {} :: any)
		end).toThrow("needs a handler")
		expect(function()
			router:Route("", { handler = function() end })
		end).toThrow("non-empty name")
	end)

	t.test("an unknown route is a server bug, so it errors loudly", function(expect)
		local router = Router.new()
		expect(function()
			router:Dispatch("Nope", ALICE)
		end).toThrow("no route named Nope")
		expect(function()
			router:Stats("Nope")
		end).toThrow("no route named Nope")
	end)

	t.test("Stats returns a copy", function(expect)
		local router = Router.new()
		router:Route("A", { handler = function() end })
		local stats = router:Stats("A")
		stats.accepted = 999
		expect(router:Stats("A").accepted).toBe(0)
	end)

	-- End to end through a fake RemoteEvent: this is the shape production code has, and
	-- the fake lets a spec send what no honest client could.
	t.test("works end to end wired to a remote event", function(expect)
		local clock = FakeClock.new()
		local remote = FakeRemote.event()
		local router = Router.new()
		local damageApplied = 0

		router:Route("Hit", {
			rateLimit = RateLimit.new({ rate = 2, burst = 2 }, clock.Now),
			validate = Validate.tuple({ Validate.integer(1, 100) }),
			handler = function(_p, amount)
				damageApplied += amount
			end,
		})
		remote.OnServerEvent:Connect(function(p, ...)
			router:Dispatch("Hit", p, ...)
		end)

		remote:FireServer(ALICE, 10)
		remote:FireServer(ALICE, 15)
		expect(damageApplied).toBe(25)

		-- A hostile client: out of range, then NaN, then a flood. None land.
		remote:FireServer(ALICE, 9999)
		remote:FireServer(ALICE, 0 / 0)
		for _ = 1, 20 do
			remote:FireServer(ALICE, 5)
		end
		expect(damageApplied).toBe(25)
	end)
end
