"""Disk reader for the Studio Agent vision sidecar.

Roblox writes CaptureService:CaptureScreenshot output as full-resolution viewport PNGs to
%LOCALAPPDATA%\\Roblox\\tmp-capture-storage\\wob-<StudioPID><counter>. A plugin can't read that file
(the path API is RobloxScript-gated), but this local helper can. We return the newest N COMPLETE PNGs
whose mtime is >= a caller-supplied timestamp, as PNG bytes. Pure standard library (no third-party deps).
"""

from __future__ import annotations

import glob
import os
import time

PNG_SIG = b"\x89PNG\r\n\x1a\n"
PNG_IEND = b"IEND\xaeB`\x82"  # final 8 bytes of every complete PNG


def capture_dir() -> str:
    base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
    return os.path.join(base, "Roblox", "tmp-capture-storage")


def _mtime(path: str) -> float:
    try:
        return os.path.getmtime(path)
    except OSError:
        return float("-inf")


def _complete_png_bytes(path: str):
    """Return the file's bytes iff it is a complete PNG (sig + trailing IEND), else None."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return None
    if data[:8] == PNG_SIG and data.rstrip().endswith(PNG_IEND):
        return data
    return None


def newest_captures(count, since_ts=0.0, timeout_s=8.0, poll_s=0.15):
    """Up to `count` newest COMPLETE capture PNGs with mtime >= since_ts, returned oldest-first
    (= capture order). Polls up to timeout_s for `count` files to appear (captures may still be
    flushing). Returns fewer than `count` on timeout (a shortfall)."""
    deadline = time.monotonic() + timeout_s
    directory = capture_dir()
    while True:
        files = [f for f in glob.glob(os.path.join(directory, "wob-*")) if _mtime(f) >= since_ts]
        files.sort(key=_mtime)  # oldest-first
        complete = []
        for f in files:
            b = _complete_png_bytes(f)
            if b is not None:
                complete.append(b)
        if len(complete) >= count or time.monotonic() >= deadline:
            return complete[-count:] if count > 0 else []
        time.sleep(poll_s)
