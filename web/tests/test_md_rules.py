"""What a reply's markdown may do (MD_PURIFY, mdAttr, mdStyle and mdTaskBox in static/shared.js; mdSanitize in app.js).

A reply keeps what the sanitizer keeps by default, drawings, video, audio, formulas and its own inline style included; its
box holds what it paints (.md in style.css). What goes is what no box holds, what acts, and what would answer to a name of
the page's: style sheets, forms and controls, dialogs and popover openers, classes and data-* attributes; every id, name
and pointer at one gets the reply's own prefix. Here the rules run in node, on the vendored marked's own output for every
markdown feature (CORPUS) and on the vendored DOMPurify's file and recipe; test_md_rules_ui.py tries the rules in the page.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
from html.parser import HTMLParser

import pytest

from sala_web.app import STATIC

NODE = shutil.which("node")
SHARED = (STATIC / "shared.js").read_text()
APP = (STATIC / "app.js").read_text()
STYLE = (STATIC / "style.css").read_text()
MARKED = (STATIC / "vendor" / "marked.min.js").read_text()
PURIFY = STATIC / "vendor" / "purify.min.js"
RECIPE = STATIC.parent.parent.parent / "vendor-src" / "dompurify"
VERSION = "3.5.0"
SHA256 = "f69a46022ab1f53e969c8ebbca98172c8995785a9b3be72ea4a12d25b1a1bf67"
RULES = SHARED.split("// <md-rules>", 1)[1].split("\n", 1)[1].split("// </md-rules>", 1)[0]
needs_node = pytest.mark.skipif(not NODE, reason="node is not installed")

# one entry per markdown feature, and the HTML a reply writes that renders as before
CORPUS = {
    "headings": "# one\n## two\n### three\n#### four\n##### five\n###### six\n\nsetext\n===\n\nsecond\n---",
    "emphasis": "*em* _em_ **strong** __strong__ ***both*** ~~struck~~ a ~ lone tilde, `inline <code> & more`",
    "breaks": "one line\nsecond line  \nthird\\\nfourth\n\n---\n\n***",
    "links": ('[text](https://example.com/a "a title") <https://example.com/angle> https://example.com/bare '
              "www.example.com/w someone@example.com [ref][r] [anchor](#part) [mail](mailto:a@example.com) [rel](docs/x.md)"
              '\n\n[r]: https://example.com/ref "ref title"'),
    "images": ('![remote](https://example.com/p.png "cap") ![data](data:image/png;base64,iVBORw0KGgo=) '
               "[![linked](https://example.com/q.png)](https://example.com/q)"),
    "lists": "- a\n- b\n  - nested\n    1. deep\n\ntext\n\n7. seven\n8. eight\n\n* loose\n\n* loose two",
    "tasks": "- [ ] open\n- [x] done\n  - [ ] nested\n\ntext\n\n1. [x] numbered",
    "table": ("| left | center | right | none |\n|:--|:-:|--:|---|\n"
              "| a | **b** | `c` | [d](https://example.com/d) |\n| e \\| f | | | |"),
    "code": ('```js\nconst a = 1 < 2 && "<div>";\n```\n\n```c++\nint x;\n```\n\n```\nplain <b>not bold</b>\n```\n\n'
             "text\n\n    indented <style>p{}</style>\n\n~~~sh title\nls\n~~~"),
    "quotes": "> quoted\n> > deeper\n>\n> - item\n> ```py\n> x\n> ```",
    "escapes": "\\*not em\\* &amp; &lt;tag&gt; &copy; 1 < 2 > 0",
    "html": ("<details open><summary>More</summary>\n\nhidden **text**\n\n</details>\n\n"
             'H<sub>2</sub>O, x<sup><a href="#fn1" title="note">1</a></sup> <kbd>Ctrl</kbd> <mark>m</mark><br>after\n\n'
             "<dl><dt>term</dt><dd>meaning</dd></dl>\n\n"
             '<div><span><b>b</b> <i>i</i> <u>u</u> <s>s</s> <small>small</small></span></div>\n\n'
             '<table><tr><td colspan="2" rowspan="1" align="right">cell</td></tr></table>\n\n'
             '<ol start="3" reversed type="a"><li value="9">nine</li></ol>\n\n'
             '<img src="https://example.com/s.png" alt="sized" width="40" height="20">'),
}

def run_node(script: str) -> str:
    assert NODE, "node is not installed"
    return subprocess.run([NODE], input=script, capture_output=True, text=True, check=True, timeout=30).stdout


def in_rules(expression: str):
    return json.loads(run_node(RULES + f"\nprocess.stdout.write(JSON.stringify({expression}));"))


class Tags(HTMLParser):
    def __init__(self, html: str):
        super().__init__()
        self.found: list[tuple[str, dict]] = []
        self.feed(html)
        self.close()

    def handle_starttag(self, tag, attrs):
        self.found.append((tag, {k: v if v is not None else "" for k, v in attrs}))


# ---------- the vendored file and its recipe ----------


def test_the_sanitizer_is_the_pinned_release_with_its_recipe():
    data = PURIFY.read_bytes()
    assert data.startswith(f"/*! @license DOMPurify {VERSION} |".encode())
    assert hashlib.sha256(data).hexdigest() == SHA256
    pkg = json.loads((RECIPE / "package.json").read_text())
    assert pkg["dependencies"] == {"dompurify": VERSION}
    locked = json.loads((RECIPE / "package-lock.json").read_text())["packages"]["node_modules/dompurify"]
    assert locked["version"] == VERSION and locked["integrity"].startswith("sha512-")
    readme = (RECIPE / "README.md").read_text()
    assert VERSION in readme and SHA256 in readme and f"{len(data):,} bytes" in readme and "npm ci" in readme
    assert "Apache License" in (RECIPE / "LICENSE").read_text() and "Mozilla Public License" in (RECIPE / "LICENSE-MPL").read_text()
    assert f"`DOMPurify` {VERSION} are vendored" in (STATIC.parent.parent.parent / "README.md").read_text()


# ---------- what is dropped ----------


def attrs_of(cases: list[tuple[str, str, str]], prefix: str = "md1-") -> list:
    """What each (tag, attribute, value) keeps."""
    return in_rules(f"{json.dumps(cases)}.map(([t, n, v]) => mdAttr(t, n, v, {json.dumps(prefix)}))")


@needs_node
def test_the_sanitizer_keeps_its_defaults_but_for_what_acts_or_restyles():
    cfg = in_rules("MD_PURIFY")
    assert set(cfg) == {"RETURN_DOM_FRAGMENT", "ALLOW_DATA_ATTR", "FORBID_TAGS", "FORBID_ATTR"}   # no list of what is allowed
    assert cfg["RETURN_DOM_FRAGMENT"] is True and cfg["ALLOW_DATA_ATTR"] is False
    assert sorted(cfg["FORBID_TAGS"]) == sorted(["style", "link", "meta", "base", "form", "button", "select", "textarea", "dialog"])
    assert sorted(cfg["FORBID_ATTR"]) == sorted(["popover", "popovertarget", "popovertargetaction", "command", "commandfor",
                                                 "interestfor", "interesttarget", "anchor", "autofocus", "accesskey",
                                                 "contenteditable", "for", "form", "autopictureinpicture"])
    # what a reply is to keep is on neither list
    kept = {"svg", "math", "video", "audio", "source", "track", "img", "details", "summary", "map", "area", "label", "font"}
    assert not kept & set(cfg["FORBID_TAGS"]) and "style" not in cfg["FORBID_ATTR"]
    # a video keeps what its controls offer; what asks for picture in picture without the reader goes
    assert not {"controls", "controlslist", "disablepictureinpicture", "playsinline"} & set(cfg["FORBID_ATTR"])
    assert "autopictureinpicture" in cfg["FORBID_ATTR"]


@needs_node
def test_the_only_class_is_a_code_block_s_language():
    cases = [("code", "class", v) for v in ("language-js", "language-c++", "fold tool language-js", "  language-a\tlanguage-b\n")]
    cases += [("code", "class", "tool"), ("div", "class", "msg assistant"), ("a", "class", "sess-more"), ("p", "class", ""),
              ("rect", "class", "tab"), ("span", "class", "xlanguage-js"), ("div", "class", "md-start codebox")]
    assert attrs_of(cases) == ["language-js", "language-c++", "language-js", "language-a language-b"] + [None] * 7


@needs_node
def test_every_name_and_every_pointer_at_one_gets_the_reply_s_prefix():
    cases = [
        (("div", "id", "composer"), "md7-composer"),
        (("input", "name", "ns-role"), "md7-ns-role"),
        (("details", "name", "group"), "md7-group"),
        (("map", "name", "m"), "md7-m"),
        (("img", "usemap", "#m"), "#md7-m"),
        (("div", "aria-labelledby", "a  b"), "md7-a md7-b"),
        (("td", "headers", "h1"), "md7-h1"),
        (("lineargradient", "href", "#g"), "#md7-g"),
        (("textpath", "xlink:href", " #p"), " #md7-p"),
        (("image", "href", "https://example.com/a.png"), "https://example.com/a.png"),
        (("animatetransform", "href", "#sidebar"), "#md7-sidebar"),
        (("animatemotion", "xlink:href", "#top"), "#md7-top"),
        (("mpath", "href", "#path"), "#md7-path"),
        # an animation that names its target any other way moves nothing
        (("animatetransform", "href", "https://example.com/chat#sidebar"), None),
        (("animatemotion", "href", "chat#top"), None),
        (("mpath", "xlink:href", "/#x"), None),
        # a link's address is the link's own
        (("a", "href", "#part"), "#part"),
        (("a", "xlink:href", "#part"), "#part"),
        (("area", "href", "#sessions"), "#sessions"),
        (("rect", "fill", "url(#g)"), "url(#md7-g)"),
        (("path", "marker-end", "url('#arrow')"), "url('#md7-arrow')"),
        (("circle", "clip-path", 'URL( "#c" )'), 'URL("#md7-c" )'),
        (("div", "style", "color: red; filter: url(#f); background: -moz-element(#sidebar)"),
         "color: red; filter: url(#md7-f); background: -moz-element(#md7-sidebar)"),
        (("div", "style", "color: #f00; width: 50%"), "color: #f00; width: 50%"),
        (("rect", "fill", "#ff0000"), "#ff0000"),
        (("animatetransform", "begin", "go.click; 2.5s;shape-1.end+1s;accessKey(a);indefinite"),
         "md7-go.click; 2.5s;md7-shape-1.end+1s;accessKey(a);indefinite"),
        (("animatemotion", "end", "0s; a.begin"), "0s; md7-a.begin"),
        (("div", "title", "url(#x) #y"), "url(#x) #y"),
    ]
    assert attrs_of([c for c, _ in cases], "md7-") == [want for _, want in cases]


@needs_node
def test_no_pointer_picture_and_no_place_ahead_in_the_tab_order():
    cases = [("rect", "cursor", "pointer"), ("rect", "cursor", "url(a.png), pointer"), ("rect", "cursor", "var(--c)"),
             ("div", "tabindex", "5"), ("div", "tabindex", "0"), ("div", "tabindex", "-1")]
    assert attrs_of(cases) == ["pointer", None, None, "0", "0", "-1"]


@needs_node
def test_what_renders_stays_as_written():
    cases = [("div", "style", "color: rgb(1, 2, 3); position: fixed"), ("svg", "viewbox", "0 0 10 10"), ("path", "d", "M0 0L1 1"),
             ("video", "src", "https://example.com/v.mp4"), ("video", "controls", ""), ("mo", "stretchy", "false"),
             ("a", "title", "t"), ("img", "width", "3000"), ("details", "open", ""), ("font", "color", "red"),
             ("div", "role", "button"), ("div", "aria-label", "a b"), ("div", "hidden", "")]
    assert attrs_of(cases) == [v for _, _, v in cases]


@needs_node
def test_inline_style_loses_only_what_the_box_cannot_hold():
    script = r"""
const run = (props) => { const had = new Map(Object.entries(props));
  mdStyle({ getPropertyValue: (p) => had.get(p) || "", removeProperty: (p) => { had.delete(p); } });
  return [...had.keys()].sort(); };
process.stdout.write(JSON.stringify([
  run({ color: "red", position: "fixed", cursor: "pointer", "z-index": "99" }),
  run({ cursor: 'url("a.png"), auto' }), run({ cursor: 'image-set("a.png" 1x), auto' }), run({ cursor: "var(--c), auto" }),
  run({ "-webkit-user-modify": "read-write", "anchor-name": "--a", "view-transition-name": "x", margin: "-9px" }),
]));
"""
    assert json.loads(run_node(RULES + script)) == [["color", "cursor", "position", "z-index"], [], [], [], ["margin"]]


@needs_node
def test_inline_style_that_would_hold_content_wide_is_made_to_fit():
    """mdFitStyle on a stand-in declaration (test_md_rules_ui.py measures the layout in the page)."""
    script = r"""
const run = (props) => { const had = new Map(Object.entries(props));
  mdFitStyle({ getPropertyValue: (p) => had.get(p) || "", removeProperty: (p) => { had.delete(p); }, setProperty: (p, v) => { had.set(p, v); } });
  return Object.fromEntries(had); };
process.stdout.write(JSON.stringify([
  // a least width stops at the box's, but for one every box has room for
  run({ "min-width": "3000px" }), run({ "min-width": "40em" }), run({ "min-width": "200px" }), run({ "min-width": "0px" }),
  // a line kept from wrapping wraps
  run({ "white-space": "nowrap" }), run({ "white-space": "pre" }), run({ "white-space": "pre-wrap", "overflow-wrap": "normal" }),
  run({ "text-wrap-mode": "nowrap" }), run({ "text-wrap": "nowrap" }),
  // a scroll box of the reply's own keeps its up and down, and does not scroll sideways
  run({ "overflow-x": "auto", "overflow-y": "auto" }), run({ "overflow-x": "scroll" }), run({ "overflow-y": "auto" }),
  run({ "overflow-y": "hidden" }),
  // an element that cuts its own line off keeps it
  run({ "overflow-x": "hidden", "overflow-y": "hidden", "white-space": "nowrap", "text-overflow": "ellipsis" }),
  // and the rest is as written
  run({ color: "red", width: "3000px", "overflow-x": "visible", "overflow-y": "clip" }),
]));
"""
    assert json.loads(run_node(RULES + script)) == [
        {"min-width": "min(3000px, 100%)"}, {"min-width": "min(40em, 100%)"}, {"min-width": "200px"}, {"min-width": "0px"},
        {"white-space": "normal"}, {"white-space": "pre-wrap"}, {"white-space": "pre-wrap"}, {}, {},
        {"overflow-x": "clip", "overflow-y": "auto"}, {"overflow-x": "clip", "overflow-y": "auto"},
        {"overflow-x": "clip", "overflow-y": "auto"}, {"overflow-x": "clip", "overflow-y": "hidden"},
        {"overflow-x": "hidden", "overflow-y": "hidden", "white-space": "nowrap", "text-overflow": "ellipsis"},
        {"color": "red", "width": "3000px", "overflow-x": "visible", "overflow-y": "clip"},
    ]


@needs_node
def test_the_only_input_is_a_disabled_checkbox():
    cases = [("checkbox", True), ("CheckBox", True), ("checkbox", False), ("text", True), ("password", True), ("radio", True),
             ("submit", True), ("button", True), ("image", True), ("file", True), ("hidden", True), (" checkbox", True),
             ("", True), (None, True), (None, False)]
    assert in_rules(f"{json.dumps(cases)}.map(([t, d]) => mdTaskBox(t, d))") == [True, True] + [False] * (len(cases) - 2)


@needs_node
def test_the_page_hands_every_reply_to_these_rules():
    """app.js's own wiring, run in node against a stand-in for DOMPurify and the nodes it returns: the configuration, the
    hooks, and what is done to each element that comes back. test_md_rules_ui.py runs the real library in the page."""
    wiring = APP[APP.index("const NEW_TAB = "):APP.index("// A reply's box is a formatting context")]
    script = RULES + r"""
const hooks = {}, removed = [], listeners = [];
const element = (localName, attrs, name = localName) => ({ localName, attrs: { ...attrs },
  getAttribute(n) { return n in this.attrs ? this.attrs[n] : null; }, hasAttribute(n) { return n in this.attrs; },
  getAttributeNames() { return Object.keys(this.attrs); }, setAttribute(n, v) { this.attrs[n] = v; }, removeAttribute(n) { delete this.attrs[n]; },
  remove() { removed.push(name); }, style: { getPropertyValue: (p) => (p === "cursor" ? "url(a)" : ""), removeProperty: (p) => removed.push("style " + p) } });
const task = element("input", { type: "checkbox", disabled: "" }, "task"), live = element("input", { type: "checkbox" }, "live");
const div = element("div", { id: "x", class: "msg", style: "cursor: url(a)" }), video = element("video", { src: "v" });
let asked = null;
globalThis.window = globalThis;
globalThis.document = { baseURI: "https://sala.example/", addEventListener: (name) => listeners.push(name) };
globalThis.DOMPurify = {
  addHook: (name, fn) => { hooks[name] = fn; },
  sanitize: (html, cfg) => { asked = [html, cfg === MD_PURIFY]; return { querySelectorAll: () => [task, live, div, video] }; },
};
""" + wiring + r"""
mdSanitize("<p>x</p>");
const first = { div: { ...div.attrs }, video: { ...video.attrs }, task: { ...task.attrs } };
div.attrs = { id: "x" }; mdSanitize("<p>y</p>");
const link = (localName, namespaceURI = "http://www.w3.org/1999/xhtml") => { const e = element(localName, { href: "#a", "xlink:href": "#b" });
  e.namespaceURI = namespaceURI; hooks.afterSanitizeAttributes(e); return e.attrs; };
const seen = (tagName, attrs) => { const e = element(tagName, attrs); e.nodeType = 1; let emptied = false; e.replaceChildren = () => { emptied = true; };
  hooks.uponSanitizeElement(e, { tagName }); return [Object.keys(e.attrs).sort(), emptied]; };
hooks.uponSanitizeElement({ nodeType: 3 }, { tagName: "#text" });
process.stdout.write(JSON.stringify({ asked, removed, first, second: div.attrs, listeners,
  links: [link("a"), link("area"), link("a", "http://www.w3.org/2000/svg"), link("mi", "http://www.w3.org/1998/Math/MathML"), link("image", "http://www.w3.org/2000/svg")],
  seen: [seen("div", { popover: "" }), seen("dialog", {}), seen("dialog", { open: "" }), seen("div", {})] }));
"""
    got = json.loads(run_node(script))
    assert got["asked"] == ["<p>y</p>", True]
    assert got["removed"][:2] == ["live", "style cursor"]
    assert got["first"]["div"] == {"id": "md1-x", "style": "cursor: url(a)"} and got["second"] == {"id": "md2-x"}
    assert got["first"]["video"] == {"src": "v"}   # full screen and picture in picture stay as its controls offer them
    assert got["first"]["task"] == {"type": "checkbox", "disabled": ""}
    assert got["listeners"] == []   # nothing waits to leave a full screen the reader opened
    opened = {"href": "#a", "xlink:href": "#b", "target": "_blank", "rel": "noopener noreferrer"}
    assert got["links"] == [opened, opened, opened, {}, {"href": "#a", "xlink:href": "#b"}]
    assert got["seen"] == [[["hidden", "popover"], False], [[], True], [["open"], False], [[], False]]
    # md() is the one way a reply becomes nodes, and it goes through these
    assert "d.append(mdSanitize(html));" in APP and APP.count("DOMPurify.sanitize(") == 1


@needs_node
def test_the_margins_at_a_box_s_edges_move_to_the_box():
    """mdEdges (app.js) on a stand-in tree: the elements down each edge below the box's own children are marked, and the box
    takes their margins; a list inside a list adds none, and a table keeps what is inside it."""
    wiring = APP[APP.index("const MD_EDGE_MARGINS"):APP.index("const isLocalSrc")]
    script = r"""
const node = (localName, kids = [], classes = []) => { const set = new Set(classes), props = {};
  const n = { nodeType: 1, localName, kids, classes: set, props,
    classList: { add: (c) => set.add(c), remove: (c) => set.delete(c), contains: (c) => set.has(c) },
    matches: (sel) => sel.split(", ").includes(localName),
    style: { setProperty: (k, v) => { props[k] = v; }, removeProperty: (k) => { delete props[k]; } },
    get firstChild() { return link(kids, 1); }, get lastChild() { return link(kids, -1); },
    querySelectorAll: (sel) => { const out = [], walk = (e) => { for (const k of e.kids || []) { if (k.classes?.has(sel.slice(1))) out.push(k); walk(k); } }; walk(n); return out; } };
  return n; };
const link = (kids, dir) => { const list = dir > 0 ? kids : [...kids].reverse(); list.forEach((k, i) => { k.nextSibling = k.previousSibling = list[i + 1] || null; }); return list[0] || null; };
const text = (data) => ({ nodeType: 3, data, kids: [] });
""" + wiring + r"""
const marked = (box) => { mdEdges(box); const out = [], walk = (e) => { for (const k of e.kids || []) { for (const c of k.classes || []) if (c.startsWith("md-s") || c.startsWith("md-e")) out.push(k.localName + " " + c); walk(k); } }; walk(box); return [out.sort(), box.props]; };
const p = () => node("p", [text("x")]);
const quote = node("div", [node("blockquote", [text("\n"), p(), text("\n")]), text("\n")]);
const lists = node("div", [node("ul", [node("li", [node("ul", [node("li", [p()])])])])]);
const words = node("div", [node("p", [text("see "), node("span", [], ["md-local"])])]);
const table = node("div", [node("blockquote", [node("table", [node("tbody", [node("tr")])])])]);
const plain = node("div", [p(), p()]);
const code = node("div", [p(), node("div", [node("pre"), node("button")], ["codebox"])]);
const inline = node("div", [node("p", [node("a", [text("x")])])]);
const twice = node("div", [node("blockquote", [p()])]); mdEdges(twice); twice.kids.push(p());
process.stdout.write(JSON.stringify([quote, lists, words, table, plain, twice, code, inline].map(marked)));
"""
    quote, lists, words, table, plain, twice, code, inline = json.loads(run_node(script))
    assert quote == [["p md-end", "p md-start"], {"--md-start": "max(0px)", "--md-end": "max(.7em)"}]
    assert lists == [["p md-end", "p md-start"], {"--md-start": "max(0px)", "--md-end": "max(.7em)"}]   # a list in a list has no margin
    assert words == [["span md-end"], {"--md-end": "max(8px)"}]   # words come first, so only the bottom edge is the picture's
    assert table == [["table md-end", "table md-start"], {"--md-start": "max(.5em)", "--md-end": "max(.5em)"}]
    assert plain == [[], {}]
    # marked again after the box gained a child (a footer put together): the old marks go
    assert twice == [["p md-start"], {"--md-start": "max(0px)"}]
    # a code block keeps its margin as the box's own last child; what has no margin is not marked
    assert code == [["div md-end"], {"--md-end": "max(.7em)"}] and inline == [[], {}]


@needs_node
def test_a_list_with_long_numbers_is_indented_further():
    """mdHang (app.js) on stand-in lists: only a list that is in no other list and reaches a number of four digits or more."""
    wiring = APP[APP.index("const MD_EDGE_MARGINS"):APP.index("const isLocalSrc")]
    script = wiring + r"""
const list = (start, values = [0], inner = false) => { const set = new Set(), props = {};
  return { set, props, start, childElementCount: values.length, children: values.map((value) => ({ value })),
    parentElement: { closest: (sel) => (inner && sel === "ul, ol, menu" ? {} : null) },
    classList: { toggle: (c, on) => (on ? set.add(c) : set.delete(c)) }, style: { setProperty: (k, v) => { props[k] = v; } } }; };
const lists = [list(1, [0, 0]), list(999), list(999, [0, 0]), list(2026), list(1, [261126]), list(123456789), list(2026, [0], true),
  list(-5000, [undefined])];
mdHang({ querySelectorAll: (sel) => (sel === "ol" ? lists : []) });
process.stdout.write(JSON.stringify(lists.map((l) => [l.set.has("md-hang"), l.props["--md-hang"] ?? null])));
"""
    none = [False, None]
    assert json.loads(run_node(script)) == [none, none, [True, "0.7em"], [True, "0.7em"], [True, "2.1em"], [True, "4.2em"], none, none]
    assert APP.count("mdHang(d);") == 1 and APP.count("mdHang(footer);") == 1
    assert ".md ol.md-hang { padding-inline-start: calc(40px + var(--md-hang)); }" in STYLE


# ---------- what renders as before ----------


@needs_node
def test_the_rules_change_nothing_markdown_writes():
    """Every element and attribute the vendored marked writes for the corpus (and the plain HTML in it) passes the rules as it
    is, so the sanitized tree is marked's own."""
    script = (SHARED + "\n" + MARKED + "\nconst m = exports.marked; noSingleTildeStrike(m);\n"
              f"process.stdout.write(JSON.stringify(Object.fromEntries(Object.entries({json.dumps(CORPUS)})"
              ".map(([k, t]) => [k, m.parse(mdPrep(t), { gfm: true, breaks: true })]))));")
    rendered = json.loads(run_node(script))
    assert set(rendered) == set(CORPUS)
    found = {k: Tags(html).found for k, html in rendered.items()}
    everything = [(k, tag, attrs) for k, tags in found.items() for tag, attrs in tags]
    forbidden = set(in_rules("MD_PURIFY.FORBID_TAGS"))
    assert [(k, tag) for k, tag, _ in everything if tag in forbidden] == []
    assert not {n for _, _, a in everything for n in a} & set(in_rules("MD_PURIFY.FORBID_ATTR"))
    # no name and no pointer in the corpus but what it writes as HTML itself, so markdown's own output is untouched
    triples = [(tag, name, value) for k, tag, attrs in everything if k != "html" for name, value in attrs.items()]
    assert [(t, k) for t, k in zip(triples, attrs_of(triples)) if k != t[2]] == []
    html = [(tag, name, value) for k, tag, attrs in everything if k == "html" for name, value in attrs.items()]
    assert [(t, k) for t, k in zip(html, attrs_of(html)) if k != t[2]] == []
    boxes = [(a.get("type"), "disabled" in a) for _, tag, a in everything if tag == "input"]
    assert len(boxes) == 4 and in_rules(f"{json.dumps(boxes)}.map(([t, d]) => mdTaskBox(t, d))") == [True] * 4
    attrs = {(tag, name) for tag, name, _ in triples}
    assert {("a", "href"), ("a", "title"), ("img", "src"), ("img", "alt"), ("img", "title"), ("code", "class"), ("ol", "start"),
            ("th", "align"), ("td", "align"), ("input", "type"), ("input", "checked"), ("input", "disabled")} <= attrs
