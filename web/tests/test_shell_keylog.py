"""POST /api/shell/keylog: the Shell's key log (keylog.py), the server's half of what static/termclip.js records.

The page posts what the keyboard sends to the Shell's terminal (named keys and composition events, never a typed character) so that a
key that does nothing can be read off afterwards. The server does not trust the page: it checks every field again, drops an event with any
other shape, and keeps a file of its own: `<state_dir>/shell-keylog.jsonl`, one JSON line an event, mode 0600, never past 256 KB (a write
that would pass the cap keeps the newest half). Same guards as the other POSTs: 403 cross-origin, 415 not JSON. The page's half is
test_terminal_shell_font.py's. No tmux, no browser, no network: the app on a temp folder.
"""

from __future__ import annotations

import json
import os

import pytest
from starlette.testclient import TestClient

from sala_web import keylog as KL
from sala_web.app import STATIC, create_app
from sala_web.config import Settings

T0 = 1_760_000_000_000      # a millisecond epoch time in 2025
KO = "\uac00"               # one Korean syllable, as an escape: no Hangul literal in the source


@pytest.fixture
def env(tmp_path):
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    (claude / "projects").mkdir()
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                        tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"])
    return {"client": TestClient(create_app(settings)), "file": settings.state_dir / KL.FILE_NAME, "dir": settings.state_dir, "settings": settings}


def key(**over) -> dict:
    return {**{"t": T0, "type": "keydown", "key": "HangulMode", "code": "Lang1", "keyCode": 21, "isComposing": False,
               "shift": False, "ctrl": False, "alt": False, "meta": False}, **over}


def comp(**over) -> dict:
    return {**{"t": T0, "type": "compositionupdate"}, **over}


def post(env, body, **kw):
    return env["client"].post("/api/shell/keylog", content=json.dumps(body), headers={"content-type": "application/json"}, **kw)


def lines(env) -> list[dict]:
    return [json.loads(line) for line in env["file"].read_text().splitlines()]


# ---------------------------------------------------------------- what is kept


def test_a_good_batch_is_written_one_line_an_event_and_answered_with_the_count(env):
    batch = [key(key="Alt", code="AltRight", keyCode=18, alt=True), key(type="keyup", key="Alt", code="AltRight", keyCode=18),
             key(key="Process", code="KeyG", keyCode=229, isComposing=True), key(key="Unidentified", code="", keyCode=0),
             comp(type="compositionstart"), comp(), comp(type="compositionend")]
    r = post(env, batch)
    assert r.status_code == 200 and r.json() == {"ok": True, "n": 7}
    assert lines(env) == batch
    assert (env["file"].stat().st_mode & 0o777) == 0o600
    assert env["file"].read_text().isascii()
    assert post(env, [key(key="Enter", code="Enter", keyCode=13)]).json()["n"] == 1
    assert len(lines(env)) == 8                                               # appended, never replaced


def test_an_empty_list_is_fine_and_writes_nothing(env):
    assert post(env, []).json() == {"ok": True, "n": 0}
    assert not env["file"].exists()


# a client that is not the page, or a page with a bug, sends these; each is dropped (the rest of the batch is kept)
BAD = [
    ("a printable letter", key(key="a", code="KeyA", keyCode=65)),
    ("an upper-case letter", key(key="A", code="KeyA", keyCode=65, shift=True)),
    ("a digit", key(key="5", code="Digit5", keyCode=53)),
    ("a space", key(key=" ", code="Space", keyCode=32)),
    ("a punctuation mark", key(key="!", code="Digit1", keyCode=49, shift=True)),
    ("a Korean letter", key(key=KO, code="KeyG", keyCode=229)),
    ("a keyup of a letter", key(type="keyup", key="q", code="KeyQ", keyCode=81)),
    ("a name with a non-ASCII letter", key(key="Alté")),
    ("a name over 24 characters", key(key="A" * 25)),
    ("a name that starts with a digit", key(key="1F")),
    ("a name with a space", key(key="Arrow Left")),
    ("an empty name", key(key="")),
    ("a name with a newline at its end", key(key="Alt\n")),
    ("a key that is not a string", key(key=5)),
    ("a code with punctuation", key(code="Key-A")),
    ("a code over 24 characters", key(code="A" * 25)),
    ("a code that is not a string", key(code=None)),
    ("a keyCode below 0", key(keyCode=-1)),
    ("a keyCode over 65535", key(keyCode=65536)),
    ("a keyCode as a string", key(keyCode="229")),
    ("a keyCode as a float", key(keyCode=21.5)),
    ("a keyCode as a bool", key(keyCode=True)),
    ("a flag as a number", key(shift=1)),
    ("a flag as a string", key(alt="false")),
    ("a flag as null", key(isComposing=None)),
    ("a time as a string", key(t=str(T0))),
    ("a time as a float", key(t=float(T0))),
    ("a time as a bool", key(t=True)),
    ("a time before 2000", key(t=1000)),
    ("a time after 2100", key(t=4_200_000_000_000)),
    ("a time missing", {k: v for k, v in key().items() if k != "t"}),
    ("an event type that is not listed (keypress)", key(type="keypress")),
    ("an event type that is not listed (input)", comp(type="input")),
    ("an event type that is not a string", key(type=["keydown"])),
    ("a field of another kind", key(data="x")),
    ("an extra field (the typed text)", key(text="hunter2")),
    ("a missing flag", {k: v for k, v in key().items() if k != "meta"}),
    ("a composition event with a key", comp(key="Process")),
    ("a composition event with data (a Korean syllable)", comp(data=KO)),
    ("a composition event with data (one letter)", comp(data="x")),
    ("a composition event with empty data", comp(type="compositionstart", data="")),
    ("a composition event with data that is not a string", comp(data=5)),
    ("a composition event with null data", comp(data=None)),
    ("a composition event with a text field", comp(text="secret")),
    ("a composition event with an extra field", comp(isComposing=True)),
    ("a string", "keydown Alt"),
    ("a number", 5),
    ("null", None),
    ("a list", [key()]),
    ("an empty object", {}),
]


@pytest.mark.parametrize("what, event", BAD, ids=[w for w, _ in BAD])
def test_an_event_that_is_not_exactly_a_key_name_or_a_composition_is_dropped(env, what, event):
    good = key(key="Alt", code="AltRight", keyCode=18)
    r = post(env, [event, good])
    assert r.status_code == 200 and r.json() == {"ok": True, "n": 1}, (what, r.text)
    assert lines(env) == [good]                                              # only the good one, and nothing of the bad one in the file
    assert env["file"].read_text().count("\n") == 1


def test_a_single_printable_keydown_from_a_buggy_client_never_reaches_the_file(env):
    typed = [key(key=chr(c), code="KeyA", keyCode=65) for c in range(0x20, 0x7f)] + [key(key=KO), key(key="é")]
    for chunk in (typed[:50], typed[50:]):
        assert post(env, chunk).json() == {"ok": True, "n": 0}
    assert not env["file"].exists()                                          # a password typed in the pane is nowhere on disk


def test_a_composed_password_leaves_no_composed_character_in_the_file(env):
    """A password typed in Korean mode at a prompt: the IME composes it syllable by syllable, each update carrying the text so far.
    Sent as a buggy client would send it (with `data`) every event is dropped; sent as the page sends it, only {t, type} is kept."""
    secret = KO + "\ub098\ub2e4" + "hunter2"
    steps = [secret[:i] for i in range(1, len(secret) + 1)]
    with_text = [comp(type="compositionstart", data="")] + [comp(data=s) for s in steps] + [comp(type="compositionend", data=secret)]
    assert post(env, with_text).json() == {"ok": True, "n": 0}
    assert not env["file"].exists()
    as_sent = [{"t": T0 + i, "type": e["type"]} for i, e in enumerate(with_text)]
    assert post(env, as_sent).json() == {"ok": True, "n": len(with_text)}
    text = env["file"].read_text()
    assert [r["type"] for r in lines(env)] == ["compositionstart"] + ["compositionupdate"] * len(steps) + ["compositionend"]
    assert all(set(r) == {"t", "type"} for r in lines(env))
    raw = env["file"].read_bytes()
    assert all(ch not in text and ch.encode() not in raw for ch in secret if not ch.isascii())   # no Korean syllable, escaped or not
    assert "\\u" not in text and "data" not in text and "hunter" not in text and "nter2" not in text


# ---------------------------------------------------------------- the body


@pytest.mark.parametrize("body", [{"events": []}, {}, "text", 5, None, True])
def test_a_body_that_is_not_a_list_is_400(env, body):
    r = post(env, body)
    assert r.status_code == 400 and "list" in r.json()["error"]
    assert not env["file"].exists()


def test_more_than_50_events_or_32_kb_is_400_and_nothing_is_written(env):
    assert post(env, [key()] * 50).json()["n"] == 50
    n = len(lines(env))
    r = post(env, [key()] * 51)
    assert r.status_code == 400 and "50" in r.json()["error"]
    big = env["client"].post("/api/shell/keylog", content=json.dumps([key()] * 50 + [{"pad": "x" * 33_000}]), headers={"content-type": "application/json"})
    assert big.status_code == 400
    under = json.dumps([key()] * 3 + [{"pad": "x" * (KL.MAX_BODY - 600)}])                          # just under 32 KB: read, the pad item dropped
    assert len(under) <= KL.MAX_BODY and post(env, json.loads(under)).json()["n"] == 3
    assert len(lines(env)) == n + 3
    over = "[" + ",".join([json.dumps(key())] * 200) + "]"
    assert len(over) > KL.MAX_BODY
    assert env["client"].post("/api/shell/keylog", content=over, headers={"content-type": "application/json"}).status_code == 400
    assert len(lines(env)) == n + 3


def test_a_body_that_is_not_json_or_nests_deeply_is_400(env):
    h = {"content-type": "application/json"}
    c = env["client"]
    assert c.post("/api/shell/keylog", content=b"[{", headers=h).status_code == 400
    assert c.post("/api/shell/keylog", content=b"\xff\xfe", headers=h).status_code == 400
    assert c.post("/api/shell/keylog", content=b"", headers=h).status_code == 400
    assert c.post("/api/shell/keylog", content=b"[" * 20_000 + b"]" * 20_000, headers=h).status_code == 400    # deep enough to overflow the parser
    assert not env["file"].exists()


def test_the_guards_are_those_of_the_other_posts(env):
    c = env["client"]
    body = json.dumps([key()])
    assert c.post("/api/shell/keylog", content=body, headers={"content-type": "text/plain"}).status_code == 415
    assert c.post("/api/shell/keylog", content=body).status_code == 415
    assert c.post("/api/shell/keylog", content=body, headers={"content-type": "application/json", "origin": "https://evil.example"}).status_code == 403
    assert c.post("/api/shell/keylog", content=body, headers={"content-type": "application/json", "origin": "null"}).status_code == 403
    assert not env["file"].exists()
    ok = c.post("/api/shell/keylog", content=body, headers={"content-type": "application/json; charset=utf-8", "origin": "http://testserver"})
    assert ok.status_code == 200 and ok.json()["n"] == 1                       # the page's own origin, with a charset
    assert c.get("/api/shell/keylog").status_code == 405                       # nothing reads the log back over HTTP


# ---------------------------------------------------------------- the file


def numbered(i: int) -> dict:
    return key(t=T0 + i, key="Shift", code="ShiftLeft", keyCode=16)


def test_the_file_never_passes_the_cap_and_keeps_the_newest_half_when_it_would(env):
    sizes, total = [], 0
    for b in range(120):                                                       # about 8 KB a batch: past the 256 KB cap after about 33
        batch = [numbered(b * 50 + i) for i in range(50)]
        assert post(env, batch).json()["n"] == 50
        total += 50
        sizes.append(env["file"].stat().st_size)
        assert not [p for p in env["dir"].iterdir() if p.name.startswith(".shell-keylog-")]      # no temp file left behind
    assert max(sizes) <= KL.MAX_FILE and any(b < a for a, b in zip(sizes, sizes[1:]))            # it was cut back at least once
    assert min(sizes[40:]) >= KL.MAX_FILE // 2 - 10_000                       # and cut to about half, not emptied
    rows = lines(env)
    assert rows[-1]["t"] == T0 + total - 1                                    # the newest is the last line
    assert [r["t"] for r in rows] == sorted(r["t"] for r in rows) and rows[0]["t"] > T0   # in order, the oldest gone
    assert len({r["t"] for r in rows}) == len(rows) and rows[-1]["t"] - rows[0]["t"] == len(rows) - 1   # one unbroken run of the newest
    assert (env["file"].stat().st_mode & 0o777) == 0o600                      # the rewritten file too


def test_a_rewrite_cuts_at_a_line_and_a_file_that_is_too_big_is_cut_to_the_newest_half(env):
    env["dir"].mkdir(parents=True)
    old = "".join(json.dumps(numbered(i), separators=(",", ":")) + "\n" for i in range(3000))      # about 450 KB, more than the cap
    assert len(old) > KL.MAX_FILE
    env["file"].write_text(old)
    os.chmod(env["file"], 0o644)
    assert post(env, [numbered(5000)]).json()["n"] == 1
    rows = lines(env)                                                           # every line whole (the cut falls on a line start)
    assert env["file"].stat().st_size <= KL.MAX_FILE // 2 + 400
    assert rows[-1]["t"] == T0 + 5000 and rows[-2]["t"] == T0 + 2999
    assert (env["file"].stat().st_mode & 0o777) == 0o600


def test_an_existing_file_with_a_loose_mode_is_made_0600_by_the_next_write(env):
    env["dir"].mkdir(parents=True)
    env["file"].write_text("")
    os.chmod(env["file"], 0o666)
    assert post(env, [key()]).json()["n"] == 1
    assert (env["file"].stat().st_mode & 0o777) == 0o600


def test_the_state_folder_is_made_when_it_is_missing(env):
    assert not env["dir"].exists()
    assert post(env, [key()]).json()["n"] == 1
    assert env["file"].is_file()


def test_a_file_that_cannot_be_written_is_a_plain_500(tmp_path):
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=tmp_path / "claude",
                        tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"])
    (tmp_path / "state").write_text("a file where the folder should be")
    r = TestClient(create_app(settings)).post("/api/shell/keylog", json=[key()])
    assert r.status_code == 500 and "key log" in r.json()["error"]


def test_the_unit_functions_agree_with_the_endpoint():
    assert KL.clean(key()) == key() and KL.clean(comp()) == comp()
    assert KL.clean_all([key(key="a"), key(), "x", comp(data="y"), comp()]) == [key(), comp()]
    assert KL.clean(comp(data="")) is None and KL.COMPOSITION_FIELDS == {"t", "type"}      # no text of any kind, not even an empty string
    assert KL.MAX_FILE == 256 * 1024 and KL.MAX_EVENTS == 50 and KL.MAX_BODY == 32 * 1024 and not hasattr(KL, "MAX_DATA")


def test_the_endpoint_is_in_the_apps_docstring_and_the_readme():
    app_py = (STATIC.parent / "app.py").read_text()
    assert "POST /api/shell/keylog" in app_py and "state_dir/shell-keylog.jsonl" in app_py
    readme = (STATIC.parents[2] / "README.md").read_text()
    assert readme.count("`POST /api/shell/keylog`") >= 2 and "shell-keylog.jsonl" in readme
