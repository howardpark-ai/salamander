"""Operation log pages: GET /op/<id> serves the log `sala op` wrote, as plain text, read-only (oplog.py, docs/op-log-page.md).

The tests drive the app in process (starlette's TestClient) over a log folder the test makes; nothing outside tmp_path is read.
"""

import os
import re
import subprocess
from pathlib import Path

import pytest
from starlette.testclient import TestClient

from sala_web import oplog as OL
from sala_web.app import create_app
from sala_web.config import Settings, log_dir

ROOT = Path(__file__).resolve().parents[2]
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
    factory = log_dir
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
    monkeypatch.delenv("SALA_LOG_DIR")
    monkeypatch.setenv("HOME", str(tmp_path / "h"))
    monkeypatch.chdir(tmp_path)
    cfg.write_text("SALA_LOG_DIR=logs\n")
    assert factory() == tmp_path / "h" / "logs"                            # a relative folder is under $HOME (as the CLI reads it), never the working folder
    monkeypatch.setenv("SALA_LOG_DIR", "a/b")
    assert factory() == tmp_path / "h" / "a" / "b"


def test_a_running_service_follows_a_folder_changed_in_the_config(tmp_path, monkeypatch):
    # the CLI rereads the config at each post, so the service must too: an app built once finds a log in the folder the config names NOW
    monkeypatch.setenv("HOME", str(tmp_path / "h"))
    for k in ("SALA_LOG_DIR", "SALA_WEB_LOG_DIR"):
        monkeypatch.delenv(k, raising=False)
    cfg = tmp_path / "config"
    monkeypatch.setenv("SALA_CONFIG", str(cfg))
    (tmp_path / "h" / "first").mkdir(parents=True)
    (tmp_path / "h" / "second").mkdir()
    store(tmp_path / "h" / "first", data="in the first folder\n")
    store(tmp_path / "h" / "second", data="in the second folder\n")
    cfg.write_text("SALA_LOG_DIR=first\n")
    web = TestClient(create_app(make_settings(tmp_path)))                     # built once, as the service is
    assert web.get(f"/op/{ID}").text == "in the first folder\n"
    cfg.write_text("SALA_LOG_DIR=second\n")
    assert web.get(f"/op/{ID}").text == "in the second folder\n"              # no restart
    cfg.write_text("SALA_TZ=Etc/UTC\n")
    assert web.get(f"/op/{ID}").status_code == 404                           # back to ~/.claude, where there is none


def test_the_log_folder_is_resolved_off_the_event_loop(tmp_path, monkeypatch):
    # reading sala's config is a file read: it runs in the worker thread with the log read, never on the loop (a slow home folder must not stall other requests)
    import asyncio
    import sala_web.app as appmod
    seen = []

    def spy():
        try:
            asyncio.get_running_loop()
            seen.append("loop")
        except RuntimeError:
            seen.append("worker")
        return tmp_path / "logs"

    (tmp_path / "logs").mkdir()
    store(tmp_path / "logs")
    monkeypatch.setattr(appmod, "log_dir", spy)
    web = TestClient(create_app(make_settings(tmp_path)))
    assert web.get(f"/op/{ID}").text == LOG
    assert seen == ["worker"]


# The CLI's own post, run as the CLI runs it (lib/common.sh and lib/op.sh sourced, the real op_post, Slack a printed line), then its link followed
# through the web app built the way the service builds it: no sala environment of its own, only the default config file under the same HOME.
CLI_POST = r"""
set -u
. "$ROOT/lib/common.sh"; . "$ROOT/lib/op.sh"
sala_notify_raw() { printf '%s\n' "$1"; }
OP_PF=(); OP_PL=()
mkdir -p "$SALA_OP_DIR" "$SALA_LOG_DIR"
printf 'id=%s\ntime=%s\nfrom=sala-test-h\nwords=w\nverb=model\narg=sala-test-a\narg=--clear\nstate=done\n' "$ID" 1795241896 > "$SALA_OP_DIR/$ID.op"
case ${LOGKIND:-file} in
    file) printf '%s' "$LOGTEXT" > "$(op_oplog "$ID")" ;;
    symlink) printf '%s' "$LOGTEXT" > "$HOME/elsewhere.log"; ln -s "$HOME/elsewhere.log" "$(op_oplog "$ID")" ;;
    unreadable) printf '%s' "$LOGTEXT" > "$(op_oplog "$ID")"; chmod 0200 "$(op_oplog "$ID")" ;;
    readonly) printf '%s' "$LOGTEXT" > "$(op_oplog "$ID")"; chmod 0400 "$(op_oplog "$ID")" ;;
    missing) : ;;
esac
op_post "$ID" done 1 0 sala-test-a
"""
CLI_LOG = "[2026-11-02T10:00:00Z] op: cleared the model\nthe verb's own output\n"
CLI_CASES = {   # name: (default config's text, the CLI's own SALA_CONFIG text or None, extra CLI environment, CLI working folder, the log's kind, link expected)
    "default folder": (None, None, {}, "", "file", True),
    "moved in the config": ("SALA_LOG_DIR=~/moved\n", None, {}, "", "file", True),
    "relative in the config, CLI run from elsewhere": ("SALA_LOG_DIR=logs\n", None, {}, "elsewhere", "file", True),
    "a CLI-only SALA_CONFIG": (None, "SALA_LOG_DIR=~/cli-only\n", {}, "", "file", False),
    "a CLI-only SALA_LOG_DIR": (None, None, {"SALA_LOG_DIR": "@cli-only"}, "", "file", False),
    "a CLI-only relative SALA_LOG_DIR": (None, None, {"SALA_LOG_DIR": "elsewhere-logs"}, "", "file", False),
    "the config's line wins over the CLI's environment, as it does for the CLI": ("SALA_LOG_DIR=~/moved\n", None, {"SALA_LOG_DIR": "@cli-only"}, "", "file", True),
    # the config's SALA_LOG_DIR line in every shape the app's reader understands: the CLI's reading of it must agree with the app's
    "an export, double quotes, a space in the folder": ('export SALA_LOG_DIR="$HOME/other logs"\n', None, {}, "", "file", True),
    "a trailing comment": ("SALA_LOG_DIR=~/moved   # kept here\n", None, {}, "", "file", True),
    # (the two HOME forms are built from pieces so no home-path shape sits in the source; each case holds ONE assignment, so each form is used by both readers)
    "braced HOME alone": ("SALA_LOG_DIR=$" + "{HOME}" + "/braced\n", None, {}, "", "file", True),
    "plain HOME alone": ("SALA_LOG_DIR=" + "$HOME" + "/plain\n", None, {}, "", "file", True),
    "an ampersand in HOME, plain HOME in the config": ("SALA_LOG_DIR=" + "$HOME" + "/logs\n", None, {}, "", "file", True, "a&b"),
    "an ampersand in HOME, braced HOME in the config": ("SALA_LOG_DIR=$" + "{HOME}" + "/logs\n", None, {}, "", "file", True, "a&b"),
    "an ampersand in HOME, a tilde in the config": ("SALA_LOG_DIR=~/logs\n", None, {}, "", "file", True, "a&b"),
    "the last assignment wins": ("SALA_LOG_DIR=~/first\nSALA_LOG_DIR=~/moved\n", None, {}, "", "file", True),
    "an indented line": ("   SALA_LOG_DIR=~/moved\n", None, {}, "", "file", True),
    "an empty value is the default": ("SALA_LOG_DIR=\n", None, {}, "", "file", True),
    # the log itself: the page opens a regular file only, so a link to a missing log or to a symlink would 404
    "a missing log": (None, None, {}, "", "missing", False),
    "a symlink log": (None, None, {}, "", "symlink", False),
    "a write-only log (nobody can read it, the page answers 404)": (None, None, {}, "", "unreadable", False),
    # The readability test is the CLI user's own, and the service is a user unit of the same account, so the two agree: a log the owner can read gets the link
    # and opens. NOT covered: a separate web account reading the logs through an ACL (the repo does not set one up); there the CLI cannot tell, posts the path
    # and errs on the side of no link rather than a dead one (web/README.md, Operation log pages).
    "a read-only log (the owner reads it: linked and opens)": (None, None, {}, "", "readonly", True),
    "a missing log in a moved folder": ("SALA_LOG_DIR=~/moved\n", None, {}, "", "missing", False),
}


@pytest.mark.parametrize("case", list(CLI_CASES))
def test_the_link_the_cli_posts_opens_the_log_or_is_not_posted(tmp_path, monkeypatch, case):
    default_cfg, cli_cfg, extra, cwd, kind, linked, *more = CLI_CASES[case]
    if kind == "unreadable" and os.geteuid() == 0:
        pytest.skip("root reads a write-only file anyway: the case needs an ordinary user")
    home = tmp_path / (more[0] if more else "home")
    (home / ".config" / "salamander").mkdir(parents=True)
    default = home / ".config" / "salamander" / "config"
    if default_cfg:
        default.write_text(default_cfg)
    other = tmp_path / "cli.conf"
    if cli_cfg:
        other.write_text(cli_cfg)
    work = tmp_path / (cwd or "work")
    work.mkdir()
    cli_env = {k: str(home / v[1:]) if v.startswith("@") else v for k, v in extra.items()}
    env = {"PATH": os.environ["PATH"], "HOME": str(home), "ROOT": str(ROOT), "ID": ID, "LOGTEXT": CLI_LOG, "LOGKIND": kind,
           "SALA_CONFIG": str(other if cli_cfg else default), "SALA_SESSION_URL": "https://sala.example/#s={name}", **cli_env}
    out = subprocess.run(["bash", "-c", CLI_POST], env=env, cwd=work, capture_output=True, text=True, timeout=60, check=True).stdout.splitlines()[-1]
    m = re.search(r"<https://sala\.example(/op/[^|>]+)\|log>$", out)
    assert bool(m) == linked, out
    # the web service: no sala environment, the same HOME, its own working folder
    for k in ("SALA_CONFIG", "SALA_LOG_DIR", "SALA_WEB_LOG_DIR"):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.chdir(tmp_path)
    web = TestClient(create_app(make_settings(tmp_path)))
    r = web.get(m.group(1) if m else f"/op/{ID}")
    if linked:
        assert r.status_code == 200 and r.text == CLI_LOG, (case, r.status_code)     # the link the CLI posted opens the log it wrote
    else:
        assert r.status_code == 404, case             # the page would not have found it: that is why the post names the file instead
        assert "/op/" not in out and out.endswith(f"salamander-op-{ID}.log"), out


def test_the_link_check_runs_no_config_command(tmp_path):
    # the config is sourced once, by the CLI (common.sh); the link check reads the default config as text and never runs it again, and never
    # touches it at all when the CLI was pointed at another config
    home = tmp_path / "home"
    (home / ".config" / "salamander").mkdir(parents=True)
    default = home / ".config" / "salamander" / "config"
    base = {"PATH": os.environ["PATH"], "HOME": str(home), "ROOT": str(ROOT), "ID": ID, "LOGTEXT": CLI_LOG,
            "SALA_SESSION_URL": "https://sala.example/#s={name}"}
    marker = 'echo ran >> "$HOME/ran.log"\n'

    def run(cfg: Path):
        return subprocess.run(["bash", "-c", CLI_POST], env={**base, "SALA_CONFIG": str(cfg)}, cwd=tmp_path, capture_output=True, text=True,
                              timeout=60, check=True).stdout.splitlines()[-1]

    default.write_text(marker + "SALA_LOG_DIR=~/moved\n")
    assert run(default).endswith("|log>")
    assert (home / "ran.log").read_text() == "ran\n"                  # once: the CLI's own source of its config, not a second time for the link
    (home / "ran.log").unlink()
    other = tmp_path / "other.conf"
    other.write_text("SALA_LOG_DIR=~/cli-only\n")
    out = run(other)                                                  # the CLI was pointed elsewhere: the default config is not executed at all
    assert not (home / "ran.log").exists() and "/op/" not in out
