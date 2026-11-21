#!/usr/bin/env python3
"""lib/bgagents.py — `sala bg-agents`: give a project a background (engineer) agent when stackshot says it wants one (docs/bg-agents.md).

Stackshot records a "want" for a project that lists a front agent and no background agent and serves the open wants as plain text, one line per
project: `<project key> <name prefix> <front agent>` (`client.py background-wanted`; empty when there is none or its switch is off). This job, run on a
timer, takes at most ONE of them per run: it lists the agent `<name prefix>-engineer` on the project (`client.py post project-agent … --role engineer
--back`, the label the New session form uses) and starts its session (`sala spawn NAME --project KEY --role back --mandate TEXT`), behind its own load
check, a per-project ledger with a back-off and a maximum number of attempts. No model call; standard library only.

  sala bg-agents [--dry-run]     one run (SALA_BGAGENTS=on; off or unset: one line, nothing touched). --dry-run makes the whole decision and posts,
                                 spawns and writes nothing
  sala bg-agents --status        the ledger, one line a project: attempts, next try, state (read-only; also with the switch off)

A run, in order:
  1. SALA_BGAGENTS is not `on`: one line, exit 0, nothing read, written or started.
  2. The list is read (SALA_BGAGENTS_LIST_CMD). A read that fails is one line and exit 0 with the ledger untouched: it is no project's failure.
  3. The ledger is brought up to date: a project in it that is not on the list gets `absent_since`; once it has been absent for the cooldown its
     entry is dropped (the only reset); a project back on the list clears `absent_since`.
  4. Each listed project is looked at in list order. A project given up (attempts at the maximum) or in back-off (next_try not reached) is skipped. The
     first project that is due gets the run's one attempt; the load check comes first and a high load is a skip with nothing taken from the ledger.
  5. The attempt: list the agent (skipped when the project record already has the name, or when this job listed it on an earlier run), then start the
     pane and wait, bounded, for it to be live.
Failures (each one raises the project's back-off: cooldown, doubled for every failure, up to the cap): a post that failed or timed out (an HTTP 409 and
a 403 included), a start that failed, a project listed again after this job created AND retired its agent, and a project still listed once the cooldown
has passed after this job started its pane (a running agent is never retired for that). A start that fails because stackshot's project record has not yet
caught up with the post (spawn exit 3) is waited out for SALA_BGAGENTS_RECORD_GRACE and is no failure within it.

RETIRING IS A MARKED STEP, NOT DONE HERE. An agent this job listed whose start failed would be taken off the project again, but every path sala has for
that (`sala op retire`, `sala op forget-row`) takes the owner's words for an agent that is on a project's agents map (lib/op.sh, THE WORDS POLICY: retire is
`throwaway`, forget-row is `owner`), and no door lets a job do it. So `retire_own_agent` only says `retire needed: <name>`, the run exits 1, and the ledger
keeps `retire_needed`; the entry stays on the map and the next attempt finds it there and tries the start again without listing it twice.

Settings (environment; lib/bgagents.sh passes the config file's values): SALA_BGAGENTS (off), SALA_BGAGENTS_COOLDOWN (600), SALA_BGAGENTS_COOLDOWN_MAX
(86400), SALA_BGAGENTS_MAX_ATTEMPTS (5), SALA_BGAGENTS_MAX_LOAD (10), SALA_BGAGENTS_MANDATE, SALA_BGAGENTS_SENDER (sala-web), SALA_BGAGENTS_LEDGER,
SALA_BGAGENTS_LOADAVG (/proc/loadavg), SALA_BGAGENTS_RECORD_GRACE (900), SALA_BGAGENTS_ALIVE_WAIT (30), SALA_BGAGENTS_POST_TIMEOUT (120),
SALA_BGAGENTS_SPAWN_TIMEOUT (300), and the four commands SALA_BGAGENTS_LIST_CMD, _POST_CMD, _SPAWN_CMD, _ALIVE_CMD (the suites stub them);
SALA_PROJECT_RECORD and SALA_PROJECT_RECORD_MAX_AGE (stackshot's project record, as spawn reads it), SALA_TZ (the zone times are shown in),
SALA_OWNER_NAME (the mandate's default text). SALA_BGAGENTS_NOW is the suites' clock.
Exit: 0 = the run finished (also when it skipped or a project failed), 1 = a retire is needed, 2 = usage or a bad setting.
"""
import fcntl
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from zoneinfo import ZoneInfo

ROLE = "engineer"
NAME_MAX = 48
KEY_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*/[a-z0-9]+(?:-[a-z0-9]+)*$")
PREFIX_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
DEFAULT_MANDATE = ("Handles outside events (mail, Slack, GitHub) for this project and builds what needs no decision of {owner}, "
                   "so the front agent serves only {owner}")


# ---- settings -------------------------------------------------------------------------------------------------------------------

def env_num(name, default):
    try:
        v = float(os.environ.get(name, ""))
        return v if v >= 0 else default
    except ValueError:
        return default


def now_s():
    try:
        return int(float(os.environ["SALA_BGAGENTS_NOW"]))
    except (KeyError, ValueError):
        return int(time.time())


def state_dir():
    base = os.environ.get("SALA_STATE_DIR") or os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state"), "salamander")
    return base


def ledger_path():
    return os.environ.get("SALA_BGAGENTS_LEDGER") or os.path.join(state_dir(), "bgagents.json")


def mandate_text():
    """The one line the agent is listed with and starts on: SALA_BGAGENTS_MANDATE, else the default with the owner's name. The one place it lives."""
    m = os.environ.get("SALA_BGAGENTS_MANDATE")
    if m is None or not m.strip():
        owner = os.environ.get("SALA_OWNER_NAME") or "the owner"
        return DEFAULT_MANDATE.format(owner=owner)
    return m.strip()


def mandate_ok(m):
    return 0 < len(m) <= 600 and not re.search(r"[\x00-\x1f\x7f\\]", m)


def cmd_words(name):
    v = os.environ.get(name, "")
    try:
        return shlex.split(v)
    except ValueError:
        return []


# ---- time and log ---------------------------------------------------------------------------------------------------------------

def _local(epoch):
    z = os.environ.get("SALA_TZ")
    if z:
        try:
            return datetime.fromtimestamp(epoch, ZoneInfo(z))
        except Exception:
            pass
    return datetime.fromtimestamp(epoch).astimezone()


def local_text(epoch):
    """`Sat Nov 21st 15:10 KST`: the date form prose uses, in SALA_TZ (this machine's own zone when unset), with the zone's own label."""
    d = _local(epoch)
    n = d.day
    suf = "th" if 11 <= n % 100 <= 13 else {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")
    return "%s %s %d%s %s %s" % (d.strftime("%a"), d.strftime("%b"), n, suf, d.strftime("%H:%M"), d.strftime("%Z"))


def local_iso(epoch):
    return _local(epoch).isoformat(timespec="seconds")


def dur_text(s):
    s = int(round(s))
    if s < 90:
        return "%d s" % s
    if s < 5400:
        return "%d min" % round(s / 60)
    return "%.1f h" % (s / 3600)


class Log:
    """One line per decision, on stdout (journald) and, unless dry, in <ledger folder>/bgagents.log: `<time> <action> <text>`. Nothing secret is ever put in a line."""

    def __init__(self, now, dry):
        self.now, self.dry = now, dry
        self.path = os.path.join(os.path.dirname(ledger_path()), "bgagents.log")

    def say(self, action, text):
        line = "%s %s %s%s" % (local_iso(self.now), action, text, " (dry run)" if self.dry else "")
        print(line, flush=True)
        if not self.dry:
            try:
                os.makedirs(os.path.dirname(self.path), mode=0o700, exist_ok=True)
                fd = os.open(self.path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
                with os.fdopen(fd, "a", encoding="utf-8") as f:
                    f.write(line + "\n")
            except OSError:
                pass


def last_line(text, n=160):
    lines = [l.strip() for l in (text or "").splitlines() if l.strip()]
    s = lines[-1] if lines else ""
    return s if len(s) <= n else s[:n - 1] + "…"


# ---- the ledger -----------------------------------------------------------------------------------------------------------------

BLANK = {"prefix": "", "agent": "", "attempts": 0, "failures": 0, "next_try": 0, "created": False, "posted_at": 0, "started_at": 0, "retired": False,
         "retire_needed": False, "awaiting_record": False, "last": "", "last_at": 0, "absent_since": 0}


class Ledger:
    def __init__(self, path, dry):
        self.path, self.dry = path, dry
        self.projects = {}
        try:
            with open(path, encoding="utf-8") as f:
                d = json.load(f)
            p = d.get("projects") if isinstance(d, dict) else None
            if isinstance(p, dict):
                self.projects = {str(k): dict(BLANK, **v) for k, v in p.items() if isinstance(v, dict)}
        except (OSError, ValueError):
            pass
        self.dirty = False

    def entry(self, key):
        return self.projects.setdefault(key, dict(BLANK))

    def save(self):
        """Atomic: a temporary file in the same folder (mode 600), fsynced, then renamed over the ledger, so a crash leaves the old whole file or the new whole file."""
        if self.dry:
            return
        d = os.path.dirname(self.path)
        os.makedirs(d, mode=0o700, exist_ok=True)
        for old in os.listdir(d):       # a crash between the write and the rename leaves its temporary file; the run's lock makes this the only writer
            if old.startswith(".bgagents.") and old.endswith(".tmp"):
                try:
                    os.unlink(os.path.join(d, old))
                except OSError:
                    pass
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".bgagents.", suffix=".tmp")
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump({"schema": 1, "projects": self.projects}, f, ensure_ascii=False, indent=1, sort_keys=True)
                f.write("\n")
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, self.path)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)


def given_up(e, cfg):
    return e["attempts"] >= cfg["max_attempts"]


def state_of(e, cfg, now):
    if given_up(e, cfg):
        return "given up"
    if e["retire_needed"]:
        return "retire needed (the agent's entry stays on the project; the start is tried again)"
    if e["next_try"] > now:
        return "backing off"
    if e["started_at"]:
        return "started, waiting for the project to leave the list"
    if e["awaiting_record"]:
        return "listed, waiting for stackshot's project record"
    if e["absent_since"]:
        return "absent from the list"
    return "ready"


# ---- reading and acting on the world --------------------------------------------------------------------------------------------

def run(cmd, timeout):
    """-> (rc, output) with stdin closed; rc 124 for a timeout, 127 for a command that cannot be run. The child is waited for and never signalled by name."""
    try:
        p = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout, text=True, errors="replace")
        return p.returncode, p.stdout
    except subprocess.TimeoutExpired:
        return 124, "timed out after %d s" % timeout
    except OSError as e:
        return 127, "cannot run %s: %s" % (cmd[0] if cmd else "(no command)", e.__class__.__name__)


def read_list(cfg, log):
    """-> a list of (key, prefix, front) or None when the list could not be read (the reason said)."""
    cmd = cfg["list_cmd"]
    if not cmd:
        log.say("skip", "the want list was not read: no stackshot client on this machine (SALA_BGAGENTS_LIST_CMD); ledger untouched")
        return None
    rc, out = run(cmd, 30)
    if rc != 0:
        log.say("skip", "the want list was not read (exit %d: %s); ledger untouched" % (rc, last_line(out, 100)))
        return None
    rows, seen = [], set()
    for ln in out.splitlines():
        if not ln.strip():
            continue
        w = ln.split()
        if len(w) != 3 or not KEY_RE.match(w[0]) or not PREFIX_RE.match(w[1]) or len(w[1] + "-" + ROLE) > NAME_MAX:
            log.say("skip", "a line of the want list is not <project key> <name prefix> <front agent>: ignored")
            continue
        if w[0] in seen:
            continue
        seen.add(w[0])
        rows.append((w[0], w[1], w[2]))
    return rows


def load_average(cfg):
    try:
        with open(cfg["loadavg"], encoding="utf-8") as f:
            return float(f.read().split()[0])
    except (OSError, ValueError, IndexError):
        return None


def agent_on_map(key, name, now):
    """Does stackshot's project record (the file spawn reads) list NAME on KEY? True / False, or None when it cannot answer (missing, stale, unreadable, no such project)."""
    path = os.environ.get("SALA_PROJECT_RECORD") or os.path.join(os.path.expanduser("~"), ".local", "state", "stackshot", "projects.json")
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        if not isinstance(d, dict) or d.get("schema") != 1:
            return None
        gen = datetime.fromisoformat(str(d["generated"]).replace("Z", "+00:00")).timestamp()
        if now - gen > env_num("SALA_PROJECT_RECORD_MAX_AGE", 600) or now - gen < -60:
            return None
        projects = d["projects"]
        pid = (d.get("by_key") or {}).get(key)
        p = projects.get(pid) if pid else None
        if p is None:
            p = next((v for v in projects.values() if isinstance(v, dict) and v.get("key") == key), None)
        if not isinstance(p, dict):
            return None
        return isinstance(p.get("agents"), dict) and isinstance(p["agents"].get(name), dict)
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return None


def is_alive(cfg, name):
    cmd = cfg["alive_cmd"]
    if not cmd:
        return False
    rc, _ = run(cmd + [name, "--live"], 30)
    return rc == 0


def wait_alive(cfg, name):
    deadline = time.monotonic() + cfg["alive_wait"]
    while True:
        if is_alive(cfg, name):
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(min(2.0, max(0.05, deadline - time.monotonic())))


# ---- the decisions --------------------------------------------------------------------------------------------------------------

def backoff(failures, cfg):
    return min(cfg["cooldown"] * (2 ** max(0, failures - 1)), cfg["cooldown_max"])


def fail(e, key, why, cfg, now, log, led, counts_attempt=False):
    """A project failure: the back-off grows. counts_attempt: a failure the job only observed (relisted, still listed) is one more attempt too, so a project
    that never settles is given up like one that never starts."""
    if counts_attempt:
        e["attempts"] += 1
    e["failures"] += 1
    e["next_try"] = int(now + backoff(e["failures"], cfg))
    e["last"], e["last_at"] = "failed: " + why, now
    if given_up(e, cfg):
        log.say("failed", "%s: %s; attempt %d of %d: given up, left alone from now on" % (key, why, e["attempts"], cfg["max_attempts"]))
    else:
        log.say("failed", "%s: %s; next try %s (in %s)" % (key, why, local_text(e["next_try"]), dur_text(e["next_try"] - now)))
    led.save()


def retire_own_agent(key, name, e, log):
    """THE MARKED STEP (see the module's text): an agent this job listed and could not start should come off the project, and no unattended path does
    that without the owner's words. Says so and returns True ("needed"): the run then exits 1. Nothing is removed anywhere."""
    e["retire_needed"] = True
    log.say("retire", "retire needed: %s (listed on %s by this job, its pane did not start; no path takes it off without the owner's words)" % (name, key))
    return True


def post_agent(cfg, key, name):
    """-> (ok, created, why). created is False when stackshot says the agent was already listed (nothing changed)."""
    cmd = cfg["post_cmd"] + [key, name, "--role", ROLE, "--back", "--mandate", cfg["mandate"], "--sender", cfg["sender"]]
    if not cfg["post_cmd"]:
        return False, False, "no stackshot client on this machine (SALA_BGAGENTS_POST_CMD)"
    rc, out = run(cmd, cfg["post_timeout"])
    if rc == 0:
        return True, "nothing changed" not in out and "already listed" not in out.lower(), ""
    if rc == 124:
        return False, False, "the post timed out (it may have gone through: the next attempt looks at the project record first)"
    m = re.search(r"\[(\d{3})\]\s*(.*)", out)
    return False, False, ("HTTP %s: %s" % (m.group(1), last_line(m.group(2), 120)) if m else "the post failed (exit %d: %s)" % (rc, last_line(out, 120)))


def attempt(cfg, key, prefix, e, now, log, led):
    """The run's one attempt on a project. -> True when a retire is needed."""
    name = "%s-%s" % (prefix, ROLE)
    waiting = bool(e["awaiting_record"] and e["posted_at"] and e["agent"] == name)    # a start only waited for stackshot's record: not a new attempt
    e["prefix"], e["agent"] = prefix, name
    if not waiting:
        e["attempts"] += 1
        e["last"], e["last_at"] = "trying", now
        led.save()      # counted before anything is asked: a crash mid-attempt still leaves the attempt on the record
    on_map = agent_on_map(key, name, now)
    if on_map is False and e["posted_at"] and now - e["posted_at"] >= cfg["record_grace"]:
        e["posted_at"], e["created"] = 0, False      # a fresh record has not shown the agent for longer than the grace: it was taken off since, so it is listed again
    skip = on_map or (on_map is None and e["posted_at"]) or (on_map is False and e["posted_at"])
    if skip:
        log.say("post", "%s: %s is %s; not listed again" % (key, name, "already on the project's map" if on_map else "listed by an earlier run (waiting for the record)"))
    else:
        ok, created, why = post_agent(cfg, key, name)
        if not ok:
            fail(e, key, "listing %s failed: %s" % (name, why), cfg, now, log, led)
            return False
        if created:
            e["created"] = True
            log.say("post", "%s: listed %s (%s, background)" % (key, name, ROLE))
        else:
            log.say("post", "%s: %s was already listed (nothing changed)" % (key, name))
        e["posted_at"], e["awaiting_record"] = now, False
        led.save()
    rc, out = run(cfg["spawn_cmd"] + [name, "--project", key, "--role", "back", "--mandate", cfg["mandate"]], cfg["spawn_timeout"])
    if rc == 3 and e["posted_at"] and now - e["posted_at"] < cfg["record_grace"]:
        e["awaiting_record"], e["last"], e["last_at"] = True, "listed; waiting for stackshot's project record before the start", now
        log.say("wait", "%s: %s is listed but sala's copy of stackshot's project record does not show it yet; the start is tried again at the next run" % (key, name))
        led.save()
        return False
    alive = wait_alive(cfg, name) if rc == 0 else is_alive(cfg, name)
    if alive:
        e.update(started_at=now, awaiting_record=False, retire_needed=False, last="started", last_at=now)
        log.say("start", "%s: %s is live" % (key, name))
        led.save()
        return False
    e["awaiting_record"] = False
    why = "the start of %s %s" % (name, "timed out" if rc == 124 else ("failed (exit %d: %s)" % (rc, last_line(out, 100))) if rc != 0 else "did not come up (spawn said it was up, but it is not live)")
    fail(e, key, why, cfg, now, log, led)
    if e["created"] and not e["retired"]:
        needed = retire_own_agent(key, name, e, log)
        led.save()
        return needed
    log.say("keep", "%s: %s was not listed by this job; its entry is left as it is" % (key, name))
    return False


def pending(e):
    """An agent this job listed whose pane it has not started yet: the want list no longer shows such a project (its agent is on the map), so the ledger drives it."""
    return bool(e["posted_at"] and not e["started_at"] and not e["retired"])


def one_run(cfg, dry, now, log):
    rows = read_list(cfg, log)
    if rows is None:
        return 0
    led = Ledger(cfg["ledger"], dry)
    listed = {k for k, _, _ in rows}
    changed = False
    for key in sorted(led.projects):
        e = led.projects[key]
        if key in listed:
            if e["absent_since"]:
                e["absent_since"], changed = 0, True
        elif not e["absent_since"]:
            e["absent_since"], changed = now, True
        elif now - e["absent_since"] >= cfg["cooldown"] and not pending(e):
            log.say("reset", "%s: off the list for %s: its ledger entry is cleared" % (key, dur_text(now - e["absent_since"])))
            del led.projects[key]
            changed = True
    if changed:
        led.save()
    # the list's projects in its order, then the ones this job listed an agent for and has not started (off the list because the agent is on the map now)
    cands = list(rows) + [(k, led.projects[k]["prefix"], "") for k in sorted(led.projects) if k not in listed and pending(led.projects[k]) and led.projects[k]["prefix"]]
    if not cands:
        log.say("idle", "nobody on the want list")
        return 0
    retire = 0
    for key, prefix, _front in cands:
        e = led.projects.get(key)
        if e is not None:
            if given_up(e, cfg):
                log.say("skip", "%s: given up after %d attempts (%s); left alone" % (key, e["attempts"], e["last"] or "no outcome"))
                continue
            if e["retired"] and key in listed:       # this job created the agent and retired it earlier, and the project wants one again
                e["retired"], e["created"], e["posted_at"] = False, False, 0
                fail(e, key, "listed again after this job created and retired its agent", cfg, now, log, led, counts_attempt=True)
                continue
            if e["next_try"] > now:
                log.say("skip", "%s: backing off until %s (attempt %d of %d)" % (key, local_text(e["next_try"]), e["attempts"], cfg["max_attempts"]))
                continue
            if e["started_at"]:
                if is_alive(cfg, e["agent"]):
                    if key in listed and now - e["started_at"] >= cfg["cooldown"]:
                        fail(e, key, "still on the want list %s after its pane started (the pane is left running)" % dur_text(now - e["started_at"]), cfg, now, log, led, counts_attempt=True)
                    elif key in listed:
                        log.say("skip", "%s: %s started %s ago; waiting for the project to leave the list" % (key, e["agent"], dur_text(now - e["started_at"])))
                    continue
                e["started_at"] = 0
        load = load_average(cfg)
        if load is None:
            log.say("skip", "%s: the load average could not be read (%s); nothing attempted" % (key, cfg["loadavg"]))
            return 0
        if load >= cfg["max_load"]:
            log.say("skip", "%s: load %.2f is at or above %g; nothing attempted, nothing counted" % (key, load, cfg["max_load"]))
            return 0
        if dry:
            e2 = e or dict(BLANK)
            name = "%s-%s" % (prefix, ROLE)
            on_map = agent_on_map(key, name, now)
            waiting = bool(e2["awaiting_record"] and e2["posted_at"])
            step = ("skip the listing (%s)" % ("already on the map" if on_map else "listed by an earlier run")) if (on_map or e2["posted_at"]) \
                else "list %s (%s, background; label %s)" % (name, ROLE, cfg["sender"])
            log.say("plan", "%s: would %s, then start its pane (sala spawn --project %s --role back); attempt %d of %d; load %.2f" % (key, step, key, e2["attempts"] + (0 if waiting else 1), cfg["max_attempts"], load))
            return 0
        e = led.entry(key)
        if attempt(cfg, key, prefix, e, now, log, led):
            retire += 1
        break
    return 1 if retire else 0


def status(cfg):
    now = now_s()
    led = Ledger(cfg["ledger"], True)
    if not led.projects:
        print("the ledger is empty (%s)" % cfg["ledger"])
        return 0
    for key in sorted(led.projects):
        e = led.projects[key]
        nxt = local_text(e["next_try"]) if e["next_try"] > now else "-"
        extra = ""
        if e["absent_since"]:
            extra = "; off the list since %s" % local_text(e["absent_since"])
        if e["last"]:
            extra += "; last: %s (%s)" % (e["last"], local_text(e["last_at"]))
        print("%s  %s  attempts %d/%d  failures %d  next try %s  %s%s" % (key, e["agent"] or "-", e["attempts"], cfg["max_attempts"], e["failures"], nxt, state_of(e, cfg, now), extra))
    return 0


def config():
    return {
        "cooldown": env_num("SALA_BGAGENTS_COOLDOWN", 600.0), "cooldown_max": env_num("SALA_BGAGENTS_COOLDOWN_MAX", 86400.0),
        "max_attempts": int(env_num("SALA_BGAGENTS_MAX_ATTEMPTS", 5)), "max_load": env_num("SALA_BGAGENTS_MAX_LOAD", 10.0),
        "loadavg": os.environ.get("SALA_BGAGENTS_LOADAVG") or "/proc/loadavg", "ledger": ledger_path(),
        "sender": os.environ.get("SALA_BGAGENTS_SENDER") or "sala-web", "mandate": mandate_text(),
        "record_grace": env_num("SALA_BGAGENTS_RECORD_GRACE", 900.0), "alive_wait": env_num("SALA_BGAGENTS_ALIVE_WAIT", 30.0),
        "post_timeout": env_num("SALA_BGAGENTS_POST_TIMEOUT", 120.0), "spawn_timeout": env_num("SALA_BGAGENTS_SPAWN_TIMEOUT", 300.0),
        "list_cmd": cmd_words("SALA_BGAGENTS_LIST_CMD"), "post_cmd": cmd_words("SALA_BGAGENTS_POST_CMD"),
        "spawn_cmd": cmd_words("SALA_BGAGENTS_SPAWN_CMD"), "alive_cmd": cmd_words("SALA_BGAGENTS_ALIVE_CMD"),
    }


def main(argv):
    args = argv[1:]
    dry = stat = False
    for a in args:
        if a == "--dry-run":
            dry = True
        elif a == "--status":
            stat = True
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            print("usage: sala bg-agents [--dry-run | --status]", file=sys.stderr)
            return 2
    if dry and stat:
        print("usage: sala bg-agents [--dry-run | --status]", file=sys.stderr)
        return 2
    cfg = config()
    if stat:
        return status(cfg)
    now = now_s()
    log = Log(now, dry)
    if os.environ.get("SALA_BGAGENTS", "off").strip().lower() != "on":
        print("bg-agents is off (SALA_BGAGENTS=on in the config turns it on); nothing done")
        return 0
    if not mandate_ok(cfg["mandate"]):
        print("bg-agents: SALA_BGAGENTS_MANDATE must be one line of at most 600 characters with no control character or backslash; nothing done", file=sys.stderr)
        return 2
    if not dry:
        os.makedirs(os.path.dirname(cfg["ledger"]), mode=0o700, exist_ok=True)
        lock = os.open(cfg["ledger"] + ".lock", os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print("bg-agents: another run holds the lock; nothing done")
            return 0
    rc = one_run(cfg, dry, now, log)
    if dry:
        print("dry run: nothing was posted, started or written")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
