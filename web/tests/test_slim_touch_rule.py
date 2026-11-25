"""The slim touch control is one rule in style.css, and no page copies it (pure text, no browser).

A button in a one-line row (the composer's Send, the update strip's Reload) is drawn 30 px under a finger with a 44 px tap area that
takes no room: an `::after` box with `inset: -7px`. That was written twice in index.html's own `look` style and left a second page (since retired) with a
tall Send of its own; Reload had got its own copy before. The style guide (web/README.md, *The slim touch control*) says it is
fixed once: the class `.slim-touch` in style.css, which every page loads.

Held here, from the files:
- `style.css` holds the rule exactly once: one `.slim-touch` rule under `(pointer: coarse)` that sets `--ctl` to 30 px and one `.slim-touch::after`
  with `inset: -7px`; and `inset: -7px` appears nowhere else under static/;
- `index.html` holds no `inset: -7px` copy and no phone-size rule of its own for Send or Reload;
- the buttons take the class: `#send` and `#reload-btn` in index.html;
- every page of static/ that has a Send or Reload button (it names `send-btn` or `reload-btn`, or loads a script that builds one) loads style.css.

Wrong answers it catches: a second copy of the rule in a page's style, a page with a Send that does not load style.css, a button without the class.
"""

from __future__ import annotations

import re

from sala_web.app import STATIC

COARSE = re.compile(r"@media\s*\(\s*pointer:\s*coarse\s*\)\s*\{")


def text(name: str) -> str:
    return (STATIC / name).read_text(encoding="utf-8")


def without_comments(s: str) -> str:
    return re.sub(r"/\*.*?\*/", "", s, flags=re.S)


def coarse_blocks(css: str) -> list[str]:
    """The text inside each `@media (pointer: coarse) { ... }` of a stylesheet (braces matched), comments dropped."""
    css, out = without_comments(css), []
    for m in COARSE.finditer(css):
        depth, i = 1, m.end()
        while depth and i < len(css):
            depth += {"{": 1, "}": -1}.get(css[i], 0)
            i += 1
        out.append(css[m.end():i - 1])
    return out


def test_the_rule_is_in_style_css_once():
    css = without_comments(text("style.css"))
    assert len(re.findall(r"\.slim-touch\s*\{", css)) == 1, "one .slim-touch rule in style.css"
    assert len(re.findall(r"\.slim-touch::after\s*\{", css)) == 1, "one .slim-touch::after rule in style.css"
    # the two rules sit together in one coarse block
    m = re.search(r"@media\s*\(\s*pointer:\s*coarse\s*\)\s*\{\s*(\.slim-touch\s*\{[^{}]*\})\s*(\.slim-touch::after\s*\{[^{}]*\})\s*\}", css)
    assert m, "the .slim-touch pair is one (pointer: coarse) block"
    body, after = m.group(1), m.group(2)
    assert re.search(r"--ctl:\s*30px", body) and re.search(r"position:\s*relative", body), body
    assert re.search(r"content:\s*\"\"", after) and re.search(r"position:\s*absolute", after) and re.search(r"inset:\s*-7px\s*;", after), after


def test_no_other_file_copies_the_tap_area():
    assert len(re.findall(r"inset:\s*-7px", text("style.css"))) == 1, "style.css holds the tap-area box once"
    for p in sorted(STATIC.iterdir()):
        if p.suffix in {".css", ".html", ".js"} and p.name != "style.css":
            assert not re.search(r"inset:\s*-7px", p.read_text(encoding="utf-8")), f"{p.name} holds a copy of the tap-area rule"


def test_index_has_no_phone_size_for_send_or_reload():
    for block in coarse_blocks(text("index.html")):
        assert ".send-btn" not in block and "#reload-btn" not in block, f"index.html sizes Send or Reload under a finger: {block[:160]}"


def test_the_buttons_take_the_class():
    index = text("index.html")
    for ident in ("send", "reload-btn"):
        tag = re.search(r'<button\b[^>]*\bid="%s"[^>]*>' % ident, index)
        assert tag and re.search(r'class="[^"]*\bslim-touch\b', tag.group(0)), f"#{ident} takes .slim-touch"


def test_every_page_with_a_send_or_reload_button_loads_style_css():
    pages = sorted(STATIC.glob("*.html"))
    assert pages, "no pages under static/"
    checked = []
    for p in pages:
        html = p.read_text(encoding="utf-8")
        # the color tool's scripts draw inert sample buttons in its own preview (its own styles), not a page's button
        scripts = [text(js) for js in re.findall(r'<script[^>]+src="static/([\w.-]+\.js)', html) if (STATIC / js).exists() and not js.startswith("colortool")]
        has_button = "send-btn" in html or "reload-btn" in html or any("send-btn" in s or "reload-btn" in s for s in scripts)
        if has_button:
            checked.append(p.name)
            assert re.search(r'<link[^>]+rel="stylesheet"[^>]+href="static/style\.css', html), f"{p.name} has a Send or Reload button and does not load style.css"
    assert "index.html" in checked, checked


def test_the_retired_chat_page_left_no_sheet_script_or_page_behind():
    """/chat is a redirect now: the first page's own files are gone, so no second Send (its own rule, its own arrow) can come back with them."""
    for name in ("chat.html", "chat.js", "chat.css"):
        assert not (STATIC / name).exists(), name


def test_the_control_size_is_defined_for_every_page_in_style_css():
    css = without_comments(text("style.css"))
    assert re.search(r":root\s*\{\s*--ctl:\s*32px;\s*\}", css) and re.search(r"@media\s*\(\s*pointer:\s*coarse\s*\)\s*\{\s*:root\s*\{\s*--ctl:\s*44px;", css)
    assert "--ctl: 32px" not in without_comments(text("index.html")), "index.html does not define --ctl a second time"
