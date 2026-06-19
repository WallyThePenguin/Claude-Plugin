"""Dependency-free tests for the disk-reader. Run: python sidecar/test_capture.py"""
import os
import sys
import tempfile

import capture


def _complete(marker: int) -> bytes:
    # The reader only checks the 8-byte signature and a trailing IEND, so we don't need a real
    # encoder. A marker byte in the middle makes files distinguishable to assert capture order.
    return capture.PNG_SIG + bytes([marker]) + capture.PNG_IEND


def _write(path, body, mtime):
    with open(path, "wb") as f:
        f.write(body)
    os.utime(path, (mtime, mtime))


def _check(name, cond):
    print(("  PASS  " if cond else "  FAIL  ") + name)
    return 0 if cond else 1


def main():
    fails = 0
    with tempfile.TemporaryDirectory() as d:
        os.environ["LOCALAPPDATA"] = d
        cdir = capture.capture_dir()
        os.makedirs(cdir, exist_ok=True)

        _write(os.path.join(cdir, "wob-1"), _complete(1), 1000)
        _write(os.path.join(cdir, "wob-2"), _complete(2), 2000)
        _write(os.path.join(cdir, "wob-3"), _complete(3), 3000)
        _write(os.path.join(cdir, "wob-4"), _complete(4), 4000)

        got = capture.newest_captures(2, since_ts=0.0, timeout_s=0.2)
        fails += _check("returns the newest 2, oldest-first", got == [_complete(3), _complete(4)])

        got = capture.newest_captures(10, since_ts=3000, timeout_s=0.2)
        fails += _check("since_ts filters to wob-3 + wob-4", len(got) == 2)

        # incomplete PNG (sig but no IEND) is skipped
        _write(os.path.join(cdir, "wob-5"), capture.PNG_SIG + b"\x00" * 32, 5000)
        got = capture.newest_captures(1, since_ts=5000, timeout_s=0.2)
        fails += _check("incomplete PNG is skipped (timeout -> empty)", len(got) == 0)

    print(f"=== {('ALL PASS' if fails == 0 else str(fails) + ' FAILED')} ===")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
