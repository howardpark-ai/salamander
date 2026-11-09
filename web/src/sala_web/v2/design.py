"""The v2 design pass: today's stylesheets, page and script rewritten to the v2 look, text in, text out.

v2 is a layer over the live v1 sources, not a copy of them. These functions take a v1 file's text and return the v2 text; the
server (layer.py) runs them on request and caches the result by the source file's mtime, so v1 work that lands while v2 is
being tried flows into /v2 by itself. Nothing here reads or writes a file except `EXTRA`, the stylesheet of additions that
live next to this module.

The pass is the one stackshot's pages go through (a type scale, two weights, a 4 px grid, two radii, sentence case), applied
rule by rule so a rule keeps its own selector and its own declarations:

- font sizes snap to 12, 13, 15, 17 and 22 px (a form field keeps 16 px: below it iOS zooms the page when the field is focused);
- weights are 400 and 600 (500 stays on tags);
- no letter-spacing and no uppercase;
- the monospace face stays on code and terminal rules only (CODE), and is D2Coding where it stays;
- padding, margin and gap snap to the 4 px grid (2 px and under are left alone);
- corner radii are 4 px or 8 px (pills and 2 px stay);
- the three wide-column limits (820, 980 and 1100 px) become one, 920 px;
- sala's own inline icons (html, js) are redrawn on stackshot's 24 grid: 2 px stroke, round ends.

`css()` is the rule pass, `html()` the page pass, `js()` the script pass. A pass that does not find what it expects in the v1
source (v1 changed shape) leaves that part as v1 had it and logs the miss once; test_v2_design.py fails on a miss, so it is seen
in CI and not first on a screen.
"""

from __future__ import annotations

import logging
import re
from pathlib import Path

log = logging.getLogger("sala_web.v2")

HERE = Path(__file__).parent
EXTRA = (HERE / "extra.css").read_text(encoding="utf-8")

# The face is served by the layer next to the static files; the URL is relative so it resolves against /v2/ (the page's own base).
FONT_URL = "static/fonts/D2Coding-Regular.woff2"
FACE = ('@font-face{font-family:"D2Coding";src:url("%s") format("woff2");font-weight:400;font-style:normal;font-display:swap}\n' % FONT_URL)

# What a tab says that it is v2: the page title (and every title the script sets) starts with this.
TITLE_MARK = "v2 · "

SIZES = (12, 13, 15, 17, 22)
SIZE_OF = {10: 12, 11: 12, 12: 12, 13: 13, 14: 15, 15: 15, 16: 15, 18: 17, 20: 22, 22: 22, 24: 22}
FIELD_SIZE = 16     # a form field's size is kept: under 16 px iOS zooms the page in when the field takes focus

# One CSS rule (selector block): optional leading comments, the selector, the declarations. Rules inside an @media block are
# found one by one, since the at-rule's own header cannot start a match ('@' is excluded).
RULE = re.compile(r"((?:\s*/\*(?:(?!\*/).)*\*/)*)([^{}@]+)\{([^{}]*)\}", re.S)   # a comment ends at the first */, never a later one
# Selectors whose rules are code or terminal: they keep the monospace face.
CODE = re.compile(r"\.md code|pre|\.se-x\.code|kbd|terminal|xterm|details\.fold|shell-keys|\.sk-")
# Selectors of form fields: they keep 16 px.
FIELD = re.compile(r"input|textarea|\.cm-|composer|select")
# Selectors of tags: they keep weight 500.
TAG = re.compile(r"badge|tag|pill|chip|-cat|-lane")

_missed: set[str] = set()


def _miss(what: str) -> None:
    """Log a pass that found nothing to change in the v1 source, once per pass and process."""
    if what not in _missed:
        _missed.add(what)
        log.warning("v2 design pass %r found nothing to change in the v1 source; that part is left as v1 has it", what)


def snap_size(n: float) -> int:
    return SIZE_OF.get(int(round(n)), min(SIZES, key=lambda s: abs(s - n)))


def grid(v: float | str) -> float:
    """A length on the 4 px grid; 2 px and under are hairlines and gaps that stay."""
    v = float(v)
    return v if v <= 2 else round(v / 4) * 4


def space(val: str) -> str:
    """A padding / margin / gap value with each plain px length on the grid; a value with calc(), var(), env() and the like is left."""
    if re.search(r"calc|max\(|min\(|env|var|clamp", val):
        return val
    return re.sub(r"(?<![-\d.])(\d+(?:\.\d+)?)px", lambda m: f"{grid(m.group(1)):g}px", val)


def radius(val: str) -> str:
    """A border-radius value: 2 px and under stay, up to 5 px is 4 px, a pill (999+) stays, the rest is 8 px."""
    def one(m: re.Match) -> str:
        n = float(m.group(1))
        if n <= 2 or n >= 999:
            return m.group(0)
        return "4px" if n <= 5 else "8px"
    return re.sub(r"(\d+(?:\.\d+)?)px", one, val)


def declarations(sel: str, dec: str) -> str:
    """One rule's declarations on the v2 scale; `sel` decides what a form field, a tag and code keep."""
    field = bool(FIELD.search(sel))

    def size(m: re.Match) -> str:
        n = float(m.group(1))
        return m.group(0) if field and n == FIELD_SIZE else f"font-size: {snap_size(n)}px"
    dec = re.sub(r"font-size:\s*([\d.]+)px", size, dec)
    dec = re.sub(r"font-size:\s*calc\(16px \* \.85\)", "font-size: 13px", dec)
    # the shorthand `font: [style] [weight] <size>[/<line-height>] <family>`: its size snaps the same way, its family follows the code rule
    dec = re.sub(r"(font:\s*(?:(?:italic|oblique|normal|bold|\d{3})\s+)*)([\d.]+)px",
                 lambda m: m.group(1) + ("16" if field and float(m.group(2)) == FIELD_SIZE else f"{snap_size(float(m.group(2)))}") + "px", dec)
    keep500 = bool(TAG.search(sel))
    weight = lambda n: 600 if n >= 600 else 500 if (n == 500 and keep500) else 400
    dec = re.sub(r"font-weight:\s*(\d+)", lambda m: f"font-weight: {weight(int(m.group(1)))}", dec)
    dec = re.sub(r"font-weight:\s*bold\b", "font-weight: 600", dec)
    dec = re.sub(r"(?:^|;)\s*letter-spacing:[^;]*", "", dec)
    dec = re.sub(r"(?:^|;)\s*text-transform:\s*uppercase", "", dec)
    if not CODE.search(sel):
        dec = re.sub(r"(?:^|;)\s*font-family:\s*var\(--mono[^;]*", "", dec)
        dec = re.sub(r"(font:[^;]*?)var\(--mono\)", r"\1var(--font)", dec)
    dec = re.sub(r"((?:padding|margin|gap|row-gap|column-gap)[a-z-]*:\s*)([^;]+)", lambda m: m.group(1) + space(m.group(2)), dec)
    dec = re.sub(r"(border-[a-z-]*radius:\s*)([^;]+)", lambda m: m.group(1) + radius(m.group(2)), dec)
    return dec.lstrip(";")


def css(text: str) -> str:
    """A v1 stylesheet on the v2 scale (rule by rule), with JetBrains Mono swapped for D2Coding and the wide columns made 920 px."""
    def one(m: re.Match) -> str:
        return f"{m.group(1)}{m.group(2)}{{{declarations(m.group(2).strip(), m.group(3))}}}"
    out = RULE.sub(one, text)
    out = out.replace('"JetBrains Mono Variable"', '"D2Coding"')
    for wide in ("820px", "980px", "1100px"):
        out = out.replace(f"max-width: {wide}", "max-width: 920px")
    return out


# ----------------------------------------------------------------------------- icons

SVG_ATTRS = ('viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" '
             'aria-hidden="true"')
DOTS = "".join(f'<circle cx="{x}" cy="12" r="1.5" fill="currentColor" stroke="none"/>' for x in (5, 12, 19))

# (a piece of today's drawing that names the icon, the drawing on stackshot's 24 grid: 2 px stroke, round ends). Sala has no
# icon of its own that stackshot lacks a shape for: each is drawn from the same set of strokes (circle, rounded rect, chevron, arrow).
ICONS = [
    ("M12.4 12.4l4.1 4.1", '<circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/>'),                                  # search
    ("M10 6.5v7M6.5 10h7", '<circle cx="12" cy="12" r="9"/><path d="M12 8v8M8 12h8"/>'),                                    # new session
    ("M2.8 8h14.4M2.8 12.2h14.4M8 8v8.2", '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 10h18M3 15h18M9 10v10"/>'),  # overview
    ("M7.5 3.8v12.4", '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M9 4v16"/>'),                                # sidebar
    ("M3 5.5h14M5.5 10h9M8 14.5h4", '<path d="M3 6h18M6 12h12M10 18h4"/>'),                                                # unread filter
    ("M16.2 10a6.2 6.2 0 1 1-1.9-4.5", '<path d="M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/>'),  # reload
    ("M6 8l3 2.5L6 13M11 13h3", '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M7 9l3 3-3 3M13 15h4"/>'),       # shell
    ("M7.9 7.9a2.2 2.2 0 1 1 3.1 2", '<circle cx="12" cy="12" r="9"/><path d="M9.5 9.2a2.6 2.6 0 1 1 3.7 2.4c-.8.4-1.2 1-1.2 1.8v.3"/><path d="M12 17h.01"/>'),  # help
    ("M12.5 4.5L7 10l5.5 5.5", '<path d="M15 5l-7 7 7 7"/>'),                                                               # back
    ("M13.5 6.5l-6 6a1.75", '<path d="M16 8l-7 7a2 2 0 0 0 3 3l7.5-7.5a4 4 0 0 0-6-6L6 12a6 6 0 0 0 8.5 8.5l6-6"/>'),     # attach
    ("M10 16V4M5 9l5-5 5 5", '<path d="M12 20V4M6 10l6-6 6 6"/>'),                                                         # send
    ("M5 8l5 5 5-5", '<path d="M6 9l6 6 6-6"/>'),                                                                           # chevron down
    ('cx="4.5" cy="10"', DOTS),                                                                                             # the more menu
]


def _icon(m: re.Match) -> str:
    s = m.group(0)
    w = re.search(r'width="(\d+)"', s)
    for key, new in ICONS:
        if key in s and w:
            return f'<svg width="{w.group(1)}" height="{w.group(1)}" {SVG_ATTRS}>{new}</svg>'
    return s


# ----------------------------------------------------------------------------- the page

def html(doc: str) -> str:
    """The page template (index.html with its {{...}} fields still in it) as v2: icons redrawn, no manifest link (so the browser
    does not offer a second install), a title that says v2, no JetBrains Mono stylesheet (D2Coding replaces it), and the face and
    the additions in a <style> at the end of <head>, after every stylesheet link, so they win the cascade."""
    doc, n = re.subn(r"<svg.*?</svg>", _icon, doc, flags=re.S)
    if not n:
        _miss("html icons")
    doc, n = re.subn(r'<link rel="manifest"[^>]*>\s*', "", doc)
    if not n:
        _miss("html manifest")
    doc, n = re.subn(r"<title>([^<]*)</title>", lambda m: f"<title>{TITLE_MARK}{m.group(1)}</title>", doc, count=1)
    if not n:
        _miss("html title")
    doc, n = re.subn(r'<link rel="stylesheet" href="[^"]*jetbrains-mono[^"]*">\s*', "", doc)
    if not n:
        _miss("html mono font")
    doc, n = re.subn(r"</head>", lambda _m: f'<style id="v2-extra">{FACE}{EXTRA}</style>\n</head>', doc, count=1)
    if not n:
        _miss("html head")
    return doc


# ----------------------------------------------------------------------------- the script

def js(src: str) -> str:
    """app.js as v2: a title that says v2 (setTitle is the one place that writes document.title), the copy
    confirmation's check at the common stroke, and no service worker registration (the installed app's worker is v1's and stays so)."""
    src, n = re.subn(r'let wantTitle = "sala";', f'let wantTitle = "{TITLE_MARK}sala";', src, count=1)
    if not n:
        _miss("js title")
    src, n = re.subn(r"function setTitle\(t\) \{ wantTitle = t; document\.title = t; \}",
                     lambda _m: f'function setTitle(t) {{ wantTitle = "{TITLE_MARK}" + t; document.title = wantTitle; }}', src, count=1)
    if not n:
        _miss("js setTitle")
    src, n = re.subn(r'(const ICON_CHECK = .*?)stroke-width="2\.2"', r'\1stroke-width="2"', src, count=1)
    if not n:
        _miss("js check")
    src, n = re.subn(r'if \("serviceWorker" in navigator\) \{', "if (false) {   // v2: no service worker of its own", src, count=1)
    if not n:
        _miss("js service worker")
    return src
