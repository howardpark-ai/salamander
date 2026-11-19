"""Every text-entry field in the web UI is 16px, on every device, from the one base rule in style.css (no media query, no device check).

Why: WebKit on iOS zooms the page into a focused field whose text is under 16px and never zooms back out. The fields were 15px, with a
16px patch on three of them on a narrow screen, so every other field (the composer, the New session form, the Quick session form, the
schedules sort, the date boxes) zoomed the page on a phone. One rule that applies to every field, at every width, is less to keep up
than a patch per field, and it cannot be forgotten for the next one: this file reads the computed size of every field in the DOM, the
ones not on the screen too, so a field added later under a rule that sets its own font-size fails here.

Held here, in a headless Chromium (conftest.py: `served`, `browser`):
- the field list is the page's own: every input, textarea, select and editable element in the DOM except the inputs that take no typed
  text (checkbox, radio, range, color, file, buttons, hidden), never a list of ids; each computes 16px at 1280 and 390 px wide;
- the views whose fields are drawn only when they open (the New session form, the Quick session form, the search page, the Schedules
  tab, the Usage explorer, the color tool's pop-up) are opened and read the same way, and at 390 px none of them scrolls sideways and no
  field's right edge is past its pane's (the nearest ancestor that clips or scrolls sideways: a pane with overflow-x: hidden would cut it
  off with the document still not scrolling);
- the composer stays one line tall with 16px text: the editor 30px, the row 48 px with a 30px Send button on a touch screen, 50 px with
  a 32px one on a desktop (test_composer_touch_row.py holds the same numbers), the line 22px with its text centred on the button;
- the three narrow-screen 16px patches (search.css twice, usage-explorer.css once) are gone, their heights kept, and the base rule, read
  from the CSSOM, is found once with no parent rule (under no @media, @supports or @container); two probes show the pane check and the
  CSSOM check fail on the cases they are for.

One field sets its own size on purpose: the color tool's hex box (colortool.js, stackshot's pinned file, `font: 16px ui-monospace, ...`).
The computed-size check passes for it even if that were the only source of the 16px.

Runs in a headless Chromium when one is installed, else skipped.
"""

from __future__ import annotations

import json
import re
import time

import pytest
from conftest import CHAT_READY, NAME
from sala_web.app import STATIC
from test_new_session import click, open_form
from test_new_session import sala  # noqa: F401  (fixture)
from test_schedules import open_schedules
from test_search_ui import open_page as open_search_page
from test_side_sessions import open_hash as open_quick_form
from test_usage_explorer_ui import open_explorer
from test_usage_ui import DESKTOP, PHONE

CSS = {p.name: p.read_text() for p in STATIC.glob("*.css")}
SETTLED = "new Promise((ok) => requestAnimationFrame(() => requestAnimationFrame(() => ok(innerWidth))))"

# Every field in the DOM: whatever takes typed text. The browser's own idea of an input's type (`type`: "text" for none or an unknown
# one), so a field of an old kind is found, and so is one of a new kind unless it is listed here as one that takes no text.
NO_TEXT = ["checkbox", "radio", "range", "color", "file", "button", "reset", "submit", "image", "hidden"]
FIELDS = """(() => {
  const NO_TEXT = %s;
  const fields = [...document.querySelectorAll("input, textarea, select, [contenteditable]")]
    .filter((e) => !(e.localName === "input" && NO_TEXT.includes(e.type)) && e.getAttribute("contenteditable") !== "false");
  const who = (e) => e.id ? "#" + e.id : e.localName + (e.className && typeof e.className === "string" ? "." + e.className.trim().split(/\\s+/).join(".") : "");
  // The nearest ancestor that clips or scrolls its overflow sideways (the pane: #search-pane, #chat-pane and #overview-pane are overflow-x:
  // hidden, body is too), null when a fixed box is reached first (it is placed against the viewport, not clipped by what it sits in).
  const clip = (e) => {
    if (getComputedStyle(e).position === "fixed") return null;
    for (let p = e.parentElement; p; p = p.parentElement) {
      if (getComputedStyle(p).overflowX !== "visible") return p;
      if (getComputedStyle(p).position === "fixed") return null;
    }
    return null;
  };
  return { fields: fields.map((e) => {
             const r = e.getBoundingClientRect(), p = clip(e), pr = p && p.getBoundingClientRect();
             return { who: who(e), kind: e.localName + (e.localName === "input" ? "[" + e.type + "]" : ""), px: getComputedStyle(e).fontSize,
                      shown: e.getClientRects().length > 0, right: Math.round(r.right * 10) / 10, pane: p ? who(p) : "the viewport",
                      paneRight: Math.round(Math.min(pr ? pr.right : innerWidth, innerWidth) * 10) / 10 };
           }),
           width: innerWidth, scroll: document.documentElement.scrollWidth, body: document.body.scrollWidth };
})()""" % json.dumps(NO_TEXT)


def resize(browser, width: int, height: int, mobile: bool) -> None:
    browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": height, "deviceScaleFactor": 1, "mobile": mobile})
    deadline = time.monotonic() + 10
    while browser.evaluate(SETTLED) != width:
        assert time.monotonic() < deadline, f"the {width}px viewport never took effect"
        time.sleep(0.05)


def until(browser, expr: str, what: str, ms: int = 10000) -> None:
    ok = browser.evaluate("""new Promise((res) => { const t0 = Date.now(); (function poll() {
      let v; try { v = (%s); } catch (e) { v = null; }
      if (v || Date.now() - t0 > %d) res(!!v); else setTimeout(poll, 50); })(); })""" % (expr, ms))
    assert ok, what


def fields_beyond_their_pane(got: dict) -> list[dict]:
    """The fields on the screen whose right edge is past their pane's (half a pixel of rounding is let go)."""
    return [f for f in got["fields"] if f["shown"] and f["right"] > f["paneRight"] + 0.5]


def assert_all_16px(browser, where: str, must: tuple[str, ...] = (), width: int | None = None) -> dict:
    """Every field now in the DOM computes 16px; `must` names the ones this view has to show (so an empty query cannot pass); at 390 px
    the document does not scroll sideways and no field reaches past the right edge of its pane (the nearest ancestor that clips or scrolls
    sideways, or the screen): a pane with overflow-x: hidden would cut it off without the document scrolling, so the two checks above
    cannot see it."""
    got = browser.evaluate(FIELDS)
    assert got["fields"], (where, got)
    wrong = [f for f in got["fields"] if f["px"] != "16px"]
    assert not wrong, (where, "fields not at 16px", wrong)
    have = {f["who"] for f in got["fields"]}
    assert set(must) <= have, (where, "fields missing from the DOM", sorted(set(must) - have), sorted(have))
    if width is not None and width <= 400:
        assert got["scroll"] <= got["width"] and got["body"] <= got["width"], (where, "scrolls sideways", got)
        beyond = fields_beyond_their_pane(got)
        assert not beyond, (where, "fields reach past the right edge of their pane", beyond)
    return got


PAGE_FIELDS = ("#input", "#side-q", "#se-query", "#se-from", "#se-to", "#sc-sortsel", "#ns-filter", "#ns-name", "#ns-mandate",
               "#ns-model-other", "#ns-lane", "#ns-model", "#ns-effort", "#sd-project", "#sd-agents", "#sd-name", "#sd-mandate")


@pytest.mark.parametrize("width,height,mobile", [(1280, 800, False), (390, 844, True)])
def test_every_field_in_the_page_is_16px_whether_it_is_on_the_screen_or_not(served, browser, width, height, mobile):
    browser.open(f"{served['url']}/#s={NAME}")
    browser.wait_ready(CHAT_READY)
    resize(browser, width, height, mobile)
    got = assert_all_16px(browser, f"the page at {width}", PAGE_FIELDS, width)
    kinds = {f["kind"] for f in got["fields"]}
    assert {"textarea", "select", "input[text]", "input[search]", "input[datetime-local]"} <= kinds, kinds   # every kind the page has
    # the composer's editor and its lines: the lines inherit the editor's size, and the placeholder is one of them
    c = browser.evaluate("""(() => { const px = (s) => getComputedStyle(document.querySelector(s)).fontSize;
      return { content: px("#input"), line: px("#input .cm-line"), editable: document.querySelector("#input").getAttribute("contenteditable") }; })()""")
    assert c == {"content": "16px", "line": "16px", "editable": "true"}, c
    # what is not a field keeps the body's 15px
    rest = browser.evaluate("""({ body: getComputedStyle(document.body).fontSize, chat: getComputedStyle(document.querySelector("#chat .msg")).fontSize,
      send: getComputedStyle(document.querySelector("#send")).fontSize })""")
    assert rest == {"body": "15px", "chat": "15px", "send": "15px"}, rest


def test_a_new_field_cannot_slip_under_16px_the_query_finds_a_field_added_at_run_time(served, browser):
    """The check above reads whatever the DOM holds: a field made later is read too, and one that a field rule sizes under 16px fails it."""
    browser.open(f"{served['url']}/#s={NAME}")
    browser.wait_ready(CHAT_READY)
    browser.evaluate("""(() => { document.body.insertAdjacentHTML("beforeend",
      '<input id="probe-a"><input id="probe-b" type="email"><input id="probe-c" type="number"><textarea id="probe-d"></textarea>' +
      '<select id="probe-e"></select><div id="probe-f" contenteditable="plaintext-only">x</div><div id="probe-g" contenteditable="false">x</div>' +
      '<input id="probe-h" type="checkbox"><input id="probe-i" type="hidden">'); return 1; })()""")
    got = assert_all_16px(browser, "the added fields", ("#probe-a", "#probe-b", "#probe-c", "#probe-d", "#probe-e", "#probe-f"))
    who = {f["who"] for f in got["fields"]}
    assert not who & {"#probe-g", "#probe-h", "#probe-i"}, who      # not editable, no typed text, no typed text
    browser.evaluate("""(() => { const s = document.createElement("style"); s.textContent = ".ns-form input, #probe-a { font-size: 15px; }"; document.head.append(s); return 1; })()""")
    wrong = [f["who"] for f in browser.evaluate(FIELDS)["fields"] if f["px"] != "16px"]
    assert "#probe-a" in wrong, wrong   # a field rule that sizes a field, as the old ones did, is what the check is for: it fails


VIEWS = {
    "new session": ("#ns-filter", "#ns-name", "#ns-mandate", "#ns-model-other", "#ns-lane", "#ns-model", "#ns-effort"),
    "quick session": ("#sd-project", "#sd-agents", "#sd-name", "#sd-mandate"),
    "search page": ("#side-q", "#se-query", "#se-from", "#se-to"),
    "schedules": ("#sc-sortsel",),
    "usage explorer": ("#ex-sa", "#ex-sb"),
}


def open_view(view: str, served, browser, width: int) -> None:
    height = 844 if width <= 400 else 800
    if view == "new session":
        open_form(browser, served, width=width, height=height)
        browser.evaluate("document.querySelectorAll('.ns-more').forEach((d) => { d.open = true; }); 1")   # Lane, Model, Effort
        until(browser, "document.querySelector('#ns-lane').getClientRects().length", "the form's More options")
    elif view == "quick session":
        open_quick_form(browser, served, "#side=", width=width, height=height)
        until(browser, "document.querySelector('#sd-form') && getComputedStyle(document.querySelector('#sd-form')).display !== 'none'", "the Quick session form")
    elif view == "search page":
        from test_search_ui import prepare
        prepare(served)
        open_search_page(served, browser, "#search?q=zebra&hours=6&front=1&messages=1", width=width, prepared=True)
        until(browser, "document.querySelector('#se-form').getClientRects().length", "the search page")
        browser.evaluate("document.querySelector('#se-range [data-hours=\"dates\"]').click(); 1")       # the date boxes
        until(browser, "document.querySelector('#se-from').getClientRects().length", "the date boxes")
    elif view == "schedules":
        open_schedules(served, browser, wide=width > 400)
    elif view == "usage explorer":
        open_explorer(served, browser, DESKTOP if width > 400 else PHONE)


@pytest.mark.parametrize("width", [1280, 390])
@pytest.mark.parametrize("view", list(VIEWS))
def test_the_fields_a_view_draws_when_it_opens_are_16px_and_the_view_does_not_scroll_sideways(view, width, served, browser, sala):
    open_view(view, served, browser, width)
    assert_all_16px(browser, f"{view} at {width}", VIEWS[view], width)


def test_the_color_tools_boxes_are_16px(served, browser):
    """colortool.js is stackshot's pinned file and draws its own hex boxes (a rule of its own, font: 16px): the base rule agrees with it."""
    browser.open(f"{served['url']}/#s={NAME}")
    browser.wait_ready(CHAT_READY)
    resize(browser, 390, 844, True)
    browser.evaluate("document.querySelector('#side-colors button').click(); 1")
    until(browser, "document.querySelectorAll('.ct-hex').length", "the color tool opened no hex boxes")
    assert_all_16px(browser, "the color tool open", ("#ct-name",))


COMPOSER = """(() => {
  const h = (s) => Math.round(document.querySelector(s).getBoundingClientRect().height * 10) / 10;
  const line = document.querySelector("#input .cm-line"), lb = line.getBoundingClientRect(), sb = document.querySelector("#send").getBoundingClientRect();
  return { width: innerWidth, row: h(".compose-row"), editor: h("#composer-editor"), content: h("#input"),
           send: [Math.round(sb.width), Math.round(sb.height)], line: lb.height, lineHeight: getComputedStyle(line).lineHeight,
           px: getComputedStyle(document.querySelector("#input")).fontSize, lineMid: (lb.top + lb.bottom) / 2, sendMid: (sb.top + sb.bottom) / 2,
           lines: document.querySelectorAll("#input .cm-line").length, coarse: matchMedia("(pointer: coarse)").matches };
})()"""


@pytest.mark.parametrize("width,height,mobile,row,send", [(390, 844, True, 48, [30, 30]), (1280, 800, False, 50, [32, 32])])
def test_the_composer_stays_one_line_tall_at_16px(served, browser, width, height, mobile, row, send):
    browser.open(f"{served['url']}/#s={NAME}")
    browser.wait_ready(CHAT_READY)
    if mobile:
        browser.touch()
    resize(browser, width, height, mobile)
    browser.settle("document.querySelector('.compose-row')")
    m = browser.evaluate(COMPOSER)
    assert m["px"] == "16px" and m["coarse"] == mobile and m["width"] == width, m
    assert m["row"] == row and m["send"] == send, m                  # the heights test_composer_touch_row.py holds: the bigger text grows nothing
    assert m["lines"] == 1 and m["line"] == 22 and m["lineHeight"] == "22px", m   # one line, 22px tall: 16px text fits it
    assert m["content"] == 30 and m["editor"] == 30, m               # 22px of line, 4px above and below
    assert abs(m["lineMid"] - m["sendMid"]) <= 1, m                  # the text is centred on the Send button


def test_the_narrow_screen_patches_are_gone_and_keep_their_heights():
    """The base rule replaces them: no field rule sets a font-size, and the 44px heights they sat beside are still there."""
    assert "font-size: 16px" not in CSS["search.css"] and "font-size: 16px" not in CSS["usage-explorer.css"]
    assert re.search(r"@media \(max-width: 760px\) \{ \.side-search input \{ height: 44px; \}", CSS["search.css"])
    assert re.search(r"#search-pane \.se-q input \{ height: 44px; \}", CSS["search.css"])
    assert re.search(r"#ov-usage \.ex-ctl select \{ min-height: 44px; \}", CSS["usage-explorer.css"])
    base = re.findall(r"^input:not\(.*?\{ font-size: 16px; \}$", CSS["style.css"], re.S | re.M)
    assert len(base) == 1 and "textarea, select, [contenteditable]" in base[0], base          # one base rule, in one place
    # that it is not inside an @media, @supports or @container is read from the CSSOM below: a regex over this text cannot tell


# The base rule as the browser parsed it: every style rule, at any depth, whose selector list holds textarea, select and contenteditable,
# with the at-rule or style rule it sits in (null at the top level of its sheet). A regex over the CSS text would capture the rule itself
# and miss an @media, @supports or @container wrapped around it; the CSSOM has the parent.
BASE_RULES = """(() => {
  const found = [];
  const has = (sel, word) => new RegExp("(^|[\\\\s,])" + word + "([\\\\s,]|$)").test(sel);
  const walk = (rules, sheet) => {
    for (const r of rules) {
      if (r.selectorText !== undefined && has(r.selectorText, "textarea") && has(r.selectorText, "select") && r.selectorText.includes("[contenteditable")) {
        found.push({ sheet, size: r.style.fontSize, parent: r.parentRule ? r.parentRule.constructor.name + " " + r.parentRule.cssText.slice(0, 50) : null });
      }
      if (r.cssRules) walk(r.cssRules, sheet);
    }
  };
  for (const sheet of document.styleSheets) {
    try { walk(sheet.cssRules, (sheet.href || "inline").split("?")[0].split("/").pop()); } catch (e) { /* a sheet from another origin cannot be read */ }
  }
  return found;
})()"""


def assert_base_rule_is_at_the_top_level(browser, where: str) -> list[dict]:
    """One base rule, 16px, parentRule null (so under no @media, @supports or @container, and not nested in another rule)."""
    found = browser.evaluate(BASE_RULES)
    assert len(found) == 1, (where, "the base field rule is not found exactly once", found)
    assert found[0]["parent"] is None and found[0]["size"] == "16px" and found[0]["sheet"] == "style.css", (where, found)
    return found


def test_the_base_rule_sits_at_the_top_of_style_css_under_no_media_query(served, browser):
    browser.open(f"{served['url']}/#s={NAME}")
    browser.wait_ready(CHAT_READY)
    assert_base_rule_is_at_the_top_level(browser, "the page")


def test_the_cssom_check_finds_a_base_rule_wrapped_in_a_media_query_and_a_field_past_its_pane(served, browser):
    """The two checks added to the ones above fail on the cases they are for: a copy of the base rule inside an @media (what the text
    regex missed), and a field wider than the pane that clips it (what the document and body widths missed)."""
    browser.open(f"{served['url']}/#s={NAME}")
    browser.wait_ready(CHAT_READY)
    resize(browser, 390, 844, True)
    assert_all_16px(browser, "the page before the probes", PAGE_FIELDS, 390)
    browser.evaluate("""(() => { const s = document.createElement("style");
      s.textContent = '@media (min-width: 1px) { textarea, select, [contenteditable]:not([contenteditable="false"]) { font-size: 16px; } }';
      document.head.append(s); return 1; })()""")
    with pytest.raises(AssertionError, match="not found exactly once"):
        assert_base_rule_is_at_the_top_level(browser, "a rule in an @media")
    assert [f["parent"] is not None for f in browser.evaluate(BASE_RULES)].count(True) == 1   # the copy is found, with its @media as the parent
    # a 600px box in #search-pane (overflow-x: hidden): the pane clips it, the document and the body do not scroll
    browser.evaluate("""(() => { document.body.classList.add("search-open");
      document.querySelector("#search-pane").insertAdjacentHTML("beforeend", '<input id="probe-wide" style="width: 600px">'); return 1; })()""")
    until(browser, "document.querySelector('#probe-wide').getClientRects().length", "the probe in the search pane")
    got = browser.evaluate(FIELDS)
    assert got["scroll"] <= got["width"] and got["body"] <= got["width"], got      # the checks that were there see nothing
    beyond = fields_beyond_their_pane(got)
    assert [f["who"] for f in beyond] == ["#probe-wide"] and beyond[0]["pane"] == "#search-pane", beyond
    with pytest.raises(AssertionError, match="reach past the right edge of their pane"):
        assert_all_16px(browser, "a field wider than its pane", ("#probe-wide",), 390)
