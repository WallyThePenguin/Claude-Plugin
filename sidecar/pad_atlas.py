# pad_atlas.py — UV edge-padding for PAINTED atlases (the conveyor's post-paint bleed pass).
#
# WHY: rig_weapon's AO bake carries margin=8 island bleed, but paint_atlas REPAINTS the
# background black (with a dark object outline), destroying that bleed. Grazing-projection
# texels (surfaces nearly parallel to the planar projector — cup flanks, quillon bars) live
# within a few texels of the island border, so on-mesh they sample the black background:
# gold guards render with black flanks (DivineRapier, live-caught 2026-07-25). Classic fix =
# flood every background texel with the color of its NEAREST island texel (infinite padding);
# only texels within the sampler's bleed distance are ever read, the rest are inert.
#
# Island mask = luminance threshold (painted islands are bright material on near-black bg).
# For atlases whose CONTENT is legitimately near-black, pass --mask-from-uv <glb> instead
# (rasterizes the true island mask from the mesh UVs — slower, exact).
#
# Usage: python pad_atlas.py <in-atlas> [out-atlas] [--threshold 60] [--mask-from-uv mesh.glb]
# In-place when out-atlas is omitted. Prints PAD_ATLAS_OK <changed-px> on success.
import sys
import numpy as np
from PIL import Image
from scipy import ndimage


def island_mask_luminance(rgb: np.ndarray, threshold: int) -> np.ndarray:
    return rgb.astype(np.int32).sum(axis=2) > threshold * 3


def island_mask_from_uv(glb_path: str, w: int, h: int) -> np.ndarray:
    """Exact island mask: rasterize the mesh's UV triangles (meshio convention — glTF top-down
    V, NO flip, so v maps straight to the row index). Needed when painted CONTENT is
    legitimately dark (dark guards/grips) and the luminance threshold would flood it."""
    import meshio

    data = meshio.parse_glb_textured(glb_path)
    uvs = np.asarray(data.get("uvs") or [], dtype=np.float64)
    faces = np.asarray(data.get("faces") or [], dtype=np.int64)
    if uvs.size == 0 or faces.size == 0:
        raise SystemExit("PAD_ATLAS_FAIL glb has no UVs/faces for --mask-from-uv")
    if faces.min() >= 1:  # meshio emits 1-based faces (the Luau import contract)
        faces = faces - 1
    mask = np.zeros((h, w), dtype=bool)
    tris = uvs[faces] * np.array([w, h], dtype=np.float64)  # (T,3,2) pixel space
    for t in tris:
        x0 = max(int(np.floor(t[:, 0].min())) - 1, 0)
        x1 = min(int(np.ceil(t[:, 0].max())) + 1, w - 1)
        y0 = max(int(np.floor(t[:, 1].min())) - 1, 0)
        y1 = min(int(np.ceil(t[:, 1].max())) + 1, h - 1)
        if x1 < x0 or y1 < y0:
            continue
        xs = np.arange(x0, x1 + 1, dtype=np.float64) + 0.5
        ys = np.arange(y0, y1 + 1, dtype=np.float64) + 0.5
        gx, gy = np.meshgrid(xs, ys)

        def edge(ax, ay, bx, by):
            return (gx - ax) * (by - ay) - (gy - ay) * (bx - ax)

        e0 = edge(t[0, 0], t[0, 1], t[1, 0], t[1, 1])
        e1 = edge(t[1, 0], t[1, 1], t[2, 0], t[2, 1])
        e2 = edge(t[2, 0], t[2, 1], t[0, 0], t[0, 1])
        inside = ((e0 >= 0) & (e1 >= 0) & (e2 >= 0)) | ((e0 <= 0) & (e1 <= 0) & (e2 <= 0))
        mask[y0:y1 + 1, x0:x1 + 1] |= inside
    return ndimage.binary_dilation(mask, iterations=1)


def pad(rgb: np.ndarray, mask: np.ndarray) -> tuple[np.ndarray, int]:
    """Replace every non-island pixel with its nearest island pixel's color."""
    if mask.all():
        return rgb, 0
    # EDT over the background; indices point at the nearest island texel.
    _, (iy, ix) = ndimage.distance_transform_edt(~mask, return_indices=True)
    out = rgb[iy, ix]
    out[mask] = rgb[mask]
    return out, int((~mask).sum())


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        raise SystemExit(__doc__ or "usage: pad_atlas.py <in> [out]")
    threshold = 60
    mask_glb = None
    skip = set()
    for i, a in enumerate(sys.argv):
        if a == "--threshold":
            threshold = int(sys.argv[i + 1])
            skip.add(sys.argv[i + 1])
        if a == "--mask-from-uv":
            mask_glb = sys.argv[i + 1]
            skip.add(mask_glb)
    args = [a for a in args if a not in skip]
    src = args[0]
    dst = args[1] if len(args) > 1 else src
    im = Image.open(src).convert("RGB")
    rgb = np.asarray(im)
    if mask_glb:
        mask = island_mask_from_uv(mask_glb, rgb.shape[1], rgb.shape[0])
    else:
        mask = island_mask_luminance(rgb, threshold)
    if mask.mean() < 0.02:
        raise SystemExit(f"PAD_ATLAS_FAIL island mask covers {mask.mean():.1%} — wrong threshold?")
    out, changed = pad(rgb, mask)
    Image.fromarray(out.astype(np.uint8)).save(dst, quality=95)
    print(f"islands {mask.mean():.1%} of canvas; flooded {changed} bg px")
    print(f"PAD_ATLAS_OK {changed}")


if __name__ == "__main__":
    main()
