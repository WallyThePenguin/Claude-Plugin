"""factory.py  -  headless single-rung factory iteration (the unattended learning loop).

The factory-iteration workflow (docs/superpowers/workflows/factory-iteration.workflow.js) proved
the BUILD -> GATE -> VERIFY -> STAGE discipline, but it runs under the Claude Code / Workflow
harness (attended). This module runs the same discipline with NO attended session  -  just the
sidecar + Studio + the model tunnel  -  by driving the intelligent stages through the sidecar-side
agent loop (LoopRunner) and the mechanical stages through the dev bridge directly:

  BUILD   -> a loop run: the model builds the rung in the live place, ends with FACTORY_BUILD_JSON.
  GATE    -> one bridge luau call: walk the artifact for reserved test symbols (mechanical).
  VERIFY  -> a loop run: a skeptic drives a real playtest, ends with FACTORY_VERIFY_JSON.
  STAGE   -> write the staging entry to the git-tracked store + move/destroy the artifact.

Charter safety carried over verbatim: PROPOSE-ONLY (this never promotes  -  it only stages evidence
for a human), NO unmanned first ascents (proven=false rungs are refused), an unavailable oracle is
UNVERIFIED never PASSED, and any StudioAgentTest_* / TestAutoKill symbol BLOCKS the rung.

Single-flight: BUILD and VERIFY reuse the ONE LoopRunner (never two loops at once); a factory-busy
flag fences external /loop and /agent for the whole iteration (server.py wires it).
"""

import json
import os
import re
import threading
import time

BUILD_JSON_RE = re.compile(r"FACTORY_BUILD_JSON:\s*(\{.*\})", re.DOTALL)
VERIFY_JSON_RE = re.compile(r"FACTORY_VERIFY_JSON:\s*(\{.*\})", re.DOTALL)

STAGE_TIMEOUT = 90.0
GATE_TIMEOUT = 90.0
LOOP_POLL = 1.0
LOOP_WAIT_CAP = 50 * 60.0  # a hair over the loop's own 45-min wall-clock cap

# Reserved symbols that block extraction (kept in sync with the workflow's GATE).
RESERVED_PREFIX = "StudioAgentTest_"
DENYLIST = ["TestAutoKill"]


class FactoryError(ValueError):
    """Client error  -  maps to HTTP 400/409."""


def _last_json(text: str, pattern):
    """Parse the LAST match of pattern in text as JSON, or None. Trailing prose after the
    closing brace is tolerated by retrying on progressively shorter suffixes of the capture."""
    if not text:
        return None
    m = None
    for m in pattern.finditer(text):
        pass
    if m is None:
        return None
    blob = m.group(1).strip()
    # The greedy .* can swallow trailing prose; peel back to the last balanced-looking brace.
    for end in range(len(blob), 0, -1):
        if blob[end - 1] != "}":
            continue
        try:
            return json.loads(blob[:end])
        except ValueError:
            continue
    return None


def _gate_luau(artifact_path: str) -> str:
    """Luau that walks the artifact + descendants for reserved test symbols. Returns
    'GATE_CLEAN' or 'GATE_HITS:' + a ';'-joined list."""
    deny = "{ " + ", ".join(f'["{d}"] = true' for d in DENYLIST) + " }"
    return f"""
local RESERVED = "{RESERVED_PREFIX}"
local DENY = {deny}
local target = "{artifact_path}"
local node = game
for seg in string.gmatch(target, "[^.]+") do
  if seg ~= "game" then node = node and node:FindFirstChild(seg) end
end
if not node then return "GATE_MISSING" end
local hits = {{}}
local function bad(s) return (string.find(s, RESERVED, 1, true) ~= nil) or (DENY[s] == true) end
local function check(inst)
  if bad(inst.Name) then table.insert(hits, "name:" .. inst:GetFullName()) end
  for k in pairs(inst:GetAttributes()) do
    if bad(k) then table.insert(hits, "attr:" .. inst:GetFullName() .. "." .. k) end
  end
  if inst:IsA("LuaSourceContainer") then
    local ok, src = pcall(function()
      return game:GetService("ScriptEditorService"):GetEditorSource(inst)
    end)
    if ok and type(src) == "string"
      and (string.find(src, RESERVED, 1, true) or string.find(src, "TestAutoKill", 1, true)) then
      table.insert(hits, "source:" .. inst:GetFullName())
    end
  end
end
check(node)
for _, d in ipairs(node:GetDescendants()) do check(d) end
if #hits == 0 then return "GATE_CLEAN" end
return "GATE_HITS:" .. table.concat(hits, ";")
"""


class FactoryRunner:
    def __init__(self, loop_runner, bridge, curriculum_path, store_writer, sleep=time.sleep):
        self._loop = loop_runner
        self._bridge = bridge
        self._curriculum_path = curriculum_path
        self._write_store = store_writer
        self._sleep = sleep
        self._lock = threading.Lock()
        self._busy = False
        self._counter = 0
        self._status = {"state": "idle"}

    # -- public --

    def busy(self) -> bool:
        with self._lock:
            return self._busy

    def status(self) -> dict:
        with self._lock:
            return json.loads(json.dumps(self._status))

    def start(self, rung_id, sabotage=False, variant_hint=None, staging_id=None) -> int:
        if not isinstance(rung_id, str) or not rung_id.strip():
            raise FactoryError("rungId is required")
        rung = self._find_rung(rung_id.strip())
        if rung is None:
            raise FactoryError(f"unknown rung '{rung_id}'")
        if not rung.get("proven"):
            # Charter: no unmanned first ascents. A proven=false rung needs a supervised session.
            raise FactoryError(
                f"rung '{rung_id}' is not proven  -  first ascents must be supervised, not headless"
            )
        with self._lock:
            if self._busy or self._loop.status().get("state") == "running":
                raise FactoryError("a factory or loop run is already active  -  one at a time")
            self._busy = True
            self._counter += 1
            run_id = self._counter
            self._status = {
                "state": "running",
                "id": run_id,
                "rung": rung_id.strip(),
                "sabotage": bool(sabotage),
                "stage": "build",
                "startedAt": time.time(),
            }
        threading.Thread(
            target=self._run,
            args=(run_id, rung, bool(sabotage), variant_hint, staging_id),
            daemon=True,
        ).start()
        return run_id

    # -- internals --

    def _set(self, **kv):
        with self._lock:
            self._status.update(kv)

    def _find_rung(self, rung_id: str):
        with open(self._curriculum_path, encoding="utf-8") as fh:
            curriculum = json.load(fh)
        for rung in curriculum.get("rungs", []):
            if rung.get("id") == rung_id:
                return rung
        return None

    def _finish(self, **kv):
        with self._lock:
            self._status.update(kv)
            self._busy = False

    def _run(self, run_id, rung, sabotage, variant_hint=None, staging_id=None):
        try:
            self._run_inner(run_id, rung, sabotage, variant_hint, staging_id)
        except Exception as exc:  # noqa: BLE001  -  never leave _busy stuck
            self._finish(state="error", error=f"internal factory error: {exc!r}")

    def _wait_loop(self, prompt, max_iterations, stage):
        """Run one loop to completion; return (ok, final_text, err)."""
        self._loop.start(prompt, max_iterations=max_iterations)
        deadline = time.monotonic() + LOOP_WAIT_CAP
        while time.monotonic() < deadline:
            st = self._loop.status()
            state = st.get("state")
            self._set(loopIteration=st.get("iteration"), loopToolCalls=st.get("toolCalls"))
            if state == "done":
                return True, str(st.get("result") or ""), None
            if state == "error":
                return False, "", str(st.get("error") or "loop error")
            self._sleep(LOOP_POLL)
        return False, "", f"{stage} loop exceeded {LOOP_WAIT_CAP:.0f}s"

    def _run_inner(self, run_id, rung, sabotage, variant_hint=None, staging_id=None):
        rung_id = rung["id"]
        playbook = _playbook(rung)
        # Self-heal: if a PRIOR run's verify sandbox was interrupted (sidecar killed before its
        # teardown finally ran), its scripts are still disabled — re-enable them before we build,
        # so the game isn't left broken across runs.
        self._bridge.call({"kind": "luau", "code": _SANDBOX_OFF_LUAU}, GATE_TIMEOUT)
        result = {"rung": rung_id, "sabotage": sabotage, "family": rung.get("family")}

        # ---- BUILD ----
        self._set(stage="build")
        ok, text, err = self._wait_loop(
            _build_prompt(rung, sabotage, playbook, variant_hint), max_iterations=45, stage="build"
        )
        if not ok:
            return self._finish(state="done", status="BLOCKED", reason=f"build: {err}", **result)
        build = _last_json(text, BUILD_JSON_RE)
        if not build or not build.get("ok") or not build.get("artifactPath"):
            return self._finish(
                state="done", status="BLOCKED", reason="build produced no FACTORY_BUILD_JSON", **result
            )
        result["build"] = build

        # ---- GATE ----
        self._set(stage="gate")
        gate = self._bridge.call(
            {"kind": "luau", "code": _gate_luau(build["artifactPath"])}, GATE_TIMEOUT
        )
        gate_text = "" if not gate else str(gate.get("result") or "")
        if gate is None or gate.get("_timeout") or "GATE_CLEAN" not in gate_text:
            reason = "gate found test symbols" if "GATE_HITS" in gate_text else "gate could not verify a clean artifact"
            self._destroy_artifact(build["artifactPath"])
            return self._finish(
                state="done", status="BLOCKED", reason=reason, gate=gate_text, **result
            )

        # ---- VERIFY ----
        self._set(stage="verify")
        # A runtime playbook drives a playtest of the LIVE game  -  sandbox it first so the game's
        # own mobs/round loop don't chase and kill the tester mid-measure ("clear" also removes
        # stray enemy rigs; "keep" leaves the rung's own test enemy alone).
        sandbox = playbook.get("sandbox")
        if sandbox:
            self._verify_sandbox(True, clear=(sandbox == "clear"))
        try:
            ok, text, err = self._wait_loop(
                _verify_prompt(rung, build, playbook), max_iterations=36, stage="verify"
            )
        finally:
            if sandbox:
                self._verify_sandbox(False)
            # Deterministic teardown: a verify that hit the iteration cap may not have called
            # playtest_stop, leaving a ZOMBIE session that blocks the NEXT verify. Force-stop it.
            if playbook.get("kind") == "runtime":
                self._bridge.call(
                    {"kind": "luau", "code": 'pcall(function() game:GetService("RunService"):Stop() end) return "stopped"'},
                    GATE_TIMEOUT,
                )
        verify = _last_json(text, VERIFY_JSON_RE) if ok else None
        if not verify or verify.get("status") not in ("PASSED", "FAILED", "UNVERIFIED"):
            verify = {"status": "UNVERIFIED", "reasons": [err or "verify produced no verdict"]}
        result["verify"] = verify
        status = verify["status"]

        # ---- STAGE ----
        self._set(stage="stage")
        if status == "PASSED":
            self._move_to_staging(build["artifactPath"], build.get("toolName") or rung_id)
        else:
            self._destroy_artifact(build["artifactPath"])
        # Restore whatever the build parked out of StarterPack so the place is left as found
        # (the artifact itself is now either in FactoryStaging or destroyed)  -  this runs on EVERY
        # outcome, matching the attended workflow's STAGE step.
        parked = build.get("parked")
        if isinstance(parked, list) and parked:
            self._bridge.call({"kind": "luau", "code": _restore_luau(parked)}, STAGE_TIMEOUT)
        staging_id = staging_id or _staging_id(rung_id, sabotage)
        entry = {
            "rung": rung_id,
            "sabotage": sabotage,
            "status": status,
            "gate": "clean",
            "evidence": verify.get("evidence"),
            "reasons": verify.get("reasons", []),
            "artifactTrace": {
                "path": build.get("artifactPath"),
                "config": build.get("config"),
                "steps": build.get("steps"),
            },
            "recipe": {"provisional": True, "text": build.get("notes", "")},
            "stagedAt": time.time(),
            "headless": True,
        }
        try:
            self._write_store("staging", staging_id, entry)
            staged = True
        except Exception as exc:  # noqa: BLE001
            staged = False
            result["stageError"] = repr(exc)
        self._finish(
            state="done", status=status, staged=staged, stagingId=staging_id, **result
        )

    def _verify_sandbox(self, on: bool, clear: bool = False):
        code = (_SANDBOX_ON_LUAU % ("true" if clear else "false")) if on else _SANDBOX_OFF_LUAU
        self._bridge.call({"kind": "luau", "code": code}, STAGE_TIMEOUT)

    def _destroy_artifact(self, path: str):
        self._bridge.call({"kind": "luau", "code": _destroy_luau(path)}, STAGE_TIMEOUT)

    def _move_to_staging(self, path: str, name: str):
        self._bridge.call({"kind": "luau", "code": _stage_luau(path, name)}, STAGE_TIMEOUT)


def _staging_id(rung_id: str, sabotage: bool) -> str:
    return f"{rung_id}-sabotaged" if sabotage else rung_id


def _destroy_luau(path: str) -> str:
    return f"""
local node = game
for seg in string.gmatch("{path}", "[^.]+") do
  if seg ~= "game" then node = node and node:FindFirstChild(seg) end
end
if node then node:Destroy() return "DESTROYED" end
return "ALREADY_GONE"
"""


def _restore_luau(parked) -> str:
    """Move each parked instance (by its CURRENT path in ServerStorage) back to StarterPack."""
    paths = [p for p in parked if isinstance(p, str)][:16]
    lua_list = ", ".join(json.dumps(p) for p in paths)
    return f"""
local StarterPack = game:GetService("StarterPack")
local moved = 0
for _, target in ipairs({{ {lua_list} }}) do
  local node = game
  for seg in string.gmatch(target, "[^.]+") do
    if seg ~= "game" then node = node and node:FindFirstChild(seg) end
  end
  if node then node.Parent = StarterPack moved = moved + 1 end
end
return "RESTORED:" .. moved
"""


_SANDBOX_ON_LUAU = """
-- VERIFY SANDBOX: stop the live game from swarming the tester. Disable round/wave/spawner
-- scripts (marked so teardown re-enables exactly them) and, when clearing, remove stray enemy
-- rigs  -  so the playtest is a CALM arena with just the player + the VerifyTarget.
local sss = game:GetService("ServerScriptService")
local n = 0
for _, s in ipairs(sss:GetDescendants()) do
  if (s:IsA("BaseScript")) and not s.Disabled then
    local nm = string.lower(s.Name)
    if nm:find("round") or nm:find("wave") or nm:find("spawn") or nm:find("enemy") or nm:find("mob") then
      s.Disabled = true
      s:SetAttribute("SAVerifyDisabled", true)
      n += 1
    end
  end
end
if %s then
  for _, m in ipairs(workspace:GetChildren()) do
    if m:FindFirstChildOfClass("Humanoid") and m.Name ~= "VerifyTarget" then
      local nm = string.lower(m.Name)
      if nm:find("husk") or nm:find("enemy") or nm:find("mob") or m:GetAttribute("StudioAgentGenerated") then
        m:Destroy()
      end
    end
  end
end
return "sandbox on: " .. n .. " scripts disabled"
"""

_SANDBOX_OFF_LUAU = """
-- restore the game: re-enable exactly the scripts the sandbox disabled.
local sss = game:GetService("ServerScriptService")
local restored = 0
for _, s in ipairs(sss:GetDescendants()) do
  if s:GetAttribute("SAVerifyDisabled") then
    s.Disabled = false
    s:SetAttribute("SAVerifyDisabled", nil)
    restored += 1
  end
end
return "sandbox off: restored " .. restored .. " scripts"
"""


def _stage_luau(path: str, name: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9_]", "_", name) or "Artifact"
    return f"""
local ServerStorage = game:GetService("ServerStorage")
local folder = ServerStorage:FindFirstChild("FactoryStaging")
if not folder then folder = Instance.new("Folder") folder.Name = "FactoryStaging" folder.Parent = ServerStorage end
local node = game
for seg in string.gmatch("{path}", "[^.]+") do
  if seg ~= "game" then node = node and node:FindFirstChild(seg) end
end
if not node then return "MISSING" end
node.Name = "{safe}"
node.Parent = folder
return "STAGED"
"""


# ---- domain playbooks (this is what makes the factory build ANYTHING, not just weapons) ----
#
# The pipeline (BUILD->GATE->VERIFY->STAGE, loop, staging) is domain-general. Only the BUILD and
# VERIFY *procedures* differ by domain, so each family maps to a playbook: `build` = how to build
# this kind of thing, `verify` = how to prove it. `kind` picks the verification mode:
#   runtime = drive a playtest and probe live state (weapons, enemies, systems);
#   visual  = capture the artifact + get_references + grade against the rubric (buildings,
#             animations, environments, GUI look)  -  the reference-first image-learning path.
# To make the factory build a NEW category, add a curriculum rung (brief+oracle+family) and, if the
# family is new, a playbook entry  -  no pipeline changes.

_WEAPON_VERIFY = (
    "The game's round/wave/spawner scripts are auto-disabled and stray mobs cleared for this verify "
    "(a CALM sandbox - the tester will NOT be swarmed). "
    "CRITICAL SEQUENCING: the test target must exist in EDIT mode BEFORE playtest_start so it is "
    "baked into the play snapshot - a dummy/probe created AFTER the snapshot is NOT in the running "
    "session and forces a restart loop. So:\n"
    "(1) In EDIT (no playtest running), run_luau to place a GOD-MODE self-measuring target near "
    "spawn: clone game.ServerStorage.VerifyDummy into workspace as 'VerifyTarget' (if VerifyDummy is "
    "absent, clone EnemyTemplate, delete its scripts, add a Script that on Humanoid.HealthChanged "
    "records (MaxHealth-health) to the model's 'LastDamage' attribute + increments 'HitCount' then "
    "resets Health=MaxHealth), set Humanoid.MaxHealth=10000, anchor every BasePart, and PivotTo ~6 "
    "studs in front of the SpawnLocation. This dummy HEALS after every hit (it never dies -> no "
    "restart loop) and records each hit's damage on ITSELF (no separate probe to sequence).\n"
    "The dummy PRINTS each hit to the log as `[VerifyTarget] HIT damage=<n> hitcount=<n>`, so the "
    "damage readout needs NO playtest_eval/loadstring (which is usually disabled).\n"
    "(2) playtest_start; (3) playtest_act record  -  the echo ends [tool=<name> w=<x> a=<y> c=<z>]: "
    "FAIL if the tool name or echoed config does not match the build's config; (4) DAMAGE: walk the "
    "player up to the VerifyTarget (~6 studs ahead of spawn), face it, and playtest_act activate to "
    "swing 2-3 times; (5) playtest_logs since 0 and read the `[VerifyTarget] HIT damage=` lines  -  "
    "FAIL unless a hit's damage EXACTLY equals the configured damage (a broken or sabotaged weapon "
    "prints NO hit line  -  hitcount stays 0), and FAIL on any error mentioning the artifact; (6) "
    "ALWAYS playtest_stop, then destroy workspace.VerifyTarget in edit."
)
_ENEMY_VERIFY = (
    "The PLAYER is the enemy's target. Give the player GOD MODE that LOGS each hit, so the readout "
    "needs NO playtest_eval/loadstring (which is usually disabled - eval will fail):\n"
    "(1) In EDIT before playtest (baked into the snapshot): (a) add a StarterCharacterScripts "
    "Script that on the player Humanoid.HealthChanged, if health dropped, WARNs "
    "'[PlayerHit] damage=<MaxHealth-health>' and then resets Health=MaxHealth (invincible + "
    "self-reporting to the log); (b) POSITION the test enemy ~8 studs from the SpawnLocation (well "
    "within its DetectRange) so it detects+chases+attacks the spawning player IMMEDIATELY - do NOT "
    "rely on walking the player across the map. (2) playtest_start; (3) wait through a couple of the "
    "enemy's attack cooldowns (it should close and strike the stationary god-mode player); (4) "
    "playtest_logs since 0 and read the '[PlayerHit] damage=' lines - FAIL "
    "unless the enemy deals the configured damage (NO hit lines = the enemy never attacked = FAIL), "
    "and FAIL on any error mentioning the artifact; (5) ALWAYS playtest_stop. Do NOT rely on "
    "playtest_eval."
)
# Reference-first image learning (the standing mandate): every recognizable artifact is built
# against real reference photos and checked by capture, never from memory alone. Injected into
# the BUILD prompt of every playbook except script-only families (vision=False).
_VISION_BUILD = (
    "BUILD WITH VISION - never from memory alone:\n"
    "(a) BEFORE building the visual, get_references for the real-world thing the brief names "
    "(the weapon, creature, structure, space, or motion; 2-4 images) and note the signature "
    "features and proportions the references show - those are your build targets;\n"
    "(b) once the visual is assembled, capture_angles it (count 3-4, e.g. front/left/iso - NOT "
    "the default 6, which floods the image window) and COMPARE what you SEE against the "
    "reference features - if a signature feature is missing or proportions are off, fix the "
    "concrete mismatches and re-capture ONCE;\n"
    "(c) then STOP the visual work - two capture rounds max; this is a scoped build, not an art "
    "pass. If get_references errors, say so in notes and build on - do not stall."
)

_VISUAL_VERIFY = (
    "This is judged VISUALLY, not by a runtime probe: (1) get_references for what the brief "
    "describes FIRST and list the signature features/proportions real examples show; (2) "
    "capture_angles of the artifact from several sides; (3) grade it feature-by-feature against "
    "the references AND the matching rubric (use_rubric)  -  scale vs the 5-stud character, "
    "silhouette, the parts the brief requires, material/colour coherence; PASS only if it clearly "
    "reads as the intended thing AND clears the above-generic bar; FAILED with the specific gaps if "
    "not; UNVERIFIED if you cannot capture."
)
_SYSTEM_VERIFY = (
    "Verify from the LOG only (playtest_eval/loadstring is usually disabled - do NOT rely on it). "
    "Full end-to-end VICTORY needs winning the whole game, which is out of scope for an automated "
    "check - instead confirm the system RUNS and PROGRESSES observably:\n"
    "(1) playtest_start; (2) read playtest_logs since 0, then again after ~15-25s (the system needs "
    "time to run) - confirm the lifecycle is observable in the logs: the system STARTS (e.g. a wave/"
    "round begins), enemies/state SPAWN or advance, and it PROGRESSES (a wave clears or the next "
    "begins, or a state transition fires) with NO runtime error mentioning the artifact; (3) PASS if "
    "that progression is clearly logged at PLAYER level (never via an auto-kill/test hook - those are "
    "gate-blocked); FAIL if it errors or never starts; UNVERIFIED only if the playtest will not run; "
    "(4) ALWAYS playtest_stop."
)

PLAYBOOKS = {
    "melee-weapon": {
        "kind": "runtime",
        "sandbox": "clear",
        "config": '{"windup":<n>,"active":<n>,"cooldown":<n>,"damage":<n>,"reach":<n>}',
        "build": (
            "(1) park any Tools in StarterPack into ServerStorage and report their new paths in "
            "'parked' so STAGE restores them; (2) build a SHAPED above-primitive visual (prefer "
            "generate_mesh + save_mesh) with a profile distinct to this weapon, reference-matched "
            "per the VISION discipline above; (3) make_tool with the grip as Handle; "
            "(4) move the Tool into StarterPack; (5) bind_behavior with windup/active/cooldown per "
            "the brief's speed; (6) bind_hitbox with reach + damage + cooldown per the brief."
        ),
        "verify": _WEAPON_VERIFY,
    },
    "ranged-weapon": {
        "kind": "runtime",
        "sandbox": "clear",
        "config": '{"windup":<n>,"active":<n>,"cooldown":<n>,"damage":<n>,"range":<n>,"projectileSpeed":<n>}',
        "build": (
            "(1) park StarterPack Tools into ServerStorage (report in 'parked'); (2) build a shaped "
            "visual (mesh preferred), reference-matched per the VISION discipline; (3) make_tool (grip as Handle), move "
            "to StarterPack; (4) bind_behavior for the draw/fire timing; (5) wire the projectile "
            "spawn+flight+contact-damage per the brief."
        ),
        "verify": _WEAPON_VERIFY,
    },
    "melee-enemy": {
        "kind": "runtime",
        "sandbox": "keep",
        "config": '{"damage":<n>,"walkSpeed":<n>,"detectRange":<n>,"attackRange":<n>,"cooldown":<n>}',
        "build": (
            "(1) prepare a rig (spawn_rig or the EnemyTemplate); (2) give it a shaped, above-blob "
            "visual, reference-matched per the VISION discipline; (3) make_npc with the brief's damage/speed/detect/"
            "attack-range/cooldown so it idles, chases in range, and attacks."
        ),
        "verify": _ENEMY_VERIFY,
    },
    "ranged-enemy": {
        "kind": "runtime",
        "sandbox": "keep",
        "config": '{"damage":<n>,"walkSpeed":<n>,"detectRange":<n>,"keepDistance":<n>,"cooldown":<n>}',
        "build": (
            "(1) prepare a rig; (2) shaped visual, reference-matched per the VISION discipline; (3) make_npc that keeps distance "
            "and fires projectiles per the brief."
        ),
        "verify": _ENEMY_VERIFY,
    },
    "animation": {
        "kind": "visual",
        "config": '{"clipName":"<name>","keyframeCount":<n>,"priority":"<Action|Movement|...>"}',
        "build": (
            "(1) use an existing rig or spawn_rig; (2) author the clip as KEYPOSES: pose_joint / "
            "ik_reach into each keypose then add_keyframe to snapshot it, repeated per pose, with "
            "KeyframeMarkers if the brief needs contact/cancel points; (3) the artifact is the clip/"
            "KeyframeSequence. Author with NO preview running; review with capture_animation."
        ),
        "verify": (
            "This is judged VISUALLY: (1) capture_animation as a filmstrip; (2) get_references for "
            "the motion and check the arc/timing/weight; (3) grade against the animation rubric  -  "
            "the motion must READ as the intended action (correct arc, torso lead, no foot-slide, "
            "clean start/end); PASS only if it clearly reads right; FAILED with what's off; "
            "UNVERIFIED if you cannot render the filmstrip."
        ),
    },
    "building": {
        "kind": "visual",
        "config": '{"footprintStuds":<n>,"heightStuds":<n>,"style":"<desc>"}',
        "build": (
            "(1) assemble a Model from primitives and/or meshes: walls, roof, floor, and openings "
            "(doorways ~7 studs so a character fits), scaled to the 5-stud character; coherent "
            "materials and colours; (2) proportion and silhouette reference-matched per the VISION "
            "discipline; the artifact is the Model in Workspace."
        ),
        "verify": _VISUAL_VERIFY,
    },
    "environment": {
        "kind": "visual",
        "config": '{"theme":"<desc>","areaStuds":<n>}',
        "build": (
            "(1) build the described space  -  terrain and/or parts, plus Lighting/Atmosphere for the "
            "mood; (2) scale and coherence reference-matched per the VISION discipline; the artifact "
            "is the Model/Folder of the environment set (report its path)."
        ),
        "verify": _VISUAL_VERIFY,
    },
    "gui": {
        "kind": "runtime",
        "sandbox": "keep",
        # no Wikimedia reference pass: game HUDs aren't a photo subject; verify already
        # playtest_captures the rendered screen and grades it against the GUI rubric.
        "vision": False,
        "config": '{"screen":"<name>","elements":["..."]}',
        "build": (
            "(1) build a ScreenGui in StarterGui with the described elements  -  frames, buttons, "
            "labels, laid out with UIListLayout/UIPadding, styled with UICorner/UIStroke and "
            "readable fonts; (2) wire any RemoteEvent/handler the brief calls for; the artifact is "
            "the ScreenGui (report its path)."
        ),
        "verify": (
            "(1) playtest_start; (2) playtest_capture to SEE it render on the player's screen  -  FAIL "
            "if it does not appear, overlaps, or is unreadable; (3) if the brief specifies an "
            "interaction (button -> effect), drive it via playtest_act/playtest_eval and confirm "
            "the effect; (4) grade layout/readability against the GUI rubric; (5) ALWAYS "
            "playtest_stop."
        ),
    },
    "game-system": {
        "kind": "runtime",
        "vision": False,  # the artifact is a script - nothing recognizable to reference or capture
        # NO sandbox: a game-system rung IS the round/wave/spawn logic, so disabling those scripts
        # would disable the very system under test. Verify runs the game LIVE and reads the outcome
        # from playtest_logs (server-authoritative — the player dying doesn't stop the wave loop).
        "config": '{"systemName":"<name>","params":{}}',
        "build": (
            "(1) author the server script(s) for the system (config-driven, RoundLoop-style) via "
            "create_instance/edit_script; keep it scoped to the brief's lifecycle; PRINT the "
            "lifecycle events (system start, each wave/round start, spawn, wave clear, victory) with "
            "a clear tag like '[System]' so VERIFY can observe progression via playtest_logs; the "
            "artifact is the script/system (report its path). Do NOT wire any auto-kill/test hook - "
            "GATE blocks those symbols."
        ),
        "verify": _SYSTEM_VERIFY,
    },
    "_default": {
        "kind": "visual",
        "config": "{}",
        "build": (
            "Build exactly what the brief describes with the most appropriate tools, scoped  -  no "
            "gold-plating. Report the artifact's instance path and the config VERIFY needs."
        ),
        "verify": (
            "Verify per the ORACLE. If it has observable runtime behaviour, playtest and probe it; "
            "if it is visual/aesthetic, get_references + capture and grade against the brief and the "
            "matching rubric. UNVERIFIED if you cannot gather real evidence  -  never PASSED on a "
            "guess."
        ),
    },
}

# category -> playbook, used when a rung has no (or an unknown) family.
_CATEGORY_FALLBACK = {"combat": "melee-weapon", "npc": "melee-enemy", "gui": "gui"}


def _playbook(rung) -> dict:
    fam = rung.get("family")
    if fam in PLAYBOOKS:
        return PLAYBOOKS[fam]
    cat = _CATEGORY_FALLBACK.get(rung.get("category"))
    if cat in PLAYBOOKS:
        return PLAYBOOKS[cat]
    return PLAYBOOKS["_default"]


def _build_prompt(rung, sabotage: bool, playbook: dict, variant_hint=None) -> str:
    sabotage_line = (
        "SABOTAGE RUN: deliberately break the ONE thing the ORACLE checks (for a weapon skip the "
        "hitbox; for a system omit the win condition; for a visual omit the required feature) and "
        "do NOT mention the omission anywhere  -  this tests whether VERIFY catches it.\n\n"
        if sabotage
        else ""
    )
    variant_line = (
        f"AUTONOMOUS VARIATION: {variant_hint} Build a FRESH, distinct concept within the brief's "
        "family  -  not a repeat of what already exists.\n\n"
        if variant_hint
        else ""
    )
    return (
        f"You are the headless factory BUILD stage for curriculum rung '{rung['id']}' "
        f"(category: {rung.get('category', '?')}, family: {rung.get('family', '?')}).\n"
        f"BRIEF: {rung.get('brief', '')}\n"
        f"ORACLE (what VERIFY will check): {rung.get('oracle', '')}\n\n"
        f"{variant_line}"
        "Build ONLY what the brief asks, using the approach below, then STOP and emit the JSON. "
        "This is a SCOPED build stage: do NOT gold-plate, do NOT add features from other rungs "
        "(extra animations, polish passes, unrelated systems), do NOT playtest (that is VERIFY's "
        "job)  -  over-building burns the iteration budget and FAILS the run. Never create anything "
        "named or attributed StudioAgentTest_* or TestAutoKill.\n\n"
        + (f"{_VISION_BUILD}\n\n" if playbook.get("vision", True) else "")
        + f"APPROACH for this {rung.get('family', 'artifact')}:\n{playbook['build']}\n\n"
        f"{sabotage_line}"
        "The MOMENT the core artifact is complete, your VERY NEXT message must be ONLY the JSON "
        "line (emit it well before iteration 40, no polish first). End that message with EXACTLY "
        "ONE line, no code fence:\n"
        'FACTORY_BUILD_JSON: {"ok":true,"artifactPath":"<full instance path, e.g. '
        'game.Workspace.Barn or game.StarterPack.Spear>","artifactKind":"<Tool|Model|ScreenGui|'
        'KeyframeSequence|Script|Folder>","config":' + playbook["config"] + ','
        '"parked":["<any path you moved out of StarterPack, to restore>"],"steps":["..."],'
        '"notes":"<3-6 line recipe of how you built it>"}\n'
        'If you could not complete the build, emit that line with "ok":false and a notes reason.'
    )


def _verify_prompt(rung, build, playbook: dict) -> str:
    return (
        f"You are the headless factory VERIFY stage for rung '{rung['id']}'  -  a SKEPTIC whose job "
        f"is to find reasons to FAIL. Artifact: {build.get('artifactPath')} "
        f"(kind: {build.get('artifactKind', '?')}). Config: {json.dumps(build.get('config'))}.\n"
        f"ORACLE: {rung.get('oracle', '')}\n\n"
        f"VERIFY APPROACH for this {rung.get('family', 'artifact')}, ONE step at a time:\n"
        f"{playbook['verify']}\n\n"
        "If ANY oracle step is unavailable (playtest will not start, a probe errors, you cannot "
        "capture), status=UNVERIFIED with the reason  -  NEVER PASSED on partial evidence, and NEVER "
        "PASSED on a visual that merely 'looks okay' without meeting the brief.\n\n"
        "BUDGET: the MOMENT you have the oracle evidence (the pass/fail is decided), do your "
        "playtest_stop + brief cleanup and emit the JSON verdict immediately - do NOT keep probing. "
        "Emit the verdict well before iteration 32, or the run is lost to the cap as UNVERIFIED.\n\n"
        "End your FINAL message with EXACTLY ONE line, no code fence:\n"
        'FACTORY_VERIFY_JSON: {"status":"PASSED|FAILED|UNVERIFIED","evidence":{"summary":'
        '"<verbatim probe output OR capture-vs-reference findings>"},"reasons":["..."]}'
    )
