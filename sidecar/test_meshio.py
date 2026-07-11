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

    # ---- textured parse (v4, the texture slice) ----
    with tempfile.TemporaryDirectory() as d:
        tp = os.path.join(d, "tex.glb")
        positions = struct.pack("<9f", 0, 0, 0, 1, 0, 0, 0, 1, 0)
        uvs = struct.pack("<6f", 0.0, 0.0, 1.0, 0.0, 0.0, 1.0)
        png = b"\x89PNG\r\n\x1a\n" + b"fakepngbody!"  # content is opaque to the reader
        indices = struct.pack("<3H", 0, 1, 2) + b"\x00\x00"
        binchunk = positions + uvs + png + indices
        gltf = {
            "asset": {"version": "2.0"},
            "meshes": [{"primitives": [{
                "attributes": {"POSITION": 0, "TEXCOORD_0": 1}, "indices": 2}]}],
            "images": [{"mimeType": "image/png", "bufferView": 2}],
            "accessors": [
                {"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"},
                {"bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC2"},
                {"bufferView": 3, "componentType": 5123, "count": 3, "type": "SCALAR"},
            ],
            "bufferViews": [
                {"buffer": 0, "byteOffset": 0, "byteLength": 36},
                {"buffer": 0, "byteOffset": 36, "byteLength": 24},
                {"buffer": 0, "byteOffset": 60, "byteLength": len(png)},
                {"buffer": 0, "byteOffset": 60 + len(png), "byteLength": 6},
            ],
            "buffers": [{"byteLength": len(binchunk)}],
        }
        jsonchunk = json.dumps(gltf).encode()
        jsonchunk += b" " * ((4 - len(jsonchunk) % 4) % 4)
        total = 12 + 8 + len(jsonchunk) + 8 + len(binchunk)
        with open(tp, "wb") as fh:
            fh.write(b"glTF" + struct.pack("<II", 2, total))
            fh.write(struct.pack("<II", len(jsonchunk), 0x4E4F534A) + jsonchunk)
            fh.write(struct.pack("<II", len(binchunk), 0x004E4942) + binchunk)
        out = meshio.parse_glb_textured(tp)
        fails += _check("uvs aligned with vertices", out["uvs"] == [[0, 0], [1, 0], [0, 1]])
        import base64 as b64mod
        tex = out.get("texture") or {}
        fails += _check("embedded atlas extracted",
                        tex.get("mime") == "image/png" and b64mod.b64decode(tex.get("base64", ""))[:4] == b"\x89PNG")

    # ---- atlas RGBA decode + textured read_reference_mesh (texture-apply slice, Luau half) ----
    # decode_atlas_rgba: the Luau side cannot decode PNG, so the sidecar hands it raw RGBA it can
    # buffer.fromstring straight into EditableImage:WritePixelsBuffer (top-down rows, R,G,B,A order).
    try:
        from PIL import Image as _PILImage
        _have_pil = True
    except ImportError:
        _have_pil = False
    if not _have_pil:
        print("  SKIP  PIL not available for atlas-decode tests")
    else:
        import io as _io

        def _glb_with_png(path, png_bytes):
            positions = struct.pack("<9f", 0, 0, 0, 1, 0, 0, 0, 1, 0)
            uvs = struct.pack("<6f", 0.0, 0.0, 1.0, 0.0, 0.0, 1.0)
            indices = struct.pack("<3H", 0, 1, 2) + b"\x00\x00"
            binchunk = positions + uvs + png_bytes + indices
            gltf = {
                "asset": {"version": "2.0"},
                "meshes": [{"primitives": [{
                    "attributes": {"POSITION": 0, "TEXCOORD_0": 1}, "indices": 2}]}],
                "images": [{"mimeType": "image/png", "bufferView": 2}],
                "accessors": [
                    {"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"},
                    {"bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC2"},
                    {"bufferView": 3, "componentType": 5123, "count": 3, "type": "SCALAR"},
                ],
                "bufferViews": [
                    {"buffer": 0, "byteOffset": 0, "byteLength": 36},
                    {"buffer": 0, "byteOffset": 36, "byteLength": 24},
                    {"buffer": 0, "byteOffset": 60, "byteLength": len(png_bytes)},
                    {"buffer": 0, "byteOffset": 60 + len(png_bytes), "byteLength": 6},
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

        def _png(w, h, color):
            buf = _io.BytesIO()
            _PILImage.new("RGBA", (w, h), color).save(buf, format="PNG")
            return buf.getvalue()

        with tempfile.TemporaryDirectory() as d:
            tp = os.path.join(d, "atlas4.glb")
            _glb_with_png(tp, _png(4, 4, (200, 160, 30, 255)))
            res = meshio.decode_atlas_rgba(tp)
            fails += _check("atlas decodes to native size", res["width"] == 4 and res["height"] == 4)
            fails += _check("rgba byte length = w*h*4", len(res["rgba"]) == 4 * 4 * 4)
            fails += _check("rgba is R,G,B,A order", tuple(res["rgba"][:4]) == (200, 160, 30, 255))

            tp2 = os.path.join(d, "atlas20.glb")
            _glb_with_png(tp2, _png(20, 20, (10, 20, 30, 255)))
            res2 = meshio.decode_atlas_rgba(tp2, max_size=8)
            fails += _check("atlas downscaled to max_size", max(res2["width"], res2["height"]) == 8)
            fails += _check("downscaled rgba length matches dims",
                            len(res2["rgba"]) == res2["width"] * res2["height"] * 4)

            # decode_image_rgba: the Gemini-painted atlas arrives as a bare PNG file (not embedded
            # in a GLB) — same RGBA contract so the Luau apply path is identical.
            pp = os.path.join(d, "painted.png")
            with open(pp, "wb") as fh:
                fh.write(_png(20, 20, (77, 66, 55, 255)))
            res3 = meshio.decode_image_rgba(pp, max_size=8)
            fails += _check("png decodes + downscales to max_size",
                            max(res3["width"], res3["height"]) == 8
                            and len(res3["rgba"]) == res3["width"] * res3["height"] * 4)
            fails += _check("png rgba pixel order", tuple(res3["rgba"][:4]) == (77, 66, 55, 255))

            # render_uv_template: rasterize the UV islands (glTF top-down space — Roblox samples
            # the atlas 1:1, no V-flip, proven live on the DivineRapier) for the texture painter.
            # The synthetic GLB's one face covers UV (0,0),(1,0),(0,1) — the upper-left triangle.
            tpl = meshio.render_uv_template(tp, size=64)
            im = _PILImage.open(_io.BytesIO(tpl)).convert("RGB")
            fails += _check("template is the requested size", im.size == (64, 64))
            inside = im.getpixel((16, 16))   # centroid region of the upper-left triangle
            outside = im.getpixel((60, 60))  # far corner, outside every island
            fails += _check("island interior is filled (non-black)", sum(inside) > 60)
            fails += _check("outside the islands stays black", sum(outside) == 0)

    # textured read_reference_mesh on the real cleaned rapier: vertex-aligned uvs + a LEAN texture
    # descriptor (pixels ship via the separate binary /assets/texture route, never in this JSON).
    rapier = os.path.join(meshio.ASSET_DIR, "rapier2-clean.glb")
    if os.path.isfile(rapier):
        base = meshio.read_reference_mesh("rapier2-clean.glb")
        fails += _check("default read omits uvs (backward compat)", "uvs" not in base)
        tx = meshio.read_reference_mesh("rapier2-clean.glb", textured=True)
        fails += _check("textured read includes vertex-aligned uvs",
                        len(tx.get("uvs", [])) == len(tx["vertices"]) and len(tx["uvs"]) > 0)
        tex = tx.get("texture") or {}
        fails += _check("texture descriptor present with dims",
                        tex.get("present") is True and tex.get("width", 0) > 0 and tex.get("height", 0) > 0)
        fails += _check("textured read stays lean (no base64 pixels in JSON)", "base64" not in tex)
    else:
        print("  SKIP  rapier2-clean.glb not present for textured read test")

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
