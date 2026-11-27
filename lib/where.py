#!/usr/bin/env python3
"""lib/where.py: `sala where`, the box the owner works from right now (standard library only; lib/where.sh runs it).

  where.py show [--json]            the record, one line (or the record plus age_s as JSON); "no record" when there is none
  where.py set BOX [--by SESSION]   record BOX (via "told"); a different box also replaces the where-notice, the same box only refreshes "at"
  where.py clear                    remove the record and its notice
  where.py seen ADDRESS             the third source: the web UI saw the owner's address (X-Forwarded-For); records its box with via "web"
  where.py scan                     the second source: the newest ssh-attached tmux client of the last 10 minutes, mapped to a fleet box

The record, $SALA_STATE_DIR/where.json (default ~/.local/state/salamander, the folder lib/notice.py uses):
  {"box": "<fleet name>", "at": <epoch seconds>, "via": "told" | "ssh" | "web", "by": "<session name or empty>"}
written whole to a temp file in the same folder, then renamed. where.lock serializes every read-modify-write.

The notice is one `sala notice` (lib/notice.py) from the sender "sala-where", expiring in 12 hours; a change of box drops the old one first,
so only the latest stays. Times are shown in Korean Standard Time (Asia/Seoul, "13:45 KST"), whatever TZ the process runs with.
The scan fails silently: no tmux, no tailscale, an unreadable client environment or an unknown address changes nothing.
Test hooks: SALA_WHERE_ENVIRON_DIR (read <dir>/<pid>/environ instead of /proc/<pid>/environ).
"""
import contextlib, datetime, fcntl, json, os, subprocess, sys, time, zoneinfo

HERE = os.path.dirname(os.path.abspath(__file__))
HOME = os.path.expanduser("~")
STATE = os.environ.get("SALA_STATE_DIR") or os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local", "state"), "salamander")
RECORD = os.path.join(STATE, "where.json")
LOCK = os.path.join(STATE, "where.lock")
SENDER = "sala-where"
STALE_S = 12 * 3600
SCAN_WINDOW_S = 600
# every time sala where prints or posts is Korean Standard Time, whatever TZ the process runs with
try:
    ZONE = zoneinfo.ZoneInfo("Asia/Seoul")
except Exception:   # no tz database on the box: Korea has no daylight saving, a fixed +9 is the same clock
    ZONE = datetime.timezone(datetime.timedelta(hours=9))


@contextlib.contextmanager
def locked():
    os.makedirs(STATE, exist_ok=True)
    with open(LOCK, "a") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        yield


def read_record():
    try:
        with open(RECORD, encoding="utf-8") as fh:
            d = json.load(fh)
        if isinstance(d, dict) and isinstance(d.get("box"), str) and d["box"] and isinstance(d.get("at"), (int, float)):
            return {"box": d["box"], "at": int(d["at"]), "via": d.get("via") if d.get("via") in ("told", "ssh", "web") else "told", "by": str(d.get("by") or "")}
    except (OSError, ValueError):
        pass
    return None


def write_record(rec):
    os.makedirs(STATE, exist_ok=True)
    tmp = "%s.tmp.%d" % (RECORD, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(rec, fh)
            fh.write("\n")
        os.replace(tmp, RECORD)
    finally:
        with contextlib.suppress(OSError):
            os.unlink(tmp)


def clock(at):
    """The time of day of epoch AT in Korean Standard Time, "13:45 KST" (zoneinfo, not the TZ variable)."""
    return datetime.datetime.fromtimestamp(at, ZONE).strftime("%H:%M ") + "KST"


def age_words(age):
    if age < 60:
        return "just now"
    if age < 3600:
        return "%dm ago" % (age // 60)
    if age < 86400:
        return "%dh ago" % (age // 3600)
    return "%dd ago" % (age // 86400)


# ---- the fleet ---------------------------------------------------------------------------------------------------------------

def fleet():
    """-> list of machine entries (lib/machines.py); [] when no fleet names file is named."""
    sys.path.insert(0, HERE)
    try:
        import machines
        return [m for m in machines.machine_list(os.environ.get("SALA_FLEET_NAMES") or None, os.environ.get("SALA_MACHINE_FOLLOW_MACHINES") or None)
                if m.get("name") and not m.get("retired")]
    except Exception:
        return []


def fleet_names(ms):
    return sorted({m["name"] for m in ms})


def resolve(word, ms):
    w = word.strip().lower()
    for m in ms:
        if w in {str(m.get(k)).lower() for k in ("name", "hostname") if m.get(k)}:
            return m["name"]
    return None


# ---- the notice --------------------------------------------------------------------------------------------------------------

def notice(*args):
    env = dict(os.environ, SALA_STATE_DIR=STATE)
    return subprocess.run([sys.executable, "-I", "-S", os.path.join(HERE, "notice.py")] + list(args), env=env, capture_output=True, text=True, timeout=60)


def drop_notices():
    r = notice("list", "--json")
    if r.returncode != 0:
        return
    try:
        rows = json.loads(r.stdout or "[]")
    except ValueError:
        return
    for row in rows:
        if row.get("from") == SENDER:
            notice("drop", str(row["id"]))


def post_notice(box, at):
    text = ("the owner is now on %s (since %s). A step for his machine, a browser pick or a step bound to his network goes to that box. "
            "Read it with sala where." % (box, clock(at)))
    notice("add", text, "--from", SENDER, "--until", "12h")


# ---- verbs -------------------------------------------------------------------------------------------------------------------

def apply(box, via, by, at):
    """Record BOX. -> "changed" or "same". The caller holds the lock."""
    rec = read_record()
    if rec and rec["box"] == box:
        rec["at"] = max(int(at), rec["at"])
        write_record(rec)
        return "same"
    write_record({"box": box, "at": int(at), "via": via, "by": by})
    drop_notices()
    post_notice(box, at)
    return "changed"


def line(rec, now):
    age = max(0, int(now - rec["at"]))
    if rec["via"] == "ssh":
        how = "seen over ssh"
    elif rec["via"] == "web":
        how = "seen in the web UI"
    else:
        how = "told by %s" % rec["by"] if rec["by"] else "told"
    s = "the owner is on %s (%s, %s, %s)" % (rec["box"], how, clock(rec["at"]), age_words(age))
    if age > STALE_S:
        s += " (stale)"
    return s


def cmd_show(args):
    as_json = False
    for a in args:
        if a == "--json":
            as_json = True
        else:
            print("usage: sala where [--json] | --scan | set <box> [--by <session>] | clear", file=sys.stderr)
            return 2
    scan()
    rec = read_record()
    now = time.time()
    if as_json:
        if rec is None:
            print("null")
        else:
            print(json.dumps(dict(rec, age_s=max(0, int(now - rec["at"])))))
        return 0
    print(line(rec, now) if rec else "no record")
    return 0


def cmd_set(args):
    by = ""
    words = []
    i = 0
    while i < len(args):
        if args[i] == "--by":
            if i + 1 >= len(args):
                print("sala where set: --by needs a session name", file=sys.stderr)
                return 2
            by = args[i + 1]
            i += 2
        else:
            words.append(args[i])
            i += 1
    if len(words) != 1 or words[0].startswith("-"):
        print("usage: sala where set <box> [--by <session>]", file=sys.stderr)
        return 2
    ms = fleet()
    box = resolve(words[0], ms)
    if box is None:
        known = fleet_names(ms)
        print("sala where set: '%s' is not a fleet machine; known: %s" % (words[0], ", ".join(known) if known else "none (no fleet names file is named: set SALA_FLEET_NAMES)"), file=sys.stderr)
        return 1
    now = int(time.time())
    with locked():
        r = apply(box, "told", by, now)
    print("the owner is on %s%s" % (box, " (refreshed, no new notice)" if r == "same" else " (recorded, one notice posted)"))
    return 0


def cmd_clear(args):
    if args:
        print("usage: sala where clear", file=sys.stderr)
        return 2
    with locked():
        with contextlib.suppress(OSError):
            os.unlink(RECORD)
        drop_notices()
    print("where record cleared")
    return 0


def run(cmd, timeout=10):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout if r.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None


def client_address(pid):
    d = os.environ.get("SALA_WHERE_ENVIRON_DIR")
    path = os.path.join(d, str(pid), "environ") if d else "/proc/%d/environ" % pid
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError:
        return None
    for item in raw.split(b"\0"):
        if item.startswith(b"SSH_CONNECTION="):
            parts = item[len(b"SSH_CONNECTION="):].decode("utf-8", "replace").split()
            return parts[0] if parts else None
    return None


def box_of_address(addr, ms):
    sys.path.insert(0, HERE)
    import machines
    st = machines.tailnet_status()
    if st:
        nodes = [st.get("Self")] + list((st.get("Peer") or {}).values())
        for n in nodes:
            if isinstance(n, dict) and addr in (n.get("TailscaleIPs") or []):
                names = machines._node_names(n)
                for m in ms:
                    if names & machines._row_names(m):
                        return m["name"]
    for m in ms:
        if addr in (m.get("addresses") or []):
            return m["name"]
    return None


def scan():
    """The second source. -> the box it recorded, or None. Silent on every failure."""
    try:
        out = run(["tmux", "list-clients", "-F", "#{client_pid} #{client_activity}"])
        if not out:
            return None
        now = time.time()
        best = None
        for ln in out.splitlines():
            p = ln.split()
            if len(p) == 2 and p[0].isdigit() and p[1].isdigit():
                act = int(p[1])
                if now - act <= SCAN_WINDOW_S and (best is None or act > best[1]):
                    best = (int(p[0]), act)
        if best is None:
            return None
        addr = client_address(best[0])
        if not addr:
            return None
        ms = fleet()
        box = box_of_address(addr, ms)
        if not box:
            return None
        with locked():
            rec = read_record()
            if rec and best[1] <= rec["at"]:
                return None
            if rec and rec["box"] == box:
                apply(box, rec["via"], rec["by"], best[1])
                return None
            apply(box, "ssh", "", best[1])
            return box
    except Exception:
        return None


def seen(addr):
    """The third source: the web UI's request came from ADDR. -> the box it recorded, or None. Silent on every failure.
    A box the machine list does not know is ignored and overwrites nothing. A "told" record under STALE_S old wins over another box;
    "ssh" and "web" sightings are equals, the newest wins (a web sighting is always now)."""
    try:
        import ipaddress
        addr = str(ipaddress.ip_address(addr.strip()))
        box = box_of_address(addr, fleet())
        if not box:
            return None
        now = int(time.time())
        with locked():
            rec = read_record()
            if rec and rec["box"] != box and rec["via"] == "told" and now - rec["at"] <= STALE_S:
                return None
            if rec and rec["box"] == box:
                apply(box, rec["via"], rec["by"], now)
                return None
            apply(box, "web", "", now)
            return box
    except Exception:
        return None


def cmd_seen(args):
    if len(args) != 1:
        print("usage: sala where seen <address>", file=sys.stderr)
        return 2
    box = seen(args[0])
    if box:
        print("the owner is on %s (seen in the web UI)" % box)
    return 0


def cmd_scan(args):
    if args:
        print("usage: sala where --scan", file=sys.stderr)
        return 2
    box = scan()
    if box:
        print("the owner is on %s (seen over ssh)" % box)
    return 0


def main(argv):
    if not argv or argv[0] == "--json":
        return cmd_show(argv)
    verb, rest = argv[0], argv[1:]
    if verb == "show":
        return cmd_show(rest)
    if verb == "set":
        return cmd_set(rest)
    if verb == "clear":
        return cmd_clear(rest)
    if verb == "seen":
        return cmd_seen(rest)
    if verb in ("--scan", "scan"):
        return cmd_scan(rest)
    print("sala where: unknown argument '%s'" % verb, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
