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
ap.add_argument("--uv-sides", dest="uv_sides", type=int, default=2, choices=[1, 2],
                help="planar unwrap islands: 2 (default) = front/back faces get their OWN "
                     "stacked bands (no texel sharing — overlapped UVs speckle AO bakes with "
                     "double-writes and mirror-smear complex geometry); 1 = the old "
                     "mirror-texel single island")
ap.add_argument("--smooth", type=int, default=0,
                help="TAUBIN smoothing iterations (+0.5/-0.53 pairs) after decimate — melts the "
                     "voxel-reconstruction bumps ('rocky' surfaces) with ~zero shrink. 0 = off. "
                     "(Plain Laplacian is BANNED here: its shrink pulled the non-watertight "
                     "shell's pinholes visibly open and thinned ornament.)")
ap.add_argument("--bake-ao", dest="bake_ao", default="",
                help="PNG path: bake the mesh's OWN ambient occlusion into UV space (Cycles CPU) "
                     "at the canvas aspect — the relief map the texture PAINTER molds paint to "
                     "(theme from the reference, layout from the mesh). Requires --uv.")
ap.add_argument("--canon", default="long-y", choices=["none", "long-y"],
                help="long-y (default) = PCA-rotate so the principal (long) axis lands on ROBLOX "
                     "vertical (+Y in the exported glTF). In Blender coords that is +Z — the glTF "
                     "exporter's +Y-up conversion maps Blender Z->glTF Y (and Blender Y->glTF -Z; "
                     "live-caught: a Blender-Y-long sword imported lying flat). Second axis -> "
                     "Blender X, thinnest -> Blender Y. Every downstream stage (planar UVs, grip "
                     "detection, extents gate) sees one canonical frame")
args = ap.parse_args(argv)

if args.mode == "skinned":
    raise SystemExit("mode 'skinned' is not implemented yet (organics track)")

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=args.in_glb)


def mesh_extents(o):
    """Per-axis extents straight from the vertices. obj.dimensions is STALE right after
    obj.data.transform in background mode (live-caught: the scale step read pre-rotation dims
    and overshot target-studs by 38%) — never trust it between edits."""
    vs = o.data.vertices
    if not vs:
        return (0.0, 0.0, 0.0)
    lo = [min(v.co[i] for v in vs) for i in range(3)]
    hi = [max(v.co[i] for v in vs) for i in range(3)]
    return tuple(hi[i] - lo[i] for i in range(3))

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

# bmesh repair: merge-by-distance + degenerate dissolve (the anti-bone-heat pre-pass too) +
# HOLE FILL (TRELLIS meshes are documented non-watertight — pinholes that stay sub-pixel on the
# raw mesh get pulled WIDE OPEN by any smoothing; user-caught as visible holes) + RECALC FACE
# NORMALS: voxel-reconstruction meshes ship MIXED WINDING (the reason generated blades rendered
# see-through from behind and needed DoubleSided=true) — inward-pointing faces also sample AO
# from INSIDE the shell, shredding relief bakes into shard noise (measured).


def fill_holes(bm_):
    """Close small boundary loops. Returns the boundary-edge count BEFORE filling (the hole
    metric the manifest reports). holes_fill can emit ngons — callers re-triangulate."""
    boundary = [e for e in bm_.edges if e.is_boundary]
    if boundary:
        bmesh.ops.holes_fill(bm_, edges=boundary, sides=64)
    return len(boundary)


bm = bmesh.new()
bm.from_mesh(obj.data)
before_v, before_f = len(bm.verts), len(bm.faces)
bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-4)
bmesh.ops.dissolve_degenerate(bm, edges=bm.edges[:], dist=1e-5)
boundary_in = fill_holes(bm)
bmesh.ops.triangulate(bm, faces=bm.faces[:])
bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
bm.to_mesh(obj.data)
bm.free()
if boundary_in:
    print(f"hole fill (repair): {boundary_in} boundary edges closed")

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
    rm.voxel_size = max(mesh_extents(obj)) / 200.0
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=rm.name)
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    bm.to_mesh(obj.data)
    bm.free()
    print(f"remesh escalation: {len(obj.data.polygons)} tris after voxel remesh")
    tri_count = decimate_to(args.tri_budget)

# geometric smoothing: melt voxel-reconstruction bumps on the FINAL topology (after decimate /
# remesh). TAUBIN (alternating +0.5 / -0.53), NOT plain Laplacian — Laplacian SHRINKS, and the
# shrink is what pulled the non-watertight shell's pinholes visibly open and thinned ornament
# (user-caught holes on both swords). Taubin smooths the noise band with ~zero volume loss.
# Post-smooth: dissolve slivers, re-fill any boundary the motion opened, re-triangulate,
# recalc normals — smoothing must never be the last word on topology.
boundary_smooth = 0
if args.smooth > 0:
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    for _ in range(args.smooth):
        bmesh.ops.smooth_vert(bm, verts=bm.verts[:], factor=0.5,
                              use_axis_x=True, use_axis_y=True, use_axis_z=True)
        bmesh.ops.smooth_vert(bm, verts=bm.verts[:], factor=-0.53,
                              use_axis_x=True, use_axis_y=True, use_axis_z=True)
    bmesh.ops.dissolve_degenerate(bm, edges=bm.edges[:], dist=1e-5)
    boundary_smooth = fill_holes(bm)
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bm.to_mesh(obj.data)
    bm.free()
    print(f"smooth: {args.smooth} Taubin iterations (+0.5/-0.53); "
          f"{boundary_smooth} boundary edges re-closed after")

# SMOOTH SHADING, always: without it the glTF exports faceted normals and the corner-split
# EditableMesh import renders every voxel facet with its own highlight (the "rocky" look —
# user-caught). Shared smooth normals ride TEXCOORD-style into the NORMAL attribute.
for poly in obj.data.polygons:
    poly.use_smooth = True

# orientation canonicalization: PCA-rotate so principal axis -> +Y, second -> +Z, thinnest -> +X.
# Runs BEFORE scale/recenter so extents, grip detection, and the planar unwrap all live in the
# canonical frame. Sign ambiguity (a PCA axis is a line, not a ray) is left to downstream
# grip-end detection — a 180-degree flip changes nothing it can't handle.
if args.canon == "long-y":
    import numpy as np
    from mathutils import Matrix

    pts = np.array([v.co[:] for v in obj.data.vertices])
    pts -= pts.mean(axis=0)
    evals, evecs = np.linalg.eigh(pts.T @ pts)  # ascending eigenvalues
    # basis columns (BLENDER frame): X <- middle spread, Y <- smallest, Z <- largest (long).
    # Blender +Z is what the glTF +Y-up export turns into Roblox vertical.
    basis = np.column_stack([evecs[:, 1], evecs[:, 0], evecs[:, 2]])
    if np.linalg.det(basis) < 0:
        basis[:, 0] = -basis[:, 0]  # keep it a proper rotation
    rot = basis.T  # new_co = basis^T @ co
    mat = Matrix([[rot[0][0], rot[0][1], rot[0][2], 0.0],
                  [rot[1][0], rot[1][1], rot[1][2], 0.0],
                  [rot[2][0], rot[2][1], rot[2][2], 0.0],
                  [0.0, 0.0, 0.0, 1.0]])
    obj.data.transform(mat)
    obj.data.update()
    print(f"canon long-y: dims now {tuple(round(d, 3) for d in mesh_extents(obj))}")

# scale: longest extent -> target studs (EditableMesh coords stream as raw studs)
dims = mesh_extents(obj)
longest = max(dims)
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
    dims = mesh_extents(obj)
    order = sorted(range(3), key=lambda i: -dims[i])
    ax_u, ax_v = order[0], order[1]
    lo_u = min(v.co[ax_u] for v in mesh.vertices)
    hi_u = max(v.co[ax_u] for v in mesh.vertices)
    lo_v = min(v.co[ax_v] for v in mesh.vertices)
    hi_v = max(v.co[ax_v] for v in mesh.vertices)
    span_u = max(hi_u - lo_u, 1e-9)
    span_v = max(hi_v - lo_v, 1e-9)
    ax_w = order[2]  # the thin axis — face-normal sign along it decides front vs back
    m = max(0.0, min(0.2, args.uv_margin))
    usable_u = 1.0 - 2.0 * m
    # FULL-BOX per-axis normalization: the CANVAS carries the aspect, not the UVs — the
    # template/atlas is rendered at the layout's aspect (uv_aspect in the manifest; meshio
    # reads it), so texels stay square, the silhouette is undistorted, and the whole canvas is
    # detail budget. TWO-SIDED (default): front/back faces get their own stacked horizontal
    # bands — overlapped mirror-texels DOUBLE-WRITE AO bakes into shard noise (measured) and
    # mirror-smear complex geometry like guards.
    sides = args.uv_sides
    if sides == 2:
        band = (1.0 - 3.0 * m) / 2.0  # two bands + three gutters (top, middle, bottom)
        canvas_aspect = 2.0 * span_v / span_u
    else:
        band = 1.0 - 2.0 * m
        canvas_aspect = span_v / span_u

    def v_of(nv, side):
        return (m + nv * band) if side == 0 else (2.0 * m + band + nv * band)

    layer = mesh.uv_layers.new(name="UVMap")
    for poly in mesh.polygons:
        side = 0 if (sides == 1 or poly.normal[ax_w] >= 0.0) else 1
        for li in poly.loop_indices:
            co = mesh.vertices[mesh.loops[li].vertex_index].co
            u = m + (co[ax_u] - lo_u) / span_u * usable_u
            nv = (co[ax_v] - lo_v) / span_v
            layer.data[li].uv = (u, v_of(nv, side))
    uv_stats = {"uv": "planar", "uv_axes": "XYZ"[ax_u] + "XYZ"[ax_v], "uv_margin": m,
                "uv_sides": sides, "uv_aspect": round(canvas_aspect, 4),
                "uv_layers": len(mesh.uv_layers)}
    print(f"planar uv: axes={uv_stats['uv_axes']} sides={sides} margin={m} "
          f"canvas-aspect={uv_stats['uv_aspect']}")

bones_manifest = []
if args.mode == "rigid":
    # ---- deterministic weapon armature ----
    dims = mesh_extents(obj)
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

ao_stats = {}
if args.bake_ao:
    # The mesh's own relief, laid out in UV space — what the painter molds materials to
    # (user-caught: silhouette paints are "an image stuck on a bunch of bumps"). Cycles AO is
    # purely geometric (no lights needed); margin=8 doubles as the island bleed. The bake
    # material is REMOVED before export so the GLB stays clean (an embedded AO would masquerade
    # as the base-color atlas to parse_glb_textured).
    if not obj.data.uv_layers:
        raise SystemExit("--bake-ao requires a UV layer (pass --uv planar)")
    if "uv_aspect" in uv_stats:  # the unwrap's own canvas aspect (two-band != geometric)
        aspect = uv_stats["uv_aspect"]
    else:
        spans = sorted(mesh_extents(obj), reverse=True)
        aspect = (spans[1] / spans[0]) if spans[0] > 1e-9 else 1.0
    bw = 1024
    bh = max(16, round(bw * max(0.05, min(1.0, aspect))))
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = 24
    img = bpy.data.images.new("SA_AO", width=bw, height=bh, alpha=False)
    mat = bpy.data.materials.new("SA_BakeMat")
    mat.use_nodes = True
    tex_node = mat.node_tree.nodes.new("ShaderNodeTexImage")
    tex_node.image = img
    mat.node_tree.nodes.active = tex_node
    obj.data.materials.clear()
    obj.data.materials.append(mat)
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.bake(type="AO", margin=8)
    os.makedirs(os.path.dirname(os.path.abspath(args.bake_ao)), exist_ok=True)
    img.filepath_raw = args.bake_ao
    img.file_format = "PNG"
    img.save()
    obj.data.materials.clear()
    ao_stats = {"ao": os.path.basename(args.bake_ao), "ao_size": [bw, bh]}
    print(f"ao bake: {bw}x{bh} -> {args.bake_ao}")

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
    "extents_studs": [round(d, 3) for d in mesh_extents(obj)],
    "target_studs": args.target_studs,
    "smooth": args.smooth,
    "holes_closed_repair": boundary_in,
    "holes_closed_post_smooth": boundary_smooth,
    "bones": bones_manifest,
    **uv_stats,
    **ao_stats,
}
with open(os.path.splitext(args.out_glb)[0] + ".manifest.json", "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=1)
print("manifest:", json.dumps(manifest))
print("RIG_WEAPON_OK")
