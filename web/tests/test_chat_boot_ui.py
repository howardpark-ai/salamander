"""The first paint of the chat session's address, frame by frame in a headless Chromium (what the server serves and the script's decision are test_chat_boot.py).

A recorder put in the page ahead of its scripts reads, on every animation frame from the first, what is VISIBLE in the header's name and in #chat. The page's first
script at the end of the body, its reads and its transcript stream are held back, so each step of a load is on screen for a while, as on a slow link. Held here, in
English and Korean, at 1280 x 800 and 390 x 844 (also 360 and 320):
  - the chat session's address, opened directly, through /chat, reloaded, or reached by a phone's or the installed app's launch with no address, never shows "Select a
    session", "Pick a session" or the session's bare name: nothing, then the loading line, then the chat under its label;
  - another session's load is the same with a chat session set as with none, and no other address is held;
  - it never stays held: not running, asleep, a failed read and a script error each end on the page as it is without this;
  - going to the chat session inside the page, from another session or the Overview, shows only where it came from and the chat;
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
from test_chat_session_view_ui import DESKTOP, PHONE, SIZES
from test_sleeping_sessions import wake  # noqa: F401 (a fixture)

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
    if (name) frames.push({ t: performance.now(), head: text(name), chat: text(chat).slice(0, 400), raw: name.textContent,
      pick: !!document.querySelector('#chat > [data-i18n="ui.chat.pick"]'), msgs: document.querySelectorAll("#chat > .msg").length,
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


def prepare(browser, served, monkeypatch, lang="en", fail=(), extra=(), broken=None) -> None:
    """The recorder and the delays, ahead of every document the page loads from here on. `broken`: a static file served as a script that throws."""
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
    for source in (RECORDER, SLOW % (json.dumps(READS), json.dumps(list(fail)), STREAM_MS), *extra):
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
@pytest.mark.parametrize("path", ["#s=" + NAME, "chat"], ids=["direct", "through-chat"])
@pytest.mark.parametrize("size", SIZES)
@pytest.mark.parametrize("lang", LANGS)
def test_a_load_of_the_chat_address_shows_nothing_of_another_view(served, browser, monkeypatch, lang, size, path):
    prepare(browser, served, monkeypatch, lang)
    load(browser, served, monkeypatch, size, path)
    until(browser, CHAT_DRAWN)
    assert browser.evaluate("location.hash") == "#s=" + NAME
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
    assert browser.evaluate("location.hash") == "#s=" + NAME
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
