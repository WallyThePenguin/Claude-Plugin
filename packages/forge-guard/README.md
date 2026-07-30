# forge-guard

Server-side anti-exploit primitives for Roblox: argument validation, token-bucket rate
limits, decaying abuse scores, and movement plausibility checks.

**Server realm only.** Mount under `ServerScriptService` using Forest's two-manifest
pattern. A guard enforced somewhere the attacker controls is not a guard.

## Install

```sh
forest i @<scope>/forge-guard
```

## Why this exists

Nothing in the mirrored Wally ecosystem covers it. `sleitnick/net` has no rate limiting at
all — and a perfectly valid remote call at 500 Hz is an attack that argument validation
cannot see.

Every module is pure Luau with an injected clock, so all of it runs under Lune — 59 specs,
mostly hostile inputs. That matters for a package whose entire value is *correctly*
validated boundaries.

## Usage

```lua
local Guard = require(ServerPackages["forge-guard"])
local Validate, RateLimit, AbuseScore = Guard.Validate, Guard.RateLimit, Guard.AbuseScore

-- Declare the shape of what the client may send. Arity included.
local swingArgs = Validate.tuple({
    Validate.literal("light", "heavy"),
    Validate.instanceOf("Humanoid"),
})

local swingLimit = RateLimit.new({ rate = 3, burst = 5 }, os.clock)
local abuse = AbuseScore.new({ threshold = 10, decayPerSecond = 0.5 }, os.clock)

SwingRemote.OnServerEvent:Connect(function(player, ...)
    -- Rate first: cheapest check, and it is what stops a flood.
    if not swingLimit:Consume(player.UserId) then
        abuse:Report(player.UserId, "rate")
        return
    end

    local ok, reason = swingArgs(...)
    if not ok then
        -- Log the reason for YOU. Never send it back: telling an attacker which
        -- check they failed is free reconnaissance.
        warn(`[guard] {player.Name} bad swing: {reason}`)
        abuse:Report(player.UserId, "malformed", 2)
        return
    end

    if abuse:Exceeded(player.UserId) then
        -- Act on the accumulated score, never on a single observation.
        kick(player, abuse:Breakdown(player.UserId))
        return
    end

    -- ...only now do you have arguments worth reasoning about.
end)

Players.PlayerRemoving:Connect(function(player)
    -- A per-player table with no cleanup is both a leak and its own DoS surface.
    swingLimit:Forget(player.UserId)
    abuse:Forget(player.UserId)
end)
```

## API

### `Validate`

Every validator is `(value: unknown) -> (boolean, string?)`. Compose freely.

| Constructor | Notes |
|---|---|
| `Validate.number(opts?)` | `{min, max, integer, allowNaN, allowInfinite}`. **Rejects NaN and both infinities by default**, and anything past 2^53. |
| `Validate.integer(min, max)` | The common case, named so it is hard to get wrong. |
| `Validate.string(opts?)` | `{minLength, maxLength, pattern}`. Defaults to a 256-char ceiling — an unbounded string is a bandwidth and storage attack. |
| `Validate.boolean()` | Strict; `0` and `"true"` are rejected. |
| `Validate.literal(...)` | One of a fixed set. The right shape for anything the client "chooses". |
| `Validate.optional(inner)` | `nil` passes; a present value is still validated. |
| `Validate.array(inner, opts?)` | Rejects sparse tables and mixed keys. Default 64-element ceiling. |
| `Validate.shape(fields)` | Exact table shape. **Extra fields are rejected**, not ignored. |
| `Validate.map(keyV, valueV, max?)` | Bounded entry count. |
| `Validate.instanceOf(className)` | Proves the class. Proves **nothing** about ownership — that check is yours. |
| `Validate.vector3(opts?)` | Per-component finiteness, optional `maxMagnitude`. |
| `Validate.tuple({...})` | An argument list, **arity included**. This is the remote entry point. |

Why NaN gets its own check: it defeats every comparison. `NaN > 100` is false *and*
`NaN <= 100` is false, so `if n < 1 or n > 100 then reject end` lets it straight through,
after which it poisons arithmetic silently and persists into saved data.

### `RateLimit.new(options, clock)`

Token bucket, not a fixed window — a fixed window allows 2N calls across its boundary and
false-positives on legitimate bursts.

`{rate, burst?, idleTimeout?}`. Methods: `Consume(key, cost?)`, `Rejections(key)`,
`Forget(key)`, `Prune()`, `Count()`.

Rejection is silent by design. Survives a non-monotonic clock without draining.

### `AbuseScore.new(options, clock)`

`{threshold, decayPerSecond, maxScore?, idleTimeout?}`. Methods: `Report(key, kind,
weight?)`, `Score(key)`, `Exceeded(key)`, `Breakdown(key)`, `Forget(key)`, `Prune()`.

On Roblox almost every individual signal is ambiguous — one impossible speed sample is lag,
one rejected remote is a dropped packet. Acting on a single observation punishes players on
bad connections, which is worse than missing a cheater: the cheater comes back, the
wrongly-kicked player does not. So weight the evidence, decay it, act on the total.
`maxScore` stops a burst banking a debt that keeps someone flagged after they stopped.

Note that decay applies *before* each report, so N weight-1 reports never reach a score of
N. Size thresholds against the arithmetic, not intuition.

### `Movement`

`Movement.check(previous, current, elapsed, options) -> {Violation}` and
`Movement.withinRadius(sample, centre, radius)`.

Produces **evidence, not verdicts** — Roblox replicates character physics from the client
by design, and fighting that gives you rubber-banding that feels worse than the cheating.
Feed the violations to `AbuseScore`.

`minInterval` (default 0.1s) exists because over a 10 ms interval one stud of replication
jitter reads as 100 studs/second — the single biggest source of false positives in naive
implementations. `maxStep` is interval-independent, so a teleport arriving inside one tick
is still caught. Violation weights scale with severity and cap at 4, so one absurd sample
cannot single-handedly trip a threshold.

Takes `{X, Y, Z}` tables as well as `Vector3`, which is how it stays Lune-testable.

## License

MIT
