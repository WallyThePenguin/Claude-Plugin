"""Land a Kimodo .npz onto the AgentRig as an editable KeyframeSequence, over the dev bridge.

retarget.py (fresh from disk — no sidecar restart) -> per-R15-PART quaternion tracks -> a bridge
luau that reuses the tested AnimationClip.buildPoseTree/getOrCreateClip to build
rig/AnimSaves/<clip>. The retarget emits JOINT names (Root/RightWrist/...); buildPoseTree keys by
the CHILD PART name (LowerTorso/RightHand/...), so we map joint->part via the chain here. The big
pose JSON rides embedded in the posted luau (a [==[...]==] long string — JSON never contains
]==]), so it never enters the agent's context. Preview/verify with capture_animation.

Usage:  python land_kimodo.py <file.npz> [clip=KimodoSlash] [mirror=0]
"""

import json
import os
import sys
import time
import urllib.request

import retarget

SIDECAR = "http://127.0.0.1:" + os.environ.get("SIDECAR_PORT", "8389")

LAND_LUAU = r"""
local raw = [==[__JSON__]==]
local data = game:GetService("HttpService"):JSONDecode(raw)
local AnimationClip = require(script.Parent.AnimationClip)
local rig = workspace:FindFirstChild("AgentRig")
if not rig then return "NO AgentRig in workspace" end
local ks = AnimationClip.getOrCreateClip(rig, "__CLIP__")
for _, kf in ks:GetKeyframes() do kf:Destroy() end
ks.Loop = true
local parts, times = data.parts, data.times
local nparts = 0
for _ in pairs(parts) do nparts += 1 end
local built = 0
for fi, t in ipairs(times) do
  local map = {}
  for part, rot in pairs(parts) do
    local q = rot[fi]
    if q then map[part] = CFrame.new(0, 0, 0, q[1], q[2], q[3], q[4]) end
  end
  local pose = AnimationClip.buildPoseTree(rig, map)
  if pose then
    local nkf = Instance.new("Keyframe")
    nkf.Time = AnimationClip.normalizeTime(t)
    pose.Parent = nkf
    ks:AddKeyframe(nkf)
    built += 1
  end
end
return string.format("built %d keyframes across %d parts in AgentRig/AnimSaves/__CLIP__", built, nparts)
"""


def _joint_to_part():
    """R15 joint name -> R15 part name, from both chains (part = the thing that moves)."""
    m = {}
    for row in retarget.KIMODO_SMPLX_CHAIN:
        m[row[0]] = row[1]
    for row in retarget.KIMODO_SOMA_CHAIN:
        m[row[0]] = row[1]
    return m


def bridge_luau(code, timeout_s=90):
    req = urllib.request.Request(
        SIDECAR + "/agent", data=json.dumps({"kind": "luau", "code": code}).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=10) as r:
        cid = json.loads(r.read().decode())["id"]
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        time.sleep(0.5)
        with urllib.request.urlopen(SIDECAR + "/agent/result?id=" + str(cid), timeout=10) as r:
            res = json.loads(r.read().decode())
        if isinstance(res, dict) and "ok" in res:
            return res
    return {"ok": False, "error": "bridge luau timed out"}


def land(npz_name, clip="KimodoSlash", mirror=False, drop_parts=None):
    """drop_parts: iterable of R15 PART names to OMIT (they hold their rest pose) — used to A/B
    the wrist/ankle channels against a body-only landing."""
    drop = set(drop_parts or ())
    out = retarget.retarget_reference_kimodo(npz_name, mirror=mirror)
    j2p = _joint_to_part()
    parts, times = {}, None
    for jname, ch in out["joints"].items():
        part = j2p.get(jname, jname)
        if part in drop:
            continue
        parts[part] = ch["rot"]
        times = ch["times"]
    if not times:
        return {"ok": False, "error": "retarget produced no moving joints"}
    payload = json.dumps({"parts": parts, "times": times})
    if "]==]" in payload:  # would break the long-string; should never happen with JSON
        return {"ok": False, "error": "payload contains ]==] — unsafe to embed"}
    code = LAND_LUAU.replace("__JSON__", payload).replace("__CLIP__", clip)
    res = bridge_luau(code)
    res["skeleton"] = out.get("skeleton")
    res["duration_s"] = out.get("duration_s")
    res["joints_landed"] = sorted(parts.keys())
    return res


_BODY_DROP = {"RightHand", "LeftHand", "RightFoot", "LeftFoot"}  # the wrist/ankle-driven parts

if __name__ == "__main__":
    npz = sys.argv[1] if len(sys.argv) > 1 else "kimodo-soma-slash.npz"
    clip = sys.argv[2] if len(sys.argv) > 2 else "KimodoSlash"
    mir = len(sys.argv) > 3 and sys.argv[3] not in ("0", "", "false", "no")
    drop = _BODY_DROP if (len(sys.argv) > 4 and sys.argv[4] == "body") else None
    print(json.dumps(land(npz, clip, mir, drop_parts=drop), indent=1))
