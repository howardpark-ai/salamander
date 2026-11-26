"""The chat session's header and tab title say its label, in a headless Chromium (the function and the text of the script are test_session_label.py).

The rule: while the open session IS the chat session (SALA_CHAT_SESSION), the header's name and the tab's title say the label api/chat gives it, the same text as the
sidebar's entry; the real name is the header's tooltip. A label renamed while the page is open is drawn again. Every other session is drawn as it always was: its own
name in the header and the tab, no tooltip, and the same Overview row.

Held here, at 1280 x 800 and 390 x 844, with api/chat replaced in the page and the real server behind everything else (the fake session is `demo-one`, labelled
`Demo One`, or `demo-two`, which is not the chat session):
  - the header's text, the tab's title and the entry's text are equal; the header's tooltip is the real name; the route and state.selected are the real name;
  - a rename of the label changes all three together, and a label that goes (no chat session configured) leaves the name and no tooltip;
  - with no label the header and the tab say the name;
  - a second session, `demo-two`, while the chat entry says `Demo One`: its header, tab and Overview row say `demo-two`, and it has no tooltip;
  - a very long label never makes the page scroll sideways (1280, 390, 360, 320): the header's name is cut by its ellipsis inside the bar.

What a wrong answer costs: a header that says the raw name while the sidebar says another, a label that leaks into another session's header or the Overview, a label that
stays stale after a rename, a header pushed wider than the screen. Runs in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else is skipped;
GitHub CI runs it. All names are invented."""

from __future__ import annotations

import json

import pytest

from test_board_items_ui import wait_for
from test_chat_session_view_ui import MEASURE, SIZES, api_chat, check, open_page, phone
from test_unread_filter import show_panel

NAME = "demo-one"
OTHER = "demo-two"
LABEL = "Demo One"

# the tooltip is the title attribute of the span inside the name (a view that is no chat session writes the name's text and the span is gone)
READ = """(() => { const n = document.querySelector('#title .name'), t = n.querySelector('[title]');
  return { header: n.textContent, tip: t ? t.getAttribute('title') : null, ownTip: n.getAttribute('title'), tipNodes: n.querySelectorAll('[title]').length,
           entry: document.querySelector('#side-chat .label').textContent, docTitle: document.title, hash: location.hash, selected: state.selected }; })()"""


def full(browser) -> str:
    """The whole READ as one JSON line, for a failure message: pytest cuts a long dict short, and the tab's title (`docTitle`) was the part a failed run did not show."""
    return json.dumps(browser.evaluate(READ), sort_keys=True)


def say(text: str) -> str:
    """The header, the entry and the tab title all say `text`."""
    return (f"(() => {{ const t = {text!r}; return document.querySelector('#title .name').textContent === t "
            f"&& document.querySelector('#side-chat .label').textContent === t && document.title === t; }})()")


def says_name(text: str) -> str:
    """The header and the tab title say `text`, and nothing in the header has a tooltip."""
    return (f"(() => {{ const n = document.querySelector('#title .name'); return n.textContent === {text!r} && document.title === {text!r} "
            f"&& !n.hasAttribute('title') && n.querySelectorAll('[title]').length === 0; }})()")


@pytest.mark.parametrize("served", [{"name": NAME}], indirect=True)
@pytest.mark.parametrize("size", SIZES)
def test_the_chat_session_header_and_tab_title_say_what_the_sidebar_entry_says(served, browser, monkeypatch, size):
    open_page(browser, served, monkeypatch, size, api_chat(session=NAME, name=LABEL), chat=NAME, hash_="#s=" + NAME)
    assert wait_for(browser, say(LABEL), 10.0), browser.evaluate(READ)      # polled: the label arrives with api/chat, after the first draw
    got = browser.evaluate(READ)
    assert got["header"] == got["entry"] == got["docTitle"] == LABEL, got
    assert got["tip"] == NAME and got["tipNodes"] == 1 and got["ownTip"] is None, got      # the real name, for a person who needs to type or copy it
    assert got["hash"] == "#s=" + NAME and got["selected"] == NAME, got                    # the route and the selection are the real name


@pytest.mark.parametrize("served", [{"name": NAME}], indirect=True)
@pytest.mark.parametrize("size", SIZES)
def test_a_renamed_label_is_drawn_again_in_the_entry_the_header_and_the_tab(served, browser, monkeypatch, size):
    open_page(browser, served, monkeypatch, size, api_chat(session=NAME, name=LABEL), chat=NAME, hash_="#s=" + NAME)
    assert wait_for(browser, say(LABEL), 10.0), full(browser)
    browser.evaluate("window.__chat = Object.assign({}, window.__chat, { name: 'Demo Three' }); loadChatMarks(); ''")      # the read the 25-second poll makes
    assert wait_for(browser, say("Demo Three"), 10.0), full(browser)
    got = browser.evaluate(READ)
    assert got["tip"] == NAME and got["hash"] == "#s=" + NAME and got["selected"] == NAME, got
    # the label goes (the chat session is no longer configured): the name again, and no tooltip
    browser.evaluate("window.__chat = Object.assign({}, window.__chat, { configured: false }); loadChatMarks(); ''")
    assert wait_for(browser, says_name(NAME), 10.0), full(browser)


@pytest.mark.parametrize("served", [{"name": NAME}], indirect=True)
@pytest.mark.parametrize("size", SIZES)
def test_with_no_label_the_header_and_the_tab_say_the_name_and_have_no_tooltip(served, browser, monkeypatch, size):
    open_page(browser, served, monkeypatch, size, api_chat(configured=False), chat=None, hash_="#s=" + NAME, ready=False)
    assert wait_for(browser, says_name(NAME), 10.0), browser.evaluate(READ)


@pytest.mark.parametrize("served", [{"name": OTHER}], indirect=True)
@pytest.mark.parametrize("size", SIZES)
def test_another_session_keeps_its_name_in_the_header_the_tab_and_the_overview(served, browser, monkeypatch, size):
    open_page(browser, served, monkeypatch, size, api_chat(session=NAME, name=LABEL), chat=NAME, hash_="#s=" + OTHER, ready=False)
    assert wait_for(browser, f"document.querySelector('#side-chat .label').textContent === {LABEL!r}", 10.0), browser.evaluate(READ)     # the label exists, for the chat session
    assert wait_for(browser, says_name(OTHER), 10.0), browser.evaluate(READ)                  # and this session's header and tab are its own name, no tooltip
    browser.evaluate("window.__chat = Object.assign({}, window.__chat, { name: 'Demo Three' }); loadChatMarks(); ''")      # a rename of the chat label does not reach it
    assert wait_for(browser, "document.querySelector('#side-chat .label').textContent === 'Demo Three'", 10.0), browser.evaluate(READ)
    assert browser.evaluate(says_name(OTHER)) is True, browser.evaluate(READ)
    # the Overview's row for it is its name, as ever
    browser.evaluate("location.hash = '#sessions'; ''")
    show_panel(browser)
    sel = f"#overview-pane a[href=\"#s={OTHER}\"]"
    assert wait_for(browser, f"!!document.querySelector('{sel}') && document.querySelector('{sel}').textContent === {OTHER!r}", 12.0), browser.evaluate(
        "[...document.querySelectorAll('#overview-pane a')].map((a) => a.getAttribute('href') + '=' + a.textContent).slice(0, 12)")


SCROLL = """(() => { const n = document.querySelector('#title .name'), s = n.querySelector('span[title]'), r = (s || n).getBoundingClientRect(), t = document.querySelector('#top').getBoundingClientRect();
  return { doc: document.documentElement.scrollWidth, vw: document.documentElement.clientWidth, cut: (s || n).scrollWidth > (s || n).clientWidth, text: n.textContent,
           inside: r.left >= t.left - 0.5 && r.right <= t.right + 0.5 }; })()"""


@pytest.mark.parametrize("served", [{"name": NAME}], indirect=True)
@pytest.mark.parametrize("size", SIZES)
def test_a_long_label_never_scrolls_the_page_sideways(served, browser, monkeypatch, size):
    long = "Label" + "W" * 120 + " and some more words after it"
    open_page(browser, served, monkeypatch, size, api_chat(session=NAME, name=long), chat=NAME, hash_="#s=" + NAME)
    assert wait_for(browser, say(long), 10.0), browser.evaluate(READ)
    for w in ([size[0]] if not phone(size) else [390, 360, 320]):
        browser.send("Emulation.setDeviceMetricsOverride", {"width": w, "height": size[1], "deviceScaleFactor": 1, "mobile": phone(size)})
        assert wait_for(browser, f"document.documentElement.clientWidth === {w}", 10.0)
        assert wait_for(browser, "(() => { const s = document.querySelector('#title .name span[title]'); return !!s && s.scrollWidth > s.clientWidth; })()", 10.0), (w, browser.evaluate(SCROLL))
        got = browser.evaluate(SCROLL)
        assert got["doc"] <= got["vw"] and got["inside"], (w, got)      # cut by the ellipsis inside the bar, the page never wider than the screen
        assert got["text"] == long and got["cut"], (w, got)             # the whole label is in the text, only the drawing is cut
        check(browser.evaluate(MEASURE), f"{w} px, a {len(long)}-character label")   # the measure of the thread test: no box, the label's span included, ends outside the window
