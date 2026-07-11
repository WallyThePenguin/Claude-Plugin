"""Blender-headless asset prep for the Roblox pipeline (Stage 3). Run via blenderbridge.

Modes (--mode):
  cleanup — the Lane A pass: import GLB -> bmesh repair (merge-by-distance, degenerate
           dissolve) -> decimate to --tri-budget -> scale so the longest extent is
           --target-studs -> export GLB + a manifest JSON. AI meshes are dense/non-manifold
           (systemic finding); this pass makes them EditableMesh-ingestible (60k-vert cap) and
           Roblox-budget-shaped (20k tris/MeshPart).
  rigid  — cleanup PLUS a deterministic weapon armature: the mesh is banded along its LONG
           axis into --segments bones (Grip at the detected grip end, then Seg1..SegN toward
           the tip), every vertex weighted 1.0 to exactly one bone (vertex groups named like
           the bones; bone-heat is BANNED for weapons — deterministic weights guarantee no
           zero-influence bones, which the Roblox importer silently drops). Grip end =
           the end band with the smaller mean cross-section (a handle is thinner than a
           blade); override with --grip-end min|max. Exports GLB WITH the skin; the manifest
           carries the bone list so downstream (meshio -> EditableMesh AddBone) can verify.
  skinned — organics (bone-heat / UniRig track); NOT implemented yet.

Success marker: prints RIG_WEAPON_OK as the last line (blenderbridge requires it — Blender can
exit 0 despite script errors in some paths).
"""

import argparse
import json
import os
import sys

import bpy
import bmesh
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
ap = argparse.ArgumentParser()
ap.add_argument("--in", dest="in_glb", required=True)
ap.add_argument("--out", dest="out_glb", required=True)
ap.add_argument("--mode", default="cleanup", choices=["cleanup", "rigid", "skinned"])
ap.add_argument("--target-studs", dest="target_studs", type=float, default=4.5)
ap.add_argument("--tri-budget", dest="tri_budget", type=int, default=19500)
ap.add_argument("--segments", type=int, default=4, help="rigid mode: bone count (Grip + N-1 blade segments)")
ap.add_argument("--grip-end", dest="grip_end", default="auto", choices=["auto", "min", "max"])
args = ap.parse_args(argv)

if args.mode == "skinned":
    raise SystemExit("mode 'skinned' is not implemented yet (organics track)")

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=args.in_glb)

meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
if not meshes:
    raise SystemExit("no meshes in GLB")

# join into one object (single MeshPart target)
bpy.ops.object.select_all(action="DESELECT")
for o in meshes:
    o.select_set(True)
bpy.context.view_layer.objects.active = meshes[0]
if len(meshes) > 1:
    bpy.ops.object.join()
obj = bpy.context.view_layer.objects.active
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

# bmesh repair: merge-by-distance + degenerate dissolve (the anti-bone-heat pre-pass too)
bm = bmesh.new()
bm.from_mesh(obj.data)
before_v, before_f = len(bm.verts), len(bm.faces)
bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-4)
bmesh.ops.dissolve_degenerate(bm, edges=bm.edges[:], dist=1e-5)
bmesh.ops.triangulate(bm, faces=bm.faces[:])
bm.to_mesh(obj.data)
bm.free()

# decimate to budget (preserving UVs where possible)
tri_count = len(obj.data.polygons)
if tri_count > args.tri_budget:
    mod = obj.modifiers.new("decim", "DECIMATE")
    mod.ratio = args.tri_budget / tri_count
    mod.use_collapse_triangulate = True
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=mod.name)

# scale: longest extent -> target studs (EditableMesh coords stream as raw studs)
dims = obj.dimensions
longest = max(dims.x, dims.y, dims.z)
if longest > 1e-6:
    f = args.target_studs / longest
    obj.scale = (f, f, f)
    bpy.ops.object.transform_apply(scale=True)

# recenter on origin (grip math prefers a centered handle-space)
mins = Vector((1e9, 1e9, 1e9))
maxs = Vector((-1e9, -1e9, -1e9))
for v in obj.data.vertices:
    w = obj.matrix_world @ v.co
    mins = Vector((min(mins[i], w[i]) for i in range(3)))
    maxs = Vector((max(maxs[i], w[i]) for i in range(3)))
center = (mins + maxs) / 2
obj.location = obj.location - center
bpy.ops.object.transform_apply(location=True)

bones_manifest = []
if args.mode == "rigid":
    # ---- deterministic weapon armature ----
    dims = obj.dimensions
    axis = max(range(3), key=lambda i: dims[i])  # the LONG axis index
    lo = min(v.co[axis] for v in obj.data.vertices)
    hi = max(v.co[axis] for v in obj.data.vertices)
    span = hi - lo
    if span < 1e-6:
        raise SystemExit("degenerate mesh: no extent along the long axis")
    n = max(2, args.segments)
    # grip-end detection: mean cross-section magnitude of the two end bands — a handle is
    # thinner than a blade. Cross = the two non-long axes.
    others = [i for i in range(3) if i != axis]

    def band_cross(frac_lo, frac_hi):
        vals = [
            abs(v.co[others[0]]) + abs(v.co[others[1]])
            for v in obj.data.vertices
            if frac_lo <= (v.co[axis] - lo) / span <= frac_hi
        ]
        return (sum(vals) / len(vals)) if vals else 0.0

    if args.grip_end == "auto":
        grip_at_min = band_cross(0.0, 0.2) <= band_cross(0.8, 1.0)
    else:
        grip_at_min = args.grip_end == "min"

    def frac_of(v):  # 0 at the GRIP end, 1 at the tip
        f = (v.co[axis] - lo) / span
        return f if grip_at_min else 1.0 - f

    bone_names = ["Grip"] + [f"Seg{i}" for i in range(1, n)]
    # armature: bones chained along the long axis at equal band boundaries
    arm_data = bpy.data.armatures.new("WeaponArmature")
    arm_obj = bpy.data.objects.new("WeaponArmature", arm_data)
    bpy.context.collection.objects.link(arm_obj)
    bpy.context.view_layer.objects.active = arm_obj
    bpy.ops.object.mode_set(mode="EDIT")

    def axis_point(frac):
        p = [0.0, 0.0, 0.0]
        p[axis] = (lo + frac * span) if grip_at_min else (hi - frac * span)
        return Vector(p)

    prev_bone = None
    for i, name in enumerate(bone_names):
        eb = arm_data.edit_bones.new(name)
        eb.head = axis_point(i / n)
        eb.tail = axis_point((i + 1) / n)
        if prev_bone is not None:
            eb.parent = prev_bone
            eb.use_connect = True
        prev_bone = eb
    bpy.ops.object.mode_set(mode="OBJECT")
    # deterministic 1.0 weights: every vertex -> exactly its band's bone
    groups = {name: obj.vertex_groups.new(name=name) for name in bone_names}
    band_counts = {name: 0 for name in bone_names}
    for v in obj.data.vertices:
        b = min(n - 1, int(frac_of(v) * n))
        name = bone_names[b]
        groups[name].add([v.index], 1.0, "REPLACE")
        band_counts[name] += 1
    if any(c == 0 for c in band_counts.values()):
        raise SystemExit(f"empty bone band(s): {band_counts} — the Roblox importer would drop them")
    mod = obj.modifiers.new("Armature", "ARMATURE")
    mod.object = arm_obj
    obj.parent = arm_obj
    for i, name in enumerate(bone_names):
        h = axis_point(i / n)
        bones_manifest.append({"name": name, "parent": bone_names[i - 1] if i > 0 else None,
                               "head_studs": [round(c, 3) for c in h]})
    print(f"rigid rig: axis={'XYZ'[axis]} grip_at_{'min' if grip_at_min else 'max'} bands={band_counts}")

out_dir = os.path.dirname(os.path.abspath(args.out_glb))
os.makedirs(out_dir, exist_ok=True)
bpy.ops.export_scene.gltf(filepath=args.out_glb, export_format="GLB")

final_tris = len(obj.data.polygons)
final_verts = len(obj.data.vertices)
manifest = {
    "mode": args.mode,
    "source": os.path.basename(args.in_glb),
    "verts_in": before_v,
    "tris_in": before_f,
    "verts": final_verts,
    "tris": final_tris,
    "extents_studs": [round(d, 3) for d in obj.dimensions],
    "target_studs": args.target_studs,
    "bones": bones_manifest,
}
with open(os.path.splitext(args.out_glb)[0] + ".manifest.json", "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=1)
print("manifest:", json.dumps(manifest))
print("RIG_WEAPON_OK")
