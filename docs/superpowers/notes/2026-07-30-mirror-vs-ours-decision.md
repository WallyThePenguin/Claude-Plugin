# 2026-07-30 — Mirror audit: which packages we do NOT write

The M2 plan said: *"before writing each tier-0 package, audit it against existing mirrors
and drop ours if a mirror is strictly better."* This is that audit. It cut the roster from
12 hand-rolled packages to **7 written + 7 taken**.

Method: probe the registry by attempting the install. There's no `forest search`, so a
successful `forest i <author>/<name>` is the existence check. All versions below are what
actually resolved on 2026-07-30 against forest 1.8.0.

## Taken — do not write these

| Mirror | Version | Replaces | Why it wins |
|---|---|---|---|
| `sleitnick/signal` | 2.0.3 | `forge-signal` | Mature, minimal, the de-facto Roblox signal. `stravant/goodsignal` (0.3.1) is also mirrored if we ever want the other lineage. |
| `sleitnick/trove` | 1.8.0 | `forge-signal` (cleanup half) | Cleanup/lifetime management, done properly. |
| `evaera/promise` | 4.0.0 | `forge-signal` (promise half) | The reference Roblox Promise. Writing a "promise-lite" against this would be strictly worse. |
| `nezuo/lapis` | 0.3.4 | **`forge-store`** | The big one. Ships `Collection`, `Document`, `Migration`, `AutoSave`, `Error`, `noYield`, `freezeDeep` — i.e. session locking, forward migrations, autosave and retry, all battle-tested. Everything `forge-store` was scoped to do, already done and maintained. |
| `littensy/reflex` | 4.3.1 | **`forge-state`** | Redux-shaped store with server→client replication built in. Strictly better than a hand-rolled delta replicator. `littensy/charm` (0.11.0) is the lighter atom-based alternative, also mirrored. |
| `jsdotlua/react` | 17.2.1 | **`forge-ui`** | Real React. A hand-rolled UI runtime cannot compete. (`roblox/roact` 1.4.4 also mirrored.) HUD components and theme tokens are *game-specific*, so they live in `game/`, not a package. |
| `osyrisrblx/t` | 3.1.1 | — | Runtime type validation. Available, and noted — but see the deliberate non-use below. |

Also confirmed mirrored and considered: `sleitnick/knit` 1.7.0, `sleitnick/net` 0.2.0,
`sleitnick/component` 2.4.8, `sleitnick/option` 1.0.5.

## Dropped outright

- **`forge-sched`** — a fixed-step tick and debounce/throttle is a handful of lines over
  `task` and `RunService`. The one place a real fixed-step buffer is needed is
  `forge-combat`'s position history, so it lives there where it's actually used. A package
  that exists to wrap `task.wait` earns nothing.

## Written — and the specific gap each one fills

| Package | Tier | Nearest mirror | Why ours anyway |
|---|---|---|---|
| `forge-testkit` | 0 | none | Roblox API fakes for **Lune**, so packages can be unit-tested in a terminal. Nothing in the ecosystem targets this; it's the foundation of the test strategy. |
| `forge-lifecycle` | 0 | `sleitnick/knit` 1.7.0 | Knit does Init/Start ordering — but bundles its own networking and component system, both of which we're replacing. Ours is a small dependency-free registry. **This is the weakest "write" call on the list**; if it grows past ~200 lines, take Knit instead. |
| `forge-net` | 1 | `sleitnick/net` 0.2.0 | Net has **no rate limiting**. Per-player token buckets on every remote is the gap, and it's the one that matters — a perfectly valid call at 500 Hz is an attack. |
| `forge-guard` | 1 | none | Anti-exploit: validation, movement sanity, abuse scoring, telemetry. No mirror addresses it. |
| `forge-combat` | 2 | none | Server-authoritative hit resolution with a bounded lag-compensation rewind buffer. |
| `forge-round` | 2 | none | Round/match state machine and matchmaking queue. |
| `forge-economy` | 2 | none | Idempotent transaction ledger and anti-dupe. Lapis persists data; it says nothing about transaction semantics. |

## One deliberate non-use: `osyrisrblx/t`

`t` is good and it's mirrored, and `forge-net`/`forge-guard` could take it for schema
validation. They don't, for one reason: **a dependency lands in
`packages/<name>/src/Packages/`, and Lune cannot resolve `script.Parent.Packages.t`.** A
package whose entire value proposition is *correctly validated boundaries* must have its
boundary checks under test — including the cases that are easy to get wrong (`NaN` defeats
every comparison, since `NaN > 0` and `NaN <= 0` are both false; `math.huge`; non-integers;
negative zero).

So tier-1 packages stay **dependency-free and 100% Lune-testable**, with ~60 lines of
validation written here and specced against those boundaries. If the validator ever grows
past that, revisit — `t` is the better answer for a large schema surface.

## Net effect

Five planned packages deleted, one dropped, seven kept. The work now concentrates on what
is genuinely novel and genuinely hard — server authority, lag compensation, anti-exploit,
transaction integrity — instead of on reimplementing signals and promises.
