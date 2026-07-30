--!strict
-- Registry: a service registry with two explicit lifecycle phases.
--
-- THE PROBLEM IT SOLVES. Modules that require each other at load time create ordering
-- problems that surface as intermittent nil errors - the kind that reproduce once a week
-- under load and never in Studio. The fix is to separate "exists" from "wired" from
-- "running", and to make the ordering explicit and checkable:
--
--   Add    - the service exists. No dependencies resolved, no work done.
--   Init   - dependency-ordered. A service may look up its dependencies. It may NOT
--            assume any other service has finished initialising.
--   Start  - everything is initialised. Connect events, begin loops, spawn work.
--
-- What that buys: a service can be added without editing a load-order list, and a missing
-- or circular dependency fails LOUDLY at boot with a named path instead of silently at 3am.
--
-- Pure Luau. No `game`, no services - so the whole ordering algorithm is under test.
--
-- WHY NOT sleitnick/knit (mirrored, 1.7.0): Knit does this, but bundles its own networking
-- and component system, both of which we are replacing. This is the ordering, alone. If it
-- grows past ~200 lines, take Knit instead.

export type Service = {
	Name: string,
	Requires: { string }?,
	Init: ((self: any, registry: any) -> ())?,
	Start: ((self: any) -> ())?,
	[any]: any,
}

export type Registry = {
	Add: (self: Registry, service: Service) -> Service,
	Get: (self: Registry, name: string) -> Service,
	Find: (self: Registry, name: string) -> Service?,
	Init: (self: Registry) -> (),
	Start: (self: Registry) -> (),
	Order: (self: Registry) -> { string },
	Phase: (self: Registry) -> "added" | "initialised" | "started",
}

local Registry = {}
Registry.__index = Registry

function Registry.new(): Registry
	return (
		setmetatable({
			_services = {} :: { [string]: Service },
			-- Insertion order, so a graph with no constraints between two services
			-- resolves deterministically rather than by hash order.
			_added = {} :: { string },
			_order = nil :: { string }?,
			_phase = "added",
		}, Registry) :: any
	) :: Registry
end

--[[
	Register a service. Returns it, so `local Round = registry:Add(require(...))` reads
	well at the call site.
]]
function Registry.Add(self: Registry, service: Service): Service
	local this = self :: any
	assert(this._phase == "added", "cannot Add after Init")
	assert(typeof(service) == "table", "a service must be a table")

	local name = service.Name
	assert(typeof(name) == "string" and name ~= "", "a service needs a non-empty Name")
	-- Duplicate names would make Get ambiguous, and the second registration would
	-- silently shadow the first.
	assert(this._services[name] == nil, `duplicate service {name}`)

	this._services[name] = service
	table.insert(this._added, name)
	return service
end

function Registry.Find(self: Registry, name: string): Service?
	return (self :: any)._services[name]
end

--[[
	Look up a service, erroring if it is absent. Use this from Init/Start - a typo in a
	dependency name should stop the boot, not return nil and fail three frames later.
]]
function Registry.Get(self: Registry, name: string): Service
	local service = (self :: any)._services[name]
	if service == nil then
		error(`no service named {name}`, 2)
	end
	return service
end

--[[
	Resolve dependency order. Errors on an unknown dependency or a cycle, naming the path
	in both cases.

	Depth-first with a three-colour marking, which is what lets us report the cycle as an
	actual path (A -> B -> A) rather than just "there is a cycle somewhere".
]]
function Registry._resolve(self: any): { string }
	local order: { string } = {}
	local state: { [string]: number } = {} -- nil = unvisited, 1 = on stack, 2 = done

	local function visit(name: string, stack: { string })
		if state[name] == 2 then
			return
		end
		if state[name] == 1 then
			local from = table.find(stack, name) or 1
			local cycle = table.concat(stack, " -> ", from) .. " -> " .. name
			error(`dependency cycle: {cycle}`, 0)
		end

		local service = self._services[name]
		if service == nil then
			local requiredBy = if #stack > 0 then stack[#stack] else "?"
			error(`{requiredBy} requires unknown service {name}`, 0)
		end

		state[name] = 1
		table.insert(stack, name)
		for _, dependency in service.Requires or {} do
			visit(dependency, stack)
		end
		table.remove(stack)
		state[name] = 2
		table.insert(order, name)
	end

	for _, name in self._added do
		visit(name, {})
	end
	return order
end

--[[
	Init every service in dependency order. Idempotent-guarded: calling twice errors
	rather than re-initialising, because a double Init is a bug and silently tolerating it
	hides it.
]]
function Registry.Init(self: Registry): ()
	local this = self :: any
	assert(this._phase == "added", "Init has already run")

	this._order = this:_resolve()
	for _, name in this._order do
		local service = this._services[name]
		if service.Init then
			service:Init(self)
		end
	end
	this._phase = "initialised"
end

--[[
	Start every service, in the same order. Init must have run first - that is the
	guarantee Start exists to provide.
]]
function Registry.Start(self: Registry): ()
	local this = self :: any
	assert(this._phase == "initialised", `Start requires Init first (phase: {this._phase})`)

	for _, name in this._order :: { string } do
		local service = this._services[name]
		if service.Start then
			service:Start()
		end
	end
	this._phase = "started"
end

--[[
	The resolved order. Available before Init too - useful for asserting on the graph in a
	spec, or logging the boot order.
]]
function Registry.Order(self: Registry): { string }
	local this = self :: any
	return table.clone(this._order or this:_resolve())
end

function Registry.Phase(self: Registry): "added" | "initialised" | "started"
	return (self :: any)._phase
end

return Registry
