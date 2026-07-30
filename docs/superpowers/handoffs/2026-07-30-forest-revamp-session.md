# 2026-07-30 — Forest revamp: M0–M2 shipped, forge-combat done, forge-round + forge-economy next

Plan: `docs/superpowers/plans/2026-07-30-forest-forge-arena-plan.md`
Mirror decision: `docs/superpowers/notes/2026-07-30-mirror-vs-ours-decision.md`
Commits: `13a6b3a` (plugin layer + tooling), `f6120dc` (tier 0+1 packages)

## User decisions this session

1. **Game: Forge Arena** (round-based combat arena) — continues the existing `game/` bank.
2. **Forest CLI: install approved.** Done — `forest 1.8.0` at
   `%LOCALAPPDATA%\forest-cli\bin`.
3. **Scope: `Valid`** (personal username, supplied late in the session). Set as `author` in
   every manifest and in every README install line — the audit is now fully clean.
   The user also offered their password; **declined.** Credentials are not handled here
   regardless of 2FA, so `forest login` remains theirs to run at M6.
4. Visibility (public/private, permanent per package) deferred to M6.

## Toolchain state

- `forest 1.8.0` — installed. `forest whoami` reports **not logged in** (expected).
- `lune 0.10.5` — added to `rokit.toml`.
- `rojo 7.6.1`, `selene 0.31.0`, `StyLua 2.5.2` — unchanged.

Note: the Forest installer appends to the **user** PATH, so shells opened before the
install won't see it. `scripts/forest.sh` / `.ps1` resolve the binary directly.

## What shipped

**Layer A — Claude Code plugin** (`.claude-plugin/`, `skills/`, `commands/`, `agents/`,
`hooks/`). 7 skills, 7 commands, 2 agents, and a `PreToolUse` hook that blocks
`forest publish` / `login` / `init` (irreversible, TTY-only, or the user's to run) —
verified against 7 command shapes including wrapper invocations.

**Tooling** — `scripts/forge.py` (pure offline: `list`, `order`, `audit`, `new`,
`version`), `scripts/test.luau` (Lune runner).

**Layer B — 4 packages written, 113 specs passing:**

| Package | Realm | Modules |
|---|---|---|
| `forge-guard` | server | Validate, RateLimit, AbuseScore, Movement |
| `forge-net` | any | Router |
| `forge-lifecycle` | any | Registry |
| `forge-testkit` | dev | FakeClock, FakeSignal, FakeDataStore, FakePlayers, FakeRemote |
| `forge-combat` | server | History (rewind buffer), Claim (hit resolution) |

Gates green: **147 specs**, selene 0 warnings, stylua clean, `forge audit` fully clean.

`selene.toml` + `.styluaignore` now exclude `game/archive/` (superseded banks kept for
provenance; 2 errors + 28 warnings of noise). `game/src` is clean.

## Verified findings — do not re-derive these

1. **`forest init` needs a TTY.** Dies with `IO error: not a terminal` even with
   `-p/--platform`, which the help text calls "scriptable". An agent cannot use it. Use
   `python scripts/forge.py new <name>`. Only `forest init --project` and
   `forest install --init <platform>` are non-interactive-safe.
2. **`Packages/` lands next to the ROOT MODULE** when a manifest declares `root` — so
   `packages/<name>/src/Packages/`, not `packages/<name>/Packages/`. That is deliberate:
   dev-time and consumer-time require paths come out identical.
3. **The real CLI has `logout`, `whoami`, `audit`** — none documented. `forest audit -u`
   updates and reinstalls. Hidden aliases `i` / `grow` / `chop` / `upgrade` all resolve.
4. **Lockfile v2 shape:** `{file_version, packages: {"id": [{version, integrity, public,
   root, location, dependencies}]}}`. Array per id because Roblox installs incompatible
   versions side-by-side. `location: "~"` is the root `Packages/`. Every installed folder
   also gets a `.forest-receipt`, which `forge audit` cross-checks against the lockfile.
5. **Lune 0.10.5 requires `./`, `../` or `@` prefixes.** So a package's `init.luau` (Roblox
   `require(script.X)`) is unresolvable there. Hence the layering rule: **`init.luau` is a
   one-line aggregator, all logic in siblings, specs require siblings.**
6. **Lune requires are file paths**, so a spec can reach across the workspace —
   `require("../../forge-guard/src/RateLimit")`. That is a dev-time reference, not a Forest
   dependency, and `.forestignore` keeps `tests/` out of every archive. It lets specs prove
   real integration instead of mocking it.
7. **`core.ignorecase=true` on Windows** makes a bare `Packages/` gitignore rule also match
   the `packages/` SOURCE tree — it silently ignored the entire workspace. Caught live;
   ignores are now anchored paths (`/packages/*/src/Packages/` etc).
8. **Mirrors are rich.** Probed and confirmed: `nezuo/lapis`, `littensy/reflex`,
   `littensy/charm`, `jsdotlua/react`, `roblox/roact`, `sleitnick/{signal,trove,knit,net,
   component,option}`, `osyrisrblx/t`, `evaera/promise`, `stravant/goodsignal`. No
   `forest search` command — probe by attempting the install.
9. **`AbuseScore` decays before each report**, so N weight-1 reports never reach a score of
   N. Size thresholds against the arithmetic (this cost one wrong spec).

## M3 — `forge-combat` DONE, two to go

**`forge-combat` shipped** (`80f1877`): `History` (bounded ring buffer, interpolated lookup,
three distinct miss reasons) + `Claim` (cooldown → equipped → alive → team → timestamp →
origin → range → sight, cheapest-and-most-certain first). 34 specs.

Two things worth remembering from writing it:

- I put `require(script.Parent.History)` in `Claim.luau` — the exact mistake the workspace
  rule exists to prevent. One Roblox-syntax line would have made the module that decides
  whether damage lands untestable outside Studio. It now takes a structural `HistoryLike`
  through its `Context`. **Watch for this in every remaining tier-2 package.**
- **A claim slightly ahead of the newest sample is NOT a lie.** History samples at a fixed
  rate, so an honest attack routinely lands 20–40 ms between two ticks. My first version
  rejected those, which would have discarded a large share of legitimate hits. It now clamps
  to the newest record inside `futureToleranceSeconds`.
- The **origin check** is the one people forget: a client can name any attack origin, so
  without validating it against history every range test measures from an invented point.

The `expired` branch is an explicit `Policy` with a conservative shipped default (`reject`).
**Open decision for the user:** `game/src/ReplicatedStorage/CombatPolicy.luau` carries a
marked TODO — `reject` (safe, but a laggy player's real hits vanish) vs
`acceptWithTightRange` (kind, but an attacker can fake latency and aim at the window). The
default keeps the game shippable while it stays open; it just isn't a decision yet.

Remaining:

- **forge-round** — round/match state machine + matchmaking queue + intermission + results.
  Data-driven so `game/` supplies wave counts and durations.
- **forge-economy** — idempotent ledger. Server-generated transaction ids, recorded applied
  ids, replay is a no-op. **Never read-modify-write across a yield** — that interleaving is
  the classic dupe. Lapis handles persistence; transaction semantics are ours.

Then M4 (assemble the game on two manifests), M5 (content via the StudioAgent asset
pipeline), M6 (hardening + publish — needs the user's `forest login`).

## Untouched

`src/` (StudioAgent Luau plugin) and `sidecar/` (Python bridge) are exactly as they were.
The animation/grip work in flight (HANDOFF.md 2026-07-26c) was not touched.
