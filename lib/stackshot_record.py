#!/usr/bin/env python3
"""lib/stackshot_record.py - where sala reads stackshot's project record and roles list from (docs/stackshot-contracts.md, interface 20).

The record and the list are stackshot's. A file copy of each (~/.local/state/stackshot/projects.json and roles.json) is written by a puller, so it is
only as new as the puller's last run: when stackshot's server moved, the copy sat 18 hours old while the truth had not moved. So a reader asks
stackshot by its address first, through stackshot's client (`client.py get state-files` for the whole project record, `client.py get roles` for the
list), and reads the file copy ONLY when stackshot cannot be reached, saying how old that copy is.

    resolve(kind) -> dict(path, source, note, why)
        kind    "projects" or "roles"
        path    a file the caller reads as it always read the file: stackshot's answer written (atomically) to sala's state folder, or the file copy
                (always set: when there is nothing to read it is the file copy's path, so a caller's "no record at <path>" stays as it was)
        source  "live" (stackshot answered, now or within the last few seconds), "file" (the copy, because stackshot could not be asked or did not
                answer), "none" (neither)
        note    one line for a person: why the copy is read and how old it is (empty for a live answer)
        why     why stackshot did not answer (empty for a live answer, or when there is no client on this box to ask)

A live answer is kept for SALA_RECORD_LIVE_TTL seconds (20) so that one command, or one tick of the watch, that reads the record many times asks once;
a failed ask is kept for the same time, so a tick does not wait for a dead server once per reader. The ask runs under `timeout`
(SALA_RECORD_LIVE_TIMEOUT, 15 s) with stdin closed. SALA_RECORD_LIVE=off reads the file copy alone (a box that has no stackshot to ask).
The file copy's own limit (SALA_PROJECT_RECORD_MAX_AGE, SALA_ROLES_FILE_MAX_AGE) stays: the readers refuse a copy older than it. Each time the copy is
read after an ask that failed, one line goes to $SALA_LOG_DIR/salamander-record.log (at most one per five minutes for each record).

Command line (the shell side, lib/common.sh `record_file_r`):
    python3 stackshot_record.py resolve <projects|roles> --fallback FILE --max-age SECONDS [--client CLIENT.PY] [--state-dir DIR] [--log-dir DIR]
                                 [--ttl S] [--timeout S] [--file-only]
    prints `<path> TAB <source> TAB <note> TAB <why>`; exit 0 for live or file, 1 for none. Standard library only (bgagents.py runs with -I -S)."""
import datetime
import json
import os
import subprocess
import sys
import tempfile
import time

KINDS = {
    "projects": {"env_file": "SALA_PROJECT_RECORD", "file": "projects.json", "env_age": "SALA_PROJECT_RECORD_MAX_AGE", "age": 600,
                 "verb": ["get", "state-files"], "what": "project record"},
    "roles": {"env_file": "SALA_ROLES_FILE", "file": "roles.json", "env_age": "SALA_ROLES_FILE_MAX_AGE", "age": 1800,
              "verb": ["get", "roles"], "what": "roles list"},
}
LOG_GAP = 300   # seconds: one log line per record at most this often while the ask keeps failing


def _num(name, default):
    try:
        return float(os.environ.get(name, "") or default)
    except ValueError:
        return float(default)


def age_words(sec):
    """A plain age: 40 s, 3 min 5 s, 2 h 10 min, 18 h 2 min, 3 days 4 h."""
    s = int(max(0, sec))
    if s < 60:
        return "%d s" % s
    if s < 3600:
        return "%d min %d s" % (s // 60, s % 60) if s % 60 else "%d min" % (s // 60)
    if s < 86400:
        return "%d h %d min" % (s // 3600, s % 3600 // 60) if s % 3600 // 60 else "%d h" % (s // 3600)
    return "%d days %d h" % (s // 86400, s % 86400 // 3600) if s % 86400 // 3600 else "%d days" % (s // 86400)


def default_fallback(kind):
    k = KINDS[kind]
    return os.environ.get(k["env_file"]) or os.path.join(os.path.expanduser("~"), ".local", "state", "stackshot", k["file"])


def default_state_dir():
    return os.environ.get("SALA_STATE_DIR") or os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state"), "salamander")


def find_client(env=None):
    """The stackshot client's path (SALA_STACKSHOT_CLIENT, else the one under SALA_STACKSHOT_DIR: the package path, or the old root path on an older checkout), or ""."""
    env = os.environ if env is None else env
    c = env.get("SALA_STACKSHOT_CLIENT") or ""
    if c:
        return c if os.path.isfile(c) else ""
    d = env.get("SALA_STACKSHOT_DIR") or ""
    if not d:
        return ""
    new, old = os.path.join(d, "stackshot", "fleet", "client.py"), os.path.join(d, "client.py")
    p = new if os.path.isfile(new) or not os.path.isfile(old) else old
    return p if os.path.isfile(p) else ""


def file_age(path, now=None):
    """Seconds since the file copy was written: its own `generated` stamp, else its modification time; None when it cannot be read."""
    now = time.time() if now is None else now
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        return now - datetime.datetime.fromisoformat(str(d["generated"]).replace("Z", "+00:00")).timestamp()
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        pass
    try:
        return now - os.stat(path).st_mtime
    except OSError:
        return None


def _extract(kind, text):
    """-> (the object to keep, "") or (None, why): the answer of the client's verb, checked to have the shape the readers need."""
    try:
        d = json.loads(text)
    except ValueError:
        return None, "its answer is not JSON"
    if kind == "projects":
        d = d.get("projects") if isinstance(d, dict) else None   # state-files: the published projects.json is its `projects`
        if not isinstance(d, dict):
            return None, "it has no project record to give"
        if d.get("schema") != 1 or not isinstance(d.get("projects"), dict):
            return None, "its project record is not schema 1"
        return d, ""
    if not isinstance(d, dict) or not isinstance(d.get("sessions"), dict):
        return None, "its roles list has no sessions"
    return d, ""


def fetch(kind, client, timeout):
    """One ask of stackshot through its client, stdin closed, under a timeout -> (object, "") or (None, why)."""
    try:
        p = subprocess.run([sys.executable or "python3", client] + KINDS[kind]["verb"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, timeout=timeout, text=True, errors="replace")
    except subprocess.TimeoutExpired:
        return None, "no answer within %d s" % timeout
    except OSError as e:
        return None, "the client cannot be run (%s)" % e.__class__.__name__
    if p.returncode != 0:
        last = [x.strip() for x in (p.stderr or p.stdout or "").splitlines() if x.strip()]
        return None, "the client exited %d%s" % (p.returncode, ": " + last[-1][:160] if last else "")
    return _extract(kind, p.stdout)


def _write_atomic(path, text):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix="." + os.path.basename(path) + ".")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _mtime_age(path, now):
    try:
        return now - os.stat(path).st_mtime
    except OSError:
        return None


def _log(log_dir, state_dir, kind, line, now):
    """One line in salamander-record.log, at most one per LOG_GAP seconds for a record; never an error."""
    try:
        mark = os.path.join(state_dir, "record-live", kind + ".logged")
        a = _mtime_age(mark, now)
        if a is not None and 0 <= a < LOG_GAP:
            return
        os.makedirs(os.path.dirname(mark), exist_ok=True)
        with open(mark, "w", encoding="utf-8"):
            pass
        os.makedirs(log_dir, exist_ok=True)
        stamp = datetime.datetime.fromtimestamp(now).astimezone().isoformat(timespec="seconds")
        with open(os.path.join(log_dir, "salamander-record.log"), "a", encoding="utf-8") as f:
            f.write("[%s] %s\n" % (stamp, line))
    except OSError:
        pass


def resolve(kind, fallback=None, max_age=None, client=None, state_dir=None, log_dir=None, ttl=None, timeout=None, live=None, now=None):
    k = KINDS[kind]
    now = time.time() if now is None else now
    fallback = fallback or default_fallback(kind)
    max_age = _num(k["env_age"], k["age"]) if max_age is None else float(max_age)
    client = find_client() if client is None else client
    state_dir = state_dir or default_state_dir()
    log_dir = log_dir or os.environ.get("SALA_LOG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    ttl = _num("SALA_RECORD_LIVE_TTL", 20) if ttl is None else float(ttl)
    timeout = _num("SALA_RECORD_LIVE_TIMEOUT", 15) if timeout is None else float(timeout)
    if live is None:
        live = os.environ.get("SALA_RECORD_LIVE", "on") != "off"
    memo = os.path.join(state_dir, "record-live", kind + ".json")
    fail = os.path.join(state_dir, "record-live", kind + ".fail")
    why = ""
    if live and client:
        a = _mtime_age(memo, now)
        if ttl > 0 and a is not None and 0 <= a <= ttl:
            return {"path": memo, "source": "live", "note": "", "why": ""}
        f = _mtime_age(fail, now)
        if ttl > 0 and f is not None and 0 <= f <= ttl:
            try:
                with open(fail, encoding="utf-8") as fh:
                    why = fh.read().strip()
            except OSError:
                why = "it did not answer a moment ago"
        else:
            obj, why = fetch(kind, client, timeout)
            if obj is not None:
                try:
                    _write_atomic(memo, json.dumps(obj, ensure_ascii=False))
                    try:
                        os.unlink(fail)
                    except OSError:
                        pass
                    return {"path": memo, "source": "live", "note": "", "why": ""}
                except OSError as e:
                    why = "its answer could not be kept (%s)" % (e.strerror or e)
            try:
                _write_atomic(fail, why)
            except OSError:
                pass
    # stackshot could not be asked, or did not answer: the file copy, with its age said
    age = file_age(fallback, now) if os.access(fallback, os.R_OK) else None
    asked = "stackshot did not answer (%s); " % why if why else ""
    if age is None:
        note = "%sthere is no readable file copy at %s" % (asked, fallback)
        if why:
            _log(log_dir, state_dir, kind, "%s: %s" % (k["what"], note), now)
        return {"path": fallback, "source": "none", "note": note, "why": why}
    note = "%sthe file copy %s is %s old%s" % (asked, fallback, age_words(age), " (past its %s limit, so it answers nothing)" % age_words(max_age) if age > max_age else "")
    if why:
        _log(log_dir, state_dir, kind, "%s: %s" % (k["what"], note), now)
    return {"path": fallback, "source": "file", "note": note, "why": why}


def _main(argv):
    if len(argv) < 3 or argv[0] != "resolve" or argv[1] not in KINDS:
        print("usage: stackshot_record.py resolve <projects|roles> --fallback FILE --max-age SECONDS [--client CLIENT.PY] [--state-dir DIR] [--log-dir DIR] [--ttl S] [--timeout S] [--file-only]", file=sys.stderr)
        return 2
    kind, a, kw, i = argv[1], argv[2:], {}, 0
    names = {"--fallback": "fallback", "--max-age": "max_age", "--client": "client", "--state-dir": "state_dir", "--log-dir": "log_dir", "--ttl": "ttl", "--timeout": "timeout"}
    while i < len(a):
        if a[i] == "--file-only":
            kw["live"] = False
            i += 1
        elif a[i] in names and i + 1 < len(a):
            kw[names[a[i]]] = a[i + 1]
            i += 2
        else:
            print("stackshot_record.py: unknown argument %s" % a[i], file=sys.stderr)
            return 2
    r = resolve(kind, **kw)
    print("\t".join([r["path"], r["source"], " ".join(r["note"].split()), " ".join(r["why"].split())]))
    return 0 if r["source"] in ("live", "file") else 1


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
