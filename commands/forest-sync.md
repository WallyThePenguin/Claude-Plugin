---
description: Install every manifest's dependencies and verify the resulting trees
---

# Sync all Forest trees

Bring every `Packages/` tree in the workspace up to date with its lockfile. Run this after
a fresh clone, a branch switch, or a pull that touched any manifest.

## Steps

1. **Find every manifest** — each owns an independent tree, so each needs its own install:

   ```sh
   python scripts/forge.py list
   ```

2. **Install from each manifest's own directory.** Typically:

   ```sh
   cd game        && ../scripts/forest.sh i && cd ..
   cd game/Server && ../../scripts/forest.sh i && cd ../..
   # and each packages/<name>/ that declares dependencies
   ```

   Add `-f` if a tree is suspect — `forest install -f` reinstalls from scratch, ignoring
   installed state. That's the fix whenever the audit reports a receipt/lockfile mismatch.

3. **Verify:**

   ```sh
   python scripts/forge.py audit
   rojo sourcemap default.project.json -o sourcemap.json
   ```

4. **Report** each tree, its package count, and any drift found.

## Notes

- A missing lockfile prints `⚠️ No lockfile found` and resolves ranges fresh. If that
  happens on a manifest that should have one, the lockfile wasn't committed — say so.
- `Packages/` is gitignored at any depth; `forest.json` and `forest-lock.json` are not.
  Never commit an installed tree.
- Nothing here needs a login. Private packages do — if an install fails on one, check
  `forest whoami` and whether the user has access through their Studio.
