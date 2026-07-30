# forge-testkit

Roblox API fakes so Luau packages can be unit-tested in a terminal, under
[Lune](https://lune-org.github.io/docs), instead of inside Studio.

**Dev dependency.** Nothing in shipped code should require this.

## Install

```sh
forest i @<scope>/forge-testkit
```

## Why fakes rather than a Roblox emulator

The point is not to test the happy path — that always works. It's to test the paths that
only happen in production and are impossible to trigger reliably against the real thing:

- A DataStore call that fails three times and then succeeds.
- A value written by a *newer* schema than this server understands.
- A player leaving mid-save.
- A client sending `NaN`, wrong arity, or 500 calls a second.
- "Player B claims to be acting on player A's inventory."

Those are the paths that cause data loss and exploits. Everything here exists to make them
one line each.

## Usage

```lua
local TestKit = require(Packages["forge-testkit"])

local clock = TestKit.Clock.new()
local store = TestKit.DataStore.new()
local players = TestKit.Players.new()

store:Seed("p1", { version = 1, coins = 5 })   -- old-schema fixture, no call recorded
store:FailNext(2, "throttled")                 -- now test your retry loop

local profile = MyStore.new(store, clock.Now)
profile:Load("p1")

clock.Advance(31)                              -- the session lock is now stale
assert(store:CallCount("UpdateAsync") == 3)    -- two failures, one success
```

## Modules

| Module | For |
|---|---|
| `TestKit.Clock` | `Now`, `Advance`, `Set`, `Delay`. Turns "after 30 seconds" into an instant assertion. `Set` goes backwards on purpose — a non-monotonic clock is a real condition worth testing. |
| `TestKit.Signal` | A minimal signal, so the other fakes have events. Not a production signal — take `sleitnick/signal` for that. |
| `TestKit.DataStore` | In-memory `GetAsync`/`SetAsync`/`UpdateAsync`/`RemoveAsync`/`IncrementAsync`, plus `Seed`, `Peek`, `FailNext`, `FailAlways`, `Calls`, `CallCount`. |
| `TestKit.Players` | `PlayerAdded`/`PlayerRemoving`, `Add`, `Remove`, `GetPlayers`, `GetPlayerByUserId`. `Kick` is recorded, not acted on. |
| `TestKit.Remote` | `Remote.event()` and `Remote.func()`. `FireServer` takes the sender **explicitly**. |

### Details that matter

**The DataStore hands back deep copies.** The real service serialises, so a caller can't
hold a live reference — a fake that returns the same table would hide production code that
mutates what it believes is a private copy.

**It's synchronous.** Real DataStore calls yield, but what you're testing is the *decision
logic* around the call, and that's identical either way. Where yield ordering itself is the
subject, sequence it explicitly with `FailNext` plus the fake clock.

**`Seed` and `Peek` don't record calls**, so assertions on `CallCount` stay meaningful.

**`PlayerRemoving` fires while the player is still listed**, matching the real service, so
handlers that iterate players during removal behave the same way.

**`FireServer(player, ...)` takes the sender.** The engine injects it and a client can't
forge it — but in a spec you *want* to send as whoever you like. That's a test case, not a
bug in the fake.

**An unbound `OnServerInvoke` errors.** In production that shows up as a mysterious client
hang; here it's loud.

## Using it inside this workspace

Lune requires are **file paths**, so a spec in another package reaches these directly:

```lua
local FakeClock = require("../../forge-testkit/src/FakeClock")
```

That's a dev-time file reference, not a Forest dependency — which is why no package here
declares `forge-testkit` in its `forest.json`, and why `.forestignore` keeps `tests/` out of
every published archive.

## License

MIT
