"""The Overview's Machines tab in a browser (static/machines.js, machines.css, the tab and panel in index.html, app.js's tab routing), at a
desktop's width (1280) and a phone's (390): the machine cards, with a footer that says how old the reading is. The page reads the real api/machines, which reads a made-up fleet written to a
temporary folder (machines_world.py, removed when the test ends); nothing here reaches GitHub, ssh or this box's real stackshot files.

What a wrong answer costs: a tab that is not reachable by its link, Back or the keyboard, a read the owner did not ask for (or none when the tab
opens), a card missing or in the wrong place, a button in a view that is only a view, a phone that scrolls sideways, a tab that shows a
blank or an error where a reading is missing, markup built from data (a name that carries `<img onerror=…>` must stay text).

The page runs in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else skipped. Set SALA_MACHINES_SHOTS to a
folder to leave a screenshot of each width there.
"""

from __future__ import annotations

import base64
import contextlib
import json
import os

import pytest

from machines_world import settings as world_settings, world

SHOTS = os.environ.get("SALA_MACHINES_SHOTS")
DESKTOP = {"width": 1280, "height": 1600, "deviceScaleFactor": 1, "mobile": False}
PHONE = {"width": 390, "height": 844, "deviceScaleFactor": 1, "mobile": True}
# every api/machines request the page makes is counted (the real answer still comes back)
COUNT = """(() => { const real = window.fetch.bind(window); window.__mcFetches = 0;
  window.fetch = (url, opts) => { if (String(url).startsWith("api/machines")) window.__mcFetches++; return real(url, opts); }; })();"""
CARD = "#mc-grid .mc-card"


@contextlib.contextmanager
def fleet(served, monkeypatch, **kw):
    """The made-up fleet, read by the served app."""
    with world(**kw) as w:
        s, mine = served["settings"], world_settings(w)
        for k in ("stackshot_state", "fleet_names_file", "follow_machines_file", "follow_state_dir"):
            setattr(s, k, getattr(mine, k))
        monkeypatch.setenv("XDG_CONFIG_HOME", str(w.config))
        yield w


def wait(browser, expr: str, what: str, ms: int = 15000):
    v = browser.evaluate("""new Promise((res) => { const t0 = Date.now(); (function poll() {
      let v; try { v = (%s); } catch (e) { v = null; }
      if (v || Date.now() - t0 > %d) res(v || null); else setTimeout(poll, 100); })(); })""" % (expr, ms))
    assert v, what
    return v


def open_tab(served, browser, size: dict, hash_: str = "#machines", cards: bool = True) -> None:
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": COUNT})
    browser.open(f"{served['url']}/{hash_}", dark=True)
    browser.send("Emulation.setDeviceMetricsOverride", size)
    if cards:
        wait(browser, f'document.querySelectorAll("{CARD}").length > 0', "the machine cards")
    else:
        wait(browser, 'document.querySelector("#overview-pane") && document.body.classList.contains("overview-open")', "the Overview")


def screenshot(browser, name: str) -> None:
    if SHOTS:
        os.makedirs(SHOTS, exist_ok=True)
        with open(os.path.join(SHOTS, name), "wb") as f:
            f.write(base64.b64decode(browser.send("Page.captureScreenshot", {"format": "png"})["data"]))


# what the page shows, as a dict of text: the cards, the footer and the notes
SHOWN = """(() => {
  const t = (n) => n.textContent.replace(/\\s+/g, " ").trim();
  return {
    tab: document.querySelector("#overview-pane").dataset.tab,
    selected: [...document.querySelectorAll(".ov-tab")].map((a) => [a.id, a.getAttribute("aria-selected")]),
    count: document.querySelector("#ov-n-machines").textContent,
    cards: [...document.querySelectorAll("#mc-grid .mc-card")].map((c) => ({ name: c.querySelector(".mc-name").textContent, bad: c.classList.contains("mc-bad"),
      rows: [...c.querySelectorAll(".mc-vr")].map((r) => [...r.children].map(t)), fails: [...c.querySelectorAll(".mc-fail")].map(t), last: t(c.querySelector(".mc-fl")) })),
    footer: t(document.querySelector("#mc-upd")),
    none: t(document.querySelector("#mc-none")),
    controls: document.querySelectorAll("#ov-machines button, #ov-machines input, #ov-machines select, #ov-machines form, #ov-machines textarea").length,
    note: t(document.querySelector("#mc-note")),
  };
})()"""


def test_the_machines_tab_shows_the_cards_and_the_age_and_has_no_control_in_it(served, browser, monkeypatch):
    with fleet(served, monkeypatch):
        open_tab(served, browser, DESKTOP)
        m = browser.evaluate(SHOWN)
    assert m["tab"] == "machines" and m["selected"] == [["ov-tab-sessions", "false"], ["ov-tab-schedules", "false"], ["ov-tab-machines", "true"], ["ov-tab-usage", "false"]], m
    assert m["count"] == "6" and [c["name"] for c in m["cards"]] == ["alpha-box", "beta-box", "gamma-box", "delta-box", "eps-host", "zeta-host"]
    by = {c["name"]: c for c in m["cards"]}
    assert by["alpha-box"]["rows"] == [["claude code", "2.1.5", "latest ✓"], ["gbrain", "0.5.0", "→ 0.6.0"]] and by["alpha-box"]["last"] == "the machine the others follow"
    assert by["beta-box"]["rows"] == [["claude code", "2.1.2", "→ 2.1.5"]] and by["beta-box"]["last"] == "updates itself"
    assert by["eps-host"]["last"] == "follows alpha-box · last 10:43" and by["zeta-host"]["last"] == "follows alpha-box"
    assert by["delta-box"]["rows"] == [["claude code", "2.1.5", "offline"]] and by["gamma-box"]["rows"] == []
    # a failed update or setup is a line inside its card and marks the card; the others are not marked
    assert by["beta-box"]["bad"] and by["beta-box"]["fails"] == ["setup failed ✗ step 4", "update failed ✗ claude code 2.1.2"]
    assert [c["name"] for c in m["cards"] if c["bad"]] == ["beta-box"]
    assert m["footer"] == "updated 4 min ago" and m["none"] == "" and m["note"] == ""      # the age of the versions file's reading
    assert m["controls"] == 0, "the tab is a view: no button, field or form in it (its Reload is in the tab bar)"
    assert "runner" not in browser.evaluate("document.querySelector('#ov-machines').textContent").lower()   # no runner section is drawn
    screenshot(browser, "machines-1280.png")


@pytest.mark.parametrize("size,cols,name", [(DESKTOP, 3, "desktop"), (PHONE, 1, "phone")])
def test_the_layout_is_three_columns_of_cards_on_a_desktop_and_one_on_a_phone_and_never_scrolls_sideways(served, browser, monkeypatch, size, cols, name):
    with fleet(served, monkeypatch):
        open_tab(served, browser, size)
        m = browser.evaluate("""(() => { const vw = document.documentElement.clientWidth, cs = (s) => getComputedStyle(document.querySelector(s));
          const tracks = (s) => cs(s).gridTemplateColumns.split(" ").length;
          const top = (n) => Math.round(n.getBoundingClientRect().top);
          const over = [...document.querySelectorAll("#ov-machines *")].filter((n) => n.getBoundingClientRect().right > vw + 0.5 && n.getClientRects().length).map((n) => n.className || n.tagName);
          return { vw, doc: document.documentElement.scrollWidth, body: document.body.scrollWidth, pane: document.querySelector("#overview-pane").scrollWidth,
                   paneClient: document.querySelector("#overview-pane").clientWidth, panel: document.querySelector("#ov-machines").scrollWidth,
                   panelClient: document.querySelector("#ov-machines").clientWidth, over,
                   cardCols: tracks("#mc-grid"), cardsAcross: new Set([...document.querySelectorAll("#mc-grid .mc-card")].map((c) => top(c))).size,
                   tabs: [...document.querySelectorAll(".ov-tab")].map((a) => Math.round(a.getBoundingClientRect().width)), bar: [document.querySelector(".ov-bar").scrollWidth, document.querySelector(".ov-bar").clientWidth] }; })()""")
    assert m["doc"] <= m["vw"] and m["body"] <= m["vw"] + 1 and m["pane"] <= m["paneClient"] and m["panel"] <= m["panelClient"], m   # no sideways scroll
    assert m["over"] == [], m["over"]
    assert m["bar"][0] <= m["bar"][1], m                                                                                      # four tabs and the Reload fit the bar
    assert m["cardCols"] == cols, m
    assert m["cardsAcross"] == (2 if cols == 3 else 6), m                                                                      # six cards: two rows of three on a desktop, one to a line on a phone
    if SHOTS:
        browser.send("Emulation.setDeviceMetricsOverride", {**size, "height": 2400})   # the whole tab in one picture
    screenshot(browser, f"machines-{size['width']}.png")


def test_a_phone_shows_the_four_tabs_and_the_reload_in_one_bar_each_tab_a_comfortable_target(served, browser, monkeypatch):
    with fleet(served, monkeypatch):
        open_tab(served, browser, PHONE)
        m = browser.evaluate("""(() => ({ tabs: [...document.querySelectorAll(".ov-tab")].map((a) => { const r = a.getBoundingClientRect(); return [a.textContent.trim(), Math.round(r.width), Math.round(r.height)]; }),
          reload: (() => { const r = document.querySelector("#mc-reload").getBoundingClientRect(); return [Math.round(r.left), Math.round(r.width), getComputedStyle(document.querySelector("#sc-reload")).display]; })(),
          lastRight: Math.round(document.querySelector("#ov-tab-machines").getBoundingClientRect().right),
          clipped: [...document.querySelectorAll(".ov-tab")].filter((a) => a.scrollWidth > a.clientWidth + 1).map((a) => a.id),
          vw: document.documentElement.clientWidth }))()""")
    assert [t[0] for t in m["tabs"]] == ["Agents 1", "Schedules", "Machines 6", "Usage analysis"], m
    assert all(t[2] >= 44 for t in m["tabs"]) and m["reload"][0] + m["reload"][1] <= m["vw"] and m["reload"][2] == "none", m   # the Schedules tab's own Reload is hidden here
    assert m["lastRight"] <= m["reload"][0] and m["clipped"] == [] and m["reload"][1] >= 44, m                              # the Reload sits beside the last tab, never over its count


def test_the_tab_reads_when_it_opens_and_on_reload_and_never_by_itself(served, browser, monkeypatch):
    with fleet(served, monkeypatch):
        open_tab(served, browser, DESKTOP, "#sessions", cards=False)
        wait(browser, '!!document.querySelector("#sp-table")', "the Agents tab")
        assert browser.evaluate("window.__mcFetches") == 0 and browser.evaluate("document.querySelector('#ov-machines').offsetParent") is None   # not read, not shown
        browser.evaluate("document.querySelector('#ov-tab-machines').click(); ''")
        wait(browser, f'document.querySelectorAll("{CARD}").length === 6', "the cards after the tab opened")
        assert browser.evaluate("location.hash") == "#machines" and browser.evaluate("window.__mcFetches") == 1
        browser.evaluate("document.querySelector('#mc-reload').click(); ''")
        wait(browser, "window.__mcFetches === 2", "Reload reads again")
        browser.evaluate("document.querySelector('#ov-tab-sessions').click(); ''")
        assert browser.evaluate("document.querySelector('#overview-pane').dataset.tab") == "sessions" and browser.evaluate("document.querySelector('#ov-machines').offsetParent") is None
        browser.evaluate("document.querySelector('#ov-tab-machines').click(); ''")
        wait(browser, "window.__mcFetches === 3", "the tab reads again when it opens again")
        browser.evaluate("new Promise((r) => setTimeout(r, 1500))")
        assert browser.evaluate("window.__mcFetches") == 3                                               # and at no other time


def test_the_keyboard_reaches_the_tab_and_back_leaves_it(served, browser, monkeypatch):
    with fleet(served, monkeypatch):
        open_tab(served, browser, DESKTOP, "#sessions", cards=False)
        wait(browser, '!!document.querySelector("#sp-table")', "the Agents tab")
        for want in ("#schedules", "#machines"):   # Agents → Schedules → Machines
            browser.evaluate("""document.querySelector("#overview-pane .ov-tabs").dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true })); ''""")
            wait(browser, f'location.hash === "{want}"', f"ArrowRight reaches {want}")
        wait(browser, f'document.querySelectorAll("{CARD}").length === 6', "the cards")
        assert browser.evaluate("document.activeElement && document.activeElement.id") == "ov-tab-machines"
        browser.evaluate("document.querySelector('#overview-pane .ov-tabs').dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true })); ''")
        wait(browser, 'location.hash === "#usage"', "ArrowRight from Machines reaches Usage analysis, the last tab")
        browser.evaluate("document.querySelector('#overview-pane .ov-tabs').dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true })); ''")
        wait(browser, 'location.hash === "#sessions"', "ArrowRight from the last tab wraps to Agents")
        browser.evaluate("history.back(); ''")
        wait(browser, 'location.hash === "#usage"', "Back returns to the Usage analysis tab")
        browser.evaluate("history.back(); ''")
        wait(browser, 'location.hash === "#machines"', "Back returns to the Machines tab")
        assert browser.evaluate("document.querySelector('#overview-pane').dataset.tab") == "machines"


def test_a_missing_versions_file_is_a_line_in_the_tab_never_an_error_and_the_footer_goes_blank(served, browser, monkeypatch):
    with fleet(served, monkeypatch) as w:
        open_tab(served, browser, DESKTOP)
        m = browser.evaluate(SHOWN)
        assert m["cards"] and m["none"] == "" and m["note"] == "" and m["footer"].startswith("updated "), m
        (w.state / "site" / "versions.json").unlink()
        browser.evaluate("document.querySelector('#mc-reload').click(); ''")
        wait(browser, 'document.querySelectorAll("#mc-grid .mc-card").length === 0', "the cards are gone")
        m = browser.evaluate(SHOWN)
        assert m["none"] == "No reading yet. stackshot has not written the machines' versions yet.", m
        assert m["count"] == "" and m["footer"] == "", m
        screenshot(browser, "machines-no-reading.png")


def test_a_failed_read_keeps_the_last_answer_and_says_so(served, browser, monkeypatch):
    with fleet(served, monkeypatch):
        open_tab(served, browser, DESKTOP)
        browser.evaluate("""(() => { const real = window.fetch.bind(window);
          window.fetch = (url, opts) => String(url).startsWith("api/machines") ? Promise.resolve(new Response("nope", { status: 500 })) : real(url, opts); })(); ''""")
        browser.evaluate("document.querySelector('#mc-reload').click(); ''")
        wait(browser, 'document.querySelector("#mc-note").textContent.startsWith("Could not read the machines")', "the note")
        m = browser.evaluate(SHOWN)
        assert len(m["cards"]) == 6 and "the server answered 500" in m["note"], m


def test_names_from_the_files_are_text_never_markup(served, browser, monkeypatch):
    evil = '<img src=x onerror="window.__pwned=1">'
    with fleet(served, monkeypatch) as w:
        (w.state / "clients" / "fleet" / "d" / "machine.json").write_text(json.dumps({"letter": "d", "fleet": evil}))
        open_tab(served, browser, DESKTOP)
        wait(browser, 'document.querySelectorAll("#mc-grid .mc-card").length === 6', "the cards")
        m = browser.evaluate("""({ pwned: window.__pwned || 0, imgs: document.querySelectorAll("#ov-machines img").length,
          names: [...document.querySelectorAll("#mc-grid .mc-name")].map((n) => n.textContent) })""")
    assert m["pwned"] == 0 and m["imgs"] == 0 and evil in m["names"], m


def test_the_footer_words():
    pytest.importorskip("starlette")
    # the two small formatters machines.js exposes, evaluated on their own source in node when it is installed
    import shutil
    import subprocess
    from pathlib import Path
    node = shutil.which("node")
    if not node:
        pytest.skip("no node on PATH")
    src = (Path(__file__).resolve().parents[1] / "src" / "sala_web" / "static" / "machines.js").read_text()
    body = src[src.index("function agoText("):src.index("/* ---------- the machine cards")]
    js = body + "\nconsole.log(JSON.stringify([agoText(0), agoText(59), agoText(240), agoText(3599), agoText(3 * 3600), agoText(47 * 3600), agoText(3 * 86400)]));"
    out = subprocess.run([node, "-e", js], capture_output=True, text=True, timeout=30, check=True).stdout
    assert json.loads(out) == ["1 min ago", "1 min ago", "4 min ago", "59 min ago", "3 h ago", "47 h ago", "3 d ago"]
