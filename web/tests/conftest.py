"""Shared fixtures for the tests that read the rendered page in a headless Chromium.

`served` runs the app on a loopback port (tests only: production listens on a unix socket) with one fake live session
whose pid is this process and a sample transcript; `browser` drives a headless Chromium over --remote-debugging-pipe
(JSON messages, NUL-separated, on fds 3 and 4), so no browser library is needed. A Chromium is looked for on PATH
(chromium, chromium-browser, google-chrome) and in playwright's cache (~/.cache/ms-playwright, chrome-headless-shell);
without one, or when it cannot start here, a test that asks for `browser` is skipped. Nothing here touches a tmux
server: the page is only read, and the fake session points at no pane.
"""

from __future__ import annotations

import atexit
import glob
import json
import os
import re
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

import pytest

# The sala settings the pages read (sala_web.config.sala_setting) are fixed for the whole run, before sala_web is imported: not this
# box's real ~/.config/salamander/config, whatever it sets. The zone is Asia/Dubai (UTC+4 all year, no daylight saving, whole hours)
# because the checks below were written against it (their expected strings carry its label "+04"); a test of another zone or of
# none sets or deletes SALA_TZ itself.
os.environ["SALA_CONFIG"] = "/nonexistent/sala-config-for-tests"
os.environ.pop("SALA_SHELL_SESSION", None)
os.environ["SALA_TZ"] = "Asia/Dubai"
# The scopes are a setting (scopes.py): stackshot's own file under XDG_CONFIG_HOME first, then SALA_SCOPES. Not this box's stackshot
# file, so an empty config home that is removed when the run ends; the scope names the older tests were written against ("example
# beta gamma") are the made-up fleet they assume, set here the way a config line would. test_scopes_brand.py sets its own.
_REAL_XDG_CONFIG_HOME = os.environ.get("XDG_CONFIG_HOME")   # kept for guard_pattern, which reads the owner's deny file
_CONFIG_HOME = tempfile.mkdtemp(prefix="salaweb-test-config-")
atexit.register(shutil.rmtree, _CONFIG_HOME, True)
os.environ["XDG_CONFIG_HOME"] = _CONFIG_HOME
os.environ["SALA_SCOPES"] = "example beta gamma"
os.environ["SALA_DEFAULT_SCOPE"] = "gamma"
os.environ.pop("SALA_BRAND_SUFFIX", None)
# The Get Help chip opens a session named by a setting (config.help_session): a made-up one, as a config line would set it.
os.environ["SALA_HELP_SESSION"] = "help-session"
# The owner's name in the words a form sends (config.owner_name): a made-up one, as a config line would set it. test_owner_name.py sets its own.
os.environ["SALA_OWNER_NAME"] = "Rowan"


class _Guard:
    """What the checks that the shipped page, manifest and units name nobody look for. The same deny data the clean-text check reads
    (.github/scripts/clean_text.py: the CLEAN_TEXT_DENY variable when it holds a pattern, else $XDG_CONFIG_HOME/salamander/clean-text-deny,
    one regex per line), unless SALA_TEST_GUARD_NAMES (names separated by commas) is set, which replaces it. With neither there is
    nothing to look for, and the test that asks skips with that reason. Read on each call, so a module can hold it at import."""

    def __init__(self, flags: int, word: bool):
        self.flags, self.word = flags, word

    def _rules(self) -> "list[re.Pattern[str]]":
        names = [n.strip() for n in os.environ.get("SALA_TEST_GUARD_NAMES", "").split(",") if n.strip()]
        if names:
            edge = r"\b" if self.word else ""
            return [re.compile(edge + "(?:" + "|".join(re.escape(n) for n in names) + ")" + edge, self.flags)]
        import importlib.util
        from pathlib import Path
        script = Path(__file__).resolve().parents[2] / ".github" / "scripts" / "clean_text.py"
        if not script.is_file():
            return []
        spec = importlib.util.spec_from_file_location("clean_text_for_tests", script)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        env = {"CLEAN_TEXT_DENY": os.environ.get("CLEAN_TEXT_DENY", ""), "XDG_CONFIG_HOME": _REAL_XDG_CONFIG_HOME or ""}
        raw, source, _ = mod.local_deny(env)
        return mod.deny_rule(raw, source)

    def search(self, text: str):
        rules = self._rules()
        if not rules:
            import pytest
            pytest.skip("no names to keep out: set SALA_TEST_GUARD_NAMES, CLEAN_TEXT_DENY, or the file salamander/clean-text-deny in the config home")
        for rx in rules:
            m = rx.search(text)
            if m:
                return m
        return None


def guard_pattern(flags: int = 0, word: bool = False) -> _Guard:
    """The names the shipped page, manifest and units must not carry (see _Guard); `.search(text)` as on a compiled pattern."""
    return _Guard(flags, word)


from sala_web import sessions as S
from sala_web import transcript as TR
from sala_web.app import create_app
from sala_web.config import Settings

SID = "aaaaaaaa-0000-4000-8000-000000000001"
NAME = "pytest-fake"
CWD = "/home/alex/work"
ASSISTANT_MD = """Done. Tracked on [board#16](https://board.example.test/items/16).

Bare URL: https://board.example.test/items/134 and www.example.com/x

- a list item with [a link](https://example.com/list)

| what | where |
|---|---|
| item | [board#17](https://board.example.test/items/17) |

**bold [link](https://example.com/bold) inside**

[javascript link](javascript:alert(1)) and <https://example.com/angle>
"""
USER_TEXT = "please look at [board#16](https://board.example.test/items/16) and https://example.com/user"
NOTICE = ("Another Claude session sent a message:\nfrom: demo\n\n"
          "Alex's go on [board#16](https://board.example.test/items/16); see https://example.com/notice too.")


def transcript_line(t: str, content: list, uuid: str, meta: bool = False, model: str | None = None) -> str:
    msg: dict = {"role": t, "content": content}
    if model:
        msg["model"] = model
    d: dict = {"type": t, "uuid": uuid, "timestamp": "2026-10-14T03:00:00.000Z", "message": msg}
    if meta:
        d["isMeta"] = True
    return json.dumps(d) + "\n"


SAMPLE_TRANSCRIPT = (
    transcript_line("user", [{"type": "text", "text": USER_TEXT}], "u-1")
    + transcript_line("assistant", [{"type": "text", "text": ASSISTANT_MD}], "a-1", model="claude-opus-5-5")
    + transcript_line("user", [{"type": "text", "text": NOTICE}], "u-2", meta=True)
    + transcript_line("user", [{"type": "tool_result", "tool_use_id": "t1", "content": "see [x](https://example.com/tool)"}], "u-3"))


@pytest.fixture(autouse=True)
def no_real_board(tmp_path, monkeypatch):
    """Every page polls api/board-items, and Settings() defaults to stackshot's real token and address files: point them
    at files that do not exist, so no test reads the real board (the endpoint answers its plain "no token" error). A
    test of the board itself passes its own paths to Settings."""
    monkeypatch.setenv("SALA_WEB_STACKSHOT_TOKEN", str(tmp_path / "no-stackshot-token"))
    monkeypatch.setenv("SALA_WEB_STACKSHOT_URL", str(tmp_path / "no-stackshot-url"))
    monkeypatch.delenv("STACKSHOT_URL", raising=False)


@pytest.fixture(autouse=True)
def no_real_sala_state(tmp_path, monkeypatch):
    """Settings() defaults to sala's real state directory, where the dormant record (lane-state.tsv) hides a
    lane's card and the New session form's choice: point it at a directory that has none. A test of the record itself
    passes its own sala_state_dir to Settings."""
    monkeypatch.setenv("SALA_WEB_SALA_STATE", str(tmp_path / "no-sala-state"))


@pytest.fixture(autouse=True)
def no_real_sala_command(tmp_path, monkeypatch):
    """The AWS spend card (spend.py) asks sala's lane table whether each lane is set up, on every count the app
    starts: point the sala command at a program that does not exist, so no test runs the real `sala` (the answer is then
    "not known", which the card reads as active). A test of the lane table or of the form sets its own command after this."""
    monkeypatch.setenv("SALA_WEB_SALA_CMD", str(tmp_path / "no-sala"))


@pytest.fixture(autouse=True)
def no_real_stackshot_state(tmp_path, monkeypatch):
    """The Machines tab reads stackshot's state folder, the fleet names and machine-follow's list and records (config.Settings, machines.py):
    point all four at places that do not exist, so no test reads this machine's real ones (the tab then says "No reading yet"). A test of the
    tab passes its own paths to Settings, or sets them on the served app's settings."""
    monkeypatch.setenv("SALA_WEB_STACKSHOT_STATE", str(tmp_path / "no-stackshot-state"))
    monkeypatch.setenv("SALA_WEB_FLEET_NAMES", str(tmp_path / "no-fleet-names.tsv"))
    monkeypatch.setenv("SALA_WEB_MACHINE_FOLLOW_MACHINES", str(tmp_path / "no-machines.toml"))
    monkeypatch.setenv("SALA_WEB_MACHINE_FOLLOW_STATE", str(tmp_path / "no-machine-follow"))


@pytest.fixture(autouse=True)
def no_real_login_dirs(monkeypatch):
    """The Usage analysis tab (usage.py) reads the second login's transcripts too, from sessions.LANE_DIRS, which is built on the real home
    directory: count none of them, so no test reads this machine's transcripts. A test of the tab sets `usage._login_dirs` itself."""
    from sala_web import usage as USG
    monkeypatch.setattr(USG, "_login_dirs", lambda: {})


@pytest.fixture
def served(tmp_path, monkeypatch, request):
    """{"url", "settings", "name"}: the app on 127.0.0.1:<free port>, the fake session NAME with SAMPLE_TRANSCRIPT.
    A test may give the fake session another name, a role, a lane and a status
    (`@pytest.mark.parametrize("served", [{"name": ..., "role": "front", "lane": "subscription-2", "status": "busy"}], indirect=True)`):
    the role comes through a roles command that prints it, the lane by patching proc_lane (the pid is this process's)."""
    import uvicorn

    want = getattr(request, "param", None) or {}
    name = want.get("name", NAME)
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    cwd = CWD
    pid = os.getpid()
    (claude / "sessions" / f"{pid}.json").write_text(json.dumps(
        {"pid": pid, "sessionId": SID, "name": name, "cwd": cwd, "status": want.get("status", "idle"), "tmux": "x:@0.%0",
         "procStart": S.proc_start(pid)}))
    proj = claude / "projects" / TR.project_slug(cwd)
    proj.mkdir(parents=True)
    (proj / f"{SID}.jsonl").write_text(SAMPLE_TRANSCRIPT)
    monkeypatch.setattr(S, "live_tmux_names", lambda: {})  # never the default tmux server's names
    roles_cmd = ["false"]
    if "role" in want:
        roles_cmd = [sys.executable, "-c", f"print({json.dumps({'sessions': {name: {'role': want['role']}}})!r})"]
    if "lane" in want:
        monkeypatch.setattr(S, "proc_lane", lambda _pid, lane=want["lane"]: lane)
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                        tmux_socket_name="salaweb-pytest-none", roles_cmd=roles_cmd, sala_models=tmp_path / "none.tsv",
                        admin_key=tmp_path / "none-key")
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    server = uvicorn.Server(uvicorn.Config(create_app(settings), host="127.0.0.1", port=port, log_level="warning"))
    t = threading.Thread(target=server.run, daemon=True)
    t.start()
    for _ in range(100):
        if server.started:
            break
        time.sleep(0.05)
    assert server.started
    yield {"url": f"http://127.0.0.1:{port}", "settings": settings, "name": name}
    server.should_exit = True
    t.join(timeout=10)


def transcript_file(served: dict):
    """The fake session's transcript: a test writes its own lines there before it opens the page (the stream reads the
    tail when it opens)."""
    return served["settings"].claude_dir / "projects" / TR.project_slug(CWD) / f"{SID}.jsonl"


def chromium_binary() -> str | None:
    for n in ("chromium", "chromium-browser", "google-chrome", "google-chrome-stable"):
        if p := shutil.which(n):
            return p
    shells = sorted(glob.glob(os.path.expanduser(
        "~/.cache/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell")))
    return shells[-1] if shells else None


class CDP:
    """A headless Chromium on --remote-debugging-pipe, one page attached; `send` is a DevTools call on that page."""

    def __init__(self, binary: str, width: int, height: int):
        r_in, w_in = os.pipe()
        r_out, w_out = os.pipe()
        args = [binary, "--headless=new", "--disable-gpu", "--no-sandbox", "--remote-debugging-pipe",
                "--hide-scrollbars", f"--window-size={width},{height}", "about:blank"]
        # A small python puts the pipe ends on 3 and 4 and execs chromium: pass_fds alone leaves them at whatever
        # numbers the parent had free (under pytest, 8 and 11), a sh redirection cannot name a two-digit fd (dash:
        # "Bad fd number"), and os.dup makes non-inheritable fds (PEP 446), so 3 and 4 are made inheritable by hand.
        wrap = ("import os, sys; a = os.dup(int(sys.argv[1])); b = os.dup(int(sys.argv[2])); os.dup2(a, 3); os.dup2(b, 4); "
                "os.set_inheritable(3, True); os.set_inheritable(4, True); os.execv(sys.argv[3], sys.argv[3:])")
        self.p = subprocess.Popen([sys.executable, "-c", wrap, str(r_in), str(w_out), *args],
                                  pass_fds=(r_in, w_out), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL)
        os.close(r_in)
        os.close(w_out)
        self.w, self.r = os.fdopen(w_in, "wb", 0), os.fdopen(r_out, "rb", 0)
        self.seq = 0
        self.buf = b""
        self.events: list[dict] = []   # DevTools events (messages with no id), kept for a test that reads them (test_look_browser.py)
        self.session = None
        self.width, self.height = width, height
        tid = self.call("Target.createTarget", {"url": "about:blank"})["targetId"]
        self.session = self.call("Target.attachToTarget", {"targetId": tid, "flatten": True})["sessionId"]

    def call(self, method: str, params: dict | None = None, session: str | None = None) -> dict:
        self.seq += 1
        msg: dict = {"id": self.seq, "method": method, "params": params or {}}
        if session:
            msg["sessionId"] = session
        self.w.write(json.dumps(msg).encode() + b"\0")
        while True:
            m = self._recv()
            if "id" not in m:
                self.events.append(m)
            if m.get("id") == self.seq:
                if "error" in m:
                    raise RuntimeError(f"{method}: {m['error']}")
                return m.get("result", {})

    def send(self, method: str, params: dict | None = None) -> dict:
        return self.call(method, params, self.session)

    def open(self, url: str, dark: bool = True) -> None:
        # the viewport is set here: --window-size applies to the first window only, not to a created target
        self.send("Emulation.setDeviceMetricsOverride", {"width": self.width, "height": self.height,
                                                         "deviceScaleFactor": 1, "mobile": True})
        if dark:
            self.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": "dark"}]})
        self.send("Page.navigate", {"url": url})

    def touch(self, on: bool = True) -> None:
        """A touch screen: `(pointer: coarse)` matches (the look's 44 px controls) and `(hover: none)`; set on the open page, live."""
        self.send("Emulation.setTouchEmulationEnabled", {"enabled": True, "maxTouchPoints": 1} if on else {"enabled": False})

    def evaluate(self, expression: str, timeout_ms: int = 25000):
        """The value of a JS expression on the page; a promise is awaited."""
        r = self.send("Runtime.evaluate", {"expression": expression, "awaitPromise": True, "returnByValue": True,
                                           "timeout": timeout_ms})
        if "exceptionDetails" in r:
            raise RuntimeError(r["exceptionDetails"].get("text") or str(r["exceptionDetails"]))
        return r["result"].get("value")

    def _recv(self) -> dict:
        while b"\0" not in self.buf:
            if not select.select([self.r], [], [], 30)[0]:
                raise RuntimeError("chromium did not answer within 30 s")
            chunk = self.r.read(65536)
            if not chunk:
                raise RuntimeError("chromium closed the pipe")
            self.buf += chunk
        raw, self.buf = self.buf.split(b"\0", 1)
        return json.loads(raw)

    # How long Chromium gets to exit on its own after Browser.close, and to be reaped after a kill. A loaded runner can take
    # far longer than an idle box to wind down, so the first wait is generous; a slow exit is never a test error.
    EXIT_WAIT = 30
    KILL_WAIT = 10

    def close(self) -> None:
        try:
            try:
                self.call("Browser.close")
            except Exception:
                self.p.kill()
            try:
                self.p.wait(timeout=self.EXIT_WAIT)
            except subprocess.TimeoutExpired:
                self.p.kill()   # this handle only, never a process by name
                self.p.wait(timeout=self.KILL_WAIT)
        finally:
            self.w.close()
            self.r.close()


@pytest.fixture
def browser():
    """A headless Chromium page at a phone's width (390 x 844); skipped when none is installed or it cannot start."""
    binary = chromium_binary()
    if not binary:
        pytest.skip("no headless Chromium (chromium / google-chrome on PATH, or playwright's chrome-headless-shell)")
    try:
        c = CDP(binary, 390, 844)
    except RuntimeError as e:
        pytest.skip(f"{binary} did not start headless here: {e}")
    yield c
    c.close()
