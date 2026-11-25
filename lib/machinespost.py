#!/usr/bin/env python3
"""machinespost.py: the fleet's machine list the heartbeat writes and hands to stackshot (docs/stackshot-contracts.md, interface 39).

stackshot's board server runs on another machine and reads none of the owner's machine files. It is given the list the one reader of those files builds,
`machine_list()` in lib/machines.py (`read_list` there, which also says which named files could not be read): sala decides, stackshot only shows. The file is
`<live store>/<letter>/machines.json`, written atomically on EVERY heartbeat run beside agent-state.json and never into git, then posted:

  {"schema": 1, "written": <epoch s>, "machines": [<machine_list() entries, keys as machines.KEYS, then machines.READING_KEYS>], "not_read": [<file names named and not read>]}

Each entry carries four readings after the file facts (`read_with_readings` in lib/machines.py): `online` and `last_seen` from this box's `tailscale status --json` (null = not read),
`versions` ({"claude", "sala"} on this box's own row, {} on every other) and `checked` (epoch s, the same second as `written`). `checked` is a clock, so the fingerprint leaves it out.

Posted when the list (machines without `checked`, and not_read; not `written`) differs from the last one stackshot was given, and otherwise every REPOST_AFTER seconds (10 minutes) so stackshot can show
the list's age. The memory of the last good post is a small file in the log folder (STAMP_NAME: the list's fingerprint and the time), not in the store. A list with no machine in it
(no machine file could be read) is not written or posted: it would blank stackshot's view. The post is the one interface 38 uses (agentstate.post: the command with the file's path as its
last argument, a process-group timeout, one log line per five minutes), through the machine token and never a pass. The default command is the stackshot client's `post machines --file`;
stackshot's route `POST /client/machines` is stackshot's to build, so a 404 is the normal answer until it is live. Standard library only; the heartbeat loads this file and calls `publish`
in its own process.

Settings (heartbeat.sh passes them in HB_MP_*): SALA_MACHINES_POST=off writes and posts nothing; SALA_MACHINES_POST_CMD is the command the file's path is appended to (empty = no post);
SALA_MACHINES_POST_TIMEOUT (30 s); SALA_MACHINES_POST_MAX_BODY (900000 bytes: over it the file is written and not posted). A failure to build, write or post logs ONE line per five
minutes to $SALA_LOG_DIR/salamander-machines.log and never fails the heartbeat."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import sys
import time

SCHEMA = 1
MAX_BODY = 900000              # stackshot refuses a body over 1 MB
REPOST_AFTER = 600             # an unchanged list is posted again after this many seconds…
SLACK = 60                     # …less this: a heartbeat on a five-minute timer runs a few seconds off its beat, and must post on every second run, not every third
LOG_NAME = "salamander-machines.log"
STAMP_NAME = "salamander-machines-post.json"
OFF_WORDS = ("off", "0", "no", "false")
_HERE = os.path.dirname(os.path.abspath(__file__))
_mods: dict = {}


def _load(name: str):
    """A sibling module of lib/ by its path, as the heartbeat loads its own (no sys.path change, no bytecode)."""
    if name not in _mods:
        sp = importlib.util.spec_from_file_location("sala_" + name, os.path.join(_HERE, name + ".py"))
        mod = importlib.util.module_from_spec(sp)
        sys.dont_write_bytecode = True
        sp.loader.exec_module(mod)
        _mods[name] = mod
    return _mods[name]


def build(machines: list, not_read: list, now: float) -> dict:
    """The body: the entries `read_with_readings` gives (machine_list()'s keys, then the four readings), and the files named and not read."""
    return {"schema": SCHEMA, "written": int(now), "machines": machines, "not_read": list(not_read)}


def fingerprint(doc: dict) -> str:
    """What makes two lists the same: the machines and not_read, never `written` and never a machine's `checked` (both only say when the list was read)."""
    machines = [{k: v for k, v in m.items() if k != "checked"} for m in doc["machines"]]
    return hashlib.sha256(json.dumps([machines, doc["not_read"]], sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")).hexdigest()


def dump(doc: dict) -> str:
    return json.dumps(doc, ensure_ascii=False, separators=(",", ":")) + "\n"


def counts(doc: dict) -> str:
    """Numbers only, for a dry run: no name, no address."""
    m = doc["machines"]
    return "%d machines (%d retired), %d file(s) not read" % (len(m), sum(1 for x in m if x.get("retired")), len(doc["not_read"]))


def due(stamp: dict | None, fp: str, now: float) -> bool:
    """Post now? When the last good post was of another list, or none is on record, or it is old enough (REPOST_AFTER, less SLACK) or in the future (a clock that moved back)."""
    if not isinstance(stamp, dict) or stamp.get("hash") != fp or not isinstance(stamp.get("at"), (int, float)):
        return True
    age = now - stamp["at"]
    return age < 0 or age >= REPOST_AFTER - SLACK


def _read_stamp(path: str) -> dict | None:
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else None
    except (OSError, ValueError):
        return None


def publish(E: dict, letter: str, mode: str) -> str:
    """The heartbeat's call: build, write and post. `E` is the heartbeat's environment (HB_MP_*), `mode` run | nopush | dry. Returns a one-line summary of counts for a dry run, else "". Never raises."""
    log_dir = E.get("HB_MP_LOGDIR") or os.path.join(os.path.expanduser("~"), ".claude")
    ag = None
    try:
        if str(E.get("HB_MP_ON", "on")).lower() in OFF_WORDS:
            return ""
        ag = _load("agentstate")
        mc = _load("machines")

        def say(kind: str, msg: str) -> None:
            ag.note(log_dir, kind, msg, log_name=LOG_NAME, tag="machines")

        state = E.get("HB_STATE", "")
        names, follow = E.get("HB_MP_NAMES") or None, E.get("HB_MP_FOLLOW") or None
        if not state or not (names or follow):
            return ""      # no live store to write in, or no machine file named (a standalone install): nothing to say
        now = time.time()
        machines, not_read = mc.read_with_readings(names, follow, now=now, claude=E.get("HB_CVER") or None, name=E.get("HB_NAME") or None)
        doc = build(machines, not_read, now)
        if not machines:
            if mode == "dry":
                return "machines: no machine could be read; nothing would be written or posted"
            say("empty", "machines.json not written, the last good file stays: no machine could be read from the files named (%s)" % (", ".join(not_read) or "none named"))
            return ""
        text = dump(doc)
        size = len(text.encode("utf-8"))
        if mode == "dry":
            return "machines: %s; %d bytes" % (counts(doc), size)
        path = os.path.join(state, letter, "machines.json")
        try:
            ag.write_atomic(path, text)
        except OSError as e:
            say("write", "machines.json not written (%s)" % e.__class__.__name__)
            return ""
        if mode != "run":
            return ""
        try:
            limit = int(E.get("HB_MP_MAX_BODY") or MAX_BODY)
        except ValueError:
            limit = MAX_BODY
        if size > limit:
            say("big", "machines.json is %d bytes, over the %d-byte limit: written, not posted" % (size, limit))
            return ""
        cmd = E.get("HB_MP_CMD", "")
        if not cmd:
            return ""
        stamp_path = os.path.join(log_dir, STAMP_NAME)
        fp = fingerprint(doc)
        if not due(_read_stamp(stamp_path), fp, now):
            return ""
        try:
            timeout = float(E.get("HB_MP_TIMEOUT") or 30)
        except ValueError:
            timeout = 30.0
        if ag.post(cmd, path, timeout, log_dir, log_name=LOG_NAME, tag="machines"):
            try:
                ag.write_atomic(stamp_path, json.dumps({"hash": fp, "at": int(now)}) + "\n")
            except OSError:
                say("write", "the post's record was not written (a repeat of the post is likely)")
    except Exception as e:      # noqa: BLE001  — nothing here may fail the heartbeat
        msg = "not published (%s: %s)" % (e.__class__.__name__, e)
        if ag is not None:
            ag.note(log_dir, "error", msg, log_name=LOG_NAME, tag="machines")
        else:
            _note_fallback(log_dir, "error", msg)
    return ""


def _note_fallback(log_dir: str, kind: str, msg: str) -> None:
    """When agentstate.py itself cannot be loaded: one plain line, without the five-minute mark."""
    try:
        os.makedirs(log_dir, exist_ok=True)
        with open(os.path.join(log_dir, LOG_NAME), "a", encoding="utf-8") as f:
            f.write("[%s] machines: %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S%z"), " ".join(str(msg).split())[:400]))
    except OSError:
        pass
