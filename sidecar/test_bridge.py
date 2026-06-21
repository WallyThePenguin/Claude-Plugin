"""Tests for the dev-bridge Store. Run: python sidecar/test_bridge.py (no pytest needed)."""
from bridge import Store


def test_submit_returns_increasing_ids():
    s = Store()
    assert s.submit({"kind": "tool", "tool": "x"}) == 1
    assert s.submit({"kind": "luau", "code": "y"}) == 2


def test_take_pending_returns_then_clears():
    s = Store()
    i = s.submit({"kind": "tool", "tool": "x"})
    cmd = s.take_pending()
    assert cmd["id"] == i and cmd["tool"] == "x"
    assert s.take_pending() is None  # slot cleared


def test_put_and_get_result():
    s = Store()
    s.put_result(7, {"ok": True, "result": "done"})
    assert s.get_result(7) == {"ok": True, "result": "done"}
    assert s.get_result(8) is None


def test_set_and_get_logs():
    s = Store()
    assert s.get_logs() == []
    s.set_logs([{"kind": "output", "text": "hi"}])
    assert s.get_logs() == [{"kind": "output", "text": "hi"}]


def test_submit_overwrites_single_slot():
    s = Store()
    s.submit({"kind": "tool", "tool": "a"})
    s.submit({"kind": "tool", "tool": "b"})
    assert s.take_pending()["tool"] == "b"  # latest wins (single-flight)


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
