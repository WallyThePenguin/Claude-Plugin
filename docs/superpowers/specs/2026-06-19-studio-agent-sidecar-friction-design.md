# Studio Agent — Sidecar friction reduction (design)

**Date:** 2026-06-19
**Status:** approved (brainstorm), pending implementation plan

## Problem

The vision sidecar (the `capture` / `capture_angles` tools' disk-reader) is the friction point in
the otherwise self-contained plugin. To use vision today a user must, per machine:

1. Install Python.
2. `py -m pip install -r requirements.txt` (pywin32 + Pillow).
3. Run `run.ps1` in a terminal and leave it open.
4. Copy the random token it prints and paste it into the panel's "Sidecar token" field + Save.

Steps 1–2 (Python + pip) and step 4 (token copy-paste) are the real friction. This work removes
them: **double-click an `.exe`, and capture works** — no Python, no pip, no token.

## Hard constraint that shapes the design

The plugin is Luau at PluginSecurity. It has **no filesystem access** — it can only reach the sidecar
over `HttpService`. So the plugin can never silently pick up a `.token` file off disk. "Auto-token"
therefore cannot mean "discover the random token"; it has to mean **change the auth model so there is
nothing to copy**. The only real trust boundary is the existing `127.0.0.1`-only bind. The thing the
token protected is "the newest Roblox viewport PNGs on your own machine."

## Decisions (from the brainstorm)

- **Drop auth entirely.** Rely solely on the `127.0.0.1`-only bind. The token field disappears from
  the panel and the token gate disappears from the sidecar.
- **Drop Pillow; the sidecar becomes pure Python-stdlib.** Pillow's only use was downscaling batches
  of **>20 images** (`maxPxForCount`). Dropping it yields a tiny, dependency-free `.exe`.
- **Cap `capture_angles` at 20 images per call.** Beyond 20 we could not downscale; 20 is a sane
  per-call limit anyway (bigger sweeps split across calls). This removes the downscale path entirely.
- **Bundle as a PyInstaller `--onefile` exe** and **commit the prebuilt exe** (small ~6–8 MB onefile;
  double-click-and-go; future-proof for the eventual "ship to others" goal), alongside a build script
  to regenerate it.

## Non-goals

- Tray icon, auto-start-on-login, or auto-launching the sidecar from the plugin (the plugin can't
  spawn processes). The exe stays a manually-launched console app, same lifecycle as today minus
  Python/terminal/token.
- Changing the disk-reader mechanism, the `/captures` endpoint shape (apart from removing `max_px`),
  the port (`8389`), or `sidecarUrl` remaining configurable.

## Design

### 1. Sidecar → pure stdlib

- `sidecar/capture.py`: delete `from PIL import Image`, `_downscale`, the `io` import, and the
  `max_px` parameter of `newest_captures`. Remaining imports are all stdlib (`glob`, `os`, `time`).
- `sidecar/server.py`: delete the `max_px` query parsing. No non-stdlib imports remain.
- `sidecar/requirements.txt`: deleted (no runtime dependencies). pywin32 was already dead (the
  PrintWindow grab was removed in the disk-reader rework); Pillow is now gone too.

### 2. Drop auth

- `sidecar/server.py`: remove `TOKEN`, `_authorized`, the `401` response path, and the
  "no token → `sys.exit(1)`" guard in `main()`. `/captures` serves unconditionally, protected only by
  the `127.0.0.1` bind. Unknown paths still `404`.
- `src/Tools/CaptureCore.luau` `fetchCaptures`: drop the token lookup, the `Authorization: Bearer`
  header, the `max_px` argument, and the `401` error branch. New signature
  `fetchCaptures(count, since, config)`; `config` now supplies only the URL. Keep the
  not-enabled / server-only / unreachable error branches (update the unreachable text — see §4).
- `src/Config.luau`: remove the `sidecarToken` default, its `set` validation branch, and
  `getSidecarToken()`. Keep `sidecarUrl` + `getSidecarUrl()`.
- `src/UI/Widget.luau`: remove the sidecar-token row (the `tokenBox` TextBox + `tokenSaveBtn` Save
  button, ~lines 73–91, and the `tokenSaveBtn.Activated` handler ~614–616). Reflow the header: the
  control row moves up from y64 to y32 and the `TOP` layout constant drops 96 → 64 (the header is now
  two 26px rows on a 32px stride: proxy-key at y0, control at y32).

### 3. Cap orbits at 20; remove the downscale path

- `src/Tools/CaptureCore.luau`: delete `maxPxForCount`.
- `src/Tools/Capture.luau` `runAngles`: clamp the computed `count` to a max of 20 (presets already
  cap at 7). Drop the `maxPxForCount(triggered)` argument to `fetchCaptures`.
- `src/CaptureSpec.luau`: remove the `maxPxForCount` test cases; keep the framing / preset / yaw /
  elevation tests.

### 4. Bundle as exe + docs

- New `sidecar/build-exe.ps1`:
  `pyinstaller --onefile --name StudioAgentSidecar server.py` → `sidecar/dist/StudioAgentSidecar.exe`.
  PyInstaller follows the `import capture` automatically. One-time `pip install pyinstaller` on the
  build machine. Fallback note in the script: use `--onedir` if antivirus flags the onefile build.
- Commit `sidecar/dist/StudioAgentSidecar.exe` (the only thing kept under `dist/`).
- `sidecar/run.ps1`: simplify to a dev-only "run from source" path —
  `$env:SIDECAR_PORT = "8389"; py "$PSScriptRoot\server.py"` (no token generation).
- `src/SystemPrompt.luau` + the `fetchCaptures` "unreachable" error text: drop any
  token / `run.ps1` wording; point at "start the vision sidecar (`StudioAgentSidecar.exe`)".
- `sidecar/README.md`: rewrite for the disk-reader + exe flow (the current README still documents the
  deleted PrintWindow `/screenshot?window=` path). Cover: what it does (reads Roblox's
  `tmp-capture-storage` PNGs and serves them on `127.0.0.1:8389`), how to run (double-click the exe;
  or `run.ps1` from source), how to build (`build-exe.ps1`), and the security model (localhost-only,
  read-only, no auth by design).
- `.gitignore`: remove `sidecar/.token`; add `sidecar/build/` and `sidecar/*.spec` (PyInstaller
  intermediates). Do **not** ignore `sidecar/dist/` (the committed exe lives there). Delete the
  now-unused `sidecar/.token` file from the tree.

## Behaviour after the change

- Capture path: plugin GETs `http://127.0.0.1:8389/captures?b64=1&count=N&since=T` with no auth
  header; the sidecar returns `{"images":[...],"returned":N,"shortfall":bool}` exactly as today.
- `capture` (single) and the default 6-angle `capture_angles` are unaffected functionally. Orbits
  requesting >20 angles are clamped to 20.
- A missing sidecar still produces the existing clear "is it running? start the sidecar exe" error
  (no token-related errors remain).

## Testing

- **Static:** `selene src` 0/0, `stylua --check src` clean, `rojo build` OK.
- **In-Studio self-test:** `CaptureSpec` passes after the `maxPxForCount` cases are removed.
- **Sidecar smoke (from source, no Studio needed):** start `py server.py`, `curl`
  `http://127.0.0.1:8389/captures?b64=1&count=1` with no token → `200` JSON (empty `images` /
  `shortfall:true` if no captures exist), and `/nope` → `404`. Confirms auth removal + stdlib-only.
- **Exe smoke:** `build-exe.ps1` produces `dist/StudioAgentSidecar.exe`; double-click → prints the
  listening line; the same `curl` returns `200`.
- **Live (user, in Studio):** a fresh chat with no token set in the panel → ask the agent to build a
  GUI and `capture` → it sees the screenshot; a `capture_angles` 6-shot orbit returns 6 framed images.

## Risks / mitigations

- **PyInstaller onefile AV false-positive:** documented `--onedir` fallback in `build-exe.ps1`.
- **Committed binary drift:** the exe must be rebuilt + re-committed whenever `server.py`/`capture.py`
  change (rare). The build script makes this one command; this is an accepted solo-dev tradeoff.
- **Localhost exposure:** another local process could now read the newest viewport PNGs. Accepted —
  the asset is low-value (your own Studio viewport) and the bind is loopback-only.
