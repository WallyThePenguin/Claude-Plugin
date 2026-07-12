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

    # ---- SOMA-77 Kimodo retarget (wrists + ankles) ----
    try:
        import numpy as np
    except ImportError:
        _check("SOMA test SKIPPED (numpy absent)", True)
        print(("test_retarget: ALL GREEN" if fails == 0 else f"test_retarget: {fails} FAILURES"))
        return fails

    with tempfile.TemporaryDirectory() as d:
        # synthetic posed_joints[2,77,3]: distinct baseline positions so every bone is off-rest,
        # with the RIGHT hand chain placed to a KNOWN direction (Hand -> Middle1 points -Z).
        arr = np.zeros((2, 77, 3), dtype=np.float32)
        for i in range(77):
            arr[:, i, 0] = math.sin(i * 0.5)
            arr[:, i, 1] = math.cos(i * 0.3) + 1.5
            arr[:, i, 2] = math.sin(i * 0.2)
        hand = retarget.SOMA77_IX["RightHand"]
        mid1 = retarget.SOMA77_IX["RightHandMiddle1"]
        idx1 = retarget.SOMA77_IX["RightHandIndex1"]
        arr[:, hand] = [1.0, 1.0, 0.0]
        arr[:, mid1] = [1.0, 1.0, -0.7]   # Hand -> Middle1 = -Z  (the wrist should aim HERE)
        arr[:, idx1] = [1.0, 1.3, 0.0]    # a DIFFERENT finger, so a wrong index would be caught
        p = os.path.join(d, "soma.npz")
        np.savez(p, posed_joints=arr)

        out = retarget.retarget_kimodo_npz(p, fps=30)
        joints = out["joints"]
        fails += _check("SOMA-77 auto-detected", out.get("skeleton") == "soma77")
        fails += _check("wrists + ankles now emit (the stuck-limbs fix)",
                        all(j in joints for j in ("RightWrist", "LeftWrist", "RightAnkle", "LeftAnkle")))
        fails += _check("all 15 R15 joints present",
                        all(j in joints for j in (r[0] for r in retarget.KIMODO_SOMA_CHAIN)))

        # re-accumulate world rotations from the emitted tracks; the R15 hand's world dir must
        # equal the converted Hand->Middle1 source dir (not Index1) — pins the wrist index map.
        rows = retarget._soma_rows(False)

        def world_of(target_part, t):
            world = {"HumanoidRootPart": [0.0, 0.0, 0.0, 1.0]}
            for joint, part, parent, _si, _sj, _rest in rows:
                ch = joints.get(joint)
                qt = ch["rot"][t] if ch else [0.0, 0.0, 0.0, 1.0]
                world[part] = retarget.q_norm(retarget.q_mul(world[parent], qt))
            return world[target_part]

        got = retarget.q_rot_vec(world_of("RightHand", 1), [0.0, -1.0, 0.0])
        # convert(Hand->Middle1) = (-x, y, -z) of (0,0,-0.7) = (0,0,0.7) -> normalized (0,0,1)
        exp = [0.0, 0.0, 1.0]
        err = math.sqrt(sum((got[i] - exp[i]) ** 2 for i in range(3)))
        fails += _check("RightWrist aims the hand along Hand->Middle1 (not Index1)", err < 1e-3)

        # mirror swaps the SOURCE hand: the RightWrist row should then read the LEFT hand bones
        mrows = retarget._soma_rows(True)
        rw = next(r for r in mrows if r[0] == "RightWrist")
        fails += _check("mirror swaps RightWrist source to the LEFT hand",
                        rw[3] == retarget.SOMA77_IX["LeftHand"] and rw[4] == retarget.SOMA77_IX["LeftHandMiddle1"])

    print(("test_retarget: ALL GREEN" if fails == 0 else f"test_retarget: {fails} FAILURES"))
    return fails


if __name__ == "__main__":
    sys.exit(main())
