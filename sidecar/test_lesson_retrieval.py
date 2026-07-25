"""Dependency-free tests for SP5 scored lesson retrieval (lesson_retrieval.py) plus the
factory._learned_block knob wiring. Run: python sidecar/test_lesson_retrieval.py
Pure module + tmp files  -  no model, no Studio, no network.
Spec: docs/superpowers/specs/2026-07-25-sp5-learnings-retrieval-design.md"""
import json
import os
import sys
import tempfile
import time

import lesson_retrieval as lr
import factory


def _check(name, cond):
    print(("  PASS  " if cond else "  FAIL  ") + name)
    return 0 if cond else 1


def _e(text, tier=None):
    d = {"bucket": "t", "id": 0, "text": text, "localId": 0, "createdAt": 0}
    if tier:
        d["tier"] = tier
    return d


def _write(path, entries, category="factory-methods"):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump({"category": category, "seq": len(entries), "entries": entries}, fh, indent=1)


def main():
    fails = 0
    os.environ.pop("STUDIO_AGENT_LESSON_RETRIEVAL", None)

    # --- tokenizer ---
    t = lr.tokens("Fit the Grip AT T-pose, verify 2.5-4 studs (Motor6D)!")
    fails += _check("tokenizer: case folded + punctuation dropped",
                    "grip" in t and "fit" in t and "t" in t and "pose" in t)
    fails += _check("tokenizer: stopwords removed", "the" not in t and "at" not in t)
    fails += _check("tokenizer: decimals + alnum kept whole",
                    "2.5" in t and "4" in t and "motor6d" in t)
    fails += _check("tokenizer: empty/None safe",
                    lr.tokens("") == frozenset() and lr.tokens(None) == frozenset())

    # --- tier ranks ---
    fails += _check("tier ranks ordered",
                    lr.tier_rank("playtest-confirmed") > lr.tier_rank("capture-confirmed")
                    > lr.tier_rank("symbolic-only") > lr.tier_rank(None) == lr.tier_rank("gospel"))

    # --- headline: old on-topic capture-confirmed OUTRANKS newest off-topic untagged ---
    gold = "planar uv atlas texel stretch verdict on median grazing tail"
    pool = [_e(gold, tier="capture-confirmed")] + [
        _e("gui overlay stripes outside uilistlayout container item %d" % i) for i in range(11)
    ]
    query = "weapons texel stretch on the planar uv atlas"
    picked = [e["text"] for e in lr.select(pool, query, 8)]
    newest8 = [e["text"] for e in pool[-8:]]
    fails += _check("headline: scored keeps the old gold lesson", gold in picked)
    fails += _check("headline: newest-8 slice would have missed it", gold not in newest8)
    fails += _check("selection returned in age order",
                    picked[0] == gold and len(picked) == 8)

    # --- tie-breaks ---
    two = [_e("same words here", tier="capture-confirmed"), _e("same words here")]
    fails += _check("tier beats adjacent recency",
                    lr.select(two, "", 1)[0].get("tier") == "capture-confirmed")
    same = [_e("alpha beta one"), _e("alpha beta two")]
    fails += _check("equal tier: newer wins", lr.select(same, "", 1)[0]["text"] == "alpha beta two")

    # --- empty query degrades to tier+recency ---
    flat = [_e("a1"), _e("a2"), _e("a3")]
    fails += _check("empty query + flat tiers == newest-k",
                    [e["text"] for e in lr.select(flat, "", 2)] == ["a2", "a3"])

    # --- K > corpus, corrupt entries, determinism ---
    messy = [None, {"id": 1}, _e("   "), _e("real lesson"), "a bare string"]
    got = lr.select(messy, "anything", 10)
    fails += _check("K > corpus: all well-formed, corrupt skipped",
                    len(got) == 1 and got[0]["text"] == "real lesson")
    fails += _check("k<=0 or empty pool -> []",
                    lr.select(pool, query, 0) == [] and lr.select([], query, 5) == [])
    fails += _check("deterministic across calls",
                    lr.select(pool, query, 8) == lr.select(pool, query, 8))

    # --- score excludes usage counts (anti-Goodhart: field must be inert) ---
    a, b = _e("texel stretch"), dict(_e("texel stretch"), uses=9999)
    fails += _check("usage-count field is inert",
                    lr.score(a, lr.tokens("texel"), 0, 2) == lr.score(b, lr.tokens("texel"), 0, 2))

    # --- archive spill ---
    d = tempfile.mkdtemp()
    active = os.path.join(d, "factory-methods.json")
    data = {"category": "factory-methods", "seq": 45,
            "entries": [_e("lesson %02d" % i) for i in range(45)]}
    moved = lr.spill_overflow(data, active, 40)
    arch = json.load(open(lr.archive_path_for(active), encoding="utf-8"))
    fails += _check("spill: 5 moved, active trimmed to exactly cap",
                    moved == 5 and len(data["entries"]) == 40
                    and data["entries"][0]["text"] == "lesson 05")
    fails += _check("spill: overflow landed verbatim, oldest first",
                    [e["text"] for e in arch["entries"]] == ["lesson %02d" % i for i in range(5)]
                    and arch["category"] == "factory-methods-archive")
    data["entries"].extend(_e("lesson %02d" % i) for i in range(45, 48))
    moved = lr.spill_overflow(data, active, 40)
    arch = json.load(open(lr.archive_path_for(active), encoding="utf-8"))
    fails += _check("spill: second overflow appends (5+3), never overwrites",
                    moved == 3 and len(arch["entries"]) == 8
                    and arch["entries"][-1]["text"] == "lesson 07")
    fails += _check("spill: under cap is a no-op",
                    lr.spill_overflow({"entries": [_e("x")]}, active, 40) == 0)
    _write(active, data["entries"])
    pool2 = lr.load_pool(active)
    fails += _check("load_pool: archive (older) + active, in age order",
                    len(pool2) == 48 and pool2[0]["text"] == "lesson 00"
                    and pool2[-1]["text"] == "lesson 47")
    fails += _check("load_pool: missing files -> []",
                    lr.load_pool(os.path.join(d, "nope.json")) == [])

    # --- perf: scoring 100 entries stays in microsecond territory (spec: < 10ms) ---
    big = [_e("lesson about %d grip texel capture atlas words" % i,
              tier="symbolic-only" if i % 3 else None) for i in range(100)]
    lr.select(big, query, 8)  # warm
    best = min(_timed(big, query) for _ in range(3))
    fails += _check("perf: select over 100 entries < 10ms (best %.2fms)" % (best * 1000),
                    best < 0.010)

    # --- factory._learned_block knob wiring ---
    factory.LEARNINGS_DIR = tempfile.mkdtemp()
    fm = os.path.join(factory.LEARNINGS_DIR, "factory-methods.json")
    _write(fm, [_e("recent filler method %d about gui overlays" % i) for i in range(9)])
    _write(lr.archive_path_for(fm), [_e(gold, tier="capture-confirmed")],
           category="factory-methods-archive")
    _write(os.path.join(factory.LEARNINGS_DIR, "weapons.json"),
           [_e("blade needs converging apex thin cross-section")], category="weapons")

    blk_default = factory._learned_block("melee-weapon", query)
    fails += _check("default (no env) stays newest-K: archive invisible",
                    gold not in blk_default and "recent filler method 8" in blk_default)
    os.environ["STUDIO_AGENT_LESSON_RETRIEVAL"] = "scored"
    blk_scored = factory._learned_block("melee-weapon", query)
    fails += _check("scored: the archived gold lesson is retrieved",
                    gold in blk_scored and "[capture-confirmed]" in blk_scored)
    fails += _check("scored: family bucket still contributes",
                    "converging apex" in blk_scored)
    fails += _check("scored: header + tier rule preserved",
                    blk_scored.startswith("LEARNED METHODS") and "Tier rule:" in blk_scored)
    # fail-open: corrupt active file must not raise in either mode
    with open(fm, "w", encoding="utf-8") as fh:
        fh.write("{ not json")
    blk_corrupt = factory._learned_block("melee-weapon", query)
    fails += _check("scored + corrupt active: archive still serves, no crash",
                    gold in blk_corrupt)
    os.environ.pop("STUDIO_AGENT_LESSON_RETRIEVAL", None)
    fails += _check("newest + corrupt active: falls back to bucket only",
                    "converging apex" in factory._learned_block("melee-weapon", query))
    fails += _check("no sources at all -> empty block",
                    factory._learned_block(None, None) == "")

    print("\n%d failure(s)" % fails)
    return 1 if fails else 0


def _timed(big, query):
    t0 = time.perf_counter()
    lr.select(big, query, 8)
    return time.perf_counter() - t0


if __name__ == "__main__":
    sys.exit(main())
