# Multi-Image Viewport Capture (disk-reader) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the whole-window PrintWindow capture with a disk-reader that serves the real viewport PNGs Roblox writes to `tmp-capture-storage`, and add multi-image capture (orbit angles + animation filmstrip) so the agent can build and visually verify objects/rigs/art and review animations.

**Architecture:** All capture flows are plugin-orchestrated — the plugin moves the camera (or steps animation time), triggers `CaptureService:CaptureScreenshot` N times, then makes ONE HTTP call to the local sidecar, which reads the N newest `wob-*` PNGs off disk (downscaling if asked) and returns them as base64. A shared Luau `CaptureCore` owns camera math + trigger + fetch; three thin tool descriptors (`capture`, `capture_angles`, `capture_animation`) wrap it. Edit-mode only for v1.

**Tech Stack:** Luau (Roblox plugin, `--!strict`, Rojo build), Python 3 stdlib `http.server` + Pillow (already a sidecar dependency), in-Studio spec harness (mirrors `RelaySpec`).

**Spec:** `docs/superpowers/specs/2026-06-18-studio-agent-multi-capture-design.md`

---

## File Structure

- **Modify** `sidecar/capture.py` — replace the PrintWindow window-grabber with disk-read functions (`capture_dir`, `newest_captures`, helpers).
- **Modify** `sidecar/server.py` — replace the `/screenshot` handler with `/captures`.
- **Create** `sidecar/test_capture.py` — dependency-free CLI test for the disk-reader.
- **Create** `src/Tools/CaptureCore.luau` — shared engine: pure helpers (camera math, presets, downscale policy, target AABB, validation) + impure helpers (camera save/set/restore, trigger, sidecar fetch).
- **Modify** `src/Tools/Capture.luau` — three descriptors delegating to `CaptureCore`.
- **Create** `src/CaptureSpec.luau` — in-Studio spec for the pure surface.
- **Modify** `src/RelaySpec.luau` — add the two new tool names to `EXPECTED_RELAY` (the no-drift test).
- **Modify** `src/Tools/init.luau` — registry-order comment only (descriptors auto-register via `CaptureTool.descriptors`).
- **Modify** `src/SystemPrompt.luau` — tool guidance for the three capture tools.

Convention notes: every Luau file starts `--!strict`. Descriptors match the `Descriptor` type in `src/Tools/init.luau` (`name`, `description`, `inputSchema`, `destructive`, `run`). A tool may return a `tool_result` blocks array (a table) instead of a string; `AgentLoop` forwards it as the `tool_result` content. On any failure, return a STRING error + `true`.

---

## Task 1: Sidecar disk-reader (`capture.py`)

**Files:**
- Modify: `sidecar/capture.py` (full rewrite)
- Test: `sidecar/test_capture.py` (create)

- [ ] **Step 1: Write the failing test**

Create `sidecar/test_capture.py`:

```python
"""Dependency-free tests for the disk-reader. Run: python sidecar/test_capture.py"""
import os
import sys
import tempfile

from PIL import Image

import capture


def _write_png(path, w, h, mtime):
    Image.new("RGB", (w, h), (10, 20, 30)).save(path, format="PNG")
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

        _write_png(os.path.join(cdir, "wob-1"), 100, 50, 1000)
        _write_png(os.path.join(cdir, "wob-2"), 100, 50, 2000)
        _write_png(os.path.join(cdir, "wob-3"), 100, 50, 3000)
        _write_png(os.path.join(cdir, "wob-4"), 100, 50, 4000)

        got = capture.newest_captures(2, since_ts=0.0, timeout_s=0.2)
        fails += _check("returns the newest 2 (oldest-first)", len(got) == 2)
        # decode to confirm both are valid PNGs
        from io import BytesIO
        fails += _check("both results are valid PNGs",
                        all(Image.open(BytesIO(b)).size == (100, 50) for b in got))

        since3 = 3000
        got = capture.newest_captures(10, since_ts=since3, timeout_s=0.2)
        fails += _check("since_ts filters to wob-3 + wob-4", len(got) == 2)

        # incomplete PNG (no IEND) is skipped
        with open(os.path.join(cdir, "wob-5"), "wb") as f:
            f.write(b"\x89PNG\r\n\x1a\n" + b"\x00" * 32)
        os.utime(os.path.join(cdir, "wob-5"), (5000, 5000))
        got = capture.newest_captures(1, since_ts=5000, timeout_s=0.2)
        fails += _check("incomplete PNG is skipped (timeout -> empty)", len(got) == 0)

        # downscale: long edge capped at max_px
        _write_png(os.path.join(cdir, "wob-6"), 3000, 1000, 6000)
        got = capture.newest_captures(1, since_ts=6000, max_px=2000, timeout_s=0.2)
        ok = len(got) == 1 and max(Image.open(BytesIO(got[0])).size) == 2000
        fails += _check("max_px downscales the long edge to 2000", ok)

    print(f"=== {('ALL PASS' if fails == 0 else str(fails) + ' FAILED')} ===")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `python sidecar/test_capture.py`
Expected: FAIL — `AttributeError: module 'capture' has no attribute 'capture_dir'` (old `capture.py` only has `find_window`/`capture_window_png`).

- [ ] **Step 3: Rewrite `sidecar/capture.py`**

Replace the ENTIRE file contents with:

```python
"""Disk reader for the Studio Agent vision sidecar.

Roblox writes CaptureService:CaptureScreenshot output as full-resolution viewport PNGs to
%LOCALAPPDATA%\\Roblox\\tmp-capture-storage\\wob-<StudioPID><counter>. A plugin can't read that file
(the path API is RobloxScript-gated), but this local helper can. We return the newest N COMPLETE PNGs
whose mtime is >= a caller-supplied timestamp, optionally downscaling them, as PNG bytes.
"""

from __future__ import annotations

import glob
import io
import os
import time

from PIL import Image

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


def _downscale(data: bytes, max_px: int) -> bytes:
    """Aspect-preserving downscale so the long edge <= max_px; returns data unchanged if already small."""
    img = Image.open(io.BytesIO(data))
    longest = max(img.width, img.height)
    if longest <= max_px:
        return data
    scale = max_px / longest
    resized = img.resize((max(1, round(img.width * scale)), max(1, round(img.height * scale))))
    out = io.BytesIO()
    resized.save(out, format="PNG")
    return out.getvalue()


def newest_captures(count, since_ts=0.0, max_px=None, timeout_s=8.0, poll_s=0.15):
    """Up to `count` newest COMPLETE capture PNGs with mtime >= since_ts, returned oldest-first
    (= capture order). Polls up to timeout_s for `count` files to appear (captures may still be
    flushing). Downscales to max_px when given. Returns fewer than `count` on timeout (a shortfall)."""
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
            chosen = complete[-count:] if count > 0 else []
            if max_px is not None:
                chosen = [_downscale(b, max_px) for b in chosen]
            return chosen
        time.sleep(poll_s)
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `python sidecar/test_capture.py`
Expected: all `PASS`, `=== ALL PASS ===`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add sidecar/capture.py sidecar/test_capture.py
git commit -m "feat(sidecar): disk-read newest capture PNGs from tmp-capture-storage"
```

---

## Task 2: Sidecar `/captures` endpoint (`server.py`)

**Files:**
- Modify: `sidecar/server.py:38-61` (the `do_GET` handler + module docstring)

- [ ] **Step 1: Replace the module docstring (lines 1-8)**

```python
"""Studio Agent vision sidecar — localhost-only, token-authed capture-file server.

GET /captures?count=N&since=<epoch>[&max_px=P][&b64=1]
  - reads the N newest complete viewport PNGs Roblox wrote to tmp-capture-storage (mtime >= since).
  - returns JSON {"images":[<base64 png>,...],"returned":N,"shortfall":bool} when b64=1 (the default
    the plugin uses); requires the token via ?token=<t> or `Authorization: Bearer <t>`.

Bind is 127.0.0.1 ONLY. Combined with the token, this keeps disk access off the network.
"""
```

- [ ] **Step 2: Replace `do_GET` (lines 38-61)**

```python
    def do_GET(self):
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)

        if parsed.path != "/captures":
            self._send(404, "application/json", b'{"error":"not found"}')
            return
        if not self._authorized(qs):
            self._send(401, "application/json", b'{"error":"unauthorized"}')
            return

        try:
            count = int(qs.get("count", ["1"])[0])
            since = float(qs.get("since", ["0"])[0])
            max_px = int(qs["max_px"][0]) if "max_px" in qs else None
        except ValueError:
            self._send(400, "application/json", b'{"error":"bad count/since/max_px"}')
            return

        import json

        try:
            pngs = capture.newest_captures(count, since_ts=since, max_px=max_px)
        except Exception as exc:  # noqa: BLE001 - surface any read failure as JSON
            self._send(500, "application/json", json.dumps({"error": str(exc)}).encode())
            return

        images = [base64.b64encode(p).decode("ascii") for p in pngs]
        body = json.dumps(
            {"images": images, "returned": len(images), "shortfall": len(images) < count}
        ).encode()
        self._send(200, "application/json", body)
```

- [ ] **Step 3: Verify the server imports/starts (smoke test, no Studio needed)**

Run: `SIDECAR_TOKEN=test python -c "import sidecar.server" 2>/dev/null || (cd sidecar && SIDECAR_TOKEN=test python -c "import server; print('import OK')")`
Expected: `import OK` (no syntax/import errors). On Windows PowerShell: `cd sidecar; $env:SIDECAR_TOKEN='test'; python -c "import server; print('import OK')"`.

- [ ] **Step 4: Commit**

```bash
git add sidecar/server.py
git commit -m "feat(sidecar): serve /captures (newest viewport PNGs) instead of /screenshot"
```

---

## Task 3: `CaptureCore` pure surface + `CaptureSpec`

**Files:**
- Create: `src/Tools/CaptureCore.luau` (pure helpers in this task; impure helpers added in Task 4)
- Create: `src/CaptureSpec.luau`

- [ ] **Step 1: Write the spec (the failing test)**

Create `src/CaptureSpec.luau`:

```lua
--!strict
-- CaptureSpec: in-Studio self-test for the PURE surface of CaptureCore (camera framing math, presets,
-- downscale policy, elevation mapping). Run via temporarily adding `require(script.CaptureSpec).run()`
-- to init.server.luau, build, reopen Studio, read Output. Impure helpers (camera set/restore, trigger,
-- HTTP fetch) are LIVE-verified in Studio, not here.

local CaptureCore = require(script.Parent.Tools.CaptureCore)

local M = {}
type Case = { name: string, fn: () -> (boolean, string?) }

local function approx(a: number, b: number): boolean
	return math.abs(a - b) < 1e-3
end

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("yawsFor(4) is 0/90/180/270", function()
		local y = CaptureCore.yawsFor(4)
		if #y ~= 4 then return false, "len " .. #y end
		return approx(y[1], 0) and approx(y[2], 90) and approx(y[3], 180) and approx(y[4], 270)
	end)

	add("frameCFrame front (yaw0,pitch0) places the eye on +Z looking at center", function()
		local center = Vector3.new(0, 0, 0)
		local cf = CaptureCore.frameCFrame(center, Vector3.new(4, 4, 4), 0, 0, 1, 70)
		-- eye on +Z, distance > 0
		if cf.Position.Z <= 0 then return false, "eye not on +Z" end
		if not (approx(cf.Position.X, 0) and approx(cf.Position.Y, 0)) then
			return false, "eye not on the Z axis"
		end
		-- LookVector points back toward center (-Z)
		if cf.LookVector.Z >= 0 then return false, "not looking toward center" end
		return true
	end)

	add("frameCFrame distance scales with target size", function()
		local c = Vector3.new(0, 0, 0)
		local near = CaptureCore.frameCFrame(c, Vector3.new(2, 2, 2), 0, 0, 1, 70).Position.Z
		local far = CaptureCore.frameCFrame(c, Vector3.new(20, 20, 20), 0, 0, 1, 70).Position.Z
		return far > near
	end)

	add("frameCFrame distScale multiplies distance", function()
		local c = Vector3.new(0, 0, 0)
		local d1 = CaptureCore.frameCFrame(c, Vector3.new(4, 4, 4), 0, 0, 1, 70).Position.Z
		local d2 = CaptureCore.frameCFrame(c, Vector3.new(4, 4, 4), 0, 0, 2, 70).Position.Z
		return approx(d2, d1 * 2)
	end)

	add("PRESETS has the seven named angles, top/bottom non-degenerate", function()
		for _, n in { "front", "back", "left", "right", "top", "bottom", "iso" } do
			if CaptureCore.PRESETS[n] == nil then return false, "missing " .. n end
		end
		return math.abs(CaptureCore.PRESETS.top.pitch) < 90
			and math.abs(CaptureCore.PRESETS.bottom.pitch) < 90
	end)

	add("maxPxForCount: native res <=20, then 2000/1280/768", function()
		return CaptureCore.maxPxForCount(20) == nil
			and CaptureCore.maxPxForCount(21) == 2000
			and CaptureCore.maxPxForCount(50) == 2000
			and CaptureCore.maxPxForCount(80) == 1280
			and CaptureCore.maxPxForCount(200) == 768
	end)

	add("elevationPitch maps low/eye/high and passes numbers through", function()
		return CaptureCore.elevationPitch("low") == 5
			and CaptureCore.elevationPitch("high") == 45
			and CaptureCore.elevationPitch("eye") == 20
			and CaptureCore.elevationPitch(33) == 33
			and CaptureCore.elevationPitch(nil) == 20
	end)

	return cases
end

function M.run(): { passed: boolean, total: number, failed: number }
	local cases = buildCases()
	local total, failed = #cases, 0
	print("=== CaptureSpec: running " .. tostring(total) .. " cases ===")
	for _, case in ipairs(cases) do
		local ok, result, detail = pcall(case.fn)
		local pass = ok and result == true
		if pass then
			print("  PASS  " .. case.name)
		else
			failed += 1
			local why = if not ok then tostring(result) else tostring(detail)
			print("  FAIL  " .. case.name .. (if why ~= "nil" then " (" .. why .. ")" else ""))
		end
	end
	print("=== Summary: " .. tostring(total - failed) .. "/" .. tostring(total) .. " passed ===")
	return { passed = failed == 0, total = total, failed = failed }
end

return M
```

- [ ] **Step 2: Create `CaptureCore.luau` with the pure helpers**

Create `src/Tools/CaptureCore.luau`:

```lua
--!strict
-- CaptureCore: the shared engine for the capture tools. PURE helpers (camera framing math, presets,
-- downscale policy, elevation) are unit-tested in CaptureSpec; IMPURE helpers (camera save/set/restore,
-- CaptureScreenshot trigger, sidecar HTTP fetch, target resolution) are added in Task 4 and are
-- LIVE-verified in Studio. A plugin can't read the capture file, so the impure fetch asks the local
-- sidecar to read the newest wob PNG(s) off disk. See the multi-capture design spec.

local CaptureCore = {}

local DEFAULT_FOV = 70 -- degrees; Studio's default camera FieldOfView
local FIT_MARGIN = 1.2 -- pad the bounding sphere so the target isn't edge-to-edge

-- preset name -> (yawDeg, pitchDeg). top/bottom use 89/-89 to avoid the CFrame.lookAt up-vector
-- degeneracy at a perfectly vertical view.
CaptureCore.PRESETS = {
	front = { yaw = 0, pitch = 0 },
	back = { yaw = 180, pitch = 0 },
	right = { yaw = 90, pitch = 0 },
	left = { yaw = -90, pitch = 0 },
	top = { yaw = 0, pitch = 89 },
	bottom = { yaw = 0, pitch = -89 },
	iso = { yaw = 45, pitch = 30 },
} :: { [string]: { yaw: number, pitch: number } }

-- N evenly-spaced yaw angles (degrees) starting at 0.
function CaptureCore.yawsFor(count: number): { number }
	local yaws: { number } = {}
	for i = 0, count - 1 do
		table.insert(yaws, (360 / count) * i)
	end
	return yaws
end

-- Camera CFrame framing the target's bounding sphere from (yaw, pitch) at a fitted distance.
-- Pure + deterministic. yaw rotates around Y (0 = eye on +Z looking toward -Z at the center).
function CaptureCore.frameCFrame(
	center: Vector3,
	size: Vector3,
	yawDeg: number,
	pitchDeg: number,
	distScale: number,
	fovDeg: number?
): CFrame
	local fov = fovDeg or DEFAULT_FOV
	local radius = math.max(size.Magnitude / 2, 1)
	local distance = (radius / math.tan(math.rad(fov) / 2)) * FIT_MARGIN * distScale
	local yaw, pitch = math.rad(yawDeg), math.rad(pitchDeg)
	local dir = Vector3.new(
		math.cos(pitch) * math.sin(yaw),
		math.sin(pitch),
		math.cos(pitch) * math.cos(yaw)
	)
	return CFrame.lookAt(center + dir * distance, center)
end

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

-- "low"/"eye"/"high" or a numeric degrees -> pitch degrees.
function CaptureCore.elevationPitch(elevation: any): number
	if type(elevation) == "number" then
		return elevation
	elseif elevation == "low" then
		return 5
	elseif elevation == "high" then
		return 45
	end
	return 20 -- "eye" / default
end

return CaptureCore
```

- [ ] **Step 3: Run lint + build, then run the spec in Studio**

Run: `selene src/` then `rojo build` (expected: 0 errors). Then temporarily add `require(script.CaptureSpec).run()` near the end of `src/init.server.luau`, `rojo build`, reopen Studio on a fresh Baseplate, and read the Output window.
Expected: `=== Summary: 7/7 passed ===`. Then REMOVE the temporary `require(...).run()` line.

- [ ] **Step 4: Commit**

```bash
git add src/Tools/CaptureCore.luau src/CaptureSpec.luau
git commit -m "feat(capture): CaptureCore pure surface (framing math, presets, downscale policy) + spec"
```

---

## Task 4: `CaptureCore` impure surface (camera, trigger, fetch, target)

**Files:**
- Modify: `src/Tools/CaptureCore.luau` (append before `return CaptureCore`)

- [ ] **Step 1: Add the service requires at the top of the file**

Insert directly under the module comment, above `local CaptureCore = {}`:

```lua
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local CaptureService = game:GetService("CaptureService")
local Selection = game:GetService("Selection")
```

- [ ] **Step 2: Append the impure helpers (before `return CaptureCore`)**

```lua
export type CameraState = { camType: Enum.CameraType, cframe: CFrame, fov: number }?

function CaptureCore.saveCamera(): CameraState
	local cam = Workspace.CurrentCamera
	if cam == nil then
		return nil
	end
	return { camType = cam.CameraType, cframe = cam.CFrame, fov = cam.FieldOfView }
end

function CaptureCore.restoreCamera(state: CameraState)
	local cam = Workspace.CurrentCamera
	if cam == nil or state == nil then
		return
	end
	cam.CameraType = state.camType
	cam.CFrame = state.cframe
	cam.FieldOfView = state.fov
end

function CaptureCore.setCamera(cframe: CFrame)
	local cam = Workspace.CurrentCamera
	if cam == nil then
		return
	end
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CFrame = cframe
end

-- Let the viewport re-render the new camera/pose before we capture.
function CaptureCore.settle(frames: number?)
	for _ = 1, (frames or 2) do
		RunService.Heartbeat:Wait()
	end
end

-- Trigger one CaptureScreenshot and yield until the engine invokes the callback (or a timeout). We
-- don't need the rbxtemp id — the sidecar reads the file by mtime. Returns true if the callback fired.
function CaptureCore.triggerCapture(timeoutS: number?): boolean
	local done = false
	local ok = pcall(function()
		CaptureService:CaptureScreenshot(function(_id)
			done = true
		end)
	end)
	if not ok then
		return false
	end
	local deadline = os.clock() + (timeoutS or 5)
	while not done and os.clock() < deadline do
		RunService.Heartbeat:Wait()
	end
	return done
end

-- Walk a dotted/slashed instance path from `game` (e.g. "Workspace.Model.Part"). Returns nil on miss.
local function resolvePath(path: string): Instance?
	local node: Instance = game
	for token in string.gmatch(path, "[^%./]+") do
		local child = node:FindFirstChild(token)
		if child == nil then
			return nil
		end
		node = child
	end
	return if node == game then nil else node
end

-- Axis-aligned bounding box (center, size) over every BasePart under the given roots. nil if none.
local function aabbOf(roots: { Instance }): (Vector3?, Vector3?)
	local minV: Vector3? = nil
	local maxV: Vector3? = nil
	local function acc(part: BasePart)
		local cf, sz = part.CFrame, part.Size
		for _, sx in { -0.5, 0.5 } do
			for _, sy in { -0.5, 0.5 } do
				for _, sz2 in { -0.5, 0.5 } do
					local p = (cf * CFrame.new(sz.X * sx, sz.Y * sy, sz.Z * sz2)).Position
					if minV == nil then
						minV, maxV = p, p
					else
						minV = Vector3.new(math.min(minV.X, p.X), math.min(minV.Y, p.Y), math.min(minV.Z, p.Z))
						maxV = Vector3.new(math.max(maxV.X, p.X), math.max(maxV.Y, p.Y), math.max(maxV.Z, p.Z))
					end
				end
			end
		end
	end
	for _, root in roots do
		if root:IsA("BasePart") then
			acc(root)
		end
		for _, d in root:GetDescendants() do
			if d:IsA("BasePart") then
				acc(d)
			end
		end
	end
	if minV == nil or maxV == nil then
		return nil, nil
	end
	return (minV + maxV) / 2, (maxV - minV)
end

-- Resolve the target into (center, size, errString). A path string, or (nil/empty) the current
-- Studio Selection. Unions the bounding boxes of all resolved instances' BaseParts.
function CaptureCore.resolveTarget(target: any): (Vector3?, Vector3?, string?)
	local roots: { Instance } = {}
	if type(target) == "string" and target ~= "" then
		local inst = resolvePath(target)
		if inst == nil then
			return nil, nil, "target not found: " .. target
		end
		table.insert(roots, inst)
	else
		for _, inst in Selection:Get() do
			table.insert(roots, inst)
		end
		if #roots == 0 then
			return nil, nil, "nothing selected — select a part/model in Studio or pass a target path."
		end
	end
	local center, size = aabbOf(roots)
	if center == nil or size == nil then
		return nil, nil, "target has no parts to frame (no BasePart found)."
	end
	return center, size, nil
end

-- Ask the sidecar for `count` newest capture PNGs created at/after `since` (epoch seconds), downscaled
-- to maxPx when given. Returns (blocks, nil) on success — a list of base64 image blocks — or
-- (nil, errString) on any failure (same error wording as the previous capture tool).
function CaptureCore.fetchCaptures(
	count: number,
	since: number,
	maxPx: number?,
	config: any
): ({ any }?, string?)
	if config == nil then
		return nil, "capture: internal error (no config available)"
	end
	local token = config:getSidecarToken()
	if token == "" then
		return nil,
			"capture: no sidecar token is set. Start the vision sidecar (sidecar/run.ps1) and paste "
				.. "the token it prints into the panel's 'sidecar token' field."
	end
	local url = config:getSidecarUrl()
		.. "/captures?b64=1&count="
		.. tostring(count)
		.. "&since="
		.. tostring(math.floor(since))
	if maxPx ~= nil then
		url ..= "&max_px=" .. tostring(maxPx)
	end

	local ok, res = pcall(function()
		return HttpService:RequestAsync({
			Url = url,
			Method = "GET",
			Headers = { ["Authorization"] = "Bearer " .. token },
		})
	end)
	if not ok then
		local msg = string.lower(tostring(res))
		if string.find(msg, "not enabled", 1, true) then
			return nil,
				"capture: HTTP requests are disabled. Enable 'Allow HTTP Requests' in Game Settings > Security."
		end
		if string.find(msg, "game server", 1, true) then
			return nil,
				"capture: HttpService is server-only — capture from edit mode or the Studio Server view."
		end
		return nil,
			"capture: could not reach the vision sidecar at "
				.. config:getSidecarUrl()
				.. " — is it running? Start it with sidecar/run.ps1. ("
				.. tostring(res)
				.. ")"
	end

	local response = res :: any
	if not response.Success then
		if response.StatusCode == 401 then
			return nil,
				"capture: the sidecar rejected the token (401). Re-copy the token from sidecar/run.ps1."
		end
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

- [ ] **Step 3: Lint + build**

Run: `selene src/` then `stylua --check src/` then `rojo build`
Expected: 0 errors / 0 warnings. (CaptureSpec from Task 3 still passes — these are additive.)

- [ ] **Step 4: Commit**

```bash
git add src/Tools/CaptureCore.luau
git commit -m "feat(capture): CaptureCore impure surface — camera, trigger, target AABB, sidecar fetch"
```

---

## Task 5: The three tool descriptors (`Capture.luau`)

**Files:**
- Modify: `src/Tools/Capture.luau` (full rewrite — keep the `Descriptor` export type)

- [ ] **Step 1: Rewrite `src/Tools/Capture.luau`**

Replace the ENTIRE file with:

```lua
--!strict
-- Capture: the vision tools. A plugin can't read viewport pixels, so each tool triggers
-- CaptureService:CaptureScreenshot (which writes a full-res viewport PNG to disk) and asks the local
-- sidecar to read the newest file(s). Three tools share CaptureCore:
--   capture           - one shot at the current camera.
--   capture_angles    - orbit a target: N framed angles (objects/assets/art).
--   capture_animation - filmstrip: time-sampled frames of an animation (review a motion).
-- These return STRUCTURED content (a tool_result blocks array of text labels + base64 images);
-- AgentLoop forwards the array verbatim. On ANY failure they fall back to a STRING error (isError=true).

local CaptureCore = require(script.Parent.CaptureCore)

local Capture = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (any, boolean),
}

local function getConfig(context: any): any
	return if type(context) == "table" then context.config else nil
end

-- ---- capture (single) -------------------------------------------------------

local function runSingle(_input: any, context: any): (any, boolean)
	local since = os.time() - 2
	if not CaptureCore.triggerCapture() then
		return "capture: CaptureService did not produce a screenshot (ensure Studio is focused, retry).",
			true
	end
	CaptureCore.settle(1)
	local blocks, err = CaptureCore.fetchCaptures(1, since, nil, getConfig(context))
	if blocks == nil then
		return err :: string, true
	end
	return blocks, false
end

-- ---- capture_angles (orbit) -------------------------------------------------

type Shot = { yaw: number, pitch: number, label: string }

local function runAngles(input: any, context: any): (any, boolean)
	local args = if type(input) == "table" then input else {}
	local center, size, terr = CaptureCore.resolveTarget(args.target)
	if center == nil or size == nil then
		return "capture_angles: " .. tostring(terr), true
	end

	local shots: { Shot } = {}
	if type(args.presets) == "table" and #args.presets > 0 then
		for _, name in args.presets do
			local p = CaptureCore.PRESETS[string.lower(tostring(name))]
			if p ~= nil then
				table.insert(shots, { yaw = p.yaw, pitch = p.pitch, label = tostring(name) })
			end
		end
		if #shots == 0 then
			return "capture_angles: no valid presets (use front/back/left/right/top/bottom/iso).", true
		end
	else
		local count = if type(args.count) == "number" and args.count >= 1
			then math.floor(args.count)
			else 6
		local pitch = CaptureCore.elevationPitch(args.elevation)
		for _, yaw in CaptureCore.yawsFor(count) do
			table.insert(shots, {
				yaw = yaw,
				pitch = pitch,
				label = string.format("%d deg", math.floor(yaw + 0.5)),
			})
		end
	end

	local distScale = if type(args.distance) == "number" and args.distance > 0
		then args.distance
		else 1
	local saved = CaptureCore.saveCamera()
	local since = os.time() - 2
	local triggered = 0
	local okAll = pcall(function()
		for _, shot in shots do
			CaptureCore.setCamera(
				CaptureCore.frameCFrame(center :: Vector3, size :: Vector3, shot.yaw, shot.pitch, distScale)
			)
			CaptureCore.settle(2)
			if CaptureCore.triggerCapture() then
				triggered += 1
			end
		end
	end)
	CaptureCore.restoreCamera(saved)

	if not okAll or triggered == 0 then
		return "capture_angles: failed to capture any angle (camera restored).", true
	end
	local blocks, err =
		CaptureCore.fetchCaptures(triggered, since, CaptureCore.maxPxForCount(triggered), getConfig(context))
	if blocks == nil then
		return err :: string, true
	end

	local content: { any } = {
		{ type = "text", text = string.format("%d viewport angles of the target:", #blocks) },
	}
	for i, b in blocks do
		local label = if shots[i] ~= nil then shots[i].label else tostring(i)
		table.insert(content, {
			type = "text",
			text = string.format("angle %d/%d — %s", i, #blocks, label),
		})
		table.insert(content, b)
	end
	if #blocks < #shots then
		table.insert(content, {
			type = "text",
			text = string.format(
				"(note: %d of %d frames returned; if you need more, reduce the count or retry)",
				#blocks,
				#shots
			),
		})
	end
	return content, false
end

-- ---- capture_animation (filmstrip) -----------------------------------------
-- Implemented in Task 7 after the edit-mode-playback feasibility spike. Until then it returns a
-- clear, non-crashing error so the registry/relay wiring is testable now.

local function runAnimation(_input: any, _context: any): (any, boolean)
	return "capture_animation: not yet enabled (pending the edit-mode animation-playback spike).", true
end

-- ---- descriptors ------------------------------------------------------------

Capture.descriptors = {
	{
		name = "capture",
		description = "Take a SCREENSHOT of the current Studio VIEWPORT and SEE it (returned as an "
			.. "image). Use it to visually verify anything with an appearance — GUIs, scenes, rigs, a "
			.. "single framing — then adjust and capture again. Requires the local vision sidecar; if "
			.. "it isn't running, returns an error explaining how to start it.",
		inputSchema = { type = "object", properties = {} },
		destructive = false,
		run = runSingle,
	},
	{
		name = "capture_angles",
		description = "Capture a target from MULTIPLE camera angles in one call — give a target and a "
			.. "count and the tool frames it and orbits automatically (you NEVER compute camera CFrames). "
			.. "Use it to inspect/build an object, asset, or art from several sides. Inputs: target "
			.. "(instance path; defaults to the current Studio selection), count (default 6), elevation "
			.. "(low/eye/high or degrees), distance (zoom scale), or presets (e.g. ['front','left','top']) "
			.. "to override the even orbit. Returns the angles as labeled images.",
		inputSchema = {
			type = "object",
			properties = {
				target = { type = "string", description = "Instance path; omit to use the selection." },
				count = { type = "number", description = "Number of evenly-spaced angles (default 6)." },
				elevation = {
					type = "string",
					description = "low | eye | high, or a pitch in degrees as a number.",
				},
				distance = { type = "number", description = "Zoom scale of the auto-fit (default 1.0)." },
				presets = {
					type = "array",
					items = { type = "string" },
					description = "Named angles (front/back/left/right/top/bottom/iso); overrides the orbit.",
				},
			},
		},
		destructive = false,
		run = runAngles,
	},
	{
		name = "capture_animation",
		description = "Capture a FILMSTRIP of an animation — time-sampled frames of a rig's motion from "
			.. "a fixed angle, so you can review whether an animation looks right end-to-end. Inputs: rig "
			.. "(instance path), animation (asset id or KeyframeSequence path), frames (default 8), "
			.. "startTime/endTime (seconds; defaults to the full clip), angle (a preset). Returns the "
			.. "sampled frames as labeled images.",
		inputSchema = {
			type = "object",
			properties = {
				rig = { type = "string", description = "Path to the model with an Animator/Humanoid." },
				animation = { type = "string", description = "Animation asset id or KeyframeSequence path." },
				frames = { type = "number", description = "Number of time samples (default 8)." },
				startTime = { type = "number", description = "Start time in seconds (default 0)." },
				endTime = { type = "number", description = "End time in seconds (default clip length)." },
				angle = { type = "string", description = "A preset angle (front/left/iso/…)." },
			},
			required = { "rig", "animation" },
		},
		destructive = false,
		run = runAnimation,
	},
} :: { Descriptor }

return Capture
```

- [ ] **Step 2: Lint + build**

Run: `selene src/` then `stylua --check src/` then `rojo build`
Expected: 0 errors / 0 warnings.

- [ ] **Step 3: Commit**

```bash
git add src/Tools/Capture.luau
git commit -m "feat(capture): three descriptors (capture / capture_angles / capture_animation) over CaptureCore"
```

---

## Task 6: Wire-up — RelaySpec, registry comment, SystemPrompt

**Files:**
- Modify: `src/RelaySpec.luau:22-33` (the `EXPECTED_RELAY` list)
- Modify: `src/Tools/init.luau:11-13` (registry-order comment)
- Modify: `src/SystemPrompt.luau` (tool guidance — two locations)

- [ ] **Step 1: Add the new tools to `EXPECTED_RELAY` in `src/RelaySpec.luau`**

In the `EXPECTED_RELAY` table (currently ends with `"dispatch_writers",`), the entry `"capture"` already exists. Add the two new tools right after it so the "no drift" test still passes:

```lua
	"capture",
	"capture_angles",
	"capture_animation",
```

(They are camera/DataModel + HTTP tools → relay in client-view play, same class as `capture`.)

- [ ] **Step 2: Update the registry-order comment in `src/Tools/init.luau`**

Change the comment listing the final registry (currently `... create_instance, capture, dispatch_subagents, ...`) to include the new tools:

```lua
-- registry. Final registry: run_luau, get_tree, search, get_properties, get_output, set_property,
-- create_instance, capture, capture_angles, capture_animation, dispatch_subagents, update_tasks,
-- remember, forget, dispatch_writers, use_skill, save_skill, delete_skill.
```

No code change is needed in `init.luau` — the existing `for _, descriptor in CaptureTool.descriptors` loop registers all three automatically.

- [ ] **Step 3: Update the capture guidance in `src/SystemPrompt.luau`**

(a) In the main verification bullet (around line 63, "for anything VISUAL … call capture to screenshot Studio …"), replace that bullet with:

```lua
- for anything VISUAL (a GUI, a built scene, a posed rig, an animation): use the capture tools to SEE it and confirm colors, layout, alignment, and framing, then adjust and capture again until it looks right. Use capture for the current view, capture_angles to inspect an object/asset/art from several sides (just give a target + count — never hand-compute camera CFrames), and capture_animation to review an animation as a filmstrip;
```

(b) In the main tool list (the bullet starting "- capture(window?): screenshot…", around line 109), replace that single bullet with:

```lua
- capture(): screenshot the current Studio VIEWPORT and SEE it.
- capture_angles(target?, count?, elevation?, distance?, presets?): see a target from MULTIPLE framed angles in one call (defaults to your selection); the tool orbits the camera for you.
- capture_animation(rig, animation, frames?, startTime?, endTime?, angle?): see an animation as a time-sampled filmstrip.
```

- [ ] **Step 4: Lint + build, then run BOTH specs in Studio**

Run: `selene src/` then `stylua --check src/` then `rojo build`. Then temporarily add `require(script.RelaySpec).run()` and `require(script.CaptureSpec).run()` to `src/init.server.luau`, build, reopen Studio, read Output.
Expected: RelaySpec `Summary: 18/18 passed` (15 prior + the 3 names still classified, no drift) and CaptureSpec `7/7 passed`. Then REMOVE the temporary requires.

- [ ] **Step 5: Commit**

```bash
git add src/RelaySpec.luau src/Tools/init.luau src/SystemPrompt.luau
git commit -m "feat(capture): register + classify the new capture tools; system-prompt guidance"
```

---

## Task 7: `capture_animation` — feasibility spike + implementation

**Files:**
- Modify: `src/Tools/CaptureCore.luau` (add `sampleAnimation` impure helper)
- Modify: `src/Tools/Capture.luau` (replace the `runAnimation` stub)

- [ ] **Step 1: Run the edit-mode playback spike (command bar, fresh Baseplate)**

In Studio (edit mode) with an R15 rig in Workspace, run this in the command bar and read Output. It answers: can we drive an `AnimationTrack` `TimePosition` in edit and have the rig pose update?

```lua
local rig = workspace:FindFirstChild("Rig") or workspace:FindFirstChildWhichIsA("Model")
local hum = rig:FindFirstChildWhichIsA("Humanoid")
local animator = hum and hum:FindFirstChildWhichIsA("Animator")
local anim = Instance.new("Animation"); anim.AnimationId = "rbxassetid://507771019" -- a default walk
local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
print("[SPIKE] LoadAnimation ok=" .. tostring(ok) .. " track=" .. tostring(track))
if ok then
	track:Play(); track:AdjustSpeed(0); track.TimePosition = 0.5
	game:GetService("RunService").Heartbeat:Wait()
	print("[SPIKE] length=" .. tostring(track.Length) .. " pose applied? (eyeball the rig)")
end
```

Decide from the result:
- **If the pose updates in edit** → implement Step 2 (the `AnimationTrack` path).
- **If it does NOT** (no Animator, or pose frozen at identity) → keep the `runAnimation` stub's error but change its text to: `"capture_animation: animation playback isn't available in edit on this rig — playtest-mode filmstrips are a planned follow-up."`, commit, and STOP here (ship `capture` + `capture_angles`). Record the outcome in the handoff.

- [ ] **Step 2 (only if the spike succeeded): Add `sampleAnimation` to `CaptureCore.luau`**

Append before `return CaptureCore`:

```lua
local AssetService = game:GetService("AssetService")

-- Resolve the `animation` arg into an Animation instance: an asset id ("rbxassetid://N" or a bare
-- number string) or a path to a KeyframeSequence (published via AssetService into a temp Animation).
local function toAnimation(animationArg: string): (Animation?, string?)
	if string.match(animationArg, "^%d+$") or string.match(animationArg, "^rbxassetid://%d+$") then
		local anim = Instance.new("Animation")
		anim.AnimationId = if string.match(animationArg, "^%d+$")
			then "rbxassetid://" .. animationArg
			else animationArg
		return anim, nil
	end
	local inst = resolvePath(animationArg)
	if inst ~= nil and inst:IsA("KeyframeSequence") then
		local ok, id = pcall(function()
			return AssetService:RegisterAnimation(inst)
		end)
		if ok then
			local anim = Instance.new("Animation")
			anim.AnimationId = "rbxassetid://" .. tostring(id)
			return anim, nil
		end
		return nil, "could not register the KeyframeSequence as an animation."
	end
	return nil, "animation must be an asset id or a path to a KeyframeSequence."
end

-- Drive `rig`'s Animator through `frames` time samples in [startTime,endTime] (endTime nil = clip
-- length), capturing each from the current (caller-set) camera. Returns (triggered, errString).
function CaptureCore.sampleAnimation(
	rigArg: string,
	animationArg: string,
	frames: number,
	startTime: number,
	endTime: number?
): (number, string?)
	local rig = resolvePath(rigArg)
	if rig == nil then
		return 0, "rig not found: " .. rigArg
	end
	local hum = rig:FindFirstChildWhichIsA("Humanoid") or rig:FindFirstChildWhichIsA("AnimationController")
	local animator = if hum ~= nil then hum:FindFirstChildWhichIsA("Animator") else nil
	if animator == nil then
		return 0, "rig has no Animator (needs a Humanoid or AnimationController with an Animator)."
	end
	local anim, aerr = toAnimation(animationArg)
	if anim == nil then
		return 0, aerr
	end
	local okLoad, track = pcall(function()
		return animator:LoadAnimation(anim :: Animation)
	end)
	if not okLoad or track == nil then
		return 0, "could not load the animation onto the rig."
	end
	local t = track :: AnimationTrack
	t:Play()
	t:AdjustSpeed(0) -- freeze; we scrub TimePosition manually
	local stop = endTime
	if stop == nil or stop <= startTime then
		CaptureCore.settle(1) -- let Length populate
		stop = t.Length
	end
	local triggered = 0
	local span = math.max(stop - startTime, 0)
	for i = 0, frames - 1 do
		local frac = if frames > 1 then i / (frames - 1) else 0
		t.TimePosition = startTime + span * frac
		CaptureCore.settle(2)
		if CaptureCore.triggerCapture() then
			triggered += 1
		end
	end
	t:Stop()
	return triggered, nil
end
```

- [ ] **Step 3 (only if the spike succeeded): Replace the `runAnimation` stub in `Capture.luau`**

```lua
local function runAnimation(input: any, context: any): (any, boolean)
	local args = if type(input) == "table" then input else {}
	if type(args.rig) ~= "string" or args.rig == "" then
		return "capture_animation: 'rig' (an instance path) is required.", true
	end
	if type(args.animation) ~= "string" or args.animation == "" then
		return "capture_animation: 'animation' (asset id or KeyframeSequence path) is required.", true
	end
	local frames = if type(args.frames) == "number" and args.frames >= 1
		then math.floor(args.frames)
		else 8
	local startTime = if type(args.startTime) == "number" then args.startTime else 0
	local endTime = if type(args.endTime) == "number" then args.endTime else nil

	-- Fix the camera at a preset angle (default front) framing the rig, for the whole strip.
	local center, size = CaptureCore.resolveTarget(args.rig)
	local saved = CaptureCore.saveCamera()
	if center ~= nil and size ~= nil then
		local preset = CaptureCore.PRESETS[string.lower(tostring(args.angle))] or CaptureCore.PRESETS.front
		CaptureCore.setCamera(CaptureCore.frameCFrame(center, size, preset.yaw, preset.pitch, 1))
		CaptureCore.settle(2)
	end

	local since = os.time() - 2
	local triggered, serr = 0, nil
	local okAll = pcall(function()
		triggered, serr = CaptureCore.sampleAnimation(args.rig, args.animation, frames, startTime, endTime)
	end)
	CaptureCore.restoreCamera(saved)
	if not okAll then
		return "capture_animation: failed while sampling (camera restored).", true
	end
	if triggered == 0 then
		return "capture_animation: " .. tostring(serr or "no frames captured."), true
	end
	local blocks, err =
		CaptureCore.fetchCaptures(triggered, since, CaptureCore.maxPxForCount(triggered), getConfig(context))
	if blocks == nil then
		return err :: string, true
	end
	local content: { any } = {
		{ type = "text", text = string.format("%d animation frames (filmstrip):", #blocks) },
	}
	for i, b in blocks do
		table.insert(content, { type = "text", text = string.format("frame %d/%d", i, #blocks) })
		table.insert(content, b)
	end
	return content, false
end
```

- [ ] **Step 4: Lint + build**

Run: `selene src/` then `stylua --check src/` then `rojo build`
Expected: 0 errors / 0 warnings.

- [ ] **Step 5: Commit**

```bash
git add src/Tools/CaptureCore.luau src/Tools/Capture.luau
git commit -m "feat(capture): capture_animation filmstrip via Animator TimePosition scrub (post-spike)"
```

---

## Task 8: Live verification (fresh Baseplate)

**Files:** none (manual verification; no code change unless a bug is found).

- [ ] **Step 1: Start the sidecar and wire its token**

Run `sidecar/run.ps1`, copy the printed token into the panel's "sidecar token" field (and confirm `sidecar url` = `http://127.0.0.1:8389`). Confirm "Allow HTTP Requests" is on in Game Settings > Security.

- [ ] **Step 2: Verify `capture` (single)**

Build + install the plugin, open a fresh Baseplate, ask the agent: "capture the viewport." Expected: one viewport image comes back (the Baseplate), not the whole Studio window. Confirm the on-disk file appeared in `%LOCALAPPDATA%\Roblox\tmp-capture-storage`.

- [ ] **Step 3: Verify `capture_angles`**

Insert a Part, select it, ask: "show me this part from 8 angles." Expected: 8 labeled images orbiting the part, each properly framed; the camera returns to where it started afterward.

- [ ] **Step 4: Verify `capture_animation` (only if Task 7 shipped it)**

With an R15 rig in Workspace, ask: "show me frames of a walk animation on this rig." Expected: a labeled filmstrip of distinct poses; camera restored.

- [ ] **Step 5: Update the handoff + memory**

Append the outcome (what shipped, animation spike result) to `HANDOFF.md` / the session handoff, and update the `roblox-plugin-native-screenshot-infeasible` memory to note the disk-reader capture shipped. Commit:

```bash
git add HANDOFF.md docs/superpowers/handoffs/
git commit -m "docs: multi-capture shipped + live-verified"
```

---

## Self-Review (completed during planning)

- **Spec coverage:** disk-reader (Tasks 1-2), three tools (Task 5), orbit + presets (Tasks 3/5), filmstrip (Task 7), no fixed cap / auto-downscale / many-image rule (`maxPxForCount`, Tasks 3/5), edit-mode-only (no relay/playtest tasks), error handling + camera restore guard (Tasks 4/5), specs (Tasks 1/3) + RelaySpec no-drift (Task 6) + spike (Task 7) + live verify (Task 8). All covered.
- **Placeholder scan:** no TBD/TODO; the `runAnimation` stub is a deliberate, compiling, error-returning placeholder finalized by the defined spike in Task 7 (not a code-gap).
- **Type/name consistency:** `frameCFrame`, `yawsFor`, `maxPxForCount`, `elevationPitch`, `resolveTarget`, `saveCamera`/`restoreCamera`/`setCamera`/`settle`/`triggerCapture`/`fetchCaptures`/`sampleAnimation`, `PRESETS` — used identically across CaptureCore, Capture.luau, and CaptureSpec. `resolvePath`/`aabbOf` are file-local in CaptureCore and referenced only there (incl. `toAnimation`/`sampleAnimation`). Sidecar `capture_dir`/`newest_captures` match between `capture.py`, `server.py`, and `test_capture.py`.
