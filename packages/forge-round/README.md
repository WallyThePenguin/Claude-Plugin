# forge-round

Round and match lifecycle for Roblox: a guarded state machine, a wait-time-fair matchmaking
queue, and a thin Roblox adapter.

## Install

```sh
forest i @Valid/forge-round
```

## Why a machine and not a loop

The obvious implementation is `while true do ... task.wait(n) end`. It works right up until
you need anything real: aborting a round when players leave, an admin force-ending, a rejoin
mid-match, or a test. **A coroutine parked inside a `wait` cannot be asked what phase it is
in, cannot be interrupted, and cannot be tested without real time passing.**

So the lifecycle is data — a phase, an entry timestamp, and a table of legal transitions.
`Tick(now, world)` is a pure function of `(state, time, world) → transitions`, which makes it
inspectable, interruptible, and testable in microseconds. 32 specs, none of which wait.

## Phases

```
idle ──▶ queueing ──▶ intermission ──▶ active ──▶ results ──┬──▶ idle
          ▲   │            │                                │
          └───┴────────────┘                                └──▶ queueing
```

Every legal edge lives in one table. **A transition not listed cannot happen** — so a bug
surfaces as a loud error at the transition rather than as a game wedged in a phase nobody can
name.

Four behaviours worth calling out, each of which is a real bug avoided:

- **A lobby shrinking during intermission falls back to `queueing`** instead of starting a
  match that would abort on its first tick.
- **The objective beats the timer.** A round won with 40 seconds left ends with reason
  `objective-met`, and that reason is what the results screen reports.
- **`results` goes straight back to `queueing`** when players are already waiting. Making
  them sit through an idle phase they can't see is dead air.
- **One `Tick` resolves the whole cascade**, so a caller ticking at 5 Hz behaves identically
  to one at 60 Hz.

## Usage

```lua
local Round = require(ServerPackages["forge-round"])

local service = Round.Service.new({
    minPlayers = 2,
    maxPlayers = 8,
    intermissionSeconds = 5,
    roundSeconds = 180,
    resultsSeconds = 8,
    abortBelowPlayers = 1,
})

service.MatchStarted:Connect(function(round, playerIds)
    arena:Spawn(playerIds)
end)

service.MatchEnded:Connect(function(round, reason)
    -- reason is one of: objective-met, time-limit, aborted-too-few-players, forced
    scoreboard:Show(round, reason)
end)

service.PhaseChanged:Connect(function(transition)
    Replicate:SetPhase(transition.to, service:Remaining())
end)

service:Start()   -- nothing is connected until this call
```

`Start()` is separate from `new()` on purpose: no require-time or construction-time side
effects, so this slots into `forge-lifecycle`'s Init/Start ordering rather than racing it.

## API

`Round.Service` — the Roblox adapter. `new(config, clock?)`, `Start()`, `Destroy()`,
`Join(id)`, `Leave(id)`, `SetObjectiveMet(bool)`, `Phase()`, `Remaining()`, `Round()`,
`QueueSize()`, `LongestQueueWait()`, `IsParticipant(id)`. Signals: `PhaseChanged`,
`MatchStarted`, `MatchEnded`, `QueueChanged`.

The roster locks when the match **starts**, not when the countdown begins — a player who
queues during intermission still gets in.

`Round.Machine` — the pure machine. `Tick(now, world)`, `Phase()`, `Remaining(now)`,
`Elapsed(now)`, `Force(phase, now)`, `CanTransition(phase)`, `Round()`. Exposed because a
custom lifecycle can drive it without adopting our Roblox glue.

`Round.Queue` — `Join(id, now)`, `Leave(id)`, `Take(count)`, `Peek(count)`, `Contains(id)`,
`Size()`, `WaitedFor(id, now)`, `LongestWait(now)`, `Clear()`.

Fair by **wait time**, not skill rating. With a handful of concurrent players, rating-based
matching just makes everyone wait longer for a worse match; add it when population justifies
it. `Take` returns fewer than asked rather than refusing — whether a short match is
acceptable is the machine's `minPlayers` policy, not the queue's. Joining twice is a no-op
that preserves your place in line, because a double-click is a UI event, not an exploit.

Surface `LongestWait`, not the average: the average hides the player who has been waiting
four minutes, and that's the player who leaves.

## Dependencies

Consumes two mirrored Wally packages rather than reimplementing them:

- `sleitnick/signal` — events
- `sleitnick/trove` — cleanup and lifetimes

Both are used only in `RoundService.luau`, the single Roblox-facing file. `Machine` and
`Queue` stay dependency-free and pure, which is why they're the tested part.

## License

MIT
