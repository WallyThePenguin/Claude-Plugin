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
import zlib

BUILD_JSON_RE = re.compile(r"FACTORY_BUILD_JSON:\s*(\{.*\})", re.DOTALL)
VERIFY_JSON_RE = re.compile(r"FACTORY_VERIFY_JSON:\s*(\{.*\})", re.DOTALL)

STAGE_TIMEOUT = 90.0
GATE_TIMEOUT = 90.0
LOOP_POLL = 1.0
LOOP_WAIT_CAP = 50 * 60.0  # a hair over the loop's own 45-min wall-clock cap

# Self-improvement feedback: lessons banked by the RETRO stage (forever.py) + the plugin's
# per-category quality lessons are injected into every BUILD/VERIFY prompt.
LEARNINGS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "store", "learnings")
_FAMILY_BUCKET = {
    "melee-weapon": "weapons",
    "ranged-weapon": "weapons",
    "melee-enemy": "npc",
    "ranged-enemy": "npc",
    "building": "environment",
    "environment": "environment",
    "gui": "gui",
    "animation": "characters",
    "game-system": "combat",
}


def _learned_block(family) -> str:
    """Newest factory-method lessons + the family's quality lessons as a prompt block.
    Missing/corrupt files mean no block — this must never fail a run."""
    picks = []
    sources = [("factory-methods.json", 8)]
    bucket = _FAMILY_BUCKET.get(family or "")
    if bucket:
        sources.append((bucket + ".json", 6))
    for fname, count in sources:
        try:
            with open(os.path.join(LEARNINGS_DIR, fname), encoding="utf-8") as fh:
                entries = json.load(fh).get("entries") or []
        except (OSError, ValueError):
            continue
        for e in entries[-count:]:
            e = e if isinstance(e, dict) else {}
            t = str(e.get("text") or "").strip()
            if not t:
                continue
            tier = e.get("tier")
            picks.append((f"[{tier}] " if tier else "") + t)
    if not picks:
        return ""
    return (
        "LEARNED METHODS (banked from past cycles - apply these FIRST):\n"
        + "\n".join("- " + t for t in picks)
        + "\nTier rule: a [symbolic-only] lesson is an unconfirmed hypothesis from oracle "
        "numbers alone - try it, but NEVER cite it as settled method; [capture-confirmed] and "
        "then [playtest-confirmed] carry increasing weight. Untagged lessons predate tiers.\n\n"
    )


MAX_TOOLING_ISSUES = 40
TOOLING_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "factory", "tooling-issues.json"
)


def append_tooling_issues(issues, path):
    """Append tooling defects to the mechanic's backlog file, deduped by title (shared by
    forever's RETRO stage and the factory's capture-audit oracle-bug filing)."""
    if not issues:
        return
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        data = {"issues": []}
    bucket = data.setdefault("issues", [])
    by_title = {i.get("title"): i for i in bucket if isinstance(i, dict)}
    for issue in issues:
        title = str(issue.get("title"))[:200]
        if title in by_title:
            by_title[title]["seenCount"] = int(by_title[title].get("seenCount") or 1) + 1
            by_title[title]["lastSeenAt"] = int(time.time())
            continue
        bucket.append({
            "title": title,
            "symptom": str(issue.get("symptom") or "")[:600],
            "suspectFiles": issue.get("suspectFiles") or [],
            "repro": str(issue.get("repro") or "")[:600],
            "seenCount": 1,
            "lastSeenAt": int(time.time()),
        })
    del bucket[:-MAX_TOOLING_ISSUES]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=1)


AUDIT_EVERY = 5


def _audit_pick(token) -> bool:
    """Deterministic 1-in-AUDIT_EVERY selection keyed on the run token (spec §3: the stochastic
    capture audit must be reproducible, not random)."""
    return zlib.crc32(str(token).encode("utf-8")) % AUDIT_EVERY == 0


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
    def __init__(self, loop_runner, bridge, curriculum_path, store_writer, sleep=time.sleep,
                 tooling_path=None):
        self._loop = loop_runner
        self._bridge = bridge
        self._curriculum_path = curriculum_path
        self._write_store = store_writer
        self._sleep = sleep
        self._tooling_path = tooling_path or TOOLING_PATH
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

    def start(self, rung_id, sabotage=False, variant_hint=None, staging_id=None, supervised=False) -> int:
        if not isinstance(rung_id, str) or not rung_id.strip():
            raise FactoryError("rungId is required")
        rung = self._find_rung(rung_id.strip())
        if rung is None:
            raise FactoryError(f"unknown rung '{rung_id}'")
        if not rung.get("proven") and not supervised:
            # Charter: no unmanned first ascents. supervised=True is for interactive sessions where
            # a human-present operator judges the evidence; the forever loop NEVER sets it.
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

    def _narrate(self, text, warn=False):
        """Live commentary into Studio's Output window (best-effort — never breaks a run)."""
        try:
            self._bridge.call({"kind": "narrate", "text": str(text)[:400], "warn": bool(warn)}, 15)
        except Exception:  # noqa: BLE001
            pass

    def _run_inner(self, run_id, rung, sabotage, variant_hint=None, staging_id=None):
        rung_id = rung["id"]
        playbook = _playbook(rung)
        # Self-heal: if a PRIOR run's verify sandbox was interrupted (sidecar killed before its
        # teardown finally ran), its scripts are still disabled — re-enable them before we build,
        # so the game isn't left broken across runs.
        self._bridge.call({"kind": "luau", "code": _SANDBOX_OFF_LUAU}, GATE_TIMEOUT)
        result = {"rung": rung_id, "sabotage": sabotage, "family": rung.get("family")}
        self._narrate(
            f"BUILD {rung_id} ({rung.get('family')}): " + str(rung.get("brief") or "")[:140]
        )

        # ---- BUILD ----
        self._set(stage="build")
        ok, text, err = self._wait_loop(
            _build_prompt(rung, sabotage, playbook, variant_hint),
            max_iterations=_build_iterations(playbook),
            stage="build",
        )
        if not ok:
            self._narrate(f"BUILD blocked: {err}", warn=True)
            return self._finish(state="done", status="BLOCKED", reason=f"build: {err}", **result)
        build = _last_json(text, BUILD_JSON_RE)
        if not build or not build.get("ok") or not build.get("artifactPath"):
            # Keep whatever the build DID say (partial JSON and/or the transcript tail) so the
            # RETRO stage sees the failure cause instead of an all-null record.
            partial = dict(build) if isinstance(build, dict) else {}
            if not partial.get("notes"):
                tail = (text or "").strip()[-600:]
                if tail:
                    partial["notes"] = "no FACTORY_BUILD_JSON; transcript tail: " + tail
            result["build"] = partial
            self._narrate("BUILD blocked: no FACTORY_BUILD_JSON emitted", warn=True)
            return self._finish(
                state="done", status="BLOCKED", reason="build produced no FACTORY_BUILD_JSON", **result
            )
        result["build"] = build
        self._narrate(
            f"BUILD done: {build.get('artifactPath')} - " + str(build.get("notes") or "")[:140]
        )

        # ---- GATE ----
        self._set(stage="gate")
        gate = self._bridge.call(
            {"kind": "luau", "code": _gate_luau(build["artifactPath"])}, GATE_TIMEOUT
        )
        gate_text = "" if not gate else str(gate.get("result") or "")
        if gate is None or gate.get("_timeout") or "GATE_CLEAN" not in gate_text:
            reason = "gate found test symbols" if "GATE_HITS" in gate_text else "gate could not verify a clean artifact"
            self._narrate(f"GATE blocked: {reason}", warn=True)
            self._destroy_artifact(build["artifactPath"])
            return self._finish(
                state="done", status="BLOCKED", reason=reason, gate=gate_text, **result
            )

        # ---- VERIFY ----
        audit = _audit_pick(staging_id or f"{rung_id}#{run_id}")
        self._set(stage="verify", audit=audit)
        self._narrate(
            f"VERIFY {rung_id}{' [AUDIT MODE: full capture cross-check]' if audit else ''}: "
            "gathering edit-first evidence, then the verdict"
        )
        # A runtime playbook drives a playtest of the LIVE game  -  sandbox it first so the game's
        # own mobs/round loop don't chase and kill the tester mid-measure ("clear" also removes
        # stray enemy rigs; "keep" leaves the rung's own test enemy alone).
        sandbox = playbook.get("sandbox")
        if sandbox:
            self._verify_sandbox(True, clear=(sandbox == "clear"))
        try:
            ok, text, err = self._wait_loop(
                _verify_prompt(rung, build, playbook, audit), max_iterations=36, stage="verify"
            )
        finally:
            if sandbox:
                self._verify_sandbox(False)
            # Deterministic teardown: a verify that hit the iteration cap may not have called
            # playtest_stop, leaving a ZOMBIE session that blocks the NEXT verify AND poisons the
            # next build (Studio stuck in play mode). RunService:Stop() alone does NOT end a
            # StudioTestService session — invoke the real playtest_stop tool, then Stop() as a
            # belt-and-suspenders fallback.
            if playbook.get("kind") == "runtime":
                self._bridge.call(
                    {"kind": "tool", "tool": "playtest_stop", "input": {}},
                    GATE_TIMEOUT,
                )
                self._bridge.call(
                    {"kind": "luau", "code": 'pcall(function() game:GetService("RunService"):Stop() end) return "stopped"'},
                    GATE_TIMEOUT,
                )
        verify = _last_json(text, VERIFY_JSON_RE) if ok else None
        if not verify or verify.get("status") not in ("PASSED", "FAILED", "UNVERIFIED"):
            # Keep the transcript tail (like BUILD does) so RETRO sees the failure cause
            # instead of an all-null record with only the generic reason.
            reasons = [err or "verify produced no verdict"]
            tail = (text or "").strip()[-600:]
            if tail:
                reasons.append("no FACTORY_VERIFY_JSON; transcript tail: " + tail)
            verify = {"status": "UNVERIFIED", "reasons": reasons}
        result["verify"] = verify
        if audit:
            result["audit"] = True
            oa = verify.get("oracleAudit")
            dis = oa.get("disagreements") if isinstance(oa, dict) else None
            if not isinstance(dis, list):
                dis = []  # a single-object (or junk) shape from the model must not crash the audit
            bugs = []
            for item in dis[:8]:
                if not isinstance(item, dict) or not item.get("check"):
                    continue
                bugs.append({
                    "title": f"ORACLE BUG: {str(item.get('check'))[:60]} - suite vs capture disagree ({rung_id})",
                    "symptom": f"suite said: {str(item.get('suiteSaid') or '?')[:200]} | capture showed: "
                               f"{str(item.get('captureShowed') or '?')[:200]}",
                    "suspectFiles": ["src/Tools/OracleChecks.luau", "src/Tools/Oracle.luau"],
                    "repro": f"oracle_suite on {build.get('artifactPath')} vs a full capture review "
                             f"(audit run, rung {rung_id})",
                })
            if bugs:
                try:
                    append_tooling_issues(bugs, self._tooling_path)
                    self._narrate(f"AUDIT: {len(bugs)} suite-vs-capture disagreement(s) filed as ORACLE BUGs", warn=True)
                except Exception:  # noqa: BLE001 — filing is best-effort; a wrong-shape
                    # tooling-issues.json (hand-edited, git-tracked) raises AttributeError/
                    # TypeError/ValueError, not just OSError, and must never abort the run
                    # between verify and STAGE (same convention as forever.py's RETRO).
                    pass
        status = verify["status"]
        ev = verify.get("evidence")
        ev_summary = str((ev or {}).get("summary") or "") if isinstance(ev, dict) else ""
        self._narrate(
            f"VERIFY {status}: {ev_summary[:180]}" if ev_summary else f"VERIFY {status}",
            warn=(status != "PASSED"),
        )

        # ---- STAGE ----
        self._set(stage="stage")
        if status == "PASSED":
            self._move_to_staging(build["artifactPath"], build.get("toolName") or rung_id)
            self._narrate(f"STAGED {staging_id or rung_id} -> ServerStorage.FactoryStaging")
        else:
            self._destroy_artifact(build["artifactPath"])
            self._narrate(f"artifact destroyed ({status}); the evidence entry is staged for review")
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
            "audit": audit,
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
    if m:FindFirstChildOfClass("Humanoid") and m.Name ~= "VerifyTarget" and m.Name ~= "TrainingDummy" and m.Name ~= "AgentRig" then
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
    "(a CALM sandbox). Gather ALL visual evidence in EDIT MODE - the playtest at the end is ONLY "
    "for the damage number, and must be SHORT.\n"
    "(1) EDIT - EVERY ANGLE: capture_angles the weapon Tool (count 3-4, neutralLight=true so it "
    "never reads as a silhouette) - it must READ as the brief's weapon from all sides.\n"
    "(2) EDIT - ON THE RIG, FRAME BY FRAME, FROM MULTIPLE ANGLES (no playtest needed): use "
    "workspace.AgentRig (spawn_rig if missing). Record Tool.Grip and Tool.Parent via run_luau "
    "FIRST. grip_tool the weapon onto the rig - its capture shows the held pose. Then "
    "capture_animation the Tool's bound swing (animation = the Tool's Anims.use path - the Tool "
    "lives UNDER THE RIG while gripped) at least TWICE: once with angle front, once with angle "
    "right or iso (frames 5-6 each), judging each strip as it arrives - imperfections hide from "
    "a single viewpoint. JUDGE ONLY WHAT IS VISIBLE: your evidence must STATE which way the "
    "blade points relative to the fist, as seen in the frames. FAIL if the Tool has no Anims/use "
    "clip (the build must bind one), or if ANY angle shows the swing not READING (no windup/"
    "strike arc), the weapon detached from the hand, the weapon/arm clipping through the body, "
    "OR the blade pointing down/into the body from the fist. If you cannot actually SEE the "
    "blade's orientation (silhouette, occlusion, blade hidden behind the arm), the strip is "
    "UNREADABLE - it is NOT passable evidence; re-shoot before judging. Afterward RESTORE via run_luau: destroy "
    "the 'AgentEditGrip' weld under the rig's RightHand, set Grip back, and reparent the Tool to "
    "its recorded parent.\n"
    "(3) EDIT - THE DUMMY: locate workspace.TrainingDummy with run_luau and print BOTH its "
    "Position AND the SpawnLocation's Position (it may be BESIDE spawn - compute the offset so you "
    "know exactly which way and how far to walk; do NOT assume 'straight ahead'). If MISSING, "
    "create it: clone ServerStorage.VerifyDummy (or EnemyTemplate, deleting its scripts), name it "
    "'TrainingDummy', SetAttribute('StudioAgentGenerated', nil), add a Script that on "
    "Humanoid.HealthChanged prints '[TrainingDummy] HIT damage=<n> hitcount=<n>' then resets "
    "Health=MaxHealth, MaxHealth=10000, anchor every BasePart, PivotTo ~5 studs from the "
    "SpawnLocation on OPEN floor. PERMANENT fixture: NEVER destroy or move it.\n"
    "(4) PLAYTEST - DAMAGE ONLY, IN AND OUT: playtest_start; playtest_act record (the echo ends "
    "[tool=<name> w=<x> a=<y> c=<z>] - FAIL if the tool name or echoed config does not match the "
    "build's config); walk to the dummy along the measured offset, face it, swing 2-3 times; "
    "playtest_logs and read the '[TrainingDummy] HIT damage=' lines - FAIL unless a hit's damage "
    "EXACTLY equals the configured damage (a broken or sabotaged weapon prints NO hit line), and "
    "FAIL on any error mentioning the artifact. The MOMENT the damage lines are read - or after "
    "~3 failed approach attempts (note the mobility trouble, judge on the evidence you have) - "
    "playtest_stop IMMEDIATELY. Never linger in play mode; the visual evidence is already banked "
    "from EDIT."
)
# Oracle-first melee verify (SP2b): the suite measures, captures diagnose flagged rows plus one
# aesthetic sign-off. Steps 3-4 are verbatim from _WEAPON_VERIFY - the damage twin and dummy
# discipline are unchanged. ranged-weapon keeps _WEAPON_VERIFY until its suite family exists.
_MELEE_ORACLE_VERIFY = (
    "The game's round/wave/spawner scripts are auto-disabled and stray mobs cleared for this "
    "verify (a CALM sandbox). This verify is ORACLE-FIRST - measure with the suite, look only "
    "where it points, then sign off aesthetics:\n"
    "(1) ORACLE SUITE BEFORE ANY CAPTURE: record Tool.Grip and Tool.Parent via run_luau, "
    "grip_tool the weapon onto workspace.AgentRig (spawn_rig if missing) with NO offset/rot args "
    "(frame alignment), then run oracle_suite {family:'melee-weapon', target:<the Tool's path "
    "UNDER the rig>, rig:'game.Workspace.AgentRig', clip:'SwordSwing'}. Read EVERY row. Your "
    "evidence MUST QUOTE the magnitudes as NUMBERS with units - grip_offset_studs, "
    "blade_up_angle_deg, sweep_deg, max_reach_studs, penetration depths - adjectives ('aligned', "
    "'smooth', 'looks right') are NOT evidence. UNKNOWN rows never count as pass; say why each "
    "UNKNOWN is unknown.\n"
    "(2) CAPTURES ONLY WHERE THE SUITE POINTS + ONE SIGN-OFF: (a) for each FAILED or UNKNOWN row, "
    "capture exactly what is needed to diagnose it (a flagged grip -> capture the held pose; a "
    "flagged clip -> capture_animation that clip); (b) then ONE final aesthetic sign-off - "
    "capture_angles the Tool (count 3-4, neutralLight=true) and capture_animation the swing at "
    "least TWICE, once with angle front, once with angle right or iso (frames 5-6 each) - the "
    "suite's blindspot manifest lists exactly what was NOT asserted (silhouette, materials, swing "
    "FEEL) and that is what your eyes are for. If a strip is UNREADABLE (silhouette/occlusion), "
    "re-shoot before judging. FAIL if any suite FAIL row stands unexplained, or the sign-off "
    "shows the weapon not READING as the brief's weapon. Afterward RESTORE via run_luau: destroy "
    "the 'AgentEditGrip' weld under the rig's RightHand, set Grip back, and reparent the Tool to "
    "its recorded parent.\n"
    "(3) EDIT - THE DUMMY: locate workspace.TrainingDummy with run_luau and print BOTH its "
    "Position AND the SpawnLocation's Position (it may be BESIDE spawn - compute the offset so you "
    "know exactly which way and how far to walk; do NOT assume 'straight ahead'). If MISSING, "
    "create it: clone ServerStorage.VerifyDummy (or EnemyTemplate, deleting its scripts), name it "
    "'TrainingDummy', SetAttribute('StudioAgentGenerated', nil), add a Script that on "
    "Humanoid.HealthChanged prints '[TrainingDummy] HIT damage=<n> hitcount=<n>' then resets "
    "Health=MaxHealth, MaxHealth=10000, anchor every BasePart, PivotTo ~5 studs from the "
    "SpawnLocation on OPEN floor. PERMANENT fixture: NEVER destroy or move it.\n"
    "(4) PLAYTEST - DAMAGE ONLY, IN AND OUT: playtest_start; playtest_act record (the echo ends "
    "[tool=<name> w=<x> a=<y> c=<z>] - FAIL if the tool name or echoed config does not match the "
    "build's config); walk to the dummy along the measured offset, face it, swing 2-3 times; "
    "playtest_logs and read the '[TrainingDummy] HIT damage=' lines - FAIL unless a hit's damage "
    "EXACTLY equals the configured damage (a broken or sabotaged weapon prints NO hit line), and "
    "FAIL on any error mentioning the artifact. The MOMENT the damage lines are read - or after "
    "~3 failed approach attempts (note the mobility trouble, judge on the evidence you have) - "
    "playtest_stop IMMEDIATELY. Never linger in play mode; the measured evidence is already "
    "banked from EDIT."
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
    "(b) once the visual is assembled, capture_angles it from ALL SIDES (presets "
    "front/back/left/right/iso, or count 5-6) - imperfections hide from a single viewpoint, so "
    "judge EVERY angle against the reference features as it arrives and COMPARE what you SEE - "
    "if a signature feature is missing, proportions are off, or ANY side reads wrong, fix the "
    "concrete mismatches and re-capture ONCE;\n"
    "(c) then STOP the visual work - two capture rounds max; this is a scoped build, not an art "
    "pass. If get_references errors, say so in notes and build on - do not stall.\n"
    "(d) READABILITY IS A PRECONDITION: if a capture reads as a dark SILHOUETTE, the subject is "
    "occluded, tiny in frame, or you cannot actually see the detail you are judging - the frame "
    "is UNREADABLE. Re-shoot it (neutralLight=true on capture_angles for rigs/items, re-angle, "
    "move the subject to clear ground) - NEVER judge or pass unreadable frames, and never "
    "describe what you INTENDED to build as if you saw it."
)
# Oracle-first build discipline (SP2b): injected into the BUILD prompt of every playbook that
# names an oracle suite family (oracleFamily) - semantics are declared at build time so the
# suite can measure them, never inferred at verify time.
_ORACLE_BUILD = (
    "SEMANTIC FRAME DISCIPLINE (oracle-first): declare semantics at BUILD time, never leave them "
    "to be inferred at verify time - stamp_frame the family schema BEFORE make_tool (read_frame "
    "shows what is still missing), grip via FRAME ALIGNMENT (grip_tool with NO offset/rot args - "
    "it aligns Semantic_Grip to the hand and stamps the resulting grip back), and BEFORE emitting "
    "FACTORY_BUILD_JSON run oracle_suite {family:'%s', target:<artifact>} as a self-check: fix "
    "every FAIL row and quote at least one magnitude as a NUMBER in notes (e.g. grip 0.0 studs / "
    "0.3 deg)."
)

_VISUAL_VERIFY = (
    "This is judged VISUALLY, not by a runtime probe: (1) get_references for what the brief "
    "describes FIRST and list the signature features/proportions real examples show; (2) "
    "capture_angles of the artifact from ALL SIDES (presets front/back/left/right/iso, or count "
    "5-6 - imperfections hide from a single viewpoint, judge every angle); (3) grade it feature-by-feature against "
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
        "oracleFamily": "melee-weapon",
        # The oracle-first procedure adds measured steps (stamp_frame, suite self-check, fix
        # rows) — the first live SP2b cycle capped out at the old default one step short.
        "buildIterations": 70,
        "config": '{"windup":<n>,"active":<n>,"cooldown":<n>,"damage":<n>,"reach":<n>}',
        "build": (
            "(1) park any Tools in StarterPack into ServerStorage and report their new paths in "
            "'parked' so STAGE restores them; (2) build a SHAPED above-primitive visual (prefer "
            "generate_mesh + save_mesh) with a profile distinct to this weapon, reference-matched "
            "per the VISION discipline above; "
            "(3) stamp_frame the melee-weapon frame on the assembled model BEFORE make_tool: "
            "points Grip + BladeTip, dirs blade_dir + edge_dir, roles hilt + blade (Handle-local "
            "coords - the stamp_frame description documents the schema); then make_tool with the "
            "grip part as Handle; "
            "(4) ANIMATE THE SWING in EDIT (no playtest): on workspace.AgentRig (spawn_rig if "
            "missing) author a 3-keypose right-arm swing clip NAMED 'SwordSwing' (the oracle "
            "suite's default clip name) - add_keyframe scope rightArm: windup back, strike "
            "through, recover; total ~0.6-0.9s per the brief's speed - then bind_animation "
            "{tool, event='use', clip} so the weapon ACTUALLY ANIMATES when used; "
            "(5) MEASURE, THEN PREVIEW: record Tool.Grip and Tool.Parent via run_luau, grip_tool "
            "the weapon onto the rig with NO offset/rot args (frame alignment - a stamped frame "
            "makes mis-grips impossible), run oracle_suite {family:'melee-weapon', target:<the "
            "Tool under the rig>, rig:'game.Workspace.AgentRig', clip:'SwordSwing'} and FIX every "
            "FAIL row (grip_sane's blade_up_angle_deg and clip_arc_of's sweep_deg are your "
            "numbers - quote one in notes); then ONE aesthetic capture_animation pass from TWO "
            "angles (front, then right or iso, frames 5-6 each) for what numbers cannot see - "
            "readability, silhouette, the blade visibly out of the fist; if the strip is "
            "unreadable re-shoot once; then RESTORE via run_luau: destroy the 'AgentEditGrip' "
            "weld under the rig's RightHand, set Grip back, and reparent the Tool out of the "
            "rig; "
            "(6) move the Tool into StarterPack; (7) bind_behavior with windup/active/cooldown per "
            "the brief's speed; (8) bind_hitbox with reach + damage + cooldown per the brief."
        ),
        "verify": _MELEE_ORACLE_VERIFY,
    },
    "ranged-weapon": {
        "kind": "runtime",
        "sandbox": "clear",
        "config": '{"windup":<n>,"active":<n>,"cooldown":<n>,"damage":<n>,"range":<n>,"projectileSpeed":<n>}',
        "build": (
            "(1) park StarterPack Tools into ServerStorage (report in 'parked'); (2) build a shaped "
            "visual (mesh preferred), reference-matched per the VISION discipline; (3) make_tool "
            "(grip as Handle); (4) author a 3-keypose right-arm draw/release clip on "
            "workspace.AgentRig (spawn_rig if missing) and bind_animation {tool, event='use', "
            "clip}; (5) preview in EDIT: grip_tool onto the rig + capture_animation the bound clip "
            "(the Tool's Anims.use path under the rig), then restore: destroy the AgentEditGrip "
            "weld, set Grip back, reparent out; "
            "(6) move to StarterPack; (7) bind_behavior for the draw/fire timing; (8) wire the "
            "projectile spawn+flight+contact-damage per the brief."
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
        "oracleFamily": "animation",
        "buildIterations": 60,
        "config": '{"clipName":"<name>","keyframeCount":<n>,"priority":"<Action|Movement|...>"}',
        "build": (
            "(1) use an existing rig or spawn_rig; FIRST run oracle_check {check:'joint_census', "
            "args:{rig:<rig>}} - a MIXED Motor6D/AnimationConstraint rig will silently T-pose "
            "your clip; fix the rig before authoring; (2) author the clip as KEYPOSES: pose_joint "
            "/ ik_reach into each keypose then add_keyframe to snapshot it, repeated per pose, "
            "with KeyframeMarkers if the brief needs contact/cancel points; (3) after authoring, "
            "oracle_check {check:'rig_channel_check', args:{rig:<rig>, clip:<clipName>}} - "
            "unmapped pose names are silently-dead channels; fix them before filming; (4) the "
            "artifact is the clip/KeyframeSequence. Author with NO preview running; review with "
            "capture_animation from at least TWO angles (front, then right or iso) - "
            "imperfections hide from one angle."
        ),
        "verify": (
            "ORACLE-FIRST: (1) run oracle_suite {family:'animation', target:<the rig>, rig:<the "
            "rig>, clip:<the config's clipName>} BEFORE any filmstrip - quote its magnitudes as "
            "NUMBERS (motor6d/constraint counts, unmapped channel names) in your evidence; a "
            "MIXED rig or dead channel FAILs regardless of how the filmstrip looks. (2) "
            "capture_animation filmstrips from at least TWO angles - one call with angle front, "
            "another with angle right or iso (frames 5-6 each), judging each as it arrives "
            "(foot-slide, clipping, and broken arcs are suite BLINDSPOTS - the manifest says so; "
            "they are exactly what the filmstrips are for); (3) get_references for the motion and "
            "check the arc/timing/weight; (4) grade against the animation rubric - the motion "
            "must READ as the intended action from EVERY angle (correct arc, torso lead, no "
            "foot-slide, no limb clipping, clean start/end); PASS only if it clearly reads right; "
            "FAILED with what's off; UNVERIFIED if you cannot render the filmstrip."
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


def _build_iterations(playbook: dict) -> int:
    """BUILD loop budget: oracle-first playbooks carry their own (bigger) budget."""
    return int(playbook.get("buildIterations") or 45)


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
        + _learned_block(rung.get("family"))
        + (f"{_VISION_BUILD}\n\n" if playbook.get("vision", True) else "")
        + (_ORACLE_BUILD % playbook["oracleFamily"] + "\n\n" if playbook.get("oracleFamily") else "")
        + f"APPROACH for this {rung.get('family', 'artifact')}:\n{playbook['build']}\n\n"
        f"{sabotage_line}"
        "The MOMENT the core artifact is complete, your VERY NEXT message must be ONLY the JSON "
        f"line (emit it well before iteration {_build_iterations(playbook) - 5}, no polish "
        "first). End that message with EXACTLY ONE line, no code fence:\n"
        'FACTORY_BUILD_JSON: {"ok":true,"artifactPath":"<full instance path, e.g. '
        'game.Workspace.Barn or game.StarterPack.Spear>","artifactKind":"<Tool|Model|ScreenGui|'
        'KeyframeSequence|Script|Folder>","config":' + playbook["config"] + ','
        '"parked":["<any path you moved out of StarterPack, to restore>"],"steps":["..."],'
        '"notes":"<3-6 line recipe of how you built it>"}\n'
        'If you could not complete the build, emit that line with "ok":false and a notes reason.'
    )


def _verify_prompt(rung, build, playbook: dict, audit: bool = False) -> str:
    audit_block = (
        "AUDIT MODE (this run was deterministically selected, 1-in-5): even if the oracle suite "
        "is fully GREEN, ALSO run the FULL capture review (every angle/filmstrip the procedure "
        "names) and CROSS-CHECK each suite verdict against what the captures show. Report any "
        "disagreement in the verdict JSON's \"oracleAudit\" field (empty disagreements list when "
        "they agree). A disagreement does NOT change your verdict rules - it files an oracle bug "
        "for the mechanic (gap-mining).\n\n"
        if audit
        else ""
    )
    oracle_fam = playbook.get("oracleFamily")
    oracle_block = (
        f"ORACLE-FIRST (standing rule): your FIRST evidence action is oracle_suite "
        f"{{family:'{oracle_fam}'}} with the target/rig/clip args the approach below names - the "
        f"artifact was built at {build.get('artifactPath')}, but pass its CURRENT path: a gripped "
        "Tool lives UNDER the rig at suite time, and the animation suite targets the RIG, not the "
        "KeyframeSequence. The suite is the MEASUREMENT layer; captures are reserved for "
        "rows the suite FLAGGED plus ONE final aesthetic sign-off (its blindspot manifest lists "
        "exactly what was NOT asserted - that is what your eyes are for). Your evidence MUST "
        "QUOTE suite magnitudes as NUMBERS with units - adjectives are not evidence. A green "
        "suite alone is never 'done'.\n\n"
        if oracle_fam
        else ""
    )
    return (
        f"You are the headless factory VERIFY stage for rung '{rung['id']}'  -  a SKEPTIC whose job "
        f"is to find reasons to FAIL. Artifact: {build.get('artifactPath')} "
        f"(kind: {build.get('artifactKind', '?')}). Config: {json.dumps(build.get('config'))}.\n"
        f"ORACLE: {rung.get('oracle', '')}\n\n"
        + _learned_block(rung.get("family"))
        + oracle_block
        + audit_block
        + "EDIT-MODE FIRST (standing rule): before ANY playtest_start, enumerate the edit-mode "
        "routes to each oracle item - captures, filmstrips, rig scrubbing (grip_tool + "
        "capture_animation), run_luau probes and direct invocation, RunService:Run() server-sim - "
        "and ATTEMPT them; aim for ~9 distinct edit-mode checks before you conclude anything "
        "needs play mode. Play mode is the LAST resort, only for evidence that is provably "
        "runtime-only, and must be in-and-out.\n\n"
        f"VERIFY APPROACH for this {rung.get('family', 'artifact')}, ONE step at a time:\n"
        f"{playbook['verify']}\n\n"
        "If ANY oracle step is unavailable (playtest will not start, a probe errors, you cannot "
        "capture), status=UNVERIFIED with the reason  -  NEVER PASSED on partial evidence, and NEVER "
        "PASSED on a visual that merely 'looks okay' without meeting the brief.\n\n"
        "BUDGET: the MOMENT you have the oracle evidence (the pass/fail is decided), do your "
        "playtest_stop + brief cleanup and emit the JSON verdict immediately - do NOT keep probing. "
        "Emit the verdict well before iteration 32, or the run is lost to the cap as UNVERIFIED.\n\n"
        "Your FINAL message must be ONLY the JSON line below - no prose before it (a long preamble "
        "gets the JSON truncated and the verdict is LOST as UNVERIFIED). Say any reasoning in the "
        "message BEFORE it. Keep evidence.summary to ONE sentence (<200 chars) and each reason "
        "short. No code fence:\n"
        'FACTORY_VERIFY_JSON: {"status":"PASSED|FAILED|UNVERIFIED","evidence":{"summary":'
        '"<one-sentence probe output or capture-vs-reference finding>"},"reasons":["..."]'
        + (',"oracleAudit":{"disagreements":[{"check":"<name>","suiteSaid":"<verdict + magnitude>",'
           '"captureShowed":"<what the frames show>"}]}' if audit else "")
        + "}"
    )
