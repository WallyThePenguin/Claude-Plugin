"""Dependency-free tests for the headless factory runner. Run: python sidecar/test_factory.py
LoopRunner, bridge, curriculum, and store are all stubbed — no model, no Studio, no network."""
import json
import os
import sys
import tempfile
import time

import factory


def _check(name, cond):
    print(("  PASS  " if cond else "  FAIL  ") + name)
    return 0 if cond else 1


CURRICULUM = {
    "rungs": [
        {"id": "weapon-spear", "family": "melee-weapon", "category": "combat", "proven": True, "brief": "spear brief", "oracle": "spear oracle"},
        {"id": "house-cottage", "family": "building", "category": "environment", "proven": True, "brief": "a cottage", "oracle": "reads as a cottage"},
        {"id": "weapon-bow", "family": "ranged-weapon", "category": "combat", "proven": False, "brief": "bow brief", "oracle": "tbd"},
    ]
}


class FakeLoop:
    """Scripts a result per start() call; status() reports done immediately after start."""

    def __init__(self, results):
        self.results = list(results)  # each: {"state","result"} or {"state":"error","error"}
        self.prompts = []
        self._cur = {"state": "idle"}

    def start(self, prompt, max_iterations=None, model=None):
        self.prompts.append(prompt)
        nxt = self.results.pop(0) if self.results else {"state": "done", "result": ""}
        self._cur = {"iteration": 3, "toolCalls": 5, **nxt}
        return len(self.prompts)

    def status(self):
        return dict(self._cur)


class FakeBridge:
    def __init__(self, responses):
        self.responses = dict(responses)  # marker-in-code -> result dict
        self.calls = []

    def call(self, command, timeout):
        self.calls.append(command)
        code = command.get("code", "")
        for marker, resp in self.responses.items():
            if marker in code:
                return resp
        return {"ok": True, "result": '{"returns":["?"]}'}


def build_line(**over):
    cfg = {"windup": 0.5, "active": 0.25, "cooldown": 0.9, "damage": 20, "reach": 9}
    obj = {
        "ok": True,
        "artifactPath": "game.StarterPack.Spear",
        "toolName": "Spear",
        "config": cfg,
        "parked": ["game.ServerStorage.Dagger"],
        "steps": ["a", "b"],
        "notes": "built a spear",
    }
    obj.update(over)
    return "I built it.\nFACTORY_BUILD_JSON: " + json.dumps(obj)


def verify_line(status="PASSED"):
    return (
        "Verdict below.\nFACTORY_VERIFY_JSON: "
        + json.dumps(
            {
                "status": status,
                "evidence": {"recordLine": "[tool=Spear w=0.5 a=0.25 c=0.9]", "damageLine": "100->80"},
                "reasons": [],
            }
        )
        + "\n(done)"
    )


def _writer(store):
    def write(kind, item_id, body):
        store[(kind, item_id)] = body

    return write


def _runner(loop, bridge, store, curriculum=CURRICULUM):
    d = tempfile.mkdtemp()
    path = os.path.join(d, "curriculum.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(curriculum, fh)
    return factory.FactoryRunner(loop, bridge, path, _writer(store), sleep=lambda s: None)


def _wait(runner, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if runner.status().get("state") in ("done", "error"):
            return runner.status()
        time.sleep(0.01)
    return runner.status()


GATE_CLEAN = {"ok": True, "result": '{"returns":["GATE_CLEAN"]}'}
GATE_HITS = {"ok": True, "result": '{"returns":["GATE_HITS:name:game.StarterPack.StudioAgentTest_X"]}'}
STAGE_OK = {"ok": True, "result": '{"returns":["STAGED"]}'}
DESTROY_OK = {"ok": True, "result": '{"returns":["DESTROYED"]}'}


def main():
    fails = 0

    # --- happy path: PASSED, artifact staged, entry written ---
    loop = FakeLoop([{"state": "done", "result": build_line()}, {"state": "done", "result": verify_line("PASSED")}])
    bridge = FakeBridge({"GetAttributes": GATE_CLEAN, "FactoryStaging": STAGE_OK})
    store = {}
    r = _runner(loop, bridge, store)
    r.start("weapon-spear")
    st = _wait(r)
    fails += _check("passed run completes", st["state"] == "done" and st["status"] == "PASSED")
    fails += _check("staging entry written", ("staging", "weapon-spear") in store)
    entry = store.get(("staging", "weapon-spear"), {})
    fails += _check("entry records PASSED + headless", entry.get("status") == "PASSED" and entry.get("headless") is True)
    fails += _check("entry carries config trace", entry["artifactTrace"]["config"]["reach"] == 9)
    fails += _check("passed artifact moved to staging", any("FactoryStaging" in c.get("code", "") for c in bridge.calls))
    fails += _check("parked tools restored", any("StarterPack" in c.get("code", "") and "Dagger" in c.get("code", "") for c in bridge.calls))
    fails += _check("two loop runs (build+verify)", len(loop.prompts) == 2)
    fails += _check("build prompt names the rung", "weapon-spear" in loop.prompts[0])
    fails += _check("weapon playbook drives build", "make_tool" in loop.prompts[0] and "bind_hitbox" in loop.prompts[0])
    fails += _check("verify prompt is the skeptic", "SKEPTIC" in loop.prompts[1])
    fails += _check("weapon verify uses the god-mode target", "VerifyTarget" in loop.prompts[1] and "GOD-MODE" in loop.prompts[1])

    # --- a NON-weapon rung uses the visual playbook (build anything) ---
    loop = FakeLoop([
        {"state": "done", "result": 'Built.\nFACTORY_BUILD_JSON: {"ok":true,"artifactPath":"game.Workspace.Cottage","artifactKind":"Model","config":{"style":"cottage"},"parked":[],"steps":[],"notes":"a cottage"}'},
        {"state": "done", "result": verify_line("PASSED")},
    ])
    bridge = FakeBridge({"GetAttributes": GATE_CLEAN, "FactoryStaging": STAGE_OK})
    store = {}
    r = _runner(loop, bridge, store)
    r.start("house-cottage")
    st = _wait(r)
    fails += _check("building rung completes", st["state"] == "done" and st["status"] == "PASSED")
    fails += _check("building build prompt is a Model, not a Tool", "Model" in loop.prompts[0] and "make_tool" not in loop.prompts[0])
    fails += _check("building verify uses references (visual)", "get_references" in loop.prompts[1] and "VerifyTarget" not in loop.prompts[1])
    fails += _check("building staged as its own id", ("staging", "house-cottage") in store)

    # --- playbook resolution: family, category fallback, default ---
    fails += _check("family resolves", factory._playbook({"family": "animation"})["kind"] == "visual")
    fails += _check("category fallback resolves", factory._playbook({"category": "gui"}) is factory.PLAYBOOKS["gui"])
    fails += _check("unknown -> default", factory._playbook({"id": "x"}) is factory.PLAYBOOKS["_default"])

    # --- proven=false rung refused (no unmanned first ascents) ---
    r = _runner(FakeLoop([]), FakeBridge({}), {})
    try:
        r.start("weapon-bow")
        fails += _check("first ascent refused", False)
    except factory.FactoryError as exc:
        fails += _check("first ascent refused", "supervised" in str(exc))

    # --- unknown rung refused ---
    r = _runner(FakeLoop([]), FakeBridge({}), {})
    try:
        r.start("weapon-nope")
        fails += _check("unknown rung refused", False)
    except factory.FactoryError:
        fails += _check("unknown rung refused", True)

    # --- gate hit -> BLOCKED, artifact destroyed, no verify loop ---
    loop = FakeLoop([{"state": "done", "result": build_line()}])
    bridge = FakeBridge({"GetAttributes": GATE_HITS, "Destroy": DESTROY_OK})
    store = {}
    r = _runner(loop, bridge, store)
    r.start("weapon-spear")
    st = _wait(r)
    fails += _check("gate hit blocks", st["state"] == "done" and st["status"] == "BLOCKED")
    fails += _check("gate reason names test symbols", "test symbols" in st["reason"])
    fails += _check("no verify loop after gate block", len(loop.prompts) == 1)
    fails += _check("blocked artifact destroyed", any("Destroy" in c.get("code", "") for c in bridge.calls))
    fails += _check("no staging entry on gate block", ("staging", "weapon-spear") not in store)

    # --- build with no JSON tail -> BLOCKED ---
    loop = FakeLoop([{"state": "done", "result": "I got confused and did nothing parseable."}])
    r = _runner(loop, FakeBridge({}), {})
    r.start("weapon-spear")
    st = _wait(r)
    fails += _check("unparseable build blocks", st["status"] == "BLOCKED" and "FACTORY_BUILD_JSON" in st["reason"])

    # --- build ok:false -> BLOCKED ---
    loop = FakeLoop([{"state": "done", "result": build_line(ok=False)}])
    r = _runner(loop, FakeBridge({}), {})
    r.start("weapon-spear")
    st = _wait(r)
    fails += _check("build ok:false blocks", st["status"] == "BLOCKED")

    # --- FAILED verify (sabotage-style) -> destroyed, staged as FAILED ---
    loop = FakeLoop([{"state": "done", "result": build_line()}, {"state": "done", "result": verify_line("FAILED")}])
    bridge = FakeBridge({"GetAttributes": GATE_CLEAN, "Destroy": DESTROY_OK})
    store = {}
    r = _runner(loop, bridge, store)
    r.start("weapon-spear", sabotage=True)
    st = _wait(r)
    fails += _check("failed verify recorded", st["status"] == "FAILED")
    fails += _check("sabotage id suffix", ("staging", "weapon-spear-sabotaged") in store)
    fails += _check("failed artifact destroyed not staged", any("Destroy" in c.get("code", "") for c in bridge.calls))

    # --- verify loop errored -> UNVERIFIED (never PASSED) ---
    loop = FakeLoop([{"state": "done", "result": build_line()}, {"state": "error", "error": "playtest wedged"}])
    bridge = FakeBridge({"GetAttributes": GATE_CLEAN, "Destroy": DESTROY_OK})
    store = {}
    r = _runner(loop, bridge, store)
    r.start("weapon-spear")
    st = _wait(r)
    fails += _check("verify error -> UNVERIFIED", st["status"] == "UNVERIFIED")
    fails += _check("unverified staged with reason", store[("staging", "weapon-spear")]["reasons"])

    # --- build loop errored -> BLOCKED, no gate ---
    loop = FakeLoop([{"state": "error", "error": "model down"}])
    bridge = FakeBridge({})
    r = _runner(loop, bridge, {})
    r.start("weapon-spear")
    st = _wait(r)
    fails += _check("build loop error blocks", st["status"] == "BLOCKED" and "model down" in st["reason"])
    fails += _check("no gate call after build error", len(bridge.calls) == 0)

    # --- busy fencing: second start refused while running ---
    class SlowLoop(FakeLoop):
        def status(self):
            time.sleep(0.2)
            return dict(self._cur)

    slow = SlowLoop([{"state": "done", "result": build_line()}, {"state": "done", "result": verify_line()}])
    r = _runner(slow, FakeBridge({"GetAttributes": GATE_CLEAN, "FactoryStaging": STAGE_OK}), {})
    r.start("weapon-spear")
    fails += _check("busy() true while running", r.busy() is True)
    try:
        r.start("weapon-spear")
        fails += _check("second factory start refused", False)
    except factory.FactoryError as exc:
        fails += _check("second factory start refused", "already active" in str(exc))
    _wait(r)
    fails += _check("busy() false after finish", r.busy() is False)

    # --- JSON tail parser tolerates trailing prose ---
    parsed = factory._last_json(
        'FACTORY_VERIFY_JSON: {"status":"PASSED","evidence":{}} and then some closing words.',
        factory.VERIFY_JSON_RE,
    )
    fails += _check("json tail parsed past trailing prose", parsed and parsed["status"] == "PASSED")
    fails += _check("no-marker parse returns None", factory._last_json("nothing here", factory.BUILD_JSON_RE) is None)

    # --- gate luau escapes the denylist + reserved prefix ---
    luau = factory._gate_luau("game.StarterPack.Spear")
    fails += _check("gate luau references reserved prefix", "StudioAgentTest_" in luau and "TestAutoKill" in luau)

    print(f"=== {('ALL PASS' if fails == 0 else str(fails) + ' FAILED')} ===")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
