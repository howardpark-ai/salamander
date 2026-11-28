"""The chat strip's words for the owner's group are the ones stackshot serves, with sala's own copy only as the fallback.

The rule: the group's name in the chat session's pinned strip (the first tab's words, the chevron's expand and collapse titles, the panel's label, the second list's help line) and on the sessions-drawer entry
(its tooltip and its chip) is a parameter, `{group}`, filled from `group: {en, ko}` of GET /api/chat (the answer of stackshot's `GET /client/your-move`, yourmove.py). A rename in stackshot reaches
every one of those words with no change here. sala's own copy ("chat.group") is used only when no group is served, a served one is malformed (not both words, a word
under 1 or over 40 characters once stripped, a control character, markup), or the page is Korean and the served `ko` equals the served `en` (stackshot has no Korean
catalog: an English word under a Korean page is worse). It is drawn as text, never as markup.

Held here without a browser:
  - the real functions of app.js (chatGroupName, paintChatEntry, paintChatWait with paintChatBar, on an answer with no promised line) run in node against a stand-in for the few nodes they touch: a served group overrides the
    fallback in English and Korean, a renamed group shows in every word of the strip, every kind of bad group and a throw-away value falls back without an exception, a
    served ko equal to en falls back to sala's Korean for a Korean page and not for an English one, a change of language or of the served group repaints;
  - the entry's tooltip is set by its painter alone: the markup gives it no title and names no `{group}` key for any element, so `{group}` is never drawn unfilled
    (before the first answer, after a language switch, with no chat session configured);
  - the text: no string carries the group's literal words except the fallback table (so a stray hard-coded copy cannot come back), `{group}` is used by
    the strip's and the entry's keys alone (no other view's string takes it or changed its words), and the served name is never written with innerHTML.
The page in a browser (a renamed group at 390 and 1280 px, no sideways scroll, a Korean page) is test_chat_wait_pin_ui.py. All names are invented; Korean is escaped."""

from __future__ import annotations

import json
import re

import pytest

from i18n_node import STATIC, prelude
from test_chat_session_view import EN_T, KO_T, body_of, cp
from test_i18n import markup_items, needs_node, run_node

APP_JS = (STATIC / "app.js").read_text(encoding="utf-8")
INDEX = (STATIC / "index.html").read_text(encoding="utf-8")

OWN_EN = "Your move"
OWN_KO = cp(0xB0B4, 0x20, 0xCC28, 0xB840)
SERVED_EN = "Decide"
SERVED_KO = cp(0xACB0, 0xC815)                # a made-up Korean label for the renamed group
GROUP = {"en": SERVED_EN, "ko": SERVED_KO}

# the keys that carry the group's name as a parameter: the strip's line and titles, the second list's help line (it says where a done line goes), and the
# entry's tooltip and chip title
GROUP_KEYS = {"chat.strip.line", "chat.strip.expand", "chat.strip.collapse", "chat.onit.note", "ui.side.chatTip", "ui.side.chatWait.one", "ui.side.chatWait.other"}
KEY_HEADS = ("chat.strip.", "chat.onit.note", "ui.side.chatTip", "ui.side.chatWait")


def piece(pattern: str) -> str:
    m = re.search(pattern, APP_JS, re.S)
    assert m, pattern
    return m.group(0)


MODEL = r"""
const el = (tag, attrs) => ({ tag, ...attrs });
const mkEl = () => ({ hidden: false, textContent: "", title: "", attrs: {}, setAttribute(k, v) { this.attrs[k] = String(v); }, getAttribute(k) { return this.attrs[k] ?? null; }, removeAttribute(k) { delete this.attrs[k]; }, replaceChildren(...kids) { this.kids = kids; },
  classList: { toggle() {}, remove() {} } });
const parts = { ".label": mkEl(), ".dot": mkEl(), ".wchip": mkEl(), ".ucount": mkEl() };
const side = mkEl(); side.querySelector = (s) => parts[s];
const pin = mkEl();
const nodes = { "#side-chat": side, "#chat-strip-wait": pin };
const $ = (s) => nodes[s];
const state = { selected: "", byName: new Map() };
const UNREAD_SHOWN_MAX = 9, unreadOf = () => 0, unreadLabel = (n) => tl("app.unread.count", { n });   // the unread chip: not under test here (test_chat_session_view_ui.py)
let entryOn = true;
const chatEntryOn = () => entryOn;
const chatView = { data: null, waitOpen: false, waitTab: "move", waitRove: "move", ui: Object.fromEntries(
  ["wait", "onit", "onitSum", "onitList", "onitNone", "moveTab", "moveLine", "onitTab", "onitLine", "lateDot", "chevron", "help", "pop"].map((k) => [k, mkEl()])) };
const chatHelp = () => {};   // opening and shutting the (?) box: not under test here (its lines are: chatHelpParts, chatHelpText)
%(group_word)s
%(group_name)s
%(entry)s
%(wait)s
%(help_text)s
%(count)s
%(late)s
%(bar)s
// what app.js wires on a language change: the entry and the strip are painted again from what they already hold
SalaI18n.onChange(() => { paintChatEntry(); paintChatWait(); });
const read = () => ({ line: chatView.ui.moveLine.textContent, aria: chatView.ui.wait.attrs["aria-label"], title: chatView.ui.chevron.title,
                      tip: side.title, chip: parts[".wchip"].title, chipAria: parts[".wchip"].attrs["aria-label"], note: (chatView.ui.pop.kids || []).map((k) => k.text).join(" | "),
                      noteVars: (chatView.ui.pop.kids || []).map((k) => k["data-i18n-vars"] || "").join(""), lang: SalaI18n.lang });
function paint(c) {
  SalaI18n.setLang(c.lang);
  chatView.data = { session: "demo-one", name: "Demo", waiting: Array.from({ length: c.n }, (_, i) => ({ id: "demo#" + (i + 1) })), group: c.group,
                    mine: Array.from({ length: c.mine || 0 }, () => ({})), motion: Array.from({ length: c.motion || 0 }, () => ({})) };
  chatView.waitOpen = !!c.open;
  chatView.waitTab = c.tab || "move";
  paintChatEntry(); paintChatWait();
  return read();
}
const cases = %(cases)s;
console.log(JSON.stringify(cases.map((c) => (c.steps ? c.steps.map(paint) : paint(c)))));
"""


def run_cases(cases: list[dict], page_lang: str = "en") -> list:
    prog = prelude(page_lang) + MODEL % {
        "group_word": piece(r"function chatGroupWord\(v\) \{.*?\n\}\n"),
        "group_name": piece(r"function chatGroupName\(group\) \{.*?\n\}\n"),
        "entry": piece(r"function paintChatEntry\(\) \{.*?\n\}\n"),
        "wait": piece(r"function paintChatWait\(\) \{.*?\n\}\n"),
        "help_text": piece(r"function chatHelpParts\(group\) \{.*?function chatHelpText\(parts\) \{.*?\n\}\n"),
        "count": piece(r"const chatMoveCount = .*?;\n"),
        "late": piece(r"// A row of the second list is late.*?function chatBackTone\(m, now\) \{.*?\n\}\n"),
        "bar": piece(r"function paintChatBar\(onIt, n, group, open\) \{.*?\n\}\n"),
        "cases": json.dumps(cases),
    }
    return run_node(prog)


def one(group, lang="en", n=3, open_=False) -> dict:
    return run_cases([{"group": group, "lang": lang, "n": n, "open": open_}])[0]


# ── a served group overrides the fallback, everywhere the name appears ───────────────────────────
@needs_node
@pytest.mark.parametrize("lang,name", [("en", SERVED_EN), ("ko", SERVED_KO)])
def test_a_served_group_is_the_name_in_every_word_of_the_strip_in_both_languages(lang, name):
    closed, opened = one(GROUP, lang), one(GROUP, lang, open_=True)
    assert closed["line"] == f"{name} · 3" and closed["aria"] == closed["line"], closed
    assert name in closed["title"] and name in opened["title"] and closed["title"] != opened["title"], (closed, opened)
    assert name in closed["chip"] and closed["chipAria"] == closed["chip"], closed
    assert closed["tip"] == (KO_T if lang == "ko" else EN_T)["ui.side.chatTip"].replace("{group}", name), closed
    for out in (closed, opened):
        assert OWN_EN not in " ".join(out.values()) and OWN_KO not in " ".join(out.values()), out        # none of sala's own words is left


@needs_node
@pytest.mark.parametrize("group,lang,name", [(GROUP, "en", SERVED_EN), (GROUP, "ko", SERVED_KO), (None, "en", OWN_EN), (None, "ko", OWN_KO)])
def test_the_second_list_s_help_line_names_the_first_list_where_a_done_line_goes(group, lang, name):
    got = run_cases([{"group": group, "lang": lang, "n": 3, "open": True, "tab": "onit"}])[0]
    assert got["note"] == (KO_T if lang == "ko" else EN_T)["chat.onit.note"].replace("{group}", name) and name in got["note"], got
    assert json.loads(got["noteVars"]) == {"group": name}, got      # the line holds the name, so the static applier never words it with a bare {group}


# what the one (?) says, by the open list and what the first one holds: the moves (n), the done lines waiting for a confirm (mine)
STATES = {"moves": (3, 0, "move", ["chat.wait.note"]), "moves and done lines": (3, 2, "move", ["chat.wait.note", "chat.mine.note"]),
          "done lines": (0, 2, "move", ["chat.mine.note"]), "an empty first list": (0, 0, "move", ["chat.wait.note"]),
          "the second list, done lines in the first": (3, 2, "onit", ["chat.onit.note"])}


@needs_node
@pytest.mark.parametrize("lang", ["en", "ko"])
@pytest.mark.parametrize("state", STATES)
def test_the_one_help_box_says_the_notes_of_what_the_open_list_holds(state, lang):
    n, mine, tab, keys = STATES[state]
    got = run_cases([{"group": None, "lang": lang, "n": n, "mine": mine, "motion": 1, "open": True, "tab": tab}])[0]
    table, own = (KO_T, OWN_KO) if lang == "ko" else (EN_T, OWN_EN)
    assert got["note"] == " | ".join(table[k].replace("{group}", own) for k in keys), (state, got)


@needs_node
def test_the_chip_title_keeps_its_singular_and_plural_forms_with_the_served_name():
    assert one(GROUP, "en", n=1)["chip"] == "1 item in Decide" and one(GROUP, "en", n=3)["chip"] == "3 items in Decide"
    assert one(GROUP, "ko", n=3)["chip"] == f"{SERVED_KO} 3" + cp(0xAC74)


@needs_node
def test_without_a_served_group_sala_s_own_words_stand_exactly_as_before():
    en, ko = one(None, "en"), one(None, "ko")
    assert en["line"] == "Your move · 3" and en["chip"] == "3 items in Your move", en
    assert ko["line"] == OWN_KO + " · 3" and ko["chip"] == OWN_KO + " 3" + cp(0xAC74), ko
    assert en["tip"] == "Open the chat session, with the list: Your move", en
    before = cp(0xCC44, 0xD305, 0x20, 0xC138, 0xC158, 0x20, 0xC5F4, 0xAE30, 0x2C, 0x20) + OWN_KO + cp(0x20, 0xBAA9, 0xB85D, 0x20, 0xBCF4, 0xAE30)
    assert ko["tip"] == before, ko                 # with the fallback name, the Korean line is word for word as it was


@needs_node
def test_the_entry_s_tooltip_is_painted_with_nothing_waiting_too():
    assert one(GROUP, "en", n=0)["tip"] == "Open the chat session, with the list: Decide"


@needs_node
def test_a_rename_shows_in_the_strip_the_chip_and_the_titles_and_the_next_read_changes_it_again():
    steps = [{"group": GROUP, "lang": "en", "n": 2}, {"group": {"en": "Decide demo", "ko": SERVED_KO}, "lang": "en", "n": 2},
             {"group": None, "lang": "en", "n": 2}, {"group": {"en": "Back", "ko": "b"}, "lang": "en", "n": 2, "open": True}]
    got = run_cases([{"steps": steps}])[0]
    assert [g["line"] for g in got] == ["Decide · 2", "Decide demo · 2", "Your move · 2", "Back · 2"]
    assert [g["chip"] for g in got] == ["2 items in Decide", "2 items in Decide demo", "2 items in Your move", "2 items in Back"]
    assert got[3]["title"] == "Hide the list: Back"
    assert [g["tip"] for g in got] == ["Open the chat session, with the list: " + n for n in ("Decide", "Decide demo", "Your move", "Back")]


# ── a bad group is no group ──────────────────────────────────────────────────────────────────
BAD = [None, "Your move", 7, True, [], [SERVED_EN, SERVED_KO], {}, {"en": SERVED_EN}, {"ko": SERVED_KO}, {"en": SERVED_EN, "ko": None}, {"en": 1, "ko": 2},
       {"en": "", "ko": SERVED_KO}, {"en": SERVED_EN, "ko": "   "}, {"en": "x" * 41, "ko": SERVED_KO}, {"en": SERVED_EN, "ko": "y" * 41},
       {"en": "<b>Decide</b>", "ko": SERVED_KO}, {"en": SERVED_EN, "ko": "a > b"}, {"en": "two\nlines", "ko": SERVED_KO}, {"en": SERVED_EN, "ko": "tab\there"},
       {"en": "zero" + chr(0x200B) + "width", "ko": SERVED_KO}, {"en": SERVED_EN, "ko": "bidi" + chr(0x202E) + "flip"}, {"en": ["a"], "ko": {"x": 1}}]


@needs_node
def test_a_missing_malformed_over_long_or_markup_group_falls_back_to_sala_s_own_words_and_never_throws():
    got = run_cases([{"group": g, "lang": lang, "n": 3} for g in BAD for lang in ("en", "ko")])
    for (g, lang), out in zip([(g, lang) for g in BAD for lang in ("en", "ko")], got):
        own = OWN_EN if lang == "en" else OWN_KO
        assert out["line"] == f"{own} · 3" and own in out["chip"] and own in out["tip"] and "{group}" not in out["tip"], (g, lang, out)


@needs_node
def test_forty_characters_and_surrounding_spaces_are_accepted_and_the_words_are_trimmed():
    assert one({"en": "x" * 40, "ko": "y"})["line"] == "x" * 40 + " · 3"
    assert one({"en": "  Decide  ", "ko": f" {SERVED_KO} "}, "ko")["line"] == f"{SERVED_KO} · 3"
    assert one({"en": "x" * 40, "ko": "y"}, "en")["line"] != OWN_EN + " · 3"


@needs_node
def test_a_served_name_with_markup_like_or_brace_text_is_text_only():
    # a name is data: `{n}` or `$&` in it is not filled or expanded again, and `&amp;` is not decoded (nothing here writes markup)
    out = one({"en": "{n} $& &amp;", "ko": "k"}, "en", n=3)
    assert out["line"] == "{n} $& &amp; · 3" and out["chip"] == "3 items in {n} $& &amp;"
    assert out["tip"] == "Open the chat session, with the list: {n} $& &amp;"


# ── Korean page, served ko equal to served en ────────────────────────────────────────────────
@needs_node
def test_a_korean_page_uses_sala_s_korean_when_stackshot_has_no_korean_catalog_and_an_english_page_uses_the_served_word():
    same = {"en": "Decide", "ko": "Decide"}             # no catalog configured: ko equals en
    assert one(same, "ko")["line"] == OWN_KO + " · 3" and one(same, "ko")["chip"].startswith(OWN_KO + " 3")
    assert one(same, "en")["line"] == "Decide · 3"
    assert one({"en": "Decide", "ko": " Decide "}, "ko")["line"] == OWN_KO + " · 3"        # equal once stripped


@needs_node
def test_a_change_of_language_repaints_the_strip_and_the_chip_in_the_other_languages_served_word():
    # the language hook: paint once in English, switch to Korean with no new read, the hook repaints from what is held
    prog = prelude("en") + MODEL.split("const cases =")[0] % {
        "group_word": piece(r"function chatGroupWord\(v\) \{.*?\n\}\n"),
        "group_name": piece(r"function chatGroupName\(group\) \{.*?\n\}\n"),
        "entry": piece(r"function paintChatEntry\(\) \{.*?\n\}\n"),
        "wait": piece(r"function paintChatWait\(\) \{.*?\n\}\n"),
        "help_text": piece(r"function chatHelpParts\(group\) \{.*?function chatHelpText\(parts\) \{.*?\n\}\n"),
        "count": piece(r"const chatMoveCount = .*?;\n"),
        "late": piece(r"// A row of the second list is late.*?function chatBackTone\(m, now\) \{.*?\n\}\n"),
        "bar": piece(r"function paintChatBar\(onIt, n, group, open\) \{.*?\n\}\n"),
    } + """
const out = [paint({ group: %s, lang: "en", n: 3 })];
SalaI18n.setLang("ko"); out.push(read());
SalaI18n.setLang("en"); out.push(read());
console.log(JSON.stringify(out));
""" % json.dumps(GROUP)
    got = run_node(prog)
    assert [g["line"] for g in got] == ["Decide · 3", f"{SERVED_KO} · 3", "Decide · 3"]
    assert got[1]["chip"].startswith(f"{SERVED_KO} 3") and got[1]["title"].startswith(SERVED_KO + " ")
    assert [g["tip"] for g in got] == [t["ui.side.chatTip"].replace("{group}", n) for t, n in ((EN_T, SERVED_EN), (KO_T, SERVED_KO), (EN_T, SERVED_EN))]
    assert not [v for g in got for v in g.values() if "{group}" in v], got


@needs_node
def test_before_the_first_answer_and_with_no_chat_session_the_entry_is_hidden_with_no_tooltip_and_no_placeholder():
    prog = prelude("en") + MODEL.split("const cases =")[0] % {
        "group_word": piece(r"function chatGroupWord\(v\) \{.*?\n\}\n"),
        "group_name": piece(r"function chatGroupName\(group\) \{.*?\n\}\n"),
        "entry": piece(r"function paintChatEntry\(\) \{.*?\n\}\n"),
        "wait": piece(r"function paintChatWait\(\) \{.*?\n\}\n"),
        "help_text": piece(r"function chatHelpParts\(group\) \{.*?function chatHelpText\(parts\) \{.*?\n\}\n"),
        "count": piece(r"const chatMoveCount = .*?;\n"),
        "late": piece(r"// A row of the second list is late.*?function chatBackTone\(m, now\) \{.*?\n\}\n"),
        "bar": piece(r"function paintChatBar\(onIt, n, group, open\) \{.*?\n\}\n"),
    } + """
const out = [], keep = () => out.push({ hidden: side.hidden, tip: side.title });
entryOn = false; paintChatEntry(); keep();                              // no answer yet
SalaI18n.setLang("ko"); keep();                                         // a language switch before any answer
chatView.data = { configured: false }; paintChatEntry(); keep();        // no chat session configured
SalaI18n.setLang("en"); keep();
entryOn = true; chatView.data = { session: "demo-one", name: "Demo", waiting: [], group: null }; paintChatEntry(); keep();
entryOn = false; paintChatEntry(); SalaI18n.setLang("ko"); keep();      // it goes, and the language changes while it is hidden
entryOn = true; paintChatEntry(); keep();                               // it comes back
console.log(JSON.stringify(out));
"""
    got = run_node(prog)
    assert [g["hidden"] for g in got] == [True, True, True, True, False, True, False], got
    assert [g["tip"] for g in got[:4]] == [""] * 4, got
    assert got[4]["tip"] == "Open the chat session, with the list: " + OWN_EN
    assert got[6]["tip"] == KO_T["ui.side.chatTip"].replace("{group}", OWN_KO), got
    assert not [g for g in got if "{group}" in g["tip"]], got


def test_the_markup_s_applier_can_never_draw_the_placeholder():
    # the applier fills data-i18n* with the markup's own values only, so no element of the page may name a key that takes {group}
    named = {key for _, key, _, _, _ in markup_items("index.html")}
    takes = {k for t in (EN_T, KO_T) for k, v in t.items() if "{group}" in v}
    assert not [k for k in named if {k, k + ".one", k + ".other"} & takes], named & takes
    opening = re.search(r'<a id="side-chat"[^>]*>', INDEX).group(0)
    assert " title=" not in opening and "data-i18n-title" not in opening and "{group}" not in INDEX, opening
    assert not re.search(r'tx\("(chat\.strip\.|chat\.onit\.note|ui\.side\.chat(Tip|Wait))', APP_JS), "and no element built in script marks one of them either"


# ── the text: no stray hard-coded copy, no other view's string takes the parameter ─────────────
def test_only_the_fallback_row_carries_the_group_s_literal_words():
    en = {k for k, v in EN_T.items() if re.search(r"your move", v, re.I)}
    ko = {k for k, v in KO_T.items() if OWN_KO in v}
    # chat.group is sala's own copy, the fallback
    assert en == {"chat.group"}, sorted(en)
    assert ko == {"chat.group"}, sorted(ko)
    assert EN_T["chat.group"] == OWN_EN and KO_T["chat.group"] == OWN_KO


def test_the_group_parameter_is_in_the_strip_s_and_the_entry_s_keys_and_in_no_other_string():
    assert {k for k, v in EN_T.items() if "{group}" in v} == GROUP_KEYS
    assert {k for k, v in KO_T.items() if "{group}" in v} == {k.replace(".one", ".other") for k in GROUP_KEYS}
    for t in (EN_T, KO_T):
        assert not [k for k, v in t.items() if "{group}" in v and not k.startswith(KEY_HEADS)]


def test_no_script_or_markup_of_the_page_holds_the_group_s_words_outside_the_fallback_table():
    assert not re.search(r"your move", APP_JS, re.I), "app.js words the group only through tl() and the served name"
    assert OWN_KO not in APP_JS
    for name in ("shared.js", "sessions.js", "machines.js", "schedules.js", "search.js", "usage.js"):
        assert OWN_KO not in (STATIC / name).read_text(encoding="utf-8") and not re.search(r"your move", (STATIC / name).read_text(encoding="utf-8"), re.I), name
    strip = re.search(r'<div id="chat-strip-wait"[^>]*>(.*?)</div>', INDEX, re.S)
    assert strip and strip.group(1).strip() == "", "the pinned strip's markup holds no words of its own"


def test_the_served_name_is_drawn_as_text_only_and_the_group_reaches_the_strip_through_two_painters():
    for head in ("function chatGroupWord(", "function chatGroupName(", "function paintChatEntry()", "function paintChatWait()"):
        fn = body_of(APP_JS, head)
        assert not re.search(r"innerHTML|insertAdjacentHTML|outerHTML|document\.write", fn), head
    assert len(re.findall(r"chatGroupName\(", APP_JS)) == 3          # its definition and the two painters (the entry's call, the pinned line's)
    # the one language hook repaints both when the language changes, and every read of api/chat paints them again (a changed served group)
    assert "paintChatEntry(); if (!$(\"#chat-strip\").hidden) paintChatStrip();" in APP_JS
    assert "function chatMarks(d)" in APP_JS and "else paintChatEntry();" in body_of(APP_JS, "function chatMarks(d)")


def test_the_group_parameter_is_given_only_by_these_calls_of_app_js():
    calls = [line.strip() for line in APP_JS.splitlines() if ("tl(" in line or '["chat.onit.note"' in line) and re.search(r"\{[^}]*\bgroup\b", line)]
    assert len(calls) == 5, calls      # the tooltip, the chip, the first tab's words, the second list's help line and the chevron's title (the second tab's name takes the same place there)
    assert all(any(head in c for head in KEY_HEADS) for c in calls), calls
