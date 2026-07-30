--!strict
-- forge-round: round/match lifecycle and matchmaking for Roblox.
--
-- The value returned here is the package's ENTIRE public API.
--
-- Three surfaces, deliberately: most consumers want RoundService, but Machine and Queue are
-- exposed because they are pure and useful on their own - a custom lifecycle can drive the
-- machine directly without adopting our Roblox glue.
--
-- No require-time side effects: nothing here connects anything. RoundService only starts
-- ticking when you call :Start(), which is what lets it slot into forge-lifecycle's
-- Init/Start ordering rather than racing it.

return {
	-- Roblox adapter. Signals for PhaseChanged / MatchStarted / MatchEnded / QueueChanged.
	Service = require(script.RoundService),
	-- The guarded lifecycle state machine. Pure; fully specced.
	Machine = require(script.Machine),
	-- Wait-time-fair matchmaking queue. Pure; fully specced.
	Queue = require(script.Queue),
}
