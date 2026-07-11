# Vision sidecar — screenshots so Claude can *see*

A Roblox plugin can't read viewport pixels, but `CaptureService:CaptureScreenshot` writes a full-res
viewport PNG to disk (`%LOCALAPPDATA%\Roblox\tmp-capture-storage\wob-*`). This tiny helper reads the
newest of those files and serves them over **localhost only**, so the plugin's `capture` /
`capture_angles` tools can fetch a frame and forward it to Claude as a base64 image block.

```
plugin  --GET /captures?b64=1&count=N-->  127.0.0.1:8389 (this sidecar)  --reads-->  tmp-capture-storage
```

## Run it

**Normal use — no Python needed:** double-click `dist/StudioAgentSidecar.exe`. It prints
`listening on http://127.0.0.1:8389` and serves while the window is open. Close the window to stop.

**From source (dev):** `.\run.ps1` (needs Python 3; the sidecar is pure standard library — no `pip`).

There is **no token** — capture works as soon as the sidecar is running. (Earlier versions required
pasting a token into the panel; that field is gone.)

> The exe is capture-only in practice: it does **not** load the env file described under
> [Ops](#ops--reproducible-restarts), so the SDK loop / factory / Open Cloud features need `run.ps1`
> (or vars set by hand before launching the exe).

## Ops — reproducible restarts

The sidecar's behavior depends on environment variables that used to exist only in whichever shell
happened to start it — which made restarts irreproducible and kept getting them deferred. Fix:
`run.ps1` now loads **`%USERPROFILE%\.studio-agent\sidecar.env`** into the process env before
launching Python, and creates that file with a commented template on first run.

**Env file format:** `KEY=VALUE` lines; full-line `#` comments and blank lines ignored; `%VAR%`
patterns expanded at load time; optional surrounding quotes stripped; blank values skipped.
**Precedence:** a variable already set in the launching shell WINS over the file (one-off overrides
stay easy). `run.ps1` echoes only the **names** of variables loaded/kept/skipped — never values.

### Variables

| Variable | Consumer | Meaning |
| --- | --- | --- |
| `CLAUDE_CODE_OAUTH_TOKEN` | `sdk_loop.py` | Token for the sidecar-side SDK agent loop (`/loop`, `/factory`, `/forever`). Unset = those routes refuse; capture/bridge still work. |
| `STUDIO_AGENT_AUDIT_EVERY` | `factory.py` | Audit every Nth factory rung. Code default 5; ops runs at 2 (the template says 2). |
| `STUDIO_AGENT_OPENCLOUD_KEY_FILE` | Open Cloud module (pending) | **Path** to the single-line Open Cloud API key file (default `%USERPROFILE%\.studio-agent\opencloud.key`). The variable holds only a path — the key value never goes in env files, code, logs, or git. |
| `STUDIO_AGENT_MESH_UPLOAD` | `factory.py` | Mesh upload policy: `manual` (default; `save_mesh` runs draft-only) or `auto` (real uploads). |
| `STUDIO_AGENT_MECHANIC_MCP` | `sdk_loop.py` | Optional extra MCP config JSON for the mechanic stage. |
| `SIDECAR_PORT` | `server.py` | Bind port on 127.0.0.1 (default 8389; `run.ps1` sets it if nothing else did). |

### Restart procedure

1. Let any in-flight `/loop` / `/factory` / `/forever` run finish (check
   `scripts\studio-agent.ps1 status` / `factory-status` / `forever-status`), or stop it gracefully.
2. Dry-run the env first — **does not start a second sidecar**:
   `powershell -NoProfile -File sidecar\run.ps1 -EnvOnly`
   Expect `sidecar.env: loaded [...]` lines listing variable names, then
   `-EnvOnly: env loaded; NOT starting the sidecar.`
3. Close the old sidecar window (or stop its `py`/exe process).
4. From `sidecar\`: `.\run.ps1` — same env every time, regardless of which shell you're in.

### Pending at next restart

Routes/modules already merged (or landing) that the **live** sidecar predates — they go live at the
next natural restart. Keep this list current:

- `/play/twins`
- `/opencloud/asset-status` (fetch-free moderation readiness gate for mesh uploads)
- sparse `ensure_docs` (creator-docs clone)
- mesh ledger

### Security notes

- `sidecar.env` and `opencloud.key` live under `%USERPROFILE%\.studio-agent\` — **outside the repo**,
  so they can never be committed. Do not copy them into the tree.
- The Open Cloud key is referenced **only by file path** (`STUDIO_AGENT_OPENCLOUD_KEY_FILE`). Never
  paste the key value into the env file, code, tests, logs, or shell history.
- `run.ps1` prints variable **names only**; nothing it echoes can leak a secret.

## Build the exe

```powershell
py -m pip install pyinstaller   # one time
.\build-exe.ps1                 # -> dist\StudioAgentSidecar.exe (commit it)
```

Rebuild and re-commit the exe whenever `server.py` / `capture.py` change. If antivirus flags the
onefile build, edit `build-exe.ps1` to use `--onedir`.

## Verify it reads captures (standalone)

With Studio open, take a screenshot in it (so a `wob-*` file exists), then from another shell:

```powershell
curl.exe -s "http://127.0.0.1:8389/captures?b64=1&count=1"
```

`{"images":[],"returned":0,"shortfall":true}` means no recent capture file was found; a non-empty
`images` array is a base64 PNG. `404` means a path other than `/captures`.

## Security

- Binds `127.0.0.1` only — the sole trust boundary. The served asset is just your own Studio
  viewport PNGs, kept off the network by loopback.
- The sidecar only ever *reads* capture files; it executes nothing it is sent.
