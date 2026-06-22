# capture_animation framing (auto-fit to the swept pose extent) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `capture_animation` frames the WHOLE motion (so a splayed/action pose is fully visible the first time) by auto-fitting the camera to the animation's swept extent, plus a manual `zoom` knob.

**Architecture:** Reuse CaptureCore's existing oriented-corner world-AABB (`aabbOf`, currently local) by exposing it, and add a PURE `unionAABB` that merges a list of boxes. `capture_animation` runs a cheap measure pre-pass (step each sample time, union the rig's AABB across poses) and frames once to that swept box scaled by `zoom`, falling back to today's resting `GetBoundingBox()` framing if the measure is degenerate.

**Tech Stack:** Luau (`--!strict`), Roblox Studio plugin. **No local Luau execution** — verify with `selene`/`stylua`/`rojo build` (static) + the in-Studio `CaptureSpec` (run at the dogfood) + a bridge dogfood (`scripts/studio-agent.ps1`) after a Studio restart.

**Source of truth:** [`docs/superpowers/specs/2026-06-22-capture-animation-framing-design.md`](../specs/2026-06-22-capture-animation-framing-design.md).

---

## Reference facts (from the codebase — do not re-derive)

- `src/Tools/CaptureCore.luau` has a LOCAL `aabbOf(roots: { Instance }): (Vector3?, Vector3?)` (lines ~142-184) that returns the tight world-AABB `(center, size)` over every BasePart under the roots, using ORIENTED corners (`cf * CFrame.new(±size/2)`). It is called once, by `CaptureCore.resolveTarget` (`local center, size = aabbOf(roots)`).
- `CaptureCore.frameCFrame(center, size, yawDeg, pitchDeg, distScale, fovDeg?)` returns the camera CFrame fitting a box of `size` at `(yaw,pitch)`; `distScale` multiplies the fitted distance (already has a `FIT_MARGIN = 1.2` baked in). `capture_animation` currently calls it with a hardcoded `distScale = 1`.
- `src/Tools/Capture.luau` `runAnimation` (lines ~234-341): after the track loads and `frames`/`startT`/`endT` are computed (lines ~278-285), it frames via `preset` + `rig:GetBoundingBox()` + `setCamera` (lines ~287-292), then the capture loop (lines ~297-308) steps `animTrack.TimePosition = t; animator:StepAnimations(0); settle(2); triggerCapture()`. All of it runs inside a saved-state window torn down + restored at lines ~310-317 (`animator:Destroy()`, `restoreTransforms`, `RigWorkbench.applyPose`, `restoreCamera`).
- `frames` is clamped to `[2, 20]`, so `frames - 1 >= 1` (no divide-by-zero in the time formula).
- `src/CaptureSpec.luau` is the in-Studio pure self-test for CaptureCore (uses Vector3, so it runs in Studio, not locally). It has 6 cases + an `M.run()` that prints `=== Summary: N/N passed ===`. Run it via a temporary `require(script.CaptureSpec).run()` in `init.server.luau`.
- A plugin CODE change needs `.\build.ps1` + a USER Studio restart (the dev bridge can't hot-reload). Drive the dogfood from the shell via `& scripts/studio-agent.ps1 …` (keep bridge Luau ASCII-only). **Verify by LOOKING at the capture, not coordinates.** Don't delete the user's `Rig` model.

---

## File structure

| File | New/Mod | Responsibility |
|---|---|---|
| `src/Tools/CaptureCore.luau` | mod | Expose `aabbOf`; add pure `unionAABB(boxes)`. |
| `src/CaptureSpec.luau` | mod | Add `unionAABB` pure cases. |
| `src/Tools/Capture.luau` | mod | `runAnimation`: measure pass → swept-box framing + `zoom` param; schema/description. |
| `src/init.server.luau` | mod (temp) | Temporary `require(script.CaptureSpec).run()` for the dogfood; reverted in Task 3. |
| `HANDOFF.md` | mod | Dated shipped block. |

---

## Task 1: CaptureCore — expose `aabbOf` + add pure `unionAABB` + spec

**Files:**
- Modify: `src/Tools/CaptureCore.luau`
- Modify: `src/CaptureSpec.luau`

- [ ] **Step 1: Expose `aabbOf`.** In `src/Tools/CaptureCore.luau`, change the local function definition `local function aabbOf(roots: { Instance }): (Vector3?, Vector3?)` to a module method `function CaptureCore.aabbOf(roots: { Instance }): (Vector3?, Vector3?)` (keep its body byte-for-byte identical). Add a one-line comment above it noting it reads parts (impure) and is exposed for capture_animation's swept-extent measure pass. Then update its ONE caller inside `CaptureCore.resolveTarget`: change `local center, size = aabbOf(roots)` to `local center, size = CaptureCore.aabbOf(roots)`.

- [ ] **Step 2: Add the pure `unionAABB`.** Immediately AFTER `CaptureCore.aabbOf` (the function you just exposed), add:

```lua
-- Pure: union a list of axis-aligned boxes given as { center, size }. Returns (center, size) of the
-- union, or (nil, nil) for an empty list. Used to frame the SWEPT extent of an animation across its
-- sampled poses (capture_animation) so action poses that exceed the resting box still fit. Mirrors
-- aabbOf's min/max accumulation but over precomputed boxes (no DataModel reads -> unit-testable).
function CaptureCore.unionAABB(boxes: { { center: Vector3, size: Vector3 } }): (Vector3?, Vector3?)
	local minV: Vector3? = nil
	local maxV: Vector3? = nil
	for _, b in boxes do
		local half = b.size / 2
		local lo = b.center - half
		local hi = b.center + half
		if minV == nil or maxV == nil then
			minV, maxV = lo, hi
		else
			minV = Vector3.new(math.min(minV.X, lo.X), math.min(minV.Y, lo.Y), math.min(minV.Z, lo.Z))
			maxV = Vector3.new(math.max(maxV.X, hi.X), math.max(maxV.Y, hi.Y), math.max(maxV.Z, hi.Z))
		end
	end
	if minV == nil or maxV == nil then
		return nil, nil
	end
	return (minV + maxV) / 2, (maxV - minV)
end
```

- [ ] **Step 3: Add `unionAABB` cases to `src/CaptureSpec.luau`.** Inside `buildCases`, before the final `return cases`, add:

```lua
	add("unionAABB of empty list is nil", function()
		local c, s = CaptureCore.unionAABB({})
		return c == nil and s == nil
	end)

	add("unionAABB of one box round-trips its center/size", function()
		local c, s = CaptureCore.unionAABB({ { center = Vector3.new(1, 2, 3), size = Vector3.new(4, 4, 4) } })
		if c == nil or s == nil then
			return false, "nil for one box"
		end
		return approx(c.X, 1)
			and approx(c.Y, 2)
			and approx(c.Z, 3)
			and approx(s.X, 4)
			and approx(s.Y, 4)
			and approx(s.Z, 4)
	end)

	add("unionAABB widens to cover offset + splayed boxes", function()
		-- a box at the origin and a wide box offset on +X: union spans both extremes
		local c, s = CaptureCore.unionAABB({
			{ center = Vector3.new(0, 0, 0), size = Vector3.new(2, 2, 2) }, -- spans X[-1,1]
			{ center = Vector3.new(10, 0, 0), size = Vector3.new(4, 2, 2) }, -- spans X[8,12]
		})
		if c == nil or s == nil then
			return false, "nil union"
		end
		-- union X spans [-1, 12] -> size.X = 13, center.X = 5.5
		return approx(s.X, 13) and approx(c.X, 5.5) and approx(s.Y, 2) and approx(s.Z, 2)
	end)
```

(`approx` already exists in CaptureSpec.)

- [ ] **Step 4: Static-verify** — `stylua src ; stylua --check src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`. `stylua --check` clean; `selene` MUST be `0 errors / 0 warnings / 0 parse errors`; `rojo build` succeeds. Fix any slip and re-run. (The CaptureSpec cases RUN in Studio at the Task 3 dogfood — they cannot run locally.)

- [ ] **Step 5: Commit**
```
git add src/Tools/CaptureCore.luau src/CaptureSpec.luau
git commit -m "feat: expose CaptureCore.aabbOf + add pure unionAABB (swept-extent framing) + spec" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: capture_animation — measure pass + `zoom` param

**Files:**
- Modify: `src/Tools/Capture.luau`

- [ ] **Step 1: Replace the resting-box framing with the swept measure pass.** In `runAnimation`, find the current framing block (right after `frames`/`startT`/`endT` are computed):

```lua
	local preset = CaptureCore.PRESETS[string.lower(tostring(args.angle))]
		or CaptureCore.PRESETS.front
	local boundCF, boundSize = (rig :: Model):GetBoundingBox()
	CaptureCore.setCamera(
		CaptureCore.frameCFrame(boundCF.Position, boundSize, preset.yaw, preset.pitch, 1)
	)
```

Replace that ENTIRE block with:

```lua
	-- Frame to the SWEPT extent, not the resting pose: action poses (splayed limbs, jumps) exceed
	-- rig:GetBoundingBox() measured at rest, so a measure PRE-PASS steps the same sample times and unions
	-- the rig's world AABB across all poses, then frames ONCE to that union scaled by zoom. The pass only
	-- steps joints (no screenshots), so it's cheap, and it runs inside the saved-state window restored below.
	local zoom = if type(args.zoom) == "number" and args.zoom > 0 then args.zoom else 1.1
	local preset = CaptureCore.PRESETS[string.lower(tostring(args.angle))]
		or CaptureCore.PRESETS.front
	local boxes: { { center: Vector3, size: Vector3 } } = {}
	pcall(function()
		for i = 0, frames - 1 do
			local t = startT + (endT - startT) * (i / (frames - 1))
			animTrack.TimePosition = t
			animator:StepAnimations(0)
			CaptureCore.settle(1)
			local c, s = CaptureCore.aabbOf({ rig })
			if c ~= nil and s ~= nil then
				table.insert(boxes, { center = c, size = s })
			end
		end
	end)
	local sweptCenter, sweptSize = CaptureCore.unionAABB(boxes)
	if sweptCenter == nil or sweptSize == nil then
		-- Degenerate measure (no parts found): fall back to today's resting-box framing.
		local boundCF, boundSize = (rig :: Model):GetBoundingBox()
		sweptCenter, sweptSize = boundCF.Position, boundSize
	end
	CaptureCore.setCamera(
		CaptureCore.frameCFrame(sweptCenter, sweptSize, preset.yaw, preset.pitch, zoom)
	)
```

(`frames`/`startT`/`endT`/`animTrack`/`animator`/`rig` are all already in scope above this block. The capture loop that follows is UNCHANGED — it re-steps from `i = 0` and triggers screenshots.)

- [ ] **Step 2: Add the `zoom` param to the schema.** In the `capture_animation` descriptor's `inputSchema.properties`, after the `angle` property, add:

```lua
				zoom = {
					type = "number",
					description = "Distance scale of the auto-fit framing (default 1.1). >1 pulls the camera back, <1 pushes in.",
				},
```

- [ ] **Step 3: Update the `capture_animation` description** to mention the auto-fit + zoom. In its `description` string, append this sentence to the existing text (before the closing `"`): ` It auto-frames the whole motion's extent (so action poses aren't cropped); pass zoom (>1 pulls back, <1 pushes in) to adjust.`

- [ ] **Step 4: Static-verify** — `stylua src ; stylua --check src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm` (all green; selene 0/0).

- [ ] **Step 5: Commit**
```
git add src/Tools/Capture.luau
git commit -m "feat: capture_animation auto-fits the swept pose extent + adds a zoom param" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: build + bridge dogfood + HANDOFF

**Files:** `src/init.server.luau` (temporary spec require, reverted in Step 6); `HANDOFF.md`.

- [ ] **Step 1: Temporarily wire the spec** — in `src/init.server.luau`, after the final `print(...)`, add:
```lua
require(script.CaptureSpec).run()
```

- [ ] **Step 2: Build + install + restart** — `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm ; .\build.ps1`; then the **USER restarts Studio** ("Restart to update") on a fresh Baseplate (sidecar + bridge + tunnel already running).

- [ ] **Step 3: Confirm the spec + bridge** — `& scripts/studio-agent.ps1 logs` → expect `=== Summary: 9/9 passed ===` for CaptureSpec (6 existing + 3 new unionAABB) and `dev bridge active`.

- [ ] **Step 4: Dogfood — author a splayed pose and SEE it framed:**
```
& scripts/studio-agent.ps1 tool spawn_rig '{"type":"block"}'
& scripts/studio-agent.ps1 tool ik_reach '{"rig":"Workspace.AgentRig","chain":"RightArm","target":{"x":4,"y":5,"z":0}}'
& scripts/studio-agent.ps1 tool ik_reach '{"rig":"Workspace.AgentRig","chain":"LeftArm","target":{"x":-4,"y":5,"z":0}}'
& scripts/studio-agent.ps1 tool add_keyframe '{"rig":"Workspace.AgentRig","time":0}'
& scripts/studio-agent.ps1 tool reset_pose '{"rig":"Workspace.AgentRig"}'
& scripts/studio-agent.ps1 tool add_keyframe '{"rig":"Workspace.AgentRig","time":0.5}'
& scripts/studio-agent.ps1 tool capture_animation '{"rig":"Workspace.AgentRig","frames":4}'
```
**LOOK at the returned filmstrip:** the splayed-arms keypose at t=0 must be FULLY in frame (arms not cropped at the edges) — the verification that matters. Then confirm the zoom knob:
```
& scripts/studio-agent.ps1 tool capture_animation '{"rig":"Workspace.AgentRig","frames":4,"zoom":0.7}'   # pushes in (rig larger)
& scripts/studio-agent.ps1 tool capture_animation '{"rig":"Workspace.AgentRig","frames":4,"zoom":1.6}'   # pulls back (rig smaller)
```
Confirm: the default-zoom strip shows the full splayed pose uncropped; `zoom:0.7` fills more of the frame; `zoom:1.6` shows more margin; the working pose is restored after (the rig returns to its last manual pose). If the default frame is still slightly tight on the splayed arms, the `settle(1)` in the measure pass may need bumping to `settle(2)` (parts not fully updated before `aabbOf` reads them) — apply that, rebuild, restart, re-dogfood.

- [ ] **Step 5: (Recommended) quick review** — diff-verify the two code commits (the measure pass sits inside the saved-state window; the fallback covers the degenerate case; `zoom` is coerced).

- [ ] **Step 6: Revert the temporary spec require** — remove the `require(script.CaptureSpec).run()` line from `src/init.server.luau`; rebuild + reinstall (`stylua src ; selene src ; rojo build … ; .\build.ps1`).

- [ ] **Step 7: Update HANDOFF.md + commit** — add a dated block: capture_animation now auto-fits the swept pose extent (no more cropped action poses) + a `zoom` knob; new `CaptureCore.unionAABB` (+ exposed `aabbOf`) with 9/9 CaptureSpec; bridge-dogfooded. Commit.
```
git add HANDOFF.md src/init.server.luau
git commit -m "docs: capture_animation swept-extent framing shipped + bridge-verified; revert spec auto-run" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-review (completed during plan authoring)

- **Spec coverage:** pure `unionAABB` helper + exposed `aabbOf` → Task 1; measure-pass swept framing + `zoom` param + schema/description → Task 2; fallback to `GetBoundingBox` → Task 2 Step 1; restore-safety (runs in the existing saved-state window) → Task 2 Step 1 comment; testing (pure CaptureSpec cases + bridge dogfood looking at the filmstrip) → Tasks 1 + 3. All spec sections covered.
- **Placeholder scan:** every step has concrete code/commands; the dogfood specifies exact bridge calls and the visual pass/fail criterion (splayed arms uncropped). No TBDs.
- **Type/name consistency:** `CaptureCore.aabbOf` (Task 1) and `CaptureCore.unionAABB(boxes: { { center, size } })` (Task 1) are the exact names/shapes called by `runAnimation` (Task 2); `zoom` arg/param name matches across Task 2 Steps 1-3; CaptureSpec uses the existing `approx` + `M.run()` summary format.
- **YAGNI:** no per-frame camera tracking, no oriented tight-bounds, no change to capture/capture_angles — only the one tool that sweeps time.
