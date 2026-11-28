"""Link cards in the chat session's view, without a browser (the page in a browser is test_chat_link_cards_ui.py).

The chat session (SALA_CHAT_SESSION) is sala's own view of a session. A reply of that session that links a /mockup/<n> page of this site or a claude.ai artifact is drawn with a
card under it, by the one renderer every session uses (renderMessage), from data the server put on the message. Held here:
  - chatkeep.with_cards: a reply's `cards` are chatpage.cards's rule over the reply's text blocks: the two kinds, each address once, at most six, a mockup's
    title from the local store, an artifact's from the link text, no other link a card, a message that is not a reply and a reply with no such link have no `cards` key, and
    nothing is fetched;
  - over HTTP (the real server): the chat session's transcript (the last page, an older page, a newer page, a page around a line) and its stream (the reset and each append)
    carry `cards`, another session's transcript and stream carry none and are as they were, a reply for the owner (his mark taken off) carries them too;
  - linkCard (app.js), run in node: a card is one <a> with the address, a new tab, rel noopener and the words by i18n keys; an address that is neither shape, a kind it does not
    know and a title that is text with markup in it are drawn as the text they are or not drawn, never as markup;
  - the page's text: one renderer, no second page, the cards' strings in both languages (Korean as escapes), their rules in sala's tokens with no scrolling overflow and the
    focus ring every control has.

What a wrong answer costs: a card for a link that was not a mockup or an artifact, a title or an address set as markup, a second renderer drifting from sala's, a card on another
session's message, a page that scrolls sideways, or a fetch from a card. Names are invented; every temporary folder is removed as the test ends."""

from __future__ import annotations

import json
import re
import shutil
import socket
import subprocess
import threading
import time
import urllib.request

import pytest

from conftest import NAME, transcript_file
from sala_web import chatkeep as CK
from sala_web import chatpage as CP
from sala_web.app import STATIC
from test_chat_session_view import body_of, rules
from test_chatkeep import get_json, pid, read_events, write
from test_chatturns import OWNER, assistant, human, peer

NODE = shutil.which("node")
APP_JS = (STATIC / "app.js").read_text(encoding="utf-8")
STYLE = (STATIC / "style.css").read_text(encoding="utf-8")
EN = (STATIC / "i18n-en.js").read_text(encoding="utf-8")
KO = (STATIC / "i18n-ko.js").read_text(encoding="utf-8")
HOST = "sala.example.test"
ART = "https://claude.ai/artifact/AbC123_x-9"


@pytest.fixture(autouse=True)
def _rm_tmp(tmp_path):
    yield
    shutil.rmtree(tmp_path, ignore_errors=True)


def store(root, n: int, title: str) -> None:
    root.mkdir(parents=True, exist_ok=True)
    (root / f"{n}.html").write_text(f"<!doctype html><title>{title}</title><p>x</p>", encoding="utf-8")


def reply(*texts: str, uuid: str = "a-1", role: str = "assistant") -> dict:
    """A display message as transcript.parse_line makes it: the given strings as text blocks."""
    blocks: list[dict] = []
    for t in texts:
        blocks.append({"kind": "text", "text": t})
    return {"uuid": uuid, "role": role, "ts": "2026-10-14T03:00:00.000Z", "blocks": blocks}


# ── with_cards ───────────────────────────────────────────────────────────────
def test_a_reply_that_links_a_mockup_and_an_artifact_carries_both_cards_in_order(tmp_path):
    store(tmp_path / "m", 7, "Pricing &amp; plans")
    m = reply(f"Here are the pages: [pricing](/mockup/7), then [the plan]({ART}).")
    CK.with_cards([m], HOST, tmp_path / "m")
    assert m["cards"] == [{"kind": "mockup", "url": "/mockup/7", "n": 7, "title": "Pricing & plans"},
                          {"kind": "artifact", "url": ART, "title": "the plan"}]


def test_the_cards_are_chatpages_rule_over_the_replys_text_blocks(tmp_path):
    store(tmp_path / "m", 3, "Three")
    text = "[a](/mockup/3) and /mockup/3 again, https://elsewhere.example.test/mockup/3, https://example.com/page, [x](https://claude.ai/chat/abc)"
    m = reply(text, "and a second block with " + ART)
    m["blocks"].insert(1, {"kind": "tool_use", "name": "Bash", "summary": "", "input": "see /mockup/9"})   # a tool call's text is not a link of the reply
    CK.with_cards([m], HOST, tmp_path / "m")
    assert [c["url"] for c in m["cards"]] == ["/mockup/3", ART]
    assert m["cards"] == CP.cards(text + "\nand a second block with " + ART, HOST, tmp_path / "m")


def test_a_full_address_on_this_site_is_a_card_and_one_on_another_site_is_not(tmp_path):
    store(tmp_path / "m", 4, "Four")
    m = reply(f"https://{HOST}/mockup/4 and https://other.example.test/mockup/5")
    CK.with_cards([m], HOST, tmp_path / "m")
    assert [c["n"] for c in m["cards"]] == [4]
    m = reply(f"https://{HOST}/mockup/4")
    CK.with_cards([m], "another.example.test", tmp_path / "m")
    assert "cards" not in m, "the host a request came to decides which addresses are this site's"


@pytest.mark.parametrize("role", ["user", "kept"])
def test_only_a_reply_gets_cards(tmp_path, role):
    m = reply(f"see {ART} and /mockup/2", role=role)
    CK.with_cards([m], HOST, tmp_path)
    assert "cards" not in m


def test_a_reply_with_no_such_link_has_no_cards_key_and_nothing_else_changes(tmp_path):
    m = reply("see https://example.com/a and [b](https://claude.ai/chat/xyz)", "plain")
    before = json.dumps(m, sort_keys=True)
    CK.with_cards([m, reply("")], HOST, tmp_path)
    assert json.dumps(m, sort_keys=True) == before
    empty = {"uuid": "x", "role": "assistant", "blocks": []}
    CK.with_cards([empty], HOST, tmp_path)
    assert "cards" not in empty


def test_no_more_than_six_cards_and_nothing_is_fetched(tmp_path, monkeypatch):
    def boom(*a, **k):
        raise AssertionError("a card must never fetch anything")
    monkeypatch.setattr(urllib.request, "urlopen", boom)
    monkeypatch.setattr(socket, "create_connection", boom)
    m = reply(" ".join(f"https://claude.ai/artifact/id{i}" for i in range(12)))
    CK.with_cards([m], HOST, tmp_path)
    assert len(m["cards"]) == CP.CARDS_MAX


def test_hostile_link_text_is_cut_to_a_title_and_kept_as_text(tmp_path):
    label = "<img src=x onerror=alert(1)> " + "w" * 300
    m = reply(f"[{label}]({ART})")
    CK.with_cards([m], HOST, tmp_path)
    t = m["cards"][0]["title"]
    assert len(t) <= CP.TITLE_MAX and t.startswith("<img src=x"), "a title is a string the page sets as text, never markup"


# ── over HTTP ────────────────────────────────────────────────────────────────
def lines_with_links(url: str) -> list[dict]:
    return [human("show me the pages", 1),
            assistant(f"Here: [the pricing page](/mockup/3), {url}/mockup/3 and [the plan]({ART}). Not a card: https://example.com/page", 2),
            peer("Another Claude session sent a message:\nfrom: chat-other\n\nThe slides are drawn.", 3),
            assistant("[for Rowan] Slide 4 is at [slides](/mockup/4).", 4)]


def messages(d: dict) -> list[dict]:
    return [m for m in d["messages"] if m["role"] == "assistant"]


def test_the_chat_sessions_transcript_carries_the_cards_and_another_sessions_does_not(served, monkeypatch):
    monkeypatch.setenv("SALA_OWNER_NAME", OWNER)
    store(served["settings"].mockups_dir, 3, "Pricing page")
    write(transcript_file(served), lines_with_links(served["url"]))
    base = f"{served['url']}/api/s/{pid()}/transcript"
    monkeypatch.delenv("SALA_CHAT_SESSION", raising=False)
    assert "cards" not in json.dumps(get_json(base)), "another session's messages are as they were"
    monkeypatch.setenv("SALA_CHAT_SESSION", NAME)
    d = get_json(base)
    first, owned = messages(d)
    assert first["cards"] == [{"kind": "mockup", "url": "/mockup/3", "n": 3, "title": "Pricing page"},
                              {"kind": "artifact", "url": ART, "title": "the plan"}], "each address once, the card of a link on this site by its full address too"
    assert owned["cards"] == [{"kind": "mockup", "url": "/mockup/4", "n": 4, "title": "slides"}] and "[for" not in json.dumps(owned["blocks"]), "a reply for the owner has its cards, its mark off"
    assert all("cards" not in m for m in d["messages"] if m["role"] != "assistant")
    for q in ("after=0&n=1000", "around=0&n=6"):
        got = [m for m in get_json(f"{base}?{q}")["messages"] if m["role"] == "assistant"]
        assert [m.get("cards") for m in got] == [first["cards"], owned["cards"]], q
    older = get_json(f"{base}?before={d['before']}")
    assert older["messages"] == []


def test_the_chat_sessions_stream_carries_the_cards_in_the_reset_and_in_each_append(served, monkeypatch):
    monkeypatch.setenv("SALA_CHAT_SESSION", NAME)
    monkeypatch.setenv("SALA_OWNER_NAME", OWNER)
    store(served["settings"].mockups_dir, 3, "Pricing page")
    path = transcript_file(served)
    lines = lines_with_links(served["url"])
    write(path, lines[:2])
    events: list = []
    stop = threading.Event()
    resp = urllib.request.urlopen(f"{served['url']}/api/s/{pid()}/stream", timeout=20)
    t = threading.Thread(target=read_events, args=(resp, 99, events, stop), daemon=True)
    t.start()
    try:
        def wait(pred, secs=15.0):
            end = time.time() + secs
            while time.time() < end:
                if pred():
                    return True
                time.sleep(0.1)
            return False
        assert wait(lambda: any(e == "reset" for e, _ in events))
        reset = next(d for e, d in events if e == "reset")
        assert [c["url"] for m in messages(reset) for c in m["cards"]] == ["/mockup/3", ART]
        with path.open("a", encoding="utf-8") as f:
            f.write("".join(json.dumps(d) + "\n" for d in lines[2:]))
        assert wait(lambda: any(e == "append" for e, _ in events))
        time.sleep(1.5)
        appended = [m for e, d in events if e == "append" for m in d["messages"] if m["role"] == "assistant"]
        assert [c["url"] for m in appended for c in m["cards"]] == ["/mockup/4"]
    finally:
        stop.set()
        resp.close()
        t.join(timeout=5)


def test_another_sessions_stream_carries_no_cards(served, monkeypatch):
    monkeypatch.setenv("SALA_CHAT_SESSION", "demo-someone-else")
    write(transcript_file(served), lines_with_links(served["url"]))
    events: list = []
    stop = threading.Event()
    resp = urllib.request.urlopen(f"{served['url']}/api/s/{pid()}/stream", timeout=20)
    t = threading.Thread(target=read_events, args=(resp, 99, events, stop), daemon=True)
    t.start()
    try:
        end = time.time() + 15
        while time.time() < end and not any(e == "reset" for e, _ in events):
            time.sleep(0.1)
        reset = next(d for e, d in events if e == "reset")
        assert messages(reset) and "cards" not in json.dumps(reset)
    finally:
        stop.set()
        resp.close()
        t.join(timeout=5)


# ── linkCard, run in node ────────────────────────────────────────────────────
NEW_TAB_DEF = next(l for l in APP_JS.splitlines() if l.startswith("const NEW_TAB = ")) + "\n"


def run_cards(cards: list) -> list:
    """linkCard (the function's own text from app.js) with `el` and `tx` replaced by recorders: each card as {tag, attrs, kids} or null."""
    assert NODE, "node is not installed"
    fn = NEW_TAB_DEF + body_of(APP_JS, "function linkCard(") + "\n}\n"
    script = ("const el = (tag, attrs = {}, ...kids) => ({ tag, attrs, kids });\n"
              "const tx = (key, vars) => ({ 'data-i18n': key, ...(vars ? { 'data-i18n-vars': JSON.stringify(vars) } : {}) });\n"
              + fn + f"\nconsole.log(JSON.stringify({json.dumps(cards)}.map(linkCard)));")
    out = subprocess.run([NODE, "-e", script], capture_output=True, text=True, check=True, timeout=30)
    return json.loads(out.stdout)


@pytest.mark.skipif(not NODE, reason="node is not installed")
def test_a_card_is_one_link_with_its_words_by_key_both_in_a_new_tab():
    got = run_cards([{"kind": "mockup", "url": "/mockup/7", "n": 7, "title": "Pricing <b>page</b>"},
                     {"kind": "artifact", "url": ART, "title": "The plan"},
                     {"kind": "artifact", "url": "https://claude.ai/code/artifact/0a1b2c3d", "title": ""}])
    mock, art, bare = got
    # sala's own page and another site's both open in a new tab: the chat's page is never left
    assert mock["tag"] == "a" and mock["attrs"] == {"class": "link-card", "href": "mockup/7", "target": "_blank", "rel": "noopener noreferrer"}
    assert art["attrs"]["href"] == ART and art["attrs"]["target"] == "_blank" and art["attrs"]["rel"] == "noopener noreferrer"
    assert [k["attrs"]["class"] for k in mock["kids"]] == ["lc-t", "lc-l", "lc-o"]
    assert mock["kids"][0]["attrs"] == {"class": "lc-t", "text": "Pricing <b>page</b>"}, "the title is set as text"
    assert mock["kids"][1]["attrs"]["data-i18n"] == "chat.card.mockup" and json.loads(mock["kids"][1]["attrs"]["data-i18n-vars"]) == {"n": 7}
    assert mock["kids"][2]["attrs"]["data-i18n"] == "chat.card.opens"
    assert art["kids"][1]["attrs"]["data-i18n"] == "chat.card.artifact"
    assert [k["attrs"]["class"] for k in bare["kids"]] == ["lc-t", "lc-o"] and bare["kids"][0]["attrs"]["data-i18n"] == "chat.card.artifact", "no title: the kind is the title"


@pytest.mark.skipif(not NODE, reason="node is not installed")
@pytest.mark.parametrize("card", [
    {"kind": "artifact", "url": "javascript:alert(1)", "title": "x"},
    {"kind": "artifact", "url": "https://claude.ai.evil.example/artifact/abc", "title": "x"},
    {"kind": "artifact", "url": "https://evil.example/https://claude.ai/artifact/abc", "title": "x"},
    {"kind": "artifact", "url": "http://claude.ai/artifact/abc", "title": "x"},
    {"kind": "artifact", "url": "https://claude.ai/artifact/abc?x=1", "title": "x"},
    {"kind": "artifact", "title": "no address"},
    {"kind": "mockup", "url": "/mockup/0", "n": 0, "title": "x"},
    {"kind": "mockup", "url": "/mockup/1", "n": "1", "title": "n is a number"},
    {"kind": "mockup", "url": "/mockup/1", "n": 1.5, "title": "x"},
    {"kind": "board", "url": "https://example.com/pages/three", "title": "x"},
    {"title": "no kind"}, None, "text", 7])
def test_an_address_that_is_neither_shape_is_not_drawn_as_a_card(card):
    assert run_cards([card]) == [None]


# ── the page's text ──────────────────────────────────────────────────────────
def test_one_renderer_draws_the_card_for_a_reply_only_and_nothing_is_fetched_or_set_as_markup():
    render = body_of(APP_JS, "function renderMessage(")
    assert 'm.role === "assistant" && Array.isArray(m.cards)' in render and "m.cards.map(linkCard)" in render
    assert render.index("m.cards.map(linkCard)") < render.index("copyBar(copy, m.ts)"), "the card is under the text, before the copy row"
    assert APP_JS.count("function renderMessage(") == 1 and APP_JS.count("function linkCard(") == 1
    card = body_of(APP_JS, "function linkCard(")
    for banned in ("innerHTML", "fetch(", "apiFetch(", "XMLHttpRequest", "window.open", "eval("):
        assert banned not in card, banned
    assert "...NEW_TAB" in card
    assert "chat.js" not in (STATIC / "index.html").read_text(encoding="utf-8"), "no second page's script"


@pytest.mark.parametrize("key", ["chat.card.mockup", "chat.card.artifact", "chat.card.opens"])
def test_the_cards_words_are_in_both_languages_and_korean_is_escapes(key):
    assert f'"{key}": ' in EN and f'"{key}": ' in KO and f'"{key}"' in APP_JS
    line = next(l for l in KO.splitlines() if l.lstrip().startswith(f'"{key}":'))
    assert re.search(r"\\u[0-9a-f]{4}", line) and line.isascii(), line


def test_the_cards_rules_are_sala_s_tokens_in_one_block_with_a_focus_ring_and_no_scrolling_overflow():
    mine = [(s, b) for s, b in rules(STYLE) if "link-card" in s]
    assert len(mine) >= 6
    for sel, body in mine:
        assert sel.startswith("#chat "), sel
        assert not re.search(r"overflow(-x)?\s*:\s*(scroll|auto)", body), (sel, body)
        assert not re.search(r"#[0-9a-fA-F]{3,8}\b|rgba?\(", body), f"a color of its own, not a token: {sel}"
    card = " ".join(b for s, b in mine if s == "#chat .msg.assistant > .link-card")
    assert "var(--panel)" in card and "var(--border)" in card and "border-radius: 8px" in card and "min-width: 0" in card and "max-width: min(100%, 420px)" in card
    assert "outline: 2px solid var(--accent)" in " ".join(b for s, b in mine if s.endswith(":focus-visible"))
    assert "var(--hover)" in " ".join(b for s, b in mine if s.endswith(":hover"))
    text = " ".join(b for s, b in mine if s == "#chat .link-card > span")
    assert "overflow-wrap: anywhere" in text and "min-width: 0" in text
    assert "var(--link)" in " ".join(b for s, b in mine if s.endswith(".lc-o")) and "var(--muted)" in " ".join(b for s, b in mine if s.endswith(".lc-l"))


# ── which links open where ───────────────────────────────────────────────────
def test_the_reply_s_links_and_the_text_links_take_their_attributes_from_one_rule():
    hook = body_of(APP_JS, "DOMPurify.addHook(\"afterSanitizeAttributes\"")
    assert "setAttribute(\"target\", NEW_TAB.target)" in hook and "isOwn" not in hook and "isOwn" not in APP_JS
    nodes = APP_JS[APP_JS.index("const linkNodes ="):][:300]
    assert "...NEW_TAB" in nodes
