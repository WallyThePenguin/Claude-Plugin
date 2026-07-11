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

# The prompt SHAPE is the user's (2026-07-11, the divine-rapier result): style-forward
# ("make it look divine") + a plain WHITE background named for its purpose ("so TRELLIS 2 can
# replicate it"). The earlier sterile product-photography template produced technically-clean
# but boring weapons — style adjectives are what buy the ornate filigree/glow detail.
REFERENCE_PROMPT = (
    "Generate me {subject}, make it look {style}, make it have a plain white background "
    "so TRELLIS 2 can replicate it. The entire object fully in frame, no hands, no people, "
    "no text, no watermark."
)
DEFAULT_STYLE = "striking and detailed"

# Prompt enrichment (pilot doctrine): a TEXT model turns a bare subject into a rich image
# prompt. The proxy's closest tier to the user's "3.5 flash medium effort" is
# gemini-3.5-flash-low (no medium variant is served; the image model itself must stay
# gemini-3.1-flash-image — the only image-capable model on the proxy).
ENRICH_MODEL = os.environ.get("STUDIO_AGENT_GEMINI_ENRICH_MODEL", "gemini-3.5-flash-low")


def enrich_prompt(subject, style, desc):
    """Ask the text model to write ONE vivid image prompt for the subject; falls back to the
    template on any failure (enrichment is a bonus, never a blocker)."""
    base_url = (desc.get("baseUrl") or "").rstrip("/")
    key = desc.get("proxyKey") or ""
    ask = (
        "Write ONE image-generation prompt (a single paragraph, no preamble, no options) for: "
        f"{subject}, in a {style} style. Requirements that MUST appear: plain white background, "
        "entire object fully in frame, no hands, no people, no text, no watermark. Make the "
        "object description vivid and specific (materials, ornament, silhouette)."
    )
    body = {"model": ENRICH_MODEL, "messages": [{"role": "user", "content": ask}]}
    req = urllib.request.Request(
        base_url + "/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + key},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            resp = json.loads(r.read().decode("utf-8", "replace"))
        text = str(resp.get("choices", [{}])[0].get("message", {}).get("content") or "").strip()
        if 40 < len(text) < 2000:
            return text
    except (urllib.error.URLError, OSError, ValueError, TimeoutError):
        pass
    return None


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


def generate(subject, out_path, describe=None, model=None, raw_prompt=None,
             style=DEFAULT_STYLE, enrich=False):
    """subject ('an elden ring rapier') -> reference image at out_path (extension corrected to
    the actual format). enrich=True drafts the prompt via the text model first.
    Returns {ok, wall_s, out, bytes, prompt} or {ok: False, error}."""
    t0 = time.time()
    desc = (describe or self_describe)()
    base_url = (desc.get("baseUrl") or "").rstrip("/")
    key = desc.get("proxyKey") or ""
    if not base_url:
        return {"ok": False, "error": "no proxy baseUrl from describe (is Studio open with the bridge?)"}
    prompt = raw_prompt
    if prompt is None and enrich:
        prompt = enrich_prompt(subject, style, desc)
    if prompt is None:
        prompt = REFERENCE_PROMPT.format(subject=subject, style=style)
    body = {
        "model": model or MODEL,
        "messages": [{"role": "user", "content": prompt}],
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
    return {"ok": True, "wall_s": round(time.time() - t0, 1), "out": out, "bytes": len(data),
            "prompt": prompt}
