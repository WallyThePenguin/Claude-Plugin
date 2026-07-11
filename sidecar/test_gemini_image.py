"""Dependency-free tests for the Gemini image driver. Run: python sidecar/test_gemini_image.py
No proxy/sidecar is contacted — describe + HTTP seams are stubbed."""
import base64
import json
import os
import sys
import tempfile

import gemini_image


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

    p = gemini_image.REFERENCE_PROMPT.format(subject="rusty falchion sword", style="divine")
    fails += _check("prompt names the subject fully in frame",
                    "rusty falchion sword" in p and "fully in frame" in p)
    fails += _check("prompt pins a plain background and applies the style",
                    "plain white background" in p and "divine" in p)
    fails += _check("prompt bans hands/text/watermark",
                    "no hands" in p and "no text" in p and "no watermark" in p)

    png = base64.b64encode(b"\x89PNG" + b"\x00" * 2000).decode()
    found = gemini_image.extract_image('{"content":"data:image/png;base64,' + png + '"}')
    fails += _check("extracts data-URL images", found is not None and found[0] == "png" and found[1][:4] == b"\x89PNG")
    found = gemini_image.extract_image('{"b64_json":"' + png + '"}')
    fails += _check("extracts b64_json images", found is not None and found[0] == "png")
    fails += _check("ignores short/absent payloads", gemini_image.extract_image('{"content":"no image here"}') is None)

    # enrichment: the tier the user asked for (medium/high) must ride the model string, and
    # enrich_prompt must send that model and return the proxy's drafted prompt.
    fails += _check("enrich default carries an explicit effort tier (not bare low)",
                    gemini_image.ENRICH_MODEL.startswith("gemini-3.5-flash") and "(" in gemini_image.ENRICH_MODEL)
    captured = {}
    real_enrich_open = gemini_image.urllib.request.urlopen

    def _capture_open(req, timeout=0):
        captured["model"] = json.loads(req.data.decode())["model"]
        return FakeResp(b'{"choices":[{"message":{"content":"A vivid divine falchion sword on a '
                        b'plain white background, entire object fully in frame, no hands, no text."}}]}')

    gemini_image.urllib.request.urlopen = _capture_open
    try:
        drafted = gemini_image.enrich_prompt("falchion", "divine", {"baseUrl": "http://x", "proxyKey": "k"})
        fails += _check("enrich sends the configured tier model", captured.get("model") == gemini_image.ENRICH_MODEL)
        fails += _check("enrich returns the proxy's drafted prompt", drafted is not None and "falchion" in drafted)
    finally:
        gemini_image.urllib.request.urlopen = real_enrich_open

    # paint_atlas(): multimodal texture painting — the request must carry the IMAGE model plus
    # BOTH conditioning images (reference first, UV template second) as data-URL parts, and the
    # painted result must be written like generate() writes (atomic, extension-corrected).
    captured2 = {}
    real_paint_open = gemini_image.urllib.request.urlopen
    painted_png = base64.b64encode(b"\x89PNG" + b"\x02" * 2000).decode()

    def _paint_open(req, timeout=0):
        captured2["body"] = json.loads(req.data.decode())
        return FakeResp(('{"choices":[{"message":{"content":"data:image/png;base64,' + painted_png + '"}}]}').encode())

    gemini_image.urllib.request.urlopen = _paint_open
    try:
        with tempfile.TemporaryDirectory() as d:
            ref = os.path.join(d, "ref.png")
            tpl = os.path.join(d, "tpl.png")
            with open(ref, "wb") as fh:
                fh.write(b"\x89PNG-ref")
            with open(tpl, "wb") as fh:
                fh.write(b"\x89PNG-tpl")
            out = os.path.join(d, "atlas.png")
            r = gemini_image.paint_atlas(
                "divine rapier sword", ref, tpl, out,
                describe=lambda: {"baseUrl": "http://x", "proxyKey": "sekrit-b2c4"})
            body = captured2.get("body") or {}
            parts = (body.get("messages") or [{}])[0].get("content") or []
            img_parts = [p for p in parts if isinstance(p, dict) and p.get("type") == "image_url"]
            txt_parts = [p for p in parts if isinstance(p, dict) and p.get("type") == "text"]
            fails += _check("paint uses the image model", body.get("model") == gemini_image.MODEL)
            fails += _check("paint sends BOTH conditioning images as data URLs",
                            len(img_parts) == 2 and all(
                                p["image_url"]["url"].startswith("data:image/png;base64,") for p in img_parts))
            fails += _check("paint instruction names the islands contract",
                            len(txt_parts) == 1 and "island" in txt_parts[0]["text"].lower())
            fails += _check("painted atlas written", r["ok"] is True and os.path.exists(r["out"]))
            fails += _check("paint result never echoes the key", "sekrit-b2c4" not in str(r))

            # relief mode: the template is the mesh's OWN baked relief (AO) — the prompt must
            # flip the authority (reference = theme only; relief = where detail lives) and
            # demand albedo (no baked lighting). User-caught: silhouette paints are "an image
            # stuck on a bunch of bumps" — painted features land where the REFERENCE had them,
            # not where the mesh's real geometry is.
            r2 = gemini_image.paint_atlas(
                "divine rapier", ref, tpl, out, mode="relief",
                describe=lambda: {"baseUrl": "http://x", "proxyKey": "sekrit-b2c4"})
            body2 = captured2.get("body") or {}
            parts2 = (body2.get("messages") or [{}])[0].get("content") or []
            txt2 = [p for p in parts2 if isinstance(p, dict) and p.get("type") == "text"]
            low2 = txt2[0]["text"].lower() if txt2 else ""
            fails += _check("relief prompt makes the relief map the layout authority",
                            "relief" in low2 and "albedo" in low2 and "theme" in low2)
            fails += _check("relief paint writes too", r2["ok"] is True)
    finally:
        gemini_image.urllib.request.urlopen = real_paint_open

    # generate(): no baseUrl from describe refuses before any HTTP
    r = gemini_image.generate("sword", "out.png", describe=lambda: {"baseUrl": "", "proxyKey": ""})
    fails += _check("missing baseUrl refuses early", r["ok"] is False and "describe" in r["error"])

    # happy path with a stubbed proxy response; extension corrected to the actual format
    real_open = gemini_image.urllib.request.urlopen
    jpeg = base64.b64encode(b"\xff\xd8\xff" + b"\x01" * 2000).decode()
    gemini_image.urllib.request.urlopen = lambda req, timeout=0: FakeResp(
        ('{"choices":[{"message":{"content":"data:image/jpeg;base64,' + jpeg + '"}}]}').encode()
    )
    try:
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "ref.png")
            r = gemini_image.generate("sword", out, describe=lambda: {"baseUrl": "http://x", "proxyKey": "sekrit-a8f3k9"})
            fails += _check("image written with corrected extension", r["ok"] is True and r["out"].endswith(".jpeg") and os.path.exists(r["out"]))
            fails += _check("no tmp residue", not os.path.exists(r["out"] + ".tmp"))
            fails += _check("result never echoes the key", "sekrit-a8f3k9" not in str(r))
    finally:
        gemini_image.urllib.request.urlopen = real_open

    print(("test_gemini_image: ALL GREEN" if fails == 0 else f"test_gemini_image: {fails} FAILURES"))
    return fails


if __name__ == "__main__":
    sys.exit(main())
