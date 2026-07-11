"""Gemini text->image via hecate's CLIProxyAPI — Stage 1 of the asset pipeline.

USER DECISION (2026-07-11, overriding the earlier direct-API plan): image generation goes through
the SAME proxy the plugin uses for Claude — hecate's CLIProxyAPI (SSH tunnel, default
http://127.0.0.1:8318). LIVE-VERIFIED: the proxy lists `gemini-3.1-flash-image` and one
chat-completions call returned a museum-grade falchion reference in 9.3s (studio background,
3/4 view — a BETTER image-to-3D input than found photos; no rembg fight).

Credential flow: baseUrl + proxyKey come from the plugin via the bridge `describe` command —
the same seam agent_loop uses. The key is held in-process only and NEVER logged/printed
(leak-regression doctrine). Standalone use (CLI while the sidecar runs) self-describes over
the sidecar's /agent route; in-process use (a server.py route) passes a describe callable.

Prompt shape (image-to-3D best practice, measured tonight): single object, whole object in
frame, 3/4 view, plain background, no hands/text/watermark. Flat 2D-drawing styles make bad
3D inputs — keep it photographic.
"""

import base64
import json
import os
import re
import time
import urllib.error
import urllib.request

SIDECAR = "http://127.0.0.1:" + os.environ.get("SIDECAR_PORT", "8389")
MODEL = os.environ.get("STUDIO_AGENT_GEMINI_IMAGE_MODEL", "gemini-3.1-flash-image")
GENERATE_TIMEOUT_S = int(os.environ.get("STUDIO_AGENT_GEMINI_IMAGE_TIMEOUT_S", "180"))

REFERENCE_PROMPT = (
    "Generate an image: a single {subject}, entire object fully in frame, 3/4 view, "
    "plain solid light-gray background, studio product photography, sharp detail, "
    "no hands, no people, no text, no watermark."
)


def self_describe():
    """Fetch {baseUrl, proxyKey} from the plugin via the sidecar's /agent bridge route."""
    req = urllib.request.Request(
        SIDECAR + "/agent",
        data=json.dumps({"kind": "describe"}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        cid = json.loads(r.read().decode()).get("id")
    deadline = time.time() + 30
    while time.time() < deadline:
        time.sleep(0.5)
        with urllib.request.urlopen(SIDECAR + f"/agent/result?id={cid}", timeout=10) as r:
            res = json.loads(r.read().decode())
        if isinstance(res, dict) and "ok" in res:
            return {"baseUrl": res.get("baseUrl") or "", "proxyKey": res.get("proxyKey") or ""}
    return {"baseUrl": "", "proxyKey": ""}


def extract_image(response_text):
    """(ext, bytes) from a chat-completions response carrying a data URL or b64_json; None if absent."""
    m = re.search(r"data:image/(png|jpeg);base64,([A-Za-z0-9+/=]{1000,})", response_text)
    if m:
        return m.group(1), base64.b64decode(m.group(2))
    m = re.search(r'"b64_json"\s*:\s*"([A-Za-z0-9+/=]{1000,})"', response_text)
    if m:
        return "png", base64.b64decode(m.group(1))
    return None


def generate(subject, out_path, describe=None, model=None, raw_prompt=None):
    """subject ('rusty falchion sword') -> reference image at out_path (extension corrected to
    the actual format). Returns {ok, wall_s, out, bytes} or {ok: False, error}."""
    t0 = time.time()
    desc = (describe or self_describe)()
    base_url = (desc.get("baseUrl") or "").rstrip("/")
    key = desc.get("proxyKey") or ""
    if not base_url:
        return {"ok": False, "error": "no proxy baseUrl from describe (is Studio open with the bridge?)"}
    body = {
        "model": model or MODEL,
        "messages": [{"role": "user",
                      "content": raw_prompt or REFERENCE_PROMPT.format(subject=subject)}],
    }
    req = urllib.request.Request(
        base_url + "/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + key},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=GENERATE_TIMEOUT_S) as r:
            text = r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return {"ok": False, "error": f"proxy HTTP {e.code}: {e.read()[:300]!r}"}
    except (urllib.error.URLError, OSError, TimeoutError) as e:
        return {"ok": False, "error": f"proxy transport error: {e}"}
    found = extract_image(text)
    if found is None:
        head = ""
        try:
            msg = json.loads(text).get("choices", [{}])[0].get("message", {})
            head = str(msg.get("content"))[:200]
        except (ValueError, AttributeError, IndexError):
            head = text[:200]
        return {"ok": False, "error": "no image in response; content head: " + head}
    ext, data = found
    root, _ = os.path.splitext(out_path)
    out = root + "." + ext
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    tmp = out + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, out)
    return {"ok": True, "wall_s": round(time.time() - t0, 1), "out": out, "bytes": len(data)}
