# Sidecar Friction Reduction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the vision sidecar zero-config — no Python install, no `pip`, no token copy-paste — so capture works by double-clicking a bundled `.exe`.

**Architecture:** Strip the sidecar down to pure Python stdlib (drop Pillow, drop the token auth), cap `capture_angles` at 20 images (which removes the only reason Pillow existed), update the plugin to stop sending a token / `max_px`, remove the panel's token row, then bundle the sidecar as a PyInstaller `--onefile` exe committed to the repo.

**Tech Stack:** Python 3 stdlib (`http.server`, `glob`, `base64`, `json`), PyInstaller (build-time only), Luau (Roblox plugin), Rojo / selene / stylua.

**Spec:** `docs/superpowers/specs/2026-06-19-studio-agent-sidecar-friction-design.md`

---

## File Structure

**Sidecar (Python) — `sidecar/`:**
- `capture.py` — disk reader. Becomes pure stdlib (drop Pillow / `_downscale` / `max_px`).
- `server.py` — HTTP server. Drop auth + `max_px` parsing; pure stdlib.
- `test_capture.py` — dependency-free reader tests (rewritten to not use Pillow).
- `requirements.txt` — **deleted** (no runtime deps).
- `run.ps1` — simplified dev-only "run from source" (no token generation).
- `build-exe.ps1` — **new**; PyInstaller onefile build script.
- `dist/StudioAgentSidecar.exe` — **new, committed**; the bundled exe.
- `README.md` — rewritten for the disk-reader + exe flow.
- `.token` — **deleted** (unused).

**Plugin (Luau) — `src/`:**
- `Tools/CaptureCore.luau` — `fetchCaptures` loses the token + `max_px`; `maxPxForCount` deleted.
- `Tools/Capture.luau` — `runSingle`/`runAngles` drop the `max_px` arg; orbit count capped at 20.
- `CaptureSpec.luau` — drop the `maxPxForCount` test case.
- `Config.luau` — drop `sidecarToken` default / validation / getter.
- `UI/Widget.luau` — remove the sidecar-token row + handler; reflow the header.
- `Tools/init.luau` — fix a one-line comment (drop "+ token").

**Repo root:**
- `.gitignore` — drop `sidecar/.token`; add `sidecar/build/` and `sidecar/*.spec`.

---

## Task 1: Sidecar → pure stdlib, no auth (Python)

Do this FIRST: the running sidecar must stop *requiring* a token before the plugin stops *sending* one, so there's never a 401 window during live testing.

**Files:**
- Modify: `sidecar/capture.py` (full rewrite — short file)
- Modify: `sidecar/server.py` (full rewrite — short file)
- Modify: `sidecar/test_capture.py` (full rewrite — short file)
- Modify: `sidecar/run.ps1`
- Delete: `sidecar/requirements.txt`, `sidecar/.token`

- [ ] **Step 1: Rewrite `sidecar/capture.py` (drop Pillow / `_downscale` / `max_px`)**

Replace the entire file with:

```python
"""Disk reader for the Studio Agent vision sidecar.

Roblox writes CaptureService:CaptureScreenshot output as full-resolution viewport PNGs to
%LOCALAPPDATA%\\Roblox\\tmp-capture-storage\\wob-<StudioPID><counter>. A plugin can't read that file
(the path API is RobloxScript-gated), but this local helper can. We return the newest N COMPLETE PNGs
whose mtime is >= a caller-supplied timestamp, as PNG bytes. Pure standard library (no third-party deps).
"""

from __future__ import annotations

import glob
import os
import time

PNG_SIG = b"\x89PNG\r\n\x1a\n"
PNG_IEND = b"IEND\xaeB`\x82"  # final 8 bytes of every complete PNG


def capture_dir() -> str:
    base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
    return os.path.join(base, "Roblox", "tmp-capture-storage")


def _mtime(path: str) -> float:
    try:
        return os.path.getmtime(path)
    except OSError:
        return float("-inf")


def _complete_png_bytes(path: str):
    """Return the file's bytes iff it is a complete PNG (sig + trailing IEND), else None."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return None
    if data[:8] == PNG_SIG and data.rstrip().endswith(PNG_IEND):
        return data
    return None


def newest_captures(count, since_ts=0.0, timeout_s=8.0, poll_s=0.15):
    """Up to `count` newest COMPLETE capture PNGs with mtime >= since_ts, returned oldest-first
    (= capture order). Polls up to timeout_s for `count` files to appear (captures may still be
    flushing). Returns fewer than `count` on timeout (a shortfall)."""
    deadline = time.monotonic() + timeout_s
    directory = capture_dir()
    while True:
        files = [f for f in glob.glob(os.path.join(directory, "wob-*")) if _mtime(f) >= since_ts]
        files.sort(key=_mtime)  # oldest-first
        complete = []
        for f in files:
            b = _complete_png_bytes(f)
            if b is not None:
                complete.append(b)
        if len(complete) >= count or time.monotonic() >= deadline:
            return complete[-count:] if count > 0 else []
        time.sleep(poll_s)
```

- [ ] **Step 2: Rewrite `sidecar/server.py` (drop auth + `max_px`)**

Replace the entire file with:

```python
"""Studio Agent vision sidecar — localhost-only capture-file server.

GET /captures?count=N&since=<epoch>[&b64=1]
  - reads the N newest complete viewport PNGs Roblox wrote to tmp-capture-storage (mtime >= since).
  - returns JSON {"images":[<base64 png>,...],"returned":N,"shortfall":bool}.

Bind is 127.0.0.1 ONLY — the only trust boundary. No auth: the served asset is just your own Studio
viewport PNGs, and loopback keeps them off the network. Pure standard library (no third-party deps).
"""

import base64
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import capture

PORT = int(os.environ.get("SIDECAR_PORT", "8389"))


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, content_type: str, body: bytes):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)

        if parsed.path != "/captures":
            self._send(404, "application/json", b'{"error":"not found"}')
            return

        try:
            count = int(qs.get("count", ["1"])[0])
            since = float(qs.get("since", ["0"])[0])
        except ValueError:
            self._send(400, "application/json", b'{"error":"bad count/since"}')
            return

        try:
            pngs = capture.newest_captures(count, since_ts=since)
        except Exception as exc:  # noqa: BLE001 - surface any read failure as JSON
            self._send(500, "application/json", json.dumps({"error": str(exc)}).encode())
            return

        images = [base64.b64encode(p).decode("ascii") for p in pngs]
        body = json.dumps(
            {"images": images, "returned": len(images), "shortfall": len(images) < count}
        ).encode()
        self._send(200, "application/json", body)

    def log_message(self, *args):  # silence default stderr access logging
        pass


def main():
    print(f"Studio Agent vision sidecar listening on http://127.0.0.1:{PORT}")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Rewrite `sidecar/test_capture.py` (dependency-free)**

Replace the entire file with:

```python
"""Dependency-free tests for the disk-reader. Run: python sidecar/test_capture.py"""
import os
import sys
import tempfile

import capture


def _complete(marker: int) -> bytes:
    # The reader only checks the 8-byte signature and a trailing IEND, so we don't need a real
    # encoder. A marker byte in the middle makes files distinguishable to assert capture order.
    return capture.PNG_SIG + bytes([marker]) + capture.PNG_IEND


def _write(path, body, mtime):
    with open(path, "wb") as f:
        f.write(body)
    os.utime(path, (mtime, mtime))


def _check(name, cond):
    print(("  PASS  " if cond else "  FAIL  ") + name)
    return 0 if cond else 1


def main():
    fails = 0
    with tempfile.TemporaryDirectory() as d:
        os.environ["LOCALAPPDATA"] = d
        cdir = capture.capture_dir()
        os.makedirs(cdir, exist_ok=True)

        _write(os.path.join(cdir, "wob-1"), _complete(1), 1000)
        _write(os.path.join(cdir, "wob-2"), _complete(2), 2000)
        _write(os.path.join(cdir, "wob-3"), _complete(3), 3000)
        _write(os.path.join(cdir, "wob-4"), _complete(4), 4000)

        got = capture.newest_captures(2, since_ts=0.0, timeout_s=0.2)
        fails += _check("returns the newest 2, oldest-first", got == [_complete(3), _complete(4)])

        got = capture.newest_captures(10, since_ts=3000, timeout_s=0.2)
        fails += _check("since_ts filters to wob-3 + wob-4", len(got) == 2)

        # incomplete PNG (sig but no IEND) is skipped
        _write(os.path.join(cdir, "wob-5"), capture.PNG_SIG + b"\x00" * 32, 5000)
        got = capture.newest_captures(1, since_ts=5000, timeout_s=0.2)
        fails += _check("incomplete PNG is skipped (timeout -> empty)", len(got) == 0)

    print(f"=== {('ALL PASS' if fails == 0 else str(fails) + ' FAILED')} ===")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run the reader tests**

Run: `python sidecar/test_capture.py`
Expected: three `PASS` lines and `=== ALL PASS ===` (exit 0). No `ModuleNotFoundError: PIL` — the test and `capture.py` are now pure stdlib.

- [ ] **Step 5: Simplify `sidecar/run.ps1`**

Replace the entire file with:

```powershell
# Run the Studio Agent vision sidecar from source (dev convenience). For normal use, double-click the
# bundled StudioAgentSidecar.exe instead (no Python needed). Leave this window open while capturing.
$ErrorActionPreference = "Stop"
$env:SIDECAR_PORT = "8389"
py "$PSScriptRoot\server.py"
```

- [ ] **Step 6: Delete the obsolete files**

Run: `git rm sidecar/requirements.txt sidecar/.token`
Expected: both removed from the index. (If `.token` was never committed, `git rm` errors — then just `rm sidecar/.token` / delete it from disk and continue.)

- [ ] **Step 7: Smoke-test the server with no token**

Start the server in the background, then probe it:

Run:
```bash
python sidecar/server.py &
sleep 1
curl -s -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:8389/captures?b64=1&count=1"
curl -s -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:8389/nope"
kill %1
```
Expected: first curl prints `200` (no token needed; JSON body is `{"images":[],"returned":0,"shortfall":true}` when no captures exist), second prints `404`.

- [ ] **Step 8: Commit**

```bash
git add sidecar/capture.py sidecar/server.py sidecar/test_capture.py sidecar/run.ps1
git commit -m "feat(sidecar): pure-stdlib disk reader, drop token auth + Pillow"
```

---

## Task 2: Plugin — remove token auth + downscale, cap orbits at 20 (Luau)

All edits here form ONE buildable commit: `Config.getSidecarToken` is consumed by both `Widget` and `CaptureCore`, so the getter and both call sites must change together or the build breaks mid-way. Verification is static (selene/stylua/rojo) plus the in-Studio `CaptureSpec` the user runs live.

**Files:**
- Modify: `src/Tools/CaptureCore.luau`
- Modify: `src/Tools/Capture.luau`
- Modify: `src/CaptureSpec.luau`
- Modify: `src/Config.luau`
- Modify: `src/UI/Widget.luau`
- Modify: `src/Tools/init.luau`

- [ ] **Step 1: `CaptureCore.luau` — delete `maxPxForCount`**

Delete this whole block (the comment + function, currently lines ~62–73):

```luau
-- Downscale ceiling so a batch stays under Anthropic's per-request limits: >20 images must each be
-- <=2000px (the "many-image" rule), and the 32MB request payload caps total bytes. nil = native res.
function CaptureCore.maxPxForCount(count: number): number?
	if count <= 20 then
		return nil
	elseif count <= 50 then
		return 2000
	elseif count <= 100 then
		return 1280
	end
	return 768
end
```

- [ ] **Step 2: `CaptureCore.luau` — rewrite `fetchCaptures` (no token, no `max_px`)**

Replace the existing `fetchCaptures` function (its doc comment through its final `end`) with:

```luau
-- Ask the sidecar for `count` newest capture PNGs created at/after `since` (epoch seconds). Returns
-- (blocks, nil) on success — a list of base64 image blocks — or (nil, errString) on any failure.
function CaptureCore.fetchCaptures(
	count: number,
	since: number,
	config: any
): ({ any }?, string?)
	if config == nil then
		return nil, "capture: internal error (no config available)"
	end
	local url = config:getSidecarUrl()
		.. "/captures?b64=1&count="
		.. tostring(count)
		.. "&since="
		.. tostring(math.floor(since))

	local ok, res = pcall(function()
		return HttpService:RequestAsync({
			Url = url,
			Method = "GET",
		})
	end)
	if not ok then
		local msg = string.lower(tostring(res))
		if string.find(msg, "not enabled", 1, true) then
			return nil,
				"capture: HTTP requests are disabled. Enable 'Allow HTTP Requests' in Game "
					.. "Settings > Security."
		end
		if string.find(msg, "game server", 1, true) then
			return nil,
				"capture: HttpService is server-only — capture from edit mode or the Studio Server view."
		end
		return nil,
			"capture: could not reach the vision sidecar at "
				.. config:getSidecarUrl()
				.. " — is it running? Start StudioAgentSidecar.exe (sidecar/dist). ("
				.. tostring(res)
				.. ")"
	end

	local response = res :: any
	if not response.Success then
		return nil,
			"capture: the sidecar returned HTTP "
				.. tostring(response.StatusCode)
				.. ": "
				.. tostring(response.Body)
	end

	local okDecode, payload = pcall(function()
		return HttpService:JSONDecode(response.Body)
	end)
	if not okDecode or type(payload) ~= "table" or type((payload :: any).images) ~= "table" then
		return nil, "capture: the sidecar returned an unexpected response."
	end
	local blocks: { any } = {}
	for _, b64 in (payload :: any).images do
		local data = (string.gsub(tostring(b64), "%s", ""))
		if data ~= "" then
			table.insert(blocks, {
				type = "image",
				source = { type = "base64", media_type = "image/png", data = data },
			})
		end
	end
	if #blocks == 0 then
		return nil, "capture: the sidecar returned no images (try focusing Studio once and retry)."
	end
	return blocks, nil
end
```

- [ ] **Step 3: `Capture.luau` — `runSingle` drops the `nil` arg**

Change (in `runSingle`):

```luau
	local blocks, err = CaptureCore.fetchCaptures(1, since, nil, getConfig(context))
```
to:
```luau
	local blocks, err = CaptureCore.fetchCaptures(1, since, getConfig(context))
```

- [ ] **Step 4: `Capture.luau` — `runAngles` caps count at 20 and drops `max_px`**

Change the count computation:

```luau
			local count = if type(args.count) == "number" and args.count >= 1
				then math.floor(args.count)
				else 6
```
to:
```luau
			local count = if type(args.count) == "number" and args.count >= 1
				then math.floor(args.count)
				else 6
			count = math.min(count, 20) -- batch cap: keeps requests within Anthropic's image limits
```

Then change the fetch call:

```luau
		local blocks, err = CaptureCore.fetchCaptures(
			triggered,
			since,
			CaptureCore.maxPxForCount(triggered),
			getConfig(context)
		)
```
to:
```luau
		local blocks, err = CaptureCore.fetchCaptures(triggered, since, getConfig(context))
```

- [ ] **Step 5: `CaptureSpec.luau` — remove the `maxPxForCount` case**

Delete this `add(...)` block (currently lines ~69–75):

```luau
	add("maxPxForCount: native res <=20, then 2000/1280/768", function()
		return CaptureCore.maxPxForCount(20) == nil
			and CaptureCore.maxPxForCount(21) == 2000
			and CaptureCore.maxPxForCount(50) == 2000
			and CaptureCore.maxPxForCount(80) == 1280
			and CaptureCore.maxPxForCount(200) == 768
	end)
```

- [ ] **Step 6: `Config.luau` — drop the `sidecarToken` default**

Change:

```luau
	-- Vision sidecar (the `capture` tool): localhost screenshot server + its auth token.
	sidecarUrl = "http://127.0.0.1:8389",
	sidecarToken = "",
```
to:
```luau
	-- Vision sidecar (the `capture` tool): localhost screenshot server (no auth — 127.0.0.1-only).
	sidecarUrl = "http://127.0.0.1:8389",
```

- [ ] **Step 7: `Config.luau` — drop the `sidecarToken` validation branch**

Delete:

```luau
	elseif key == "sidecarToken" then
		if type(value) ~= "string" then
			return false, "sidecarToken must be a string"
		end
```

(The `sidecarUrl` branch immediately above it stays; make sure the following `elseif key == "model"` still chains correctly.)

- [ ] **Step 8: `Config.luau` — drop the getter**

Delete:

```luau
function Config.getSidecarToken(self: Config): string
	return self:get("sidecarToken") :: string
end
```

(Keep `Config.getSidecarUrl`.)

- [ ] **Step 9: `Widget.luau` — remove the sidecar-token row**

Delete the entire "Sidecar token row" block (currently lines ~73–91):

```luau
	-- Sidecar token row (vision/capture) — mirrors the proxy-key row.
	local tokenBox = Instance.new("TextBox")
	tokenBox.Size = UDim2.new(1, -58, 0, 26)
	tokenBox.Position = UDim2.fromOffset(0, 32)
	tokenBox.BackgroundColor3 = Color3.fromRGB(40, 40, 44)
	tokenBox.BorderSizePixel = 0
	tokenBox.TextColor3 = TEXT
	tokenBox.PlaceholderText = "sidecar token (vision)"
	tokenBox.PlaceholderColor3 = MUTED
	tokenBox.Text = deps.config:getSidecarToken()
	tokenBox.ClearTextOnFocus = false
	tokenBox.TextSize = 13
	tokenBox.Font = Enum.Font.Code
	tokenBox.TextXAlignment = Enum.TextXAlignment.Left
	tokenBox.Parent = root
	local tokenSaveBtn = button("Save")
	tokenSaveBtn.Size = UDim2.fromOffset(54, 26)
	tokenSaveBtn.Position = UDim2.new(1, -54, 0, 32)
	tokenSaveBtn.Parent = root
```

- [ ] **Step 10: `Widget.luau` — move the control row up to y32**

In the "Control row" block, change every `64` y-offset to `32`:

```luau
	local newBtn = button("New chat")
	newBtn.Size = UDim2.fromOffset(64, 26)
	newBtn.Position = UDim2.fromOffset(0, 64)
	newBtn.Parent = root
	local histBtn = button("History")
	histBtn.Size = UDim2.fromOffset(56, 26)
	histBtn.Position = UDim2.fromOffset(68, 64)
	histBtn.Parent = root
	local memBtn = button("Memory")
	memBtn.Size = UDim2.fromOffset(56, 26)
	memBtn.Position = UDim2.fromOffset(128, 64)
	memBtn.Parent = root
	local skillsBtn = button("Skills")
	skillsBtn.Size = UDim2.fromOffset(52, 26)
	skillsBtn.Position = UDim2.fromOffset(188, 64)
	skillsBtn.Parent = root
	local status = Instance.new("TextLabel")
	status.BackgroundTransparency = 1
	status.Size = UDim2.new(1, -244, 0, 26)
	status.Position = UDim2.fromOffset(244, 64)
```
becomes (only the five `Position` y-values change 64 → 32):
```luau
	local newBtn = button("New chat")
	newBtn.Size = UDim2.fromOffset(64, 26)
	newBtn.Position = UDim2.fromOffset(0, 32)
	newBtn.Parent = root
	local histBtn = button("History")
	histBtn.Size = UDim2.fromOffset(56, 26)
	histBtn.Position = UDim2.fromOffset(68, 32)
	histBtn.Parent = root
	local memBtn = button("Memory")
	memBtn.Size = UDim2.fromOffset(56, 26)
	memBtn.Position = UDim2.fromOffset(128, 32)
	memBtn.Parent = root
	local skillsBtn = button("Skills")
	skillsBtn.Size = UDim2.fromOffset(52, 26)
	skillsBtn.Position = UDim2.fromOffset(188, 32)
	skillsBtn.Parent = root
	local status = Instance.new("TextLabel")
	status.BackgroundTransparency = 1
	status.Size = UDim2.new(1, -244, 0, 26)
	status.Position = UDim2.fromOffset(244, 32)
```

- [ ] **Step 11: `Widget.luau` — shrink the `TOP` constant**

Change:

```luau
	local TOP = 96 -- three 26px header rows on a 32px stride: proxy-key (y0), sidecar-token (y32), control (y64).
```
to:
```luau
	local TOP = 64 -- two 26px header rows on a 32px stride: proxy-key (y0), control (y32).
```

- [ ] **Step 12: `Widget.luau` — remove the token Save handler**

Delete (currently lines ~614–617):

```luau
	tokenSaveBtn.Activated:Connect(function()
		local ok, reason = deps.config:set("sidecarToken", tokenBox.Text)
		status.Text = if ok then "sidecar token saved" else "rejected: " .. tostring(reason)
	end)

```

(The `saveBtn.Activated` block just above it for the proxy key stays.)

- [ ] **Step 13: `Tools/init.luau` — fix the comment**

Change:

```luau
-- tools ignore it; `capture` reads context.config for the sidecar URL + token.
```
to:
```luau
-- tools ignore it; `capture` reads context.config for the sidecar URL.
```

- [ ] **Step 14: Format, lint, build**

Run:
```bash
stylua src
selene src
rojo build default.project.json --output StudioAgent.rbxm
```
Expected: `stylua` makes no further changes on a second run; `selene` reports `0 errors, 0 warnings`; `rojo build` succeeds and writes `StudioAgent.rbxm` with no errors (no reference to `getSidecarToken`, `maxPxForCount`, `tokenBox`, or `tokenSaveBtn` remains — grep to confirm: `git grep -nE "getSidecarToken|maxPxForCount|tokenBox|tokenSaveBtn|sidecarToken" src` returns nothing).

- [ ] **Step 15: Commit**

```bash
git add src/Tools/CaptureCore.luau src/Tools/Capture.luau src/CaptureSpec.luau src/Config.luau src/UI/Widget.luau src/Tools/init.luau
git commit -m "feat(capture): drop sidecar token auth + downscale; cap orbits at 20"
```

---

## Task 3: Bundle the exe + docs + gitignore

**Files:**
- Create: `sidecar/build-exe.ps1`
- Create (built + committed): `sidecar/dist/StudioAgentSidecar.exe`
- Modify: `sidecar/README.md` (full rewrite)
- Modify: `.gitignore`

- [ ] **Step 1: Create `sidecar/build-exe.ps1`**

```powershell
# Build the standalone vision sidecar exe (no Python needed to run it). One-time setup:
#   py -m pip install pyinstaller
# Then run this script; the exe lands at sidecar\dist\StudioAgentSidecar.exe (committed to the repo).
# If antivirus flags the --onefile build, swap --onefile for --onedir (ships a folder beside the exe).
$ErrorActionPreference = "Stop"
Push-Location $PSScriptRoot
try {
	py -m PyInstaller --onefile --name StudioAgentSidecar --distpath dist --workpath build --specpath build server.py
	Write-Host "Built dist\StudioAgentSidecar.exe" -ForegroundColor Green
} finally {
	Pop-Location
}
```

- [ ] **Step 2: Update `.gitignore`**

Change the secrets block — replace this line:

```
sidecar/.token
```
with:
```
sidecar/build/
sidecar/*.spec
```
(Leave `sidecar/*.png` as-is. Do NOT add `sidecar/dist/` — the committed exe lives there.)

- [ ] **Step 3: Build the exe**

Run:
```bash
py -m pip install pyinstaller
powershell -File sidecar/build-exe.ps1
```
Expected: PyInstaller runs and prints `Built dist\StudioAgentSidecar.exe`; the file `sidecar/dist/StudioAgentSidecar.exe` exists. (Intermediates land in `sidecar/build/` and are gitignored.)

- [ ] **Step 4: Smoke-test the exe**

Run:
```bash
./sidecar/dist/StudioAgentSidecar.exe &
sleep 2
curl -s -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:8389/captures?b64=1&count=1"
kill %1
```
Expected: prints `200` (the bundled exe serves with no Python and no token).

- [ ] **Step 5: Rewrite `sidecar/README.md`**

Replace the entire file with:

```markdown
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
```

- [ ] **Step 6: Commit (including the exe binary)**

```bash
git add sidecar/build-exe.ps1 sidecar/dist/StudioAgentSidecar.exe sidecar/README.md .gitignore
git commit -m "feat(sidecar): bundle StudioAgentSidecar.exe + build script; rewrite README"
```

---

## Self-Review Notes

- **Spec coverage:** §1 pure-stdlib → Task 1 steps 1–2; §2 drop auth → Task 1 step 2 (server) + Task 2 steps 2, 6–8, 9, 12; §3 cap at 20 / remove downscale → Task 2 steps 1, 4, 5; §4 exe + run.ps1 + README + gitignore → Task 1 step 5, Task 3 all. Widget reflow → Task 2 steps 9–11. SystemPrompt: grep confirmed it carries no token wording, so no edit needed; the only stale comment is in `Tools/init.luau` (Task 2 step 13).
- **No placeholders:** every code step shows full file content or exact old→new text.
- **Type/signature consistency:** `fetchCaptures(count, since, config)` is defined in Task 2 step 2 and both call sites updated to match in steps 3–4. `maxPxForCount` is deleted (step 1) and its only references removed (steps 4, 5). `getSidecarToken` deleted (step 8) with both callers removed (steps 2, 9, 12).
```
