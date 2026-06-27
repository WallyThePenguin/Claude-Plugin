--!strict
-- BehaviorFactory: PURE logic for the item behavior state machine (roadmap #3) — no DataModel, no services,
-- directly unit-testable (mirrors ToolFactory's pure layer). An item's on-activate behavior is a timed
-- sequence windup -> active -> cooldown -> idle; this module validates the authored durations and computes
-- the cumulative timeline (so the tool can report it + the spec can assert it). The impure side (writing the
-- Attributes + the runtime LocalScript) lives in Tools/ItemBehavior. See
-- docs/superpowers/specs/2026-06-26-item-behavior-state-machine-design.md.

local BehaviorFactory = {}

export type Config = { windup: number, active: number, cooldown: number }
export type Phase = { state: string, at: number, duration: number }

-- Defaults: a snappy melee feel (telegraph, brief hit window, recovery that gates spam).
local DEFAULTS: Config = { windup = 0.15, active = 0.15, cooldown = 0.4 }

BehaviorFactory.DEFAULTS = DEFAULTS

-- Coerce one duration: a finite number >= 0, else the default. (nil/NaN/inf/negative -> default.)
local function coerce(v: any, default: number): number
	if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
		return default
	end
	if v < 0 then
		return 0
	end
	return v
end

-- Validate an authored config into a clean Config, or (config, errorString) when the total is zero (a state
-- machine with no time can't run). Missing/invalid fields fall back to the defaults.
function BehaviorFactory.validate(cfg: any): (Config, string?)
	local args = if type(cfg) == "table" then cfg else {}
	local clean: Config = {
		windup = coerce(args.windup, DEFAULTS.windup),
		active = coerce(args.active, DEFAULTS.active),
		cooldown = coerce(args.cooldown, DEFAULTS.cooldown),
	}
	if clean.windup + clean.active + clean.cooldown <= 0 then
		return clean, "behavior durations sum to 0 — give a positive windup/active/cooldown"
	end
	return clean, nil
end

-- The cumulative timeline of the on-activate sequence: each phase with its start offset (`at`) and duration.
-- The ACTIVE WINDOW (where #4 hit detection fires) is [windup, windup+active]. The final `idle` phase marks the
-- return to rest (duration 0).
function BehaviorFactory.timeline(cfg: any): { Phase }
	local c = BehaviorFactory.validate(cfg)
	return {
		{ state = "windup", at = 0, duration = c.windup },
		{ state = "active", at = c.windup, duration = c.active },
		{ state = "cooldown", at = c.windup + c.active, duration = c.cooldown },
		{ state = "idle", at = c.windup + c.active + c.cooldown, duration = 0 },
	}
end

-- The [start, finish] of the active window (the effect window), for the tool's summary + #4.
function BehaviorFactory.activeWindow(cfg: any): (number, number)
	local c = BehaviorFactory.validate(cfg)
	return c.windup, c.windup + c.active
end

return BehaviorFactory
