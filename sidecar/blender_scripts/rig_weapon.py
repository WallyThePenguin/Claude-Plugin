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
ap.add_argument("--uv", default="none", choices=["none", "smart", "planar"],
                help="Clean unwrap after cleanup (the decoupled-texture architecture: shape from "
                     "TRELLIS, UVs authored once here, texture painted on these islands "
                     "downstream). smart = Smart UV Project — MEASURED UNPAINTABLE on voxel-shell "
                     "weapon meshes (thousands of micro-islands, 1.5%% canvas coverage). planar = "
                     "deterministic projection onto the two-largest-extents plane: ONE "
                     "silhouette-shaped island, front/back sharing texels (the hand-painter "
                     "mirror trick) — the painter-friendly default for blade-like assets. Both "
                     "also heal the voxel-remesh path, which destroys source UVs.")
ap.add_argument("--uv-angle", dest="uv_angle", type=float, default=66.0,
                help="smart-project angle limit in DEGREES; higher merges more faces per island "
                     "(fewer, larger islands paint better)")
ap.add_argument("--uv-margin", dest="uv_margin", type=float, default=0.02,
                help="island margin (UV space) — the gutter that absorbs painter bleed")
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

# decimate to budget (preserving UVs where possible). ITERATE: a single collapse pass can
# bottom out above the requested ratio on messy topology (measured: 56,962 tris -> 20,577 for
# BOTH 19,500 and 18,000 budgets — and 20,577 tris corner-split past EditableMesh's 60k-vert
# cap). Repeat passes until under budget or the count stops moving.
def decimate_to(budget):
    count = len(obj.data.polygons)
    attempts = 0
    while count > budget and attempts < 5:
        mod = obj.modifiers.new("decim", "DECIMATE")
        mod.ratio = budget / count
        mod.use_collapse_triangulate = True
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.modifier_apply(modifier=mod.name)
        new_count = len(obj.data.polygons)
        if new_count >= count:
            break  # no progress — topology floor
        count = new_count
        attempts += 1
    return count


tri_count = decimate_to(args.tri_budget)
if tri_count > args.tri_budget:
    # Collapse floored out (measured: voxel-reconstruction shell soup stuck at ~20.5k for any
    # budget). VOXEL REMESH rebuilds clean manifold topology — the retopo step — then the
    # collapse can actually reach the budget. UVs are lost; acceptable: this path feeds the
    # untextured EditableMesh import (texture streaming is a separate leg).
    rm = obj.modifiers.new("remesh", "REMESH")
    rm.mode = "VOXEL"
    rm.voxel_size = max(obj.dimensions) / 200.0
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=rm.name)
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    bm.to_mesh(obj.data)
    bm.free()
    print(f"remesh escalation: {len(obj.data.polygons)} tris after voxel remesh")
    tri_count = decimate_to(args.tri_budget)

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

uv_stats = {}
if args.uv == "smart":
    # Clean unwrap AFTER all geometry surgery (decimate/remesh/scale) so the islands map the
    # final topology. Smart UV Project is deterministic and headless-safe; angle limit is
    # radians in 4.x.
    import math as _math

    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    while obj.data.uv_layers:  # drop stale source UVs — this unwrap becomes THE layout
        obj.data.uv_layers.remove(obj.data.uv_layers[0])
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(
        angle_limit=_math.radians(args.uv_angle),
        island_margin=args.uv_margin,
        correct_aspect=True,
        scale_to_bounds=False,
    )
    bpy.ops.object.mode_set(mode="OBJECT")
    uv_stats = {"uv": "smart", "uv_angle_deg": args.uv_angle, "uv_margin": args.uv_margin,
                "uv_layers": len(obj.data.uv_layers)}
    print(f"smart uv: angle={args.uv_angle}deg margin={args.uv_margin} layers={len(obj.data.uv_layers)}")
elif args.uv == "planar":
    # Deterministic planar projection: UV = the vertex position on the two-largest-extents
    # plane, normalized to [margin, 1-margin]. One island, silhouette-shaped, front/back
    # overlapped — no operators, no context, fully headless-safe.
    while obj.data.uv_layers:
        obj.data.uv_layers.remove(obj.data.uv_layers[0])
    mesh = obj.data
    dims = obj.dimensions
    order = sorted(range(3), key=lambda i: -dims[i])
    ax_u, ax_v = order[0], order[1]
    lo_u = min(v.co[ax_u] for v in mesh.vertices)
    hi_u = max(v.co[ax_u] for v in mesh.vertices)
    lo_v = min(v.co[ax_v] for v in mesh.vertices)
    hi_v = max(v.co[ax_v] for v in mesh.vertices)
    span_u = max(hi_u - lo_u, 1e-9)
    span_v = max(hi_v - lo_v, 1e-9)
    m = max(0.0, min(0.2, args.uv_margin))
    usable = 1.0 - 2.0 * m
    layer = mesh.uv_layers.new(name="UVMap")
    for loop in mesh.loops:
        co = mesh.vertices[loop.vertex_index].co
        u = (co[ax_u] - lo_u) / span_u
        w = (co[ax_v] - lo_v) / span_v
        layer.data[loop.index].uv = (m + u * usable, m + w * usable)
    uv_stats = {"uv": "planar", "uv_axes": "XYZ"[ax_u] + "XYZ"[ax_v], "uv_margin": m,
                "uv_layers": len(mesh.uv_layers)}
    print(f"planar uv: axes={uv_stats['uv_axes']} margin={m} layers={len(mesh.uv_layers)}")

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
    **uv_stats,
}
with open(os.path.splitext(args.out_glb)[0] + ".manifest.json", "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=1)
print("manifest:", json.dumps(manifest))
print("RIG_WEAPON_OK")
