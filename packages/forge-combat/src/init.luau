--!strict
-- forge-combat: server-authoritative hit resolution with a bounded lag-compensation window.
--
-- The value returned here is the package's ENTIRE public API.
--
-- SERVER REALM ONLY. Mount under ServerScriptService via Forest's two-manifest pattern.
-- Hit resolution that a client can read is hit resolution a client can plan around.
--
-- The contract: the client reports INTENT ("I attacked at time T, from here, at them"),
-- never outcome. The server rewinds its own position record to T and decides. Neither
-- extreme works on Roblox - resolving against current positions feels broken at any real
-- ping, and trusting client-reported hits is a free aimbot.
--
-- Thin aggregator: History and Claim are pure Luau with injected inputs, fully specced
-- under Lune. Notably Claim does NOT require History - it takes one through its Context -
-- because that single Roblox-syntax require would make the module that decides whether
-- damage lands untestable outside Studio.

return {
	-- Bounded per-entity position ring buffer with interpolated lookup.
	History = require(script.History),
	-- Resolve one claimed hit. Ships a conservative DEFAULT_POLICY.
	Claim = require(script.Claim),
}
