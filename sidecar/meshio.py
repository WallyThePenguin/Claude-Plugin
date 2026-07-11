"""Minimal pure-stdlib GLB (glTF 2.0 binary) mesh reader for the asset-ingestion pipeline.

Real-world reference assets (CC0 libraries like Quaternius) arrive as .glb files; the plugin
cannot read files, so the sidecar parses them and serves {vertices, faces} JSON that Luau turns
into an EditableMesh -> CreateMeshPartAsync (the June breakthrough path, no manual 3D Importer).

Scope (v1, deliberate): POSITION + indices of every mesh primitive, merged; component types
float32 / uint8 / uint16 / uint32; byteStride honored. Node transforms, normals, UVs, and
materials are NOT applied — this feeds silhouette/proportion study and re-topology reference,
not 1:1 visual reproduction. Faces are 1-indexed for Luau.

SKIN extraction (v2, weapon-as-limb 2026-07-11): when the GLB carries a skin (the Blender
rigid-rig export), parse_glb also returns {skin = {bones, vertex_bone, weights_lossy}} so the
plugin can rebuild the rig via EditableMesh:AddBone + SetVertexBones (the G3-proven runtime
skinning path — bones + weights survive CreateMeshPartAsync and deform in edit). Bone rest
positions come from inverse(inverseBindMatrices) — rigid-transform inverse (R^T | -R^T t) —
so Blender's baked bone orientations don't corrupt positions; the plugin authors Roblox Bone
instances with IDENTITY rotation at those positions (simpler Transform composition, and the
deterministic band weights make orientation irrelevant to the deformation). vertex_bone is the
DOMINANT bone per vertex (0-based); weights_lossy=true flags any vertex whose max weight was
below 0.9 (foreign multi-weighted skins import lossily — ours are exact 1.0 bands).
"""

import json
import os
import struct

ASSET_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets", "reference"
)

MAX_VERTS = 60000

_COMPONENT = {
    5120: ("b", 1),  # int8
    5121: ("B", 1),  # uint8
    5122: ("h", 2),  # int16
    5123: ("H", 2),  # uint16
    5125: ("I", 4),  # uint32
    5126: ("f", 4),  # float32
}
_TYPE_COUNT = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


class MeshError(ValueError):
    """Client error — maps to HTTP 400."""


def _read_glb(path: str):
    with open(path, "rb") as fh:
        data = fh.read()
    if len(data) < 12 or data[0:4] != b"glTF":
        raise MeshError("not a GLB file")
    (length,) = struct.unpack_from("<I", data, 8)
    offset = 12
    gltf = None
    binchunk = b""
    while offset + 8 <= min(length, len(data)):
        clen, ctype = struct.unpack_from("<II", data, offset)
        payload = data[offset + 8 : offset + 8 + clen]
        if ctype == 0x4E4F534A:  # 'JSON'
            gltf = json.loads(payload.decode("utf-8"))
        elif ctype == 0x004E4942:  # 'BIN'
            binchunk = payload
        offset += 8 + clen
    if gltf is None:
        raise MeshError("GLB has no JSON chunk")
    return gltf, binchunk


def _accessor_values(gltf, binchunk, accessor_index):
    acc = gltf["accessors"][accessor_index]
    fmt, csize = _COMPONENT[acc["componentType"]]
    ncomp = _TYPE_COUNT[acc["type"]]
    count = acc["count"]
    view = gltf["bufferViews"][acc["bufferView"]]
    base = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
    stride = view.get("byteStride") or (csize * ncomp)
    out = []
    for i in range(count):
        off = base + i * stride
        out.append(struct.unpack_from("<" + fmt * ncomp, binchunk, off))
    return out


def _skin_bones(gltf, binchunk):
    """skins[0] -> [{name, parent (0-based bone index or -1), position [x,y,z]}].
    Rest position = inverse(IBM) translation via the rigid-transform inverse (R^T | -R^T t);
    glTF matrices are column-major float32."""
    skin = gltf["skins"][0]
    joints = skin["joints"]  # node indices, in JOINTS_0 index order
    nodes = gltf.get("nodes", [])
    joint_pos = {int(n): i for i, n in enumerate(joints)}
    parent_of_node = {}
    for ni, node in enumerate(nodes):
        for child in node.get("children", []):
            parent_of_node[int(child)] = ni
    ibms = None
    if "inverseBindMatrices" in skin:
        ibms = _accessor_values(gltf, binchunk, skin["inverseBindMatrices"])
    bones = []
    for bi, node_index in enumerate(joints):
        name = nodes[node_index].get("name", f"Bone{bi}")
        pnode = parent_of_node.get(int(node_index))
        parent = joint_pos.get(pnode, -1) if pnode is not None else -1
        if ibms is not None:
            m = ibms[bi]  # 16 floats, column-major: columns of (R|t)
            r = ((m[0], m[4], m[8]), (m[1], m[5], m[9]), (m[2], m[6], m[10]))
            t = (m[12], m[13], m[14])
            # inverse translation = -R^T t; R^T rows are r's columns == original rows
            pos = [
                -(r[0][0] * t[0] + r[1][0] * t[1] + r[2][0] * t[2]),
                -(r[0][1] * t[0] + r[1][1] * t[1] + r[2][1] * t[2]),
                -(r[0][2] * t[0] + r[1][2] * t[1] + r[2][2] * t[2]),
            ]
        else:
            pos = [0.0, 0.0, 0.0]
        bones.append({"name": name, "parent": parent, "position": [round(c, 4) for c in pos]})
    return bones


def parse_glb(path: str) -> dict:
    """{vertices: [[x,y,z]...], faces: [[a,b,c]...1-indexed], meshes: n, source: name,
    skin?: {bones, vertex_bone (0-based dominant bone per vertex), weights_lossy}}."""
    gltf, binchunk = _read_glb(path)
    has_skin = bool(gltf.get("skins"))
    vertices = []
    faces = []
    vertex_bone = []
    weights_lossy = False
    mesh_count = 0
    for mesh in gltf.get("meshes", []):
        for prim in mesh.get("primitives", []):
            attrs = prim.get("attributes", {})
            if "POSITION" not in attrs or "indices" not in prim:
                continue
            mesh_count += 1
            vbase = len(vertices)
            positions = _accessor_values(gltf, binchunk, attrs["POSITION"])
            vertices.extend([round(p[0], 4), round(p[1], 4), round(p[2], 4)] for p in positions)
            if len(vertices) > MAX_VERTS:
                raise MeshError(f"mesh exceeds {MAX_VERTS} vertices — too heavy for EditableMesh")
            if has_skin and "JOINTS_0" in attrs and "WEIGHTS_0" in attrs:
                jvals = _accessor_values(gltf, binchunk, attrs["JOINTS_0"])
                wacc = gltf["accessors"][attrs["WEIGHTS_0"]]
                wvals = _accessor_values(gltf, binchunk, attrs["WEIGHTS_0"])
                wscale = {5121: 1 / 255.0, 5123: 1 / 65535.0}.get(wacc["componentType"], 1.0)
                for j4, w4 in zip(jvals, wvals):
                    weights = [w * wscale for w in w4]
                    best = max(range(len(weights)), key=lambda i: weights[i])
                    if weights[best] < 0.9:
                        weights_lossy = True
                    vertex_bone.append(int(j4[best]))
            elif has_skin:
                vertex_bone.extend([0] * len(positions))  # unskinned primitive under a skin
            indices = [v[0] for v in _accessor_values(gltf, binchunk, prim["indices"])]
            for t in range(0, len(indices) - 2, 3):
                faces.append(
                    [vbase + indices[t] + 1, vbase + indices[t + 1] + 1, vbase + indices[t + 2] + 1]
                )
    if not vertices:
        raise MeshError("no triangle mesh primitives found")
    out = {
        "vertices": vertices,
        "faces": faces,
        "meshes": mesh_count,
        "source": os.path.basename(path),
    }
    if has_skin:
        out["skin"] = {
            "bones": _skin_bones(gltf, binchunk),
            "vertex_bone": vertex_bone,
            "weights_lossy": weights_lossy,
        }
    return out


def parse_glb_textured(path: str) -> dict:
    """parse_glb PLUS the texture channel (v4, the texture slice): per-vertex UVs from
    TEXCOORD_0 (corner-split order matches the vertex expansion — same accessor walk) and the
    FIRST embedded image (the TRELLIS base-color atlas) as base64. UV convention (PROVEN LIVE
    2026-07-11 on the DivineRapier): NO V-flip anywhere — glTF UVs are top-down and an
    EditableImage written row-by-row from the top (WritePixelsBuffer with PIL tobytes()) samples
    the SAME way, so glTF UVs pass through 1:1. (A flipped import rendered 81%-black — the
    atlas background — and the unflipped re-import rendered correctly.) Returns parse_glb's
    dict + {uvs: [[u,v]...], texture: {mime, base64} | None}. Meshes without TEXCOORD_0 get
    uvs=[]."""
    import base64 as _b64

    out = parse_glb(path)
    gltf, binchunk = _read_glb(path)
    uvs = []
    normals = []
    for mesh in gltf.get("meshes", []):
        for prim in mesh.get("primitives", []):
            attrs = prim.get("attributes", {})
            if "POSITION" not in attrs or "indices" not in prim:
                continue
            n_pos = len(_accessor_values(gltf, binchunk, attrs["POSITION"]))
            if "TEXCOORD_0" in attrs:
                for uv in _accessor_values(gltf, binchunk, attrs["TEXCOORD_0"]):
                    uvs.append([round(uv[0], 5), round(uv[1], 5)])
            else:
                # keep uv list aligned with the vertex list even on mixed primitives
                uvs.extend([[0.0, 0.0]] * n_pos)
            if "NORMAL" in attrs:
                # smooth shading for the Luau side (EditableMesh AddNormal/SetFaceNormals —
                # probed live): without these the corner-split import renders FLAT-shaded and
                # every voxel facet catches its own highlight (the "rocky" look).
                for n in _accessor_values(gltf, binchunk, attrs["NORMAL"]):
                    normals.append([round(n[0], 4), round(n[1], 4), round(n[2], 4)])
            else:
                normals.extend([[0.0, 0.0, 0.0]] * n_pos)
    texture = None
    for img in gltf.get("images", []):
        if "bufferView" in img:
            view = gltf["bufferViews"][img["bufferView"]]
            start = view.get("byteOffset", 0)
            data = binchunk[start:start + view["byteLength"]]
            texture = {
                "mime": img.get("mimeType", "image/png"),
                "base64": _b64.b64encode(data).decode("ascii"),
            }
            break  # the first image = the base-color atlas in TRELLIS exports
    out["uvs"] = uvs if len(uvs) == len(out["vertices"]) else []
    out["normals"] = normals if len(normals) == len(out["vertices"]) else []
    out["texture"] = texture
    return out


def decode_atlas_rgba(path: str, max_size: int = 1024) -> dict:
    """The base-color atlas as raw RGBA bytes for EditableImage:WritePixelsBuffer — the Luau side
    can't decode PNG, so PIL does it here: first embedded image -> RGBA, downscaled so the longest
    edge is <= max_size (the shipping EditableImage tops out around 1024, and a native 1536 atlas
    would also bloat the single-slot bridge). Rows run TOP-DOWN, bytes R,G,B,A per pixel — the plugin
    buffer.fromstring()s the body straight into WritePixelsBuffer and flips V on the UVs, not on the
    image. Returns {width, height, rgba}. Raises MeshError when the GLB carries no embedded image."""
    from io import BytesIO
    from PIL import Image

    gltf, binchunk = _read_glb(path)
    img_bytes = None
    for img in gltf.get("images", []):
        if "bufferView" in img:
            view = gltf["bufferViews"][img["bufferView"]]
            start = view.get("byteOffset", 0)
            img_bytes = binchunk[start:start + view["byteLength"]]
            break
    if img_bytes is None:
        raise MeshError("GLB has no embedded texture image")
    im = Image.open(BytesIO(img_bytes)).convert("RGBA")
    w, h = im.size
    longest = max(w, h)
    if longest > max_size:
        scale = max_size / longest
        im = im.resize((max(1, round(w * scale)), max(1, round(h * scale))), Image.LANCZOS)
        w, h = im.size
    return {"width": w, "height": h, "rgba": im.tobytes()}


def decode_image_rgba(path: str, max_size: int = 1024) -> dict:
    """A bare image FILE (the Gemini-painted atlas PNG) -> the same {width, height, rgba}
    contract as decode_atlas_rgba, so the Luau apply path is identical for embedded-in-GLB and
    painted-on-disk textures. Top-down rows, R,G,B,A — no V-flip (see parse_glb_textured)."""
    from PIL import Image

    im = Image.open(path).convert("RGBA")
    w, h = im.size
    longest = max(w, h)
    if longest > max_size:
        scale = max_size / longest
        im = im.resize((max(1, round(w * scale)), max(1, round(h * scale))), Image.LANCZOS)
        w, h = im.size
    return {"width": w, "height": h, "rgba": im.tobytes()}


def render_uv_template(path: str, size: int = 1024, wire: bool = True,
                       aspect: float | None = None) -> bytes:
    """Rasterize a GLB's UV islands into a PNG template for the texture PAINTER (Gemini): black
    background, light-gray island fill, and (wire=True) white wireframe edges. wire=False is the
    PAINTER's version — on dense meshes the wireframe reads as solid white and pollutes the
    canvas; the clean silhouette fill is the paint-here mask.

    NON-SQUARE canvas: `aspect` = height/width. None (default) AUTO-derives it from the mesh's
    two largest extents (matching the planar unwrap's axis pick), so a full-box planar unwrap
    renders UNDISTORTED on a canvas shaped like the object — the whole canvas is detail budget
    (an aspect-true unwrap inside a SQUARE canvas wasted ~half the texels; measured: the squeezed
    repaint read worse than the near-square one). Roblox samples UV [0,1]^2 over any image dims,
    so non-square atlases are native. Pass aspect=1.0 to force square (non-planar unwraps).

    Drawn in glTF's top-down UV space — exactly the space the painted atlas is sampled in (no
    V-flip, proven live), so painting inside these islands IS painting on the mesh. Returns PNG
    bytes."""
    from io import BytesIO
    from PIL import Image, ImageDraw

    parsed = parse_glb_textured(path)
    uvs, faces = parsed["uvs"], parsed["faces"]
    if not uvs:
        raise MeshError("GLB has no TEXCOORD_0 — unwrap it first (rig_weapon.py --uv planar)")
    if aspect is None:
        # the unwrap's manifest knows the CANVAS aspect (a two-band layout is ~2x the geometric
        # ratio — only rig_weapon knows how it packed the islands); geometry is the fallback.
        manifest_path = os.path.splitext(path)[0] + ".manifest.json"
        if os.path.isfile(manifest_path):
            try:
                with open(manifest_path, "r", encoding="utf-8") as fh:
                    aspect = json.load(fh).get("uv_aspect")
            except (ValueError, OSError):
                aspect = None
    if aspect is None:
        verts = parsed["vertices"]
        spans = []
        for i in range(3):
            vals = [v[i] for v in verts]
            spans.append(max(vals) - min(vals))
        spans.sort(reverse=True)
        aspect = (spans[1] / spans[0]) if spans[0] > 1e-9 else 1.0
    aspect = max(0.05, min(1.0, aspect))
    w, h = size, max(16, round(size * aspect))
    im = Image.new("RGB", (w, h), (0, 0, 0))
    draw = ImageDraw.Draw(im)

    def px(uv):
        return (uv[0] * (w - 1), uv[1] * (h - 1))

    fill = (70, 70, 70) if wire else (128, 128, 128)
    for f in faces:  # fill first, then edges, so shared borders stay visible
        draw.polygon([px(uvs[f[0] - 1]), px(uvs[f[1] - 1]), px(uvs[f[2] - 1])], fill=fill)
    if wire:
        for f in faces:
            pts = [px(uvs[f[0] - 1]), px(uvs[f[1] - 1]), px(uvs[f[2] - 1])]
            draw.line([pts[0], pts[1], pts[2], pts[0]], fill=(255, 255, 255), width=1)
    buf = BytesIO()
    im.save(buf, format="PNG")
    return buf.getvalue()


def list_animations(path: str) -> dict:
    """{animations: [{name, channels, duration_s}], source} — the clip CATALOG of a GLB
    (animation libraries like Quaternius UAL2 pack hundreds of named clips in one file;
    the Pilot Doctrine's animation leg starts by LISTING what the library offers)."""
    gltf, binchunk = _read_glb(path)
    out = []
    for i, anim in enumerate(gltf.get("animations", [])):
        duration = 0.0
        for ch in anim.get("channels", []):
            sampler = anim["samplers"][ch["sampler"]]
            times = _accessor_values(gltf, binchunk, sampler["input"])
            if times:
                duration = max(duration, times[-1][0])
        out.append({
            "name": anim.get("name", f"Animation{i}"),
            "channels": len(anim.get("channels", [])),
            "duration_s": round(duration, 3),
        })
    return {"animations": out, "source": os.path.basename(path)}


def parse_animation(path: str, name: str) -> dict:
    """One named clip -> {name, duration_s, joints: {nodeName: {rotation?: {times, values
    (quat xyzw)}, translation?: {times, values}}}, interpolation}. RAW keyframes (no
    resampling — the retarget/Luau layer owns timing). Scale channels are ignored (Roblox
    joint channels are rigid). Unnamed target nodes fall back to node<index>."""
    gltf, binchunk = _read_glb(path)
    target = None
    for i, anim in enumerate(gltf.get("animations", [])):
        if anim.get("name", f"Animation{i}") == name:
            target = anim
            break
    if target is None:
        available = [a.get("name", f"Animation{i}") for i, a in enumerate(gltf.get("animations", []))]
        raise MeshError(f"no animation named {name!r} (available: {', '.join(available[:20])})")
    nodes = gltf.get("nodes", [])
    joints: dict = {}
    duration = 0.0
    interpolation = "LINEAR"
    for ch in target.get("channels", []):
        tgt = ch.get("target", {})
        path_kind = tgt.get("path")
        if path_kind not in ("rotation", "translation"):
            continue  # scale/weights are not Roblox joint channels
        node_index = tgt.get("node")
        node_name = nodes[node_index].get("name", f"node{node_index}") if node_index is not None else "?"
        sampler = target["samplers"][ch["sampler"]]
        interpolation = sampler.get("interpolation", "LINEAR")
        times = [round(t[0], 5) for t in _accessor_values(gltf, binchunk, sampler["input"])]
        values = [[round(c, 5) for c in v] for v in _accessor_values(gltf, binchunk, sampler["output"])]
        if times:
            duration = max(duration, times[-1])
        joints.setdefault(node_name, {})[path_kind] = {"times": times, "values": values}
    return {
        "name": name,
        "duration_s": round(duration, 3),
        "joints": joints,
        "interpolation": interpolation,
        "source": os.path.basename(path),
    }


def read_reference_mesh(filename: str, textured: bool = False) -> dict:
    """Parse a .glb from assets/reference (allowlisted directory, .glb only). textured=True adds
    per-vertex uvs + a LEAN texture descriptor {present, mime, width, height}; the atlas PIXELS
    ship as raw RGBA via the separate /assets/texture route, never inline in this JSON (a 1536
    atlas is ~9MB of RGBA — it does not belong in the mesh payload)."""
    if not isinstance(filename, str) or "/" in filename or "\\" in filename or ".." in filename:
        raise MeshError("bad filename")
    if not filename.lower().endswith(".glb"):
        raise MeshError("only .glb files are supported")
    path = os.path.join(ASSET_DIR, filename)
    if not os.path.isfile(path):
        raise MeshError(f"no such reference asset: {filename}")
    if not textured:
        return parse_glb(path)
    out = parse_glb_textured(path)
    tex = out.pop("texture", None)  # drop the heavy base64 PNG; describe it instead
    if tex is not None:
        import base64 as _b64

        raw = _b64.b64decode(tex.get("base64", ""))
        width = height = 0
        if raw[:8] == b"\x89PNG\r\n\x1a\n":  # dims from the IHDR without a full decode
            width, height = struct.unpack(">II", raw[16:24])
        out["texture"] = {"present": True, "mime": tex.get("mime"), "width": width, "height": height}
    else:
        out["texture"] = {"present": False}
    return out
