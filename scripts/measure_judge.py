#!/usr/bin/env python3
"""measure_judge.py - measure the above-generic JUDGE for one category (stone 3), via the local proxy.

Re-runs the train-category above-generic judge over a category's rubric criteria with TWO prompts - the
CURRENT one and a TIGHTENED one - and runs the discrimination back-test (a MEAN vs a GREAT artifact),
emitting RAW numbers so "the judge under-rejects / this is low-value" is answered by measurement, not
assumption. Uses the working local proxy (8319), NOT the down 8318 path.

Usage: python scripts/measure_judge.py <category>     (mean/great artifact descriptions: built-in for vfx)
Env: LOOP_DIRECTOR_URL (default 8319), LOOP_DIRECTOR_KEY, LOOP_MODEL.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
URL = os.environ.get("LOOP_DIRECTOR_URL", "http://127.0.0.1:8319/v1/messages")
KEY = os.environ.get("LOOP_DIRECTOR_KEY", "")
MODEL = os.environ.get("LOOP_MODEL", "claude-opus-4-8")

# Mean (generic floor) + great (top exemplar) artifact descriptions per category for the back-test.
ARTIFACTS = {
    "vfx": {
        "mean": "A single ParticleEmitter parented to a part: the default white-square texture, CONSTANT "
        "Size/Transparency/Color (no NumberSequence/ColorSequence curves), Enabled and always-on (no "
        "lifecycle/cleanup), one omnidirectional spray, no layering, no light, no per-particle variation - "
        "the generic default a beginner ships.",
        "great": "A layered impact: a coordinated SET of role-separated emitters (a bright core flash + a "
        "soft glow + fast sparks/debris + slow rising smoke + a synced PointLight + a directed shockwave), "
        "each driven by authored NumberSequence/ColorSequence lifetime curves (size/transparency/color over "
        "life), additive self-lit authored sprites, distinct per-layer motion (drag/acceleration), "
        "choreographed timed phases (burst -> sustain -> dissipate via task.delay/sub-emitters), and a "
        "triggered one-shot Emit() lifecycle with Debris cleanup + a one-frame light flash + camera shake.",
    },
    "combat": {
        "mean": "A single full-body attack animation that plays on click; hit detection via a .Touched "
        "event or a swing-wide hitbox; the same fixed damage every time; no wind-up/contact/recovery timing; "
        "no hit reactions, no combos, no hitstop, no impact feedback - the generic default a beginner ships.",
        "great": "Marker-driven combat: named animation event markers (HitStart/HitEnd/Contact/CancelOpen) "
        "drive active-frame SWEPT hitboxes (not .Touched); a deliberate anticipation -> contact -> "
        "follow-through timing skeleton with strength-scaled HIT-STOP; directional hit reactions layered "
        "additively; cancelable combos with input buffering; an impact bus where VFX/SFX/camera-shake/"
        "knockback all fire off one contact event and scale by attack strength; server-authoritative hit "
        "validation tied to the marker contact frame.",
    },
    "audio": {
        "mean": "One legacy Sound instance playing a single placeholder library clip at full Volume on "
        "every event, 2D and non-spatial (no AudioEmitter/AudioListener, no RollOff) - the SAME clip every "
        "time with no randomization or pitch/volume variation, no SoundGroup/AudioFader bus or ducking, no "
        "AudioCompressor/Limiter, no AudioReverb/AudioEcho/occlusion, no event-marker sync - the generic "
        "default a beginner ships.",
        "great": "A pro audio system built ON Roblox's audio library: fitting curated SFX/music assets "
        "chosen per event with LAYERED + RANDOMIZED variation (multiple alternate clips + per-play pitch/"
        "volume jitter); TRUE 3D positional audio via the modern Audio API (an AudioPlayer -> effect nodes "
        "-> AudioEmitter -> AudioListener -> AudioDeviceOutput graph wired by Wire, with tuned distance/"
        "attenuation curves); a SoundGroup/AudioFader bus hierarchy (SFX/Music/Ambient/UI) with DUCKING "
        "(music drops under key SFX) and AudioCompressor/AudioLimiter mastering; AudioReverb/AudioEcho effect "
        "nodes + reverb zones + EQ-based occlusion (muffle behind walls) for environmental reflection; and "
        "event-marker-synced one-shots (GetMarkerReachedSignal) plus adaptive LAYERED music whose stems "
        "crossfade by game state via AudioFader.",
    },
}

TIER_W = {"baseline": 0, "good": 1, "exceptional": 2}
SCORE_V = {"pass": 1.0, "partial": 0.5, "fail": 0.0}


def proxy(prompt, max_tokens):
    body = json.dumps({"model": MODEL, "max_tokens": max_tokens,
                       "messages": [{"role": "user", "content": prompt}]}).encode("utf-8")
    headers = {"content-type": "application/json", "anthropic-version": "2023-06-01",
               "authorization": "Bearer " + KEY}
    for _ in range(6):
        try:
            req = urllib.request.Request(URL, data=body, headers=headers, method="POST")
            with urllib.request.urlopen(req, timeout=180) as r:
                data = json.loads(r.read().decode("utf-8"))
            return "".join(b.get("text", "") for b in data.get("content", []) if b.get("type") == "text")
        except urllib.error.HTTPError as e:
            msg = e.read().decode("utf-8", "replace")
            if e.code in (502, 503) or "unknown provider" in msg:
                time.sleep(12)
                continue
            sys.exit("HTTP %s: %s" % (e.code, msg[:200]))
        except Exception as e:  # noqa: BLE001
            sys.exit("proxy error: %s" % e)
    sys.exit("proxy unreachable")


def first_json(text, kind):
    import re
    m = re.search(r"\[.*\]" if kind == "array" else r"\{.*\}", text or "", re.S)
    return json.loads(m.group(0)) if m else []


def judge(criteria, mean_desc, tighten):
    extra = ("" if not tighten else
             " ADDITIONAL STRICTNESS: also REJECT if the criterion is a generic best-practice/tip rather "
             "than a deliberate SYSTEM; if it does not name a SPECIFIC mechanism the floor lacks; if it "
             "could be satisfied by toggling ONE property/value; or if it merely says an element EXISTS. "
             "Only keep criteria that require multi-part systems engineering the floor omits.")
    prompt = (
        "You are an ABOVE-GENERIC JUDGE (STRICT). The GENERIC FLOOR for these criteria - what default/"
        "generic builds and a basic tutorial already produce - is:\n\"%s\"\nFor EACH criterion, REJECT it "
        "if ANY of: (a) that floor already satisfies it; (b) a beginner following a basic tutorial would "
        "produce it; (c) it checks surface PRESENCE rather than deliberate systems DEPTH. Only 'keep' if it "
        "genuinely requires systems engineering the floor omits. Be very skeptical; when in doubt, REJECT.%s"
        "\n\nRespond with EXACTLY one minified JSON array: "
        '[{"id":"...","verdict":"keep|reject","reason":"<=15 words"}]\n\nCRITERIA:\n%s'
    ) % (mean_desc, extra, json.dumps([{"id": c["id"], "tier": c["tier"], "statement": c["statement"]}
                                       for c in criteria], indent=1))
    rows = first_json(proxy(prompt, 2000), "array")
    by = {r.get("id"): r.get("verdict") for r in rows}
    kept = [c["id"] for c in criteria if by.get(c["id"]) != "reject"]
    return kept, rows


def grade(artifact, criteria):
    prompt = (
        "Grade this ARTIFACT against the rubric criteria: one row per criterion, score pass/partial/fail by "
        "the criterion's described requirement vs the artifact's behavior - never on vibe.\n\nARTIFACT:\n%s"
        "\n\nCRITERIA:\n%s\n\nRespond with EXACTLY one minified JSON array: "
        '[{"id":"...","score":"pass|partial|fail"}]'
    ) % (artifact, json.dumps([{"id": c["id"], "tier": c["tier"], "statement": c["statement"]}
                              for c in criteria], indent=1))
    rows = first_json(proxy(prompt, 2000), "array")
    return rows


def aggregate(rows, criteria):
    tier = {c["id"]: c["tier"] for c in criteria}
    num = den = 0.0
    for r in rows:
        w = (TIER_W.get(tier.get(r.get("id")), 0)) + 1
        num += w * SCORE_V.get(r.get("score"), 0.0)
        den += w
    return (num / den) if den else 0.0


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: measure_judge.py <category>")
    cat = sys.argv[1].strip().lower()
    with open(os.path.join(ROOT, "docs", "superpowers", "rubrics", cat + ".rubric.json"), encoding="utf-8") as f:
        rub = json.load(f)
    crit = rub.get("criteria", [])
    art = ARTIFACTS.get(cat)
    if not art:
        sys.exit("no mean/great artifacts defined for '%s' - add to ARTIFACTS" % cat)

    n = len(crit)
    kept_cur, _ = judge(crit, art["mean"], tighten=False)
    kept_tig, rows_tig = judge(crit, art["mean"], tighten=True)
    mean_rows = grade(art["mean"], crit)
    great_rows = grade(art["great"], crit)
    m, g = aggregate(mean_rows, crit), aggregate(great_rows, crit)
    gap = g - m
    rejected_tig = [r for r in rows_tig if r.get("verdict") == "reject"]

    print("=== JUDGE MEASUREMENT: %s (%d criteria) via 8319 proxy ===" % (cat, n))
    print("CURRENT judge survival:   %d/%d = %d%%" % (len(kept_cur), n, round(100 * len(kept_cur) / n)))
    print("TIGHTENED judge survival: %d/%d = %d%%" % (len(kept_tig), n, round(100 * len(kept_tig) / n)))
    if rejected_tig:
        print("  tightened-judge would REJECT:")
        for r in rejected_tig:
            print("   - %s: %s" % (r.get("id"), r.get("reason")))
    print("BACK-TEST: mean=%.3f  great=%.3f  gap=%.3f  -> %s"
          % (m, g, gap, "PASS" if (gap >= 0.35 and m <= 0.5 and g >= 0.7) else "FAIL"))


if __name__ == "__main__":
    main()
