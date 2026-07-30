--!strict
-- Router: the decision layer for every client -> server call.
--
-- A remote handler has four jobs and they must happen in this order:
--
--   1. rate      - is this caller within budget? cheapest check, and the one that stops
--                  a flood. A perfectly valid call at 500 Hz is an attack that no amount
--                  of argument validation can see.
--   2. validate  - is the payload the shape we declared? arity, type, finiteness, range.
--   3. handle    - only now are the arguments worth reasoning about.
--   4. contain   - a throwing handler must not take the boundary down with it, and must
--                  not go unnoticed.
--
-- Getting that order wrong is how games get exploited: validating before rate-limiting
-- means an attacker still burns your CPU on 500 malformed calls a second.
--
-- ZERO DEPENDENCIES, BY DESIGN. The router does not import forge-guard - it accepts a
-- `validate` FUNCTION and a `rateLimit` OBJECT. Both are duck-typed interfaces that
-- forge-guard happens to satisfy. That is dependency inversion, and it buys two things:
-- the router is fully testable under Lune (a Forest dependency would land in
-- src/Packages/, which Lune cannot resolve), and a consumer can bring their own validator
-- library without forking this.

-- (...args) -> (ok, reason?). forge-guard's Validate.tuple returns exactly this.
export type TupleValidator = (...any) -> (boolean, string?)

-- Anything with Consume/Forget. forge-guard's RateLimit satisfies it.
export type Limiter = {
	Consume: (self: any, key: unknown, cost: number?) -> boolean,
	Forget: (self: any, key: unknown) -> (),
}

export type RejectionKind = "rate" | "invalid" | "closed"

export type Route = {
	-- Argument-list validator. Omit only for a route that genuinely takes no arguments.
	validate: TupleValidator?,
	-- Per-caller budget. Omitting it is a deliberate choice, and the router will say so.
	rateLimit: Limiter?,
	-- Token cost of one call, for routes that are more expensive than others.
	cost: number?,
	handler: (player: any, ...any) -> ...any,
}

export type Options = {
	-- Called on every rejection. This is your telemetry hook: feed it to an AbuseScore.
	-- Never send `reason` back to the client - naming the failed check is free
	-- reconnaissance for an attacker.
	onReject: ((player: any, route: string, kind: RejectionKind, reason: string?) -> ())?,
	-- Called when a handler throws. Default is a `warn`, because a silently swallowed
	-- handler error is indistinguishable from a gameplay bug for weeks.
	onError: ((player: any, route: string, err: string) -> ())?,
}

export type Stats = {
	accepted: number,
	rejectedRate: number,
	rejectedInvalid: number,
	errored: number,
}

local Router = {}
Router.__index = Router

export type Router = {
	Route: (self: Router, name: string, route: Route) -> (),
	Dispatch: (self: Router, name: string, player: any, ...any) -> (boolean, ...any),
	Forget: (self: Router, player: any) -> (),
	Close: (self: Router) -> (),
	IsOpen: (self: Router) -> boolean,
	Stats: (self: Router, name: string) -> Stats,
	Routes: (self: Router) -> { string },
	UnlimitedRoutes: (self: Router) -> { string },
}

function Router.new(options: Options?): Router
	local opts: Options = options or {}
	return (
		setmetatable({
			_routes = {} :: { [string]: Route },
			_stats = {} :: { [string]: Stats },
			_onReject = opts.onReject,
			_onError = opts.onError,
			_open = true,
		}, Router) :: any
	) :: Router
end

--[[
	Declare a route. Names must be unique - a duplicate would silently shadow the first
	registration, which is the kind of bug that only shows up as "why isn't my handler
	running".
]]
function Router.Route(self: Router, name: string, route: Route): ()
	local this = self :: any
	assert(typeof(name) == "string" and name ~= "", "a route needs a non-empty name")
	assert(this._routes[name] == nil, `duplicate route {name}`)
	assert(typeof(route.handler) == "function", `route {name} needs a handler`)

	this._routes[name] = route
	this._stats[name] = { accepted = 0, rejectedRate = 0, rejectedInvalid = 0, errored = 0 }
end

--[[
	Run a call through the pipeline. Returns `false` when the call was rejected or the
	handler threw, otherwise `true` plus whatever the handler returned.

	The caller does not learn WHY it failed. That is deliberate: the client gets silence,
	and the detail goes to onReject/onError where you can see it.
]]
function Router.Dispatch(self: Router, name: string, player: any, ...: any): (boolean, ...any)
	local this = self :: any
	local route = this._routes[name]
	if route == nil then
		-- An unregistered route is a programming error on the server, not a client
		-- attack, so it is loud.
		error(`no route named {name}`, 2)
	end
	local stats: Stats = this._stats[name]

	-- Closed means shutting down. Reject everything rather than let a handler start work
	-- that cannot finish - especially anything that was going to write to a datastore.
	if not this._open then
		if this._onReject then
			this._onReject(player, name, "closed" :: RejectionKind, nil)
		end
		return false
	end

	-- 1. Rate, first and cheapest.
	if route.rateLimit then
		local key = if player ~= nil then player.UserId else "server"
		if not route.rateLimit:Consume(key, route.cost) then
			stats.rejectedRate += 1
			if this._onReject then
				this._onReject(player, name, "rate" :: RejectionKind, nil)
			end
			return false
		end
	end

	-- 2. Shape.
	if route.validate then
		local ok, reason = route.validate(...)
		if not ok then
			stats.rejectedInvalid += 1
			if this._onReject then
				this._onReject(player, name, "invalid" :: RejectionKind, reason)
			end
			return false
		end
	end

	-- 3 and 4. Handle, contained. Roblox swallows an error thrown inside OnServerEvent,
	-- so without this the failure is invisible.
	local results = table.pack(pcall(route.handler, player, ...))
	if not results[1] then
		stats.errored += 1
		local err = tostring(results[2])
		if this._onError then
			this._onError(player, name, err)
		else
			warn(`[forge-net] {name} handler errored: {err}`)
		end
		return false
	end

	stats.accepted += 1
	return true, table.unpack(results, 2, results.n)
end

--[[
	Drop a player's rate-limit state across every route. Call from PlayerRemoving: a
	per-player table with no cleanup is a leak, and an attacker cycling identities makes
	it a denial-of-service surface.
]]
function Router.Forget(self: Router, player: any): ()
	local this = self :: any
	local key = if player ~= nil then player.UserId else "server"
	local seen: { [any]: true } = {}
	for _, route in this._routes do
		-- Routes commonly share one limiter; Forget is idempotent but skipping the
		-- repeats keeps this O(limiters) rather than O(routes).
		if route.rateLimit and not seen[route.rateLimit] then
			seen[route.rateLimit] = true
			route.rateLimit:Forget(key)
		end
	end
end

--[[
	Stop accepting calls. Use this from BindToClose, before flushing saves, so nothing new
	starts during shutdown.
]]
function Router.Close(self: Router): ()
	(self :: any)._open = false
end

function Router.IsOpen(self: Router): boolean
	return (self :: any)._open
end

function Router.Stats(self: Router, name: string): Stats
	local stats = (self :: any)._stats[name]
	if stats == nil then
		error(`no route named {name}`, 2)
	end
	return table.clone(stats)
end

function Router.Routes(self: Router): { string }
	local names = {}
	for name in (self :: any)._routes do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

--[[
	Routes with no rate limit. Nothing enforces that every route has one - some genuinely
	do not need it - but an unlimited route should be a decision you can see, so audit
	this at boot and log whatever comes back.
]]
function Router.UnlimitedRoutes(self: Router): { string }
	local names = {}
	for name, route in (self :: any)._routes do
		if route.rateLimit == nil then
			table.insert(names, name)
		end
	end
	table.sort(names)
	return names
end

return Router
