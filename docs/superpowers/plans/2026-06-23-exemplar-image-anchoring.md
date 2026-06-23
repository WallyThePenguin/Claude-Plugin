# Exemplar-image anchoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `evaluate` *see* — it captures the built subject and grades that screenshot against curated, clean-license exemplar images per category (calibration anchoring), folded into the same forced-`submit_grade` call, with a guaranteed text-only fallback.

**Architecture:** A sidecar-served exemplar folder (`sidecar/exemplars/` + `manifest.json`) exposed by a new `GET /exemplars` endpoint that returns the same base64-image shape `fetchCaptures` already consumes. A new Luau module `ExemplarEvidence` fetches those exemplars and auto-captures the subject (reusing `CaptureCore`), returning labeled image blocks; `evaluate` assembles an array `content` (text + build capture + exemplars) instead of a string. A stdlib validator enforces clean licensing. Everything degrades to today's text-only grade on any failure.

**Tech Stack:** Luau (Roblox plugin, `--!strict`), Python 3 stdlib (sidecar + scripts), Rojo build, `selene`/`stylua` static gate, the dev bridge (`scripts/studio-agent.ps1`) for live dogfooding.

---

## File Structure

- **Create `sidecar/exemplars.py`** — manifest reader: `exemplars_dir()`, `manifest_path()`, `load_manifest()`, `exemplars_for(category, want_b64)`. One responsibility: turn the manifest + files into serveable dicts.
- **Create `sidecar/test_exemplars.py`** — dependency-free test for the reader (mirrors `test_capture.py`).
- **Modify `sidecar/server.py`** — add the `GET /exemplars` route + `_exemplars` handler + docstring line.
- **Create `scripts/validate_exemplars.py`** — stdlib manifest validator (mirrors `validate_rubric.py`); pure `validate(...)` + `known_criteria()` + `main()`.
- **Create `scripts/test_validate_exemplars.py`** — dependency-free test for `validate(...)`.
- **Create `src/ExemplarEvidence.luau`** — pure `buildExemplarBlocks` + impure `fetchExemplars` / `captureSubject`. The visual-evidence unit, paralleling `GuiEvidence`/`EnvEvidence`.
- **Create `src/ExemplarEvidenceSpec.luau`** — in-Studio self-test for the pure helper.
- **Modify `src/Tools/Evaluate.luau`** — assemble array `content`, fold visual evidence, add `capture` input + `VISUAL_INSTRUCTION`, graceful degrade.
- **Modify `src/SystemPrompt.luau`** — extend the "Evaluating against the rubric" section with the visual-anchoring + study-only-copyright nudge.
- **Create `sidecar/exemplars/manifest.json` + `sidecar/exemplars/<category>/*.png`** — the seed corpus.

**Note on "test fails first" for Luau:** there is no local Luau runtime — Luau specs run *in-Studio* via a temporary `require(script.XSpec).run()` in `init.server.luau`, exercised at the dogfood (Task 7). For Luau tasks the per-task gate is `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm` (selene MUST be 0/0). Python tasks run their tests locally for real.

---

### Task 1: Sidecar exemplar reader + `/exemplars` endpoint

**Files:**
- Create: `sidecar/exemplars.py`
- Test: `sidecar/test_exemplars.py`
- Modify: `sidecar/server.py`

- [ ] **Step 1: Write the failing test**

Create `sidecar/test_exemplars.py`:

```python
"""Dependency-free tests for the exemplar reader. Run: python sidecar/test_exemplars.py"""
import base64
import json
import os
import sys
import tempfile
from unittest import mock

import exemplars


def _check(name, cond):
    print(("  PASS  " if cond else "  FAIL  ") + name)
    return 0 if cond else 1


def main():
    fails = 0
    with tempfile.TemporaryDirectory() as d:
        ex_dir = os.path.join(d, "exemplars")
        os.makedirs(os.path.join(ex_dir, "environment"))
        png = b"\x89PNG\r\n\x1a\nHELLOIEND"
        with open(os.path.join(ex_dir, "environment", "a.png"), "wb") as f:
            f.write(png)
        manifest = {"version": 1, "exemplars": [
            {"id": "env-a", "category": "environment", "file": "environment/a.png",
             "license": "own", "source": "me", "caption": "crafted", "tier": "exceptional"},
            {"id": "loco-a", "category": "locomotion", "file": "locomotion/missing.png",
             "license": "cc0", "source": "x", "caption": "y"},
        ]}
        with open(os.path.join(ex_dir, "manifest.json"), "w", encoding="utf-8") as f:
            json.dump(manifest, f)

        with mock.patch.object(exemplars, "exemplars_dir", return_value=ex_dir):
            meta = exemplars.exemplars_for("environment", want_b64=False)
            fails += _check("filters to category (1 entry)", len(meta) == 1 and meta[0]["id"] == "env-a")
            fails += _check("metadata-only omits image", "image" not in meta[0])

            withimg = exemplars.exemplars_for("environment", want_b64=True)
            fails += _check("b64 attaches file bytes",
                            len(withimg) == 1 and withimg[0]["image"] == base64.b64encode(png).decode("ascii"))

            missing = exemplars.exemplars_for("locomotion", want_b64=True)
            fails += _check("missing file skipped when b64", len(missing) == 0)

            none = exemplars.exemplars_for("combat", want_b64=True)
            fails += _check("unknown category -> []", none == [])

    print(f"=== {('ALL PASS' if fails == 0 else str(fails) + ' FAILED')} ===")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python sidecar/test_exemplars.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'exemplars'`.

- [ ] **Step 3: Write minimal implementation**

Create `sidecar/exemplars.py`:

```python
"""Exemplar corpus reader for the Studio Agent vision sidecar.

Serves curated reference images per rubric category for evaluate's visual (calibration) grading.
Reads sidecar/exemplars/manifest.json + the referenced PNGs; returns metadata (+ base64 image when
requested). The manifest IS the store; scripts/validate_exemplars.py enforces clean licensing before
anything lands here. Pure standard library.
"""

from __future__ import annotations

import base64
import json
import os

_PUBLIC_FIELDS = ("id", "category", "caption", "tier", "license", "source", "criterion_id")


def exemplars_dir() -> str:
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "exemplars")


def manifest_path() -> str:
    return os.path.join(exemplars_dir(), "manifest.json")


def load_manifest():
    """The manifest's exemplar list, or [] if missing/unreadable/malformed."""
    try:
        with open(manifest_path(), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return []
    exemplars = data.get("exemplars") if isinstance(data, dict) else None
    return exemplars if isinstance(exemplars, list) else []


def exemplars_for(category, want_b64=False):
    """Manifest entries for `category` as dicts of the public fields (+ base64 `image` when want_b64
    and the file reads). Entries whose file is missing are skipped when want_b64."""
    out = []
    for ex in load_manifest():
        if not isinstance(ex, dict) or ex.get("category") != category:
            continue
        entry = {k: ex.get(k) for k in _PUBLIC_FIELDS}
        if want_b64:
            rel = ex.get("file")
            if not isinstance(rel, str):
                continue
            try:
                with open(os.path.join(exemplars_dir(), rel), "rb") as f:
                    entry["image"] = base64.b64encode(f.read()).decode("ascii")
            except OSError:
                continue
        out.append(entry)
    return out
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python sidecar/test_exemplars.py`
Expected: `=== ALL PASS ===`, exit 0.

- [ ] **Step 5: Add the `/exemplars` route to the server**

In `sidecar/server.py`: add `import exemplars` next to `import capture` (top of the imports block, line ~20). Extend the module docstring (after the `/captures` line, ~line 3) with:

```
GET  /exemplars?category=<cat>[&b64=1]        -> {"exemplars":[...],"returned":N}
```

In `do_GET` (after the `if parsed.path == "/captures":` block, ~line 53) add:

```python
        if parsed.path == "/exemplars":
            return self._exemplars(qs)
```

Add the handler method next to `_captures` (after `_captures`, ~line 100):

```python
    def _exemplars(self, qs):
        category = qs.get("category", [""])[0]
        want_b64 = qs.get("b64", ["0"])[0] in ("1", "true")
        try:
            items = exemplars.exemplars_for(category, want_b64=want_b64)
        except Exception as exc:  # noqa: BLE001
            return self._json(500, {"error": str(exc)})
        self._json(200, {"exemplars": items, "returned": len(items)})
```

- [ ] **Step 6: Verify the server still imports and the route is wired**

Run (from the repo root): `python -c "import sys; sys.path.insert(0, 'sidecar'); import server"`
Expected: no output, exit 0 (clean import — confirms `import exemplars` resolves and there's no syntax error). `server.py` uses bare imports (`import capture`, `import exemplars`), so it must be imported with `sidecar/` on `sys.path`, not as `sidecar.server`.

- [ ] **Step 7: Commit**

```bash
git add sidecar/exemplars.py sidecar/test_exemplars.py sidecar/server.py
git commit -m "feat(sidecar): exemplar manifest reader + GET /exemplars endpoint

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Exemplar manifest validator

**Files:**
- Create: `scripts/validate_exemplars.py`
- Test: `scripts/test_validate_exemplars.py`

- [ ] **Step 1: Write the failing test**

Create `scripts/test_validate_exemplars.py`:

```python
"""Dependency-free tests for validate_exemplars.validate(). Run: python scripts/test_validate_exemplars.py"""
import sys

import validate_exemplars as v


def _check(name, cond):
    print(("  PASS  " if cond else "  FAIL  ") + name)
    return 0 if cond else 1


def main():
    fails = 0
    known = {"environment": {"env-foliage"}, "gui": {"gui-anchor"}}
    def exists(rel):
        return rel in ("environment/a.png", "gui/b.png")

    good = [{"id": "e1", "category": "environment", "file": "environment/a.png",
             "license": "own", "criterion_id": "env-foliage", "tier": "exceptional"}]
    ok, _ = v.validate(good, known, exists)
    fails += _check("a clean entry validates", ok)

    ok, _ = v.validate([{"id": "e2", "category": "environment", "file": "environment/a.png",
                         "license": "copyrighted"}], known, exists)
    fails += _check("copyrighted license rejected", not ok)

    ok, _ = v.validate([{"id": "e3", "category": "nope", "file": "environment/a.png",
                         "license": "own"}], known, exists)
    fails += _check("unknown category rejected", not ok)

    ok, _ = v.validate([{"id": "e4", "category": "gui", "file": "gui/missing.png",
                         "license": "cc0"}], known, exists)
    fails += _check("missing file rejected", not ok)

    ok, _ = v.validate([{"id": "d", "category": "gui", "file": "gui/b.png", "license": "own"},
                        {"id": "d", "category": "gui", "file": "gui/b.png", "license": "own"}], known, exists)
    fails += _check("duplicate id rejected", not ok)

    ok, _ = v.validate([{"id": "e5", "category": "gui", "file": "gui/b.png", "license": "own",
                         "criterion_id": "no-such"}], known, exists)
    fails += _check("criterion_id not in category rejected", not ok)

    print(f"=== {('ALL PASS' if fails == 0 else str(fails) + ' FAILED')} ===")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python scripts/test_validate_exemplars.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'validate_exemplars'`.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/validate_exemplars.py`:

```python
"""Stdlib validator for the exemplar manifest (sidecar/exemplars/manifest.json).

Enforces: unique ids; category matches a known rubric module; file exists under exemplars/; license in
{own, official, cc0} (copyrighted is NEVER storable); optional criterion_id resolves to a real criterion
of that category; optional tier in {baseline, good, exceptional}.
"""
import glob
import json
import os
import sys

LICENSES = {"own", "official", "cc0"}
TIERS = {"baseline", "good", "exceptional"}
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXEMPLARS_DIR = os.path.join(REPO, "sidecar", "exemplars")
RUBRICS_DIR = os.path.join(REPO, "docs", "superpowers", "rubrics")


def known_criteria():
    """{category: set(criterion_id)} from docs/superpowers/rubrics/*.rubric.json."""
    out = {}
    for path in glob.glob(os.path.join(RUBRICS_DIR, "*.rubric.json")):
        try:
            with open(path, encoding="utf-8") as f:
                r = json.load(f)
        except (OSError, ValueError):
            continue
        module = r.get("module")
        if isinstance(module, str):
            out[module] = {c.get("id") for c in r.get("criteria", []) if isinstance(c, dict)}
    return out


def validate(exemplars, known, file_exists):
    errors = []
    seen = set()
    for i, ex in enumerate(exemplars):
        if not isinstance(ex, dict):
            errors.append(f"exemplar {i} is not an object")
            continue
        cid = ex.get("id")
        if not cid or cid in seen:
            errors.append(f"exemplar {i}: missing/duplicate id: {cid}")
        seen.add(cid)
        cat = ex.get("category")
        if cat not in known:
            errors.append(f"{cid}: unknown category '{cat}'")
        if ex.get("license") not in LICENSES:
            errors.append(f"{cid}: license must be one of {sorted(LICENSES)} (got '{ex.get('license')}')")
        rel = ex.get("file")
        if not isinstance(rel, str) or not file_exists(rel):
            errors.append(f"{cid}: file '{rel}' does not exist under exemplars/")
        crit = ex.get("criterion_id")
        if crit is not None and crit not in known.get(cat, set()):
            errors.append(f"{cid}: criterion_id '{crit}' not a criterion of '{cat}'")
        tier = ex.get("tier")
        if tier is not None and tier not in TIERS:
            errors.append(f"{cid}: bad tier '{tier}'")
    return (not errors), errors


def main():
    manifest = os.path.join(EXEMPLARS_DIR, "manifest.json")
    with open(manifest, encoding="utf-8") as f:
        data = json.load(f)
    items = data.get("exemplars", []) if isinstance(data, dict) else []
    ok, errors = validate(
        items, known_criteria(),
        lambda rel: os.path.isfile(os.path.join(EXEMPLARS_DIR, rel)),
    )
    if ok:
        print(f"VALID: {manifest} ({len(items)} exemplars)")
        sys.exit(0)
    print(f"INVALID: {manifest}")
    for e in errors:
        print("  -", e)
    sys.exit(1)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python scripts/test_validate_exemplars.py`
Expected: `=== ALL PASS ===`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/validate_exemplars.py scripts/test_validate_exemplars.py
git commit -m "feat(scripts): exemplar manifest validator (clean-license + category/criterion checks)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `ExemplarEvidence` Luau module + spec

**Files:**
- Create: `src/ExemplarEvidence.luau`
- Create: `src/ExemplarEvidenceSpec.luau`

- [ ] **Step 1: Write the spec (the failing test, run in-Studio at the dogfood)**

Create `src/ExemplarEvidenceSpec.luau`:

```lua
--!strict
-- ExemplarEvidenceSpec: in-Studio self-test for the PURE ExemplarEvidence.buildExemplarBlocks (no
-- DataModel / HTTP). Run via temporarily adding `require(script.ExemplarEvidenceSpec).run()` to
-- init.server.luau, like GuiEvidenceSpec.

local ExemplarEvidence = require(script.Parent.ExemplarEvidence)

local M = {}
type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("empty/absent payload -> {}", function()
		return #ExemplarEvidence.buildExemplarBlocks(nil) == 0
			and #ExemplarEvidence.buildExemplarBlocks({}) == 0
			and #ExemplarEvidence.buildExemplarBlocks({ exemplars = {} }) == 0
	end)

	add("one exemplar -> a text label + an image block", function()
		local blocks = ExemplarEvidence.buildExemplarBlocks({
			exemplars = {
				{ caption = "crafted slope", tier = "exceptional", source = "own", image = "QUJD" },
			},
		})
		if #blocks ~= 2 then
			return false, "want 2 blocks, got " .. #blocks
		end
		if blocks[1].type ~= "text" then
			return false, "block1 not text"
		end
		if string.find(blocks[1].text, "exceptional", 1, true) == nil then
			return false, "tier missing: " .. blocks[1].text
		end
		if string.find(blocks[1].text, "crafted slope", 1, true) == nil then
			return false, "caption missing"
		end
		if blocks[2].type ~= "image" or blocks[2].source.data ~= "QUJD" then
			return false, "image block wrong"
		end
		return true
	end)

	add("entry without an image is skipped", function()
		local blocks = ExemplarEvidence.buildExemplarBlocks({
			exemplars = { { caption = "no image", tier = "good" }, { caption = "ok", image = "QQ" } },
		})
		return #blocks == 2 and blocks[2].source.data == "QQ"
	end)

	add("missing tier defaults to 'reference'", function()
		local blocks = ExemplarEvidence.buildExemplarBlocks({ exemplars = { { image = "QQ" } } })
		return #blocks == 2 and string.find(blocks[1].text, "reference", 1, true) ~= nil
	end)

	return cases
end

function M.run(): boolean
	local cases = buildCases()
	local passed = 0
	for _, c in ipairs(cases) do
		local ok, err = c.fn()
		if ok then
			passed += 1
			print("[ExemplarEvidenceSpec] PASS " .. c.name)
		else
			warn("[ExemplarEvidenceSpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[ExemplarEvidenceSpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
```

- [ ] **Step 2: Write the implementation**

Create `src/ExemplarEvidence.luau`:

```lua
--!strict
-- ExemplarEvidence: VISUAL evidence for evaluate's grader. Fetches a category's curated exemplar images
-- from the sidecar (GET /exemplars) and captures the subject build (reusing CaptureCore), returning
-- labeled Anthropic content blocks (text label + base64 image). PURE buildExemplarBlocks is unit-tested
-- (ExemplarEvidenceSpec); the impure fetchExemplars / captureSubject are live-verified. Every path
-- returns (nil, err) on failure so evaluate degrades to the text-only grade. Calibration anchoring: the
-- images make the bar concrete; the per-criterion rubric text stays the spine.

local HttpService = game:GetService("HttpService")

local CaptureCore = require(script.Parent.Tools.CaptureCore)

local ExemplarEvidence = {}

-- ---- pure ----

-- Decode a /exemplars payload ({ exemplars = { {caption,tier,source,image}, ... } }) into alternating
-- text-label + image content blocks. Entries without an image are skipped. {} if none/malformed.
function ExemplarEvidence.buildExemplarBlocks(payload: any): { any }
	local blocks: { any } = {}
	if type(payload) ~= "table" or type(payload.exemplars) ~= "table" then
		return blocks
	end
	for _, ex in payload.exemplars do
		if type(ex) == "table" then
			local data = if type(ex.image) == "string"
				then (string.gsub(ex.image, "%s", ""))
				else ""
			if data ~= "" then
				local tier = if type(ex.tier) == "string" and ex.tier ~= ""
					then ex.tier
					else "reference"
				local caption = if type(ex.caption) == "string" then ex.caption else ""
				local source = if type(ex.source) == "string" and ex.source ~= ""
					then " (" .. ex.source .. ")"
					else ""
				table.insert(blocks, {
					type = "text",
					text = "EXEMPLAR [" .. tier .. "] — " .. caption .. source,
				})
				table.insert(blocks, {
					type = "image",
					source = { type = "base64", media_type = "image/png", data = data },
				})
			end
		end
	end
	return blocks
end

-- ---- impure ----

-- GET /exemplars?category=..&b64=1 and build the labeled image blocks. (nil, err) on any failure.
function ExemplarEvidence.fetchExemplars(category: string, config: any): ({ any }?, string?)
	if config == nil then
		return nil, "no config (sidecar url) available"
	end
	local url = config:getSidecarUrl()
		.. "/exemplars?b64=1&category="
		.. HttpService:UrlEncode(category)
	local ok, res = pcall(function()
		return HttpService:RequestAsync({ Url = url, Method = "GET" })
	end)
	if not ok then
		return nil, "could not reach the sidecar for exemplars: " .. tostring(res)
	end
	local response = res :: any
	if not response.Success then
		return nil, "sidecar /exemplars returned HTTP " .. tostring(response.StatusCode)
	end
	local okDecode, payload = pcall(function()
		return HttpService:JSONDecode(response.Body)
	end)
	if not okDecode then
		return nil, "could not decode the /exemplars response"
	end
	local blocks = ExemplarEvidence.buildExemplarBlocks(payload)
	if #blocks == 0 then
		return nil, "no exemplars for category '" .. category .. "'"
	end
	return blocks, nil
end

-- Frame + capture the subject (one beauty shot) -> one image block. (nil, err) on any failure. Reuses
-- CaptureCore (aabbOf + save/frame/capture/restore + sidecar fetch), like the `capture` tool.
function ExemplarEvidence.captureSubject(subject: Instance?, config: any): ({ any }?, string?)
	if config == nil then
		return nil, "no config (sidecar url) available"
	end
	if subject == nil then
		return nil, "no subject to capture"
	end
	local center, size = CaptureCore.aabbOf({ subject :: Instance })
	if center == nil or size == nil then
		return nil, "subject has no parts to frame (no BasePart found)"
	end
	local saved = CaptureCore.saveCamera()
	local since = os.time() - 2
	local triggered = false
	local okAll = pcall(function()
		CaptureCore.setCamera(
			CaptureCore.frameCFrame(center :: Vector3, size :: Vector3, 35, 20, 1)
		)
		CaptureCore.settle(2)
		triggered = CaptureCore.triggerCapture()
	end)
	CaptureCore.restoreCamera(saved)
	if not okAll or not triggered then
		return nil, "could not capture the subject (camera restored)"
	end
	local blocks, err = CaptureCore.fetchCaptures(1, since, config)
	if blocks == nil then
		return nil, err
	end
	return blocks, nil
end

return ExemplarEvidence
```

- [ ] **Step 3: Static gate (the per-task verification for Luau)**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: `stylua` reformats nothing new, `selene` reports `Results: 0 errors 0 warnings`, `rojo build` writes `StudioAgent.rbxm` with no error. (The spec runs in-Studio at Task 7.)

- [ ] **Step 4: Commit**

```bash
git add src/ExemplarEvidence.luau src/ExemplarEvidenceSpec.luau
git commit -m "feat: ExemplarEvidence — fetch exemplar images + capture subject for visual grading

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Fold visual evidence into `evaluate`

**Files:**
- Modify: `src/Tools/Evaluate.luau`

- [ ] **Step 1: Require ExemplarEvidence**

In `src/Tools/Evaluate.luau`, after the `local EnvEvidence = require(script.Parent.Parent.EnvEvidence)` line (~line 16), add:

```lua
local ExemplarEvidence = require(script.Parent.Parent.ExemplarEvidence)
```

- [ ] **Step 2: Add the visual-calibration instruction constant**

Immediately after the existing `local INSTRUCTION = ...` block (it ends `.. "criterion id."`, ~line 147), add:

```lua
local VISUAL_INSTRUCTION = "You are ALSO shown the build's own screenshot and reference images of GREAT "
	.. "work in this category. Use the references to CALIBRATE the bar for the visually-anchorable "
	.. "criteria (composition, material/lighting craft, layout/typography, pose readability) and judge "
	.. "the build's screenshot against that bar. Do NOT grade by visual similarity to any single "
	.. "reference image — the per-criterion rubric text remains the spine; the images make the bar concrete."
```

- [ ] **Step 3: Rename the assembled string to `text` and assemble array `content`**

Find the block that builds `local content = INSTRUCTION .. "\n\n=== RUBRIC ===\n" .. ...` (ends with the learnings ternary, ~lines 196–208). Rename that local from `content` to `text` (change only the `local content =` on the first line to `local text =`). Then, immediately after that assembled `text` block and BEFORE `local gradeTool = EvaluateReport.buildGradeTool(rubric)`, insert:

```lua
	-- Visual evidence (calibration anchoring): the build's own capture + curated exemplar images, folded
	-- into the SAME grade call. Best-effort — ANY failure degrades to the text-only grade (no hard fail).
	local cfg = if type(context) == "table" then context.config else nil
	local wantCapture = not (type(args) == "table" and args.capture == false)
	local imageBlocks: { any } = {}
	if cfg ~= nil then
		if wantCapture then
			local buildBlocks = ExemplarEvidence.captureSubject(subject, cfg)
			if buildBlocks ~= nil and #buildBlocks > 0 then
				table.insert(imageBlocks, {
					type = "text",
					text = "\n=== AGENT'S BUILD (live capture — grade what you SEE) ===",
				})
				for _, b in buildBlocks do
					table.insert(imageBlocks, b)
				end
			end
		end
		local exemplarBlocks = ExemplarEvidence.fetchExemplars(args.category, cfg)
		if exemplarBlocks ~= nil and #exemplarBlocks > 0 then
			table.insert(imageBlocks, {
				type = "text",
				text = "\n=== REFERENCE: what GREAT looks like in this category "
					.. "(calibrate the BAR to these; do NOT grade by similarity to any single image) ===",
			})
			for _, b in exemplarBlocks do
				table.insert(imageBlocks, b)
			end
		end
	end

	-- With images present, prepend the visual-calibration instruction and send ARRAY content; otherwise
	-- send the text-only path exactly as before (a plain string).
	local content: any = text
	if #imageBlocks > 0 then
		local blocks: { any } = { { type = "text", text = VISUAL_INSTRUCTION .. "\n\n" .. text } }
		for _, b in imageBlocks do
			table.insert(blocks, b)
		end
		content = blocks
	end
```

The existing `requestStructured` call already passes `content = content` — leave it; `content` is now either the string (degrade) or the blocks array (visual).

- [ ] **Step 4: Add the `capture` input to the descriptor**

In the `evaluate` descriptor's `inputSchema.properties` (after the `design = { ... }` property, ~line 279), add:

```lua
					capture = {
						type = "boolean",
						description = "Capture the subject and grade it VISUALLY against curated exemplar images (default true). Set false for a text-only grade (e.g. no sidecar / purely architectural checks).",
					},
```

Also append to the descriptor `description` string (after "address them and re-evaluate."): ` It also CAPTURES the subject and shows the grader curated reference images of great work, so visually-anchorable craft is judged on what it SEES (set capture=false to skip).`

- [ ] **Step 5: Static gate**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: `selene` 0 errors / 0 warnings; `rojo build` writes the rbxm cleanly.

- [ ] **Step 6: Commit**

```bash
git add src/Tools/Evaluate.luau
git commit -m "feat(evaluate): fold visual evidence (build capture + exemplars) into the grade call

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: SystemPrompt nudge

**Files:**
- Modify: `src/SystemPrompt.luau`

- [ ] **Step 1: Extend the "Evaluating against the rubric" section**

In `src/SystemPrompt.luau`, the "# Evaluating against the rubric (close the loop)" paragraph (line ~92) ends with `...evaluate weighs the actual structure over your claims.` Append to that same line:

```
 evaluate now also SHOWS the grader the build: it captures your subject and grades that screenshot against curated REFERENCE images of great work in the category — it calibrates the visual bar (it does NOT reward copying any image), so your craft (composition, materials/lighting, layout/typography, pose readability) is judged on what it looks like, not just claims. For SOURCING study you MAY web_fetch copyrighted references to learn the METHOD, but never store or reproduce them — technique, not expression.
```

- [ ] **Step 2: Static gate**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: `selene` 0/0; `rojo build` clean.

- [ ] **Step 3: Commit**

```bash
git add src/SystemPrompt.luau
git commit -m "feat(prompt): nudge the agent to evaluate visually + study copyright as method-only

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Seed corpus (≥1 real exemplar) + validate

> **Gate to enter this task:** Tasks 3–5 changed plugin code → run `.\build.ps1`, then **ask the USER to restart Studio** ("Restart to update"). Task 1 changed `sidecar/server.py` → **restart the sidecar** so `/exemplars` is live (re-run the sidecar from `scripts/studio-agent.ps1`'s start path, or ask the user). Confirm both are up before proceeding.

**Files:**
- Create: `sidecar/exemplars/manifest.json`
- Create: `sidecar/exemplars/environment/<id>.png` (and `gui/<id>.png` if time permits)

- [ ] **Step 1: Build a crafted seed subject (environment) via the bridge**

Drive `scripts/studio-agent.ps1` to build a deliberately *good* small environment scene (varied non-Plastic materials, a placed light, Atmosphere + a post-effect, eye-level composition) — this is the "great" reference, so make it clearly above-generic. Keep any Luau ASCII-only (write a temp `.lua` for multi-line). Select the scene's root model.

- [ ] **Step 2: Capture it and save the PNG to the exemplar folder**

Trigger a capture (the `capture` tool, or a framed `capture` of the selection), then fetch the newest frame as base64 from the sidecar and write it to disk. From the PowerShell tool:

```powershell
New-Item -ItemType Directory -Force sidecar/exemplars/environment | Out-Null
$r = Invoke-RestMethod "http://127.0.0.1:8389/captures?count=1&b64=1&since=0"
[IO.File]::WriteAllBytes("$PWD/sidecar/exemplars/environment/env-crafted-scene.png",
  [Convert]::FromBase64String($r.images[-1]))
```

Verify the PNG opens (Read it as an image) and clearly shows the crafted scene.

- [ ] **Step 3: Write the manifest**

Create `sidecar/exemplars/manifest.json` (add a `gui` entry too if you also captured one; the validator and reader tolerate any subset of categories):

```json
{
  "version": 1,
  "exemplars": [
    {
      "id": "env-crafted-scene",
      "category": "environment",
      "file": "environment/env-crafted-scene.png",
      "license": "own",
      "source": "agent-seed (built + captured via the bridge, 2026-06-23)",
      "caption": "Eye-level composition; varied crafted materials, a placed light, Atmosphere + post-processing — above the flat-Plastic greybox default.",
      "criterion_id": null,
      "tier": "good"
    }
  ]
}
```

- [ ] **Step 4: Validate the manifest**

Run: `python scripts/validate_exemplars.py`
Expected: `VALID: ...manifest.json (1 exemplars)` (or N), exit 0. If it reports an unknown category/criterion or a missing file, fix the manifest/file and re-run.

- [ ] **Step 5: Confirm the endpoint serves it (sidecar must be restarted from the gate above)**

Run:

```powershell
(Invoke-RestMethod "http://127.0.0.1:8389/exemplars?category=environment&b64=1").returned
```

Expected: `1` (or N) — and the response carries a base64 `image`. If `0`, the sidecar wasn't restarted after Task 1, or the manifest path/category is wrong.

- [ ] **Step 6: Commit**

```bash
git add sidecar/exemplars/manifest.json sidecar/exemplars/environment
git commit -m "feat(exemplars): seed corpus (environment crafted-scene reference, license=own)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Bridge dogfood — the acceptance gate

**Files:** none (live verification + the in-Studio spec run + HANDOFF update).

> Requires the Task-6 gate satisfied (plugin rebuilt + USER-restarted; sidecar restarted; seed manifest serving). Verify by LOOKING at the result, never by trusting coordinates.

- [ ] **Step 1: Run the pure spec in-Studio**

Temporarily add `require(script.ExemplarEvidenceSpec).run()` to `init.server.luau` (alongside how other specs are run), `.\build.ps1`, ask the USER to restart, and read the output. Expected: `[ExemplarEvidenceSpec] 4/4 passed`. **Revert** the temporary require afterward (and rebuild) so `init.server.luau` is clean.

- [ ] **Step 2: Build a deliberately MEDIOCRE environment subject**

Via the bridge, build a bare greybox scene (a few flat-Plastic parts, default lighting, no atmosphere/post, no composition). Select it. This is the thing under test — it should clearly fall short of the seed exemplar.

- [ ] **Step 3: Evaluate WITHOUT the visual pass (baseline)**

Run `evaluate {category:"environment", design:"A small outdoor scene.", capture:false}` through the bridge (generous timeout, e.g. 200000 — a real grade is >30s). Save the rendered report. This is the text-only baseline.

- [ ] **Step 4: Evaluate WITH the visual pass**

Run `evaluate {category:"environment", design:"A small outdoor scene."}` (capture defaults true). The bridge `tool` result text won't show the images, but the grade reflects them. Save this report.

- [ ] **Step 5: Confirm the images moved the grade (the gate)**

Compare the two reports. PASS requires BOTH:
  1. The visual report **cites something visible in the capture** that the text-only path could not infer from structure/claim alone (e.g. "the scene reads flat / lacks the crafted material contrast and atmospheric depth of the reference") — evidence the grader actually used the pixels.
  2. At least one **visually-anchorable criterion shifts** between the two reports (tier change or materially different cited evidence).
If neither holds, debug (is the capture reaching the call? are exemplars fetched? — add a temporary `print` of `#imageBlocks` in `runEvaluate`, rebuild, retry) before claiming success. Filmstrip note: to view what the grader saw, fetch `GET /captures?count=N&b64=1` and Read the PNGs.

- [ ] **Step 6: Confirm graceful degrade**

Temporarily point the manifest at an empty category (or rename the seed PNG) and run `evaluate {category:"environment", design:"..."}` — confirm it returns a normal structured report (text-only path), no error. Restore the manifest/file afterward. Then confirm `capture:false` also returns the clean text-only report.

- [ ] **Step 7: Clean up + final commit**

Destroy the test subjects built in Steps 2/6 (leave the user's `Rig` and `UAL2_Standard` models alone). Confirm `init.server.luau` is back to clean (no temp require) and `selene src` is 0/0. Update `HANDOFF.md` (a new START-HERE block summarizing: exemplar-image anchoring SHIPPED + bridge-verified; the with/without grade-shift evidence; the seed corpus + drop-in curation workflow; NEXT options). Commit:

```bash
git add HANDOFF.md
git commit -m "docs: exemplar-image anchoring shipped + bridge-verified (visual evaluate live)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review notes (for the executor)

- **Spec coverage:** §3a/§3b storage+manifest → Tasks 1 & 6; §3c calibration grading → Task 4 (`VISUAL_INSTRUCTION`, no similarity scoring); §3d evaluate flow + degrade → Task 4; §4 components → Tasks 1–5; §5 seed+curation → Task 6; §7 acceptance gate → Task 7; licensing enforcement → Task 2.
- **Type/name consistency:** `exemplars_for(category, want_b64)`, `buildExemplarBlocks(payload)`, `fetchExemplars(category, config)`, `captureSubject(subject, config)`, `validate(exemplars, known, file_exists)`, `known_criteria()` — used identically across tasks and tests. The endpoint response key is `exemplars`/`returned`; the per-image fields are `id, category, caption, tier, license, source, criterion_id, image`. Image blocks are `{type="image", source={type="base64", media_type="image/png", data=...}}` (matches `CaptureCore.fetchCaptures`).
- **Degrade invariant:** `evaluate` only builds array content when `#imageBlocks > 0`; otherwise `content` stays the original string — today's behavior is untouched when the sidecar/exemplars are absent or `capture=false`.
