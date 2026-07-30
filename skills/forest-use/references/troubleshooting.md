# Forest troubleshooting

Ordered roughly by how often each one bites.

## `Error: IO error: not a terminal`

You tried to run an interactive command without a TTY. `forest init` (the
package-authoring scaffold) and `forest publish` both prompt and both need one.

**Fix:** use `python scripts/forge.py new <name>` to scaffold a package, and
`forest init --project` for a consumer manifest. Publishing genuinely requires a human —
hand it to the user.

## A package landed in the wrong realm

Symptom: an anti-cheat or datastore package shows up in `ReplicatedStorage.Packages`, or
a shared library isn't visible to the client.

**Cause:** you ran the CLI from the wrong directory. Each manifest owns its own
`Packages/` tree and knows nothing about its siblings.

**Fix:** `forest remove` it from the manifest you ran against, then `cd` to the correct
folder and install there. Confirm with `python scripts/forge.py list`, which prints every
manifest and its role.

## `Packages/` isn't where I expected

If the manifest declares `root`, the tree lands **next to the root module** —
`src/Packages/`, not `./Packages/`. *Verified behaviour, not a bug.* See
`references/manifest.md` for why it's designed that way.

## Require works in Studio, breaks when the package is a dependency

Symptom: your package works in the project you developed it in, then a consumer reports
`attempt to index nil`.

**Cause:** an absolute require inside the package —
`require(game:GetService("ReplicatedStorage").Packages.x)`. That resolves only when the
package sits at that exact path. As a *transitive* dependency it lives inside its
parent's `Packages/` folder, so the path is wrong.

**Fix:** relative requires only (`script.Parent.Something`). `python scripts/forge.py
audit` fails the build on absolute requires inside `packages/`.

## Teammates get different versions

`forest-lock.json` wasn't committed. Without it, ranges re-resolve per machine.

**Fix:** commit it. Note that `.gitignore` in this repo ignores `Packages/` at any depth
but explicitly un-ignores `forest.json` and `forest-lock.json`.

## Installed tree disagrees with the lockfile

Symptom: `forge.py audit` reports "installed X@Y is not in the lockfile".

**Cause:** a hand-edited `Packages/` folder, an interrupted install, or a lockfile
updated on another branch.

**Fix:** `forest install -f` — reinstall everything from scratch, ignoring installed state.

## Two packages with the same name

Different scopes, same name, both needed. They collide on folder name.

**Fix:** alias one of them.

```sh
forest i @user2/pasta -a pasta2
```

Then `require(Packages.pasta2)`. Aliases may not start with `_` or `.`.

## A dependency has two incompatible versions

On Roblox this is not an error — both install side-by-side, each consumer getting the one
it asked for. Cost is disk and duplicated state. (On UEFN it *is* a hard error.)

Check for it with `forest audit`, and look for a package identifier with more than one
entry in the lockfile array.

## Circular dependency

Allowed at both publish and install time; the resolver handles cycles. But the docs are
blunt that "cycles should be design smells rather than tool features" — two packages that
need each other are usually one package.

`forge.py audit` reports workspace cycles as warnings.

## `forest` not found in an already-open terminal

The installer appends `%LOCALAPPDATA%\forest-cli\bin` to the **user** PATH, which only
reaches shells started afterwards.

**Fix:** open a new terminal, or use `scripts/forest.sh` / `scripts/forest.ps1`, which
resolve the binary directly.

## Private package won't install for a teammate

Private is registry-level access control. They need to be logged in (`forest login`) and
have access — either they own it, or they're in the Studio that owns it with the right
role.

Check identity first: `forest whoami`.

## "Is my private package hidden from players?"

**No.** Private controls who can *download from the registry*. Once installed, the code
ships inside your game and a determined player can recover anything that replicates. To
keep code away from players, keep it out of replicated containers — that is the
two-manifest pattern, not a visibility setting.

## Type tooling doesn't see a newly installed package

Regenerate the sourcemap:

```sh
rojo sourcemap default.project.json -o sourcemap.json
```

## The 10 MB publish cap

Archives are capped at 10 MB. `forge.py audit` warns at 8 MB and errors past 10.

Usual culprit is committed assets. Add them to `.forestignore` if consumers don't need
them; otherwise the package is trying to be an asset bundle and should be split.
