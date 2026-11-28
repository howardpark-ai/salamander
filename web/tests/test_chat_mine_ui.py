"""The done rows of the chat session's first list, in a headless Chromium (the server's side, the confirm route and the reply a row links to: test_chat_motion_done.py).

The rule: a line the session marked done with `sala motion done` waits in the owner's list, after his moves and counted with them, with a result (the given link,
else a jump to the first reply after the done time), a reply button and a confirm button; his confirm cannot be undone, and it or a reply made with the row's
button is what takes it away. Held here against the app itself (its api/chat, its confirm and outbox routes and the session's motion file; only the moves are
put in by the test), at 1280 x 800 and 390 x 844:
  - the done rows follow the moves, the tab counts both, and each row has its text, "Done", its result, its reply button and its confirm button;
  - a press on reply puts the line over the composer, where it can be taken away; a message sent with it there names the line and takes its row off the list,
    one sent without it takes nothing, and a refused send or a command takes nothing;
  - the jump lights the reply in the thread;
  - a press on confirm posts, the line leaves the file and the row leaves the list, the others staying; a second press while the first is on its way posts
    nothing and says nothing;
  - the reference over the composer goes when its line does (confirmed here or elsewhere, or the chat session set to another), from the browser's storage
    too; one that Edit gave back from a message the server had stays;
  - a confirm the server refuses says so under the tabs, the row staying, and the next confirm that works takes the line of words away;
  - the bar's one (?) says what the open list holds: for the first list the note on the moves, the note on the done lines, or both on lines of their own (with
    nothing in it, the one on the moves), for the second list its own note; a read that changes which notes those are shuts the box, any other leaves it;
  - under a finger the result, the reply and the confirm button are at least 44 px each way, no two targets of the list share a point and each of them
    answers in its middle and at the middle of each edge (the buttons' corners are rounded off); with a mouse none has the finger's size.

What a wrong answer costs: a line confirmed by a tap meant for its result, which no one can take back; a done line nobody sees; a confirm that fails in silence.
Runs in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else is skipped; GitHub CI runs it. All names are invented."""

from __future__ import annotations

import json
import time

import pytest

from conftest import transcript_file
from sala_web import chatpage as CP
from sala_web import motion as MO
from test_board_items_ui import wait_for
from test_chat_motion_done import filler_line, reply_line, write_motion
from test_chat_onit_ui import HELP_BTN, MOVE_NOTE, MOVE_PANEL, MOVE_TAB, NOTE, ONIT_TAB, PIN, click, phone, waiting
from test_chat_session_view_ui import DESKTOP, SIZES, open_page
from test_composer_editable import typed
from test_outbox_send import until

LINKED = "Compare the two venues and say which one holds the whole group, with the reasons for it"
JUMPED = "Draw slide 4"
RESULT = "https://example.com/results/4"
FAILED = "Could not confirm. The list was read again."
MINE_NOTE = "Lines the assistant has marked done in this chat. Confirm or reply to one once you have seen its result; it then leaves this list."
HEAD = '> In reply to the done "On it" line: '


def open_mine(browser, served, monkeypatch, size) -> list[dict]:
    """Two moves, a done line with a link, a done line whose result is a reply in the thread, and one line still open; the first list opened. The moves
    the app answers with are the list returned: a test changes it in place."""
    now = int(time.time())
    write_motion(served["settings"].motion_dir, served["name"], [
        {"text": LINKED, "at": now - 900, "done": now - 600, "link": RESULT},
        {"text": JUMPED, "at": now - 800, "done": now - 300},
        {"text": "Still open", "at": now - 60}])
    transcript_file(served).write_text(filler_line("u-ask", (now - 200) * 1000) + reply_line("a-result", (now - 100) * 1000))
    moves = waiting()
    monkeypatch.setattr(CP, "waiting", lambda board_doc, your_move=None: moves)
    open_page(browser, served, monkeypatch, size)
    assert wait_for(browser, f"!document.querySelector('#chat-strip').hidden && !{PIN}.hidden", 15.0)
    if size[0] < 700:
        phone(browser, size[0])
    click(browser, MOVE_TAB)
    assert wait_for(browser, f"document.querySelectorAll('#{MOVE_PANEL} .mine-row').length === 2", 15.0)
    browser.settle(PIN)
    return moves


ROWS = f"""(() => {{ const p = document.getElementById('{MOVE_PANEL}'), text = (n) => n ? n.textContent : null;
  return {{ tab: {MOVE_TAB}.textContent.trim(), err: [...document.querySelectorAll('#chat-strip-wait .wait-err')].filter((n) => n.getClientRects().length).map(text),
    rows: [...p.querySelectorAll('.wait-row')].map((r) => {{ const res = r.querySelector('.mine-result'), ok = r.querySelector('.mine-confirm'), re = r.querySelector('.mine-reply');
      return {{ mine: r.classList.contains('mine-row'), title: text(r.querySelector('.wait-title, .wait-link')), state: text(r.querySelector('.mine-state')),
        result: res ? [res.tagName, text(res), res.getAttribute('href'), res.getAttribute('target')] : null, confirm: ok ? [ok.tagName, ok.type, text(ok)] : null,
        reply: re ? [re.tagName, re.type, text(re)] : null }}; }}) }}; }})()"""


def row_button(title: str, kind: str) -> str:
    return (f"[...document.querySelectorAll('#{MOVE_PANEL} .mine-row')].find((r) => r.querySelector('.wait-title').textContent === {json.dumps(title)})"
            f".querySelector('.mine-{kind}')")


def confirm_button(title: str) -> str:
    return row_button(title, "confirm")


def kept(served) -> list[str]:
    return [r["text"] for r in json.loads((served["settings"].motion_dir / f"{served['name']}.json").read_text())["lines"]]


@pytest.mark.parametrize("size", SIZES)
def test_done_rows_follow_the_moves_and_a_confirm_takes_its_row_away(served, browser, monkeypatch, size):
    open_mine(browser, served, monkeypatch, size)
    got = browser.evaluate(ROWS)
    assert got["tab"].endswith(" 4") and got["err"] == [], got
    assert [r["mine"] for r in got["rows"]] == [False, False, True, True], got
    linked, jumped = got["rows"][2:]
    assert (linked["title"], linked["state"], linked["result"]) == (LINKED, "Done", ["A", "View result", RESULT, "_blank"]), got
    assert (jumped["title"], jumped["state"], jumped["result"]) == (JUMPED, "Done", ["BUTTON", "View result", None, None]), got
    assert [r["confirm"] for r in (linked, jumped)] == [["BUTTON", "button", "Confirm"]] * 2, got
    assert [r["reply"] for r in (linked, jumped)] == [["BUTTON", "button", "Reply"]] * 2, got
    assert all(r["confirm"] is None and r["reply"] is None and r["state"] is None for r in got["rows"][:2]), got

    reply = "document.querySelector('#chat > .msg[data-uuid=\"a-result\"]')"
    assert wait_for(browser, f"!!{reply}", 15.0)
    browser.evaluate(f"document.querySelector('#{MOVE_PANEL} button.mine-result').click(); ''")
    assert wait_for(browser, f"{reply}?.classList.contains('search-hit') === true", 15.0)

    click(browser, confirm_button(LINKED))
    assert wait_for(browser, f"document.querySelectorAll('#{MOVE_PANEL} .wait-row').length === 3", 15.0)
    got = browser.evaluate(ROWS)
    assert got["tab"].endswith(" 3") and got["err"] == [] and [r["title"] for r in got["rows"] if r["mine"]] == [JUMPED], got
    assert kept(served) == [JUMPED, "Still open"]


def test_a_refused_confirm_says_so_and_the_row_stays(served, browser, monkeypatch):
    open_mine(browser, served, monkeypatch, DESKTOP)
    # the first confirm is refused as the server refuses one (409), later ones go to the app
    browser.evaluate("""(() => { const real = window.fetch.bind(window); window.__posts = [];
      window.fetch = (url, opts) => { if (!String(url).startsWith('api/chat/motion/confirm')) return real(url, opts);
        window.__posts.push([opts.method, JSON.parse(opts.body)]);
        return window.__posts.length === 1 ? Promise.resolve(new Response('{}', { status: 409 })) : real(url, opts); }; return ''; })()""")
    click(browser, confirm_button(JUMPED))
    assert wait_for(browser, f"document.querySelector('#chat-strip-wait').innerText.includes({json.dumps(FAILED)})", 15.0)
    got = browser.evaluate(ROWS)
    assert got["err"] == [FAILED] and got["tab"].endswith(" 4") and len(got["rows"]) == 4, got
    posts = browser.evaluate("window.__posts")
    assert len(posts) == 1 and posts[0][0] == "POST" and posts[0][1]["text"] == JUMPED and isinstance(posts[0][1]["at"], int), posts
    assert kept(served) == [LINKED, JUMPED, "Still open"]

    click(browser, confirm_button(JUMPED))
    assert wait_for(browser, f"document.querySelectorAll('#{MOVE_PANEL} .wait-row').length === 3", 15.0)
    assert browser.evaluate(ROWS)["err"] == [] and kept(served) == [LINKED, "Still open"]


def test_a_double_press_on_confirm_posts_once_and_says_nothing(served, browser, monkeypatch):
    open_mine(browser, served, monkeypatch, DESKTOP)
    browser.evaluate("""(() => { const real = window.fetch.bind(window); window.__posts = 0;
      window.fetch = (url, opts) => { if (!String(url).startsWith('api/chat/motion/confirm')) return real(url, opts);
        window.__posts += 1; return new Promise((done) => { window.__go = () => real(url, opts).then(done); }); }; return ''; })()""")
    click(browser, confirm_button(JUMPED))
    click(browser, confirm_button(JUMPED))
    assert browser.evaluate("window.__posts") == 1
    browser.evaluate("window.__go(); ''")
    assert wait_for(browser, f"document.querySelectorAll('#{MOVE_PANEL} .wait-row').length === 3", 15.0)
    assert browser.evaluate(ROWS)["err"] == [] and browser.evaluate("window.__posts") == 1 and kept(served) == [LINKED, "Still open"]


# The reference over the composer: whether it shows, and its line.
REF = """(() => { const r = document.querySelector('#reply-ref');
  return [!r.hidden && r.getClientRects().length > 0, document.querySelector('#reply-ref-line').textContent]; })()"""


def say(browser, text: str) -> None:
    assert wait_for(browser, "!state.sending", 15.0)   # the send button is off while the last message is on its way
    browser.evaluate("document.querySelector('#input').focus(); ''")
    typed(browser, text)
    click(browser, "document.querySelector('#send')")


def sent(served) -> list[dict]:
    """The messages the server keeps for the session (the made-up pane takes nothing, so each is held)."""
    path = served["settings"].outbox_dir / f"{served['name']}.json"
    return json.loads(path.read_text())["messages"] if path.exists() else []


@pytest.mark.parametrize("size", SIZES)
def test_a_reply_names_its_line_over_the_composer_and_once_sent_takes_that_row_away(served, browser, monkeypatch, size):
    open_mine(browser, served, monkeypatch, size)
    assert browser.evaluate(REF) == [False, ""]
    click(browser, row_button(JUMPED, "reply"))
    assert browser.evaluate(REF) == [True, JUMPED]
    click(browser, "document.querySelector('#reply-ref-drop')")
    assert browser.evaluate(REF) == [False, ""]
    # the reference taken away: the message is an ordinary one, whatever it quotes, and no line leaves
    say(browser, f"> {JUMPED}")
    assert until(lambda: [m["text"] for m in sent(served)] == [f"> {JUMPED}"]), sent(served)
    assert kept(served) == [LINKED, JUMPED, "Still open"]

    # a send the server refuses takes nothing
    browser.evaluate("""(() => { const real = window.fetch.bind(window); window.__refused = 0;
      window.fetch = (url, opts) => { if (!String(url).startsWith('api/outbox/') || opts?.method !== 'POST' || window.__refused) return real(url, opts);
        window.__refused = 1; return Promise.resolve(new Response('{"ok": false, "error": "no"}', { status: 400 })); }; return ''; })()""")
    click(browser, row_button(LINKED, "reply"))
    say(browser, "this one is refused")
    assert wait_for(browser, "window.__refused === 1", 15.0)
    assert browser.evaluate(REF) == [False, ""]
    assert kept(served) == [LINKED, JUMPED, "Still open"] and len(sent(served)) == 1

    # a command can not be a reply: said so, kept in the box, nothing sent
    click(browser, row_button(JUMPED, "reply"))
    say(browser, "/status")
    assert wait_for(browser, "document.querySelector('#send-status').textContent.includes('A command cannot reply to a line')", 15.0)
    assert browser.evaluate(REF) == [True, JUMPED] and browser.evaluate("getText()") == "/status"
    assert len(sent(served)) == 1
    browser.evaluate("setText(''); ''")

    say(browser, "go on")
    assert wait_for(browser, f"document.querySelectorAll('#{MOVE_PANEL} .wait-row').length === 3", 15.0), browser.evaluate(ROWS)
    assert kept(served) == [LINKED, "Still open"]
    last = sent(served)[-1]
    assert (last["text"], last["own"], last["reply"]["text"]) == (f"{HEAD}{JUMPED}\ngo on", "go on", JUMPED), last
    assert browser.evaluate(REF) == [False, ""]
    assert wait_for(browser, "document.querySelector('#chat').textContent.includes('In reply to the done')", 15.0)


STORED = "localStorage.getItem('salaweb.reply.' + state.selected)"


def test_the_reply_reference_goes_when_its_line_does(served, browser, monkeypatch):
    open_mine(browser, served, monkeypatch, DESKTOP)
    # confirmed here
    click(browser, row_button(JUMPED, "reply"))
    assert browser.evaluate(REF) == [True, JUMPED] and browser.evaluate(f"!!{STORED}") is True
    click(browser, confirm_button(JUMPED))
    assert wait_for(browser, f"document.querySelector('#reply-ref').hidden && {STORED} === null", 15.0), browser.evaluate(REF)
    # confirmed on another device: the next read takes it away
    click(browser, row_button(LINKED, "reply"))
    browser.evaluate("loadChatMarks(); ''")
    assert browser.evaluate(REF) == [True, LINKED]
    line = next(r for r in MO.read_lines(served["settings"].motion_dir, served["name"]) if r["text"] == LINKED)
    assert MO.confirm(served["settings"].motion_dir, served["name"], LINKED, line["at"]) == "ok"
    browser.evaluate("loadChatMarks(); ''")
    assert wait_for(browser, f"document.querySelector('#reply-ref').hidden && {STORED} === null", 15.0), browser.evaluate(REF)


def test_the_reply_reference_goes_when_the_session_stops_being_the_chat(served, browser, monkeypatch):
    open_mine(browser, served, monkeypatch, DESKTOP)
    click(browser, row_button(JUMPED, "reply"))
    assert browser.evaluate(REF) == [True, JUMPED]
    monkeypatch.setenv("SALA_CHAT_SESSION", "another-chat")
    browser.evaluate("loadChatMarks(); ''")
    assert wait_for(browser, f"document.querySelector('#reply-ref').hidden && {STORED} === null", 15.0), browser.evaluate(REF)


def test_an_edited_reply_keeps_its_reference_though_its_line_was_taken(served, browser, monkeypatch):
    open_mine(browser, served, monkeypatch, DESKTOP)
    click(browser, row_button(JUMPED, "reply"))
    say(browser, "go on")
    assert wait_for(browser, f"document.querySelectorAll('#{MOVE_PANEL} .wait-row').length === 3", 15.0), browser.evaluate(ROWS)
    edit = "[...document.querySelectorAll('#chat > .msg.local .note-actions button')].find((b) => b.textContent === 'Edit')"
    assert wait_for(browser, f"!!{edit}", 15.0)
    click(browser, edit)
    assert wait_for(browser, "getText() === 'go on'", 15.0) and browser.evaluate(REF) == [True, JUMPED]
    browser.evaluate("window.__read = chatView.data; loadChatMarks(); ''")
    assert wait_for(browser, "chatView.data !== window.__read && !chatView.reading", 15.0)
    assert browser.evaluate(REF) == [True, JUMPED]


# Every target of the first list (the moves' title links, each done row's result, reply and confirm button): its box, the pairs whose boxes cross, and, scrolled to the
# middle of the list, the points (the middle, and the middle of each edge 1 px in) where elementFromPoint answers with something else.
TARGETS = f"""(() => {{ const w = document.getElementById('{MOVE_PANEL}'); w.style.scrollBehavior = 'auto';
  const all = [...w.querySelectorAll('.wait-link, .mine-reply, .mine-confirm')], boxes = all.map((n) => n.getBoundingClientRect()), overlap = [], missed = [];
  boxes.forEach((a, i) => boxes.slice(i + 1).forEach((b, k) => {{
    const x = Math.min(a.right, b.right) - Math.max(a.left, b.left), y = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top); if (x > 0.1 && y > 0.1) overlap.push([i, i + 1 + k, x, y]); }}));
  const mine = all.filter((n) => n.matches('.mine-result, .mine-reply, .mine-confirm')).map((n) => {{
    const q = n.getBoundingClientRect(), b = w.getBoundingClientRect(); w.scrollTop += Math.round((q.top + q.bottom - b.top - b.bottom) / 2);
    const r = n.getBoundingClientRect(), c = getComputedStyle(n);
    const mx = (r.left + r.right) / 2, my = (r.top + r.bottom) / 2;
    for (const [x, y] of [[mx, my], [r.left + 1, my], [r.right - 2, my], [mx, r.top + 1], [mx, r.bottom - 2]])
      if (document.elementFromPoint(x, y) !== n) missed.push([n.className, x - r.left, y - r.top]);
    return {{ kind: n.classList.contains('mine-confirm') ? 'confirm' : n.classList.contains('mine-reply') ? 'reply' : n.tagName, w: r.width, h: r.height, pad: [c.paddingTop, c.paddingRight, c.paddingBottom, c.paddingLeft].join(' '),
      min: [c.minWidth, c.minHeight].join(' ') }}; }});
  return {{ targets: all.length, overlap, missed, mine, side: w.scrollWidth - w.clientWidth }}; }})()"""


@pytest.mark.parametrize("size", [pytest.param((390, 844), id="390"), pytest.param((360, 844), id="360"), pytest.param((320, 844), id="320"),
                                  pytest.param(DESKTOP, id="desktop")])
def test_under_a_finger_the_result_the_reply_and_the_confirm_are_44px_and_apart(served, browser, monkeypatch, size):
    open_mine(browser, served, monkeypatch, size)
    browser.touch()
    assert wait_for(browser, "matchMedia('(pointer: coarse)').matches", 10.0)
    browser.settle(PIN)
    got = browser.evaluate(TARGETS)
    assert got["targets"] == 8 and sorted(t["kind"] for t in got["mine"]) == ["A", "BUTTON", "confirm", "confirm", "reply", "reply"], got
    assert all(t["w"] >= 43.9 and t["h"] >= 43.9 for t in got["mine"]), got
    assert got["overlap"] == [] and got["missed"] == [] and got["side"] <= 0, got


def test_with_a_mouse_the_done_row_keeps_its_small_controls(served, browser, monkeypatch):
    open_mine(browser, served, monkeypatch, DESKTOP)
    assert browser.evaluate("matchMedia('(pointer: coarse)').matches") is False
    got = browser.evaluate(TARGETS)
    for t in got["mine"]:
        assert t["h"] < 32 and t["pad"] == ("2px 8px 2px 8px" if t["kind"] in ("confirm", "reply") else "0px 0px 0px 0px"), got
        assert "44px" not in t["min"], got
    assert got["overlap"] == [], got


# The (?) and its box as they stand: how many (?) the pinned strip has, whether the box shows, its lines, whether each starts under the one before it, and
# whether the box stays inside the window with nothing to scroll sideways.
SAYS = """(() => { const p = document.querySelector('#chat-strip-wait'), b = p.querySelector('.wait-help'), pop = p.querySelector('.wait-pop'), spans = [...pop.children];
  const r = pop.getBoundingClientRect(), boxes = spans.map((s) => s.getBoundingClientRect());
  return { buttons: p.querySelectorAll('.wait-help, .exp-help').length, open: !pop.hidden && pop.getClientRects().length > 0, expanded: b.getAttribute('aria-expanded'),
    lines: spans.map((s) => s.textContent), apart: boxes.every((q, i) => !i || q.top >= boxes[i - 1].bottom + 1),
    inside: pop.hidden || (r.left >= 0 && r.right <= document.documentElement.clientWidth + 0.5 && pop.scrollWidth <= pop.clientWidth + 1) }; })()"""


def pressed(browser, lines: list[str]) -> None:
    """The (?) is the one button, shut; a press shows these lines, each on its own, inside the window."""
    got = browser.evaluate(SAYS)
    assert got["buttons"] == 1 and not got["open"] and got["expanded"] == "false", got
    click(browser, HELP_BTN)
    got = browser.evaluate(SAYS)
    assert got["open"] and got["expanded"] == "true" and got["lines"] == lines and got["apart"] and got["inside"], got


@pytest.mark.parametrize("size", SIZES)
def test_the_one_help_button_says_what_the_open_list_holds(served, browser, monkeypatch, size):
    moves = open_mine(browser, served, monkeypatch, size)
    rows = f"document.querySelectorAll('#{MOVE_PANEL} .wait-row').length"
    motion, name, now = served["settings"].motion_dir, served["name"], int(time.time())
    still, finished = {"text": "Still open", "at": now - 60}, {"text": JUMPED, "at": now - 800, "done": now - 300}

    def read(count: int) -> dict:
        browser.evaluate("loadChatMarks(); ''")
        assert wait_for(browser, f"{rows} === {count}", 15.0), browser.evaluate(ROWS)
        return browser.evaluate(SAYS)

    # moves and done lines: both notes, the moves' first; a language change words both again, the box staying open
    pressed(browser, [MOVE_NOTE, MINE_NOTE])
    browser.evaluate("SalaI18n.setLang('ko'); ''")
    korean = browser.evaluate("['chat.wait.note', 'chat.mine.note'].map((k) => SalaI18n.tables.ko[k])")
    got = browser.evaluate(SAYS)
    assert got["open"] and got["lines"] == korean and got["apart"] and got["inside"], got
    browser.evaluate("SalaI18n.setLang('en'); ''")
    # a read that changes the rows but not which notes they need leaves the box open
    moves.pop()
    got = read(3)
    assert got["open"] and got["lines"] == [MOVE_NOTE, MINE_NOTE], got
    # only done lines: their note alone (the read shuts the box, whose notes are no longer these)
    moves.clear()
    assert not read(2)["open"]
    pressed(browser, [MINE_NOTE])
    # nothing in the first list, which stays open beside a second list with a line: the note on the moves
    write_motion(motion, name, [still])
    assert not read(0)["open"]
    pressed(browser, [MOVE_NOTE])
    # only moves: the same note, so the box stays
    moves.extend(waiting())
    got = read(2)
    assert got["open"] and got["lines"] == [MOVE_NOTE], got
    # the second list: its own note, whatever the first holds, naming the first list
    write_motion(motion, name, [finished, still])
    assert not read(3)["open"]
    click(browser, ONIT_TAB)
    pressed(browser, [NOTE])
    click(browser, MOVE_TAB)
    pressed(browser, [MOVE_NOTE, MINE_NOTE])
