--!strict
-- CombatPolicy: Forge Arena's lag-compensation policy.
--
-- This file is TUNING DATA, which is why it lives in game/ rather than in forge-combat.
-- The package supplies the mechanism and a conservative default; how forgiving Forge Arena
-- chooses to be is a decision about this game.
--
-- Consumed by the server as the third argument to `Combat.Claim.resolve(claim, ctx, policy)`.
--
-- ============================================================================
-- THE DECISION — over to you.
-- ============================================================================
--
-- `onExpired` is what happens when a player's claimed attack time reaches further back
-- than the rewind window retained. At that point the server genuinely CANNOT tell whether
-- the hit was real. There is no correct answer, only a trade:
--
--   "reject"                -- Safe. A player whose connection hiccuped loses hits that
--                              were probably legitimate. It reads to them as the game
--                              ignoring their input, which is the single most common
--                              complaint about server-authoritative combat.
--
--   "acceptWithTightRange"  -- Forgiving. Those players get their hits back. The cost is a
--                              window an attacker can aim at: fake a large latency, claim a
--                              stale timestamp, and the only remaining guard is the
--                              tightened range check against the OLDEST position on record.
--
-- The knobs that go with it:
--
--   windowSeconds           -- How far back the buffer retains at all. Longer is kinder to
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
--
-- Write the policy below. Roughly 5-10 lines, and it decides whether Forge Arena feels fair
-- on a bad connection or exploitable on a good one.

local Combat = require(game:GetService("ServerScriptService").Packages["forge-combat"])

export type Policy = typeof(Combat.Claim.DEFAULT_POLICY)

-- TODO(user): replace this with the deliberate policy for Forge Arena.
--
-- Starting from the package default keeps the game shippable in the meantime: it is the
-- conservative branch, so nothing here is exploitable while the decision is open. It is
-- just not yet a decision — it is the absence of one.
local CombatPolicy: Policy = table.clone(Combat.Claim.DEFAULT_POLICY)

-- The rewind window itself is passed to History.new, not to resolve(), so it is exported
-- alongside the policy to keep both numbers in one place.
local WINDOW_SECONDS = 0.25
local SAMPLE_RATE = 20

return {
	Policy = CombatPolicy,
	WindowSeconds = WINDOW_SECONDS,
	SampleRate = SAMPLE_RATE,
}
