"""lesson_retrieval.py  -  SP5 scored lesson retrieval over the git-tracked learnings store.

Selection used to be pure tail-slicing (newest-K) and the 40-cap DELETED overflow, so the
learning loop structurally forgot. This module gives factory.py's two injection sites a scored
alternative  -  relevance + verification tier + recency over active+archive  -  and gives
forever.py an archive spill so the cap stops deleting.
Spec: docs/superpowers/specs/2026-07-25-sp5-learnings-retrieval-design.md

Doctrine guards (non-negotiable):
- Pure + deterministic + stdlib-only: no LLM, no embeddings, no network (the SP4 tripwire).
- Anti-Goodhart: the score EXCLUDES citation/usage counts  -  popularity feedback loops would
  let an early lesson entrench itself. Content, verification tier, and age only.
- Fail-open: a corrupt store entry or unwritable archive must never fail a factory run or
  cost a lesson.
"""
import json
import os
import re

# Weights: an on-topic capture-confirmed lesson must beat an off-topic untagged newest one,
# while equally-relevant lessons tie-break by tier then recency (spec section 3.1).
# Recalibration is a one-line diff here  -  but only with A/B evidence, not vibes.
W_MATCH = 0.5
W_TIER = 0.3
W_RECENT = 0.2

# Verification-tier prior. Untagged != untrue, but unverified (33/40 factory-method entries
# are untagged legacy today  -  they stay retrievable, just outranked by verified truth).
TIER_RANK = {
    "playtest-confirmed": 1.0,
    "capture-confirmed": 0.8,
    "symbolic-only": 0.4,
}
UNTAGGED_RANK = 0.3

# Numbers are kept whole  -  magnitudes are signal in this corpus ("2.5-4 studs", "motor6d").
_TOKEN_RE = re.compile(r"[a-z0-9]+(?:\.[0-9]+)?")
_STOPWORDS = frozenset(
    "a an and are as at be before but by can do does for from he how i if in is it its no not "
    "of on or she so than that the their them then they this to was we when will with you "
    "your".split()
)


def tokens(text):
    """Lowercased content tokens: punctuation dropped, stopwords removed, numbers kept with
    decimals intact ('2.5' is one token; so is 'motor6d')."""
    if not text:
        return frozenset()
    return frozenset(t for t in _TOKEN_RE.findall(str(text).lower()) if t not in _STOPWORDS)


def tier_rank(tier):
    return TIER_RANK.get(str(tier or "").strip().lower(), UNTAGGED_RANK)


def _jaccard(a, b):
    if not a or not b:
        return 0.0
    inter = len(a & b)
    return inter / float(len(a | b)) if inter else 0.0


def score(entry, query_tokens, position, n):
    """The SP5 score for one lesson at age `position` of `n` (newest = n-1 -> recency 1.0)."""
    recency = (position + 1) / float(n) if n > 0 else 0.0
    return (
        W_MATCH * _jaccard(tokens(entry.get("text")), query_tokens)
        + W_TIER * tier_rank(entry.get("tier"))
        + W_RECENT * recency
    )


def select(entries, query_text, k):
    """Top-`k` well-formed entries of `entries` (given oldest-first) by score, returned in
    age order  -  how the prompt block has always read. Corrupt entries (non-dict, blank
    text) are skipped. An empty query degrades to tier+recency."""
    pool = [e for e in entries
            if isinstance(e, dict) and str(e.get("text") or "").strip()]
    if k <= 0 or not pool:
        return []
    n = len(pool)
    q = tokens(query_text)
    ranked = sorted(
        ((score(e, q, pos, n), tier_rank(e.get("tier")), pos, e) for pos, e in enumerate(pool)),
        key=lambda r: (r[0], r[1], r[2]),
        reverse=True,
    )
    return [r[3] for r in sorted(ranked[:k], key=lambda r: r[2])]


def archive_path_for(active_path):
    """foo.json -> foo-archive.json (extension preserved)."""
    root, ext = os.path.splitext(active_path)
    return root + "-archive" + (ext or ".json")


def _entries_of(path):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return []
    entries = data.get("entries") if isinstance(data, dict) else None
    return entries if isinstance(entries, list) else []


def load_pool(active_path):
    """Everything the scorer may draw from, in age order: archived (older) then active."""
    return _entries_of(archive_path_for(active_path)) + _entries_of(active_path)


def spill_overflow(data, active_path, cap):
    """Move `data['entries']` overflow beyond the newest `cap` into the sibling archive file
    (same shape, entries verbatim). The active list is trimmed IN PLACE only after the
    archive write succeeds  -  a failed write leaves the active list over-cap rather than
    costing lessons (the next successful spill catches up). Returns entries moved."""
    entries = data.get("entries")
    if not isinstance(entries, list) or cap <= 0 or len(entries) <= cap:
        return 0
    overflow = entries[:-cap]
    apath = archive_path_for(active_path)
    try:
        with open(apath, encoding="utf-8") as fh:
            arch = json.load(fh)
        if not isinstance(arch, dict):
            arch = {}
    except (OSError, ValueError):
        arch = {}
    if not isinstance(arch.get("entries"), list):
        arch["entries"] = []
    arch.setdefault("category", str(data.get("category") or "learnings") + "-archive")
    arch["entries"].extend(overflow)
    try:
        parent = os.path.dirname(apath)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(apath, "w", encoding="utf-8") as fh:
            json.dump(arch, fh, indent=1)
    except OSError:
        return 0
    del entries[:-cap]
    return len(overflow)
