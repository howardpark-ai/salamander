"""The done rows of the chat session's first list, in a headless Chromium (the server's side, the confirm route and the reply a row links to: test_chat_motion_done.py).

The rule: a line the session marked done with `sala motion done` waits in the owner's list, after his moves and counted with them, with a result (the given link,
else a jump to the first reply after the done time) and a confirm button; his confirm cannot be undone and is what takes it away. Held here against the app
itself (its api/chat, its confirm route and the session's motion file; only the moves are put in by the test), at 1280 x 800 and 390 x 844:
  - the done rows follow the moves, the tab counts both, and each row has its text, "Done", its result and its confirm button;
  - the jump lights the reply in the thread;
  - a press on confirm posts, the line leaves the file and the row leaves the list, the others staying;
  - a confirm the server refuses says so under the tabs, the row staying, and the next confirm that works takes the line of words away;
  - under a finger the result and the confirm button are at least 44 px each way, no two targets of the list share a point and each of the two answers
    in its middle and at the middle of each edge (the confirm button's corners are rounded off); with a mouse neither has the finger's size.

What a wrong answer costs: a line confirmed by a tap meant for its result, which no one can take back; a done line nobody sees; a confirm that fails in silence.
Runs in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else is skipped; GitHub CI runs it. All names are invented."""

from __future__ import annotations

import json
import time

import pytest

from conftest import transcript_file
from sala_web import chatpage as CP
from test_board_items_ui import wait_for
from test_chat_motion_done import filler_line, reply_line, write_motion
from test_chat_onit_ui import MOVE_PANEL, MOVE_TAB, PIN, click, phone, waiting
from test_chat_session_view_ui import DESKTOP, SIZES, open_page

LINKED = "Compare the two venues and say which one holds the whole group, with the reasons for it"
JUMPED = "Draw slide 4"
RESULT = "https://example.com/results/4"
FAILED = "Could not confirm. The list was read again."


def open_mine(browser, served, monkeypatch, size) -> None:
    """Two moves, a done line with a link, a done line whose result is a reply in the thread, and one line still open; the first list opened."""
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


ROWS = f"""(() => {{ const p = document.getElementById('{MOVE_PANEL}'), text = (n) => n ? n.textContent : null;
  return {{ tab: {MOVE_TAB}.textContent.trim(), err: [...document.querySelectorAll('#chat-strip-wait .wait-err')].filter((n) => n.getClientRects().length).map(text),
    rows: [...p.querySelectorAll('.wait-row')].map((r) => {{ const res = r.querySelector('.mine-result'), ok = r.querySelector('.mine-confirm');
      return {{ mine: r.classList.contains('mine-row'), title: text(r.querySelector('.wait-title, .wait-link')), state: text(r.querySelector('.mine-state')),
        result: res ? [res.tagName, text(res), res.getAttribute('href'), res.getAttribute('target')] : null, confirm: ok ? [ok.tagName, ok.type, text(ok)] : null }}; }}) }}; }})()"""


def confirm_button(title: str) -> str:
    return (f"[...document.querySelectorAll('#{MOVE_PANEL} .mine-row')].find((r) => r.querySelector('.wait-title').textContent === {json.dumps(title)})"
            ".querySelector('.mine-confirm')")


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
    assert all(r["confirm"] is None and r["state"] is None for r in got["rows"][:2]), got

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


# Every target of the first list (the moves' title links, each done row's result and confirm button): its box, the pairs whose boxes cross, and, scrolled to the
# middle of the list, the points (the middle, and the middle of each edge 1 px in) where elementFromPoint answers with something else.
TARGETS = f"""(() => {{ const w = document.getElementById('{MOVE_PANEL}'); w.style.scrollBehavior = 'auto';
  const all = [...w.querySelectorAll('.wait-link, .mine-confirm')], boxes = all.map((n) => n.getBoundingClientRect()), overlap = [], missed = [];
  boxes.forEach((a, i) => boxes.slice(i + 1).forEach((b, k) => {{
    const x = Math.min(a.right, b.right) - Math.max(a.left, b.left), y = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top); if (x > 0.1 && y > 0.1) overlap.push([i, i + 1 + k, x, y]); }}));
  const mine = all.filter((n) => n.matches('.mine-result, .mine-confirm')).map((n) => {{
    const q = n.getBoundingClientRect(), b = w.getBoundingClientRect(); w.scrollTop += Math.round((q.top + q.bottom - b.top - b.bottom) / 2);
    const r = n.getBoundingClientRect(), c = getComputedStyle(n);
    const mx = (r.left + r.right) / 2, my = (r.top + r.bottom) / 2;
    for (const [x, y] of [[mx, my], [r.left + 1, my], [r.right - 2, my], [mx, r.top + 1], [mx, r.bottom - 2]])
      if (document.elementFromPoint(x, y) !== n) missed.push([n.className, x - r.left, y - r.top]);
    return {{ kind: n.classList.contains('mine-confirm') ? 'confirm' : n.tagName, w: r.width, h: r.height, pad: [c.paddingTop, c.paddingRight, c.paddingBottom, c.paddingLeft].join(' '),
      min: [c.minWidth, c.minHeight].join(' ') }}; }});
  return {{ targets: all.length, overlap, missed, mine, side: w.scrollWidth - w.clientWidth }}; }})()"""


@pytest.mark.parametrize("size", [pytest.param((390, 844), id="390"), pytest.param((360, 844), id="360"), pytest.param((320, 844), id="320"),
                                  pytest.param(DESKTOP, id="desktop")])
def test_under_a_finger_the_result_and_the_confirm_are_44px_and_apart(served, browser, monkeypatch, size):
    open_mine(browser, served, monkeypatch, size)
    browser.touch()
    assert wait_for(browser, "matchMedia('(pointer: coarse)').matches", 10.0)
    browser.settle(PIN)
    got = browser.evaluate(TARGETS)
    assert got["targets"] == 6 and sorted(t["kind"] for t in got["mine"]) == ["A", "BUTTON", "confirm", "confirm"], got
    assert all(t["w"] >= 43.9 and t["h"] >= 43.9 for t in got["mine"]), got
    assert got["overlap"] == [] and got["missed"] == [] and got["side"] <= 0, got


def test_with_a_mouse_the_done_row_keeps_its_small_controls(served, browser, monkeypatch):
    open_mine(browser, served, monkeypatch, DESKTOP)
    assert browser.evaluate("matchMedia('(pointer: coarse)').matches") is False
    got = browser.evaluate(TARGETS)
    for t in got["mine"]:
        assert t["h"] < 32 and t["pad"] == ("2px 8px 2px 8px" if t["kind"] == "confirm" else "0px 0px 0px 0px"), got
        assert "44px" not in t["min"], got
    assert got["overlap"] == [], got
