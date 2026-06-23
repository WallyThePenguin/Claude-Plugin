"""Dependency-free tests for the exemplar reader. Run: python sidecar/test_exemplars.py"""
import base64
import json
import os
import sys
import tempfile
from unittest import mock

import exemplars


def _check(name, cond):
    print(("  PASS  " if cond else "  FAIL  ") + name)
    return 0 if cond else 1


def main():
    fails = 0
    with tempfile.TemporaryDirectory() as d:
        ex_dir = os.path.join(d, "exemplars")
        os.makedirs(os.path.join(ex_dir, "environment"))
        png = b"\x89PNG\r\n\x1a\nHELLOIEND"
        with open(os.path.join(ex_dir, "environment", "a.png"), "wb") as f:
            f.write(png)
        manifest = {"version": 1, "exemplars": [
            {"id": "env-a", "category": "environment", "file": "environment/a.png",
             "license": "own", "source": "me", "caption": "crafted", "tier": "exceptional"},
            {"id": "loco-a", "category": "locomotion", "file": "locomotion/missing.png",
             "license": "cc0", "source": "x", "caption": "y"},
        ]}
        with open(os.path.join(ex_dir, "manifest.json"), "w", encoding="utf-8") as f:
            json.dump(manifest, f)

        with mock.patch.object(exemplars, "exemplars_dir", return_value=ex_dir):
            meta = exemplars.exemplars_for("environment", want_b64=False)
            fails += _check("filters to category (1 entry)", len(meta) == 1 and meta[0]["id"] == "env-a")
            fails += _check("metadata-only omits image", "image" not in meta[0])

            withimg = exemplars.exemplars_for("environment", want_b64=True)
            fails += _check("b64 attaches file bytes",
                            len(withimg) == 1 and withimg[0]["image"] == base64.b64encode(png).decode("ascii"))

            missing = exemplars.exemplars_for("locomotion", want_b64=True)
            fails += _check("missing file skipped when b64", len(missing) == 0)

            none = exemplars.exemplars_for("combat", want_b64=True)
            fails += _check("unknown category -> []", none == [])

    print(f"=== {('ALL PASS' if fails == 0 else str(fails) + ' FAILED')} ===")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
