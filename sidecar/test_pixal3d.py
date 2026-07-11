"""Dependency-free tests for the Pixal3D ComfyUI driver. Run: python sidecar/test_pixal3d.py
No ComfyUI is spawned — HTTP + staging seams are stubbed."""
import json
import os
import sys
import tempfile

import pixal3d


def _check(name, cond):
    print(("  PASS  " if cond else "  FAIL  ") + name)
    return 0 if cond else 1


def main():
    fails = 0

    wf = pixal3d.build_workflow("sword.png", seed=7, pipeline_type="512")
    fails += _check("workflow selects the Pixal3D-GGUF model",
                    wf["1"]["inputs"]["modelname"] == "Pixal3D-GGUF")
    fails += _check("workflow backend is sdpa (Turing-safe; no flash_attn/xformers installed)",
                    wf["1"]["inputs"]["backend"] == "sdpa")
    fails += _check("image name lands in the load node", wf["2"]["inputs"]["image"] == "sword.png")
    fails += _check("rembg preprocessing is ON", wf["3"]["inputs"]["remove_background"] is True)
    fails += _check("seed threads through", wf["4"]["inputs"]["seed"] == 7)
    fails += _check("shape-only by default (texturing = the TRELLIS.2 leg)",
                    wf["4"]["inputs"]["generate_texture_slat"] is False)
    fails += _check("export emits glb", wf["6"]["inputs"]["file_format"] == "glb")
    fails += _check("graph wires 1->4, 3->4, 4->5, 5->6",
                    wf["4"]["inputs"]["pipeline"] == ["1", 0]
                    and wf["4"]["inputs"]["image"] == ["3", 0]
                    and wf["5"]["inputs"]["mesh"] == ["4", 0]
                    and wf["6"]["inputs"]["trimesh"] == ["5", 0])
    fails += _check("graph is JSON-serializable", bool(json.dumps(wf)))

    r = pixal3d.generate(os.path.join(tempfile.gettempdir(), "no-such-img.png"), "out.glb")
    fails += _check("missing input refuses early", r["ok"] is False and "not found" in r["error"])

    real_ensure = pixal3d.ensure_server
    pixal3d.ensure_server = lambda boot_timeout_s=90: (False, "comfyui install incomplete (stub)")
    try:
        with tempfile.TemporaryDirectory() as d:
            img = os.path.join(d, "in.png")
            with open(img, "wb") as f:
                f.write(b"\x89PNGfake")
            # staging writes into COMFY_DIR/input which may not exist in test envs — ensure_server
            # refuses first, so generate must return its note without touching the filesystem
            r = pixal3d.generate(img, os.path.join(d, "out.glb"))
            fails += _check("server-unavailable note surfaces", r["ok"] is False and "incomplete" in r["error"])
    finally:
        pixal3d.ensure_server = real_ensure

    print(("test_pixal3d: ALL GREEN" if fails == 0 else f"test_pixal3d: {fails} FAILURES"))
    return fails


if __name__ == "__main__":
    sys.exit(main())
