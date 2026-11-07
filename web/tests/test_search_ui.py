"""Search: the sidebar's search box (on every page, the drawer's top on a phone) and the Search results page (#search?q=…), a page of
its own with the When / Agents / Content filters. The box focuses on Ctrl+K and on "/" (not while typing in a field), Escape leaves
it, Enter opens the page in a NEW TAB (in place in the installed app and at a phone's width, and where the browser blocks the new tab)
with the box's defaults (the last 6 hours, front agents only, messages only) written in the address; a filter
change searches again and rewrites the address in place; a reload and Back open the same search; a result opens its chat at its
entry; results are text and never markup; the Overview has no Search tab any more.

What a wrong answer costs: a box that steals "/" from the composer, defaults that hide or show the wrong things, an address that
does not reopen the search (a reload or a shared link losing it), a result that does not lead to its chat, a snippet that runs a
script because a transcript said `<img onerror=…>`, a page that scrolls sideways on a phone, or a return from a chat that searches
again for the results just read.

The page runs in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else skipped. The fake session `served`
makes is registered in a registry file written here (the sala state directory the app reads), its transcript gets fresh entries, and a
second, unregistered transcript is in another project folder. Chromium reads the app's real api/search; api/schedules is a stub.
"""

from __future__ import annotations

import json
import re
import time
from urllib.parse import parse_qs
from datetime import datetime, timezone

import pytest

from conftest import CWD, NAME, SID, transcript_file
from sala_web import transcript as TR

STUB = """(() => {
  window.__searchCalls = [];
  const real = window.fetch.bind(window);
  window.fetch = (url, opts) => {
    const u = String(url);
    if (u.startsWith("api/search")) window.__searchCalls.push(u);
    if (u.startsWith("api/schedules")) return Promise.resolve(new Response(JSON.stringify({ generated: null, timezone: "", timers: [], cron: [],
      counts: { timers: 0, cron: 0, flagged: 0, byReason: {}, packaged: 0 }, scopes: { user: true, system: true } }), { headers: { "Content-Type": "application/json" } }));
    return real(url, opts);
  };
})();"""

LOOSE_SID = "44444444-0000-4000-8000-000000000001"
ROW = "f0000000-0000-4000-8000-00000000000a"
XSS = '<img src=x onerror="window.__pwned=1"> zebra <script>window.__pwned=2</script>'


def iso(ago_s: float) -> str:
    return datetime.fromtimestamp(time.time() - ago_s, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def entry(kind: str, content, ago_s: float, uuid: str) -> str:
    return json.dumps({"type": kind, "uuid": uuid, "timestamp": iso(ago_s), "message": {"role": kind, "content": content}}) + "\n"


def prepare(served) -> None:
    """The registry, the fake session's fresh entries, and an unregistered transcript."""
    st = served["settings"].sala_state_dir
    st.mkdir(parents=True, exist_ok=True)
    (st / "sessions.json").write_text(json.dumps({"schema": 1, "sessions": {ROW: {
        "id": ROW, "name": NAME, "role": "front", "state": "live", "transcripts": [{"id": SID, "why": "add"}]}}}))
    with open(transcript_file(served), "a", encoding="utf-8") as f:
        f.write(entry("user", [{"type": "text", "text": "zebra question"}], 1800, "u-zq"))
        f.write(entry("assistant", [{"type": "text", "text": "the zebra answer"}], 1700, "a-za"))
        f.write(entry("assistant", [{"type": "tool_use", "id": "t9", "name": "Bash", "input": {"command": "echo zebra"}}], 1600, "a-zt"))
        f.write(entry("user", [{"type": "tool_result", "tool_use_id": "t9", "content": "zebra output"}], 1500, "u-zo"))
        f.write(entry("assistant", [{"type": "text", "text": XSS}], 1400, "a-xss"))
    loose = served["settings"].claude_dir / "projects" / TR.project_slug("/srv/demo/other") / f"{LOOSE_SID}.jsonl"
    loose.parent.mkdir(parents=True)
    loose.write_text(entry("assistant", [{"type": "text", "text": "a zebra from a headless run"}], 1300, "l-1"))


DEFAULTS = {"hours": "6", "front": "1", "back": "0", "sub": "0", "unknown": "0", "messages": "1", "tools": "0", "output": "0", "thinking": "0"}
READY = """typeof state !== "undefined" && state.byName.has(%s) && !!document.querySelector("#side-q")""" % json.dumps(NAME)


# Enter in the box opens a new tab (the target of test_enter_in_the_box_opens_the_results_in_a_new_tab...): every other test here is about the
# results page, so unless it asks for `popups` the page answers window.open with null, a browser that blocks the tab, and the search runs in place
NO_POPUPS = "window.open = () => null;"
# a window.open that records its calls and then opens for real
SPY_OPEN = """(() => { const real = window.open.bind(window); window.__opens = [];
  window.open = (...a) => { window.__opens.push(a); return real(...a); }; })();"""
# the installed app emulated where the page asks (test_back_button.py: DevTools cannot emulate display-mode)
STANDALONE = """(() => { const real = window.matchMedia.bind(window);
  window.matchMedia = (q) => { const m = real(q); if (!/display-mode:\\s*standalone/.test(q)) return m;
    return new Proxy(m, { get: (t, k) => (k === "matches" ? true : typeof t[k] === "function" ? t[k].bind(t) : t[k]) }); }; })();"""


def open_page(served, browser, hash_: str = "#sessions", width: int = 1280, prepared: bool = False, popups: bool = False, standalone: bool = False) -> None:
    if not prepared:
        prepare(served)
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": STUB})
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": SPY_OPEN if popups else NO_POPUPS})
    if standalone:
        browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": STANDALONE})
    browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 844, "deviceScaleFactor": 1, "mobile": width <= 760})
    browser.send("Page.navigate", {"url": f"{served['url']}/{hash_}"})
    wait(browser, READY, "the page and its session list")


def address(browser) -> dict:
    """The Search page's address as a dict (the parameters after #search?)."""
    h = browser.evaluate("location.hash")
    assert h.startswith("#search?"), h
    return {k: v[0] for k, v in parse_qs(h[len("#search?"):], keep_blank_values=True).items()}


def key(browser, k: str, code: str, vk: int, modifiers: int = 0, text: str = "") -> None:
    """A real key press (DevTools input), so the page's own keydown handlers and the default action run."""
    down = {"type": "keyDown", "key": k, "code": code, "windowsVirtualKeyCode": vk, "nativeVirtualKeyCode": vk, "modifiers": modifiers}
    if text:
        down["text"] = text
    browser.send("Input.dispatchKeyEvent", down)
    browser.send("Input.dispatchKeyEvent", {"type": "keyUp", "key": k, "code": code, "windowsVirtualKeyCode": vk, "nativeVirtualKeyCode": vk, "modifiers": modifiers})


def box_search(browser, q: str) -> None:
    """Type the query in the sidebar's box and press Enter there (a real key event, so the form's own submission runs)."""
    browser.evaluate("""(() => { const i = document.querySelector("#side-q"); i.focus(); i.value = %s; })()""" % json.dumps(q))
    key(browser, "Enter", "Enter", 13, text="\r")


def wait(browser, expr: str, what: str, ms: int = 15000):
    v = browser.evaluate("""new Promise((res) => { const t0 = Date.now(); (function poll() {
      let v; try { v = (%s); } catch (e) { v = null; }
      if (v || Date.now() - t0 > %d) res(v || null); else setTimeout(poll, 100); })(); })""" % (expr, ms))
    assert v, what
    return v


def hits(browser) -> list[dict]:
    return browser.evaluate("""[...document.querySelectorAll("#se-hits .se-hit")].map((li) => ({
      text: li.querySelector(".se-x").textContent, marks: [...li.querySelectorAll("mark")].map((m) => m.textContent),
      name: li.querySelector(".se-name").textContent, role: li.querySelector(".se-role").textContent, kind: li.querySelector(".se-kind").textContent,
      sub: !!li.querySelector(".se-sub"), open: li.classList.contains("open"), gone: !!li.querySelector(".se-gone"),
      href: (li.querySelector("a") || {}).getAttribute ? li.querySelector("a").getAttribute("href") : null }))""")


def test_the_markup_has_the_box_in_the_sidebar_the_page_of_its_own_and_no_overview_tab():
    from sala_web.app import STATIC
    index = (STATIC / "index.html").read_text()
    tabs = re.findall(r'<a id="ov-tab-(\w+)" class="ov-tab" role="tab" href="#(\w+)"', index)
    assert tabs == [("sessions", "sessions"), ("schedules", "schedules"), ("machines", "machines"), ("usage", "usage")]                  # the Overview's Search tab is gone
    assert "ov-search" not in index and "ov-tab-search" not in index and 'id="se-q"' not in index
    side = index[index.index('<aside id="sidebar">'):index.index("</aside>")]
    # the box is at the top of the sidebar: just under its header, before the views and the session list; it has no filters
    assert side.index('id="side-search"') < side.index('class="side-top"') < side.index('id="session-list"')
    form = side[side.index('<form id="side-search"'):side.index("</form>")]
    assert 'role="search"' in form and len(re.findall(r"<input", form)) == 1 and 'type="search"' in form
    assert '<section id="search-pane" class="pane"' in index and 'id="se-form"' in index
    assert 'static/search.js?v={{v}}' in index and 'static/search.css?v={{v}}' in index


def test_ctrl_k_and_slash_focus_the_box_and_escape_leaves_it(served, browser):
    open_page(served, browser)
    focused = 'document.activeElement === document.querySelector("#side-q")'
    shown = 'document.getElementById("sidebar").getBoundingClientRect().left === 0'
    assert browser.evaluate(focused) is False
    key(browser, "k", "KeyK", 75, modifiers=2)                                                 # Ctrl+K
    wait(browser, focused, "Ctrl+K puts the cursor in the box")
    wait(browser, shown, "a wide screen's sidebar is shown while the box has the cursor")
    key(browser, "Escape", "Escape", 27)
    wait(browser, "!(%s)" % focused, "Escape leaves the box")
    wait(browser, "document.getElementById('sidebar').getBoundingClientRect().right <= 0", "and the sidebar goes again")
    key(browser, "/", "Slash", 191, text="/")
    wait(browser, focused, '"/" puts the cursor in the box')
    assert browser.evaluate('document.querySelector("#side-q").value') == ""                   # the key itself is not typed
    key(browser, "Escape", "Escape", 27)
    wait(browser, "!(%s)" % focused, "Escape leaves the box again")
    # "/" while typing in a field is the field's: open the chat and type it in the composer
    browser.evaluate('go("#s=%s")' % NAME)
    wait(browser, '!!document.querySelector("#composer [contenteditable=true]")', "the composer")
    browser.evaluate('document.querySelector("#composer [contenteditable=true]").focus()')
    key(browser, "/", "Slash", 191, text="/")
    time.sleep(0.2)
    assert browser.evaluate(focused) is False
    assert "/" in browser.evaluate('document.querySelector("#composer [contenteditable=true]").textContent')
    key(browser, "k", "KeyK", 75, modifiers=2)                                                 # Ctrl+K works from anywhere
    wait(browser, focused, "Ctrl+K from the composer")


def test_enter_opens_the_results_page_with_the_defaults_in_the_address(served, browser):
    open_page(served, browser)
    box_search(browser, "")
    time.sleep(0.2)
    assert browser.evaluate("location.hash") == "#sessions" and browser.evaluate("window.__searchCalls.length") == 0   # nothing typed: nothing opens
    box_search(browser, "zebra")
    wait(browser, 'document.body.classList.contains("search-open") && document.querySelectorAll("#se-hits .se-hit").length === 3', "the results page")
    assert address(browser) == {"q": "zebra", **DEFAULTS}
    calls = browser.evaluate("window.__searchCalls")
    assert len(calls) == 1 and dict(re.findall(r"([a-z]+)=([^&]*)", calls[0])) == {"q": "zebra", **DEFAULTS}, calls
    s = browser.evaluate("""(() => ({
      overview: document.body.classList.contains("overview-open"), title: document.querySelector("#title .name").textContent,
      pane: getComputedStyle(document.querySelector("#search-pane")).display, ov: getComputedStyle(document.querySelector("#overview-pane")).display,
      chips: [...document.querySelectorAll("#se-range .se-chip")].map((c) => [c.textContent, c.getAttribute("aria-pressed")]),
      boxes: Object.fromEntries([...document.querySelectorAll("#se-form input[data-box]")].map((b) => [b.dataset.box, b.checked])),
      labels: [...document.querySelectorAll("#se-form .se-row")].map((r) => r.textContent.replace(/\\s+/g, " ").trim()),
      box: document.querySelector("#side-q").value, focused: document.activeElement === document.querySelector("#side-q") }))()""")
    assert (s["overview"], s["title"], s["pane"], s["ov"]) == (False, "Search", "block", "none"), s
    assert s["chips"] == [["1 h", "false"], ["6 h", "true"], ["24 h", "false"], ["3 days", "false"], ["7 days", "false"], ["Pick dates…", "false"]]
    assert s["boxes"] == {"front": True, "back": False, "sub": False, "unknown": False, "messages": True, "tools": False, "output": False, "thinking": False}
    assert s["labels"][0].startswith("When 1 h 6 h") and s["labels"][2].startswith("Agents Front agents") and s["labels"][3].startswith("Content Messages")
    assert s["box"] == "zebra" and s["focused"] is False
    rows = hits(browser)
    # the fake session's three messages (front); its tool call and the headless run (role unknown) are off by default
    assert {r["text"] for r in rows} == {"zebra question", "the zebra answer", XSS} and all(r["role"] == "front" and r["kind"] == "message" for r in rows)
    mine = next(r for r in rows if r["text"] == "the zebra answer")
    assert (mine["name"], mine["open"], mine["href"], mine["sub"], mine["marks"]) == (NAME, True, "#s=" + NAME, False, ["zebra"])
    summary = browser.evaluate('document.querySelector("#se-summary").textContent')
    assert re.match(r"^3 matches for “zebra”, newest first · 6 h to \w{3} \w{3} \d+(st|nd|rd|th) \d\d:\d\d \+04 · searched in \d+(\.\d)? s$", summary), summary
    counts = browser.evaluate("""Object.fromEntries([...document.querySelectorAll("#se-form input[data-box]")].map((b) => [b.dataset.box, b.parentElement.querySelector("small").textContent]))""")
    assert counts["tools"] == "(1)" and counts["unknown"] == "(1)" and counts["front"] == "(3)", counts


def page_targets(browser) -> dict:
    return {t["targetId"]: t for t in browser.call("Target.getTargets")["targetInfos"] if t["type"] == "page"}


def other_tab(browser, before: set, what: str, ms: int = 10000) -> str:
    """The session of the page tab that opened after `before` (attached; closed with the browser)."""
    t0 = time.time()
    while time.time() - t0 < ms / 1000:
        new = [i for i in page_targets(browser) if i not in before]
        if new:
            return browser.call("Target.attachToTarget", {"targetId": new[0], "flatten": True})["sessionId"]
        time.sleep(0.1)
    raise AssertionError(what)


def tab_eval(browser, session: str, expr: str):
    r = browser.call("Runtime.evaluate", {"expression": expr, "awaitPromise": True, "returnByValue": True}, session)
    return r.get("result", {}).get("value")


def tab_wait(browser, session: str, expr: str, what: str, ms: int = 15000):
    t0 = time.time()
    while time.time() - t0 < ms / 1000:
        v = tab_eval(browser, session, "(() => { try { return (%s); } catch (e) { return null; } })()" % expr)
        if v:
            return v
        time.sleep(0.1)
    raise AssertionError(what)


def test_enter_in_the_box_opens_the_results_in_a_new_tab_and_the_page_stays_as_it_was(served, browser):
    open_page(served, browser, f"#s={NAME}", popups=True)
    browser.evaluate('document.querySelector("#chat").scrollTop = 7; document.querySelector("#composer [contenteditable=true]").textContent = "half a thought"')
    start = browser.evaluate("""({ hash: location.hash, href: location.href.split("#")[0], depth: history.length, chat: document.querySelector("#chat").innerHTML.length,
      scroll: document.querySelector("#chat").scrollTop, composer: document.querySelector("#composer [contenteditable=true]").textContent })""")
    before = set(page_targets(browser))
    box_search(browser, "zebra")
    tab = other_tab(browser, before, "a new tab opens")
    tab_wait(browser, tab, 'document.body.classList.contains("search-open") && document.querySelectorAll("#se-hits .se-hit").length === 3', "the new tab shows the results")
    got = tab_eval(browser, tab, """({ hash: location.hash, href: location.href.split("#")[0], opener: window.opener, summary: document.querySelector("#se-summary").textContent,
      query: document.querySelector("#se-query").value })""")
    want = "#search?" + "&".join(f"{k}={v}" for k, v in {"q": "zebra", **DEFAULTS}.items())
    assert got["hash"] == want and got["href"] == start["href"] and got["opener"] is None and got["query"] == "zebra", got   # the same page, the search in the address
    assert "3 matches for “zebra”" in got["summary"]
    # the tab he was on: the same page, chat, scroll and half-typed message, no search made, one call to window.open
    time.sleep(0.3)
    now = browser.evaluate("""({ hash: location.hash, href: location.href.split("#")[0], depth: history.length, chat: document.querySelector("#chat").innerHTML.length,
      scroll: document.querySelector("#chat").scrollTop, composer: document.querySelector("#composer [contenteditable=true]").textContent })""")
    assert now == start, (now, start)
    assert browser.evaluate("[window.__searchCalls.length, document.body.classList.contains('search-open'), window.__opens.length]") == [0, False, 1]
    assert browser.evaluate("window.__opens[0][1]") == "_blank"
    assert browser.evaluate('document.activeElement === document.querySelector("#side-q")') is False
    box_search(browser, "   ")                                                                  # nothing typed: no tab either
    time.sleep(0.3)
    assert len(page_targets(browser)) == len(before) + 1 and browser.evaluate("window.__opens.length") == 1


@pytest.mark.parametrize("how", ["phone", "installed app"])
def test_where_a_new_window_would_leave_sala_the_search_opens_in_place(served, browser, how):
    """A phone's width and the installed app (replaceMode): the results page replaces this one; no window.open, no second tab."""
    phone = how == "phone"
    open_page(served, browser, "#sessions", width=390 if phone else 1280, popups=True, standalone=not phone)
    assert browser.evaluate("replaceMode()") is True
    if phone:
        browser.evaluate('document.querySelector("#side-open").click()')
        wait(browser, 'document.body.classList.contains("side-open")', "the drawer")
    before = set(page_targets(browser))
    box_search(browser, "zebra")
    wait(browser, 'document.body.classList.contains("search-open") && document.querySelectorAll("#se-hits .se-hit").length === 3', "the results page, here")
    assert address(browser) == {"q": "zebra", **DEFAULTS}
    assert browser.evaluate("window.__opens.length") == 0 and set(page_targets(browser)) == before


def test_a_browser_that_blocks_the_new_tab_gets_the_search_in_place(served, browser):
    open_page(served, browser, "#sessions")                                                    # popups=False: window.open answers null
    assert browser.evaluate("window.open('about:blank', '_blank')") is None
    assert browser.evaluate("replaceMode()") is False
    before = set(page_targets(browser))
    box_search(browser, "zebra")
    wait(browser, 'document.body.classList.contains("search-open") && document.querySelectorAll("#se-hits .se-hit").length === 3', "the results page, here")
    assert address(browser) == {"q": "zebra", **DEFAULTS}
    assert set(page_targets(browser)) == before


@pytest.mark.parametrize("width", [1280, 390])
def test_a_search_from_the_box_opens_at_6_h_and_an_address_that_names_its_hours_keeps_them(served, browser, width):
    pressed = """[...document.querySelectorAll("#se-range .se-chip")].filter((c) => c.getAttribute("aria-pressed") === "true").map((c) => c.textContent)"""
    open_page(served, browser, "#sessions", width=width)
    if width <= 760:
        browser.evaluate('document.querySelector("#side-open").click()')
        wait(browser, 'document.body.classList.contains("side-open")', "the drawer")
    box_search(browser, "zebra")
    wait(browser, 'document.body.classList.contains("search-open") && document.querySelectorAll("#se-hits .se-hit").length === 3', "the results page")
    assert browser.evaluate(pressed) == ["6 h"]
    assert address(browser)["hours"] == "6"
    calls = browser.evaluate("window.__searchCalls")
    assert len(calls) == 1 and dict(re.findall(r"([a-z]+)=([^&]*)", calls[0]))["hours"] == "6", calls
    assert "6 h to " in browser.evaluate('document.querySelector("#se-summary").textContent')
    # an old link that names its hours keeps them: opened fresh, it is at 1 h, not at the box's 6 h
    browser.send("Page.navigate", {"url": "about:blank"})
    browser.send("Page.navigate", {"url": f"{served['url']}/#search?q=zebra&hours=1"})
    wait(browser, READY + ' && document.querySelectorAll("#se-hits .se-hit").length === 3', "the old link's results")
    assert browser.evaluate(pressed) == ["1 h"]
    assert address(browser)["hours"] == "1"
    calls = browser.evaluate("window.__searchCalls")
    assert len(calls) == 1 and dict(re.findall(r"([a-z]+)=([^&]*)", calls[0]))["hours"] == "1", calls


def test_a_filter_change_searches_again_and_rewrites_the_address_in_place(served, browser):
    open_page(served, browser)
    box_search(browser, "zebra")
    wait(browser, 'document.querySelectorAll("#se-hits .se-hit").length === 3', "three results")
    depth = browser.evaluate("history.length")
    browser.evaluate('document.querySelector("#se-tools").click()')
    wait(browser, 'window.__searchCalls.length === 2 && document.querySelectorAll("#se-hits .se-hit").length === 4', "tool calls join the results")
    assert address(browser) == {"q": "zebra", **DEFAULTS, "tools": "1"}
    assert "tools=1" in browser.evaluate("window.__searchCalls[1]")
    browser.evaluate('document.querySelector("#se-unknown").click()')
    wait(browser, 'window.__searchCalls.length === 3 && document.querySelectorAll("#se-hits .se-hit").length === 5', "the unknown bucket shows")
    assert address(browser)["unknown"] == "1"
    assert browser.evaluate('document.querySelector("#se-think-note").hidden') is True
    browser.evaluate('document.querySelector("#se-thinking").click()')
    wait(browser, "window.__searchCalls.length === 4", "thinking searches")
    note = browser.evaluate('(() => { const n = document.querySelector("#se-think-note"); return [n.hidden, getComputedStyle(n).display, n.textContent]; })()')
    assert note[0] is False and note[1] != "none" and "only about 6% of thinking blocks" in note[2]
    browser.evaluate('document.querySelector("#se-range [data-hours=\\"24\\"]").click()')
    wait(browser, "window.__searchCalls.length === 5", "a range searches again")
    wait(browser, 'document.querySelector("#se-summary").textContent.includes("24 h to ")', "the summary says the range")
    assert address(browser)["hours"] == "24" and "hours=24&" in browser.evaluate("window.__searchCalls[4]") + "&"
    # picking dates shows the pickers in the page's zone and searches once a From is chosen; the address then has from, not hours
    browser.evaluate('document.querySelector("#se-range [data-hours=\\"dates\\"]").click()')
    assert browser.evaluate('[document.querySelector("#se-dates").hidden, getComputedStyle(document.querySelector("#se-dates")).display, document.querySelector("#se-zone").textContent]') == [False, "flex", "in +04"]
    assert browser.evaluate("window.__searchCalls.length") == 5 and address(browser)["hours"] == "24"   # no From yet: nothing sent, the address as it was
    browser.evaluate("""(() => { const f = document.querySelector("#se-from"); f.value = "2000-01-01T00:00"; f.dispatchEvent(new Event("change", { bubbles: true })); })()""")
    wait(browser, "window.__searchCalls.length === 6", "dates search")
    a = address(browser)
    assert a["from"] == "2000-01-01T00:00" and "hours" not in a and "from=2000-01-01T00%3A00" in browser.evaluate("window.__searchCalls[5]")
    assert browser.evaluate("history.length") == depth                                         # rewritten in place: no entry per filter


def test_a_reload_and_a_shared_link_open_the_same_search(served, browser):
    open_page(served, browser)
    box_search(browser, "zebra")
    wait(browser, 'document.querySelectorAll("#se-hits .se-hit").length === 3', "three results")
    browser.evaluate('document.querySelector("#se-tools").click()')
    browser.evaluate('document.querySelector("#se-range [data-hours=\\"1\\"]").click()')
    wait(browser, 'window.__searchCalls.length === 3 && document.querySelectorAll("#se-hits .se-hit").length === 4', "the search with tool calls over 1 h")
    want = browser.evaluate("location.hash")
    browser.send("Page.reload")
    wait(browser, READY + ' && location.hash === %s && document.querySelectorAll("#se-hits .se-hit").length === 4' % json.dumps(want), "the reload opens the same search")
    assert browser.evaluate("window.__searchCalls") and len(browser.evaluate("window.__searchCalls")) == 1   # one search, at load
    got = browser.evaluate("""(() => ({ boxes: Object.fromEntries([...document.querySelectorAll("#se-form input[data-box]")].map((b) => [b.dataset.box, b.checked])),
      range: [...document.querySelectorAll("#se-range .se-chip")].filter((c) => c.getAttribute("aria-pressed") === "true").map((c) => c.textContent),
      box: document.querySelector("#side-q").value, open: document.body.classList.contains("search-open") }))()""")
    assert got == {"boxes": {"front": True, "back": False, "sub": False, "unknown": False, "messages": True, "tools": True, "output": False, "thinking": False},
                   "range": ["1 h"], "box": "zebra", "open": True}, got
    # the same address in a fresh tab (a shared link): the same search
    browser.send("Page.navigate", {"url": "about:blank"})
    browser.send("Page.navigate", {"url": f"{served['url']}/{want}"})
    wait(browser, READY + ' && document.querySelectorAll("#se-hits .se-hit").length === 4', "a shared link opens the same search")


def test_a_result_opens_its_chat_at_the_entry_and_back_finds_the_results_again(served, browser):
    open_page(served, browser)
    box_search(browser, "zebra answer")
    wait(browser, 'document.querySelectorAll("#se-hits .se-hit").length === 1', "the result")
    want = browser.evaluate("location.hash")
    browser.evaluate('document.querySelector("#se-hits a.se-link").click()')
    wait(browser, 'location.hash === "#s=%s"' % NAME, "the session's chat opens")
    wait(browser, '!!document.querySelector("#chat .msg.search-hit")', "the entry is lit")
    assert browser.evaluate('document.querySelector("#chat .msg.search-hit").dataset.uuid') == "a-za"
    assert browser.evaluate('document.querySelector("#chat .msg.search-hit").textContent').count("zebra answer") == 1
    assert browser.evaluate("document.body.classList.contains('search-open')") is False
    browser.evaluate("history.back()")                                                        # a wide browser: every view is an entry
    wait(browser, 'location.hash === %s && document.querySelectorAll("#se-hits .se-hit").length === 1' % json.dumps(want), "Back finds the results")
    assert browser.evaluate("window.__searchCalls.length") == 1                               # read from memory, not searched again
    browser.evaluate("history.back()")
    wait(browser, 'location.hash === "#sessions" && document.body.classList.contains("overview-open")', "and Back again is where the search started")


def test_a_snippet_is_text_never_markup(served, browser):
    open_page(served, browser)
    box_search(browser, "zebra")
    wait(browser, 'document.querySelectorAll("#se-hits .se-hit").length === 3', "the results")
    assert browser.evaluate('document.querySelectorAll("#se-hits img, #se-hits script").length') == 0
    assert browser.evaluate("window.__pwned === undefined")
    xss = [r for r in hits(browser) if "onerror" in r["text"]]
    assert len(xss) == 1 and xss[0]["text"].startswith('<img src=x onerror="window.__pwned=1"> zebra <script>')
    assert xss[0]["marks"] == ["zebra"]


def test_the_overview_has_four_tabs_and_an_old_search_link_opens_the_page(served, browser):
    open_page(served, browser, "#sessions")
    got = browser.evaluate("""(() => ({ tabs: [...document.querySelectorAll("#overview-pane .ov-tab")].map((t) => t.getAttribute("href")),
      panels: [...document.querySelectorAll("#overview-pane .ov-panel")].map((p) => p.id) }))()""")
    assert got == {"tabs": ["#sessions", "#schedules", "#machines", "#usage"], "panels": ["ov-agents", "ov-schedules", "ov-machines", "ov-usage"]}, got
    seen = []
    for _ in range(4):
        browser.evaluate("""document.querySelector('#overview-pane .ov-tab[aria-selected="true"]').dispatchEvent(
          new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }))""")
        wait(browser, 'location.hash !== %s' % json.dumps(seen[-1] if seen else "#sessions"), "the tab changes")
        seen.append(browser.evaluate("location.hash"))
    assert seen == ["#schedules", "#machines", "#usage", "#sessions"]                                      # the arrows walk four tabs and wrap
    # an old #search link (the tab it was) opens the Search page, which asks for a query and searches nothing
    browser.evaluate('go("#search")')
    wait(browser, 'document.body.classList.contains("search-open")', "the Search page")
    assert "Type something in the search box" in browser.evaluate('document.querySelector("#se-summary").textContent')
    assert browser.evaluate("window.__searchCalls.length") == 0


def test_the_phone_has_the_box_at_the_drawers_top_and_does_not_scroll_sideways(served, browser):
    open_page(served, browser, "#sessions", width=390)
    key(browser, "/", "Slash", 191, text="/")                                                   # a phone with a keyboard: the drawer opens on the box
    wait(browser, 'document.body.classList.contains("side-open") && document.activeElement === document.querySelector("#side-q")', "the drawer opens with the cursor in the box")
    time.sleep(0.35)                                                                           # the slide is over
    m = browser.evaluate("""(() => { const r = (s) => { const b = document.querySelector(s).getBoundingClientRect(); return { top: b.top, bottom: b.bottom, left: b.left, right: b.right, height: b.height }; };
      return { box: r("#side-q"), head: r("#sidebar .side-head"), top: r("#sidebar .side-top"), sb: r("#sidebar")}; })()""")
    assert m["head"]["bottom"] <= m["box"]["top"] + 0.5 and m["box"]["bottom"] <= m["top"]["top"] + 0.5, m      # under the header, above the views
    assert m["box"]["left"] >= m["sb"]["left"] and m["box"]["right"] <= m["sb"]["right"] and m["box"]["height"] >= 44, m
    key(browser, "Escape", "Escape", 27)
    wait(browser, '!document.body.classList.contains("side-open") && document.activeElement !== document.querySelector("#side-q")', "Escape leaves the box and the drawer")
    # a tap on the toggle, the box, Enter: the page opens with the drawer closed
    browser.evaluate('document.querySelector("#side-open").click()')
    wait(browser, 'document.body.classList.contains("side-open")', "the drawer")
    box_search(browser, "zebra")
    wait(browser, '!document.body.classList.contains("side-open") && document.querySelectorAll("#se-hits .se-hit").length === 3', "the results, the drawer closed")
    assert address(browser) == {"q": "zebra", **DEFAULTS}
    browser.evaluate('document.querySelector("#se-tools").click()')
    browser.evaluate('document.querySelector("#se-unknown").click()')
    wait(browser, 'window.__searchCalls.length === 3 && document.querySelectorAll("#se-hits .se-hit").length === 5', "the wider search")
    m = browser.evaluate("""(() => ({ vw: document.documentElement.clientWidth, doc: document.documentElement.scrollWidth, body: document.body.scrollWidth,
      pane: document.querySelector("#search-pane").scrollWidth, paneClient: document.querySelector("#search-pane").clientWidth,
      chips: [...document.querySelectorAll("#se-range .se-chip")].map((c) => Math.round(c.getBoundingClientRect().height)),
      right: Math.max(...[...document.querySelectorAll("#search-pane *")].map((e) => e.getBoundingClientRect().right)) }))()""")
    assert m["doc"] <= m["vw"] and m["body"] <= m["vw"] and m["pane"] <= m["paneClient"] and m["right"] <= m["vw"], m
    assert min(m["chips"]) >= 30, m


def test_on_a_phone_a_result_is_an_entry_and_back_finds_the_results_again(served, browser):
    """A phone replaces the entry for every move between views, except opening a search result: that one pushes, so Back from the
    result's chat is the results page (the same query and filters, read from its address), not whatever was before it."""
    open_page(served, browser, "#sessions", width=390)
    assert browser.evaluate("replaceMode()") is True
    pos = lambda: browser.send("Page.getNavigationHistory")["currentIndex"]
    start = pos()
    browser.evaluate('go("#s=%s")' % NAME)                                                     # another move on a phone: replaced
    wait(browser, 'location.hash === "#s=%s"' % NAME, "the chat")
    assert pos() == start
    browser.evaluate('go("#sessions")')
    wait(browser, 'location.hash === "#sessions" && document.body.classList.contains("overview-open")', "the Overview")
    assert pos() == start
    browser.evaluate('document.querySelector("#side-open").click()')
    wait(browser, 'document.body.classList.contains("side-open")', "the drawer")
    box_search(browser, "zebra")
    wait(browser, 'nav.busy === null && nav.pending === null && !document.body.classList.contains("side-open") && document.querySelectorAll("#se-hits .se-hit").length === 3', "the results")
    browser.evaluate('document.querySelector("#se-tools").click()')                           # a filter: the address rewritten in place
    wait(browser, 'window.__searchCalls.length === 2 && document.querySelectorAll("#se-hits .se-hit").length === 4', "the wider search")
    want = browser.evaluate("location.hash")
    assert pos() == start                                                                      # the search page replaced the entry too
    browser.evaluate('document.querySelector("#se-hits a.se-link").click()')
    wait(browser, 'location.hash === "#s=%s" && !document.body.classList.contains("search-open")' % NAME, "the result's chat opens")
    assert pos() == start + 1                                                                  # the result pushed an entry
    browser.evaluate("history.back()")
    wait(browser, 'location.hash === %s && document.body.classList.contains("search-open") && document.querySelectorAll("#se-hits .se-hit").length === 4' % json.dumps(want),
         "Back finds the same results")
    assert pos() == start
    assert address(browser) == {"q": "zebra", **DEFAULTS, "tools": "1"}
    assert browser.evaluate('document.querySelector("#se-tools").checked') is True
    assert browser.evaluate("window.__searchCalls.length") == 2                               # read from memory, not searched again
    browser.evaluate('go("#sessions")')                                                        # and the next move replaces again
    wait(browser, 'location.hash === "#sessions"', "the Overview")
    assert pos() == start


def results_box_search(browser, q: str) -> None:
    """Type the query in the results page's own box and press Enter there (a real key event)."""
    browser.evaluate("""(() => { const i = document.querySelector("#se-query"); i.focus(); i.value = %s; })()""" % json.dumps(q))
    key(browser, "Enter", "Enter", 13, text="\r")


def test_the_results_page_has_its_own_query_box_that_searches_again_with_the_filters_kept(served, browser):
    from sala_web.app import STATIC
    index = (STATIC / "index.html").read_text()
    pane = index[index.index('<section id="search-pane"'):]
    assert pane.index('id="se-query"') < pane.index('id="se-range"') and '<input id="se-query" type="search"' in pane   # the box is above the switches
    open_page(served, browser)
    box_search(browser, "zebra")
    wait(browser, 'document.querySelectorAll("#se-hits .se-hit").length === 3', "three results")
    box = browser.evaluate("""(() => { const q = document.querySelector("#se-query"), s = document.querySelector("#side-q"), r = (e) => e.getBoundingClientRect();
      return { value: q.value, shown: r(q).width > 200, aboveWhen: r(q).bottom <= r(document.querySelector("#se-range")).top, max: q.maxLength,
               look: [getComputedStyle(q).height, getComputedStyle(q).borderRadius], sideLook: [getComputedStyle(s).height, getComputedStyle(s).borderRadius] }; })()""")
    assert box["value"] == "zebra" and box["shown"] and box["aboveWhen"] and box["max"] == 200 and box["look"] == box["sideLook"], box   # prefilled from the address
    browser.evaluate('document.querySelector("#se-tools").click()')
    browser.evaluate('document.querySelector("#se-range [data-hours=\\"1\\"]").click()')
    wait(browser, 'window.__searchCalls.length === 3 && document.querySelectorAll("#se-hits .se-hit").length === 4', "the search with tool calls over 1 h")
    depth = browser.evaluate("history.length")
    # an empty query does what the sidebar's box does: nothing
    results_box_search(browser, "   ")
    time.sleep(0.3)
    assert browser.evaluate("window.__searchCalls.length") == 3 and address(browser)["q"] == "zebra"
    # a new query: the filters stay, the address follows in place, the sidebar's box follows too
    results_box_search(browser, "  answer ")
    wait(browser, 'window.__searchCalls.length === 4 && document.querySelectorAll("#se-hits .se-hit").length === 1', "the new query's result")
    assert address(browser) == {"q": "answer", **DEFAULTS, "hours": "1", "tools": "1"}
    call = dict(re.findall(r"([a-z]+)=([^&]*)", browser.evaluate("window.__searchCalls[3]")))
    assert call == {"q": "answer", **DEFAULTS, "hours": "1", "tools": "1"}, call
    assert browser.evaluate("history.length") == depth                                        # rewritten in place, like a switch
    assert "“answer”" in browser.evaluate('document.querySelector("#se-summary").textContent')
    assert hits(browser)[0]["text"] == "the zebra answer"
    assert browser.evaluate('[document.querySelector("#se-query").value, document.querySelector("#side-q").value]') == ["answer", "answer"]
    # a switch afterwards keeps the new query; a reload opens the same search with the box filled
    browser.evaluate('document.querySelector("#se-output").click()')
    wait(browser, "window.__searchCalls.length === 5", "a switch searches again")
    assert address(browser)["q"] == "answer" and address(browser)["output"] == "1"
    want = browser.evaluate("location.hash")
    browser.send("Page.reload")
    wait(browser, READY + ' && location.hash === %s && document.querySelector("#se-query").value === "answer"' % json.dumps(want), "the reload fills the box")
    # Back leaves the page as for the switches (the entry was rewritten, not added)
    browser.evaluate("history.back()")
    wait(browser, 'location.hash === "#sessions"', "Back is where the search started")


def test_the_phone_results_box_takes_the_full_width_and_searches_again(served, browser):
    open_page(served, browser, "#sessions", width=390)
    browser.evaluate('document.querySelector("#side-open").click()')
    wait(browser, 'document.body.classList.contains("side-open")', "the drawer")
    box_search(browser, "zebra")
    wait(browser, '!document.body.classList.contains("side-open") && document.querySelectorAll("#se-hits .se-hit").length === 3', "the results")
    m = browser.evaluate("""(() => { const r = (s) => document.querySelector(s).getBoundingClientRect(), q = r("#se-query"), f = r("#se-form");
      return { qLeft: q.left, qRight: q.right, fLeft: f.left, fRight: f.right, height: q.height, vw: document.documentElement.clientWidth,
               font: getComputedStyle(document.querySelector("#se-query")).fontSize, doc: document.documentElement.scrollWidth,
               pane: document.querySelector("#search-pane").scrollWidth, paneClient: document.querySelector("#search-pane").clientWidth }; })()""")
    assert m["qLeft"] >= m["fLeft"] and abs(m["qRight"] - m["fRight"]) <= 1 and m["height"] >= 44 and m["font"] == "16px", m   # the full width, a tap target
    assert m["doc"] <= m["vw"] and m["pane"] <= m["paneClient"], m                                                            # no sideways scroll
    browser.evaluate('document.querySelector("#se-tools").click()')
    wait(browser, "window.__searchCalls.length === 2", "tool calls")
    results_box_search(browser, "answer")
    wait(browser, 'window.__searchCalls.length === 3 && document.querySelectorAll("#se-hits .se-hit").length === 1', "the new query")
    assert address(browser) == {"q": "answer", **DEFAULTS, "tools": "1"}
    assert browser.evaluate("document.documentElement.scrollWidth <= document.documentElement.clientWidth")
