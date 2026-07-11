"""Pixal3D (GGUF) image->3D via headless ComfyUI — the SHAPE engine (user pivot 2026-07-11).

Pixal3D (TencentARC, SIGGRAPH 2026, MIT) is TRELLIS.2's pixel-aligned successor: near-
reconstruction front-view fidelity. Officially 16-24GB on RTX 30+; the COMMUNITY GGUF route
(Aero-Ex/ComfyUI-Trellis2-GGUF custom nodes, first-class "Pixal3D-GGUF" model option, weights
auto-downloaded from HF Aero-Ex/Pixal3D-GGUF) runs Q4_K_M on ~6GB, RTX 20-series+
(practitioner-verified). Texturing is Pixal3D's weak leg — the recommended combo is Pixal3D
SHAPE + TRELLIS.2 texturing (sidecar/trellis.py stays for that + as fallback).

Stack facts (measured/installed on this machine):
- C:\\tools\\ComfyUI + py311 venv, torch PINNED 2.8.0+cu128 (the prebuilt cp311 wheels —
  cumesh/nvdiffrast/nvdiffrec_render/flex_gemm/o_voxel/custom_rasterizer from
  visualbruno/ComfyUI-Trellis2 wheels/Windows/Torch280 — target the 2.7/2.8 ABI; torchaudio
  must match torch or ComfyUI crashes at import with WinError 127).
- Attention backend: "sdpa" (torch built-in; flash_attn/xformers NOT installed; Turing-safe).
- CUDA-only path: the NVIDIA card is SHARED with Studio (3.4GB baseline) — serialize
  generation against heavy Studio sessions; Q4 wants ~6GB.
- ComfyUI API: POST /prompt {prompt: api-graph, client_id} -> {prompt_id};
  GET /history/<id> -> status + outputs; artifacts land under ComfyUI/output/.

Import-inert (no process spawned until ensure_server/generate are called).
"""

import json
import os
import subprocess
import time
import urllib.error
import urllib.request

COMFY_DIR = os.environ.get("STUDIO_AGENT_COMFY_DIR", r"C:\tools\ComfyUI")
PYTHON = os.path.join(COMFY_DIR, "venv", "Scripts", "python.exe")
HOST = "127.0.0.1"
PORT = int(os.environ.get("STUDIO_AGENT_COMFY_PORT", "8188"))
GENERATE_TIMEOUT_S = int(os.environ.get("STUDIO_AGENT_PIXAL3D_TIMEOUT_S", "1800"))

_server_proc = None


def base_url():
    return f"http://{HOST}:{PORT}"


def _get_json(path, timeout_s=5):
    with urllib.request.urlopen(f"{base_url()}{path}", timeout=timeout_s) as r:
        return json.loads(r.read().decode("utf-8"))


def is_healthy(timeout_s=3):
    try:
        return "comfyui_version" in json.dumps(_get_json("/system_stats", timeout_s))
    except (urllib.error.URLError, OSError, ValueError):
        return False


def ensure_server(boot_timeout_s=90):
    """Start headless ComfyUI if /system_stats doesn't answer. Returns (ok, note)."""
    global _server_proc
    if is_healthy():
        return True, "comfyui already healthy"
    main_py = os.path.join(COMFY_DIR, "main.py")
    if not os.path.isfile(PYTHON) or not os.path.isfile(main_py):
        return False, f"comfyui install incomplete ({PYTHON} / {main_py})"
    _server_proc = subprocess.Popen(
        [PYTHON, main_py, "--listen", HOST, "--port", str(PORT)],
        stdout=open(os.path.join(COMFY_DIR, "boot-out.log"), "ab"),
        stderr=open(os.path.join(COMFY_DIR, "boot-err.log"), "ab"),
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    deadline = time.time() + boot_timeout_s
    while time.time() < deadline:
        if is_healthy():
            return True, f"comfyui started (pid {_server_proc.pid})"
        if _server_proc.poll() is not None:
            return False, f"comfyui exited at boot (code {_server_proc.returncode})"
        time.sleep(1.5)
    return False, "comfyui did not become healthy in time"


def build_workflow(image_name, seed=42, model_format="GGUF Q4_K_M", pipeline_type="512",
                   generate_texture=False, filename_prefix="3D/pixal"):
    """The proven API-format graph: load Pixal3D-GGUF -> load+preprocess image (rembg) ->
    generate -> trimesh -> export GLB. Shape-only by default (texturing = the TRELLIS.2 leg)."""
    return {
        "1": {"class_type": "Trellis2LoadModel_GGUF", "inputs": {
            "modelname": "Pixal3D-GGUF", "model_format": model_format, "backend": "sdpa",
            "device": "cuda", "low_vram": True, "keep_models_loaded": True}},
        "2": {"class_type": "Trellis2LoadImageWithTransparency_GGUF", "inputs": {"image": image_name}},
        "3": {"class_type": "Trellis2PreProcessImage_GGUF", "inputs": {
            "image": ["2", 0], "padding": 0, "remove_background": True}},
        "4": {"class_type": "Trellis2MeshWithVoxelGenerator_GGUF", "inputs": {
            "pipeline": ["1", 0], "image": ["3", 0], "seed": int(seed),
            "pipeline_type": pipeline_type, "sparse_structure_steps": 12, "shape_steps": 12,
            "texture_steps": 12, "max_num_tokens": 49152, "sparse_structure_resolution": 32,
            "max_views": 4, "generate_texture_slat": bool(generate_texture),
            "use_tiled_decoder": True, "sampler": "euler"}},
        "5": {"class_type": "Trellis2MeshWithVoxelToTrimesh_GGUF", "inputs": {
            "mesh": ["4", 0], "reorient_vertices": "90 degrees",
            "rotate_x": 0.0, "rotate_y": 0.0, "rotate_z": 0.0}},
        "6": {"class_type": "Trellis2ExportMesh_GGUF", "inputs": {
            "trimesh": ["5", 0], "filename_prefix": filename_prefix, "file_format": "glb"}},
    }


def generate(image_path, out_glb, seed=42, model_format="GGUF Q4_K_M", pipeline_type="512"):
    """image file -> shape GLB at out_glb via Pixal3D-GGUF. Returns {ok, wall_s, ...}."""
    t0 = time.time()
    if not os.path.isfile(image_path):
        return {"ok": False, "error": f"input image not found: {image_path}"}
    ok, note = ensure_server()
    if not ok:
        return {"ok": False, "error": note}
    # stage the input where ComfyUI's LoadImage can see it
    image_name = os.path.basename(image_path)
    stage = os.path.join(COMFY_DIR, "input", image_name)
    with open(image_path, "rb") as src, open(stage, "wb") as dst:
        dst.write(src.read())
    wf = build_workflow(image_name, seed=seed, model_format=model_format,
                        pipeline_type=pipeline_type)
    body = json.dumps({"prompt": wf, "client_id": "sidecar-pixal3d"}).encode("utf-8")
    req = urllib.request.Request(f"{base_url()}/prompt", data=body,
                                 headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            resp = json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        return {"ok": False, "error": f"/prompt HTTP {e.code}: {e.read()[:300]!r}"}
    prompt_id = resp.get("prompt_id")
    if not prompt_id:
        return {"ok": False, "error": f"no prompt_id in response: {resp}"}
    deadline = time.time() + GENERATE_TIMEOUT_S
    rel_path = None
    while time.time() < deadline:
        time.sleep(5)
        try:
            hist = _get_json(f"/history/{prompt_id}", timeout_s=10).get(prompt_id)
        except (urllib.error.URLError, OSError, ValueError):
            continue
        if not hist:
            continue
        status = hist.get("status", {})
        if status.get("status_str") == "error":
            msgs = json.dumps(status.get("messages", []))[:400]
            return {"ok": False, "error": f"workflow error: {msgs}"}
        if status.get("completed"):
            for node_out in hist.get("outputs", {}).values():
                for v in node_out.values():
                    if isinstance(v, list) and v and isinstance(v[0], str) and v[0].endswith(".glb"):
                        rel_path = v[0]
            break
    if rel_path is None:
        return {"ok": False, "error": "timed out or no .glb path in outputs",
                "wall_s": round(time.time() - t0, 1)}
    src_path = os.path.join(COMFY_DIR, "output", rel_path)
    if not os.path.isfile(src_path):
        return {"ok": False, "error": f"exported glb missing on disk: {src_path}"}
    os.makedirs(os.path.dirname(os.path.abspath(out_glb)), exist_ok=True)
    tmp = out_glb + ".tmp"
    with open(src_path, "rb") as srcf, open(tmp, "wb") as dstf:
        dstf.write(srcf.read())
    os.replace(tmp, out_glb)
    return {"ok": True, "wall_s": round(time.time() - t0, 1),
            "bytes": os.path.getsize(out_glb), "out": out_glb, "comfy_output": rel_path}
