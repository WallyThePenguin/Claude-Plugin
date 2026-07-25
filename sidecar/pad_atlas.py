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
    # Rasterize UV triangles (exact mask). Lazy import; only needed for --mask-from-uv.
    from pygltflib import GLTF2  # noqa: F401  (meshio-side helpers could replace this)
    raise SystemExit("--mask-from-uv not implemented yet; use the luminance mask")


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
    for i, a in enumerate(sys.argv):
        if a == "--threshold":
            threshold = int(sys.argv[i + 1])
        if a == "--mask-from-uv":
            raise SystemExit("--mask-from-uv not implemented yet; use the luminance mask")
    src = args[0]
    dst = args[1] if len(args) > 1 else src
    im = Image.open(src).convert("RGB")
    rgb = np.asarray(im)
    mask = island_mask_luminance(rgb, threshold)
    if mask.mean() < 0.02:
        raise SystemExit(f"PAD_ATLAS_FAIL island mask covers {mask.mean():.1%} — wrong threshold?")
    out, changed = pad(rgb, mask)
    Image.fromarray(out.astype(np.uint8)).save(dst, quality=95)
    print(f"islands {mask.mean():.1%} of canvas; flooded {changed} bg px")
    print(f"PAD_ATLAS_OK {changed}")


if __name__ == "__main__":
    main()
