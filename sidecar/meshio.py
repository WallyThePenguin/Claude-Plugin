"""Minimal pure-stdlib GLB (glTF 2.0 binary) mesh reader for the asset-ingestion pipeline.

Real-world reference assets (CC0 libraries like Quaternius) arrive as .glb files; the plugin
cannot read files, so the sidecar parses them and serves {vertices, faces} JSON that Luau turns
into an EditableMesh -> CreateMeshPartAsync (the June breakthrough path, no manual 3D Importer).

Scope (v1, deliberate): POSITION + indices of every mesh primitive, merged; component types
float32 / uint8 / uint16 / uint32; byteStride honored. Node transforms, skinning, normals, UVs,
and materials are NOT applied — this feeds silhouette/proportion study and re-topology reference,
not 1:1 visual reproduction. Faces are 1-indexed for Luau.
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
_TYPE_COUNT = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}


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


def parse_glb(path: str) -> dict:
    """{vertices: [[x,y,z]...], faces: [[a,b,c]...1-indexed], meshes: n, source: name}."""
    gltf, binchunk = _read_glb(path)
    vertices = []
    faces = []
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
            indices = [v[0] for v in _accessor_values(gltf, binchunk, prim["indices"])]
            for t in range(0, len(indices) - 2, 3):
                faces.append(
                    [vbase + indices[t] + 1, vbase + indices[t + 1] + 1, vbase + indices[t + 2] + 1]
                )
    if not vertices:
        raise MeshError("no triangle mesh primitives found")
    return {
        "vertices": vertices,
        "faces": faces,
        "meshes": mesh_count,
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
