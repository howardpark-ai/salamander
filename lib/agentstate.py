#!/usr/bin/env python3
"""agentstate.py: the per-agent working-state snapshot the heartbeat writes and hands to stackshot (docs/stackshot-contracts.md, interface 38).

stackshot's board server runs on another machine, with no ssh to this one and no notion of which machine an agent is on. It needs, for each REGISTERED AGENT of this box
(a live or sleeping row of the session registry, docs/session-registry.md), whether the agent is busy or idle and what its running subagents are. sala decides, stackshot
only reads. The file is `<live store>/<letter>/agent-state.json`, written atomically on EVERY heartbeat run and never into git (a brief is free text), then posted:

  {"schema": 1, "written": <epoch s>, "agents": {"<agent name>": <entry>}}        the keys of an entry are ENTRY_KEYS below, the one place that names them

  state      busy | idle | unknown   busy: the pane is in a turn, or a subagent applies; idle: the pane is idle, shell or asleep and no subagent applies and read is true;
                                     unknown: read is false, or the pane's state cannot be read, or the name is not one session's. A reader never takes unknown for idle.
  since      epoch s   when the state last changed (the last file's `since` while the state is the same; else the pane's own status stamp when it flipped since the last
                       file, else `written`)
  why        one plain line
  pane       turn | idle | shell | sleeping | unknown   the CLI's registry status of the agent's pane (busy is a turn); sleeping = no claude, its marker; unknown = not readable
  read       false when the subagents could not be read (running() raised): subagents is [] then, and state is unknown
  subagents  stackshot's own `running(session, roots, now)` list (audit/subagent_tie.py), the redundant `text` key dropped and `brief` cut to BRIEF_BYTES bytes at a character
             boundary: [{"id", "description", "brief", "at", "quiet": true?, "unreadable": true?, "meta_at": <epoch s>?}]

stackshot's own code decides which subagents are running: this module IMPORTS `stackshot.audit.subagent_tie` from stackshot's production checkout (SALA_STACKSHOT_CHECKOUT,
default $SALA_STACKSHOT_DIR, else ~/stackshot), never copies its rules and never writes into that checkout (no bytecode, no git). The one rule kept here is the audit's own filter
for a pane that is not in a turn (`applies`), copied with its source named. Standard library only; the heartbeat loads this file and calls `publish` in its own process.

Settings (heartbeat.sh passes them in HB_AS_*): SALA_AGENT_STATE=off writes and posts nothing; SALA_AGENT_STATE_POST_CMD is the command the file's path is appended to (empty = no post; the default is the stackshot client's `post agent-state --file` with the machine token and STACKSHOT_CLIENT_PASS unset, since a pass opens only the New session form's calls);
SALA_AGENT_STATE_TIMEOUT is how long that command may run (30 s); SALA_STACKSHOT_CHECKOUT; SALA_AGENT_STATE_TRANSCRIPTS (the roots of Claude Code's transcripts, `:` separated);
SALA_AGENT_STATE_MAX_BODY (900000 bytes: stackshot refuses a body over 1 MB). A failure to import, write or post logs ONE line per five minutes to
$SALA_LOG_DIR/salamander-agent-state.log and never fails the heartbeat."""
from __future__ import annotations

import calendar
import importlib
import json
import os
import shlex
import signal
import subprocess
import sys
import time

SCHEMA = 1
ENTRY_KEYS = ("state", "since", "why", "pane", "read", "subagents")        # the keys of an agent's entry, in the order they are written
SUB_KEYS = ("id", "description", "brief", "at")                           # of a subagent, always; running() adds quiet, unreadable and meta_at only where they hold
SUB_FLAGS = ("quiet", "unreadable")
STATES = ("busy", "idle", "unknown")
PANES = ("turn", "idle", "shell", "sleeping", "unknown")
BRIEF_BYTES = 2048             # of a subagent's brief at most this many bytes are kept
MAX_BODY = 900000              # stackshot refuses a body over 1 MB (400, the old snapshot stays): over this, briefs are shortened
SHRINK_STEPS = (512, 0)        # …longest first, to this many bytes, then to none: an agent and its state are never dropped
LOG_GAP = 300                  # one log line of a kind per this many seconds
LOG_NAME = "salamander-agent-state.log"
STATUS_PANE = {"busy": "turn", "idle": "idle", "shell": "shell"}      # the CLI registry's status → pane; any other status (a dialog open, say) reads unknown, as the audit does
OFF_WORDS = ("off", "0", "no", "false")


# ---- the snapshot --------------------------------------------------------------------------------------------------------------
def cut_bytes(text: str, limit: int) -> str:
    """`text` cut to at most `limit` bytes of UTF-8, at a character boundary (a cut character is dropped whole)."""
    b = text.encode("utf-8")
    return text if len(b) <= limit else b[:limit].decode("utf-8", "ignore")


def entry(state: str, since: int, why: str, pane: str, read: bool, subagents: list) -> dict:
    """One agent's entry: every key of ENTRY_KEYS, in order."""
    vals = {"state": state, "since": since, "why": why, "pane": pane, "read": read, "subagents": subagents}
    return {k: vals[k] for k in ENTRY_KEYS}


def shape(s: dict) -> dict:
    """One subagent of running()'s list as the file carries it: no `text`; description and brief always a string; times whole seconds."""
    out = {"id": str(s.get("id") or ""), "description": str(s.get("description") or ""), "brief": cut_bytes(str(s.get("brief") or ""), BRIEF_BYTES), "at": int(float(s.get("at") or 0))}
    for k in SUB_FLAGS:
        if s.get(k):
            out[k] = True
    if s.get("meta_at") is not None:
        out["meta_at"] = int(float(s["meta_at"]))
    return out


def applies(s: dict, pane: str, now: float, running_s: float) -> bool:
    """Does a subagent from running() count for this pane? The audit's own filter, reproduced from stackshot's `_mover_subagents` (stackshot/service/audit_ticks.py): a pane in a turn
    keeps every entry (a quiet subagent may wait on a long CI or suite run); for an idle, shell or sleeping pane a quiet one is dropped (a recycled or killed pane leaves one behind), and so is
    an unreadable one whose meta file (`meta_at`) is older than `running_s` (subagent_tie.RUNNING_S, 90 minutes: a meta with no transcript beside it). An unreadable one with no `meta_at` is kept."""
    if pane == "turn":
        return True
    if s.get("quiet"):
        return False
    return not (s.get("unreadable") and s.get("meta_at") is not None and now - float(s["meta_at"]) > running_s)


def _plural(n: int) -> str:
    return "%d subagent%s" % (n, "" if n == 1 else "s")


def find_pane(names: set, ids: set, panes: list) -> dict | None:
    """The live pane of an agent: the registry's rows of live interactive panes (heartbeat.sh builds `panes`) whose conversation is one of the agent's or whose name is its name, the newest status wins
    (stackshot's `pane_row`, fleet/liveness.py)."""
    best = None
    for p in panes:
        if p.get("kind") not in (None, "interactive"):
            continue
        if not ((set(p.get("ids") or ()) & ids) or (p.get("name") and p["name"] in names)):
            continue
        if best is None or float(p.get("at") or 0) > float(best.get("at") or 0):
            best = p
    return best


def _iso_epoch(v) -> int | None:
    try:
        return calendar.timegm(time.strptime(str(v), "%Y-%m-%dT%H:%M:%SZ"))
    except (ValueError, TypeError, OverflowError):
        return None


def build(rows: list, panes: list, now: float, prev: dict | None, tie, roots: list) -> dict:
    """The snapshot: one entry for the name of every live row (a sleeping one too; a retired row is no agent). `rows` are the session registry's published rows (lib/sessions.py export_doc),
    `panes` the CLI registry's live panes of this box, `prev` the last file (for `since`), `tie` stackshot's subagent_tie module."""
    now_i = int(now)
    pw = prev.get("written") if isinstance(prev, dict) and isinstance(prev.get("written"), int) else 0
    pa = prev.get("agents") if isinstance(prev, dict) and isinstance(prev.get("agents"), dict) else {}
    live = [r for r in rows if isinstance(r, dict) and r.get("state") == "live" and r.get("name")]
    count: dict = {}
    for r in live:
        count[r["name"]] = count.get(r["name"], 0) + 1
    agents: dict = {}
    for r in live:
        name = str(r["name"])
        if name in agents and count[name] > 1:
            continue
        tr = [t.get("id") for t in (r.get("transcripts") or []) if isinstance(t, dict) and t.get("id")]
        stamp = None
        if count[name] > 1:
            state, why, pane, read, subs = "unknown", "two live sessions share this name", "unknown", False, []
        else:
            p = find_pane({name}, set(tr), panes)
            sid = (p.get("sessionId") if p else None) or (tr[-1] if tr else "")
            if p:
                pane = STATUS_PANE.get(str(p.get("status") or ""), "unknown")
                if pane != "unknown" and p.get("at"):
                    stamp = int(float(p["at"]) / 1000.0)
            elif r.get("sleeping"):
                pane, stamp = "sleeping", _iso_epoch(r.get("sleeping"))
            else:
                pane = "unknown"
            subs: list = []
            read = False
            if pane == "unknown":
                st = str(p.get("status") or "") if p else ""
                state, why = "unknown", ("the pane's status is '%s', not one sala reads" % st if st else "no live pane of this session on this box")
            elif not sid:
                state, why = "unknown", "the session has no transcript yet"
            else:
                try:
                    raw = tie.running(sid, roots, now)
                    subs = [shape(s) for s in raw if applies(s, pane, now, float(tie.RUNNING_S))]
                    read = True
                except Exception as e:       # Unreadable (no transcript here, a folder that cannot be listed) or anything else: nothing can be said, and nothing is guessed
                    subs, read = [], False
                    state, why = "unknown", ("transcript not readable on this box" if e.__class__.__name__ == "Unreadable" else "subagents not readable (%s)" % e.__class__.__name__)
                else:
                    n = len(subs)
                    if pane == "turn":
                        state, why = "busy", "in a turn" + ("; %s running" % _plural(n) if n else "")
                    elif n:
                        state, why = "busy", "no turn%s; %s running" % (" (background shell)" if pane == "shell" else "", _plural(n))
                    else:
                        state, why = "idle", ("asleep" if pane == "sleeping" else "no turn") + (" (background shell)" if pane == "shell" else "") + ", no subagents"
        old = pa.get(name) if isinstance(pa.get(name), dict) else {}
        if old.get("state") == state and isinstance(old.get("since"), int) and old["since"] <= now_i:
            since = old["since"]
        elif stamp and pw and pw < stamp <= now_i:      # the pane flipped since the last file: that is the better time (no earlier file: `written`, the time of the first look)
            since = stamp
        else:
            since = now_i
        agents[name] = entry(state, since, why, pane, read, subs)
    return {"schema": SCHEMA, "written": now_i, "agents": agents}


def dump(doc: dict) -> str:
    return json.dumps(doc, ensure_ascii=False, separators=(",", ":")) + "\n"


def _size(s: str) -> int:
    return len(json.dumps(s, ensure_ascii=False).encode("utf-8"))


def fit(doc: dict, limit: int = MAX_BODY) -> tuple[str, bool]:
    """(the file's text, whether briefs were shortened). Over `limit` bytes, every brief is cut longest first to SHRINK_STEPS[0] bytes, and if the body is still over, longest first to none, stopping
    as soon as it fits. Never drops an agent, a subagent or any field but the brief's own words."""
    text = dump(doc)
    total = len(text.encode("utf-8"))
    if total <= limit:
        return text, False
    subs = [s for a in doc["agents"].values() for s in a["subagents"]]
    for cap in SHRINK_STEPS:
        for s in sorted(subs, key=lambda x: -_size(x["brief"])):
            if total <= limit:
                break
            if len(s["brief"].encode("utf-8")) > cap:
                before = _size(s["brief"])
                s["brief"] = cut_bytes(s["brief"], cap)
                total -= before - _size(s["brief"])
        if total <= limit:
            break
    return dump(doc), True


def counts(doc: dict) -> str:
    """Numbers only, for a dry run and the report: never a brief or any free text."""
    a = doc["agents"]
    c = {k: sum(1 for v in a.values() if v["state"] == k) for k in STATES}
    return "%d agents: %d busy, %d idle, %d unknown; %d subagents" % (len(a), c["busy"], c["idle"], c["unknown"], sum(len(v["subagents"]) for v in a.values()))


# ---- stackshot's module, the file, the log, the post ---------------------------------------------------------------------------
def load_tie(checkout: str):
    """stackshot's `stackshot.audit.subagent_tie` from its checkout, imported without writing bytecode into it and without leaving the checkout on sys.path."""
    ck = os.path.expanduser(checkout or "")
    if not os.path.isfile(os.path.join(ck, "stackshot", "audit", "subagent_tie.py")):
        raise ImportError("no stackshot checkout with audit/subagent_tie.py at %s" % (ck or "(unset)"))
    sys.dont_write_bytecode = True
    sys.path.insert(0, ck)
    try:
        return importlib.import_module("stackshot.audit.subagent_tie")
    finally:
        try:
            sys.path.remove(ck)
        except ValueError:
            pass


def note(log_dir: str, kind: str, msg: str, now: float | None = None, gap: float = LOG_GAP, log_name: str = LOG_NAME, tag: str = "agent-state") -> None:
    """One line in salamander-agent-state.log, at most one per `gap` seconds for each `kind` (the mark is a file beside the log). Never raises; never holds a secret.
    `log_name` and `tag` let another snapshot (lib/machinespost.py) keep its own log and marks with this same code: the mark is `<log name without .log>.<kind>.mark`."""
    try:
        now = time.time() if now is None else now
        os.makedirs(log_dir, exist_ok=True)
        mark = os.path.join(log_dir, "%s.%s.mark" % (log_name[:-4] if log_name.endswith(".log") else log_name, kind))
        try:
            if 0 <= now - os.stat(mark).st_mtime < gap:
                return
        except OSError:
            pass
        with open(mark, "w", encoding="utf-8"):
            pass
        os.utime(mark, (now, now))
        with open(os.path.join(log_dir, log_name), "a", encoding="utf-8") as f:
            f.write("[%s] %s: %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now)), tag, " ".join(str(msg).split())[:400]))
    except OSError:
        pass


def write_atomic(path: str, text: str) -> None:
    """Temp file beside it, then replace: a reader never sees a torn file. The temp file is removed when the write fails."""
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    tmp = os.path.join(d, ".%s.%d.tmp" % (os.path.basename(path), os.getpid()))
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def post(cmd: str, path: str, timeout: float, log_dir: str, log_name: str = LOG_NAME, tag: str = "agent-state") -> bool:
    """Hand the file to stackshot: `cmd` (shell words) with the file's path as its last argument, at most `timeout` seconds (then its process group is killed). Anything but a clean answer is ONE
    log line per five minutes and nothing else: exit status other than 0, a timeout, a command that cannot start, or an answer on stdout that is JSON and says ok is not true (stackshot answers
    200 {ok, agents}). Returns True only when the command ran and answered cleanly, False for no command or any failure. Never raises. `log_name` and `tag` as in `note`."""
    def say(msg: str) -> None:
        note(log_dir, "post", msg, log_name=log_name, tag=tag)
    try:
        words = shlex.split(cmd or "")
    except ValueError:
        words = []
    if not words:
        return False
    try:
        p = subprocess.Popen(words + [path], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, errors="replace", start_new_session=True)
    except OSError as e:
        say("not handed to stackshot: the post command cannot start (%s)" % e.__class__.__name__)
        return False
    try:
        out, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)       # our own child's group (start_new_session), never a process found by name
        except OSError:
            pass
        try:
            p.communicate(timeout=5)
        except Exception:      # noqa: BLE001
            pass
        say("not handed to stackshot: the post command ran longer than %s s and was stopped" % timeout)
        return False
    tail = " ".join((err or out or "").split())[-160:]
    if p.returncode != 0:
        say("not handed to stackshot: the post command exited %d%s" % (p.returncode, (": " + tail) if tail else ""))
        return False
    try:
        ans = json.loads((out or "").strip())
    except ValueError:
        return True
    if isinstance(ans, dict) and ans.get("ok") is not True:
        say("not handed to stackshot: the answer was not ok (%s)" % " ".join(str(ans)[:120].split()))
        return False
    return True


def publish(E: dict, letter: str, rows: list, panes: list, mode: str) -> str:
    """The heartbeat's call: build, write and post. `E` is the heartbeat's environment (HB_AS_*), `mode` run | nopush | dry. Returns a one-line summary of counts for a dry run, else "". Never raises."""
    try:
        if str(E.get("HB_AS_ON", "on")).lower() in OFF_WORDS:
            return ""
        state = E.get("HB_STATE", "")
        log_dir = E.get("HB_AS_LOGDIR") or os.path.join(os.path.expanduser("~"), ".claude")
        if not state:
            return ""      # the live store only: with none there is nowhere to write
        path = os.path.join(state, letter, "agent-state.json")
        try:
            tie = load_tie(E.get("HB_AS_CHECKOUT", ""))
        except Exception as e:      # noqa: BLE001  — any failure to import stackshot's module: no new file, the last good one stays
            if mode != "dry":
                note(log_dir, "import", "agent-state.json not written, the last good file stays: stackshot's subagent_tie cannot be imported (%s: %s)" % (e.__class__.__name__, e))
            return ("agent-state: stackshot's subagent_tie cannot be imported (%s)" % e.__class__.__name__) if mode == "dry" else ""
        try:
            with open(path, encoding="utf-8") as f:
                prev = json.load(f)
        except (OSError, ValueError):
            prev = None
        roots = [os.path.expanduser(x) for x in str(E.get("HB_AS_ROOTS", "")).split(":") if x] or [os.path.expanduser("~/.claude/projects")]
        doc = build(rows, panes, time.time(), prev, tie, roots)
        try:
            limit = int(E.get("HB_AS_MAX_BODY") or MAX_BODY)
        except ValueError:
            limit = MAX_BODY
        text, shortened = fit(doc, limit)
        if mode == "dry":
            return "agent-state: %s; %d bytes%s" % (counts(doc), len(text.encode("utf-8")), " (briefs shortened)" if shortened else "")
        if shortened:
            note(log_dir, "shrink", "the body was over %d bytes, so subagent briefs were shortened (%d bytes now); no agent or state was dropped" % (limit, len(text.encode("utf-8"))))
        try:
            write_atomic(path, text)
        except OSError as e:
            note(log_dir, "write", "agent-state.json not written (%s)" % e.__class__.__name__)
            return ""
        if mode == "run":
            try:
                timeout = float(E.get("HB_AS_TIMEOUT") or 30)
            except ValueError:
                timeout = 30.0
            post(E.get("HB_AS_CMD", ""), path, timeout, log_dir)
    except Exception as e:      # noqa: BLE001  — nothing here may fail the heartbeat
        if E.get("HB_AS_LOGDIR"):
            note(E["HB_AS_LOGDIR"], "error", "not published (%s: %s)" % (e.__class__.__name__, e))
    return ""
