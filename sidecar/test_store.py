"""Dependency-free tests for the file-backed knowledge store. Run: python sidecar/test_store.py"""
import os
import sys
import tempfile
from unittest import mock

import store


def _check(name, cond):
    print(("  PASS  " if cond else "  FAIL  ") + name)
    return 0 if cond else 1


def main():
    fails = 0
    with tempfile.TemporaryDirectory() as d:
        with mock.patch.object(store, "STORE_DIR", d):
            # Roundtrip + list.
            store.write_item("learnings", "combat", {"entries": [{"id": 1, "text": "x"}]})
            got = store.read_item("learnings", "combat")
            fails += _check("write/read roundtrip", got == {"entries": [{"id": 1, "text": "x"}]})
            items = store.list_items("learnings")
            fails += _check("list shows the item", len(items) == 1 and items[0]["id"] == "combat")
            fails += _check("read absent -> None", store.read_item("learnings", "nope") is None)

            # Overwrite is atomic-in-effect: new content fully replaces old.
            store.write_item("learnings", "combat", {"entries": []})
            fails += _check("overwrite replaces", store.read_item("learnings", "combat") == {"entries": []})

            # Delete.
            fails += _check("delete existing -> True", store.delete_item("learnings", "combat") is True)
            fails += _check("delete absent -> False", store.delete_item("learnings", "combat") is False)
            fails += _check("list empty after delete", store.list_items("learnings") == [])

            # Kind allowlist.
            try:
                store.write_item("secrets", "x", {})
                fails += _check("bad kind rejected", False)
            except store.StoreError:
                fails += _check("bad kind rejected", True)
            try:
                store.list_items("../../etc")
                fails += _check("bad kind in list rejected", False)
            except store.StoreError:
                fails += _check("bad kind in list rejected", True)

            # Id sanitization / traversal.
            for bad in ("../evil", "a/b", "UPPER", "", "-lead", "x" * 65, "nul\x00"):
                try:
                    store.write_item("skills", bad, {})
                    fails += _check(f"bad id rejected: {bad!r}", False)
                except store.StoreError:
                    fails += _check(f"bad id rejected: {bad!r}", True)

            # Valid edge ids.
            store.write_item("skills", "a", {"ok": 1})
            store.write_item("skills", "a-b-9", {"ok": 2})
            fails += _check("edge ids accepted", store.read_item("skills", "a-b-9") == {"ok": 2})

            # No .tmp litter after writes.
            kind_dir = os.path.join(d, "skills")
            leftovers = [n for n in os.listdir(kind_dir) if n.endswith(".tmp")]
            fails += _check("no tmp litter", leftovers == [])

            # Staging kind exists for the factory.
            store.write_item("staging", "candidate-1", {"evidence": "raw"})
            fails += _check("staging kind works", store.read_item("staging", "candidate-1")["evidence"] == "raw")

    print(f"=== {('ALL PASS' if fails == 0 else str(fails) + ' FAILED')} ===")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
