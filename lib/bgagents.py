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
  sala bg-agents --reset KEY     clear that project's ledger entry (attempts, failures, back-off, given up, retire needed, the board item, the last outcome) so the next run tries it
                                 afresh; the agent's entry on the project is left as it is. A ledger edit, not a run: works with the switch off; --dry-run says what it would clear
                                 and writes nothing; a key with no entry is refused (exit 1)

A run, in order:
  1. SALA_BGAGENTS is not `on`: one line, exit 0, nothing read, written or started.
  2. The list is read (SALA_BGAGENTS_LIST_CMD). A read that fails is one line and exit 0 with the ledger untouched: it is no project's failure.
  3. The ledger is brought up to date: a project in it that is not on the list gets `absent_since`; once it has been absent for the cooldown its
     entry is dropped (the only reset); a project back on the list clears `absent_since`.
  4. Each listed project is looked at in list order. A project given up (attempts at the maximum), with a board item raised or in back-off (next_try not reached) is skipped. The
     first project that is due gets the run's one attempt; the load check comes first and a high load is a skip with nothing taken from the ledger.
  5. The attempt: list the agent (skipped when the project record already has the name, or when this job listed it on an earlier run), then start the
     pane and wait, bounded, for it to be live. A live pane is a start only when it is also PLACED in its project, read three ways (`read_back`): stackshot's
     project record lists it on the project's agents map as a back agent, stackshot's roles list has a live entry for it on the project with the role back, and sala's own registry
     row is the session's own row (the registry also answers a renamed session's old name with the renamed session's row, which is not a placement) and carries the project and the
     role back. The three are read again until SALA_BGAGENTS_PLACE_WAIT is up (the record and roles.json are rewritten about every five minutes); the registry command is given
     only the time left to that deadline (at least 5 s for the first read and 1 s for a later one, at most 30 s). A link that disagrees or cannot answer at the deadline fails
     the attempt (the pane is left running): the reason names the link, the back-off applies, counted from the moment the attempt failed and not from the run's start (the listing, the
     start and this wait may have used much of it), one
     Slack post (`sala alert`) and, after the attempt, the board item.
  6. After the attempt, at most ONE board item is raised for a project it cannot start (below).
Failures (each one raises the project's back-off: cooldown, doubled for every failure, up to the cap): a post that failed or timed out (an HTTP 409 and
a 403 included), a start that failed, a project listed again after this job created AND retired its agent, and a project still listed once the cooldown
has passed after this job started its pane (a running agent is never retired for that). A start that fails because stackshot's project record has not yet
caught up with the post (spawn exit 3) is waited out for SALA_BGAGENTS_RECORD_GRACE and is no failure within it.

RETIRING IS A MARKED STEP, NOT DONE HERE. An agent this job listed whose start failed would be taken off the project again, but every path sala has for
that (`sala op retire`, `sala op forget-row`) takes the owner's words for an agent that is on a project's agents map (lib/op.sh, THE WORDS POLICY: retire is
`throwaway`, forget-row is `owner`), and no door lets a job do it. So `retire_own_agent` only says `retire needed: <name>`, the run exits 1, and the ledger
keeps `retire_needed`; the entry stays on the map and the next attempt finds it there and tries the start again without listing it twice (until the board item for
it is raised, which is in the same run: after that nothing is tried until a session resets the record).

Settings (environment; lib/bgagents.sh passes the config file's values): SALA_BGAGENTS (off), SALA_BGAGENTS_COOLDOWN (600), SALA_BGAGENTS_COOLDOWN_MAX
(86400), SALA_BGAGENTS_MAX_ATTEMPTS (5), SALA_BGAGENTS_MAX_LOAD (10), SALA_BGAGENTS_MANDATE, SALA_BGAGENTS_SENDER (sala-web), SALA_BGAGENTS_LEDGER,
SALA_BGAGENTS_LOADAVG (/proc/loadavg), SALA_BGAGENTS_RECORD_GRACE (900), SALA_BGAGENTS_ALIVE_WAIT (30), SALA_BGAGENTS_POST_TIMEOUT (120),
SALA_BGAGENTS_SPAWN_TIMEOUT (300), SALA_BGAGENTS_RAISE_TIMEOUT (30), SALA_BGAGENTS_MAX_PROBES (3), SALA_BGAGENTS_PLACE_WAIT (360) and _PLACE_POLL (5) (the read-back), SALA_ROLES_FILE and
SALA_ROLES_FILE_MAX_AGE (1800: the file copy of the roles list, read only when stackshot cannot be reached; stackshot is asked first, lib/stackshot_record.py, with SALA_RECORD_LIVE, _TTL and _TIMEOUT), SALA_BGAGENTS_ALERT_CMD (the Slack post, `sala alert`), and the four commands SALA_BGAGENTS_LIST_CMD, _POST_CMD, _SPAWN_CMD, _ALIVE_CMD (the suites stub them);
SALA_PROJECT_RECORD and SALA_PROJECT_RECORD_MAX_AGE (stackshot's project record, as spawn reads it), SALA_TZ (the zone times are shown in),
SALA_OWNER_NAME (the mandate's default text). SALA_BGAGENTS_NOW is the suites' clock.
A PROJECT IT CANNOT START NEVER STAYS SILENT, AND IS NOT PUT TO THE OWNER. A failed start is a fault in the job or its setup, not a decision of the owner, so by default
(SALA_BGAGENTS_RAISE=report) the job REPORTS it to sala's builder session instead of filing a decision: one message through stackshot's client (`client.py message <session> -
--sender sala-bg-agents`, the text on stdin; SALA_BGAGENTS_REPORT_CMD, the session SALA_BGAGENTS_REPORT_TO) naming the project, the agent, the attempts, the LAST REAL ERROR of the
attempts (the words the failed step gave, kept in the ledger's `last_error`, cut to 300 characters, never a guessed cause) and what to do (`sala bg-agents --reset KEY` once the cause is
fixed). Everything below that says "board item" or "raised" holds for the report as well, with the report in its place (the ledger's `raised` and `raised_at` record that it went out,
`raised_item` the session it went to, `raise_token` the id a retry reuses and the message carries as "Report id"; the logs say `report needed: <project>` and `reported to <session>`);
no prefix, ask line or option is made for it. SALA_BGAGENTS_RAISE=ask keeps the old route, a decision item for the owner, described below.
When a project reaches the attempt cap ("given up") or the ledger sets retire_needed (an agent this job listed
whose pane did not start) or `unplaced` (a pane that is live but not placed in its project by the record, roles.json and sala's row), the job raises ONE board item for the owner through stackshot's client (`client.py post question`: a decision item with a short
ask and three options; the want list's project is its page), once per project: the ledger's `raised` is set with the item's id and the time, and it is set
again only after a session reset the entry (`--reset`) and it gives up again: a raised entry is NEVER pruned for being off the want list. Once an item is raised the job makes NO start attempt for that project until a
session resets it (`sala bg-agents --reset KEY`, what the answer "Keep trying later" is); the other two answers ("Leave it without one", "I will start it by hand") just
leave it raised, so nothing runs. The raise is no attempt and no failure of the project, and it never delays a start: it is made AFTER the run's start attempt, at most
ONE a run (the next outstanding project waits for the next run), with its own short timeout (SALA_BGAGENTS_RAISE_TIMEOUT, 30 s) for each of its two calls, and the
ledger lock is NOT held across them (it is taken to keep the request id, given up for the calls and taken again to write the result to the entry as it is then on disk;
a `--reset` that ran meanwhile wins: its cleared entry is not written over, and the run says so; the entry is marked `raising_at` before the lock is given up, so no other run
starts the project meanwhile, until the mark is older than 2 x the raise timeout + 15 s, and the result is written only while the entry still carries this raise's token and the
project is still stuck). A raise that fails (no client, the client refused or timed out)
leaves `raised` false, says `board item needed: <project>` and is tried again, with the same request id (a repeat files nothing twice), after the project's own back-off (`raise_failures`,
`raise_next_try`: the cooldown, doubled): the run's one raise goes to the first project DUE for one, so a key the board keeps refusing holds nobody back. The request id of
an escalation is `bgagents-<scope>-<slug>-<time>-<random>`, kept in the ledger's `raise_token` and new after a reset. --dry-run raises nothing.
A project that stays on the want list while its agent's session is LIVE (the start failed late, or the pane was started by hand) is no start failure: before raising, the
job asks whether the session is live (SALA_BGAGENTS_ALIVE_CMD); when it is, nothing is raised, the ledger records `agent running, want list stale` (`stale`) and the
project makes no new attempt while its pane is alive. When the check cannot say, a project not marked stale is raised for, saying only that the start did not finish; one that is stale, or whose pane was started, is left as it is
(only a confirmed "not live", exit 1, lets it back into the start path). The checks are made WITHOUT the ledger lock (collect, give it up, ask, take it again, read the ledger again
from disk), at most SALA_BGAGENTS_MAX_PROBES (3) a run, the least recently checked first.

Settings of the report: SALA_BGAGENTS_RAISE (report, the default, or ask), SALA_BGAGENTS_REPORT_TO (the session the report goes to: the name of sala's builder session in the
owner's fleet, set in the owner's config; the repository names none, so unset it says `report needed` and exits 1), SALA_BGAGENTS_REPORT_CMD (the sending command, `client.py message`; the suites stub it).
Settings of the ask route: SALA_BGAGENTS_ASK_CMD (the filing command, `client.py post question`), SALA_BGAGENTS_PREFIXES_CMD (`client.py get config`, read for
the instance's subject prefixes), SALA_BGAGENTS_RAISE_TIMEOUT (30 s a call), SALA_BGAGENTS_SUBJECT_PREFIX (the subject's bracket, "[scope] ": unset = the project's own
scope in the project record, else SALA_DEFAULT_SCOPE, else the first of SALA_SCOPES, the first of them the instance has as a prefix, else the instance's first prefix).
Exit: 0 = the run finished (also when it skipped or a project failed), 1 = a retire is needed or a report (a board item, in ask mode) is needed and could not be sent, 2 = usage or a bad setting.
"""
import fcntl
import json
import os
import copy
import re
import secrets
import shlex
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from zoneinfo import ZoneInfo

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))     # run as `python3 -I -S`: no script directory on the path by itself
import stackshot_record as SR     # the one reader of stackshot's project record and roles list: stackshot first, the file copy only when it does not answer

ROLE = "engineer"
NAME_MAX = 48
KEY_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*/[a-z0-9]+(?:-[a-z0-9]+)*$")
PREFIX_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
ASK_SENDER = "sala-bg-agents"       # the job's own label on the board item and on the report (a script's label, never a session's name)
ERROR_MAX = 300                     # the longest real error a report carries; an owner's board item carries 160
SUBJECT_MAX = 80
BRACKET_RE = re.compile(r"^\[[A-Za-z0-9._-]+\] $")
OPTIONS = (("Keep trying later", "A session resets the project's record, and the job tries again from the first attempt."),
           ("Leave it without one", "The project goes on without a background agent."),
           ("I will start it by hand", "You start the agent yourself; the job leaves the project alone."))
RECOMMENDED = OPTIONS[0][0]
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


START = time.monotonic()


def fresh_now():
    """The clock right now. A run's `now` is its start; the probes and the start of a project can take minutes, so the filing mark and its window are read from this: with
    SALA_BGAGENTS_NOW set (a suite's fake clock) the run's start plus the real time since the process began, else the wall clock."""
    try:
        return int(float(os.environ["SALA_BGAGENTS_NOW"])) + int(time.monotonic() - START)
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


def first_word(name):
    """The first blank-separated word of a setting, kept to the characters a subject bracket takes."""
    w = os.environ.get(name, "").split()
    return re.sub(r"[^A-Za-z0-9._-]", "", w[0]) if w else ""


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
         "retire_needed": False, "awaiting_record": False, "last": "", "last_at": 0, "absent_since": 0,
         "last_plain": "", "last_error": "", "raised": False, "raised_at": 0, "raised_item": "", "raise_token": "", "stale": False,
         "raising_at": 0, "raising_by": "", "raise_failures": 0, "raise_next_try": 0, "probed_at": 0, "unplaced": ""}


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


def raise_window(cfg):
    """How long an entry marked `raising` is believed: both calls of the raise at their timeout, and the wait to take the ledger lock again."""
    return 2 * cfg["raise_timeout"] + 15


def raising_now(e, cfg):
    """Is another run filing this project's board item right now (its mark is younger than the window, both read from the clock now)?"""
    return bool(e["raising_at"]) and fresh_now() - e["raising_at"] < raise_window(cfg)


def state_of(e, cfg, now):
    n, done, notyet = noun_of(cfg), "raised" if cfg["raise_mode"] == "ask" else "sent", "not raised yet" if cfg["raise_mode"] == "ask" else "not sent yet"
    if raising_now(e, cfg) and not e["raised"]:
        return "a %s is being %s" % (n, "filed" if cfg["raise_mode"] == "ask" else "sent")
    if e["stale"] and not e["raised"]:
        return "agent running, want list stale (no %s %s)" % (n, done)
    if given_up(e, cfg):
        return "given up (%s %s%s)" % (n, done if e["raised"] else notyet, ", not on the want list" if e["raised"] and e["absent_since"] else "")
    if e["unplaced"]:
        return "started but not placed on the project (its pane is left running; %s)" % ("left alone until a session resets it, %s %s" % (n, done) if e["raised"] else "%s %s" % (n, notyet))
    if e["raised"]:
        return "left alone until a session resets it (%s %s%s%s)" % (n, done, ", retire needed" if e["retire_needed"] else "", ", not on the want list" if e["absent_since"] else "")
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


def record_path(kind, poll=None):
    """-> (the path to read, what to add to a "cannot answer" reason): stackshot's own answer (SR.resolve asks it first, under a timeout) else the file copy (SALA_PROJECT_RECORD /
    SALA_ROLES_FILE), whose age the note says when stackshot was asked and did not answer. POLL: the seconds a live answer may be kept (the read-back reads again every few seconds)."""
    try:
        r = SR.resolve(kind, ttl=poll)
    except Exception:                                   # the reader itself failed: the file copy, as before
        return SR.default_fallback(kind), ""
    return r["path"], ("; " + r["note"]) if r["why"] else ""


def agent_on_map(key, name, now):
    """Does stackshot's project record (stackshot's own answer, else the file copy spawn reads) list NAME on KEY? True / False, or None when it cannot answer (missing, stale, unreadable, no such project)."""
    path, _note = record_path("projects")
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


def alive_state(cfg, name):
    """Is the session NAME live? True / False, or None when the check cannot say (no liveness command, no name, a timeout, a command that cannot be run, an ambiguous name: any
    exit but 0 = found and 1 = none)."""
    if not cfg["alive_cmd"] or not name:
        return None
    rc, _ = run(cfg["alive_cmd"] + [name, "--live"], 30)
    return True if rc == 0 else False if rc == 1 else None


def wait_alive(cfg, name):
    deadline = time.monotonic() + cfg["alive_wait"]
    while True:
        if is_alive(cfg, name):
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(min(2.0, max(0.05, deadline - time.monotonic())))


# ---- the read-back: is a started session placed in its project? ------------------------------------------------------------------

BACK = "back"
LOOKUP_MAX, LOOKUP_FIRST, LOOKUP_FLOOR = 30, 5, 1     # the registry command's limit in seconds: at most, at least for the first lookup of a read-back, at least for a later one
LINKS = ("the record", "roles.json", "sala's row")     # the three places that put a session in its project, in the order they are read


def _fresh_json(path, max_age, now):
    """-> (the file's object, "") or (None, why): a file stackshot rewrites ({"generated": "<ISO Z>", ...}); older than MAX_AGE (or dated in the future) answers nothing."""
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        if not isinstance(d, dict):
            return None, "it is not an object"
        gen = datetime.fromisoformat(str(d["generated"]).replace("Z", "+00:00")).timestamp()
    except OSError:
        return None, "it is missing"
    except (ValueError, KeyError, TypeError, AttributeError):
        return None, "it is unreadable"
    if now - gen > max_age or now - gen < -60:
        return None, "it is stale (written %s ago)" % dur_text(now - gen)
    return d, ""


def _page_id(p):
    """A project compared by what it names: a registry row's project is a page key (projects/<slug>), the roles file may give the bare <slug>."""
    p = p.strip() if isinstance(p, str) else ""
    return p[len("projects/"):] if p.startswith("projects/") else p


def record_link(name, key, role, now, poll=None):
    """Link 1: stackshot's project record (stackshot's own answer, else the file copy spawn reads, SALA_PROJECT_RECORD, schema 1) lists NAME on KEY's agents map with ROLE (back = front false). -> ("ok" | "no" | "cannot", detail)."""
    path, note = record_path("projects", poll)
    d, why = _fresh_json(path, env_num("SALA_PROJECT_RECORD_MAX_AGE", 600), now)
    if d is None:
        return "cannot", why + note
    try:
        if d.get("schema") != 1:
            return "cannot", "it is not schema 1"
        projects = d["projects"]
        pid = (d.get("by_key") or {}).get(key)
        p = projects.get(pid) if pid else None
        if p is None:
            p = next((v for v in projects.values() if isinstance(v, dict) and v.get("key") == key), None)
        if not isinstance(p, dict):
            return "cannot", "it has no project %s" % key
        a = (p.get("agents") if isinstance(p.get("agents"), dict) else {}).get(name)
        if not isinstance(a, dict):
            return "no", ""
        if not isinstance(a.get("front"), bool):
            return "cannot", "it gives no front or back for %s" % name
        return ("ok", "") if (role == "front") == a["front"] else ("no", "as a %s agent" % role)
    except (KeyError, TypeError, AttributeError):
        return "cannot", "it is unreadable"


def roles_link(name, key, role, now, poll=None):
    """Link 2: stackshot's roles list (stackshot's own answer, else roles.json, SALA_ROLES_FILE, the file sala's Overview Role column and the lane rules read) has a LIVE entry for NAME that names KEY and carries ROLE. -> ("ok" | "no" | "cannot", detail)."""
    path, note = record_path("roles", poll)
    d, why = _fresh_json(path, env_num("SALA_ROLES_FILE_MAX_AGE", 1800), now)
    if d is None:
        return "cannot", why + note
    sessions = d.get("sessions")
    if not isinstance(sessions, dict):
        return "cannot", "it has no sessions"
    ent = sessions.get(name)
    if not isinstance(ent, dict) or ent.get("retired") is True or _page_id(ent.get("project")) != _page_id(key):
        return "no", ""
    if ent.get("role") != role:
        return "no", "as a %s agent" % role
    return ("ok", "") if ent.get("live") is True else ("no", "as a live session")


def row_link(cfg, name, key, role, limit=LOOKUP_MAX):
    """Link 3: sala's own registry row for NAME (`sessions resolve NAME --live --json`, the liveness command) is NAME's own row and carries project KEY and role ROLE. The command also
    matches a renamed session's old name (the row it answers is the renamed session's), so the row's own name must be NAME. LIMIT: the seconds the command may take. -> ("ok" | "no" | "cannot", detail)."""
    if not cfg["alive_cmd"]:
        return "cannot", "there is no registry command"
    rc, out, _ = run_split(cfg["alive_cmd"] + [name, "--live", "--json"], limit)
    if rc == 1:
        return "no", "as a live session"
    if rc != 0:
        return "cannot", "the registry could not be asked (exit %d)" % rc
    try:
        row = json.loads(out)
    except ValueError:
        return "cannot", "its answer is unreadable"
    if not isinstance(row, dict):
        return "cannot", "its answer is unreadable"
    if row.get("name") != name:
        return "no", "under its own name (that name belongs to a renamed session)"
    if _page_id(row.get("project")) != _page_id(key):
        return "no", ""
    return ("ok", "") if row.get("role") == role else ("no", "as a %s agent" % role)


def unplaced_reason(name, key, bad):
    """The plain sentence for the links that did not put NAME on KEY: `<name> started but the record does not list it on <key>`; one clause a link, in LINKS order."""
    parts = []
    for link, kind, detail in bad:
        if kind == "cannot":
            parts.append("%s could not be read (%s), so it does not confirm it on %s" % (link, detail, key))
        else:
            parts.append("%s does not list it on %s%s" % (link, key, " " + detail if detail else ""))
    return "%s started but %s" % (name, "; ".join(parts))


def read_back(cfg, name, key, role=BACK):
    """The read-back of a started session: is NAME placed on project KEY with ROLE by all three links (the project record, roles.json, sala's registry row)? -> (0, "") when all three
    agree, else (1, the reason, naming each link that does not). The three are read again every SALA_BGAGENTS_PLACE_POLL seconds until SALA_BGAGENTS_PLACE_WAIT seconds are up (the record and
    roles.json are rewritten about every five minutes, a fresh start is on neither at once) and it fails only then; a link that cannot answer (missing, stale, unreadable) is a miss, never
    a pass. The one place this lives: a spawn or rename read-back asks the same question."""
    deadline = time.monotonic() + cfg["place_wait"]
    first = True
    while True:
        # the registry command is bounded by the time left to the deadline (a slow last lookup must not run past SALA_BGAGENTS_PLACE_WAIT), never above its own maximum and never below a floor
        limit = min(LOOKUP_MAX, max(LOOKUP_FIRST if first else LOOKUP_FLOOR, deadline - time.monotonic()))
        first = False
        poll = cfg["place_poll"]      # a live answer is kept no longer than one poll, so the next read sees a start that stackshot has just recorded
        res = (record_link(name, key, role, fresh_now(), poll), roles_link(name, key, role, fresh_now(), poll), row_link(cfg, name, key, role, limit))
        bad = [(LINKS[i], r[0], r[1]) for i, r in enumerate(res) if r[0] != "ok"]
        if not bad:
            return 0, ""
        if time.monotonic() >= deadline:
            return 1, unplaced_reason(name, key, bad)
        time.sleep(min(cfg["place_poll"], max(0.05, deadline - time.monotonic())))


def alert(cfg, text, log):
    """One Slack post through sala's own alert path (`sala alert HEADLINE LINE`, SALA_BGAGENTS_ALERT_CMD); a failed post is one log line and changes nothing."""
    if not cfg["alert_cmd"]:
        log.say("alert", "not posted: no alert command (SALA_BGAGENTS_ALERT_CMD)")
        return
    rc, out = run(cfg["alert_cmd"] + [text, "The job left its session running and did not count it as a start."], 60)
    log.say("alert", "posted to Slack" if rc == 0 else "the Slack post failed (exit %d: %s)" % (rc, last_line(out, 100)))


# ---- the decisions --------------------------------------------------------------------------------------------------------------

def backoff(failures, cfg):
    return min(cfg["cooldown"] * (2 ** max(0, failures - 1)), cfg["cooldown_max"])


def fail(e, key, why, cfg, now, log, led, counts_attempt=False, plain=""):
    """A project failure: the back-off grows, counted from NOW. Pass the time of the failure itself (`fresh_now()`) where the failure comes after a wait (a post, a start, the read-back:
    minutes can have gone since the run began), the run's start where the project is only observed. counts_attempt: a failure the job only observed (relisted, still listed) is one more attempt too, so a project
    that never settles is given up like one that never starts. plain: the same failure in one everyday sentence, kept for the board item (last_plain)."""
    if counts_attempt:
        e["attempts"] += 1
    e["failures"] += 1
    e["next_try"] = int(now + backoff(e["failures"], cfg))
    e["last"], e["last_at"] = "failed: " + why, now
    e["last_plain"], e["last_error"] = plain, why
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
    """-> (ok, created, why, plain). created is False when stackshot says the agent was already listed (nothing changed). plain: the failure in one everyday sentence."""
    cmd = cfg["post_cmd"] + [key, name, "--role", ROLE, "--back", "--mandate", cfg["mandate"], "--sender", cfg["sender"]]
    if not cfg["post_cmd"]:
        return False, False, "no stackshot client on this machine (SALA_BGAGENTS_POST_CMD)", "There is no stackshot client on this machine to add the agent to the project."
    rc, out = run(cmd, cfg["post_timeout"])
    if rc == 0:
        return True, "nothing changed" not in out and "already listed" not in out.lower(), "", ""
    if rc == 124:
        return False, False, "the post timed out (it may have gone through: the next attempt looks at the project record first)", "Adding the agent to the project took too long."
    m = re.search(r"\[(\d{3})\]\s*(.*)", out)
    plain = "Stackshot refused the request to add the agent to the project." if m else "Stackshot did not accept the request to add the agent to the project."     # what happened, never a guessed cause: the error itself is `why`
    return False, False, ("HTTP %s: %s" % (m.group(1), last_line(m.group(2), 250)) if m else "the post failed (exit %d: %s)" % (rc, last_line(out, 120))), plain


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
        ok, created, why, plain = post_agent(cfg, key, name)
        if not ok:
            fail(e, key, "listing %s failed: %s" % (name, why), cfg, fresh_now(), log, led, plain=plain)
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
        placed, reason = read_back(cfg, name, key)
        if placed != 0:
            # live is not registered: the pane is left running and the start is NOT counted; the back-off applies as for any failed attempt, and the miss is told once per attempt
            # (the Slack post here, the board item after the attempt), never once per poll of the read-back
            e["awaiting_record"], e["unplaced"] = False, reason
            fail(e, key, reason, cfg, fresh_now(), log, led, plain=reason[0].upper() + reason[1:] + ".")
            alert(cfg, reason, log)
            return False
        e.update(started_at=now, awaiting_record=False, retire_needed=False, unplaced="", last="started", last_at=now, last_error="")
        log.say("start", "%s: %s is live and placed on the project (the record, roles.json and sala's row agree)" % (key, name))
        led.save()
        return False
    e["awaiting_record"] = False
    why = "the start of %s %s" % (name, "timed out" if rc == 124 else ("failed (exit %d: %s)" % (rc, last_line(out, 100))) if rc != 0 else "did not come up (spawn said it was up, but it is not live)")
    fail(e, key, why, cfg, fresh_now(), log, led, plain="Starting the agent's session took too long." if rc == 124 else
         ("The agent's session could not be started." if rc != 0 else "The agent's session started but did not stay up."))
    if e["created"] and not e["retired"]:
        needed = retire_own_agent(key, name, e, log)
        led.save()
        return needed
    log.say("keep", "%s: %s was not listed by this job; its entry is left as it is" % (key, name))
    return False


# ---- the board item for a project it cannot start --------------------------------------------------------------------------------

def needs_item(e, cfg):
    """A project the job cannot start: at the attempt cap, an agent it listed whose pane did not start (the retire step it may not take itself), or a session that started but is not
    placed on the project by all three of the record, roles.json and sala's row (its pane is left running)."""
    return given_up(e, cfg) or bool(e["retire_needed"]) or bool(e["unplaced"])


def run_split(cmd, timeout, stdin=None):
    """-> (rc, stdout, stderr), the two kept apart (the client prints the answer on stdout and the reason on stderr); rc 124 for a timeout, 127 for a command that cannot be run."""
    try:
        p = subprocess.run(cmd, input=stdin, stdin=None if stdin is not None else subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, text=True, errors="replace")
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "timed out after %d s" % timeout
    except OSError as e:
        return 127, "", "cannot run %s: %s" % (cmd[0] if cmd else "(no command)", e.__class__.__name__)


def record_scope(key):
    """The project's scope in stackshot's project record (stackshot's own answer, else the file copy spawn reads), whatever the copy's age; "" when it says none."""
    path, _note = record_path("projects")
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        pid = (d.get("by_key") or {}).get(key)
        p = d["projects"].get(pid) if pid else None
        if p is None:
            p = next((v for v in d["projects"].values() if isinstance(v, dict) and v.get("key") == key), None)
        return re.sub(r"[^A-Za-z0-9._-]", "", str(p.get("scope") or "")) if isinstance(p, dict) else ""
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return ""


def instance_prefixes(cfg):
    """The subject prefixes the stackshot instance takes (`client.py get config`: {"subject": {"prefixes": [...]}}), or [] when it cannot be read."""
    if not cfg["prefixes_cmd"]:
        return []
    rc, out, _ = run_split(cfg["prefixes_cmd"], cfg["raise_timeout"])
    try:
        v = json.loads(out)["subject"]["prefixes"] if rc == 0 else []
        return [x for x in v if isinstance(x, str) and BRACKET_RE.match(x)]
    except (ValueError, KeyError, TypeError):
        return []


def subject_prefix(cfg, key):
    """-> the bracket a board subject for KEY opens with ("[scope] "), or "" when there is none to use. SALA_BGAGENTS_SUBJECT_PREFIX wins. Else the first of the
    project's own scope (project record), SALA_DEFAULT_SCOPE and the first of SALA_SCOPES that the instance takes as a prefix; none of them: the instance's first
    prefix; the instance not readable: the first of them as it is."""
    if cfg["subject_prefix"]:
        return cfg["subject_prefix"]
    cands = []
    for sc in (record_scope(key), cfg["default_scope"], cfg["first_scope"]):
        b = "[%s] " % sc if sc else ""
        if b and b not in cands:
            cands.append(b)
    known = instance_prefixes(cfg)
    if known:
        return next((c for c in cands if c in known), known[0])
    return cands[0] if cands else ""


def error_text(e, n):
    """The last real error of the attempts (the words the failed step gave, `last_error`; an older ledger entry has only `last`, "failed: <error>"), on one line, cut to N characters;
    "" when none was recorded. Never a guessed cause."""
    err = e["last_error"] or (e["last"][len("failed: "):] if e["last"].startswith("failed: ") else "")
    err = " ".join(err.split())
    return err if len(err) <= n else err[:n - 1].rstrip() + "…"


def noun_of(cfg):
    """What the job calls the one thing it sends for a project it cannot start: a board item for the owner (SALA_BGAGENTS_RAISE=ask) or a report to sala's builder session (the default)."""
    return "board item" if cfg["raise_mode"] == "ask" else "report"


def report_parts(cfg, key, e, known=True, token=""):
    """-> the text of the report sent to sala's builder session (cfg["report_to"]) for a project the job cannot start: the project, the agent, the attempts, the last real error and what to do.
    token: the report's id (the ledger's `raise_token`, the one a retry of the same report reuses), so a repeat after a timeout is seen to be the same report."""
    agent = e["agent"] or "%s-%s" % (e["prefix"] or key.split("/", 1)[-1], ROLE)
    why = ("its attempts reached the maximum and the job has stopped trying" if given_up(e, cfg) else
           "its session is live but not placed on the project (the pane is left running)" if e["unplaced"] else
           "the agent is on the project but its session did not start, and no unattended path takes it off")
    err = error_text(e, ERROR_MAX)
    lines = ["bg-agents could not give %s its background agent: %s." % (key, why if known else "the start did not finish, and whether the session is live could not be told"),
             "Agent: %s. Attempts: %d of %d (failures: %d)." % (agent, e["attempts"], cfg["max_attempts"], e["failures"]),
             "Last error: %s" % (err or "none was recorded."),
             "This is a fault in the job or its setup, not a decision of the owner. Fix the cause, then run `sala bg-agents --reset %s` so the next run tries the project afresh; until then the job leaves it alone." % key]
    if token:
        lines.append("Report id: %s" % token)
    return "\n".join(lines) + "\n"


def item_parts(cfg, key, e, prefix, known=True):
    """-> (subject, ask, text lines, options): the owner's item in everyday words (no exit code, no command). known: the job saw that the agent's session is not running;
    when the liveness check could not say (known False) the item says only what is known: that the start did not finish."""
    slug = key.split("/", 1)[-1]
    n = e["failures"] or e["attempts"] or 1
    times = "%d time%s" % (n, "" if n == 1 else "s")
    what = "its start failed %s" % times if known else "its start did not finish"
    subject = prefix + "%s wants a background agent and %s" % (slug, what)
    if len(subject) > SUBJECT_MAX:
        subject = subject[:SUBJECT_MAX - 1].rstrip() + "…"
    stakes = "the project has no background agent until then" if known else "the job does not try again until then"
    ask = "Decide: what to do about the background agent of %s · Recommend: %s · Stakes: %s · By: any time" % (slug, RECOMMENDED, stakes)
    agent = e["agent"] or "%s-%s" % (e["prefix"] or slug, ROLE)
    err = error_text(e, 160)
    lines = ["%s wants a background agent (%s), and %s." % (slug, agent, "starting it has failed %s" % times if known else "the start did not finish"),
             "The last problem: %s%s" % (e["last_plain"] or "no reason was recorded.", " The error it gave: %s" % err if err else "")]
    if given_up(e, cfg):
        lines.append("The job has stopped trying, so the project stays without a background agent until you decide." if known else "The job has stopped trying until you decide.")
    if e["retire_needed"]:
        lines.append("The agent is still on the project although its session is not running, and the job may not take it off without your word." if known else
                     "The agent is still on the project, and the job may not take it off without your word.")
    lines.append("If you pick \"%s\", a session resets the project's record and the job tries again." % RECOMMENDED)
    return subject, ask, lines, list(OPTIONS)


class RunLock:
    """The run's flock on <ledger>.lock. The raise gives it up around its network call (release) and takes it again to write the result (retake), so a slow stackshot never
    holds `--reset` or another run out."""

    def __init__(self, fd):
        self.fd = fd

    def release(self):
        fcntl.flock(self.fd, fcntl.LOCK_UN)

    def retake(self, wait=15.0):
        end = time.monotonic() + wait
        while True:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return True
            except OSError:
                if time.monotonic() >= end:
                    return False
                time.sleep(0.1)


def new_token(key, now):
    """The request id of ONE escalation: the full project key (scope-slug), the time and a random part, so two projects with one slug, or one project escalating twice in a second
    (a reset between), never share an id. Kept in the ledger: a retry of the same escalation names the same question."""
    return "bgagents-%s-%d-%s" % (key.replace("/", "-")[:64], now, secrets.token_hex(4))


def raise_item(cfg, key, e, now, log, led, dry, lock=None, known=True):
    """Raise the one board item for KEY. -> True when it was raised (or would be, in a dry run), False when it could not be (`board item needed: KEY`; `raised` stays false, the
    failure is counted on the project and its next filing waits out a back-off like a start's), None when the result was set aside (a reset, or the project started, meanwhile).
    Never touches attempts, failures or the start's back-off, and never takes the run's one attempt.
    The ledger lock is NOT held across the network calls. Under it the entry gets its request id (the idempotency key a retry reuses), `raising_at` (the clock when filing begins, not
    the run's start: the mark that makes every other run leave the project alone while the item is filed) and `raising_by` (a token of THIS filing attempt, its owner); the calls are
    made without the lock; then it is taken again and the entry is read as it is on disk: the result is written only when that entry still carries this raise's request id (a `--reset`
    that ran meanwhile cleared it, and wins), is still marked as this attempt's (a later filing of the same project, after this one's window ran out, owns it now and this result is
    set aside) and the project still needs the item (a start that worked meanwhile is not told to the owner as a failure)."""
    ask_mode, noun = cfg["raise_mode"] == "ask", noun_of(cfg)
    if dry:
        log.say("plan", "%s: would %s (%s)" % (key, "raise one board item for the owner" if ask_mode else "report to %s" % cfg["report_to"],
                                               "given up" if given_up(e, cfg) else "its started session is not placed on the project" if e["unplaced"] else "an agent this job listed did not start"))
        return True

    def failure(x, why):
        x["raise_failures"] += 1
        x["raise_next_try"] = int(now + backoff(x["raise_failures"], cfg))
        x["raising_at"], x["raising_by"] = 0, ""
        log.say("raise", "%s needed: %s (could not be %s: %s); tried again after %s" % (noun, key, "raised" if ask_mode else "sent", why, local_text(x["raise_next_try"])))
        return False

    if not (cfg["ask_cmd"] if ask_mode else cfg["report_cmd"]):
        r = failure(e, "no stackshot client on this machine (%s)" % ("SALA_BGAGENTS_ASK_CMD" if ask_mode else "SALA_BGAGENTS_REPORT_CMD"))
        led.save()
        return r
    if not ask_mode and not cfg["report_to"]:
        r = failure(e, "no session to report to (set SALA_BGAGENTS_REPORT_TO)")
        led.save()
        return r
    if not e["raise_token"]:
        e["raise_token"] = new_token(key, now)     # kept before the call: a retry after a timeout names the same question and files nothing twice
    by = secrets.token_hex(8)
    e["raising_at"], e["raising_by"] = fresh_now(), by      # when the filing begins: the probes and the start before it may have taken the run's whole window
    led.save()
    token, snap = e["raise_token"], dict(e)
    if lock:
        lock.release()
    try:
        prefix = subject_prefix(cfg, key) if ask_mode else ""
        res = None
        if not ask_mode:
            res = run_split(cfg["report_cmd"] + [cfg["report_to"], "-", "--sender", ASK_SENDER], cfg["raise_timeout"], report_parts(cfg, key, snap, known, token))
        elif prefix:
            subject, ask, lines, options = item_parts(cfg, key, snap, prefix, known)
            cmd = cfg["ask_cmd"] + ["--project", key, "--subject", subject, "--ask", ask, "--request-id", token, "--sender", ASK_SENDER]
            for label, line in options:
                cmd += ["--option", "%s=%s" % (label, line)]
            cmd += ["--recommended", RECOMMENDED]
            res = run_split(cmd, cfg["raise_timeout"], "\n".join(lines) + "\n")
    finally:
        held = lock.retake() if lock else True
    if not held:
        log.say("raise", "%s needed: %s (could not be %s: the ledger is locked by another process; it may have gone out and the next try names the same %s)" % (noun, key, "raised" if ask_mode else "sent", "question" if ask_mode else "report"))
        return False
    item, why = "", ""
    if res is None:
        why = "no subject prefix: set SALA_BGAGENTS_SUBJECT_PREFIX"
    else:
        rc, out, err = res
        if ask_mode:
            item = (out.split() or [""])[0]
            if rc != 0 or not item or len(item) > 40:
                why = "exit %d: %s" % (rc, last_line(err or out, 120)) if rc != 0 else "the client printed no item id"
        else:
            item = cfg["report_to"]
            if rc != 0:
                why = "exit %d: %s" % (rc, last_line(err or out, 120))
    cur = Ledger(led.path, False)       # the entry as it is on disk now: a reset (or another run) may have changed it during the call
    ce = cur.projects.get(key)
    if ce is None or ce["raise_token"] != token:
        log.say("raise", "%s: the record was reset while the %s was being %s%s; the result is not recorded" % (key, noun, "filed" if ask_mode else "sent", " (%s %s)" % ("item" if ask_mode else "sent to", item) if not why else ""))
        return None
    if ce["raising_by"] != by:
        log.say("raise", "%s: another %s of this %s took over while this one was in flight (its window ran out); this result is not recorded%s" % (key, "filing" if ask_mode else "sending", noun, "" if why else " (%s %s)" % ("item" if ask_mode else "sent to", item)))
        return None
    if not ce["raised"] and (not needs_item(ce, cfg) or ce["started_at"] != snap["started_at"]):
        ce["raising_at"], ce["raising_by"] = 0, ""      # recovered while the item was filed (another run started the agent): no failure, no back-off, no item for a project that is running
        cur.save()
        log.say("raise", "%s: the project is no longer stuck (it started while the %s %s); nothing is recorded" % (key, noun, ("was being filed" if not why else "was being filed and the filing failed") if ask_mode else ("was being sent" if not why else "was being sent and the sending failed")))
        return None
    if why:
        r = failure(ce, why)
        cur.save()
        return r
    ce.update(raised=True, raised_at=now, raised_item=item, raising_at=0, raising_by="", raise_failures=0, raise_next_try=0)
    cur.save()
    what = "given up" if given_up(ce, cfg) else "not placed on the project" if ce["unplaced"] else "retire needed"
    if ask_mode:
        log.say("raise", "%s: board item %s raised for the owner (%s)" % (key, item, what))
    else:
        log.say("raise", "%s: reported to %s (%s; last error: %s)" % (key, item, what, error_text(ce, 160) or "none recorded"))
    return True


STALE_TEXT = "agent running, want list stale"
NOT_PROBED = object()       # a liveness answer this run did not get (the probe cap); never confused with None, "the check could not say"
CHANGED = object()          # an answer that was dropped: the project's entry changed (another run acted on it) while the check was made


def unsure(r, cfg):
    """Why a project is left as it is: the words of the log line for an answer that is not a confirmed live / not live."""
    if r is None:
        return "could not be told"
    if r is CHANGED:
        return "was overtaken by another run (its entry changed while it was checked)"
    return "is checked at a later run (at most %d checks a run)" % cfg["max_probes"]


def pending(e):
    """An agent whose pane the job has not started (counted) yet: the want list no longer shows such a project (its agent is on the map), so the ledger drives it. Either this job listed
    the agent (`posted_at`), or the agent was already on the map and its pane came up but was not placed in its project (`unplaced`: no listing was made, so `posted_at` stays 0, yet the
    entry still owes its board item and its next attempt)."""
    return bool((e["posted_at"] or e["unplaced"]) and not e["started_at"] and not e["retired"])


class NullLog:
    def say(self, action, text):
        pass


def probe_sig(led, name):
    """What the start path decides on for the projects that carry the agent NAME: if it differs after a check, another run acted on them and the answer is out of date."""
    return tuple(sorted((k, e["started_at"], e["stale"], e["attempts"], e["raised"]) for k, e in led.projects.items() if e["agent"] == name))


class ProbeBook:
    """The liveness answers of a run: name -> True (live), False (confirmed not live), None (the check could not say), CHANGED (dropped, see probe_sig). A name with no answer is
    NOT_PROBED. In `collect` mode nothing is answered and the names asked for are kept, in the order they were asked."""

    def __init__(self, results=None, collect=False, sigs=None):
        self.results, self.collect, self.wanted, self.sigs = results or {}, collect, [], sigs or {}

    def get(self, name):
        if not name:
            return None
        if name in self.results:
            return self.results[name]
        if self.collect and name not in self.wanted:
            self.wanted.append(name)
        return NOT_PROBED

    def forget(self, name):
        """The run attempted a start of this agent: whatever was answered before it (a "not live" most of all, the pane may have come up since, or be coming up) is out of date."""
        if not self.collect and name in self.results:
            self.results[name] = CHANGED

    def revalidate(self, led):
        """After the lock was given up and taken again: an answer whose projects changed meanwhile is dropped (CHANGED), so a cached "not live" never starts an agent another run just started."""
        for n in list(self.results):
            if self.results[n] is not CHANGED and probe_sig(led, n) != self.sigs.get(n):
                self.results[n] = CHANGED


def probe_window(cfg, wanted, cap, led, now, lock, dry):
    """Ask whether up to CAP of the sessions in WANTED are live, WITHOUT the ledger lock (a probe may take 30 s). The ledger is saved first, the lock given up, the probes made, the lock
    taken again and the ledger read again from disk (a reset or another run may have changed it; an answer for a project that changed is dropped), and each probed project's `probed_at`
    is set (the least recently probed go first, so a few live projects never starve the rest). -> (a ProbeBook, the ledger), or (None, None) when the lock could not be taken again.
    No command to ask with: every answer is None, no lock is given up, and `probed_at` is still advanced for the names considered, so the same first names never take the slots every run."""
    seen = {e["agent"]: e["probed_at"] for e in led.projects.values() if e["agent"]}
    names = []
    for n in sorted(wanted, key=lambda n: seen.get(n, 0)):
        if n not in names:
            names.append(n)
    names = names[:cap]
    if not names:
        return ProbeBook(), led
    if not cfg["alive_cmd"]:
        for e in led.projects.values():
            if e["agent"] in names:
                e["probed_at"] = now
        led.save()
        return ProbeBook({n: None for n in names}), led
    sigs = {n: probe_sig(led, n) for n in names}
    led.save()
    if lock:
        lock.release()
    try:
        results = {n: alive_state(cfg, n) for n in names}
    finally:
        held = lock.retake() if lock else True
    if not held:
        return None, None
    if lock:
        led = Ledger(led.path, dry)
    book = ProbeBook(results, sigs=sigs)
    book.revalidate(led)
    for e in led.projects.values():
        if e["agent"] in results:
            e["probed_at"] = now
    led.save()
    return book, led


def raise_order(cfg, led, listed, now):
    """The projects that need a board item and have none, that another run is not filing right now: the least recently probed first, then by key."""
    ks = [k for k, e in led.projects.items() if not e["raised"] and needs_item(e, cfg) and (k in listed or pending(e)) and not raising_now(e, cfg)]
    return sorted(ks, key=lambda k: (led.projects[k]["probed_at"], k))


def raise_next(cfg, led, listed, now, log, dry, lock, probes):
    """After the run's attempt: the ONE raise of the run, for the first project that needs an item, has none and is DUE for one (a project whose last filing failed waits out its own
    back-off, so a key the board keeps refusing never holds the others back). A project whose agent session is live is no start failure: it is recorded as `agent running, want list
    stale` and raises nothing; when the check cannot say, a project that was already stale is left as it is and any other is raised saying only that the start did not finish.
    -> 1 when the raise could not be made (or an item is still waiting out its filing back-off and nothing was raised)."""
    waiting = raise_order(cfg, led, listed, now)
    held_back = 0
    for i, key in enumerate(waiting):
        e = led.projects[key]
        if e["raise_next_try"] > now:
            held_back += 1
            log.say("raise", "%s still needed: %s (the last %s failed %d time%s; next try %s)" % (noun_of(cfg), key, "filing" if cfg["raise_mode"] == "ask" else "sending", e["raise_failures"], "" if e["raise_failures"] == 1 else "s", local_text(e["raise_next_try"])))
            continue
        r = False if e["unplaced"] else probes.get(e["agent"])      # a session that is live and not placed is the failure itself: the stale check does not hold its item back
        if r is NOT_PROBED or r is CHANGED:
            log.say("raise", "%s: whether its agent's session is live %s; the %s waits" % (key, unsure(r, cfg), noun_of(cfg)))
            continue
        if r is True:
            if not e["stale"] and not dry:
                e["stale"], e["last"], e["last_at"] = True, STALE_TEXT, now
                led.save()
            log.say("stale", "%s: %s (%s is live while the project is still on the want list): no %s %s, no new attempt while its pane is alive" % (key, STALE_TEXT, e["agent"], noun_of(cfg), "raised" if cfg["raise_mode"] == "ask" else "sent"))
            continue
        if r is None and (e["stale"] or e["started_at"]):       # a pane that is, or may be, running: no failure item for it on a check that cannot say
            log.say("stale", "%s: whether %s is live could not be told; the entry is left as it is (%s, no %s, no attempt)" % (key, e["agent"], "stale" if e["stale"] else "its pane was started", noun_of(cfg)))
            continue
        if r is False and e["stale"] and not dry:
            e["stale"] = False      # its pane is confirmed gone: the project is looked at as any other
            led.save()
        more = sum(1 for k in waiting[i + 1:] if led.projects[k]["raise_next_try"] <= now)
        res = raise_item(cfg, key, e, now, log, led, dry, lock, known=r is False)
        if more:
            log.say("raise", "%d more project%s still need%s a %s; one a run, the rest wait for the next run" % (more, "" if more == 1 else "s", "s" if more == 1 else "", noun_of(cfg)))
        return 1 if res is False else 0
    return 1 if held_back else 0


def start_one(cfg, cands, listed, led, now, log, dry, probes):
    """The run's one attempt: the candidates in order, the first project that is due. -> 1 when a retire is needed. A pane's liveness comes from PROBES (asked outside the lock):
    only a confirmed "not live" lets a project that was running (stale, or started) into the start path again; an answer that could not be told, or none this run, leaves it as it is."""
    for key, prefix, _front in cands:
        e = led.projects.get(key)
        if e is not None:
            if given_up(e, cfg):
                log.say("skip", "%s: given up after %d attempts (%s); left alone" % (key, e["attempts"], e["last"] or "no outcome"))
                continue
            if e["raised"]:     # the owner has been asked: no start attempt until a session resets the record (`--reset`, what "Keep trying later" is); the other two answers leave it so
                log.say("skip", ("%s: board item %s raised; left alone until a session resets the project's record" if cfg["raise_mode"] == "ask" else "%s: reported to %s; left alone until a session resets the project's record") % (key, e["raised_item"] or "-"))
                continue
            if raising_now(e, cfg):      # another run is filing the item for this project right now (its lock is given up for the call): no start under it
                log.say("skip", "%s: another run is %s its %s (since %s); no attempt meanwhile" % (key, "filing" if cfg["raise_mode"] == "ask" else "sending", noun_of(cfg), local_text(e["raising_at"])))
                continue
            if e["stale"]:
                r = probes.get(e["agent"])
                if r is True:
                    log.say("skip", "%s: %s (%s is live); no attempt while its pane is alive" % (key, STALE_TEXT, e["agent"]))
                    continue
                if r is not False:
                    log.say("skip", "%s: %s; whether %s is live %s: the entry is left as it is, no attempt" % (key, STALE_TEXT, e["agent"], unsure(r, cfg)))
                    continue
                e["stale"] = False      # its pane is confirmed gone: the project is looked at as any other
                led.save()
            if e["retired"] and key in listed:       # this job created the agent and retired it earlier, and the project wants one again
                e["retired"], e["created"], e["posted_at"] = False, False, 0
                fail(e, key, "listed again after this job created and retired its agent", cfg, now, log, led, counts_attempt=True,
                     plain="The project asked for a background agent again after this job had added one and taken it off.")
                continue
            if e["next_try"] > now:
                log.say("skip", "%s: backing off until %s (attempt %d of %d)" % (key, local_text(e["next_try"]), e["attempts"], cfg["max_attempts"]))
                continue
            if e["started_at"]:
                r = probes.get(e["agent"])
                if r is None or r is NOT_PROBED or r is CHANGED:
                    log.say("skip", "%s: %s was started; whether it is live %s: the entry is left as it is, no attempt" % (key, e["agent"], unsure(r, cfg)))
                    continue
                if r is True:
                    if key in listed and now - e["started_at"] >= cfg["cooldown"]:
                        fail(e, key, "still on the want list %s after its pane started (the pane is left running)" % dur_text(now - e["started_at"]), cfg, now, log, led, counts_attempt=True,
                             plain="The agent's session is running, but the project kept asking for a background agent.")
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
        needed = attempt(cfg, key, prefix, e, now, log, led)
        probes.forget(e["agent"])       # (the attempt may have made the pane, even when it reports a failed start)
        return 1 if needed else 0
    return 0


def candidates(rows, led, listed):
    """The list's projects in its order, then the ones this job listed an agent for and has not started (off the list because the agent is on the map now)."""
    return list(rows) + [(k, led.projects[k]["prefix"], "") for k in sorted(led.projects) if k not in listed and pending(led.projects[k]) and led.projects[k]["prefix"]]


def one_run(cfg, dry, now, log, lock=None):
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
        elif now - e["absent_since"] >= cfg["cooldown"] and not pending(e) and not e["raised"] and not raising_now(e, cfg):
            # a raised entry is never pruned: the owner was asked, and the project stays left alone, on the list or off it, until a session resets it (`--reset`)
            log.say("reset", "%s: off the list for %s: its ledger entry is cleared" % (key, dur_text(now - e["absent_since"])))
            del led.projects[key]
            changed = True
    if changed:
        led.save()
    if not candidates(rows, led, listed):
        log.say("idle", "nobody on the want list")
        return 0
    # the liveness probes of the start phase (a pane that was started, or is marked stale), asked without the lock; at most SALA_BGAGENTS_MAX_PROBES - 1 of them, one is left for the raise
    book = ProbeBook(collect=True)
    ghost = copy.deepcopy(led)
    ghost.dry = True        # the collecting pass decides nothing and writes nothing
    start_one(cfg, candidates(rows, led, listed), listed, ghost, now, NullLog(), True, book)
    first, led = probe_window(cfg, book.wanted, cfg["max_probes"] - 1, led, now, lock, dry)
    if led is None:
        log.say("skip", "the ledger is locked by another process after the liveness checks; nothing more this run")
        return 0
    retire = start_one(cfg, candidates(rows, led, listed), listed, led, now, log, dry, first)     # the starts come first ...
    first.revalidate(led)       # an answer given before this run's own start of that agent is out of date (the pane may have come up since): dropped, so the raise phase asks again or leaves it
    # ... then at most one board item: its liveness probes (the rest of the cap), then the call itself, both without the lock
    due = [led.projects[k]["agent"] for k in raise_order(cfg, led, listed, now) if led.projects[k]["raise_next_try"] <= now and led.projects[k]["agent"] and not led.projects[k]["unplaced"] and first.results.get(led.projects[k]["agent"], CHANGED) is CHANGED]
    second, led = probe_window(cfg, due, cfg["max_probes"] - len(first.results), led, now, lock, dry)
    if led is None:
        log.say("skip", "the ledger is locked by another process after the liveness checks; no %s this run" % noun_of(cfg))
        return 1 if retire else 0
    first.revalidate(led)
    unraised = raise_next(cfg, led, listed, now, log, dry, lock, ProbeBook(dict(first.results, **second.results)))
    return 1 if (retire or unraised) else 0


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
        if e["raised"] and not given_up(e, cfg):
            extra += ("; board item %s raised (%s)" if cfg["raise_mode"] == "ask" else "; reported to %s (%s)") % (e["raised_item"] or "-", local_text(e["raised_at"]))
        elif e["raised"]:
            extra += "; %s %s (%s)" % ("item" if cfg["raise_mode"] == "ask" else "reported to", e["raised_item"] or "-", local_text(e["raised_at"]))
        if e["raise_failures"] and not e["raised"]:
            extra += "; the %s could not be %s %d time%s, next try %s" % (noun_of(cfg), "filed" if cfg["raise_mode"] == "ask" else "sent", e["raise_failures"], "" if e["raise_failures"] == 1 else "s", local_text(e["raise_next_try"]))
        print("%s  %s  attempts %d/%d  failures %d  next try %s  %s%s" % (key, e["agent"] or "-", e["attempts"], cfg["max_attempts"], e["failures"], nxt, state_of(e, cfg, now), extra))
    return 0


def config():
    return {
        "cooldown": env_num("SALA_BGAGENTS_COOLDOWN", 600.0), "cooldown_max": env_num("SALA_BGAGENTS_COOLDOWN_MAX", 86400.0),
        "max_attempts": int(env_num("SALA_BGAGENTS_MAX_ATTEMPTS", 5)), "max_load": env_num("SALA_BGAGENTS_MAX_LOAD", 10.0),
        "loadavg": os.environ.get("SALA_BGAGENTS_LOADAVG") or "/proc/loadavg", "ledger": ledger_path(),
        "sender": os.environ.get("SALA_BGAGENTS_SENDER") or "sala-web", "mandate": mandate_text(),
        "record_grace": env_num("SALA_BGAGENTS_RECORD_GRACE", 900.0), "alive_wait": env_num("SALA_BGAGENTS_ALIVE_WAIT", 30.0),
        "post_timeout": env_num("SALA_BGAGENTS_POST_TIMEOUT", 120.0), "raise_timeout": env_num("SALA_BGAGENTS_RAISE_TIMEOUT", 30.0), "max_probes": max(2, int(env_num("SALA_BGAGENTS_MAX_PROBES", 3))),
        "spawn_timeout": env_num("SALA_BGAGENTS_SPAWN_TIMEOUT", 300.0),
        "place_wait": env_num("SALA_BGAGENTS_PLACE_WAIT", 360.0), "place_poll": env_num("SALA_BGAGENTS_PLACE_POLL", 5.0),
        "list_cmd": cmd_words("SALA_BGAGENTS_LIST_CMD"), "post_cmd": cmd_words("SALA_BGAGENTS_POST_CMD"),
        "spawn_cmd": cmd_words("SALA_BGAGENTS_SPAWN_CMD"), "alive_cmd": cmd_words("SALA_BGAGENTS_ALIVE_CMD"),
        "raise_mode": "ask" if os.environ.get("SALA_BGAGENTS_RAISE", "").strip().lower() == "ask" else "report",
        "report_cmd": cmd_words("SALA_BGAGENTS_REPORT_CMD"), "report_to": os.environ.get("SALA_BGAGENTS_REPORT_TO", "").strip(),
        "ask_cmd": cmd_words("SALA_BGAGENTS_ASK_CMD"), "alert_cmd": cmd_words("SALA_BGAGENTS_ALERT_CMD"), "prefixes_cmd": cmd_words("SALA_BGAGENTS_PREFIXES_CMD"),
        "subject_prefix": os.environ.get("SALA_BGAGENTS_SUBJECT_PREFIX", ""),
        "default_scope": first_word("SALA_DEFAULT_SCOPE"), "first_scope": first_word("SALA_SCOPES"),
    }


RESET_FIELDS = ("attempts", "failures", "next_try", "retire_needed", "raised", "raised_at", "raised_item", "raise_token", "stale", "raising_at", "raising_by", "raise_failures", "raise_next_try", "probed_at", "unplaced", "last", "last_at", "last_plain", "last_error")
USAGE = "usage: sala bg-agents [--dry-run | --status | --reset <project key> [--dry-run]]"


def reset_project(cfg, key, dry, now, log):
    """`--reset KEY`: a ledger edit, not a run (it works with the switch off). Clears the project's attempts, failures, back-off (so it is not given up), retire_needed, the board item
    (raised, raised_at, raised_item, raise_token) and the last outcome, so the next run tries it afresh. The agent's entry on the project is left as it is: the ledger keeps the
    agent, its listing and its start, so the next run sees the agent already listed and goes to the start. A key with no entry is refused (exit 1). Atomic like every write."""
    path = cfg["ledger"]
    if not os.path.exists(path):
        print("bg-agents: no ledger entry for %s; nothing cleared" % key, file=sys.stderr)
        return 1
    lock = None
    if not dry:
        lock = os.open(path + ".lock", os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print("bg-agents: another run holds the lock; nothing cleared", file=sys.stderr)
            return 1
    led = Ledger(path, dry)
    e = led.projects.get(key)
    if e is None:
        print("bg-agents: no ledger entry for %s; nothing cleared" % key, file=sys.stderr)
        return 1
    state = "given up" if given_up(e, cfg) else "retire needed" if e["retire_needed"] else "backing off" if e["next_try"] > now else "not stuck"
    was = "attempts %d, failures %d, %s%s" % (e["attempts"], e["failures"], state, (", board item raised" if cfg["raise_mode"] == "ask" else ", report sent") if e["raised"] else "")
    for f in RESET_FIELDS:
        e[f] = BLANK[f]
    log.say("reset", "%s: %s the ledger entry (was: %s); the next run tries it afresh, the agent's entry on the project is left as it is" % (key, "would clear" if dry else "cleared", was))
    led.save()
    return 0


def main(argv):
    args = argv[1:]
    dry = stat = False
    reset = None
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--dry-run":
            dry = True
        elif a == "--status":
            stat = True
        elif a == "--reset":
            if i + 1 >= len(args) or args[i + 1].startswith("-") or reset is not None:
                print(USAGE, file=sys.stderr)
                return 2
            reset = args[i + 1]
            i += 1
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            print(USAGE, file=sys.stderr)
            return 2
        i += 1
    if (dry and stat) or (stat and reset is not None):
        print(USAGE, file=sys.stderr)
        return 2
    cfg = config()
    if stat:
        return status(cfg)
    now = now_s()
    log = Log(now, dry)
    if reset is not None:
        return reset_project(cfg, reset, dry, now, log)
    if os.environ.get("SALA_BGAGENTS", "off").strip().lower() != "on":
        print("bg-agents is off (SALA_BGAGENTS=on in the config turns it on); nothing done")
        return 0
    if not mandate_ok(cfg["mandate"]):
        print("bg-agents: SALA_BGAGENTS_MANDATE must be one line of at most 600 characters with no control character or backslash; nothing done", file=sys.stderr)
        return 2
    if os.environ.get("SALA_BGAGENTS_RAISE", "").strip().lower() not in ("", "report", "ask"):
        print("bg-agents: SALA_BGAGENTS_RAISE must be report (the default) or ask; nothing done", file=sys.stderr)
        return 2
    if cfg["report_to"] and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:/-]{0,79}", cfg["report_to"]):
        print("bg-agents: SALA_BGAGENTS_REPORT_TO must be a session's name (letters, digits, . _ : / -); nothing done", file=sys.stderr)
        return 2
    sp = cfg["subject_prefix"]
    if sp:
        sp = sp.strip()
        cfg["subject_prefix"] = sp = "[%s] " % sp[1:-1] if sp.startswith("[") and sp.endswith("]") else sp + " "
        if not BRACKET_RE.match(sp):
            print("bg-agents: SALA_BGAGENTS_SUBJECT_PREFIX must be a bracket word like [scope] (letters, digits, . _ -); nothing done", file=sys.stderr)
            return 2
    if not dry:
        os.makedirs(os.path.dirname(cfg["ledger"]), mode=0o700, exist_ok=True)
        lock = os.open(cfg["ledger"] + ".lock", os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print("bg-agents: another run holds the lock; nothing done")
            return 0
    rc = one_run(cfg, dry, now, log, None if dry else RunLock(lock))
    if dry:
        print("dry run: nothing was posted, started or written")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
