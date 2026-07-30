---
name: forest-workspace
description: Use when working inside this repo's packages/ monorepo — adding a workspace package, wiring one package to another, running the offline audit or the Lune test suite, ordering a multi-package release, or figuring out whether new code belongs in a package or in game/. Triggers on "forge.py", "packages/", "workspace", "which package should this go in", "run the tests", or "release order".
---

# This repo's Forest workspace

## Layout

```
.claude-plugin/       plugin + marketplace manifests
skills/ commands/ agents/ hooks/
scripts/
  forge.py            offline workspace tool: list, order, audit, new, version
  test.luau           Lune test runner
  forest.sh/.ps1      CLI wrappers that resolve the binary regardless of PATH
packages/<name>/      one Forest package each — publishable, versioned, tested
game/                 Forge Arena; consumes packages via forest install
src/ sidecar/         StudioAgent: the in-Studio execution surface (unchanged)
```

`packages/` and `game/` are the new work. `src/` and `sidecar/` are the existing Roblox
Studio plugin and its Python bridge — they keep working as-is and own everything that
must happen *inside* Studio (geometry, capture, playtests, rigs, animation).

## The daily loop

```sh
python scripts/forge.py list                    # every manifest and its role
python scripts/forge.py audit                   # offline integrity; exit 1 on error
lune run scripts/test.luau                      # all specs
lune run scripts/test.luau forge-signal         # one package
python scripts/forge.py order                   # dependency order (deps first)
python scripts/forge.py new forge-thing --description "..."
```

`forge.py` never touches the network. That is what lets CI run `audit` on every push, and
lets you verify a change without a `forest install` round-trip. Network operations —
`install`, `publish`, `login` — belong to the `forest` CLI and stay there.

## Package conventions

Every workspace package:

- Is named `forge-<thing>`, lowercase and hyphenated (Forest requires that charset).
- Declares `"root": "src/init.luau"` explicitly — never relies on root auto-detection.
- Keeps `src/init.luau` a **thin aggregator**; all logic in siblings. Non-negotiable:
  Lune can't resolve `script`, so anything in `init.luau` is untestable outside Studio.
- Uses **relative requires only**. `forge.py audit` fails the build otherwise.
- Has no require-time side effects. Initialise through `:Init()` / `:Start()`.
- Ships `README.md`, `LICENSE` (MIT), `CHANGELOG.md`, `.forestignore`.
- Has specs under `tests/` requiring **sibling modules**, never `../src/init`.
- Leaves `author` blank until publish. `audit` warns, which is correct — it's a
  publish-time requirement, not a development one.

## Wiring one package to another

Install it like any dependency, from inside the consuming package:

```sh
cd packages/forge-net
../../scripts/forest.sh i @scope/forge-signal
```

Because `forge-net` declares `root`, that lands in `packages/forge-net/src/Packages/` —
right next to the root module — so `require(script.Parent.Packages["forge-signal"])`
resolves identically at dev time and after a consumer installs it.

**Before the packages are published there is nothing to install.** During M2/M3, a
cross-package dependency is a declared intent in `forest.json` plus a local require path
that will resolve once published. Prefer keeping tier boundaries clean enough that this
rarely comes up: tier 0 depends on nothing, tier 1 on tier 0, tier 2 on tier 0 and 1.

## Package or game? The test

Put it in a **package** if it would still make sense in a different game. Put it in
**`game/`** if it encodes a decision specific to Forge Arena.

- Round *state machine* → package (`forge-round`). Round *durations and wave counts* →
  `game/`.
- Hit *resolution* → package (`forge-combat`). *Which weapon does 24 damage* → `game/`.
- Currency *ledger* → package (`forge-economy`). *Prices* → `game/`.

`game/` should read like wiring and tuning data. When a file in `game/` starts growing
logic that isn't Forge-Arena-specific, that's the signal to move it.

## The roster

Tier 0 depends on nothing; tier 1 on tier 0; tier 2 on both.

| Tier | Package | Owns |
|---|---|---|
| 0 | `forge-signal` | Signal, promise-lite, cleanup/trove |
| 0 | `forge-testkit` | Roblox API fakes so packages test under Lune |
| 0 | `forge-lifecycle` | Service registry, dependency-ordered Init/Start |
| 0 | `forge-sched` | Fixed-step tick, timers, debounce/throttle |
| 1 | `forge-net` | Typed remotes: schema validation, rate limits, request/response |
| 1 | `forge-state` | Server-owned store, delta-replicated to read-only client mirrors |
| 1 | `forge-store` | Profiles: session lock, migrations, retry/backoff. **Server realm.** |
| 1 | `forge-guard` | Anti-exploit: validation, movement sanity, abuse scoring. **Server realm.** |
| 1 | `forge-ui` | UI runtime, HUD primitives, theme tokens. **Client realm.** |
| 2 | `forge-combat` | Server-authoritative hit resolution, lag-comp window, damage pipeline |
| 2 | `forge-round` | Round/match state machine, matchmaking queue, results |
| 2 | `forge-economy` | Currency, inventory, shop, idempotent ledger, anti-dupe |

**Check for a Wally mirror before writing any of these.** Forest mirrors the whole
open-source Wally ecosystem (`forest i evaera/promise`). If a mirror does the job, take
it and delete ours — reimplementing a maintained library is a permanent maintenance bill.
Where we keep ours, the README says why.

## Release order

```sh
python scripts/forge.py order
```

Publish dependencies before dependents, or a dependent's range can't resolve. `order` is
cycle-tolerant, so it still prints something useful if `audit` warned about a cycle — but
fix the cycle; two packages that need each other are usually one package.

`forest publish` needs a TTY and is the user's to run. See `skills/forest-author`.
