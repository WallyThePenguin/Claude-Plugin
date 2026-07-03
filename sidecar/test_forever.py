"""Dependency-free tests for the endless curriculum loop. Run: python sidecar/test_forever.py
Factory, loop, curriculum, and staging list are all stubbed — no model, no Studio, no network."""
import json
import os
import sys
import tempfile
import time

import forever


def _check(name, cond):
    print(("  PASS  " if cond else "  FAIL  ") + name)
    return 0 if cond else 1


CURRICULUM = {
    "rungs": [
        {"id": "weapon-spear", "family": "melee-weapon", "category": "combat", "proven": True, "brief": "spear", "oracle": "o"},
        {"id": "enemy-brute", "family": "melee-enemy", "category": "npc", "proven": True, "brief": "brute", "oracle": "o"},
        {"id": "structure-house", "family": "building", "category": "environment", "proven": False, "brief": "house", "oracle": "o"},
    ],
    "proposals": [],
}


class FakeFactory:
    """Records start() calls; reports done synchronously with a scripted status."""

    def __init__(self, status="PASSED"):
        self.calls = []
        self._status_val = status
        self._cur = {"state": "idle"}

    def busy(self):
        return False

    def start(self, rung_id, sabotage=False, variant_hint=None, staging_id=None):
        self.calls.append({"rung": rung_id, "hint": variant_hint, "stagingId": staging_id})
        self._cur = {"state": "done", "status": self._status_val, "stage": "stage"}
        return len(self.calls)

    def status(self):
        return dict(self._cur)


class FakeLoop:
    """Author loop: returns a scripted proposals JSON per start()."""

    def __init__(self, results):
        self.results = list(results)
        self.prompts = []
        self._cur = {"state": "idle"}

    def start(self, prompt, max_iterations=None, model=None):
        self.prompts.append(prompt)
        nxt = self.results.pop(0) if self.results else {"state": "done", "result": ""}
        self._cur = {**nxt}
        return len(self.prompts)

    def status(self):
        return dict(self._cur)


def proposals_result(props):
    return {"state": "done", "result": "Here are ideas.\nFACTORY_PROPOSALS_JSON: " + json.dumps(props)}


def _runner(factory, loop, curriculum=CURRICULUM, staged=None):
    d = tempfile.mkdtemp()
    path = os.path.join(d, "curriculum.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(curriculum, fh)
    lister = (lambda: [{"id": s} for s in (staged or [])])
    r = forever.ForeverRunner(factory, loop, path, lister, sleep=lambda s: None)
    return r, path


def _wait(runner, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if runner.status().get("state") in ("done", "error"):
            return runner.status()
        time.sleep(0.01)
    return runner.status()


PROP = [{"id": "weapon-mace", "category": "combat", "family": "melee-weapon", "brief": "a mace", "oracle": "swings"}]


def main():
    fails = 0

    # --- 2 cycles: runs proven families round-robin, appends proposals ---
    factory = FakeFactory("PASSED")
    loop = FakeLoop([proposals_result(PROP), proposals_result([{"id": "enemy-archer", "family": "ranged-enemy", "brief": "archer", "oracle": "shoots"}])])
    r, path = _runner(factory, loop)
    r.start(cycles=2)
    st = _wait(r)
    fails += _check("two cycles complete", st["state"] == "done" and st["cycle"] == 2)
    fails += _check("cycled two proven families", {c["rung"] for c in factory.calls} == {"weapon-spear", "enemy-brute"})
    fails += _check("variant hint passed", all(c["hint"] for c in factory.calls))
    fails += _check("unique staging ids per cycle", factory.calls[0]["stagingId"] != factory.calls[1]["stagingId"])
    curriculum = json.load(open(path))
    prop_ids = {p["id"] for p in curriculum["proposals"]}
    fails += _check("proposals appended", "weapon-mace" in prop_ids and "enemy-archer" in prop_ids)
    fails += _check("proposals forced proven=false", all(p["proven"] is False for p in curriculum["proposals"]))
    fails += _check("proposals tagged provenance", all(p.get("proposedBy") == "forever-author" for p in curriculum["proposals"]))
    fails += _check("rungs NOT mutated (propose-only)", len(curriculum["rungs"]) == 3)

    # --- author dedup: a proposal duplicating an existing id is dropped ---
    factory = FakeFactory("PASSED")
    loop = FakeLoop([proposals_result([{"id": "weapon-spear", "family": "melee-weapon", "brief": "dup", "oracle": "o"}, {"id": "weapon-axe", "family": "melee-weapon", "brief": "axe", "oracle": "o"}])])
    r, path = _runner(factory, loop)
    r.start(cycles=1)
    st = _wait(r)
    curriculum = json.load(open(path))
    prop_ids = [p["id"] for p in curriculum["proposals"]]
    fails += _check("duplicate id dropped", "weapon-spear" not in prop_ids)
    fails += _check("fresh id kept", "weapon-axe" in prop_ids)

    # --- malformed / missing-field proposals are skipped ---
    factory = FakeFactory("PASSED")
    loop = FakeLoop([proposals_result([{"id": "no-brief", "family": "gui"}, "not a dict", {"family": "gui", "brief": "no id"}, {"id": "GOOD_one!!", "family": "gui", "brief": "ok", "oracle": "o"}])])
    r, path = _runner(factory, loop)
    r.start(cycles=1)
    _wait(r)
    curriculum = json.load(open(path))
    prop_ids = [p["id"] for p in curriculum["proposals"]]
    fails += _check("bad proposals skipped", "no-brief" not in prop_ids and "no id" not in prop_ids)
    fails += _check("id sanitized + kept", "good-one" in prop_ids)

    # --- an all-unproven curriculum runs nothing (charter: no unmanned first ascents) ---
    only_unproven = {"rungs": [{"id": "x", "family": "building", "proven": False, "brief": "b", "oracle": "o"}], "proposals": []}
    r, path = _runner(FakeFactory(), FakeLoop([]), curriculum=only_unproven)
    r.start(cycles=3)
    st = _wait(r)
    fails += _check("no proven families -> clean stop", st["state"] == "done" and st.get("stopped") == "no-proven-families")

    # --- families filter restricts which families cycle ---
    factory = FakeFactory("PASSED")
    loop = FakeLoop([proposals_result([]), proposals_result([])])
    r, path = _runner(factory, loop)
    r.start(cycles=2, families=["melee-enemy"])
    _wait(r)
    fails += _check("families filter honored", all(c["rung"] == "enemy-brute" for c in factory.calls))

    # --- graceful stop ends after the current cycle ---
    class SlowFactory(FakeFactory):
        def status(self):
            time.sleep(0.15)
            return {"state": "done", "status": "PASSED", "stage": "stage"}

    factory = SlowFactory("PASSED")
    loop = FakeLoop([proposals_result([]) for _ in range(20)])
    r, path = _runner(factory, loop)
    r.start(cycles=50)  # would run long
    time.sleep(0.05)
    fails += _check("busy() true while running", r.busy() is True)
    r.stop()
    st = _wait(r, timeout=8.0)
    fails += _check("stop ends the loop", st["state"] == "done" and st.get("stopped") in ("requested", "cycles"))
    fails += _check("stopped well before 50 cycles", st["cycle"] < 50)
    fails += _check("busy() false after stop", r.busy() is False)

    # --- second start refused while running ---
    factory = SlowFactory("PASSED")
    r, path = _runner(factory, FakeLoop([proposals_result([]) for _ in range(20)]))
    r.start(cycles=50)
    time.sleep(0.05)
    try:
        r.start(cycles=1)
        fails += _check("second forever start refused", False)
    except forever.ForeverError:
        fails += _check("second forever start refused", True)
    r.stop()
    _wait(r, timeout=8.0)

    # --- author-loop error does not crash the cycle (0 proposals, run continues) ---
    factory = FakeFactory("PASSED")
    loop = FakeLoop([{"state": "error", "error": "model down"}])
    r, path = _runner(factory, loop)
    r.start(cycles=1)
    st = _wait(r)
    fails += _check("author error tolerated", st["state"] == "done" and st["proposalsAdded"] == 0)

    # --- orphaned factory (busy never clears past the backstop) -> fatal abort, no author ---
    class HangFactory(FakeFactory):
        def __init__(self):
            super().__init__("PASSED")
            self._started = False

        def busy(self):
            return self._started  # idle until start(), then busy forever (orphan)

        def start(self, rung_id, sabotage=False, variant_hint=None, staging_id=None):
            self._started = True
            return super().start(rung_id, sabotage, variant_hint, staging_id)

    loop = FakeLoop([proposals_result(PROP)])
    factory = HangFactory()
    r, path = _runner(factory, loop)
    saved_cap = forever.FACTORY_WAIT_CAP
    forever.FACTORY_WAIT_CAP = 0.05
    r.start(cycles=2)
    st = _wait(r, timeout=6.0)
    forever.FACTORY_WAIT_CAP = saved_cap
    fails += _check("orphaned factory -> error abort", st["state"] == "error" and "orphaned" in str(st.get("error")))
    fails += _check("no author run after orphan abort", len(loop.prompts) == 0)

    # --- unbounded (cycles=None) self-terminates at the default backstop ---
    factory = FakeFactory("PASSED")
    loop = FakeLoop([proposals_result([]) for _ in range(6)])
    r, path = _runner(factory, loop)
    saved_def = forever.DEFAULT_UNBOUNDED_CAP
    forever.DEFAULT_UNBOUNDED_CAP = 2
    r.start(cycles=None)
    st = _wait(r)
    forever.DEFAULT_UNBOUNDED_CAP = saved_def
    fails += _check(
        "unbounded uses default cap",
        st["state"] == "done" and st["cycle"] == 2 and st.get("cyclesRequested") is None and st.get("cyclesCap") == 2,
    )
    fails += _check("staging id carries a run token", "-auto-" in factory.calls[0]["stagingId"])

    # --- proposal parser tolerates trailing prose ---
    parsed = forever._parse_proposals('FACTORY_PROPOSALS_JSON: [{"id":"a","family":"gui","brief":"b"}] thanks!')
    fails += _check("proposals parsed past prose", parsed and parsed[0]["id"] == "a")
    fails += _check("no marker -> empty", forever._parse_proposals("nope") == [])

    print(f"=== {('ALL PASS' if fails == 0 else str(fails) + ' FAILED')} ===")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
