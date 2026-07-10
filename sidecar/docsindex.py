"""Docs-grounding channel: local clone of Roblox/creator-docs + the machine-readable API dump.

ensure_docs() sparse-clones creator-docs into sidecar/docscache/creator-docs ONCE (no auto-pull:
the clone is grounding material, not a live mirror — refresh by deleting the directory).
search() greps content/en-us/reference/engine/**/*.{yaml,md} then the rest of content/en-us/**/*.md,
engine-reference hits ranked first. api_dump() caches the versioned Studio API dump; api_diff()
cross-checks src/Tools/PropertyCatalog.luau class names against it so a class the engine renamed
or replaced (the AnimationConstraint surprise) becomes a report, not a runtime mystery.

Pure standard library; every network touch is isolated in api_dump()/ensure_docs().
"""

import json
import os
import re
import subprocess
import urllib.request

SIDECAR_DIR = os.path.dirname(os.path.abspath(__file__))
DOCSCACHE = os.path.join(SIDECAR_DIR, "docscache")
DOCS_REPO = "https://github.com/Roblox/creator-docs"
DOCS_ROOT = os.path.join(DOCSCACHE, "creator-docs")
CATALOG_PATH = os.path.join(os.path.dirname(SIDECAR_DIR), "src", "Tools", "PropertyCatalog.luau")
VERSION_URL = "https://clientsettings.roblox.com/v2/client-version/WindowsStudio64"
DUMP_URL = "https://setup.rbxcdn.com/{}-API-Dump.json"

SNIPPET_CHARS = 240
_EN_US = os.path.join("content", "en-us")
_ENGINE_REF = os.path.join(_EN_US, "reference", "engine")


def ensure_docs(docs_root: str = DOCS_ROOT) -> str:
    """Clone creator-docs (sparse: md/yaml only, ~20 MB not ~20 GB) if absent; existing clone untouched.

    search() only reads content/en-us/**/*.{md,yaml}, so a blob:none partial clone plus a
    non-cone sparse-checkout of those patterns is a full-fidelity substrate for it.
    """
    if os.path.isdir(os.path.join(docs_root, "content")):
        return docs_root
    os.makedirs(os.path.dirname(docs_root), exist_ok=True)
    subprocess.run(
        [
            "git",
            "clone",
            "--depth",
            "1",
            "--single-branch",
            "--filter=blob:none",
            "--sparse",
            DOCS_REPO,
            docs_root,
        ],
        check=True,
        capture_output=True,
        timeout=900,
    )
    subprocess.run(
        [
            "git",
            "-C",
            docs_root,
            "sparse-checkout",
            "set",
            "--no-cone",
            "content/en-us/**/*.md",
            "content/en-us/**/*.yaml",
        ],
        check=True,
        capture_output=True,
        timeout=900,
    )
    return docs_root


def _matcher(query: str):
    """Regex when the query compiles, else literal substring — bad regex must not 500 a search."""
    try:
        return re.compile(query, re.IGNORECASE)
    except re.error:
        return re.compile(re.escape(query), re.IGNORECASE)


def _snippet(line: str, start: int) -> str:
    line = line.rstrip("\n")
    if len(line) <= SNIPPET_CHARS:
        return line.strip()
    lo = max(0, start - SNIPPET_CHARS // 2)
    return line[lo : lo + SNIPPET_CHARS].strip()


def _scan_file(full: str, rel: str, pattern, hits: list, count: int, per_file_cap: int = 3):
    """Append up to per_file_cap {path,line,snippet} hits; stop once `hits` reaches count."""
    taken = 0
    try:
        with open(full, "r", encoding="utf-8", errors="replace") as fh:
            for lineno, line in enumerate(fh, 1):
                m = pattern.search(line)
                if m is None:
                    continue
                hits.append({"path": rel, "line": lineno, "snippet": _snippet(line, m.start())})
                taken += 1
                if taken >= per_file_cap or len(hits) >= count:
                    return
    except OSError:
        return


def search(query: str, count: int = 5, docs_root: str = None) -> list:
    """[{path,line,snippet}] over the docs clone, engine-reference hits first."""
    if not query:
        return []
    count = max(1, min(int(count), 50))
    docs_root = ensure_docs(docs_root or DOCS_ROOT)
    pattern = _matcher(query)
    hits: list = []
    # Pass 1: reference/engine (yaml + md) — walked first so ranking falls out of scan order.
    engine_dir = os.path.join(docs_root, _ENGINE_REF)
    for root, _dirs, files in os.walk(engine_dir):
        for name in sorted(files):
            if not name.endswith((".yaml", ".md")):
                continue
            full = os.path.join(root, name)
            rel = os.path.relpath(full, docs_root).replace(os.sep, "/")
            _scan_file(full, rel, pattern, hits, count)
            if len(hits) >= count:
                return hits[:count]
    # Pass 2: the rest of content/en-us, md only, skipping the already-scanned engine subtree.
    en_us = os.path.join(docs_root, _EN_US)
    for root, dirs, files in os.walk(en_us):
        if os.path.abspath(root) == os.path.abspath(os.path.join(docs_root, _ENGINE_REF)):
            dirs[:] = []
            continue
        for name in sorted(files):
            if not name.endswith(".md"):
                continue
            full = os.path.join(root, name)
            rel = os.path.relpath(full, docs_root).replace(os.sep, "/")
            _scan_file(full, rel, pattern, hits, count)
            if len(hits) >= count:
                return hits[:count]
    return hits[:count]


def _fetch_json(url: str):
    with urllib.request.urlopen(url, timeout=60) as resp:
        return json.loads(resp.read().decode("utf-8"))


def api_dump() -> dict:
    """{version, classCount, dump} — cached per clientVersionUpload in docscache/."""
    os.makedirs(DOCSCACHE, exist_ok=True)
    try:
        version = _fetch_json(VERSION_URL)["clientVersionUpload"]
    except Exception:
        # Offline: fall back to the newest cached dump rather than failing the diff.
        cached = sorted(
            (n for n in os.listdir(DOCSCACHE) if n.startswith("api-dump-") and n.endswith(".json")),
            key=lambda n: os.path.getmtime(os.path.join(DOCSCACHE, n)),
        )
        if not cached:
            raise
        version = cached[-1][len("api-dump-") : -len(".json")]
    cache_path = os.path.join(DOCSCACHE, "api-dump-{}.json".format(version))
    if os.path.isfile(cache_path):
        with open(cache_path, "r", encoding="utf-8") as fh:
            dump = json.load(fh)
    else:
        dump = _fetch_json(DUMP_URL.format(version))
        tmp = cache_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(dump, fh)
        os.replace(tmp, cache_path)
    return {"version": version, "classCount": len(dump.get("Classes", [])), "dump": dump}


_STRING_RE = re.compile(r'"[^"]*"')
_CLASS_KEY_RE = re.compile(r"^\s*([A-Za-z_]\w*)\s*=\s*\{")


def parse_catalog_classes(text: str) -> list:
    """Class names = depth-1 keys of the M.byClass table literal (see PropertyCatalog.luau)."""
    names = []
    depth = 0
    in_byclass = False
    for line in text.splitlines():
        # Strip strings then comments so brace counting can't be fooled by either.
        bare = _STRING_RE.sub('""', line)
        bare = bare.split("--", 1)[0]
        if not in_byclass:
            if re.search(r"\bbyClass\s*=\s*\{", bare):
                in_byclass = True
                depth = bare.count("{") - bare.count("}")
            continue
        if depth == 1:
            m = _CLASS_KEY_RE.match(bare)
            if m:
                names.append(m.group(1))
        depth += bare.count("{") - bare.count("}")
        if depth <= 0:
            break
    return names


def api_diff(catalog_text: str = None, dump_info: dict = None) -> dict:
    """{unknownClasses, dumpVersion}: catalog classes absent from the live API dump."""
    if catalog_text is None:
        with open(CATALOG_PATH, "r", encoding="utf-8") as fh:
            catalog_text = fh.read()
    if dump_info is None:
        dump_info = api_dump()
    known = {c.get("Name") for c in dump_info["dump"].get("Classes", [])}
    unknown = sorted(n for n in parse_catalog_classes(catalog_text) if n not in known)
    return {"unknownClasses": unknown, "dumpVersion": dump_info["version"]}
