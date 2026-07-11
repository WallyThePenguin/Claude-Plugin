"""Blender-headless asset prep for the Roblox pipeline (Stage 3). Run via blenderbridge.

Modes (--mode):
  cleanup  (implemented) — the Lane A pass: import GLB -> bmesh repair (merge-by-distance,
           degenerate dissolve) -> decimate to --tri-budget -> scale so the longest extent is
           --target-studs -> export GLB + a manifest JSON. AI meshes are dense/non-manifold
           (systemic finding); this pass makes them EditableMesh-ingestible (60k-vert cap) and
           Roblox-budget-shaped (20k tris/MeshPart).
  rigid / skinned — the Lane B armature passes; NOT implemented yet (weapons articulate via the
           plugin's own Motor6D chain system; the armature leg starts with Lane B).

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
args = ap.parse_args(argv)

if args.mode != "cleanup":
    raise SystemExit(f"mode '{args.mode}' is not implemented yet (Lane B)")

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
}
with open(os.path.splitext(args.out_glb)[0] + ".manifest.json", "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=1)
print("manifest:", json.dumps(manifest))
print("RIG_WEAPON_OK")
