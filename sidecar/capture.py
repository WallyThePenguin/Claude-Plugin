"""Window capture for the Studio Agent vision sidecar (Windows).

Uses PrintWindow(PW_RENDERFULLCONTENT), which captures a window's pixels even when it is
occluded or not focused (the modern flag also handles hardware-accelerated content like the
Studio viewport). Returns PNG bytes.
"""

import io

import win32con  # noqa: F401  (kept for clarity / future flags)
import win32gui
import win32ui
from ctypes import windll
from PIL import Image

PW_RENDERFULLCONTENT = 0x00000002


def find_window(title_substr: str):
    """Return the hwnd of the first visible top-level window whose title contains title_substr."""
    needle = title_substr.lower()
    matches = []

    def _cb(hwnd, _):
        if win32gui.IsWindowVisible(hwnd):
            title = win32gui.GetWindowText(hwnd)
            if title and needle in title.lower():
                matches.append(hwnd)
        return True

    win32gui.EnumWindows(_cb, None)
    return matches[0] if matches else None


def capture_window_png(title_substr: str = "Roblox Studio") -> bytes:
    """Capture the named window and return PNG bytes. Raises on miss / zero-size window."""
    hwnd = find_window(title_substr)
    if not hwnd:
        raise RuntimeError(f"no visible window matching '{title_substr}'")

    left, top, right, bottom = win32gui.GetWindowRect(hwnd)
    width, height = right - left, bottom - top
    if width <= 0 or height <= 0:
        raise RuntimeError("window has zero size (minimized?)")

    hwnd_dc = win32gui.GetWindowDC(hwnd)
    mfc_dc = win32ui.CreateDCFromHandle(hwnd_dc)
    save_dc = mfc_dc.CreateCompatibleDC()
    bitmap = win32ui.CreateBitmap()
    bitmap.CreateCompatibleBitmap(mfc_dc, width, height)
    save_dc.SelectObject(bitmap)

    ok = windll.user32.PrintWindow(hwnd, save_dc.GetSafeHdc(), PW_RENDERFULLCONTENT)

    info = bitmap.GetInfo()
    bits = bitmap.GetBitmapBits(True)
    image = Image.frombuffer(
        "RGB", (info["bmWidth"], info["bmHeight"]), bits, "raw", "BGRX", 0, 1
    )

    win32gui.DeleteObject(bitmap.GetHandle())
    save_dc.DeleteDC()
    mfc_dc.DeleteDC()
    win32gui.ReleaseDC(hwnd, hwnd_dc)

    if ok != 1:
        # PrintWindow returned non-1 but frequently still produced a valid frame; only fail if the
        # image is entirely black (a real capture failure).
        if not image.getbbox():
            raise RuntimeError("PrintWindow produced an empty frame (try focusing Studio once)")

    out = io.BytesIO()
    image.save(out, format="PNG")
    return out.getvalue()
