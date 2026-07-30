# forge-combat

Server-authoritative hit resolution with a **bounded** lag-compensation rewind window.

**Server realm only.** Mount under `ServerScriptService` via Forest's two-manifest pattern.

## Install

```sh
forest i @Valid/forge-combat
```

## The contract

The client reports **intent** — *"I attacked at time T, from here, at them."* It never
reports outcome. The server rewinds its own position record to T and decides.

Neither extreme works on Roblox:

- **Resolve against current positions** → feels broken at any real ping. You aimed where
  the target was; by the time the packet lands they're elsewhere, and your hit evaporates.
- **Trust client-reported hits** → a free aimbot.

So the server re-simulates. And the window is bounded, because unbounded rewind lets a
client claim a hit on someone who moved away seconds ago.

## Usage

```lua
local Combat = require(ServerPackages["forge-combat"])

local history = Combat.History.new({ windowSeconds = 0.25, sampleRate = 20 })

-- Sample every character on a fixed cadence.
RunService.Heartbeat:Connect(function()
    local now = os.clock()
    for _, player in Players:GetPlayers() do
        local root = player.Character and player.Character.PrimaryPart
        if root then
            history:Record(player.UserId, root.Position, now)
        end
    end
end)

-- Resolve a claim (arriving through a forge-net route, already shape-validated).
local verdict = Combat.Claim.resolve({
    attackerId = attacker.UserId,
    targetId = target.UserId,
    at = clientClaimedTime,
    origin = clientClaimedOrigin,
    weapon = { range = 10, cooldown = 0.5 },
}, {
    now = os.clock(),
    history = history,
    lastAcceptedAt = lastHit[attacker.UserId],
    targetAlive = targetHumanoid.Health > 0,
    weaponEquipped = equipped[attacker.UserId] == "sword",
    sameTeam = attacker.Team == target.Team,
    lineOfSight = raycastClear(origin, verdictPosition),
}, CombatPolicy)

if verdict.accepted then
    lastHit[attacker.UserId] = os.clock()
    applyDamage(target, 24)
else
    abuse:Report(attacker.UserId, verdict.reason)
end

Players.PlayerRemoving:Connect(function(player)
    history:Forget(player.UserId)
end)
```

## `History`

`History.new({windowSeconds, sampleRate?})` — a bounded ring buffer per entity.

| Method | Behaviour |
|---|---|
| `Record(id, position, at)` | Appends. Drops out-of-order and non-finite samples silently — interpolation depends on ordering. Stores a copy. |
| `SampleAt(id, at)` | Interpolated position, or `nil` + reason. |
| `Newest(id)` / `Oldest(id)` / `Span(id)` | Retained bounds. |
| `Count(id)` / `Entities()` / `Forget(id)` | Bookkeeping. |

The three failure reasons mean different things:

- `"unknown"` — no record at all. There is nothing to hit.
- `"future"` — ahead of the newest sample. See below; this is **not** automatically a lie.
- `"expired"` — older than the retained window. **The policy edge.**

The window is measured back from the **newest recorded sample**, not from wall-clock now, so
a verdict doesn't change based on when the caller happens to ask.

Interpolation is linear on purpose: we're reconstructing a few tens of milliseconds of
travel, where the error sits far below hitbox size, and a smoother curve fitted through
client-influenced samples would invent motion that never happened.

## `Claim`

`Claim.resolve(claim, context, policy?) -> Verdict`. Never throws.

Checks run cheapest-and-most-certain first, so an obviously bogus claim never reaches a
raycast: **cooldown → equipped → alive → team → timestamp → origin → range → sight.**

Two of those deserve calling out.

**Origin is checked against history.** A client can name *any* origin it likes, and without
this check every range test measures from a point the attacker invented. This is the one
people forget.

**A claim slightly ahead of the newest sample is not a lie.** History is sampled at a fixed
rate, so an honest attack routinely lands 20–40 ms *between two ticks*. Rejecting those
would throw away a large share of legitimate hits, so inside `futureToleranceSeconds` the
claim clamps to the newest record. Past that, it's a claim about a future we have no record
of.

## The policy, and the tradeoff you own

`expired` means the claim reached past what we retained — we genuinely **cannot verify it
either way**. What to do is a judgement call about your game, not a fact, so it's a policy:

```lua
Claim.DEFAULT_POLICY = {
    onExpired = "reject",          -- or "acceptWithTightRange"
    rangeSlackStuds = 4,
    tightRangeSlackStuds = 0,
    futureToleranceSeconds = 0.05,
    originSlackStuds = 6,
}
```

- **`"reject"`** (default, conservative): a player whose connection hiccuped past the window
  loses hits that were probably legitimate. It feels like the game ignoring you.
- **`"acceptWithTightRange"`**: those players get their hits back, at the cost of a window an
  attacker can aim at — fake a large latency, claim a stale timestamp. The only thing still
  guarding you is the tightened range check against the **oldest** position on record, which
  is why `tightRangeSlackStuds` defaults to 0.

A game with generous hitboxes and forgiving TTK can afford to accept. A precise one cannot.
Set it in game config, not here — see `game/src/ReplicatedStorage/CombatPolicy.luau`.

## License

MIT
