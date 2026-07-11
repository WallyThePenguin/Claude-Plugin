"""Headless Blender subprocess bridge — Stage 3 of the asset pipeline (SP3).

Design decision (banked in docs/superpowers/notes/2026-07-11-trellis-pipeline-plan.md): NO MCP.
This leg is a deterministic batch step — GLB in, cleaned/rigged export out — so it is a plain
`blender -b --factory-startup -P <script> -- <args>` subprocess with a timeout and captured
logs. Scripts live in sidecar/blender_scripts/ (versioned in-repo).

Blender 4.5.11 LTS portable at C:\\tools\\blender-4.5.11-windows-x64 (verified headless:
FBX exporter, glTF importer, EEVEE renders). Override via STUDIO_AGENT_BLENDER.
"""

import os
import subprocess

BLENDER_EXE = os.environ.get(
    "STUDIO_AGENT_BLENDER", r"C:\tools\blender-4.5.11-windows-x64\blender.exe"
)
SCRIPT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "blender_scripts")


def run_script(script_name, script_args, timeout_s=600):
    """Run sidecar/blender_scripts/<script_name> headless. Returns
    {ok, code, out_tail, err_tail} — tails are the last ~2KB each (Blender is chatty)."""
    if not os.path.isfile(BLENDER_EXE):
        return {"ok": False, "code": -1, "out_tail": "", "err_tail": f"blender not found: {BLENDER_EXE}"}
    script = os.path.join(SCRIPT_DIR, script_name)
    if not os.path.isfile(script):
        return {"ok": False, "code": -1, "out_tail": "", "err_tail": f"script not found: {script}"}
    cmd = [BLENDER_EXE, "-b", "--factory-startup", "-P", script, "--"] + list(script_args)
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            timeout=timeout_s,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except subprocess.TimeoutExpired:
        return {"ok": False, "code": -1, "out_tail": "", "err_tail": f"blender timed out after {timeout_s}s"}
    out = proc.stdout.decode("utf-8", "replace")
    err = proc.stderr.decode("utf-8", "replace")
    # the script signals success explicitly — Blender exits 0 even after Python tracebacks
    # in some paths, so require the marker AND exit 0
    ok = proc.returncode == 0 and "RIG_WEAPON_OK" in out
    return {"ok": ok, "code": proc.returncode, "out_tail": out[-2000:], "err_tail": err[-2000:]}
