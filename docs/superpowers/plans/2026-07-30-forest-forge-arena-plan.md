# 2026-07-30 — Forest revamp + Forge Arena production build: architecture & milestones

Status: **PROPOSED** (awaiting user sign-off on the four decisions in §7).

## 0. What was read before writing this

- This repo: `src/` (Studio plugin, 44 tool modules under `src/Tools/`, agent loop, hot-reload dev
  harness), `sidecar/` (Python bridge: capture, mesh/TRELLIS, Kimodo retarget, factory loop),
  `game/` (Forge Arena bank: `ForgeConfig` + `ForgeRoundLoop`, 64 lines — a P1 skeleton),
  `docs/superpowers/` (specs/plans/handoffs/rubrics), `rokit.toml` (rojo 7.6.1, selene, StyLua).
- Forest PM docs, every page: `/concepts/{intro,publishing,manifest,dependencies,private-packages}`,
  `/platforms/roblox/{intro,installing,anatomy,server-client,mirrored}`,
  `/forest-cli/{install,commands}`, `/studios/*`, `/faq`.

### Forest facts this plan is built on (verified from the docs, not memory)

| Fact | Detail |
|---|---|
| Manifest | **`forest.json`** (JSON, not TOML). Fields: `name`, `author`, `version`, `description`, `platform` (`"roblox"`\|`"uefn"`), `license` (SPDX), `root` (Roblox: path to entry module), `dependencies`. Unknown fields ignored. |
| Lockfile | `forest-lock.json` — resolved version **+ SHA-256** per package, direct and transitive. **Commit it.** |
| CLI | `forest init` (`-p/--platform`, `--project` for a consume-only bare manifest), `forest install\|i\|grow <pkg>` (`-v/--version`, `-a/--alias`; bare = install all), `forest remove\|chop`, `forest publish`, `forest login`, `forest update\|upgrade` (`--check`). |
| Install layout | One `Packages/` folder **next to `forest.json`** — or next to the `root` module if `root` is set (so `src/Packages/`). Transitive deps nest inside their parent's `Packages/`. |
| Realm split | Not a registry feature. Server-only packages use the **two-manifest pattern**: a second `forest.json` in `Server/`, mounted to `ServerScriptService.Packages`; run CLI from that folder. |
| Package shape | Exactly **one root module**; its return value is the entire public API. Root resolution: `root` field → top-level `init.luau` → one dir deep → prompt. Archive re-roots at the root module's directory. `README.md` required (public), `LICENSE` required, 10 MB cap, `Packages/` + `forest-lock.json` + dotfiles excluded, `.forestignore` honored, Rojo files ignored. |
| Server+client API | Root returns `{ Server = require(script.Server), Client = require(script.Client) }` (recommended) — both halves load on both sides, so **no require-time side effects**; init via `:Init()`/`:Start()`. |
| Versioning | `^` (default, incl. bare `"1.2.3"`), `~`, `=`, comma comparators, `1.2.*`. De-dup when compatible; on Roblox, incompatible ranges install side-by-side. |
| Mirrors | Wally's ecosystem is mirrored: `forest i evaera/promise`. Unmodified, auto-updated, licenses recognized. |
| Publishing | Needs a forest.dev account + `forest login`. First publish prompts visibility (**public/private is permanent**), name, description, version, license. Re-publish prompts bugfix/feature/breaking and bumps SemVer. |
| Private | Registry-level access control only — **does not hide code from players**. |

## 1. The core insight that shapes this plan

This repo's "plugin" is a **Roblox Studio plugin** (Luau, talks to Claude through the CLIProxyAPI
tunnel). The user's ask — "utilize the claude code plugin to use or create forest packages" — needs a
**Claude Code plugin**, which does not exist here yet (`.claude-plugin/` is absent; `.claude/` holds
only stale worktrees).

So the revamp is **additive, not a rewrite**: keep StudioAgent as the in-Studio execution surface
(it is the only thing that can build geometry, capture screenshots, and run playtests), and add a
Claude Code plugin layer that owns everything that lives on disk — Forest, the package workspace,
Rojo, tests, CI. Three layers, clean seam:

```
Layer A  .claude-plugin/          Claude Code plugin: skills, commands, agents, hooks, scripts
         └─ drives the terminal: forest, rojo, lune, selene, git, CI
Layer B  packages/                12 authored Forest packages = the game engine (publishable)
         └─ each: forest.json + src/init.luau + tests + README + LICENSE
Layer C  game/                    Forge Arena — consumes Layer B via `forest install`
         └─ StudioAgent (src/, sidecar/) supplies art, rigs, animation, capture, playtest
```

The payoff of Layer B being *real packages* rather than folders: the game's architecture becomes
independently versioned, unit-testable outside Studio, and shippable to other creators. That is what
makes "end game" mean something.

## 2. The game

**Forge Arena** — round-based combat arena. Continues the existing bank (`game/`, Place2
`71518658263588`, P1 loop already evidence-gated per the 2026-07-16 handoff) rather than starting
cold. Production scope:

- Matchmaking queue → lobby → round state machine → intermission → results, N players.
- Server-authoritative combat: weapon swings, hitbox resolution with a lag-compensation window,
  damage pipeline with modifiers, death/respawn.
- Progression: XP/levels, unlocks, weapon mastery. Persisted with session-locked profiles.
- Economy: soft currency, shop, inventory, cosmetics — idempotent ledger, anti-dupe.
- Leaderboards: in-round scoreboard + persistent OrderedDataStore top-N.
- UI: HUD, queue panel, shop, results screen, theme tokens.
- Anti-exploit: remote validation, rate limits, movement sanity, telemetry.

## 3. Layer A — the Claude Code plugin

```
.claude-plugin/plugin.json         marketplace manifest
.claude-plugin/marketplace.json    so this repo is installable as a marketplace
skills/
  forest-use/SKILL.md              search, install, alias, require paths, Rojo mounting,
                                   two-manifest realm split, lockfile discipline, mirrors
    references/manifest.md         full forest.json field table (verbatim from docs)
    references/cli.md              every command + flag
    references/troubleshooting.md  failure modes and their fixes
  forest-author/SKILL.md           init → anatomy → root module → README/LICENSE → publish;
                                   server+client recipe; .forestignore; the 10 MB cap;
                                   the permanent-visibility trap; version-bump semantics
  forest-workspace/SKILL.md        this repo's monorepo conventions: packages/<name>/,
                                   local dev linking, release ordering by dependency graph
  roblox-architecture/SKILL.md     service lifecycle, realm boundaries, state replication,
                                   what belongs in a package vs the game
  roblox-server-authority/SKILL.md the anti-exploit rulebook: never trust the client, validate
                                   shape+range+rate, server-side hit resolution, telemetry
  roblox-persistence/SKILL.md      session locking, migrations, retry/backoff, budget limits
  roblox-testing/SKILL.md          Lune-based unit tests, fakes, what is and isn't testable
                                   outside Studio
commands/
  forest-add.md          install a dependency, remount, regenerate sourcemap, commit lock
  forest-new-package.md  scaffold a workspace package end to end
  forest-publish.md      preflight (lint, test, README, LICENSE, version) then hand off to login
  forest-audit.md        manifest/lockfile/require-path integrity across the workspace
  forest-sync.md         install everything from every manifest, verify the tree
  game-build.md          rojo build/serve the game, sourcemap, selene+stylua
  game-test.md           run the whole Lune suite, report per-package
agents/
  forest-package-author.md    authors one package to the workspace standard
  roblox-security-reviewer.md audits a diff for exploit surface
hooks/hooks.json            post-install sourcemap regen; pre-commit selene+stylua+tests
scripts/
  forest.ps1 / forest.sh      wrapper: resolves the CLI, fails loudly if absent
  forest_audit.py             offline manifest/lock/require-graph checker (no network)
  workspace.py                dependency-ordered build/test/release plan for packages/
```

Design rules for Layer A: every command is a thin, idempotent, re-runnable wrapper; nothing touches
the network except `install`/`publish`; `forest_audit.py` is pure-offline so CI can run it; no
command ever runs `forest publish` without an explicit user go-ahead (login is theirs).

## 4. Layer B — the 12 packages

Tier 0 has no game knowledge; tier 2 is the arena. Dependency-ordered:

| # | Package | Tier | Responsibility |
|---|---|---|---|
| 1 | `forge-signal` | 0 | Signal, Promise-lite, Trove/cleanup. The leaf dependency. |
| 2 | `forge-testkit` | 0 | Lune test runner + fakes: DataStore, Players, RunService, clock. |
| 3 | `forge-lifecycle` | 0 | Service registry with dependency-ordered `Init`/`Start`, per-realm. |
| 4 | `forge-sched` | 0 | Fixed-step server tick, RunService bindings, debounce/throttle, timers. |
| 5 | `forge-net` | 1 | Typed remotes: schema-validated payloads, per-player rate limits, request/response, server→client fan-out. Server+client surfaces. |
| 6 | `forge-state` | 1 | Server-owned replicated store → read-only client mirror, delta replication. |
| 7 | `forge-store` | 1 | Profiles: session lock, schema migrations, retry/backoff, budget awareness, mock provider. **Server-realm.** |
| 8 | `forge-guard` | 1 | Anti-exploit: input validation, movement sanity, remote abuse scoring, telemetry sink. **Server-realm.** |
| 9 | `forge-ui` | 1 | UI runtime + HUD primitives, theme tokens, responsive scaling. **Client-realm.** |
| 10 | `forge-combat` | 2 | Server-authoritative hit resolution: cast shapes, lag-comp window, damage pipeline with modifiers, i-frames. |
| 11 | `forge-round` | 2 | Round/match state machine, matchmaking queue, intermission, results. Data-driven. |
| 12 | `forge-economy` | 2 | Currency, inventory, shop transactions, idempotent ledger, anti-dupe. |

Every package ships: `forest.json`, `src/init.luau` (single public API), `src/*` internals,
`tests/*.spec.luau` running under Lune, `README.md` with a usage example, `LICENSE` (MIT),
`CHANGELOG.md`. Realm-scoped packages document their mount point; nothing has require-time side
effects.

Where possible we **consume mirrors instead of reinventing** — the audit in M2 checks each tier-0
package against the mirrored Wally ecosystem before we write it, and we drop ours if a mirror is
strictly better. Not-invented-here is a cost, not a virtue.

## 5. Layer C — game assembly

```
game/
  forest.json                 shared/client deps      → ReplicatedStorage.Packages
  Server/forest.json          server-realm deps       → ServerScriptService.Packages
  default.project.json        Rojo tree for the place
  src/ReplicatedStorage/      shared config, types, net schemas
  src/ServerScriptService/    bootstrap + arena services (thin: composition over logic)
  src/StarterPlayer/          client bootstrap + HUD wiring
  tests/                      integration specs
```

The game code stays deliberately thin — it wires packages together and holds tuning data. If a piece
of logic is reusable, it belongs in Layer B.

## 6. Milestones

| M | Deliverable | Gate |
|---|---|---|
| **M0** | Toolchain: Forest CLI installed (needs user OK to run the installer), `rokit add lune`, workspace dirs, `.forestignore`, CI skeleton | `forest --version` prints; `rojo build` still green |
| **M1** | Layer A complete and usable | Every command runs; `forest_audit.py` passes on an empty workspace |
| **M2** | Tier 0 + tier 1 packages with tests | `/game-test` green; mirror-vs-ours audit written down |
| **M3** | Tier 2 packages with tests | `/game-test` green; `/forest-audit` clean |
| **M4** | Game assembled on packages; Rojo builds; place syncs | Unmanned playtest: queue → round → combat → results, zero errors |
| **M5** | Content & polish: weapons via the StudioAgent asset pipeline, progression, cosmetics, leaderboards, UI pass | Playtest evidence per the existing rubric discipline |
| **M6** | Hardening: security review, perf pass, CI on push, publish to Forest | `roblox-security-reviewer` clean; **user runs `forest login` + approves publish** |

## 7. Decisions the user owns

1. **Genre** — proceeding with round-based combat arena (Forge Arena, continuing the existing bank).
   Say the word and it changes; everything in Layer A/B is genre-agnostic, only Layer C moves.
2. **Forest scope/username** — `author` in every manifest. Only needed at publish time, so packages
   get built with it blank and filled in at M6. What scope? Personal username or a Studio/org?
3. **Installing the Forest CLI** — the official installer is
   `irm https://releases.forest.dev/install.ps1 | iex` (installs to `%LOCALAPPDATA%\forest-cli\bin`,
   verifies its own SHA-256). Downloading and executing an installer needs an explicit yes.
   Until then M1–M3 proceed with hand-authored manifests that match the documented schema exactly.
4. **Package visibility** — public or private, **permanent per package, chosen at first publish**.
   Recommendation: tier 0/1 public (they're generic infrastructure, and public packages are what
   make this a showcase), tier 2 your call.

## 8. Non-goals

- Not rewriting StudioAgent's Luau tools or the Python sidecar. They keep working as-is.
- Not publishing anything without the user's login and explicit approval.
- Not touching the animation/grip work in flight (see HANDOFF.md 2026-07-26c).
