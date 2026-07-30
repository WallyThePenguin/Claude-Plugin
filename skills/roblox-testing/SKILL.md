---
name: roblox-testing
description: Use when writing, running, or debugging tests for Roblox/Luau code outside Studio — Lune specs, the forge test runner, faking Roblox services, deciding what can be unit-tested versus what needs an in-Studio playtest. Triggers on "write tests", "run the tests", "lune", "spec.luau", "test runner", "mock DataStore", "fake RunService", or "how do I test this".
---

# Testing Luau outside Studio

Two test surfaces, and knowing which one a piece of code belongs to is most of the skill:

| Surface | Runs | Tests |
|---|---|---|
| **Lune** (`lune run scripts/test.luau`) | in a terminal, milliseconds | pure logic: state machines, validation, math, ledgers, migrations, diffing |
| **Studio** (StudioAgent `play`) | a real playtest | anything touching instances, physics, replication, input, animation |

Most bugs live in the first category, and the first category is a thousand times cheaper to
run. So the goal is to keep as much code as possible testable there — which is a *design*
constraint, not a testing one.

## The constraint that makes it work

**Lune has no `script`, no `game`, no services.** So:

- `require("./Sibling")` — Lune requires must start with `./`, `../` or `@`. *Verified on
  Lune 0.10.5.*
- `require(script.Sibling)` — Roblox syntax. **Unresolvable in Lune.**

A package's `init.luau` uses the Roblox form, so **specs never require `../src/init`.**
They require the sibling modules directly:

```lua
--!strict
local Signal = require("../src/Signal")   -- yes
-- local Signal = require("../src/init")  -- no: `script` is nil under Lune

return function(t)
	t.test("fires listeners with the payload", function(expect)
		local s = Signal.new()
		local got
		s:Connect(function(v) got = v end)
		s:Fire(7)
		expect(got).toBe(7)
	end)
end
```

Hence the layering rule for every package here: **`init.luau` is a one-line aggregator,
all logic lives in siblings.** The untestable surface shrinks to a line that is trivially
correct by inspection.

## Inject, don't import

The other half of testability: a module that reaches for a service is stuck in Studio. A
module that *takes* one can be tested anywhere.

```lua
-- Untestable outside Studio.
local DataStoreService = game:GetService("DataStoreService")

-- Testable: the caller supplies it, a spec supplies a fake.
function Store.new(dataStore: DataStoreLike, clock: () -> number)
```

Passing `clock` matters more than it looks — it turns "wait 30 seconds for the lock to go
stale" into `clock = function() return 31 end`. Anything time-dependent should take its
clock.

`forge-testkit` provides the fakes: DataStore, Players, RunService, a controllable clock.

## The runner

```sh
lune run scripts/test.luau                  # everything
lune run scripts/test.luau forge-signal     # filter by package or path substring
lune run scripts/test.luau -- --verbose      # name every passing test
```

It discovers `packages/*/tests/**/*.spec.luau` and `game/tests/**`. A spec file returns
`function(t)`; inside, `t.test(name, fn)` and `fn` receives `expect`.

Matchers: `toBe`, `toEqual` (deep), `toBeTruthy`, `toBeFalsy`, `toBeNil`, `toContain`,
`toBeCloseTo(n, tolerance?)`, `toThrow(substring?)`.

Exit code is 1 on any failure, so CI and hooks can gate on it.

`toThrow` takes a function, and pairs well with the validation code in
`skills/roblox-server-authority`:

```lua
t.test("rejects NaN", function(expect)
	expect(function() validate(0 / 0) end).toThrow("finite")
end)
```

## What to test

Worth specs:

- State machines — every transition, and the illegal ones.
- Validation — the boundary values, and specifically `NaN`, `math.huge`, negative zero,
  non-integers, wrong types, missing arguments.
- Ledgers and economy — idempotency (apply the same transaction id twice, expect one
  effect), and ordering.
- Migrations — every version chain from every old fixture.
- Anything with arithmetic: damage formulas, XP curves, rate-limit budgets, interpolation.

Not worth specs:

- Getters, and tables of constants.
- Thin adapters whose only job is to call one Roblox API.
- `init.luau` aggregators.

## When Lune isn't enough

Physics, replication timing, input, animation, and anything where the *feel* is the
requirement need a real playtest. That's StudioAgent's job:
`scripts/studio-agent.ps1 play` runs an unmanned playtest and returns logs, so a "does the
round loop actually progress" check is automatable too — it's just slower and coarser.

Rule of thumb: if a spec can express it, a spec should. If the only honest assertion is
"a human looked at it", capture a screenshot and grade it against a rubric — the existing
`evaluate` path in this repo already does that.
