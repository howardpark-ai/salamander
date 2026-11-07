"""Install as an app: the manifest at the root, the service worker at the root (network-only, never a cache), the
icons, the page's links, and the routes around them left as they were."""

import json
import re
import struct
import zlib

import pytest
from starlette.testclient import TestClient

from sala_web.app import STATIC, create_app
from sala_web.config import Settings

MAKE_ICONS = STATIC.parent.parent.parent / "tools" / "make_icons.py"

HEX_COLOR = re.compile(r"^#[0-9a-f]{6}$")


@pytest.fixture
def client(tmp_path):
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    (claude / "projects").mkdir()
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                        tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"])
    return TestClient(create_app(settings))


def png_size(data: bytes) -> tuple[int, int]:
    """The width and height in a PNG's IHDR chunk; fails on anything that is not a PNG."""
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    assert data[12:16] == b"IHDR"
    return struct.unpack(">II", data[16:24])


def manifest_of(client: TestClient) -> dict:
    r = client.get("/manifest.webmanifest")
    assert r.status_code == 200
    return json.loads(r.text)


def test_manifest_is_served_at_the_root_as_a_manifest(client):
    r = client.get("/manifest.webmanifest")
    assert r.status_code == 200
    assert r.headers["content-type"].split(";")[0].strip() == "application/manifest+json"
    assert r.headers["cache-control"] == "no-cache"
    m = json.loads(r.text)
    # what Chrome asks of an installable app: a name, a short name, a start URL inside the scope, standalone, icons
    assert m["name"] == "sala" and m["short_name"] == "sala"  # the app's name, not the package's
    assert m["start_url"] == "./" and m["scope"] == "./"  # relative: the site root, whatever host serves it
    assert m["display"] == "standalone"
    assert HEX_COLOR.match(m["background_color"]) and HEX_COLOR.match(m["theme_color"])
    assert m["icons"], "no icons"


def theme_bgs() -> dict:
    """{"light", "dark"}: --bg of each theme in style.css (the :root block, then the data-theme="dark" block, which
    must agree with the prefers-color-scheme: dark one)."""
    css = (STATIC / "style.css").read_text()
    light = re.search(r":root\s*\{[^}]*?--bg:\s*(#[0-9a-f]{6})", css).group(1)
    dark = re.search(r':root\[data-theme="dark"\]\s*\{[^}]*?--bg:\s*(#[0-9a-f]{6})', css).group(1)
    system_dark = re.search(r'prefers-color-scheme: dark\)\s*\{\s*:root:not\(\[data-theme="light"\]\)\s*\{[^}]*?--bg:\s*(#[0-9a-f]{6})', css).group(1)
    assert dark == system_dark and light != dark
    return {"light": light, "dark": dark}


def hex_rgb(h: str) -> str:
    return f"rgb({int(h[1:3], 16)}, {int(h[3:5], 16)}, {int(h[5:7], 16)})"


def test_manifest_colors_are_the_dark_themes_page_background():
    # A manifest carries one theme_color and one background_color, with no variant per colour scheme (Chrome has
    # none); they show on the launch splash screen and until the page's own theme-color meta applies. They are the
    # dark theme's --bg: a light splash was the same light strip (after
    # the light bars fixed by the metas). Once the page loads, each scheme's bars come from the two theme-color metas
    # in index.html (test below), so a light-scheme device still gets light bars.
    bg = theme_bgs()
    m = json.loads((STATIC / "manifest.webmanifest").read_text())
    assert m["background_color"] == bg["dark"] and m["theme_color"] == bg["dark"]


def test_index_covers_the_whole_screen_in_the_themes_colours(client):
    """The installed app (standalone: no browser bar) showed light bars above and below a dark page (on Android a white strip
    showed at the bottom): the status bar and the strip behind the gesture bar take the
    theme-color meta, which was the light page colour whatever the theme."""
    html = client.get("/").text
    bg = theme_bgs()
    assert f'<meta name="theme-color" content="{bg["light"]}" media="(prefers-color-scheme: light)">' in html
    assert f'<meta name="theme-color" content="{bg["dark"]}" media="(prefers-color-scheme: dark)">' in html
    assert html.count('name="theme-color"') == 2
    assert '<meta name="color-scheme" content="light dark">' in html  # the canvas is dark before the stylesheet lands
    vp = re.search(r'<meta name="viewport" content="([^"]+)">', html).group(1)
    assert {"width=device-width", "initial-scale=1", "viewport-fit=cover", "interactive-widget=resizes-content"} <= {p.strip() for p in vp.split(",")}
    css = (STATIC / "style.css").read_text()
    # the canvas (behind an overscroll, under the gesture bar) is the page colour, and what reaches an edge pads the inset
    assert re.search(r"html,\s*body\s*\{[^}]*background:\s*var\(--bg\)", css)
    assert re.search(r"#composer\s*\{[^}]*env\(safe-area-inset-bottom\)", css)
    assert re.search(r"#sidebar\s*\{[^}]*env\(safe-area-inset-top\)", css) and re.search(r"#sidebar\s*\{[^}]*env\(safe-area-inset-bottom\)", css)
    assert re.search(r"#main\s*\{[^}]*env\(safe-area-inset-top\)", css)


PAGE_COLOURS = """(() => ({
  html: getComputedStyle(document.documentElement).backgroundColor, body: getComputedStyle(document.body).backgroundColor,
  dark: matchMedia("(prefers-color-scheme: dark)").matches, scheme: getComputedStyle(document.documentElement).colorScheme,
  themeColor: [...document.querySelectorAll('meta[name="theme-color"]')].filter((m) => matchMedia(m.media).matches).map((m) => m.content) }))()"""


def test_page_canvas_and_theme_color_follow_the_scheme_in_the_browser(served, browser):
    from conftest import NAME
    from test_composer_attach import WAIT_READY
    bg = theme_bgs()
    for dark in (True, False):
        browser.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": "dark" if dark else "light"}]})
        browser.open(f"{served['url']}/#s={NAME}", dark=dark)
        assert browser.evaluate(WAIT_READY)
        got = browser.evaluate(PAGE_COLOURS)
        want = bg["dark" if dark else "light"]
        assert got["dark"] == dark and got["scheme"] == ("dark" if dark else "light"), got
        assert got["html"] == hex_rgb(want) and got["body"] == hex_rgb(want), got
        assert got["themeColor"] == [want], got  # exactly one meta applies, the scheme's own


PADS = """(() => { const p = (s, k) => parseFloat(getComputedStyle(document.querySelector(s))[k]);
  return { composer: p("#composer", "paddingBottom"), sideBottom: p("#sidebar", "paddingBottom"), sideTop: p("#sidebar", "paddingTop"),
           mainTop: p("#main", "paddingTop"), rowBottom: document.querySelector(".compose-row").getBoundingClientRect().bottom, h: innerHeight }; })()"""


def test_safe_area_insets_pad_what_reaches_the_screens_edges(served, browser):
    from conftest import NAME
    from test_composer_attach import WAIT_READY
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate(WAIT_READY)
    before = browser.evaluate(PADS)
    try:  # a phone with a 24 px status bar and a 34 px gesture bar
        browser.send("Emulation.setSafeAreaInsetsOverride", {"insets": {"top": 24, "bottom": 34, "left": 0, "right": 0}})
    except RuntimeError as e:
        pytest.skip(f"this Chromium cannot emulate safe-area insets: {e}")
    after = browser.evaluate(PADS)
    assert after["composer"] == before["composer"] + 34 and after["sideBottom"] == before["sideBottom"] + 34, (before, after)
    assert after["sideTop"] == before["sideTop"] + 24 and after["mainTop"] == before["mainTop"] + 24, (before, after)
    assert after["rowBottom"] <= after["h"] - 34, after  # the composer's row ends above the gesture bar


def test_icons_exist_serve_as_png_and_match_their_stated_sizes(client):
    m = manifest_of(client)
    seen = {}
    for icon in m["icons"]:
        src = icon["src"]
        assert not src.startswith("/") and "://" not in src, f"icon src must be relative: {src}"
        assert icon["type"] == "image/png"
        r = client.get("/" + src)  # relative to the manifest's URL, the root
        assert r.status_code == 200, src
        assert r.headers["content-type"] == "image/png"
        w, h = png_size(r.content)
        assert f"{w}x{h}" == icon["sizes"], f"{src}: {w}x{h} is not the stated {icon['sizes']}"
        assert (STATIC / src.removeprefix("static/")).is_file()
        seen.setdefault(icon.get("purpose", "any"), set()).add(icon["sizes"])
    assert {"192x192", "512x512"} <= seen["any"], seen  # Chrome's minimum for the install prompt
    assert "512x512" in seen["maskable"], seen  # the launcher's own shape (Android), without a border of its own


def test_service_worker_is_served_at_the_root_as_javascript_and_never_caches(client):
    r = client.get("/sw.js")
    assert r.status_code == 200
    assert r.headers["content-type"].split(";")[0].strip() in ("text/javascript", "application/javascript")
    assert r.headers["cache-control"] == "no-cache"
    src = r.text
    assert src == (STATIC / "sw.js").read_text()
    assert "caches." not in src and "caches.open" not in src and "CacheStorage" not in src  # network only
    assert "skipWaiting" in src and "clients.claim" in src


def test_service_worker_has_no_fetch_handler_but_still_installs_and_takes_over(client):
    # An earlier worker passed every request through with fetch(req); once sala also resolved to a private-network address,
    # Chrome's private-network rules blocked that fetch in an app installed over the public address (ERR_FAILED). The
    # worker must not intercept requests at all. Comments are stripped first: the file's own text explains the absence.
    code = "\n".join(line for line in client.get("/sw.js").text.splitlines() if not line.lstrip().startswith("//"))
    assert not re.search(r"""addEventListener\(\s*["']fetch["']|\bonfetch\b|\bFetchEvent\b""", code), code
    assert "respondWith" not in code
    # install and activate stay, so the new bytes replace the old worker and take over every open client at once
    assert re.search(r"""addEventListener\(\s*["']install["'][^;]*skipWaiting\(\)""", code), code
    assert re.search(r"""addEventListener\(\s*["']activate["'][^;]*clients\.claim\(\)""", code), code


def test_index_links_the_manifest_with_credentials_the_theme_color_and_the_apple_icon(client):
    html = client.get("/").text
    assert '<link rel="manifest" href="manifest.webmanifest" crossorigin="use-credentials">' in html
    m = manifest_of(client)
    assert f'<meta name="theme-color" content="{m["theme_color"]}" media="(prefers-color-scheme: dark)">' in html
    apple = re.search(r'<link rel="apple-touch-icon" href="([^"]+)">', html)
    assert apple and not apple.group(1).startswith("/")
    r = client.get("/" + apple.group(1))
    assert r.status_code == 200 and r.headers["content-type"] == "image/png"
    assert png_size(r.content) == (180, 180)
    # the page registers the worker from its own directory, so the scope is the root the page is served from
    js = (STATIC / "app.js").read_text()
    assert 'navigator.serviceWorker.register("sw.js")' in js and '"serviceWorker" in navigator' in js


def test_the_routes_around_them_are_unchanged(client):
    assert client.post("/manifest.webmanifest").status_code == 405
    assert client.post("/sw.js").status_code == 405
    r = client.get("/sessions", follow_redirects=False)
    assert r.status_code == 302 and r.headers["location"] == "./#sessions"
    r = client.get("/?arg=demo", follow_redirects=False)
    assert r.status_code == 302 and r.headers["location"] == "/terminal?arg=demo"
    assert client.get("/api/config").status_code == 200
    assert client.get("/static/style.css").headers["cache-control"] == "no-cache"
    assert client.get("/static/icons/nope.png").status_code == 404


# --- the icons are stackshot's recipe: its dark tile, its orange stroke, sala's >_ glyph ---------------------------------

def png_pixels(data: bytes) -> tuple[int, int, list[bytes]]:
    """(width, height, rows of RGBA bytes) of an 8-bit RGBA, non-interlaced PNG, decoded with the standard library only
    (Pillow is not a dependency of the app or its tests)."""
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, idat, w, h = 8, b"", 0, 0
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            assert (depth, ctype, interlace) == (8, 6, 0), "expected 8-bit RGBA, not interlaced"
        elif kind == b"IDAT":
            idat += body
        pos += 12 + n
    raw, stride, rows, prev = zlib.decompress(idat), w * 4, [], bytearray(w * 4)
    for y in range(h):
        ft, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - 4] if i >= 4 else 0
            b = prev[i]
            c = prev[i - 4] if i >= 4 else 0
            if ft == 1:
                line[i] = (line[i] + a) & 255
            elif ft == 2:
                line[i] = (line[i] + b) & 255
            elif ft == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif ft == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(line))
        prev = line
    return w, h, rows


def px(rows: list[bytes], x: int, y: int) -> tuple[int, int, int, int]:
    return tuple(rows[y][x * 4:x * 4 + 4])


def icon_colours() -> tuple[str, str]:
    """(tile, glyph) colours as #rrggbb, read from the constants of tools/make_icons.py."""
    src = MAKE_ICONS.read_text(encoding="utf-8")
    out = []
    for name in ("ICON_FILL", "GLYPH_COLOR"):
        r, g, b, a = map(int, re.search(rf"^{name} = \((\d+), (\d+), (\d+), (\d+)\)", src, re.M).groups())
        assert a == 255
        out.append(f"#{r:02x}{g:02x}{b:02x}")
    return out[0], out[1]


def test_the_generator_holds_stackshots_tile_and_orange():
    assert icon_colours() == ("#1f1f21", "#f0a06a")


@pytest.mark.parametrize("name,size,full_bleed", [
    ("icon-192.png", 192, False), ("icon-512.png", 512, False),
    ("icon-512-maskable.png", 512, True), ("apple-touch-icon.png", 180, True),
])
def test_each_icon_is_the_dark_tile_with_an_orange_glyph(name, size, full_bleed):
    tile, glyph = (tuple(int(c[i:i + 2], 16) for i in (1, 3, 5)) for c in icon_colours())
    w, h, rows = png_pixels((STATIC / "icons" / name).read_bytes())
    assert (w, h) == (size, size)
    corners = [px(rows, x, y) for x, y in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1))]
    if full_bleed:
        assert all(c == (*tile, 255) for c in corners), corners   # opaque to the edge: the launcher cuts its own shape
    else:
        assert all(c[3] == 0 for c in corners), corners           # rounded: transparent outside the corners
    assert px(rows, w // 2, h // 12 + 6) == (*tile, 255)         # an interior pixel above the glyph is the tile
    near = [p for row in rows for p in (row[i:i + 4] for i in range(0, len(row), 4))
            if p[3] == 255 and all(abs(p[k] - glyph[k]) <= 6 for k in range(3))]
    assert len(near) > size * size // 40, "no glyph pixels in #f0a06a"   # a heavy glyph: a few percent of the tile at least


def test_the_inline_tab_icons_use_the_generators_colours():
    tile, glyph = icon_colours()
    for name in ("index.html", "terminal.html"):
        html = (STATIC / name).read_text(encoding="utf-8")
        assert f"fill='%23{tile[1:]}'" in html and f"stroke='%23{glyph[1:]}'" in html, name
    # the stroke weight too: 4 of 32 in both the favicon and the generator
    assert re.search(r"^STROKE = 4\.0$", MAKE_ICONS.read_text(encoding="utf-8"), re.M)
    assert "stroke-width='4'" in (STATIC / "index.html").read_text(encoding="utf-8")
