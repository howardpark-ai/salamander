"""The v2 design pass (sala_web/v2/design.py) over every stylesheet the page loads, over the page and over app.js.

v2 is a layer: the pass rewrites today's sources at request time, so what has to hold is a property of the OUTPUT, whatever v1 holds
that day: every font size on the type scale, two weights (500 on tags), no letter-spacing, no uppercase, the monospace face on code
and terminal rules only, spacing on the 4 px grid, two corner radii, one column width. The checks read the output of `css()` over
the real files in static/, so a v1 rule written off the scale next week fails here, in CI, and not on a screen; they do not
look at the pass's own tables.

Rules of code and of the terminal are exempt from the monospace check only (they keep the face); their sizes still snap. Values the
pass cannot know (calc(), var(), env(), min(), max(), clamp(), negative offsets, percentages, em and rem) are not counted.

What a wrong answer costs: a size, weight or corner that differs from stackshot's by a pixel (the look drifts apart again), a mono
face left on a label, a stylesheet whose rule the pass cannot read and so leaves as v1 (a half-converted screen), or a pass that
no longer finds its anchor in app.js or the page after v1 changed (a v2 tab that looks like v1, or one that registers a service
worker and so touches the installed app).

Pure text: no server, no browser.
"""

from __future__ import annotations

import re

import pytest

from sala_web.app import STATIC
from sala_web.v2 import design

CSS_FILES = sorted(p.relative_to(STATIC).as_posix() for p in STATIC.glob("*.css"))
SCALE = {12, 13, 15, 17, 22}
FIELD_PX = 16
RULE = re.compile(r"([^{}@]+)\{([^{}]*)\}")
# the same classification as the pass, written out here on purpose: the test must not agree with the pass by sharing its tables
FIELD = re.compile(r"input|textarea|\.cm-|composer|select")
TAGS = re.compile(r"badge|tag|pill|chip|-cat|-lane")
CODE = re.compile(r"\.md code|pre|\.se-x\.code|kbd|terminal|xterm|details\.fold|shell-keys|\.sk-")
NOT_COUNTED = re.compile(r"calc|max\(|min\(|env|var|clamp")


def v2_rules(name: str):
    """(selector, [(property, value)]) of every rule of a stylesheet after the pass, comments dropped."""
    text = re.sub(r"/\*.*?\*/", "", design.css((STATIC / name).read_text(encoding="utf-8")), flags=re.S)
    for sel, body in RULE.findall(text):
        decls = []
        for d in body.split(";"):
            if ":" in d:
                prop, _, val = d.partition(":")
                decls.append((prop.strip().lower(), val.strip()))
        yield sel.strip(), decls


def all_decls():
    for name in CSS_FILES:
        for sel, decls in v2_rules(name):
            for prop, val in decls:
                yield name, sel, prop, val


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


def test_no_other_font_is_named_and_the_code_face_is_d2coding():
    out = "\n".join(design.css((STATIC / n).read_text(encoding="utf-8")) for n in CSS_FILES)
    out = re.sub(r"/\*.*?\*/", "", out, flags=re.S)   # a comment may still tell why (v1's comments are not rewritten)
    assert not re.search(r"jetbrains", out, re.I)
    # --mono is where the stack is named (style.css), and it leads with the face the layer serves
    assert re.search(r'--mono:\s*"D2Coding"', out)


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
    out = "\n".join(design.css((STATIC / n).read_text(encoding="utf-8")) for n in CSS_FILES)
    widths = set(re.findall(r"max-width:\s*(820|980|1100)px", out))
    assert not widths, f"column widths the pass should have made 920 px: {sorted(widths)}"
    assert re.search(r"max-width:\s*920px", out), "no column limit at 920 px at all"


def test_the_pass_leaves_a_rule_it_has_no_reason_to_touch_as_it_was():
    src = ".a { color: red; border: 1px solid #000; width: 33px; font-size: 13px; }\n@media (max-width: 760px) { .b { padding: 8px; } }"
    assert design.css(src) == src


def test_the_pass_does_each_thing_on_a_small_rule():
    out = design.css(".x { font-size: 14px; font-weight: 500; letter-spacing: .04em; text-transform: uppercase; padding: 6px 10px; border-radius: 6px; font-family: var(--mono); }")
    assert "font-size: 15px" in out and "font-weight: 400" in out and "letter-spacing" not in out and "uppercase" not in out
    assert "padding: 8px 8px" in out and "border-radius: 8px" in out and "--mono" not in out
    # a tag keeps 500, a field keeps 16 px, code keeps the monospace face, a shorthand is read too
    assert "font-weight: 500" in design.css(".sp-tag { font-weight: 500; }")
    assert "font-size: 16px" in design.css("input.q { font-size: 16px; }")
    assert "font-family: var(--mono)" in design.css(".md pre { font-family: var(--mono); }")
    assert "font: 12px/1.45 var(--font)" in design.css(".cmd { font: 12.5px/1.45 var(--mono); }")


# ----------------------------------------------------------------------------- the page and the script

def page() -> str:
    return design.html((STATIC / "index.html").read_text(encoding="utf-8"))


def test_every_pass_still_finds_its_anchor_in_the_current_sources(caplog):
    """The sources are v1's and move: a pass whose anchor is gone logs once and leaves that part as v1 had it. Here it is a failure."""
    design._missed.clear()
    with caplog.at_level("WARNING", logger="sala_web.v2"):
        page()
        design.js((STATIC / "app.js").read_text(encoding="utf-8"))
        for n in CSS_FILES:
            design.css((STATIC / n).read_text(encoding="utf-8"))
    assert not design._missed, f"v1 changed under the v2 pass: {sorted(design._missed)}"
    assert not [r for r in caplog.records if r.name == "sala_web.v2"]


def test_page_pass_drops_the_manifest_marks_the_title_and_carries_the_face_and_the_additions_once():
    out = page()
    assert "rel=\"manifest\"" not in out
    assert "<title>v2 · sala</title>" in out
    assert out.count('id="v2-extra"') == 1 and out.count("@font-face") == 1
    assert design.FONT_URL in out and design.EXTRA.strip() in out
    # the additions come after every stylesheet link: same specificity, the later wins
    assert out.rindex('rel="stylesheet"') < out.index('id="v2-extra"') < out.index("</head>")
    assert "jetbrains" not in out.lower()
    # the template fields are left for the app to fill (the same rendering as /)
    assert "{{v}}" in out and "{{brand}}" in out


def test_page_pass_redraws_every_inline_icon_on_the_24_grid():
    out = page()
    svgs = re.findall(r"<svg.*?</svg>", out, flags=re.S)
    assert len(svgs) >= 15
    for s in svgs:
        assert 'viewBox="0 0 24 24"' in s, s[:200]
        assert 'stroke-width="2"' in s and 'stroke-linecap="round"' in s, s[:200]
    # nothing of today's 20 grid is left over
    assert 'viewBox="0 0 20 20"' not in out


def test_script_pass_marks_the_title_has_no_service_worker_and_draws_stackshots_icons():
    src = (STATIC / "app.js").read_text(encoding="utf-8")
    out = design.js(src)
    assert 'let wantTitle = "v2 · sala"' in out
    assert 'wantTitle = "v2 · " + t' in out
    # v1 registers its worker; v2 must not (it would offer a second install and touch the installed app's worker)
    assert 'navigator.serviceWorker.register' in src and 'if (false) {' in out
    assert re.search(r"register\(", out)  # the text of the dead branch stays; it never runs
    assert 'viewBox="0 0 20 20"' not in out
    # sala's checkmark and stackshot's icons share one stroke
    m = re.search(r"const ICON_CHECK = .*", out)
    assert m and 'stroke-width="2"' in m.group(0) and "2.2" not in m.group(0)
    # every other line is v1's: the pass touches the four anchors and nothing else
    changed = [i for i, (a, b) in enumerate(zip(src.splitlines(), out.splitlines())) if a != b]
    assert len(changed) == 4, changed
