"""Dependency-free tests for the GLB reader. Run: python sidecar/test_meshio.py
Builds a minimal one-triangle GLB from scratch, then (if present) parses a real reference asset."""
import json
import os
import struct
import sys
import tempfile

import meshio


def _check(name, cond):
    print(("  PASS  " if cond else "  FAIL  ") + name)
    return 0 if cond else 1


def _make_glb(path):
    # One triangle: 3 float32 vec3 positions + 3 uint16 indices.
    positions = struct.pack("<9f", 0, 0, 0, 1, 0, 0, 0, 1, 0)
    indices = struct.pack("<3H", 0, 1, 2) + b"\x00\x00"  # pad to 4 bytes
    binchunk = positions + indices
    gltf = {
        "asset": {"version": "2.0"},
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1}]}],
        "accessors": [
            {"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"},
            {"bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR"},
        ],
        "bufferViews": [
            {"buffer": 0, "byteOffset": 0, "byteLength": 36},
            {"buffer": 0, "byteOffset": 36, "byteLength": 6},
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


def _make_skinned_glb(path):
    # One triangle skinned to 2 bones: Grip at origin (verts 0,1 @ weight 1), Seg1 at (0,2,0)
    # (vert 2 @ weight 1). IBMs are translation-only column-major inverses (-t).
    positions = struct.pack("<9f", 0, 0, 0, 1, 0, 0, 0, 2, 0)
    joints = struct.pack("<12B", 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0)  # uint8 vec4 x3
    weights = struct.pack("<12f", 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0)
    ident = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0]
    ibm_grip = struct.pack("<16f", *(ident + [0, 0, 0, 1]))          # inverse of I = I
    ibm_seg = struct.pack("<16f", *(ident + [0, -2, 0, 1]))          # inverse of T(0,2,0)
    indices = struct.pack("<3H", 0, 1, 2) + b"\x00\x00"
    binchunk = positions + joints + weights + ibm_grip + ibm_seg + indices
    off_j, off_w = 36, 48
    off_ibm, off_idx = 96, 224
    gltf = {
        "asset": {"version": "2.0"},
        "nodes": [
            {"name": "Grip", "children": [1]},
            {"name": "Seg1", "translation": [0, 2, 0]},
            {"name": "Mesh", "mesh": 0, "skin": 0},
        ],
        "skins": [{"joints": [0, 1], "inverseBindMatrices": 3}],
        "meshes": [{"primitives": [{
            "attributes": {"POSITION": 0, "JOINTS_0": 1, "WEIGHTS_0": 2}, "indices": 4}]}],
        "accessors": [
            {"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"},
            {"bufferView": 1, "componentType": 5121, "count": 3, "type": "VEC4"},
            {"bufferView": 2, "componentType": 5126, "count": 3, "type": "VEC4"},
            {"bufferView": 3, "componentType": 5126, "count": 2, "type": "MAT4"},
            {"bufferView": 4, "componentType": 5123, "count": 3, "type": "SCALAR"},
        ],
        "bufferViews": [
            {"buffer": 0, "byteOffset": 0, "byteLength": 36},
            {"buffer": 0, "byteOffset": off_j, "byteLength": 12},
            {"buffer": 0, "byteOffset": off_w, "byteLength": 48},
            {"buffer": 0, "byteOffset": off_ibm, "byteLength": 128},
            {"buffer": 0, "byteOffset": off_idx, "byteLength": 6},
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
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "tri.glb")
        _make_glb(p)
        out = meshio.parse_glb(p)
        fails += _check("triangle verts", out["vertices"] == [[0, 0, 0], [1, 0, 0], [0, 1, 0]])
        fails += _check("triangle face 1-indexed", out["faces"] == [[1, 2, 3]])
        fails += _check("no skin key on unskinned glb", "skin" not in out)

        sp = os.path.join(d, "skinned.glb")
        _make_skinned_glb(sp)
        out = meshio.parse_glb(sp)
        skin = out.get("skin") or {}
        bones = skin.get("bones") or []
        fails += _check("skin bones parsed", len(bones) == 2 and bones[0]["name"] == "Grip" and bones[1]["name"] == "Seg1")
        fails += _check("bone parent chain", bones[0]["parent"] == -1 and bones[1]["parent"] == 0)
        fails += _check("bone rest position from inverse(IBM)", bones[1]["position"] == [0, 2, 0])
        fails += _check("dominant vertex_bone per vertex", skin.get("vertex_bone") == [0, 0, 1])
        fails += _check("exact 1.0 weights are not lossy", skin.get("weights_lossy") is False)

    # ---- glTF animation parsing (the Pilot Doctrine's animation leg, v3) ----
    with tempfile.TemporaryDirectory() as d:
        ap = os.path.join(d, "anim.glb")
        # 2-keyframe rotation on one named node
        times = struct.pack("<2f", 0.0, 1.0)
        quats = struct.pack("<8f", 0, 0, 0, 1, 0, 0.70711, 0, 0.70711)
        binchunk = times + quats
        gltf = {
            "asset": {"version": "2.0"},
            "nodes": [{"name": "RightArm"}],
            "animations": [{
                "name": "Swing",
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
        with open(ap, "wb") as fh:
            fh.write(b"glTF" + struct.pack("<II", 2, total))
            fh.write(struct.pack("<II", len(jsonchunk), 0x4E4F534A) + jsonchunk)
            fh.write(struct.pack("<II", len(binchunk), 0x004E4942) + binchunk)
        cat = meshio.list_animations(ap)
        fails += _check("animation catalog lists the clip",
                        cat["animations"] == [{"name": "Swing", "channels": 1, "duration_s": 1.0}])
        clip = meshio.parse_animation(ap, "Swing")
        rot = clip["joints"].get("RightArm", {}).get("rotation", {})
        fails += _check("clip channel keyed by node name", rot.get("times") == [0.0, 1.0])
        fails += _check("quat keyframes parsed", rot.get("values", [[None]])[1] == [0, 0.70711, 0, 0.70711])
        fails += _check("clip duration", clip["duration_s"] == 1.0)
        try:
            meshio.parse_animation(ap, "NoSuchClip")
            fails += _check("unknown clip errors with the available list", False)
        except meshio.MeshError as e:
            fails += _check("unknown clip errors with the available list", "Swing" in str(e))

    for bad in ("../x.glb", "a/b.glb", "x.fbx"):
        try:
            meshio.read_reference_mesh(bad)
            fails += _check(f"bad name rejected: {bad!r}", False)
        except meshio.MeshError:
            fails += _check(f"bad name rejected: {bad!r}", True)

    real = os.path.join(meshio.ASSET_DIR, "Mannequin_F.glb")
    if os.path.isfile(real):
        out = meshio.read_reference_mesh("Mannequin_F.glb")
        nv, nf = len(out["vertices"]), len(out["faces"])
        inrange = all(1 <= i <= nv for f in out["faces"][:200] for i in f)
        fails += _check(f"real asset parses (verts={nv}, faces={nf})", nv > 100 and nf > 100 and inrange)
    else:
        print("  SKIP  real asset not present")

    print(f"=== {('ALL PASS' if fails == 0 else str(fails) + ' FAILED')} ===")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
