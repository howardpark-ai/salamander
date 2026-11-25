"""Link cards in the chat session's view, in a headless Chromium (the data and the script's logic are test_chat_link_cards.py).

The chat session (SALA_CHAT_SESSION) is sala's own view of a session. A reply of that session that links a /mockup/<n> page of this site or a claude.ai artifact is drawn with a
card under its text, by the one renderer every session uses. Held here, at 1280 x 800 and 390 x 844, against the real server and a real transcript (nothing is replaced):
  - each such link is one card under the reply's text: the right address, a new tab, rel noopener, its title and the kind of page it is, focusable by keyboard; a link that is
    not a mockup or an artifact has no card and stays the plain link in the text;
  - the card is sala's own: the panel gray with the border and corner of sala's folds, the text colors tokens, readable (4.5:1) in the dark and the light palette;
  - a card follows the interface language in place (English, Korean) with no redraw;
  - a reply that arrives while the page is open gets its cards;
  - another session given the same transcript has the plain links and no card;
  - NO SIDEWAYS SCROLL, at 1280, 390, 360 and 320 px, drawer shut and open, with a 300-character word and a long address in the card's title, a long artifact address and a
    long address as plain text in the same reply.

What a wrong answer costs: a card that is not clickable, opens over the page it was in, a card in the wrong palette or unreadable in one, a card for a plain link, a card on
another session's page, a page that scrolls sideways. Runs in a headless Chromium when one is installed (conftest.py: `served`, `browser`), else is skipped; GitHub CI runs it.
It was written and collected on a box whose Chromium does not start, so CI is its first run. All names are invented."""

from __future__ import annotations

import json
import shutil

import pytest

from conftest import NAME, transcript_file, transcript_line
from test_board_items_ui import wait_for
from test_chat_session_view_ui import DESKTOP, MEASURE, PHONE, SIZES, URL, WORD, check, drawer_open, open_page

ART = "https://claude.ai/artifact/AbC123_x-9"
ART_LONG = "https://claude.ai/artifact/" + "a" * 80
PLAIN = "https://example.com/some/page"


@pytest.fixture(autouse=True)
def _rm_tmp(tmp_path):
    yield
    shutil.rmtree(tmp_path, ignore_errors=True)


def mockup(served, n: int, title: str) -> None:
    root = served["settings"].mockups_dir
    root.mkdir(parents=True, exist_ok=True)
    (root / f"{n}.html").write_text(f"<!doctype html><title>{title}</title><p>x</p>", encoding="utf-8")


def reply_text() -> str:
    return (f"Both pages are up: [the pricing page](/mockup/3) and [the plan]({ART}), and the bare {ART_LONG}.\n\n"
            f"Not a card: {PLAIN}, and [a docs page](https://docs.example.test/guide/start).")


def write(served, *lines: str) -> None:
    transcript_file(served).write_text("".join(lines), encoding="utf-8")


def append(served, *lines: str) -> None:
    with transcript_file(served).open("a", encoding="utf-8") as f:
        f.write("".join(lines))


def thread(text: str | None = None) -> tuple[str, str]:
    """The owner's typed line and one reply (the owner's own turn shows whole, whatever the clock)."""
    return (transcript_line("user", [{"type": "text", "text": "show me the pages"}], "c-1", human=True),
            transcript_line("assistant", [{"type": "text", "text": text if text is not None else reply_text()}], "c-2", model="claude-opus-5-5"))


def open_real(browser, served, monkeypatch, size, **kw) -> None:
    open_page(browser, served, monkeypatch, size, None, **kw)
    assert wait_for(browser, "!document.querySelector('#chat-strip').hidden", 15.0)


CARDS = """(() => { const reply = document.querySelector('#chat .msg.assistant'), md = reply.querySelector('.md'), vw = document.documentElement.clientWidth;
  const cards = [...reply.querySelectorAll(':scope > a.link-card')];
  const mdR = md.getBoundingClientRect();
  return { count: cards.length, all: document.querySelectorAll('#chat .link-card').length,
           cards: cards.map((a) => { const r = a.getBoundingClientRect(), q = (s) => (a.querySelector(s) || {}).textContent || null;
             return { href: a.getAttribute('href'), target: a.target, rel: a.rel, tab: a.tabIndex, title: q('.lc-t'), kind: q('.lc-l'), opens: q('.lc-o'),
                      below: r.top >= mdR.bottom - 0.5, left: r.left, right: r.right, w: r.width, scrollW: a.scrollWidth, clientW: a.clientWidth, vw, tag: a.tagName }; }),
           plain: [...md.querySelectorAll('a[href]')].map((a) => a.getAttribute('href')),
           cardsInMd: md.querySelectorAll('.link-card').length }; })()"""


# ── the cards ────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("size", SIZES)
def test_each_mockup_and_artifact_link_has_a_card_under_the_text_and_a_plain_link_has_none(served, browser, monkeypatch, size):
    mockup(served, 3, "Pricing page")
    write(served, *thread())
    open_real(browser, served, monkeypatch, size)
    assert wait_for(browser, "document.querySelectorAll('#chat .link-card').length === 3", 15.0)
    d = browser.evaluate(CARDS)
    assert d["count"] == 3 and d["all"] == 3 and d["cardsInMd"] == 0, d
    mock, art, bare = d["cards"]
    assert (mock["href"], mock["title"], mock["kind"]) == ("mockup/3", "Pricing page", "Mockup 3"), mock
    assert (art["href"], art["title"], art["kind"]) == (ART, "the plan", "Claude artifact"), art
    assert (bare["href"], bare["title"], bare["kind"]) == (ART_LONG, "Claude artifact", None), bare   # no link text: the kind is the title
    for c in d["cards"]:
        assert c["tag"] == "A" and c["target"] == "_blank" and "noopener" in c["rel"] and c["tab"] >= 0, c      # a link: the keyboard reaches it, a new tab
        assert c["opens"] and "↗" in c["opens"] and c["below"], c
    for want in (PLAIN, "https://docs.example.test/guide/start", "/mockup/3", ART):
        assert want in d["plain"], (want, d["plain"])      # the text keeps every link it had, and the two that are not cards are only that


@pytest.mark.parametrize("size", SIZES)
def test_a_card_takes_the_keyboards_focus_and_shows_the_ring(served, browser, monkeypatch, size):
    write(served, *thread())
    open_real(browser, served, monkeypatch, size)
    assert wait_for(browser, "document.querySelectorAll('#chat .link-card').length === 3", 15.0)
    browser.evaluate("document.querySelector('#chat .link-card').focus(); ''")
    assert browser.evaluate("document.activeElement === document.querySelector('#chat .link-card')") is True
    # the ring itself is sala's focus style (style.css, held in test_chat_link_cards.py); a script's focus() shows it or not by the browser's own heuristic
    assert browser.evaluate("[...document.querySelectorAll('#chat .link-card')].every((a) => a.tabIndex === 0)") is True


def test_a_card_is_sala_s_own_in_the_dark_and_the_light_palette_and_readable_in_both(served, browser, monkeypatch):
    mockup(served, 3, "Pricing page")
    write(served, *thread())
    open_real(browser, served, monkeypatch, DESKTOP)
    assert wait_for(browser, "document.querySelectorAll('#chat .link-card').length === 3", 15.0)
    probe = """(() => { const card = document.querySelector('#chat .link-card'), cs = getComputedStyle(card);
      const tok = (v, prop) => { const p = document.createElement('i'); p.style[prop] = 'var(' + v + ')'; document.body.append(p); const c = getComputedStyle(p)[prop]; p.remove(); return c; };
      const num = (c) => (c.match(/[\\d.]+/g) || []).slice(0, 3).map(Number);
      const lum = (c) => { const [r, g, b] = num(c).map((x) => { x /= 255; return x <= 0.03928 ? x / 12.92 : Math.pow((x + 0.055) / 1.055, 2.4); }); return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
      const ratio = (a, b) => { const x = lum(a), y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); };
      const fold = document.createElement('details'); fold.className = 'fold'; document.querySelector('#chat').append(fold); const fs = getComputedStyle(fold);
      const out = { bg: cs.backgroundColor, panel: tok('--panel', 'backgroundColor'), border: cs.borderTopColor, borderTok: tok('--border', 'borderTopColor'), radius: cs.borderTopLeftRadius,
                    foldRadius: fs.borderTopLeftRadius, foldBg: fs.backgroundColor, foldBorder: fs.borderTopColor, dark: matchMedia('(prefers-color-scheme: dark)').matches,
                    page: getComputedStyle(document.body).backgroundColor, text: {} };
      fold.remove();
      for (const k of ['lc-t', 'lc-l', 'lc-o']) { const c = getComputedStyle(card.querySelector('.' + k)).color; out.text[k] = [c, Math.round(ratio(c, cs.backgroundColor) * 100) / 100]; }
      return out; })()"""
    seen = {}
    for scheme in ("dark", "light"):
        browser.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": scheme}]})
        assert wait_for(browser, f"matchMedia('(prefers-color-scheme: {scheme})').matches", 5.0)
        browser.settle("document.querySelector('#chat')")
        d = browser.evaluate(probe)
        seen[scheme] = d
        assert d["dark"] == (scheme == "dark"), d
        assert d["bg"] == d["panel"] == d["foldBg"] and d["border"] == d["borderTok"] == d["foldBorder"] and d["radius"] == d["foldRadius"] == "8px", d   # sala's own card: the panel, its border and corner
        for k, (color, ratio) in d["text"].items():
            assert ratio >= 4.5, (scheme, k, color, ratio, d)
    assert seen["dark"]["bg"] != seen["light"]["bg"], "the two palettes are told apart"


def test_a_card_follows_the_interface_language_in_place(served, browser, monkeypatch):
    mockup(served, 3, "Pricing page")
    write(served, *thread())
    open_real(browser, served, monkeypatch, DESKTOP)
    assert wait_for(browser, "document.querySelectorAll('#chat .link-card').length === 3", 15.0)
    words = "(() => { const a = document.querySelector('#chat .link-card'); return [a.querySelector('.lc-l').textContent, a.querySelector('.lc-o').textContent, a.querySelector('.lc-t').textContent]; })()"
    en = browser.evaluate(words)
    assert en[0] == "Mockup 3" and en[2] == "Pricing page"
    browser.evaluate("SalaI18n.setLang('ko'); ''")
    try:
        assert wait_for(browser, f"document.querySelector('#chat .link-card .lc-o').textContent !== {json.dumps(en[1])}", 5.0)
        ko = browser.evaluate(words)
        assert ko[1] == browser.evaluate("tl('chat.card.opens')") and ko[0] == browser.evaluate("tl('chat.card.mockup', { n: 3 })") and ko[0] != en[0]
        assert ko[2] == "Pricing page", "the title is the page's own text, not an interface word"
    finally:
        browser.evaluate("SalaI18n.setLang('en'); ''")


@pytest.mark.parametrize("size", SIZES)
def test_a_reply_that_arrives_while_the_page_is_open_gets_its_cards(served, browser, monkeypatch, size):
    write(served, *thread("Nothing yet."))
    open_real(browser, served, monkeypatch, size)
    assert browser.evaluate("document.querySelectorAll('#chat .link-card').length") == 0
    mockup(served, 5, "Second page")
    append(served, transcript_line("user", [{"type": "text", "text": "and another"}], "c-3", human=True),
           transcript_line("assistant", [{"type": "text", "text": "Here: [second](/mockup/5)"}], "c-4", model="claude-opus-5-5"))
    assert wait_for(browser, "document.querySelectorAll('#chat .link-card').length === 1", 15.0)
    d = browser.evaluate("(() => { const a = document.querySelector('#chat .link-card'); return [a.getAttribute('href'), a.querySelector('.lc-t').textContent, a.closest('.msg').dataset.uuid]; })()")
    assert d == ["mockup/5", "Second page", "c-4"], d


@pytest.mark.parametrize("size", SIZES)
def test_another_session_given_the_same_transcript_has_the_plain_links_and_no_card(served, browser, monkeypatch, size):
    write(served, *thread())
    open_page(browser, served, monkeypatch, size, None, chat="demo-someone-else")
    assert wait_for(browser, "document.querySelectorAll('#chat .msg.assistant .md a[href]').length >= 3", 15.0)
    assert browser.evaluate("document.querySelectorAll('#chat .link-card').length") == 0
    assert browser.evaluate("document.querySelector('#chat-strip').hidden") is True


# ── no sideways scroll ───────────────────────────────────────────────────────
def hostile_reply() -> str:
    return (f"Pages: [{WORD}](/mockup/3), [{WORD} {URL}]({ART}), [{URL}](https://claude.ai/artifact/{'b' * 60}) and the bare {ART_LONG}\n\n"
            f"{URL}\n\n[{WORD}]({URL})\n\n{WORD}")


CARD_BOXES = """(() => { const vw = document.documentElement.clientWidth, out = [];
  for (const a of document.querySelectorAll('#chat .link-card')) {
    const r = a.getBoundingClientRect();
    if (r.right > vw + 0.5 || r.left < -0.5 || a.scrollWidth > a.clientWidth + 0.5) out.push([a.textContent.slice(0, 24), Math.round(r.left), Math.round(r.right), a.scrollWidth, a.clientWidth]);
    for (const k of a.children) if (k.scrollWidth > k.clientWidth + 0.5) out.push(['child', k.className, k.scrollWidth, k.clientWidth]);
  }
  return { bad: out, n: document.querySelectorAll('#chat .link-card').length }; })()"""


@pytest.mark.parametrize("width", [1280, 390, 360, 320])
@pytest.mark.parametrize("drawer", [False, True], ids=["drawer-shut", "drawer-open"])
def test_no_sideways_scroll_with_hostile_text_in_the_cards_and_the_reply(served, browser, monkeypatch, width, drawer):
    mockup(served, 3, "T" * 300)
    write(served, *thread(hostile_reply()))
    open_real(browser, served, monkeypatch, (width, 800 if width > 700 else 844))
    assert wait_for(browser, "document.querySelectorAll('#chat .link-card').length === 4", 15.0)
    if width < 700:
        browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": 844, "deviceScaleFactor": 1, "mobile": True})
        assert wait_for(browser, f"document.documentElement.clientWidth === {width}", 10.0)
        if drawer:
            drawer_open(browser)
    browser.settle("document.querySelector('#chat')")
    m = browser.evaluate(MEASURE)
    assert m["vw"] == width and m["msgs"] >= 2, m
    check(m, f"{width} px, drawer {'open' if drawer else 'shut'}")
    boxes = browser.evaluate(CARD_BOXES)
    assert boxes["n"] == 4 and boxes["bad"] == [], f"a card is never wider than the window or than its own box: {boxes}"
