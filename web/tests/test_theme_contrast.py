"""The page's palette is stackshot's, and every text colour holds WCAG AA (4.5:1) on the surfaces it sits on, in both themes.

These read style.css and the files that repeat its colours; no browser, no server, no files written. The token blocks are parsed
from the stylesheet itself (the light `:root`, the `prefers-color-scheme: dark` block, and the `data-theme="dark"` block, which
must agree), so a token that goes under 4.5:1 fails here whoever changed it, and the status bar and splash colours cannot drift
from `--bg`.
"""

import colorsys
import json
import re

import pytest

from sala_web.app import STATIC

CSS = (STATIC / "style.css").read_text(encoding="utf-8")
HEX = re.compile(r"^#[0-9a-f]{6}$")


def _block(opening: str) -> dict[str, str]:
    """{token: value} of the declaration block that starts at `opening` in style.css."""
    start = CSS.index(opening) + len(opening)
    body = CSS[start:CSS.index("}", start)]
    return dict(re.findall(r"(--[a-z0-9-]+):\s*([^;]+);", body))


THEMES = {
    "light": _block(":root {"),
    "dark": _block('@media (prefers-color-scheme: dark) {\n  :root:not([data-theme="light"]) {'),
}
DARK_ATTR = _block(':root[data-theme="dark"] {')


def _rgb(h: str) -> tuple[float, float, float]:
    return tuple(int(h[i:i + 2], 16) / 255 for i in (1, 3, 5))


def _lum(h: str) -> float:
    f = lambda c: c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (f(c) for c in _rgb(h))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def ratio(a: str, b: str) -> float:
    hi, lo = sorted((_lum(a), _lum(b)), reverse=True)
    return (hi + 0.05) / (lo + 0.05)


def mix(fg: str, pct: float, under: str) -> str:
    """color-mix(in srgb, fg pct%, transparent) laid over `under` (or mixed with an opaque `under`): the same arithmetic."""
    p = pct / 100
    return "#" + "".join(f"{round((x * p + y * (1 - p)) * 255):02x}" for x, y in zip(_rgb(fg), _rgb(under)))


# text token -> the surfaces it is drawn on (a token name, or a tint made by mix())
SURFACES = ["--bg", "--side-bg", "--panel", "--user-bubble", "--code-bg", "--hover"]
TEXT = {
    "--text": SURFACES + ["--selected", "--error-bg"],
    "--muted": SURFACES + ["--selected"],
    "--faint": SURFACES,           # on a selected row --faint reads as --muted (test below)
    "--link": SURFACES + ["--selected"],      # the orange links; on a selected row too (the tightest light surface, 4.8:1)
    "--accent": SURFACES + ["--selected"],    # the accent as text or a stroke (a hover, a selected tab's word, a ring)
    "--error": ["--bg", "--panel", "--error-bg"],
    "--waiting": ["--bg", "--side-bg", "--panel", "--hover"],
    "--busy": ["--bg", "--side-bg", "--panel", "--hover"],
    "--warn": ["--bg", "--panel"],
    "--call": ["--bg", "--panel"],
    "--state-active": ["--bg", "--side-bg", "--panel", "--hover"],
}
# text on a solid fill
ON_FILL = [("--accent-text", "--accent"), ("--waiting-text", "--waiting")]


def _pairs(theme: str):
    t = THEMES[theme]
    for fg, surfaces in TEXT.items():
        for s in surfaces:
            yield f"{fg} on {s}", t[fg], t[s]
    for fg, bg in ON_FILL:
        yield f"{fg} on {bg}", t[fg], t[bg]
    # a state pill: the colour as text on its own 12% tint over the page or a panel
    for tok in ("--busy", "--waiting", "--state-active", "--call", "--accent"):
        for under in ("--bg", "--panel"):
            yield f"{tok} on its 12% tint over {under}", t[tok], mix(t[tok], 12, t[under])
    # the front badge: text on --call at 12% over the page (at 20% the light orange text measured 4.10:1); the background badge: its violet at 20%
    yield "--role-front-text on --call 12%", t["--role-front-text"], mix(t["--call"], 12, t["--bg"])
    yield "--role-back-text on --role-back 20%", t["--role-back-text"], mix(t["--role-back"], 20, t["--bg"])
    # a search hit's highlight: the page text on --warn at 35%
    for under in ("--bg", "--panel"):
        yield f"--text on the search highlight over {under}", t["--text"], mix(t["--warn"], 35, t[under])


PAIRS = [(theme, name, fg, bg) for theme in THEMES for name, fg, bg in _pairs(theme)]


def test_the_token_blocks_agree_and_are_plain_hex():
    """The dark theme is declared twice (for the system scheme and for the data-theme switch): the same values in both, and every
    colour token a six-digit hex, so these measurements read what the page draws."""
    assert THEMES["dark"] == DARK_ATTR, {k: (THEMES["dark"].get(k), DARK_ATTR.get(k)) for k in set(THEMES["dark"]) | set(DARK_ATTR) if THEMES["dark"].get(k) != DARK_ATTR.get(k)}
    for theme in THEMES:
        for tok, val in THEMES[theme].items():
            if tok in ("--font", "--mono", "color-scheme"):
                continue
            assert HEX.match(val), (theme, tok, val)
    assert set(THEMES["light"]) - {"--font", "--mono"} == set(THEMES["dark"]), "a token the light theme sets is missing in the dark one (or the reverse)"


@pytest.mark.parametrize("theme,name,fg,bg", PAIRS, ids=[f"{t}:{n}" for t, n, _, _ in PAIRS])
def test_text_pair_holds_aa(theme, name, fg, bg):
    assert ratio(fg, bg) >= 4.5, f"{theme}: {name} is {ratio(fg, bg):.2f}:1 ({fg} on {bg})"


# the dark theme's shipped small-label and disabled tokens (the shipped dark look)
_SHIPPED_LOOK = re.findall(r':root\[data-theme="dark"\] \{ (--label-bg:[^}]*)\}', CSS)
SHIPPED_LOOK = dict(re.findall(r"(--[a-z-]+):\s*([^;]+?)\s*(?:;|$)", _SHIPPED_LOOK[0])) if len(_SHIPPED_LOOK) == 1 else {}


def test_the_dark_theme_ships_the_label_and_disabled_pairs_and_they_hold_aa():
    """A small label is the orange on a deep brown fill, #f0a06a on #3a2619, the outline the fill's own color; a disabled solid button is #a3a29d on
    #2a2a2c at full opacity. Each text pair holds AA (4.5:1: 6.76:1 for the label, 5.60:1 for the disabled one), the label text is the app's one orange (the same token
    value as --link), and the label stays a different surface from the page and the card (the fill is not the page)."""
    dark = THEMES["dark"]
    assert SHIPPED_LOOK == {"--label-bg": "#3a2619", "--label-fg": "#f0a06a", "--label-bd": "#3a2619", "--dis-bg": "#2a2a2c", "--dis-fg": "#a3a29d", "--dis-op": "1"}, SHIPPED_LOOK
    assert SHIPPED_LOOK["--label-fg"] == dark["--link"] == dark["--accent"] == dark["--call"] == dark["--role-front-text"]      # the single orange
    assert ratio(SHIPPED_LOOK["--label-fg"], SHIPPED_LOOK["--label-bg"]) >= 4.5, ratio(SHIPPED_LOOK["--label-fg"], SHIPPED_LOOK["--label-bg"])
    assert ratio(SHIPPED_LOOK["--dis-fg"], SHIPPED_LOOK["--dis-bg"]) >= 4.5, ratio(SHIPPED_LOOK["--dis-fg"], SHIPPED_LOOK["--dis-bg"])
    for surface in ("--bg", "--panel"):
        assert SHIPPED_LOOK["--label-bg"] != dark[surface] and SHIPPED_LOOK["--dis-bg"] != dark[surface], surface
    # the light theme sets none of them (it keeps the stylesheets' fallbacks)
    for tok in SHIPPED_LOOK:
        assert tok not in THEMES["light"], tok


def test_the_faint_text_on_a_selected_row_reads_as_muted():
    """--faint holds 4.5:1 on the page surfaces but not on the selected row; a selected row (and a selected group header) makes it --muted."""
    assert re.search(r"\.sess\.selected,\s*\.has-selected\s*\{\s*--faint:\s*var\(--muted\);\s*\}", CSS)
    for theme, t in THEMES.items():
        assert ratio(t["--muted"], t["--selected"]) >= 4.5, theme


def test_the_palette_is_stackshots():
    """The tokens that follow stackshot's: the page, the text, the orange accent and the --call orange (a spot check of the values; the one orange is a step deeper in the light theme, for text contrast)."""
    light, dark = THEMES["light"], THEMES["dark"]
    assert (light["--bg"], light["--text"], light["--accent"], light["--call"], light["--panel"]) == ("#fafaf8", "#1a1918", "#ad4608", "#ad4608", "#ffffff")
    assert (dark["--bg"], dark["--text"], dark["--accent"], dark["--call"], dark["--panel"]) == ("#161617", "#ececea", "#f0a06a", "#f0a06a", "#1f1f21")


def test_the_accent_and_the_links_are_the_icons_orange():
    """The accent and the links are one orange (#ad4608 light, #f0a06a dark, the same orange as the app icons), the text on an accent fill is white on the
    light one and the panel's dark on the dark one."""
    light, dark = THEMES["light"], THEMES["dark"]
    assert (light["--accent"], light["--link"], light["--accent-text"]) == ("#ad4608", "#ad4608", "#ffffff")
    assert (dark["--accent"], dark["--link"], dark["--accent-text"]) == ("#f0a06a", "#f0a06a", "#1f1f21")
    assert "html { accent-color: var(--accent); }" in CSS      # the native radios of the New session form are not the browser's blue


def test_front_and_metered_use_call_and_never_the_accent():
    """The front badge and the metered lane use --call, never the accent token (both are the one orange now, so the token alone tells them apart in the CSS);
    the Ultra lane's blue is untouched."""
    front = CSS.split("#top .pill.role-front {", 1)[1].split("}", 1)[0]
    assert "var(--call)" in front and "var(--accent)" not in front
    assert re.search(r"\.lane-api\s*\{\s*--lane:\s*var\(--call\);\s*\}", CSS)
    assert "#search-pane .se-role.front" in (STATIC / "search.css").read_text(encoding="utf-8")
    # the badge's tint is the fill side of the orange: the solid orange when one is set (the color tool), else --call
    assert "var(--accent-solid, var(--call)) 12%" in (STATIC / "search.css").read_text(encoding="utf-8").split("#search-pane .se-role.front", 1)[1].split("}", 1)[0]
    for theme, t in THEMES.items():
        assert t["--call"] != t["--lane-subscription-1"], theme


def test_the_status_bar_and_splash_colours_are_the_page_background():
    """index.html's two theme-color metas are each theme's --bg, and the manifest's one background_color and theme_color are the dark
    theme's (a manifest has no variant per colour scheme; a light splash was a light strip behind the dark app)."""
    html = (STATIC / "index.html").read_text(encoding="utf-8")
    assert f'<meta name="theme-color" content="{THEMES["light"]["--bg"]}" media="(prefers-color-scheme: light)">' in html
    assert f'<meta name="theme-color" content="{THEMES["dark"]["--bg"]}" media="(prefers-color-scheme: dark)">' in html
    assert html.count('name="theme-color"') == 2
    m = json.loads((STATIC / "manifest.webmanifest").read_text(encoding="utf-8"))
    assert m["background_color"] == THEMES["dark"]["--bg"] and m["theme_color"] == THEMES["dark"]["--bg"]


def test_no_file_repeats_a_colour_of_the_old_palette():
    """The warm greys and the orange accent of the old palette are gone from the page's files, the tab icons included (the PNG icons are images)."""
    old = ["#faf9f5", "#262624", "#c96442", "#d97757", "#f3f1ea", "#1f1e1d", "#30302e", "#29261b", "#ece9e1", "#e3e0d4", "#3d3c38"]
    for f in STATIC.iterdir():
        if f.suffix not in (".css", ".html", ".webmanifest", ".js") or f.name == "timing-debug.js":
            continue
        text = f.read_text(encoding="utf-8").lower()
        for c in old:
            assert c not in text, (f.name, c)
            assert "%23" + c[1:] not in text, (f.name, c, "as it is written inside a data URI")   # the old tab icon's form


def test_the_tab_icons_are_stackshots_tile_and_orange():
    """index.html and terminal.html each carry the inline tab icon once: stackshot's dark tile (#1f1f21) with an orange (#f0a06a) stroke."""
    for name in ("index.html", "terminal.html"):
        text = (STATIC / name).read_text(encoding="utf-8")
        assert text.count("rel='icon'") + text.count('rel="icon"') == 1, name
        icon = re.search(r'<link rel="icon" href="(data:image/svg\+xml,[^"]+)">', text).group(1)
        assert "fill='%231f1f21'" in icon, name         # the tile
        assert "stroke='%23f0a06a'" in icon, name       # the glyph
        assert "stroke='white'" not in icon, name


# --- one orange in the whole app: no other orange left in any page file ---------------------------------------------------

V2 = STATIC.parent / "v2"
TOOLS = STATIC.parent.parent.parent / "tools"
ORANGES = {"#ad4608", "#f0a06a"}             # the light theme's orange, the dark theme's (which is also the app icons' own)
ICON_ORANGE = "#f0a06a"                      # the app icons' own colour: the same value as the dark theme's orange, set in the inline tab icons and in make_icons.py
# static/colortool.js is the pinned shared source of stackshot's color tool: its presets hold their own hex values (oranges on purpose). This one
# file, by name, is skipped by the orange scans; no other file is. (sala's own wiring, colortool-sala.js, is scanned like any page file.)
PINNED_COLORTOOL = "colortool.js"
PINNED_REASON = "pinned shared source of stackshot's color tool: its presets hold their own hex values"
# amber and yellow colours in the orange band that stay, each by name (a status or a lane identity, not the accent)
AMBER_ALLOWED = {
    "#a16207": "--lane-aws-platform in the light theme: a lane's identity colour, an amber, not the accent",
}
_COLOUR = re.compile(
    r"(?:#|%23)([0-9a-fA-F]{6}|[0-9a-fA-F]{3})(?![0-9a-zA-Z])"
    r"|rgba?\(\s*(\d+)\s*[, ]\s*(\d+)\s*[, ]\s*(\d+)"
    r"|hsla?\(\s*(\d+(?:\.\d+)?)(?:deg)?\s*[, ]\s*(\d+(?:\.\d+)?)%\s*[, ]\s*(\d+(?:\.\d+)?)%")
_ICON_LINK = re.compile(r'<link rel="icon" href="data:image/svg\+xml,[^"]+">')


def _page_files():
    for d in (STATIC, V2):
        for f in sorted(d.iterdir()):
            if f.suffix in (".css", ".html", ".js", ".py") and f.name != "timing-debug.js":
                yield f


def _oranges_in(text: str):
    """(as written, normalised #rrggbb) of every colour in `text` whose hue is 15 to 40 degrees with a saturation above 40%."""
    for m in _COLOUR.finditer(text):
        if m.group(1):
            h = m.group(1)
            h = h if len(h) == 6 else "".join(c * 2 for c in h)
            r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
            hue, _, sat = colorsys.rgb_to_hls(r, g, b)
            hue *= 360
        elif m.group(2):
            r, g, b = (int(x) / 255 for x in m.group(2, 3, 4))
            hue, _, sat = colorsys.rgb_to_hls(r, g, b)
            hue *= 360
        else:
            hue, sat = float(m.group(5)) % 360, float(m.group(6)) / 100
            r, g, b = colorsys.hls_to_rgb(hue / 360, float(m.group(7)) / 100, sat)
        if 15 <= hue <= 40 and sat > 0.4:
            yield m.group(0), "#" + "".join(f"{round(c * 255):02x}" for c in (r, g, b))


def test_every_orange_in_the_page_files_is_one_of_the_two_oranges():
    """The app has one orange, #ad4608 in the light theme and #f0a06a in the dark one (--accent, --link, --call, --role-front-text). Any other
    colour in the orange band (hue 15 to 40 degrees, saturation above 40%) in a page file, the former dark #ec8a47 and #a34a14 included, fails here,
    unless it is an amber listed by name in AMBER_ALLOWED. The inline tab icons are left out of this scan: they carry the icons' own orange, which is the same #f0a06a (checked by the next test)."""
    seen = set()
    for f in _page_files():
        if f.name == PINNED_COLORTOOL:
            continue
        text = _ICON_LINK.sub("", f.read_text(encoding="utf-8"))
        for written, norm in _oranges_in(text):
            seen.add(norm)
            assert norm in ORANGES or norm in AMBER_ALLOWED, (f.name, written, "is an orange that is not the app's orange")
    assert ORANGES <= seen, "the page files no longer carry both oranges"
    assert set(AMBER_ALLOWED) <= seen, "an allow-listed amber is no longer used: drop it from AMBER_ALLOWED"


def test_the_icons_orange_is_the_dark_themes_orange():
    """#f0a06a is the app icons' colour (the two inline tab icons and make_icons.py) and is also the dark theme's orange, so the icons and the dark page
    share one value; the page files carry it as the dark theme's orange (the scan above allows nothing else in the band besides #ad4608)."""
    icons = 0
    for name in ("index.html", "terminal.html"):
        found = _ICON_LINK.findall((STATIC / name).read_text(encoding="utf-8"))
        icons += len(found)
        assert any(n == ICON_ORANGE for _, n in _oranges_in("".join(found))), name
    assert icons == 2
    assert ICON_ORANGE in (TOOLS / "make_icons.py").read_text(encoding="utf-8").lower()
    assert THEMES["dark"]["--accent"] == ICON_ORANGE and THEMES["dark"]["--link"] == ICON_ORANGE
    assert THEMES["light"]["--accent"] != ICON_ORANGE          # the light theme keeps its deeper orange (the icon's holds only 2.0:1 on the light page)
    assert ICON_ORANGE in (STATIC / "style.css").read_text(encoding="utf-8").lower()


def test_the_orange_scan_catches_a_stray_orange():
    """The scan itself: it finds stray oranges in hex, rgb and hsl forms, a 3-digit hex and a data-URI form (the former dark orange #ec8a47 among them), and passes the two oranges and a blue."""
    found = [n for _, n in _oranges_in("a{color:#ec8a47;b:#A34A14;c:rgb(236 138 71);d:hsl(24 80% 60%);e:#e82;f:%23c96442}")]
    assert len(found) == 6
    assert not list(_oranges_in("a{color:#1f5bc4;b:#e3b341;c:#ececea}"))
    assert [n for _, n in _oranges_in("a{color:#ad4608;b:#f0a06a}")] == ["#ad4608", "#f0a06a"]
