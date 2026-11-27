"""The first paint of the chat session's address, frame by frame in a headless Chromium (what the server serves and the script's decision are test_chat_boot.py).

A recorder put in the page ahead of its scripts reads, on every animation frame from the first, what is VISIBLE in the header's name and in #chat. The page's first
script at the end of the body, its reads and its transcript stream are held back, so each step of a load is on screen for a while, as on a slow link. Held here, in
English and Korean, at 1280 x 800 and 390 x 844 (also 360 and 320):
  - the chat session's address, opened directly, through /chat, reloaded, or reached by a phone's or the installed app's launch with no address, never shows "Select a
    session", "Pick a session" or the session's bare name: nothing, then the loading line, then the chat under its label;
  - another session's load is the same with a chat session set as with none, and no other address is held;
  - it never stays held: not running, asleep, a failed read and a script error each end on the page as it is without this;
  - going to the chat session inside the page, from another session or the Overview, shows only where it came from and the chat;
  - the row the chat page keeps above its thread (the kept-back switch) is in no frame that shows the thread's loading line, on a load, a reload,
    a switch inside the page and a sleeping chat session, while the pinned bar of two tabs is; once a thread or a note stands in the loading line's place
    the rows are there, scrolled out of view above a long thread; with a thread that never arrives they stay away; another session never has them;
  - no frame scrolls sideways.

What a wrong answer costs: another view flashing on the chat's address, a header or a thread left blank, another session's load changed. Runs in a headless Chromium
when one is installed (conftest.py: `served`, `browser`), else is skipped; GitHub CI runs it. All names are invented. Not covered: a real phone's network (the delays
are staged) and what is painted before the first animation frame callback runs."""

from __future__ import annotations

import asyncio
import json
import os
import time
import urllib.request

import pytest
from starlette.responses import PlainTextResponse

from conftest import CWD, NAME, transcript_file, transcript_line
from sala_web import app as APP
from sala_web import sessions as S
from test_back_button import STANDALONE
from test_chat_session_view import EN_T, KO_T
from test_chat_session_view_ui import DESKTOP, PHONE, SIZES, api_chat, stub
from test_sleeping_sessions import SLEEP_UUID, wake  # noqa: F401 (a fixture)

LABEL = "Demo One"
WORDS = {"en": EN_T, "ko": KO_T}
HEADS = [t["ui.hdr.selectSession"] for t in WORDS.values()]
PICKS = [t[k] for t in WORDS.values() for k in ("ui.chat.pick", "app.pickSession")]
LANGS = ["en", "ko"]
# how late each read answers, in ms (the first prefix that matches): the sessions before api/chat, so the chat is open for a while with its label unknown
READS = [["api/chat", 1600], ["api/sessions", 700], ["api/", 300]]
STREAM_MS = 500

RECORDER = """(() => {
  const frames = window.__frames = [];
  const seen = (n) => n.checkVisibility({ checkVisibilityCSS: true, visibilityProperty: true });
  const text = (root) => { if (!root) return ""; let out = ""; const walk = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    for (let n; (n = walk.nextNode());) if (seen(n.parentElement)) out += n.data; return out.trim(); };
  const read = () => {
    const name = document.querySelector("#title .name"), chat = document.querySelector("#chat"), root = document.documentElement;
    const pane = document.querySelector("#chat-pane"), strip = document.querySelector("#chat-strip"), bar = document.querySelector("#chat-strip-wait");
    if (name) frames.push({ t: performance.now(), head: text(name), chat: text(chat).slice(0, 400), raw: name.textContent,
      pick: !!document.querySelector('#chat > [data-i18n="ui.chat.pick"]'), msgs: document.querySelectorAll("#chat > .msg").length,
      loading: !!document.querySelector('#chat > .empty[data-i18n="app.loadingTranscript"]'), on: !!strip && !strip.hidden,
      rows: strip ? [...strip.querySelectorAll(".kept-row")].filter(seen).length : 0, bar: !!bar && seen(bar),
      tabs: bar ? [...bar.querySelectorAll("[role=tab]")].filter(seen).length : 0,
      below: pane ? Math.round(pane.scrollHeight - pane.scrollTop - pane.clientHeight) : 0, wide: pane ? pane.scrollWidth - pane.clientWidth : 0,
      hold: root.hasAttribute("data-chat-boot"), over: root.scrollWidth - root.clientWidth });
    requestAnimationFrame(read);
  };
  requestAnimationFrame(read);
})();"""

SLOW = """(() => {
  const READS = %s, FAIL = %s, real = window.fetch.bind(window);
  window.fetch = (url, opts) => { const u = String(url), hit = READS.find(([p]) => u.startsWith(p));
    return new Promise((r) => setTimeout(r, hit ? hit[1] : 0)).then(() => {
      if (FAIL.some((p) => u.startsWith(p))) throw new TypeError("staged: the read failed");
      return real(url, opts); }); };
  const Real = window.EventSource;
  window.EventSource = class {
    static CLOSED = 2;
    constructor(url) { this.on = []; this.es = null; this.shut = false;
      setTimeout(() => { if (this.shut) return; this.es = new Real(url); for (const [t, f] of this.on) this.es.addEventListener(t, f); }, %d); }
    addEventListener(t, f) { if (this.es) this.es.addEventListener(t, f); else this.on.push([t, f]); }
    close() { this.shut = true; if (this.es) this.es.close(); }
    get readyState() { return this.es ? this.es.readyState : this.shut ? 2 : 0; }
  };
})();"""

LAST_VIEW = "try { if (location.protocol === 'http:') localStorage.setItem('salaweb.lastView', %s); } catch (e) {}"


def prepare(browser, served, monkeypatch, lang="en", fail=(), extra=(), broken=None, reads=READS, stream_ms=STREAM_MS) -> None:
    """The recorder and the delays, ahead of every document the page loads from here on. `broken`: a static file served as a script that throws; `reads` and
    `stream_ms`: how late the reads and the transcript's stream answer."""
    req = urllib.request.Request(served["url"] + "/api/prefs", data=json.dumps({"lang": lang}).encode(), method="PUT",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        assert r.status == 200
    monkeypatch.setenv("SALA_CHAT_NAME", LABEL)
    real = APP.RevalidatedStatic.get_response

    async def get_response(self, path, scope):
        if path == "i18n-en.js":          # the first script at the end of the body: the served markup is on screen while it is on its way
            await asyncio.sleep(1.0)
        if path == broken:
            return PlainTextResponse("throw new Error('staged');", media_type="text/javascript")
        return await real(self, path, scope)

    monkeypatch.setattr(APP.RevalidatedStatic, "get_response", get_response)
    browser.send("Page.enable")
    for source in (RECORDER, SLOW % (json.dumps(reads), json.dumps(list(fail)), stream_ms), *extra):
        browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": source})


def until(browser, expr: str, secs: float = 25.0) -> None:
    end, last = time.time() + secs, None
    while time.time() < end:
        try:
            if browser.evaluate(expr):
                return
        except RuntimeError as e:        # the document was replaced under the call
            last = e
        time.sleep(0.1)
    state = browser.evaluate("({ url: location.href, last: (window.__frames || []).slice(-1)[0] })")
    raise AssertionError(f"never true: {expr}; the page: {state}; last error: {last}")


def load(browser, served, monkeypatch, size, path: str, chat=NAME) -> None:
    """A real load of `path` under the served root at `size`, with SALA_CHAT_SESSION=`chat` (None: unset)."""
    if chat is None:
        monkeypatch.delenv("SALA_CHAT_SESSION", raising=False)
    else:
        monkeypatch.setenv("SALA_CHAT_SESSION", chat)
    browser.send("Page.navigate", {"url": "about:blank"})
    until(browser, "location.href === 'about:blank'", 10.0)
    browser.width, browser.height = size
    url = f"{served['url']}/{path}"
    if size[0] < 700:
        browser.open(url, dark=True)
    else:
        browser.send("Emulation.setDeviceMetricsOverride", {"width": size[0], "height": size[1], "deviceScaleFactor": 1, "mobile": False})
        browser.send("Page.navigate", {"url": url})


def frames(browser) -> list[dict]:
    time.sleep(0.5)                     # a few frames of the end state
    return browser.evaluate("window.__frames")


NAME_EL = "document.querySelector('#title .name')"
LET_GO = "!document.documentElement.hasAttribute('data-chat-boot')"
CHAT_DRAWN = (f"location.protocol === 'http:' && !!{NAME_EL} && {NAME_EL}.textContent === '{LABEL}' && "
              f"document.querySelectorAll('#chat > .msg').length >= 1 && {LET_GO}")


def check_chat_load(seen: list[dict], lang: str) -> None:
    assert seen, "no frame was recorded"
    for f in seen:
        assert f["head"] in ("", LABEL), f                                      # never the served header, the bare name or "not running"
        assert not any(p in f["chat"] for p in PICKS), f
        assert f["over"] <= 0, f
    # the recorder was there for the steps that used to show: the served markup, and the chat open ahead of its label
    assert any(f["pick"] and f["hold"] and f["head"] == "" and f["chat"] == "" for f in seen), seen[:5]
    assert any(f["raw"] == NAME and f["hold"] and f["head"] == "" for f in seen), "the bare name was never held back"
    assert any(f["chat"] == WORDS[lang]["app.loadingTranscript"] for f in seen), "the loading line, in the page's language"
    assert (seen[-1]["head"], seen[-1]["hold"]) == (LABEL, False) and seen[-1]["msgs"] >= 1, seen[-1]


# ── the chat session's address ───────────────────────────────────────────────
@pytest.mark.parametrize("path", ["s/" + NAME, "#s=" + NAME, "chat"], ids=["direct", "older-link", "through-chat"])
@pytest.mark.parametrize("size", SIZES)
@pytest.mark.parametrize("lang", LANGS)
def test_a_load_of_the_chat_address_shows_nothing_of_another_view(served, browser, monkeypatch, lang, size, path):
    prepare(browser, served, monkeypatch, lang)
    load(browser, served, monkeypatch, size, path)
    until(browser, CHAT_DRAWN)
    assert browser.evaluate("SalaAddress.here()") == "#s=" + NAME
    check_chat_load(frames(browser), lang)


@pytest.mark.parametrize("width", [360, 320])
def test_the_narrowest_phones_neither_flash_nor_scroll_sideways(served, browser, monkeypatch, width):
    prepare(browser, served, monkeypatch, "ko")
    load(browser, served, monkeypatch, (width, 844), "#s=" + NAME)
    until(browser, CHAT_DRAWN)
    assert browser.evaluate("document.documentElement.clientWidth") == width
    check_chat_load(frames(browser), "ko")


@pytest.mark.parametrize("size", SIZES)
@pytest.mark.parametrize("lang", LANGS)
def test_a_reload_of_the_chat_address_shows_nothing_of_another_view(served, browser, monkeypatch, lang, size):
    prepare(browser, served, monkeypatch, lang)
    load(browser, served, monkeypatch, size, "#s=" + NAME)
    until(browser, CHAT_DRAWN)
    browser.evaluate("window.__stale = true; ''")
    browser.send("Page.reload")
    until(browser, "!window.__stale && " + CHAT_DRAWN)
    check_chat_load(frames(browser), lang)


@pytest.mark.parametrize("size", SIZES)
@pytest.mark.parametrize("lang", LANGS)
def test_a_launch_with_no_address_that_reopens_the_chat_shows_nothing_of_another_view(served, browser, monkeypatch, lang, size):
    """A phone's width in any browser, and the installed app at a desktop's: app.js opens the last view again, after its reads."""
    extra = [LAST_VIEW % json.dumps("#s=" + NAME)] + ([STANDALONE] if size == DESKTOP else [])
    prepare(browser, served, monkeypatch, lang, extra=extra)
    load(browser, served, monkeypatch, size, "")
    until(browser, CHAT_DRAWN)
    assert browser.evaluate("SalaAddress.here()") == "#s=" + NAME
    check_chat_load(frames(browser), lang)


# ── every other load ─────────────────────────────────────────────────────────
@pytest.mark.parametrize("size, path, last, drawn", [
    pytest.param(DESKTOP, "", "#s=" + NAME, "overview-open", id="wide-browser-no-address"),
    pytest.param(PHONE, "", "#sessions", "overview-open", id="phone-last-view-overview"),
    pytest.param(PHONE, "#sessions", "#s=" + NAME, "overview-open", id="overview"),
    pytest.param(DESKTOP, "#new", "#s=" + NAME, "new-open", id="new-session"),
    pytest.param(PHONE, "#search", "#s=" + NAME, "search-open", id="search"),
])
def test_another_address_is_not_held(served, browser, monkeypatch, size, path, last, drawn):
    prepare(browser, served, monkeypatch, extra=[LAST_VIEW % json.dumps(last)])
    load(browser, served, monkeypatch, size, path)
    until(browser, f"!!document.body && document.body.classList.contains('{drawn}')")
    seen = frames(browser)
    assert not any(f["hold"] for f in seen)
    first = next(f for f in seen if f["pick"])      # the served markup shows as it did, which also shows the recorder sees it when nothing hides it
    assert (first["head"], first["chat"]) == (EN_T["ui.hdr.selectSession"], EN_T["ui.chat.pick"]), first


def steps(seen: list[dict]) -> list[tuple[str, str]]:
    """What was on screen, in order: (header, thread), a step shorter than 150 ms (between two scripts of one load) left out."""
    runs: list[tuple[tuple[str, str], float]] = []
    for f in seen:
        key = (f["head"], f["chat"])
        if not runs or runs[-1][0] != key:
            runs.append((key, f["t"]))
    kept = [k for i, (k, t) in enumerate(runs) if i == len(runs) - 1 or runs[i + 1][1] - t >= 150]
    return [k for i, k in enumerate(kept) if i == 0 or kept[i - 1] != k]


@pytest.mark.parametrize("size", SIZES)
@pytest.mark.parametrize("lang", LANGS)
def test_another_sessions_load_is_the_same_with_a_chat_session_set(served, browser, monkeypatch, lang, size):
    prepare(browser, served, monkeypatch, lang)
    load(browser, served, monkeypatch, size, "#s=" + NAME, chat=None)      # not measured: both measured loads then start from the same browser storage
    until(browser, "location.protocol === 'http:' && document.querySelectorAll('#chat > .msg').length >= 1")
    got = []
    for chat in (None, "demo-chat"):
        load(browser, served, monkeypatch, size, "#s=" + NAME, chat=chat)
        until(browser, f"location.protocol === 'http:' && !!{NAME_EL} && {NAME_EL}.textContent === '{NAME}' && "
                       "document.querySelectorAll('#chat > .msg').length >= 1")
        until(browser, "performance.now() > 3500")      # api/chat has answered too
        seen = frames(browser)
        assert not any(f["hold"] for f in seen)
        assert not any(f["on"] or f["rows"] or f["bar"] for f in seen), "none of the chat page's rows on another session"
        assert seen[-1]["below"] <= 1 and not any(f["wide"] > 0 for f in seen), seen[-1]
        got.append(steps(seen))
    without, with_chat = got
    assert with_chat == without
    # the sequence as it is: the served markup first, the loading line under the session's own name, then its thread
    assert without[0] == (EN_T["ui.hdr.selectSession"], EN_T["ui.chat.pick"]), without
    assert (NAME, WORDS[lang]["app.loadingTranscript"]) in without and without[-1][0] == NAME, without


# ── it never stays held ──────────────────────────────────────────────────────
def released_at(seen: list[dict]) -> float:
    """When the page was let go, in ms from the start of the load; it must have been held first."""
    held = [i for i, f in enumerate(seen) if f["hold"]]
    assert held, "the page was never held"
    after = seen[held[-1] + 1:]
    assert after and not seen[-1]["hold"], seen[-1]
    return after[0]["t"]


@pytest.mark.parametrize("size", SIZES)
def test_a_chat_session_that_is_not_running_shows_the_page_as_it_is(served, browser, monkeypatch, size):
    prepare(browser, served, monkeypatch)
    load(browser, served, monkeypatch, size, "#s=demo-absent", chat="demo-absent")
    said = EN_T["app.notRunning"].replace("{name}", "demo-absent")
    until(browser, f"!!{NAME_EL} && {NAME_EL}.textContent === {json.dumps(said)} && {LET_GO}")
    seen = frames(browser)
    assert released_at(seen) < 8000, "let go by what the page drew, not by the time limit"
    assert seen[-1]["head"] == said and EN_T["app.notLive"] in seen[-1]["chat"], seen[-1]


def test_a_launch_whose_last_view_is_a_chat_session_that_is_gone_opens_the_overview(served, browser, monkeypatch):
    prepare(browser, served, monkeypatch, extra=[LAST_VIEW % json.dumps("#s=demo-absent")])
    load(browser, served, monkeypatch, PHONE, "", chat="demo-absent")
    until(browser, f"!!document.body && document.body.classList.contains('overview-open') && {LET_GO}")
    seen = frames(browser)
    assert released_at(seen) < 8000
    assert seen[-1]["head"] == EN_T["common.overview"], seen[-1]


def test_a_sleeping_chat_session_shows_the_page_as_it_is(wake, served, browser, monkeypatch):  # noqa: F811
    wake.sleeper(name="demo-asleep")
    prepare(browser, served, monkeypatch)
    load(browser, served, monkeypatch, PHONE, "#s=demo-asleep", chat="demo-asleep")
    until(browser, f"!!{NAME_EL} && {NAME_EL}.textContent === 'demo-asleep' && !!document.querySelector('#title .dot.sleeping') && {LET_GO}")
    seen = frames(browser)
    assert released_at(seen) < 8000
    assert seen[-1]["head"] == "demo-asleep", seen[-1]


def test_a_failed_read_of_the_sessions_shows_the_page_as_it_is(served, browser, monkeypatch):
    prepare(browser, served, monkeypatch, fail=["api/sessions"])
    load(browser, served, monkeypatch, PHONE, "#s=" + NAME)
    said = EN_T["app.notRunning"].replace("{name}", NAME)
    until(browser, f"!!{NAME_EL} && {NAME_EL}.textContent === {json.dumps(said)} && {LET_GO}", 40.0)
    seen = frames(browser)
    released_at(seen)
    assert seen[-1]["head"] == said, seen[-1]


def test_a_failed_read_of_the_chat_lets_the_session_s_name_show_after_the_time_limit(served, browser, monkeypatch):
    prepare(browser, served, monkeypatch, fail=["api/chat"])
    load(browser, served, monkeypatch, PHONE, "#s=" + NAME)
    until(browser, f"!!{NAME_EL} && {NAME_EL}.textContent === '{NAME}' && {LET_GO} && document.querySelectorAll('#chat > .msg').length >= 1", 40.0)
    seen = frames(browser)
    assert released_at(seen) >= 10000
    assert any(f["hold"] and f["msgs"] and f["head"] == "" for f in seen), "the thread was drawn while the name waited"
    assert seen[-1]["head"] == NAME, seen[-1]


def test_a_script_error_shows_the_page_as_it_is(served, browser, monkeypatch):
    prepare(browser, served, monkeypatch, broken="app.js")
    load(browser, served, monkeypatch, PHONE, "#s=" + NAME)
    until(browser, f"document.readyState === 'complete' && location.protocol === 'http:' && {LET_GO}")
    seen = frames(browser)
    assert released_at(seen) < 8000
    assert seen[-1]["head"] == EN_T["ui.hdr.selectSession"] and seen[-1]["chat"] == EN_T["ui.chat.pick"], seen[-1]


# ── inside the page ──────────────────────────────────────────────────────────
OTHER_SAYS = "words of the other session"


def second_session(served) -> None:
    sid, pid = "bbbbbbbb-0000-4000-8000-000000000002", os.getppid()
    (served["settings"].claude_dir / "sessions" / f"{pid}.json").write_text(json.dumps(
        {"pid": pid, "sessionId": sid, "name": "demo-other", "cwd": CWD, "status": "idle", "tmux": "x:@1.%1", "procStart": S.proc_start(pid)}))
    transcript_file(served).with_name(sid + ".jsonl").write_text(
        transcript_line("user", [{"type": "text", "text": "hello"}], "o-1", human=True)
        + transcript_line("assistant", [{"type": "text", "text": OTHER_SAYS}], "o-2", model="claude-opus-5-5"))


@pytest.mark.parametrize("start, head", [("#s=demo-other", "demo-other"), ("#sessions", EN_T["common.overview"])], ids=["from-a-session", "from-the-overview"])
@pytest.mark.parametrize("size", SIZES)
def test_going_to_the_chat_session_inside_the_page_shows_no_other_view_on_the_way(served, browser, monkeypatch, size, start, head):
    second_session(served)
    prepare(browser, served, monkeypatch)
    load(browser, served, monkeypatch, size, start)
    there = f"document.querySelector('#chat').textContent.includes('{OTHER_SAYS}')" if "demo-other" in start else "document.body.classList.contains('overview-open')"
    until(browser, f"location.protocol === 'http:' && !!document.querySelector('#side-chat') && !document.querySelector('#side-chat').hidden && "
                   f"{NAME_EL}.textContent === {json.dumps(head)} && {there}")
    browser.evaluate("window.__frames.length = 0; document.querySelector('#side-chat').click(); ''")
    until(browser, CHAT_DRAWN)
    seen = frames(browser)
    assert seen and not any(f["hold"] for f in seen)
    for f in seen:
        assert f["head"] in (head, LABEL), f
        assert not any(p in f["chat"] for p in PICKS), f
        assert f["head"] != LABEL or OTHER_SAYS not in f["chat"], f          # the chat's header never over the other thread
        assert f["over"] <= 0, f
    assert seen[-1]["head"] == LABEL, seen[-1]


# ── the rows above the thread ────────────────────────────────────────────────
# api/chat answers at once (a stand-in with two moves that wait) and the thread comes late, so the strip is on all the while the loading line stands
QUICK = [["api/sleeping/", 1200], ["api/sessions", 300], ["api/", 100]]
LATE_STREAM_MS = 1200
ROWS = 1     # the kept-back switch
TABS = 2     # the pinned part is a bar of two tabs

PANE = """(() => { const box = (s) => document.querySelector(s).getBoundingClientRect(), p = document.querySelector('#chat-pane');
  return { paneTop: box('#chat-pane').top, paneBottom: box('#chat-pane').bottom, stripTop: box('#chat-strip').top, stripBottom: box('#chat-strip').bottom,
    stripH: box('#chat-strip').height, barTop: box('#chat-strip-wait').top, barBottom: box('#chat-strip-wait').bottom, barH: box('#chat-strip-wait').height,
    top: p.scrollTop, below: p.scrollHeight - p.scrollTop - p.clientHeight, wide: p.scrollWidth - p.clientWidth }; })()"""


def long_thread() -> str:
    """A thread many screens long, every turn the owner's own, so none is kept back."""
    return "".join(transcript_line("user", [{"type": "text", "text": f"question {i}"}], f"long-u{i}", human=True)
                   + transcript_line("assistant", [{"type": "text", "text": f"answer {i}: " + "a line of the reply. " * 12}], f"long-a{i}", model="claude-opus-5-5")
                   for i in range(30))


def prepare_rows(browser, served, monkeypatch, session=NAME, stream_ms=LATE_STREAM_MS, fail=()) -> None:
    prepare(browser, served, monkeypatch, fail=fail, reads=QUICK, stream_ms=stream_ms, extra=[stub(api_chat(session=session, name=LABEL))])


def check_rows(seen: list[dict]) -> None:
    for f in seen:
        assert not (f["loading"] and f["rows"]), f                   # never above a thread still loading
        assert f["over"] <= 0 and f["wide"] <= 0, f
    # the case was staged: the strip was on (api/chat had answered) while the loading line stood, which is where its rows showed; the pinned part stood there too
    waited = [f for f in seen if f["loading"] and f["on"]]
    assert waited, "the strip was never on while the thread loaded"
    assert all(f["bar"] and f["tabs"] == TABS for f in waited), waited[:3]


def check_rows_above_a_long_thread(browser, rows: int = ROWS) -> None:
    """The thread is in and the view is at its end: the strip is in the pane, scrolled out above; at the top it is under the pinned bar. `rows`: how many of its rows
    show (none with the chat layer on, whose sheet hides the kept-back switch: the strip then takes no height)."""
    end = browser.evaluate(PANE)
    assert (end["stripH"] > 0) is (rows > 0) and end["top"] > 0 and end["below"] <= 1 and end["wide"] <= 0, end
    assert end["stripBottom"] <= end["paneTop"] + 1, end
    assert end["barH"] > 0 and abs(end["barTop"] - end["paneTop"]) <= 1, end
    top = browser.evaluate(f"(document.querySelector('#chat-pane').scrollTop = 0, {PANE})")     # one call: nothing scrolls between the two
    assert top["barBottom"] - 1 <= top["stripTop"] <= top["stripBottom"] <= top["paneBottom"], top
    assert abs(top["barTop"] - top["paneTop"]) <= 1, top


@pytest.mark.parametrize("size", SIZES)
def test_the_rows_above_the_thread_wait_for_it_on_a_load_and_a_reload(served, browser, monkeypatch, size):
    transcript_file(served).write_text(long_thread())
    prepare_rows(browser, served, monkeypatch)
    load(browser, served, monkeypatch, size, "#s=" + NAME)
    for again in (False, True):
        if again:
            browser.evaluate("window.__stale = true; ''")
            browser.send("Page.reload")
        until(browser, "!window.__stale && " + CHAT_DRAWN)
        seen = frames(browser)
        check_rows(seen)
        assert (seen[-1]["rows"], seen[-1]["tabs"]) == (ROWS, TABS), seen[-1]
        check_rows_above_a_long_thread(browser)


@pytest.mark.parametrize("start, head", [("#s=demo-other", "demo-other"), ("#sessions", EN_T["common.overview"])], ids=["from-a-session", "from-the-overview"])
@pytest.mark.parametrize("size", SIZES)
def test_the_rows_above_the_thread_wait_for_it_on_a_switch_inside_the_page(served, browser, monkeypatch, size, start, head):
    transcript_file(served).write_text(long_thread())
    second_session(served)
    prepare_rows(browser, served, monkeypatch)
    load(browser, served, monkeypatch, size, start)
    there = f"document.querySelector('#chat').textContent.includes('{OTHER_SAYS}')" if "demo-other" in start else "document.body.classList.contains('overview-open')"
    until(browser, f"location.protocol === 'http:' && !!document.querySelector('#side-chat') && !document.querySelector('#side-chat').hidden && "
                   f"{NAME_EL}.textContent === {json.dumps(head)} && {there}")
    browser.evaluate("window.__frames.length = 0; document.querySelector('#side-chat').click(); ''")
    until(browser, CHAT_DRAWN)
    seen = frames(browser)
    check_rows(seen)
    assert seen[-1]["rows"] == ROWS, seen[-1]
    check_rows_above_a_long_thread(browser)
    # and on to the other session: its loading line and its thread with nothing of the chat page above them
    browser.evaluate("window.__frames.length = 0; location.hash = 's=demo-other'; ''")
    until(browser, f"{NAME_EL}.textContent === 'demo-other' && document.querySelector('#chat').textContent.includes('{OTHER_SAYS}')")
    seen = frames(browser)
    there_now = [f for f in seen if f["head"] == "demo-other"]
    assert any(f["loading"] for f in there_now), seen[:5]
    assert not any(f["on"] or f["rows"] or f["bar"] for f in there_now), there_now[:3]
    assert not any(f["over"] > 0 or f["wide"] > 0 for f in seen), seen[-1]


@pytest.mark.parametrize("size", [*SIZES, pytest.param((320, 844), id="narrowest")])
def test_a_thread_that_never_arrives_keeps_the_rows_away_and_the_pinned_bar(served, browser, monkeypatch, size):
    prepare_rows(browser, served, monkeypatch, stream_ms=600_000)
    load(browser, served, monkeypatch, size, "#s=" + NAME)
    until(browser, f"location.protocol === 'http:' && !!{NAME_EL} && {NAME_EL}.textContent === '{LABEL}' && {LET_GO} && "
                   "!document.querySelector('#chat-strip').hidden && !document.querySelector('#chat-strip-wait').hidden")
    time.sleep(1.0)
    seen = frames(browser)
    check_rows(seen)
    last = seen[-1]
    assert (last["loading"], last["on"], last["rows"], last["bar"], last["tabs"]) == (True, True, 0, True, TABS), last


@pytest.mark.parametrize("fail", [(), ("api/sleeping/",)], ids=["the-thread-arrives", "the-read-fails"])
@pytest.mark.parametrize("size", SIZES)
def test_a_sleeping_chat_session_s_rows_wait_for_its_thread_or_its_note(wake, served, browser, monkeypatch, size, fail):  # noqa: F811
    wake.sleeper(name="demo-asleep", cwd=CWD)
    transcript_file(served).with_name(SLEEP_UUID + ".jsonl").write_text(long_thread())
    prepare_rows(browser, served, monkeypatch, session="demo-asleep", fail=fail)
    load(browser, served, monkeypatch, size, "#s=demo-asleep", chat="demo-asleep")
    drawn = "#chat > .sleeping-note" if fail else "#chat > .msg"
    until(browser, f"location.protocol === 'http:' && !!document.querySelector('{drawn}') && !document.querySelector('#chat-strip').hidden && "
                   "!document.querySelector('#chat-strip-wait').hidden")
    seen = frames(browser)
    check_rows(seen)
    assert seen[-1]["rows"] == ROWS, seen[-1]
    if not fail:
        check_rows_above_a_long_thread(browser)


def test_a_chat_thread_with_no_messages_shows_the_rows(served, browser, monkeypatch):
    transcript_file(served).write_text("")
    prepare_rows(browser, served, monkeypatch)
    load(browser, served, monkeypatch, PHONE, "#s=" + NAME)
    until(browser, """location.protocol === 'http:' && !!document.querySelector('#chat > [data-i18n="app.noMessages"]')""")
    seen = frames(browser)
    check_rows(seen)
    assert seen[-1]["rows"] == ROWS, seen[-1]
