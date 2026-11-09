"""The page's look, held in the sources: every stylesheet the page loads, the page itself and app.js.

The look is a type scale, two weights, a 4 px grid, two corner radii and one column width, with the code face on code and terminal rules only
and the icons on stackshot's 24 grid. It is written into `static/` (the stylesheets, `index.html`'s `look` style and `app.js`), so what has to
hold is a property of those files as they are: every font size on the scale, two weights (500 on tags), no letter-spacing, no uppercase, the
monospace face on code and terminal rules only, spacing on the 4 px grid, two corner radii, one column width. A rule written off the scale next
week fails here, in CI, and not on a screen.

Rules of code and of the terminal are exempt from the monospace check only (they keep the face); their sizes still count. Values this test cannot
know (calc(), var(), env(), min(), max(), clamp(), negative offsets, percentages, em and rem) are not counted.

What a wrong answer costs: a size, weight or corner that differs from stackshot's by a pixel (the look drifts apart again), a mono face left on a
label, an icon on the old 20 grid beside the new ones, a second look style or one that lands before a stylesheet (and so loses the cascade), a page
that lost its manifest link or the service worker's registration (the installed app stops being installable).

Pure text: no server, no browser.
"""

from __future__ import annotations

import re

from sala_web.app import STATIC

CSS_FILES = sorted(p.relative_to(STATIC).as_posix() for p in STATIC.glob("*.css"))
SCALE = {12, 13, 15, 17, 22}
FIELD_PX = 16
RULE = re.compile(r"([^{}@]+)\{([^{}]*)\}")
FIELD = re.compile(r"input|textarea|\.cm-|composer|select")
TAGS = re.compile(r"badge|tag|pill|chip|-cat|-lane")
CODE = re.compile(r"\.md code|pre|\.se-x\.code|kbd|terminal|xterm|details\.fold|shell-keys|\.sk-")
NOT_COUNTED = re.compile(r"calc|max\(|min\(|env|var|clamp")


def rules(name: str):
    """(selector, [(property, value)]) of every rule of a stylesheet, comments dropped."""
    text = re.sub(r"/\*.*?\*/", "", (STATIC / name).read_text(encoding="utf-8"), flags=re.S)
    for sel, body in RULE.findall(text):
        decls = []
        for d in body.split(";"):
            if ":" in d:
                prop, _, val = d.partition(":")
                decls.append((prop.strip().lower(), val.strip()))
        yield sel.strip(), decls


def all_decls():
    for name in CSS_FILES:
        for sel, decls in rules(name):
            for prop, val in decls:
                yield name, sel, prop, val


def sheets() -> str:
    return "\n".join((STATIC / n).read_text(encoding="utf-8") for n in CSS_FILES)


def test_there_are_stylesheets_to_check():
    # a glob that finds nothing would pass every check below
    assert {"style.css", "sessions.css", "schedules.css", "machines.css", "search.css"} <= set(CSS_FILES)
    assert sum(1 for _ in all_decls()) > 1000


def test_font_sizes_are_on_the_scale():
    bad = []
    for name, sel, prop, val in all_decls():
        if prop == "font-size":
            sizes = re.findall(r"(?<![\w.-])(\d+(?:\.\d+)?)px", val) if not NOT_COUNTED.search(val) else []
        elif prop == "font":
            m = re.match(r"(?:(?:italic|oblique|normal|bold|\d{3})\s+)*(\d+(?:\.\d+)?)px", val)
            sizes = [m.group(1)] if m else []
        else:
            continue
        for s in sizes:
            n = float(s)
            if not (n in SCALE or (n == FIELD_PX and FIELD.search(sel))):
                bad.append(f"{name}: {sel} {{ {prop}: {val} }}")
    assert not bad, "\n".join(bad)


def test_weights_are_400_and_600_and_500_on_tags():
    bad = []
    for name, sel, prop, val in all_decls():
        if prop == "font-weight":
            ok = {"400", "600"} | ({"500"} if TAGS.search(sel) else set())
            if val.split()[0] not in ok and val not in ("inherit", "normal"):
                bad.append(f"{name}: {sel} {{ font-weight: {val} }}")
    assert not bad, "\n".join(bad)


def test_no_letter_spacing_and_no_uppercase():
    bad = [f"{n}: {s} {{ {p}: {v} }}" for n, s, p, v in all_decls()
           if p == "letter-spacing" or (p == "text-transform" and v == "uppercase")]
    assert not bad, "\n".join(bad)


def test_the_monospace_face_stays_on_code_and_terminal_rules_only():
    bad = []
    for name, sel, prop, val in all_decls():
        if prop in ("font-family", "font") and re.search(r"--mono|monospace|jetbrains|d2coding", val, re.I) and not CODE.search(sel):
            bad.append(f"{name}: {sel} {{ {prop}: {val} }}")
    assert not bad, "\n".join(bad)


def test_no_other_code_face_is_named_and_the_code_face_is_d2coding():
    out = re.sub(r"/\*.*?\*/", "", sheets(), flags=re.S)
    assert not re.search(r"jetbrains", out, re.I)
    # --mono is where the stack is named (style.css), and it leads with the face the page's look style declares
    assert re.search(r'--mono:\s*"D2Coding"', out)
    page = (STATIC / "index.html").read_text(encoding="utf-8")
    assert "jetbrains" not in page.lower()
    assert (STATIC / "fonts" / "D2Coding-Regular.woff2").is_file() and (STATIC / "fonts" / "OFL.txt").is_file()


def test_spacing_is_on_the_4px_grid():
    bad = []
    for name, sel, prop, val in all_decls():
        if re.match(r"(padding|margin|gap|row-gap|column-gap)(-|$)", prop) and not NOT_COUNTED.search(val):
            for m in re.finditer(r"(?<![\w.-])(\d+(?:\.\d+)?)px", val):
                n = float(m.group(1))
                if n > 2 and n % 4:
                    bad.append(f"{name}: {sel} {{ {prop}: {val} }}")
    assert not bad, "\n".join(bad)


def test_corners_are_4px_or_8px_and_a_pill_or_a_hairline_stays():
    bad = []
    for name, sel, prop, val in all_decls():
        if re.search(r"border(-[a-z]+)*-radius$", prop):
            for m in re.finditer(r"(\d+(?:\.\d+)?)px", val):
                n = float(m.group(1))
                if not (n <= 2 or n in (4, 8) or n >= 999):
                    bad.append(f"{name}: {sel} {{ {prop}: {val} }}")
    assert not bad, "\n".join(bad)


def test_one_column_width():
    out = sheets()
    widths = set(re.findall(r"max-width:\s*(820|980|1100)px", out))
    assert not widths, f"column widths that should be 920 px: {sorted(widths)}"
    assert re.search(r"max-width:\s*920px", out), "no column limit at 920 px at all"


# ----------------------------------------------------------------------------- the page and the script

def page() -> str:
    return (STATIC / "index.html").read_text(encoding="utf-8")


def test_the_page_keeps_its_manifest_and_title_and_carries_the_face_and_the_additions_once():
    out = page()
    assert out.count('<link rel="manifest" href="manifest.webmanifest"') == 1
    assert "<title>sala</title>" in out
    assert out.count('id="look"') == 1 and out.count("@font-face") == 1
    assert 'url("static/fonts/D2Coding-Regular.woff2")' in out
    # the additions come after every stylesheet link: same specificity, the later wins
    assert out.rindex('rel="stylesheet"') < out.index('id="look"') < out.index("</head>")
    # the template fields are left for the app to fill
    assert "{{v}}" in out and "{{brand}}" in out


def test_every_inline_icon_of_the_page_is_on_the_24_grid():
    svgs = re.findall(r"<svg.*?</svg>", page(), flags=re.S)
    assert len(svgs) >= 15
    for s in svgs:
        assert 'viewBox="0 0 24 24"' in s, s[:200]
        assert 'stroke-width="2"' in s and 'stroke-linecap="round"' in s, s[:200]
    assert 'viewBox="0 0 20 20"' not in page()


def test_the_script_registers_the_worker_has_no_old_icons_and_checks_at_the_common_stroke():
    src = (STATIC / "app.js").read_text(encoding="utf-8")
    # the installed app stays an installed app: the worker is registered at the site root
    assert re.search(r'if \("serviceWorker" in navigator\) \{', src) and "navigator.serviceWorker.register" in src
    assert "if (false)" not in src and "no service worker of its own" not in src
    assert 'viewBox="0 0 20 20"' not in src
    m = re.search(r"const ICON_CHECK = .*", src)
    assert m and 'stroke-width="2"' in m.group(0) and "2.2" not in m.group(0)
    # the title is sala's own, with no mark in front of it
    assert 'let wantTitle = "sala";' in src
    assert re.search(r"function setTitle\(t\) \{ wantTitle = t; document\.title = t; \}", src)
