"""The Shell draws in D2Coding 14px, and its key log (static/termclip.js `hookShellTerminal`).

ttyd 1.7.7's own face ("Consolas,Liberation Mono,Menlo,Courier,monospace", 13px) has no Korean glyphs. The Shell drawer's frame, and
the full-size page (terminal.html) when its ?arg is the Shell session (api/config `shellSession`), load the font the pages themselves
use (static/fonts/D2Coding-Regular.woff2, at an absolute same-origin address: the frame's own base is /tty/) into the frame's document,
wait for it, set `term.options.fontFamily` and `fontSize` 14, and fit the terminal again. The same hook records what the keyboard sends
(named keys and composition events only, never a typed character) and posts it to `POST /api/shell/keylog` (test_shell_keylog.py is the
server's half). The Terminal tab (Claude session panes) is left as ttyd draws it.

Three levels, the browser ones in the headless Chromium of conftest.py (skipped without one):

* the source: the call sites, the number, the font name, the wait for the font before the options, the privacy rule in the code;
* a fake `term` in a same-origin about:blank frame (as test_terminal_ctrl_v.py): the hook polls, hooks a term once, leaves a
  cross-origin or a throwing term alone, what the key log records and when it posts;
* the real ttyd on a scratch tmux session behind one same-origin address (ttyd_harness.py): the font file loads, the cell is measured
  from it, a Korean letter is two cells, the pane is told the new size, real key events reach the log, and the Terminal tab stays as it was.
"""

from __future__ import annotations

import json
import time

import pytest

from conftest import NAME
from sala_web import keylog as KL
from sala_web import tmuxio as T
from sala_web.app import STATIC
from test_composer_attach import WAIT_READY
from ttyd_harness import ALT, press, real_ttyd

APP_JS = (STATIC / "app.js").read_text()
TERMCLIP = (STATIC / "termclip.js").read_text()
TERMINAL_JS = (STATIC / "terminal.js").read_text()
KO = "\uac00\ub098\ub2e4"     # three Korean syllables, written as escapes: no Hangul literal in the source


def body_of(src: str, head: str) -> str:
    start = src.index(head)
    return src[start:src.index("\n}\n", start)]


# ---------------------------------------------------------------- the source


def test_the_shell_drawer_and_the_shell_session_of_the_full_size_page_are_hooked_and_nothing_else():
    assert APP_JS.count("hookShellTerminal(") == 1
    assert "hookShellTerminal(frame)" in body_of(APP_JS, "async function ensureShellFrame()")
    assert "hookTerminalClipboard(frame)" in body_of(APP_JS, "async function ensureShellFrame()")      # still there
    for other in ("async function loadTerminal(", "function loadTerminal("):                          # the Terminal tab keeps ttyd's face
        if other in APP_JS:
            assert "hookShellTerminal" not in body_of(APP_JS, other)
    # terminal.html: only when ?arg is the Shell session api/config names
    assert TERMINAL_JS.count("hookShellTerminal(") == 1 and "hookTerminalClipboard(frame)" in TERMINAL_JS
    assert 'if (arg && arg === shellSession) hookShellTerminal(frame);' in TERMINAL_JS
    assert "c.shellSession" in TERMINAL_JS


def test_the_font_is_d2coding_14px_loaded_in_the_frame_before_it_is_set():
    assert (STATIC / "fonts" / "D2Coding-Regular.woff2").is_file()
    assert "const SHELL_FONT_SIZE = 14;" in TERMCLIP
    assert """const SHELL_FONT_FAMILY = '"D2Coding", Consolas, monospace';""" in TERMCLIP
    assert "font-display:block;size-adjust:100.2%" in TERMCLIP and "D2Coding-Regular.woff2" in TERMCLIP   # see the comment there: without it a cell is 6px, not 7
    # an absolute address made from this script's own (ttyd's frame is served from /tty/; the ?v is kept)
    assert "document.currentScript" in TERMCLIP and "new URL(" in TERMCLIP
    fn = body_of(TERMCLIP, "async function applyShellFont(")
    assert fn.index("doc.fonts.load(") < fn.index("term.options.fontFamily") < fn.index("term.options.fontSize") < fn.index("term.fit")
    assert "win.dispatchEvent(new win.Event(\"resize\"))" in fn                # without term.fit ttyd's own resize handler refits
    assert "win.term !== term" in fn                                           # a frame that went elsewhere meanwhile is left alone
    hook = body_of(TERMCLIP, "function hookShellTerminal(")
    assert "frame.addEventListener(\"load\", start)" in hook and "10000" in hook and "shellHooked.has(term)" in hook


def test_the_key_log_records_names_and_composition_only():
    assert '"api/shell/keylog"' in TERMCLIP and "keepalive: true" in TERMCLIP and "splice(0, 50)" in TERMCLIP and "2000" in TERMCLIP
    assert "const KEYLOG_KEYS = new Set([" in TERMCLIP and "KEYLOG_NAME" not in TERMCLIP     # a listed name, never one typed character
    assert 'for (const type of ["keydown", "keyup", ...KEYLOG_COMPOSITION]) win.document.addEventListener(type, recordKey, true);' in TERMCLIP
    assert "pagehide" in TERMCLIP
    entry = body_of(TERMCLIP, "function keyLogEntry(")                           # a composition event is {t, type}: never its text
    comp_line = [ln for ln in entry.splitlines() if "KEYLOG_COMPOSITION" in ln][0]
    assert "return { t, type: ev.type };" in comp_line and "data" not in comp_line and "slice(0, 16)" not in TERMCLIP


# ---------------------------------------------------------------- the hook, against a fake term in a same-origin frame

OPEN_SHELL = """
new Promise((res) => { const t0 = Date.now(); (function poll() {
  if (typeof state !== "undefined" && state.current) {
    state.terminalUrl = "about:blank#";   // a same-origin frame stands in for ttyd
    window.__posts = [];                  // what the page posts to api/shell/keylog
    // a fake xterm.js: `options` records each assignment; `fit` counts
    window.__fakeTerm = () => { const t = { sets: [], fits: 0, fit() { this.fits++; } };
      const store = {}; t.options = new Proxy(store, { set(o, k, v) { o[k] = v; t.sets.push([k, v]); return true; } }); return t; };
    const realFetch = window.fetch;
    window.fetch = (url, opts) => String(url).includes("api/shell/keylog")
      ? (window.__posts.push(JSON.parse(opts.body)), Promise.resolve(new Response('{"ok":true}'))) : realFetch(url, opts);
    setShell(true);
    res(true);
  } else if (Date.now() - t0 > 15000) res(false); else setTimeout(poll, 50);
})(); })
"""

# the fake term is installed on the Shell frame after `delay` ms
INSTALL = """
(delay) => new Promise((res) => {
  const f = document.querySelector("#shell-term iframe");
  setTimeout(() => { f.contentWindow.term = window.__fakeTerm(); res(true); }, delay);
})
"""

TERM_STATE = """new Promise((res) => { const t0 = Date.now(); (function poll() {
  const f = document.querySelector("#shell-term iframe"); const t = f.contentWindow.term;
  if ((t && t.sets.length >= 2) || Date.now() - t0 > %d) res(t ? { sets: t.sets, fits: t.fits,
      style: (f.contentDocument.getElementById("sala-shell-font") || {}).textContent || null } : null);
  else setTimeout(poll, 50);
})(); })"""


@pytest.fixture
def fake(served, browser, monkeypatch):
    async def ensure(settings):
        return False
    monkeypatch.setattr(T, "ensure_shell_session", ensure)
    browser.open(f"{served['url']}/#s={NAME}")
    assert browser.evaluate(WAIT_READY)
    browser.served = served
    assert browser.evaluate(OPEN_SHELL) is True
    assert browser.evaluate("new Promise((res) => { const t0 = Date.now(); (function poll() { if (document.querySelector('#shell-term iframe') || Date.now() - t0 > 8000) res(!!document.querySelector('#shell-term iframe')); else setTimeout(poll, 50); })(); })")
    return browser


def test_a_term_that_appears_late_gets_the_face_once_and_is_fitted(fake):
    fake.evaluate("(%s)(700)" % INSTALL.strip())                    # the page builds its term 0.7 s after the frame loads
    s = fake.evaluate(TERM_STATE % 8000)
    assert s["sets"] == [["fontFamily", '"D2Coding", Consolas, monospace'], ["fontSize", 14]] and s["fits"] == 1
    # the font is declared in the frame's own document, at an absolute same-origin address (the main page's base, not /tty/), cache-busted
    assert s["style"].startswith('@font-face{font-family:"D2Coding";src:url("http://127.0.0.1:') and "/static/fonts/D2Coding-Regular.woff2?v=" in s["style"]
    assert "font-display:block" in s["style"]
    # a second look at the same term changes nothing; a reloaded frame has a new term and is hooked again
    fake.evaluate("document.querySelector('#shell-term iframe').dispatchEvent(new Event('load'))")
    fake.evaluate("new Promise((r) => setTimeout(r, 700))")
    assert fake.evaluate("document.querySelector('#shell-term iframe').contentWindow.term.sets.length") == 2
    fake.evaluate("""(() => { const f = document.querySelector("#shell-term iframe"); f.contentWindow.term = window.__fakeTerm();
                              f.dispatchEvent(new Event("load")); return 1; })()""")
    assert fake.evaluate(TERM_STATE % 8000)["sets"] == [["fontFamily", '"D2Coding", Consolas, monospace'], ["fontSize", 14]]


def test_the_font_is_the_real_file_and_a_fit_falls_back_to_a_resize_event(fake):
    fake.evaluate("""(() => { const f = document.querySelector("#shell-term iframe"); window.__resized = 0;
      f.contentWindow.addEventListener("resize", () => window.__resized++);
      const t = window.__fakeTerm(); delete t.fit; f.contentWindow.term = t; return 1; })()""")
    assert fake.evaluate(TERM_STATE % 8000)["sets"][-1] == ["fontSize", 14]
    assert fake.evaluate("new Promise((r) => setTimeout(() => r(window.__resized), 200))") == 1     # no term.fit: ttyd's own resize handler is asked
    assert fake.evaluate("""document.querySelector("#shell-term iframe").contentDocument.fonts.check("14px D2Coding")""") is True


def test_a_term_without_options_is_left_alone_and_a_failing_font_leaves_ttyds_face(fake):
    # no `options` at all: not a term this hook knows; then one whose font file cannot load (the style points at nothing)
    fake.evaluate("""(() => { const f = document.querySelector("#shell-term iframe"); f.contentWindow.term = { parser: {} };
                              f.dispatchEvent(new Event("load")); return 1; })()""")
    fake.evaluate("""(() => { const f = document.querySelector("#shell-term iframe");
      const t = window.__fakeTerm(); f.contentWindow.term = t; f.contentWindow.document.fonts.load = () => Promise.reject(new Error("no file"));
      f.dispatchEvent(new Event("load")); return 1; })()""")
    fake.evaluate("new Promise((r) => setTimeout(r, 900))")
    assert fake.evaluate("document.querySelector('#shell-term iframe').contentWindow.term.sets.length") == 0


def test_the_terminal_tab_is_not_given_the_shell_face_or_the_key_log(fake):
    fake.evaluate("""document.querySelector("#top .tab[data-tab=terminal]").click(); 1""")
    assert fake.evaluate("new Promise((res) => { const t0 = Date.now(); (function poll() { const f = document.querySelector('#terminal-pane iframe');"
                         " if (f || Date.now() - t0 > 8000) res(!!f); else setTimeout(poll, 50); })(); })") is True
    fake.evaluate("""(() => { const f = document.querySelector("#terminal-pane iframe"); f.contentWindow.term = window.__fakeTerm();
      f.dispatchEvent(new Event("load")); return 1; })()""")
    fake.evaluate("""(() => { const d = document.querySelector("#terminal-pane iframe").contentDocument;
      d.dispatchEvent(new KeyboardEvent("keydown", { key: "Alt", code: "AltRight" })); return 1; })()""")
    fake.evaluate("new Promise((r) => setTimeout(r, 2600))")
    assert fake.evaluate("document.querySelector('#terminal-pane iframe').contentWindow.term.sets.length") == 0
    assert fake.evaluate("document.querySelector('#terminal-pane iframe').contentDocument.getElementById('sala-shell-font')") is None
    assert fake.evaluate("window.__posts.flat().length") == 0


def frame_events(browser, js: str):
    """Run `js` (a function of the frame's document) and return what the page has posted after the 2 s flush."""
    browser.evaluate("(%s)(document.querySelector('#shell-term iframe').contentDocument)" % js)
    browser.evaluate("new Promise((r) => setTimeout(r, 2600))")
    return browser.evaluate("window.__posts")


def hooked(browser):
    browser.evaluate("(%s)(0)" % INSTALL.strip())
    assert browser.evaluate(TERM_STATE % 8000)["sets"]


def test_the_key_log_records_named_keys_and_composition_and_never_a_typed_character(fake):
    hooked(fake)
    posts = frame_events(fake, """(d) => {
      const k = (type, init) => d.dispatchEvent(new KeyboardEvent(type, Object.assign({ bubbles: true }, init)));
      k("keydown", { key: "a", code: "KeyA" }); k("keyup", { key: "a", code: "KeyA" });          // typed text: never
      k("keydown", { key: "%s", code: "KeyG" });                                                 // a Korean syllable is a character too
      k("keydown", { key: " ", code: "Space" }); k("keydown", { key: "5", code: "Digit5" });
      k("keydown", { key: "Alt", code: "AltRight", altKey: true });
      k("keydown", { key: "HangulMode", code: "Lang1" }); k("keyup", { key: "HangulMode", code: "Lang1" });
      k("keydown", { key: "Process", code: "KeyG", isComposing: true, shiftKey: true });          // an IME key: stored without its code and shift
      k("keydown", { key: "Enter", code: "Enter", ctrlKey: true, metaKey: true });
      const c = (type, data) => d.dispatchEvent(new CompositionEvent(type, { data, bubbles: true }));
      c("compositionstart", ""); c("compositionupdate", "%s"); c("compositionupdate", "0123456789abcdefXYZ"); c("compositionend", "%s");
    }""" % (KO[0], KO, KO))
    ev = [e for batch in posts for e in batch]
    assert [(e["type"], e.get("key")) for e in ev] == [
        ("keydown", "Alt"), ("keydown", "HangulMode"), ("keyup", "HangulMode"), ("keydown", "Process"), ("keydown", "Enter"),
        ("compositionstart", None), ("compositionupdate", None), ("compositionupdate", None), ("compositionend", None)]
    alt = ev[0]
    assert alt["code"] == "AltRight" and alt["alt"] is True and alt["shift"] is False and alt["isComposing"] is False and alt["keyCode"] == 0
    assert isinstance(alt["t"], int) and abs(alt["t"] - time.time() * 1000) < 60_000
    proc = ev[3]
    assert proc["isComposing"] is True and proc["shift"] is False and proc["code"] == "" and proc["keyCode"] == 0
    assert ev[4]["ctrl"] is True and ev[4]["meta"] is True and ev[4]["code"] == "Enter" and ev[4]["keyCode"] == 0
    assert all(set(e) == {"t", "type"} for e in ev[5:])                                  # a composition event is its time and type, no text
    flat = json.dumps(ev, ensure_ascii=False)
    assert KO not in flat and KO[0] not in flat and "0123456789" not in flat and "XYZ" not in flat
    assert "KeyA" not in json.dumps(ev) and '"a"' not in json.dumps(ev)                  # nothing of the typed letter went out
    assert all(len(b) <= 50 for b in posts)


def test_a_composed_password_never_reaches_the_queue_or_a_post(fake):
    """Typed in Korean mode at a prompt, a password is composed syllable by syllable: each update carries the text so far, so a cap on one
    event would not hold it. The page records that the composition started, updated and ended, and nothing of the text."""
    hooked(fake)
    secret = KO + "\ub098\ub2e4" + "hunter2"
    steps = [secret[:i] for i in range(1, len(secret) + 1)]
    fake.evaluate("""((steps, secret) => { const d = document.querySelector("#shell-term iframe").contentDocument;
      const c = (type, data) => d.dispatchEvent(new CompositionEvent(type, { data, bubbles: true }));
      c("compositionstart", ""); for (const s of steps) c("compositionupdate", s); c("compositionend", secret); return 1; })(%s, %s)""" % (json.dumps(steps), json.dumps(secret)))
    queued = fake.evaluate("keyLogQueue.map((e) => JSON.stringify(e))")                 # what waits on the queue, before any post
    assert len(queued) == len(steps) + 2 and all(set(json.loads(q)) == {"t", "type"} for q in queued)
    assert not any(ch in q for q in queued for ch in secret if not ch.isascii()) and not any("hunter" in q for q in queued)
    fake.evaluate("window.dispatchEvent(new Event('pagehide'))")
    sent = json.dumps(fake.evaluate("window.__posts"), ensure_ascii=False)
    assert not any(ch in sent for ch in secret if not ch.isascii()) and "hunter" not in sent and "data" not in sent
    assert sent.count("compositionupdate") == len(steps)


# What a browser sends for a password typed on a 2-set Korean layout: every letter key is a keydown with key "Process" that keeps the
# physical code, keyCode 229 (on some events the real one) and the Shift state, and a keyup with the Latin letter, the code and the real keyCode.
IME_SEQUENCE = """((d) => {
  const ev = (type, init, keyCode) => { const e = new KeyboardEvent(type, Object.assign({ bubbles: true }, init));
    Object.defineProperty(e, "keyCode", { value: keyCode }); d.dispatchEvent(e); };
  const c = (type) => d.dispatchEvent(new CompositionEvent(type, { data: "x", bubbles: true }));
  ev("keydown", { key: "HangulMode", code: "Lang1" }, 21); ev("keyup", { key: "HangulMode", code: "Lang1" }, 21);       // the switch to Hangul
  ev("keydown", { key: "Alt", code: "AltRight", altKey: true }, 18); ev("keyup", { key: "Alt", code: "AltRight" }, 18);
  ev("keydown", { key: "Process", code: "Lang1" }, 229); ev("keyup", { key: "Process", code: "Lang1" }, 21);         // the same key arriving as Process
  ev("keydown", { key: "Process", code: "KeyG", isComposing: false }, 229); c("compositionstart");
  ev("keyup", { key: "g", code: "KeyG" }, 71);
  ev("keydown", { key: "Process", code: "KeyK", isComposing: true }, 229); c("compositionupdate");
  ev("keyup", { key: "k", code: "KeyK", isComposing: true }, 75);
  ev("keydown", { key: "Process", code: "KeyQ", shiftKey: true, isComposing: true }, 229); c("compositionupdate");
  ev("keyup", { key: "Q", code: "KeyQ", shiftKey: true, isComposing: true }, 81);
  ev("keydown", { key: "Process", code: "KeyH", isComposing: true }, 72);                            // some events keep the real keyCode
  ev("keyup", { key: "Process", code: "KeyH", isComposing: false }, 72);
  ev("keydown", { key: "Process", code: "Digit1", isComposing: true }, 229); ev("keyup", { key: "1", code: "Digit1" }, 49);
  ev("keydown", { key: "Process", code: "Space", isComposing: true }, 229); ev("keyup", { key: " ", code: "Space" }, 32);
  ev("keydown", { key: "Process", code: "Comma", isComposing: true }, 229); ev("keyup", { key: ",", code: "Comma" }, 188);
  ev("keydown", { key: "Process", code: "Numpad5", isComposing: true, shiftKey: true }, 229); ev("keyup", { key: "5", code: "Numpad5" }, 101);
  ev("keydown", { key: "Enter", code: "Enter", isComposing: true, shiftKey: true }, 229); c("compositionend");
  ev("keydown", { key: "Enter", code: "Enter" }, 13);
  return 1; })(document.querySelector("#shell-term iframe").contentDocument)"""


def test_a_korean_password_leaves_no_letter_code_keycode_or_shift_in_the_queue_or_a_post(fake):
    hooked(fake)
    fake.evaluate(IME_SEQUENCE)
    queued = [json.loads(q) for q in fake.evaluate("keyLogQueue.map((e) => JSON.stringify(e))")]
    fake.evaluate("window.dispatchEvent(new Event('pagehide'))")
    sent = [e for batch in fake.evaluate("window.__posts") for e in batch]
    assert queued and [{k: v for k, v in e.items() if k != "t"} for e in sent] == [{k: v for k, v in e.items() if k != "t"} for e in queued]
    flat = json.dumps(sent)
    for leak in ("KeyG", "KeyK", "KeyQ", "KeyH", "Digit", "Space", "Comma", "Numpad", '"g"', '"k"', '"Q"', '"1"', '" "', '","', '"5"'):
        assert leak not in flat, leak
    for e in sent:
        if e["type"].startswith("composition"):
            assert set(e) == {"t", "type"}
        else:
            assert e["keyCode"] not in (71, 75, 81, 72, 49, 32, 188, 101, 229), e       # no real keyCode of a letter, nor the IME's 229
            if e["key"] in ("Process", "Unidentified") or e["isComposing"]:
                assert e["code"] in KL.CODES and e["keyCode"] == 0 and e["shift"] is False, e   # an IME event: its time, key name and, at most, a non-character code
    # what the key log is for stays readable: the Hangul/English key, right Alt, Enter, and that IME activity happened and when
    readable = [(e["type"], e["key"], e["code"], e["keyCode"]) for e in sent if e["type"].startswith("key") and e["code"]]
    assert readable == [("keydown", "HangulMode", "Lang1", 21), ("keyup", "HangulMode", "Lang1", 21), ("keydown", "Alt", "AltRight", 18),
                        ("keyup", "Alt", "AltRight", 18), ("keydown", "Process", "Lang1", 0), ("keyup", "Process", "Lang1", 0),
                        ("keydown", "Enter", "Enter", 0), ("keydown", "Enter", "Enter", 13)]     # the first Enter ended the composition: an IME event, no keyCode
    assert [e["type"] for e in sent if e["type"].startswith("composition")] == ["compositionstart", "compositionupdate", "compositionupdate", "compositionend"]
    assert sum(e["key"] == "Process" for e in sent if e["type"].startswith("key")) == 11         # the IME keydowns and the keyups of Process are there, as events
    assert not any(e["key"] in ("g", "k", "Q", "1", " ", ",", "5") for e in sent if e["type"].startswith("key"))   # the Latin keyups are not


def test_the_pages_lists_are_the_servers(fake):
    got = fake.evaluate("({ keys: [...KEYLOG_KEYS], codes: [...KEYLOG_CODES], keyCodes: [...KEYLOG_KEYCODES], ime: [...KEYLOG_IME_KEYS] })")
    assert sorted(got["keys"]) == sorted(KL.KEY_NAMES) and sorted(got["codes"]) == sorted(KL.CODES)
    assert sorted(got["keyCodes"]) == sorted(KL.KEYCODES) and sorted(got["ime"]) == sorted(KL.IME_KEYS)


def test_a_name_or_code_outside_the_lists_is_never_recorded(fake):
    hooked(fake)
    posts = frame_events(fake, """(d) => {
      const k = (type, init) => d.dispatchEvent(new KeyboardEvent(type, Object.assign({ bubbles: true }, init)));
      k("keydown", { key: "Hello", code: "" });                                            // a name no key sends
      k("keydown", { key: "Spacebar", code: "Space" }); k("keydown", { key: "Enter", code: "KeyA" });          // a code that names a letter key
      k("keydown", { key: "Enter", code: "Numpad5" }); k("keydown", { key: "Tab", code: "Comma" });
      k("keydown", { key: "Alt", code: "AltRight" });                                       // the control: this one is recorded
    }""")
    assert [(e["key"], e["code"]) for b in posts for e in b] == [("Alt", "AltRight")]


def test_events_go_in_batches_of_50_and_the_page_hide_flushes_what_waits(fake):
    hooked(fake)
    fake.evaluate("""(() => { const d = document.querySelector("#shell-term iframe").contentDocument;
      for (let i = 0; i < 120; i++) d.dispatchEvent(new KeyboardEvent("keydown", { key: "Shift", code: "ShiftLeft", shiftKey: true })); return 1; })()""")
    assert fake.evaluate("window.__posts.length") == 0                                  # nothing at once: every 2 s while there is any
    fake.evaluate("window.dispatchEvent(new Event('pagehide'))")
    assert [len(b) for b in fake.evaluate("window.__posts")] == [50, 50, 20]


# ---------------------------------------------------------------- the real ttyd (ttyd_harness.py)


@pytest.fixture
def real_shell(served, browser, monkeypatch):
    async def ensure(settings):
        return False
    monkeypatch.setattr(T, "ensure_shell_session", ensure)
    with real_ttyd(served) as (pane, port):
        url = f"http://127.0.0.1:{port}"
        browser.call("Browser.grantPermissions", {"origin": url, "permissions": ["clipboardReadWrite", "clipboardSanitizedWrite"]})
        browser.send("Emulation.setFocusEmulationEnabled", {"enabled": True})
        browser.send("Emulation.setDeviceMetricsOverride", {"width": 1100, "height": 800, "deviceScaleFactor": 1, "mobile": False})
        browser.open(f"{url}/#s={NAME}")
        assert browser.evaluate(WAIT_READY)
        yield {"browser": browser, "pane": pane, "url": url, "served": served}


def wait_for(browser, expr: str, secs: float = 20):
    return browser.evaluate("new Promise((res) => { const t0 = Date.now(); (function poll() { let v = false; try { v = (%s); } catch (e) {} "
                            "if (v || Date.now() - t0 > %d) res(v); else setTimeout(poll, 100); })(); })" % (expr, secs * 1000))


def open_real_shell(r):
    b = r["browser"]
    b.evaluate("setShell(true); 1")
    assert wait_for(b, """(() => { const t = document.querySelector("#shell-term iframe").contentWindow.term;
      return t && t.buffer && Array.from({ length: t.rows }, (_, i) => t.buffer.active.getLine(i)?.translateToString(true) || "").join("").includes("READY"); })()""") is True
    return b


FRAME = 'document.querySelector("#shell-term iframe")'

MEASURE = """(() => {
  const f = %s, w = f.contentWindow, t = w.term, d = f.contentDocument;
  const cv = d.createElement("canvas").getContext("2d"); cv.font = "14px D2Coding";
  const cell = t._core._renderService.dimensions.css.cell;
  const screen = d.querySelector(".xterm-screen");
  return { size: t.options.fontSize, family: t.options.fontFamily, cols: t.cols, rows: t.rows, cellW: cell.width, cellH: cell.height,
           aW: cv.measureText("A").width, wideW: cv.measureText("%s").width, screenW: screen.getBoundingClientRect().width,
           hostW: d.documentElement.clientWidth, loaded: [...d.fonts].filter((x) => x.family.includes("D2Coding") && x.status === "loaded").length,
           check: d.fonts.check("14px D2Coding") };
})()"""


def test_the_shell_in_ttyd_draws_in_d2coding_14px_with_cells_measured_from_it(real_shell):
    b = open_real_shell(real_shell)
    assert wait_for(b, FRAME + ".contentWindow.term.options.fontSize === 14") is True
    time.sleep(0.5)
    m = b.evaluate(MEASURE % (FRAME, KO[0]))
    assert m["size"] == 14 and m["family"] == '"D2Coding", Consolas, monospace' and m["loaded"] == 1 and m["check"] is True
    # a Korean letter is exactly two cells in D2Coding, and the terminal's cell is that face's, not the old one's
    assert abs(m["wideW"] - 2 * m["aW"]) < 0.01
    assert m["cellW"] == 7 and abs(m["cellW"] - m["aW"]) < 0.1, m     # a whole 7px: D2Coding's advance measures 6.99997 without size-adjust, which xterm floors to 6
    assert m["cellH"] > 14
    # the terminal was fitted again: the columns are what fits the frame at the new cell, and the pane has been told
    assert m["screenW"] == m["cols"] * m["cellW"] and 0 <= m["hostW"] - m["screenW"] < 2 * m["cellW"] + 24, m   # whole cells fill the frame (less ttyd's scrollbar and padding)
    pw = int(real_shell["pane"].tmux("display-message", "-p", "-t", "scratch", "#{window_width}").stdout.strip())
    assert pw == m["cols"], (pw, m)


def test_a_korean_letter_takes_two_columns_in_the_shell(real_shell):
    b = open_real_shell(real_shell)
    assert wait_for(b, FRAME + ".contentWindow.term.options.fontSize === 14") is True
    cells = b.evaluate("""new Promise((res) => { const t = %s.contentWindow.term;
      t.write("\\x1b[2J\\x1b[H%sAB", () => { const l = t.buffer.active.getLine(0);
        res([0, 1, 2, 3, 4, 5, 6, 7].map((i) => { const c = l.getCell(i); return [c.getChars(), c.getWidth()]; })); }); })""" % (FRAME, KO))
    assert cells == [[KO[0], 2], ["", 0], [KO[1], 2], ["", 0], [KO[2], 2], ["", 0], ["A", 1], ["B", 1]]


def test_real_key_events_reach_the_log_and_a_typed_letter_does_not(real_shell):
    b = open_real_shell(real_shell)
    assert wait_for(b, FRAME + ".contentWindow.term.options.fontSize === 14") is True
    b.evaluate(FRAME + ".contentWindow.term.focus(); 1")
    press(b, "q", "KeyQ", 81, text="q")                                      # typed text: never logged
    press(b, "Alt", "AltRight", 18, ALT)                                     # the Hangul/English key on a keyboard that sends AltRight
    press(b, "HangulMode", "Lang1", 21)
    log = real_shell["served"]["settings"].state_dir / "shell-keylog.jsonl"
    assert wait_for(b, "true") is True
    deadline = time.time() + 6
    while time.time() < deadline and not (log.exists() and "HangulMode" in log.read_text()):
        time.sleep(0.2)
    rows = [json.loads(line) for line in log.read_text().splitlines()]
    assert [(r["type"], r["key"], r["code"]) for r in rows if r["type"].startswith("key")] == [
        ("keydown", "Alt", "AltRight"), ("keyup", "Alt", "AltRight"), ("keydown", "HangulMode", "Lang1"), ("keyup", "HangulMode", "Lang1")]
    assert '"q"' not in log.read_text() and "KeyQ" not in log.read_text()
    assert oct(log.stat().st_mode & 0o777) == "0o600"


def test_the_terminal_tab_in_ttyd_keeps_ttyds_own_face(real_shell):
    b = real_shell["browser"]
    b.evaluate("""document.querySelector("#top .tab[data-tab=terminal]").click(); 1""")
    assert wait_for(b, """(() => { const t = document.querySelector("#terminal-pane iframe").contentWindow.term;
      return t && t.buffer && Array.from({ length: t.rows }, (_, i) => t.buffer.active.getLine(i)?.translateToString(true) || "").join("").includes("READY"); })()""") is True
    time.sleep(2)
    got = b.evaluate("""(() => { const f = document.querySelector("#terminal-pane iframe"), t = f.contentWindow.term;
      return [t.options.fontSize, t.options.fontFamily, f.contentDocument.getElementById("sala-shell-font") === null]; })()""")
    assert got[0] == 13 and "D2Coding" not in got[1] and got[2] is True


@pytest.mark.parametrize("arg, shell", [("sala-shell", True), ("some-claude-session", False)])
def test_the_full_size_page_gets_the_face_for_the_shell_session_only(real_shell, arg, shell):
    b = real_shell["browser"]
    b.open(f"{real_shell['url']}/terminal?arg={arg}")
    assert wait_for(b, """(() => { const f = document.querySelector("#term-full iframe"); const t = f && f.contentWindow.term;
      return t && t.buffer && Array.from({ length: t.rows }, (_, i) => t.buffer.active.getLine(i)?.translateToString(true) || "").join("").includes("READY"); })()""") is True
    time.sleep(2.5)
    got = b.evaluate("""(() => { const t = document.querySelector("#term-full iframe").contentWindow.term; return [t.options.fontSize, t.options.fontFamily]; })()""")
    if shell:
        assert got == [14, '"D2Coding", Consolas, monospace']
    else:
        assert got[0] == 13 and "D2Coding" not in got[1]
