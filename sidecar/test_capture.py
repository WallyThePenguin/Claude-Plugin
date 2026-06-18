"""Dependency-free tests for the disk-reader. Run: python sidecar/test_capture.py"""
import os
import sys
import tempfile
from io import BytesIO

from PIL import Image

import capture


def _write_png(path, w, h, mtime):
    Image.new("RGB", (w, h), (10, 20, 30)).save(path, format="PNG")
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

        _write_png(os.path.join(cdir, "wob-1"), 100, 50, 1000)
        _write_png(os.path.join(cdir, "wob-2"), 100, 50, 2000)
        _write_png(os.path.join(cdir, "wob-3"), 100, 50, 3000)
        _write_png(os.path.join(cdir, "wob-4"), 100, 50, 4000)

        got = capture.newest_captures(2, since_ts=0.0, timeout_s=0.2)
        fails += _check("returns the newest 2 (oldest-first)", len(got) == 2)
        fails += _check(
            "both results are valid PNGs",
            all(Image.open(BytesIO(b)).size == (100, 50) for b in got),
        )

        since3 = 3000
        got = capture.newest_captures(10, since_ts=since3, timeout_s=0.2)
        fails += _check("since_ts filters to wob-3 + wob-4", len(got) == 2)

        # incomplete PNG (no IEND) is skipped
        with open(os.path.join(cdir, "wob-5"), "wb") as f:
            f.write(b"\x89PNG\r\n\x1a\n" + b"\x00" * 32)
        os.utime(os.path.join(cdir, "wob-5"), (5000, 5000))
        got = capture.newest_captures(1, since_ts=5000, timeout_s=0.2)
        fails += _check("incomplete PNG is skipped (timeout -> empty)", len(got) == 0)

        # downscale: long edge capped at max_px
        _write_png(os.path.join(cdir, "wob-6"), 3000, 1000, 6000)
        got = capture.newest_captures(1, since_ts=6000, max_px=2000, timeout_s=0.2)
        ok = len(got) == 1 and max(Image.open(BytesIO(got[0])).size) == 2000
        fails += _check("max_px downscales the long edge to 2000", ok)

    print(f"=== {('ALL PASS' if fails == 0 else str(fails) + ' FAILED')} ===")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
