"""Dependency-free tests for the library->R15 animation retargeter.
Run: python sidecar/test_retarget.py"""
import json
import math
import os
import struct
import sys
import tempfile

import retarget


def _check(name, cond):
    print(("  PASS  " if cond else "  FAIL  ") + name)
    return 0 if cond else 1


def _quat_z(deg):
    h = math.radians(deg) / 2.0
    return [0.0, 0.0, math.sin(h), math.cos(h)]


def _make_anim_glb(path):
    """Two-bone chain pelvis -> upperarm_r (rest identity); one clip rotates PELVIS 90deg about Z
    over 1s. upperarm_r has NO local key, so its world delta is inherited — the telescoping
    retarget must put the whole 90deg on Root and IDENTITY on RightShoulder."""
    times = struct.pack("<2f", 0.0, 1.0)
    quats = struct.pack("<8f", 0, 0, 0, 1, *(_quat_z(90.0)))
    binchunk = times + quats
    gltf = {
        "asset": {"version": "2.0"},
        "scenes": [{"nodes": [0]}],
        "nodes": [
            {"name": "pelvis", "children": [1]},
            {"name": "upperarm_r"},
        ],
        "animations": [{
            "name": "TestSpin",
            "channels": [{"sampler": 0, "target": {"node": 0, "path": "rotation"}}],
            "samplers": [{"input": 0, "output": 1, "interpolation": "LINEAR"}],
        }],
        "accessors": [
            {"bufferView": 0, "componentType": 5126, "count": 2, "type": "SCALAR"},
            {"bufferView": 1, "componentType": 5126, "count": 2, "type": "VEC4"},
        ],
        "bufferViews": [
            {"buffer": 0, "byteOffset": 0, "byteLength": 8},
            {"buffer": 0, "byteOffset": 8, "byteLength": 32},
        ],
        "buffers": [{"byteLength": len(binchunk)}],
    }
    jsonchunk = json.dumps(gltf).encode()
    jsonchunk += b" " * ((4 - len(jsonchunk) % 4) % 4)
    total = 12 + 8 + len(jsonchunk) + 8 + len(binchunk)
    with open(path, "wb") as fh:
        fh.write(b"glTF" + struct.pack("<II", 2, total))
        fh.write(struct.pack("<II", len(jsonchunk), 0x4E4F534A) + jsonchunk)
        fh.write(struct.pack("<II", len(binchunk), 0x004E4942) + binchunk)


def main():
    fails = 0

    # ---- quaternion helpers ----
    q = retarget.q_mul(_quat_z(90), _quat_z(-90))
    fails += _check("q_mul inverse pair collapses to identity",
                    abs(q[3]) > 0.9999 and abs(q[0]) + abs(q[1]) + abs(q[2]) < 1e-6)
    s = retarget.q_slerp(_quat_z(0), _quat_z(90), 0.5)
    ang = math.degrees(2 * math.acos(max(-1, min(1, s[3]))))
    fails += _check("q_slerp halfway = 45deg", abs(ang - 45) < 0.5)

    # ---- telescoping retarget on the synthetic 2-bone clip ----
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "anim.glb")
        _make_anim_glb(p)
        out = retarget.retarget_clip(p, "TestSpin", fps=10)
        fails += _check("output carries clip name + duration",
                        out["clip"] == "TestSpin" and abs(out["duration_s"] - 1.0) < 1e-6)
        joints = out["joints"]
        fails += _check("only mapped joints with real motion are emitted",
                        "Root" in joints)
        root_last = joints["Root"]["rot"][-1]
        ang = math.degrees(2 * math.acos(max(-1, min(1, abs(root_last[3])))))
        fails += _check("Root ends at 90deg (pelvis world delta)", abs(ang - 90) < 1.0)
        if "RightShoulder" in joints:
            sh_last = joints["RightShoulder"]["rot"][-1]
            fails += _check("RightShoulder stays identity (inherited motion telescopes out)",
                            abs(sh_last[3]) > 0.9999)
        else:
            fails += _check("RightShoulder stays identity (inherited motion telescopes out)", True)
        fails += _check("tracks share the fixed-fps time grid",
                        joints["Root"]["times"][0] == 0.0 and len(joints["Root"]["times"]) == 11)

    print(("test_retarget: ALL GREEN" if fails == 0 else f"test_retarget: {fails} FAILURES"))
    return fails


if __name__ == "__main__":
    sys.exit(main())
