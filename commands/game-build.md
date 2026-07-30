---
description: Build and sync the Forge Arena place, with a full pre-build verification pass
---

# Build the game

Verify, then build. A build that succeeds on unverified source just moves the failure later.

## Verify first

```sh
python scripts/forge.py audit
lune run scripts/test.luau
selene packages/ game/
stylua --check packages/ game/
```

Stop and report on any failure.

## Build

```sh
cd game
rojo build default.project.json -o ForgeArena.rbxl
rojo sourcemap default.project.json -o ../sourcemap.json
```

For live iteration against an open Studio session:

```sh
cd game && rojo serve default.project.json
```

## Two mounts, two manifests

The game's Rojo tree mounts **two** `Packages` folders, and the split is what keeps
server-only code off clients:

- `game/Packages` → `ReplicatedStorage.Packages` (shared and client)
- `game/Server/Packages` → `ServerScriptService.Packages` (server realm only)

If a build is missing a package, the usual cause is that it was installed against the wrong
manifest. `python scripts/forge.py list` shows every manifest; reinstall from the right
directory.

## Then verify it actually runs

A green build is not a working game. The existing StudioAgent harness runs an unmanned
playtest and returns logs:

```powershell
.\scripts\studio-agent.ps1 reload    # step zero after ANY Studio restart
.\scripts\studio-agent.ps1 play
```

`reload` first is not optional — a fresh Studio boot runs a stale plugin generation even
when the sidecar is up. The tell is an "unknown tool/command kind" error.

Report the playtest outcome, not just the build outcome: did the round loop progress, and
were there errors in the log?
