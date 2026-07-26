"""Kimodo text->motion generation driver (the required Windows flag trio baked in).

Every Kimodo run needs three env flags (XET off, SYMLINKS off, CPU text encoder) — each fixes a
real Windows blocker (see the studio-agent-kimodo-text-to-motion memory). This driver sets them so
callers never forget. It shells out to the kimodo venv's OWN python (torch 2.11+cu128), cwd = the
kimodo repo, `-m kimodo.scripts.generate`. Default model = Kimodo-SOMA-RP-v1 (77-joint, commercial
license, full finger + toe chains — the skeleton the retarget's wrist/ankle rows need).

Output: writes <stem>.npz into meshio.ASSET_DIR (assets/reference/) so the /animate/kimodo route
(retarget_reference_kimodo) reads it by basename. Returns {ok, npz, path, wall_s, tail} |
{ok:False, error, tail?}. Never pipe gen output through `| tail` (masks the real exit code — a
failed run once printed "exit 0"); this uses returncode directly.
"""

import os
import subprocess
import time

import meshio

KIMODO_DIR = os.environ.get("STUDIO_AGENT_KIMODO_DIR", r"C:\tools\kimodo")
KIMODO_PY = os.path.join(KIMODO_DIR, ".venv", "Scripts", "python.exe")
DEFAULT_MODEL = os.environ.get("STUDIO_AGENT_KIMODO_MODEL", "Kimodo-SOMA-RP-v1")
GEN_TIMEOUT_S = int(os.environ.get("STUDIO_AGENT_KIMODO_TIMEOUT_S", "1200"))

# The REQUIRED trio (each fixes a real Windows blocker — do not drop any).
KIMODO_ENV = {
    "HF_HUB_DISABLE_XET": "1",       # hf-xet throws OSError[22] making .lock files on Windows
    "HF_HUB_DISABLE_SYMLINKS": "1",  # hf symlinks blobs->snapshots; Windows blocks (WinError 1314)
    "TEXT_ENCODER_DEVICE": "cpu",    # LLM2Vec-on-Llama-3-8B is ~17GB VRAM; CPU keeps GPU <3GB
}


def _build_cmd(prompt, stem_path, model, duration, seed, cfg_weight, no_postprocess):
    """Pure: the argv for `kimodo.scripts.generate`. Unit-tested (no subprocess)."""
    cmd = [
        KIMODO_PY, "-m", "kimodo.scripts.generate", str(prompt),
        "--model", model or DEFAULT_MODEL,
        "--duration", str(duration),
        "--output", stem_path,
    ]
    if seed is not None:
        cmd += ["--seed", str(int(seed))]
    if no_postprocess:
        cmd += ["--no-postprocess"]
    if cfg_weight is not None:
        cmd += ["--cfg_weight", str(cfg_weight)]
    return cmd


def generate(prompt, out_stem, model=None, duration=3.0, seed=42, cfg_weight=None,
             no_postprocess=True, timeout_s=None):
    """prompt -> <out_stem>.npz in assets/reference/. out_stem is a BARE name (no path/ext).
    cfg_weight (float) raises guidance for punchier motion. Returns the result dict."""
    if not isinstance(out_stem, str) or "/" in out_stem or "\\" in out_stem or ".." in out_stem:
        return {"ok": False, "error": "bad out_stem (bare name, no path/ext)"}
    if not os.path.isfile(KIMODO_PY):
        return {"ok": False, "error": f"kimodo venv python not found at {KIMODO_PY}"}
    os.makedirs(meshio.ASSET_DIR, exist_ok=True)
    stem_path = os.path.join(meshio.ASSET_DIR, out_stem)
    npz_path = stem_path + ".npz"
    cmd = _build_cmd(prompt, stem_path, model, duration, seed, cfg_weight, no_postprocess)
    env = dict(os.environ)
    env.update(KIMODO_ENV)
    t0 = time.time()
    try:
        proc = subprocess.run(
            # encoding/errors are REQUIRED on Windows: text=True decodes with the ANSI
            # codepage (cp1252), and kimodo's progress bars emit bytes it cannot map —
            # the reader thread dies with UnicodeDecodeError and the tail is lost exactly
            # when a failing run needs it most (live-caught 2026-07-26).
            cmd, cwd=KIMODO_DIR, env=env, capture_output=True, text=True,
            encoding="utf-8", errors="replace",
            timeout=timeout_s or GEN_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": f"kimodo generate timed out ({timeout_s or GEN_TIMEOUT_S}s)"}
    tail = ((proc.stdout or "")[-600:] + "\n" + (proc.stderr or "")[-600:]).strip()
    if proc.returncode != 0:
        return {"ok": False, "error": f"kimodo exit {proc.returncode}", "tail": tail}
    if not os.path.isfile(npz_path):
        return {"ok": False, "error": "kimodo returned 0 but no npz was written", "tail": tail}
    return {
        "ok": True, "npz": os.path.basename(npz_path), "path": npz_path,
        "wall_s": round(time.time() - t0, 1), "model": model or DEFAULT_MODEL, "tail": tail[-300:],
    }


if __name__ == "__main__":
    import json
    import sys

    prompt = sys.argv[1] if len(sys.argv) > 1 else \
        "a person swings a sword downward with the right hand"
    stem = sys.argv[2] if len(sys.argv) > 2 else "kimodo-soma-test"
    cfg = float(sys.argv[3]) if len(sys.argv) > 3 else None
    print(json.dumps(generate(prompt, stem, cfg_weight=cfg), indent=1))
