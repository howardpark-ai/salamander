"""Every link in a message opens in a new tab, in a headless Chromium (the page's own markdown rules are test_md_rules.py).

A link in the body of a message (the reply's markdown, the owner's typed line) used to follow the page's own rule: a link to this site's own host (a Canvas page, say)
had no target and loaded in the tab it was tapped in, so the browser asked "Leave site?" and the session page was lost. Held here, at 1280 x 800, against the real server
and a real transcript, on the chat page (SALA_CHAT_SESSION) and on the plain session view (the same transcript, no chat session configured):
  - a link to this site's host, one to another host and (in a reply) a relative one, and the first two in the owner's line, each has target=_blank and rel="noopener noreferrer";
  - a real click on each opens a new page (tab) and the session page keeps its address, its history and its thread.

What a wrong answer costs: a session page that is navigated away from, with a prompt to leave it. Runs in a headless Chromium when one is installed (conftest.py: `served`,
`browser`), else is skipped; GitHub CI runs it. All names are invented."""

from __future__ import annotations

import json
import shutil
import time

import pytest

from conftest import NAME, transcript_file, transcript_line
from test_board_items_ui import wait_for
from test_chat_session_view_ui import DESKTOP, open_page
from test_search_ui import page_targets

KINDS = ["same host", "other host", "relative"]


@pytest.fixture(autouse=True)
def _rm_tmp(tmp_path):
    yield
    shutil.rmtree(tmp_path, ignore_errors=True)


def write_thread(served) -> None:
    own = served["url"] + "/mockup/3"
    root = served["settings"].mockups_dir
    root.mkdir(parents=True, exist_ok=True)
    (root / "3.html").write_text("<!doctype html><title>Plan</title><p>x</p>", encoding="utf-8")
    ask = f"my links: [same host]({own}) [other host](https://docs.example.test/guide)"   # a typed line links only http(s) addresses (linkTokens)
    answer = f"Here: [same host]({own}), [other host](https://docs.example.test/guide) and [relative](mockup/3)."
    transcript_file(served).write_text(
        transcript_line("user", [{"type": "text", "text": ask}], "c-1", human=True)
        + transcript_line("assistant", [{"type": "text", "text": answer}], "c-2", model="claude-opus-5-5"), encoding="utf-8")


LINKS = """(() => [...document.querySelectorAll('#chat .msg .md a, #chat .msg.user a')].filter((a) => !a.classList.contains('link-card'))
  .map((a) => ({ text: a.textContent, msg: a.closest('.msg').classList.contains('assistant') ? 'assistant' : 'user', target: a.getAttribute('target'), rel: a.getAttribute('rel') })))()"""


@pytest.mark.parametrize("chat", ["chat", None], ids=["chat page", "plain session view"])
def test_every_message_link_opens_in_a_new_tab_and_the_session_page_stays(served, browser, monkeypatch, chat):
    write_thread(served)
    open_page(browser, served, monkeypatch, DESKTOP, None, chat=NAME if chat else None)
    assert wait_for(browser, "document.querySelectorAll('#chat .msg a[href]').length >= 5", 15.0)
    links = browser.evaluate(LINKS)
    assert sorted((l["msg"], l["text"]) for l in links) == sorted([("assistant", k) for k in KINDS] + [("user", k) for k in KINDS[:2]]), links
    for l in links:
        assert (l["target"], l["rel"]) == ("_blank", "noopener noreferrer"), l
    start = browser.evaluate("({ href: location.href, depth: history.length, msgs: document.querySelectorAll('#chat > .msg').length })")
    opened = []
    try:
        for kind in KINDS:
            before = set(page_targets(browser))
            browser.evaluate(f"""(() => {{ const a = [...document.querySelectorAll('#chat .msg.assistant .md a')].find((x) => x.textContent === {json.dumps(kind)});
              a.scrollIntoView({{ block: 'center' }}); const r = a.getBoundingClientRect(); window.__at = [r.x + r.width / 2, r.y + r.height / 2]; }})()""")
            x, y = browser.evaluate("window.__at")
            for t in ("mousePressed", "mouseReleased"):
                browser.send("Input.dispatchMouseEvent", {"type": t, "x": x, "y": y, "button": "left", "clickCount": 1})
            end = time.time() + 10
            new = []
            while time.time() < end and not new:
                new = [i for i in page_targets(browser) if i not in before]
                time.sleep(0.1)
            assert new, f"the {kind} link opened no new page"
            opened += new
            assert browser.evaluate("({ href: location.href, depth: history.length, msgs: document.querySelectorAll('#chat > .msg').length })") == start, kind
    finally:
        for tid in opened:
            try:
                browser.call("Target.closeTarget", {"targetId": tid})
            except RuntimeError:
                pass
