#!/usr/bin/env python3
"""lib/holders.py — name what still runs under a pane's claude, and stop what a finished subagent left.

  holders.py scan <claude-pid> [--max N]   the count on the first line, then one line per process that holds the pane: pid, how
                                           long it has run, the task id the CLI gave it, the subagent that started it (when one
                                           did), its command (cut to 120). "0" alone when nothing holds it. Read-only, the table read from /proc (one `ps` only where there is none); the callers are
                                           `sala ready`, the relaunch notice, and the skip / deferral reasons (lib/common.sh,
                                           holders_lines).
  holders.py scan <claude-pid> --summary   one line, "<count> <seconds the oldest holder has run>" ("0 0" when nothing holds it): what the
                                           deferred-pane bullets in a recycle's posts are built from (lib/common.sh, hold_bullet), which
                                           name neither a pid nor a command.
  holders.py subagent-stop                 the SubagentStop hook (lib/hook.sh, `salamander hook subagent-stop`): reads the hook
                                           input on stdin; when the subagent has handed back, SIGTERMs the background shells
                                           that subagent started and that are still running under the pane's claude, then every process
                                           those shells started (their children, in groups and sessions of their own too), then every
                                           process of the user whose fd 1 / 2 is that task's output file, whatever its parent (a
                                           leftover whose parent died); SIGKILL only for what still runs after 0.3 s. Never prints,
                                           always exits 0.

WHAT HOLDS A PANE. The pane's claude, and every direct child of it that work_children (lib/common.sh) counts: a plugin's MCP
server (CLAUDE_PLUGIN_ROOT in its environment, and not a Bash-tool shell) is left out, everything else is work. A Bash tool
call's shell (`/bin/bash -c source …/shell-snapshots/… && eval '<command>' < /dev/null && pwd -P >| …`) is a direct child of
the claude, a subagent's too (measured 2.1.310): the process tree does not say who started it. The processes this program runs
under (its own ancestors up to the claude: the Bash call that ran `sala ready`, a hook's `sh -c`) are never listed. Nothing
filters on the word "claude" but the registry file that names the pane's process (SALA_REG_DIR/<pid>.json).

WHO STARTED A SHELL. Claude Code opens a background command's stdout and stderr on `<scratch>/tasks/<task id>.output`, so
/proc/<pid>/fd/1 names the task id of the shell and of everything it started. The subagent's own transcript
(<projects>/<slug>/<session>/subagents/agent-<id>.jsonl) holds the Bash tool_use with run_in_background and a tool_result
"Command running in background with ID: <task id>". The same id in both is the proof; nothing else is used (a command text
alone would also match the main thread's identical command). The hook adds the process check: the shell's command line carries
the command text of that tool_use, and the shell is a descendant of the pane's claude.

WHAT THE HOOK STOPS. The shell (its process group when it leads one, else the process), then every descendant of it found by parent
links in a fresh read of the process table (an until-loop's `sleep 300` has a process group of its own and would outlive the
shell), leaf first; then every other process of the same user whose fd 1 or fd 2 is that very output file (the full path: the same
task id under another scratch directory is another file), whatever its parent, group or session: a `setsid sleep` whose parent died
has init for its parent and has left the shell's tree, but keeps the file it was started with (found by a real-pane
test). After 0.3 s only what still runs and is still the same process (start time unchanged: a pid may be reused) gets SIGKILL.
Never signalled: the hook's own chain, the pane's claude and its ancestors (one of these ends the walk below the shell); a process
whose fd points at a different task file (another task of the same or of another subagent). A process that left the tree and
no longer holds the file on fd 1 / 2 (redirected elsewhere, or the file closed) is not found. The scan reads fd 1 and 2 of the
user's own processes (a readlink or two each) and runs only once a shell has passed the proof above.

WHEN THE HOOK ACTS. Only after the subagent's SubagentHandback tool_use: a subagent without it that ends its turn may be waiting
for its background command to finish and be woken by it (Claude Code sends the subagent a notification when the command ends),
which is real work. Stopping the shell wakes the subagent once more (a second SubagentStart / SubagentStop with nothing left
to stop; measured). Exit 0 on every path, a line in SALA_SUBAGENT_LOG for what it did or why it did nothing."""
import glob, json, os, re, signal, subprocess, sys, time

CMD_CUT = 120


def env_scrub():
    src = os.environ.get("SALA_SCRUB_PY")
    if src:
        ns = {}
        try:
            exec(src, ns)
            return ns["scrub"]
        except Exception:
            pass
    return lambda t: t


SCRUB = env_scrub()


def etime_secs(e):
    e = e.strip()
    d = 0
    if "-" in e:
        d, e = e.split("-", 1)
    parts = [int(x) for x in e.split(":")]
    h, m, s = ([0] * (3 - len(parts))) + parts
    return ((int(d) * 24 + h) * 60 + m) * 60 + s


def words(s):
    if s >= 86400:
        h = s // 3600
        return "%d days %d h" % (h // 24, h % 24) if h % 24 else "%d days" % (h // 24)
    if s >= 3600:
        return "%d h %d min" % (s // 3600, (s % 3600) // 60) if (s % 3600) // 60 else "%d h" % (s // 3600)
    if s >= 60:
        return "%d min" % (s // 60)
    return "%d s" % s


def table_proc():
    """pid -> (ppid, seconds up, args) read from /proc: no ps process (the suites and the watch count processes).
    args is the command line as ps shows it (the NUL-separated words joined by a space); a kernel thread's is empty."""
    with open("/proc/uptime") as f:
        up = float(f.read().split()[0])
    hz = os.sysconf("SC_CLK_TCK") or 100
    t = {}
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % name) as f:
                st = f.read()
            rest = st[st.rindex(")") + 2:].split()      # after "pid (comm) ": state is rest[0], ppid rest[1], starttime rest[19]
            with open("/proc/%s/cmdline" % name, "rb") as f:
                args = f.read().replace(b"\0", b" ").decode("utf-8", "replace").strip()
            t[int(name)] = (int(rest[1]), max(0, int(up - int(rest[19]) / hz)), args)
        except (OSError, ValueError, IndexError):
            continue                                    # gone while it was read
    return t


def table():
    """pid -> (ppid, seconds up, args): /proc where there is one (Linux), else one ps call (macOS)."""
    if os.path.isdir("/proc/%d" % os.getpid()):
        try:
            return table_proc()
        except (OSError, ValueError):
            pass
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,etime=,args=", "-ww"], capture_output=True, text=True, timeout=10).stdout
    t = {}
    for line in out.splitlines():
        p = line.split(None, 3)
        if len(p) < 3 or not p[0].isdigit() or not p[1].isdigit():
            continue
        try:
            t[int(p[0])] = (int(p[1]), etime_secs(p[2]), p[3] if len(p) > 3 else "")
        except ValueError:
            continue
    return t


def ancestors(t, pid):
    out, seen = [], set()
    while pid and pid not in seen and pid != 1:
        seen.add(pid)
        out.append(pid)
        pid = t.get(pid, (0,))[0]
    return out


def read_cmdline(pid):
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except OSError:
        return None


def is_plugin_child(pid):
    """work_children (lib/common.sh): a child with CLAUDE_PLUGIN_ROOT in its environment and no shell-snapshots in its command
    line is a plugin's MCP / LSP server, which runs for the session's life. An environment that cannot be read counts as work."""
    cl = read_cmdline(pid)
    if cl is not None and "shell-snapshots" in cl:
        return False
    try:
        with open("/proc/%d/environ" % pid, "rb") as f:
            return b"\0CLAUDE_PLUGIN_ROOT=" in b"\0" + f.read()
    except OSError:
        return False


TASK_FILE_RE = re.compile(r"/tasks/([A-Za-z0-9]+)\.output$")


def task_file(pid):
    """(task id, full path) of a process's output file: its stdout / stderr are <scratch>/tasks/<id>.output (Linux), else ('', '')."""
    for fd in (1, 2):
        try:
            path = os.readlink("/proc/%d/fd/%d" % (pid, fd))
        except OSError:
            continue
        m = TASK_FILE_RE.search(path)
        if m:
            return m.group(1), path
    return "", ""


def task_of(pid):
    """The CLI's background task id of a process: its stdout / stderr are <scratch>/tasks/<id>.output (Linux)."""
    return task_file(pid)[0]


def holds_file(pid, path):
    """True when fd 1 or fd 2 of the process is exactly that file (the full path: the same task id in another scratch directory is another file)."""
    for fd in (1, 2):
        try:
            if os.readlink("/proc/%d/fd/%d" % (pid, fd)) == path:
                return True
        except OSError:
            continue
    return False


def outside_holders(fresh, path, skip):
    """[pid] of the user's own processes, not in skip, whose fd 1 or 2 is that task output file, whatever their parent, group or session
    (a leftover whose parent died has init for its parent and left the shell's tree, but keeps the file it was started with)."""
    me = os.getuid()
    out = []
    for p in sorted(fresh):
        if p in skip:
            continue
        try:
            if os.stat("/proc/%d" % p).st_uid != me:
                continue
        except OSError:
            continue
        if holds_file(p, path):
            out.append(p)
    return out


EVAL_RE = re.compile(r"eval '(.*)'(?: < /dev/null)?(?: && pwd -P >\| \S+)?\s*$", re.S)


def command_of(args):
    """The command a Bash-tool shell was given: the eval'd text of its snapshot line, else the command line itself."""
    if "shell-snapshots" in args:
        m = EVAL_RE.search(args)
        if m:
            args = m.group(1).replace("'\"'\"'", "'").replace("'\\''", "'")   # the CLI quotes a ' as '"'"' (a shell's own way: '\'')
    return " ".join(args.split())


def cut(s, n=CMD_CUT):
    s = SCRUB(s)
    return s if len(s) <= n else s[: n - 1] + "…"


def registry(cpid):
    try:
        with open(os.path.join(os.environ.get("SALA_REG_DIR", os.path.expanduser("~/.claude/sessions")), "%d.json" % cpid)) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def subagent_dirs(session_id):
    if not session_id or "/" in session_id:
        return []
    return glob.glob(os.path.join(os.environ.get("SALA_PROJECTS", os.path.expanduser("~/.claude/projects")), "*", session_id, "subagents"))


def started_by_subagent(session_id, task, up_secs):
    """The id of the subagent whose transcript holds the 'running in background with ID: <task>' result, else ''."""
    if not task:
        return ""
    needle = ("background with ID: %s" % task).encode()
    oldest = time.time() - up_secs - 300
    for d in subagent_dirs(session_id):
        for f in glob.glob(os.path.join(d, "agent-*.jsonl")):
            try:
                if os.path.getmtime(f) < oldest:
                    continue
                with open(f, "rb") as fh:
                    if needle in fh.read():
                        return os.path.basename(f)[len("agent-"):-len(".jsonl")]
            except OSError:
                continue
    return ""


def holders(cpid, t=None, exclude=()):
    """[(pid, secs, task, agent, command)] for the work children of the pane's claude, oldest first."""
    t = t or table()
    mine = set(ancestors(t, os.getpid())) | set(exclude)
    sid = registry(cpid).get("sessionId") or ""
    out = []
    for pid, (ppid, secs, args) in sorted(t.items()):
        if ppid != cpid or pid in mine or "<defunct>" in args or is_plugin_child(pid):
            continue
        task = task_of(pid)
        out.append((pid, secs, task, started_by_subagent(sid, task, secs), command_of(args)))
    out.sort(key=lambda h: -h[1])
    return out


def holder_line(h):
    pid, secs, task, agent, cmd = h
    bits = ["pid %d" % pid, "up %s" % words(secs)]
    if task:
        bits.append("task %s" % task)
    if agent:
        bits.append("started by a subagent (%s)" % agent[:8])
    return "%s: %s" % (", ".join(bits), cut(cmd))


def scan(argv):
    mx = 5
    if "--max" in argv:
        i = argv.index("--max")
        mx = int(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    summary = "--summary" in argv
    argv = [a for a in argv if a != "--summary"]
    cpid = int(argv[0])
    hs = holders(cpid)
    if summary:
        print("%d %d" % (len(hs), hs[0][1] if hs else 0))   # holders() is sorted oldest first
        return
    print(len(hs))                                      # the first line is the count; the holders follow, one a line
    for h in hs[:mx]:
        print(holder_line(h))
    if len(hs) > mx:
        print("and %d more" % (len(hs) - mx))


# ── the SubagentStop hook ─────────────────────────────────────────────────────

def log(msg):
    path = os.environ.get("SALA_SUBAGENT_LOG")
    if not path:
        return
    try:
        with open(path, "a") as f:
            f.write("[%s] %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S%z"), msg))
    except OSError:
        pass


def read_transcript(path):
    """-> (handed_back, {task id: command}) from a subagent's transcript."""
    bash_uses, tasks, back = {}, {}, False
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return False, {}
    with fh:
        for line in fh:
            if "tool_use" not in line and "tool_result" not in line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            c = (o.get("message") or {}).get("content")
            if not isinstance(c, list):
                continue
            for b in c:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "tool_use":
                    if b.get("name") == "SubagentHandback":
                        back = True
                    elif b.get("name") in ("Bash", "PowerShell") and isinstance(b.get("input"), dict) and b["input"].get("run_in_background"):
                        bash_uses[b.get("id")] = str(b["input"].get("command") or "")
                elif b.get("type") == "tool_result" and b.get("tool_use_id") in bash_uses:
                    txt = b.get("content")
                    if isinstance(txt, list):
                        txt = " ".join(x.get("text", "") for x in txt if isinstance(x, dict))
                    m = re.match(r"Command running in background with ID: ([A-Za-z0-9]+)", txt if isinstance(txt, str) else "")
                    if m:
                        tasks[m.group(1)] = bash_uses[b["tool_use_id"]]
    return back, tasks


def norm(s):
    return re.sub(r"[^A-Za-z0-9]", "", s)


def own_claude(t):
    reg = os.environ.get("SALA_REG_DIR", os.path.expanduser("~/.claude/sessions"))
    for p in ancestors(t, os.getpid())[1:]:
        if os.path.exists(os.path.join(reg, "%d.json" % p)):
            return p
    return 0


def proc_mark(pid):
    """(start time in ticks) of a process: with the pid it names one process; a reused pid has another. None when it is gone."""
    try:
        with open("/proc/%d/stat" % pid) as f:
            return f.read().rsplit(")", 1)[1].split()[19]
    except (OSError, IndexError):
        return None


def running_same(pid, mark):
    """True while pid is the process that was marked and is not a zombie (a stopped child waits for its parent to reap it)."""
    try:
        with open("/proc/%d/stat" % pid) as f:
            rest = f.read().rsplit(")", 1)[1].split()
    except (OSError, IndexError):
        return False
    return rest[0] != "Z" and rest[19] == mark


def signal_same(pid, mark, sig):
    if mark is None or not running_same(pid, mark):
        return
    try:
        os.kill(pid, sig)
    except OSError:
        pass


def descendants(t, top, protected):
    """[(depth, pid)] of every process below top by parent links (other process groups and sessions too), deepest first. A
    protected pid (the hook's own chain, the pane's claude) is left alone, and so is everything below it."""
    kids = {}
    for pid, (ppid, _s, _a) in t.items():
        kids.setdefault(ppid, []).append(pid)
    out, seen, stack = [], {top}, [(top, 0)]
    while stack:
        p, d = stack.pop()
        for k in kids.get(p, []):
            if k in seen or k in protected:
                continue
            seen.add(k)
            out.append((d + 1, k))
            stack.append((k, d + 1))
    out.sort(key=lambda x: -x[0])
    return out


def subagent_stop():
    try:
        d = json.load(sys.stdin)
    except Exception:
        return
    if not isinstance(d, dict):
        return
    agent, path = d.get("agent_id"), d.get("agent_transcript_path")
    if not (isinstance(agent, str) and re.fullmatch(r"[A-Za-z0-9_-]{4,64}", agent) and isinstance(path, str)):
        return
    path = os.path.expanduser(path)
    if os.path.basename(path) != "agent-%s.jsonl" % agent or os.path.basename(os.path.dirname(path)) != "subagents":
        return                                          # not a subagent's own transcript: nothing is proven
    running = {x.get("id"): x for x in (d.get("background_tasks") or []) if isinstance(x, dict) and x.get("type") == "shell"}
    if not running:
        return                                          # nothing in flight to stop: the common case
    back, tasks = False, {}
    for i in range(4):                                  # the transcript is written asynchronously and may lag the hook
        back, tasks = read_transcript(path)
        if back and any(k in running for k in tasks):
            break
        time.sleep(0.25)
    mine = {k: v for k, v in tasks.items() if k in running}
    if not mine:
        return                                          # no running shell was started by this subagent
    tag = "session %s agent %s" % (str(d.get("session_id"))[:8], agent[:8])
    if not back:
        log("%s: left %d running background shell(s) (%s) but has not handed back, so it may be waiting for them: nothing stopped" % (tag, len(mine), ", ".join(sorted(mine))))
        return
    if not os.path.isdir("/proc/%d" % os.getpid()):
        log("%s: no /proc on this system, so a shell cannot be tied to its task: nothing stopped" % tag)
        return
    t = table()
    cpid = own_claude(t)
    if not cpid:
        log("%s: this hook does not run under a registered claude: nothing stopped" % tag)
        return
    protected = set(ancestors(t, os.getpid()))
    kids = {}
    for pid, (ppid, _s, _a) in t.items():
        kids.setdefault(ppid, []).append(pid)
    below, stack = set(), [cpid]                        # descendants of the pane's claude
    while stack:
        for k in kids.get(stack.pop(), []):
            if k not in below:
                below.add(k)
                stack.append(k)
    for task, cmd in sorted(mine.items()):
        procs = [p for p in below if task_of(p) == task and p not in protected]
        tops = [p for p in procs if t[p][0] not in procs]
        if not tops:
            log("%s: task %s (%s) is listed as running but no process under the pane writes to it: nothing stopped" % (tag, task, cut(cmd, 80)))
            continue
        for top in tops:
            args = t[top][2]
            if norm(cmd) and norm(cmd)[:200] not in norm(args):
                log("%s: task %s pid %d does not carry the subagent's command text: nothing stopped (%s)" % (tag, task, top, cut(command_of(args), 80)))
                continue
            try:
                pg = os.getpgid(top)
            except OSError:
                continue
            fresh = table()                             # the shell's children as they are now: the until-loop starts a new sleep every few seconds
            desc = descendants(fresh, top, protected | {cpid})
            tid, tpath = task_file(top)                 # the shell's own output file, full path (the same task id in another scratch directory is another task's)
            outside = outside_holders(fresh, tpath, protected | {cpid, top} | set(procs) | {p for _d, p in desc} | set(ancestors(fresh, cpid))) if tid == task else []
            marks = {p: proc_mark(p) for p in [top] + [p for _d, p in desc] + outside}
            try:
                if pg == top and pg not in protected and pg != os.getpgid(cpid):
                    os.killpg(pg, signal.SIGTERM)       # the shell first, with whatever shares its group
                    how = "process group %d" % pg
                else:
                    os.kill(top, signal.SIGTERM)
                    how = "no group of its own"
            except OSError as e:
                log("%s: task %s pid %d: kill failed (%s)" % (tag, task, top, e))
                continue
            for _d, p in desc:                          # then everything it started, in groups and sessions of their own too (leaf first)
                signal_same(p, marks[p], signal.SIGTERM)
            for p in outside:                           # then what left the tree but still writes to the task's file
                signal_same(p, marks[p], signal.SIGTERM)
            time.sleep(0.3)
            left = [p for p in [top] + [p for _d, p in desc] + outside if running_same(p, marks[p])]
            for p in left:                              # still running after the wait, and still the same process (a pid may be reused)
                signal_same(p, marks[p], signal.SIGKILL)
            killed = set(left)
            log("%s: stopped task %s, pid %d (%s), up %s, SIGTERM to %s%s, %d descendant(s), %d outside its tree: %s" % (tag, task, top, how, words(t[top][1]), how, ", SIGKILL after 0.3 s" if top in killed else "", len(desc), len(outside), cut(cmd)))
            for _d, p in desc:
                log("%s: stopped task %s, descendant pid %d of %d, up %s, SIGTERM%s: %s" % (tag, task, p, top, words(fresh[p][1]), ", SIGKILL after 0.3 s" if p in killed else "", cut(command_of(fresh[p][2]), 80)))
            for p in outside:
                log("%s: stopped task %s, outside the shell's tree pid %d, up %s, SIGTERM%s: %s" % (tag, task, p, words(fresh[p][1]), ", SIGKILL after 0.3 s" if p in killed else "", cut(command_of(fresh[p][2]), 80)))


def main(argv):
    if not argv:
        return 0
    try:
        if argv[0] == "scan":
            scan(argv[1:])
        elif argv[0] == "subagent-stop":
            subagent_stop()
    except Exception as e:                              # fail open: a hook never blocks a subagent
        if argv[0] == "subagent-stop":
            log("subagent-stop failed open: %s" % e)
        else:
            print(0)                                    # scan: nothing found, never an error for its caller
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
