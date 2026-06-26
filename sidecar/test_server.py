"""Smoke test for the hot-reload source reader. Run: python sidecar/test_server.py (no pytest needed)."""
from server import read_src_sources


def test_reads_known_luau_modules():
    sources = read_src_sources()
    assert isinstance(sources, dict)
    assert "AnimationClip.luau" in sources
    assert "Tools/init.luau" in sources
    assert sources["AnimationClip.luau"].strip() != ""
    assert "init.server.luau" in sources


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
