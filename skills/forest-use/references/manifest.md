# `forest.json` and `forest-lock.json` reference

## `forest.json` fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `name` | string | to publish | Lowercase letters, digits and hyphens only. With `author` it forms `@author/name`. |
| `author` | string | to publish | The scope you publish under: your username, or a Studio you admin/own. |
| `version` | string | to publish | SemVer `MAJOR.MINOR.PATCH`; prerelease/build suffixes allowed (`1.2.0-rc.1`). The publish flow manages it. |
| `description` | string | no | Shown in registry search and on the package page. |
| `platform` | string | **yes** | `"roblox"` or `"uefn"`. Both install and publish require it; it decides layout and import style. |
| `license` | string | to publish | An SPDX id (`MIT`, `Apache-2.0`) or `"SEE LICENSE IN <file>"`. |
| `root` | string | Roblox | Relative path to the entry module (`src/init.luau`), **always forward slashes**. |
| `dependencies` | object | no | Defaults to `{}`. Maps full package identifiers to version specs. |

Unknown fields are ignored by the registry.

### Full example

```json
{
  "name": "datastream",
  "author": "stratiz",
  "description": "Typed networking for Roblox",
  "version": "1.4.2",
  "platform": "roblox",
  "license": "MIT",
  "root": "src/init.luau",
  "dependencies": {
    "@forest/signal": "^2.0.1",
    "@user1/promise": {
      "version": "^3.1.0",
      "alias": "promise3"
    }
  }
}
```

### A bare project manifest

What `forest init --project` writes. No `name`, so it is a *consumer*, not a publishable
package. This is the right shape for `game/forest.json`.

```json
{
  "dependencies": {},
  "platform": "roblox"
}
```

### Dependency entry forms

A string is a version range:

```json
"@forest/signal": "^2.0.1"
```

An object adds an alias (Roblox only; written by `forest i -a`):

```json
"@user1/promise": { "version": "^3.1.0", "alias": "promise3" }
```

The alias controls the installed folder name, and therefore the name you require it by.
**Aliases may not start with `_` or `.`**

Keys are full package identifiers:

- Native Forest packages: `@scope/name`
- Mirrored Wally packages: `author/name` — **no `@`**

## Where `Packages/` lands

*Verified against forest 1.8.0.* One `Packages/` folder per manifest:

| Manifest | Install location |
|---|---|
| No `root` declared | `Packages/` beside `forest.json` |
| `"root": "src/init.luau"` | `src/Packages/` — beside the root module |

The second case is the important one for **package authors**, and it is deliberate: your
dev-time require path is identical to the consumer's. Because the published archive
re-roots at the root module's directory, `src/Packages/promise` at dev time becomes
`Packages/promise` beside your `init.luau` after install. `script.Parent.Packages.promise`
resolves in both.

Transitive dependencies nest inside their parent's `Packages/`, not the root one. If your
own code needs a transitive dependency, install it directly.

## `forest-lock.json`

**Commit it.** With a lockfile, `forest install` reproduces an identical tree everywhere.
Without one, ranges are re-resolved and may pick newer versions.

Real lockfile after `forest i evaera/promise`:

```json
{
  "file_version": 2,
  "packages": {
    "evaera/promise": [
      {
        "version": "4.0.0",
        "integrity": "b7ee0f4d28ba123bcb8beb29404521ce39d61533e5490212be31adefdbadcd9e",
        "public": true,
        "root": "lib/init.lua",
        "location": "~",
        "dependencies": {}
      }
    ]
  }
}
```

Notes on the shape:

- `packages` maps identifier → **array** of entries. An array because Roblox installs
  incompatible versions side-by-side; each entry is one resolved version.
- `integrity` is the SHA-256 of the package tarball.
- `location` is `~` for the root `Packages/` folder; nested deps carry their parent path.
- `root` records the publisher's entry module, which is what the installer re-roots on.
- Private packages never leak a URL into the lockfile — only the integrity hash.

## `.forest-receipt`

Every installed package folder gets one. It is how you tell what is actually on disk:

```json
{
  "name": "evaera/promise",
  "version": "4.0.0",
  "integrity": "b7ee0f4d28ba123bcb8beb29404521ce39d61533e5490212be31adefdbadcd9e",
  "root": "lib/init.lua"
}
```

`scripts/forge.py audit` cross-checks every receipt against the lockfile — that is how a
hand-edited or half-installed tree gets caught. The fix is always `forest install -f`.

## What ends up in a published archive

- Re-rooted at the directory containing the root module.
- **Excluded:** `Packages/`, `forest-lock.json`, dotfiles (`.git`, `.DS_Store`), and
  anything matched by `.gitignore` or `.forestignore`.
- **Required:** `LICENSE` always; `README.md` for public packages (optional for private).
- Rojo project files are ignored — `root` defines the package, not Rojo.
- Hard cap: **10 MB**.

Dev layout:

```
my-package/
├── forest.json
├── README.md
├── LICENSE
└── src/
    ├── init.luau
    ├── Helper.luau
    └── Internal/
```

What a consumer gets:

```
Packages/my-package/
├── init.luau
├── Helper.luau
├── Internal/
└── LICENSE
```

The root file needn't be named `init` — any module can be `root`, and it is renamed to
`init.luau` on install.

## Root module resolution order

1. The `root` field in `forest.json`
2. `init.luau` / `init.lua` at the top level
3. `init.luau` / `init.lua` one directory deep
4. The CLI prompts

**Always declare `root` explicitly.** Relying on the fallbacks makes the package's shape
depend on directory scanning order.
