#!/usr/bin/env python3
"""lib/notice.py: the store and the delivery of `sala notice` (standard library only; lib/notice.sh and lib/hook.sh call it).

  notice.py add TEXT --from SENDER [--until WHEN]    append a notice; prints "<id>\t<until epoch>\t<live sessions it reaches>"
  notice.py list [--json]                            the active notices, each with how many live sessions had it and how many are still due
  notice.py drop ID                                  withdraw a notice
  notice.py prune                                    drop expired notices and the delivery state of sessions that are gone
  notice.py deliver SESSION_ID EVENT                 the hooks' slow path: print the hook JSON for what is due to this session (and for
                                                     $SALA_NOTICE_PRE, a line the hook already has), record it as delivered

State, all under $SALA_STATE_DIR (default ~/.local/state/salamander):
  notices.tsv        id, created epoch, sender, until epoch, text: one notice a line, text one line with no tab
  notices.seq        the last id given; never pruned, so an id is never reused
  notices-seen/<id>  per session (the hook's session_id): the last notice id handled for it (delivered or skipped); its mtime is
                     the mtime notices.tsv had when it was read, so the hooks' `[ notices.tsv -nt seen ]` is the whole fast path
  notices.lock       flock for every read-modify-write of the above

A session whose conversation started after a notice was created skips it (it loaded the current rules at its start): the start is
the later of the CLI's registry row (startedAt of the process holding the conversation) and sala's session registry (the first record
of that conversation). Unknown start: the notice is delivered. A delivery never fails the caller: deliver prints nothing and exits 0
on any error.
"""
import contextlib, fcntl, json, os, re, sys, time

HOME = os.path.expanduser("~")
STATE = os.environ.get("SALA_STATE_DIR") or os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local", "state"), "salamander")
REG = os.environ.get("SALA_REG_DIR") or os.path.join(HOME, ".claude", "sessions")
NOTICES = os.path.join(STATE, "notices.tsv")
SEQ = os.path.join(STATE, "notices.seq")
SEEN = os.path.join(STATE, "notices-seen")
LOCK = os.path.join(STATE, "notices.lock")
MAXLEN = 400
DEFAULT_TTL = 7 * 86400
SID_RE = re.compile(r"[0-9A-Za-z_-]{8,64}\Z")
SENDER_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
EVENTS = {"PostToolUse", "UserPromptSubmit"}


class Refuse(Exception):
    pass


@contextlib.contextmanager
def locked():
    os.makedirs(STATE, exist_ok=True)
    with open(LOCK, "a") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        yield


def atomic_write(path, data):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(data)
    os.replace(tmp, path)


def read_notices():
    """-> list of (id, created, sender, until, text); a malformed line is skipped."""
    out = []
    try:
        with open(NOTICES, encoding="utf-8") as fh:
            for line in fh:
                f = line.rstrip("\n").split("\t", 4)
                if len(f) != 5:
                    continue
                try:
                    out.append((int(f[0]), int(f[1]), f[2], int(f[3]), f[4]))
                except ValueError:
                    continue
    except OSError:
        pass
    return out


def write_notices(rows):
    atomic_write(NOTICES, "".join("%d\t%d\t%s\t%d\t%s\n" % r for r in rows))


def parse_when(v, now):
    """an epoch, a relative span (90m, 12h, 7d), or an ISO 8601 time (a trailing Z or an offset; none = UTC) -> epoch seconds"""
    v = v.strip()
    if re.fullmatch(r"\d+(\.\d+)?", v):
        return int(float(v))
    m = re.fullmatch(r"(\d+)([mhd])", v)
    if m:
        return now + int(m.group(1)) * {"m": 60, "h": 3600, "d": 86400}[m.group(2)]
    import datetime
    try:
        d = datetime.datetime.fromisoformat(v.replace("Z", "+00:00"))
    except ValueError:
        raise Refuse("--until '%s' is not an epoch, a span like 12h or 7d, or an ISO 8601 time" % v)
    if d.tzinfo is None:
        d = d.replace(tzinfo=datetime.timezone.utc)
    return int(d.timestamp())


def check_text(text):
    if not text.strip():
        raise Refuse("the notice text is empty")
    if len(text) > MAXLEN:
        raise Refuse("the notice text is %d characters; the most is %d" % (len(text), MAXLEN))
    if any(ord(c) < 32 or ord(c) == 127 for c in text):
        raise Refuse("the notice text must be one line: no newline, tab or other control character")


def live_sessions():
    """-> {session id: process start (epoch s)} for every live Claude process the CLI has a registry row for."""
    out = {}
    try:
        names = os.listdir(REG)
    except OSError:
        return out
    for n in names:
        if not n.endswith(".json"):
            continue
        try:
            with open(os.path.join(REG, n), encoding="utf-8") as fh:
                r = json.load(fh)
            pid, sid = r.get("pid"), r.get("sessionId")
            if not isinstance(sid, str) or not SID_RE.match(sid):
                continue
            if isinstance(pid, int) and not os.path.exists("/proc/%d" % pid):
                continue
            sa = r.get("startedAt")
            out[sid] = sa / 1000.0 if isinstance(sa, (int, float)) else 0
        except Exception:
            continue
    return out


def registry_starts():
    """-> {claude session id: first record epoch} from sala's session registry (sessions.json transcripts)."""
    out = {}
    try:
        with open(os.path.join(STATE, "sessions.json"), encoding="utf-8") as fh:
            rows = json.load(fh).get("sessions", {})
        import datetime
        for r in rows.values():
            for t in r.get("transcripts", []) or []:
                tid, at = t.get("id"), t.get("at")
                if not isinstance(tid, str) or not isinstance(at, str):
                    continue
                try:
                    e = datetime.datetime.fromisoformat(at.replace("Z", "+00:00")).timestamp()
                except ValueError:
                    continue
                if tid not in out or e < out[tid]:
                    out[tid] = e
    except Exception:
        pass
    return out


def start_of(sid, live, regs):
    """the later of the process start and the conversation's first record; 0 when neither is known"""
    return max(live.get(sid, 0) or 0, regs.get(sid, 0) or 0)


def seen_id(sid):
    try:
        with open(os.path.join(SEEN, sid)) as fh:
            return int(fh.read().strip() or 0)
    except (OSError, ValueError):
        return 0


def write_seen(sid, value, mtime_ns):
    os.makedirs(SEEN, exist_ok=True)
    p = os.path.join(SEEN, sid)
    tmp = "%s.tmp.%d" % (p, os.getpid())
    with open(tmp, "w") as fh:
        fh.write("%d\n" % value)
    os.utime(tmp, ns=(mtime_ns, mtime_ns))
    os.replace(tmp, p)


def prune_locked(now):
    """expired notices out; with none left, every delivery file out; else the files of sessions that are gone and a day idle"""
    rows = read_notices()
    keep = [r for r in rows if r[3] > now]
    if len(keep) != len(rows):
        write_notices(keep)
    try:
        names = os.listdir(SEEN)
    except OSError:
        return len(rows) - len(keep)
    live = live_sessions() if keep else {}
    for n in names:
        p = os.path.join(SEEN, n)
        try:
            if not keep or (n not in live and now - os.stat(p).st_mtime > 86400) or ".tmp." in n:
                os.unlink(p)
        except OSError:
            pass
    if not keep:
        try:
            os.rmdir(SEEN)
        except OSError:
            pass
    return len(rows) - len(keep)


def cmd_add(args):
    sender = until = None
    words = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--from":
            sender = args[i + 1] if i + 1 < len(args) else ""
            i += 2
        elif a == "--until":
            until = args[i + 1] if i + 1 < len(args) else ""
            i += 2
        else:
            words.append(a)
            i += 1
    if sender is None or not sender:
        raise Refuse("--from <sender> is required (your session name)")
    if not SENDER_RE.match(sender):
        raise Refuse("--from '%s' is not a session name (letters, digits, . _ -)" % sender)
    if len(words) != 1:
        raise Refuse("give the text as one quoted argument")
    text = words[0]
    check_text(text)
    now = int(time.time())
    end = parse_when(until, now) if until is not None else now + DEFAULT_TTL
    if end <= now:
        raise Refuse("--until is not in the future")
    with locked():
        prune_locked(now)
        rows = read_notices()
        try:
            with open(SEQ) as fh:
                last = int(fh.read().strip() or 0)
        except (OSError, ValueError):
            last = 0
        last = max([last] + [r[0] for r in rows]) + 1
        atomic_write(SEQ, "%d\n" % last)
        rows.append((last, now, sender, end, text))
        write_notices(rows)
        reach = len(live_sessions())
    print("%d\t%d\t%d" % (last, end, reach))


def tallies(rows):
    """-> {notice id: (had, due)} over the live sessions"""
    live, regs = live_sessions(), registry_starts()
    out = {}
    for (nid, created, _s, _u, _t) in rows:
        had = due = 0
        for sid in live:
            if seen_id(sid) >= nid:
                had += 1
            elif start_of(sid, live, regs) <= created:
                due += 1
        out[nid] = (had, due)
    return out


def cmd_list(args):
    as_json = "--json" in args
    now = int(time.time())
    with locked():
        prune_locked(now)
        rows = read_notices()
        t = tallies(rows)
    if as_json:
        print(json.dumps([{"id": r[0], "created": r[1], "from": r[2], "until": r[3], "text": r[4], "had": t[r[0]][0], "due": t[r[0]][1]} for r in rows],
                         ensure_ascii=False))
        return
    for r in rows:
        print("\t".join([str(r[0]), str(r[1]), r[2], str(r[3]), str(t[r[0]][0]), str(t[r[0]][1]), r[4]]))


def cmd_drop(args):
    if len(args) != 1 or not re.fullmatch(r"\d+", args[0]):
        raise Refuse("usage: sala notice drop <id>")
    nid = int(args[0])
    with locked():
        rows = read_notices()
        keep = [r for r in rows if r[0] != nid]
        if len(keep) == len(rows):
            raise Refuse("no notice %d (sala notice list)" % nid)
        write_notices(keep)
        prune_locked(int(time.time()))
    print(nid)


def cmd_prune(_args):
    with locked():
        n = prune_locked(int(time.time()))
    print(n)


def cmd_deliver(args):
    """the hooks' slow path; never raises, prints the hook's JSON or nothing"""
    pre = os.environ.get("SALA_NOTICE_PRE", "").strip()
    text = ""
    try:
        sid, event = args[0], args[1]
        if event not in EVENTS or not SID_RE.match(sid) or os.environ.get("SALA_NOTICE_SKIP"):
            raise ValueError
        now = int(time.time())
        with locked():
            try:
                st = os.stat(NOTICES)
            except OSError:
                raise ValueError
            rows = [r for r in read_notices() if r[3] > now]
            prev = seen_id(sid)
            new = [r for r in rows if r[0] > prev]
            top = prev
            lines = []
            if new:
                live = live_sessions()
                start = start_of(sid, live, registry_starts())
                for (nid, created, sender, _u, body) in sorted(new, key=lambda r: (r[1], r[0])):
                    top = max(top, nid)
                    if start and start > created:
                        continue
                    lines.append("[sala notice %d from %s] %s" % (nid, sender, body))
            write_seen(sid, top, st.st_mtime_ns)   # written before the print: a notice is never shown twice
            text = "\n".join(lines)
    except Exception:
        text = ""
    out = "\n\n".join(x for x in (pre, text) if x)
    if out:
        try:
            print(json.dumps({"hookSpecificOutput": {"hookEventName": args[1], "additionalContext": out}}))
        except Exception:
            pass


def main(argv):
    if not argv:
        return 2
    verb, rest = argv[0], argv[1:]
    if verb == "deliver":
        try:
            cmd_deliver(rest)
        except Exception:
            pass
        return 0
    try:
        {"add": cmd_add, "list": cmd_list, "drop": cmd_drop, "prune": cmd_prune}[verb](rest)
    except Refuse as e:
        print("✗ %s" % e, file=sys.stderr)
        return 1
    except KeyError:
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass
    sys.exit(main(sys.argv[1:]))
