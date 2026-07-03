"""Real-world reference images for ANY object/asset build — the "image learning" channel.

Searches Wikimedia Commons (keyless, license metadata in the API response), downloads small
thumbnails into a local cache (sidecar/refcache/<slug>/), and serves them base64 for the plugin's
get_references tool — so the in-Studio agent literally SEES real references next to its own
captures for every category, not just ones with a curated exemplar set.

References are STUDY material: any license may be looked at for proportions/feature study, but
only CC0/owned expression ships (project charter). License + author + source ride every entry so
the boundary stays auditable. Captions are UNTRUSTED wiki metadata — sanitized here, and the
plugin tool labels them as data, not instructions.

Hard constraints honored here (found by adversarial review):
- Roblox HttpService:RequestAsync has a fixed ~30s timeout -> the whole cold fetch runs under a
  _TOTAL_BUDGET deadline and downloads only what was asked for.
- One malformed image block 400s the ENTIRE Anthropic request -> every payload is validated
  (magic bytes + parsed dimensions vs Anthropic's 8000px limit) BEFORE it is cached or served.
- ThreadingHTTPServer -> a module lock serializes cache access; image files are written
  tmp+os.replace so a reader can never see a truncated file.
- Thumbnails are fetched ONLY from upload.wikimedia.org (the API response is data, not trust).
"""

import base64
import hashlib
import json
import os
import re
import struct
import sys
import threading
import time
import urllib.parse
import urllib.request

if getattr(sys, "frozen", False):  # a rebuilt exe must not cache into the PyInstaller temp dir
    REF_DIR = os.path.join(os.path.dirname(sys.executable), "refcache")
else:
    REF_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "refcache")

MAX_COUNT = 4
THUMB_WIDTH = 640
MAX_IMAGE_BYTES = 3 * 1024 * 1024
MAX_DIM = 7900  # Anthropic rejects images over 8000px on either axis
_UA = "StudioAgentSidecar/1.0 (local Roblox Studio dev plugin; single-user)"
_SEARCH_TIMEOUT = 10
_IMAGE_TIMEOUT = 8
_TOTAL_BUDGET = 22.0  # the Roblox client gives up at ~30s; stay well inside it
_THUMB_PREFIX = "https://upload.wikimedia.org/"
_LOCK = threading.Lock()


class ReferenceError(ValueError):
    """Client error — maps to HTTP 400."""


def _slug(query: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", (query or "").lower()).strip("-")
    if not s:  # non-Latin queries are fine — key the cache by hash instead of rejecting
        s = "q-" + hashlib.sha1(query.encode("utf-8")).hexdigest()[:12]
    return s[:60]


def _sanitize(text, maxlen: int) -> str:
    """Captions come from attacker-editable wiki fields: strip tags/control chars, cap length."""
    s = re.sub(r"<[^>]+>", " ", str(text or ""))
    s = re.sub(r"[\x00-\x1f\x7f]+", " ", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s[:maxlen]


def _http_json(url: str, timeout: float):
    req = urllib.request.Request(url, headers={"User-Agent": _UA})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _http_bytes(url: str, timeout: float):
    req = urllib.request.Request(url, headers={"User-Agent": _UA})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read(MAX_IMAGE_BYTES + 1)


def _image_type_and_dims(data: bytes):
    """(media_type, w, h) parsed from magic bytes, or None if not a clean JPEG/PNG/GIF."""
    try:
        if data[:8] == b"\x89PNG\r\n\x1a\n" and data[12:16] == b"IHDR":
            w, h = struct.unpack(">II", data[16:24])
            return "image/png", w, h
        if data[:6] in (b"GIF87a", b"GIF89a"):
            w, h = struct.unpack("<HH", data[6:10])
            return "image/gif", w, h
        if data[:2] == b"\xff\xd8":
            i = 2
            while i + 9 <= len(data):
                if data[i] != 0xFF:
                    i += 1
                    continue
                marker = data[i + 1]
                if marker in (0x01, 0xD8) or 0xD0 <= marker <= 0xD7:
                    i += 2
                    continue
                (seglen,) = struct.unpack(">H", data[i + 2 : i + 4])
                if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                    h, w = struct.unpack(">HH", data[i + 5 : i + 9])
                    return "image/jpeg", w, h
                i += 2 + seglen
    except (struct.error, IndexError):
        pass
    return None


def _validate_image(data: bytes):
    """media_type for a servable image, else None (never cache what Anthropic would reject)."""
    if not data or len(data) > MAX_IMAGE_BYTES:
        return None
    parsed = _image_type_and_dims(data)
    if parsed is None:
        return None
    media_type, w, h = parsed
    if not (1 <= w <= MAX_DIM and 1 <= h <= MAX_DIM):
        return None
    return media_type


def _search_commons(query: str, limit: int, timeout: float):
    """Commons file-namespace search -> [{title, thumburl, license, author, source}]."""
    params = {
        "action": "query",
        "format": "json",
        "generator": "search",
        "gsrsearch": "filetype:bitmap " + query,
        "gsrnamespace": "6",
        "gsrlimit": str(limit),
        "prop": "imageinfo",
        "iiprop": "url|extmetadata",
        "iiurlwidth": str(THUMB_WIDTH),
    }
    data = _http_json(
        "https://commons.wikimedia.org/w/api.php?" + urllib.parse.urlencode(params), timeout
    )
    pages = (data.get("query") or {}).get("pages") or {}
    results = []
    # 'index' is the search rank; pages arrive as an unordered dict.
    for page in sorted(pages.values(), key=lambda p: p.get("index", 0)):
        infos = page.get("imageinfo") or []
        if not infos or not infos[0].get("thumburl"):
            continue
        meta = infos[0].get("extmetadata") or {}

        def field(name, maxlen=120):
            return _sanitize((meta.get(name) or {}).get("value", ""), maxlen)

        results.append(
            {
                "title": _sanitize(str(page.get("title") or "").removeprefix("File:"), 150),
                "thumburl": infos[0]["thumburl"],
                "license": field("LicenseShortName", 60) or "unknown",
                "author": field("Artist"),
                "source": _sanitize(infos[0].get("descriptionurl") or "", 300),
            }
        )
    return results


def _cache_paths(slug: str):
    d = os.path.join(REF_DIR, slug)
    return d, os.path.join(d, "meta.json")


def _read_cache(slug: str):
    """{'entries': [...], 'exhausted': bool} or None. Accepts the legacy bare-list format."""
    d, meta_path = _cache_paths(slug)
    try:
        with open(meta_path, encoding="utf-8") as fh:
            meta = json.load(fh)
    except (OSError, ValueError):
        return None
    if isinstance(meta, list):  # legacy v1
        meta = {"entries": meta, "exhausted": False}
    entries = meta.get("entries") if isinstance(meta, dict) else None
    if not isinstance(entries, list):
        return None
    for e in entries:
        if not isinstance(e, dict) or not os.path.isfile(os.path.join(d, str(e.get("file", "")))):
            return None
    return {"entries": entries, "exhausted": bool(meta.get("exhausted"))}


def _write_file_atomic(path: str, data: bytes):
    tmp = path + ".tmp"
    with open(tmp, "wb") as fh:
        fh.write(data)
    os.replace(tmp, path)


def _write_cache(slug: str, meta):
    d, meta_path = _cache_paths(slug)
    os.makedirs(d, exist_ok=True)
    _write_file_atomic(meta_path, json.dumps(meta, indent=1).encode("utf-8"))


def _fetch(slug: str, query: str, want: int):
    """Download up to `want` validated thumbnails under the time budget.
    -> {'entries': [...], 'exhausted': bool}; exhausted means Commons genuinely ran out of
    usable results (NOT that the budget cut us short), so a cache with fewer than `count`
    entries can still be a legitimate final answer."""
    deadline = time.monotonic() + _TOTAL_BUDGET
    d, _ = _cache_paths(slug)
    found = _search_commons(query, MAX_COUNT * 3, min(_SEARCH_TIMEOUT, _TOTAL_BUDGET))
    entries = []
    ran_out_of_time = False
    consumed_all = True
    for item in found:
        if len(entries) >= want:
            consumed_all = False  # stopped because we had enough, not because Commons ran dry
            break
        remaining = deadline - time.monotonic()
        if remaining < 1:
            ran_out_of_time = True
            consumed_all = False
            break
        if not item["thumburl"].startswith(_THUMB_PREFIX):
            continue  # the API response is data — never fetch off-host URLs it names
        try:
            data = _http_bytes(item["thumburl"], min(_IMAGE_TIMEOUT, remaining))
        except Exception:  # noqa: BLE001 — a dead thumbnail just gets skipped
            continue
        media_type = _validate_image(data)
        if media_type is None:
            continue
        ext = {"image/png": "png", "image/gif": "gif"}.get(media_type, "jpg")
        name = f"{len(entries) + 1:03d}.{ext}"
        os.makedirs(d, exist_ok=True)
        _write_file_atomic(os.path.join(d, name), data)
        entries.append(
            {
                "file": name,
                "title": item["title"],
                "license": item["license"],
                "author": item["author"],
                "source": item["source"],
                "media_type": media_type,
            }
        )
    return {"entries": entries, "exhausted": consumed_all and not ran_out_of_time}


def get_references(query: str, count: int = 2) -> dict:
    """{query, references: [{title, license, author, source, media_type, image(b64)}], cached}."""
    if not isinstance(query, str) or not query.strip():
        raise ReferenceError("query is required")
    count = max(1, min(int(count or 2), MAX_COUNT))
    slug = _slug(query)
    d, _ = _cache_paths(slug)

    with _LOCK:
        cache = _read_cache(slug)
        have = cache["entries"] if cache else []
        satisfied = cache is not None and (len(have) >= count or cache["exhausted"])
        if not satisfied:
            fresh = None
            try:
                fresh = _fetch(slug, query.strip(), count)
            except Exception:  # noqa: BLE001 — network trouble must not hide a valid cache
                pass
            # Only bank a fetch that actually produced images — an empty result (Commons dry,
            # every download failed, budget gone) must never become a permanent negative cache.
            if fresh is not None and fresh["entries"] and len(fresh["entries"]) >= len(have):
                _write_cache(slug, fresh)
                have = fresh["entries"]
            elif cache is None:
                raise ReferenceError(
                    f"no reference images found for '{query}' — try different words"
                )
            # else: keep serving the older, longer cache

        refs = []
        for e in have[:count]:
            with open(os.path.join(d, e["file"]), "rb") as fh:
                image_b64 = base64.b64encode(fh.read()).decode("ascii")
            refs.append(
                {
                    "title": e["title"],
                    "license": e["license"],
                    "author": e["author"],
                    "source": e["source"],
                    "media_type": e["media_type"],
                    "image": image_b64,
                }
            )
    if not refs:
        raise ReferenceError(f"no reference images found for '{query}' — try different words")
    return {
        "query": query,
        "references": refs,
        "returned": len(refs),
        "cached": bool(satisfied),
    }
