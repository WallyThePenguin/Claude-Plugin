---
name: roblox-persistence
description: Use when saving or loading player data in Roblox — DataStoreService, profiles, session locking, schema migrations, retry and backoff, request budgets, OrderedDataStore leaderboards, or debugging data loss and rollbacks. Triggers on "DataStore", "GetAsync", "SetAsync", "UpdateAsync", "save player data", "session lock", "data loss", "ProfileService", "leaderboard", or "migration".
---

# Persistence

Data loss is the one bug players never forgive. Everything here exists because some game
shipped without it and rolled back a thousand inventories.

## Non-negotiables

**1. `UpdateAsync`, not `GetAsync` + `SetAsync`.** The get/set pair is a read-modify-write
race across a network yield: two servers (or one server twice) both read the old value and
the second write wins. `UpdateAsync` gives you the current value inside a transform
function and retries on conflict.

**2. Session locking.** Two servers holding the same player's profile will overwrite each
other. Stamp the profile with a `(jobId, timestamp)` claim inside `UpdateAsync`:

- Unlocked, or lock older than the staleness threshold → take it.
- Locked and fresh → the player is live elsewhere. Do **not** load. Retry a bounded number
  of times, then refuse and tell the player, rather than forking their data.
- Release on `PlayerRemoving` **and** on `BindToClose`.

**3. `BindToClose`.** Without it, a server shutdown drops every unsaved profile. Roblox
gives you a short window — save everything, and don't start new work you can't finish.

**4. Never save on a timer alone.** Save on meaningful change (debounced), on
`PlayerRemoving`, and on `BindToClose`. A pure 60-second timer loses up to 60 seconds.

**5. Retry with backoff, and give up loudly.** DataStore calls fail. Wrap every one in
`pcall`, retry with exponential backoff and jitter, cap the attempts, and on final failure
**mark the profile unsaveable and stop mutating it** — do not let gameplay continue writing
to data that will never persist. A player who loses a session is annoyed; a player who
loses their account is gone.

## Request budgets

DataStore budgets are per-server and scale with player count. Blowing the budget doesn't
error — it *queues*, so calls silently get slower until they time out. Check
`DataStoreService:GetRequestBudgetForRequestType()` before bulk operations, and treat a
shrinking budget as backpressure.

Practical consequences:

- One profile per player, not one key per stat. Ten keys per player is ten times the budget.
- Batch. Debounce. Coalesce writes to the same key.
- Leaderboard writes are the usual budget sink — write them on a slow cadence.

## Schema migrations

Player data outlives every assumption in it. Version the schema from day one:

```lua
local CURRENT_VERSION = 3

local MIGRATIONS = {
    -- each takes data at version N and returns data at N+1
    [1] = function(data) data.cosmetics = {}; return data end,
    [2] = function(data) data.xp = (data.level or 1) * 100; data.level = nil; return data end,
}
```

Rules that keep this safe:

- Migrations run **forward only**, in order, on load.
- A migration never fails destructively. If it can't understand the data, keep the original
  and flag the profile for inspection.
- **Never** write a newer schema than the running server understands — a rollback then
  reads data from the future. Gate on `data.version <= CURRENT_VERSION`.
- Keep old migrations forever. Someone hasn't played in two years.
- Test migrations against real fixtures, not fresh profiles. That's what a fake DataStore
  is for — see `skills/roblox-testing`.

## Leaderboards

`OrderedDataStore` gives you sorted top-N cheaply, but it holds **one number per key**.
So: one OrderedDataStore per board, key by user id, value the score. Read the top page,
then resolve names separately (and cache them).

- Write on a slow cadence, not per-event.
- Never make it authoritative for gameplay — it's a display surface, and it lags.
- Global boards need a reset or decay strategy decided *before* launch. Retrofitting one
  onto a live board means either wiping it or living with an unreachable all-time top.

## Testing

Everything above is pure logic — claim/release, migration chains, retry decisions, budget
backpressure — *if* you keep it away from `DataStoreService`. Take the datastore as an
injected dependency:

```lua
function Store.new(dataStore: DataStoreLike, clock: () -> number)
```

Then a Lune spec passes a fake that returns canned values, fails on demand, and has a
controllable clock. That's how you test "lock is stale by one second" without waiting.

`forge-store` is built this way; `forge-testkit` provides the fake.

## Failure-mode checklist

- [ ] `UpdateAsync` everywhere a value is modified.
- [ ] Session lock claimed on load, released on `PlayerRemoving` **and** `BindToClose`.
- [ ] Stale-lock threshold set, and a bounded retry before refusing to load.
- [ ] Every call `pcall`ed, with backoff, jitter and an attempt cap.
- [ ] Final failure marks the profile unsaveable and stops mutating it.
- [ ] `BindToClose` flushes everything.
- [ ] Schema versioned; forward-only migrations; refuses data from the future.
- [ ] One key per player, not one per stat.
- [ ] Budget checked before bulk work.
- [ ] Migrations covered by specs against realistic fixtures.
