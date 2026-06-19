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
