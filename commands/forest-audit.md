---
description: Audit the whole workspace — offline integrity plus registry updates and licenses
---

# Workspace audit

Two audits, and they check different things. Run both.

```sh
python scripts/forge.py audit     # offline: structure and discipline
forest audit                      # registry: available updates, license considerations
```

## What the offline audit covers

`forge.py audit` never touches the network, so it's safe in CI and cheap to run constantly:

- Manifest schema — `platform`, `name` charset, SemVer `version`, `license`, `root` exists
  and is a Luau file with forward slashes.
- Publish readiness — `LICENSE` present (error), `README.md` present (warning: only public
  packages need it), 10 MB archive cap.
- Dependency entries — valid identifiers, valid ranges, aliases not starting with `_`/`.`.
- Lockfile — every declared dependency is pinned with an integrity hash.
- **Installed-tree agreement** — every `.forest-receipt` on disk matches a lockfile entry.
  This is what catches a hand-edited or half-installed `Packages/` folder. Fix:
  `forest install -f`.
- **Require discipline** — an absolute require inside a package is an error. It works in the
  project you developed in and breaks for consumers, especially as a transitive dependency.
- Workspace dependency cycles (warning — legal in Forest, but a design smell).

Exit code 1 on any error, so hooks and CI can gate on it.

`author` unset is a *warning* by design: it's a publish-time requirement, not a development
one.

## Then

Also run the suite and the linters, since "clean" should mean all of it:

```sh
lune run scripts/test.luau
selene packages/ game/
stylua --check packages/ game/
```

## Reporting

Report errors and warnings separately, and for each error give the fix, not just the
finding. If everything is clean, say so in one line — don't pad it.

If the audit surfaces something out of scope for the current task, flag it rather than
fixing it inline.
