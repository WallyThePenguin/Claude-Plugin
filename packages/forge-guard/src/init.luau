--!strict
-- forge-guard: server-side anti-exploit primitives.
--
-- The value returned here is the package's ENTIRE public API.
--
-- SERVER REALM ONLY. Mount this under ServerScriptService via Forest's two-manifest
-- pattern. Nothing here is secret in itself, but a client that can read your thresholds
-- can tune underneath them - and a guard enforced somewhere the attacker controls is not
-- a guard.
--
-- Thin aggregator on purpose: every module below is pure Luau with an injected clock, so
-- it all runs under Lune. This file uses Roblox require syntax and is the only untestable
-- line in the package.

return {
	-- Composable validators. The defaults reject NaN and infinities.
	Validate = require(script.Validate),
	-- Per-key token buckets. Every remote needs one.
	RateLimit = require(script.RateLimit),
	-- Weighted, decaying suspicion. Act on the score, never on one observation.
	AbuseScore = require(script.AbuseScore),
	-- Position plausibility. Produces evidence, not verdicts.
	Movement = require(script.Movement),
}
