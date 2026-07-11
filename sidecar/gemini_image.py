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
# prompt. The effort tier the user wanted ("3.5 flash medium") IS reachable after all — it
# rides the model string as a call-time suffix: gemini-3.5-flash-low(medium) | (high). An
# isolated cliproxy test (issue #3699) proved a bare listed alias can't carry the tier (it
# resolves to low), but the (tier) suffix and the reasoning_effort param both do — verified
# 200 on the live proxy. Default to medium (the user's original ask); flip to (high) via
# STUDIO_AGENT_GEMINI_ENRICH_MODEL with no code change. The IMAGE model stays
# gemini-3.1-flash-image — the only image-capable model on the proxy.
ENRICH_MODEL = os.environ.get("STUDIO_AGENT_GEMINI_ENRICH_MODEL", "gemini-3.5-flash-low(medium)")


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


# Texture painting (decoupled-texture architecture, user decision 2026-07-11): the shape comes
# from TRELLIS untextured, Blender authors clean UV islands ONCE (rig_weapon.py --uv smart), and
# the PAINTER fills those islands conditioned on the original Gemini reference. This prompt is
# the islands contract — the template's gray regions are the canvas, black is dead space, and
# painted color must bleed PAST island borders so mip-sampling at seams never reads black.
PAINT_PROMPT = (
    "You are painting a texture atlas for a 3D model of {subject}. The second image is the UV "
    "layout template: each solid gray region is one unwrapped island of the model's surface "
    "(for a planar unwrap the single island IS the object's silhouette seen from its broad "
    "side); black is unused space. The first image is the reference showing how the object must "
    "look. Paint a complete texture atlas AT THE SAME RESOLUTION and aspect ratio as the "
    "template: fill EVERY gray island with the surface detail the reference shows for that part "
    "of the object, and MATCH THE REFERENCE'S MATERIAL DISTRIBUTION REGION BY REGION — do not "
    "restyle or recolor (if the reference blade is pale polished silver with a narrow gold "
    "center line, paint exactly that, not an all-gold blade). Keep every painted feature "
    "aligned to the island's shape. Extend each island's colors roughly 8 pixels past its "
    "border (bleed), and keep all remaining space PURE BLACK — no drop shadows, no glow, no "
    "background, no outlines, labels, or wireframe lines. Output only the painted atlas image."
)


# Relief mode (user-caught failure of silhouette mode: "an image stuck on a bunch of bumps" —
# painted features land where the REFERENCE had them, not where the mesh's real geometry is).
# The template here is the mesh's OWN baked relief (ambient occlusion in UV space): dark
# crevices, bright ridges — the ground truth of where the actual surface detail lives. The
# reference is demoted to THEME (materials, palette, mood); the relief is the layout authority.
# Albedo-only keeps engine lighting honest (painted highlights/shadows fight real-time light).
PAINT_RELIEF_PROMPT = (
    "You are painting a texture atlas for a 3D model of {subject}. The second image is the "
    "model's OWN surface relief map (an ambient-occlusion bake laid out in UV space): dark "
    "areas are real crevices and recesses of the mesh, bright areas are raised ridges and "
    "flats; pure black is unused space. The first image is a THEME reference only — take its "
    "materials, colors, and mood from it, but do NOT copy its layout or paste its picture. "
    "Paint a full-color ALBEDO texture at the same resolution and aspect as the relief map, "
    "molding the paint to the relief: where the relief SHOWS features, respect them (recessed "
    "engraving gets darker inlay tones, raised ornament gets the bright metal); where the "
    "relief is FLAT and featureless — large smooth areas like blade flats — that is your "
    "canvas: DECORATE it richly with the theme's own ornament (engraved motifs, runes, inlay "
    "lines, filigree, gem settings) drawn from the reference, at high detail. A plain "
    "undecorated expanse is a FAILURE unless the reference shows that part truly plain. Style: "
    "a RICH hand-painted game albedo texture — realistic material detail and color variation "
    "(brushed-metal grain, subtle patina, engraving fill, worn edges), NOT flat cartoon fills — "
    "but with lighting kept OUT of the paint: no specular highlights, no cast shadows, no baked "
    "shading, no glow. Cover every non-black region of the relief (each island) fully, bleed "
    "each region's colors roughly 8 pixels past its border, keep unused space pure black, and "
    "draw no outlines, labels, or wireframe lines. Output only the painted atlas image."
)


def _data_url(path):
    mime = "image/jpeg" if path.lower().endswith((".jpg", ".jpeg")) else "image/png"
    with open(path, "rb") as f:
        return "data:" + mime + ";base64," + base64.b64encode(f.read()).decode("ascii")


def paint_atlas(subject, reference_path, template_path, out_path, describe=None, model=None,
                mode="silhouette"):
    """Paint a UV atlas for `subject`: multimodal call = reference image + template + the
    contract prompt -> painted atlas PNG at out_path (extension corrected). mode="silhouette"
    paints into the flat island mask (render_uv_template wire=False); mode="relief" expects the
    template to be the mesh's OWN AO bake and paints theme-from-reference, layout-from-relief,
    albedo-only. Same describe / extract / atomic-write seams as generate(). Returns
    {ok, wall_s, out, bytes} | {ok:False, error}."""
    t0 = time.time()
    desc = (describe or self_describe)()
    base_url = (desc.get("baseUrl") or "").rstrip("/")
    key = desc.get("proxyKey") or ""
    if not base_url:
        return {"ok": False, "error": "no proxy baseUrl from describe (is Studio open with the bridge?)"}
    prompt = (PAINT_RELIEF_PROMPT if mode == "relief" else PAINT_PROMPT).format(subject=subject)
    body = {
        "model": model or MODEL,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": prompt},
                {"type": "image_url", "image_url": {"url": _data_url(reference_path)}},
                {"type": "image_url", "image_url": {"url": _data_url(template_path)}},
            ],
        }],
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
