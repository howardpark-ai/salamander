"""The name drawn for a session, in a headless Chromium (the function and the text of the script are test_session_label.py).

The rule: the chat session (SALA_CHAT_SESSION) is drawn under the label api/chat gives it everywhere the sidebar's entry draws it: the header at the top of the
session view and the tab's title say the same text as the entry, from the same function. The real name stays the key (the hash, state.selected, the links) and is
the header's tooltip. A session with no label is drawn under its own name, with no tooltip. A label renamed while the page is open is drawn again in every place.

Held here, at 1280 x 800 and 390 x 844, with api/chat replaced in the page and the real server behind everything else (a session `demo-one`, labelled `Demo One`):
  - the header's text is the entry's text, the tab's title is the same, the header's title attribute is the real name, and the hash and state.selected are the real name;
  - a rename of the label changes the entry, the header and the tab title together, and the hash stays;
  - with no label (no chat session configured) the header and the tab say the name and the header has no tooltip;
  - the Overview's row for the session says the label and links to #s=<name>;
  - a very long label never makes the page scroll sideways (1280, 390, 360, 320): the header's name is cut by its ellipsis inside the bar.

What a wrong answer costs: a header that says the raw name while the sidebar says another, a link built from the label, a label that stays stale after a rename, a header
pushed wider than the screen. Runs in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else is skipped; GitHub CI runs it. All names are invented."""

from __future__ import annotations

import pytest

from conftest import CHAT_READY
from test_board_items_ui import wait_for
from test_chat_session_view_ui import SIZES, api_chat, open_page, phone
from test_unread_filter import show_panel

NAME = "demo-one"
LABEL = "Demo One"
SERVED = [{"name": NAME}]

READ = """(() => ({
  header: document.querySelector('#title .name').textContent, tip: document.querySelector('#title .name').getAttribute('title'),
  entry: document.querySelector('#side-chat .label').textContent, docTitle: document.title, hash: location.hash, selected: state.selected,
  entryHref: document.querySelector('#side-chat').getAttribute('href') }))()"""


def same(browser, text: str) -> bool:
    """The header, the entry and the tab title all say `text` (polled: the label arrives with api/chat, after the first draw)."""
    q = f"(() => {{ const t = {text!r}; return document.querySelector('#title .name').textContent === t && document.querySelector('#side-chat .label').textContent === t && document.title === t; }})()"
    return wait_for(browser, q, 10.0)


@pytest.mark.parametrize("served", SERVED, indirect=True)
@pytest.mark.parametrize("size", SIZES)
def test_the_header_and_the_tab_title_say_what_the_sidebar_entry_says(served, browser, monkeypatch, size):
    open_page(browser, served, monkeypatch, size, api_chat(session=NAME, name=LABEL), chat=NAME, hash_="#s=" + NAME)
    assert same(browser, LABEL), browser.evaluate(READ)
    got = browser.evaluate(READ)
    assert got["header"] == got["entry"] == got["docTitle"] == LABEL, got
    assert got["tip"] == NAME, got                                   # the real name, for a person who needs to type or copy it
    assert got["hash"] == "#s=" + NAME and got["selected"] == NAME and got["entryHref"] == "#s=" + NAME, got   # the route is the real name


@pytest.mark.parametrize("served", SERVED, indirect=True)
@pytest.mark.parametrize("size", SIZES)
def test_a_renamed_label_is_drawn_again_in_the_entry_the_header_and_the_tab(served, browser, monkeypatch, size):
    open_page(browser, served, monkeypatch, size, api_chat(session=NAME, name=LABEL), chat=NAME, hash_="#s=" + NAME)
    assert same(browser, LABEL)
    browser.evaluate("window.__chat = Object.assign({}, window.__chat, { name: 'Demo Two' }); loadChatMarks(); ''")
    assert same(browser, "Demo Two"), browser.evaluate(READ)
    got = browser.evaluate(READ)
    assert got["tip"] == NAME and got["hash"] == "#s=" + NAME and got["selected"] == NAME, got
    # the label goes (the chat session is no longer configured): every place says the name again, and the tooltip goes with the difference
    browser.evaluate("window.__chat = Object.assign({}, window.__chat, { configured: false }); loadChatMarks(); ''")
    assert wait_for(browser, f"document.querySelector('#title .name').textContent === {NAME!r} && document.title === {NAME!r}", 10.0), browser.evaluate(READ)
    assert browser.evaluate("document.querySelector('#title .name').hasAttribute('title')") is False


@pytest.mark.parametrize("served", SERVED, indirect=True)
@pytest.mark.parametrize("size", SIZES)
def test_a_session_with_no_label_is_drawn_under_its_own_name_with_no_tooltip(served, browser, monkeypatch, size):
    open_page(browser, served, monkeypatch, size, api_chat(configured=False), chat=None, hash_="#s=" + NAME)
    assert wait_for(browser, f"document.querySelector('#title .name').textContent === {NAME!r} && document.title === {NAME!r}", 10.0), browser.evaluate(READ)
    assert browser.evaluate("document.querySelector('#title .name').hasAttribute('title')") is False
    # and another session beside the chat session keeps its own name: the label is for the chat session only
    browser.evaluate("window.__chat = Object.assign({}, window.__chat, { configured: true, session: 'demo-other', name: 'Other' }); loadChatMarks(); ''")
    assert wait_for(browser, "!document.querySelector('#side-chat').hidden", 10.0)
    assert browser.evaluate("document.querySelector('#title .name').textContent") == NAME and browser.evaluate("document.title") == NAME


@pytest.mark.parametrize("served", SERVED, indirect=True)
@pytest.mark.parametrize("size", SIZES)
def test_the_overview_row_says_the_label_and_links_to_the_real_name(served, browser, monkeypatch, size):
    open_page(browser, served, monkeypatch, size, api_chat(session=NAME, name=LABEL), chat=NAME, hash_="#sessions", ready=False)
    show_panel(browser)
    sel = f"#overview-pane a[href=\"#s={NAME}\"]"
    assert wait_for(browser, f"!!document.querySelector('{sel}') && document.querySelector('{sel}').textContent === {LABEL!r}", 12.0), browser.evaluate(
        f"[...document.querySelectorAll('#overview-pane a')].map((a) => a.getAttribute('href') + '=' + a.textContent).slice(0, 12)")
    assert browser.evaluate(f"document.querySelector('{sel}').title.startsWith({NAME!r})")     # the tooltip leads with the real name


SCROLL = """(() => { const n = document.querySelector('#title .name'), r = n.getBoundingClientRect(), t = document.querySelector('#top').getBoundingClientRect();
  return { doc: document.documentElement.scrollWidth, vw: document.documentElement.clientWidth, cut: n.scrollWidth > n.clientWidth, text: n.textContent,
           inside: r.left >= t.left - 0.5 && r.right <= t.right + 0.5 }; })()"""


@pytest.mark.parametrize("served", SERVED, indirect=True)
@pytest.mark.parametrize("size", SIZES)
def test_a_long_label_never_scrolls_the_page_sideways(served, browser, monkeypatch, size):
    long = "Label" + "W" * 120 + " and some more words after it"
    open_page(browser, served, monkeypatch, size, api_chat(session=NAME, name=long), chat=NAME, hash_="#s=" + NAME)
    assert same(browser, long)
    for w in ([size[0]] if not phone(size) else [390, 360, 320]):
        browser.send("Emulation.setDeviceMetricsOverride", {"width": w, "height": size[1], "deviceScaleFactor": 1, "mobile": phone(size)})
        assert wait_for(browser, f"document.documentElement.clientWidth === {w}", 10.0)
        assert wait_for(browser, "(() => { const n = document.querySelector('#title .name'); return n.scrollWidth > n.clientWidth; })()", 10.0), (w, browser.evaluate(SCROLL))
        got = browser.evaluate(SCROLL)
        assert got["doc"] <= got["vw"] and got["inside"], (w, got)      # cut by the ellipsis inside the bar, the page never wider than the screen
        assert got["text"] == long, (w, got)                            # the whole label is in the text, only the drawing is cut
