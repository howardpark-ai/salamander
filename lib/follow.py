"""lib/follow.py — the resident watcher behind `salamander follow` (Linux, inotify).

One long-running process keeps the last known state of every live Claude Code session in memory, from the registry
directory (~/.claude/sessions/<pid>.json), and is woken by the kernel when a file there is written. A write that changes
nothing a handler cares about (the status flips of every turn) costs one small JSON read and nothing else: no process,
no scan, no log line. Only a real change reaches a handler, so the work scales with events, not with turns or panes.

Handlers (HANDLERS below) each say which fields they watch and what to run; a burst of changes is handled once after
SALA_FOLLOW_QUIET seconds of quiet, and each handler runs at most SALA_FOLLOW_MAX times a minute (beyond that it pauses
for the rest of the minute and says so once in the log; `salamander watch` is every handler's backstop).

  rename   name / nameSource changed → `salamander rename --sync` (follows a hand /rename, and a
           mechanism that scales with renames, not turns; Claude Code has no rename hook event)
  continued  sessionId changed → `salamander watch --continued`: a live pane that moved to a new transcript id
           (a continued-in record in the old one) has its pane map row and session registry follow within seconds, not at the
           2-minute tick; a /clear changes it too, and the run finds no record and does nothing

A handler run that does not exit within SALA_FOLLOW_TIMEOUT seconds is killed and logged; the follower keeps going.

Env: SALA_BIN, SALA_REG_DIR, SALA_LOG_DIR, SALA_FOLLOW_QUIET (2), SALA_FOLLOW_MAX (5), SALA_FOLLOW_TIMEOUT (60).
"""
import ctypes, ctypes.util, errno, json, os, select, struct, subprocess, sys, time

REG = os.environ["SALA_REG_DIR"]
BIN = os.environ["SALA_BIN"]
LOG = os.path.join(os.environ.get("SALA_LOG_DIR", os.path.expanduser("~/.claude")), "salamander-follow.log")
QUIET = float(os.environ.get("SALA_FOLLOW_QUIET") or 2)
MAX = int(os.environ.get("SALA_FOLLOW_MAX") or 5)
RUN_TIMEOUT = int(os.environ.get("SALA_FOLLOW_TIMEOUT") or 60)

HANDLERS = {
    "rename": {"fields": ("name", "nameSource"), "cmd": [BIN, "rename", "--sync"]},
    "continued": {"fields": ("sessionId",), "cmd": [BIN, "watch", "--continued"]},
}

def log(msg):
    with open(LOG, "a") as f:
        f.write(time.strftime("[%Y-%m-%dT%H:%M:%S%z] ") + msg + "\n")

def read(path):
    try:
        with open(path) as f: return json.load(f)
    except Exception: return None

def fields(d, names):
    return tuple(d.get(n) for n in names) if d else None

# ── inotify through libc (no third-party module)
libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
IN_CLOSE_WRITE, IN_MOVED_TO, IN_CREATE, IN_DELETE, IN_MOVED_FROM = 0x8, 0x80, 0x100, 0x200, 0x40
IN_NONBLOCK, IN_CLOEXEC = 0o4000, 0o2000000
fd = libc.inotify_init1(IN_NONBLOCK | IN_CLOEXEC)
if fd < 0: sys.exit("follow: inotify_init1 failed: " + os.strerror(ctypes.get_errno()))
if libc.inotify_add_watch(fd, REG.encode(), IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE | IN_DELETE | IN_MOVED_FROM) < 0:
    sys.exit("follow: cannot watch %s: %s" % (REG, os.strerror(ctypes.get_errno())))

# state: file name → the watched fields per handler, as last seen
state = {}
def snapshot(fn):
    d = read(os.path.join(REG, fn))
    return {h: fields(d, spec["fields"]) for h, spec in HANDLERS.items()} if d else None

for fn in os.listdir(REG):
    if fn.endswith(".json"): state[fn] = snapshot(fn)

due = {}            # handler → time of the last change that wants it run
runs = {h: [] for h in HANDLERS}
paused_note = set()

def run(h):
    now = time.time()
    runs[h] = [t for t in runs[h] if now - t < 60]
    if len(runs[h]) >= MAX:
        if h not in paused_note: log("%s: %d runs in the last minute — paused until the minute is over (watch is the backstop)" % (h, MAX)); paused_note.add(h)
        due[h] = now; return
    paused_note.discard(h); runs[h].append(now)
    try:
        r = subprocess.run(HANDLERS[h]["cmd"], capture_output=True, text=True, timeout=RUN_TIMEOUT)
    except subprocess.TimeoutExpired:       # a hung handler must not stop the follower (subprocess kills the child itself)
        log("%s: no exit after %ds — killed, the follower goes on (watch is the backstop)" % (h, RUN_TIMEOUT))
        return
    if r.returncode not in (0, 3) or r.stdout.strip() or r.stderr.strip():
        log("%s: exit %d %s" % (h, r.returncode, (r.stdout + r.stderr).strip()[:300]))

log("follow: started, %d sessions, handlers: %s" % (len(state), ", ".join(HANDLERS)))
for h in HANDLERS: due[h] = 0.0        # one pass at start catches what changed while nobody was watching

HDR = struct.calcsize("iIII")
while True:
    timeout = None
    if due: timeout = max(0.0, min(due.values()) + QUIET - time.time())
    ready, _, _ = select.select([fd], [], [], timeout)
    if ready:
        try: buf = os.read(fd, 65536)
        except BlockingIOError: buf = b""
        i = 0
        while i + HDR <= len(buf):
            wd, mask, cookie, ln = struct.unpack_from("iIII", buf, i)
            name = buf[i + HDR:i + HDR + ln].split(b"\0", 1)[0].decode(errors="replace"); i += HDR + ln
            if not name.endswith(".json"): continue
            if mask & (IN_DELETE | IN_MOVED_FROM): state.pop(name, None); continue
            new = snapshot(name)
            if new is None: continue
            old = state.get(name)
            state[name] = new
            for h in HANDLERS:
                if old is None and not new[h][0]: continue          # a fresh session with nothing set yet
                if old is None or old[h] != new[h]: due[h] = time.time()
    now = time.time()
    for h, t in list(due.items()):
        if now - t >= QUIET:
            del due[h]; run(h)
