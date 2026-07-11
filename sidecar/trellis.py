"""Local image->3D via trellis.cpp — Stage 2 of the asset pipeline (SP3).

Drives the trellis.cpp server binary (TRELLIS.2 GGUF weights) as a managed child process and
turns a reference PNG/JPG into a textured GLB on disk. Everything here was MEASURED live on this
machine (2026-07-11, RTX 2060 SUPER 8GB + AMD iGPU, Windows 11):

- The CUDA build is DEAD on Turing sm_75: `no kernel image is available` at IM2COL — the shipped
  fatbins carry sm_80+ only. The VULKAN build is the working engine on this card.
- Device pinning: ggml's Vulkan backend picks the LARGEST-memory device by default, which here is
  the AMD iGPU (33GB shared UMA, slow). GGML_VK_VISIBLE_DEVICES="0" pins the NVIDIA card.
  (The iGPU is a legitimate fallback lane for VRAM-starved sessions — slower, memory-rich.)
- One generation at --res 512: ~90s wall on the pinned 2060 (Studio open), peak process VRAM
  ~2.8GB over baseline; per-stage model load/free keeps it inside 8GB.
- HTTP surface (learned by error-walking the binary): GET /health -> "ok";
  POST /generate multipart fields: image (file part, REQUIRED — missing => {"error": ...}),
  resolution (512|1024|1536 — the field is `resolution`; `res` is silently IGNORED and the
  server then defaults to 1024, which cascades into the *_1024 GGUFs), bg_removal
  (threshold|birefnet), seed. Response body = binary GLB (magic 'glTF'), or JSON error.
- res-512 output is NOT ship-ready: ~120k tris (Roblox cap 20k/MeshPart), non-watertight —
  the Blender cleanup stage (blenderbridge) owns decimation/repair.
- Garbage-in garbage-out is REAL and cheap to hit: a scanned book-page "photo" generated a flat
  paper plate with the sword as a texture. Inputs must be single-object, plain-background
  (Stage 1's Gemini job); bg_removal=birefnet handles mild backgrounds like cloth.

The sidecar server route (POST /model3d/generate) is wired separately in server.py; this module
stays import-inert (no process spawned until ensure_server/generate are called) so the running
sidecar is undisturbed by its presence.
"""

import json
import os
import subprocess
import time
import urllib.error
import urllib.request

TRELLIS_DIR = os.environ.get("STUDIO_AGENT_TRELLIS_DIR", r"C:\tools\trellis")
# Vulkan build (the working engine on this GPU); the CUDA build lives one level up and is
# kept only for future driver/binary updates.
SERVER_EXE = os.path.join(TRELLIS_DIR, "vulkan", "trellis-server.exe")
MODELS_DIR = os.path.join(TRELLIS_DIR, "models")
HOST = "127.0.0.1"
PORT = int(os.environ.get("STUDIO_AGENT_TRELLIS_PORT", "8082"))
# "0" pins the NVIDIA card; "" lets ggml pick (the big-memory iGPU); None inherits the env.
VULKAN_DEVICES = os.environ.get("STUDIO_AGENT_TRELLIS_VK_DEVICES", "0")

HEALTH_TIMEOUT_S = 30
GENERATE_TIMEOUT_S = int(os.environ.get("STUDIO_AGENT_TRELLIS_TIMEOUT_S", "1200"))

_server_proc = None


def base_url():
    return f"http://{HOST}:{PORT}"


def is_healthy(timeout_s=3):
    try:
        with urllib.request.urlopen(f"{base_url()}/health", timeout=timeout_s) as r:
            return r.read().strip() == b"ok"
    except (urllib.error.URLError, OSError):
        return False


def ensure_server(log_dir=None):
    """Start trellis-server if not already answering /health. Returns (ok, note)."""
    global _server_proc
    if is_healthy():
        return True, "trellis-server already healthy"
    if not os.path.isfile(SERVER_EXE):
        return False, f"trellis-server.exe not found at {SERVER_EXE}"
    if not os.path.isdir(MODELS_DIR):
        return False, f"models dir not found at {MODELS_DIR}"
    env = dict(os.environ)
    if VULKAN_DEVICES is not None and VULKAN_DEVICES != "":
        env["GGML_VK_VISIBLE_DEVICES"] = VULKAN_DEVICES
    out = err = subprocess.DEVNULL
    if log_dir:
        os.makedirs(log_dir, exist_ok=True)
        out = open(os.path.join(log_dir, "trellis-out.log"), "ab")
        err = open(os.path.join(log_dir, "trellis-err.log"), "ab")
    _server_proc = subprocess.Popen(
        [SERVER_EXE, "-m", MODELS_DIR, "--host", HOST, "--port", str(PORT)],
        stdout=out,
        stderr=err,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    deadline = time.time() + HEALTH_TIMEOUT_S
    while time.time() < deadline:
        if is_healthy():
            return True, f"trellis-server started (pid {_server_proc.pid})"
        if _server_proc.poll() is not None:
            return False, f"trellis-server exited immediately (code {_server_proc.returncode})"
        time.sleep(0.5)
    return False, "trellis-server did not become healthy in time"


def stop_server():
    global _server_proc
    if _server_proc is not None and _server_proc.poll() is None:
        _server_proc.terminate()
    _server_proc = None


def _multipart(fields, file_field, file_name, file_bytes):
    boundary = "----trellisboundary%d" % int(time.time() * 1000)
    lines = []
    for k, v in fields.items():
        lines.append(f"--{boundary}\r\n".encode())
        lines.append(f'Content-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
    lines.append(f"--{boundary}\r\n".encode())
    lines.append(
        f'Content-Disposition: form-data; name="{file_field}"; filename="{file_name}"\r\n'
        f"Content-Type: application/octet-stream\r\n\r\n".encode()
    )
    lines.append(file_bytes)
    lines.append(f"\r\n--{boundary}--\r\n".encode())
    return b"".join(lines), boundary


def generate(image_path, out_glb, resolution=512, bg_removal="birefnet", seed=42):
    """image file -> textured GLB at out_glb. Returns dict {ok, wall_s, bytes, error?}.

    The caller owns retry policy (plan: <=2 re-seeds) and post-validation (meshio/trimesh).
    """
    t0 = time.time()
    if not os.path.isfile(image_path):
        return {"ok": False, "error": f"input image not found: {image_path}"}
    ok, note = ensure_server()
    if not ok:
        return {"ok": False, "error": note}
    with open(image_path, "rb") as f:
        img = f.read()
    body, boundary = _multipart(
        {"resolution": str(int(resolution)), "bg_removal": bg_removal, "seed": str(int(seed))},
        "image",
        os.path.basename(image_path),
        img,
    )
    req = urllib.request.Request(
        f"{base_url()}/generate",
        data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=GENERATE_TIMEOUT_S) as r:
            payload = r.read()
    except urllib.error.HTTPError as e:
        detail = e.read()[:400]
        return {"ok": False, "error": f"generate HTTP {e.code}: {detail!r}"}
    except (urllib.error.URLError, OSError, TimeoutError) as e:
        return {"ok": False, "error": f"generate transport error: {e}"}
    wall = round(time.time() - t0, 1)
    if payload[:4] != b"glTF":
        # JSON error body (e.g. missing model file) — surface it verbatim, truncated
        try:
            err = json.loads(payload.decode("utf-8", "replace"))
        except (ValueError, UnicodeDecodeError):
            err = payload[:200].decode("utf-8", "replace")
        return {"ok": False, "wall_s": wall, "error": f"non-GLB response: {err}"}
    os.makedirs(os.path.dirname(os.path.abspath(out_glb)), exist_ok=True)
    tmp = out_glb + ".tmp"
    with open(tmp, "wb") as f:
        f.write(payload)
    os.replace(tmp, out_glb)
    return {"ok": True, "wall_s": wall, "bytes": len(payload), "out": out_glb}
