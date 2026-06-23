# Evaluate environment structural evidence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]`.

**Goal:** `evaluate environment` grades the material/lighting/performance criteria on real structure (not just the design claim), via an `EnvEvidence` gatherer that mirrors the shipped `GuiEvidence`.

**Architecture:** `src/EnvEvidence.luau` (pure `isDefaultMaterial`/`summarize` + impure `gather`) censuses a subject's BaseParts/meshes/models + material craft (non-Plastic ratio, SurfaceAppearance) + placed lights, and reads the global `Lighting` service (Atmosphere, Technology, post-effects). `gatherStructural` appends it when the subject has BaseParts (category-agnostic, like `GuiEvidence`; "" for a pure-GUI subject). Composition/visual criteria still lean on captures.

**Tech Stack:** Luau (`--!strict`). Verify with `selene`/`stylua`/`rojo build` + an in-Studio pure spec + a bridge dogfood. **Build/restart BATCHED into one dogfood** at the end.

---

## Reference facts
- `src/Tools/Evaluate.luau` `gatherStructural(subject)` builds a `parts` list (animation census + script source); this session it also appends `GuiEvidence.gather(subject)` when GUI is present (inside the `if subject ~= nil then` branch, before `else`). `EnvEvidence` is wired the same way. `Tools/Evaluate.luau` requires sibling-of-AnimationClip modules as `require(script.Parent.Parent.X)`.
- Mirror `src/GuiEvidence.luau` + `src/GuiEvidenceSpec.luau` (shipped this session) for the pure+impure split + spec shape.
- `Light` is the base class of PointLight/SpotLight/SurfaceLight (`d:IsA("Light")`). `Lighting.Technology` is an EnumItem (`.Name` → "Future"/"ShadowMap"/…). Post-effect classes: ColorCorrectionEffect/BloomEffect/SunRaysEffect/DepthOfFieldEffect/BlurEffect. `Atmosphere` is a child of Lighting.

---

## File structure
| File | New/Mod | Responsibility |
|---|---|---|
| `src/EnvEvidence.luau` | new | Pure `isDefaultMaterial`/`summarize` + impure `gather`. |
| `src/EnvEvidenceSpec.luau` | new | Pure spec. |
| `src/Tools/Evaluate.luau` | mod | `gatherStructural` appends `EnvEvidence.gather(subject)`. |

---

## Task 1: `EnvEvidence.luau` + pure spec

**Files:** Create `src/EnvEvidence.luau`, `src/EnvEvidenceSpec.luau`.

- [ ] **Step 1: Write `src/EnvEvidence.luau`**

```lua
--!strict
-- EnvEvidence: structural evidence for 3D ENVIRONMENT subjects, for evaluate's grader. Censuses the build's
-- BaseParts/meshes/models + material craft (non-default vs Plastic, SurfaceAppearance) + placed lights, and
-- reads the global Lighting service (Atmosphere, Technology, post-effects), so evaluate can grade the
-- material/lighting/performance criteria on real structure (composition/visual criteria still lean on
-- captures). Pure helpers unit-tested; impure gather() reads the DataModel. Mirrors GuiEvidence. "" when the
-- subject has no BaseParts (e.g. a pure GUI subject).

local Lighting = game:GetService("Lighting")

local EnvEvidence = {}

local DEFAULT_MATERIALS: { [string]: boolean } = { Plastic = true, SmoothPlastic = true }
local POST_EFFECTS: { [string]: boolean } = {
	ColorCorrectionEffect = true,
	BloomEffect = true,
	SunRaysEffect = true,
	DepthOfFieldEffect = true,
	BlurEffect = true,
}

export type Stats = {
	meshes: number,
	models: number,
	totalParts: number,
	craftedMat: number,
	surfaceAppearance: number,
	lights: number,
	atmosphere: boolean,
	technology: string,
	postEffects: number,
}

-- ---- pure ----

-- A material is "default" (the generic floor) if it is Plastic/SmoothPlastic (or empty).
function EnvEvidence.isDefaultMaterial(name: string): boolean
	return name == "" or DEFAULT_MATERIALS[name] == true
end

-- Format a stats record into a one-paragraph evidence line.
function EnvEvidence.summarize(s: Stats): string
	return string.format(
		"Environment structure: %d BaseParts (%d MeshParts, %d Models); materials: %d/%d parts use a crafted "
			.. "(non-Plastic) material, %d SurfaceAppearance; %d placed lights; lighting: Atmosphere=%s, "
			.. "Technology=%s, %d post-effects (ColorCorrection/Bloom/SunRays/DepthOfField/Blur).",
		s.totalParts,
		s.meshes,
		s.models,
		s.craftedMat,
		s.totalParts,
		s.surfaceAppearance,
		s.lights,
		(if s.atmosphere then "yes" else "no"),
		s.technology,
		s.postEffects
	)
end

-- ---- impure ----

-- Census the subject's parts/materials/lights + the global Lighting service. "" if no BaseParts.
function EnvEvidence.gather(subject: Instance): string
	local meshes, models, totalParts, craftedMat, surfaceAppearance, lights = 0, 0, 0, 0, 0, 0
	for _, d in subject:GetDescendants() do
		if d:IsA("BasePart") then
			totalParts += 1
			if d:IsA("MeshPart") then
				meshes += 1
			end
			if not EnvEvidence.isDefaultMaterial((d :: BasePart).Material.Name) then
				craftedMat += 1
			end
		elseif d:IsA("Model") then
			models += 1
		elseif d:IsA("SurfaceAppearance") then
			surfaceAppearance += 1
		elseif d:IsA("Light") then
			lights += 1
		end
	end
	if totalParts == 0 then
		return ""
	end
	local postEffects = 0
	for _, d in Lighting:GetChildren() do
		if POST_EFFECTS[d.ClassName] then
			postEffects += 1
		end
	end
	local stats: Stats = {
		meshes = meshes,
		models = models,
		totalParts = totalParts,
		craftedMat = craftedMat,
		surfaceAppearance = surfaceAppearance,
		lights = lights,
		atmosphere = Lighting:FindFirstChildOfClass("Atmosphere") ~= nil,
		technology = Lighting.Technology.Name,
		postEffects = postEffects,
	}
	return EnvEvidence.summarize(stats)
end

return EnvEvidence
```

- [ ] **Step 2: Write `src/EnvEvidenceSpec.luau`**

```lua
--!strict
-- EnvEvidenceSpec: in-Studio self-test for the PURE EnvEvidence helpers (no DataModel). Run via temporarily
-- adding `require(script.EnvEvidenceSpec).run()` to init.server.luau.

local EnvEvidence = require(script.Parent.EnvEvidence)

local M = {}
type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("isDefaultMaterial: Plastic/SmoothPlastic/empty default, others crafted", function()
		return EnvEvidence.isDefaultMaterial("Plastic") == true
			and EnvEvidence.isDefaultMaterial("SmoothPlastic") == true
			and EnvEvidence.isDefaultMaterial("") == true
			and EnvEvidence.isDefaultMaterial("Concrete") == false
			and EnvEvidence.isDefaultMaterial("Neon") == false
	end)

	add("summarize formats the stats", function()
		local s: EnvEvidence.Stats = {
			meshes = 4,
			models = 2,
			totalParts = 10,
			craftedMat = 7,
			surfaceAppearance = 1,
			lights = 3,
			atmosphere = true,
			technology = "Future",
			postEffects = 2,
		}
		local out = EnvEvidence.summarize(s)
		if string.find(out, "10 BaseParts (4 MeshParts, 2 Models)", 1, true) == nil then
			return false, "parts: " .. out
		end
		if string.find(out, "7/10 parts use a crafted", 1, true) == nil then
			return false, "crafted: " .. out
		end
		if string.find(out, "3 placed lights", 1, true) == nil then
			return false, "lights: " .. out
		end
		if string.find(out, "Atmosphere=yes, Technology=Future, 2 post-effects", 1, true) == nil then
			return false, "lighting: " .. out
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
			print("[EnvEvidenceSpec] PASS " .. c.name)
		else
			warn("[EnvEvidenceSpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[EnvEvidenceSpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
```

- [ ] **Step 3:** `stylua src ; stylua --check src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm` (stylua clean; selene 0/0/0; build OK).
- [ ] **Step 4:** Commit: `git add src/EnvEvidence.luau src/EnvEvidenceSpec.luau ; git commit -m "feat: EnvEvidence -- structural environment evidence (parts/materials/lighting) for evaluate + spec" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"`

---

## Task 2: wire into `Evaluate.gatherStructural`

**Files:** Modify `src/Tools/Evaluate.luau`.

- [ ] **Step 1:** Add the require near the other top-of-file requires (after `local GuiEvidence = require(script.Parent.Parent.GuiEvidence)`): `local EnvEvidence = require(script.Parent.Parent.EnvEvidence)`
- [ ] **Step 2:** In `gatherStructural`, immediately AFTER the existing GuiEvidence append (the `local guiEv = GuiEvidence.gather(subject) ... end` block, still inside the `if subject ~= nil then` branch), add:
```lua
		local envEv = EnvEvidence.gather(subject)
		if envEv ~= "" then
			table.insert(parts, envEv)
		end
```
- [ ] **Step 3:** `stylua src ; stylua --check src ; selene src ; rojo build … ; echo done`.
- [ ] **Step 4:** Commit: `git add src/Tools/Evaluate.luau ; git commit -m "feat: evaluate folds environment structural evidence in (parts/materials/lighting)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"`

---

## Dogfood (batched, after both tasks)
Temp-wire `require(script.EnvEvidenceSpec).run()` in `init.server.luau`; build + install; USER restart; `logs` → `[EnvEvidenceSpec] 2/2`; build a small environment (a few non-Plastic Parts + a PointLight + an Atmosphere in Lighting) + select it → `evaluate environment {design:"a small outdoor scene"}` → confirm a structured **N/28** report whose material/lighting criteria reflect the real structure (the EnvEvidence line), not just the claim. Revert the temp require; rebuild; HANDOFF + commit.

## Self-review
- Coverage: env census + material/lighting summary → `gather` (Task 1); pure helpers + spec → Task 1; wired category-agnostic, no regression → Task 2; dogfood batched. Mild note: `gather` also fires for a part-having rig (locomotion/combat subject) — harmless extra evidence the animation grader ignores.
- Placeholders: complete code; Task 2 names the exact anchor (after the GuiEvidence append). No TBDs.
- Type consistency: `EnvEvidence.isDefaultMaterial`/`summarize`/`gather` + `Stats` consistent across module, spec, and the Evaluate call (`gather`).
