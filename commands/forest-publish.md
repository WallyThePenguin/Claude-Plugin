---
description: Run the full publish preflight for a package, then hand off to the user's login
argument-hint: <package-name>
---

# Publish preflight

Get `$ARGUMENTS` ready to publish, verify everything that can be verified, then **stop and
hand off**. `forest publish` is the user's to run.

Load the `forest-author` skill first.

## Why you stop

`forest publish` takes no flags, prompts for everything, and needs a TTY. More importantly:

- It requires the user's Forest account (`forest login`).
- **First publish sets visibility permanently.** Public or private is inherited by every
  future version and can only be changed by republishing under a new name.

Never run it. Prepare, then ask.

## Preflight

Run all of it. Report every failure; do not proceed past one.

```sh
python scripts/forge.py audit              # schema, lockfile/receipt agreement, requires,
                                           # README/LICENSE presence, 10 MB cap
lune run scripts/test.luau <name>          # specs green
selene packages/<name>
stylua --check packages/<name>
forest audit                               # dependency updates + license considerations
forest whoami                              # is the right identity logged in?
```

Then check by hand what tooling can't:

- [ ] `README.md` has a real usage example that matches the current API. Required for
      public packages.
- [ ] `LICENSE` present, and `license` in the manifest matches it.
- [ ] `CHANGELOG.md` has an entry for this version.
- [ ] `author` is set to the scope being published under.
- [ ] Root module exports only what's intended — **the root table is the permanent
      contract**; anything on it, you maintain.
- [ ] No require-time side effects (both surfaces load on both realms).
- [ ] No absolute requires anywhere in the package.
- [ ] `.forestignore` excludes tests and anything consumers don't need.
- [ ] Dependencies are **declared in `forest.json`**, not merely required in source —
      the CLI does not scan code, so an undeclared dependency works for you and fails for
      every consumer.

## Release order

If publishing more than one package, dependencies go first or a dependent's range can't
resolve:

```sh
python scripts/forge.py order
```

## Hand off

Report the preflight results, then give the user exactly this, and the two things they'll
be asked:

```sh
forest login
cd packages/<name>
forest publish
```

- **Visibility** — permanent. Recommendation for this workspace: tier 0/1 public (generic
  infrastructure), tier 2 the user's call.
- **Bump** — bugfix / feature / breaking. Publish handles the SemVer arithmetic.

Afterwards, offer to verify with `forest audit` and to bump the game's manifests to the
newly published version.
