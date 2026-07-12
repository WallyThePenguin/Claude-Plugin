"""grip_review — one-command Gemini vision review of the AgentRig's grip.

Dumps the live scene digest over the bridge (the same numbers Claude reads), attaches
labeled capture PNGs, sends the gemini_review request, validates corrections against the
grip whitelist, and PRINTS the verdict. Dry-run by default: --apply is required for the
validated Luau to touch the DataModel (and even then it drives only the existing grip
surfaces — see gemini_review.to_luau).

Usage (from sidecar/):
  python grip_review.py --task "judge the sword hold" --img front=path.png --img t0=path2.png
  python grip_review.py ... --apply        # run validated corrections through the bridge
"""

import argparse
import json
import sys
import time
import urllib.request

import gemini_review

SIDECAR = "http://127.0.0.1:8389"

# The digest contract (spec 2026-07-12): grip surfaces + SemanticFrame + arm joints READ-ONLY.
DIGEST_LUAU = r"""
local rig = workspace:FindFirstChild("AgentRig")
if not rig then return "NO AgentRig" end
local HttpService = game:GetService("HttpService")
local function cf(c)
  if not c then return nil end
  local x, y, z = c:ToEulerAnglesXYZ()
  local function r(v) return math.floor(v * 1000 + 0.5) / 1000 end
  return { pos = { r(c.Position.X), r(c.Position.Y), r(c.Position.Z) },
           euler_deg = { r(math.deg(x)), r(math.deg(y)), r(math.deg(z)) } }
end
local hand = rig:FindFirstChild("RightHand", true)
local ga = hand and hand:FindFirstChild("RightGripAttachment")
local grip = hand and hand:FindFirstChild("AgentEditGrip")
local handle = grip and grip.Part1
local tool = handle and handle:FindFirstAncestorWhichIsA("Tool")
local sg = handle and handle:FindFirstChild("Semantic_Grip")
local digest = {
  hand = { RightGripAttachment = cf(ga and ga.CFrame) },
  sword = {
    tool_name = tool and tool.Name,
    handle_size = handle and { handle.Size.X, handle.Size.Y, handle.Size.Z },
    Semantic_Grip = cf(sg and sg.CFrame),
    SemanticFrame = handle and handle:GetAttribute("SemanticFrame"),
  },
  current_grip = {
    C0 = cf(grip and grip.C0),
    C1 = cf(grip and grip.C1),
    tool_Grip = cf(tool and tool.Grip),
  },
  arm_readonly = {},
}
for _, n in { "RightShoulder", "RightElbow", "RightWrist" } do
  local j = rig:FindFirstChild(n, true)
  if j and j:IsA("Motor6D") then
    digest.arm_readonly[n] = { C0 = cf(j.C0), C1 = cf(j.C1), Transform = cf(j.Transform) }
  end
end
return HttpService:JSONEncode(digest)
"""


def bridge_luau(code, timeout_s=30):
    """Run a Luau chunk over the bridge; -> the first return value (string) or raises."""
    req = urllib.request.Request(
        SIDECAR + "/agent",
        data=json.dumps({"kind": "luau", "code": code}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        cid = json.loads(r.read().decode()).get("id")
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        time.sleep(0.5)
        with urllib.request.urlopen(SIDECAR + "/agent/result?id=" + str(cid), timeout=10) as r:
            res = json.loads(r.read().decode())
        if isinstance(res, dict) and "ok" in res:
            if not res.get("ok"):
                raise RuntimeError("bridge luau failed: %s" % res.get("error"))
            result = res.get("result")
            if isinstance(result, str):
                try:
                    result = json.loads(result)
                except ValueError:
                    return result
            if isinstance(result, dict):
                returns = result.get("returns") or []
                return returns[0] if returns else ""
            return str(result)
    raise TimeoutError("bridge luau timed out (is Studio open with the bridge?)")


def fetch_digest():
    raw = bridge_luau(DIGEST_LUAU)
    if raw == "NO AgentRig":
        raise RuntimeError("no AgentRig in workspace")
    return json.loads(raw)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Gemini vision review of the AgentRig grip")
    ap.add_argument("--task", required=True, help="what to judge, in plain English")
    ap.add_argument("--img", action="append", default=[],
                    help="label=path.png (repeat; order preserved)")
    ap.add_argument("--model", default=None, help="override the review model id")
    ap.add_argument("--apply", action="store_true",
                    help="run VALIDATED corrections through the bridge (default: dry-run)")
    ap.add_argument("--json-out", default=None, help="also write the full result JSON here")
    args = ap.parse_args(argv)

    images = []
    for spec in args.img:
        label, _, path = spec.partition("=")
        if not path:
            ap.error("--img needs label=path, got: " + spec)
        images.append((label, path))
    if not images:
        ap.error("at least one --img is required (the eyes need frames)")

    digest = fetch_digest()
    print("digest: grip C0=%s C1=%s toolGrip=%s" % (
        digest["current_grip"]["C0"]["euler_deg"],
        digest["current_grip"]["C1"]["pos"],
        digest["current_grip"]["tool_Grip"]["euler_deg"],
    ))
    print("sending %d image(s) to %s ..." % (len(images), args.model or gemini_review.REVIEW_MODEL))
    result = gemini_review.review(args.task, digest, images, model=args.model)
    if not result.get("ok"):
        print("REVIEW FAILED: %s" % result.get("error"))
        if result.get("raw"):
            print("raw head: " + result["raw"][:500])
        return 1

    rev = result["review"]
    accepted, rejected = gemini_review.validate_corrections(rev["corrections"])
    print("\n--- diagnosis (%.1fs, confidence %s) ---" % (result["wall_s"], rev.get("confidence")))
    print(rev["diagnosis"])
    for o in rev["observations"]:
        print("  [%s] %s" % (o.get("label"), o.get("note")))
    if rev["need_more_views"]:
        print("needs more views: " + "; ".join(str(v) for v in rev["need_more_views"]))
    print("\ncorrections: %d accepted, %d rejected" % (len(accepted), len(rejected)))
    for a in accepted:
        print("  ACCEPT %s.%s %s: %s" % (a["target"], a["property"], a["op"], a.get("rationale")))
    for r in rejected:
        print("  REJECT (%s): %s" % (r["reason"], json.dumps(r["correction"])[:120]))

    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as f:
            json.dump({"digest": digest, "review": rev,
                       "accepted": accepted, "rejected": rejected}, f, indent=2)
        print("wrote " + args.json_out)

    if accepted and args.apply:
        lua = gemini_review.to_luau(accepted)
        print("\napplying validated corrections through the bridge ...")
        print(bridge_luau(lua))
    elif accepted:
        print("\n(dry-run: re-run with --apply to execute the accepted corrections)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
