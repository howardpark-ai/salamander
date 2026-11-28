"""The composer's own words (its placeholder and its name for a screen reader) are the page's language every time, without a browser.

The cause of the English placeholder on a Korean page: the editor is made once, at the start of app.js, with the words of that moment, and
cm6Composer.resetDoc (the text replaced: a send, a session switch, a draft put back) builds the editor's state again from the extensions it was made
with, so it brought those first words back over whatever a language change or a window width had set since. app.js therefore paints the words in one
place (paintComposerWords), at start, on a language change and after every setText. Held here:
  - the words are keys of both tables, Korean differing from English;
  - the one call of resetDoc in app.js is setText's, and setText paints the words after it; the language-change hook uses the same function;
  - a model of the bundle's behaviour (resetDoc gives back the creation-time words), running the real functions of app.js in node: after a language change
    and a setText, after a switch back, and after a width change, the placeholder and the aria-label are the active language's, on a page made in English
    (the saved language arrived late) and on a page made in Korean.
The same in a real page, after a load, a language switch and a session switch, is test_composer_words_ui.py (headless Chromium, CI). Names are invented."""

from __future__ import annotations

import re

from i18n_node import STATIC, prelude
from test_i18n import EN, KO, needs_node, run_node

APP = (STATIC / "app.js").read_text()
KEYS = ("app.composer.label", "app.composer.phKeys", "app.composer.phTouch")


def piece(pattern: str) -> str:
    m = re.search(pattern, APP, re.S)
    assert m, pattern
    return m.group(0)


def test_the_words_are_in_both_tables_and_the_korean_is_not_the_english():
    for k in KEYS:
        assert k in EN and k in KO and KO[k] != EN[k], k


def test_setText_is_the_one_resetDoc_and_paints_the_words_after_it():
    assert len(re.findall(r"cm6Composer\.resetDoc\(", APP)) == 1
    body = piece(r"function setText\(v\) \{.*?\}\n")
    assert body.index("cm6Composer.resetDoc(composer, v)") < body.index("paintComposerWords()")


def test_one_function_paints_the_label_and_the_placeholder_and_the_language_hook_and_the_start_use_it():
    fn = piece(r"function paintComposerWords\(\) \{.*?\n\}\n")
    assert 'input.setAttribute("aria-label", tl("app.composer.label"))' in fn and "setPlaceholder()" in fn
    hook = piece(r"SalaI18n\.onChange\(\(\) => \{   // the words around the draft change.*?\n\}\);\n")
    assert "paintComposerWords();" in hook and 'setAttribute("aria-label"' not in hook
    assert re.search(r"function setPlaceholder\(\) \{[^\n]*\}\npaintComposerWords\(\);\n", APP), "painted at start, after the editor and the placeholder's helper exist"
    assert 'addEventListener("change", setPlaceholder)' in APP, "a width and a touch-mode change repaint the placeholder"


MODEL = r"""
let narrow = false, touch = false;
window.matchMedia = (q) => ({ get matches() { return q.includes("max-width") ? narrow : touch; }, addEventListener() {} });
const touchMode = window.matchMedia("(pointer: coarse) and (hover: none)");
%(placeholder_for)s
// the bundle: the editor is made with the words of its creation, and resetDoc builds its state again from those
const made = { label: tl("app.composer.label"), ph: placeholderFor() };
const composer = { ph: made.ph, text: "" };
const input = { attrs: { "aria-label": made.label }, setAttribute(k, v) { this.attrs[k] = v; } };
const cm6Composer = {
  resetDoc(view, t) { view.text = t; view.ph = made.ph; input.attrs["aria-label"] = made.label; },
  setPlaceholder(view, t) { view.ph = t; },
};
function syncListKeys() {}   // the phone's list buttons (app.js): not part of the words
%(set_placeholder)s
%(paint)s
%(set_text)s
// what app.js wires: the language hook and the media queries repaint
SalaI18n.onChange(() => paintComposerWords());
const seen = (label) => ({ label, lang: SalaI18n.lang, ph: composer.ph, aria: input.attrs["aria-label"] });
const out = [];
paintComposerWords();
out.push(seen("start"));
setText("a draft"); setText("");
out.push(seen("after a send"));
SalaI18n.setLang("ko");
out.push(seen("ko"));
setText("a draft"); setText("");
out.push(seen("ko, after a send"));
narrow = true; setPlaceholder(); setText("");
out.push(seen("ko, narrow, after a send"));
narrow = false; touch = true; setPlaceholder(); setText("x"); setText("");
out.push(seen("ko, touch, after a send"));
touch = false;
SalaI18n.setLang("en");
setText("");
out.push(seen("en again"));
console.log(JSON.stringify(out));
"""


def run_model(page_lang: str) -> list[dict]:
    prog = prelude(page_lang) + MODEL % {
        "placeholder_for": piece(r"const placeholderFor = \(\) => tl\(.*?;\n"),
        "set_placeholder": piece(r"function setPlaceholder\(\) \{[^\n]*\}\n"),
        "paint": piece(r"function paintComposerWords\(\) \{.*?\n\}\n"),
        "set_text": piece(r"function setText\(v\) \{[^\n]*\}\n"),
    }
    return run_node(prog)


@needs_node
def test_a_page_made_in_english_whose_language_arrives_later_is_never_painted_back_to_english():
    got = {o["label"]: o for o in run_model("en")}
    en_wide, en_touch, en_label = EN["app.composer.phKeys"], EN["app.composer.phTouch"], EN["app.composer.label"]
    assert got["start"]["ph"] == en_wide and got["after a send"]["ph"] == en_wide and got["after a send"]["aria"] == en_label
    for k in ("ko", "ko, after a send"):
        assert got[k]["ph"] == KO["app.composer.phKeys"] and got[k]["aria"] == KO["app.composer.label"], (k, got[k])
    assert got["ko, narrow, after a send"]["ph"] == KO["app.composer.label"] and got["ko, narrow, after a send"]["aria"] == KO["app.composer.label"]
    assert got["ko, touch, after a send"]["ph"] == KO["app.composer.phTouch"] and got["ko, touch, after a send"]["aria"] == KO["app.composer.label"]
    assert got["en again"]["ph"] == en_wide and got["en again"]["aria"] == en_label and en_touch != en_wide


@needs_node
def test_a_page_made_in_korean_is_painted_back_to_the_language_it_has_now_not_the_one_it_was_made_in():
    got = {o["label"]: o for o in run_model("ko")}
    assert got["start"]["ph"] == KO["app.composer.phKeys"] and got["after a send"]["ph"] == KO["app.composer.phKeys"]
    assert got["ko"]["lang"] == "ko" and got["ko, after a send"]["ph"] == KO["app.composer.phKeys"]
    assert got["en again"]["ph"] == EN["app.composer.phKeys"] and got["en again"]["aria"] == EN["app.composer.label"], \
        "the editor was made in Korean: a send after the switch to English must not bring Korean back"


@needs_node
def test_without_the_paint_the_model_does_bring_the_creation_words_back():
    """The model itself: setText without paintComposerWords (the code as it was) leaves the creation-time words, so the two tests above can fail."""
    prog = prelude("en") + MODEL % {
        "placeholder_for": piece(r"const placeholderFor = \(\) => tl\(.*?;\n"),
        "set_placeholder": piece(r"function setPlaceholder\(\) \{[^\n]*\}\n"),
        "paint": piece(r"function paintComposerWords\(\) \{.*?\n\}\n"),
        "set_text": "function setText(v) { cm6Composer.resetDoc(composer, v); }",
    }
    got = {o["label"]: o for o in run_node(prog)}
    assert got["ko"]["ph"] == KO["app.composer.phKeys"], "the language hook still paints"
    assert got["ko, after a send"]["ph"] == EN["app.composer.phKeys"] and got["ko, after a send"]["aria"] == EN["app.composer.label"]
