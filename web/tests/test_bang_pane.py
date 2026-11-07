"""A running `!` command read from the pane: what Claude Code 2.1.312 really does.

An earlier version gated the chat's live block and Stop on two things a real-pane check on 2.1.312 showed false: the transcript gets no
`<bash-input>` record while the command runs (0 `bash-` lines during and after), and the pane keeps its input box (it
showed the command's output, `+14 lines (18s)`, `(ctrl+b ctrl+b (twice) to run in background)`, a rule, `❯ `, a rule and a
footer with `esc to interrupt`). So `tmuxio.bang_pane` decides from the capture alone.

Checked here, on captured pane text (tests/fixtures/pane-*.txt, the shape of that capture): a running command is found, with
the command taken from the `! ` echo and the text from the output lines (no rules, input box, footer, hint, fold counter;
the same text for two captures a second apart, so the counter does not make every tick a change); a finished command, one
stopped with Escape (the command back in a shell-mode box), a model turn showing `esc to interrupt`, a model's own Bash call
with the same `ctrl+b ctrl+b` hint under an older `! ` echo, and a finished command followed by a thinking spinner are none
of them taken for a running one; SGR colour codes in the capture change nothing; a wrapped-away echo is not guessed.
These are plain functions on strings: no tmux, no temp files.
"""

from __future__ import annotations

from pathlib import Path

from sala_web import tmuxio as T

FIX = Path(__file__).parent / "fixtures"


def pane(name: str) -> str:
    return (FIX / f"pane-{name}.txt").read_text()


def test_a_running_bang_command_is_found_with_its_command_and_output():
    got = T.bang_pane(pane("bang-running"))
    assert got == {
        "command": "sudo apt update",
        "text": "Hit:1 http://archive.ubuntu.com/ubuntu resolute InRelease\n"
                "Get:2 http://archive.ubuntu.com/ubuntu resolute-updates InRelease [126 kB]\n"
                "Reading package lists...\n"
                "Building dependency tree...",
    }, got


def test_the_text_has_no_input_box_rules_footer_hint_or_fold_counter():
    got = T.bang_pane(pane("bang-running"))["text"]
    for chrome in ("─", "❯", "esc to interrupt", "ctrl+b", "run in background", "+14 lines", "(18s)", "⎿", "⏵⏵"):
        assert chrome not in got, chrome


def test_the_fold_counter_ticking_does_not_change_the_text():
    a = pane("bang-running")
    b = a.replace("+14 lines (18s)", "+14 lines (1m 19s)")
    assert b != a and T.bang_pane(a) == T.bang_pane(b)


def _quiet(timer: str) -> str:
    """The running pane with the output and the fold counter replaced by a single timer line (no hint either)."""
    keep = [ln for ln in pane("bang-running").split("\n")
            if not ln.startswith("     ") and "Hit:1" not in ln and "run in background" not in ln]
    at = next(i for i, ln in enumerate(keep) if ln.startswith("! "))
    return "\n".join(keep[:at + 1] + [f"  ⎿  {timer}"] + keep[at + 1:])


def test_a_bare_timer_after_short_output_marks_it_and_is_not_text():
    fixture = "\n".join(ln for ln in pane("bang-running").split("\n")
                        if "run in background" not in ln and "Get:2" not in ln and "Reading" not in ln and "Building" not in ln)
    fixture = fixture.replace("     +14 lines (18s)", "     (4s)")
    assert "(4s)" in fixture and "ctrl+b" not in fixture
    got = T.bang_pane(fixture)
    assert got == {"command": "sudo apt update", "text": "Hit:1 http://archive.ubuntu.com/ubuntu resolute InRelease"}, got
    assert T.bang_pane(fixture.replace("(4s)", "(5s)")) == got
    assert T.bang_pane(fixture.replace("(4s)", "(1h 2m 5s)")) == got


def test_a_quiet_command_with_only_running_and_a_timer_still_counts_as_running():
    quiet = _quiet("Running… (3s)")
    assert "ctrl+b" not in quiet and "Running… (3s)" in quiet
    assert T.bang_pane(quiet) == {"command": "sudo apt update", "text": ""}
    # the timer ticks, the text does not
    for t in ("Running… (4s)", "Running… (1m 5s)", "Running… (1h 2m 5s)"):
        assert T.bang_pane(_quiet(t)) == {"command": "sudo apt update", "text": ""}, t


def test_a_bare_timer_alone_marks_a_quiet_command():
    assert T.bang_pane(_quiet("(7s)")) == {"command": "sudo apt update", "text": ""}


def test_a_timer_with_h_and_m_parts_is_cut_from_the_text():
    a = pane("bang-running")
    for t in ("+14 lines (2m 5s)", "+14 lines (1h 2m 5s)", "+14 lines (1h 5s)"):
        assert T.bang_pane(a.replace("+14 lines (18s)", t)) == T.bang_pane(a), t


def test_a_line_that_only_ends_like_a_timer_is_output_not_a_timer():
    a = pane("bang-running").replace("Building dependency tree...", "done in (3s)")
    assert T.bang_pane(a)["text"].endswith("done in (3s)")


def test_an_indented_bang_line_under_a_model_turn_is_not_an_echo():
    # the real echo is at column 0; an indented `! text` inside a reply is the model quoting something
    quoted = "\n".join([
        "● Here is the line to run:",
        "  ! sudo apt update",
        "  ⎿  Hit:1 http://archive.ubuntu.com/ubuntu resolute InRelease",
        "     +14 lines (18s)",
        "     (ctrl+b ctrl+b (twice) to run in background)",
    ] + pane("bang-running").split("\n")[-5:])
    assert "! sudo apt update" in quoted and "esc to interrupt" in quoted
    assert T.bang_pane(quoted) is None
    # and with no turn glyph at all, an indented line is still no echo
    assert T.bang_pane(quoted.replace("● Here is the line to run:", "Here is the line to run:")) is None


def test_colour_codes_in_the_capture_change_nothing():
    plain_text = pane("bang-running")
    coloured = "\n".join(
        f"\x1b[38;5;244m{ln}\x1b[39m" if ln.startswith("─") else ln for ln in plain_text.split("\n")
    ).replace("❯ ", "\x1b[39m❯ \x1b[7m \x1b[27m").replace("  esc to interrupt", "\x1b[2m  esc to interrupt\x1b[22m")
    assert "\x1b[" in coloured
    assert T.bang_pane(coloured) == T.bang_pane(plain_text) and T.bang_pane(coloured) is not None


def test_the_fold_counter_alone_marks_it_without_the_background_hint():
    no_hint = "\n".join(ln for ln in pane("bang-running").split("\n") if "run in background" not in ln)
    assert T.bang_pane(no_hint)["command"] == "sudo apt update"


def test_the_background_hint_alone_marks_it_without_the_fold_counter():
    no_fold = "\n".join(ln for ln in pane("bang-running").split("\n") if "+14 lines" not in ln)
    assert T.bang_pane(no_fold)["command"] == "sudo apt update"


def test_a_finished_command_is_not_running():
    assert T.bang_pane(pane("bang-finished")) is None


def test_a_command_stopped_with_escape_is_not_running():
    # no "Interrupted" echo is left behind: only the command text back in the shell-mode box, hint "! for shell mode"
    assert T.bang_pane(pane("bang-stopped")) is None


def test_a_normal_assistant_turn_showing_esc_to_interrupt_is_not_a_bang_command():
    assert "esc to interrupt" in pane("assistant-turn")
    assert T.bang_pane(pane("assistant-turn")) is None


def test_a_model_bash_call_with_the_same_background_hint_is_not_a_bang_command():
    # the hint, the fold counter and the footer are all there, and an older `! ls` echo is higher up; the reply and the
    # prompt of the owner's between them and the hint say whose command it is
    fixture = pane("assistant-bash-tool")
    assert "ctrl+b ctrl+b (twice) to run in background" in fixture and "+14 lines (18s)" in fixture and "! ls" in fixture
    assert T.bang_pane(fixture) is None


def test_a_thinking_spinner_after_a_finished_command_is_not_a_running_one():
    assert T.bang_pane(pane("bang-then-thinking")) is None


def test_no_echo_on_the_screen_is_not_guessed():
    # a long output scrolled the echo off: with no `! ` line there is nothing to say whose the hint is
    scrolled = "\n".join(ln for ln in pane("bang-running").split("\n") if not ln.startswith("! "))
    assert T.bang_pane(scrolled) is None


def test_a_pane_with_no_input_box_is_read_the_same():
    no_box = "\n".join(pane("bang-running").split("\n")[:9]) + "\n  esc to interrupt\n"
    got = T.bang_pane(no_box)
    assert got and got["command"] == "sudo apt update" and got["text"].endswith("Building dependency tree..."), got


def test_text_is_the_last_forty_lines_each_cut():
    many = "\n".join(f"     line {i}" for i in range(100))
    fixture = pane("bang-running").replace("     Building dependency tree...\n", many + "\n")
    lines = T.bang_pane(fixture)["text"].split("\n")
    assert len(lines) == T.LIVE_LINES and lines[-1] == "line 99"
    long = pane("bang-running").replace("Building dependency tree...", "y" * 5000)
    assert max(len(ln) for ln in T.bang_pane(long)["text"].split("\n")) == T.LIVE_LINE_CHARS


def test_plain_and_empty_captures_are_none():
    assert T.bang_pane("") is None
    assert T.bang_pane("hello\nworld\n") is None
