"""Dependency-free tests for the mesh-upload ledger + STUDIO_AGENT_MESH_UPLOAD policy flag.
Run: python sidecar/test_mesh_ledger.py
LoopRunner/bridge/store are stubbed via test_factory's fakes — no model, no Studio, no network."""
import json
import os
import sys
import tempfile

import factory
from test_factory import (
    CURRICULUM, FakeBridge, FakeLoop, GATE_CLEAN, STAGE_OK, _wait, _writer, build_line,
    verify_line,
)


def _check(name, cond):
    print(("  PASS  " if cond else "  FAIL  ") + name)
    return 0 if cond else 1


def _ledger_path():
    return os.path.join(tempfile.mkdtemp(), "mesh-uploads.json")


def _runner(loop, bridge, store, ledger):
    d = tempfile.mkdtemp()
    path = os.path.join(d, "curriculum.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(CURRICULUM, fh)
    return factory.FactoryRunner(loop, bridge, path, _writer(store), sleep=lambda s: None,
                                 tooling_path=os.path.join(d, "tooling-issues.json"),
                                 mesh_ledger_path=ledger)


RUNG = {"id": "w", "family": "melee-weapon", "brief": "b", "oracle": "o"}


def main():
    fails = 0
    # Isolate learnings so live lessons can't flake prompt-content assertions (same as
    # test_factory) and pin the env flag to its default for the whole run except where set.
    factory.LEARNINGS_DIR = tempfile.mkdtemp()
    os.environ.pop("STUDIO_AGENT_MESH_UPLOAD", None)
    pb = factory.PLAYBOOKS["melee-weapon"]

    # --- ledger roundtrip: record -> load -> update ---
    ledger = _ledger_path()
    added = factory.record_mesh_uploads(
        [{"assetId": 111, "imageId": 222, "partPath": "game.Workspace.Spear.Handle"},
         {"assetId": 333, "partPath": "game.Workspace.Axe.Head"}],
        "weapon-spear", ledger)
    fails += _check("record adds two pending entries", added == 2)
    entries = factory.load_mesh_ledger(ledger)
    fails += _check("roundtrip: two entries persisted", len(entries) == 2)
    e0 = entries[0]
    fails += _check("entry carries the full shape",
                    e0["assetId"] == 111 and e0["imageId"] == 222
                    and e0["partPath"] == "game.Workspace.Spear.Handle"
                    and e0["rung"] == "weapon-spear" and e0["status"] == "pending"
                    and isinstance(e0.get("uploadedAt"), int))
    fails += _check("imageId optional", "imageId" not in entries[1])
    fails += _check("pending filter sees both", len(factory.pending_mesh_uploads(ledger)) == 2)
    # dedupe by assetId
    added = factory.record_mesh_uploads([{"assetId": 111, "partPath": "x"}], "again", ledger)
    fails += _check("re-record dedupes by assetId",
                    added == 0 and len(factory.load_mesh_ledger(ledger)) == 2)
    # update: pending -> finalized / flagged; unknown + junk ignored
    changed = factory.update_mesh_statuses(
        [{"assetId": 111, "status": "finalized"},
         {"assetId": 333, "status": "flagged"},
         {"assetId": 999, "status": "finalized"},   # unknown id
         {"assetId": 111, "status": "pending"},     # non-definitive: ignored
         "junk", {"assetId": "nope", "status": "finalized"}],
        ledger)
    fails += _check("update changes exactly the two known entries", changed == 2)
    by_id = {e["assetId"]: e for e in factory.load_mesh_ledger(ledger)}
    fails += _check("111 finalized with confirmedAt",
                    by_id[111]["status"] == "finalized"
                    and isinstance(by_id[111].get("confirmedAt"), int))
    fails += _check("333 flagged", by_id[333]["status"] == "flagged")
    fails += _check("no pending entries remain", factory.pending_mesh_uploads(ledger) == [])
    # junk-shape inputs are no-ops
    fails += _check("record with junk shape is a no-op",
                    factory.record_mesh_uploads({"assetId": 1}, "r", ledger) == 0)
    fails += _check("update with junk shape is a no-op",
                    factory.update_mesh_statuses("nope", ledger) == 0)

    # --- malformed ledger file: fail-open (empty), then a record rebuilds it ---
    bad = _ledger_path()
    with open(bad, "w", encoding="utf-8") as fh:
        fh.write("{not json at all")
    fails += _check("malformed ledger loads as empty", factory.load_mesh_ledger(bad) == [])
    fails += _check("malformed ledger has no pendings", factory.pending_mesh_uploads(bad) == [])
    factory.record_mesh_uploads([{"assetId": 7, "partPath": "p"}], "r", bad)
    fails += _check("record over malformed ledger rebuilds it",
                    [e["assetId"] for e in factory.load_mesh_ledger(bad)] == [7])
    # wrong-shape (top-level array) is also fail-open
    arr = _ledger_path()
    with open(arr, "w", encoding="utf-8") as fh:
        json.dump([{"assetId": 5}], fh)
    fails += _check("wrong-shape ledger loads as empty", factory.load_mesh_ledger(arr) == [])
    fails += _check("missing ledger loads as empty",
                    factory.load_mesh_ledger(_ledger_path()) == [])

    # --- policy flag: both arms in the emitted BUILD prompt ---
    manual = factory._build_prompt(RUNG, False, pb, mesh_mode="manual")
    auto = factory._build_prompt(RUNG, False, pb, mesh_mode="auto")
    fails += _check("manual arm forbids upload",
                    '"upload": false' in manual and "NOT approved" in manual)
    fails += _check("manual arm has no report field", "meshUploads" not in manual)
    fails += _check("auto arm uses plain save_mesh",
                    "save_mesh normally" in auto and '"upload": false' not in auto)
    fails += _check("auto arm reports assetIds verbatim",
                    '"meshUploads"' in auto and "VERBATIM" in auto)
    # env default is manual; env=auto flips the arm at emit time
    dflt = factory._build_prompt(RUNG, False, pb)
    fails += _check("env default emits the manual arm", '"upload": false' in dflt)
    os.environ["STUDIO_AGENT_MESH_UPLOAD"] = "auto"
    try:
        env_auto = factory._build_prompt(RUNG, False, pb)
    finally:
        os.environ.pop("STUDIO_AGENT_MESH_UPLOAD", None)
    fails += _check("env=auto emits the auto arm", '"meshUploads"' in env_auto)
    fails += _check("mesh_upload_mode defaults manual", factory.mesh_upload_mode() == "manual")
    # script-only families (vision=False) never mesh -> no policy block
    gui = factory._build_prompt({"id": "g", "family": "gui", "brief": "b", "oracle": "o"},
                                False, factory.PLAYBOOKS["gui"])
    fails += _check("script-only family skips the policy block",
                    "MESH UPLOAD POLICY" not in gui)

    # --- confirm-pass instruction: only when pending entries exist, capped at 5 ids ---
    fails += _check("no pendings -> no confirm block",
                    "confirm_mesh" not in factory._build_prompt(RUNG, False, pb))
    pend = [{"assetId": 1000 + i, "status": "pending"} for i in range(7)]
    conf = factory._build_prompt(RUNG, False, pb, pending_uploads=pend)
    fails += _check("pendings -> confirm_mesh first",
                    "confirm_mesh" in conf and "FIRST action" in conf and '"meshConfirm"' in conf)
    fails += _check("confirm block reports the true pending count", "7 mesh upload(s)" in conf)
    fails += _check("confirm block mentions at most 5 ids",
                    "1004" in conf and "1005" not in conf and "1006" not in conf)

    # --- end-to-end through FactoryRunner: relay fields drive deterministic ledger IO ---
    ledger = _ledger_path()
    factory.record_mesh_uploads([{"assetId": 42, "partPath": "game.Workspace.Old.Handle"}],
                                "weapon-spear", ledger)
    loop = FakeLoop([
        {"state": "done", "result": build_line(
            meshUploads=[{"assetId": 555, "imageId": 556, "partPath": "game.StarterPack.Spear.Handle"}],
            meshConfirm=[{"assetId": 42, "status": "finalized"}])},
        {"state": "done", "result": verify_line("PASSED")},
    ])
    bridge = FakeBridge({"GetAttributes": GATE_CLEAN, "FactoryStaging": STAGE_OK})
    store = {}
    r = _runner(loop, bridge, store, ledger)
    r.start("weapon-spear")
    st = _wait(r)
    fails += _check("run with ledger fields completes PASSED",
                    st["state"] == "done" and st["status"] == "PASSED")
    fails += _check("pre-seeded pending rode the build prompt",
                    "confirm_mesh" in loop.prompts[0] and "42" in loop.prompts[0])
    by_id = {e["assetId"]: e for e in factory.load_mesh_ledger(ledger)}
    fails += _check("relayed confirm finalized the old entry",
                    by_id[42]["status"] == "finalized")
    fails += _check("relayed upload recorded pending",
                    by_id.get(555, {}).get("status") == "pending"
                    and by_id[555].get("imageId") == 556
                    and by_id[555].get("rung") == "weapon-spear")

    # --- corrupt ledger never blocks a run (fail-open at cycle start AND ingest) ---
    bad2 = _ledger_path()
    with open(bad2, "w", encoding="utf-8") as fh:
        fh.write("]]]")
    loop = FakeLoop([
        {"state": "done", "result": build_line(meshUploads=[{"assetId": 9, "partPath": "p"}])},
        {"state": "done", "result": verify_line("PASSED")},
    ])
    bridge = FakeBridge({"GetAttributes": GATE_CLEAN, "FactoryStaging": STAGE_OK})
    store = {}
    r = _runner(loop, bridge, store, bad2)
    r.start("weapon-spear")
    st = _wait(r)
    fails += _check("corrupt ledger run still completes",
                    st["state"] == "done" and st["status"] == "PASSED")
    fails += _check("corrupt ledger run has no confirm block",
                    "confirm_mesh" not in loop.prompts[0])
    fails += _check("corrupt ledger rebuilt from the relayed upload",
                    [e["assetId"] for e in factory.load_mesh_ledger(bad2)] == [9])

    print(f"=== {('ALL PASS' if fails == 0 else str(fails) + ' FAILED')} ===")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
