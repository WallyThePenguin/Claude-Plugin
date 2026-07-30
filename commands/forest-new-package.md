---
description: Scaffold a new Forest package in the workspace, to this repo's standard
argument-hint: <forge-name> [one-line description]
---

# New workspace package

Create a publishable Forest package for `$ARGUMENTS`.

Load the `forest-author` and `forest-workspace` skills first.

## Steps

1. **Justify it.** Before scaffolding, check whether a Wally mirror already does the job
   (`forest i evaera/promise`-style, bare `author/name`). If one does, say so and take it
   instead — reimplementing a maintained library is a permanent maintenance bill. If we
   keep ours anyway, the reason goes in the README.

2. **Pick the tier**, and don't cross it:
   - tier 0 — depends on nothing
   - tier 1 — depends only on tier 0
   - tier 2 — game systems; may depend on tier 0 and 1

3. **Scaffold.** Do **not** use `forest init` — it needs a TTY and fails with
   `IO error: not a terminal`.

   ```sh
   python scripts/forge.py new <name> --description "..." --holder WallyThePenguin
   ```

4. **Design the public API before writing internals.** Write `README.md`'s usage example
   first — it's the API review. If the example is awkward, the API is wrong, and it's much
   cheaper to notice now than after publish (the root table's shape is the contract).

5. **Implement** under the layering rule:
   - `src/init.luau` stays a thin aggregator (`return require(script.Thing)`).
   - Logic in siblings, pure Luau, no `game`/`script`/services. Need a service? Take it as
     an injected argument so a spec can pass a fake.
   - Relative requires only.
   - No require-time side effects — initialise via `:Init()`/`:Start()`.

6. **Write specs** requiring sibling modules (never `../src/init` — Lune has no `script`).
   Cover boundaries: `NaN`, `math.huge`, non-integers, wrong types, missing arguments.

7. **Verify:**

   ```sh
   python scripts/forge.py audit
   lune run scripts/test.luau <name>
   selene packages/<name> && stylua --check packages/<name>
   ```

8. **Report** the public API surface, the tier, its dependencies, and what the specs cover.

## Rules

- Leave `author` blank. It's a publish-time field; `audit` warns and that's correct.
- Don't publish. That's `/forest-publish`, and it needs the user's login.
- `CHANGELOG.md` gets an entry as you go, not retroactively.
