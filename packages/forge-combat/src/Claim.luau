--!strict
-- Claim: resolve a client's claimed hit against the server's own record.
--
-- THE CONTRACT. The client reports INTENT - "I attacked at time T, from here, at them."
-- It never reports outcome. The server rewinds its own position history to T and decides.
-- Everything the client says is a hypothesis; everything in `Context` is server truth.
--
-- Checks run cheapest-and-most-certain first, so an obviously bogus claim never reaches a
-- raycast:
--
--   1. cooldown   - server's own record of the last accepted attack
--   2. equipped   - server's own view of what they are holding
--   3. alive      - server's own view of the target
--   4. team       - server's own view
--   5. timestamp  - not the future; not older than the rewind window
--   6. origin     - is the attacker where they claim to be shooting FROM? a client can
--                   name any origin, and this is the check people forget
--   7. range      - against the REWOUND target position, plus slack
--   8. sight      - caller supplies the raycast result (the only Roblox-dependent input)
--
-- Pure Luau: the caller injects the history, the raycast result, and the policy. So every
-- branch below is testable in a terminal.

-- NOTE: this module deliberately does NOT require History, even though it uses one.
-- `require(script.Parent.History)` is Roblox syntax that Lune cannot resolve, and that
-- single line would make this file - the one that decides whether damage lands - untestable
-- outside Studio. The history arrives through `Context.history` instead, so a spec can pass
-- the real thing (by relative file path) or a stub. The types below are declared locally
-- for the same reason.

export type Vec = { X: number, Y: number, Z: number }

-- Structural type: anything with these two methods. The real History satisfies it.
export type HistoryLike = {
	SampleAt: (self: any, id: unknown, at: number) -> (Vec?, string?),
	Oldest: (self: any, id: unknown) -> { at: number, position: Vec }?,
	Newest: (self: any, id: unknown) -> { at: number, position: Vec }?,
}

export type Weapon = {
	-- Studs. Compared against the rewound target position, not the current one.
	range: number,
	-- Seconds between accepted attacks.
	cooldown: number,
}

export type Claim = {
	attackerId: unknown,
	targetId: unknown,
	-- When the CLIENT says it happened. Untrusted, and the reason this module exists.
	at: number,
	-- Where the client says it attacked FROM. Also untrusted - checked against history.
	origin: Vec,
	weapon: Weapon,
}

export type Context = {
	-- Server time now.
	now: number,
	history: HistoryLike,
	-- Server's record of the last ACCEPTED attack, or nil if none yet.
	lastAcceptedAt: number?,
	targetAlive: boolean,
	weaponEquipped: boolean,
	sameTeam: boolean,
	-- Result of the caller's raycast between origin and the rewound target position.
	-- nil means "not checked" and is treated as clear - pass false to reject.
	lineOfSight: boolean?,
}

export type ExpiredBehaviour = "reject" | "acceptWithTightRange"

export type Policy = {
	-- What to do when the claim falls outside the verifiable window. See the discussion
	-- in DEFAULT_POLICY below: this is a judgement call about your game, not a fact.
	onExpired: ExpiredBehaviour,
	-- Studs of slack on the range check, absorbing interpolation error and hitbox size.
	rangeSlackStuds: number,
	-- Slack used when accepting an unverifiable claim. Only consulted when
	-- onExpired == "acceptWithTightRange".
	tightRangeSlackStuds: number,
	-- How far into the future a timestamp may sit before it is nonsense. Small: clock
	-- skew is real, but a client claiming the future is desynced or lying.
	futureToleranceSeconds: number,
	-- How far the claimed origin may sit from where history says the attacker was.
	originSlackStuds: number,
}

export type Verdict = {
	accepted: boolean,
	-- Stable machine-readable reason. Log it; never send it to the client.
	reason: string,
	-- Where history said the target was at the claimed instant, when we got that far.
	rewoundTo: Vec?,
	distance: number?,
	-- True when the claim was accepted without a verifiable record.
	unverified: boolean?,
}

local Claim = {}

--[[
	The conservative default: an unverifiable claim is refused.

	The tradeoff, stated plainly because it is a real one. `onExpired = "reject"` means a
	player whose connection hiccuped past the rewind window loses hits that were probably
	legitimate - it feels like the game ignoring you. `"acceptWithTightRange"` gives those
	players their hits back, at the cost of a window an attacker can aim at: fake a large
	latency, claim a stale timestamp, and the only thing still guarding you is the tightened
	range check against the OLDEST position on record.

	Which is right depends on your game. A game with a generous hitbox and forgiving TTK can
	afford to accept; a precise one cannot. Pick deliberately, in game config, not here.
]]
Claim.DEFAULT_POLICY = {
	onExpired = "reject" :: ExpiredBehaviour,
	rangeSlackStuds = 4,
	tightRangeSlackStuds = 0,
	futureToleranceSeconds = 0.05,
	originSlackStuds = 6,
} :: Policy

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

local function finiteVec(v: Vec?): boolean
	return v ~= nil and isFinite(v.X) and isFinite(v.Y) and isFinite(v.Z)
end

local function distance(a: Vec, b: Vec): number
	local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function reject(reason: string, extra: { [string]: any }?): Verdict
	local verdict: Verdict = { accepted = false, reason = reason }
	if extra then
		for key, value in extra do
			(verdict :: any)[key] = value
		end
	end
	return verdict
end

--[[
	Resolve one claim. Never throws; always returns a Verdict.
]]
function Claim.resolve(claim: Claim, context: Context, policy: Policy?): Verdict
	local rules: Policy = policy or Claim.DEFAULT_POLICY

	-- Malformed geometry or timestamps. forge-guard should have caught these at the
	-- boundary, but this module must be safe on its own - it is the last line before
	-- damage is applied.
	if not isFinite(claim.at) then
		return reject("claim-time-not-finite")
	end
	if not finiteVec(claim.origin) then
		return reject("origin-not-finite")
	end
	if not (isFinite(claim.weapon.range) and claim.weapon.range > 0) then
		return reject("weapon-range-invalid")
	end

	-- 1. Cooldown, from the server's record. A client that fires faster than the weapon
	-- allows is the single most common exploit, and this is a pure comparison.
	local lastAt = context.lastAcceptedAt
	if lastAt ~= nil and (context.now - lastAt) < claim.weapon.cooldown then
		return reject("cooldown")
	end

	-- 2-4. Server's own view of the world. Nothing the client says is involved.
	if not context.weaponEquipped then
		return reject("not-equipped")
	end
	if not context.targetAlive then
		return reject("target-dead")
	end
	if context.sameTeam then
		return reject("same-team")
	end

	-- 5. Timestamp sanity.
	if claim.at > context.now + rules.futureToleranceSeconds then
		return reject("claim-in-future")
	end

	local targetAt, missReason = context.history:SampleAt(claim.targetId, claim.at)
	local unverified = false
	local rangeSlack = rules.rangeSlackStuds

	if targetAt == nil then
		if missReason == "unknown" then
			-- No record at all. Not a policy question: there is nothing to hit.
			return reject("target-unknown")
		end
		if missReason == "future" then
			-- NOT automatically a lie. History is sampled at a fixed rate (20 Hz is
			-- typical), so a perfectly honest claim routinely lands 20-40 ms AHEAD of
			-- the newest sample we hold - the attack happened between two ticks.
			-- Rejecting those would throw away a large share of legitimate hits.
			--
			-- So: if the overshoot is inside the same tolerance we allow for clock skew,
			-- clamp to the newest record, which is the best evidence in existence. Past
			-- that, it is a claim about a future we have no record of.
			local newest = context.history:Newest(claim.targetId)
			if newest == nil then
				return reject("target-unknown")
			end
			if claim.at - newest.at > rules.futureToleranceSeconds then
				return reject("claim-in-future")
			end
			targetAt = newest.position
		end
	end

	-- Anything still unresolved is `expired`: inside no verifiable record.
	if targetAt == nil then
		-- THE POLICY EDGE. `expired` means the claim reached past what we retained, so we
		-- genuinely cannot verify it either way.
		if rules.onExpired == "reject" then
			return reject("claim-expired")
		end

		-- Accepting: fall back to the oldest position we still hold, and tighten the
		-- range check, because that position is the least trustworthy input we have.
		local oldest = context.history:Oldest(claim.targetId)
		if oldest == nil then
			return reject("target-unknown")
		end
		targetAt = oldest.position
		rangeSlack = rules.tightRangeSlackStuds
		unverified = true
	end

	local rewound = targetAt :: Vec

	-- 6. Is the attacker where they claim to be attacking FROM? A client can name any
	-- origin it likes, and without this check every range test above is measuring from a
	-- point the attacker invented.
	local attackerAt = context.history:SampleAt(claim.attackerId, claim.at)
	if attackerAt ~= nil then
		local drift = distance(claim.origin, attackerAt)
		if drift > rules.originSlackStuds then
			return reject("origin-mismatch", { distance = drift, rewoundTo = rewound })
		end
	end

	-- 7. Range, against the rewound position.
	local reach = distance(claim.origin, rewound)
	if reach > claim.weapon.range + rangeSlack then
		return reject("out-of-range", { distance = reach, rewoundTo = rewound })
	end

	-- 8. Sight. nil means the caller did not check; false is an explicit block.
	if context.lineOfSight == false then
		return reject("no-line-of-sight", { distance = reach, rewoundTo = rewound })
	end

	return {
		accepted = true,
		reason = if unverified then "accepted-unverified" else "accepted",
		rewoundTo = rewound,
		distance = reach,
		unverified = unverified or nil,
	}
end

return Claim
