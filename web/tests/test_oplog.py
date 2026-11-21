"""Operation log pages: GET /op/<id> serves the log `sala op` wrote, as plain text, read-only (oplog.py, docs/op-log-page.md).

The tests drive the app in process (starlette's TestClient) over a log folder the test makes; nothing outside tmp_path is read.
"""

import os
from pathlib import Path

import pytest
from starlette.testclient import TestClient

from sala_web import oplog as OL
from sala_web.app import create_app
from sala_web.config import Settings

ID = "1795241896-3776744"          # the shape `sala op` builds an id in: the epoch second and the process id
HEADERS = {
    "cache-control": "private, no-store",
    "x-content-type-options": "nosniff",
    "referrer-policy": "no-referrer",
    "content-security-policy": "default-src 'none'; sandbox",
}
LOG = "[2026-11-02T10:00:00Z] op 1795241896-3776744: retire sala-test-a — asked by sala-test-h\nline two ✓\n"


def make_settings(tmp_path, **kw) -> Settings:
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True, exist_ok=True)
    (claude / "projects").mkdir(exist_ok=True)
    return Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude, sala_state_dir=tmp_path / "salastate",
                    tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"], **kw)


@pytest.fixture
def env(tmp_path):
    logs = tmp_path / "logs"
    logs.mkdir()
    settings = make_settings(tmp_path, log_dir=logs)
    return {"client": TestClient(create_app(settings)), "logs": logs, "tmp": tmp_path}


def store(logs: Path, op_id: str = ID, data: bytes | str = LOG) -> Path:
    p = logs / f"salamander-op-{op_id}.log"
    p.write_bytes(data.encode("utf-8") if isinstance(data, str) else data)
    return p


def check_headers(r) -> None:
    for k, v in HEADERS.items():
        assert r.headers[k] == v, k
    assert "set-cookie" not in r.headers


def test_a_log_is_served_as_utf8_plain_text_with_the_headers(env):
    store(env["logs"])
    r = env["client"].get(f"/op/{ID}")
    assert r.status_code == 200
    assert r.headers["content-type"] == "text/plain; charset=utf-8"
    assert r.text == LOG                       # as the file is: nothing parsed, nothing taken out
    check_headers(r)


def test_head_is_answered_like_get_and_with_the_headers(env):
    store(env["logs"])
    r = env["client"].head(f"/op/{ID}")
    assert r.status_code == 200
    check_headers(r)


def test_a_log_is_not_redacted_or_rewritten(env):
    body = "a path ~/logs/a.log\na token-like value stays as written\n<b>not html</b>\n"
    store(env["logs"], data=body)
    r = env["client"].get(f"/op/{ID}")
    assert r.text == body
    assert r.headers["content-type"].startswith("text/plain")


def test_the_last_256_kb_are_served_with_the_notice_first(env):
    lines = [f"line {i:06d} " + "x" * 40 for i in range(12000)]        # about 630 KB
    data = "\n".join(lines) + "\n"
    store(env["logs"], data=data)
    size = len(data.encode())
    assert size > OL.MAX_BYTES
    r = env["client"].get(f"/op/{ID}")
    assert r.status_code == 200
    first, rest = r.text.split("\n", 1)
    assert first == f"[earlier lines cut: showing the last 256 KB of {size} bytes]"
    assert len(rest.encode()) <= OL.MAX_BYTES
    assert rest.endswith(lines[-1] + "\n")                          # the end of the log is what is kept
    assert rest.startswith("line ")                                 # cut at a line start, never in the middle of one
    assert "line 000000" not in rest
    check_headers(r)


def test_a_cut_on_a_line_start_keeps_the_first_whole_line(env):
    # the byte before the cut is a newline: the tail starts on a line, so no line is lost to the "partial line" rule
    tail = ("a" * 99 + "\n") * (OL.MAX_BYTES // 100) + "b" * (OL.MAX_BYTES % 100 - 1) + "\n"
    assert len(tail) == OL.MAX_BYTES
    store(env["logs"], data="head line\n" + tail)
    first, rest = env["client"].get(f"/op/{ID}").text.split("\n", 1)
    assert first.startswith("[earlier lines cut:")
    assert rest == tail                                                # every line of the tail, the first one included
    # the byte before the cut is not a newline (the cut is inside a line): the first, partial line goes
    store(env["logs"], data="head line\nx" + tail)
    rest = env["client"].get(f"/op/{ID}").text.split("\n", 1)[1]
    assert rest == tail[100:]


def test_a_log_of_exactly_the_cap_is_not_cut(env):
    data = ("y" * 99 + "\n") * (OL.MAX_BYTES // 100)
    data += "z" * (OL.MAX_BYTES - len(data))
    assert len(data) == OL.MAX_BYTES
    store(env["logs"], data=data)
    r = env["client"].get(f"/op/{ID}")
    assert r.text == data


def test_a_cut_in_the_middle_of_a_utf8_character_is_replaced_not_an_error(env):
    data = ("é" * 200000) + "\n" + "end\n"                 # 2 bytes each: the cut lands inside a character
    store(env["logs"], data=data)
    r = env["client"].get(f"/op/{ID}")
    assert r.status_code == 200
    assert r.text.endswith("end\n")


def test_bytes_that_are_not_utf8_are_replaced(env):
    store(env["logs"], data=b"ok\n\xff\xfe broken \x80\nnext\n")
    r = env["client"].get(f"/op/{ID}")
    assert r.status_code == 200
    assert r.text == "ok\n�� broken �\nnext\n"


def test_an_empty_log_is_an_empty_page(env):
    store(env["logs"], data="")
    r = env["client"].get(f"/op/{ID}")
    assert r.status_code == 200 and r.text == ""
    check_headers(r)


def test_a_missing_log_is_404_with_the_headers(env):
    r = env["client"].get(f"/op/{ID}")
    assert r.status_code == 404
    assert r.text == "no such log"
    check_headers(r)


@pytest.mark.parametrize("bad", [
    "..%2Fx", "1-2%2F..%2F..%2Fetc%2Fpasswd", "1795241896-3776744%2F..%2Fx", "1795241896", "1795241896-", "-3776744",
    "17952-3776744", "1795241896-37767441234", "17952418961234-3", "1795241896-3776744.log", "1795241896-3776744%00",
    "1795241896--3", "+1795241896-3", "%20", "abc-def", "１７９５２４１８９６-３", "1795241896-3776744/x",
])
def test_an_address_that_is_not_an_id_is_404_with_the_headers(env, bad):
    # a valid log is there, and a file outside the folder: nothing but the validated id builds a path
    store(env["logs"])
    (env["tmp"] / "x").write_text("secret")
    r = env["client"].get("/op/" + bad)
    assert r.status_code == 404, bad
    assert r.text == "no such log"
    check_headers(r)


def test_the_empty_address_and_a_deeper_one_are_404_with_the_headers(env):
    store(env["logs"])
    for path in ("/op", "/op/", "/op/%s/" % ID, "/op/a/b/c"):
        r = env["client"].get(path)
        assert r.status_code == 404, path
        check_headers(r)


def test_a_dotdot_path_never_leaves_the_log_folder(env):
    (env["tmp"] / "salamander-op-1-2.log").write_text("outside")
    store(env["logs"])
    r = env["client"].get("/op/..%2Flogs%2Fsalamander-op-" + ID)
    assert r.status_code == 404


def test_the_id_check_is_a_full_match_not_a_prefix_or_a_line(env):
    # read_log directly: a newline after a good id (an HTTP client may drop it from the address) is still not an id
    store(env["logs"])
    assert OL.read_log(env["logs"], ID) == LOG
    for bad in (ID + "\n", "\n" + ID, ID + " ", " " + ID, ID + "\x00", ID.replace("-", "\u2010")):
        assert OL.read_log(env["logs"], bad) is None, repr(bad)


def test_a_symlink_log_is_refused(env):
    target = env["tmp"] / "elsewhere.txt"
    target.write_text("private\n")
    (env["logs"] / f"salamander-op-{ID}.log").symlink_to(target)
    r = env["client"].get(f"/op/{ID}")
    assert r.status_code == 404
    assert "private" not in r.text
    check_headers(r)


def test_a_folder_and_a_pipe_are_refused(env):
    (env["logs"] / f"salamander-op-{ID}.log").mkdir()
    assert env["client"].get(f"/op/{ID}").status_code == 404
    other = "1795241897-1"
    os.mkfifo(env["logs"] / f"salamander-op-{other}.log")
    assert env["client"].get(f"/op/{other}").status_code == 404      # and it does not wait for a writer


def test_only_the_logs_own_name_is_served(env):
    # the other files an operation leaves beside its log are not reachable through the id
    store(env["logs"], data="the log\n")
    (env["logs"] / f"salamander-op-{ID}.out").write_text("the verb's output\n")
    (env["logs"] / f"salamander-op-{ID}.helper.log").write_text("the helper\n")
    assert env["client"].get(f"/op/{ID}").text == "the log\n"


@pytest.mark.parametrize("method", ["post", "put", "patch", "delete", "options", "trace", "connect"])
def test_any_other_method_is_405_with_the_headers(env, method):
    store(env["logs"])
    for path in (f"/op/{ID}", "/op/nonsense", "/op"):
        r = env["client"].request(method.upper(), path)
        assert r.status_code == 405, (method, path)
        assert r.headers["allow"] == "GET, HEAD"
        check_headers(r)


@pytest.mark.parametrize("method", ["PROPFIND", "MKCOL", "PURGE", "BREW"])
def test_a_method_no_list_names_is_405_with_the_headers_too(env, method):
    # a verb outside any list Starlette would be given: the route has no method list, so its own 405 (no headers, a wrong Allow) never answers
    store(env["logs"])
    for path in (f"/op/{ID}", "/op/nonsense", "/op/a/b", "/op"):
        r = env["client"].request(method, path)
        assert r.status_code == 405, (method, path)
        assert r.headers["allow"] == "GET, HEAD"
        check_headers(r)


@pytest.mark.parametrize("end", ["\n", ""])   # its own newline is the tail's only one, or there is none at all
def test_one_huge_line_is_served_as_its_tail_with_a_marker(env, end):
    # a log whose last 256 KB hold no newline: the page keeps the tail of that line and says its first part is cut, never an empty page
    line = "".join(chr(ord("a") + i % 26) for i in range(OL.MAX_BYTES + 5000))
    store(env["logs"], data=line + end)
    r = env["client"].get(f"/op/{ID}")
    assert r.status_code == 200
    first, second, rest = r.text.split("\n", 2)
    assert first == f"[earlier lines cut: showing the last 256 KB of {len(line) + len(end)} bytes]"
    assert second == "(first part of a very long line cut)"
    assert rest == line[-(OL.MAX_BYTES - len(end)):] + end         # the tail of the line, up to the end of the file
    check_headers(r)


def test_a_tail_with_a_newline_in_it_drops_the_partial_line_and_has_no_marker(env):
    data = "q" * 300000 + "\nsecond line\nthird\n"                    # the cut falls inside the long first line
    store(env["logs"], data=data)
    text = env["client"].get(f"/op/{ID}").text
    assert text == f"[earlier lines cut: showing the last 256 KB of {len(data)} bytes]\nsecond line\nthird\n"


def test_the_log_dir_is_the_one_setting_both_sides_read(tmp_path, monkeypatch):
    # the CLI sources sala's config file and reads SALA_LOG_DIR from it; sala-web has no sala environment, so it reads the same line from the same
    # file (separate environments: the web service's has no SALA_LOG_DIR, and no SALA_WEB_LOG_DIR is read at all)
    factory = Settings.__dataclass_fields__["log_dir"].default_factory
    cfg = tmp_path / "config"
    monkeypatch.setenv("SALA_CONFIG", str(cfg))
    monkeypatch.delenv("SALA_LOG_DIR", raising=False)
    monkeypatch.setenv("SALA_WEB_LOG_DIR", str(tmp_path / "ignored"))
    cfg.write_text("SALA_TZ=Etc/UTC\n")
    assert factory() == Path.home() / ".claude"                           # no line anywhere
    cfg.write_text("SALA_LOG_DIR=~/custom-logs   # moved\n")
    assert factory() == Path.home() / "custom-logs"                       # the config line alone, as the CLI's source of it
    cfg.write_text('export SALA_LOG_DIR="$HOME/other logs"\n')
    assert factory() == Path.home() / "other logs"
    monkeypatch.setenv("SALA_LOG_DIR", str(tmp_path / "env"))
    assert factory() == tmp_path / "env"                                   # the environment still wins, as for every sala setting
