--!strict
-- CombatPolicy: Forge Arena's lag-compensation tuning.
--
-- PURE DATA. No requires, no services. Two reasons that matters:
--   * This lives in ReplicatedStorage, so the CLIENT can read it (it needs the same numbers
--     to predict locally). A require reaching into ServerScriptService would simply fail
--     there.
--   * Config that imports code stops being config.
--
-- The server passes `Policy` as the third argument to `Combat.Claim.resolve(claim, ctx,
-- policy)` and feeds `WindowSeconds`/`SampleRate` to `Combat.History.new`. The package
-- ships its own conservative DEFAULT_POLICY; these values override it, so the shape here
-- must match `forge-combat`'s `Policy` type.
--
-- ============================================================================
-- THE DECISION — over to you.
-- ============================================================================
--
-- `onExpired` is what happens when a player's claimed attack time reaches further back than
-- the rewind window retained. At that point the server genuinely CANNOT tell whether the hit
-- was real. There is no correct answer, only a trade:
--
--   "reject"                -- Safe. A player whose connection hiccuped loses hits that were
--                              probably legitimate. It reads to them as the game ignoring
--                              their input, which is the most common complaint about
--                              server-authoritative combat.
--
--   "acceptWithTightRange"  -- Forgiving. Those players get their hits back. The cost is a
--                              window an attacker can aim at: fake a large latency, claim a
--                              stale timestamp, and the only remaining guard is the tightened
--                              range check against the OLDEST position on record.
--
-- The knobs that go with it:
--
--   WindowSeconds           -- How far back the buffer retains at all. Longer is kinder to
--                              high-ping players and gives an attacker more room. 0.20-0.25
--                              covers most real ping; past ~0.4 you are reconstructing a
--                              world the target had already left.
--   rangeSlackStuds         -- Slack on a VERIFIED hit. Absorbs interpolation error and
--                              hitbox size. Forge Arena's weapons are melee with generous
--                              arcs, so a few studs is honest, not lax.
--   tightRangeSlackStuds    -- Slack when accepting an UNVERIFIED claim. This is the last
--                              guard in that branch; 0 means the claim must be dead-on
--                              against the oldest record.
--   originSlackStuds        -- How far the claimed attack origin may sit from where history
--                              says the attacker was. Too tight and honest movement drift
--                              rejects real hits; too loose and a client can attack from a
--                              position it invented.
--   futureToleranceSeconds  -- Clock skew allowance, and also how far past the newest sample
--                              an honest between-ticks claim may land.
--
-- Write the policy below. Roughly 5-10 lines, and it decides whether Forge Arena feels fair
-- on a bad connection or exploitable on a good one.

-- TODO(user): make this deliberate for Forge Arena.
--
-- These values mirror forge-combat's shipped default, which is the conservative branch --
-- so nothing here is exploitable while the decision is open. It is just not yet a decision;
-- it is the absence of one.
return {
	WindowSeconds = 0.25,
	SampleRate = 20,

	Policy = {
		onExpired = "reject",
		rangeSlackStuds = 4,
		tightRangeSlackStuds = 0,
		futureToleranceSeconds = 0.05,
		originSlackStuds = 6,
	},
}
