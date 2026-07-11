"""Tests for the play-session twin archive (/play/twins — the sidecar-witnessed half of the
oracle twin evidence contract). Run: python sidecar/test_play_twins.py (no pytest needed).

Store-level tests exercise bridge.Store directly; the HTTP test spins the REAL server Handler
in-process on an ephemeral port (never touches the live sidecar on 8389)."""
import json

from bridge import Store, TWIN_CAP

ENV = {"check": "anchored_weld_census", "verdict": "PASS", "reason": "all welded",
       "magnitudes": {"loose": 0}, "context": "run", "validity": "PLAY_ONLY", "cost_ms": 12}


def _oracle_result(store, envelope, ok=True):
    """Submit an oracle play command and post its result the way PlayBridge does
    (result JSON-encoded into the 'result' field)."""
    pid = store.play_submit({"cmd": "oracle", "arg": json.dumps({"check": envelope.get("check", "x")})})
    store.play_put_result(pid, {"id": pid, "ok": ok, "result": json.dumps(envelope)})
    return pid


def test_empty_state_is_session_zero():
    s = Store()
    assert s.play_twins() == {"session": 0, "active": False, "twins": []}


def test_start_opens_session_and_oracle_results_archive():
    s = Store()
    s.play_submit({"cmd": "start"})
    _oracle_result(s, ENV)
    t = s.play_twins()
    assert t["session"] == 1 and t["active"] is True
    assert t["twins"] == [ENV]  # verbatim envelope, arrival order


def test_already_decoded_envelope_archives_too():
    s = Store()
    s.play_submit({"cmd": "start"})
    pid = s.play_submit({"cmd": "oracle", "arg": "{}"})
    s.play_put_result(pid, {"id": pid, "ok": True, "result": dict(ENV)})  # object, not string
    assert s.play_twins()["twins"] == [ENV]


def test_non_oracle_results_do_not_archive():
    s = Store()
    s.play_submit({"cmd": "start"})
    pid = s.play_submit({"cmd": "sdiag"})
    s.play_put_result(pid, {"id": pid, "ok": True, "result": json.dumps(ENV)})
    t = s.play_twins()
    assert t["twins"] == [] and "skipped" not in t


def test_stop_marks_inactive_but_keeps_twins():
    s = Store()
    s.play_submit({"cmd": "start"})
    _oracle_result(s, ENV)
    s.play_submit({"cmd": "stop"})
    t = s.play_twins()
    assert t["active"] is False and len(t["twins"]) == 1 and t["session"] == 1


def test_start_increments_session_and_serves_only_latest():
    s = Store()
    s.play_submit({"cmd": "start"})
    _oracle_result(s, ENV)
    s.play_submit({"cmd": "start"})  # session 2 — session-1 archive is gone
    t = s.play_twins()
    assert t["session"] == 2 and t["active"] is True and t["twins"] == []
    second = dict(ENV, check="stable_over")
    _oracle_result(s, second)
    assert s.play_twins()["twins"] == [second]


def test_late_result_from_prior_session_is_ignored():
    s = Store()
    s.play_submit({"cmd": "start"})
    old_pid = s.play_submit({"cmd": "oracle", "arg": "{}"})
    s.play_submit({"cmd": "start"})  # new session before the old result lands
    s.play_put_result(old_pid, {"id": old_pid, "ok": True, "result": json.dumps(ENV)})
    t = s.play_twins()
    assert t["session"] == 2 and t["twins"] == [] and "skipped" not in t


def test_malformed_envelope_skipped_and_counted():
    s = Store()
    s.play_submit({"cmd": "start"})
    pid = s.play_submit({"cmd": "oracle", "arg": "{}"})
    # PlayBridge error path: result is a plain string, not envelope JSON
    s.play_put_result(pid, {"id": pid, "ok": False, "result": "oracle: bad arg -- expected JSON"})
    _oracle_result(s, ENV)  # a good one still archives after the skip
    t = s.play_twins()
    assert t["twins"] == [ENV] and t["skipped"] == 1


def test_cap_drops_oldest_and_reports_dropped():
    s = Store()
    s.play_submit({"cmd": "start"})
    for i in range(TWIN_CAP + 5):
        _oracle_result(s, dict(ENV, cost_ms=i))
    t = s.play_twins()
    assert len(t["twins"]) == TWIN_CAP
    assert t["dropped"] == 5
    assert t["twins"][0]["cost_ms"] == 5      # oldest 5 evicted
    assert t["twins"][-1]["cost_ms"] == TWIN_CAP + 4


def test_arrival_order_preserved():
    s = Store()
    s.play_submit({"cmd": "start"})
    _oracle_result(s, dict(ENV, check="anchored_weld_census"))
    _oracle_result(s, dict(ENV, check="stable_over"))
    assert [e["check"] for e in s.play_twins()["twins"]] == ["anchored_weld_census", "stable_over"]


def test_http_route_serves_twins_end_to_end():
    """The REAL Handler on an ephemeral in-process port: POST /play + /play/result, GET /play/twins."""
    import threading
    import urllib.request
    from http.server import ThreadingHTTPServer

    import server as server_mod

    saved = server_mod.STORE
    server_mod.STORE = Store()  # isolate: never share state with anything else
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), server_mod.Handler)
    port = httpd.server_address[1]
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{port}"

    def post(path, body):
        req = urllib.request.Request(base + path, data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=5) as r:
            return json.loads(r.read())

    def get(path):
        with urllib.request.urlopen(base + path, timeout=5) as r:
            return json.loads(r.read())

    try:
        assert get("/play/twins") == {"session": 0, "active": False, "twins": []}
        post("/play", {"cmd": "start"})
        oid = post("/play", {"cmd": "oracle", "arg": json.dumps({"check": "anchored_weld_census"})})["id"]
        post("/play/result", {"id": oid, "ok": True, "result": json.dumps(ENV)})
        t = get("/play/twins")
        assert t["session"] == 1 and t["active"] is True and t["twins"] == [ENV]
        post("/play", {"cmd": "stop"})
        assert get("/play/twins")["active"] is False
        # SP2e observability rider: /loop/status carries the SSE subscriber counters additively.
        bs = get("/loop/status").get("bridgeStream")
        assert bs is not None and bs["active"] == 0 and bs["total"] >= 0
    finally:
        httpd.shutdown()
        httpd.server_close()
        server_mod.STORE = saved


if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    passed = 0
    for fn in fns:
        try:
            fn()
            print(f"PASS {fn.__name__}")
            passed += 1
        except AssertionError as e:
            print(f"FAIL {fn.__name__}: {e}")
    print(f"{passed}/{len(fns)} passed")
    raise SystemExit(0 if passed == len(fns) else 1)
