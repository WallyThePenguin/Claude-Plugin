--!strict
-- HitValidator: the PURE server-authoritative validation primitive for the item-hit seam (the netcode
-- foundation). bind_hitbox's ItemHitServer trusts every client hit-request and sweeps/damages on it, so a
-- malicious client can FireServer-spam to deal damage at an arbitrary rate (even without swinging). This
-- module is the first authoritative gate: a per-(player,tool) COOLDOWN that caps accepted hits to a
-- legitimate swing rate. Pure (no DataModel) so it is directly unit-testable; ItemHitServer inlines the
-- SAME algorithm (a generated in-experience Script can't require a plugin module). Heavier netcode
-- (lag-comp rewind, per-limb, reconciliation) layers on top of this seam later.

local HitValidator = {}

-- Default minimum seconds between server-accepted hits for one (player, tool). A normal swing's active
-- window is short; ~0.4s blocks FireServer spam while leaving real swinging unaffected. Tunable via the
-- Tool's HitCooldown attribute.
local DEFAULT_COOLDOWN = 0.4
HitValidator.DEFAULT_COOLDOWN = DEFAULT_COOLDOWN

-- Clamp a cooldown value to a sane non-negative number, falling back to the default.
function HitValidator.coerceCooldown(v: any): number
	if type(v) ~= "number" or v ~= v then -- nil / NaN
		return DEFAULT_COOLDOWN
	end
	if v < 0 then
		return 0
	end
	return v
end

-- Decide whether a hit request is accepted given the prior accepted-hit time for this (player, tool).
-- lastHit: the timestamp of the previous ACCEPTED hit (nil = none yet). now: the request time. cooldown:
-- the minimum interval. Returns (accepted, reason, nextLastHit) where nextLastHit is the timestamp to
-- store: advanced to `now` on accept, UNCHANGED on reject (a rejected spam request must not extend the
-- window — otherwise spam could starve a legitimate later swing).
function HitValidator.check(lastHit: number?, now: number, cooldown: number): (boolean, string, number)
	local cd = HitValidator.coerceCooldown(cooldown)
	if type(now) ~= "number" or now ~= now then
		return false, "bad-timestamp", (lastHit or 0)
	end
	if lastHit ~= nil and (now - lastHit) < cd then
		return false, "cooldown", lastHit
	end
	return true, "ok", now
end

return HitValidator
