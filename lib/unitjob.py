#!/usr/bin/env python3
"""lib/unitjob.py — `sala job`: scheduled jobs as systemd units kept in git, and the watcher for the ones that are not (docs/units.md).

Standard library only, no model call anywhere; run as `python3 -I -S unitjob.py <verb> …` by lib/job.sh and lib/watch.sh.

  add NAME --repo R --script PATH --schedule S [--schedule S …] --description TEXT --lane LANE --project PROJECT
           [--note TEXT] [--args TEXT] [--scope user|system] [--checkout DIR]
           writes NAME.service and NAME.timer into the repo's unit folder (the repo table, ~/.config/salamander/unit-repos.tsv), links them into the user unit folder,
           daemon-reload, enable --now; the system scope only prints the root command. Prints what to commit; commits nothing.
  list     our timers (not shipped by a package): name, repo, schedule, lane, project, in git yes/no
  set-project NAME PROJECT [--checkout DIR] [--quiet]   write X-Project=PROJECT into the service's git file (replacing one, or after X-Model-Lane=); prints what to commit
  remove NAME [--checkout DIR]   disable, unlink (skipping a link disable already removed), daemon-reload, reset-failed, delete the files from the repo checkout; prints what to commit
  relink NAME                    point a job's links at the production checkout once its pull request is deployed
  check [--post] [--quiet]       the gap watcher: our timers with no Description=, no X-Model-Lane=, no X-Project= or not in git; --post opens each gap as one
                                 board item (client.py post job-gap open; stackshot sets its mover to the builder of the repo that owns the
                                 script; deduped by unit + gap code) and, for a gap that is fixed, closes the item (post job-gap clear) and
                                 drops the record

Environment (the tests point these at a temporary tree): SALA_JOB_USER_DIR (~/.config/systemd/user), SALA_JOB_SYSTEM_DIR
(/etc/systemd/system, read only), SALA_JOB_SYSTEMCTL (systemctl), SALA_JOB_ANALYZE (systemd-analyze), SALA_JOB_REPOS
(the repo table: ~/.config/salamander/unit-repos.tsv when the box has one, else the tracked lib/unit-repos.tsv, which lists no repo), SALA_JOB_GITHUB (the GitHub owner/name for a gap whose repo has none; empty = such a gap is not posted), SALA_UNIT_PROJECT_MAP (`from=to` pairs: a unit's X-Project= shown as another project; unset = as written), SALA_STATE_DIR, SALA_STACKSHOT_CLIENT / SALA_STACKSHOT_DIR (the client the board call goes through).

The gap logic mirrors web/src/sala_web/schedules.py (`unit_file_state`, the not-git / no-lane / bad-lane / no-project flags; the same packaged rule:
a unit file under /usr/ or /lib/ is a package's and never ours), reading files instead of asking systemd, so a pass costs file reads and
no systemctl call.
"""
import fcntl, os, re, shlex, subprocess, sys, tempfile, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # run with -I -S: the script's folder is not on the path by itself
import lanewords   # the lane words (lib/lanewords.py): an X-Model-Lane= still saying max or team is read as subscription-1 or subscription-2

LANES = ("subscription-1", "bedrock", "aws-platform", "api", "subscription-2", "sdk", "none")
# a job's project, in the label the web UI's Agents table shows in its Project column (sessions.py: scope + "/" + the project's title)
PROJECT_RE = re.compile(r"^[a-z][a-z0-9-]*/[a-z0-9][a-z0-9._-]*$")
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
HOME = os.path.expanduser("~")
PACKAGED = ("/usr/", "/lib/")
PACKAGED_DIRS = {"user": ("/usr/lib/systemd/user", "/lib/systemd/user", "/etc/systemd/user"), "system": ("/usr/lib/systemd/system", "/lib/systemd/system")}
ONKEYS = ("OnCalendar", "OnBootSec", "OnStartupSec", "OnActiveSec", "OnUnitActiveSec", "OnUnitInactiveSec")
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,59}$")
RENDERED = re.compile(r"^#\s*Rendered by\s+\S+\s+from\s+(\S+\.in)\b")   # stackshot's install.sh header (schedules.py RENDERED)
SENDER = "sala-unit-gaps"
GITHUB_DEFAULT = os.environ.get("SALA_JOB_GITHUB", "").strip()   # the owner/name stackshot's job-gap call takes for a script in no known repo (the * row) and for a row with no github column; empty (the default) = none, and such a gap is not posted
DETAIL_MAX = 600                           # client.py post job-gap open --detail: at most this many characters
MAX_POSTS_PER_PASS = 3
GAP_WORDS = {"no-description": "has no Description= in its [Unit] section", "no-lane": "has no X-Model-Lane= in its [Unit] section",
             "no-project": "has no X-Project= in its [Unit] section",
             "bad-lane": "has an X-Model-Lane= that is none of " + ", ".join(LANES), "not-git": "is not kept in a git repo", "git-differs": "is a copy that differs from its git file"}
USAGE = {
    "add": "usage: sala job add NAME --repo REPO --script PATH --schedule SCHEDULE [--schedule SCHEDULE …] --description \"…\" --lane LANE\n"
           "                    --project PROJECT [--note \"…\"] [--args \"…\"] [--scope user|system] [--checkout DIR]\n"
           "  REPO      %s\n  SCHEDULE  an OnCalendar expression (\"*-*-* 03:00:00 UTC\", \"daily\") or OnXxx=value (\"OnBootSec=5min\", \"OnUnitActiveSec=1h\")\n"
           "  LANE      " + " | ".join(LANES) + "   (the model lane the script runs on; none = no model call)\n"
           "  PROJECT   scope/project, as the Agents table's Project column shows it (for example team/demo, team/web-app)\n"
           "            (the job's category on the Overview's Schedules tab; kept as X-Project= in the service's [Unit])",
    "remove": "usage: sala job remove NAME [--checkout DIR]",
    "relink": "usage: sala job relink NAME",
    "list": "usage: sala job list",
    "check": "usage: sala job check [--post] [--quiet]",
    "set-project": "usage: sala job set-project NAME PROJECT [--checkout DIR] [--quiet]",
}


# ---- settings and small helpers --------------------------------------------------------------------------------------------------

def user_dir():
    return os.environ.get("SALA_JOB_USER_DIR") or os.path.join(HOME, ".config", "systemd", "user")


def system_dir():
    return os.environ.get("SALA_JOB_SYSTEM_DIR") or "/etc/systemd/system"


def state_dir():
    return os.environ.get("SALA_STATE_DIR") or os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local", "state"), "salamander")


def systemctl_argv(*args):
    return shlex.split(os.environ.get("SALA_JOB_SYSTEMCTL") or "systemctl") + list(args)


def project_map():
    """SALA_UNIT_PROJECT_MAP: space-separated `from=to` pairs; a unit's X-Project= value that equals a `from` is shown (and checked) as its `to`.
    The units are copied byte for byte, so an instance that files these jobs under its own category says so here. A pair with no `=`, or an
    empty side, is ignored; a `from` named twice takes the last. Unset or empty: no mapping. Mirrors web/src/sala_web/schedules.py `project_map`."""
    out = {}
    for pair in (os.environ.get("SALA_UNIT_PROJECT_MAP") or "").split():
        a, eq, b = pair.partition("=")
        if eq and a and b:
            out[a] = b
    return out


def mapped_project(value):
    return project_map().get(value, value)


def say(*a):
    print(*a)


def die(msg, verb=None, code=2):
    print("sala job%s: %s" % (" " + verb if verb else "", msg), file=sys.stderr)
    if verb in USAGE and code == 2:
        print(USAGE[verb].replace("%s", repos_phrase()), file=sys.stderr)
    sys.exit(code)


def one_line(s):
    return " ".join(str(s or "").split())


def tilde(p):
    return "~" + p[len(HOME):] if p == HOME or p.startswith(HOME + "/") else p


def read_text(p):
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def run(argv, timeout=20, stdin=None):
    try:
        return subprocess.run(argv, input=stdin, stdin=None if stdin is not None else subprocess.DEVNULL, capture_output=True, text=True,
                              timeout=timeout, env=dict(os.environ, LC_ALL="C", GIT_TERMINAL_PROMPT="0"))
    except (OSError, subprocess.TimeoutExpired) as e:
        return subprocess.CompletedProcess(argv, 127, "", type(e).__name__)


# ---- the repo table ---------------------------------------------------------------------------------------------------------------

def repos_path():
    """SALA_JOB_REPOS, else ~/.config/salamander/unit-repos.tsv when the box has one, else the tracked lib/unit-repos.tsv (which lists no repo)."""
    p = os.environ.get("SALA_JOB_REPOS")
    if p:
        return p
    mine = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config"), "salamander", "unit-repos.tsv")
    return mine if os.path.isfile(mine) else os.path.join(HERE, "unit-repos.tsv")


def load_repos():
    """{repo: {checkout, user_dir, system_dir, flow, project, builder, note, github}} from the repo table (repos_path()); '-' is None."""
    path = repos_path()
    out = {}
    for line in read_text(path).splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        f = (line.split("\t") + [""] * 9)[:9]
        f = [None if x.strip() in ("", "-") else x.strip() for x in f]
        co = os.path.realpath(os.path.expanduser(f[1])) if f[1] else None
        out[f[0]] = {"checkout": co, "user_dir": f[2], "system_dir": f[3], "flow": f[4] or "pr", "project": f[5], "builder": f[6], "note": f[7] or "",
                "github": f[8] or GITHUB_DEFAULT}
    return out


def repos_phrase():
    try:
        return " | ".join(r for r in load_repos() if r != "*") or "(none: the repo table %s lists no repo; add one line to ~/.config/salamander/unit-repos.tsv)" % tilde(repos_path())
    except Exception:
        return "a repo of the repo table (~/.config/salamander/unit-repos.tsv)"


def git_root(path):
    """The directory above path that holds a .git (a directory, or a file for a worktree), else None. File reads only."""
    d = path if os.path.isdir(path) else os.path.dirname(path)
    while d and d != "/":
        if os.path.exists(os.path.join(d, ".git")):
            return d
        d = os.path.dirname(d)
    return None


def checkout_of_root(root, repos):
    """The repo name whose production checkout is root, or whose worktree root is (its .git file names a gitdir under the checkout)."""
    if not root:
        return None
    root = os.path.realpath(root)
    for name, r in repos.items():
        if r["checkout"] and r["checkout"] == root:
            return name
    g = os.path.join(root, ".git")
    if os.path.isfile(g):
        m = re.match(r"gitdir:\s*(\S.*?)\s*$", read_text(g).strip())
        if m:
            gd = os.path.realpath(m.group(1))
            for name, r in repos.items():
                if r["checkout"] and gd.startswith(r["checkout"] + "/.git/"):
                    return name
    return None


def repo_of(path, repos):
    return checkout_of_root(git_root(os.path.realpath(path)), repos)


def is_packaged(real):
    return real.startswith(PACKAGED)


# ---- unit files ---------------------------------------------------------------------------------------------------------------------

def unit_sections(text):
    """{section: [(key, value)]} of a unit file (schedules.py unit_sections)."""
    sections, cur = {}, None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line[0] in "#;":
            continue
        m = re.match(r"^\[([^\]]+)\]$", line)
        if m:
            cur = m.group(1)
            sections.setdefault(cur, [])
        elif cur is not None and "=" in line:
            k, _, v = line.partition("=")
            sections[cur].append((k.strip(), v.strip()))
    return sections


def last_value(sections, section, key):
    found = None
    for k, v in sections.get(section, []):
        if k == key:
            found = v
    return found


def schedule_of(timer_text):
    return [f"{k}={v}" for k, v in unit_sections(timer_text).get("Timer", []) if k in ONKEYS and v]


def find_script(service_text, repos):
    """The script a service runs: its ExecStart's first existing file that lies in a known repo, else in any git repo, else the first
    outside the system directories (schedules.py pick_script). A path is a token or a %h/~ path anywhere in the line (bash -c '…')."""
    cands = []
    for k, v in unit_sections(service_text).get("Service", []):
        if k != "ExecStart":
            continue
        v = v.lstrip("-@:+!")
        try:
            toks = shlex.split(v)
        except ValueError:
            toks = v.split()
        toks += re.findall(r"(?:%h|~)?/[\w./+-]+", v)
        for t in toks:
            t = t.replace("%h", HOME)
            t = os.path.expanduser(t) if t.startswith("~/") else t
            if t.startswith("/") and os.path.isfile(t):
                cands.append(os.path.realpath(t))
    for pred in (lambda p: repo_of(p, repos), lambda p: git_root(p), lambda p: not p.startswith(("/usr/", "/bin/", "/sbin/", "/lib/", "/etc/", "/opt/", "/snap/"))):
        for p in cands:
            if pred(p):
                return p
    return None


def _twin_search(path, name, roots):
    """(label, the tracked file, identical) for a regular file and the tracked file of the same name in one of `roots` ([(label, dir)]):
    an identical one if any, else the first that differs, else (None, None, False). One `git ls-files` per root."""
    data, differing = None, None
    for label, co in roots:
        if not co or not os.path.isdir(co):
            continue
        p = run(["git", "-C", co, "ls-files", "-z", "--", ":(glob)**/" + name], 8)
        if p.returncode != 0:
            continue
        for rel in [x for x in p.stdout.split("\0") if x]:
            if data is None:
                try:
                    with open(path, "rb") as f:
                        data = f.read()
                except OSError:
                    return None, None, False
            try:
                with open(os.path.join(co, rel), "rb") as f:
                    if f.read() == data:
                        return label, os.path.join(co, rel), True
            except OSError:
                continue
            differing = differing or (label, os.path.join(co, rel), False)
    return differing or (None, None, False)


def _stamp(p):
    try:
        st = os.stat(p)
        return "%d:%d" % (st.st_mtime_ns, st.st_size)
    except OSError:
        return ""


def tracked_twin(path, name, repos, script):
    """(label, tracked file, identical) as _twin_search, over the table's checkouts and the script's own repo (the web page's roots:
    schedules.py known_roots). An identical hit is remembered in unit-gaps.twin (the installed file's and the repo file's mtime and
    size), so the 2-minute pass starts no git process for a file that has not changed; a miss or a difference is searched again (it is
    a gap, and rare)."""
    roots = [(rn, r["checkout"]) for rn, r in repos.items() if r["checkout"]]
    sroot = git_root(script) if script else None
    if sroot and os.path.realpath(sroot) not in [os.path.realpath(c) for _, c in roots]:
        roots.append((sroot, sroot))
    cache = os.path.join(state_dir(), "unit-gaps.twin")
    rows = {}
    for line in read_text(cache).splitlines():
        f = line.split("\t")
        if len(f) == 5:
            rows[f[0]] = f[1:]
    hit = rows.get(path)
    if hit and hit[0] == _stamp(path) and hit[1] in [l for l, _ in roots] and _stamp(hit[2]) == hit[3] != "":
        return hit[1], hit[2], True
    label, rfile, same = _twin_search(path, name, roots)
    if label and same:
        rows[path] = [_stamp(path), label, rfile, _stamp(rfile)]
        try:
            os.makedirs(state_dir(), exist_ok=True)
            fd, tmp = tempfile.mkstemp(prefix="unit-gaps.twin.", dir=state_dir())
            with os.fdopen(fd, "w") as f:
                f.write("".join("%s\t%s\n" % (k, "\t".join(v)) for k, v in sorted(rows.items())))
            os.replace(tmp, cache)
        except OSError:
            pass
    return label, rfile, same


def in_git(path, repos, script):
    """(ok, why not, repo, gap code): a symlink whose target lies in a git repo, a stackshot-rendered file whose template exists, or a
    regular file byte-identical to a tracked file of the same name in a known repo (schedules.py unit_file_state: a copy that differs
    from its git file is `git-differs`, a file with no git source `not-git`)."""
    real = os.path.realpath(path)
    base, where = os.path.basename(path), tilde(os.path.dirname(path))
    if os.path.islink(path):
        if git_root(real):
            return True, "", repo_of(real, repos), ""
        return False, "%s links to %s, which is not in a git repo" % (base, tilde(real)), None, "not-git"
    m = RENDERED.match(read_text(real).lstrip("\ufeff").split("\n", 1)[0])
    if m:
        roots = [r["checkout"] for r in repos.values() if r["checkout"]] + ([git_root(script)] if script and git_root(script) else [])
        if any(os.path.isfile(os.path.join(rt, m.group(1))) for rt in roots):
            return True, "", None, ""
    label, rfile, same = tracked_twin(real, base, repos, script)
    if label and same:
        return True, "", label if label in repos else None, ""
    if label:
        return False, "%s (%s) is a copy that differs from %s in git" % (base, where, tilde(rfile)), None, "git-differs"
    return False, "%s is a plain file (%s), not a symlink into a git repo and not a copy of a git file" % (base, where), None, "not-git"


def scan(repos):
    """Our timers: [{scope, timer, service, timer_path, service_path, text, ...}] from the two unit folders. A timer whose file (or its
    service's) resolves under /usr/ or /lib/ is a package's and left out; a timer with no readable service unit is left out."""
    rows = []
    for scope, d in (("user", user_dir()), ("system", system_dir())):
        try:
            names = sorted(e for e in os.listdir(d) if e.endswith(".timer") and "@" not in e)
        except OSError:
            continue
        for tname in names:
            tp = os.path.join(d, tname)
            if not os.path.exists(tp) or is_packaged(os.path.realpath(tp)):
                continue
            ttext = read_text(tp)
            sname = last_value(unit_sections(ttext), "Timer", "Unit") or tname[:-6] + ".service"
            sp = os.path.join(d, sname)
            if not os.path.exists(sp):
                if any(os.path.exists(os.path.join(pd, sname)) for pd in PACKAGED_DIRS[scope]):
                    continue
                continue
            if is_packaged(os.path.realpath(sp)):
                continue
            stext = read_text(sp)
            sec = unit_sections(stext)
            script = find_script(stext, repos)
            rows.append({"scope": scope, "timer": tname, "service": sname, "timer_path": tp, "service_path": sp, "ttext": ttext, "stext": stext,
                         "description": (last_value(sec, "Unit", "Description") or "").strip(), "lane": lanewords.norm_lane((last_value(sec, "Unit", "X-Model-Lane") or "").strip().lower()),
                         "project": mapped_project((last_value(sec, "Unit", "X-Project") or "").strip()),
                         "schedule": schedule_of(ttext), "script": script})
    return rows


def owner_of(row, repos):
    """(repo name, repo record) of the repo that holds the unit's script; else the repo that holds the unit file; else the * row."""
    for p in (row["script"], os.path.realpath(row["service_path"])):
        name = repo_of(p, repos) if p else None
        if name:
            return name, repos[name]
    return "*", repos.get("*") or {"project": None, "builder": None, "note": "", "github": GITHUB_DEFAULT}


def gaps_of(row, repos):
    out = []
    if not row["description"]:
        out.append(("no-description", "%s %s" % (row["service"], GAP_WORDS["no-description"])))
    if not row["lane"]:
        out.append(("no-lane", "%s %s" % (row["service"], GAP_WORDS["no-lane"])))
    elif row["lane"] not in LANES:
        out.append(("bad-lane", "%s: X-Model-Lane=%s is none of %s" % (row["service"], row["lane"], ", ".join(LANES))))
    if not row["project"]:
        out.append(("no-project", "%s %s" % (row["service"], GAP_WORDS["no-project"])))
    bad = [(w, c) for ok, w, _, c in (in_git(row["service_path"], repos, row["script"]), in_git(row["timer_path"], repos, row["script"])) if not ok]
    for code in ("git-differs", "not-git"):   # one gap per code, the files' sentences together
        why = [w for w, c in bad if c == code]
        if why:
            out.append((code, "; ".join(why)))
    return out


def find_gaps(repos):
    found = []
    for row in scan(repos):
        repo, rec = owner_of(row, repos)
        for code, text in gaps_of(row, repos):
            found.append({"unit": row["timer"], "scope": row["scope"], "code": code, "text": text, "repo": repo, "builder": rec["builder"],
                          "project": rec["project"], "github": rec["github"], "script": row["script"], "path": row["timer_path"]})
    return found


# ---- check: the watcher -------------------------------------------------------------------------------------------------------------

def client_path():
    if os.environ.get("SALA_STACKSHOT_CLIENT"):
        return os.environ["SALA_STACKSHOT_CLIENT"]
    d = os.environ.get("SALA_STACKSHOT_DIR")   # unset: ~/stackshot; set empty: this box has no stackshot (question-board.py)
    if d is None:
        d = os.path.join(HOME, "stackshot")
    return os.path.join(d, "client.py") if d else ""


def gap_fix(g):
    """The fix for a gap, in words: what to edit or run (a system-scope unit gets root commands, which sala never runs)."""
    svc = g["unit"][:-6] + ".service"
    fix = {"no-description": "add a `Description=<what it does>` line to [Unit] of %s" % svc,
           "no-lane": "add `X-Model-Lane=<lane>` to [Unit] of %s (one of: %s)" % (svc, ", ".join(LANES)),
           "bad-lane": "set `X-Model-Lane=` in [Unit] of %s to one of: %s" % (svc, ", ".join(LANES)),
           "no-project": "run `sala job set-project %s <scope/project>` (the Agents table's Project column shows the scope/project, e.g. team/demo), or add `X-Project=<scope/project>` to [Unit] of %s" % (g["unit"][:-6], svc),
           "not-git": "keep %s and %s in the repo's unit folder and link them into the unit folder (`sala job add` does it for a new job)" % (svc, g["unit"]),
           "git-differs": "make the git file the source (commit the change, or link the unit file to it): `ln -sf <the git file> <the unit file>`, then `systemctl --user daemon-reload`"}[g["code"]]
    if g["scope"] == "system":   # /etc/systemd/system is root's: root commands for a person to run, never run by sala
        root = "sala never runs these; run them as root"
        reload_ = "`sudo systemctl daemon-reload`"
        after = (", then %s; when the unit file is a copy of the git file, re-install it first with "
                 "`sudo install -m 0644 <the git file> /etc/systemd/system/` (%s)" % (reload_, root))
        link = "`sudo systemctl link <the git file>` (or `sudo ln -sf <the git file> <the unit file>`), then %s (%s)" % (reload_, root)
        fix = {"no-description": "edit the git file of %s: add a `Description=<what it does>` line to [Unit]%s" % (svc, after),
               "no-lane": "edit the git file of %s: add `X-Model-Lane=<lane>` to [Unit] (one of: %s)%s" % (svc, ", ".join(LANES), after),
               "bad-lane": "edit the git file of %s: set `X-Model-Lane=` in [Unit] to one of: %s%s" % (svc, ", ".join(LANES), after),
               "no-project": "edit the git file of %s: add `X-Project=<scope/project>` to [Unit] (e.g. team/demo)%s" % (svc, after),
               "not-git": "keep %s and %s in the repo's unit folder (`sala job add --scope system` prints the root line for a new job), then link them: %s" % (svc, g["unit"], link),
               "git-differs": "make the git file the source (commit the change), then link the unit file to it: %s" % link}[g["code"]]
    return fix


def one_line(t):
    return re.sub(r"\s+", " ", t).strip()


def cut(t, n):
    return t if len(t) <= n else t[:n - 3].rstrip() + "..."


def gap_detail(g):
    """The --detail of `post job-gap open`: one line of at most DETAIL_MAX characters. The gap, the files, then the fix; when it is too long the
    head is cut and the fix stays (a fix longer than the limit by itself is cut at its end)."""
    fix = one_line("Fix: %s. Rule: docs/units.md of salamander." % gap_fix(g))
    head = one_line("%s. Timer file %s (%s scope); script %s; owner repo %s." %
                    (g["text"], tilde(g["path"]), g["scope"], tilde(g["script"]) if g["script"] else "not found", g["repo"] if g["repo"] != "*" else "none known"))
    room = DETAIL_MAX - len(fix) - 1
    if room >= 40:
        return cut(head, room) + " " + fix
    return cut(fix, DETAIL_MAX)


def client_argv():
    c = client_path()
    return ([c] if os.access(c, os.X_OK) else [sys.executable, c]) if c else None


def client_has_job_gap():
    """False for a stackshot client.py from before the job-gap call (the file does not name it): the pass then does nothing."""
    return "job-gap" in read_text(client_path())


def board_open(g):
    """The one call that gives a gap to the board: `client.py post job-gap open <timer> <code> --repo <owner/name> --detail <text> --sender sala-unit-gaps`
    (docs/stackshot-contracts.md, interface 26). One open item per timer + code; a repeat prints the same id; the mover is the
    builder of the project that owns the repo, set by stackshot. Returns (exit code, item id, stderr)."""
    argv = client_argv()
    if not argv or not os.path.isfile(client_path()):
        return 127, "", ""
    p = run(argv + ["post", "job-gap", "open", g["unit"], g["code"], "--repo", g["github"], "--detail", gap_detail(g), "--sender", SENDER], 20)
    out = p.stdout.strip().splitlines()
    return p.returncode, (out[0].strip() if out else ""), p.stderr.strip()


def board_close(key):
    """A fixed gap: `client.py post job-gap clear <timer> <code> --sender sala-unit-gaps` closes its item (none open: says so, exit 0).
    Returns (exit code, stderr)."""
    argv = client_argv()
    if not argv or not os.path.isfile(client_path()):
        return 127, ""
    unit, _, code = key.partition("|")
    p = run(argv + ["post", "job-gap", "clear", unit, code, "--sender", SENDER], 20)
    return p.returncode, p.stderr.strip()


def state_file():
    return os.path.join(state_dir(), "unit-gaps.tsv")


def read_state():
    out = {}
    for line in read_text(state_file()).splitlines():
        f = line.split("\t")
        if len(f) >= 3 and f[0]:
            out[f[0]] = (f[1], f[2], f[3] if len(f) > 3 else "")   # builder, time, item id ("" = a record of the message era: no item to close)
    return out


def write_state(st):
    os.makedirs(state_dir(), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix="unit-gaps.tsv.", dir=state_dir())
    with os.fdopen(fd, "w") as f:
        for k, (b, t, i) in sorted(st.items()):
            f.write("%s\t%s\t%s\t%s\n" % (k, b, t, i))
    os.replace(tmp, state_file())


def cmd_check(args):
    post, quiet = "--post" in args, "--quiet" in args
    bad = [a for a in args if a not in ("--post", "--quiet")]
    if bad:
        die("unknown argument %s" % bad[0], "check")
    repos = load_repos()
    gaps = find_gaps(repos)
    if not post:
        for g in gaps:
            say("%s\t%s\t%s\t%s\t%s" % (g["unit"], g["code"], g["builder"] or "-", g["text"], g["github"] or "-"))
        if not gaps and not quiet:
            say("no gaps: every timer of ours has a Description=, an X-Model-Lane=, an X-Project= and a place in git")
        return 1 if gaps else 0
    os.makedirs(state_dir(), exist_ok=True)
    lock = open(os.path.join(state_dir(), "unit-gaps.lock"), "a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0   # another pass is running
    st = read_state()
    now = {"%s|%s" % (g["unit"], g["code"]): g for g in gaps}
    have_client = bool(client_path()) and os.path.isfile(client_path())
    if (now or st) and not have_client:
        if not quiet:
            say("no stackshot client.py on this box (SALA_STACKSHOT_CLIENT, SALA_STACKSHOT_DIR): %d gap(s) not posted" % len(now))
        return 0
    if (now or st) and not client_has_job_gap():
        say("this stackshot client.py has no job-gap call (an old client): %d gap(s) not posted, %d record(s) kept" % (len(now), len(st)))
        return 0
    unposted = [k for k, g in now.items() if not g["github"]]
    if unposted:   # no GitHub owner/name for the gap's repo: stackshot's job-gap call needs one
        if not quiet:
            say("%d gap(s) not posted: no GitHub owner/name for their repo (set the github column in the repo table %s, or SALA_JOB_GITHUB in the sala config)" % (len(unposted), tilde(repos_path())))
    posted, closed, changed, down = 0, 0, False, False
    for key in sorted(st):
        if key in now:
            continue
        if closed >= MAX_POSTS_PER_PASS:
            break
        rc, err = board_close(key)
        if rc != 0:
            say("could not close %s (client exit %s%s): the record stays, tried again at the next pass" % (key.replace("|", " "), rc, ": " + one_line(err)[:200] if err else ""))
            down = True   # a board that does not answer costs one call a pass, not one per gap
            break
        del st[key]
        closed += 1
        changed = True
        say("closed %s (the gap is fixed)" % key.replace("|", " "))
    for key, g in sorted(now.items()):
        if down:
            break
        if not g["github"]:
            continue
        if key in st and st[key][2]:
            continue   # open on the board (a record without an item id is one of the message era: opened again, once)
        if posted >= MAX_POSTS_PER_PASS:
            break
        rc, item, err = board_open(g)
        if rc != 0:
            say("could not open %s on the board (client exit %s%s): tried again at the next pass" % (key.replace("|", " "), rc, ": " + one_line(err)[:200] if err else ""))
            break
        st[key] = (g["builder"] or "-", str(int(time.time())), item or "-")
        posted += 1
        changed = True
        say("opened %s %s on the board as %s (repo %s)" % (g["unit"], g["code"], item or "?", g["github"]))
    if changed:
        write_state(st)
    return 0


# ---- list -------------------------------------------------------------------------------------------------------------------------------

def cmd_list(args):
    if args:
        die("list takes no argument", "list")
    repos = load_repos()
    rows = []
    for row in scan(repos):
        states = [in_git(row["service_path"], repos, row["script"]), in_git(row["timer_path"], repos, row["script"])]
        repo = next((r for _, _, r, _ in states if r), None) or (repo_of(row["script"], repos) if row["script"] else None)
        git_ok = all(ok for ok, _, _, _ in states)
        rows.append((row["timer"][:-6], repo or "-", "; ".join(row["schedule"]) or "-", row["lane"] or "-", row["project"] or "-", "yes" if git_ok else "no", row["scope"]))
    head = ("NAME", "REPO", "SCHEDULE", "LANE", "PROJECT", "IN GIT", "SCOPE")
    w = [max(len(str(x[i])) for x in rows + [head]) for i in range(7)]
    for r in [head] + rows:
        say("  ".join(str(c).ljust(w[i]) for i, c in enumerate(r)).rstrip())
    return 0


# ---- add / remove / relink --------------------------------------------------------------------------------------------------------

def parse_flags(args, spec, verb):
    """spec: {flag: (key, repeatable)}; returns (positional, {key: value or [values]})."""
    pos, opts, i = [], {}, 0
    while i < len(args):
        a = args[i]
        if a.startswith("--"):
            flag, eq, val = a.partition("=")
            if flag not in spec:
                die("unknown option %s" % flag, verb)
            if not eq:
                i += 1
                if i >= len(args):
                    die("%s needs a value" % flag, verb)
                val = args[i]
            key, rep = spec[flag]
            if rep:
                opts.setdefault(key, []).append(val)
            else:
                opts[key] = val
        else:
            pos.append(a)
        i += 1
    return pos, opts


def valid_schedule(s):
    """→ (line 'OnX=value', error). A bare expression is an OnCalendar one; 'OnBootSec=5min' is taken as written."""
    s = s.strip()
    m = re.match(r"^(On\w+)=(.+)$", s)
    key, val = (m.group(1), m.group(2).strip()) if m else ("OnCalendar", s)
    if key not in ONKEYS:
        return None, "%s is not a timer key sala job takes (%s)" % (key, ", ".join(ONKEYS))
    if not val or "\n" in val:
        return None, "empty or multi-line schedule"
    an = shlex.split(os.environ.get("SALA_JOB_ANALYZE") or "systemd-analyze")
    if run(an + ["--version"], 5).returncode == 0:   # validated when systemd-analyze is on the box; otherwise taken as written
        p = run(an + (["calendar", val] if key == "OnCalendar" else ["timespan", val]), 8)
        if p.returncode != 0:
            return None, "systemd does not accept %s=%s (%s)" % (key, val, one_line(p.stderr or p.stdout)[:120])
    return "%s=%s" % (key, val), None


def exec_line(script, args_text):
    p = script.replace(HOME + "/", "%h/", 1) if script.startswith(HOME + "/") else script
    if os.access(script, os.X_OK):
        base = p
    elif script.endswith(".py"):
        base = "%h/.local/bin/uv run --script " + p   # Python goes through uv
    elif script.endswith(".sh"):
        base = "/bin/bash " + p
    else:
        return None
    return base + ((" " + args_text) if args_text else "")


def folder_of(rec, name, scope):
    d = rec["user_dir"] if scope == "user" else rec["system_dir"]
    return d.replace("{name}", name) if d else None


def checkout_for(rec, repo, opts, verb):
    ck = opts.get("checkout")
    if ck:
        ck = os.path.realpath(os.path.expanduser(ck))
        if not os.path.exists(os.path.join(ck, ".git")):
            die("--checkout %s is not a git checkout" % ck, verb)
        return ck
    if rec["flow"] == "pr":
        prod = rec["checkout"]
        die("%s takes changes by branch and pull request, and nobody edits its production checkout (%s): make a worktree and pass it as --checkout\n"
            "  git -C %s fetch origin && git -C %s worktree add ../%s-<topic> -b <topic> origin/main" % (repo, tilde(prod or ""), prod, prod, repo), verb)
    if not rec["checkout"] or not os.path.exists(os.path.join(rec["checkout"], ".git")):
        die("the %s checkout %s is not there" % (repo, tilde(rec["checkout"] or "")), verb)
    return rec["checkout"]


def git_steps(ck, rec, repo, paths, message, name):
    rels = [os.path.relpath(p, ck) for p in paths]
    q = shlex.quote
    say("git status in %s:" % tilde(ck))
    st = run(["git", "-C", ck, "status", "--short", "--"] + rels, 10)
    for l in (st.stdout.splitlines() or ["  (git status printed nothing)"]):
        say("  " + l)
    say("to commit (nothing is committed or pushed here):")
    say("  git -C %s add -- %s" % (q(ck), " ".join(q(r) for r in rels)))
    say("  git -C %s commit -m %s" % (q(ck), q(message)))
    if rec["flow"] == "main":
        say("  git -C %s pull --rebase --autostash && git -C %s push   # %s commits straight to main" % (q(ck), q(ck), repo))
    else:
        say("  git -C %s push -u origin HEAD" % q(ck))
        say("  (cd %s && gh pr create --fill)   # %s goes by branch and pull request; the releaser merges it" % (q(ck), repo))
    if rec["note"]:
        say("note: " + rec["note"].replace("NAME", name))


def link_force(target, link):
    tmp = link + ".tmp.%d" % os.getpid()
    os.symlink(target, tmp)
    os.replace(tmp, link)


def ctl(*args):
    return run(systemctl_argv("--user", *args), 30)


def cmd_add(args):
    spec = {"--repo": ("repo", 0), "--script": ("script", 0), "--schedule": ("schedule", 1), "--description": ("description", 0), "--lane": ("lane", 0),
            "--project": ("project", 0), "--note": ("note", 0), "--args": ("args", 0), "--scope": ("scope", 0), "--checkout": ("checkout", 0)}
    pos, o = parse_flags(args, spec, "add")
    if len(pos) != 1:
        die("give the job a name (one word, lowercase)", "add")
    name = pos[0]
    repos = load_repos()
    scope = o.get("scope", "user")
    if scope not in ("user", "system"):
        die("--scope is user or system", "add")
    if not NAME_RE.match(name):
        die("name %r: lowercase letters, digits, - _ . only, starting with a letter or digit, at most 60 characters" % name, "add")
    for flag, key in (("--repo", "repo"), ("--script", "script"), ("--schedule", "schedule"), ("--description", "description"), ("--lane", "lane"), ("--project", "project")):
        if not o.get(key):
            die("%s is required" % flag, "add")
    repo = o["repo"]
    if repo not in repos or repo == "*":
        die("unknown repo %r (known: %s)" % (repo, repos_phrase()), "add")
    rec = repos[repo]
    desc = o["description"].strip()
    if not desc or "\n" in desc or "\r" in desc or len(desc) > 200:
        die("--description is one line of 1 to 200 characters (it is shown on the Overview's Schedules tab)", "add")
    o["lane"] = lanewords.norm_lane(o["lane"])   # max and team are accepted: the unit is written with the lane's current code
    if o["lane"] not in LANES:
        die("--lane %r is none of: %s (max and team are read as subscription-1 and subscription-2)" % (o["lane"], ", ".join(LANES)), "add")
    if not PROJECT_RE.match(o["project"]) or len(o["project"]) > 80:
        die("--project %r is not scope/project (lower case, as the Agents table's Project column shows it: for example team/demo, team/web-app)" % o["project"], "add")
    note = o.get("note", "").strip()
    if "--note" in args and (not note or "\n" in note or len(note) > 300):
        die("--note is one line of at most 300 characters (leave the flag out for none)", "add")
    script = os.path.realpath(os.path.expanduser(o["script"]))
    if not os.path.isfile(script):
        die("--script %s does not exist" % o["script"], "add")
    args_text = o.get("args", "").strip()
    if "\n" in args_text:
        die("--args is one line", "add")
    ex = exec_line(script, args_text)
    if ex is None:
        die("--script %s is not executable and is neither .py nor .sh: chmod +x it" % tilde(script), "add")
    sched = []
    for s in o["schedule"]:
        line, err = valid_schedule(s)
        if err:
            die("--schedule: " + err, "add")
        sched.append(line)
    folder = folder_of(rec, name, scope)
    if not folder:
        why = rec["note"] if rec["user_dir"] is None and scope == "user" else "it has no %s-scope unit folder in the repo table (%s)" % (scope, tilde(repos_path()))
        die("repo %s has no convention sala writes units into: %s" % (repo, why), "add", 1)
    ck = checkout_for(rec, repo, o, "add")
    target = os.path.join(ck, folder)
    names = (name + ".service", name + ".timer")
    taken = [p for n in names for p in [os.path.join(target, n), os.path.join(user_dir(), n), os.path.join(system_dir(), n)] +
             [os.path.join(d, n) for d in PACKAGED_DIRS["user"] + PACKAGED_DIRS["system"]] if os.path.lexists(p)]
    if taken:
        die("the name %r is taken: %s exists" % (name, tilde(taken[0])), "add", 1)
    service = ["[Unit]", "Description=" + desc, "X-Model-Lane=" + o["lane"], "X-Project=" + o["project"]] + (["X-Model-Note=" + note] if note else []) + \
              ["", "[Service]", "Type=oneshot", "ExecStart=" + ex, ""]
    timer = ["[Unit]", "Description=%s (timer)" % desc, "", "[Timer]"] + sched + \
            (["Persistent=true"] if any(s.startswith("OnCalendar=") for s in sched) else []) + ["Unit=%s.service" % name, "", "[Install]", "WantedBy=timers.target", ""]
    os.makedirs(target, exist_ok=True)
    written = []
    for n, lines in zip(names, (service, timer)):
        p = os.path.join(target, n)
        with open(p, "x", encoding="utf-8") as f:
            f.write("\n".join(lines))
        written.append(p)
    say("wrote %s" % ", ".join(tilde(p) for p in written))
    if not any(re.search(r"\b\d{1,2}:\d{2}\b.*\b[A-Za-z]+/[A-Za-z_]+\b", s) for s in sched if s.startswith("OnCalendar=")) and any(s.startswith("OnCalendar=") for s in sched):
        say("note: an OnCalendar time with no zone runs on the box clock; add a zone name after the time (for example UTC) to pin it to that zone")
    if scope == "system":
        say("system scope: sala never uses root. Run this yourself, as root, in the web UI's Shell, to install it:")
        say("  sudo install -m 0644 %s /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now %s.timer" %
            (" ".join(shlex.quote(p) for p in written), name))
    else:
        os.makedirs(user_dir(), exist_ok=True)
        links = []
        for p in written:
            link = os.path.join(user_dir(), os.path.basename(p))
            os.symlink(p, link)
            links.append(link)
        say("linked %s" % ", ".join(tilde(l) for l in links))
        for step in (("daemon-reload",), ("enable", "--now", name + ".timer")):
            r = ctl(*step)
            if r.returncode != 0:
                print("sala job add: `systemctl --user %s` failed (exit %s): %s" % (" ".join(step), r.returncode, one_line(r.stderr)[:300]), file=sys.stderr)
                say("the files and links stay; fix the cause and run the failed step, or undo with `sala job remove %s`" % name)
                git_steps(ck, rec, repo, written, "%s: %s (sala job add)" % (name, desc), name)
                return 1
        say("enabled and started %s.timer (user scope)" % name)
    git_steps(ck, rec, repo, written, "%s: %s (sala job add)" % (name, desc), name)
    return 0


def cmd_remove(args):
    pos, o = parse_flags(args, {"--checkout": ("checkout", 0)}, "remove")
    if len(pos) != 1:
        die("give the job's name", "remove")
    name = pos[0]
    repos = load_repos()
    scope = "user" if os.path.lexists(os.path.join(user_dir(), name + ".timer")) else "system" if os.path.lexists(os.path.join(system_dir(), name + ".timer")) else None
    if scope is None:
        die("no job %r: no %s.timer in %s or %s" % (name, name, tilde(user_dir()), system_dir()), "remove", 1)
    base = user_dir() if scope == "user" else system_dir()
    files = [os.path.join(base, name + e) for e in (".service", ".timer")]
    files = [f for f in files if os.path.lexists(f)]
    if any(is_packaged(os.path.realpath(f)) for f in files):
        die("%s is a package's unit, not ours: sala job never removes it" % name, "remove", 1)
    # where the repo copies are, and the checkout they go from
    repo_files, ck_repo = [], None
    for f in files:
        real = os.path.realpath(f)
        r = repo_of(real, repos) if os.path.islink(f) else None
        if r:
            ck_repo = r
            repo_files.append(real)
    if scope == "system":   # the root-installed files are plain copies: the repo's own are looked for by name in each repo's system folder
        for rn, rr in repos.items():
            if rr["checkout"] and rr["system_dir"]:
                found = [os.path.join(rr["checkout"], rr["system_dir"], os.path.basename(f)) for f in files]
                found = [p for p in found if os.path.isfile(p)]
                if found:
                    ck_repo, repo_files = rn, found
                    break
    if repo_files:
        rec = repos[ck_repo]
        prod = rec["checkout"]
        if rec["flow"] == "pr":
            if not o.get("checkout"):
                die("%s goes by branch and pull request: pass the worktree as --checkout (the copy there is deleted, not the production one)" % ck_repo, "remove")
            ck = checkout_for(rec, ck_repo, o, "remove")
            if os.path.realpath(ck) == prod:
                die("--checkout is the production checkout of %s; use a worktree" % ck_repo, "remove")
            where = [os.path.join(ck, os.path.relpath(p, git_root(p))) for p in repo_files]
        else:
            ck = os.path.realpath(os.path.expanduser(o["checkout"])) if o.get("checkout") else prod
            where = list(repo_files)
    if scope == "user":
        r = ctl("disable", "--now", name + ".timer")
        if r.returncode != 0:
            say("note: systemctl --user disable --now %s.timer said: %s" % (name, one_line(r.stderr)[:200]))
        else:
            say("disabled and stopped %s.timer" % name)
    if scope == "user":
        # `systemctl disable` removes the link of a linked unit file itself (real systemd does, for the .timer sala add linked): look before each unlink
        for f in files:
            if os.path.lexists(f):
                os.unlink(f)
                say("unlinked %s" % tilde(f))
            else:
                say("%s was already removed by systemctl disable" % tilde(f))
        ctl("daemon-reload")
        # a timer that failed to start (or was left loaded as failed) would otherwise stay in `systemctl --user` once its file is gone; its errors do not matter
        ctl("reset-failed", name + ".timer", name + ".service")
    else:
        say("system scope: sala never uses root. Run this yourself, as root, in the web UI's Shell:")
        say("  sudo systemctl disable --now %s.timer && sudo rm %s && sudo systemctl daemon-reload" % (name, " ".join(shlex.quote(f) for f in files)))
    if not repo_files:
        say("no copy in a known repo was linked from there: nothing to delete from git")
        return 0
    gone = []
    for p in where:
        if os.path.lexists(p):
            os.unlink(p)
            gone.append(p)
            say("deleted %s" % tilde(p))
    if gone:
        git_steps(ck, rec, ck_repo, gone, "%s: remove the job (sala job remove)" % name, name)
    return 0


def cmd_relink(args):
    pos, _ = parse_flags(args, {}, "relink")
    if len(pos) != 1:
        die("give the job's name", "relink")
    name = pos[0]
    repos = load_repos()
    done = 0
    for e in (".service", ".timer"):
        link = os.path.join(user_dir(), name + e)
        if not os.path.islink(link):
            die("%s is not a link (nothing to relink)" % tilde(link), "relink", 1)
        real = os.path.realpath(link)
        root = git_root(real)
        repo = checkout_of_root(root, repos)
        if not repo:
            die("%s links into no known repo" % tilde(link), "relink", 1)
        prod = repos[repo]["checkout"]
        new = os.path.join(prod, os.path.relpath(real, os.path.realpath(root)))
        if os.path.realpath(root) == prod:
            say("%s already links into the production checkout" % tilde(link))
            continue
        if not os.path.isfile(new) or read_text(new) != read_text(real):
            die("%s is not in the production checkout %s yet, or differs: wait for the release to deploy" % (os.path.relpath(real, root), tilde(prod)), "relink", 1)
        link_force(new, link)
        say("relinked %s -> %s" % (tilde(link), tilde(new)))
        done += 1
    if done:
        r = ctl("daemon-reload")
        say("daemon-reload %s" % ("done" if r.returncode == 0 else "failed: " + one_line(r.stderr)[:200]))
    return 0


def with_project(text, project):
    """The service text with `X-Project=<project>` in [Unit]: the line replaced where there is one, else added after X-Model-Lane= (or Description=,
    or the end of [Unit]). Everything else is kept byte for byte."""
    lines = text.split("\n")
    start = next((i for i, l in enumerate(lines) if l.strip() == "[Unit]"), None)
    if start is None:
        return None
    end = next((i for i in range(start + 1, len(lines)) if lines[i].strip().startswith("[")), len(lines))
    new = "X-Project=" + project
    for i in range(start + 1, end):
        if lines[i].strip().startswith("X-Project="):
            lines[i] = new
            return "\n".join(lines)
    at = end
    for key in ("X-Model-Lane=", "Description="):
        hit = [i for i in range(start + 1, end) if lines[i].strip().startswith(key)]
        if hit:
            at = hit[-1] + 1
            break
    else:   # neither line: just before the blank lines that close [Unit]
        while at > start + 1 and not lines[at - 1].strip():
            at -= 1
    lines.insert(at, new)
    return "\n".join(lines)


def cmd_set_project(args):
    quiet = "--quiet" in args   # no git steps (the backfill script prints one set for all its jobs)
    pos, o = parse_flags([a for a in args if a != "--quiet"], {"--checkout": ("checkout", 0)}, "set-project")
    if len(pos) != 2:
        die("give the job's name and its project", "set-project")
    name, project = pos
    if not PROJECT_RE.match(project) or len(project) > 80:
        die("project %r is not scope/project (lower case, as the Agents table's Project column shows it: for example team/demo, team/web-app)" % project, "set-project")
    repos = load_repos()
    svc, scope = os.path.join(user_dir(), name + ".service"), "user"
    if not os.path.lexists(svc):   # a system-scope job whose unit file links to its git file is edited the same way (no root: the git file is the user's)
        svc, scope = os.path.join(system_dir(), name + ".service"), "system"
    if not os.path.lexists(svc):
        die("no job %r: no %s.service in %s or %s" % (name, name, tilde(user_dir()), tilde(system_dir())), "set-project", 1)
    real = os.path.realpath(svc)
    if is_packaged(real):
        die("%s is a package's unit, not ours" % name, "set-project", 1)
    if not os.path.islink(svc) or not git_root(real):
        why = in_git(svc, repos, None)[1] or "its unit file is not a link into a git repo"
        die("%s: %s; put it in git first (`sala job check` says how), or, for a unit rendered from a template, edit the template" % (name, why), "set-project", 1)
    repo = repo_of(real, repos)
    if not repo:
        die("%s: its git file %s is in none of the repos in the repo table (%s)" % (name, tilde(real), tilde(repos_path())), "set-project", 1)
    rec = repos[repo]
    if rec["flow"] == "pr":
        if not o.get("checkout"):
            die("%s goes by branch and pull request: pass the worktree as --checkout (the copy there is edited, not the production one)" % repo, "set-project")
        ck = checkout_for(rec, repo, o, "set-project")
        if os.path.realpath(ck) == rec["checkout"]:
            die("--checkout is the production checkout of %s; use a worktree" % repo, "set-project")
        target = os.path.join(ck, os.path.relpath(real, git_root(real)))
    else:
        ck = os.path.realpath(os.path.expanduser(o["checkout"])) if o.get("checkout") else rec["checkout"]
        target = real
    if not os.path.isfile(target):
        die("%s is not in %s (the worktree is not on a branch that has the job)" % (tilde(target), tilde(ck)), "set-project", 1)
    text = read_text(target)
    out = with_project(text, project)
    if out is None:
        die("%s has no [Unit] section" % tilde(target), "set-project", 1)
    if out == text:
        say("%s already has X-Project=%s: nothing to do" % (name, project))
        return 0
    tmp = target + ".tmp.%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(out)
    os.replace(tmp, target)
    say("set X-Project=%s in %s" % (project, tilde(target)))
    if scope == "user":   # (systemd reads no X- key: the reload only keeps `systemctl cat` current; a system unit needs root for it and does not need it)
        ctl("daemon-reload")
    if not quiet:
        git_steps(ck, rec, repo, [target], "%s: X-Project=%s (sala job set-project)" % (name, project), name)
    return 0


def main(argv):
    verb = argv[0] if argv else ""
    fn = {"add": cmd_add, "list": cmd_list, "remove": cmd_remove, "relink": cmd_relink, "check": cmd_check, "set-project": cmd_set_project}.get(verb)
    if fn is None:
        print("usage: sala job add|list|remove|relink|check|set-project …  (sala job --help)", file=sys.stderr)
        return 2
    return fn(argv[1:]) or 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
