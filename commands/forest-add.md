---
description: Install a Forest package into the right manifest, then verify the tree
argument-hint: <package-id> [--server] [--alias name] [--version x.y.z]
---

# Add a Forest dependency

Install `$ARGUMENTS` and leave the workspace in a verified state.

Load the `forest-use` skill first if you haven't already this session.

## Steps

1. **Decide which manifest** — this is the step that goes wrong. Each `forest.json` owns an
   independent `Packages/` tree, and the CLI acts on the directory you run it from.
   - Server-only (anti-cheat, datastore, server framework, anything a player must not read)
     → `game/Server/`
   - Shared or client → `game/`
   - A dependency of a workspace package → `packages/<name>/`

   If the realm is ambiguous, ask. Getting it wrong either leaks server code to every
   client or leaves the client unable to see a library.

2. **Check for a mirror.** Forest mirrors the open-source Wally ecosystem as bare
   `author/name` (no `@`). If the user asked for something we were about to write
   ourselves, say so.

3. **Install** from that directory, using the wrapper so PATH doesn't matter:

   ```sh
   ../../scripts/forest.sh i <package-id> [-v <version>] [-a <alias>]
   ```

   Alias it if the folder name would collide with an existing package.

4. **Verify** — all three, and report failures rather than pressing on:

   ```sh
   python scripts/forge.py audit
   forest audit
   rojo sourcemap default.project.json -o sourcemap.json
   ```

5. **Report**: what was installed, at what resolved version, into which manifest and
   realm, plus the require path the user will actually type:

   ```lua
   local Thing = require(ReplicatedStorage.Packages.thing)
   ```

## Rules

- Commit `forest.json` and `forest-lock.json` together — a manifest change without its
  lockfile is how teammates end up on different versions.
- Never edit `forest-lock.json` by hand. `forest install -f` regenerates it.
- Don't commit `Packages/` — `.gitignore` already excludes it at any depth.
