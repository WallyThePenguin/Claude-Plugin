"""Gemini vision second-opinion on rig/grip/animation state — eyes, not hands.

Protocol (spec 2026-07-12-gemini-vision-review-design.md): every request carries (1) a Roblox
conventions PRIMER, (2) a live scene DIGEST (the same numbers Claude reasons from; arm joints
read-only), (3) labeled stills — a filmstrip stands in for video (the proxy is chat-completions;
no mp4). Gemini returns a JSON critique; corrections are validated against a GRIP-ONLY whitelist
and only then translated to Luau that drives the EXISTING grip surfaces. Gemini-authored code is
never executed — corrections are data.

Transport mirrors gemini_image.py (same proxy, same describe seam, key never logged).
Probe-verified 2026-07-12: image->text works through the proxy on gemini-3.5-flash-low(high).
"""

import json
import os
import re
import time
import urllib.error
import urllib.request

from gemini_image import _data_url, self_describe

REVIEW_MODEL = os.environ.get("STUDIO_AGENT_GEMINI_REVIEW_MODEL", "gemini-3.5-flash-low(high)")
REVIEW_TIMEOUT_S = int(os.environ.get("STUDIO_AGENT_GEMINI_REVIEW_TIMEOUT_S", "180"))

PRIMER = """ROBLOX CONVENTIONS (authoritative — never guess against these):
Motor6D:  Part1.CFrame = Part0.CFrame * C0 * Transform * C1:Inverse()
Grip:     AgentEditGrip Motor6D — Part0=RightHand, Part1=Handle,
          C0 ~= RightGripAttachment.CFrame (hand-local), C1 = tool.Grip
Units:    studs; rotations = Euler XYZ in DEGREES
R15:      character faces -Z; +X = its right; +Y = up"""

RULES = """OUTPUT CONTRACT — reply with ONLY this JSON object (no prose, no markdown fences):
{
  "diagnosis": "plain-English read of what is wrong (may discuss arm pose)",
  "observations": [{"label": "<image label>", "note": "<what you see there>"}],
  "corrections": [
    {"target": "AgentEditGrip|tool|Semantic_Grip", "property": "C0|C1|Grip|CFrame",
     "op": "rotate_local|translate_local|set", "axis": "X|Y|Z", "deg": 0,
     "x": 0, "y": 0, "z": 0, "pos": [0,0,0], "euler_deg": [0,0,0],
     "rationale": "why this correction"}
  ],
  "confidence": 0.0,
  "need_more_views": ["describe any view you need but cannot read"]
}
RULES:
1. Corrections may ONLY target: AgentEditGrip.C0, AgentEditGrip.C1, tool.Grip,
   Semantic_Grip.CFrame — plus {"target": "RightGrip", "property": "Weld",
   "op": "delete"} IF AND ONLY IF the digest's handle_joints shows a Weld named
   RightGrip alongside the AgentEditGrip Motor6D (a stale runtime weld that overrides
   every grip edit). Arm/other joints are READ-ONLY context — discuss them in
   diagnosis, never in corrections.
2. Ops: rotate_local (axis + deg), translate_local (x/y/z studs), set (pos + euler_deg),
   delete (RightGrip.Weld only). Prefer relative ops. Values in studs / degrees per the
   primer. NOTE: two joints driving one part means CFrame corrections are USELESS until
   the stale weld is deleted — order the delete first.
3. If a view is unreadable, add it to need_more_views — NEVER invent numbers.
4. Every correction needs a rationale. You advise; deterministic code decides."""

# (target, property) pairs corrections may touch — the grip surfaces, nothing else.
# ("RightGrip", "Weld") is delete-ONLY: the stale runtime grip weld that fights
# AgentEditGrip for the Handle (live-caught 2026-07-12; two joints, the Weld wins).
WHITELIST = {
    ("AgentEditGrip", "C0"),
    ("AgentEditGrip", "C1"),
    ("tool", "Grip"),
    ("Semantic_Grip", "CFrame"),
    ("RightGrip", "Weld"),
}
OPS = ("rotate_local", "translate_local", "set", "delete")
MAX_DEG = 360.0
MAX_STUDS = 50.0


def build_messages(task, digest, images):
    """One user message: primer + rules + task + digest text, then per-image label + image_url.
    images = [(label, path)]. Labels let the model cite frames in observations."""
    header = (
        PRIMER + "\n\n" + RULES + "\n\nTASK: " + str(task)
        + "\n\nSCENE DIGEST (live DataModel dump; the same numbers the primary agent reads):\n"
        + json.dumps(digest, indent=2)
    )
    content = [{"type": "text", "text": header}]
    for label, path in images:
        content.append({"type": "text", "text": "[image: %s]" % label})
        content.append({"type": "image_url", "image_url": {"url": _data_url(path)}})
    return [{"role": "user", "content": content}]


def parse_review(text):
    """Model text -> review dict. Strips markdown fences, extracts the outermost {...} so
    prose-wrapped replies still parse. Missing optional keys get safe defaults.
    Raises ValueError when no JSON object is found (callers must not best-effort apply)."""
    s = str(text)
    fenced = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", s, re.DOTALL)
    if fenced:
        s = fenced.group(1)
    start = s.find("{")
    end = s.rfind("}")
    if start < 0 or end <= start:
        raise ValueError("no JSON object in review reply")
    try:
        d = json.loads(s[start : end + 1])
    except json.JSONDecodeError as exc:
        raise ValueError("unparseable review JSON: %s" % exc) from exc
    if not isinstance(d, dict):
        raise ValueError("review JSON is not an object")
    d.setdefault("diagnosis", "")
    d.setdefault("observations", [])
    d.setdefault("corrections", [])
    d.setdefault("confidence", 0.0)
    d.setdefault("need_more_views", [])
    if not isinstance(d["corrections"], list):
        d["corrections"] = []
    return d


def _num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def validate_corrections(corrections):
    """-> (accepted, rejected). accepted keeps input order; each rejection is
    {correction, reason}. Enforces the whitelist + op schema + sane magnitudes so a
    hallucinated correction can never reach the DataModel."""
    accepted, rejected = [], []
    for c in corrections or []:
        if not isinstance(c, dict):
            rejected.append({"correction": c, "reason": "not an object"})
            continue
        key = (str(c.get("target")), str(c.get("property")))
        if key not in WHITELIST:
            rejected.append({"correction": c, "reason": "target outside grip whitelist: %s.%s" % key})
            continue
        op = c.get("op")
        # delete is ONLY the stale-RightGrip escape hatch; RightGrip is ONLY deletable.
        if (op == "delete") != (key == ("RightGrip", "Weld")):
            rejected.append({"correction": c,
                             "reason": "delete is valid only for RightGrip.Weld (and vice versa)"})
            continue
        if op == "delete":
            accepted.append(c)
            continue
        if op == "rotate_local":
            if c.get("axis") not in ("X", "Y", "Z"):
                rejected.append({"correction": c, "reason": "rotate_local needs axis X|Y|Z"})
                continue
            if not _num(c.get("deg")) or abs(c["deg"]) > MAX_DEG:
                rejected.append({"correction": c, "reason": "deg must be a number, |deg| <= %g" % MAX_DEG})
                continue
        elif op == "translate_local":
            vals = [c.get(k, 0) for k in ("x", "y", "z")]
            if not all(_num(v) for v in vals) or any(abs(v) > MAX_STUDS for v in vals):
                rejected.append({"correction": c, "reason": "x/y/z must be numbers, |v| <= %g studs" % MAX_STUDS})
                continue
        elif op == "set":
            pos, eul = c.get("pos"), c.get("euler_deg")
            if (not isinstance(pos, list) or len(pos) != 3 or not all(_num(v) for v in pos)
                    or not isinstance(eul, list) or len(eul) != 3 or not all(_num(v) for v in eul)):
                rejected.append({"correction": c, "reason": "set needs pos[3] + euler_deg[3] numbers"})
                continue
            if any(abs(v) > MAX_STUDS for v in pos) or any(abs(v) > MAX_DEG for v in eul):
                rejected.append({"correction": c, "reason": "set values out of sane bounds"})
                continue
        else:
            rejected.append({"correction": c, "reason": "unknown op: %r" % (op,)})
            continue
        accepted.append(c)
    return accepted, rejected


def _cf_expr(pos, euler_deg):
    return (
        "CFrame.new(%g, %g, %g) * CFrame.Angles(math.rad(%g), math.rad(%g), math.rad(%g))"
        % (pos[0], pos[1], pos[2], euler_deg[0], euler_deg[1], euler_deg[2])
    )


def _rot_expr(axis, deg):
    r = "math.rad(%g)" % deg
    return {
        "X": "CFrame.Angles(%s, 0, 0)" % r,
        "Y": "CFrame.Angles(0, %s, 0)" % r,
        "Z": "CFrame.Angles(0, 0, %s)" % r,
    }[axis]


def to_luau(accepted, rig_name="AgentRig"):
    """VALIDATED corrections -> one Luau chunk for the bridge run_luau route. Drives the same
    surfaces ToolFactory.applyGrip does (tool.Grip + AgentEditGrip.C1 stay in sync); local-space
    ops post-multiply. Only ever called with validate_corrections() output — numbers, not model
    text, reach the source (no interpolation of free-form strings)."""
    lines = [
        'local rig = workspace:FindFirstChild("%s")' % rig_name,
        'if not rig then return "no rig %s" end' % rig_name,
        'local hand = rig:FindFirstChild("RightHand", true)',
        'local grip = hand and hand:FindFirstChild("AgentEditGrip")',
        'if not grip then return "no AgentEditGrip" end',
        "local handle = grip.Part1",
        "local tool = handle and handle:FindFirstAncestorWhichIsA('Tool')",
        "local applied = {}",
    ]
    for c in accepted:
        tgt, prop, op = c["target"], c["property"], c["op"]
        if tgt == "AgentEditGrip":
            ref = "grip.%s" % prop
            if op == "rotate_local":
                lines.append("%s = %s * %s" % (ref, ref, _rot_expr(c["axis"], c["deg"])))
            elif op == "translate_local":
                lines.append("%s = %s * CFrame.new(%g, %g, %g)"
                             % (ref, ref, c.get("x", 0), c.get("y", 0), c.get("z", 0)))
            else:
                lines.append("%s = %s" % (ref, _cf_expr(c["pos"], c["euler_deg"])))
            if prop == "C1":
                lines.append("if tool then tool.Grip = grip.C1 end")
            lines.append('table.insert(applied, "AgentEditGrip.%s %s")' % (prop, op))
        elif tgt == "tool":
            lines.append('if not tool then return "no Tool for Grip edit" end')
            if op == "rotate_local":
                lines.append("tool.Grip = tool.Grip * %s" % _rot_expr(c["axis"], c["deg"]))
            elif op == "translate_local":
                lines.append("tool.Grip = tool.Grip * CFrame.new(%g, %g, %g)"
                             % (c.get("x", 0), c.get("y", 0), c.get("z", 0)))
            else:
                lines.append("tool.Grip = %s" % _cf_expr(c["pos"], c["euler_deg"]))
            # applyGrip convention: the edit-mode joint mirrors tool.Grip
            lines.append("grip.C1 = tool.Grip")
            lines.append('table.insert(applied, "tool.Grip %s")' % op)
        elif tgt == "RightGrip":  # delete-only: purge the stale runtime grip weld
            lines.append('local stale = hand:FindFirstChild("RightGrip")')
            lines.append('if stale and stale:IsA("Weld") then')
            lines.append("  stale:Destroy()")
            lines.append('  table.insert(applied, "RightGrip Weld deleted")')
            lines.append("end")
        else:  # Semantic_Grip.CFrame
            lines.append('local att = handle and handle:FindFirstChild("Semantic_Grip")')
            lines.append('if not att then return "no Semantic_Grip" end')
            if op == "rotate_local":
                lines.append("att.CFrame = att.CFrame * %s" % _rot_expr(c["axis"], c["deg"]))
            elif op == "translate_local":
                lines.append("att.CFrame = att.CFrame * CFrame.new(%g, %g, %g)"
                             % (c.get("x", 0), c.get("y", 0), c.get("z", 0)))
            else:
                lines.append("att.CFrame = %s" % _cf_expr(c["pos"], c["euler_deg"]))
            lines.append('table.insert(applied, "Semantic_Grip.CFrame %s")' % op)
    lines.append('return "applied: " .. table.concat(applied, ", ")')
    return "\n".join(lines)


def review(task, digest, images, describe=None, model=None):
    """Send the review request; -> {ok, review, raw, wall_s} | {ok: False, error}.
    Same proxy/describe seams as gemini_image.generate (key held in-process, never logged)."""
    t0 = time.time()
    desc = (describe or self_describe)()
    base_url = (desc.get("baseUrl") or "").rstrip("/")
    key = desc.get("proxyKey") or ""
    if not base_url:
        return {"ok": False, "error": "no proxy baseUrl from describe (is Studio open with the bridge?)"}
    body = {"model": model or REVIEW_MODEL, "messages": build_messages(task, digest, images)}
    req = urllib.request.Request(
        base_url + "/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + key},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=REVIEW_TIMEOUT_S) as r:
            text = r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return {"ok": False, "error": "proxy HTTP %s: %r" % (e.code, e.read()[:300])}
    except (urllib.error.URLError, OSError, TimeoutError) as e:
        return {"ok": False, "error": "proxy transport error: %s" % e}
    try:
        content = str(json.loads(text).get("choices", [{}])[0].get("message", {}).get("content") or "")
    except (ValueError, AttributeError, IndexError):
        return {"ok": False, "error": "malformed proxy response: " + text[:200]}
    try:
        parsed = parse_review(content)
    except ValueError as e:
        return {"ok": False, "error": str(e), "raw": content[:2000]}
    return {"ok": True, "review": parsed, "raw": content, "wall_s": round(time.time() - t0, 1)}
