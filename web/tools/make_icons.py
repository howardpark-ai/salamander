#!/usr/bin/env python3
"""Draw sala-web's app icons into src/sala_web/static/icons/ in stackshot's recipe: stackshot's dark tile (#1f1f21) with
its orange (#f0a06a) drawn as sala's own ">_" glyph (the favicon's), at the same heavy stroke (4 of 32, stackshot's 8 of 64).
Why: the two apps' icons read as a pair. The colours are fixed here, not taken from the page's palette (static/style.css).

Pillow is needed only to draw them, never by the app, so it is not a dependency: run this with it pulled in for the
one command, in web/ of a checkout, and commit the PNGs it writes:

    uv run --no-project --with pillow tools/make_icons.py

Files (the manifest, static/manifest.webmanifest, names the first three; index.html the last):
  icon-192.png, icon-512.png     purpose "any": a rounded square, transparent outside the corners
  icon-512-maskable.png          purpose "maskable": full-bleed, the glyph inside the 80% safe zone (the launcher
                                 cuts its own shape out of the square)
  apple-touch-icon.png           180x180, full-bleed (iOS rounds the corners itself)
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

WEB = Path(__file__).resolve().parent.parent
STATIC = WEB / "src" / "sala_web" / "static"
OUT = STATIC / "icons"
GLYPH_COLOR = (240, 160, 106, 255)   # #f0a06a, stackshot's orange
ICON_FILL = (31, 31, 33, 255)        # #1f1f21, stackshot's tile
SUPERSAMPLE = 4  # drawn this many times larger, then shrunk: Pillow's lines have no anti-aliasing of their own

# the favicon's geometry (index.html, a 32-unit box): a chevron and an underscore, round caps, stroke 4 (stackshot's weight);
# the underscore starts at x=18 (the old icon's 17), so that at stroke 4 it does not run into the chevron's lower arm at 16 and 20 px
CHEVRON = [(9, 11), (15, 16), (9, 21)]
UNDERSCORE = [(18, 22), (24, 22)]
STROKE = 4.0
GLYPH_CENTER = (16.5, 16.5)


def draw_icon(size: int, *, rounded: bool, glyph_scale: float, fill: tuple) -> Image.Image:
    s = size * SUPERSAMPLE
    im = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    if rounded:
        d.rounded_rectangle([0, 0, s - 1, s - 1], radius=round(s * 7 / 32), fill=fill)  # the favicon's rx=7 of 32
    else:
        d.rectangle([0, 0, s - 1, s - 1], fill=fill)
    unit = s / 32 * glyph_scale
    cx = cy = s / 2

    def p(x: float, y: float) -> tuple[float, float]:
        return ((x - GLYPH_CENTER[0]) * unit + cx, (y - GLYPH_CENTER[1]) * unit + cy)

    w = STROKE * unit
    for stroke in (CHEVRON, UNDERSCORE):
        pts = [p(*xy) for xy in stroke]
        d.line(pts, fill=GLYPH_COLOR, width=round(w), joint="curve")
        for x, y in (pts[0], pts[-1]):  # round caps
            d.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=GLYPH_COLOR)
    return im.resize((size, size), Image.Resampling.LANCZOS)


def main() -> None:
    fill = ICON_FILL
    OUT.mkdir(parents=True, exist_ok=True)
    icons = {
        "icon-192.png": draw_icon(192, rounded=True, glyph_scale=1.0, fill=fill),
        "icon-512.png": draw_icon(512, rounded=True, glyph_scale=1.0, fill=fill),
        # the safe zone is a centred circle of 80% of the width; the glyph spans about half the width, so a little
        # smaller keeps its corners well inside it
        "icon-512-maskable.png": draw_icon(512, rounded=False, glyph_scale=0.85, fill=fill),
        "apple-touch-icon.png": draw_icon(180, rounded=False, glyph_scale=0.9, fill=fill),
    }
    for name, im in icons.items():
        im.save(OUT / name, format="PNG", optimize=True)
        print(f"{OUT / name}: {im.width}x{im.height}, fill #{fill[0]:02x}{fill[1]:02x}{fill[2]:02x}")


if __name__ == "__main__":
    main()
