#!/usr/bin/env python3
"""lib/motion.py — `sala motion`: the few short lines a session sets itself to say what is in motion right now (docs/subcommands.md).

sala-web's chat page (web/README.md, *The chat page*) shows them under "In motion". Nobody else writes them and no model filters them: the
session that sets a line is the session that shows it.

  add "<line>"          put a line on the list (one line of text, at most 120 characters; a line already there only has its clock renewed)
  done "<line>" | N     take one off, by its exact text or by its number in `list`
  clear                 take them all off
  list [--json]         the lines still in force, numbered

  --for NAME            the session whose lines these are (default: the session this command runs in; outside a session it is required)

Storage: <state>/motion/<session>.json (state = SALA_STATE_DIR, else $XDG_STATE_HOME/salamander), folder mode 700, file mode 600, one small JSON
file per session: {"v": 1, "lines": [{"text": "...", "at": <epoch seconds>}]}. The CLI is the only writer, under an exclusive lock on
<folder>/.lock; a file is written to a temporary name, flushed and renamed, so a reader (sala-web, which only reads) never sees half of one.
At most 8 lines, each at most 120 characters: a ninth line and a longer one are refused with a sentence (nothing is cut or dropped silently).
A line expires 24 hours after it was set (or last renewed): it is left out of `list` and of what sala-web shows, and the next write drops it.

Tests: SALA_MOTION_DIR (the folder), SALA_MOTION_NOW (the clock, epoch seconds), SALA_MOTION_SELF (the caller's own session name, which the shell
wrapper reads from sala's registry).
Exit: 0 done, 1 refused or failed, 2 usage.
"""
import fcntl
import json
import os
import re
import sys
import time

MAX_LINES = 8
MAX_CHARS = 120
TTL_S = 24 * 3600
NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")


def die(msg, code=1):
    print("motion: " + msg, file=sys.stderr)
    sys.exit(code)


def now():
    v = os.environ.get("SALA_MOTION_NOW", "")
    try:
        return int(v) if v else int(time.time())
    except ValueError:
        return int(time.time())


def folder():
    d = os.environ.get("SALA_MOTION_DIR")
    if d:
        return d
    state = os.environ.get("SALA_STATE_DIR") or os.path.join(
        os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state"), "salamander")
    return os.path.join(state, "motion")


def clean_text(raw):
    """One line: control characters out, runs of white space one space, ends trimmed."""
    s = "".join(" " if ch in "\t\r\n\v\f" else ch for ch in raw if ch >= " " or ch in "\t\r\n\v\f")
    return " ".join(s.split())


def load(path):
    """The lines in force (dicts with text and at), oldest first; an unreadable or foreign file reads as none."""
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return []
    rows = doc.get("lines") if isinstance(doc, dict) else None
    out = []
    t = now()
    for r in rows if isinstance(rows, list) else []:
        if not isinstance(r, dict) or not isinstance(r.get("text"), str) or isinstance(r.get("at"), bool) or not isinstance(r.get("at"), int):
            continue
        if t - r["at"] >= TTL_S:
            continue
        out.append({"text": r["text"], "at": r["at"]})
    return out[:MAX_LINES]


def save(d, path, lines):
    tmp = "%s.tmp-%d" % (path, os.getpid())
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump({"v": 1, "lines": lines}, f, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)   # gone after the rename; left only when the write failed
        except OSError:
            pass


def main(argv):
    name = os.environ.get("SALA_MOTION_SELF", "")
    args = []
    as_json = False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--for":
            if i + 1 >= len(argv):
                die("--for needs a session name", 2)
            name = argv[i + 1]
            i += 2
            continue
        if a.startswith("--for="):
            name = a[len("--for="):]
        elif a == "--json":
            as_json = True
        else:
            args.append(a)
        i += 1
    if not args:
        die("usage: sala motion add \"<line>\" | done \"<line>\"|N | clear | list [--json]   [--for NAME]", 2)
    verb, rest = args[0], args[1:]
    if verb not in ("add", "done", "clear", "list"):
        die("unknown verb '%s' (add, done, clear, list)" % verb, 2)
    if as_json and verb != "list":
        die("--json is for list", 2)
    if not name:
        die("this is not run inside a session, so say whose lines these are: sala motion %s … --for NAME" % verb, 1)
    if not NAME_RE.fullmatch(name):
        die("'%s' is not a session name (letters, digits, dot, underscore, dash)" % name, 1)
    if verb in ("clear", "list") and rest:
        die("sala motion %s takes no argument" % verb, 2)
    if verb in ("add", "done") and len(rest) != 1:
        die("sala motion %s takes one argument (quote the line)" % verb, 2)

    d = folder()
    os.makedirs(d, mode=0o700, exist_ok=True)
    os.chmod(d, 0o700)
    path = os.path.join(d, name + ".json")
    if verb == "list":   # a read: no lock needed, the file is replaced whole
        lines = load(path)
        if as_json:
            print(json.dumps([{"n": k + 1, "text": r["text"], "at": r["at"]} for k, r in enumerate(lines)], ensure_ascii=False))
        elif not lines:
            print("nothing right now")
        else:
            for k, r in enumerate(lines):
                print("%d. %s" % (k + 1, r["text"]))
        return 0

    lock = os.open(os.path.join(d, ".lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        lines = load(path)
        if verb == "clear":
            n = len(lines)
            save(d, path, [])
            print("motion: cleared %d line%s for %s" % (n, "" if n == 1 else "s", name))
            return 0
        if verb == "add":
            text = clean_text(rest[0])
            if not text:
                die("the line is empty")
            if len(text) > MAX_CHARS:
                die("the line is %d characters; at most %d (say it shorter)" % (len(text), MAX_CHARS))
            for r in lines:
                if r["text"] == text:
                    r["at"] = now()
                    save(d, path, lines)
                    print("motion: already listed; its 24 hours start again (%d of %d)" % (len(lines), MAX_LINES))
                    return 0
            if len(lines) >= MAX_LINES:
                die("%d lines are already listed for %s (the most there is room for): take one off with `sala motion done N` or start over with `sala motion clear`" % (len(lines), name))
            lines.append({"text": text, "at": now()})
            save(d, path, lines)
            print("motion: added (%d of %d): %s" % (len(lines), MAX_LINES, text))
            return 0
        # done
        want = rest[0].strip()
        hit = None
        if re.fullmatch(r"[0-9]{1,3}", want):
            k = int(want)
            if 1 <= k <= len(lines):
                hit = k - 1
        if hit is None:
            exact = [k for k, r in enumerate(lines) if r["text"] == clean_text(want)]
            if len(exact) == 1:
                hit = exact[0]
        if hit is None:
            die("no such line for %s: %s (see `sala motion list`)" % (name, want))
        gone = lines.pop(hit)
        save(d, path, lines)
        print("motion: done: %s" % gone["text"])
        return 0
    finally:
        os.close(lock)   # closing the descriptor releases the lock


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
