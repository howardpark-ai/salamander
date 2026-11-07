"""Links in the chat (hyperlinks did not render everywhere).

A reply's markdown goes through marked and DOMPurify (md() in app.js) and its links did render; what showed as plain
text was every text shown verbatim: the owner's own prompt bubble, a message from another session (a notice fold) and
a tool result. linkTokens (shared.js) now makes links out of those. The pure parts run in node like modelLabel does;
the rendered page runs in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else skipped.
"""

from __future__ import annotations

import json
import shutil
import subprocess

import pytest

from conftest import NAME
from sala_web.app import STATIC

NODE = shutil.which("node")
SHARED = (STATIC / "shared.js").read_text()
INDEX = (STATIC / "index.html").read_text()


def run_node(script: str) -> str:
    assert NODE, "node is not installed"
    return subprocess.run([NODE, "-e", script], capture_output=True, text=True, check=True, timeout=30).stdout


@pytest.mark.skipif(not NODE, reason="node is not installed")
def test_link_tokens_makes_links_out_of_verbatim_text():
    cases = [
        "see [board#16](https://board.example.test/items/16) now",
        "bare https://example.com/a/b. end",
        "in parens (https://example.com/p) x",
        "wiki https://en.wikipedia.org/wiki/Foo_(bar) ok",
        "[js](javascript:alert(1)) and javascript:alert(2) and [ftp](ftp://x.y)",
        "<https://example.com/angle>",
        "two https://a.b https://c.d",
        "no links here",
        "",
    ]
    out = json.loads(run_node(SHARED + f"\nconsole.log(JSON.stringify({json.dumps(cases)}.map(linkTokens)));"))
    assert out[0] == [{"text": "see "}, {"href": "https://board.example.test/items/16", "text": "board#16"},
                      {"text": " now"}]
    # a sentence's full stop and an enclosing ")" are not part of a bare URL; a balanced ")" is
    assert out[1] == [{"text": "bare "}, {"href": "https://example.com/a/b", "text": "https://example.com/a/b"},
                      {"text": ". end"}]
    assert out[2] == [{"text": "in parens ("}, {"href": "https://example.com/p", "text": "https://example.com/p"},
                      {"text": ") x"}]
    assert out[3][1]["href"] == "https://en.wikipedia.org/wiki/Foo_(bar)"
    # only http(s) ever becomes a link: a javascript: or ftp: URL, in markdown form or bare, stays text
    assert out[4] == [{"text": cases[4]}]
    assert out[5] == [{"text": "<"}, {"href": "https://example.com/angle", "text": "https://example.com/angle"},
                      {"text": ">"}]
    assert out[6] == [{"text": "two "}, {"href": "https://a.b", "text": "https://a.b"}, {"text": " "},
                      {"href": "https://c.d", "text": "https://c.d"}]
    assert out[7] == [{"text": "no links here"}] and out[8] == []
    # a bare URL's pieces add up to the text: nothing dropped or doubled
    for text, toks in zip(cases, out):
        if "](" not in text:
            assert "".join(t["text"] for t in toks) == text


@pytest.mark.skipif(not NODE, reason="node is not installed")
def test_marked_renders_links_and_autolinks_bare_urls():
    """md() in app.js hands marked gfm+breaks text; the javascript: href marked leaves in is DOMPurify's to drop, which
    the browser test below checks."""
    marked = (STATIC / "vendor" / "marked.min.js").read_text()
    src = ("see [board#16](https://board.example.test/items/16) and https://example.com/a and "
           "www.example.com/x and [js](javascript:alert(1))\nnext line")
    html = run_node(marked + f"\nconsole.log(exports.marked.parse({json.dumps(src)}, {{gfm: true, breaks: true}}));")
    assert '<a href="https://board.example.test/items/16">board#16</a>' in html
    assert '<a href="https://example.com/a">https://example.com/a</a>' in html
    assert '<a href="http://www.example.com/x">www.example.com/x</a>' in html
    assert '<a href="javascript:alert(1)">js</a>' in html  # marked alone does not sanitize: DOMPurify must
    assert "<br>next line" in html  # breaks: a single newline is a line break


def test_vendor_scripts_load_before_the_app():
    # marked and DOMPurify (and shared.js's linkTokens) must be defined before app.js runs
    names = ("vendor/marked.min.js", "vendor/purify.min.js", "static/shared.js", "static/app.js")
    assert [INDEX.index(n) for n in names] == sorted(INDEX.index(n) for n in names)


PROBE = r"""
new Promise((res) => {
  const t0 = Date.now();
  (function poll() {
    if (document.querySelectorAll("#chat > .msg").length < 4 && Date.now() - t0 < 15000) return setTimeout(poll, 100);
    for (const d of document.querySelectorAll("#chat details")) d.open = true;
    document.body.classList.remove("hide-tools");
    const msgs = [...document.querySelectorAll("#chat > .msg")].map((m) => ({
      cls: m.className, textColor: getComputedStyle(m).color,
      raw: (m.textContent.match(/\]\(https?:/g) || []).length,
      links: [...m.querySelectorAll("a")].map((a) => {
        const cs = getComputedStyle(a), r = a.getBoundingClientRect();
        return { href: a.getAttribute("href"), text: a.textContent, target: a.getAttribute("target"),
                 rel: a.getAttribute("rel"), color: cs.color, deco: cs.textDecorationLine, w: r.width, h: r.height };
      }),
    }));
    res({ width: innerWidth, bg: getComputedStyle(document.body).backgroundColor, msgs });
  })();
})
"""


def test_links_render_and_are_tappable_at_390px(served, browser):
    browser.open(f"{served['url']}/#s={NAME}")
    got = browser.evaluate(PROBE)
    assert got["width"] == 390 and got["bg"] == "rgb(22, 22, 23)", got  # a phone's width, the dark theme
    assert len(got["msgs"]) == 4, got["msgs"]
    assert all(m["raw"] == 0 for m in got["msgs"]), "a [label](url) is still plain text somewhere"
    hrefs = lambda m: [a["href"] for a in m["links"]]  # noqa: E731
    # a reply: markdown links, bare URLs, a link in a list, in a table, in bold, an angle autolink
    bubble, reply, notice, tool = got["msgs"]
    assert reply["cls"] == "msg assistant"
    assert hrefs(reply) == ["https://board.example.test/items/16", "https://board.example.test/items/134",
                            "http://www.example.com/x", "https://example.com/list",
                            "https://board.example.test/items/17", "https://example.com/bold", None,
                            "https://example.com/angle"]
    # the javascript: one keeps its text, DOMPurify dropped its href, and it does not look like a link
    js = [a for a in reply["links"] if a["text"] == "javascript link"][0]
    assert js["href"] is None and js["deco"] == "none" and js["color"] == reply["textColor"]
    # the owner's own prompt, a message from another session (a notice) and a tool result: verbatim text, links made
    assert bubble["cls"] == "msg user" and hrefs(bubble) == ["https://board.example.test/items/16", "https://example.com/user"]
    assert bubble["links"][0]["text"] == "board#16"
    assert hrefs(notice) == ["https://board.example.test/items/16", "https://example.com/notice"]
    assert tool["cls"] == "msg user tools-only" and hrefs(tool) == ["https://example.com/tool"]
    for m in got["msgs"]:
        for a in m["links"]:
            if a["href"] is None:
                continue
            assert a["href"].startswith("http"), a
            assert a["target"] == "_blank" and a["rel"] == "noopener noreferrer", a
            # visible on the dark theme and big enough to tap: the accent colour, underlined, a text line tall (the
            # inline box of a fold's 12 px monospace is about 14 px, of a reply's 16 px text about 19 px)
            assert a["color"] != m["textColor"] and "underline" in a["deco"], a
            assert a["h"] >= 12 and a["w"] > 0, a
