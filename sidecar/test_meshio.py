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


def main():
    fails = 0
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "tri.glb")
        _make_glb(p)
        out = meshio.parse_glb(p)
        fails += _check("triangle verts", out["vertices"] == [[0, 0, 0], [1, 0, 0], [0, 1, 0]])
        fails += _check("triangle face 1-indexed", out["faces"] == [[1, 2, 3]])

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
