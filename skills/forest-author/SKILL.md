---
name: forest-author
description: Use when creating, structuring, versioning, or publishing a Forest (forest.dev) package — designing its single root-module public API, splitting server and client surfaces, writing forest.json by hand, choosing public vs private visibility, or running forest publish. Triggers on "create a forest package", "publish to forest", "make this a package", "forest init", "root module", ".forestignore", or questions about package layout and SemVer bumps.
---

# Authoring Forest packages

A Forest package is a folder with one manifest and **one root module whose return value
is the entire public API**. That constraint is the whole design: it means a consumer can
never depend on your internals, so you can restructure freely as long as the root table
keeps its shape.

Verified against **forest 1.8.0**.

## Scaffold — do not use `forest init`

`forest init` prompts for name and root and dies without a TTY (`Error: IO error: not a
terminal`), despite `--platform` being documented as making it "scriptable". *Verified.*

```sh
python scripts/forge.py new forge-thing --description "What it does"
```

That writes `forest.json`, `src/init.luau`, `src/Thing.luau`, `tests/Thing.spec.luau`,
`README.md`, `LICENSE`, `CHANGELOG.md`, `.forestignore` — then `forest install` validates
the manifest. See `skills/forest-workspace` for the conventions it follows.

## Designing the public API

```lua
-- src/init.luau — a thin aggregator, nothing else
return require(script.Signal)
```

or, for a package with more than one surface:

```lua
-- src/init.luau
return {
    Server = require(script.Server),
    Client = require(script.Client),
}
```

Three rules, in order of how much pain they save:

**1. No require-time side effects.** With the two-surface form, *both* halves load on
*both* realms — a consumer's client requires the root, which requires `Server.luau`. If
that file connects events or reads `DataStoreService` at require time, it breaks or leaks.
Do work in an explicit `:Init()` / `:Start()` the consumer calls.

**2. Relative requires only.** `script.Parent.Shared`, never
`game:GetService("ReplicatedStorage").Packages.x`. Absolute paths break when a consumer
mounts elsewhere, and break harder when your package is a *transitive* dependency living
in its parent's `Packages/` folder. `forge.py audit` fails on these.

**3. Keep logic out of `init.luau`.** Lune has no `script`, so `init.luau` is untestable
outside Studio. Keep it one line and all the logic in siblings that specs require
directly. See `skills/roblox-testing`.

### Server + client: pick a form deliberately

**Explicit surfaces** (recommended) — the consumer chooses:

```lua
return { Server = require(script.Server), Client = require(script.Client) }
```
```lua
local MyLibrary = require(Packages.mylibrary).Server
```

**Branch on context** — the root decides:

```lua
local RunService = game:GetService("RunService")
if RunService:IsServer() then
    return require(script.Server)
else
    return require(script.Client)
end
```
```lua
local MyLibrary = require(Packages.mylibrary)
```

Explicit wins for anything typed: with the branching form, type tooling can only see one
surface at a time, and shared code gets awkward. Branching wins when the two surfaces are
genuinely the same API with different implementations.

Shared internals (`Shared.luau`) stay **unexported** — both surfaces reach them via
`script.Parent.Shared`. Don't re-export them through the root; that makes them API you
have to keep.

## Layout

```
packages/forge-thing/
├── forest.json
├── README.md          # required to publish PUBLIC
├── LICENSE            # required to publish, always
├── CHANGELOG.md
├── .forestignore
├── src/
│   ├── init.luau      # thin aggregator
│   ├── Thing.luau     # the logic
│   └── Internal/
└── tests/
    └── Thing.spec.luau
```

The archive **re-roots at the root module's directory**, so consumers get
`Packages/forge-thing/{init.luau, Thing.luau, Internal/}` — `src/` disappears. That is
also why your own dependencies install to `src/Packages/`: dev-time and consumer-time
require paths come out identical.

## What ships

- **Excluded automatically:** `Packages/`, `forest-lock.json`, dotfiles, anything matched
  by `.gitignore` or `.forestignore`. Rojo files are ignored entirely.
- **Required:** `LICENSE` always. `README.md` for public packages.
- **Cap:** 10 MB. `forge.py audit` warns at 8.

Default `.forestignore` keeps tests out of the archive — consumers don't need them, and
they'd fail to load in a Roblox context anyway.

## Publishing

**This step is the user's, not yours.** `forest publish` takes no flags, is entirely
prompt-driven, and needs a TTY.

Preflight first (`/forest-publish` runs all of it):

```sh
python scripts/forge.py audit          # schema, lockfile, requires, README/LICENSE, size
lune run scripts/test.luau             # specs green
selene packages/ && stylua --check packages/
forest audit                           # dependency updates + license considerations
forest whoami                          # confirm the right identity
```

Then hand off:

```sh
forest login      # browser, or username + password with 2FA
forest publish
```

First publish prompts for **visibility, name, description, version, license**.
Re-publishing prompts bugfix/feature/breaking and bumps SemVer itself.

### Two decisions you cannot take back

**Visibility is permanent.** Set at first publish, inherited by every later version.
Changing it means republishing under a new name. Get an explicit answer before running
publish.

**Private does not hide code from players.** It is registry access control — who may
download. Once installed, the code ships in the game and anything that replicates can be
recovered. Server-only code stays private from players via the two-manifest pattern, not
a visibility flag.

### Versioning

`forest publish` manages `version` from the bump you pick. `forge.py version <name>
<patch|minor|major>` exists to *stage* a version and open a changelog entry before
publishing — useful for a coordinated multi-package release, unnecessary otherwise.

Release order matters: publish dependencies before dependents, so a dependent's range can
resolve. `python scripts/forge.py order` prints the workspace in dependency order.

Declare dependencies **before** publishing — `forest i @scope/dep` writes them to
`forest.json` with a caret range. **The CLI does not scan your source.** A dependency you
require but never installed will resolve fine on your machine and fail for every consumer.

## Reusing instead of writing

Forest mirrors the whole open-source Wally ecosystem (`forest i evaera/promise`, bare
`author/name`). Before authoring a utility package, search for a mirror. Reimplementing a
maintained library costs you the maintenance forever and gains a name. Write the package
when you have a real reason — a different API shape, a dependency you won't take, or
behaviour that doesn't exist yet — and write the reason down.
