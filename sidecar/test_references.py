"""Dependency-free tests for the reference-image channel. Run: python sidecar/test_references.py
Network fetchers are stubbed — no real Wikimedia calls."""
import os
import shutil
import struct
import sys
import tempfile

import references


def _check(name, cond):
    print(("  PASS  " if cond else "  FAIL  ") + name)
    return 0 if cond else 1


PNG_OK = b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\x0d" + b"IHDR" + struct.pack(">II", 640, 480)
PNG_TALL = b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\x0d" + b"IHDR" + struct.pack(">II", 640, 9000)
JPG_OK = b"\xff\xd8\xff\xc0" + struct.pack(">H", 11) + b"\x08" + struct.pack(">HH", 480, 640)
GARBAGE = b"this is not an image at all"

UP = "https://upload.wikimedia.org/thumb/"


def canned(items):
    """items: [(title, thumburl, license)] -> a Commons API response in rank order."""
    pages = {}
    for i, (title, thumburl, lic) in enumerate(items):
        pages[str(100 + i)] = {
            "index": i + 1,
            "title": "File:" + title,
            "imageinfo": [
                {
                    "thumburl": thumburl,
                    "descriptionurl": "https://commons.example/" + title,
                    "extmetadata": {
                        "LicenseShortName": {"value": lic},
                        "Artist": {"value": '<a href="/u/x">Some\x07 Author</a>'},
                    },
                }
            ],
        }
    return {"query": {"pages": pages}}


class Net:
    """Swappable stub fetchers with a download counter."""

    def __init__(self, search_response, bodies):
        self.search_response = search_response
        self.bodies = bodies  # url suffix -> bytes
        self.downloads = 0

    def http_json(self, url, timeout):
        return self.search_response

    def http_bytes(self, url, timeout):
        self.downloads += 1
        for suffix, body in self.bodies.items():
            if url.endswith(suffix):
                return body
        raise OSError("404")


def broken(url, timeout):
    raise AssertionError("network hit that should not happen")


def main():
    fails = 0
    tmp = tempfile.mkdtemp()
    references.REF_DIR = tmp
    try:
        # --- validation primitives ---
        fails += _check("png dims parsed", references._image_type_and_dims(PNG_OK) == ("image/png", 640, 480))
        fails += _check("jpeg dims parsed", references._image_type_and_dims(JPG_OK) == ("image/jpeg", 640, 480))
        fails += _check("tall png rejected", references._validate_image(PNG_TALL) is None)
        fails += _check("garbage rejected", references._validate_image(GARBAGE) is None)
        fails += _check("non-latin slug hashes", references._slug("武士刀").startswith("q-"))

        for bad in ("", "   "):
            try:
                references.get_references(bad)
                fails += _check(f"bad query rejected: {bad!r}", False)
            except references.ReferenceError:
                fails += _check(f"bad query rejected: {bad!r}", True)

        # --- fetch behavior: allowlist, validation, fill-to-count only ---
        net = Net(
            canned(
                [
                    ("Evil offhost.jpg", "https://evil.example/x.jpg", "CC0"),
                    ("Broken image.jpg", UP + "broken.jpg", "CC0"),
                    ("Kilij blade.png", UP + "blade.png", "Public domain"),
                    ("Kilij hilt.jpg", UP + "hilt.jpg", "CC BY-SA 4.0"),
                    ("Tall scan.png", UP + "tall.png", "CC0"),
                ]
            ),
            {"blade.png": PNG_OK, "hilt.jpg": JPG_OK, "tall.png": PNG_TALL},
        )
        references._http_json = net.http_json
        references._http_bytes = net.http_bytes

        out = references.get_references("kilij sword", 1)
        fails += _check("fills only requested count", out["returned"] == 1)
        fails += _check("offhost url skipped, rank kept", out["references"][0]["title"] == "Kilij blade.png")
        fails += _check("license carried", out["references"][0]["license"] == "Public domain")
        fails += _check("author sanitized", out["references"][0]["author"] == "Some Author")
        fails += _check("media_type from magic bytes", out["references"][0]["media_type"] == "image/png")
        fails += _check("cold call is a fetch", out["cached"] is False)

        # --- failed refetch must serve the existing shorter cache, not error ---
        references._http_json = broken
        references._http_bytes = broken
        out = references.get_references("kilij sword", 3)
        fails += _check("failed refetch serves stale cache", out["returned"] == 1 and out["cached"] is False)

        # --- topping up: ask 3, usable results are only 2 -> exhausted is banked ---
        references._http_json = net.http_json
        references._http_bytes = net.http_bytes
        out = references.get_references("kilij sword", 3)
        fails += _check("top-up gets all usable", out["returned"] == 2)
        fails += _check("b64 round-trips", len(out["references"][1]["image"]) > 4)

        # --- sparse query now CACHES (exhausted marker): no network on repeat ---
        references._http_json = broken
        references._http_bytes = broken
        out = references.get_references("KILIJ   sword!!", 4)  # same slug post-normalization
        fails += _check("exhausted cache hits (no network)", out["cached"] is True and out["returned"] == 2)

        # --- an all-failures fetch must NOT create a permanent negative cache ---
        empty_net = Net(canned([("Only broken.jpg", UP + "nope.jpg", "CC0")]), {})
        references._http_json = empty_net.http_json
        references._http_bytes = empty_net.http_bytes
        try:
            references.get_references("desert fort", 2)
            fails += _check("no-usable-results raises", False)
        except references.ReferenceError:
            fails += _check("no-usable-results raises", True)
        good_net = Net(canned([("Fort.jpg", UP + "fort.jpg", "CC0")]), {"fort.jpg": JPG_OK})
        references._http_json = good_net.http_json
        references._http_bytes = good_net.http_bytes
        out = references.get_references("desert fort", 2)
        fails += _check("recovers after transient failure", out["returned"] == 1)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print(f"=== {('ALL PASS' if fails == 0 else str(fails) + ' FAILED')} ===")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
