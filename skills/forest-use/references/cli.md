# Forest CLI reference

Captured from `forest --help` on **forest 1.8.0** (Windows, x86_64-pc-windows-msvc).
This is the real output, not the docs — the two differ in ways that matter, noted below.

## Commands

```
login    Log in to your Forest account
logout   Log out and clear your stored credentials
whoami   Show the currently logged-in user
publish  Publish a package
init     Start development on a new package
install  Install dependencies for the package
remove   Remove a package from the project
update   Update forest to the latest release
audit    Check dependencies for available updates and license considerations
help     Print this message or the help of the given subcommand(s)
```

**The docs omit `logout`, `whoami`, and `audit`.** All three exist and work.

## Hidden aliases

Not listed in `--help`, but they resolve:

| Alias | Real command |
|---|---|
| `forest i` | `install` |
| `forest grow` | `install` |
| `forest chop` | `remove` |
| `forest upgrade` | `update` |

## `forest init`

```
Usage: forest init [OPTIONS]

  -p, --platform <PLATFORM>  Platform for the package (roblox or uefn). Skips the
                             interactive picker when provided, making `init` scriptable
      --project              Create a bare project manifest (dependencies + platform)
                             for consuming packages, instead of the package-authoring
                             scaffold. Non-interactive-safe
```

**Critical, verified:** `-p/--platform` skips only the *platform picker*. The
package-authoring scaffold still prompts for **name** and **root module**, so it dies
without a TTY:

```
$ forest init -p roblox </dev/null
Error: IO error: not a terminal
```

Despite the help text calling `-p` "scriptable", **`forest init` is not usable from an
agent or from CI.** Use `python scripts/forge.py new <name>` instead — it writes the same
manifest deterministically, and `forest install` validates it.

`--project` *is* non-interactive-safe. Verified output:

```
$ forest init --project -p roblox </dev/null
🌳 Initialized a new project in <cwd>
ℹ️  You can now run `forest install` to install dependencies!

$ cat forest.json
{
  "dependencies": {},
  "platform": "roblox"
}
```

## `forest install`

```
Usage: forest install [OPTIONS] [PACKAGE]

  [PACKAGE]                Package name (optional)
  -v, --version <VERSION>  Specify a version to install
  -a, --alias <ALIAS>      Specify an alias for the package
  -f, --force              Reinstall everything from scratch, ignoring installed state
      --init <PLATFORM>    When no forest.json exists, create one for this platform
                           and continue. The non-interactive twin of answering "Yes"
                           to the create prompt. Ignored if a manifest already exists
```

`--force` is the fix for a half-installed or hand-edited `Packages/` tree.

`--init` is the one-shot bootstrap: creates a bare project manifest **and** installs.

Verified install output:

```
$ forest i evaera/promise
🌳 Package evaera/promise added!
```

An install with no lockfile warns first:

```
⚠️  No lockfile found. Commit forest-lock.json to avoid inconsistencies.
🌳 Installed all dependencies!
```

## `forest audit`

```
Usage: forest audit [OPTIONS] [PACKAGE]

  [PACKAGE]     Only audit this package (e.g. scope/name)
  -u, --update  Update forest.json to the latest versions and reinstall
```

Verified clean output:

```
🌳 All dependencies are up to date!
🌳 No license considerations found in the dependency tree.
```

This is the *registry* audit — updates and licences. It is **not** the same as
`python scripts/forge.py audit`, which is the offline structural audit (manifest schema,
lockfile/receipt agreement, require-path discipline, publish readiness). Run both.

## `forest remove` / `publish` / `login` / `update`

```
forest remove <PACKAGE>      # no options
forest publish               # no options; fully interactive
forest login                 # no options; browser or username+password with 2FA
forest update [--check]      # --check only reports availability
```

`forest publish` takes **no flags at all** — it is entirely prompt-driven, so it needs a
TTY and cannot be automated. That is a feature: first publish sets visibility
permanently.

Not logged in looks like this:

```
$ forest whoami
ℹ️  You are not logged in. Run `forest login` to sign in.
```

## Installing the CLI

```powershell
# Windows
irm https://releases.forest.dev/install.ps1 | iex
```

```sh
# macOS / Linux
curl -fsSL https://releases.forest.dev/install.sh | sh
```

Installs per-user, no admin, and verifies its own SHA-256 against the published release
manifest. Default locations:

- Windows: `%LOCALAPPDATA%\forest-cli\bin`
- macOS/Linux: `~/.local/bin`

Pin or uninstall:

```powershell
.\install.ps1 -Version v0.1.0
.\install.ps1 -Uninstall
```

```sh
curl -fsSL https://releases.forest.dev/install.sh | FOREST_VERSION=v0.1.0 sh
curl -fsSL https://releases.forest.dev/install.sh | FOREST_INSTALL_DIR=~/bin sh
sh install.sh --uninstall
```

Env vars: `FOREST_INSTALL_DIR`, `FOREST_INSTALL_BASE`.

**The PATH gotcha:** the installer appends to the *user* PATH, which only reaches shells
started afterwards. Already-running shells won't find `forest`. Use
`scripts/forest.sh` / `scripts/forest.ps1`, which resolve the binary directly.
