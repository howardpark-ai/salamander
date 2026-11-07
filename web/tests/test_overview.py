"""The sessions overview: the #sessions view in the main page (GET /sessions redirects there), GET /api/overview, the model a pane runs now (its launch line, sala's record, the
transcript's latest reply) and reading that reply from a transcript's tail."""

import json
import os
import shutil
import subprocess
import sys
import time

import pytest
from starlette.testclient import TestClient

from sala_web import sessions as S
from sala_web import transcript as TR
from sala_web.app import STATIC, create_app
from sala_web.config import Settings

SID_A = "aaaaaaaa-0000-0000-0000-000000000001"
SID_B = "bbbbbbbb-0000-0000-0000-000000000002"
# a process started at 13:35 +04 (epoch ms), a reply before it and one after it
STARTED = 1791970500000
BEFORE, AFTER = "2026-10-13T14:45:14.189Z", "2026-10-14T09:40:00.000Z"


def assistant(model="claude-opus-5-5", effort=None, per_turn=None, **kw):
    d = {"type": "assistant", "uuid": "u", "message": {"model": model, "content": [{"type": "text", "text": "hi"}]}}
    if effort:
        d["effort"] = effort
    if per_turn:
        d["perTurnEffort"] = per_turn
    d.update(kw)
    return json.dumps(d) + "\n"


def user(text="hello"):
    return json.dumps({"type": "user", "uuid": "u", "message": {"content": text}}) + "\n"


def test_latest_model_takes_the_last_main_thread_reply(tmp_path):
    p = tmp_path / "t.jsonl"
    p.write_text(assistant("claude-sonnet-5", effort="low") + user()
                 + assistant("claude-opus-5-5", effort="medium", per_turn="high")
                 + assistant("claude-haiku-5", isSidechain=True)   # a subagent's reply: not the session's model
                 + assistant("<synthetic>")                         # an error stand-in: no model
                 + user() + '{"type": "assistant", "message": {"model": "claude-')  # still being written
    assert TR.latest_model(p) == {"model": "claude-opus-5-5", "effort": "high"}


def test_latest_model_widens_past_a_long_tail(tmp_path):
    p = tmp_path / "t.jsonl"
    filler = user("x" * 1000) * 300  # ~300 KB of user lines after the reply
    p.write_text(assistant("claude-opus-5-5", effort="medium") + filler)
    assert TR.latest_model(p, first=4096) == {"model": "claude-opus-5-5", "effort": "medium"}
    # past the cap: no model rather than reading the whole file
    assert TR.latest_model(p, first=4096, cap=64 << 10) == {}
    assert TR.latest_model(tmp_path / "missing.jsonl") == {}
    (tmp_path / "empty.jsonl").write_text("")
    assert TR.latest_model(tmp_path / "empty.jsonl") == {}


def test_model_cache_rereads_only_when_the_file_changes(tmp_path, monkeypatch):
    p = tmp_path / "t.jsonl"
    p.write_text(assistant("claude-opus-5-5", effort="medium"))
    calls = []
    real = TR.latest_model
    monkeypatch.setattr(TR, "latest_model", lambda path: calls.append(path) or real(path))
    cache = TR.ModelCache()
    assert cache.get(p)["model"] == "claude-opus-5-5"
    assert cache.get(p)["model"] == "claude-opus-5-5"
    assert len(calls) == 1
    with p.open("a") as f:
        f.write(assistant("claude-sonnet-5", effort="low"))
    assert cache.get(p) == {"model": "claude-sonnet-5", "effort": "low"}
    assert len(calls) == 2
    p.unlink()
    assert cache.get(p) == {}


def test_overview_rows_follow_the_sidebar_order():
    def sess(name, status="idle"):
        return S.Session(pid=1, session_id=name, name=name, cwd="/tmp", status=status, tmux="", lane="subscription-1")
    roles = {
        "example-x-main": {"role": "front", "project": "projects/x"},
        "example-x": {"role": "front", "project": "projects/x"},
        "example-x-builder": {"role": "back", "project": "projects/x"},
        "beta-docs": {"role": "front", "project": "projects/beta-docs"},
    }
    live = [sess("scratch-1"), sess("beta-docs"), sess("example-x-builder", "busy"), sess("example-x-main"), sess("example-x")]
    rows = S.overview_rows(live, roles)
    assert [r["name"] for r in rows] == ["example-x", "example-x-main", "example-x-builder", "beta-docs", "scratch-1"]
    assert rows[2]["status"] == "working" and rows[0]["status"] == "idle"
    # a turn that is over with a background shell still running reads "shell" (the Status column stays narrow)
    shell = S.overview_rows([sess("example-x", "shell"), sess("example-y", "waiting")], roles)
    assert sorted(r["status"] for r in shell) == ["needs input", "shell"]
    assert rows[3]["projectTitle"] == "docs" and rows[3]["scope"] == "beta"
    assert rows[4]["project"] is None and rows[4]["projectTitle"] is None and rows[4]["role"] is None
    assert rows[0]["tmuxSession"] == "" and rows[0]["startedAt"] is None  # for the caller's running_model


def test_latest_model_carries_the_reply_timestamp(tmp_path):
    p = tmp_path / "t.jsonl"
    p.write_text(assistant("claude-opus-5", effort="high", timestamp=BEFORE))
    assert TR.latest_model(p) == {"model": "claude-opus-5", "effort": "high", "ts": BEFORE}


def test_parse_launch_flags():
    # sala's resume line: claude --resume <uuid> --model <m> --effort <e> [lane args]; the = form too; the last wins
    assert S.parse_launch_flags(["claude", "--resume", "u", "--model", "claude-opus-5-5", "--effort", "medium"]) == {
        "model": "claude-opus-5-5", "effort": "medium"}
    assert S.parse_launch_flags(["claude", "--model=opus", "--effort=high"]) == {"model": "opus", "effort": "high"}
    assert S.parse_launch_flags(["claude", "--model", "opus", "--model", "sonnet"]) == {"model": "sonnet"}
    assert S.parse_launch_flags(["claude", "--resume", "u"]) == {}
    assert S.parse_launch_flags(["claude", "--model"]) == {}      # a flag with no value
    assert S.parse_launch_flags(["claude", "--model=", "--effort", ""]) == {}


def test_launch_flags_reads_the_process_command_line():
    # a real process whose command line carries the flags (python keeps the extra arguments in sys.argv)
    p = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", "--model", "claude-opus-5-5",
                          "--effort", "high"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        # Popen returns as the child's exec begins; its /proc/<pid>/cmdline is empty until the kernel has laid out the
        # new argv a moment later (a claude pane is long past that), so give it up to 5 s
        deadline = time.monotonic() + 5
        while not (got := S.launch_flags(p.pid)) and time.monotonic() < deadline:
            time.sleep(0.01)
        assert got == {"model": "claude-opus-5-5", "effort": "high"}
    finally:
        p.kill()
        p.wait()
    assert S.launch_flags(os.getpid()) == {}      # pytest's own line has no --model
    assert S.launch_flags(2 ** 22 + 7) == {}      # no such process


def test_sala_models_reads_the_tsv(tmp_path):
    f = tmp_path / "models.tsv"
    f.write_text("beta-mobile\topus\t-\nbeta-docs\tsonnet\tmedium\nbad line\n\t\t\ngamma-x\tclaude-opus-5-5\n")
    assert S.sala_models(f) == {
        "beta-mobile": {"model": "opus", "effort": None},        # "-": no effort of its own
        "beta-docs": {"model": "sonnet", "effort": "medium"},
        "gamma-x": {"model": "claude-opus-5-5", "effort": None},      # no third column at all
    }
    assert S.sala_models(tmp_path / "missing.tsv") == {}
    assert S.sala_models(tmp_path) == {}                         # a directory: unreadable, treated as none


def test_running_model_prefers_the_launch_line_over_an_old_reply():
    # a pane relaunched on claude-opus-5-5 at 13:35 +04, sala's record says opus, the latest
    # reply (claude-opus-5) is from the day before
    launch = {"model": "claude-opus-5-5", "effort": "medium"}
    record = {"model": "opus", "effort": None}
    reply = {"model": "claude-opus-5", "effort": "high", "ts": BEFORE}
    assert S.running_model(launch, record, reply, STARTED) == {
        "model": "claude-opus-5-5", "effort": "medium", "modelSource": "launch", "effortSource": "launch", "modelAlias": None}
    # the launch line's effort wins too, also when the model comes from elsewhere
    assert S.running_model({"effort": "low"}, record, reply, STARTED)["effort"] == "low"


def test_running_model_alias_takes_the_reply_version_only_when_newer_and_of_the_family():
    record = {"model": "opus", "effort": None}
    # launched as --model opus (no version): a reply of that family written after the start names the version
    assert S.running_model({"model": "opus", "effort": "medium"}, record,
                           {"model": "claude-opus-5-5", "effort": "medium", "ts": AFTER}, STARTED) == {
        "model": "claude-opus-5-5", "effort": "medium", "modelSource": "alias", "effortSource": "launch",
        "modelAlias": {"name": "opus", "from": "launch", "via": "reply", "binary": None}}
    # the reply predates the process: it may be the old version, so the alias stays
    got = S.running_model({"model": "opus", "effort": "medium"}, record,
                          {"model": "claude-opus-5-5", "effort": "medium", "ts": BEFORE}, STARTED)
    assert got["model"] == "opus" and got["modelSource"] == "alias" and got["modelAlias"]["via"] is None
    # a reply of another family (a skill's pinned turn, say): the alias stays
    assert S.running_model({"model": "sonnet"}, None, {"model": "claude-opus-5-5", "ts": AFTER}, STARTED)["model"] == "sonnet"
    # no timestamp on the reply, or no start time known: never newer
    assert S.running_model({"model": "opus"}, None, {"model": "claude-opus-5-5"}, STARTED)["model"] == "opus"
    assert S.running_model({"model": "opus"}, None, {"model": "claude-opus-5-5", "ts": AFTER}, None)["model"] == "opus"
    assert S.running_model({"model": "opus"}, None, {"model": "claude-opus-5-5", "ts": "yesterday"}, STARTED)["model"] == "opus"
    # a full id on the line is shown as it is, whatever the reply says
    assert S.running_model({"model": "claude-sonnet-5"}, None, {"model": "claude-opus-5-5", "ts": AFTER}, STARTED)["model"] == "claude-sonnet-5"


def test_running_model_falls_back_to_the_record_then_the_reply():
    reply = {"model": "claude-opus-5", "effort": "high", "ts": BEFORE}
    # no flags on the line (a hand launch): sala's record, its effort when it has one
    assert S.running_model({}, {"model": "sonnet", "effort": "medium"}, reply, STARTED) == {
        "model": "sonnet", "effort": "medium", "modelSource": "alias", "effortSource": "record",
        "modelAlias": {"name": "sonnet", "from": "record", "via": None, "binary": None}}
    # a record with no effort of its own ("-"): the reply's effort
    assert S.running_model({}, {"model": "claude-opus-5-5", "effort": None}, reply, STARTED) == {
        "model": "claude-opus-5-5", "effort": "high", "modelSource": "record", "effortSource": "reply", "modelAlias": None}
    # the record's alias is refined by a newer reply of the family as the line's would be
    assert S.running_model({}, {"model": "opus", "effort": None}, {"model": "claude-opus-5-5", "ts": AFTER}, STARTED)["model"] == "claude-opus-5-5"
    # nothing but the transcript: as before
    assert S.running_model({}, None, reply, STARTED) == {
        "model": "claude-opus-5", "effort": "high", "modelSource": "reply", "effortSource": "reply", "modelAlias": None}
    assert S.running_model({}, None, {}, None) == {"model": None, "effort": None, "modelSource": None, "effortSource": None, "modelAlias": None}


def test_running_model_falls_back_to_the_cli_default_when_nothing_names_one():
    # a session on the default model that sala's idle wrap-up cleared: no flag, no record, no reply yet
    default = {"model": "claude-opus-5-5", "effort": "high"}
    assert S.running_model({}, None, {}, None, {}, {}, default) == {
        "model": "claude-opus-5-5", "effort": "high", "modelSource": "default", "effortSource": "default", "modelAlias": None}
    # the default is a bare alias (settings.json: "model": "opus"): resolved like any alias, still marked as the default
    got = S.running_model({}, None, {}, None, {}, CATALOG, {"model": "opus", "effort": "medium"})
    assert got == {"model": "claude-opus-5-5", "effort": "medium", "modelSource": "default", "effortSource": "default",
                   "modelAlias": {"name": "opus", "from": "default", "via": "catalog", "binary": "2.1.299"}}
    # an alias no catalog can resolve stays the alias, marked as the default, version unknown
    got = S.running_model({}, None, {}, None, {}, {}, {"model": "opus", "effort": ""})
    assert (got["model"], got["modelSource"], got["modelAlias"]["via"]) == ("opus", "default", None)
    # the default read as "" (settings.json missing, unreadable, no model or effort in it): nothing, as before
    for empty in ({"model": "", "effort": ""}, {}, None):
        assert S.running_model({}, None, {}, None, {}, {}, empty) == {
            "model": None, "effort": None, "modelSource": None, "effortSource": None, "modelAlias": None}
    # an effort with no default model names no family: it fits no model, so no effort either
    assert S.running_model({}, None, {}, None, {}, {}, {"model": "", "effort": "low"}) == {
        "model": None, "effort": None, "modelSource": None, "effortSource": None, "modelAlias": None}
    assert S.running_model({"model": "claude-opus-5-5"}, None, {}, None, {}, {}, {"model": "", "effort": "low"})["effort"] is None
    got = S.running_model({}, None, {}, None, {}, {}, {"model": "claude-opus-5-5", "effort": ""})
    assert (got["model"], got["modelSource"], got["effort"], got["effortSource"]) == ("claude-opus-5-5", "default", None, None)


def test_running_model_the_default_comes_last():
    default = {"model": "claude-haiku-5-5", "effort": "low"}
    reply = {"model": "claude-opus-5", "effort": "high", "ts": BEFORE}
    # the launch line, then the record, then the reply: each still wins over the default
    got = S.running_model({"model": "claude-opus-5-5", "effort": "medium"}, {"model": "sonnet", "effort": "max"}, reply,
                          STARTED, {}, {}, default)
    assert (got["model"], got["modelSource"], got["effort"], got["effortSource"]) == ("claude-opus-5-5", "launch", "medium", "launch")
    got = S.running_model({}, {"model": "claude-sonnet-5-5", "effort": "max"}, reply, STARTED, {}, {}, default)
    assert (got["model"], got["modelSource"], got["effort"], got["effortSource"]) == ("claude-sonnet-5-5", "record", "max", "record")
    got = S.running_model({}, None, reply, STARTED, {}, {}, default)
    assert (got["model"], got["modelSource"], got["effort"], got["effortSource"]) == ("claude-opus-5", "reply", "high", "reply")
    # an alias on the launch line resolves as before and is never marked as the default
    got = S.running_model({"model": "opus"}, None, {}, STARTED, {}, CATALOG, default)
    assert (got["model"], got["modelSource"], got["modelAlias"]["from"]) == ("claude-opus-5-5", "alias", "launch")
    # effort alone from a source, the model from the default: each field keeps its own source
    got = S.running_model({"effort": "xhigh"}, None, {}, STARTED, {}, {}, default)
    assert (got["model"], got["modelSource"], got["effort"], got["effortSource"]) == ("claude-haiku-5-5", "default", "xhigh", "launch")


def test_running_model_default_effort_only_for_the_default_models_family():
    default = {"model": "opus[1m]", "effort": "xhigh"}
    # the same family: a launch model of opus gets the default's effort (the model itself is the pane's)
    got = S.running_model({"model": "claude-opus-5-5"}, None, {}, STARTED, {}, {}, default)
    assert (got["model"], got["modelSource"], got["effort"], got["effortSource"]) == ("claude-opus-5-5", "launch", "xhigh", "default")
    # a bare alias resolving to the family: the family is taken from the resolved model
    got = S.running_model({"model": "opus"}, None, {}, STARTED, {}, CATALOG, default)
    assert (got["model"], got["modelSource"], got["effort"], got["effortSource"]) == ("claude-opus-5-5", "alias", "xhigh", "default")
    # another family: the effort is not the default's to give, "not set" as before
    got = S.running_model({"model": "sonnet"}, None, {}, STARTED, {}, {}, default)
    assert (got["model"], got["effort"], got["effortSource"]) == ("sonnet", None, None)
    got = S.running_model({"model": "sonnet"}, None, {}, STARTED, {}, CATALOG, default)
    assert (got["model"], got["effort"], got["effortSource"]) == ("claude-sonnet-5-5", None, None)
    # a reply of another family with no effort of its own, and a record of one
    got = S.running_model({}, None, {"model": "claude-haiku-5", "ts": AFTER}, STARTED, {}, {}, default)
    assert (got["model"], got["modelSource"], got["effort"], got["effortSource"]) == ("claude-haiku-5", "reply", None, None)
    got = S.running_model({}, {"model": "claude-haiku-5-5", "effort": None}, {}, STARTED, {}, {}, default)
    assert (got["modelSource"], got["effort"], got["effortSource"]) == ("record", None, None)
    # a pane's own effort still shows whatever the family
    got = S.running_model({"model": "sonnet", "effort": "low"}, None, {}, STARTED, {}, {}, default)
    assert (got["effort"], got["effortSource"]) == ("low", "launch")
    # a model that names no family gets none
    assert S.running_model({"model": "gpt-x"}, None, {}, STARTED, {}, {}, default)["effort"] is None


# a catalog as CatalogCache.for_pid returns it, from Claude Code 2.1.299
CATALOG = {"aliases": {"opus": "claude-opus-5-5", "sonnet": "claude-sonnet-5-5", "fable": "claude-fable-5-1"},
           "latest": {"opus": "claude-opus-5-5", "sonnet": "claude-sonnet-5-5", "haiku": "claude-haiku-5-5"},
           "binary": "2.1.299"}


def test_running_model_alias_resolution_order():
    old = {"model": "claude-opus-5", "ts": BEFORE}
    # the catalog of the binary the process runs: its alias default
    got = S.running_model({"model": "opus", "effort": "medium"}, None, old, STARTED, {}, CATALOG)
    assert got == {"model": "claude-opus-5-5", "effort": "medium", "modelSource": "alias", "effortSource": "launch",
                   "modelAlias": {"name": "opus", "from": "launch", "via": "catalog", "binary": "2.1.299"}}
    # an alias missing from the aliases block falls back to latest_per_family
    assert S.running_model({"model": "haiku"}, None, {}, STARTED, {}, CATALOG)["model"] == "claude-haiku-5-5"
    # the env override beats the catalog
    env = {"opus": "claude-opus-5"}
    got = S.running_model({"model": "opus"}, None, old, STARTED, env, CATALOG)
    assert (got["model"], got["modelAlias"]["via"], got["modelAlias"]["binary"]) == ("claude-opus-5", "env", None)
    # an override that is itself a bare alias names no version: the catalog answers
    assert S.running_model({"model": "opus"}, None, old, STARTED, {"opus": "sonnet"}, CATALOG)["model"] == "claude-opus-5-5"
    # a newer reply of the family beats both (a /model switch within the family after the launch)
    newer = {"model": "claude-opus-5-1", "ts": AFTER}
    got = S.running_model({"model": "opus"}, None, newer, STARTED, env, CATALOG)
    assert (got["model"], got["modelAlias"]["via"]) == ("claude-opus-5-1", "reply")
    # an override for another alias does not apply
    assert S.running_model({"model": "sonnet"}, None, {}, STARTED, env, CATALOG)["model"] == "claude-sonnet-5-5"
    # [1m] on the alias carries over
    assert S.running_model({"model": "sonnet[1m]"}, None, {}, STARTED, {}, CATALOG)["model"] == "claude-sonnet-5-5[1m]"
    # the record's alias resolves the same way
    got = S.running_model({}, {"model": "sonnet", "effort": None}, {}, STARTED, {}, CATALOG)
    assert (got["model"], got["modelAlias"]["from"]) == ("claude-sonnet-5-5", "record")


def test_running_model_unresolved_alias_says_so():
    # no newer reply, no override, no catalog (another program, an unreadable or unknown-layout binary)
    for catalog in (None, {}, {"aliases": {"sonnet": "claude-sonnet-5-5"}, "latest": {}}):
        got = S.running_model({"model": "opus", "effort": "low"}, None, {"model": "claude-opus-5", "ts": BEFORE},
                              STARTED, {}, catalog)
        assert got == {"model": "opus", "effort": "low", "modelSource": "alias", "effortSource": "launch",
                       "modelAlias": {"name": "opus", "from": "launch", "via": None, "binary": None}}
    # an alias the CLI does not have stays unresolved too
    assert S.running_model({"model": "default"}, None, {}, STARTED, {}, CATALOG)["modelAlias"]["via"] is None


def fake_binary(path, catalog_bytes, pad=1 << 20):
    """A file shaped like the claude binary: padding, then the catalog as the bundle embeds it, then more padding."""
    path.write_bytes(b"\x7fELF" + b"\0" * pad + catalog_bytes + b";function O(){}" + b"\0" * pad)
    return path


REAL_CATALOG = (b'P=x({aliases:{opus:{default:"claude-opus-5-5",per_provider:{bedrock:"claude-opus-5-5",'
                b'foundry:"claude-opus-4-6",gateway:"claude-opus-4-7"}},sonnet:{default:"claude-sonnet-5-5",'
                b'per_provider:{bedrock:"claude-sonnet-4-5"}},haiku:{default:"claude-haiku-5-5",per_provider:{}},'
                b'fable:{default:"claude-fable-5-1",per_provider:{gateway:"claude-fable-5"}}},defaults:{},best:"fable",'
                b'latest_per_family:{fable:"claude-fable-5-1",opus:"claude-opus-5-5",sonnet:"claude-sonnet-5-5",'
                b'haiku:"claude-haiku-5-5"},alias_migration:{}}')


def test_parse_catalog_reads_the_embedded_catalog(tmp_path):
    got = S.parse_catalog(fake_binary(tmp_path / "2.1.299", REAL_CATALOG))
    assert got == {
        "aliases": {"opus": "claude-opus-5-5", "sonnet": "claude-sonnet-5-5", "haiku": "claude-haiku-5-5",
                    "fable": "claude-fable-5-1"},      # the first-party default, never a per_provider id
        "latest": {"fable": "claude-fable-5-1", "opus": "claude-opus-5-5", "sonnet": "claude-sonnet-5-5",
                   "haiku": "claude-haiku-5-5"}}
    # a stray anchor with nothing around it is skipped for the real one after it
    got = S.parse_catalog(fake_binary(tmp_path / "stray", b'"latest_per_family:{"' + b"\0" * 70000 + REAL_CATALOG))
    assert got["aliases"]["opus"] == "claude-opus-5-5"
    # only latest_per_family (an aliases block further back than the window): still an answer
    only_latest = b"aliases:{opus:{default:\"claude-opus-9\"}}" + b"\0" * (S.CATALOG_WINDOW + 10) + REAL_CATALOG[REAL_CATALOG.index(b"latest"):]
    assert S.parse_catalog(fake_binary(tmp_path / "far", only_latest)) == {
        "aliases": {}, "latest": {"fable": "claude-fable-5-1", "opus": "claude-opus-5-5", "sonnet": "claude-sonnet-5-5",
                                  "haiku": "claude-haiku-5-5"}}
    # no catalog, an empty file, a missing file, a directory
    assert S.parse_catalog(fake_binary(tmp_path / "python", b"nothing here")) == {}
    (tmp_path / "empty").write_bytes(b"")
    assert S.parse_catalog(tmp_path / "empty") == {}
    assert S.parse_catalog(tmp_path / "missing") == {}
    assert S.parse_catalog(tmp_path) == {}


def test_catalog_cache_scans_each_binary_once(monkeypatch):
    calls = []
    monkeypatch.setattr(S, "parse_catalog", lambda path: calls.append(path) or {"aliases": {"opus": "claude-opus-5-5"}, "latest": {}})
    cache = S.CatalogCache()
    pid = os.getpid()   # pytest's own binary stands in for claude's
    got = cache.for_pid(pid)
    assert got["aliases"] == {"opus": "claude-opus-5-5"}
    assert got["binary"] == os.path.basename(os.path.realpath(f"/proc/{pid}/exe"))
    assert cache.for_pid(pid) is got and len(calls) == 1       # the same binary: no second scan
    assert cache.for_pid(2 ** 22 + 7) == {} and len(calls) == 1  # no such process: nothing scanned


def test_model_env_reads_only_the_alias_overrides():
    env = {"PATH": os.environ.get("PATH", ""), "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-5",
           "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-5-5[1m]", "OTHER_SECRET": "x"}
    p = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"], env=env,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 5   # as for the command line: the environ is laid out a moment after exec
        while not (got := S.model_env(p.pid)) and time.monotonic() < deadline:
            time.sleep(0.01)
        assert got == {"opus": "claude-opus-5", "sonnet": "claude-sonnet-5-5[1m]"}
    finally:
        p.kill()
        p.wait()
    assert S.model_env(2 ** 22 + 7) == {}


def test_model_label_in_the_browser_helper():
    node = shutil.which("node")
    if not node:
        pytest.skip("node is not installed")
    ids = ["claude-opus-5-5", "claude-opus-5", "opus", "sonnet", "sonnet[1m]", "claude-sonnet-5-5[1m]", "claude-fable-5-1",
           "", "x-y"]
    script = (STATIC / "shared.js").read_text() + f"\nconsole.log(JSON.stringify({json.dumps(ids)}.map(modelLabel)));"
    out = subprocess.run([node, "-e", script], capture_output=True, text=True, check=True, timeout=30).stdout
    # a bare alias is never a plain family name
    assert json.loads(out) == ["Opus 5.5", "Opus 5", "Opus (version unknown)", "Sonnet (version unknown)",
                               "Sonnet (1M) (version unknown)", "Sonnet 5.5 (1M)", "Fable 5.1", "", "x-y"]


def test_model_label_reads_provider_spellings_like_the_plain_id():
    """the Overview showed "global.anthropic.claude-sonnet-5-5" raw on the bedrock lane. Bedrock's region and
    anthropic. prefix and -v1:0 suffix, an inference-profile ARN and Vertex's @date read as the plain claude- id does."""
    node = shutil.which("node")
    if not node:
        pytest.skip("node is not installed")
    arn = "arn:aws:bedrock:us-east-1:123456789012:inference-profile/global.anthropic.claude-sonnet-5-5"
    pairs = [  # (provider spelling, the plain claude- id of the same model)
        ("global.anthropic.claude-sonnet-5-5", "claude-sonnet-5-5"),
        ("global.anthropic.claude-opus-5-5", "claude-opus-5-5"),
        ("us.anthropic.claude-sonnet-4-5-20250929-v1:0", "claude-sonnet-4-5"),
        ("eu.anthropic.claude-haiku-4-5-20251001-v1:0", "claude-haiku-4-5"),
        ("apac.anthropic.claude-opus-5-v1:0", "claude-opus-5"),
        ("us-gov.anthropic.claude-sonnet-4-5-v1:0", "claude-sonnet-4-5"),
        ("anthropic.claude-opus-5-5", "claude-opus-5-5"),
        ("anthropic.claude-3-5-sonnet-20241022-v2:0", "claude-3-5-sonnet-20241022"),  # old order: unread either way
        ("claude-sonnet-4-5@20250929", "claude-sonnet-4-5"),
        ("claude-opus-5-5@default", "claude-opus-5-5"),
        (arn, "claude-sonnet-5-5"),
        ("global.anthropic.claude-opus-5-5[1m]", "claude-opus-5-5[1m]"),
    ]
    ids = [a for a, _ in pairs] + [b for _, b in pairs] + ["global.anthropic.nonsense", "us.anthropic.", "arn:aws:bedrock:x/y"]
    script = (STATIC / "shared.js").read_text() + f"\nconsole.log(JSON.stringify({json.dumps(ids)}.map(modelLabel)));"
    got = json.loads(subprocess.run([node, "-e", script], capture_output=True, text=True, check=True, timeout=30).stdout)
    n = len(pairs)
    for i, (prov, plain) in enumerate(pairs):
        if plain.startswith("claude-3-"):
            assert got[i] == prov and got[n + i] == plain  # the old naming is not read today: the raw id, both ways
        else:
            assert got[i] == got[n + i] != plain, (prov, got[i], got[n + i])
    assert got[:3] == ["Sonnet 5.5", "Opus 5.5", "Sonnet 4.5"] and got[3] == "Haiku 4.5"
    assert got[n - 1] == "Opus 5.5 (1M)"
    assert got[2 * n:] == ["global.anthropic.nonsense", "us.anthropic.", "arn:aws:bedrock:x/y"]  # unreadable: the raw id


@pytest.fixture
def env(tmp_path, monkeypatch):
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    (claude / "projects").mkdir()
    pid = os.getpid()  # a live pid; no procStart recorded, so it counts as alive
    cwd = "/home/alex/work"
    (claude / "sessions" / "a.json").write_text(json.dumps(
        {"pid": pid, "sessionId": SID_A, "name": "example-x", "cwd": cwd, "status": "busy"}))
    proj = claude / "projects" / TR.project_slug(cwd)
    proj.mkdir()
    (proj / f"{SID_A}.jsonl").write_text(user() + assistant("claude-opus-5-5", effort="medium"))
    roles = {"sessions": {"example-x": {"role": "front", "project": "projects/x"}}}
    monkeypatch.setattr(S, "proc_lane", lambda p: "api")
    # pytest's own command line stands in for every claude's: a test sets launch["model"] to put flags on it
    launch: dict = {}
    monkeypatch.setattr(S, "launch_flags", lambda p: dict(launch))
    monkeypatch.setattr(S, "live_tmux_names", lambda: {})  # never the default tmux server's names
    # the process's alias overrides and its binary's catalog: none unless a test sets them (never pytest's own)
    menv: dict = {}
    catalog: dict = {}
    monkeypatch.setattr(S, "model_env", lambda p: dict(menv))
    cfgdir: dict = {"dir": ""}   # the pane's own CLAUDE_CONFIG_DIR: none unless a test sets it
    monkeypatch.setattr(S, "pane_config_dir", lambda p: cfgdir["dir"])
    monkeypatch.setattr(S.CatalogCache, "for_pid", lambda self, p: dict(catalog))
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                        tmux_socket_name="salaweb-pytest-unused", roles_cmd=["echo", json.dumps(roles)],
                        sala_models=tmp_path / "models.tsv")
    return {"client": TestClient(create_app(settings)), "claude": claude, "pid": pid, "launch": launch,
            "menv": menv, "catalog": catalog, "cfgdir": cfgdir,
            "transcript": proj / f"{SID_A}.jsonl", "models": tmp_path / "models.tsv"}


def test_overview_endpoint(env):
    r = env["client"].get("/api/overview")
    assert r.status_code == 200
    body = r.json()
    assert body["rolesError"] is None
    assert body["sessions"] == [{
        "name": "example-x", "pid": env["pid"], "sessionId": SID_A, "scope": "example", "project": "projects/x",
        "projectTitle": "x", "role": "front", "status": "working", "lane": "api",
        "model": "claude-opus-5-5", "effort": "medium", "modelSource": "reply", "effortSource": "reply", "modelAlias": None}]


def test_overview_shows_what_the_pane_runs_now(env):
    # a session relaunched onto claude-opus-5-5 whose latest reply is still the old claude-opus-5 from the day before
    (env["claude"] / "sessions" / "a.json").write_text(json.dumps(
        {"pid": env["pid"], "sessionId": SID_A, "name": "example-x", "cwd": "/home/alex/work", "status": "busy",
         "tmux": "example-x:@1.%1", "startedAt": STARTED}))
    env["transcript"].write_text(user() + assistant("claude-opus-5", effort="high", timestamp=BEFORE))
    env["models"].write_text("example-x\topus\t-\n")
    env["launch"].update(model="claude-opus-5-5", effort="medium")
    row = env["client"].get("/api/overview").json()["sessions"][0]
    assert (row["model"], row["effort"], row["modelSource"]) == ("claude-opus-5-5", "medium", "launch")
    # launched as --model opus and the only reply predates the process: the binary's catalog names the version
    env["launch"].clear()
    env["launch"].update(model="opus", effort="medium")
    env["catalog"].update(CATALOG)
    row = env["client"].get("/api/overview").json()["sessions"][0]
    assert (row["model"], row["effort"], row["modelSource"]) == ("claude-opus-5-5", "medium", "alias")
    assert row["modelAlias"] == {"name": "opus", "from": "launch", "via": "catalog", "binary": "2.1.299"}
    # an override in the process's environment wins over the catalog
    env["menv"]["opus"] = "claude-opus-5"
    row = env["client"].get("/api/overview").json()["sessions"][0]
    assert (row["model"], row["modelAlias"]["via"]) == ("claude-opus-5", "env")
    # neither: the alias, marked unresolved
    env["menv"].clear()
    env["catalog"].clear()
    row = env["client"].get("/api/overview").json()["sessions"][0]
    assert (row["model"], row["modelSource"], row["modelAlias"]["via"]) == ("opus", "alias", None)
    # it answers on the new version: the reply names it
    with env["transcript"].open("a") as f:
        f.write(user() + assistant("claude-opus-5-5", effort="medium", timestamp=AFTER))
    row = env["client"].get("/api/overview").json()["sessions"][0]
    assert (row["model"], row["effort"], row["modelSource"]) == ("claude-opus-5-5", "medium", "alias")
    assert row["modelAlias"]["via"] == "reply"
    # no flags on the line (a hand launch): sala's record (its alias, resolved the same way), then the reply's effort
    env["launch"].clear()
    row = env["client"].get("/api/overview").json()["sessions"][0]
    assert (row["model"], row["effort"], row["modelSource"]) == ("claude-opus-5-5", "medium", "alias")
    assert row["modelAlias"] == {"name": "opus", "from": "record", "via": "reply", "binary": None}
    env["models"].write_text("example-x\tclaude-opus-5-5\t-\n")
    row = env["client"].get("/api/overview").json()["sessions"][0]
    assert (row["model"], row["modelSource"], row["modelAlias"]) == ("claude-opus-5-5", "record", None)
    env["models"].unlink()
    row = env["client"].get("/api/overview").json()["sessions"][0]
    assert row["modelSource"] == "reply"
    # the row carries no internals the page does not need
    assert not {"cwd", "tmuxSession", "startedAt"} & set(row)


def test_overview_alias_pane_with_only_a_provider_env_override_shows_the_plain_id(env):
    # a bedrock pane launched as --model sonnet, no reply since its relaunch: the process's
    # ANTHROPIC_DEFAULT_SONNET_MODEL (a provider's id) names the version; the API gives the plain claude- id
    (env["claude"] / "sessions" / "a.json").write_text(json.dumps(
        {"pid": env["pid"], "sessionId": SID_A, "name": "example-x", "cwd": "/home/alex/work", "status": "busy",
         "tmux": "example-x:@1.%1", "startedAt": STARTED}))
    env["transcript"].write_text(user() + assistant("claude-sonnet-5-5", effort="high", timestamp=BEFORE))
    env["launch"].update(model="sonnet", effort="medium")
    env["menv"]["sonnet"] = "global.anthropic.claude-sonnet-5-5"
    row = env["client"].get("/api/overview").json()["sessions"][0]
    assert (row["model"], row["modelSource"]) == ("claude-sonnet-5-5", "alias")
    assert row["modelAlias"] == {"name": "sonnet", "from": "launch", "via": "env", "binary": None}
    # the other spellings and the [1m] alias
    for raw, alias, want in [("us.anthropic.claude-opus-5-5-v1:0", "opus", "claude-opus-5-5"),
                             ("claude-sonnet-4-5@20250929", "sonnet", "claude-sonnet-4-5"),
                             ("arn:aws:bedrock:us-east-1:1:inference-profile/global.anthropic.claude-sonnet-5-5", "sonnet",
                              "claude-sonnet-5-5"),
                             ("global.anthropic.claude-sonnet-5-5", "sonnet[1m]", "claude-sonnet-5-5[1m]")]:
        env["launch"]["model"] = alias
        env["menv"].clear()
        env["menv"][alias.removesuffix("[1m]")] = raw
        row = env["client"].get("/api/overview").json()["sessions"][0]
        assert (row["model"], row["modelAlias"]["via"]) == (want, "env"), raw
    # the catalog fallback goes through the same reading
    env["menv"].clear()
    env["launch"]["model"] = "opus"
    env["catalog"].update({"aliases": {"opus": "global.anthropic.claude-opus-5-5-v1:0"}, "binary": "2.1.299"})
    row = env["client"].get("/api/overview").json()["sessions"][0]
    assert (row["model"], row["modelAlias"]["via"]) == ("claude-opus-5-5", "catalog")


def test_plain_model_id_leaves_a_plain_id_alone():
    assert S.plain_model_id("claude-haiku-4-5-20251001") == "claude-haiku-4-5-20251001"   # as today, date and all
    assert S.plain_model_id("claude-sonnet-5-5[1m]") == "claude-sonnet-5-5[1m]"
    assert S.plain_model_id("global.anthropic.claude-sonnet-5-5[1m]") == "claude-sonnet-5-5[1m]"
    assert S.plain_model_id("global.anthropic.claude-haiku-4-5-20251001-v1:0") == "claude-haiku-4-5"


def test_overview_fills_the_gap_with_the_default_lane_settings(env):
    # a session with no launch flag, no record and no reply shows the CLI's default, marked as one
    (env["claude"] / "projects" / TR.project_slug("/home/alex/work") / f"{SID_A}.jsonl").write_text("")
    (env["claude"] / "settings.json").write_text(json.dumps({"model": "claude-opus-5-5", "effortLevel": "high"}))
    row = env["client"].get("/api/overview").json()["sessions"][0]
    assert (row["model"], row["modelSource"], row["effort"], row["effortSource"]) == (
        "claude-opus-5-5", "default", "high", "default")
    # a bare alias in settings.json is resolved by the pane's binary catalog, and the row still says it is the default
    (env["claude"] / "settings.json").write_text(json.dumps({"model": "opus"}))
    env["catalog"].update(CATALOG)
    row = env["client"].get("/api/overview").json()["sessions"][0]
    assert (row["model"], row["modelSource"], row["effort"], row["effortSource"]) == ("claude-opus-5-5", "default", None, None)
    assert row["modelAlias"] == {"name": "opus", "from": "default", "via": "catalog", "binary": "2.1.299"}
    # a launch flag wins over the default
    env["launch"].update(model="claude-sonnet-5-5", effort="low")
    row = env["client"].get("/api/overview").json()["sessions"][0]
    assert (row["model"], row["modelSource"], row["effort"], row["effortSource"]) == ("claude-sonnet-5-5", "launch", "low", "launch")
    # a pane with its own CLAUDE_CONFIG_DIR may follow another settings file: no default for it, model or effort
    (env["claude"] / "settings.json").write_text(json.dumps({"model": "claude-opus-5-5", "effortLevel": "high"}))
    env["launch"].clear()
    env["cfgdir"]["dir"] = "/home/alex/.claude-team"
    row = env["client"].get("/api/overview").json()["sessions"][0]
    assert (row["model"], row["modelSource"], row["effort"], row["effortSource"]) == (None, None, None, None)
    # the same directory as the default lane's, spelled differently, is the default lane
    env["cfgdir"]["dir"] = str(env["claude"] / ".." / "claude")
    row = env["client"].get("/api/overview").json()["sessions"][0]
    assert (row["model"], row["modelSource"], row["effortSource"]) == ("claude-opus-5-5", "default", "default")
    env["cfgdir"]["dir"] = ""
    # settings.json unreadable: today's blanks
    env["launch"].clear()
    (env["claude"] / "settings.json").write_text("{broken")
    row = env["client"].get("/api/overview").json()["sessions"][0]
    assert (row["model"], row["modelSource"], row["effort"], row["effortSource"]) == (None, None, None, None)


def test_overview_session_without_a_transcript(env):
    # a second registry entry for the same live pid, with no transcript yet
    (env["claude"] / "sessions" / "b.json").write_text(json.dumps(
        {"pid": env["pid"], "sessionId": SID_B, "name": "scratch-new", "cwd": "/nowhere", "status": "idle"}))
    rows = {r["name"]: r for r in env["client"].get("/api/overview").json()["sessions"]}
    assert rows["scratch-new"]["model"] is None and rows["scratch-new"]["effort"] is None
    assert rows["scratch-new"]["modelSource"] is None
    assert rows["scratch-new"]["status"] == "idle" and rows["scratch-new"]["scope"] == "Unregistered"


def test_sessions_overview_is_a_view_of_the_main_page(env):
    # the old page's URL lands on the view, without following the redirect off the test host
    r = env["client"].get("/sessions", follow_redirects=False)
    assert r.status_code == 302 and r.headers["location"] == "./#sessions"
    assert env["client"].get("/static/sessions.html").status_code == 404
    index = env["client"].get("/").text
    assert "{{v}}" not in index and "{{build}}" not in index
    # the overview sits at the top of the sidebar and in the main area; the header's table icon is gone
    assert 'id="side-ovw"' in index and 'href="#sessions"' in index and 'id="overview-pane"' in index
    assert 'id="side-table"' not in index and 'href="sessions"' not in index
    assert 'href="#s=help-session"' in index
    assert 'href="static/sessions.css?v=' in index
    # shared helpers, then the overview, then app.js, which drives it
    assert index.index("static/shared.js") < index.index("static/sessions.js?v=") < index.index("static/app.js")
    assert env["client"].get("/static/sessions.js").status_code == 200
