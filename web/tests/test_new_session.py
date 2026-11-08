"""The New session form: the one way the page makes a session, through
sala's operation queue (`web/README.md`, *New session*).

What a wrong answer costs here is a session the owner did not ask for, or one he asked for that never comes: a spawn sent
with another project, role, name or mandate than the form showed; a mandate that reaches sala changed (a Korean text
with quotes, a leading dash, a `$(…)`, read back other than typed); typed text that reaches a shell; a second spawn from a
double tap; a refusal shown as markup; or the queue's own answer (the lines to add to the page, the missing page) lost
on the way to him. Every check guards one of those. Nothing here runs sala or touches tmux: `sala` is a stand-in script
in tmp_path that records its argv and the mandate file's text and answers as the queue does in the mode the test set
(queued, exit 3 with the ADD-TO-PAGE block, exit 4, a refusal, slow, nothing); the project pages are a few files under
a temporary pages checkout; the browser tests run in a headless Chromium when one is installed (conftest.py: `served`,
`browser`), with api/sessions a stub whose list the test extends to make the new session "appear"."""

from __future__ import annotations

import json
import os
import re
import sys
import threading
import time
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

import pytest
from starlette.testclient import TestClient

from sala_web import spawn as SP
from sala_web.app import STATIC, create_app
from sala_web.config import Settings
from fake_stackshot import FakeStackshot
from test_board_items_ui import wait_for, wait_side
from test_composer_attach import WAIT_READY
from test_composer_editable import key, typed

ROOT = STATIC.parent.parent.parent    # web/
INDEX = (STATIC / "index.html").read_text()
APP_JS = (STATIC / "app.js").read_text()
README = (ROOT / "README.md").read_text()
FAKE = "pytest-fake"
OP = "1760500000-4242"
PAGES = {   # key -> (title, kept in the list)
    "projects/gamma-harbor": ("Harbor planning", True),
    "projects/beta-web": ("BETA web", True),
    "projects/stackshot/demo-guide": ("Sessions per project", True),
    "projects/demo": ("demo", True),
}
MANDATE = ('세션입니다.\n- 첫 줄은 대시로 시작합니다\n"따옴표"와 \'작은따옴표\', 백틱 `x`, $(id), ${HOME}, 그리고 탭\t문자.\n'
           "  들여쓴 줄\n\n마지막 줄 (줄바꿈 없음)")
WORDS_RE = re.compile(r"^Rowan, via the sala web form: new (front|back) ([a-z0-9-]+) in (\S+), "
                      r"\d\d:\d\d (Mon|Tue|Wed|Thu|Fri|Sat|Sun) [A-Z][a-z]{2} \d{1,2}(st|nd|rd|th) \+04$")

STUB = r'''#!@@PY@@
"""pytest's stand-in for sala (web/tests/test_new_session.py): records its argv and the mandate file's text next to
itself, answers as sala's queue does in the mode the test set, and queues nothing."""
import json, os, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
def ctl(name, default):
    try:
        with open(os.path.join(HERE, "newsess-" + name), encoding="utf-8") as f:
            return f.read().strip() or default
    except OSError:
        return default
def record(**kw):
    with open(os.path.join(HERE, "newsess-record.jsonl"), "a", encoding="utf-8") as f:
        f.write(json.dumps(kw, ensure_ascii=False) + "\n")
argv = sys.argv[1:]
def opt(flag):
    return argv[argv.index(flag) + 1] if flag in argv else None
if argv[:2] == ["lane", "--json"]:   # the lane a spawn with no --lane gets: read by api/spawn/options, not recorded
    time.sleep(float(ctl("lane-sleep", "0")))   # a slow sala
    print(json.dumps({"default": ctl("lane-default", "subscription-1"), "lanes": []}))
    sys.exit(0)
if argv[:2] == ["spawn", "--suggest-name"]:
    record(argv=argv)
    seq = os.path.join(HERE, "newsess-suggest-seq")   # a test's own answers, one per call (a name that is taken, then a free one)
    if os.path.exists(seq):
        with open(seq, encoding="utf-8") as f:
            lines = [l for l in f.read().splitlines() if l.strip()]
        if lines:
            with open(seq, "w", encoding="utf-8") as f:
                f.write("\n".join(lines[1:]) + "\n")
            print(lines[0].strip())
            sys.exit(0)
    if "--side" in argv:   # a side conversation: <the agent forked from | the project's prefix>-side-<word><nn>
        d, _, slug = (opt("--project") or "").partition("/")
        print((opt("--fork-of") or ("example-" + slug if d == "example" else slug)) + "-side-wren42")
        sys.exit(0)
    d, _, slug = (opt("--project") or "").partition("/")
    prefix = opt("--prefix") or ("example-" + slug if d == "example" else slug).replace("/", "-")
    # as sala's suggestion: -main only for a front agent of a project with no agent yet; else a random word (here the
    # first of four that is not taken). The project's agents are what the fixture wrote from the fake stackshot's rows.
    try:
        with open(os.path.join(HERE, "newsess-agents.json"), encoding="utf-8") as f:
            agents = json.load(f)
    except (OSError, ValueError):
        agents = {}
    mine = agents.get(opt("--project"), [])
    taken = {a for names in agents.values() for a in names}
    if opt("--role") == "front" and not mine and prefix + "-main" not in taken:
        print(prefix + "-main")
    else:
        print(next(prefix + "-" + w for w in ("pink", "plum", "reed", "rust") if prefix + "-" + w not in taken))
    sys.exit(0)
if argv[:2] != ["op", "spawn"]:
    record(argv=argv, unexpected=True)
    sys.stderr.write("stub: unexpected call\n")
    sys.exit(2)
mode = ctl("mode", "ok")
name, project, role = argv[2], opt("--project"), opt("--role")
mandate = None
if opt("--mandate"):
    with open(opt("--mandate"), encoding="utf-8") as f:
        mandate = f.read()
    st = os.stat(opt("--mandate"))
    record(argv=argv, mode=mode, mandate=mandate, mandate_mode=st.st_mode & 0o777)
else:
    record(argv=argv, mode=mode, mandate=None)
if mode == "slow":
    time.sleep(float(ctl("slow", "2.5")))
    mode = "ok"
if mode == "ok":
    ops = os.path.join(HERE, "sala-state", "ops")
    os.makedirs(ops, exist_ok=True)
    with open(os.path.join(ops, "@@OP@@.op"), "w", encoding="utf-8") as f:
        f.write("verb=spawn\nstate=queued\nfrom=sala-web\ntime=1760500000\n" + "".join("arg=%s\n" % a for a in argv[2:]))
    print("plan for spawn %s: all checks passed" % name)
    print("queued op @@OP@@: salamander spawn %s --project %s --role %s" % (name, project, role))
    sys.exit(0)
if mode == "nothing":
    sys.exit(0)
if mode == "exit3":
    print("plan for spawn %s:" % name)
    print("   ✓ page %s exists" % project)
    print("   ✗ %s is not on the page's agents map" % name)
    print("   REGISTER: %s" % project)
    sys.stderr.write("✗ refused: the plan for spawn %s did not pass (exit 3) — nothing queued\n" % name)
    sys.stderr.write("   the page's keeper was asked to register it in one stackshot message (to %s)\n" % project)
    print("REGISTER: %s" % project)
    print("python3 ~/stackshot/stackshot/fleet/client.py post project-agent %s %s --role main %s --mandate \"<one line>\"   # \"quoted\" & <tagged>" % (project, name, "--back" if role == "back" else "--front"))
    sys.exit(3)
if mode == "exit4":
    print("plan for spawn %s:" % name)
    print("   ✗ no page %s" % project)
    sys.stderr.write("✗ refused: the plan for spawn %s did not pass (exit 4) — nothing queued\n" % name)
    print("NO-PAGE: %s" % project)
    sys.exit(4)
print("plan for spawn %s:" % name)
print("   ✓ page %s exists" % project)
print("   ✗ a tmux session named %s is live already <script>alert(1)</script>" % name)
sys.stderr.write("✗ refused: the plan for spawn %s did not pass (exit 1) — nothing queued\n" % name)
sys.exit(1)
'''.replace("@@PY@@", sys.executable).replace("@@OP@@", OP)


class Sala:
    """The stand-in and its files: `mode(m)` picks the answer, `records()` reads what it was called with."""

    def __init__(self, tmp_path):
        self.dir = tmp_path
        self.cmd = tmp_path / "newsess-sala"
        self.cmd.write_text(STUB, encoding="utf-8")
        self.cmd.chmod(0o755)
        self.state = tmp_path / "sala-state"
        self.brain = tmp_path / "brain"
        for k, (title, _) in PAGES.items():
            p = self.brain / f"{k}.md"
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(f"---\ntitle: {title}\ntype: project\n---\n# {title}\n", encoding="utf-8")
        (self.brain / "projects" / "README.md").write_text("# not a page\n")
        (self.brain / "example").mkdir(exist_ok=True)
        (self.brain / "example" / "README.md").write_text("---\ntitle: Example\n---\n")
        (self.brain / "projects" / "old-name.md").write_text("---\ntitle: Old\ntype: redirect\nto: projects/gamma-harbor\n---\n")
        (self.brain / "projects" / "gone.md").write_text("---\ntitle: Gone\ntype: archive\n---\n")
        (self.brain / "projects" / "Bad Name.md").write_text("---\ntitle: Bad\n---\n")
        (self.brain / "notes").mkdir()
        (self.brain / "notes" / "scratch.md").write_text("---\ntitle: Scratch\n---\n")

    def mode(self, m: str, slow: float | None = None) -> None:
        (self.dir / "newsess-mode").write_text(m)
        if slow is not None:
            (self.dir / "newsess-slow").write_text(str(slow))

    def sync_agents(self) -> None:
        """What the stand-in knows of the projects' agents (the fake stackshot's rows), for its `-main` only for a new project rule."""
        (self.dir / "newsess-agents.json").write_text(json.dumps({r["key"]: sorted(r["agents"]) for r in self.ss.rows}))

    def lane_sleep(self, seconds: float) -> None:
        (self.dir / "newsess-lane-sleep").write_text(str(seconds))

    def lane_default(self, lane: str) -> None:
        (self.dir / "newsess-lane-default").write_text(lane)

    def suggestions(self, *names: str) -> None:
        """The next answers of `spawn --suggest-name`, one per call, before the stand-in falls back to <prefix>-main/-helper."""
        (self.dir / "newsess-suggest-seq").write_text("\n".join(names) + "\n")

    def records(self) -> list[dict]:
        p = self.dir / "newsess-record.jsonl"
        return [json.loads(l) for l in p.read_text(encoding="utf-8").splitlines()] if p.exists() else []

    def spawns(self) -> list[dict]:
        return [r for r in self.records() if r["argv"][:2] == ["op", "spawn"]]

    def marker(self, state: str, result: str = "", done: bool = False) -> None:
        d = self.state / "ops" / ("done" if done else "")
        d.mkdir(parents=True, exist_ok=True)
        if done:
            (self.state / "ops" / f"{OP}.op").unlink(missing_ok=True)
        (d / f"{OP}.op").write_text(f"verb=spawn\nstate={state}\nresult={result}\nfrom=sala-web\ntime=1760500000\narg=x\n")

    def settings_kw(self) -> dict:
        return {"sala_cmd": [str(self.cmd)], "sala_state_dir": self.state, "brain_dir": self.brain, "page_dirs": ["projects", "example"]}


@pytest.fixture
def sala(tmp_path, monkeypatch) -> Sala:
    """The stand-in, and the environment that makes conftest's `served` (which builds its own Settings) use it. Stackshot's
    project API is a fake on 127.0.0.1 (fake_stackshot.py; `sala.ss`), reached through the token and address files the app
    reads, so no test touches the real stackshot or a gbrain."""
    s = Sala(tmp_path)
    s.ss = FakeStackshot(tmp_path / "stackshot-cfg")
    s.sync_agents()
    monkeypatch.setenv("SALA_WEB_SALA_CMD", str(s.cmd))
    monkeypatch.setenv("SALA_WEB_SALA_STATE", str(s.state))
    monkeypatch.setenv("SALA_WEB_BRAIN_DIR", str(s.brain))
    monkeypatch.setenv("SALA_WEB_PAGE_DIRS", "projects example")
    monkeypatch.setenv("SALA_WEB_STACKSHOT_TOKEN", str(s.ss.token_file))
    monkeypatch.setenv("SALA_WEB_STACKSHOT_URL", str(s.ss.url_file))
    yield s
    s.ss.close()


@pytest.fixture
def env(sala, tmp_path):
    """A TestClient on the app with the stand-in (no browser)."""
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    (claude / "projects").mkdir()
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                        tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"], **sala.settings_kw())
    return {"client": TestClient(create_app(settings)), "settings": settings, "sala": sala, "ss": sala.ss}


GOOD = {"project": "projects/gamma-harbor", "role": "front", "name": "gamma-harbor-main"}


# ── the server ───────────────────────────────────────────────────────────────
def test_options_list_the_project_pages_and_what_the_form_offers(env):
    r = env["client"].get("/api/spawn/options")
    assert r.status_code == 200 and r.headers["cache-control"] == "no-store"
    o = r.json()
    # every page under the page dirs, nested too, sorted by key; a README, a redirect or archive stub, a file outside the
    # dirs and a name that is no key are left out (pages.py's read_pages leaves them out as well)
    assert o["projects"] == [{"key": k, "title": t} for k, (t, _) in sorted(PAGES.items())]
    assert o["dirs"] == ["projects", "example"] and o["lanes"] == ["subscription-1", "subscription-2", "api", "bedrock", "aws-platform"]   # sdk is not spawned
    assert o["efforts"] == ["low", "medium", "high", "xhigh", "max"] and o["nameMax"] == 48 and o["mandateMax"] == 20480
    assert o["error"] is None


def test_options_carry_the_models_and_what_use_default_resolves_to(env):
    """the form says "use default (<value>)" with the real values: the lane `sala lane` launches on, and the model
    and effort of the lane's settings.json (the reader's unit tests are below)."""
    c, s = env["client"], env["sala"]
    o = c.get("/api/spawn/options").json()
    assert o["models"] == ["opus", "sonnet", "haiku", "fable"] and o["defaults"]["lane"] == "subscription-1" and o["defaults"]["model"] == "" and o["defaults"]["effort"] == "", o
    s.lane_default("subscription-2")
    (env["settings"].claude_dir / "settings.json").write_text(json.dumps({"model": "opus[1m]", "effortLevel": "xhigh"}))
    d = c.get("/api/spawn/options").json()["defaults"]
    assert d == {"lane": "subscription-2", "model": "opus[1m]", "effort": "xhigh"}, d
    assert not [r for r in s.records() if r["argv"][:1] == ["lane"]]   # the lane question is not an unexpected call


def test_a_slow_sala_does_not_hold_the_options_for_long(env):
    """`sala lane --json` is asked together with the project list and cut at a few seconds: a sala that takes 12 s leaves the lane's
    "use default" without a value, and the options still come (they used to wait the 15 s of the lanes endpoint)."""
    import time as _t

    env["sala"].lane_sleep(12)
    t0 = _t.time()
    r = env["client"].get("/api/spawn/options")
    took = _t.time() - t0
    assert r.status_code == 200 and r.json()["defaults"]["lane"] == "" and r.json()["lanes"], r.text[:300]
    assert took < 8, took


def test_claude_defaults_reads_the_model_and_the_effort_of_settings(tmp_path):
    def read(doc) -> dict:
        (tmp_path / "settings.json").write_text(doc if isinstance(doc, str) else json.dumps(doc))
        return SP.claude_defaults(tmp_path)
    assert SP.claude_defaults(tmp_path / "nowhere") == {"model": "", "effort": ""}
    assert read("{not json") == {"model": "", "effort": ""}
    assert read([1]) == {"model": "", "effort": ""}
    assert read({"model": "opus", "effortLevel": "high"}) == {"model": "opus", "effort": "high"}
    # the effort the model's own setting names beats the top-level one
    assert read({"model": "claude-opus-5-5", "effortLevel": "high", "modelSettings": {"claude-opus-5-5": {"effortLevel": "max"}}}) == \
        {"model": "claude-opus-5-5", "effort": "max"}
    # a value that is no plain word (it will be printed in the form) is left out
    assert read({"model": "opus; id", "effortLevel": "<b>"}) == {"model": "", "effort": ""}
    assert read({"model": 5, "effortLevel": ["x"]}) == {"model": "", "effort": ""}


def test_options_without_a_pages_checkout_say_so(sala, tmp_path):
    (tmp_path / "claude" / "sessions").mkdir(parents=True)
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=tmp_path / "claude",
                        tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"], **{**sala.settings_kw(), "brain_dir": tmp_path / "nowhere"})
    o = TestClient(create_app(settings)).get("/api/spawn/options").json()
    assert o["projects"] == [] and "nowhere" in o["error"]


def test_the_suggested_name_comes_from_sala(env):
    c = env["client"]
    # -main only for a project with no agent yet; gamma-harbor and projects/demo have theirs, so a random word follows the prefix
    assert c.get("/api/spawn/suggest", params={"project": "projects/gamma-harbor", "role": "front"}).json() == {"name": "gamma-harbor-pink"}
    assert c.get("/api/spawn/suggest", params={"project": "projects/demo", "role": "back"}).json() == {"name": "demo-pink"}
    assert env["sala"].records()[-1]["argv"] == ["spawn", "--suggest-name", "--project", "projects/demo", "--role", "back"]
    # the page's own prefix (the project's real one, wiki and not a scope-derived one) is passed on, and checked here
    assert c.get("/api/spawn/suggest", params={"project": "projects/gbrain", "role": "front", "prefix": "wiki"}).json() == {"name": "wiki-main"}
    assert env["sala"].records()[-1]["argv"] == ["spawn", "--suggest-name", "--project", "projects/gbrain", "--role", "front", "--prefix", "wiki"]
    for bad in ("Example", "example-", "-example", "a b", "x;id", "a" * 60):
        assert c.get("/api/spawn/suggest", params={"project": "projects/gbrain", "role": "front", "prefix": bad}).status_code == 400, bad
    n = len(env["sala"].records())
    assert c.get("/api/spawn/suggest", params={"project": "gamma-harbor", "role": "front"}).status_code == 400
    assert c.get("/api/spawn/suggest", params={"project": "projects/x", "role": "main"}).status_code == 400
    assert c.get("/api/spawn/suggest", params={"project": "projects/x;id", "role": "front"}).status_code == 400
    assert len(env["sala"].records()) == n   # a bad shape never reaches sala


@pytest.mark.parametrize("body, status", [
    ([1, 2], 400),
    ({**GOOD, "name": "Solo-Main"}, 400),
    ({**GOOD, "name": "-main"}, 400),
    ({**GOOD, "name": "main-"}, 400),
    ({**GOOD, "name": "a b"}, 400),
    ({**GOOD, "name": "x" * 49}, 400),
    ({**GOOD, "name": ""}, 400),
    ({**GOOD, "project": "gamma-harbor"}, 400),
    ({**GOOD, "project": "notes/x"}, 400),
    ({**GOOD, "project": "projects/Ab"}, 400),
    ({**GOOD, "project": "projects/x/"}, 400),
    ({**GOOD, "project": "projects/../etc"}, 400),
    ({**GOOD, "role": "main"}, 400),
    ({**GOOD, "role": "back"}, 400),                       # a background agent without a mandate
    ({**GOOD, "role": "back", "mandate": "  \n "}, 400),
    ({**GOOD, "effort": "ultra"}, 400),
    ({**GOOD, "lane": "sdk"}, 400),
    ({**GOOD, "lane": "max; id"}, 400),
    ({**GOOD, "model": "opus; rm -rf /"}, 400),
    ({**GOOD, "model": "opus 5"}, 400),
    ({**GOOD, "name": ["x"]}, 400),
    ({**GOOD, "cwd": "/tmp"}, 400),                        # a field the form does not have
    ({**GOOD, "mandate": "x" * (20 * 1024 + 1)}, 413),
])
def test_a_bad_field_is_refused_here_and_never_reaches_sala(env, body, status):
    r = env["client"].post("/api/spawn", json=body)
    assert r.status_code == status, r.text
    assert r.json()["ok"] is False and r.json()["error"]
    assert env["sala"].spawns() == []
    assert not (env["settings"].mandates_dir.exists() and list(env["settings"].mandates_dir.iterdir()))


def test_cross_origin_wrong_content_type_and_a_huge_body_are_refused_like_every_post(env):
    c = env["client"]
    assert c.post("/api/spawn", json=GOOD, headers={"Origin": "https://evil.example"}).status_code == 403
    assert c.post("/api/spawn", json=GOOD, headers={"Origin": "null"}).status_code == 403
    assert c.post("/api/spawn", content=json.dumps(GOOD).encode(), headers={"Content-Type": "text/plain"}).status_code == 415
    assert c.get("/api/spawn").status_code == 405
    assert c.post("/api/spawn", content=b"{" + b" " * (64 * 1024) + b"}", headers={"Content-Type": "application/json"}).status_code == 413
    assert c.post("/api/spawn", content=b"{not json", headers={"Content-Type": "application/json"}).status_code == 400
    assert env["sala"].spawns() == []
    # the same origin as the Host is fine
    r = c.post("/api/spawn", json=GOOD, headers={"Origin": "http://testserver"})
    assert r.status_code == 202, r.text


def test_the_argv_and_the_mandate_file_carry_what_the_form_sent(env):
    c, s = env["client"], env["sala"]
    body = {"project": "projects/gamma-harbor", "role": "back", "name": "gamma-harbor-helper", "mandate": MANDATE,
            "lane": "subscription-2", "model": "claude-opus-5-5", "effort": "high"}
    r = c.post("/api/spawn", json=body)
    assert r.status_code == 202, r.text
    assert r.json() == {"ok": True, "op": OP, "name": "gamma-harbor-helper", "project": "projects/gamma-harbor", "role": "back",
                        "output": r.json()["output"]}
    assert f"queued op {OP}" in r.json()["output"]
    (rec,) = s.spawns()
    argv = rec["argv"]
    path = argv[argv.index("--mandate") + 1]
    # one argv list, every option in its place, the mandate as a file path, the words last
    assert argv == ["op", "spawn", "gamma-harbor-helper", "--project", "projects/gamma-harbor", "--role", "back", "--mandate", path,
                    "--lane", "subscription-2", "--model", "claude-opus-5-5", "--effort", "high", "--from", "sala-web", "--words", argv[-1]]
    m = WORDS_RE.match(argv[-1])
    assert m and m.groups()[:3] == ("back", "gamma-harbor-helper", "projects/gamma-harbor"), argv[-1]
    # the mandate: the typed text byte for byte (plus a file's final newline), 0600, under state_dir/mandates/, and kept
    # after a queued spawn (the session reads it at its first prompt, after the operation has ended)
    assert rec["mandate"] == MANDATE + "\n" and rec["mandate_mode"] == 0o600
    mfile = env["settings"].mandates_dir / os.path.basename(path)
    assert os.path.dirname(path) == str(env["settings"].mandates_dir) and mfile.exists()
    assert SP.MANDATE_RE.match(mfile.name) and mfile.name.endswith("-gamma-harbor-helper.md")
    assert mfile.read_text(encoding="utf-8") == MANDATE + "\n"
    # the folded options left empty are not sent, and a front agent needs no mandate: the argv has none of them
    r = c.post("/api/spawn", json={**GOOD, "mandate": "", "lane": "", "model": "", "effort": ""})
    assert r.status_code == 202, r.text
    argv = s.spawns()[-1]["argv"]
    assert argv == ["op", "spawn", "gamma-harbor-main", "--project", "projects/gamma-harbor", "--role", "front", "--from", "sala-web", "--words", argv[-1]]
    assert s.spawns()[-1]["mandate"] is None
    # CRLF from a browser arrives as LF
    r = c.post("/api/spawn", json={**GOOD, "mandate": "a\r\nb\rc"})
    assert r.status_code == 202 and s.spawns()[-1]["mandate"] == "a\nb\nc\n"


def test_what_the_queue_answers_reaches_the_page_as_it_is(env, monkeypatch):
    c, s = env["client"], env["sala"]
    body = {**GOOD, "mandate": "x"}
    s.mode("exit3")
    r = c.post("/api/spawn", json=body)
    assert r.status_code == 409, r.text
    d = r.json()
    assert d["ok"] is False and d["code"] == "not-listed" and d["page"] == "projects/gamma-harbor" and d["name"] == "gamma-harbor-main"
    # the block: from the unindented marker line to the end, exactly (the indented copy in the plan is not it)
    assert d["block"] == ("REGISTER: projects/gamma-harbor\n"
                          "python3 ~/stackshot/stackshot/fleet/client.py post project-agent projects/gamma-harbor gamma-harbor-main --role main --front --mandate \"<one line>\"   # \"quoted\" & <tagged>")
    assert "ADD-TO-PAGE" not in d["block"] and "agents:" not in d["block"]
    assert d["keeper"] == "the page's keeper was asked to register it in one stackshot message (to projects/gamma-harbor)"
    assert "✗ refused" in d["error"] and "not on the page's agents map" in d["error"]
    s.mode("exit4")
    d = c.post("/api/spawn", json=body).json()
    assert d["code"] == "no-page" and d["page"] == "projects/gamma-harbor" and "no page" in d["error"]
    s.mode("refuse")
    r = c.post("/api/spawn", json=body)
    assert r.status_code == 409 and r.json()["code"] == "refused" and r.json()["exit"] == 1
    assert "<script>alert(1)</script>" in r.json()["error"] and "✗ refused" in r.json()["error"]
    s.mode("nothing")
    r = c.post("/api/spawn", json=body)
    assert r.status_code == 502 and r.json()["code"] == "error" and "queued op" in r.json()["error"]
    # too slow: the process is stopped, 502
    monkeypatch.setattr(SP, "QUEUE_TIMEOUT", 0.5)
    s.mode("slow", slow=5)
    t0 = time.time()
    r = c.post("/api/spawn", json=body)
    assert r.status_code == 502 and "did not finish" in r.json()["error"] and time.time() - t0 < 4, r.text
    # a refused, failed or late spawn leaves no mandate file behind; five were written, none stays
    assert len(s.spawns()) == 5
    assert not list(env["settings"].mandates_dir.iterdir())
    # sala missing altogether
    monkeypatch.setattr(SP, "QUEUE_TIMEOUT", 90.0)
    settings = Settings(socket=s.dir / "s2.sock", state_dir=s.dir / "state2", claude_dir=env["settings"].claude_dir,
                        tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"], **{**s.settings_kw(), "sala_cmd": [str(s.dir / "no-such-sala")]})
    r = TestClient(create_app(settings)).post("/api/spawn", json=body)
    assert r.status_code == 502 and r.json()["code"] == "error" and "could not run sala" in r.json()["error"]


def test_one_spawn_in_flight_at_a_time(env):
    c, s = env["client"], env["sala"]
    s.mode("slow", slow=1.5)
    first: list = []
    t = threading.Thread(target=lambda: first.append(c.post("/api/spawn", json=GOOD)))
    t.start()
    time.sleep(0.5)   # the first is inside the queue call (the stand-in sleeps 1.5 s)
    second = c.post("/api/spawn", json={**GOOD, "name": "gamma-harbor-other"})
    t.join(timeout=10)
    assert second.status_code == 409 and second.json()["code"] == "busy", second.text
    assert first and first[0].status_code == 202, first and first[0].text
    assert [r["argv"][2] for r in s.spawns()] == ["gamma-harbor-main"]   # the second never ran


def test_the_operation_state_is_read_from_the_marker(env):
    c, s = env["client"], env["sala"]
    assert c.get("/api/spawn/status", params={"op": OP}).status_code == 404
    for bad in ("", "abc", "1-", "../x", "1760500000-4242/..", "1" * 13 + "-1"):
        assert c.get("/api/spawn/status", params={"op": bad}).status_code == 400, bad
    (s.state / "ops").mkdir(parents=True)
    (s.state / "ops" / f"{OP}.op").write_text("verb=spawn\nstate=running\nfrom=sala-web\ntime=1760500000\nstarted=1760500003\n"
                                              "arg=gamma-x\narg=--project\narg=projects/ab\narg=--words\narg=a=b=c\nresult=\n")
    r = c.get("/api/spawn/status", params={"op": OP})
    assert r.status_code == 200 and r.headers["cache-control"] == "no-store"
    assert r.json() == {"op": OP, "state": "running", "result": "", "args": ["gamma-x", "--project", "projects/ab", "--words", "a=b=c"],
                        "verb": "spawn", "from": "sala-web", "time": "1760500000", "started": "1760500003"}
    s.marker("stuck", "the lane cannot launch", done=True)
    d = c.get("/api/spawn/status", params={"op": OP}).json()
    assert d["state"] == "stuck" and d["result"] == "the lane cannot launch"


DUBAI = ZoneInfo("Asia/Dubai")


def test_the_words_and_the_stamp():
    """The stamp is in the SALA_TZ zone (conftest sets Asia/Dubai) and carries the zone's own label."""
    assert SP.zone_stamp(datetime(2026, 10, 15, 5, 5, tzinfo=timezone.utc)) == "09:05 Thu Oct 15th +04"
    assert SP.words_for("back", "gamma-x-helper", "projects/gamma-x", datetime(2026, 10, 15, 23, 59, tzinfo=DUBAI)) == \
        "Rowan, via the sala web form: new back gamma-x-helper in projects/gamma-x, 23:59 Thu Oct 15th +04"
    suffix = {d: SP.zone_stamp(datetime(2026, 10, d, 12, 0, tzinfo=DUBAI)).rsplit(" ", 1)[0][-4:].strip()[len(str(d)):] for d in range(1, 32)}
    assert {d: s for d, s in suffix.items() if s != "th"} == {1: "st", 2: "nd", 3: "rd", 21: "st", 22: "nd", 23: "rd", 31: "st"}


def test_the_stamp_follows_SALA_TZ_and_says_the_zone_it_is_in(monkeypatch):
    """No zone is built in: Europe/Berlin gives Berlin's time and its own label (CEST in October), and unset gives the
    machine's local time (TZ), labelled by it, not Asia/Dubai."""
    moment = datetime(2026, 10, 15, 5, 5, tzinfo=timezone.utc)
    monkeypatch.setenv("SALA_TZ", "Europe/Berlin")
    assert SP.zone_stamp(moment) == "07:05 Thu Oct 15th CEST"
    monkeypatch.delenv("SALA_TZ")
    monkeypatch.setenv("TZ", "America/Los_Angeles")
    assert SP.zone_stamp(moment) == "22:05 Wed Oct 14th PDT"
    assert "+04" not in SP.words_for("front", "gamma-x-main", "projects/gamma-x", moment)


def test_old_mandate_files_are_pruned_with_the_uploads(tmp_path):
    d = tmp_path / "mandates"
    d.mkdir()
    old, new, other = d / f"{'a' * 16}-gamma-x.md", d / f"{'b' * 16}-gamma-y.md", d / "keep.txt"
    for p in (old, new, other):
        p.write_text("x")
    long_ago = time.time() - 31 * 86400
    os.utime(old, (long_ago, long_ago))
    os.utime(other, (long_ago, long_ago))
    SP.prune_mandates(d, 30)
    assert not old.exists() and new.exists() and other.exists()   # only the form's own files, only the old ones


# ── the page ─────────────────────────────────────────────────────────────────
def test_the_markup_and_the_rules_the_code_keeps():
    top = INDEX[INDEX.index('<nav class="side-top"'):INDEX.index("</nav>", INDEX.index('<nav class="side-top"'))]
    assert top.index('id="side-new"') < top.index('id="side-ovw"')   # New session above the Overview, above the list
    assert re.search(r'<a id="side-new"[^>]*href="#new"', top) and "aria-haspopup" not in top and "new-sheet" not in INDEX   # a link to a page of its own, no dialog
    assert re.search(r'<section id="new-pane" class="pane"', INDEX) and 'new-scrim' not in INDEX and 'new-sheet' not in APP_JS
    assert '<form id="ns-form" class="np ns-form" novalidate' in INDEX
    assert '<textarea id="ns-mandate"' in INDEX and '<button id="ns-submit" class="ns-submit" type="submit" disabled>' in INDEX
    assert re.search(r'<input type="radio" name="ns-role" value="front" checked>', INDEX)
    section = APP_JS[APP_JS.index("/* ---------- new session"):APP_JS.index("/* ---------- selection, hash")]
    assert ".innerHTML" not in section and "insertAdjacentHTML" not in section   # the queue's words are shown as text only
    assert 'nsEl.mandate.addEventListener("keydown"' not in section            # Enter and Tab in the mandate stay the browser's
    assert 'nsPost("api/spawn", ' in section and 'fetch(url, { method: "POST"' in section   # every step is a POST that is never repeated on its own
    assert "ADD-TO-PAGE" not in section and "ns-copy" not in section and "ns-copy" not in INDEX   # the block is never shown or used again
    assert 'id="ns-scopes"' in INDEX and 'id="ns-picked"' in INDEX and 'id="ns-newproj"' not in INDEX and 'id="ns-newslug"' not in INDEX
    assert "It never creates, kills" not in README and "New session form" in README


def stub(pid: int) -> str:
    """api/sessions: the fake session plus whatever names the test puts in window.__names (a session the queue "made");
    api/board-items: nothing; the clipboard: window.__copied."""
    return """(() => {
  const real = window.fetch.bind(window), json = (o) => new Response(JSON.stringify(o), { headers: { "Content-Type": "application/json" } });
  window.__names = []; window.__copied = null; window.__items = {};   // __items: api/board-items' sessions ({name: {items: [{id, subject}]}})
  const sess = (n, pid) => ({ pid, sessionId: n, name: n, cwd: "/x", status: "idle", tmux: "x:@0.%%0", tmuxSession: n, paneId: "%%0",
                              role: "front", project: "projects/demo", lane: "subscription-1", updatedAt: null, startedAt: null });
  window.fetch = (url, opts) => {
    const u = String(url);
    if (u.startsWith("api/sessions")) {
      const groups = [{ key: "projects/demo", title: "demo", scope: "example", sessions: [sess(%r, %d), ...window.__names.map((n) => sess(n, 1))] }];
      return Promise.resolve(json({ scopes: [{ key: "example", title: "example", groups }], groups, rolesError: null }));
    }
    if (u.startsWith("api/board-items")) return Promise.resolve(json({ sessions: window.__items, fetchedAt: Date.now() }));
    return real(url, opts);
  };
  Object.defineProperty(navigator, "clipboard", { value: { writeText: (t) => { window.__copied = t; return Promise.resolve(); } }, configurable: true });
})();""" % (FAKE, pid)


NS = """(() => {
  const q = (s) => document.querySelector(s), d = q("#new-pane"), f = q("#ns-form"), r = d.getBoundingClientRect(), t = (e) => (e ? e.textContent : null);
  const vw = document.documentElement.clientWidth, vh = (visualViewport && visualViewport.height) || innerHeight;
  const open = document.body.classList.contains("new-open") && getComputedStyle(d).display !== "none";
  return { hidden: !open, open, box: r.toJSON(), vw, vh,
    docScroll: document.documentElement.scrollWidth, bodyScroll: document.body.scrollWidth, formScroll: f.scrollWidth, formClient: f.clientWidth,
    formScrollH: f.scrollHeight, formClientH: f.clientHeight, docScrollH: document.documentElement.scrollHeight, docClientH: document.documentElement.clientHeight,
    current: q("#side-new").getAttribute("aria-current"), active: document.activeElement && document.activeElement.id,
    newBox: q("#side-new").getBoundingClientRect().toJSON(), ovwBox: q("#side-ovw").getBoundingClientRect().toJSON(),
    rows: [...q("#ns-projects").querySelectorAll(".ns-opt")].map((b) => ({ key: b.dataset.key, text: b.textContent, sel: b.getAttribute("aria-selected"),
      isNew: b.classList.contains("ns-new"), h: b.getBoundingClientRect().height })),
    empty: t(q("#ns-projects .ns-empty")), name: q("#ns-name").value, nameErr: t(q("#ns-name-err")),
    role: (q('input[name="ns-role"]:checked') || {}).value, mandate: q("#ns-mandate").value, mandateHint: t(q("#ns-mandate-hint")),
    mandateErr: t(q("#ns-mandate-err")), submitDisabled: q("#ns-submit").disabled, submitText: t(q("#ns-submit")), pending: !q("#ns-pending").hidden,
    status: q("#ns-status").innerText, scriptInStatus: !!q("#ns-status script"), state: t(q("#ns-status .ns-state")) || "",
    pre: t(q("#ns-status pre")), link: q("#ns-status a.ns-link") ? q("#ns-status a.ns-link").getAttribute("href") : null,
    picked: t(q("#ns-picked")), scopes: [...document.querySelectorAll("#ns-scopes .ns-chip")].map((b) => ({ scope: b.dataset.scope, on: b.getAttribute("aria-checked"), h: b.getBoundingClientRect().height })),
    divider: t(q("#ns-projects .ns-divider")), busy: q("#ns-projects").getAttribute("aria-busy"),
    order: [...q("#ns-projects").children].map((c) => (c.classList.contains("ns-divider") ? "--divider--" : c.dataset.key || "(empty)")),
    disabledRows: [...q("#ns-projects").querySelectorAll(".ns-opt[disabled]")].map((b) => b.dataset.key),
    steps: [...document.querySelectorAll("#ns-status .ns-step")].map((s) => s.textContent),
    lanes: [...q("#ns-lane").options].map((o) => o.value + "=" + o.textContent), efforts: [...q("#ns-effort").options].map((o) => o.value + "=" + o.textContent),
    models: [...q("#ns-model").options].map((o) => o.value + "=" + o.textContent), modelOtherHidden: q("#ns-model-other").hidden,
    hash: location.hash, sideOpen: document.body.classList.contains("side-open") };
})()"""
ROWS_LOADED = "document.querySelector('#ns-projects').getAttribute('aria-busy') === 'false'"
# The lanes, models and efforts (and what "use default" resolves to) come from api/spawn/options, a request of its own that
# also waits for `sala lane --json`; the project list does not wait for it, so the rows can be in a while before it. The page
# draws the options when they arrive (nsLoadOptions -> nsFillFixed); until then the three selects hold "use default" alone.
OPTIONS_LOADED = "document.querySelector('#ns-lane').options.length > 1"


def open_page(browser, served, width=390, height=844, dark=True) -> None:
    browser.send("Page.enable")
    browser.send("Page.addScriptToEvaluateOnNewDocument", {"source": stub(os.getpid())})
    browser.width, browser.height = width, height
    browser.open(f"{served['url']}/#s={FAKE}", dark=dark)
    assert browser.evaluate(WAIT_READY)
    if width <= 760:
        click(browser, "#side-open")
        wait_side(browser)


def click(browser, sel: str) -> None:
    browser.evaluate(f"document.querySelector({json.dumps(sel)}).click(); ''")


def ns(browser) -> dict:
    return browser.evaluate(NS)


def open_form(browser, served, width=1280, height=800, dark=True, scope="gamma") -> dict:
    """The form open on `scope` (the fake session is in example, so that is what it opens on; another scope is a chip click)."""
    open_page(browser, served, width, height, dark)
    click(browser, "#side-new")
    assert wait_for(browser, ROWS_LOADED, 10.0), ns(browser)
    assert wait_for(browser, OPTIONS_LOADED, 10.0), ns(browser)
    if scope:
        set_scope(browser, scope)
    return ns(browser)


def set_scope(browser, scope: str) -> None:
    if not browser.evaluate(f"document.querySelector('#ns-scopes .ns-chip[data-scope={scope}]').getAttribute('aria-checked') === 'true'"):
        click(browser, f"#ns-scopes .ns-chip[data-scope={scope}]")
    assert wait_for(browser, ROWS_LOADED, 10.0), ns(browser)


def pick(browser, key_: str) -> None:
    click(browser, f'#ns-projects .ns-opt[data-key="{key_}"]')


def unfold(browser) -> None:
    """The project box open: once a project is chosen it folds to one line, and the arrow opens it, as a person does."""
    browser.evaluate("(() => { const s = document.querySelector('#ns-summary'); if (!s.hidden && s.getAttribute('aria-expanded') === 'false') s.click(); return '' })()")


def set_value(browser, sel: str, value: str) -> None:
    """Typed text through the browser's own insertion (a focus, then Input.insertText), so the page's input handlers run."""
    browser.evaluate(f"(() => {{ const e = document.querySelector({json.dumps(sel)}); e.focus(); e.select && e.select(); return '' }})()")
    browser.send("Input.insertText", {"text": value})


STATE_WORDS = {"queued": "Queued", "starting": "Starting the session", "ready": "Ready", "failed": "Did not start"}   # the headline of a queued session


def wait_state(browser, prefix: str, timeout: float = 10.0) -> dict:
    """Wait for the status headline to end with `prefix`; a queued session's stage may be given as queued, starting, ready or failed."""
    head, sep, last = prefix.rpartition(": ")
    prefix = head + sep + STATE_WORDS.get(last, last)
    assert wait_for(browser, f"(document.querySelector('#ns-status .ns-state') || {{}}).textContent?.endsWith({json.dumps(prefix)})", timeout), ns(browser)
    return ns(browser)


def escape(browser) -> None:
    key(browser, "Escape", "Escape", 27)


def open_more(browser) -> None:
    """Unfold "Lane, model, effort" (a closed <details> cannot take the focus or typed text)."""
    browser.evaluate("document.querySelector('#ns-form details').open = true; ''")


def test_the_button_opens_a_page_in_the_main_area_at_phone_and_desktop_widths(sala, served, browser):
    # a phone: the sidebar's first row, above the Overview, a link to #new; a tap closes the drawer and the page fills the
    # main area (under the title bar, the whole width), the chat and the composer gone; no keyboard pops up
    open_page(browser, served)
    g = ns(browser)
    assert g["hidden"] and g["current"] is None and g["newBox"]["bottom"] <= g["ovwBox"]["top"] + 1 and g["newBox"]["height"] >= 30, g
    assert browser.evaluate("document.querySelector('#side-new').getAttribute('href')") == "#new"
    click(browser, "#side-new")
    assert wait_for(browser, "document.body.classList.contains('new-open') && !nav.busy", 5.0), ns(browser)
    g = ns(browser)
    assert g["open"] and g["current"] == "page" and g["hash"] == "#new" and g["active"] == "new-pane", g
    assert g["box"]["left"] <= 1 and g["box"]["width"] >= g["vw"] - 2 and abs(g["box"]["bottom"] - g["vh"]) <= 1 and g["box"]["top"] > 0, g   # the main area: below the title bar
    assert g["docScroll"] <= g["vw"] and g["bodyScroll"] <= g["vw"] and g["formScroll"] <= g["formClient"], g
    assert g["role"] == "front" and g["submitDisabled"] and not g["sideOpen"], g
    assert browser.evaluate("getComputedStyle(document.querySelector('#composer')).display") == "none"
    assert browser.evaluate("document.querySelector('#title .name').textContent") == "New session"
    assert wait_for(browser, ROWS_LOADED, 10.0)
    # 320: still no sideways scroll
    browser.send("Emulation.setDeviceMetricsOverride", {"width": 320, "height": 700, "deviceScaleFactor": 1, "mobile": True})
    g = ns(browser)
    assert g["open"] and g["vw"] == 320 and g["docScroll"] <= 320 and g["bodyScroll"] <= 320 and g["formScroll"] <= g["formClient"], g
    # a desktop: the page sits right of nothing (the sidebar is over the page and closed), the filter box takes the focus
    browser.send("Emulation.setDeviceMetricsOverride", {"width": 1280, "height": 800, "deviceScaleFactor": 1, "mobile": False})
    browser.evaluate("new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))")
    click(browser, "#side-ovw")
    assert wait_for(browser, "document.body.classList.contains('overview-open') && !nav.busy", 5.0)
    assert ns(browser)["hidden"] and ns(browser)["current"] is None
    click(browser, "#side-new")
    assert wait_for(browser, "document.body.classList.contains('new-open') && !nav.busy", 5.0)
    g = ns(browser)
    assert g["open"] and g["active"] == "ns-filter" and g["vw"] == 1280 and g["box"]["width"] >= 1200, g
    assert g["docScroll"] <= 1280, g
    # the sidebar's rows stay usable beside the page: a session row leaves it
    click(browser, "#side-ovw")
    assert wait_for(browser, "!document.body.classList.contains('new-open') && !nav.busy", 5.0)


def test_back_returns_from_the_page_and_the_link_opens_it_again(sala, served, browser):
    """The page is a view with a link of its own (README, *Back*): in every mode opening it is an entry, so Back returns to
    the view it was opened from; opened from the drawer on a phone, one Back leaves the page for that view (the drawer's own
    entry was walked back over first); a reload on the link opens the page."""
    open_page(browser, served, width=1280, height=800)
    h0 = browser.evaluate("history.length")
    click(browser, "#side-new")
    assert wait_for(browser, "document.body.classList.contains('new-open') && !nav.busy", 5.0), ns(browser)
    assert browser.evaluate("location.hash") == "#new" and browser.evaluate("history.length") == h0 + 1
    assert browser.evaluate("history.state.sala.layers") == []
    browser.evaluate("history.back(); ''")
    assert wait_for(browser, "!document.body.classList.contains('new-open') && !nav.busy", 5.0), ns(browser)
    assert browser.evaluate("location.hash") == f"#s={FAKE}" and browser.evaluate("state.selected") == FAKE
    # Forward is the page again
    browser.evaluate("history.forward(); ''")
    assert wait_for(browser, "document.body.classList.contains('new-open') && !nav.busy", 5.0), ns(browser)
    # a reload on the link opens the page (nothing else is recorded: no layer to walk back over)
    browser.send("Page.reload")
    assert wait_for(browser, WAIT_READY, 10.0)
    assert wait_for(browser, "document.body.classList.contains('new-open') && !nav.busy && nav.reload === 0", 10.0), ns(browser)
    g = ns(browser)
    assert g["open"] and g["hash"] == "#new" and g["current"] == "page", g
    assert wait_for(browser, ROWS_LOADED, 10.0)
    # a phone: from a session, through the drawer; Back from the page lands on the session, a second Back leaves nothing to undo
    browser.send("Emulation.setDeviceMetricsOverride", {"width": 390, "height": 844, "deviceScaleFactor": 1, "mobile": True})
    browser.evaluate("new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))")
    browser.evaluate(f"location.hash = {json.dumps('#s=' + FAKE)}; ''")
    assert wait_for(browser, f"location.hash === '#s={FAKE}' && !document.body.classList.contains('new-open') && !nav.busy", 5.0), ns(browser)
    click(browser, "#side-open")
    wait_side(browser)
    click(browser, "#side-new")
    assert wait_for(browser, "document.body.classList.contains('new-open') && !nav.busy && !document.body.classList.contains('side-open')", 5.0), ns(browser)
    assert browser.evaluate("history.state.sala.layers") == []
    browser.evaluate("history.back(); ''")
    assert wait_for(browser, "!document.body.classList.contains('new-open') && !nav.busy", 5.0), ns(browser)
    assert ns(browser)["hash"] == f"#s={FAKE}" and browser.evaluate("state.selected") == FAKE
    # a stale record of the old popover layer ("new") in an entry is read as no layers
    browser.evaluate("""history.replaceState({ sala: { layers: ["new"], idx: 99 } }, ""); ''""")
    browser.send("Page.reload")
    assert wait_for(browser, WAIT_READY, 10.0)
    assert browser.evaluate("nav.cur.layers.length") == 0 and ns(browser)["hidden"]


def test_the_scopes_the_one_box_the_role_and_the_suggested_name(sala, served, browser):
    # the form opens on the scope of the open session (example); the chips are stackshot's three, 40px buttons; the box lists
    # the scope's listed projects sorted by key and ends with the new-project row, which waits for a name to be typed
    g = open_form(browser, served, scope=None)
    assert [(s["scope"], s["on"]) for s in g["scopes"]] == [("beta", "false"), ("gamma", "false"), ("example", "true"), ("all", "false")] and all(s["h"] >= 40 for s in g["scopes"]), g
    assert g["order"] == ["projects/demo", "projects/stackshot", "__new__"] and g["disabledRows"] == ["__new__"], g
    assert sala.ss.calls("/client/projects")[0]["query"] == {"scope": "example"}
    # another scope: its own list, each row the key and the title in a row a thumb can hit
    set_scope(browser, "gamma")
    assert wait_for(browser, OPTIONS_LOADED, 10.0)   # the options come in beside the list
    g = ns(browser)
    assert g["order"] == ["projects/gamma-harbor", "projects/gamma-pantry", "__new__"], g
    assert g["rows"][0]["text"] == "harborHarbor planning" and g["rows"][-1]["isNew"] and all(r["h"] >= 40 for r in g["rows"]), g["rows"]
    # the first choice says what it resolves to (sala's default lane; settings.json has no model or effort here, so those say "use default" alone)
    assert g["lanes"] == ["=use default (subscription-1)", "subscription-1=subscription-1", "subscription-2=subscription-2", "api=metered", "bedrock=bedrock", "aws-platform=aws-platform"]   # LANE_LABEL: the owner calls api "metered"
    assert g["efforts"] == ["=use default", "low=low", "medium=medium", "high=high", "xhigh=xhigh", "max=max"]
    assert g["models"] == ["=use default", "opus=opus", "sonnet=sonnet", "haiku=haiku", "fable=fable", "__other=other… (a model id)"] and g["modelOtherHidden"], g
    assert g["name"] == "" and g["submitDisabled"] and g["picked"] == "" and g["divider"] is None
    # typing narrows the listed rows by key, name or title (case-insensitive) at once; Enter picks the first one shown and does not submit
    set_value(browser, "#ns-filter", "HARB")
    g = ns(browser)
    assert g["order"] == ["projects/gamma-harbor", "__new__"], g
    key(browser, "Enter", "Enter", 13, "\r")
    assert wait_for(browser, "document.querySelector('#ns-name').value === 'gamma-harbor-pink'"), ns(browser)
    g = ns(browser)
    assert g["rows"][0]["sel"] == "true" and not g["submitDisabled"] and g["mandateHint"] == "optional for a front agent", g
    assert sala.spawns() == []
    unfold(browser)   # the Enter above chose a project, which folded the box
    set_value(browser, "#ns-filter", "nothing-like-this")
    g = ns(browser)
    assert g["order"] == ["(empty)", "__new__"] and g["empty"] == "No listed project matches.", g
    assert g["rows"][-1]["text"] == '+ New project "nothing-like-this"nothing-like-this', g["rows"]
    browser.evaluate("(() => { const f = document.querySelector('#ns-filter'); f.value = ''; f.dispatchEvent(new Event('input')); return '' })()")
    # back: sala's other suggestion, and a mandate is required
    click(browser, 'input[name="ns-role"][value="back"]')
    assert wait_for(browser, "document.querySelector('#ns-name').value === 'gamma-harbor-pink'"), ns(browser)
    g = ns(browser)
    assert g["submitDisabled"] and g["mandateHint"] == "required for a background agent" and "needs a mandate" in g["mandateErr"], g
    set_value(browser, "#ns-mandate", "watch the queue")
    g = ns(browser)
    assert not g["submitDisabled"] and g["mandateErr"] == "", g
    # a name the owner edited stays through a role change; another project replaces it with sala's suggestion again
    set_value(browser, "#ns-name", "gamma-harbor-watch")
    click(browser, 'input[name="ns-role"][value="front"]')
    time.sleep(0.5)
    g = ns(browser)
    assert g["name"] == "gamma-harbor-watch" and not g["submitDisabled"], g
    set_scope(browser, "example")
    g = ns(browser)
    assert g["rows"][0]["sel"] == "false" and g["submitDisabled"], g   # a project belongs to its scope: the pick does not follow a switch
    pick(browser, "projects/demo")
    assert wait_for(browser, "document.querySelector('#ns-name').value === 'demo-pink'"), ns(browser)
    assert [r["argv"][3:] for r in sala.records() if r["argv"][:2] == ["spawn", "--suggest-name"]] == \
        [["projects/gamma-harbor", "--role", "front", "--prefix", "gamma-harbor"], ["projects/gamma-harbor", "--role", "back", "--prefix", "gamma-harbor"],
         ["projects/demo", "--role", "front", "--prefix", "demo"]]   # the project's real prefix goes along
    assert sala.ss.calls("/client/project") == [] and sala.ss.calls("/client/project-agent") == []   # looking changes nothing


def test_the_name_is_checked_here_as_the_backend_checks_it(sala, served, browser):
    open_form(browser, served)
    pick(browser, "projects/gamma-harbor")
    assert wait_for(browser, "document.querySelector('#ns-name').value === 'gamma-harbor-pink'")
    for bad in ("Solo-Main", "-main", "main-", "a b", "한글", "a_b"):
        set_value(browser, "#ns-name", bad)
        g = ns(browser)
        assert g["submitDisabled"] and "Lowercase letters" in g["nameErr"] and "48" in g["nameErr"], (bad, g)
    set_value(browser, "#ns-name", "ok-name-2")
    g = ns(browser)
    assert not g["submitDisabled"] and g["nameErr"] == "", g
    # a model with a shell character disables the button too (the server would refuse it with 400 anyway)
    open_more(browser)
    browser.evaluate("(() => { const m = document.querySelector('#ns-model'); m.value = '__other'; m.dispatchEvent(new Event('change')); return '' })()")
    assert not ns(browser)["modelOtherHidden"]                                   # "other…" opens the id box
    set_value(browser, "#ns-model-other", "opus; id")
    assert ns(browser)["submitDisabled"]
    set_value(browser, "#ns-model-other", "claude-opus-5-5")
    assert not ns(browser)["submitDisabled"]
    assert sala.spawns() == []


def test_a_submit_queues_the_spawn_and_the_link_appears_when_the_session_is_in_the_list(sala, served, browser):
    open_form(browser, served)
    pick(browser, "projects/gamma-harbor")
    assert wait_for(browser, "document.querySelector('#ns-name').value === 'gamma-harbor-pink'")
    # the mandate, typed: a Korean composition commits, Enter is a new line (not a submit), Tab leaves the box (not a
    # tab character, not swallowed), the typed text is what the box holds
    set_value(browser, "#ns-mandate", "abc ")
    for syl in ["ㅎ", "하", "한"]:
        browser.send("Input.imeSetComposition", {"text": syl, "selectionStart": 1, "selectionEnd": 1})
    typed(browser, "한")
    key(browser, "Enter", "Enter", 13, "\r")
    typed(browser, "- 둘째 줄 \"따옴표\" `x` $(id)")
    key(browser, "Tab", "Tab", 9)
    g = ns(browser)
    assert g["mandate"] == "abc 한\n- 둘째 줄 \"따옴표\" `x` $(id)" and g["active"] != "ns-mandate" and "\t" not in g["mandate"], g
    assert sala.spawns() == [] and not g["submitDisabled"] and g["role"] == "front", g
    click(browser, "#ns-submit")
    g = wait_state(browser, "queued")
    assert g["state"] == "gamma-harbor-pink: Queued" and f"Operation {OP}" in g["status"] and "Queued as op" not in g["status"], g
    assert not g["pending"] and g["submitDisabled"] and g["submitText"] == "Starting…", g   # Start works until the session is ready or has failed
    (rec,) = sala.spawns()
    assert rec["argv"][2:7] == ["gamma-harbor-pink", "--project", "projects/gamma-harbor", "--role", "front"]
    assert rec["mandate"] == "abc 한\n- 둘째 줄 \"따옴표\" `x` $(id)\n" and "--lane" not in rec["argv"] and "--model" not in rec["argv"]
    # the page left and opened again still shows it
    click(browser, "#side-ovw")
    assert wait_for(browser, "!document.body.classList.contains('new-open') && !nav.busy", 5.0)
    click(browser, "#side-new")
    assert wait_for(browser, "document.body.classList.contains('new-open') && !nav.busy", 5.0)
    assert ns(browser)["state"] == "gamma-harbor-pink: Queued"
    # the queue starts the operation: "starting", until the name is in the sessions list: "ready", with the link
    sala.marker("running")
    g = wait_state(browser, "starting")
    assert g["link"] is None and "sala is starting the session" in g["status"], g
    browser.evaluate("window.__names = ['gamma-harbor-pink']; ''")
    g = wait_state(browser, "ready")
    assert g["link"] == "#s=gamma-harbor-pink" and "Open" in g["status"], g
    # the link opens the session (the hash, through the page's own history rules) and the page gives way to it
    click(browser, "#ns-status a.ns-link")
    assert wait_for(browser, "location.hash === '#s=gamma-harbor-pink' && !document.body.classList.contains('new-open') && !nav.busy", 5.0), ns(browser)
    assert wait_for(browser, "document.querySelector('#title .name') && document.querySelector('#title .name').textContent === 'gamma-harbor-pink'", 5.0)
    assert browser.evaluate("history.state.sala.layers.length") == 0


def test_a_spawn_that_ends_without_the_session_says_so(sala, served, browser):
    open_form(browser, served)
    pick(browser, "projects/gamma-harbor")
    assert wait_for(browser, "document.querySelector('#ns-name').value === 'gamma-harbor-pink'")
    click(browser, "#ns-submit")
    wait_state(browser, "queued")
    sala.marker("stuck", "the lane cannot launch: max is signed out", done=True)
    g = wait_state(browser, "failed")
    assert "stuck" in g["status"] and "max is signed out" in g["status"] and g["link"] is None and not g["submitDisabled"], g


def test_a_name_the_queue_does_not_see_listed_is_said_in_words_and_the_add_to_page_block_is_never_shown(sala, served, browser):
    # the queue's exit 3 (the name is not on the page's agents map) used to put the ADD-TO-PAGE block and a copy button on the
    # screen for the owner to carry to the page; the form adds the agent through stackshot now, and says only what happened
    sala.mode("exit3")
    open_form(browser, served, scope="beta")
    pick(browser, "projects/beta-web")
    assert wait_for(browser, "document.querySelector('#ns-name').value === 'beta-web-pink'")
    set_value(browser, "#ns-mandate", "press")
    click(browser, "#ns-submit")
    g = wait_state(browser, "beta-web-pink: not queued", 25.0)   # the add step just changed stackshot's record: the form asks again 4, 4 and 6 s later first
    assert "does not see beta-web-pink on the project yet" in g["status"] and "Create again in a minute" in g["status"], g
    assert "ADD-TO-PAGE" not in g["status"] and "agents:" not in g["status"] and "Add this to" not in g["status"] and not g["scriptInStatus"], g
    assert browser.evaluate("document.querySelector('#ns-status .ns-copy')") is None
    # the suggestion is a new agent's name (a random word), not the project's -main: the form adds it to the project
    # first, in the project's own name for it, and only then asks the queue
    (added,) = sala.ss.calls("/client/project-agent")
    assert added["body"]["name"] == "beta-web-pink" and added["body"]["front"] is True and added["body"]["sender"] == "sala-web", added
    # a refused spawn leaves no mandate file
    assert not list(served["settings"].mandates_dir.iterdir())
    assert not ns(browser)["submitDisabled"]   # the form is usable again, for the retry


def test_exit_4_and_a_refusal_stay_text(sala, served, browser):
    sala.mode("exit4")
    open_form(browser, served)
    pick(browser, "projects/gamma-harbor")
    assert wait_for(browser, "document.querySelector('#ns-name').value === 'gamma-harbor-pink'")
    click(browser, "#ns-submit")
    g = wait_state(browser, "gamma-harbor-pink: not queued", 25.0)
    assert "sala does not see the page projects/gamma-harbor yet" in g["status"] and "NO-PAGE" not in g["status"], g
    sala.mode("refuse")
    click(browser, "#ns-submit")
    assert wait_for(browser, "(document.querySelector('#ns-status pre') || {}).textContent?.includes('alert(1)')", 10.0), ns(browser)
    g = ns(browser)
    assert g["pre"] and "<script>alert(1)</script>" in g["pre"] and "✗ refused" in g["pre"] and not g["scriptInStatus"], g
    # the first create asked the queue four times (once, then 4, 4 and 6 s later: the add step had just changed stackshot's record), the refusal once
    assert [r["mode"] for r in sala.spawns()] == ["exit4"] * 4 + ["refuse"]


def test_a_second_submit_while_one_runs_is_not_sent(sala, served, browser):
    sala.mode("slow", slow=2.5)
    open_form(browser, served)
    pick(browser, "projects/gamma-harbor")
    assert wait_for(browser, "document.querySelector('#ns-name').value === 'gamma-harbor-pink'")
    click(browser, "#ns-submit")
    browser.evaluate("document.querySelector('#ns-submit').click(); document.querySelector('#ns-form').requestSubmit(); ''")
    g = ns(browser)
    assert g["pending"] and g["submitDisabled"] and g["state"] == "gamma-harbor-pink: working…", g
    browser.evaluate("document.querySelector('#ns-form').requestSubmit(); ''")
    g = wait_state(browser, "queued", 15.0)
    assert not g["pending"] and g["submitDisabled"] and g["submitText"] == "Starting…", g   # queued is not ready: Start keeps working
    time.sleep(0.5)
    assert len(sala.spawns()) == 1, sala.spawns()


# WCAG 2 contrast of an element's text on the background under it (the first opaque one up the tree, translucent layers
# composited on it), as the browser computed both
NS_CONTRAST = r"""((sel) => {
  const parse = (s) => { let m = /^rgba?\(([\d.]+),\s*([\d.]+),\s*([\d.]+)(?:,\s*([\d.]+))?\)$/.exec(s);
    if (m) return { c: [+m[1] / 255, +m[2] / 255, +m[3] / 255], a: m[4] === undefined ? 1 : +m[4] };
    m = /^color\(srgb ([\d.e-]+) ([\d.e-]+) ([\d.e-]+)(?: \/ ([\d.]+))?\)$/.exec(s);
    if (m) return { c: [+m[1], +m[2], +m[3]], a: m[4] === undefined ? 1 : +m[4] };
    throw new Error("colour " + s); };
  const lum = ({ c }) => c.map((x) => (x <= 0.04045 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4)).reduce((s, x, i) => s + x * [0.2126, 0.7152, 0.0722][i], 0);
  const over = (top, under) => top.c.map((x, i) => x * top.a + under[i] * (1 - top.a));
  const bgOf = (e) => { const layers = []; for (let n = e; n; n = n.parentElement) { const b = parse(getComputedStyle(n).backgroundColor);
      if (b.a > 0) layers.push(b); if (b.a === 1) break; }
    if (!layers.length || layers[layers.length - 1].a < 1) return null;
    let c = layers[layers.length - 1].c; for (const l of layers.slice(0, -1).reverse()) c = over(l, c);
    return { c, a: 1 }; };
  return [...document.querySelectorAll(sel)].filter((t) => t.textContent.trim() && t.getClientRects().length && !t.disabled).map((t) => {
    const cs = getComputedStyle(t), fg0 = parse(cs.color), bg = bgOf(t), fg = bg ? { c: over(fg0, bg.c), a: 1 } : fg0;
    const [hi, lo] = bg ? [lum(fg), lum(bg)].sort((a, b) => b - a) : [0, 1];
    return { el: t.tagName.toLowerCase() + (t.id ? "#" + t.id : "") + (t.className ? "." + String(t.className).trim().split(/\s+/).join(".") : ""),
             text: t.textContent.trim().slice(0, 24), grounded: !!bg, ratio: (hi + 0.05) / (lo + 0.05), size: parseFloat(cs.fontSize) };
  });
})"""
TEXTS = ("#ns-form .ns-field > label, #ns-form .ns-field > .ns-label, #ns-form legend, #ns-form .ns-hint, #ns-form summary, "
         "#ns-form .ns-grid > label, #ns-scopes .ns-chip, #ns-projects .ns-key, #ns-projects .ns-title, #ns-projects .ns-empty, #ns-projects .ns-divider, "
         "#ns-submit, #ns-status .ns-state, #ns-status p, #ns-status pre, #ns-status .ns-step-label, #ns-status .ns-step-state, #ns-status .ns-link, "
         "#ns-picked, #ns-name-err, #ns-mandate-err, #ns-form input, #ns-form textarea")


def check_contrast(items: list[dict]) -> None:
    assert len(items) >= 20, [i["el"] for i in items]
    for i in items:
        assert i["grounded"], i   # an opaque background somewhere under it, so the ratio is the one on screen
        assert i["ratio"] >= 4.5 and i["size"] >= 12, i


def test_the_form_holds_aa_contrast_in_both_themes_and_never_scrolls_sideways(sala, served, browser):
    # a hidden project picked through a query (the divider, the picked page), then a Create that stops at
    # stackshot's refusal of the agent: the steps with their states, the words and stackshot's text are all on the screen
    sala.ss.agent_reply = (403, {"error": "projects/gamma-old-kayak is retired or hidden: list it again first"})
    open_form(browser, served, width=390, height=844)
    set_value(browser, "#ns-filter", "kayak")
    assert wait_for(browser, "document.querySelector('#ns-projects .ns-divider') !== null", 10.0), ns(browser)
    pick(browser, "projects/gamma-old-kayak")
    assert wait_for(browser, "document.querySelector('#ns-name').value === 'gamma-old-kayak-main'"), ns(browser)
    set_value(browser, "#ns-mandate", "x")
    set_value(browser, "#ns-name", "Bad")   # the inline error shows
    g = ns(browser)
    assert g["nameErr"], g
    set_value(browser, "#ns-name", "gamma-old-kayak-main")
    click(browser, "#ns-submit")
    wait_state(browser, "gamma-old-kayak-main: stopped", 15.0)
    open_more(browser)
    set_value(browser, "#ns-name", "Bad")
    dark = browser.evaluate(NS_CONTRAST + "(" + json.dumps(TEXTS) + ")")
    check_contrast(dark)
    g = ns(browser)
    assert g["docScroll"] <= 390 and g["bodyScroll"] <= 390 and g["formScroll"] <= g["formClient"], g
    browser.send("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": "light"}]})
    light = browser.evaluate(NS_CONTRAST + "(" + json.dumps(TEXTS) + ")")
    check_contrast(light)
    assert [round(i["ratio"], 2) for i in light] != [round(i["ratio"], 2) for i in dark]   # the theme did change
    for w in (320, 1280):
        browser.send("Emulation.setDeviceMetricsOverride", {"width": w, "height": 800, "deviceScaleFactor": 1, "mobile": w <= 760})
        browser.evaluate("new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))")
        g = ns(browser)
        assert g["open"] and g["vw"] == w and g["docScroll"] <= w and g["bodyScroll"] <= w and g["formScroll"] <= g["formClient"], (w, g)
        assert g["box"]["left"] >= 0 and g["box"]["right"] <= w + 1, (w, g)
