# Evaluate GUI structural evidence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make `evaluate`'s structural dump category-capable so `evaluate gui` (and future non-animation categories) grades on real GUI structure instead of the animation-only census.

**Architecture:** A new PURE-ish `src/GuiEvidence.luau` censuses UI classes under a subject and summarizes per-element layout quality (scale-vs-offset, AnchorPoint, layouts, UICorner/UIPadding, constraints). `Tools/Evaluate.luau`'s `gatherStructural` appends `GuiEvidence.gather(subject)` when GUI is present — category-agnostic, no regression to animation evaluate. Pure helpers (`usesScale`, `summarizeLayout`) are unit-tested.

**Tech Stack:** Luau (`--!strict`). No local Luau execution — verify with `selene`/`stylua`/`rojo build` + an in-Studio pure spec. **Build/restart is BATCHED with the GUI rubric onboarding** (don't restart for this alone).

---

## Reference facts
- `src/Tools/Evaluate.luau` `gatherStructural(subject)` builds a `parts` list: a class census (`CLASSES_OF_INTEREST` = Humanoid/Animator/AnimationController/IKControl/AnimationConstraint/Motor6D) starting with `table.insert(parts, "Subject " .. subject:GetFullName() .. ": " .. ...)`, then dumps capped script source. It is the impure evidence-gatherer behind `evaluate`. `Tools/Evaluate.luau` is at `src/Tools/`, so a sibling-of-`AnimationClip` module is `require(script.Parent.Parent.GuiEvidence)`.
- Existing pure+impure module pattern to mirror: `src/CaptureCore.luau`, `src/AnimationImport.luau` (pure helpers + impure gather; pure parts spec'd in a `*Spec.luau` run in-Studio).
- `UIConstraint` is the base class of `UIAspectRatioConstraint`/`UISizeConstraint`/`UITextSizeConstraint` (so `c:IsA("UIConstraint")` catches them). `UICorner`/`UIPadding`/`UIListLayout` are NOT UIConstraints — match by ClassName.

---

## File structure
| File | New/Mod | Responsibility |
|---|---|---|
| `src/GuiEvidence.luau` | **new** | Pure `usesScale`/`summarizeLayout` + impure `gather(subject)`. |
| `src/GuiEvidenceSpec.luau` | **new** | Pure spec for `usesScale` + `summarizeLayout`. |
| `src/Tools/Evaluate.luau` | mod | `gatherStructural` appends `GuiEvidence.gather(subject)` when non-empty. |

---

## Task 1: `GuiEvidence.luau` + pure spec

**Files:** Create `src/GuiEvidence.luau`, `src/GuiEvidenceSpec.luau`.

- [ ] **Step 1: Write `src/GuiEvidence.luau`**

```lua
--!strict
-- GuiEvidence: structural evidence for GUI/UI subjects, for evaluate's grader. PURE helpers (scale-vs-offset
-- detection, the layout summary) are unit-tested; the impure gather() walks a subject's GuiObjects + UI
-- classes. Mirrors the capture/animation pure+impure split. Lets evaluate grade non-animation categories
-- (e.g. gui) on real structure instead of the animation-only census. "" when the subject has no GUI.

local GuiEvidence = {}

local UI_CLASSES = {
	"Frame",
	"TextLabel",
	"TextButton",
	"ImageLabel",
	"ImageButton",
	"ScrollingFrame",
	"TextBox",
	"UIListLayout",
	"UIGridLayout",
	"UIPageLayout",
	"UITableLayout",
	"UIPadding",
	"UICorner",
	"UIAspectRatioConstraint",
	"UISizeConstraint",
	"UIStroke",
	"UIGradient",
	"UIScale",
}

local UI_SET: { [string]: boolean } = {}
for _, c in UI_CLASSES do
	UI_SET[c] = true
end

local LAYOUT_CLASSES: { [string]: boolean } =
	{ UIListLayout = true, UIGridLayout = true, UIPageLayout = true, UITableLayout = true }

local MAX_ELEMENTS = 60 -- cap the per-element walk

export type Fact = {
	scaleSize: boolean,
	scalePos: boolean,
	anchor: boolean,
	layout: boolean,
	corner: boolean,
	padding: boolean,
	constraint: boolean,
}

-- ---- pure ----

-- A UDim2 axis "uses scale" if either scale component is non-zero (responsive vs fixed-offset).
function GuiEvidence.usesScale(scaleX: number, scaleY: number): boolean
	return scaleX ~= 0 or scaleY ~= 0
end

-- Summarize a list of element facts into a one-paragraph evidence line. "" if no facts.
function GuiEvidence.summarizeLayout(facts: { Fact }): string
	local n = #facts
	if n == 0 then
		return ""
	end
	local scaleSize, scalePos, anchor, layout, corner, padding, constraint = 0, 0, 0, 0, 0, 0, 0
	for _, f in facts do
		if f.scaleSize then
			scaleSize += 1
		end
		if f.scalePos then
			scalePos += 1
		end
		if f.anchor then
			anchor += 1
		end
		if f.layout then
			layout += 1
		end
		if f.corner then
			corner += 1
		end
		if f.padding then
			padding += 1
		end
		if f.constraint then
			constraint += 1
		end
	end
	return string.format(
		"GUI layout (of %d elements sampled): %d use scale-based Size, %d scale-based Position (vs offset-only); "
			.. "%d set AnchorPoint; %d have a UIListLayout/UIGridLayout; %d have UICorner; %d have UIPadding; "
			.. "%d have a UI constraint (aspect/size).",
		n,
		scaleSize,
		scalePos,
		anchor,
		layout,
		corner,
		padding,
		constraint
	)
end

-- ---- impure ----

-- Census the UI classes under the subject + summarize per-element layout quality. "" if no GUI present.
function GuiEvidence.gather(subject: Instance): string
	local census: { [string]: number } = {}
	local guiCount = 0
	for _, d in subject:GetDescendants() do
		if UI_SET[d.ClassName] then
			census[d.ClassName] = (census[d.ClassName] or 0) + 1
			guiCount += 1
		end
	end
	if guiCount == 0 then
		return ""
	end
	local facts: { Fact } = {}
	for _, d in subject:GetDescendants() do
		if #facts >= MAX_ELEMENTS then
			break
		end
		if d:IsA("GuiObject") then
			local obj = d :: GuiObject
			local hasLayout, hasCorner, hasPadding, hasConstraint = false, false, false, false
			for _, c in (d :: Instance):GetChildren() do
				if LAYOUT_CLASSES[c.ClassName] then
					hasLayout = true
				end
				if c.ClassName == "UICorner" then
					hasCorner = true
				end
				if c.ClassName == "UIPadding" then
					hasPadding = true
				end
				if c:IsA("UIConstraint") then
					hasConstraint = true
				end
			end
			table.insert(facts, {
				scaleSize = GuiEvidence.usesScale(obj.Size.X.Scale, obj.Size.Y.Scale),
				scalePos = GuiEvidence.usesScale(obj.Position.X.Scale, obj.Position.Y.Scale),
				anchor = obj.AnchorPoint.X ~= 0 or obj.AnchorPoint.Y ~= 0,
				layout = hasLayout,
				corner = hasCorner,
				padding = hasPadding,
				constraint = hasConstraint,
			})
		end
	end
	local cl: { string } = {}
	for k, v in census do
		table.insert(cl, k .. "=" .. tostring(v))
	end
	table.sort(cl)
	local parts: { string } = { "GUI classes: " .. table.concat(cl, ", ") }
	local summary = GuiEvidence.summarizeLayout(facts)
	if summary ~= "" then
		table.insert(parts, summary)
	end
	return table.concat(parts, "\n")
end

return GuiEvidence
```

- [ ] **Step 2: Write `src/GuiEvidenceSpec.luau`**

```lua
--!strict
-- GuiEvidenceSpec: in-Studio self-test for the PURE GuiEvidence helpers (no DataModel). Run via temporarily
-- adding `require(script.GuiEvidenceSpec).run()` to init.server.luau.

local GuiEvidence = require(script.Parent.GuiEvidence)

local M = {}
type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("usesScale: nonzero scale on either axis is responsive", function()
		return GuiEvidence.usesScale(0, 0) == false
			and GuiEvidence.usesScale(0.5, 0) == true
			and GuiEvidence.usesScale(0, 1) == true
	end)

	add("summarizeLayout empty -> ''", function()
		return GuiEvidence.summarizeLayout({}) == ""
	end)

	add("summarizeLayout counts facts and formats", function()
		local facts: { GuiEvidence.Fact } = {
			{
				scaleSize = true,
				scalePos = false,
				anchor = true,
				layout = true,
				corner = true,
				padding = false,
				constraint = false,
			},
			{
				scaleSize = false,
				scalePos = false,
				anchor = false,
				layout = false,
				corner = false,
				padding = true,
				constraint = true,
			},
		}
		local s = GuiEvidence.summarizeLayout(facts)
		if string.find(s, "of 2 elements sampled", 1, true) == nil then
			return false, "count: " .. s
		end
		if string.find(s, "1 use scale-based Size", 1, true) == nil then
			return false, "scaleSize: " .. s
		end
		if string.find(s, "1 have UICorner", 1, true) == nil then
			return false, "corner: " .. s
		end
		if string.find(s, "1 have UIPadding", 1, true) == nil then
			return false, "padding: " .. s
		end
		return true
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
			print("[GuiEvidenceSpec] PASS " .. c.name)
		else
			warn("[GuiEvidenceSpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[GuiEvidenceSpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
```

- [ ] **Step 3: Static-verify** — `stylua src ; stylua --check src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm` (stylua clean; selene 0/0/0; build OK).

- [ ] **Step 4: Commit**
```
git add src/GuiEvidence.luau src/GuiEvidenceSpec.luau
git commit -m "feat: GuiEvidence -- structural GUI evidence (census + layout quality) for evaluate + pure spec" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: wire `GuiEvidence` into `Evaluate.gatherStructural`

**Files:** Modify `src/Tools/Evaluate.luau`.

- [ ] **Step 1: Require GuiEvidence.** Near the other top-of-file requires in `src/Tools/Evaluate.luau` (e.g. after `local EvaluateReport = require(script.Parent.Parent.EvaluateReport)`), add:
```lua
local GuiEvidence = require(script.Parent.Parent.GuiEvidence)
```

- [ ] **Step 2: Append GUI evidence in `gatherStructural`.** In `gatherStructural`, the `if subject ~= nil then ... end` block builds the animation class census and ends with `table.insert(parts, "Subject " .. subject:GetFullName() .. ": " .. (...))`. Immediately AFTER that `table.insert(...)` (still inside the `if subject ~= nil then` branch, before the matching `else`), add:
```lua
		local guiEv = GuiEvidence.gather(subject)
		if guiEv ~= "" then
			table.insert(parts, guiEv)
		end
```
(So a GUI subject now contributes its UI census + layout summary; an animation subject is unaffected — `gather` returns "" when no GUI is present. Do not change anything else.)

- [ ] **Step 3: Static-verify** — `stylua src ; stylua --check src ; selene src ; rojo build … ; echo done`.

- [ ] **Step 4: Commit**
```
git add src/Tools/Evaluate.luau
git commit -m "feat: evaluate folds GUI structural evidence in when the subject is a GUI" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## NOT in this plan (batched later)
- Build + install + Studio restart + dogfood (`evaluate gui` on a built GUI) — **done together with the GUI rubric onboarding** (the GUI rubric workflow is running; one restart dogfoods `use_rubric gui` + `evaluate gui` + the GuiEvidenceSpec). The temporary spec require + the live dogfood live in that onboarding step.

## Self-review
- **Coverage:** GUI census + per-element layout summary → `GuiEvidence.gather` (Task 1); pure scale/summary helpers + spec → Task 1; wired into evaluate, category-agnostic, no animation regression → Task 2. Build/dogfood explicitly deferred + batched.
- **Placeholders:** complete code; Task 2 names the exact insertion anchor (`table.insert(parts, "Subject ...")`). No TBDs.
- **Type consistency:** `GuiEvidence.usesScale`/`summarizeLayout`/`gather` + `Fact` type are consistent across the module, the spec, and the Evaluate call (`gather`).
