--!strict
-- Specs for Registry.

local Registry = require("../src/Registry")

-- A service that records the phases it went through, in order, into a shared log.
local function tracer(log: { string }, name: string, requires: { string }?)
	return {
		Name = name,
		Requires = requires,
		Init = function(self, registry)
			table.insert(log, `init:{name}`)
			self.sawRegistry = registry ~= nil
		end,
		Start = function()
			table.insert(log, `start:{name}`)
		end,
	}
end

return function(t)
	t.test("runs Init for every service, then Start for every service", function(expect)
		local log = {}
		local registry = Registry.new()
		registry:Add(tracer(log, "A"))
		registry:Add(tracer(log, "B"))
		registry:Init()
		registry:Start()
		-- Every Init completes before any Start. That is the guarantee Start exists for.
		expect(log).toEqual({ "init:A", "init:B", "start:A", "start:B" })
	end)

	t.test("initialises dependencies before their dependents", function(expect)
		local log = {}
		local registry = Registry.new()
		-- Added in the wrong order on purpose.
		registry:Add(tracer(log, "Round", { "Profile" }))
		registry:Add(tracer(log, "Profile"))
		registry:Init()
		expect(log).toEqual({ "init:Profile", "init:Round" })
	end)

	t.test("resolves a diamond without initialising anything twice", function(expect)
		local log = {}
		local registry = Registry.new()
		registry:Add(tracer(log, "Top", { "Left", "Right" }))
		registry:Add(tracer(log, "Left", { "Base" }))
		registry:Add(tracer(log, "Right", { "Base" }))
		registry:Add(tracer(log, "Base"))
		registry:Init()
		expect(log).toEqual({ "init:Base", "init:Left", "init:Right", "init:Top" })
	end)

	t.test("order is deterministic for unconstrained services", function(expect)
		local registry = Registry.new()
		registry:Add({ Name = "C" })
		registry:Add({ Name = "A" })
		registry:Add({ Name = "B" })
		-- Insertion order, not hash order - so a boot log is comparable run to run.
		expect(registry:Order()).toEqual({ "C", "A", "B" })
	end)

	-- The point of the whole module: these fail at boot with a named path, instead of
	-- returning nil and blowing up somewhere unrelated much later.
	t.test("names the path of a dependency cycle", function(expect)
		local registry = Registry.new()
		registry:Add({ Name = "A", Requires = { "B" } })
		registry:Add({ Name = "B", Requires = { "A" } })
		expect(function()
			registry:Init()
		end).toThrow("dependency cycle: A -> B -> A")
	end)

	t.test("detects a self-dependency", function(expect)
		local registry = Registry.new()
		registry:Add({ Name = "A", Requires = { "A" } })
		expect(function()
			registry:Init()
		end).toThrow("dependency cycle")
	end)

	t.test("names the service that required something missing", function(expect)
		local registry = Registry.new()
		registry:Add({ Name = "Round", Requires = { "Porfile" } })
		expect(function()
			registry:Init()
		end).toThrow("Round requires unknown service Porfile")
	end)

	t.test("rejects duplicate names", function(expect)
		local registry = Registry.new()
		registry:Add({ Name = "A" })
		expect(function()
			registry:Add({ Name = "A" })
		end).toThrow("duplicate service A")
	end)

	t.test("rejects a service with no usable Name", function(expect)
		local registry = Registry.new()
		expect(function()
			registry:Add({} :: any)
		end).toThrow("non-empty Name")
		expect(function()
			registry:Add({ Name = "" } :: any)
		end).toThrow("non-empty Name")
	end)

	t.test("services without Init or Start are fine", function(expect)
		local registry = Registry.new()
		registry:Add({ Name = "DataOnly", Config = { waves = 3 } })
		registry:Init()
		registry:Start()
		expect(registry:Get("DataOnly").Config.waves).toBe(3)
	end)

	t.test("Get errors on an unknown name; Find returns nil", function(expect)
		local registry = Registry.new()
		expect(function()
			registry:Get("Nope")
		end).toThrow("no service named Nope")
		expect(registry:Find("Nope")).toBeNil()
	end)

	t.test("Init receives the registry so a service can resolve dependencies", function(expect)
		local log = {}
		local registry = Registry.new()
		local service = tracer(log, "A")
		registry:Add(service)
		registry:Init()
		expect(service.sawRegistry).toBe(true)
	end)

	-- Phase guards. A double Init or a Start-before-Init is a bug; tolerating it silently
	-- hides it.
	t.test("enforces the phase order", function(expect)
		local registry = Registry.new()
		registry:Add({ Name = "A" })

		expect(function()
			registry:Start()
		end).toThrow("Start requires Init first")

		expect(registry:Phase()).toBe("added")
		registry:Init()
		expect(registry:Phase()).toBe("initialised")

		expect(function()
			registry:Init()
		end).toThrow("Init has already run")

		expect(function()
			registry:Add({ Name = "Late" })
		end).toThrow("cannot Add after Init")

		registry:Start()
		expect(registry:Phase()).toBe("started")
	end)

	t.test("Order returns a copy", function(expect)
		local registry = Registry.new()
		registry:Add({ Name = "A" })
		local order = registry:Order()
		table.insert(order, "injected")
		expect(#registry:Order()).toBe(1)
	end)
end
