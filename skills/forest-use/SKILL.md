---
name: forest-use
description: Use when installing, removing, updating, aliasing, or requiring Forest (forest.dev) packages in a Roblox/Luau project, mounting Packages/ through Rojo, keeping server-only packages off clients, or debugging a forest install / forest-lock.json / require-path problem. Triggers on "forest install", "forest i", "add a package", "forest.json", "forest-lock.json", "Packages folder", "wally package", or a package identifier like @scope/name.
---

# Using Forest packages

Forest is a **command-line** package manager for Roblox and UEFN. It is not a Studio
plugin and never touches your place file: it writes package folders to disk, and a
separate sync tool (Rojo) puts them into the datamodel.

Verified against **forest 1.8.0**. Anything below marked *verified* was executed, not
read off a docs page.

## The five things that matter

1. **`forest.json` is JSON**, not TOML. `forest-lock.json` sits beside it and pins the
   exact version **and SHA-256** of every package, direct and transitive. **Commit both.**
2. **`Packages/` lands next to the manifest** — *unless* the manifest declares `root`, in
   which case it lands next to the root module (`src/Packages/`). *Verified.*
3. **Realm separation is a mounting decision, not a registry feature.** Server-only
   packages need the two-manifest pattern (below), or they replicate to every client.
4. **Inside a package, every require must be relative.** Absolute paths break when a
   consumer mounts elsewhere, and break harder when the package is installed as a
   transitive dependency (it lives in its *parent's* `Packages/`, not the root one).
5. **`forest init` needs a TTY** and cannot be scripted. `forest init --project` and
   `forest install --init <platform>` can. *Verified — see references/cli.md.*

## Installing

```sh
forest install @scope/name          # or: forest i / forest grow
forest i @scope/name -v 1.2.0       # a specific version
forest i @scope/name -a myalias     # install under a different folder name
forest i                            # install everything in forest.json
forest i -f                         # blow away installed state and redo it
forest remove @scope/name           # or: forest chop
forest audit                        # available updates + license considerations
forest audit -u                     # ...and take them
```

**Mirrored Wally packages use a bare `author/name`, with no `@`:**

```sh
forest i evaera/promise      # lands as Packages/promise
```

Forest mirrors the whole open-source Wally ecosystem. **Check for a mirror before
writing anything yourself** — reimplementing a maintained library is a cost, not a
virtue. Mirrors track upstream automatically and carry the original license.

After any install: run `python scripts/forge.py audit` and regenerate the sourcemap
(`rojo sourcemap default.project.json -o sourcemap.json`) so type tooling sees the
new tree.

## Requiring

The folder name is the package name **without its scope** — `@forest/pasta` becomes
`pasta` — or the `-a` alias if you gave one.

```lua
local Packages = game:GetService("ReplicatedStorage").Packages
local Pasta = require(Packages.pasta)
```

Each package has **exactly one root module**, and its return value is the entire public
API. There is no reaching into internals; if something you need isn't on that table,
the package doesn't expose it.

## Mounting through Rojo

```json
{
  "name": "my-game",
  "tree": {
    "$className": "DataModel",
    "ReplicatedStorage": { "Packages": { "$path": "Packages" } }
  }
}
```

### The two-manifest pattern — for anything server-only

Anti-cheat, datastore wrappers, server frameworks: if it reaches `ReplicatedStorage`,
players can read it. Give the server realm its own manifest and its own tree:

```json
{
  "name": "my-game",
  "tree": {
    "$className": "DataModel",
    "ServerScriptService": { "Packages": { "$path": "Server/Packages" } },
    "ReplicatedStorage":   { "Packages": { "$path": "Shared/Packages" } }
  }
}
```

Each manifest keeps **independent** state — its own `forest.json`, its own lockfile, its
own `Packages/`. **Run the CLI from the folder whose manifest you mean to change.** This
is the single most common way to get a package into the wrong realm.

## Version ranges

| Syntax | Meaning |
|---|---|
| `^1.2.3` | `>= 1.2.3, < 2.0.0` — the default |
| `~1.2.3` | `>= 1.2.3, < 1.3.0` |
| `=1.2.3` | exactly 1.2.3 |
| `1.2.*` | any patch in 1.2 |
| `>=1.2, <1.5` | comma-separated comparators, all must hold |

A bare `"1.2.3"` means `^1.2.3`, **not** an exact pin. Forest de-duplicates when ranges
are compatible; on Roblox, incompatible ranges install **side-by-side** (the lockfile
holds an array per package id, one entry per resolved version).

## When something breaks

Read `references/troubleshooting.md`. The short version:

- *Package installed into the wrong realm* → you ran the CLI from the wrong folder.
- *`Packages/` isn't where you expected* → the manifest declares `root`; look next to it.
- *Require works in Studio, breaks as a dependency* → an absolute require inside a
  package. `python scripts/forge.py audit` catches these.
- *Teammate gets different versions* → the lockfile wasn't committed.
- *`not a terminal`* → you tried to script `forest init`. Use `forge.py new` instead.

## Reference material

- `references/cli.md` — every command and flag, with the real `--help` output.
- `references/manifest.md` — the full `forest.json` and `forest-lock.json` schema.
- `references/troubleshooting.md` — failure modes and their causes.
