"""Scenario test for machine-follow (lib/machine-follow.py, systemd/machine-follow.{path,timer,service}, systemd/machine-follow@.service, docs/units.md), run by
tests/machinefollow.sh.

machine-follow is the fleet-follow dispatcher: the machines the coordinator machine drives follow what it runs (the stackshot and salamander commits, the Claude
CLI, the installed gbrain build). What a wrong answer costs: a machine that is not brought level when something it follows changed (or one brought level over and
over, an ssh every 10 minutes), a slow machine holding up a fast one, a state file claiming a follow that did not happen, a failing step read as a skip (never
retried loudly) or a skip read as a failure.

What is checked:
- the data file: a wrong entry is refused by name, a before_command that is not a list of strings too; the setting that names the file (the environment, else the
  line in sala's config, a leading ~ expanded; the old test variable wins over both; the default under the config folder); a missing file is one line and exit 2.
- the units: the path unit watches exactly what the machines follow, the timer is every 10 minutes, the dispatcher runs the script in lib/ and no instance,
  the template runs one machine (--host %i) within a limit above the largest step plus the settle wait.
- the dispatcher starts machine-follow@<host>.service only for the machines that are due, never one already active, and runs no step itself; a machine's step
  runs only when a thing it follows changed since its last successful follow, or its catch-up passed.
- the settle rule: a due gbrain follower waits for the install to be still for 60 s (up to 10 min), the others never wait.
- exit 75 (not ready) is a skip, not a failure; a failing step is one and the other machines still run; the state file is written only on success.
- before_command: both steps always run, the result is the worse of the two, the first is capped.
- the real runner (home expansion, a kill at the limit, the exit code), the real systemctl calls (against a stub), the real fingerprints (against throwaway git
  repositories), and the real script as a command with an isolated HOME.
NOT checked: a real ssh, a real systemd run, the real machines or the real data file (the data file is the owner's, outside this repository), a step script
(they live beside the data file). Nothing here touches ~/.local/state/machine-follow, the user's systemd or the user's config: every path is under a scratch
folder, locked while this runs and removed on every exit, pass or fail. No process is killed except the step the runner test starts itself (its own process group).
"""
import contextlib
import fcntl
import importlib.util
import io
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import traceback
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "lib" / "machine-follow.py"
UNITS = ROOT / "systemd"

# the scratch folder: its own, locked while this runs (systemd-tmpfiles ageing honours flock) and removed on every exit
T = Path(tempfile.mkdtemp(prefix="machinefollowscen-"))
_lock = os.open(str(T), os.O_RDONLY)
fcntl.flock(_lock, fcntl.LOCK_EX)

# nothing of the caller's environment may steer the script: the test sets what it needs itself
for _k in [k for k in os.environ if k.startswith("MACHINE_FOLLOW_") or k in ("SALA_MACHINE_FOLLOW_MACHINES", "SALA_CONFIG", "XDG_CONFIG_HOME", "XDG_STATE_HOME")]:
    del os.environ[_k]
os.environ["SALA_CONFIG"] = str(T / "no-such-config")

_spec = importlib.util.spec_from_file_location("machine_follow", SCRIPT)
mf = importlib.util.module_from_spec(_spec)
sys.modules["machine_follow"] = mf        # (dataclasses looks its module up)
_spec.loader.exec_module(mf)

DATA = """
run_on = "coord-box"

[machines.alpha-box]
follows = ["stackshot", "salamander", "claude-cli", "gbrain"]
command = ["step-alpha"]
reach = "ops@alpha-box"
timeout_minutes = 15
catch_up_minutes = 9

[machines.beta-box]
follows = ["gbrain"]
command = ["step-beta"]
timeout_minutes = 150
catch_up_minutes = 1440
retry_minutes = 60
"""
REAL_RUN_COMMAND = mf.run_command
REAL_INSTANCE_ACTIVE, REAL_START_INSTANCE = mf.instance_active, mf.start_instance
FPS = {"stackshot": "ss1", "salamander": "sa1", "claude-cli": "2.1.1", "gbrain": "0.60.1:aaaa"}


# ---- a small harness: cases with fixtures (tmp_path, monkeypatch, capsys, env, steps, real_things), asserts, one line per case ---------------------

CASES = []


def case(fn=None, *, params=None):
    def reg(f):
        if params is None:
            CASES.append((f.__name__, f, {}))
        else:
            for i, p in enumerate(params):
                CASES.append(("%s[%d]" % (f.__name__, i), f, {"_param": p}))
        return f
    return reg(fn) if fn else reg


class Monkey:
    def __init__(self, stack):
        self.stack = stack

    def setenv(self, k, v):
        self.stack.enter_context(mock.patch.dict(os.environ, {k: v}))

    def setattr(self, obj, name, value):
        self.stack.enter_context(mock.patch.object(obj, name, value))


class Cap:
    def __init__(self, stack):
        self.o, self.e = io.StringIO(), io.StringIO()
        stack.enter_context(contextlib.redirect_stdout(self.o))
        stack.enter_context(contextlib.redirect_stderr(self.e))

    def readouterr(self):
        r = SimpleNamespace(out=self.o.getvalue(), err=self.e.getvalue())
        self.o.seek(0), self.o.truncate(), self.e.seek(0), self.e.truncate()
        return r


class raises:
    """pytest.raises(exc, match=text): the text must be in the message."""
    def __init__(self, exc, match):
        self.exc, self.match = exc, match

    def __enter__(self):
        return self

    def __exit__(self, et, ev, tb):
        assert et is not None and issubclass(et, self.exc), "no %s raised" % self.exc.__name__
        assert self.match in str(ev), (self.match, str(ev))
        return True


def make_env(tmp_path, monkeypatch):
    home = tmp_path / "home"
    g = home / ".bun/install/global"
    (g / "node_modules/gbrain").mkdir(parents=True)
    (g / "bun.lock").write_text("lock\n")
    (g / "node_modules/gbrain/package.json").write_text('{"version": "0.60.1"}\n')
    for p in (g / "bun.lock", g / "node_modules/gbrain/package.json"):
        os.utime(p, (1_000_000, 1_000_000))                                   # long still
    data = tmp_path / "machines.toml"
    data.write_text(DATA)
    state = tmp_path / "state"
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("MACHINE_FOLLOW_MACHINES", str(data))
    monkeypatch.setenv("MACHINE_FOLLOW_STATE", str(state))
    monkeypatch.setattr(mf, "this_host", lambda: "coord-box")
    fps = dict(FPS)
    monkeypatch.setattr(mf, "fingerprint", lambda thing: fps[thing])
    e = SimpleNamespace()
    e.home, e.g, e.data, e.state, e.fps = home, g, data, state, fps
    e.ran, e.rc, e.reach_calls, e.reach_ok, e.sleeps = [], {}, [], {"ops@alpha-box": True}, []
    e.started, e.active = [], set()                                           # the instances the dispatcher started / that are running
    monkeypatch.setattr(mf, "instance_active", lambda h: h in e.active)
    monkeypatch.setattr(mf, "start_instance", lambda h: e.started.append(h) or True)

    def run_command(argv, timeout_s):
        e.ran.append((argv[0], timeout_s))
        return e.rc.get(argv[0], 0)
    monkeypatch.setattr(mf, "run_command", run_command)
    monkeypatch.setattr(mf, "reachable", lambda t: e.reach_calls.append(t) or e.reach_ok[t])

    def sleep(s):
        e.sleeps.append(s)
        if e.age_on_sleep:                                                    # the install "settles" while we wait
            for p in (g / "bun.lock", g / "node_modules/gbrain/package.json"):
                os.utime(p, (1_000_000, 1_000_000))
    e.age_on_sleep = True
    monkeypatch.setattr(mf, "_sleep", sleep)
    e.hosts_run = lambda: [{"step-alpha": "alpha-box", "step-beta": "beta-box"}[a] for a, _ in e.ran]
    e.saved = lambda h: json.loads((state / f"{h}.json").read_text())

    def age(h, secs):                                                         # the last successful follow of h was secs earlier
        d = e.saved(h)
        d["at_epoch"] -= secs
        (state / f"{h}.json").write_text(json.dumps(d))
    e.age = age
    return e


def make_real_things(tmp_path, monkeypatch):
    home = tmp_path / "home"
    monkeypatch.setenv("HOME", str(home))
    git = ["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false"]
    for r in ("stackshot", "salamander"):
        (home / r).mkdir(parents=True)
        subprocess.run([*git[:1], "init", "-q", str(home / r)], check=True)
        subprocess.run([*git, "-C", str(home / r), "commit", "-q", "--allow-empty", "-m", "one"], check=True)
    v = home / ".local/share/claude/versions"
    v.mkdir(parents=True)
    (v / "2.1.1").write_text("x")
    (v / "2.1.2").write_text("y")
    (home / ".local/bin").mkdir(parents=True)
    (home / ".local/bin/claude").symlink_to(v / "2.1.1")
    g = home / ".bun/install/global"
    (g / "node_modules/gbrain").mkdir(parents=True)
    (g / "bun.lock").write_text("lock-1\n")
    (g / "node_modules/gbrain/package.json").write_text('{"version": "0.60.1"}\n')
    return home, git


def make_steps(monkeypatch):
    calls, results = [], {}

    def run_command(argv, timeout_s):
        calls.append((argv[0], timeout_s))
        return results.get(argv[0], 0)
    monkeypatch.setattr(mf, "run_command", run_command)
    m = mf.Machine("beta-box", ["claude-cli", "gbrain"], ["main"], 150, before_command=["pre"])
    return m, calls, results


def run_case(name, fn, extra):
    tmp = T / re.sub(r"[^A-Za-z0-9_.-]", "_", name)
    tmp.mkdir()
    stack = contextlib.ExitStack()
    try:
        with stack:
            mk = Monkey(stack)
            cap = Cap(stack)
            args, cache = {}, {}
            for p in fn.__code__.co_varnames[:fn.__code__.co_argcount]:
                if p == "_param":
                    args[p] = extra["_param"]
                elif p == "tmp_path":
                    args[p] = tmp
                elif p == "monkeypatch":
                    args[p] = mk
                elif p == "capsys":
                    args[p] = cap
                elif p == "env":
                    args[p] = cache.setdefault("env", make_env(tmp, mk))
                elif p == "real_things":
                    args[p] = make_real_things(tmp, mk)
                elif p == "steps":
                    args[p] = make_steps(mk)
                else:
                    raise RuntimeError("no fixture " + p)
            fn(**args)
        return None
    except BaseException:
        return traceback.format_exc(limit=-2)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def run(capsys, e, *args):
    """What systemd does: the dispatcher, then every instance it started, one after the other (in the real thing, side by side)."""
    e.started.clear()
    rc = mf.main(list(args))
    for host in list(e.started):
        rc = max(rc, mf.main(["--host", host]))
    return rc, capsys.readouterr().out


def run_host(capsys, *args):
    rc = mf.main(list(args))
    return rc, capsys.readouterr().out


def secs(unit_text):
    m = re.search(r"^TimeoutStartSec=(\d+)(h|min)", unit_text, re.M)
    return int(m.group(1)) * {"h": 3600, "min": 60}[m.group(2)]


# ---- the data file and the setting that names it -----------------------------------------------------------------------------------------------

@case
def test_parsing_a_data_file(env):
    run_on, machines = mf.load_machines(env.data)
    assert run_on == "coord-box" and [m.host for m in machines] == ["alpha-box", "beta-box"]
    alpha, beta = machines
    assert (alpha.reach, alpha.catch_up_minutes, alpha.retry_minutes, alpha.timeout_minutes) == ("ops@alpha-box", 9, 0, 15)
    assert (beta.reach, beta.catch_up_minutes, beta.retry_minutes, beta.timeout_minutes) == (None, 1440, 60, 150)
    assert alpha.before_command is None


WRONG = [
    (lambda t: t.replace('"stackshot", ', '"stack-shot", '), "follows must be"),
    (lambda t: t.replace('command = ["step-beta"]\n', ''), "command must be"),
    (lambda t: t.replace("timeout_minutes = 150", 'timeout_minutes = "150"'), "timeout_minutes"),
    (lambda t: t.replace("timeout_minutes = 150", "timeout_minutes = 0"), "timeout_minutes"),
    (lambda t: t.replace("retry_minutes = 60", "retry_minute = 60"), "unknown field"),
    (lambda t: t.replace("[machines.beta-box]", "[machines.'bad host']"), "not a hostname"),
    (lambda t: t.replace('run_on = "coord-box"', ""), "run_on"),
    (lambda t: t.split("[machines")[0], "no [machines"),
    (lambda t: t + "\n[oops", "machines.toml"),
]


@case(params=WRONG)
def test_a_wrong_entry_is_refused_by_name(env, capsys, _param):
    edit, complaint = _param
    env.data.write_text(edit(DATA))
    with raises(mf.ConfigError, match=complaint):
        mf.load_machines(env.data)
    rc = mf.main([])
    assert rc == 2 and not env.state.exists() and env.ran == []
    assert "machine-follow:" in capsys.readouterr().err


@case(params=['"bash"', "[]", '["", "x"]', "[1]"])
def test_a_wrong_before_command_is_refused_by_name(tmp_path, _param):
    f = tmp_path / "m.toml"
    f.write_text('run_on = "coord-box"\n[machines.h]\nfollows = ["gbrain"]\ncommand = ["x"]\nbefore_command = %s\ntimeout_minutes = 5\n' % _param)
    with raises(mf.ConfigError, match="before_command must be"):
        mf.load_machines(f)


@case
def test_the_data_file_is_found_by_the_setting_and_a_missing_one_is_one_line_and_exit_2(env, monkeypatch, capsys):
    # nothing named: the default under the config folder (XDG_CONFIG_HOME, else ~/.config), and it is missing
    monkeypatch.setenv("MACHINE_FOLLOW_MACHINES", "")
    cfg = env.home / ".config"
    assert mf.machines_file() == cfg / "salamander/machine-follow.toml"
    monkeypatch.setenv("XDG_CONFIG_HOME", str(env.home / "xdg"))
    assert mf.machines_file() == env.home / "xdg/salamander/machine-follow.toml"
    rc = mf.main([])
    err = capsys.readouterr().err
    assert rc == 2 and len(err.strip().splitlines()) == 1 and "machine-follow:" in err and "SALA_MACHINE_FOLLOW_MACHINES" in err and str(env.home / "xdg") in err
    assert not env.state.exists() and env.ran == [] and env.started == []
    # the setting in sala's config file, a leading ~ expanded, the last assignment winning, a comment after it ignored
    conf = env.home / "config"
    conf.write_text("SALA_MACHINE_FOLLOW_MACHINES=/nowhere/old.toml\nexport SALA_MACHINE_FOLLOW_MACHINES=~/ops/machines.toml   # the owner's data\n")
    monkeypatch.setenv("SALA_CONFIG", str(conf))
    assert mf.machines_file() == env.home / "ops/machines.toml"
    (env.home / "ops").mkdir()
    (env.home / "ops/machines.toml").write_text(DATA)
    assert mf.main(["--dry-run"]) == 0 and "alpha-box: would start" in capsys.readouterr().out
    # the process environment wins over the config file, the test variable over both
    other = env.home / "other.toml"
    other.write_text(DATA.replace("alpha-box", "gamma-box"))
    monkeypatch.setenv("SALA_MACHINE_FOLLOW_MACHINES", str(other))
    assert mf.machines_file() == other
    assert mf.main(["--dry-run"]) == 0 and "gamma-box: would start" in capsys.readouterr().out
    monkeypatch.setenv("MACHINE_FOLLOW_MACHINES", str(env.data))
    assert mf.machines_file() == env.data
    # a quoted value and an unreadable config file
    conf.write_text('SALA_MACHINE_FOLLOW_MACHINES="$HOME/quoted.toml"\n')
    monkeypatch.setenv("SALA_MACHINE_FOLLOW_MACHINES", "")
    monkeypatch.setenv("MACHINE_FOLLOW_MACHINES", "")
    assert mf.machines_file() == env.home / "quoted.toml"
    monkeypatch.setenv("SALA_CONFIG", str(env.home / "no-such-file"))
    assert mf.machines_file() == env.home / "xdg/salamander/machine-follow.toml"


@case
def test_the_units_agree_with_the_script_and_the_data_file(env):
    _, machines = mf.load_machines(env.data)
    for n in ("machine-follow.path", "machine-follow.service", "machine-follow@.service", "machine-follow.timer"):
        assert (UNITS / n).is_file(), n
    path = (UNITS / "machine-follow.path").read_text()
    watched = set(re.findall(r"^PathChanged=(.*)$", path, re.M))
    assert watched == {"%h/stackshot/.git/refs/heads/main", "%h/salamander/.git/refs/heads/main", "%h/.bun/install/global/bun.lock", "%h/.local/bin/claude"}
    assert "Unit=machine-follow.service" in path and "WantedBy=paths.target" in path
    assert {t for m in machines for t in m.follows} <= set(mf.THINGS)
    timer = (UNITS / "machine-follow.timer").read_text()
    assert "OnUnitActiveSec=10min" in timer and "OnBootSec=5min" in timer and "WantedBy=timers.target" in timer
    assert SCRIPT.is_file()


@case
def test_the_dispatcher_is_quick_and_the_template_runs_one_machine_within_its_limit(env):
    _, machines = mf.load_machines(env.data)
    disp = (UNITS / "machine-follow.service").read_text()
    assert "Type=oneshot" in disp and "ExecStart=/usr/bin/python3 %h/salamander/lib/machine-follow.py\n" in disp and "--host" not in disp.split("[Service]")[1]
    assert secs(disp) <= 600                                                    # it only starts instances
    tmpl = (UNITS / "machine-follow@.service").read_text()
    assert "Type=oneshot" in tmpl and "ExecStart=/usr/bin/python3 %h/salamander/lib/machine-follow.py --host %i\n" in tmpl and not re.search(r"^\[Install\]", tmpl, re.M)
    # one machine's settle wait plus its step, the largest of them (the 150 min machine), with margin
    assert secs(tmpl) > max(m.timeout_minutes for m in machines) * 60 + mf.SETTLE_MAX
    assert "TimeoutStartSec=3h\n" in tmpl


# ---- who runs on a trigger -----------------------------------------------------------------------------------------------------------

@case
def test_a_first_run_follows_every_machine_in_file_order_and_writes_their_state(env, capsys):
    rc, out = run(capsys, env)
    assert rc == 0 and env.hosts_run() == ["alpha-box", "beta-box"]
    assert env.ran == [("step-alpha", 15 * 60), ("step-beta", 150 * 60)]       # each with its own limit
    assert "alpha-box: following (never followed)" in out and "beta-box: followed" in out
    assert env.saved("alpha-box")["followed"] == FPS and env.saved("beta-box")["followed"] == {"gbrain": "0.60.1:aaaa"}
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d", env.saved("beta-box")["at"])      # the machine's own offset


@case
def test_nothing_changed_runs_nothing(env, capsys):
    run(capsys, env)
    env.ran.clear()
    rc, out = run(capsys, env)
    assert rc == 0 and env.ran == [] and env.reach_calls == ["ops@alpha-box"]    # (the probe of the first run only)
    assert "alpha-box: current" in out and "beta-box: current" in out


@case(params=[
    ("stackshot", ["alpha-box"]),                 # a stackshot deploy: beta-box does not follow stackshot
    ("salamander", ["alpha-box"]),
    ("claude-cli", ["alpha-box"]),
    ("gbrain", ["alpha-box", "beta-box"]),        # a gbrain install: both
])
def test_a_trigger_runs_only_the_machines_that_follow_what_changed(env, capsys, _param):
    changed, who = _param
    run(capsys, env)
    env.ran.clear()
    env.fps[changed] += "-new"
    rc, out = run(capsys, env)
    assert rc == 0 and env.hosts_run() == who
    assert f"{changed} changed" in out
    if "beta-box" not in who:
        assert "beta-box: current" in out


@case
def test_the_catch_up_makes_a_machine_due_after_its_minutes(env, capsys):
    run(capsys, env)
    env.ran.clear()
    env.age("alpha-box", 8 * 60); env.age("beta-box", 8 * 60)
    run(capsys, env)
    assert env.ran == []                                                       # alpha-box's 9 min and beta-box's day not yet
    env.age("alpha-box", 2 * 60)
    rc, out = run(capsys, env)
    assert env.hosts_run() == ["alpha-box"] and "last followed more than 9 min ago" in out
    env.ran.clear()
    env.age("beta-box", 25 * 3600)
    rc, out = run(capsys, env)
    assert "beta-box" in env.hosts_run() and "last followed more than 1440 min ago" in out


@case
def test_a_named_machine_only_and_force(env, capsys):
    run(capsys, env)
    env.ran.clear()
    rc, out = run_host(capsys, "--host", "beta-box")
    assert env.ran == [] and "alpha-box" not in out and "beta-box: current" in out      # one machine, and it is current
    rc, out = run_host(capsys, "--host", "beta-box", "--force")
    assert env.hosts_run() == ["beta-box"] and "(forced)" in out
    assert mf.main(["--host", "nobody"]) == 2 and "nobody is not in machines.toml" in capsys.readouterr().err
    assert mf.main(["--force"]) == 2 and "--force needs --host" in capsys.readouterr().err


@case
def test_dry_run_says_who_is_due_and_changes_nothing(env, capsys):
    rc, out = run(capsys, env, "--dry-run")
    assert rc == 0 and "alpha-box: would start machine-follow@alpha-box.service (never followed)" in out and "beta-box: would start" in out
    assert env.started == [] and env.ran == [] and env.reach_calls == [] and not env.state.exists() and env.sleeps == []
    rc, out = run_host(capsys, "--host", "alpha-box", "--dry-run")
    assert "alpha-box: would follow (never followed)" in out and env.ran == [] and env.reach_calls == [] and not env.state.exists()


@case
def test_it_refuses_on_any_host_but_the_one_in_the_data_file(env, monkeypatch, capsys):
    monkeypatch.setattr(mf, "this_host", lambda: "alpha-box")
    assert mf.main([]) == 64 and "run this on coord-box, not on alpha-box" in capsys.readouterr().err
    assert mf.main(["--host", "alpha-box"]) == 64
    assert env.ran == [] and env.started == [] and not env.state.exists()


@case
def test_a_second_run_of_the_same_machine_at_the_same_time_does_nothing(env, capsys):
    env.state.mkdir(parents=True)
    held = open(env.state / "alpha-box.lock", "w")
    try:
        fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
        rc, out = run_host(capsys, "--host", "alpha-box")
        assert rc == 0 and env.ran == [] and "alpha-box: another run is in progress" in out
        rc, out = run_host(capsys, "--host", "beta-box")                          # another machine is not held up by it
        assert env.hosts_run() == ["beta-box"]
    finally:
        held.close()


# ---- the dispatcher ------------------------------------------------------------------------------------------------------------------

@case
def test_the_dispatcher_starts_the_instances_of_the_due_machines_and_runs_nothing_itself(env, capsys):
    run(capsys, env)
    env.ran.clear(); env.sleeps.clear(); env.reach_calls.clear()
    env.fps["stackshot"] += "-new"
    env.started.clear()
    rc = mf.main([])
    out = capsys.readouterr().out
    assert rc == 0 and env.started == ["alpha-box"]                             # beta-box does not follow stackshot
    assert "alpha-box: due (stackshot changed): started machine-follow@alpha-box.service" in out and "beta-box: current" in out
    assert env.ran == [] and env.sleeps == [] and env.reach_calls == []         # no step, no settle wait, no probe: that is the instance's
    env.started.clear()
    env.fps["gbrain"] += "-new"
    mf.main([])
    assert env.started == ["alpha-box", "beta-box"]


@case
def test_an_instance_that_is_still_running_is_not_started_again(env, capsys):
    run(capsys, env)
    env.fps["gbrain"] += "-new"
    env.active.add("beta-box")                                                  # waiting on the release lock
    env.started.clear()
    assert mf.main([]) == 0
    out = capsys.readouterr().out
    assert env.started == ["alpha-box"]                                         # a slow beta-box does not hold alpha-box up
    assert "beta-box: due (gbrain changed), machine-follow@beta-box.service is still running: left alone" in out


@case
def test_a_machine_held_back_by_its_retry_is_not_started(env, capsys):
    run(capsys, env)
    env.fps["gbrain"] += "-new"
    env.rc["step-beta"] = 75
    run(capsys, env)
    env.started.clear()
    mf.main([])
    out = capsys.readouterr().out
    assert env.started == [] and "beta-box: due (gbrain changed) but tried" in out and "alpha-box: current" in out


@case
def test_the_dispatcher_uses_the_systemctl_user_commands(tmp_path, monkeypatch):
    bin_ = tmp_path / "bin"
    bin_.mkdir()
    log = tmp_path / "calls"
    (bin_ / "systemctl").write_text(f'#!/bin/sh\necho "$*" >> {log}\n[ "$4" = machine-follow@beta-box.service ] && [ "$2" = is-active ] && exit 3\nexit 0\n')
    (bin_ / "systemctl").chmod(0o755)
    monkeypatch.setenv("PATH", f"{bin_}:{os.environ['PATH']}")
    assert REAL_INSTANCE_ACTIVE("alpha-box") is True and REAL_INSTANCE_ACTIVE("beta-box") is False
    assert REAL_START_INSTANCE("alpha-box") is True
    assert log.read_text().splitlines() == ["--user is-active --quiet machine-follow@alpha-box.service",
                                            "--user is-active --quiet machine-follow@beta-box.service",
                                            "--user start --no-block machine-follow@alpha-box.service"]


# ---- the settle rule --------------------------------------------------------------------------------------------------------------

@case
def test_each_due_gbrain_follower_waits_until_the_install_has_been_still_60_s(env, capsys):
    for p in (env.g / "bun.lock", env.g / "node_modules/gbrain/package.json"):
        os.utime(p, None)                                                       # the cutover just wrote them
    assert mf.SETTLE == 60 and mf.SETTLE_MAX == 600
    env.fps["gbrain"] = "0.60.2:bbbb"
    rc, out = run(capsys, env)
    assert env.sleeps == [10]                                                   # one poll, then "settled" (the fake sleep aged the files)
    assert rc == 0 and env.hosts_run() == ["alpha-box", "beta-box"]


@case
def test_settled_needs_both_files_old_enough_and_the_package_there(env):
    now = time.time()
    assert mf.settled()
    os.utime(env.g / "bun.lock", (now - 30, now - 30))
    assert not mf.settled()                                                     # bun.lock rewritten 30 s ago
    os.utime(env.g / "bun.lock", (now - 61, now - 61))
    os.utime(env.g / "node_modules/gbrain/package.json", (now - 30, now - 30))
    assert not mf.settled()                                                     # the package written after it, 30 s ago
    os.utime(env.g / "node_modules/gbrain/package.json", (now - 61, now - 61))
    assert mf.settled()
    (env.g / "node_modules/gbrain/package.json").unlink()
    assert not mf.settled()                                                     # mid-install: no package yet


@case
def test_an_install_that_never_settles_leaves_the_gbrain_followers_to_the_next_run(env, capsys):
    env.data.write_text(DATA + '\n[machines.delta-box]\nfollows = ["stackshot"]\ncommand = ["step-delta"]\ntimeout_minutes = 5\n')
    env.age_on_sleep = False
    (env.g / "node_modules/gbrain/package.json").unlink()                      # never finishes
    rc, out = run(capsys, env)
    assert rc == 0 and [a for a, _ in env.ran] == ["step-delta"]               # not a failure; the machine that does not follow gbrain ran
    assert sum(env.sleeps) == 1200 and set(env.sleeps) == {10}                 # each of the two gbrain followers waited its 10 min
    assert "still changing after 10 min" in out and "coord-box's gbrain install is still changing" in out     # the line names the host this runs on
    assert not (env.state / "alpha-box.json").exists() and not (env.state / "beta-box.json").exists() and (env.state / "delta-box.json").exists()


@case
def test_a_machine_that_does_not_follow_gbrain_never_waits_for_the_install(env, capsys):
    env.data.write_text('run_on = "coord-box"\n[machines.delta-box]\nfollows = ["stackshot"]\ncommand = ["step-delta"]\ntimeout_minutes = 5\n')
    os.utime(env.g / "bun.lock", None)                                          # a cutover is writing right now
    env.age_on_sleep = False
    rc, out = run(capsys, env)
    assert rc == 0 and [a for a, _ in env.ran] == ["step-delta"] and env.sleeps == []


# ---- a machine that is off, or a step that fails ------------------------------------------------------------------------------------------

@case
def test_an_unreachable_machine_is_not_a_failure_and_records_nothing_as_followed(env, capsys):
    env.reach_ok["ops@alpha-box"] = False
    rc, out = run(capsys, env)
    assert rc == 0 and env.hosts_run() == ["beta-box"]                          # alpha-box's step never ran; the other machine did
    assert "alpha-box: not reachable (stopped?): nothing done, the next run tries again" in out
    assert not (env.state / "alpha-box.json").exists() and (env.state / "beta-box.json").exists()
    assert json.loads((env.state / "alpha-box.attempt.json").read_text())["result"] == "skipped"
    env.reach_ok["ops@alpha-box"] = True                                        # it comes back: the very next run follows it
    env.ran.clear()
    rc, out = run(capsys, env)
    assert rc == 0 and env.hosts_run() == ["alpha-box"] and (env.state / "alpha-box.json").exists()
    assert not (env.state / "alpha-box.attempt.json").exists()


@case
def test_a_step_that_says_not_ready_is_a_skip_not_a_failure(env, capsys):
    env.rc["step-beta"] = 75                                                    # unreachable, or the coordinator's gbrain not serving
    rc, out = run(capsys, env)
    assert rc == 0 and env.hosts_run() == ["alpha-box", "beta-box"]
    assert "beta-box: not ready or not reachable: nothing done, the next run tries again" in out
    assert (env.state / "alpha-box.json").exists() and not (env.state / "beta-box.json").exists()


@case
def test_a_failing_step_fails_its_instance_and_not_the_others(env, capsys):
    env.rc["step-alpha"] = 1
    rc, out = run(capsys, env)
    assert rc == 1 and env.hosts_run() == ["alpha-box", "beta-box"]
    assert "alpha-box: FAILED (exit 1)" in out
    assert not (env.state / "alpha-box.json").exists() and (env.state / "beta-box.json").exists()
    assert json.loads((env.state / "alpha-box.attempt.json").read_text())["result"] == "failed"


@case
def test_the_state_file_is_written_only_on_success_and_an_old_one_survives_a_failure(env, capsys):
    run(capsys, env)
    old = env.saved("beta-box")
    attempt = env.state / "beta-box.attempt.json"
    env.fps["gbrain"] = "0.60.2:bbbb"
    env.rc["step-beta"] = 1
    assert run(capsys, env)[0] == 1
    assert env.saved("beta-box") == old and json.loads(attempt.read_text())["result"] == "failed"      # still the build it last followed
    attempt.unlink()
    env.rc["step-beta"] = 75
    assert run(capsys, env)[0] == 0
    assert env.saved("beta-box") == old and json.loads(attempt.read_text())["result"] == "skipped"
    attempt.unlink()
    env.rc["step-beta"] = 0
    assert run(capsys, env)[0] == 0
    assert env.saved("beta-box")["followed"] == {"gbrain": "0.60.2:bbbb"} and not attempt.exists()


@case
def test_a_skipped_machine_waits_its_retry_minutes_unless_something_new_changed(env, capsys):
    run(capsys, env)
    env.ran.clear()
    env.fps["gbrain"] = "0.60.2:bbbb"
    env.rc["step-beta"] = 75
    run(capsys, env)                                                                 # the try that skips
    assert env.hosts_run().count("beta-box") == 1
    env.ran.clear()
    rc, out = run(capsys, env)
    assert "beta-box" not in env.hosts_run() and "waits for the 60 min retry" in out      # no ssh to it every 10 min
    env.fps["gbrain"] = "0.60.3:cccc"                                           # the coordinator installed again: new, so no waiting
    run(capsys, env)
    assert "beta-box" in env.hosts_run()
    env.ran.clear()
    a = json.loads((env.state / "beta-box.attempt.json").read_text())
    a["at_epoch"] -= 61 * 60                                                    # an hour later
    (env.state / "beta-box.attempt.json").write_text(json.dumps(a))
    run(capsys, env)
    assert "beta-box" in env.hosts_run()


# ---- the two steps of one entry (before_command) ------------------------------------------------------------------------------------------

@case(params=[(0, 0, 0), (75, 0, 75), (0, 75, 75), (75, 75, 75), (1, 0, 1), (124, 0, 124), (1, 75, 1), (0, 1, 1), (75, 2, 2), (1, 2, 2)])
def test_both_steps_always_run_and_the_result_is_the_worse_of_the_two(steps, _param):
    pre, main, want = _param
    m, calls, results = steps
    results.update(pre=pre, main=main)
    assert mf.run_steps(m) == want
    assert [c[0] for c in calls] == ["pre", "main"]                                  # the main step runs even after a failed first one


@case
def test_the_first_step_is_capped_and_the_main_step_keeps_the_rest_of_the_limit(steps):
    m, calls, _ = steps
    mf.run_steps(m)
    assert calls[0] == ("pre", mf.BEFORE_MAX_MINUTES * 60) and 150 * 60 - 60 <= calls[1][1] <= 150 * 60
    m2 = mf.Machine("x", ["gbrain"], ["main"], 5, before_command=["pre"])
    calls.clear()
    mf.run_steps(m2)
    assert calls[0] == ("pre", 5 * 60)                                               # never more than the entry's own limit


@case
def test_an_entry_without_a_before_step_runs_only_its_command(steps):
    _, calls, _ = steps
    m = mf.Machine("alpha-box", ["gbrain"], ["main"], 15)
    assert mf.run_steps(m) == 0 and calls == [("main", 15 * 60)]


# ---- the real process runner, the real fingerprints and the real command ------------------------------------------------------------------------------

@case
def test_run_command_expands_home_kills_a_step_past_its_limit_and_returns_the_exit_code(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    marker = tmp_path / "ran"
    step = tmp_path / "step.sh"
    step.write_text(f'#!/bin/sh\necho "$1" > "{marker}"\nexit 75\n')
    step.chmod(0o755)
    assert mf.run_command(["~/step.sh", "arg"], 30) == 75 and marker.read_text() == "arg\n"
    assert mf.run_command(["sh", "-c", "exit 3"], 30) == 3
    assert mf.run_command(["sh", "-c", "sleep 60"], 1) == 124                  # killed with its whole group at the limit
    assert mf.run_command(["/nonexistent/step"], 5) == 127


@case
def test_main_with_the_real_runner_reads_the_exit_codes(env, monkeypatch, capsys):
    monkeypatch.setattr(mf, "run_command", REAL_RUN_COMMAND)
    env.data.write_text('run_on = "coord-box"\n'
                        '[machines.ok-box]\nfollows = ["stackshot"]\ncommand = ["sh", "-c", "exit 0"]\ntimeout_minutes = 1\n'
                        '[machines.off-box]\nfollows = ["stackshot"]\ncommand = ["sh", "-c", "exit 75"]\ntimeout_minutes = 1\n'
                        '[machines.broken-box]\nfollows = ["stackshot"]\ncommand = ["sh", "-c", "exit 2"]\ntimeout_minutes = 1\n')
    rc, out = run(capsys, env)
    assert rc == 1                                                              # only the broken one fails the run
    assert "ok-box: followed" in out and "off-box: not ready or not reachable" in out and "broken-box: FAILED (exit 2)" in out
    assert [p.name for p in sorted(env.state.glob("*-box*.json"))] == ["broken-box.attempt.json", "off-box.attempt.json", "ok-box.json"]


@case
def test_the_real_fingerprints_change_when_the_thing_changes(real_things):
    home, git = real_things
    before = {t: mf.fingerprint(t) for t in mf.THINGS}
    assert before["stackshot"] != "unreadable" and re.fullmatch(r"[0-9a-f]{40}", before["stackshot"])
    assert before["claude-cli"] == "2.1.1" and before["gbrain"].startswith("0.60.1:")
    subprocess.run([*git, "-C", str(home / "stackshot"), "commit", "-q", "--allow-empty", "-m", "two"], check=True)
    assert mf.fingerprint("stackshot") != before["stackshot"] and mf.fingerprint("salamander") == before["salamander"]
    (home / ".local/bin/claude").unlink()
    (home / ".local/bin/claude").symlink_to(home / ".local/share/claude/versions/2.1.2")
    assert mf.fingerprint("claude-cli") == "2.1.2"
    (home / ".bun/install/global/bun.lock").write_text("lock-2\n")
    assert mf.fingerprint("gbrain") != before["gbrain"]
    same = mf.fingerprint("gbrain")
    (home / ".bun/install/global/bun.lock").write_text("lock-2\n")             # a rewrite with the same content is not a change
    assert mf.fingerprint("gbrain") == same


@case
def test_an_unreadable_thing_has_a_stable_fingerprint_that_cannot_make_a_machine_due(real_things):
    home, _ = real_things
    (home / ".bun/install/global/bun.lock").unlink()
    (home / ".local/bin/claude").unlink()
    assert mf.fingerprint("gbrain") == "unreadable" and mf.fingerprint("claude-cli") == "unreadable"
    (home / "salamander/.git").rename(home / "salamander/.gitx")
    assert mf.fingerprint("salamander") == "unreadable"


@case
def test_the_script_as_a_command_with_an_isolated_home(tmp_path):
    """The real file run the way the units run it (python3 + the path), HOME and the config under the scratch folder: the data file found by the
    setting in the config file, the wrong host refused (64), the right one dry-run (nothing written, no systemctl), a missing data file one line (2)."""
    home = tmp_path / "home"
    home.mkdir()
    me = socket.gethostname().split(".")[0]
    (home / ".config/salamander").mkdir(parents=True)
    data = home / "ops-data.toml"
    env = {"HOME": str(home), "PATH": os.environ["PATH"], "LANG": "C.UTF-8"}

    def cmd(*args):
        return subprocess.run([sys.executable, "-I", str(SCRIPT), *args], capture_output=True, text=True, env=env, cwd=str(tmp_path), timeout=60)
    r = cmd("--dry-run")
    assert r.returncode == 2 and r.stdout == "" and len(r.stderr.strip().splitlines()) == 1 and "salamander/machine-follow.toml" in r.stderr, (r.returncode, r.stderr)
    (home / ".config/salamander/config").write_text("SALA_MACHINE_FOLLOW_MACHINES=~/ops-data.toml\n")
    r = cmd("--dry-run")
    assert r.returncode == 2 and str(data) in r.stderr and len(r.stderr.strip().splitlines()) == 1, (r.returncode, r.stderr)
    data.write_text(DATA)                                                       # run_on is a host this is not
    r = cmd("--dry-run")
    assert r.returncode == 64 and "run this on coord-box, not on " + me in r.stderr, (r.returncode, r.stderr)
    data.write_text(DATA.replace("coord-box", me))
    r = cmd("--dry-run")
    assert r.returncode == 0 and r.stderr == "", (r.returncode, r.stderr)
    assert "machine-follow: alpha-box: would start machine-follow@alpha-box.service (never followed)" in r.stdout and "beta-box: would start" in r.stdout, r.stdout
    assert not (home / ".local/state/machine-follow").exists()
    r = cmd("--host", "alpha-box", "--dry-run")
    assert r.returncode == 0 and "alpha-box: would follow (never followed)" in r.stdout and not (home / ".local/state").exists(), (r.stdout, r.stderr)
    r = cmd("--help")
    assert r.returncode == 0 and "--host" in r.stdout and "--dry-run" in r.stdout and "--force" in r.stdout


def main():
    bad = []
    only = sys.argv[1:]
    n = 0
    for name, fn, extra in CASES:
        if only and not any(o in name for o in only):
            continue
        n += 1
        err = run_case(name, fn, extra)
        if err is None:
            print("  ok   " + name)
        else:
            bad.append(name)
            print("  FAIL " + name + "\n" + err.rstrip()[-1500:])
    print("%d/%d checks passed" % (n - len(bad), n))
    return 1 if bad else 0


try:
    rc = main()
finally:
    os.close(_lock)                       # drops the lock; the folder goes with it
    shutil.rmtree(T, ignore_errors=True)
sys.exit(rc)
