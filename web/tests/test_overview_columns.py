"""The sessions table's Model and Effort columns. Model holds the model's
name only, as a label tinted by family (Fable, Opus, Sonnet, Haiku; any other grey), one colour for every version of a
family; Effort holds the level, a shade of one colour from low (lightest) to max (strongest). Both sort by a header
click: effort by level (low < medium < high < xhigh < max, none set last), model by family, then version. Every label
holds WCAG AA contrast in the light and the dark theme, and the page never scrolls sideways at 390 or 1280 px.

The page runs in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else skipped; the
overview is fed a fixed list of sessions by a stub of fetch("api/overview") installed before the page loads.
"""

from __future__ import annotations

import json
import re

from sala_web.app import STATIC

INDEX = (STATIC / "index.html").read_text()


def row(name, model, effort, alias=None):
    return {"name": name, "pid": 1, "sessionId": name, "scope": "example", "project": "projects/x", "projectTitle": "x",
            "role": "front", "status": "idle", "lane": "subscription-1", "model": model, "effort": effort,
            "modelSource": "alias" if alias else ("launch" if model else None),
            "effortSource": "launch" if effort else None, "modelAlias": alias}


# the server's order (the sidebar's): deliberately neither by model nor by effort
ROWS = [
    row("s-high", "claude-sonnet-5-5[1m]", "high"),
    row("s-none", "claude-opus-5-5", None),
    row("s-max", "claude-fable-5-1", "max"),
    row("s-low", "claude-opus-4-1", "low"),
    row("s-alias", "opus", "xhigh", {"name": "opus", "from": "launch", "via": None, "binary": None}),
    row("s-medium", "claude-haiku-5-5", "medium"),
    row("s-odd", "gpt-x", "turbo"),
    row("s-noreply", None, None),
]

STUB = """(() => {
  const rows = %s, real = window.fetch.bind(window);
  window.fetch = (url, opts) => String(url).startsWith("api/overview")
    ? Promise.resolve(new Response(JSON.stringify({ sessions: rows, rolesError: null }), { headers: { "Content-Type": "application/json" } }))
    : real(url, opts);
})();""" % json.dumps(ROWS)

WAIT_ROWS = """
new Promise((res) => { const t0 = Date.now(); (function poll() {
  const n = document.querySelectorAll("#sp-table tbody tr td:first-child a").length;
  if (n === %d || Date.now() - t0 > 15000) res(n); else setTimeout(poll, 100);
})(); })""" % len(ROWS)

# each row: its name, the model cell's tag (text, class, colours), its "version unknown" note, the effort cell
CELLS = """(() => [...document.querySelectorAll("#sp-table tbody tr")].map((tr) => {
  const td = tr.children, tag = (c) => { const t = c.querySelector(".sp-tag"); if (!t) return null;
    const cs = getComputedStyle(t); return { text: t.textContent, cls: t.className, color: cs.color, bg: cs.backgroundColor }; };
  return { name: td[0].textContent, model: tag(td[4]), modelText: td[4].textContent, vu: !!td[4].querySelector(".sp-vu"),
           modelTitle: (td[4].firstElementChild || {}).title || "", effort: tag(td[5]), effortText: td[5].textContent,
           effortMuted: !!td[5].querySelector(".sp-muted") };
}))()"""

# WCAG 2 contrast of every tag's text on its own (opaque) background, as the browser computed both
CONTRAST = r"""(() => {
  const parse = (s) => { let m = /^rgba?\(([\d.]+),\s*([\d.]+),\s*([\d.]+)(?:,\s*([\d.]+))?\)$/.exec(s);
    if (m) return { c: [+m[1] / 255, +m[2] / 255, +m[3] / 255], a: m[4] === undefined ? 1 : +m[4] };
    m = /^color\(srgb ([\d.e-]+) ([\d.e-]+) ([\d.e-]+)(?: \/ ([\d.]+))?\)$/.exec(s);
    if (m) return { c: [+m[1], +m[2], +m[3]], a: m[4] === undefined ? 1 : +m[4] };
    throw new Error("colour " + s); };
  const lum = ({ c }) => c.map((x) => (x <= 0.04045 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4))
    .reduce((s, x, i) => s + x * [0.2126, 0.7152, 0.0722][i], 0);
  return [...document.querySelectorAll("#sp-table .sp-tag")].map((t) => {
    const cs = getComputedStyle(t), fg = parse(cs.color), bg = parse(cs.backgroundColor);
    const [hi, lo] = [lum(fg), lum(bg)].sort((a, b) => b - a);
    return { cls: t.className, text: t.textContent, fgAlpha: fg.a, bgAlpha: bg.a, ratio: (hi + 0.05) / (lo + 0.05),
             size: parseFloat(cs.fontSize), bg: cs.backgroundColor };
  });
})()"""

MEASURE = """(() => {
  const vw = document.documentElement.clientWidth, pane = document.querySelector("#overview-pane"),
        wrap = document.querySelector("#overview-pane .sp-wrap"), r = wrap.getBoundingClientRect(),
        ths = [...document.querySelectorAll("#sp-table th")].map((th) => { const b = th.getBoundingClientRect();
          return { key: th.dataset.key, w: Math.round(b.width) }; });
  return { vw, docScroll: document.documentElement.scrollWidth, bodyScroll: document.body.scrollWidth,
           paneScroll: pane.scrollWidth, paneClient: pane.clientWidth, wrapLeft: r.left, wrapRight: r.right,
           wrapScroll: wrap.scrollWidth, wrapClient: wrap.clientWidth, overflowX: getComputedStyle(wrap).overflowX,
           table: Math.round(document.querySelector("#sp-table").getBoundingClientRect().width), ths };
})()"""


def names(browser) -> list[str]:
    return browser.evaluate("""[...document.querySelectorAll("#sp-table tbody tr td:first-child")].map((c) => c.textContent)""")


def click(browser, key: str) -> str:
    """Click a header; its aria-sort after the click."""
    return browser.evaluate(f"""(() => {{ const th = document.querySelector('#sp-table th[data-key="{key}"]');
      th.querySelector("button").click(); return th.getAttribute("aria-sort"); }})()""")


def open_overview(served, browser, dark: bool = True) -> None:
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": STUB})
    browser.open(f"{served['url']}/#sessions", dark=dark)
    assert browser.evaluate(WAIT_ROWS) == len(ROWS)


def test_the_table_has_an_effort_column_right_after_model():
    keys = re.findall(r'<th data-key="(\w+)" aria-sort="none"><button type="button">(\w+)</button></th>', INDEX.split('id="ov-schedules"')[0])   # the Agents tab's table; the Schedules tab has its own
    assert keys == [("name", "Agent"), ("project", "Project"), ("role", "Role"), ("status", "Status"),
                    ("model", "Model"), ("effort", "Effort"), ("lane", "Lane")], keys
    assert '<td colspan="7" class="sp-empty">' in INDEX
    js = (STATIC / "sessions.js").read_text()
    assert "c.colSpan = 7;" in js and '" @ "' not in js   # the effort is no longer glued to the model


def test_model_and_effort_cells(served, browser):
    open_overview(served, browser)
    cells = {c["name"]: c for c in browser.evaluate(CELLS)}
    # the model's name only, the effort in its own cell
    assert cells["s-low"]["modelText"] == "Opus 4.1" and cells["s-low"]["effortText"] == "low"
    assert cells["s-none"]["model"]["text"] == "Opus 5.5"
    assert cells["s-high"]["model"]["text"] == "Sonnet 5.5 (1M)"
    assert cells["s-max"]["model"]["text"] == "Fable 5.1" and cells["s-medium"]["model"]["text"] == "Haiku 5.5"
    # an alias no version could be read for: the family label, "version unknown" beside it, the source in the tooltip
    a = cells["s-alias"]
    assert a["model"]["text"] == "Opus" and a["vu"] and a["modelText"] == "Opus version unknown", a
    assert "version unknown" in a["modelTitle"], a
    assert not any(c["vu"] for n, c in cells.items() if n != "s-alias")
    # a missing effort and a session with no reply yet stay readable, never blank
    assert cells["s-none"]["effort"] is None and cells["s-none"]["effortText"] == "not set" and cells["s-none"]["effortMuted"]
    assert cells["s-noreply"]["model"] is None and cells["s-noreply"]["modelText"] == "no reply yet"
    assert cells["s-noreply"]["effortText"] == "not set"
    # one colour class per family, the same across versions (Opus 4.1, Opus 5.5 and the bare alias)
    fam = {n: re.search(r"\bfam-(\w+)", c["model"]["cls"]).group(1) for n, c in cells.items() if c["model"]}
    assert fam == {"s-high": "sonnet", "s-none": "opus", "s-max": "fable", "s-low": "opus", "s-alias": "opus",
                   "s-medium": "haiku", "s-odd": "other"}, fam
    opus = [cells[n]["model"] for n in ("s-low", "s-none", "s-alias")]
    assert len({(m["color"], m["bg"]) for m in opus}) == 1, opus
    others = {(cells[n]["model"]["color"], cells[n]["model"]["bg"]) for n in ("s-high", "s-max", "s-medium", "s-odd")}
    assert len(others) == 4 and opus[0]["color"] not in {c for c, _ in others}, others
    # effort: one class per level, an unknown level neutral; shades deepen from low to max
    eff = {cells[n]["effortText"]: cells[n]["effort"] for n in cells if cells[n]["effort"]}
    assert {k: re.search(r"\beff-(\w+)", v["cls"]).group(1) for k, v in eff.items()} == {
        "low": "low", "medium": "medium", "high": "high", "xhigh": "xhigh", "max": "max", "turbo": "other"}
    assert len({eff[k]["bg"] for k in ("low", "medium", "high", "xhigh", "max")}) == 5


def test_default_model_and_effort_are_labelled_as_the_default(served, browser):
    # a session nothing names a model for shows the CLI's default, with "(default)" beside it and a tooltip
    rows = [dict(row("s-default", "claude-opus-5-5", "high"), modelSource="default", effortSource="default"),
            row("s-launch", "claude-opus-5-5", "high")]
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": STUB.replace(json.dumps(ROWS), json.dumps(rows), 1)})
    browser.open(f"{served['url']}/#sessions", dark=True)
    assert browser.evaluate(WAIT_ROWS.replace(f"n === {len(ROWS)}", "n === 2")) == 2
    cells = {c["name"]: c for c in browser.evaluate(CELLS)}
    assert cells["s-default"]["modelText"] == "Opus 5.5 (default)" and cells["s-default"]["effortText"] == "high (default)"
    assert cells["s-default"]["model"]["text"] == "Opus 5.5" and cells["s-default"]["effort"]["text"] == "high"
    assert "settings.json" in cells["s-default"]["modelTitle"]
    # a model the pane names itself carries no label
    assert cells["s-launch"]["modelText"] == "Opus 5.5" and cells["s-launch"]["effortText"] == "high"


def effort_order(browser) -> list[str]:
    return browser.evaluate("""[...document.querySelectorAll("#sp-table tbody tr")].map((tr) => tr.children[5].textContent)""")


def test_sort_by_effort_level_and_by_model(served, browser):
    open_overview(served, browser)
    # effort, ascending: by level, never alphabetically; an unknown level after max; none set last
    assert click(browser, "effort") == "ascending"
    assert effort_order(browser) == ["low", "medium", "high", "xhigh", "max", "turbo", "not set", "not set"]
    assert names(browser)[-2:] == ["s-none", "s-noreply"]   # ties keep the server's order
    # descending: reversed, none set still last
    assert click(browser, "effort") == "descending"
    assert effort_order(browser) == ["turbo", "max", "xhigh", "high", "medium", "low", "not set", "not set"]
    # a third click: back to the server's order, no column marked
    assert click(browser, "effort") == "none"
    assert names(browser) == [r["name"] for r in ROWS]
    # model: family (Fable, Opus, Sonnet, Haiku, others), then version; a version unknown after the family's known
    # ones; no model last
    assert click(browser, "model") == "ascending"
    assert names(browser) == ["s-max", "s-low", "s-none", "s-alias", "s-high", "s-medium", "s-odd", "s-noreply"]
    sorts = browser.evaluate("""[...document.querySelectorAll("#sp-table th")].map((th) => th.getAttribute("aria-sort"))""")
    assert sorts == ["none", "none", "none", "none", "ascending", "none", "none"], sorts
    assert click(browser, "model") == "descending"
    assert names(browser) == ["s-odd", "s-medium", "s-high", "s-alias", "s-none", "s-low", "s-max", "s-noreply"]
    # the sorted header shows its arrow
    arrow = browser.evaluate("""getComputedStyle(document.querySelector('#sp-table th[data-key="model"] button'), "::after").content""")
    assert arrow == '"▾"', arrow


def check_contrast(tags: list[dict]) -> float:
    assert len(tags) == 7 + 6, tags   # seven model labels, six effort labels
    for t in tags:
        assert t["fgAlpha"] == 1 and t["bgAlpha"] == 1, t   # opaque: the ratio is the one on screen, whatever the row's hover
        assert t["ratio"] >= 4.5 and t["size"] >= 12, t
    return min(t["ratio"] for t in tags)


def test_labels_hold_aa_contrast_in_both_themes(served, browser):
    open_overview(served, browser, dark=True)
    dark = browser.evaluate(CONTRAST)
    check_contrast(dark)
    browser.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": "light"}]})
    light = browser.evaluate(CONTRAST)
    check_contrast(light)
    assert [t["bg"] for t in light] != [t["bg"] for t in dark]   # the theme did change
    # the page's own dark setting (data-theme) over a light system gives the same colours as the system's dark
    browser.evaluate("document.documentElement.dataset.theme = 'dark'; ''")
    forced = browser.evaluate(CONTRAST)
    assert [round(t["ratio"], 2) for t in forced] == [round(t["ratio"], 2) for t in dark]


def check_no_page_overflow(m: dict, vw: int) -> None:
    assert m["vw"] == vw, m
    assert m["docScroll"] <= vw and m["bodyScroll"] <= vw and m["paneScroll"] <= m["paneClient"], m
    assert 0 <= m["wrapLeft"] and m["wrapRight"] <= vw, m
    assert [t["key"] for t in m["ths"]] == ["name", "project", "role", "status", "model", "effort", "lane"], m


def test_no_sideways_page_scroll_at_phone_and_desktop_width(served, browser):
    open_overview(served, browser)
    phone = browser.evaluate(MEASURE)
    check_no_page_overflow(phone, 390)
    # at a phone's width the table scrolls inside its box, never the page
    assert phone["overflowX"] == "auto" and phone["wrapScroll"] > phone["wrapClient"], phone
    browser.send("Emulation.setDeviceMetricsOverride", {"width": 1280, "height": 800, "deviceScaleFactor": 1, "mobile": False})
    wide = browser.evaluate(MEASURE)
    check_no_page_overflow(wide, 1280)
    assert wide["wrapScroll"] <= wide["wrapClient"], wide   # the whole table fits
