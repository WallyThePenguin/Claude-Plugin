# Visual-First Refocus Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. NOTE: Tasks 5–10 drive the LIVE single-slot Studio bridge and require visual judging of capture PNGs — they must run inline in a session with vision, not in parallel subagents.

**Goal:** Refocus the autonomous loop on map/GUI/animations/weapons with a persistent TrainingDummy as the visual verify fixture; clear waves and hostile enemies; unlock the four visual families via supervised first ascents.

**Architecture:** Three code changes (curriculum `focus` list as forever's default family filter; `supervised=True` first-ascent path; weapon verify rewritten around the persistent TrainingDummy with every-angle + frame-by-frame capture evidence), then live place cleanup, then four supervised factory ascents judged on real captures, each flipping `proven: true` on success.

**Tech Stack:** Python stdlib (sidecar), Luau (Studio), dependency-free test scripts (`python sidecar/test_*.py`), live bridge at `http://127.0.0.1:8389` via `scripts/studio-agent.ps1`.

**Spec:** `docs/superpowers/specs/2026-07-03-visual-first-refocus-design.md`

---

### Task 1: Forever honors curriculum `focus` as the default family filter

**Files:**
- Modify: `sidecar/forever.py:223-235` (`_proven_families`)
- Test: `sidecar/test_forever.py`

- [ ] **Step 1: Write the failing tests** — append inside `main()` before the final return, after the existing families-filter test:

```python
    # --- curriculum "focus" list is the DEFAULT family filter ---
    focus_curriculum = {
        "focus": ["melee-weapon"],
        "rungs": CURRICULUM["rungs"],
        "proposals": [],
    }
    factory = FakeFactory("PASSED")
    loop = FakeLoop([proposals_result([]), proposals_result([])])
    r, path = _runner(factory, loop, curriculum=focus_curriculum)
    r.start(cycles=2)
    st = _wait(r)
    fails += _check("focus filters default rotation", {c["rung"] for c in factory.calls} == {"weapon-spear"})

    # --- explicit families STILL overrides focus ---
    factory = FakeFactory("PASSED")
    loop = FakeLoop([proposals_result([])])
    r, path = _runner(factory, loop, curriculum=focus_curriculum)
    r.start(cycles=1, families=["melee-enemy"])
    st = _wait(r)
    fails += _check("explicit families overrides focus", {c["rung"] for c in factory.calls} == {"enemy-brute"})
```

- [ ] **Step 2: Run to verify failure** — `python sidecar/test_forever.py` → expect `FAIL focus filters default rotation` (both proven families cycled).

- [ ] **Step 3: Implement** — in `sidecar/forever.py`, replace `_proven_families` head:

```python
    def _proven_families(self, families):
        """Ordered unique families that have at least one proven rung (optionally filtered).
        With no explicit filter, the curriculum's persistent "focus" list (the user's standing
        rotation directive) is the filter."""
        curriculum = self._read_curriculum()
        if families is None:
            focus = curriculum.get("focus")
            if isinstance(focus, list) and focus:
                families = focus
        out = []
        for rung in curriculum.get("rungs", []):
            fam = rung.get("family")
            if not rung.get("proven") or not fam:
                continue
            if families and fam not in families:
                continue
            if fam not in out:
                out.append(fam)
        return out
```

- [ ] **Step 4: Run tests** — `python sidecar/test_forever.py` → ALL PASS.
- [ ] **Step 5: Commit** — `git add sidecar/forever.py sidecar/test_forever.py && git commit -m "feat(forever): curriculum focus list is the default family rotation"`

### Task 2: `supervised=True` first-ascent path (factory + server)

**Files:**
- Modify: `sidecar/factory.py:126-136` (`start`)
- Modify: `sidecar/server.py:27` (docstring) and `sidecar/server.py:337` (POST /factory)
- Test: `sidecar/test_factory.py` (after the "first ascent refused" block)

- [ ] **Step 1: Write the failing test** — in `test_factory.py` after the `unknown rung refused` block:

```python
    # --- supervised=True admits a proven=false rung (interactive first ascents) ---
    loop = FakeLoop([{"state": "done", "result": build_line()}, {"state": "done", "result": verify_line("PASSED")}])
    bridge = FakeBridge({"GetAttributes": GATE_CLEAN, "FactoryStaging": STAGE_OK})
    r = _runner(loop, bridge, {})
    try:
        r.start("weapon-bow", supervised=True)
        st = _wait(r)
        fails += _check("supervised first ascent admitted", st["state"] == "done")
    except factory.FactoryError:
        fails += _check("supervised first ascent admitted", False)
```

- [ ] **Step 2: Run to verify failure** — `python sidecar/test_factory.py` → expect `TypeError: start() got an unexpected keyword argument 'supervised'`.

- [ ] **Step 3: Implement** — `factory.py` `start` signature and gate:

```python
    def start(self, rung_id, sabotage=False, variant_hint=None, staging_id=None, supervised=False) -> int:
        if not isinstance(rung_id, str) or not rung_id.strip():
            raise FactoryError("rungId is required")
        rung = self._find_rung(rung_id.strip())
        if rung is None:
            raise FactoryError(f"unknown rung '{rung_id}'")
        if not rung.get("proven") and not supervised:
            # Charter: no unmanned first ascents. supervised=True is for interactive sessions
            # where a human-present operator judges the evidence; the forever loop NEVER sets it.
            raise FactoryError(
                f"rung '{rung_id}' is not proven  -  first ascents must be supervised, not headless"
            )
```

`server.py:337`: `run_id = FACTORY.start(body.get("rungId"), body.get("sabotage", False), supervised=bool(body.get("supervised", False)))`
`server.py:27` docstring: `POST /factory {"rungId":str, "sabotage"?:bool, "supervised"?:bool} -> {"id":N}`

- [ ] **Step 4: Run tests** — `python sidecar/test_factory.py && python sidecar/test_server.py` → ALL PASS (server tests confirm no route regression).
- [ ] **Step 5: Commit** — `git commit -m "feat(factory): supervised=True admits first ascents (interactive only)"`

### Task 3: Weapon verify → persistent TrainingDummy + visual evidence; sandbox spares the dummy

**Files:**
- Modify: `sidecar/factory.py` `_WEAPON_VERIFY` (≈line 417) and `_SANDBOX_ON_LUAU` (≈line 363)
- Test: `sidecar/test_factory.py:138,156`

- [ ] **Step 1: Update tests first** — replace line 138's check and line 156's exclusion:

```python
    fails += _check("weapon verify uses the persistent dummy", "TrainingDummy" in loop.prompts[1] and "NEVER destroy" in loop.prompts[1])
    fails += _check("weapon verify gathers visual evidence", "capture_angles" in loop.prompts[1] and "playtest_capture" in loop.prompts[1])
```

and in the building-rung block: `"TrainingDummy" not in loop.prompts[1]` replaces `"VerifyTarget" not in loop.prompts[1]`.

- [ ] **Step 2: Run to verify failure** — `python sidecar/test_factory.py` → the two new checks FAIL.

- [ ] **Step 3: Rewrite `_WEAPON_VERIFY`** (full replacement):

```python
_WEAPON_VERIFY = (
    "The game's round/wave/spawner scripts are auto-disabled and stray mobs cleared for this verify "
    "(a CALM sandbox - the tester will NOT be swarmed). Evidence is VISUAL + FUNCTIONAL, gathered "
    "around the PERSISTENT workspace.TrainingDummy - a god-mode fixture of the map that heals after "
    "every hit, never dies, never fights back, and PRINTS '[TrainingDummy] HIT damage=<n> "
    "hitcount=<n>' on each hit (so the damage readout needs NO playtest_eval/loadstring).\n"
    "(1) In EDIT (no playtest running): if workspace.TrainingDummy is MISSING, create it via "
    "run_luau - clone ServerStorage.VerifyDummy (or EnemyTemplate, deleting its scripts), name it "
    "'TrainingDummy', SetAttribute('StudioAgentGenerated', nil) so the sandbox spares it, add a "
    "Script that on Humanoid.HealthChanged prints the hit line then resets Health=MaxHealth, set "
    "MaxHealth=10000, anchor every BasePart, PivotTo ~6 studs in front of the SpawnLocation. It is "
    "a PERMANENT map fixture: NEVER destroy it, in edit or play.\n"
    "(2) EVERY ANGLE: capture_angles the weapon's model (count 3-4) - it must still READ as the "
    "brief's weapon from all sides; note what the frames show in the evidence.\n"
    "(3) playtest_start; (4) playtest_act record - the echo ends [tool=<name> w=<x> a=<y> c=<z>]: "
    "FAIL if the tool name or echoed config does not match the build's config; (5) DAMAGE + "
    "FRAME-BY-FRAME: walk up to the TrainingDummy (~6 studs ahead of spawn), face it, and "
    "playtest_act activate to swing 2-3 times, taking 2-3 playtest_capture frames DURING the swings "
    "so the attack animation is SEEN (windup/contact readable - describe the frames in the "
    "evidence); (6) playtest_logs since 0 and read the '[TrainingDummy] HIT damage=' lines - FAIL "
    "unless a hit's damage EXACTLY equals the configured damage (a broken or sabotaged weapon "
    "prints NO hit line - hitcount stays 0), and FAIL on any error mentioning the artifact; "
    "(7) ALWAYS playtest_stop, and leave the TrainingDummy standing."
)
```

- [ ] **Step 4: Whitelist the dummy in the sandbox** — `_SANDBOX_ON_LUAU`, change the humanoid-clear guard:

```lua
    if m:FindFirstChildOfClass("Humanoid") and m.Name ~= "VerifyTarget" and m.Name ~= "TrainingDummy" then
```

- [ ] **Step 5: Run tests** — `python sidecar/test_factory.py` → ALL PASS.
- [ ] **Step 6: Commit** — `git commit -m "feat(factory): weapon verify = persistent TrainingDummy + every-angle + frame-by-frame evidence"`

### Task 4: Real curriculum gets the focus list

**Files:**
- Modify: `factory/curriculum.json` (top level)

- [ ] **Step 1: Add the focus key** (python, preserves the rest):

```python
import json
p = "factory/curriculum.json"
c = json.load(open(p, encoding="utf-8"))
c["focus"] = ["melee-weapon", "animation", "building", "environment", "gui"]
json.dump(c, open(p, "w", encoding="utf-8"), indent=2)
```

- [ ] **Step 2: Verify** — `python -c "import json; print(json.load(open('factory/curriculum.json'))['focus'])"` → the five families.
- [ ] **Step 3: Commit** — `git commit -m "feat(curriculum): focus rotation = map/gui/animation/weapons (user directive)"`

### Task 5: Live place cleanup + TrainingDummy fixture

**Files:** none (live place, via bridge). Precondition: sidecar up, Studio bridge alive, no loop running (`GET /factory/status` idle).

- [ ] **Step 1: Liveness check** — `scripts/studio-agent.ps1 luau 'return "alive"'` → alive.
- [ ] **Step 2: Run the idempotent cleanup Luau** (one `studio-agent.ps1 luau` call; here-string):

```lua
local HttpService = game:GetService("HttpService")
local out = {}
-- 1) persistently disable the wave/round/spawner systems (plain Disabled=true, NOT the sandbox
--    tag, so a later verify sandbox-off does NOT re-enable them)
local disabled = {}
for _, s in game:GetService("ServerScriptService"):GetDescendants() do
  if s:IsA("BaseScript") and not s.Disabled then
    local nm = s.Name:lower()
    if nm:find("round") or nm:find("wave") or nm:find("spawn") then
      s.Disabled = true
      table.insert(disabled, s:GetFullName())
    end
  end
end
out.disabled = disabled
-- 2) remove hostile NPCs from workspace (humanoid models that aren't the dummy or a player)
local removed = {}
for _, m in workspace:GetChildren() do
  if m:IsA("Model") and m:FindFirstChildOfClass("Humanoid") and m.Name ~= "TrainingDummy" then
    local isPlayer = false
    for _, p in game:GetService("Players"):GetPlayers() do
      if p.Character == m then isPlayer = true end
    end
    if not isPlayer then table.insert(removed, m.Name); m:Destroy() end
  end
end
out.removed = removed
-- 3) persistent TrainingDummy near spawn (idempotent)
if workspace:FindFirstChild("TrainingDummy") then
  out.dummy = "already present"
else
  local src = game.ServerStorage:FindFirstChild("VerifyDummy") or game.ServerStorage:FindFirstChild("EnemyTemplate")
  if not src then return "ERROR: no VerifyDummy/EnemyTemplate in ServerStorage to clone" end
  local d = src:Clone()
  d.Name = "TrainingDummy"
  d:SetAttribute("StudioAgentGenerated", nil) -- the verify sandbox destroys models carrying this
  for _, s in d:GetDescendants() do
    if s:IsA("BaseScript") then s:Destroy() end
  end
  local hum = d:FindFirstChildOfClass("Humanoid")
  hum.MaxHealth = 10000
  hum.Health = 10000
  local logger = Instance.new("Script")
  logger.Name = "DummyHitLogger" -- name must NOT match round/wave/spawn/enemy/mob (sandbox patterns)
  logger.Source = table.concat({
    'local hum = script.Parent:FindFirstChildOfClass("Humanoid")',
    'local hits = 0',
    'hum.HealthChanged:Connect(function(h)',
    '  if h < hum.MaxHealth then',
    '    hits += 1',
    '    print(("[TrainingDummy] HIT damage=%d hitcount=%d"):format(hum.MaxHealth - h, hits))',
    '    hum.Health = hum.MaxHealth',
    '  end',
    'end)',
  }, "\n")
  logger.Parent = d
  for _, p in d:GetDescendants() do
    if p:IsA("BasePart") then p.Anchored = true end
  end
  local spawnLoc = workspace:FindFirstChildOfClass("SpawnLocation")
  local pos = spawnLoc and (spawnLoc.Position + spawnLoc.CFrame.LookVector * 8 + Vector3.new(0, 3, 0)) or Vector3.new(0, 5, 0)
  local back = spawnLoc and spawnLoc.Position + Vector3.new(0, 3, 0) or Vector3.new(0, 5, 10)
  d:PivotTo(CFrame.lookAt(pos, back))
  d.Parent = workspace
  out.dummy = "created"
end
return HttpService:JSONEncode(out)
```

- [ ] **Step 3: Verify visually** — `capture_angles`-equivalent: run `studio-agent.ps1 luau` returning the workspace tree (TrainingDummy present, no hostile models), then trigger one edit-mode capture of the dummy and Read the PNG from `%LOCALAPPDATA%\Roblox\tmp-capture-storage` to confirm it stands near spawn.

### Task 6: Supervised first ascent — `env-arena-dress` (the map)

Procedure (identical shape for Tasks 7–9, repeated fully each time):

- [ ] **Step 1: Start** —
`python -c "import json,urllib.request as u; print(u.urlopen(u.Request('http://127.0.0.1:8389/factory', json.dumps({'rungId':'env-arena-dress','supervised':True}).encode(), {'Content-Type':'application/json'})).read().decode())"`
- [ ] **Step 2: Watch** — poll `http://127.0.0.1:8389/factory/status` (background monitor; the run takes minutes). On `state=done` note `status`.
- [ ] **Step 3: Judge the evidence yourself (the supervision):** read the newest `sidecar/loops/loop-*.jsonl` transcript (build + verify); Glob the newest PNGs in `%LOCALAPPDATA%\Roblox\tmp-capture-storage` and READ them (vision); fetch references for the rung's subject via `http://127.0.0.1:8389/references?query=<subject>&count=3` (cached files land in `sidecar/refcache/` — Read those); compare feature-by-feature.
- [ ] **Step 4: Flip proven ONLY on a credible pass** — if factory `status=PASSED` AND the captures genuinely read as the brief: set `"proven": true` on the rung in `factory/curriculum.json`; commit `git commit -m "feat(curriculum): env-arena-dress proven — supervised first ascent"`. If FAILED/UNVERIFIED or the captures don't convince: leave unproven, record what broke, fix (or descope) before retrying — do NOT flip.

### Task 7: Supervised first ascent — `structure-house`

- [ ] **Step 1: Start** —
`python -c "import json,urllib.request as u; print(u.urlopen(u.Request('http://127.0.0.1:8389/factory', json.dumps({'rungId':'structure-house','supervised':True}).encode(), {'Content-Type':'application/json'})).read().decode())"`
- [ ] **Step 2: Watch** — poll `/factory/status` to `done`.
- [ ] **Step 3: Judge** — newest transcripts + capture PNGs (Read) + `GET /references?query=cottage house exterior&count=3`; compare.
- [ ] **Step 4: Flip proven only on a credible pass**; commit `"feat(curriculum): structure-house proven — supervised first ascent"`.

### Task 8: Supervised first ascent — `gui-main-menu`

- [ ] **Step 1: Start** —
`python -c "import json,urllib.request as u; print(u.urlopen(u.Request('http://127.0.0.1:8389/factory', json.dumps({'rungId':'gui-main-menu','supervised':True}).encode(), {'Content-Type':'application/json'})).read().decode())"`
- [ ] **Step 2: Watch** — poll `/factory/status` to `done`.
- [ ] **Step 3: Judge** — transcripts + the playtest_capture PNG of the rendered menu (Read it; layout/readability, not references — GUI verify grades against the GUI rubric).
- [ ] **Step 4: Flip proven only on a credible pass**; commit `"feat(curriculum): gui-main-menu proven — supervised first ascent"`.

### Task 9: Supervised first ascent — `anim-idle-breathe`

- [ ] **Step 1: Start** —
`python -c "import json,urllib.request as u; print(u.urlopen(u.Request('http://127.0.0.1:8389/factory', json.dumps({'rungId':'anim-idle-breathe','supervised':True}).encode(), {'Content-Type':'application/json'})).read().decode())"`
- [ ] **Step 2: Watch** — poll `/factory/status` to `done`.
- [ ] **Step 3: Judge** — transcripts + the capture_animation filmstrip PNGs (Read them frame by frame; breathing/weight-shift must read, no foot-slide).
- [ ] **Step 4: Flip proven only on a credible pass**; commit `"feat(curriculum): anim-idle-breathe proven — supervised first ascent"`.

### Task 10: Relaunch the loop on the focus rotation

- [ ] **Step 1: Launch** —
`python -c "import json,urllib.request as u; print(u.urlopen(u.Request('http://127.0.0.1:8389/forever', json.dumps({'cycles':30}).encode(), {'Content-Type':'application/json'})).read().decode())"`
(no `families` arg — the curriculum focus list is now the default filter; rotation = proven families among the focus five).
- [ ] **Step 2: Confirm rotation** — `GET /forever/status` after cycle 1–2: `family` values only from the focus set; no `game-system`, no `melee-enemy`.
- [ ] **Step 3: Arm the quiet monitor** (every-5-cycles cadence, END/error events) as in the prior run, reporting the active model + cycle family.
- [ ] **Step 4: Commit any curriculum/staging drift** at the end of the session.
