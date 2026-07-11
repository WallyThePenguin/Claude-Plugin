"""Dependency-free tests for the Gemini image driver. Run: python sidecar/test_gemini_image.py
No proxy/sidecar is contacted — describe + HTTP seams are stubbed."""
import base64
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

    p = gemini_image.REFERENCE_PROMPT.format(subject="rusty falchion sword")
    fails += _check("prompt pins single-object framing", "single rusty falchion sword" in p and "fully in frame" in p)
    fails += _check("prompt pins plain background + 3/4 view", "plain solid light-gray background" in p and "3/4 view" in p)
    fails += _check("prompt bans hands/text/watermark", "no hands" in p and "no text" in p and "no watermark" in p)

    png = base64.b64encode(b"\x89PNG" + b"\x00" * 2000).decode()
    found = gemini_image.extract_image('{"content":"data:image/png;base64,' + png + '"}')
    fails += _check("extracts data-URL images", found is not None and found[0] == "png" and found[1][:4] == b"\x89PNG")
    found = gemini_image.extract_image('{"b64_json":"' + png + '"}')
    fails += _check("extracts b64_json images", found is not None and found[0] == "png")
    fails += _check("ignores short/absent payloads", gemini_image.extract_image('{"content":"no image here"}') is None)

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
