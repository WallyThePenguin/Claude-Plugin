# Vision sidecar (M10) — screenshots so Claude can *see*

A plugin can't read viewport pixels, so this tiny OS-side helper does. It captures the Roblox
Studio window (Windows `PrintWindow(PW_RENDERFULLCONTENT)` — works even when occluded / unfocused,
including the hardware-accelerated viewport) and serves it over **localhost only**, token-authed.
The plugin's `capture` tool fetches a frame and forwards it to Claude as a base64 image block.

```
plugin  --GET /screenshot?b64=1-->  127.0.0.1:8389 (this sidecar)  --PrintWindow-->  Studio window
```

## Setup

```powershell
cd C:\Users\manso\Desktop\Claude-Plugin\sidecar
py -m pip install -r requirements.txt   # one time: pywin32 + Pillow
.\run.ps1                               # prints the token, then serves on 127.0.0.1:8389
```

`run.ps1` generates a token once (saved to `sidecar/.token`, gitignored) and prints it — paste it
into the plugin's **Sidecar token** setting (added with the `capture` tool). Leave the window open
while using vision.

## Verify it captures Studio (standalone)

With Studio open and the sidecar running, from another PowerShell:

```powershell
$t = (Get-Content .\.token -Raw).Trim()
curl.exe -s "http://127.0.0.1:8389/screenshot?window=Roblox%20Studio&token=$t" -o studio.png
start studio.png   # should be a screenshot of the Studio window
```

401 = wrong/missing token. 500 with `"no visible window matching..."` = Studio isn't open or the
title differs (pass `&window=<substring>`). A black frame = focus Studio once and retry.

## Security

- Binds `127.0.0.1` only; every request requires the token (`?token=` or `Authorization: Bearer`).
- This grants screenshot access to whatever holds the token — keep `.token` local (gitignored).
- The sidecar only ever *reads* pixels; it executes nothing it is sent.
