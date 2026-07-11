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


def read_reference_mesh(filename: str) -> dict:
    """Parse a .glb from assets/reference (allowlisted directory, .glb only)."""
    if not isinstance(filename, str) or "/" in filename or "\\" in filename or ".." in filename:
        raise MeshError("bad filename")
    if not filename.lower().endswith(".glb"):
        raise MeshError("only .glb files are supported")
    path = os.path.join(ASSET_DIR, filename)
    if not os.path.isfile(path):
        raise MeshError(f"no such reference asset: {filename}")
    return parse_glb(path)
