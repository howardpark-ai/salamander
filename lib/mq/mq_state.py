"""lib/mq/mq_state.py — where mq keeps its files, how it writes them, and its locks (docs/mq.md).

State of one repo: $XDG_STATE_HOME/mergequeue/<owner>__<repo>/ (~/.local/state/... when unset)
  queue.json          the line (entries in order), the next entry number, `blocked` and `paused`; read-modify-write only under queue.lock
  groups/g<seq>.json  one record per queue entry (one PR): base, the member with its pinned head, branch, phase, verdict, call counts. The folder and the `g` names date from
                      group mode, which was removed; they stay so that records on disk and the readers of `mq status --json` keep working
  events.log          JSON lines, the journal and the audit trail
  queue.lock          flock, held for milliseconds, never across a git or gh call (the innermost lock)
  driver.lock         flock, held by the one driver for its life (liveness is the lock, not a pid)
  driver.json         informational: the live driver's pid and start (the lock decides liveness, not this file)
  work/               the mq-owned clone;  worktrees/g<seq>  one worktree per entry, removed when the entry ends

Every JSON file is written whole: temp file in the same folder, fsync, rename, fsync of the folder.
Standard library only.
"""
import contextlib
import fcntl
import json
import os
import re
import time

REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")

WAITING, GROUPED = "waiting", "grouped"
TESTED, MERGED, FAILED, EJECTED, DROPPED = "tested", "merged", "failed", "ejected", "dropped"
ACTIVE = (WAITING, GROUPED)
TERMINAL = (TESTED, MERGED, FAILED, EJECTED, DROPPED)

# entry phases, in order; each is written to the record before the step it names is left, and re-entered after a crash
# (a record left by group mode can also say "bisecting": the driver retires such a record, see Driver.retire_legacy)
PHASES = ("building", "built", "pushed", "testing", "verdict", "merging", "cleaning", "done")


class StateError(Exception):
    pass


def valid_repo(repo):
    return bool(REPO_RE.match(repo)) and not any(p in (".", "..") for p in repo.split("/"))


def slug(repo):
    return repo.replace("/", "__")


def env_float(name, default):
    try:
        v = float(os.environ.get(name, "") or default)
        return v if v >= 0 else default
    except ValueError:
        return default


class Paths:
    def __init__(self, repo):
        base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
        self.dir = os.path.join(base, "mergequeue", slug(repo))
        self.queue = os.path.join(self.dir, "queue.json")
        self.qlock = os.path.join(self.dir, "queue.lock")
        self.dlock = os.path.join(self.dir, "driver.lock")
        self.dinfo = os.path.join(self.dir, "driver.json")
        self.events = os.path.join(self.dir, "events.log")
        self.groups = os.path.join(self.dir, "groups")
        self.work = os.path.join(self.dir, "work")
        self.wt = os.path.join(self.dir, "worktrees")

    def group(self, gid):
        return os.path.join(self.groups, gid + ".json")

    def ensure(self):
        os.makedirs(self.groups, exist_ok=True)


def config_dir():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "mergequeue")


# ---- whole-file writes -----------------------------------------------------------------------------------------------------------

def write_json_atomic(path, data):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=1, sort_keys=True)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass
    fd = os.open(d, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default
    except (OSError, ValueError):
        raise StateError("%s is unreadable or not JSON" % path)


def journal(paths, ev, **kw):
    """One JSON line to events.log (append, fsync). Never raises: the journal must not stop the queue."""
    rec = {"ts": int(time.time()), "ev": ev}
    rec.update(kw)
    try:
        os.makedirs(paths.dir, exist_ok=True)
        fd = os.open(paths.events, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, (json.dumps(rec, sort_keys=True) + "\n").encode("utf-8"))
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError:
        pass


def read_events(paths):
    out = []
    try:
        with open(paths.events, encoding="utf-8") as f:
            for ln in f:
                try:
                    out.append(json.loads(ln))
                except ValueError:
                    pass
    except OSError:
        pass
    return out


# ---- the line ---------------------------------------------------------------------------------------------------------------------

def empty_queue():
    return {"version": 1, "next_seq": 1, "blocked": None, "paused": None, "entries": []}


def load_queue(paths):
    q = read_json(paths.queue, None)
    if q is None:
        return empty_queue()
    if not isinstance(q, dict) or not isinstance(q.get("entries"), list):
        raise StateError("%s has no entries list" % paths.queue)
    q.setdefault("next_seq", 1)
    q.setdefault("blocked", None)
    q.setdefault("paused", None)
    return q


@contextlib.contextmanager
def queue_locked(paths):
    """queue.lock for a read-modify-write: yields the queue. Hold it for milliseconds only, never across a git or gh call."""
    paths.ensure()
    fd = os.open(paths.qlock, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield load_queue(paths)
    finally:
        os.close(fd)


def update_queue(paths, fn):
    """Run fn(queue) under queue.lock; the queue is written back whole afterwards. Returns fn's result."""
    with queue_locked(paths) as q:
        res = fn(q)
        write_json_atomic(paths.queue, q)
        return res


def find_entry(q, pr, active_only=False):
    """The newest entry of PR (list order = line order; a re-added PR is appended)."""
    for e in reversed(q["entries"]):
        if e["pr"] == pr and (not active_only or e["state"] in ACTIVE):
            return e
    return None


def finish_entry(e, state, reason):
    e["state"], e["reason"], e["ended"] = state, reason, int(time.time())


# ---- groups -----------------------------------------------------------------------------------------------------------------------

def load_group(paths, gid):
    return read_json(paths.group(gid), None)


def save_group(paths, g):
    write_json_atomic(paths.group(g["id"]), g)


def list_groups(paths):
    out = []
    try:
        names = sorted(os.listdir(paths.groups))
    except OSError:
        return out
    for n in names:
        if n.startswith("g") and n.endswith(".json"):
            try:
                g = read_json(os.path.join(paths.groups, n), None)
            except StateError:
                continue
            if isinstance(g, dict) and "id" in g:
                out.append(g)
    out.sort(key=lambda g: g.get("seq", 0))
    return out


# ---- the driver lock --------------------------------------------------------------------------------------------------------------

def try_lock(path, tries=1, pause=0.05):
    """Take an exclusive flock on path without waiting; → the open fd, or None when another process holds it. The fd is the lock: closing it,
    or the process dying, frees it. A few tries absorb the instant a liveness check (driver_alive) holds it."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    for i in range(max(1, tries)):
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except OSError:
            os.close(fd)
        if i + 1 < tries:
            time.sleep(pause)
    return None


def driver_alive(paths):
    fd = try_lock(paths.dlock)
    if fd is None:
        return True
    os.close(fd)
    return False


def lock_holder_info(paths):
    try:
        return read_json(paths.dinfo, None)
    except StateError:
        return None
