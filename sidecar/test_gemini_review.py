"""Dependency-free tests for gemini_review (the vision second-opinion seam).
Run: python sidecar/test_gemini_review.py"""
import json
import os
import sys
import tempfile

import gemini_review


def _check(name, cond):
    print(("  PASS  " if cond else "  FAIL  ") + name)
    return 0 if cond else 1


def _tmp_png():
    f = tempfile.NamedTemporaryFile(suffix=".png", delete=False)
    f.write(b"\x89PNG\r\n\x1a\nfakebytes")
    f.close()
    return f.name


def test_build_messages():
    fails = 0
    png = _tmp_png()
    digest = {"hand": {"RightGripAttachment": [0, -0.158, 0]}}
    msgs = gemini_review.build_messages(
        "review the sword grip", digest, [("front", png), ("t=0.30s", png)]
    )
    fails += _check("one user message", len(msgs) == 1 and msgs[0]["role"] == "user")
    content = msgs[0]["content"]
    texts = [c["text"] for c in content if c["type"] == "text"]
    images = [c for c in content if c["type"] == "image_url"]
    fails += _check("two images attached", len(images) == 2)
    joined = "\n".join(texts)
    fails += _check("primer present", "Part1.CFrame = Part0.CFrame * C0" in joined)
    fails += _check("rules present", "need_more_views" in joined)
    fails += _check("digest embedded", "RightGripAttachment" in joined)
    fails += _check("task present", "review the sword grip" in joined)
    # each image is PRECEDED by its label text block
    idx_front = next(i for i, c in enumerate(content)
                     if c["type"] == "text" and c["text"] == "[image: front]")
    fails += _check("label precedes image", content[idx_front + 1]["type"] == "image_url")
    os.unlink(png)
    return fails


def test_parse_review():
    fails = 0
    good = {"diagnosis": "blade points down", "observations": [],
            "corrections": [], "confidence": 0.8, "need_more_views": []}
    fails += _check("clean JSON parses",
                    gemini_review.parse_review(json.dumps(good))["diagnosis"] == "blade points down")
    fenced = "```json\n" + json.dumps(good) + "\n```"
    fails += _check("fenced JSON parses",
                    gemini_review.parse_review(fenced)["confidence"] == 0.8)
    wrapped = "Here is my analysis:\n" + json.dumps(good) + "\nHope that helps!"
    fails += _check("prose-wrapped JSON parses",
                    gemini_review.parse_review(wrapped)["diagnosis"] == "blade points down")
    try:
        gemini_review.parse_review("no json here at all")
        fails += _check("garbage raises", False)
    except ValueError:
        fails += _check("garbage raises", True)
    minimal = gemini_review.parse_review('{"diagnosis": "ok"}')
    fails += _check("missing keys defaulted",
                    minimal["corrections"] == [] and minimal["need_more_views"] == []
                    and minimal["observations"] == [] and minimal["confidence"] == 0.0)
    return fails


def test_validate():
    fails = 0
    ok_rot = {"target": "AgentEditGrip", "property": "C0", "op": "rotate_local",
              "axis": "Z", "deg": -90, "rationale": "level the blade"}
    ok_tr = {"target": "AgentEditGrip", "property": "C1", "op": "translate_local",
             "x": 0, "y": -0.2, "z": 0, "rationale": "seat the hilt"}
    ok_set = {"target": "Semantic_Grip", "property": "CFrame", "op": "set",
              "pos": [0, -1.8, 0], "euler_deg": [0, 0, 0], "rationale": "re-stamp"}
    arm = {"target": "RightShoulder", "property": "C0", "op": "rotate_local",
           "axis": "X", "deg": 10, "rationale": "raise arm"}
    bad_op = {"target": "AgentEditGrip", "property": "C0", "op": "lerp",
              "axis": "X", "deg": 5, "rationale": "?"}
    huge = {"target": "AgentEditGrip", "property": "C0", "op": "rotate_local",
            "axis": "X", "deg": 720, "rationale": "spin"}
    far = {"target": "AgentEditGrip", "property": "C1", "op": "translate_local",
           "x": 999, "y": 0, "z": 0, "rationale": "teleport"}
    bad_set = {"target": "tool", "property": "Grip", "op": "set",
               "pos": [0, 0], "euler_deg": [0, 0, 0], "rationale": "malformed"}
    ok_del = {"target": "RightGrip", "property": "Weld", "op": "delete",
              "rationale": "stale runtime grip weld fights AgentEditGrip"}
    bad_del = {"target": "AgentEditGrip", "property": "C0", "op": "delete",
               "rationale": "nuke the motor"}
    acc, rej = gemini_review.validate_corrections(
        [ok_rot, ok_tr, ok_set, ok_del, arm, bad_op, huge, far, bad_set, bad_del]
    )
    fails += _check("4 accepted", len(acc) == 4)
    fails += _check("6 rejected", len(rej) == 6)
    fails += _check("delete only valid for RightGrip weld",
                    any(r["correction"] is bad_del for r in rej)
                    and any(a is ok_del for a in acc))
    fails += _check("arm joint rejected (read-only rule)",
                    any(r["correction"]["target"] == "RightShoulder" for r in rej))
    fails += _check("every rejection carries a reason",
                    all(isinstance(r.get("reason"), str) and r["reason"] for r in rej))
    fails += _check("accepted preserve order",
                    [a["op"] for a in acc] == ["rotate_local", "translate_local", "set", "delete"])
    return fails


def test_to_luau():
    fails = 0
    acc, _ = gemini_review.validate_corrections([
        {"target": "AgentEditGrip", "property": "C0", "op": "rotate_local",
         "axis": "Z", "deg": -90, "rationale": "r"},
        {"target": "tool", "property": "Grip", "op": "set",
         "pos": [0, -1.8, 0], "euler_deg": [0, 0, 90], "rationale": "r"},
        {"target": "RightGrip", "property": "Weld", "op": "delete", "rationale": "r"},
    ])
    lua = gemini_review.to_luau(acc)
    fails += _check("delete targets only the RightGrip weld by name+class",
                    'FindFirstChild("RightGrip")' in lua and ":IsA(\"Weld\")" in lua
                    and ":Destroy()" in lua)
    fails += _check("post-multiplies C0 for local rotate",
                    "grip.C0 = grip.C0 * CFrame.Angles" in lua)
    fails += _check("radians conversion present", "math.rad(-90" in lua)
    fails += _check("tool.Grip set", "tool.Grip = " in lua)
    fails += _check("C1 kept in sync with Grip (applyGrip convention)",
                    "grip.C1 = tool.Grip" in lua)
    fails += _check("no string interpolation of model text",
                    "loadstring" not in lua)
    return fails


def main():
    fails = 0
    fails += test_build_messages()
    fails += test_parse_review()
    fails += test_validate()
    fails += test_to_luau()
    print("test_gemini_review: " + ("ALL GREEN" if fails == 0 else f"{fails} FAILURES"))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
