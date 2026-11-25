"""A send through the pane's mod when it can fill the prompt box: the box is judged by the box itself, the screen only refuses.

The pane is the stand-in of test_send_modbox.py (a private tmux server, `-L salaweb-modbox-<pid> -f /dev/null`, that draws a screen and
records the keys it receives); the mod is modsock.FakeMod with `fill_mode="ok"`, a small model of the CLI's box whose draft each
Enter in the recorded keys submits. What is checked: what the mod was asked (the probe, the fill), what the pane received (one Enter
and no paste, or nothing at all), what the box held after, and what the owner is told (the same words as the paste path's).
"""

import logging
import shutil
import time

import pytest

from modsock import FakeMod  # noqa: F401  (the rig's import path)
from sala_web import modbox as MB
from test_send_modbox import PASTE_END, msgs, received, rig, settle, wait_for  # noqa: F401  (rig is a fixture)

pytestmark = pytest.mark.skipif(shutil.which("tmux") is None, reason="needs tmux")

NOT_SUBMITTED = "pasted but not submitted"


def go(rig, screen="nobox", after="nobox", **kw):
    """A pane showing `screen` (and `after` once something is pasted) whose mod fills (fill_mode ok); the mod follows the pane's Enters."""
    r = rig(screen, after, fill_mode=kw.pop("fill_mode", "ok"), **kw)
    r["mod"].watch_enter(r["out"])
    return r


def enters(r) -> int:
    time.sleep(0.5)   # an Enter that would still be on its way has landed
    return received(r).count(b"\n")


def pasted(r) -> bool:
    return b"\x1b[200~" in received(r)


# ---- the box is read by the box: a screen with no box on it is no reason to refuse -----------------------------------------

@pytest.mark.parametrize("screen", ["nobox", "box", "quoted"])
def test_a_clean_fill_presses_enter_once_and_the_box_empties(rig, screen, caplog):
    caplog.set_level(logging.INFO, logger="sala_web")
    r = go(rig, screen)
    resp = r["client"].post(r["url"], json={"text": "hello there"})
    assert resp.status_code == 200, resp.text
    assert resp.json()["confirmedByMod"] is True and resp.json()["ok"] is True
    mod = r["mod"]
    assert mod.fills == [("", "insert"), ("hello there", "replace")]
    assert enters(r) == 1 and not pasted(r)
    assert mod.submitted == ["hello there"] and mod.text == ""
    assert "hello there" not in caplog.text
    assert mod.replies_left() == []


def test_a_multi_line_message_goes_in_whole_with_no_chip_in_the_way(rig):
    text = "line one\nline two\n\n  indented three\nline five\nline six"
    r = go(rig)
    resp = r["client"].post(r["url"], json={"text": text})
    assert resp.status_code == 200, resp.text
    assert r["mod"].submitted == [text] and enters(r) == 1 and not pasted(r)


def test_text_with_quotes_unicode_and_a_long_tail_survives_the_payload(rig):
    text = "say \"hi\" and 'bye' \\ \u0000 \uD55C\uAD6D\uC5B4 🎉\t tab\n" + "x" * 5000
    r = go(rig)
    resp = r["client"].post(r["url"], json={"text": text})
    assert resp.status_code == 200, resp.text
    assert r["mod"].submitted == [MB.normalize(text)]


def test_trailing_whitespace_is_dropped_as_the_cli_drops_it_and_is_no_difference(rig):
    r = go(rig)
    resp = r["client"].post(r["url"], json={"text": "hello   \n\n  \n"})
    assert resp.status_code == 200, resp.text
    assert r["mod"].fills[1] == ("hello   \n\n  \n", "replace")
    assert r["mod"].submitted == ["hello"] and enters(r) == 1


def test_zero_width_characters_and_crlf_are_what_the_cli_strips_not_a_mismatch(rig):
    r = go(rig)
    resp = r["client"].post(r["url"], json={"text": "a​b\r\nc\u0007d"})
    assert resp.status_code == 200, resp.text
    assert r["mod"].submitted == ["ab\ncd"]


def test_a_whitespace_only_difference_is_not_taken_for_the_message_being_changed(rig):
    r = go(rig)
    resp = r["client"].post(r["url"], json={"text": "  leading kept"})
    assert resp.status_code == 200 and r["mod"].submitted == ["  leading kept"]


# ---- refusals: the mod says a dialog holds the keys, or the screen shows something over the box -----------------------------

def test_a_dialog_the_mod_names_refuses_and_nothing_is_typed(rig):
    r = go(rig, "dialog", dialog=True, text="")
    resp = r["client"].post(r["url"], json={"text": "hello there"})
    assert resp.status_code == 409 and "a dialog is open in the pane" in resp.json()["error"]
    assert settle(r) == b""
    assert r["mod"].fills == [("", "insert")]    # the probe only: nothing was put in the box


@pytest.mark.parametrize("screen", ["box", "text", "quoted"])
def test_a_dialog_only_the_mod_knows_of_wins_over_a_screen_that_shows_a_box(rig, screen):
    """A typed dialog (/model, /config, the permission dialog) leaves the box drawn on the screen under it: the mod's refusal is the
    only sign, and a paste there would go into the dialog."""
    r = go(rig, screen, "box", dialog=True, text="")
    resp = r["client"].post(r["url"], json={"text": "hello there"})
    # refused in the dialog's words (the numbered list the older reader takes a quoted message for is offered as options, as it was before)
    assert resp.status_code == 409 and (resp.json().get("noInputBox") is True or "a dialog is open in the pane" in resp.json()["error"])
    assert settle(r) == b"" and r["mod"].fills == [("", "insert")] and r["mod"].enters == 0


def test_a_dialog_the_mod_names_still_takes_a_lone_option_number(rig):
    r = go(rig, "dialog", dialog=True, text="")
    resp = r["client"].post(r["url"], json={"text": "1"})
    assert resp.status_code == 200 and resp.json()["dialogAnswer"] == "1"
    assert wait_for(r, b"1") == b"1"
    assert r["mod"].fills == [("", "insert")]


def test_a_typed_dialog_the_screen_shows_no_options_for_is_refused_as_no_input_box(rig):
    r = go(rig, "nobox", dialog=True, text="")
    resp = r["client"].post(r["url"], json={"text": "hello there"})
    assert resp.status_code == 409 and resp.json().get("noInputBox") is True
    assert settle(r) == b"" and r["mod"].fills == [("", "insert")]


@pytest.mark.parametrize("screen", ["picker", "search", "transcript"])
def test_an_overlay_the_mod_does_not_refuse_is_refused_by_its_screen_and_nothing_is_typed(rig, screen):
    r = go(rig, screen, text="")
    resp = r["client"].post(r["url"], json={"text": "hello there"})
    assert resp.status_code == 409, resp.text
    assert settle(r) == b""
    assert r["mod"].fills == [("", "insert")] and r["mod"].enters == 0


def test_the_model_picker_still_takes_a_lone_option_number_as_before(rig):
    r = go(rig, "picker", text="")
    resp = r["client"].post(r["url"], json={"text": "2"})
    assert resp.status_code == 200 and resp.json()["dialogAnswer"] == "2"


# ---- the box did not take it, or the Enter did not take the box ----------------------------------------------------------

@pytest.mark.parametrize("fill_mode", ["altered", "notfilled", "chip"])
def test_a_box_that_does_not_hold_the_message_is_cleared_and_nothing_is_sent(rig, fill_mode):
    text = "one\ntwo\nthree\nfour" if fill_mode == "chip" else "hello there"
    r = go(rig, fill_mode=fill_mode)
    resp = r["client"].post(r["url"], json={"text": text})
    assert resp.status_code == 409 and NOT_SUBMITTED in resp.json()["error"]
    assert enters(r) == 0 and not pasted(r)
    assert r["mod"].fills[-1] == ("", "replace") and r["mod"].text == "" and r["mod"].submitted == []


def test_an_enter_an_overlay_swallowed_leaves_nothing_half_sent_and_is_not_pressed_again(rig, caplog):
    caplog.set_level(logging.INFO, logger="sala_web")
    r = go(rig, swallow=True)
    start = time.monotonic()
    resp = r["client"].post(r["url"], json={"text": "hello there"})
    took = time.monotonic() - start
    assert resp.status_code == 409 and NOT_SUBMITTED in resp.json()["error"]
    assert took < 5, took
    assert r["mod"].fills[-1] == ("", "replace") and r["mod"].text == "" and r["mod"].submitted == []
    assert enters(r) == 1                      # one Enter, never a second
    assert any("did not submit" in m for m in msgs(caplog)) and "hello there" not in caplog.text


def test_the_fill_going_unanswered_after_the_probe_clears_and_refuses(rig, monkeypatch):
    r = go(rig)
    real = MB.fill
    calls = []

    async def flaky(settings, pid, text, mode="replace", wait=MB.REPLY_WAIT):
        calls.append((text, mode))
        if text == "hello there":
            return None
        return await real(settings, pid, text, mode, wait)

    monkeypatch.setattr(MB, "fill", flaky)
    resp = r["client"].post(r["url"], json={"text": "hello there"})
    assert resp.status_code == 409 and NOT_SUBMITTED in resp.json()["error"]
    assert enters(r) == 0 and calls[-1] == ("", "replace")


# ---- a mod that does not have the verb, and a pane with none: the screen path as it always was -------------------------------

def test_an_old_mod_that_answers_unknown_leaves_the_paste_path_alone(rig):
    r = rig("box", "nobox", text="hello there", fill_mode="unknown")
    resp = r["client"].post(r["url"], json={"text": "hello there"})
    assert resp.status_code == 200 and resp.json()["confirmedByMod"] is True      # the older rule: missing, and the mod's draft is it
    assert wait_for(r, PASTE_END + b"\n") == b"\x1b[200~hello there" + PASTE_END + b"\n"
    assert r["mod"].fill_requests == 1 and r["mod"].fills == []


def test_an_old_mod_that_never_answers_the_verb_leaves_the_paste_path_alone_after_the_bounded_wait(rig):
    r = rig("box", "nobox", text="hello there", fill_mode="silent")
    start = time.monotonic()
    resp = r["client"].post(r["url"], json={"text": "hello there"})
    assert resp.status_code == 200 and time.monotonic() - start < 8
    assert wait_for(r, PASTE_END + b"\n") == b"\x1b[200~hello there" + PASTE_END + b"\n"
    assert r["mod"].fills == []


def test_a_pane_with_no_mod_pastes_as_always(rig):
    r = rig("box", "box", no_mod=True)
    resp = r["client"].post(r["url"], json={"text": "hello there"})
    assert resp.status_code == 200 and "confirmedByMod" not in resp.json()
    assert wait_for(r, PASTE_END + b"\n") == b"\x1b[200~hello there" + PASTE_END + b"\n"


def test_a_shell_command_is_pasted_not_filled(rig):
    r = go(rig, "box", "box")
    assert r["client"].post(r["url"], json={"text": "!ls -la"}).status_code == 200
    assert wait_for(r, PASTE_END + b"\n").startswith(b"\x1b[200~!ls -la")
    assert r["mod"].fills == []


def test_a_file_is_pasted_not_filled(rig):
    r = go(rig, "box", "box")
    up = r["client"].post("/api/upload", params={"name": "notes.txt"}, content=b"abc", headers={"Content-Type": "text/plain"}).json()
    assert r["client"].post(r["url"], json={"text": "look", "uploads": [up["name"]]}).status_code == 200
    assert r["mod"].fills == [] and pasted(r)


def test_a_long_text_is_pasted_not_filled(rig):
    r = go(rig, "box", "box")
    assert r["client"].post(r["url"], json={"text": "x " * 9000}).status_code == 200
    assert r["mod"].fills == [] and pasted(r)


# ---- a draft already in the box: today's rule -----------------------------------------------------------------------------

def test_a_draft_the_screen_reads_too_is_refused_as_before(rig):
    r = go(rig, "text", text="OWNER-WORDS-3321")
    resp = r["client"].post(r["url"], json={"text": "hello there"})
    assert resp.status_code == 409 and "pane input box is not empty" in resp.json()["error"]
    assert resp.json()["boxText"] == "OWNER-WORDS-3321"
    assert settle(r) == b"" and r["mod"].fills == [("", "insert")]


@pytest.mark.parametrize("draft", ["[Pasted text #2 +6 lines]", "[Image #1]", "owner words"])
def test_a_draft_the_screen_cannot_see_is_the_mods_and_is_refused_with_its_text(rig, draft):
    r = go(rig, "nobox", text=draft)
    resp = r["client"].post(r["url"], json={"text": "hello there"})
    assert resp.status_code == 409 and "pane input box is not empty" in resp.json()["error"]
    assert resp.json()["boxText"] == draft and resp.json()["boxChanged"] is False
    assert settle(r) == b"" and r["mod"].fills == [("", "insert")] and r["mod"].text == draft


def test_replace_clears_a_draft_the_screen_cannot_see_and_sends(rig):
    r = go(rig, "nobox", text="owner words")
    resp = r["client"].post(r["url"], json={"text": "hello there", "replace": "owner words"})
    assert resp.status_code == 200, resp.text
    assert r["mod"].fills == [("", "insert"), ("", "replace"), ("hello there", "replace")]
    assert r["mod"].submitted == ["hello there"] and enters(r) == 1


def test_replace_of_a_draft_that_changed_since_it_was_shown_is_refused_with_the_new_text(rig):
    r = go(rig, "nobox", text="owner words, more")
    resp = r["client"].post(r["url"], json={"text": "hello there", "replace": "owner words"})
    assert resp.status_code == 409 and resp.json()["boxChanged"] is True and resp.json()["boxText"] == "owner words, more"
    assert settle(r) == b"" and r["mod"].text == "owner words, more"


def test_a_retry_whose_message_is_in_the_box_presses_enter_once_and_pastes_nothing(rig):
    r = go(rig, "nobox", text="hello there")
    resp = r["client"].post(r["url"], json={"text": "hello there", "retry": True})
    assert resp.status_code == 200, resp.text
    assert resp.json()["resubmitted"] is True and resp.json()["confirmedByMod"] is True
    assert r["mod"].submitted == ["hello there"] and enters(r) == 1 and not pasted(r)
    assert r["mod"].fills == [("", "insert")]


def test_a_retry_whose_enter_is_swallowed_clears_the_box_and_does_not_press_again(rig):
    r = go(rig, "nobox", text="hello there", swallow=True)
    resp = r["client"].post(r["url"], json={"text": "hello there", "retry": True})
    assert resp.status_code == 409 and NOT_SUBMITTED in resp.json()["error"]
    assert enters(r) == 1 and r["mod"].text == "" and r["mod"].submitted == []


def test_a_retry_of_another_message_is_refused_with_the_draft(rig):
    r = go(rig, "nobox", text="something else entirely")
    resp = r["client"].post(r["url"], json={"text": "hello there", "retry": True})
    assert resp.status_code == 409 and resp.json()["boxText"] == "something else entirely"
    assert settle(r) == b""


def test_a_second_send_of_a_copy_is_still_a_duplicate(rig):
    r = go(rig)
    assert r["client"].post(r["url"], json={"text": "hello there"}).status_code == 200
    again = r["client"].post(r["url"], json={"text": "hello there"})
    assert again.status_code == 409 and again.json().get("duplicate") is True
    assert enters(r) == 1
