"""The explainer text behind a (?): a text that only says how a thing works or where it comes from is a box that opens from a button, and a status, an error, an
empty line, a label or a thing to act on stays inline. These checks read the markup and the scripts as text; the press, the hover, the keyboard and the tap are
driven in headless Chromium in test_explainer_tooltips_ui.py."""
import re
from pathlib import Path

STATIC = Path(__file__).resolve().parents[1] / "src" / "sala_web" / "static"
HTML = (STATIC / "index.html").read_text(encoding="utf-8")
APP_JS = (STATIC / "app.js").read_text(encoding="utf-8")
I18N_JS = (STATIC / "i18n.js").read_text(encoding="utf-8")
STYLE = (STATIC / "style.css").read_text(encoding="utf-8")

# the texts of index.html moved behind a (?)
MOVED = ["ui.ns.sessionHint", "ui.ns.backHint", "ui.ns.nameHint", "ui.ns.dragHint", "ui.ns.defaultHint", "ui.sd.itemHint", "ui.sd.projectHint",
         "ui.sd.agentsHint", "ui.sd.forkHint", "ui.sd.nameHint", "ui.sd.topicHint", "ui.se.thinkNote", "us.machines"]
# left inline: what the form still needs from the person, and what the quick form asks them to do
INLINE = ["ui.ns.mandateHintNone", "ui.sd.lead"]
# the texts a script draws, each through the one helper in i18n.js
MOVED_JS = {"usage.js": ["us.howTo", "us.machines", "us.prices", "us.asOf"], "usage-explorer.js": ["usx.howTo", "us.machines", "us.prices", "us.asOf"],
            "sessions.js": ["ov.unrated.note", "ov.s.counted"], "schedules.js": ["sch.count.hint"]}


def pop_of(key: str) -> str:
    m = re.search(r'<span class="exp-pop"[^>]*data-i18n="' + re.escape(key) + r'"[^>]*>', HTML)
    assert m, key
    return m.group(0)


def test_each_moved_text_is_a_hidden_note_behind_a_button_that_names_it():
    for key in MOVED:
        pop = pop_of(key)
        assert "hidden" in pop and 'role="note"' in pop, pop
        pid = re.search(r'id="([^"]+)"', pop).group(1)
        btn = re.search(r'<button type="button" class="exp-help"[^>]*aria-controls="' + re.escape(pid) + r'"[^>]*>', HTML)
        assert btn, (key, pid)
        assert 'aria-expanded="false"' in btn.group(0), btn.group(0)
        assert 'data-i18n-aria-label="ui.explain"' in btn.group(0), btn.group(0)


def test_each_moved_text_appears_once_and_only_in_its_box():
    for key in MOVED:
        assert HTML.count('data-i18n="' + key + '"') == 1, key


def test_the_texts_left_inline_are_still_plain_text_outside_a_box():
    for key in INLINE:
        assert 'data-i18n="' + key + '"' in HTML, key
        assert not re.search(r'<span class="exp-pop"[^>]*data-i18n="' + re.escape(key) + '"', HTML), key


def test_no_marker_sits_inside_a_label_so_a_fields_name_is_only_its_label():
    labels = re.findall(r"<label\b.*?</label>", HTML, re.S)
    assert len(labels) > 10 and not [x for x in labels if "exp-help" in x]


def test_one_controller_opens_one_box_on_hover_focus_and_press_and_shuts_it():
    for want in ('function explainSet(btn, on, how = "pin")', 'document.addEventListener("pointerover"', 'document.addEventListener("pointerout"',
                 'document.addEventListener("focusin"', 'document.addEventListener("focusout"', 'e.pointerType === "touch"', 'matches(":focus-visible")'):
        assert want in APP_JS, want
    # Escape is taken before the page's own Escape, so it shuts the box and nothing under it
    assert "if (seen) { e.preventDefault(); e.stopPropagation(); }   // this press shuts the box and nothing under it\n}, true);" in APP_JS
    # a press on a (?) or its box inside a fold's summary must not unfold it
    assert 'if (at && at.closest(".exp")) e.preventDefault();' in APP_JS


def test_the_drawn_texts_come_from_the_one_helper_in_i18n_js():
    assert "function expHtml(...parts)" in I18N_JS and "function expEl(...parts)" in I18N_JS
    assert 'class="exp-pop" id="${id}" role="note" hidden' in I18N_JS
    for name, keys in MOVED_JS.items():
        src = (STATIC / name).read_text(encoding="utf-8")
        calls = " ".join(line for line in src.splitlines() if "expHtml(" in line or "expEl(" in line)
        for key in keys:
            assert '"' + key + '"' in calls, (name, key)


def test_the_box_is_hidden_until_opened_and_the_marker_shows_its_focus_and_a_fingers_size():
    assert ".exp-pop[hidden] { display: none; }" in STYLE and ".exp[hidden] { display: none; }" in STYLE
    assert ".exp-help:focus-visible" in STYLE
    assert "@media (pointer: coarse) { .exp-help { width: 44px; height: 44px; } }" in STYLE
    assert ".exp:hover" not in STYLE, "app.js opens the box on hover, so Escape and aria-expanded hold for it too"
