#!/usr/bin/env python3
"""machine-follow.py -- run by machine-follow.service and machine-follow@<host>.service (systemd/, docs/units.md): the machines the
coordinator machine drives (the data file, machines.toml) follow what the coordinator runs. One script, one path unit, one timer.

Two modes, so a slow machine never holds up another (a stackshot deploy reaches a fast machine within minutes even while a slow one
waits on gbrain's release lock):

  machine-follow.py                 the dispatcher (machine-follow.service, started by the path unit and the 10 min timer; quick):
                                    take a fingerprint of what the machines follow (the stackshot and salamander commits, the Claude
                                    CLI version, the installed gbrain build), work out which machines are due (a followed thing differs
                                    from what the machine's last successful follow recorded in ~/.local/state/machine-follow/<host>.json,
                                    or its catch_up_minutes passed) and start machine-follow@<host>.service for each with
                                    `systemctl --user start --no-block`; an instance already active is left alone.
  machine-follow.py --host <host>   one machine's follow (machine-follow@<host>.service): decides again, waits until a gbrain install has
                                    been still for 60 s when the machine follows gbrain (a cutover rewrites bun.lock first and installs
                                    after it; up to 10 min, then the next dispatch tries again), probes the machine if it has `reach`,
                                    runs its step with its timeout_minutes, and writes the state only when the step exits 0.

A step's exit code: 0 followed; 75 (EX_TEMPFAIL) the machine is stopped, unreachable or not ready, nothing done, which is not a
failure (the next dispatch, or the retry_minutes after it, tries again, with no state written); anything else, or the step's
timeout_minutes, is a failure (the instance exits 1).

A machine entry may have a before_command (machines.toml): a second step run first, in the same instance, so one machine can follow
several things with independent steps (the Claude Code CLI, then gbrain). Both run every time; see run_steps.

  --dry-run   say which machines are due and why; start and run nothing, write nothing, touch no machine
  --force     with --host: treat the machine as due

The data file (machines.toml: run_on, the host this runs on, and one [machines.<hostname>] entry per machine) is not part of this
repository: it is the owner's data. Its path is the setting SALA_MACHINE_FOLLOW_MACHINES (the process environment, else the line in sala's
config file, `~/.config/salamander/config`), default `~/.config/salamander/machine-follow.toml`. A missing file is one line and exit 2.
Environment (tests): MACHINE_FOLLOW_MACHINES (the data file, wins over the setting), MACHINE_FOLLOW_STATE (the state folder),
MACHINE_FOLLOW_SETTLE, MACHINE_FOLLOW_SETTLE_MAX, MACHINE_FOLLOW_POLL (seconds).
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import signal
import socket
import subprocess
import sys
import time
import tomllib
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

EX_TEMPFAIL = 75
THINGS = ("stackshot", "salamander", "claude-cli", "gbrain")
SETTLE = int(os.environ.get("MACHINE_FOLLOW_SETTLE", "60"))             # s a gbrain install must have been still
SETTLE_MAX = int(os.environ.get("MACHINE_FOLLOW_SETTLE_MAX", "600"))    # s to wait for that; the unit's TimeoutStartSec counts it
POLL = int(os.environ.get("MACHINE_FOLLOW_POLL", "10"))
BEFORE_MAX_MINUTES = 20     # a before_command never takes more of the entry's timeout_minutes than this: the command keeps the rest
_KEYS = {"follows", "command", "before_command", "timeout_minutes", "reach", "catch_up_minutes", "retry_minutes"}
_sleep = time.sleep


class ConfigError(Exception):
    pass


@dataclass
class Machine:
    host: str
    follows: list[str]
    command: list[str]
    timeout_minutes: int
    reach: str | None = None
    catch_up_minutes: int = 0
    retry_minutes: int = 0
    before_command: list[str] | None = None


def home() -> Path:
    return Path(os.environ.get("HOME") or Path.home())


def sala_setting(name: str) -> str:
    """One sala setting, the way sala-web reads it (web/src/sala_web/config.py `sala_setting`): the process environment wins, else the
    line `NAME=value` in sala's config file ($SALA_CONFIG, default ~/.config/salamander/config; read as text, never sourced, so a quoted
    value, a trailing `# note`, an `export ` prefix and a leading $HOME or ~ are understood), else empty. The units carry no sala
    environment, so this is how a setting written once in sala's config reaches the script."""
    v = os.environ.get(name)
    if v:
        return v
    path = os.environ.get("SALA_CONFIG") or str(home() / ".config/salamander/config")
    found = ""
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                m = re.match(r"\s*(?:export\s+)?" + re.escape(name) + r"=(.*)$", line.rstrip("\n"))
                if m:
                    found = _config_value(m.group(1))     # the last assignment wins, as in a sourced file
    except (OSError, UnicodeDecodeError):
        return ""
    return found


def _config_value(raw: str) -> str:
    raw = raw.strip()
    if raw[:1] in ("'", '"'):
        end = raw.find(raw[0], 1)
        val = raw[1:end] if end > 0 else raw[1:]
    else:
        val = re.split(r"\s+#", raw, maxsplit=1)[0].strip()
    h = str(home())
    if val.startswith("~/") or val == "~":
        val = h + val[1:]
    return val.replace("${HOME}", h).replace("$HOME", h)


def machines_file() -> Path:
    v = os.environ.get("MACHINE_FOLLOW_MACHINES") or sala_setting("SALA_MACHINE_FOLLOW_MACHINES")
    return Path(v) if v else Path(os.environ.get("XDG_CONFIG_HOME") or home() / ".config") / "salamander/machine-follow.toml"


def state_dir() -> Path:
    return Path(os.environ.get("MACHINE_FOLLOW_STATE") or Path(os.environ.get("XDG_STATE_HOME") or home() / ".local/state") / "machine-follow")


def this_host() -> str:
    return socket.gethostname().split(".")[0]


def say(msg: str) -> None:
    print(f"machine-follow: {msg}", flush=True)


# ---- the data file ---------------------------------------------------------------------------------------------------------------
def load_machines(path: Path) -> tuple[str, list[Machine]]:
    """-> (the host this runs on, the machines in file order). ConfigError names the entry and the field that is wrong."""
    try:
        data = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as e:
        raise ConfigError(f"{path}: {e}")
    run_on = data.get("run_on")
    if not isinstance(run_on, str) or not run_on:
        raise ConfigError(f"{path}: run_on (the host this runs on) is missing")
    table = data.get("machines")
    if not isinstance(table, dict) or not table:
        raise ConfigError(f"{path}: no [machines.<hostname>] entry")
    out: list[Machine] = []
    for host, e in table.items():
        where = f"{path}: machines.{host}"
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]*", host):
            raise ConfigError(f"{where}: not a hostname")
        if not isinstance(e, dict):
            raise ConfigError(f"{where}: not a table")
        if set(e) - _KEYS:
            raise ConfigError(f"{where}: unknown field {sorted(set(e) - _KEYS)} (known: {sorted(_KEYS)})")
        follows, command = e.get("follows"), e.get("command")
        if not isinstance(follows, list) or not follows or any(t not in THINGS for t in follows):
            raise ConfigError(f"{where}: follows must be a non-empty list from {list(THINGS)}")
        if not isinstance(command, list) or not command or not all(isinstance(a, str) and a for a in command):
            raise ConfigError(f"{where}: command must be a non-empty list of strings")
        before = e.get("before_command")
        if before is not None and (not isinstance(before, list) or not before or not all(isinstance(a, str) and a for a in before)):
            raise ConfigError(f"{where}: before_command must be a non-empty list of strings")
        nums = {}
        for k, required in (("timeout_minutes", True), ("catch_up_minutes", False), ("retry_minutes", False)):
            v = e.get(k, None if required else 0)
            if isinstance(v, bool) or not isinstance(v, int) or v < (1 if required else 0):
                raise ConfigError(f"{where}: {k} must be a whole number of minutes" + (" above 0" if required else ""))
            nums[k] = v
        reach = e.get("reach")
        if reach is not None and (not isinstance(reach, str) or not reach):
            raise ConfigError(f"{where}: reach must be a user@host string")
        out.append(Machine(host, list(follows), list(command), reach=reach, before_command=list(before) if before else None, **nums))
    return run_on, out


# ---- what the coordinator runs ------------------------------------------------------------------------------------------------------------
def gbrain_dir() -> Path:
    return home() / ".bun/install/global"


def _git_head(repo: Path) -> str:
    r = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], capture_output=True, text=True, timeout=30)
    return r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else "unreadable"


def fingerprint(thing: str) -> str:
    """A string that changes when the thing changed on this host; 'unreadable' when it cannot be read (it then equals itself and
    cannot make a machine due, the catch-up still can)."""
    try:
        if thing in ("stackshot", "salamander"):
            return _git_head(home() / thing)
        if thing == "claude-cli":
            link = home() / ".local/bin/claude"
            return os.path.basename(os.path.realpath(link)) if link.exists() else "unreadable"
        g = gbrain_dir()
        ver = json.loads((g / "node_modules/gbrain/package.json").read_text(encoding="utf-8")).get("version", "?")
        return f"{ver}:{hashlib.sha256((g / 'bun.lock').read_bytes()).hexdigest()[:16]}"
    except (OSError, ValueError, subprocess.SubprocessError):
        return "unreadable"


def settled() -> bool:
    """this host's gbrain install has been still for SETTLE s: bun.lock and the installed package, which a cutover writes after it."""
    g, now = gbrain_dir(), time.time()
    try:
        return all(now - p.stat().st_mtime >= SETTLE for p in (g / "bun.lock", g / "node_modules/gbrain/package.json"))
    except OSError:
        return False


def wait_settled() -> bool:
    waited = 0
    while not settled():
        if waited >= SETTLE_MAX:
            return False
        _sleep(POLL)
        waited += POLL
    return True


# ---- state ------------------------------------------------------------------------------------------------------------------------
def read_json(p: Path) -> dict | None:
    try:
        d = json.loads(p.read_text(encoding="utf-8"))
        return d if isinstance(d, dict) else None
    except (OSError, ValueError):
        return None


def write_json(p: Path, data: dict) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_name(p.name + ".tmp")
    try:
        tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.replace(tmp, p)
    finally:
        tmp.unlink(missing_ok=True)


def state_path(host: str) -> Path:
    return state_dir() / f"{host}.json"


def attempt_path(host: str) -> Path:
    return state_dir() / f"{host}.attempt.json"


def record_success(m: Machine, seen: dict[str, str]) -> None:
    now = time.time()
    write_json(state_path(m.host), {"machine": m.host, "followed": {t: seen[t] for t in m.follows}, "at": datetime.now().astimezone().isoformat(timespec="seconds"), "at_epoch": int(now)})
    attempt_path(m.host).unlink(missing_ok=True)


def record_attempt(m: Machine, seen: dict[str, str], result: str) -> None:
    """A skip or a failure: what was seen is remembered (not as followed) so retry_minutes can hold the next try back."""
    write_json(attempt_path(m.host), {"machine": m.host, "seen": {t: seen[t] for t in m.follows}, "result": result, "at_epoch": int(time.time())})


# ---- who is due ---------------------------------------------------------------------------------------------------------------------
def due_reasons(m: Machine, cur: dict[str, str], now: float, force: bool = False) -> tuple[list[str], str | None]:
    """-> (why the machine is due, [] if it is not; why it is held back although due, else None)."""
    state, reasons = read_json(state_path(m.host)), []
    if force:
        reasons.append("forced")
    elif state is None or not isinstance(state.get("followed"), dict):
        reasons.append("never followed")
    else:
        reasons += [f"{t} changed" for t in m.follows if state["followed"].get(t) != cur[t]]
        if m.catch_up_minutes and now - state.get("at_epoch", 0) >= m.catch_up_minutes * 60:
            reasons.append(f"last followed more than {m.catch_up_minutes} min ago")
    if reasons and not force:
        a = read_json(attempt_path(m.host))
        if m.retry_minutes and a and a.get("seen") == {t: cur[t] for t in m.follows} and now - a.get("at_epoch", 0) < m.retry_minutes * 60:
            return reasons, f"tried {int((now - a['at_epoch']) / 60)} min ago ({a.get('result')}), nothing new since: waits for the {m.retry_minutes} min retry"
    return reasons, None


# ---- running a step ----------------------------------------------------------------------------------------------------------------
def reachable(target: str) -> bool:
    try:
        r = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", target, "true"], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=40)
    except (OSError, subprocess.SubprocessError):
        return False
    return r.returncode == 0


def run_command(argv: list[str], timeout_s: int) -> int:
    """Runs the step in its own process group; its output goes to ours (the journal). A step past its timeout is killed, 124."""
    argv = [str(home()) + a[1:] if a.startswith("~/") else a for a in argv]
    try:
        p = subprocess.Popen(argv, start_new_session=True)
    except OSError as e:
        print(f"machine-follow: cannot start {argv[0]}: {e}", file=sys.stderr, flush=True)
        return 127
    try:
        return p.wait(timeout=timeout_s)
    except subprocess.TimeoutExpired:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(p.pid, sig)
                p.wait(timeout=20)
                break
            except subprocess.TimeoutExpired:
                continue
            except ProcessLookupError:
                break
        return 124


def run_steps(m: Machine) -> int:
    """The machine's before_command (if any), then its command, within the one timeout_minutes. The command always runs, even after a
    before_command that failed; the before_command gets at most BEFORE_MAX_MINUTES so the command keeps the rest. The result is the
    command's if it failed, else the before_command's if it failed, else 75 if either was not ready, else 0."""
    total = m.timeout_minutes * 60
    if not m.before_command:
        return run_command(m.command, total)
    t0 = time.monotonic()
    rb = run_command(m.before_command, min(total, BEFORE_MAX_MINUTES * 60))
    if rb not in (0, EX_TEMPFAIL):
        say(f"{m.host}: before step failed ({'killed after its limit' if rb == 124 else f'exit {rb}'}): the main step still runs")
    rc = run_command(m.command, max(60, int(total - (time.monotonic() - t0))))
    if rc not in (0, EX_TEMPFAIL):
        return rc
    if rb not in (0, EX_TEMPFAIL):
        return rb
    return EX_TEMPFAIL if EX_TEMPFAIL in (rb, rc) else 0


def follow_one(m: Machine, reasons: list[str], seen: dict[str, str]) -> str:
    """-> 'followed' | 'skipped' | 'failed'; the state is written for 'followed' only."""
    if m.reach and not reachable(m.reach):
        say(f"{m.host}: not reachable (stopped?): nothing done, the next run tries again")
        record_attempt(m, seen, "skipped")
        return "skipped"
    say(f"{m.host}: following ({', '.join(reasons)})")
    rc = run_steps(m)
    if rc == 0:
        record_success(m, seen)
        say(f"{m.host}: followed")
        return "followed"
    if rc == EX_TEMPFAIL:
        record_attempt(m, seen, "skipped")
        say(f"{m.host}: not ready or not reachable: nothing done, the next run tries again")
        return "skipped"
    record_attempt(m, seen, "failed")
    say(f"{m.host}: FAILED " + (f"(killed after its {m.timeout_minutes} min limit)" if rc == 124 else f"(exit {rc})"))
    return "failed"


def fingerprints(things) -> dict[str, str]:
    return {t: fingerprint(t) for t in sorted(set(things))}


def instance_unit(host: str) -> str:
    return f"machine-follow@{host}.service"


def instance_active(host: str) -> bool:
    return subprocess.run(["systemctl", "--user", "is-active", "--quiet", instance_unit(host)], timeout=30).returncode == 0


def start_instance(host: str) -> bool:
    """Starts the host's instance without waiting for it (it can run for hours); the dispatcher is done in a moment."""
    return subprocess.run(["systemctl", "--user", "start", "--no-block", instance_unit(host)], timeout=30).returncode == 0


def dispatch(machines: list[Machine], dry_run: bool) -> int:
    """machine-follow.service: start the instance of every due machine that has none running. Settles nothing, runs no step."""
    cur = fingerprints(t for m in machines for t in m.follows)
    now, rc = time.time(), 0
    for m in machines:
        reasons, held = due_reasons(m, cur, now)
        if not reasons:
            say(f"{m.host}: current")
        elif held:
            say(f"{m.host}: due ({', '.join(reasons)}) but {held}")
        elif dry_run:
            say(f"{m.host}: would start {instance_unit(m.host)} ({', '.join(reasons)})")
        elif instance_active(m.host):
            say(f"{m.host}: due ({', '.join(reasons)}), {instance_unit(m.host)} is still running: left alone")
        elif start_instance(m.host):
            say(f"{m.host}: due ({', '.join(reasons)}): started {instance_unit(m.host)}")
        else:
            say(f"{m.host}: could not start {instance_unit(m.host)}")
            rc = 1
    return rc


def follow_host(m: Machine, force: bool, dry_run: bool) -> int:
    """machine-follow@<host>.service: one machine, start to end. 0 unless its step failed."""
    lock = None
    if not dry_run:
        state_dir().mkdir(parents=True, exist_ok=True)
        lock = open(state_dir() / f"{m.host}.lock", "w")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            say(f"{m.host}: another run is in progress: nothing done")
            lock.close()
            return 0
    try:
        cur = fingerprints(m.follows)
        reasons, held = due_reasons(m, cur, time.time(), force)
        if reasons and not held and not dry_run and "gbrain" in m.follows:
            # a cutover rewrites bun.lock first and installs the package after it: wait until it has been still, then look again
            if not wait_settled():
                say(f"{m.host}: {this_host()}'s gbrain install is still changing after 10 min: nothing done, the next run tries again")
                return 0
            cur = fingerprints(m.follows)
            reasons, held = due_reasons(m, cur, time.time(), force)
        if not reasons:
            say(f"{m.host}: current")
        elif held:
            say(f"{m.host}: due ({', '.join(reasons)}) but {held}")
        elif dry_run:
            say(f"{m.host}: would follow ({', '.join(reasons)})")
        else:
            return 1 if follow_one(m, reasons, cur) == "failed" else 0
        return 0
    finally:
        if lock:
            lock.close()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="machine-follow.py", description="Bring the machines this host drives to what this host runs.")
    ap.add_argument("--host", help="follow this one machine now (full hostname): what machine-follow@<host>.service runs")
    ap.add_argument("--dry-run", action="store_true", help="say which machines are due and why; start and run nothing, write nothing")
    ap.add_argument("--force", action="store_true", help="with --host: treat the machine as due")
    args = ap.parse_args(argv)
    if args.force and not args.host:
        print("machine-follow: --force needs --host", file=sys.stderr)
        return 2
    if not machines_file().is_file():
        print(f"machine-follow: {machines_file()}: no such data file (set SALA_MACHINE_FOLLOW_MACHINES in sala's config)", file=sys.stderr)
        return 2
    try:
        run_on, machines = load_machines(machines_file())
    except ConfigError as e:
        print(f"machine-follow: {e}", file=sys.stderr)
        return 2
    if this_host() != run_on:
        print(f"machine-follow: run this on {run_on}, not on {this_host()}", file=sys.stderr)
        return 64
    if not args.host:
        return dispatch(machines, args.dry_run)
    m = next((m for m in machines if m.host == args.host), None)
    if m is None:
        print(f"machine-follow: {args.host} is not in {machines_file().name}", file=sys.stderr)
        return 2
    return follow_host(m, args.force, args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
