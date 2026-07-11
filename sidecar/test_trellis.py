"""Dependency-free tests for the trellis.cpp driver. Run: python sidecar/test_trellis.py
No trellis-server is spawned — HTTP + process seams are stubbed."""
import os
import sys
import tempfile

import trellis


def _check(name, cond):
    print(("  PASS  " if cond else "  FAIL  ") + name)
    return 0 if cond else 1


class FakeResp:
    def __init__(self, payload):
        self._p = payload

    def read(self):
        return self._p

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def main():
    fails = 0

    # multipart encoding: fields + file part with the MEASURED field names
    body, boundary = trellis._multipart(
        {"resolution": "512", "bg_removal": "birefnet", "seed": "42"},
        "image",
        "in.png",
        b"\x89PNGfakebytes",
    )
    fails += _check("multipart carries the resolution field (res is silently ignored upstream)",
                    b'name="resolution"' in body and b"512" in body)
    fails += _check("multipart carries bg_removal + seed", b'name="bg_removal"' in body and b'name="seed"' in body)
    fails += _check("multipart file part named image", b'name="image"; filename="in.png"' in body)
    fails += _check("multipart closes its boundary", body.endswith(f"--{boundary}--\r\n".encode()))
    fails += _check("boundary is declared to the caller", boundary in body.decode("utf-8", "replace"))

    # generate(): missing input short-circuits before any server contact
    r = trellis.generate(os.path.join(tempfile.gettempdir(), "no-such-image-xyz.png"), "out.glb")
    fails += _check("missing input image refuses early", r["ok"] is False and "not found" in r["error"])

    # generate(): a JSON error body (the measured missing-gguf shape) is surfaced, not written
    tmpdir = tempfile.mkdtemp(prefix="trellis-test-")
    img = os.path.join(tmpdir, "in.png")
    with open(img, "wb") as f:
        f.write(b"\x89PNGfake")
    out_glb = os.path.join(tmpdir, "out", "gen.glb")

    real_ensure = trellis.ensure_server
    real_open = trellis.urllib.request.urlopen
    trellis.ensure_server = lambda log_dir=None: (True, "stubbed")
    try:
        trellis.urllib.request.urlopen = lambda req, timeout=0: FakeResp(
            b'{"error":"failed to open gguf: shape_flow_1024.gguf"}'
        )
        r = trellis.generate(img, out_glb)
        fails += _check("non-GLB response reported as error", r["ok"] is False and "gguf" in str(r["error"]))
        fails += _check("no file written on error", not os.path.exists(out_glb))

        # happy path: GLB magic -> atomic write
        trellis.urllib.request.urlopen = lambda req, timeout=0: FakeResp(b"glTF" + b"\x02" * 64)
        r = trellis.generate(img, out_glb, resolution=512, seed=7)
        fails += _check("GLB response written", r["ok"] is True and os.path.exists(out_glb))
        fails += _check("byte count reported", r.get("bytes") == 68)
        fails += _check("no tmp residue", not os.path.exists(out_glb + ".tmp"))

        # NO no_texture param, deliberately: probed live 2026-07-11 — the per-request multipart
        # field is silently ignored by trellis-server v0.1.5 (--no-texture is launch-only), so a
        # param would be a lying knob. Guard that it stays absent until a server version honors it.
        import inspect
        fails += _check("generate refuses a lying no_texture knob (server ignores the field)",
                        "no_texture" not in inspect.signature(trellis.generate).parameters)
    finally:
        trellis.ensure_server = real_ensure
        trellis.urllib.request.urlopen = real_open

    # ensure_server(): missing exe refuses with the path in the note
    real_exe = trellis.SERVER_EXE
    real_healthy = trellis.is_healthy
    trellis.is_healthy = lambda timeout_s=3: False
    trellis.SERVER_EXE = os.path.join(tmpdir, "nope", "trellis-server.exe")
    try:
        ok, note = trellis.ensure_server()
        fails += _check("missing exe refuses with path", ok is False and "not found" in note)
    finally:
        trellis.SERVER_EXE = real_exe
        trellis.is_healthy = real_healthy

    print(("test_trellis: ALL GREEN" if fails == 0 else f"test_trellis: {fails} FAILURES"))
    return fails


if __name__ == "__main__":
    sys.exit(main())
