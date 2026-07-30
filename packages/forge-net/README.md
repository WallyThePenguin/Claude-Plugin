# forge-net

A router for client→server calls that enforces the right order of operations: **rate limit,
then validate, then handle, then contain.**

## Install

```sh
forest i @<scope>/forge-net
```

## Why the order matters

Getting it wrong is how games get exploited. If validation runs before rate limiting, an
attacker still burns your CPU on 500 malformed calls a second — the flood is free for them
and expensive for you. And a throwing handler inside `OnServerEvent` is *swallowed by the
engine*, so without containment a broken route is invisible for weeks.

`sleitnick/net` (mirrored, 0.2.0) covers typed remotes but has no rate limiting at all.
That gap is what this package exists for.

## Zero dependencies, on purpose

The router accepts a `validate` **function** and a `rateLimit` **object** rather than
importing them. Both are duck-typed interfaces that `forge-guard` satisfies
(`Validate.tuple` and `RateLimit`). Dependency inversion buys two things:

- The router is fully testable under Lune. A Forest dependency lands in `src/Packages/`, a
  path Lune cannot resolve.
- Consumers can bring their own validator library — `osyrisrblx/t`, anything — without
  forking this.

## Usage

```lua
local Router = require(ServerPackages["forge-net"])
local Guard = require(ServerPackages["forge-guard"])

local abuse = Guard.AbuseScore.new({ threshold = 10, decayPerSecond = 0.5 }, os.clock)

local router = Router.new({
    -- Your telemetry hook. Feed it to an AbuseScore and act on the accumulated score.
    onReject = function(player, route, kind, reason)
        abuse:Report(player.UserId, kind)
        if reason then
            warn(`[net] {player.Name} {route}: {reason}`)
        end
    end,
    onError = function(player, route, err)
        warn(`[net] {route} threw for {player.Name}: {err}`)
    end,
})

router:Route("Swing", {
    rateLimit = Guard.RateLimit.new({ rate = 3, burst = 5 }, os.clock),
    validate = Guard.Validate.tuple({
        Guard.Validate.literal("light", "heavy"),
        Guard.Validate.instanceOf("Humanoid"),
    }),
    handler = function(player, style, target)
        Combat:Resolve(player, style, target)
    end,
})

SwingRemote.OnServerEvent:Connect(function(player, ...)
    router:Dispatch("Swing", player, ...)
end)

Players.PlayerRemoving:Connect(function(player)
    router:Forget(player)
end)

game:BindToClose(function()
    router:Close()   -- reject new work before flushing saves
end)

-- Audit at boot: an unlimited route should be a visible decision, not an oversight.
for _, name in router:UnlimitedRoutes() do
    warn(`[net] route {name} has no rate limit`)
end
```

## API

`Router.new(options?)` — `{onReject, onError}`.

| Method | Behaviour |
|---|---|
| `Route(name, route)` | `{validate?, rateLimit?, cost?, handler}`. Duplicate names error. |
| `Dispatch(name, player, ...)` | `false` on rejection or handler error; `true, ...` otherwise. An unknown route **errors** — that's a server bug, not a client attack. |
| `Forget(player)` | Clears rate-limit state across every route. Call from `PlayerRemoving`. |
| `Close()` / `IsOpen()` | Reject everything from here on. For `BindToClose`. |
| `Stats(name)` | `{accepted, rejectedRate, rejectedInvalid, errored}`. |
| `Routes()` / `UnlimitedRoutes()` | Sorted names; the second is your audit hook. |

`cost` lets an expensive route drain more of a shared bucket than a cheap one.

## What the caller never learns

`Dispatch` returns a bare `false`. The client is told nothing about *why* — naming the
failed check is free reconnaissance. The detail goes to `onReject`, which is yours.

## License

MIT
