import asyncio
from pathlib import Path

import pytest

from sala_web import tmuxio
from sala_web.config import Settings

FIX = Path(__file__).parent / "fixtures"
RULE = "\x1b[38;5;244m" + "─" * 60 + "\x1b[39m"


def test_probe_empty_box_with_dim_placeholder():
    state, shown = tmuxio.input_box((FIX / "capture-empty.txt").read_text())
    assert state == "empty"
    assert "Try" in shown  # the placeholder is visible but dim


def test_probe_box_with_image_chips_and_text():
    cap = (FIX / "capture-content.txt").read_text()
    assert tmuxio.input_box(cap) == ("text", "[Image #4] [Image #5] typed")
    assert tmuxio.count_chips(cap) == 2


def test_fleet_busy_pane_empty_box_below_spinner_and_above_agent_list():
    assert tmuxio.input_box((FIX / "capture-fleet-busy.txt").read_text())[0] == "empty"


def test_no_box_when_a_dialog_is_open():
    cap = "\n".join([RULE, " Do you want to proceed?", " ❯ 1. Yes", "   2. No", ""])
    assert tmuxio.input_box(cap)[0] == "missing"


def test_multiline_input_counts_as_text():
    cap = "\n".join(["old output", RULE, "\x1b[39m❯ first", "  second", RULE, "  footer"])
    assert tmuxio.input_box(cap) == ("text", "first\n  second")


def test_last_box_wins_over_earlier_prompt_lines():
    cap = "\n".join([RULE, "❯ earlier prompt", RULE, "answer", RULE, "❯ ", RULE])
    assert tmuxio.input_box(cap)[0] == "empty"


def test_rule_with_label_is_still_a_rule():
    assert tmuxio._is_rule("─" * 40 + " sala-web " + "─" * 4)


def test_extended_colour_params_do_not_toggle_dim():
    # 38;5;2 is a colour, not "dim" (2)
    runs = tmuxio._visible_runs("\x1b[38;5;2mx\x1b[2my\x1b[22mz")
    assert runs == [("x", False), ("y", True), ("z", False)]


def test_dialog_options_from_a_permission_prompt():
    # the numbered list in Claude's reply above the rule is not the dialog
    options, text = tmuxio.dialog((FIX / "capture-dialog.txt").read_text())
    assert options == ["1", "2", "3", "4"]
    assert text.startswith("Read outside the working directories") and "First, the service file" not in text


def test_dialog_options_from_a_menu_with_the_focus_below_option_1():
    # captured from Claude Code 2.1.296's /model menu: "❯ 2." focused, wrapped description lines between options
    assert tmuxio.dialog((FIX / "capture-menu.txt").read_text())[0] == ["1", "2", "3", "4", "5"]


def test_no_dialog_where_an_input_box_or_a_plain_list_shows():
    for name in ("capture-empty.txt", "capture-content.txt", "capture-fleet-busy.txt"):
        assert tmuxio.dialog((FIX / name).read_text()) == ([], "")
    # a numbered list without a focused "❯ N." line is Claude's output, not a dialog
    assert tmuxio.dialog("\n".join([RULE, " 1. Yes", " 2. No", ""])) == ([], "")
    # a focused line whose numbering does not count up from 1 is not one either
    assert tmuxio.dialog("\n".join([RULE, " ❯ 2. Yes", "   3. No"])) == ([], "")


def test_dialog_inside_a_box_and_its_text_tells_two_dialogs_apart():
    a = "\n".join(["╭" + "─" * 40 + "╮", "│ Read /etc/a?          │", "│ ❯ 1. Yes               │",
                   "│   2. No                │", "╰" + "─" * 40 + "╯"])
    b = a.replace("/etc/a", "/etc/b")
    assert tmuxio.dialog(a)[0] == ["1", "2"]
    assert tmuxio.dialog(a)[1] != tmuxio.dialog(b)[1]
    # the focus moving does not make it another dialog
    assert tmuxio.dialog(a)[1] == tmuxio.dialog(a.replace("❯ 1.", "  1.").replace("  2. No", "❯ 2. No"))[1]


def test_send_key_sends_only_a_digit_escape_or_the_stop_keys_second_key():
    # (Ctrl-C, "C-c", is the one key beyond a digit and Escape: the Stop button's second key; see test_bang_live.py)
    s = Settings(socket=FIX / "unused.sock", state_dir=FIX, claude_dir=FIX, tmux_socket_name="salaweb-pytest-unused")
    for key in ("Enter", "0", "10", "C-d", "C-C", "y"):
        with pytest.raises(tmuxio.TmuxError, match="refusing"):
            asyncio.run(tmuxio.send_key(s, "%1", key))


# --- the narrow pane: the session name in the rule above the box (50 columns) -------------------------------------

NARROW = (FIX / "capture-narrow-name-rule.txt").read_text()


def test_narrow_pane_rule_with_a_23_char_session_name_is_a_rule():
    top = next(ln for ln in NARROW.split("\n") if "demo-builder-side-oak02" in ln)
    s = tmuxio.plain(top)
    assert len(s) == 50 and s.count("─") / len(s) < 0.6  # under the plain rule's 60%: the old test missed it
    assert tmuxio._is_rule(top)


def test_narrow_pane_idle_box_is_found_empty():
    assert tmuxio.input_box(NARROW)[0] == "empty"
    assert tmuxio.input_box(NARROW.replace('\x1b[2mTry "fix lint errors"\x1b[0m', "draft"))[0] == "text"


def test_narrow_pane_dialog_top_rule_with_a_name_bounds_the_dialog():
    cap = "\n".join(["1. an earlier list item", "2. another", NARROW.split("\n")[4], " Do you want to proceed?",
                     " ❯ 1. Yes", "   2. No", ""])
    options, text = tmuxio.dialog(cap)
    assert options == ["1", "2"] and "earlier list" not in text


@pytest.mark.parametrize("line", [
    "── a sentence of ordinary prose that runs on and on ──",      # the label is too long to be a name
    "─" * 15 + " " + "word " * 8 + "w " + "─" * 15,                 # long label, and rules over 40% of the line
    "Summary of results ──────────────",                             # no rule characters at the start
    "────────────────── trailing words and more",                    # none at the end
    "─ ─ ─ ─ ─ ─ ─ ─ ─ ─",                                           # runs under 3 characters
    "┌─ Name ─┬─ Value ─┬─ Notes ─┐",                                # a table border starts with a corner
    "├─ Name ─┼─ Value ─┼─ Notes ─┤",
    "plain text with a ── in the middle ── of it, no rule at all",
    "── note ─",                                                      # too short, and a run of only 2 at the start
    "─── see the notes below, they matter a lot to us ─",            # prose with a few dashes: under 40% rule characters
    "─── a heading that ends in a dash and has words ─",
    "──── a label that is far too long to be a session name ─",      # label over 40 characters
])
def test_ordinary_text_and_table_borders_are_not_rules(line):
    assert not tmuxio._is_rule(line)


def test_text_line_between_prose_does_not_make_a_box():
    cap = "\n".join(["── a sentence of ordinary prose that runs on and on ──", "❯ not a box", "output"])
    assert tmuxio.input_box(cap) == ("missing", "")


# --- shell mode: "!" where "❯" stood ------------------------------------------------------------------------------

SHELL = (FIX / "capture-shell-mode.txt").read_text()
SHELL_EMPTY = (FIX / "capture-shell-mode-empty.txt").read_text()


def test_shell_mode_box_is_found_with_its_text():
    assert tmuxio.input_box(SHELL) == ("text", "ls -la /tmp")
    assert tmuxio.shell_mode(SHELL)


def test_shell_mode_box_with_nothing_typed_is_empty():
    assert tmuxio.input_box(SHELL_EMPTY) == ("empty", "")
    assert tmuxio.shell_mode(SHELL_EMPTY)


def test_prompt_box_is_not_shell_mode():
    assert not tmuxio.shell_mode(NARROW)
    assert not tmuxio.shell_mode((FIX / "capture-empty.txt").read_text())
    assert not tmuxio.shell_mode("no box here")


def test_chips_are_counted_in_a_shell_mode_box_too():
    cap = SHELL.replace("ls -la /tmp", "[Image #1] [Image #2]")
    assert tmuxio.count_chips(cap) == 2
    assert tmuxio.count_chips(NARROW) == 0


def test_footer_hint_under_a_prompt_box_is_not_a_shell_mode_box():
    # "! for bash mode" sits under every empty box and starts with "!", but it has no bottom rule below it
    cap = NARROW.replace("(shift+tab to cycle)", "(shift+tab to cycle)\n  ! for bash mode")
    assert tmuxio.input_box(cap)[0] == "empty" and not tmuxio.shell_mode(cap)
    chips = cap.replace('\x1b[2mTry "fix lint errors"\x1b[0m', "[Image #3] hi")
    assert tmuxio.count_chips(chips) == 1


# --- the real 50-column capture of app-main: one trailing rule character after the label ----------------------------

REAL50 = (FIX / "capture-narrow-app-main-50col.txt").read_text()


def test_real_50col_rule_with_one_trailing_rule_character_is_a_rule():
    top = next(ln for ln in REAL50.split("\n") if "app-main" in ln and "─" in ln)
    assert tmuxio.plain(top) == "─" * 39 + " app-main ─"
    assert tmuxio._is_rule(top)


def test_real_50col_capture_box_is_found_empty():
    assert tmuxio.input_box(REAL50) == ("empty", "")
    assert not tmuxio.shell_mode(REAL50)
    assert tmuxio.count_chips(REAL50) == 0


def test_real_50col_capture_with_text_typed_is_text():
    typed = REAL50.replace("\x1b[39m❯\xa0\n", "\x1b[39m❯\xa0hello\n")
    assert typed != REAL50
    assert tmuxio.input_box(typed) == ("text", "hello")
    assert tmuxio.count_chips(typed.replace("hello", "[Image #1]")) == 1


@pytest.mark.parametrize("line", [
    "─" * 25 + " name ─",                  # the real shape, a short label: still a rule
    "─" * 12 + " a label ─",
    "─" * 34 + " app-main ──",
])
def test_one_trailing_rule_character_is_enough(line):
    assert tmuxio._is_rule(line)
