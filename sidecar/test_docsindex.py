"""Dependency-free tests for the docs-grounding channel. Run: python sidecar/test_docsindex.py
search() runs over a FIXTURE docs tree (tempdir), api_diff() over fake catalog text + a fake dump —
no clone, no network, no Studio."""
import os
import sys
import tempfile

import docsindex


def _check(name, cond):
    print(("  PASS  " if cond else "  FAIL  ") + name)
    return 0 if cond else 1


FAKE_CATALOG = """
local M = {}
M.byClass = {
\tInstance = {
\t\tName = "string",
\t\tParent = "Instance", -- nested { braces } in a comment must not confuse depth
\t} :: ClassProps,
\tFolder = {} :: ClassProps,
\tAnimationConstraint = {
\t\tEnabled = "boolean",
\t} :: ClassProps,
}
M.readOnly = {
\tClassName = true,
} :: { [string]: boolean }
return M
"""

FAKE_DUMP = {
    "version": "version-fake123",
    "classCount": 2,
    "dump": {"Classes": [{"Name": "Instance"}, {"Name": "Folder"}]},
}


def make_fixture(root):
    engine = os.path.join(root, "content", "en-us", "reference", "engine", "classes")
    art = os.path.join(root, "content", "en-us", "art")
    os.makedirs(engine)
    os.makedirs(art)
    with open(os.path.join(engine, "AnimationConstraint.yaml"), "w", encoding="utf-8") as fh:
        fh.write("name: AnimationConstraint\nsummary: |\n  Drives joints like a Motor6D.\n")
    with open(os.path.join(engine, "Guide.md"), "w", encoding="utf-8") as fh:
        fh.write("# Engine guide\nAnimationConstraint replaces Motor6D on new rigs.\n")
    with open(os.path.join(art, "rigs.md"), "w", encoding="utf-8") as fh:
        fh.write("Avatars use an animationconstraint under the hood.\n" + ("filler " * 60) + "animationconstraint tail\n")
    with open(os.path.join(art, "notes.txt"), "w", encoding="utf-8") as fh:
        fh.write("AnimationConstraint in a txt file must NOT be indexed.\n")


def main():
    fails = 0
    with tempfile.TemporaryDirectory() as root:
        make_fixture(root)

        hits = docsindex.search("AnimationConstraint", count=10, docs_root=root)
        paths = [h["path"] for h in hits]
        fails += _check("search finds yaml + md hits", len(hits) == 4)
        fails += _check(
            "case-insensitive (lowercase md hit found)",
            any(p.endswith("art/rigs.md") for p in paths),
        )
        fails += _check(
            "engine-reference hits ranked first",
            paths[0].startswith("content/en-us/reference/engine/")
            and paths[-1].startswith("content/en-us/art/"),
        )
        fails += _check("txt files not indexed", not any(p.endswith(".txt") for p in paths))
        fails += _check(
            "hit shape is {path,line,snippet}",
            all(set(h) == {"path", "line", "snippet"} and isinstance(h["line"], int) for h in hits),
        )
        long_hit = [h for h in hits if h["line"] == 2 and h["path"].endswith("rigs.md")]
        fails += _check(
            "long line clamped to ~240 chars around the match",
            long_hit and len(long_hit[0]["snippet"]) <= 240 and "animationconstraint" in long_hit[0]["snippet"],
        )

        fails += _check("count caps results", len(docsindex.search("AnimationConstraint", count=2, docs_root=root)) == 2)
        fails += _check("empty query -> []", docsindex.search("", count=5, docs_root=root) == [])
        fails += _check("no hits -> []", docsindex.search("zzz-not-here", count=5, docs_root=root) == [])
        fails += _check(
            "bad regex falls back to substring",
            docsindex.search("AnimationConstraint(", count=5, docs_root=root) == [],
        )
        fails += _check(
            "regex queries work",
            len(docsindex.search(r"Animation\w+straint", count=5, docs_root=root)) > 0,
        )

        names = docsindex.parse_catalog_classes(FAKE_CATALOG)
        fails += _check(
            "catalog parse: nested keys/one-liners/readOnly handled",
            names == ["Instance", "Folder", "AnimationConstraint"],
        )

        diff = docsindex.api_diff(catalog_text=FAKE_CATALOG, dump_info=FAKE_DUMP)
        fails += _check("api_diff flags classes missing from dump", diff["unknownClasses"] == ["AnimationConstraint"])
        fails += _check("api_diff reports dump version", diff["dumpVersion"] == "version-fake123")

        repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        real_catalog = os.path.join(repo_root, "src", "Tools", "PropertyCatalog.luau")
        if os.path.isfile(real_catalog):
            with open(real_catalog, "r", encoding="utf-8") as fh:
                real_names = docsindex.parse_catalog_classes(fh.read())
            fails += _check(
                "real PropertyCatalog parses (Instance/BasePart/Attachment present)",
                {"Instance", "BasePart", "Attachment"} <= set(real_names) and "readOnly" not in real_names,
            )

    print(("ALL PASS" if fails == 0 else "%d FAILURE(S)" % fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
