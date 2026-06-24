# Cube Texture Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `save_mesh` persist a Cube-generated mesh's TEXTURE alongside its geometry, so a generated prop survives Play / save / ship fully textured (today the geometry survives but the texture comes back grey).

**Architecture:** Extend `MeshFactory.persistMeshPart` — it already extracts geometry, uploads the mesh, and builds the durable swap part `d`. Add a texture step: classify the original part's `TextureContent` (pure `classifyTexture`), and on a session-backed texture, extract an EditableImage → `CreateAssetAsync(Image)` → set the **writable** `TextureContent` on the durable part. `persistMeshPart`'s return becomes a result table so `runSave` can tally textures. Folds into `save_mesh` automatically — no new tool, no flag. Degrades to geometry-only on any texture failure.

**Tech Stack:** Luau (`--!strict`), Roblox `AssetService` (`CreateEditableImageAsync` + `CreateAssetAsync(Enum.AssetType.Image)` + writable `MeshPart.TextureContent`, all verified callable from the bridge this session), Rojo, `selene`/`stylua`, the dev bridge.

---

## File Structure

- **Modify `src/MeshFactory.luau`** — add the PURE `classifyTexture` helper; refactor `persistMeshPart`'s return to a result table and insert the texture step.
- **Modify `src/MeshFactorySpec.luau`** — add `classifyTexture` cases (the texture decision is the new pure unit).
- **Modify `src/Tools/Mesh.luau`** (`runSave`) — adapt to the result table and add a texture tally to the summary.
- **Modify `src/SystemPrompt.luau`** — a one-line clarification that `save_mesh` now also persists the generated texture (the grey-in-play caveat is resolved).

**Luau testing note:** there is no local Luau runtime. The pure-helper spec runs *in-Studio* (or via the bridge: `luau 'return tostring(require(script.Parent.MeshFactorySpec).run())'`) after a build + USER restart. The per-task static gate is `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm` (selene MUST be 0/0). `rojo build` does NOT type-check, so strict-type quibbles won't fail the gate — but write clean types anyway. Python n/a here.

**Design note (string-based `classifyTexture`):** the helper takes the SourceType's NAME string (`mp.TextureContent.SourceType.Name`), not the `EnumItem`. This keeps it a pure string→string map — trivially testable in the spec with plain strings and with zero coupling to a possibly-stale `Enum.ContentSourceType` definition in tooling.

---

### Task 1: Pure `classifyTexture` helper + spec

**Files:** Modify `src/MeshFactory.luau`; Modify `src/MeshFactorySpec.luau`.

- [ ] **Step 1: Add the pure helper to `src/MeshFactory.luau`**

In `src/MeshFactory.luau`, in the PURE section (just after `MeshFactory.scaleFactorForHeight`, before the `prand` local on line ~47), insert:

```lua
-- Classify a MeshPart's TextureContent for persistence by its SourceType NAME. "persist" = a
-- session-backed texture ("Opaque") to upload; "carry" = an already-durable texture ("Uri") to copy
-- across the swap; "none" = no texture ("None") or any unexpected value -> a safe skip. PURE (a
-- string->string map) -> unit-testable. Verified live: a Cube MeshPart's texture lives in
-- MeshPart.TextureContent with SourceType "Opaque" while session-backed (NOT a SurfaceAppearance, NOT
-- TextureID); a procedural author_mesh part has "None".
function MeshFactory.classifyTexture(sourceTypeName: string): string
	if sourceTypeName == "Opaque" then
		return "persist"
	elseif sourceTypeName == "Uri" then
		return "carry"
	end
	return "none"
end
```

- [ ] **Step 2: Add spec cases to `src/MeshFactorySpec.luau`**

In `src/MeshFactorySpec.luau`, inside `buildCases`, just after the existing `rockClusterLayout` case's `add(...)` block (before `return cases`), insert:

```lua
	add("classifyTexture maps SourceType name -> action", function()
		if MeshFactory.classifyTexture("Opaque") ~= "persist" then
			return false, "Opaque should persist"
		end
		if MeshFactory.classifyTexture("Uri") ~= "carry" then
			return false, "Uri should carry"
		end
		if MeshFactory.classifyTexture("None") ~= "none" then
			return false, "None should be none"
		end
		if MeshFactory.classifyTexture("Object") ~= "none" then
			return false, "unexpected value should be none (safe skip)"
		end
		return true
	end)
```

- [ ] **Step 3: Static gate**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: `selene` 0 errors / 0 warnings; `rojo build` writes the rbxm. (The spec itself runs in-Studio at Task 4.)

- [ ] **Step 4: Commit**

```bash
git add src/MeshFactory.luau src/MeshFactorySpec.luau
git commit -m "feat(mesh): pure classifyTexture (Opaque->persist / Uri->carry / None->none) + spec

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `persistMeshPart` texture step + result-table refactor + `runSave` tally

**Files:** Modify `src/MeshFactory.luau`; Modify `src/Tools/Mesh.luau`.

This task changes `persistMeshPart`'s return contract AND its one caller (`runSave`) together, so the committed state stays consistent.

- [ ] **Step 1: Replace `persistMeshPart` in `src/MeshFactory.luau`**

Replace the entire existing `persistMeshPart` function (its doc comment through its final `end`, currently the last function before `return MeshFactory`) with this. Note the new `TextureResult`/`PersistResult` type exports above it, and that `durable`/`d` are now typed `MeshPart` (so `TextureContent` assigns cleanly; `MeshPart` IS-A `BasePart`, so the existing property copies still type-check):

```lua
export type TextureResult = { imageId: number?, err: string? }
export type PersistResult = {
	meshAssetId: number?,
	swapped: boolean,
	err: string?,
	texture: TextureResult?,
}

-- Persist a session-backed MeshPart (Cube/EditableMesh geometry; MeshId=="") to a durable creator-OWNED
-- Mesh asset and SWAP the in-scene part for one loaded from that asset, so it survives Play/save/ship.
-- ALSO persists the part's generated TEXTURE: a Cube mesh's texture lives in MeshPart.TextureContent
-- (SourceType "Opaque" while session-backed); the swapped durable part starts textureless, so we extract
-- an EditableImage from the ORIGINAL part, upload it via CreateAssetAsync(Image), and set the durable
-- part's WRITABLE TextureContent to the new owned Image asset (verified live). Returns a PersistResult:
-- swapped=true means the in-scene part IS now durable; a non-nil meshAssetId with swapped=false means the
-- mesh uploaded but a fresh-asset load failed (pending moderation) so the part was NOT replaced yet (and
-- the texture is deferred to the next run). `texture` is nil when the part had no texture; otherwise it
-- carries imageId (success) or err (the geometry still persisted; only the texture step failed).
-- MeshContent/MeshId are not writable, so we REPLACE the part; TextureContent IS writable, so the texture
-- needs no swap. Needs the "CreateAssetAsync Lua API" Studio beta flag.
function MeshFactory.persistMeshPart(mp: MeshPart, name: string): PersistResult
	local em: EditableMesh? = nil
	local okEx = pcall(function()
		em = AssetService:CreateEditableMeshAsync(mp.MeshContent)
	end)
	if not okEx or em == nil then
		return {
			meshAssetId = nil,
			swapped = false,
			err = "could not extract geometry from the MeshPart",
			texture = nil,
		}
	end
	-- Classify the texture from the LIVE original part, before any swap/destroy.
	local texClass = MeshFactory.classifyTexture(mp.TextureContent.SourceType.Name)
	-- Verified beta shape: CreateAssetAsync returns (Enum.CreateAssetResult, assetId:number).
	local okSave, result, assetId = pcall(function()
		return AssetService:CreateAssetAsync(em, Enum.AssetType.Mesh, { Name = name })
	end)
	if not okSave then
		return {
			meshAssetId = nil,
			swapped = false,
			err = "CreateAssetAsync failed (is the 'CreateAssetAsync Lua API' beta flag on?): "
				.. tostring(result),
			texture = nil,
		}
	end
	if result ~= Enum.CreateAssetResult.Success or type(assetId) ~= "number" then
		return {
			meshAssetId = nil,
			swapped = false,
			err = "upload not successful (result=" .. tostring(result) .. ")",
			texture = nil,
		}
	end
	local id = assetId :: number
	local durable: MeshPart? = nil
	local okLoad = pcall(function()
		durable = AssetService:CreateMeshPartAsync(Content.fromUri("rbxassetid://" .. tostring(id)))
	end)
	if not okLoad or durable == nil then
		-- Mesh uploaded but not yet loadable (pending moderation): no durable part to texture; defer both.
		return { meshAssetId = id, swapped = false, err = nil, texture = nil }
	end
	local d = durable :: MeshPart
	d.CFrame = mp.CFrame
	d.Size = mp.Size
	d.Color = mp.Color
	d.Material = mp.Material
	d.Transparency = mp.Transparency
	d.Reflectance = mp.Reflectance
	d.CastShadow = mp.CastShadow
	d.CanCollide = mp.CanCollide
	d.Anchored = mp.Anchored
	d.Name = mp.Name
	-- Texture step: reattach the generated texture onto the durable part. Reads the ORIGINAL mp (alive
	-- until the destroy below). Whole step is pcall-wrapped -> a failure degrades to geometry-only.
	local texture: TextureResult? = nil
	if texClass == "persist" then
		local okTex, texErr = pcall(function()
			local imgEm = AssetService:CreateEditableImageAsync(mp.TextureContent)
			local tResult, imageId =
				AssetService:CreateAssetAsync(imgEm, Enum.AssetType.Image, { Name = name .. "_tex" })
			if tResult ~= Enum.CreateAssetResult.Success or type(imageId) ~= "number" then
				error("image upload not successful (result=" .. tostring(tResult) .. ")")
			end
			d.TextureContent = Content.fromUri("rbxassetid://" .. tostring(imageId))
			texture = { imageId = imageId :: number }
		end)
		if not okTex then
			texture = { err = "texture persist failed: " .. tostring(texErr) }
		end
	elseif texClass == "carry" then
		-- Already-durable texture: copy the reference across the swap (no upload).
		local okCarry = pcall(function()
			d.TextureContent = mp.TextureContent
		end)
		if okCarry then
			texture = {}
		else
			texture = { err = "texture carry failed" }
		end
	end
	for _, ch in mp:GetChildren() do
		ch.Parent = d
	end
	d.Parent = mp.Parent
	mp:Destroy()
	return { meshAssetId = id, swapped = true, err = nil, texture = texture }
end
```

- [ ] **Step 2: Update `runSave` in `src/Tools/Mesh.luau`**

Find the counter declarations in `runSave` (currently `local swapped, pending, failed = 0, 0, 0` followed by `local ids: { string } = {}` and `local firstErr: string? = nil`). Add texture counters right after `firstErr`:

```lua
	local texPersisted, texFailed = 0, 0
	local firstTexErr: string? = nil
```

Then replace the `doPersist` loop body. The existing one is:

```lua
	local function doPersist()
		for i, mp in parts do
			local assetId, didSwap, err =
				MeshFactory.persistMeshPart(mp, mp.Name .. "_" .. tostring(i))
			if assetId ~= nil then
				table.insert(ids, tostring(assetId))
				if didSwap then
					swapped += 1
				else
					pending += 1
				end
			else
				failed += 1
				if firstErr == nil then
					firstErr = err
				end
			end
		end
	end
```

Replace it with (adapts to the result table + tallies textures):

```lua
	local function doPersist()
		for i, mp in parts do
			local result = MeshFactory.persistMeshPart(mp, mp.Name .. "_" .. tostring(i))
			if result.meshAssetId ~= nil then
				table.insert(ids, tostring(result.meshAssetId))
				if result.swapped then
					swapped += 1
				else
					pending += 1
				end
			else
				failed += 1
				if firstErr == nil then
					firstErr = result.err
				end
			end
			local tex = result.texture
			if tex ~= nil then
				if tex.err == nil then
					texPersisted += 1
				else
					texFailed += 1
					if firstTexErr == nil then
						firstTexErr = tex.err
					end
				end
			end
		end
	end
```

- [ ] **Step 3: Append the texture tally to the summary**

In `runSave`, find the `if failed > 0 then msg = msg .. string.format(" — %d FAILED (%s)", failed, tostring(firstErr)) end` block. Immediately AFTER it (before the final `return msg, ...`), insert:

```lua
	if texPersisted > 0 then
		msg = msg .. string.format(" — %d texture(s) persisted", texPersisted)
	end
	if texFailed > 0 then
		msg = msg
			.. string.format(" — %d texture(s) FAILED (%s)", texFailed, tostring(firstTexErr))
	end
```

Leave the final `return msg, (swapped == 0 and pending == 0)` UNCHANGED — a texture failure with geometry success is NOT a tool error (graceful degrade).

- [ ] **Step 4: Static gate**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: `selene` 0/0; `rojo build` clean. (If selene flags an unused local, fix without suppressing.)

- [ ] **Step 5: Commit**

```bash
git add src/MeshFactory.luau src/Tools/Mesh.luau
git commit -m "feat(mesh): persist Cube textures in save_mesh (TextureContent -> owned Image asset)

persistMeshPart now extracts the generated texture (CreateEditableImageAsync),
uploads it (CreateAssetAsync Image), and repoints the durable part's writable
TextureContent. Return refactored to a PersistResult table; runSave tallies
textures. Degrades to geometry-only on texture failure.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: SystemPrompt clarification

**Files:** Modify `src/SystemPrompt.luau`.

- [ ] **Step 1: Clarify the `save_mesh` note**

In `src/SystemPrompt.luau`, in the "# Building with custom meshes" section, find this exact fragment:

```
(it uploads each via CreateAssetAsync and swaps in durable parts; needs the 'CreateAssetAsync Lua API' Studio beta flag)
```

Replace it with:

```
(it uploads each mesh AND its generated texture via CreateAssetAsync and swaps in durable parts that keep their textured look in Play; needs the 'CreateAssetAsync Lua API' Studio beta flag)
```

- [ ] **Step 2: Static gate**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: `selene` 0/0; `rojo build` clean (the only risk is a malformed long string — fix if rojo/selene errors).

- [ ] **Step 3: Commit**

```bash
git add src/SystemPrompt.luau
git commit -m "feat(prompt): note save_mesh now persists generated textures (no more grey in Play)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Bridge dogfood — the acceptance gate

**Files:** none (live verification + HANDOFF + memory).

> Gate to enter: Tasks 1–3 changed plugin code → run `.\build.ps1`, then **ask the USER to restart Studio** (Studio must also be FOCUSED for captures). The sidecar needs NO restart. The **"CreateAssetAsync Lua API" beta flag must be ON**. Verify by LOOKING at captures, never coordinates. Drive via `scripts/studio-agent.ps1` (keep bridge Luau ASCII-only; use a PowerShell here-string `$code = @'…'@` for any Luau with quotes; for Cube/long calls use the `tool` command's 150s window, not `luau`'s 30s).

- [ ] **Step 1: Run the pure spec + RelaySpec via the bridge**

Run:
```
& scripts/studio-agent.ps1 luau 'return "MeshFactory=" .. tostring(require(script.Parent.MeshFactorySpec).run()) .. " Relay=" .. tostring(require(script.Parent.RelaySpec).run())'
```
Expected: `MeshFactory=true Relay=true` (the Studio Output shows `[MeshFactorySpec] 7/7 passed` — the new `classifyTexture` case included — and the RelaySpec count; `save_mesh` classification is unchanged, so no-drift stays green). If `MeshFactory` is false, the `classifyTexture` case failed — fix and rebuild.

- [ ] **Step 2: Generate a fresh Cube barrel (a session texture)**

```
& scripts/studio-agent.ps1 tool generate_mesh '{"prompt":"a wooden barrel","name":"TexProbeBarrel","position":{"x":0,"y":0,"z":-24}}'
```
Expected: `generate_mesh OK: 'TexProbeBarrel' (1 MeshPart(s), …)`. (If it errors with a Cube rate limit, wait ~15s and retry.) Confirm the texture is session-backed with a here-string probe:
```
$code = @'
local mp = nil
for _, d in workspace.TexProbeBarrel:GetDescendants() do if d:IsA("MeshPart") then mp = d break end end
return "meshId=[" .. tostring(mp.MeshId) .. "] texSourceType=" .. tostring(mp.TextureContent.SourceType)
'@
& scripts/studio-agent.ps1 luau $code
```
Expected: `meshId=[]` (empty -> session geometry) and `texSourceType=Enum.ContentSourceType.Opaque` (session texture).

- [ ] **Step 3: `save_mesh` it — confirm BOTH geometry and texture persist**

```
& scripts/studio-agent.ps1 tool save_mesh '{"target":"Workspace.TexProbeBarrel"}'
```
Expected summary: `save_mesh: 1/1 mesh(es) now DURABLE … asset ids: <meshId> — 1 texture(s) persisted`. Then verify the swapped part is fully durable:
```
$code = @'
local mp = nil
for _, d in workspace.TexProbeBarrel:GetDescendants() do if d:IsA("MeshPart") then mp = d break end end
return "meshId=" .. tostring(mp.MeshId) .. " texSourceType=" .. tostring(mp.TextureContent.SourceType) .. " texUri=" .. tostring(mp.TextureContent.Uri)
'@
& scripts/studio-agent.ps1 luau $code
```
Expected: `meshId=rbxassetid://…` AND `texSourceType=Enum.ContentSourceType.Uri` with a `rbxassetid://…` `texUri` (the texture now references a durable owned Image asset, not a session handle).

- [ ] **Step 4: LOOK — the durable barrel renders textured**

Frame + capture the durable barrel and READ the PNG:
```
& scripts/studio-agent.ps1 tool camera_focus '{"target":"Workspace.TexProbeBarrel"}'
& scripts/studio-agent.ps1 capture "$env:TEMP/texprobe-durable.png"
```
Read `texprobe-durable.png` — expect the wood-plank + metal-hoop texture (NOT grey). The image asset may take a few seconds to moderate; if grey, wait ~15–30s and re-capture (the durable reference renders once moderated). **This is the core gate: a persisted Cube mesh keeps its look.** For the strongest proof, ask the USER to enter Play and confirm the barrel is textured (the geometry fix was confirmed in Play last session; the GREY bug is what this closes).

- [ ] **Step 5: The no-texture path is a clean skip**

```
& scripts/studio-agent.ps1 tool author_mesh '{"kind":"pine","name":"TexProbePine","position":{"x":10,"y":0,"z":-24}}'
& scripts/studio-agent.ps1 tool save_mesh '{"target":"Workspace.TexProbePine"}'
```
Expected: the `save_mesh` summary reports the pine cone(s) DURABLE with **NO** "texture(s) persisted" clause (procedural parts classify `none` → no spurious Image upload). This proves the gating.

- [ ] **Step 6: Clean up + HANDOFF + memory + final commit**

Destroy the probe artifacts (`TexProbeBarrel`, `TexProbePine`) — ASK the user before clearing any older leftovers (`ProbeBarrel`/`DogBarrel`/`DogPine`/`DogRock` and their uploaded assets). Leave the user's `Rig`/`UAL2_Standard` alone. Confirm `selene src` 0/0. Update `HANDOFF.md` with a new START-HERE block (Cube texture persistence SHIPPED + bridge-verified: the texture lives in `MeshPart.TextureContent`/Opaque; `persistMeshPart` extract→upload→repoint the writable TextureContent; `save_mesh` now persists geometry AND texture; the GREY-in-Play bug is fixed). Update memory `roblox-bridge-mesh-creation` if any live detail differs from the spec's §1 (it was already corrected to TextureContent this session). Commit:

```bash
git add HANDOFF.md
git commit -m "docs: Cube texture persistence shipped + bridge-verified (save_mesh keeps the look in Play)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review notes (for the executor)

- **Spec coverage:** §1 mechanism → Task 2 (`persistMeshPart` texture step); §2 classification → Task 1 (`classifyTexture`); §3 control flow (incl. pending-moderation early return = no `d` = no texture) → Task 2; §4 modules (MeshFactory + spec + Mesh.luau + SystemPrompt) → Tasks 1–3; §4 result-table refactor → Task 2 (every early return adopts the table shape); §5 edge cases (no-texture skip, idempotency, degrade) → Tasks 1 (`none`/unexpected→skip) & 2 (pcall degrade) & 4 Step 5 (skip proof); §6 testing/acceptance → Task 1 (spec) & Task 4 (dogfood, incl. the Opaque→Uri proof and the visual render). Reporting/tally → Task 2 Steps 2–3.
- **Type/name consistency:** `MeshFactory.classifyTexture` (Task 1) is consumed by `persistMeshPart` (Task 2) via `mp.TextureContent.SourceType.Name`; `PersistResult`/`TextureResult` (Task 2) are produced by `persistMeshPart` and consumed field-for-field by `runSave` (`meshAssetId`/`swapped`/`err`/`texture.{imageId,err}`). `Enum.AssetType.Image`, `CreateEditableImageAsync`, and the writable `TextureContent` all match the verified live session patterns. `durable`/`d` retyped to `MeshPart` so `TextureContent` assigns without a cast.
- **Degrade invariant:** the texture step is fully pcall-wrapped and the tool's `isError` return is unchanged — a texture failure NEVER regresses below today's geometry-only behavior.
