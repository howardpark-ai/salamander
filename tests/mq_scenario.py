"""Scenario test for `salamander mq` (lib/mq/, lib/mq.sh, docs/mq.md), run by tests/mq.sh.

Real git against a local bare repository standing in for origin; a fake `gh`, a fake `salamander` (the CI-run poller's reader) and a fake `systemd-run` on a fake
PATH that answer from files and log EVERY call. The fake CI is a function of the pushed tree: an entry whose tree holds a BAD_* file fails, one holding RERUN reports an
older failed `suites` run and a newer passing one. Nothing is killed and there is no tmux: a driver crash is injected with MQ_CRASH_AT=<phase> (the driver exits at that
phase), and the drivers the fake systemd-run starts end on their own (the line empties).

The queue is a chain: one entry per PR, each built on the head of the entry ahead, all tested side by side and merged in line order. The entry records are still called
groups on disk (groups/g<seq>.json, branches queue/main/g<seq>), which is the name the tests use for the files.

What it covers: shadow mode first, and the merge step below it. A PR passes and origin's main is untouched (the queue branch carried the merge commit, then was deleted), with the number of
calls per entry asserted from the fakes' logs AND from the entry's record (one GraphQL read to build, one before the verdict counts, and one check-runs read when the poller's file shows
the run going and then finished; with no poller file, check-runs reads with the ETag and a 304); a failing entry fails its PR alone; a PR that conflicts with main or with the PR ahead of
it is ejected and the rest go on; the snapshot-only conflict hook; a closed, a draft, a wrong-base and a missing PR are ejected at the GraphQL read; a head that moved after the read is
ejected; inflight_max from main's config (a PR cannot change its own rules); an invalid config blocks without spinning and clears when fixed; gh failing (retried, then given up); no verdict
in time; the newest run of a check wins; a crash at every phase (building, built, pushed, testing, verdict, cleaning, done) and the recovery by a fresh driver; the driver lock (a second
driver leaves, a live driver means `add` starts none, a dead one means it does); a dropped PR; `wait` exit codes; the modes (off refuses, on is open; with ON_OPEN False on refuses);
`status`, `status --json`, `doctor`.
The merge step (mode on, which `mq add` accepts; most scenarios add in shadow, then rewrite the host file): the head of the last entry goes to main as a fast-forward and the PRs are merged,
in line order, with a commit status per PR and no comment; main moved, a PR changed or closed before the push, a crash after the push, a deploy lock held, a push that keeps failing (the
queue pauses, resume goes on), pause and resume, the rebuild limit, a failing status call that does not stop the queue.
Refusing a PR: a PR whose own checks failed (or were cancelled, timed out) is ejected at the join with `refused: a check failed: <name>=fail`, one whose check fails while its entry is tested is
ejected before the verdict counts (shadow: the others stay tested; mode on: told, stale, rebuilt), `pr_required` narrows which checks count, and a PR that conflicts with a main that moved
meanwhile is ejected as `refused: conflicts with main`, while one that still merges, or conflicts only on the files the hook mends, is not.
Replay (`sc_replay_*`, docs/mq.md "Replay"): the host key `replay` serves the rules and the PR facts from a file (a PR that GitHub calls MERGED still joins, no GraphQL call), heads are fetched
by sha (one on no branch), a base or prefix outside practice/ blocks, mode on is refused, nothing but queue/practice/ branches is pushed (a pre-receive hook on origin logs every ref) and no
status or comment is posted, the unit takes the run and case, ci = skip ends at `built` (wait exit 4), and `mq doctor` lists only its own queue prefix.
The chain (`sc_chain_*`): three PRs stacked and merged in order; the middle one failing is failed alone and the one behind it is rebuilt on the first, which is still unmerged; the first failing
sends both behind it back; a conflict with the PR ahead; a dropped PR; `inflight_max` limiting the entries in flight, six by default; shadow. A fake CI held open by a file (`ci.never`)
makes "all entries are testing at once" a state the test waits for instead of a race.
Group mode is gone (`sc_chain_config`, `sc_retired_keys`, `sc_legacy_group_state`): `queue_mode = "chain"` is silent, `group_max` and `bisect` are ignored with a warning that names the fix,
`queue_mode = "group"` blocks the queue and names the fix, and the state a group-mode driver left on disk (a multi-PR record, the parent and halves of a bisect, a merge whose push had happened)
does not wedge the queue after the upgrade.
The merge commit identity (`sc_identity`): in a throwaway HOME whose global git config holds a fake person, the commits carry the work clone's own identity (an includeIf rule) or the host file's git_name
and git_email, never the global one; with only the global identity, or nothing, resolving, the queue is blocked with a refusal that names git_name and git_email (journal, `mq wait`, `mq doctor`), no traceback.
The other scenarios get an identity for the work clone from GIT_CONFIG_COUNT in the World's environment.
Not covered (later): the rerun of a flaky check, the sweep of stale queue branches, the push-run poller file.

    bash tests/mq.sh  (runs this file)  → exit 0 / 1"""
import fcntl
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "lib", "mq"))

fails, ran = [], []


def check(name, cond, got=None):
    ran.append(name)
    if not cond:
        fails.append(name)
        print("FAIL %s" % name + (": %s" % str(got)[:700] if got is not None else ""))


signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))      # tests/run.sh's cancel: leave through the finally below, which removes the folder
T = tempfile.mkdtemp(prefix="sala-mq.")
_lock = os.open(T, os.O_RDONLY)
fcntl.flock(_lock, fcntl.LOCK_EX)          # systemd-tmpfiles' ageing honours flock
BIN = os.path.join(T, "bin")
os.makedirs(BIN)

# ---- the fakes ---------------------------------------------------------------------------------------------------------------------------------

FAKE_COMMON = r'''
import json, os, re, subprocess, sys
F = os.environ["FAKE_DIR"]
def rd(name, default=""):
    try:
        return open(os.path.join(F, name)).read().strip()
    except OSError:
        return default
def wr(name, text):
    open(os.path.join(F, name), "w").write(text)
def log(s):
    with open(os.path.join(F, "calls"), "a") as f:
        f.write(s + "\n")
def bump(name):
    n = int(rd(name, "0") or 0) + 1
    wr(name, str(n))
    return n
'''

FAKE_GH = "#!" + sys.executable + "\n" + FAKE_COMMON + r'''
import hashlib
a = sys.argv[1:]
if a[:2] == ["api", "graphql"]:
    q = next(x for x in a if x.startswith("query="))
    nums = [int(x) for x in re.findall(r"pullRequest\(number: (\d+)\)", q)]
    n = bump("graphql.count")
    if n <= int(rd("graphql.fail", "0") or 0):
        log("gh graphql FAIL n=%d" % n)
        print("HTTP 502 boom", file=sys.stderr)
        sys.exit(1)
    prs = json.load(open(os.path.join(F, "prs.json")))
    repo = {}
    for k in nums:
        p = prs.get(str(k))
        if p is None:
            repo["p%d" % k] = None
            continue
        nodes = [dict(c, __typename="CheckRun" if "name" in c else "StatusContext") for c in p.get("checks", [])]      # the PR head's checks, as the rollup lists them
        repo["p%d" % k] = {"number": k, "state": p["state"], "isDraft": p["draft"], "headRefOid": p["head"], "headRefName": p["branch"],
                           "baseRefName": p["base"], "headRepositoryOwner": {"login": p["owner"]},
                           "commits": {"nodes": [{"commit": {"oid": p["head"], "statusCheckRollup": {"contexts": {"nodes": nodes}} if nodes else None}}]}}
    log("gh graphql %s" % ",".join(map(str, nums)))
    print(json.dumps({"data": {"repository": repo}}))
    sys.exit(0)
if a and a[0] == "api" and "/check-runs" in a[1]:
    sha = re.search(r"commits/([0-9a-f]+)/check-runs", a[1]).group(1)
    inm = ""
    for i, x in enumerate(a):
        if x == "-H" and a[i + 1].startswith("If-None-Match: "):
            inm = a[i + 1][len("If-None-Match: "):]
    n = bump("cr." + sha)
    tree = subprocess.run(["git", "--git-dir", rd("origin"), "ls-tree", "-r", "--name-only", sha], capture_output=True, text=True).stdout.split()
    names = {os.path.basename(t) for t in tree}
    bad = any(t.startswith("BAD_") for t in names)
    pending = os.path.exists(os.path.join(F, "ci.never")) or n <= int(rd("ci.pending", "0") or 0)
    runs = [{"id": 10, "name": "changes", "status": "completed", "conclusion": "success", "app": {"id": 1}}]
    if "RERUN" in names:
        runs.append({"id": 9, "name": "suites", "status": "completed", "conclusion": "failure", "app": {"id": 1}, "html_url": "https://ci.example/runs/9"})
    runs.append({"id": 11, "name": "suites", "status": "in_progress" if pending else "completed",
                 "conclusion": None if pending else ("failure" if bad else "success"), "app": {"id": 1}, "html_url": "https://ci.example/runs/11"})
    body = json.dumps({"total_count": len(runs), "check_runs": runs})
    etag = '"%s"' % hashlib.md5(body.encode()).hexdigest()
    if inm and inm == etag:
        log("gh check-runs %s n=%d inm=yes 304" % (sha[:7], n))
        sys.stdout.write("HTTP/2.0 304 Not Modified\r\nEtag: %s\r\n\r\n" % etag)
        sys.exit(1)
    log("gh check-runs %s n=%d inm=%s 200" % (sha[:7], n, "yes" if inm else "no"))
    sys.stdout.write("HTTP/2.0 200 OK\r\nContent-Type: application/json\r\nEtag: %s\r\n\r\n%s\n" % (etag, body))
    sys.exit(0)
if a and a[0] == "api" and re.match(r"repos/[^/]+/[^/]+/statuses/[0-9a-f]+$", a[1]):
    f = {x.split("=", 1)[0]: x.split("=", 1)[1] for x in a[2:] if "=" in x}
    if os.path.exists(os.path.join(F, "status.fail")):
        log("gh status FAIL %s" % a[1].rsplit("/", 1)[1][:7])
        print("HTTP 422 boom", file=sys.stderr)
        sys.exit(1)
    log("gh status %s %s %s" % (a[1].rsplit("/", 1)[1][:7], f.get("state"), f.get("description")))
    wr("status.context", f.get("context", ""))
    print("{}")
    sys.exit(0)
if a and a[0] == "api" and re.match(r"repos/[^/]+/[^/]+/issues/\d+/comments$", a[1]):
    f = {x.split("=", 1)[0]: x.split("=", 1)[1] for x in a[2:] if "=" in x}
    log("gh comment %s" % a[1].split("/")[4])
    with open(os.path.join(F, "comments"), "a") as c:
        c.write("%s\t%s\n" % (a[1].split("/")[4], f.get("body", "").replace("\n", " ")))
    print("{}")
    sys.exit(0)
log("gh UNEXPECTED " + " ".join(a))
sys.exit(9)
'''

FAKE_SALAMANDER = "#!" + sys.executable + "\n" + FAKE_COMMON + r'''
a = sys.argv[1:]
if a[:1] != ["ci-runs"]:
    log("salamander UNEXPECTED " + " ".join(a))
    sys.exit(9)
sha = a[a.index("--sha") + 1]
mode = rd("ci.mode", "unavailable")
n = bump("sal.count")
if mode == "unavailable":
    log("salamander ci-runs unavailable")
    print("ci-runs: no file", file=sys.stderr)
    sys.exit(3)
if mode == "none":
    log("salamander ci-runs none")
    print(json.dumps({"repo": a[1], "updated": 1, "runs": []}))
    sys.exit(0)
going = int(mode.split(":")[1])
st, co = ("in_progress", None) if n <= going else ("completed", "success")
log("salamander ci-runs %s" % st)
print(json.dumps({"repo": a[1], "updated": 1, "runs": [{"id": 77, "name": "tests", "head_sha": sha, "head_branch": "queue/main/gX", "event": "push", "status": st,
                                                          "conclusion": co, "html_url": "https://ci.example/runs/77", "run_attempt": 1}]}))
'''

FAKE_SYSTEMD_RUN = "#!" + sys.executable + "\n" + FAKE_COMMON + r'''
a = sys.argv[1:]
env = dict(os.environ)
unit, i, cmd = "", 0, []
while i < len(a):
    x = a[i]
    if x in ("--unit", "--description"):
        if x == "--unit":
            unit = a[i + 1]
        i += 2
        continue
    if x.startswith("--setenv="):
        k, _, v = x[len("--setenv="):].partition("=")
        env[k] = v
    elif not x.startswith("--"):
        cmd = a[i:]
        break
    i += 1
log("systemd-run unit=%s cmd=%s" % (unit, " ".join(os.path.basename(c) if j == 0 else c for j, c in enumerate(cmd[:1])) + " " + " ".join(cmd[-3:])))
if os.path.exists(os.path.join(F, "spawn")):
    out = open(os.path.join(F, "driver.out"), "a")
    subprocess.Popen(cmd, env=env, stdin=subprocess.DEVNULL, stdout=out, stderr=out, start_new_session=True)
if os.path.exists(os.path.join(F, "systemd-run.race")):
    # the racing add's driver takes the lock after this call's own liveness check: a holder (it frees the lock itself after 3 s) takes it after the delay in the file
    lockp = os.path.join(env.get("XDG_STATE_HOME", ""), "mergequeue", "acme__widgets", "driver.lock")
    holder = "import fcntl, os, sys, time; time.sleep(float(sys.argv[2])); fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644); fcntl.flock(fd, fcntl.LOCK_EX); time.sleep(3)"
    subprocess.Popen([sys.executable, "-c", holder, lockp, open(os.path.join(F, "systemd-run.race")).read().strip() or "0"],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    print("Failed to start transient service unit: Unit %s already exists." % unit, file=sys.stderr)
    sys.exit(1)
if os.path.exists(os.path.join(F, "systemd-run.fail")):
    print("Failed to start transient service unit: Unit %s already exists." % unit, file=sys.stderr)
    sys.exit(1)
'''

for name, text in (("gh", FAKE_GH), ("salamander", FAKE_SALAMANDER), ("systemd-run", FAKE_SYSTEMD_RUN)):
    p = os.path.join(BIN, name)
    with open(p, "w") as f:
        f.write(text)
    os.chmod(p, 0o755)

BASE_ENV = {k: v for k, v in os.environ.items() if not k.startswith(("SALA_", "MQ_", "XDG_", "CLAUDE", "ANTHROPIC", "TMUX"))}
REPO = "acme/widgets"
SPAWNED = []      # worlds whose fake systemd-run starts real drivers: their locks are waited for before the folder goes


def run(cmd, env, cwd=None, timeout=120):
    return subprocess.run(cmd, env=env, cwd=cwd, capture_output=True, text=True, timeout=timeout)


class World:
    def __init__(self, name, mode="shadow", config=None, spawn=False, host_extra="", ci_mode="unavailable", pending=0, files=None):
        self.d = os.path.join(T, name)
        self.fake = os.path.join(self.d, "fake")
        self.state = os.path.join(self.d, "state")
        self.cfg = os.path.join(self.d, "cfg")
        self.home = os.path.join(self.d, "home")
        self.origin = os.path.join(self.d, "origin.git")
        self.src = os.path.join(self.d, "src")
        for p in (self.fake, self.cfg, self.home):
            os.makedirs(p)
        self.env = dict(BASE_ENV, HOME=self.home, XDG_STATE_HOME=self.state, XDG_CONFIG_HOME=self.cfg, FAKE_DIR=self.fake,
                        PATH=BIN + os.pathsep + BASE_ENV.get("PATH", "/usr/bin:/bin"), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
                        GIT_CONFIG_COUNT="2", GIT_CONFIG_KEY_0="user.name", GIT_CONFIG_VALUE_0="Queue Test",       # an identity the work clone resolves (the queue refuses to commit without one);
                        GIT_CONFIG_KEY_1="user.email", GIT_CONFIG_VALUE_1="queue@example.invalid",                 # the identity scenarios (sc_identity_*) build their own environment
                        GIT_AUTHOR_NAME="Dana", GIT_AUTHOR_EMAIL="dana@example.com", GIT_COMMITTER_NAME="Dana", GIT_COMMITTER_EMAIL="dana@example.com",
                        MQ_TICK_SECS="0.02", MQ_POLL_SECS="0.02", MQ_BACKOFF_SECS="0", MQ_WAIT_SLEEP="0.02", MQ_MAX_FAILS="3", MQ_WAIT_CAP_SECS="40")
        self.git(self.d, "init", "-q", "--bare", "-b", "main", self.origin)
        self.git(self.d, "clone", "-q", self.origin, self.src)
        self.git(self.src, "symbolic-ref", "HEAD", "refs/heads/main")
        base = {"README.md": "widgets\n", "app/core.py": "def core():\n    return 1\n", "tests/tool_text.snapshot.json": '{"a": 1,\n "b": 2}\n'}
        base.update(files or {})
        if config is not None:
            base[".github/mergequeue.toml"] = config
        self.write_files(base)
        self.git(self.src, "add", "-A")
        self.git(self.src, "commit", "-q", "-m", "initial")
        self.git(self.src, "push", "-q", "origin", "main")
        self.put("origin", self.origin)
        self.put("ci.mode", ci_mode)
        self.put("ci.pending", str(pending))
        self.put("prs.json", "{}")
        if spawn:
            self.put("spawn", "1")
            SPAWNED.append(self)
        if mode:
            os.makedirs(os.path.join(self.cfg, "mergequeue"), exist_ok=True)
            with open(os.path.join(self.cfg, "mergequeue", "acme__widgets.toml"), "w") as f:
                f.write('mode = "%s"\nremote = "%s"\n%s' % (mode, self.origin, host_extra))

    # ---- helpers
    def git(self, cwd, *a):
        r = run(["git", "-C", cwd, *a], self.env)
        if r.returncode != 0:
            raise RuntimeError("git %s: %s" % (a, r.stderr))
        return r.stdout.strip()

    def put(self, name, text):
        with open(os.path.join(self.fake, name), "w") as f:
            f.write(text)

    def write_files(self, files, base=None):
        for rel, text in files.items():
            p = os.path.join(base or self.src, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w") as f:
                f.write(text)

    def host_mode(self, mode, extra=""):
        with open(os.path.join(self.cfg, "mergequeue", "acme__widgets.toml"), "w") as f:
            f.write('mode = "%s"\nremote = "%s"\n%s' % (mode, self.origin, extra))

    def comments(self):
        try:
            with open(os.path.join(self.fake, "comments")) as f:
                return [ln.split("\t", 1) for ln in f.read().splitlines()]
        except OSError:
            return []

    def main_tip(self):
        return self.git(self.origin, "rev-parse", "refs/heads/main")

    def main_commit(self, files, msg="main moves"):
        self.git(self.src, "fetch", "-q", "origin")
        self.git(self.src, "checkout", "-q", "-B", "main", "origin/main")
        self.write_files(files)
        self.git(self.src, "add", "-A")
        self.git(self.src, "commit", "-q", "-m", msg)
        self.git(self.src, "push", "-q", "origin", "main")
        return self.main_tip()

    def pr(self, n, files, base_sha=None, state="OPEN", draft=False, base="main", announce_head=True):
        """A PR branch off base_sha (default: main's tip) with these files; refs/pull/N/head on origin; the fake GraphQL answer."""
        self.git(self.src, "checkout", "-q", "-B", "pr-%d" % n, base_sha or self.main_tip())
        self.write_files(files)
        self.git(self.src, "add", "-A")
        self.git(self.src, "commit", "-q", "-m", "work of pr %d" % n)
        sha = self.git(self.src, "rev-parse", "HEAD")
        self.git(self.src, "push", "-q", "-f", "origin", "HEAD:refs/pull/%d/head" % n)
        self.set_pr(n, state=state, draft=draft, head=sha if announce_head else "0" * 40, branch="pr-%d" % n, base=base, owner="acme")
        return sha

    def set_pr(self, n, **kw):
        with open(os.path.join(self.fake, "prs.json")) as f:
            prs = json.load(f)
        prs.setdefault(str(n), {}).update(kw)
        self.put("prs.json", json.dumps(prs))

    def mq(self, *a, env=None, cwd=None, timeout=120):
        e = dict(self.env, **(env or {}))
        return run(["bash", os.path.join(ROOT, "bin", "salamander"), "mq", *a, "--repo", REPO] if a[0] not in ("--help",) else
                   ["bash", os.path.join(ROOT, "bin", "salamander"), "mq", *a], e, cwd=cwd, timeout=timeout)

    def drive(self, env=None, timeout=120):
        return run([sys.executable, "-I", os.path.join(ROOT, "lib", "mq", "main.py"), "drive", "--repo", REPO], dict(self.env, **(env or {})), timeout=timeout)

    def calls(self):
        try:
            with open(os.path.join(self.fake, "calls")) as f:
                return f.read().splitlines()
        except OSError:
            return []

    def ncalls(self, prefix):
        return sum(1 for c in self.calls() if c.startswith(prefix))

    def sdir(self):
        return os.path.join(self.state, "mergequeue", "acme__widgets")

    def group(self, gid):
        with open(os.path.join(self.sdir(), "groups", gid + ".json")) as f:
            return json.load(f)

    def queue(self):
        with open(os.path.join(self.sdir(), "queue.json")) as f:
            return json.load(f)

    def entry(self, pr):
        return [e for e in self.queue()["entries"] if e["pr"] == pr][-1]

    def events(self, ev=None):
        out = []
        try:
            with open(os.path.join(self.sdir(), "events.log")) as f:
                out = [json.loads(ln) for ln in f if ln.strip()]
        except OSError:
            pass
        return [e for e in out if ev is None or e["ev"] == ev]

    def branches(self):
        out = self.git(self.origin, "for-each-ref", "--format=%(refname:short)", "refs/heads/")
        return sorted(out.split())

    def states(self, *prs):
        return {p: self.entry(p)["state"] for p in prs}

    def lock_free(self):
        p = os.path.join(self.sdir(), "driver.lock")
        if not os.path.exists(p):
            return True
        fd = os.open(p, os.O_RDWR)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError:
            return False
        finally:
            os.close(fd)


def wait_until(cond, secs=30):
    end = time.time() + secs
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.05)
    return cond()


def settle(w):
    """The group is done: the driver ran to the end (synchronously here)."""
    r = w.drive()
    return r


def sorted_calls(w, kind):
    return [c for c in w.calls() if c.startswith(kind)]


# ---- the scenarios ----------------------------------------------------------------------------------------------------------------------------

def sc_entry_passes():
    w = World("passes", ci_mode="going:2")
    main0 = w.main_tip()
    sha = w.pr(1, {"app/f1.py": "x = 1\n"})
    r = w.mq("add", "1")
    check("add: the PR is queued", r.returncode == 0 and r.stdout.count("queued") == 1, r.stdout + r.stderr)
    check("add: the driver was requested once as a transient user unit", w.ncalls("systemd-run unit=mq-acme__widgets") == 1, w.calls())
    check("add: nothing runs by itself in this scenario (the fake only logs)", w.ncalls("gh") == 0)
    d = w.drive()
    check("driver: exits 0", d.returncode == 0, d.stderr)
    check("origin main is untouched (shadow merges nothing)", w.main_tip() == main0)
    check("the queue branch is deleted at the end", w.branches() == ["main"], w.branches())
    check("the PR is tested", w.states(1) == {1: "tested"}, w.queue())
    g = w.group("g1")
    check("entry g1 is done with verdict pass", g["phase"] == "done" and g["verdict"]["result"] == "pass", g)
    check("the entry branch is queue/main/g1", g["branch"] == "queue/main/g1")
    head = g["head"]
    subj = w.git(w.origin, "log", "--first-parent", "--format=%s", "%s" % head).splitlines()
    check("the head is one merge commit over main", subj == ["Merge pull request #1 from acme/pr-1", "initial"], subj)
    check("the head's parent is main", w.git(w.origin, "rev-parse", head + "~1") == main0)
    tree = w.git(w.origin, "ls-tree", "-r", "--name-only", head).split()
    check("the head's tree holds the PR", "app/f1.py" in tree, tree)
    check("the pinned head is in the record", [m["head"] for m in g["members"]] == [sha])
    # the budget: counted by the fakes AND by the record
    check("calls to GitHub for the entry: 2 GraphQL (the build, and the read before the verdict counts) + 1 check-runs (the poller's file said going twice, then finished)",
          w.ncalls("gh ") == 3 and w.ncalls("gh graphql") == 2 and w.ncalls("gh check-runs") == 1, w.calls())
    check("the poller's file was asked three times, no GitHub call for the two going answers", w.ncalls("salamander ci-runs") == 3, w.calls())
    check("the record counts the same as the fakes", g["gh_calls"] == {"graphql": 2, "check-runs": 1} and g["salamander_calls"] == {"ci-runs": 3}, (g["gh_calls"], g["salamander_calls"]))
    check("git over the remote is counted apart: 1 clone, 3 fetches (main, the PR, main again for the read before the verdict counts), 2 pushes (the branch, its deletion), 1 ls-remote",
          g["git_remote"] == {"clone": 1, "fetch": 3, "push": 2, "ls-remote": 1}, g["git_remote"])
    check("the graphql call named the PR", "gh graphql 1" in w.calls())
    ph = [e["phase"] for e in w.events("phase")]
    check("the phases went in order", ph == ["built", "pushed", "testing", "verdict", "cleaning", "done"], ph)
    wr = w.mq("wait", "1", "--timeout", "5")
    check("wait: tested in shadow mode is exit 3 (nothing was merged)", wr.returncode == 3 and "tested" in wr.stdout, (wr.returncode, wr.stdout, wr.stderr))
    check("no worktree is left", not os.path.exists(os.path.join(w.sdir(), "worktrees", "g1")))
    check("the driver left no lock and no info", w.lock_free() and not os.path.exists(os.path.join(w.sdir(), "driver.json")))
    r2 = w.mq("add", "4")
    check("a second add with no driver alive asks for a driver again", w.ncalls("systemd-run") == 2, w.calls())
    fd = os.open(os.path.join(w.sdir(), "driver.lock"), os.O_RDWR | os.O_CREAT)
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    w.mq("add", "5")
    check("add with a live driver (its lock held) starts none", w.ncalls("systemd-run") == 2, w.calls())
    os.close(fd)


def sc_etag_without_poller():
    w = World("etag", ci_mode="unavailable", pending=2)
    w.pr(1, {"app/g1.py": "y = 1\n"})
    w.mq("add", "1")
    w.drive()
    g = w.group("g1")
    cr = sorted_calls(w, "gh check-runs")
    check("no poller file: three check-runs reads (running, running, finished)", len(cr) == 3, cr)
    check("the first read sends no ETag, the second and third do", "inm=no" in cr[0] and "inm=yes" in cr[1] and "inm=yes" in cr[2], cr)
    check("the second read, same body, is a 304", cr[1].endswith("304") and cr[0].endswith("200") and cr[2].endswith("200"), cr)
    check("the record counts 2 reads and 1 not-modified", g["gh_calls"] == {"graphql": 2, "check-runs": 2, "check-runs-304": 1}, g["gh_calls"])
    check("the entry passed", g["verdict"]["result"] == "pass" and w.states(1) == {1: "tested"})
    check("the poller's reader was asked before every read", g["salamander_calls"] == {"ci-runs": 3}, g["salamander_calls"])
    w2 = World("etag2", ci_mode="none")
    w2.pr(1, {"app/h.py": "z = 1\n"})
    w2.mq("add", "1")
    w2.drive()
    check("a fresh poller file with no run of the commit proves nothing: the check-runs read decides",
          w2.ncalls("gh check-runs") == 1 and w2.states(1) == {1: "tested"}, w2.calls())


def sc_failing_entry():
    w = World("fails")
    main0 = w.main_tip()
    w.pr(1, {"app/BAD_x": "bad\n"})
    w.mq("add", "1")
    w.drive()
    check("a failing entry fails its PR, alone", w.states(1) == {1: "failed"}, w.queue())
    e = w.entry(1)
    check("the reason names the entry and the check", e["reason"] == "group g1 failed suites", e)
    check("one entry, one run: nothing is split", len(os.listdir(os.path.join(w.sdir(), "groups"))) == 1 and w.ncalls("gh check-runs") == 1, w.calls())
    check("the verdict is journaled with the call counts", any(v["result"] == "fail" and "gh_calls" in v for v in w.events("verdict")), w.events("verdict"))
    check("the branch is gone and main is untouched", w.branches() == ["main"] and w.main_tip() == main0)
    wr = w.mq("wait", "1", "--timeout", "5")
    check("wait: a failed PR is exit 1 with the reason on stderr", wr.returncode == 1 and "group g1 failed" in wr.stderr, (wr.returncode, wr.stderr))
    check("the verdict carries the run link", w.group("g1")["verdict"]["run_url"] == "https://ci.example/runs/11", w.group("g1")["verdict"])
    # the PR behind a failed one is failed on its own verdict only once the entry ahead passed; here the one ahead is fine
    w = World("fails-behind")
    w.pr(1, {"app/a.py": "a\n"})
    w.pr(2, {"app/BAD_x": "bad\n"})
    w.pr(3, {"app/c.py": "c\n"})
    w.mq("add", "1", "2", "3")
    w.drive()
    check("the failing PR is named by its position; the PRs around it are tested, the one behind rebuilt without it", w.states(1, 2, 3) == {1: "tested", 2: "failed", 3: "tested"}, w.queue())
    check("it is failed alone, with its own entry in the reason", w.entry(2)["reason"] == "group g2 failed suites", w.entry(2))


def sc_lone_pr_and_rerun():
    w = World("lone")
    w.pr(7, {"RERUN": "1\n"})
    w.mq("add", "7")
    w.drive()
    g = w.group("g1")
    check("a lone PR is an entry and passes; the newest `suites` run (the re-run) wins over an older failed one",
          g["verdict"]["result"] == "pass" and w.states(7) == {7: "tested"} and len(g["members"]) == 1, g["verdict"])
    subj = w.git(w.origin, "log", "--first-parent", "--format=%s", g["head"]).splitlines()
    check("a lone PR is still a merge commit", subj[0] == "Merge pull request #7 from acme/pr-7", subj)


def sc_conflicts():
    w = World("conflicts")
    base = w.main_tip()
    w.pr(1, {"app/core.py": "def core():\n    return 'one'\n"}, base_sha=base)
    w.pr(2, {"app/core.py": "def core():\n    return 'two'\n"}, base_sha=base)
    w.pr(3, {"app/other.py": "ok\n"}, base_sha=base)
    w.main_commit({"app/mainfile.py": "m\n"})
    w.pr(4, {"app/mainfile.py": "from-pr4\n"}, base_sha=base)         # branched before main added the file: add/add conflict
    w.mq("add", "1", "2", "3", "4")
    w.drive()
    st = w.states(1, 2, 3, 4)
    check("the PR that conflicts with the PR ahead of it is ejected, the others go on", st[1] == "tested" and st[2] == "ejected" and st[3] == "tested", st)
    check("the reason names the PR ahead and the file", "conflicts with main or with PR #1 ahead of it" in w.entry(2)["reason"] and "app/core.py" in w.entry(2)["reason"], w.entry(2))
    check("a PR that conflicts with main alone is ejected", st[4] == "ejected", w.entry(4))
    check("each ejected PR was an entry of its own, which ended empty with no verdict", all(w.group(x)["verdict"] is None or w.group(x)["verdict"]["result"] == "empty" for x in ("g2", "g4")) and
          [m["state"] for m in w.group("g2")["members"]] == ["ejected"] and [m["state"] for m in w.group("g4")["members"]] == ["ejected"], (w.group("g2"), w.group("g4")))
    g1, g3 = w.group("g1"), w.group("g3")
    check("the entries that stayed hold their own PR as one merge commit and passed", g1["verdict"]["result"] == "pass" and g3["verdict"]["result"] == "pass" and
          w.git(w.origin, "log", "--first-parent", "--format=%s", g1["head"]).splitlines()[0] == "Merge pull request #1 from acme/pr-1" and
          w.git(w.origin, "log", "--first-parent", "--format=%s", g3["head"]).splitlines()[0] == "Merge pull request #3 from acme/pr-3", (g1, g3))
    check("neither head holds a refused PR's file", "'one'" in w.git(w.origin, "show", g1["head"] + ":app/core.py") and
          "from-pr4" not in w.git(w.origin, "show", g3["head"] + ":app/mainfile.py"))
    wr = w.mq("wait", "2", "--timeout", "5")
    check("wait: an ejected PR is exit 1", wr.returncode == 1, (wr.returncode, wr.stderr))


def sc_snapshot_hook():
    cfg = 'on_conflict = "python3 tools/regen.py"\n'
    regen = ("import os, subprocess\n"
             "files = os.environ['MQ_CONFLICT_FILES'].split()\n"
             "assert files == ['tests/tool_text.snapshot.json'], files\n"
             "open(files[0], 'w').write('{\"regenerated\": true}\\n')\n")
    w = World("hook", config=cfg, files={"tools/regen.py": regen})
    base = w.main_tip()
    w.pr(1, {"tests/tool_text.snapshot.json": '{"a": 10,\n "b": 2}\n'}, base_sha=base)
    w.pr(2, {"tests/tool_text.snapshot.json": '{"a": 1,\n "b": 20}\n'}, base_sha=base)
    w.pr(3, {"tests/tool_text.snapshot.json": '{"a": 1,\n "b": 2,\n "c": 3}\n', "app/core.py": "def core():\n    return 'three'\n"}, base_sha=base)
    w.pr(4, {"tests/tool_text.snapshot.json": '{"z": 0}\n', "app/core.py": "def core():\n    return 'four'\n"}, base_sha=base)
    w.mq("add", "1", "2", "3", "4")
    w.drive()
    st = w.states(1, 2, 3, 4)
    check("a conflict on the snapshot alone is resolved by the hook (PR 2, and PR 3 whose other file merges clean)", st[1] == "tested" and st[2] == "tested" and st[3] == "tested", st)
    g = w.group("g3")
    check("the hook's output is what the head of the last entry holds (the entries are stacked)", w.git(w.origin, "show", g["head"] + ":tests/tool_text.snapshot.json") == '{"regenerated": true}')
    check("the hook ran for the PRs that conflicted on the snapshot and journaled it", sorted(e["pr"] for e in w.events("conflict_resolved")) == [2, 3], w.events("conflict_resolved"))
    check("a conflict on the snapshot plus another file is not the hook's: ejected", st[4] == "ejected" and "app/core.py" in w.entry(4)["reason"], (st, w.entry(4)))
    w2 = World("hookfail", config='on_conflict = "python3 -c \'import sys; sys.exit(3)\'"\n')
    b2 = w2.main_tip()
    w2.pr(1, {"tests/tool_text.snapshot.json": '{"a": 10,\n "b": 2}\n'}, base_sha=b2)
    w2.pr(2, {"tests/tool_text.snapshot.json": '{"a": 1,\n "b": 20}\n'}, base_sha=b2)
    w2.mq("add", "1", "2")
    w2.drive()
    check("a hook that fails ejects the PR and says so in the journal", w2.states(1, 2) == {1: "tested", 2: "ejected"} and w2.events("conflict_hook_failed"), (w2.states(1, 2), w2.events()))


def sc_graphql_ejections():
    w = World("gql")
    w.pr(1, {"a1.py": "1\n"})
    w.pr(2, {"a2.py": "2\n"}, state="CLOSED")
    w.pr(3, {"a3.py": "3\n"}, draft=True)
    w.pr(4, {"a4.py": "4\n"}, base="release")
    w.pr(5, {"a5.py": "5\n"}, state="MERGED")
    w.mq("add", "1", "2", "3", "4", "5", "6")           # 6 does not exist
    w.drive()
    st = w.states(1, 2, 3, 4, 5, 6)
    check("closed, draft, wrong base, merged and missing PRs are ejected at the one GraphQL read, the open one is tested",
          st == {1: "tested", 2: "ejected", 3: "ejected", 4: "ejected", 5: "ejected", 6: "ejected"}, st)
    reasons = {p: w.entry(p)["reason"] for p in (2, 3, 4, 5, 6)}
    check("each reason says why", reasons[2] == "pull request is closed" and reasons[3] == "pull request is a draft" and "release" in reasons[4] and
          reasons[5] == "pull request is merged" and reasons[6] == "pull request not found", reasons)
    gq = [c for c in w.calls() if c.startswith("gh graphql")]
    check("each PR is an entry that reads GitHub once to build (six reads, each naming its PR), and the survivor reads its PR again before the verdict counts", sorted(gq) ==
          sorted(["gh graphql %d" % n for n in (1, 2, 3, 4, 5, 6)] + ["gh graphql 1"]) and w.group("g1")["git_remote"]["fetch"] == 3, (w.calls(), w.group("g1")["git_remote"]))
    w2 = World("gql2")
    w2.pr(1, {"x.py": "1\n"}, state="CLOSED")
    w2.mq("add", "1")
    w2.drive()
    g = w2.group("g1")
    check("a group whose every PR is ejected ends without a push or a check read",
          g["phase"] == "done" and g["verdict"]["result"] == "empty" and w2.ncalls("gh check-runs") == 0 and g["head"] is None and "push" not in g["git_remote"], g)


def ck(name, conclusion="SUCCESS", status="COMPLETED", i=1):
    return {"name": name, "status": status, "conclusion": conclusion, "databaseId": i}


def sc_pr_checks_refuse():
    """A queue must not take a PR whose own checks failed: refused at the join, named in the words of release.sh's FAILED line."""
    w = World("prchecks")
    for n in (1, 2, 3, 4, 5):
        w.pr(n, {"app/f%d.py" % n: "x = %d\n" % n})
    w.set_pr(1, checks=[ck("suites"), ck("tool-text-model")])
    w.set_pr(2, checks=[ck("suites"), ck("tool-text-model", "FAILURE")])
    w.set_pr(3, checks=[ck("suites", "CANCELLED"), ck("lint", "TIMED_OUT")])
    w.set_pr(4, checks=[ck("slow", None, "IN_PROGRESS"), ck("optional", "SKIPPED"), ck("note", "NEUTRAL"), {"context": "merge queue", "state": "FAILURE"}])
    w.set_pr(5, checks=[ck("tool-text-model", "FAILURE", i=5), ck("tool-text-model", "SUCCESS", i=6)])           # a re-run supersedes the older run
    w.mq("add", "1", "2", "3", "4", "5")
    w.drive()
    st = w.states(1, 2, 3, 4, 5)
    check("passing: a PR whose checks passed, are still running, were skipped, or failed once and passed on the re-run joins and is tested; the failed ones are ejected",
          st == {1: "tested", 2: "ejected", 3: "ejected", 4: "tested", 5: "tested"}, st)
    check("the reason is parallel to release.sh's FAILED line", w.entry(2)["reason"] == "refused: a check failed: tool-text-model=fail", w.entry(2))
    check("a cancelled and a timed-out check are named with their bucket, in name order", w.entry(3)["reason"] == "refused: a check failed: lint=fail, suites=cancel", w.entry(3))
    trees = {n: w.git(w.origin, "ls-tree", "-r", "--name-only", w.group(w.entry(n)["group"])["head"]).split() for n in (1, 4, 5)}
    check("the trees of the entries that were not refused hold their own PR, and no refused PR's file", all("app/f%d.py" % n in trees[n] for n in (1, 4, 5)) and
          all("app/f2.py" not in t and "app/f3.py" not in t for t in trees.values()), trees)
    wr = w.mq("wait", "2", "--timeout", "5")
    check("wait: a refused PR is exit 1 with the reason on stderr", wr.returncode == 1 and "refused: a check failed: tool-text-model=fail" in wr.stderr, (wr.returncode, wr.stderr))
    check("shadow writes nothing to GitHub for the refusal", w.ncalls("gh status") == 0 and w.ncalls("gh comment") == 0)

    # pr_required names the checks that count; a failing one outside the list is not held against the PR
    w = World("prchecks-named", config='pr_required = ["suites"]\n')
    w.pr(1, {"app/f1.py": "1\n"})
    w.pr(2, {"app/f2.py": "2\n"})
    w.set_pr(1, checks=[ck("suites"), ck("unrelated", "FAILURE")])
    w.set_pr(2, checks=[ck("suites", "FAILURE")])
    w.mq("add", "1", "2")
    w.drive()
    check("pr_required = [suites]: only a failed suites refuses", w.states(1, 2) == {1: "tested", 2: "ejected"} and w.entry(2)["reason"] == "refused: a check failed: suites=fail", (w.queue(), w.entry(2)))

    # a check that fails after the PR joined: caught when the group's verdict is about to count
    w = World("prchecks-stays")
    w.pr(1, {"app/f1.py": "1\n"})
    w.pr(2, {"app/f2.py": "2\n"})
    w.set_pr(1, checks=[ck("tool-text-model")])
    w.set_pr(2, checks=[ck("tool-text-model")])
    w.mq("add", "1", "2")
    d = w.drive(env={"MQ_CRASH_AT": "verdict"})
    w.set_pr(2, checks=[ck("tool-text-model", "FAILURE")])
    w.drive()
    check("a PR whose check failed while its group was tested is refused and the other stays tested", w.states(1, 2) == {1: "tested", 2: "ejected"} and
          w.entry(2)["reason"] == "refused: a check failed: tool-text-model=fail" and d.returncode == 75, (w.queue(), d.returncode))
    check("the journal says what the shadow did not rebuild", [e["prs"] for e in w.events("recheck_ejected")] == [[2]], w.events("recheck_ejected"))
    wr = w.mq("wait", "2", "--timeout", "5")
    check("wait: exit 1 for it, exit 3 (tested, nothing merged) for the other", wr.returncode == 1 and w.mq("wait", "1", "--timeout", "5").returncode == 3, (wr.returncode, wr.stderr))

    # mode on: told by a failure status and one comment; the failed check at the merge makes the group stale, the rest is rebuilt and merged
    w = World("prchecks-on")
    w.pr(1, {"app/f1.py": "1\n"})
    w.pr(2, {"app/f2.py": "2\n"})
    w.pr(3, {"app/f3.py": "3\n"})
    w.set_pr(2, checks=[ck("tool-text-model", "FAILURE")])
    w.mq("add", "1", "2", "3")
    to_on(w)
    w.drive()
    tree = w.git(w.origin, "ls-tree", "-r", "--name-only", "main").split()
    check("mode on: the PR with a failed check is not merged, the others are", w.states(1, 2, 3) == {1: "merged", 2: "ejected", 3: "merged"} and "app/f2.py" not in tree, (w.queue(), tree))
    check("mode on: ONE comment for the refused PR, naming the check", [c[0] for c in w.comments()] == ["2"] and "a check failed: tool-text-model=fail" in w.comments()[0][1], w.comments())
    w = World("prchecks-on-stays")
    w.pr(1, {"app/f1.py": "1\n"})
    w.pr(2, {"app/f2.py": "2\n"})
    w.mq("add", "1", "2")
    w.drive(env={"MQ_CRASH_AT": "verdict"})
    w.set_pr(1, checks=[ck("tool-text-model", "FAILURE")])
    to_on(w)
    main0 = w.main_tip()
    w.drive()
    tree = w.git(w.origin, "ls-tree", "-r", "--name-only", "main").split()
    check("mode on: a check that failed after the group was tested keeps the PR off main, the other is rebuilt and merged",
          w.states(1, 2) == {1: "ejected", 2: "merged"} and "app/f1.py" not in tree and "app/f2.py" in tree and w.main_tip() != main0, (w.queue(), tree))
    check("the group that held it was stale", w.group("g1")["state"] == "stale" and "left the group" in w.group("g1")["outcome_reason"], w.group("g1"))
    # the repo file: pr_required is validated like the other keys
    import mq_config as C
    for text, ok in (('pr_required = "all"\n', True), ('pr_required = ["a", "b"]\n', True), ('pr_required = []\n', False), ('pr_required = "some"\n', False), ('pr_required = [1]\n', False)):
        cfg, errs, _ = C.parse_repo_config(text)
        check("pr_required %s is %s" % (text.strip().split("= ", 1)[1], "accepted" if ok else "an error"), (not errs) == ok, errs)
    check("pr_required defaults to all", C.parse_repo_config(None)[0]["pr_required"] == "all")


def sc_conflict_after_main_moves():
    """A PR that merged cleanly when its group was built, but conflicts with main by the time the group's verdict counts, is refused."""
    w = World("conflict-late", config='on_conflict = "python3 tools/regen.py"\n', files={"tools/regen.py": "open('tests/tool_text.snapshot.json', 'w').write('{}\\n')\n"})
    base = w.main_tip()
    w.pr(1, {"app/other.py": "ok\n"}, base_sha=base)
    w.pr(2, {"app/core.py": "def core():\n    return 'two'\n"}, base_sha=base)
    w.pr(3, {"tests/tool_text.snapshot.json": '{"a": 10,\n "b": 2}\n'}, base_sha=base)
    w.pr(4, {"app/new.py": "from pr 4\n"}, base_sha=base)
    w.mq("add", "1", "2", "3", "4")
    d = w.drive(env={"MQ_CRASH_AT": "verdict"})
    check("the group was built and tested clean (injected stop at the verdict)", d.returncode == 75 and w.group("g1")["verdict"]["result"] == "pass", d.returncode)
    w.main_commit({"app/core.py": "def core():\n    return 'main'\n", "tests/tool_text.snapshot.json": '{"a": 1,\n "b": 20}\n', "app/new.py": "from main\n"}, msg="main moves under the group")
    w.drive()
    st = w.states(1, 2, 3, 4)
    check("main moved: the PR that now conflicts is refused, the clean one and the snapshot-only conflict (the hook mends it) stay tested", st == {1: "tested", 2: "ejected", 3: "tested", 4: "ejected"}, st)
    check("the reason is 'refused: conflicts with main' with the files (PR 4 was rebuilt behind PR 3, so its words also name the PR ahead)", w.entry(2)["reason"] == "refused: conflicts with main (app/core.py)" and
          w.entry(4)["reason"].startswith("refused: conflicts with main") and "(app/new.py)" in w.entry(4)["reason"], (w.entry(2), w.entry(4)))
    wr = w.mq("wait", "2", "--timeout", "5")
    check("wait: exit 1 for a conflicting PR", wr.returncode == 1 and "refused: conflicts with main" in wr.stderr, (wr.returncode, wr.stderr))
    check("no extra GitHub write for it in shadow", w.ncalls("gh status") == 0 and w.ncalls("gh comment") == 0)

    # main moved and the PR still merges: nothing is refused
    w = World("conflict-late-clean")
    w.pr(1, {"app/a.py": "a\n"})
    w.mq("add", "1")
    w.drive(env={"MQ_CRASH_AT": "verdict"})
    w.main_commit({"docs/new.md": "new\n"})
    w.drive()
    check("main moved but the PR still merges into it: tested", w.states(1) == {1: "tested"}, w.queue())

    # mode on: a moved main makes the group stale, the rebuild on it meets the conflict and refuses the PR in the same words
    w = World("conflict-late-on")
    base = w.main_tip()
    w.pr(1, {"app/a.py": "a\n"}, base_sha=base)
    w.pr(2, {"app/core.py": "def core():\n    return 'two'\n"}, base_sha=base)
    w.mq("add", "1", "2")
    w.drive(env={"MQ_CRASH_AT": "verdict"})
    w.main_commit({"app/core.py": "def core():\n    return 'main'\n"})
    to_on(w)
    w.drive()
    check("mode on: the PR that conflicts with the moved main is refused (told once), the other merges", w.states(1, 2) == {1: "merged", 2: "ejected"} and
          w.entry(2)["reason"].startswith("refused: conflicts with main") and [c[0] for c in w.comments()] == ["2"], (w.queue(), w.comments()))


def sc_head_moved():
    w = World("moved")
    w.pr(1, {"a1.py": "1\n"})
    w.pr(2, {"a2.py": "2\n"})
    w.git(w.src, "checkout", "-q", "pr-2")
    w.write_files({"a2b.py": "more\n"})
    w.git(w.src, "add", "-A")
    w.git(w.src, "commit", "-q", "-m", "pushed again")
    w.git(w.src, "push", "-q", "-f", "origin", "HEAD:refs/pull/2/head")      # the author pushed after the GraphQL answer was written
    w.mq("add", "1", "2")
    w.drive()
    st = w.states(1, 2)
    check("a head that moved after the read is ejected, not tested", st == {1: "tested", 2: "ejected"} and "head moved" in w.entry(2)["reason"], (st, w.entry(2)))


def sc_config_inflight():
    cfg = "inflight_max = 2\n"
    w = World("sizes", config=cfg, ci_mode="going:3")
    for n in range(1, 6):
        w.pr(n, {"app/s%d.py" % n: "%d\n" % n})
    # PR 1 tries to change the rules for everyone (inflight_max = 5): main's file is the one read
    w.git(w.src, "checkout", "-q", "pr-1")
    w.write_files({".github/mergequeue.toml": "inflight_max = 5\n"})
    w.git(w.src, "add", "-A")
    w.git(w.src, "commit", "-q", "-m", "tries its own rules")
    sha1 = w.git(w.src, "rev-parse", "HEAD")
    w.git(w.src, "push", "-q", "-f", "origin", "HEAD:refs/pull/1/head")
    w.set_pr(1, head=sha1)
    w.mq("add", "1", "2", "3", "4", "5")
    w.drive()
    sizes = [len(w.group(g)["members"]) for g in ("g1", "g2", "g3", "g4", "g5")]
    check("every entry holds one PR", sizes == [1, 1, 1, 1, 1], sizes)
    check("all five tested", set(w.states(1, 2, 3, 4, 5).values()) == {"tested"}, w.states(1, 2, 3, 4, 5))
    ev = [(e["ev"], e.get("group")) for e in w.events() if e["ev"] in ("group_start", "group_done")]
    check("inflight_max = 2 from main's file (a PR cannot change its own rules): g2 starts before g1 is done, g3 waits for a slot",
          ev.index(("group_start", "g2")) < ev.index(("group_done", "g1")) and ev.index(("group_start", "g3")) > min(ev.index(("group_done", "g1")), ev.index(("group_done", "g2"))) and
          peak_live(w) == 2, (ev, peak_live(w)))
    check("the queue branches were pushed per entry and all deleted", w.branches() == ["main"])
    w2 = World("sizes1", config="inflight_max = 1\n", ci_mode="going:2")
    for n in range(1, 5):
        w2.pr(n, {"app/t%d.py" % n: "%d\n" % n})
    w2.mq("add", "1", "2", "3", "4")
    w2.drive()
    ev2 = [(e["ev"], e.get("group")) for e in w2.events() if e["ev"] in ("group_start", "group_done")]
    check("inflight_max = 1: g2 starts only after g1 is done", ev2.index(("group_start", "g2")) > ev2.index(("group_done", "g1")) and peak_live(w2) == 1, ev2)
    w3 = World("sizes0", ci_mode="going:2")
    for n in range(1, 8):
        w3.pr(n, {"app/u%d.py" % n: "%d\n" % n})
    w3.mq("add", *[str(n) for n in range(1, 8)])
    w3.drive()
    check("without .github/mergequeue.toml an entry is one PR and up to six are in flight", [len(w3.group("g%d" % k)["members"]) for k in range(1, 8)] == [1] * 7 and peak_live(w3) == 6,
          (peak_live(w3), [len(w3.group("g%d" % k)["members"]) for k in range(1, 8)]))


def sc_invalid_config_blocks():
    w = World("badcfg", config="inflight_max = 0\nbogus = 1\n")
    w.pr(1, {"a.py": "1\n"})
    w.mq("add", "1")
    d = w.drive()
    q = w.queue()
    check("an invalid repo config blocks the queue: the PR waits, nothing was fetched for an entry, the driver left", d.returncode == 0 and q["blocked"] and
          "inflight_max" in q["blocked"]["reason"] and w.entry(1)["state"] == "waiting" and w.lock_free() and w.ncalls("gh") == 0, (q, d.stderr))
    check("the block is journaled once", len(w.events("blocked")) == 1, w.events("blocked"))
    st = w.mq("status")
    check("status says BLOCKED", "BLOCKED" in st.stdout and "inflight_max" in st.stdout, st.stdout)
    wr = w.mq("wait", "1", "--timeout", "5")
    check("wait on a blocked queue is exit 2 with the reason", wr.returncode == 2 and "blocked" in wr.stderr, (wr.returncode, wr.stderr))
    dr = w.mq("doctor")
    check("doctor names the invalid repo config", dr.returncode == 1 and "inflight_max" in dr.stdout, dr.stdout)
    w.main_commit({".github/mergequeue.toml": "inflight_max = 3\n"})
    w.drive()
    check("fixed on main: the next driver builds the entry and the block is cleared", w.entry(1)["state"] == "tested" and w.queue()["blocked"] is None, w.queue())
    from mq_config import parse_repo_config
    cfg, errs, warns = parse_repo_config('queue_prefix = "other/"\nsuites = "some"\nrequired = []\non_conflict = "a \'b"\nflaky = [1]\nunknown = 3\n')
    check("config values are validated", len(errs) == 5 and warns == ["unknown key 'unknown' (ignored)"], (errs, warns))
    cfg, errs, warns = parse_repo_config(None)
    check("no file is the defaults", cfg["queue_mode"] == "chain" and cfg["inflight_max"] == 6 and cfg["required"] == ["suites"] and cfg["queue_prefix"] == "queue/main/" and not errs and not warns)
    check("the group-mode keys are not defaults any more", "group_max" not in cfg and "bisect" not in cfg, cfg)


def sc_gh_failures():
    w = World("ghfail")
    w.pr(1, {"a.py": "1\n"})
    w.put("graphql.fail", "2")
    w.mq("add", "1")
    w.drive()
    g = w.group("g1")
    check("GraphQL failing twice is retried; the third call works and every attempt is counted", g["gh_calls"]["graphql"] == 4 and w.ncalls("gh graphql") == 4 and
          w.entry(1)["state"] == "tested" and len(w.events("step_failed")) == 2, (g["gh_calls"], w.calls()))
    w2 = World("ghgone")
    w2.pr(1, {"a.py": "1\n"})
    w2.put("graphql.fail", "99")
    w2.mq("add", "1")
    w2.drive()
    e = w2.entry(1)
    check("GitHub failing for good: the group is given up after MQ_MAX_FAILS and the PR is failed with the reason",
          e["state"] == "failed" and "gave up in phase building after 3 failures" in e["reason"] and w2.ncalls("gh graphql") == 3 and w2.branches() == ["main"], (e, w2.calls()))


def sc_no_verdict_in_time():
    w = World("cap", ci_mode="none")
    w.put("ci.never", "1")
    w.pr(1, {"a.py": "1\n"})
    w.mq("add", "1")
    w.drive(env={"MQ_WAIT_CAP_SECS": "0.3"})
    e = w.entry(1)
    check("a run that never finishes ends in a timeout verdict, the PR is failed, the branch is deleted", e["state"] == "failed" and "no verdict" in e["reason"] and
          w.group("g1")["verdict"]["result"] == "timeout" and w.branches() == ["main"], (e, w.group("g1")["verdict"]))


def sc_crash_recovery():
    for phase in ("building", "built", "pushed", "testing", "verdict", "cleaning", "done"):
        w = World("crash-" + phase, ci_mode="going:1")
        main0 = w.main_tip()
        w.pr(1, {"a1.py": "1\n"})
        w.mq("add", "1")
        d = w.drive(env={"MQ_CRASH_AT": phase})
        check("crash at %s: the driver exits with 75 and journals the injection" % phase, d.returncode == 75 and w.events("crash_injected"), (d.returncode, d.stderr))
        check("crash at %s: the lock is free (a dead process frees it)" % phase, w.lock_free())
        if phase in ("pushed", "testing", "verdict", "cleaning"):
            check("crash at %s: the queue branch is on origin" % phase, "queue/main/g1" in w.branches(), w.branches())
        if phase in ("building", "built"):
            check("crash at %s: nothing was pushed yet" % phase, w.branches() == ["main"], w.branches())
        check("crash at %s: the record names the phase" % phase, w.group("g1")["phase"] == phase, w.group("g1")["phase"])
        mid = w.mq("status")
        check("crash at %s: status shows the entry and no driver" % phase, "g1" in mid.stdout and "no driver running" in mid.stdout or phase == "done", mid.stdout)
        d2 = w.drive()
        check("crash at %s: a fresh driver finishes the entry" % phase, d2.returncode == 0 and w.states(1) == {1: "tested"}, (d2.stderr, w.queue()))
        g = w.group("g1")
        check("crash at %s: one GraphQL read to build and one before the verdict counts, the branch deleted, main untouched" % phase,
              g["gh_calls"]["graphql"] == 2 and w.ncalls("gh graphql") == 2 and w.branches() == ["main"] and w.main_tip() == main0, (g["gh_calls"], w.calls()))
        check("crash at %s: one push of the branch (it is never pushed twice) and one deletion" % phase, g["git_remote"].get("push") == 2, g["git_remote"])
        check("crash at %s: no worktree left" % phase, not os.path.exists(os.path.join(w.sdir(), "worktrees", "g1")))
        check("crash at %s: one entry only (g1), none invented by the recovery" % phase, sorted(os.listdir(os.path.join(w.sdir(), "groups"))) == ["g1.json"])
    # two entries in a chain, a crash in the middle of their test: both are finished by the next driver, in order, and nothing is invented
    w = World("crash-chain", ci_mode="going:1")
    main0 = w.main_tip()
    w.pr(1, {"a1.py": "1\n"})
    w.pr(2, {"a2.py": "2\n"})
    w.mq("add", "1", "2")
    d = w.drive(env={"MQ_CRASH_AT": "testing"})
    w.drive()
    check("crash at testing with two entries: both finish, only g1 and g2 exist, the branches are gone and main is untouched", d.returncode == 75 and w.states(1, 2) == {1: "tested", 2: "tested"} and
          sorted(os.listdir(os.path.join(w.sdir(), "groups"))) == ["g1.json", "g2.json"] and w.branches() == ["main"] and w.main_tip() == main0, (w.queue(), w.branches()))
    # a crash between the push and the record leaves the branch on origin under the same name: the rebuild removes it first
    w = World("crash-stale")
    w.pr(1, {"a1.py": "1\n"})
    w.mq("add", "1")
    w.drive(env={"MQ_CRASH_AT": "building"})
    w.git(w.origin, "update-ref", "refs/heads/queue/main/g1", w.main_tip())     # an older push of the same name, a different sha
    g = w.group("g1")
    g["build_started"] = True
    with open(os.path.join(w.sdir(), "groups", "g1.json"), "w") as f:
        json.dump(g, f)
    w.drive()
    check("a stale branch of the group's name is removed before the rebuild, and the group still passes", w.entry(1)["state"] == "tested" and w.branches() == ["main"], (w.queue(), w.branches()))


def sc_code_reexec():
    """A release that changes lib/mq/*.py reaches a driver already running: it re-executes itself between passes, holding driver.lock throughout. Runs the driver from a COPY of lib/mq."""
    def copy_code(w):
        code = os.path.join(w.d, "code")
        shutil.copytree(os.path.join(ROOT, "lib", "mq"), code, ignore=shutil.ignore_patterns("__pycache__"))
        return code

    def start(w, code, ci):
        w.put("ci.mode", ci)
        return subprocess.Popen([sys.executable, "-I", os.path.join(code, "main.py"), "drive", "--repo", REPO],
                                env=dict(w.env, MQ_POLL_SECS="0.05", MQ_CODE_SETTLE_SECS="0.2"), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)

    def phase(w, gid="g1"):
        try:
            return w.group(gid)["phase"]
        except (OSError, ValueError):
            return None

    # unchanged code: no exec
    w = World("reexec-same", spawn=False)
    code = copy_code(w)
    w.pr(1, {"a1.py": "x\n"})
    w.mq("add", "1")
    a = start(w, code, "going:3")
    try:
        a.communicate(timeout=120)
    finally:
        if a.poll() is None:
            a.kill()
    check("unchanged code: the entry finishes and the driver never re-executes", a.returncode == 0 and w.states(1) == {1: "tested"} and
          not w.events("code_changed") and len(w.events("driver_start")) == 1, (a.returncode, w.events()))

    # changed code mid-group: the driver journals it, re-executes with the same PID and the same lock, and finishes the group
    w = World("reexec", spawn=False)
    code = copy_code(w)
    w.pr(1, {"a1.py": "x\n"})
    w.mq("add", "1")
    a = start(w, code, "going:100000")
    freed = []
    try:
        check("the driver is testing the group", wait_until(lambda: phase(w) == "testing", 30), phase(w))
        pushes = w.group("g1")["git_remote"].get("push")
        with open(os.path.join(code, "mq_state.py"), "a") as f:
            f.write("\n# a release changed this file\n")
        seen = wait_until(lambda: (freed.append(w.lock_free()) or True) and len(w.events("driver_start")) == 2, 30)
        check("the driver journals code_changed once, naming the file, and starts again as a re-exec", seen and len(w.events("code_changed")) == 1 and
              w.events("code_changed")[0]["files"] == ["mq_state.py"] and w.events("driver_start")[1].get("reexec") is True, w.events())
        check("same PID: the exec kept the process (the unit would see no restart)", w.events("code_changed")[0]["pid"] == a.pid == w.events("driver_start")[1]["pid"] == w.events("driver_start")[0]["pid"], w.events())
        check("driver.lock was never free from the first sample to the second image's start", not any(freed), freed)
        check("driver.json names the same pid and the lock is still held", json.load(open(os.path.join(w.sdir(), "driver.json")))["pid"] == a.pid and not w.lock_free())
        w.put("ci.mode", "going:0")
        a.communicate(timeout=120)
    finally:
        if a.poll() is None:
            a.kill()
    g = w.group("g1")
    check("the group finished under the new image: tested, exit 0", a.returncode == 0 and w.states(1) == {1: "tested"} and g["phase"] == "done", (a.returncode, w.queue()))
    check("no second push: the branch was pushed once and deleted once, as in a group that never saw a release", g["git_remote"].get("push") == pushes + 1 == 2 and w.branches() == ["main"], (g["git_remote"], pushes))
    check("no entry invented, no driver_busy, no second code_changed", sorted(os.listdir(os.path.join(w.sdir(), "groups"))) == ["g1.json"] and not w.events("driver_busy") and
          len(w.events("code_changed")) == 1, w.events())
    check("each phase was entered once", [e["phase"] for e in w.events("phase")] == ["built", "pushed", "testing", "verdict", "cleaning", "done"], [e["phase"] for e in w.events("phase")])
    check("one GraphQL read to build and one before the verdict counts", g["gh_calls"]["graphql"] == 2 and w.ncalls("gh graphql") == 2, (g["gh_calls"], w.calls()))

    # new code that does not import: the process dies, the lock goes with it, and a fresh driver (any mq add / wait / resume) takes the group from its record
    w = World("reexec-broken", spawn=False)
    code = copy_code(w)
    w.pr(1, {"a1.py": "x\n"})
    w.mq("add", "1")
    a = start(w, code, "going:100000")
    path = os.path.join(code, "mq_gh.py")
    with open(path) as f:
        good = f.read()
    err = ""
    try:
        check("the driver is testing the group", wait_until(lambda: phase(w) == "testing", 30), phase(w))
        with open(path, "w") as f:
            f.write(good + "\nthis is not python (\n")
        _, err = a.communicate(timeout=60)
    finally:
        if a.poll() is None:
            a.kill()
    check("code that fails to import: one code_changed, the process ends with an error and nothing loops", a.returncode not in (0, None) and len(w.events("code_changed")) == 1 and
          len(w.events("driver_start")) == 1 and "SyntaxError" in err, (a.returncode, err[-300:], w.events()))
    check("the lock is free and the group stays in its phase", w.lock_free() and phase(w) == "testing")
    with open(path, "w") as f:
        f.write(good)
    w.put("ci.mode", "going:0")
    d = w.drive()
    check("a fresh driver finishes the group from its record", d.returncode == 0 and w.states(1) == {1: "tested"} and w.group("g1")["git_remote"].get("push") == 2, (d.stderr, w.queue()))


def sc_driver_lock():
    w = World("lock", spawn=False, ci_mode="going:40")
    w.pr(1, {"a1.py": "x\n"})
    w.mq("add", "1")
    env = dict(w.env, MQ_POLL_SECS="0.05")
    a = subprocess.Popen([sys.executable, "-I", os.path.join(ROOT, "lib", "mq", "main.py"), "drive", "--repo", REPO], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        ok = wait_until(lambda: os.path.exists(os.path.join(w.sdir(), "driver.json")), 20)
        check("the first driver is up (driver.json)", ok)
        b = w.drive(timeout=60)
        check("a second driver leaves at once, exit 0, and says so in the journal", b.returncode == 0 and len(w.events("driver_busy")) == 1 and len(w.events("driver_start")) == 1,
              (b.returncode, w.events()))
        st = w.mq("status")
        check("status shows the driver running while it holds the lock", "driver running" in st.stdout, st.stdout)
        sj = json.loads(w.mq("status", "--json").stdout)
        check("status --json: driver alive, one entry in flight with its phase, queue entries", sj["driver"]["alive"] is True and sj["mode"] == "shadow" and
              len(sj["groups"]) == 1 and sj["groups"][0]["id"] == "g1" and [e["pr"] for e in sj["queue"]] == [1], sj)
    finally:
        a.wait(timeout=120)
    check("the first driver finished the entry alone", w.states(1) == {1: "tested"} and len(w.events("driver_start")) == 1, w.events("driver_start"))
    # two `mq add` racing: the fake systemd-run starts a real driver for each; never two drivers at once
    w2 = World("race", spawn=True, ci_mode="going:6")
    for n in (1, 2, 3, 4):
        w2.pr(n, {"r%d.py" % n: "x\n"})
    env2 = dict(w2.env, MQ_POLL_SECS="0.05")
    base = ["bash", os.path.join(ROOT, "bin", "salamander"), "mq", "add"]
    p1 = subprocess.Popen(base + ["1", "2", "--repo", REPO], env=env2, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    p2 = subprocess.Popen(base + ["3", "4", "--repo", REPO], env=env2, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    o1, o2 = p1.communicate(timeout=60), p2.communicate(timeout=60)
    check("both adds succeed", p1.returncode == 0 and p2.returncode == 0, (o1, o2))
    done = wait_until(lambda: len(w2.events("group_done")) >= 1 and w2.lock_free() and all(e["state"] != "waiting" and e["state"] != "grouped" for e in w2.queue()["entries"]), 60)
    check("all four PRs are settled", done and set(w2.states(1, 2, 3, 4).values()) == {"tested"}, (w2.queue(), w2.events()))
    depth, peak = 0, 0
    for e in w2.events():
        if e["ev"] == "driver_start":
            depth += 1
        elif e["ev"] == "driver_exit":
            depth -= 1
        peak = max(peak, depth)
    check("never two drivers at once (driver_start and driver_exit alternate)", peak == 1 and depth == 0, w2.events())
    check("every PR is in exactly one entry", sorted(m["pr"] for gid in sorted(os.listdir(os.path.join(w2.sdir(), "groups"))) for m in w2.group(gid[:-5])["members"]) == [1, 2, 3, 4])


def sc_driver_start_race():
    w = World("startrace", spawn=False, ci_mode="going:1")
    SPAWNED.append(w)        # the fake's lock holders free the lock by themselves; the folder waits for that
    for n in (1, 2, 3, 4):
        w.pr(n, {"s%d.py" % n: "x\n"})
    # the other add's driver takes the lock right after this add's liveness check, while this add's systemd-run loses the race for the unit
    w.put("systemd-run.race", "0")
    r = w.mq("add", "1")
    check("add: systemd-run fails with 'exists' and a driver holds the lock: says the driver is running, exit 0, PR queued",
          r.returncode == 0 and "driver running" in r.stdout and "NOT started" not in r.stdout and w.entry(1)["state"] == "waiting", (r.returncode, r.stdout, r.stderr))
    check("the race is journaled once, not as a failed start", len(w.events("driver_start_raced")) == 1 and not w.events("driver_start_failed"), w.events())
    check("the one systemd-run call was made", w.ncalls("systemd-run") == 1, w.calls())
    wait_until(w.lock_free, 30)
    # the lock is taken a moment after the failure (a unit that is still activating): the bounded wait sees it
    w.put("systemd-run.race", "0.7")
    r = w.mq("add", "2")
    check("add: the lock is taken within the wait: driver running", r.returncode == 0 and "driver running" in r.stdout and "NOT started" not in r.stdout, (r.stdout, r.stderr))
    check("both races are journaled", len(w.events("driver_start_raced")) == 2, w.events())
    wait_until(w.lock_free, 30)
    # resume goes through the same path
    w.mq("pause", "--reason", "t")
    w.put("systemd-run.race", "0")
    r = w.mq("resume")
    check("resume with the race: driver running, no NOT started", r.returncode == 0 and "driver running" in r.stdout and "NOT started" not in r.stdout, (r.stdout, r.stderr))
    wait_until(w.lock_free, 30)
    # systemd-run fails and no driver is alive: still NOT started, with the systemd-run error, exit 0, journaled as a failed start
    os.unlink(os.path.join(w.fake, "systemd-run.race"))
    w.put("systemd-run.fail", "1")
    r = w.mq("add", "3")
    check("add: systemd-run fails and no driver is alive: NOT started with the error, exit 0, PR queued",
          r.returncode == 0 and "NOT started" in r.stdout and "systemd-run:" in r.stdout and "exists" in r.stdout and w.entry(3)["state"] == "waiting", (r.returncode, r.stdout, r.stderr))
    check("that is journaled as a failed start, not a race", len(w.events("driver_start_failed")) == 1 and len(w.events("driver_start_raced")) == 3, w.events())



def sc_drop():
    w = World("drop", ci_mode="going:1")
    w.pr(1, {"a.py": "1\n"})
    w.pr(2, {"b.py": "2\n"})
    w.pr(3, {"c.py": "3\n"})
    w.mq("add", "1", "2", "3")
    r = w.mq("drop", "3")
    check("drop: a waiting PR leaves the line", r.returncode == 0 and w.entry(3)["state"] == "dropped", (r.stdout, r.stderr))
    r = w.mq("drop", "99")
    check("drop: a PR that is not in the line is exit 1", r.returncode == 1 and "not in the line" in r.stderr, (r.returncode, r.stderr))
    w.drive(env={"MQ_CRASH_AT": "built"})
    r = w.mq("drop", "1")
    check("drop: a PR in an entry in flight is dropped and the message names the entry and says the entries behind it are rebuilt without it", r.returncode == 0 and "g1" in r.stdout and "rebuilt without it" in r.stdout, r.stdout)
    w.drive()
    check("the driver does not turn a dropped PR back into tested; the PR behind it is tested", w.states(1, 2, 3) == {1: "dropped", 2: "tested", 3: "dropped"}, w.states(1, 2, 3))
    wr = w.mq("wait", "1", "--timeout", "5")
    check("wait: dropped is exit 1", wr.returncode == 1 and "dropped" in wr.stderr, (wr.returncode, wr.stderr))
    w2 = World("drop2")
    w2.pr(1, {"a.py": "1\n"})
    w2.pr(2, {"b.py": "2\n"})
    w2.mq("add", "1", "2")
    w2.drive(env={"MQ_CRASH_AT": "building"})
    w2.mq("drop", "1")
    w2.drive()
    check("a PR dropped before its entry is built is left out of the build, and the PR behind it is tested", w2.states(1, 2) == {1: "dropped", 2: "tested"} and
          [m["state"] for m in w2.group("g1")["members"]] == ["ejected"] and w2.group("g1")["members"][0]["reason"] == "dropped", w2.group("g1")["members"])


def sc_wait_codes():
    w = World("wait")
    r = w.mq("wait", "5", "--timeout", "1")
    check("wait on a PR that was never added: exit 2", r.returncode == 2 and "not in the line" in r.stderr, (r.returncode, r.stderr))
    w.pr(1, {"a.py": "1\n"})
    w.mq("add", "1")
    t0 = time.time()
    r = w.mq("wait", "1", "--timeout", "0.5")
    check("wait with no driver finishing it: gives up at --timeout, exit 2, and asked for a driver", r.returncode == 2 and "gave up" in r.stderr and
          w.ncalls("systemd-run") >= 2 and time.time() - t0 < 20, (r.returncode, r.stderr))
    check("wait makes no GitHub call", w.ncalls("gh ") == 0)
    os.makedirs(os.path.join(w.sdir()), exist_ok=True)
    q = w.queue()
    q["entries"].append({"pr": 9, "state": "merged", "flags": [], "added": 1, "group": "g0", "reason": "merged at abc1234", "ended": 2})
    with open(os.path.join(w.sdir(), "queue.json"), "w") as f:
        json.dump(q, f)
    r = w.mq("wait", "9", "--timeout", "1")
    check("wait: merged is exit 0 (the merge step; here a hand-written state)", r.returncode == 0 and "merged" in r.stdout, (r.returncode, r.stdout))
    r = w.mq("wait")
    check("wait with no PR is a usage error", r.returncode == 2 and "usage" in r.stderr, (r.returncode, r.stderr))


def sc_modes():
    w = World("off", mode=None)
    r = w.mq("add", "1")
    check("no host file: mode off, add refuses, nothing queued, no driver asked for", r.returncode == 1 and "mode is off" in r.stderr and not os.path.exists(os.path.join(w.sdir(), "queue.json")) and
          w.ncalls("systemd-run") == 0, (r.stdout, r.stderr))
    os.makedirs(os.path.join(w.cfg, "mergequeue"))
    won = World("modes-on", mode="on")
    won.pr(1, {"a.py": "1\n"})
    r = won.mq("add", "1")
    check("mode on is open: add queues the PR and asks for the driver", r.returncode == 0 and "PR 1: queued" in r.stdout and "mode on: tested entries are merged into main" in r.stdout and
          won.entry(1)["state"] == "waiting" and won.ncalls("systemd-run unit=mq-acme__widgets") == 1, (r.returncode, r.stdout, r.stderr))
    # the switch stays: with ON_OPEN False (a copy of lib/mq edited here) mode on is refused and nothing is queued
    woff = World("modes-on-closed", mode="on")
    code = os.path.join(woff.d, "code")
    shutil.copytree(os.path.join(ROOT, "lib", "mq"), code, ignore=shutil.ignore_patterns("__pycache__"))
    cfgp = os.path.join(code, "mq_config.py")
    with open(cfgp, encoding="utf-8") as f:
        src_text = f.read()
    check("ON_OPEN is True in the shipped config", "\nON_OPEN = True\n" in src_text)
    with open(cfgp, "w", encoding="utf-8") as f:
        f.write(src_text.replace("\nON_OPEN = True\n", "\nON_OPEN = False\n"))
    r = run([sys.executable, "-I", os.path.join(code, "main.py"), "add", "1", "--repo", REPO], woff.env)
    check("ON_OPEN False: mode on is refused, nothing queued, no driver asked for", r.returncode == 1 and "not open yet" in r.stderr and
          not os.path.exists(os.path.join(woff.sdir(), "queue.json")) and woff.ncalls("systemd-run") == 0, (r.returncode, r.stdout, r.stderr))
    with open(os.path.join(w.cfg, "mergequeue", "acme__widgets.toml"), "w") as f:
        f.write('mode = "sometimes"\nbogus = 1\n')
    r = w.mq("add", "1")
    check("a bad host file is refused with its problems named", r.returncode == 1 and "mode must be one of" in r.stderr and "unknown key 'bogus'" in r.stderr, r.stderr)
    with open(os.path.join(w.cfg, "mergequeue", "acme__widgets.toml"), "w") as f:
        f.write('mode = "shadow"\nremote = "%s"\n' % w.origin)
    w.pr(1, {"a.py": "1\n"})
    r = w.mq("add", "1", "--flag", "recycle")
    check("shadow: add works and keeps the flag", r.returncode == 0 and w.entry(1)["flags"] == ["recycle"], (r.stdout, r.stderr))
    r = w.mq("add", "1")
    check("a PR already in the line stays where it is", r.returncode == 0 and "already in the line" in r.stdout and len(w.queue()["entries"]) == 1, r.stdout)
    r = w.mq("add", "x")
    check("add with a word is a usage error", r.returncode == 2, (r.returncode, r.stderr))
    # off with a driver running work: a driver started while the mode is off does nothing
    w2 = World("off2", mode="shadow")
    w2.pr(1, {"a.py": "1\n"})
    w2.mq("add", "1")
    with open(os.path.join(w2.cfg, "mergequeue", "acme__widgets.toml"), "w") as f:
        f.write('mode = "off"\n')
    w2.drive()
    check("a driver finding the mode off builds nothing and leaves", w2.entry(1)["state"] == "waiting" and w2.ncalls("gh ") == 0 and not os.path.exists(os.path.join(w2.sdir(), "groups", "g1.json")),
          w2.events())


def sc_status_and_default_repo():
    w = World("status", ci_mode="going:1")
    w.pr(1, {"a.py": "1\n"})
    r = w.mq("status")
    check("status of a repo with no state: an empty line, exit 0", r.returncode == 0 and "line: empty" in r.stdout and "no driver running" in r.stdout, r.stdout)
    w.mq("add", "1")
    w.drive(env={"MQ_CRASH_AT": "pushed"})
    r = w.mq("status")
    check("status text lists the group with phase, branch, head and members", "g1" in r.stdout and "pushed" in r.stdout and "queue/main/g1" in r.stdout and "#1" in r.stdout, r.stdout)
    # no --repo: taken from the origin URL of the current folder
    cwd = os.path.join(w.d, "cwdrepo")
    os.makedirs(cwd)
    w.git(cwd, "init", "-q")
    w.git(cwd, "remote", "add", "origin", "git@github.com:acme/widgets.git")
    r = run(["bash", os.path.join(ROOT, "bin", "salamander"), "mq", "status", "--json"], w.env, cwd=cwd)
    check("--repo defaults to the GitHub origin of the current folder", r.returncode == 0 and json.loads(r.stdout)["repo"] == REPO, (r.stdout, r.stderr))
    w.drive()
    r = w.mq("status")
    check("status lists what finished", "recently finished" in r.stdout and "tested" in r.stdout, r.stdout)
    r = run(["bash", os.path.join(ROOT, "bin", "salamander"), "mq", "status"], w.env, cwd=w.d)
    check("no --repo and no origin: exit 2 with the reason", r.returncode == 2 and "--repo" in r.stderr, (r.returncode, r.stderr))
    r = w.mq("--help")
    check("mq --help prints the usage, exit 0", r.returncode == 0 and "usage: salamander mq add" in r.stdout and "internal" in r.stdout, r.stdout[:200])
    r = run(["bash", os.path.join(ROOT, "bin", "salamander"), "mq"], w.env)
    check("mq with nothing: usage on stderr, exit 2", r.returncode == 2 and "usage: salamander mq add" in r.stderr, (r.returncode,))
    r = run(["bash", os.path.join(ROOT, "bin", "salamander"), "mq", "frobnicate"], w.env)
    check("an unknown command: exit 2", r.returncode == 2 and "unknown command" in r.stderr, (r.returncode, r.stderr))


def sc_doctor():
    w = World("doctor", ci_mode="going:1")
    w.pr(1, {"a.py": "1\n"})
    r = w.mq("doctor")
    check("doctor on a repo with no state: ok, exit 0", r.returncode == 0 and "all ok" in r.stdout, r.stdout)
    w.mq("add", "1")
    r = w.mq("doctor")
    check("doctor: work waiting and no driver is named, exit 1", r.returncode == 1 and "no driver is running" in r.stdout, r.stdout)
    w.drive()
    r = w.mq("doctor")
    check("doctor after the group: ok again (and the repo config is read from the clone)", r.returncode == 0 and "repo config at origin/main" in r.stdout and "all ok" in r.stdout, r.stdout)
    w.git(w.origin, "update-ref", "refs/heads/queue/main/g99", w.main_tip())
    r = w.mq("doctor")
    check("doctor: a queue branch no live group owns is named with the command to remove it", r.returncode == 1 and "queue/main/g99" in r.stdout and "git push origin --delete queue/main/g99" in r.stdout, r.stdout)
    w.git(w.origin, "update-ref", "-d", "refs/heads/queue/main/g99")
    wt = os.path.join(w.sdir(), "worktrees", "g98")
    w.git(os.path.join(w.sdir(), "work"), "worktree", "add", "-q", "--detach", wt, "HEAD")
    r = w.mq("doctor")
    check("doctor: a worktree no live group owns is named", r.returncode == 1 and "g98" in r.stdout, r.stdout)
    w.git(os.path.join(w.sdir(), "work"), "worktree", "remove", "--force", wt)
    w.put("systemd-run.fail", "1")
    w.pr(2, {"b.py": "2\n"})
    r = w.mq("add", "2")
    check("add when systemd-run fails still queues, says the driver was not started, exit 0", r.returncode == 0 and "NOT started" in r.stdout and w.entry(2)["state"] == "waiting", (r.stdout, r.stderr))
    check("the failed start is journaled", bool(w.events("driver_start_failed")))


def sc_state_files():
    import mq_state as S
    d = os.path.join(T, "atomic")
    os.makedirs(d)
    S.write_json_atomic(os.path.join(d, "x.json"), {"a": 1})
    check("an atomic write leaves the file and no temp file", sorted(os.listdir(d)) == ["x.json"] and json.load(open(os.path.join(d, "x.json"))) == {"a": 1}, os.listdir(d))
    os.environ["XDG_STATE_HOME"] = os.path.join(d, "st")
    p = S.Paths("o/r")
    check("state lives in $XDG_STATE_HOME/mergequeue/<owner>__<repo>/", p.dir == os.path.join(d, "st", "mergequeue", "o__r") and p.queue.endswith("queue.json") and p.events.endswith("events.log"))
    del os.environ["XDG_STATE_HOME"]
    check("repo names are validated", S.valid_repo("a/b") and not S.valid_repo("a/../b") and not S.valid_repo("a") and not S.valid_repo("a/b/c"))



# ---- the merge push, statuses, pause (step 3) ------------------------------------------------------------------------------------------------

def spawn_driver(w, env=None):
    """A driver in the background (it ends on its own when the line empties); the caller waits for its lock to be free."""
    out = open(os.path.join(w.d, "driver-bg.out"), "a")
    p = subprocess.Popen([sys.executable, "-I", os.path.join(ROOT, "lib", "mq", "main.py"), "drive", "--repo", REPO], env=dict(w.env, **(env or {})),
                         stdin=subprocess.DEVNULL, stdout=out, stderr=out, start_new_session=True)
    return p


def finish_driver(p, secs=60):
    try:
        p.wait(timeout=secs)
    except subprocess.TimeoutExpired:      # the test failed to make the driver leave: say so, the finally removes the folder, and the driver is this test's own child
        p.terminate()
        p.wait(timeout=10)
        return False
    return True


def subjects(w, rev, n=20):
    return w.git(w.origin, "log", "--first-parent", "--format=%s", "-n", str(n), rev).splitlines()


def to_on(w, extra=""):
    w.host_mode("on", extra)


def sc_merge_on():
    w = World("merge-on", ci_mode="going:1")
    main0 = w.main_tip()
    for n in (1, 2, 3):
        w.pr(n, {"app/f%d.py" % n: "%d\n" % n})
    r = w.mq("add", "1", "2", "3")
    check("add in shadow queues the PRs", r.returncode == 0, r.stderr)
    to_on(w)
    d = w.drive()
    check("driver exits 0", d.returncode == 0, d.stderr)
    g1, g2, g3 = w.group("g1"), w.group("g2"), w.group("g3")
    check("the tested head of the last entry is main now: a fast-forward over the old tip", w.main_tip() == g3["head"] and w.git(w.origin, "merge-base", "--is-ancestor", main0, g3["head"]) == "", (w.main_tip(), g3["head"]))
    check("main holds the three merge commits in queue order", subjects(w, "main")[:3] == ["Merge pull request #3 from acme/pr-3", "Merge pull request #2 from acme/pr-2", "Merge pull request #1 from acme/pr-1"], subjects(w, "main"))
    check("the PRs are merged, each with its entry and the commit in the reason", w.states(1, 2, 3) == {1: "merged", 2: "merged", 3: "merged"} and g1["head"][:7] in w.entry(1)["reason"] and
          "group g1" in w.entry(1)["reason"] and "group g3" in w.entry(3)["reason"], [w.entry(n) for n in (1, 2, 3)])
    check("the entry record: merged, outcome and sha", g3["state"] == "merged" and g3["outcome"] == "merged" and g3["merged_sha"] == g3["head"] and g3["phase"] == "done", g3)
    st = [c for c in w.calls() if c.startswith("gh status")]
    check("each PR got a pending status when its entry started testing and a success when merged (six writes)",
          len(st) == 6 and sum(" pending " in c for c in st) == 3 and sum(" success " in c for c in st) == 3, st)
    check("the statuses go to the PR heads, under the context 'merge queue'", all(c.split()[2] in (g["members"][0]["head"][:7] for g in (g1, g2, g3)) for c in st) and open(os.path.join(w.fake, "status.context")).read() == "merge queue", st)
    check("no comment for a PR that merged", w.ncalls("gh comment") == 0)
    check("GitHub calls of each entry: 1 GraphQL at the build, 1 at the merge, 2 statuses", all(g["gh_calls"].get("graphql") == 2 and g["gh_calls"].get("status") == 2 for g in (g1, g2, g3)), [g["gh_calls"] for g in (g1, g2, g3)])
    check("the entry branches are gone, the main branch stays", w.branches() == ["main"], w.branches())
    check("the merges are in the journal, in line order, one push each", [(e["group"], e["prs"], e["pushed"]) for e in w.events("merged")] ==
          [("g1", [1], True), ("g2", [2], True), ("g3", [3], True)], w.events("merged"))
    wr = w.mq("wait", "2", "--timeout", "5")
    check("wait: merged is exit 0, naming its entry", wr.returncode == 0 and "merged" in wr.stdout and "[g2]" in wr.stdout, (wr.returncode, wr.stdout))
    r = w.mq("add", "9")
    check("mq add accepts mode on", r.returncode == 0 and "PR 9: queued" in r.stdout and "not open" not in r.stderr, (r.returncode, r.stdout, r.stderr))


def sc_stale_and_pr_checks():
    # main moves after the group passed
    w = World("stale")
    w.pr(1, {"app/a.py": "a\n"})
    w.pr(2, {"app/b.py": "b\n"})
    w.mq("add", "1", "2")
    d = w.drive(env={"MQ_CRASH_AT": "verdict"})
    check("the driver stopped at the verdict (injected)", d.returncode == 75 and w.group("g1")["phase"] == "verdict", d.returncode)
    moved = w.main_commit({"docs/new.md": "new\n"}, msg="a doc lands on main")
    to_on(w)
    w.drive()
    check("main moved after the group was tested: the group was stale and its PRs were rebuilt on the new main, then merged", w.states(1, 2) == {1: "merged", 2: "merged"}, w.queue())
    g1 = w.group("g1")
    check("the stale group says why", g1["state"] == "stale" and "moved from" in g1["outcome_reason"], g1)
    check("the new main keeps the commit that landed meanwhile", w.git(w.origin, "merge-base", "--is-ancestor", moved, w.main_tip()) == "")
    check("the stale entry never pushed to main (no merge event for it); the rebuilt entries merged in line order", [e["group"] for e in w.events("merged")] == ["g3", "g4"], w.events("merged"))
    check("the stale PR went back to the line once (a rebuild); the one behind it was only restacked on the entry before it, which is not a rebuild", w.entry(1).get("rebuilds") == 1 and
          not w.entry(2).get("rebuilds") and w.group("g2")["outcome"] == "restack", (w.entry(1), w.entry(2)))

    # a PR changes after the group was tested
    w = World("changed")
    w.pr(1, {"app/a.py": "a\n"})
    w.pr(2, {"app/b.py": "b\n"})
    w.mq("add", "1", "2")
    w.drive(env={"MQ_CRASH_AT": "verdict"})
    w.set_pr(2, head="f" * 40)
    to_on(w)
    w.drive()
    st = w.states(1, 2)
    check("a PR whose head changed before the push is ejected; the rest is rebuilt and merged", st == {1: "merged", 2: "ejected"}, st)
    check("no status or comment for the ejected PR (it was not queue's doing)", "left the group" in w.entry(2)["reason"] and not w.comments(), (w.entry(2), w.comments()))
    tree = w.git(w.origin, "ls-tree", "-r", "--name-only", "main").split()
    check("main has PR 1 only", "app/a.py" in tree and "app/b.py" not in tree, tree)
    w = World("dropped")
    w.pr(1, {"app/a.py": "a\n"})
    w.pr(2, {"app/b.py": "b\n"})
    w.mq("add", "1", "2")
    w.drive(env={"MQ_CRASH_AT": "verdict"})
    w.mq("drop", "2")
    to_on(w)
    w.drive()
    tree = w.git(w.origin, "ls-tree", "-r", "--name-only", "main").split()
    check("a PR dropped after its group was tested is not merged; the other is rebuilt and merged", w.states(1, 2) == {1: "merged", 2: "dropped"} and "app/a.py" in tree and "app/b.py" not in tree, (w.queue(), tree))
    w = World("closed")
    w.pr(1, {"app/a.py": "a\n"})
    w.mq("add", "1")
    w.drive(env={"MQ_CRASH_AT": "verdict"})
    w.set_pr(1, state="CLOSED")
    to_on(w)
    main0 = w.main_tip()
    w.drive()
    check("a PR closed before the push: nothing is pushed", w.states(1) == {1: "ejected"} and w.main_tip() == main0, (w.queue(), w.main_tip()))


def sc_crash_after_push():
    w = World("crash-push")
    w.pr(1, {"app/a.py": "a\n"})
    w.pr(2, {"app/b.py": "b\n"})
    w.mq("add", "1", "2")
    to_on(w)
    d = w.drive(env={"MQ_CRASH_AT": "merging"})
    check("the driver stopped as the merge phase began (injected)", d.returncode == 75 and w.group("g1")["phase"] == "merging", d.returncode)
    head = w.group("g1")["head"]
    w.git(w.origin, "update-ref", "refs/heads/main", head)         # the push happened, and the driver died before it wrote that down
    w.drive()
    check("a fresh driver finds the head in main already: merged, no second push for it", w.states(1, 2) == {1: "merged", 2: "merged"} and w.events("merged")[0]["pushed"] is False and
          w.events("merged")[0]["group"] == "g1", w.events("merged"))
    check("the entry behind it, stacked on that head, then merged: main is its head", w.main_tip() == w.group("g2")["head"] and w.events("merged")[1]["pushed"] is True, w.events("merged"))


def sc_deploy_lock():
    w = World("dlock")
    lockp = os.path.join(w.d, "deploy.lock")
    w.pr(1, {"app/a.py": "a\n"})
    w.mq("add", "1")
    to_on(w, 'deploy_lock = "%s"\n' % lockp)
    w.drive(env={"MQ_CRASH_AT": "merging"})
    main0 = w.main_tip()
    held = os.open(lockp, os.O_RDWR | os.O_CREAT)
    fcntl.flock(held, fcntl.LOCK_EX)
    p = spawn_driver(w)
    ok = wait_until(lambda: bool(w.events("deploy_lock_busy")), 20)
    check("the merge waits while the deploy lock is held, and says so once", ok and w.main_tip() == main0 and len(w.events("deploy_lock_busy")) == 1, w.events())
    fcntl.flock(held, fcntl.LOCK_UN)
    os.close(held)
    check("the driver merges once the lock is free and leaves", finish_driver(p) and w.states(1) == {1: "merged"} and w.main_tip() != main0, w.queue())


def sc_pause_resume():
    w = World("pause")
    w.pr(1, {"app/a.py": "a\n"})
    r = w.mq("pause", "--reason", "main is red")
    check("pause: exit 0", r.returncode == 0 and "paused" in r.stdout, (r.stdout, r.stderr))
    w.mq("add", "1")
    d = w.drive()
    check("a paused queue starts no group; the driver leaves with nothing done", d.returncode == 0 and w.ncalls("gh") == 0 and not os.path.isdir(os.path.join(w.sdir(), "groups", "g1.json")) and w.states(1) == {1: "waiting"}, (d.returncode, w.calls(), w.queue()))
    r = w.mq("status")
    check("status says PAUSED with the reason", "PAUSED: main is red" in r.stdout, r.stdout)
    check("status --json carries it", json.loads(w.mq("status", "--json").stdout)["paused"]["reason"] == "main is red")
    r = w.mq("doctor")
    check("doctor names the pause and is not a problem by itself", "PAUSED" in r.stdout and r.returncode == 0, (r.returncode, r.stdout))
    r = w.mq("pause")
    check("a second pause changes nothing", "already paused: main is red" in r.stdout, r.stdout)
    n_run = w.ncalls("systemd-run")
    r = w.mq("resume")
    check("resume: exit 0, starts the driver", r.returncode == 0 and "resumed" in r.stdout and w.ncalls("systemd-run") == n_run + 1, (r.stdout, w.calls()))
    w.drive()
    check("after resume the PR is tested", w.states(1) == {1: "tested"}, w.queue())
    check("resume when not paused says so", "not paused" in w.mq("resume").stdout)
    # pause while a group waits to merge
    w = World("pause-merge")
    w.pr(1, {"app/a.py": "a\n"})
    w.mq("add", "1")
    to_on(w)
    w.drive(env={"MQ_CRASH_AT": "merging"})
    main0 = w.main_tip()
    w.mq("pause", "--reason", "hold")
    p = spawn_driver(w)
    time.sleep(1.0)
    check("a paused queue pushes nothing to main, the group waits in merging", w.main_tip() == main0 and w.group("g1")["phase"] == "merging" and p.poll() is None, w.group("g1")["phase"])
    w.mq("resume")
    check("resumed: the waiting group merges and the driver leaves", finish_driver(p) and w.states(1) == {1: "merged"}, w.queue())


def sc_push_failure_pauses():
    w = World("pushfail")
    w.pr(1, {"app/a.py": "a\n"})
    w.mq("add", "1")
    to_on(w)
    w.drive(env={"MQ_CRASH_AT": "merging"})
    hook = os.path.join(w.origin, "hooks", "pre-receive")
    with open(hook, "w") as f:
        f.write("#!/bin/sh\nwhile read old new ref; do [ \"$ref\" = refs/heads/main ] && { echo 'main is closed' >&2; exit 1; }; done\nexit 0\n")
    os.chmod(hook, 0o755)
    main0 = w.main_tip()
    p = spawn_driver(w)
    ok = wait_until(lambda: bool(w.queue().get("paused")), 30)
    check("a push to main that keeps failing pauses the queue and keeps the group tested", ok and "merge push of g1 failed 3 times" in w.queue()["paused"]["reason"] and w.queue()["paused"]["by"] == "driver" and w.main_tip() == main0 and w.states(1) == {1: "grouped"}, w.queue())
    os.unlink(hook)
    w.mq("resume")
    check("after the cause is fixed and resume, the group merges (it was never failed)", finish_driver(p) and w.states(1) == {1: "merged"}, w.queue())


def sc_status_best_effort():
    w = World("statusfail")
    w.pr(1, {"app/a.py": "a\n"})
    w.mq("add", "1")
    to_on(w)
    w.put("status.fail", "1")
    w.drive()
    check("a status write that fails is journaled and does not stop the merge", w.states(1) == {1: "merged"} and len(w.events("status_failed")) >= 1, (w.queue(), w.events("status_failed")))
    check("the failed writes are counted in the record", w.group("g1")["gh_calls"].get("status", 0) >= 2, w.group("g1")["gh_calls"])


def sc_conflict_on_notifies():
    w = World("conflict-on")
    base = w.main_tip()
    w.pr(1, {"app/core.py": "def core():\n    return 'one'\n"}, base_sha=base)
    w.pr(2, {"app/core.py": "def core():\n    return 'two'\n"}, base_sha=base)
    w.mq("add", "1", "2")
    to_on(w)
    w.drive()
    check("a conflicting PR is ejected, told by a failure status and one comment; the other merges", w.states(1, 2) == {1: "merged", 2: "ejected"}, w.queue())
    check("one comment, for PR 2, naming the conflict", [c[0] for c in w.comments()] == ["2"] and "conflicts with" in w.comments()[0][1], w.comments())
    w2 = World("conflict-shadow")
    b = w2.main_tip()
    w2.pr(1, {"app/core.py": "x = 1\n"}, base_sha=b)
    w2.pr(2, {"app/core.py": "x = 2\n"}, base_sha=b)
    w2.mq("add", "1", "2")
    w2.drive()
    check("in shadow the same ejection writes nothing to GitHub", w2.ncalls("gh status") == 0 and w2.ncalls("gh comment") == 0)


def sc_rebuild_limit():
    w = World("rebuilds")
    w.pr(1, {"app/a.py": "a\n"})
    w.mq("add", "1")
    w.drive(env={"MQ_CRASH_AT": "verdict"})
    w.main_commit({"docs/x.md": "x\n"})
    to_on(w)
    w.drive(env={"MQ_MAX_REBUILDS": "0"})
    check("a PR sent back more often than MQ_MAX_REBUILDS fails with that said", w.states(1) == {1: "failed"} and "gave up" in w.entry(1)["reason"], w.entry(1))
    check("it failed with a status and a comment", len(w.comments()) == 1, w.comments())


# ---- the chain (one entry per PR, each stacked on the entry ahead, tested side by side, merged in order) -------------------

CHAIN = 'queue_mode = "chain"\ninflight_max = 6\n'


def group_files(w):
    try:
        return sorted(n for n in os.listdir(os.path.join(w.sdir(), "groups")) if n.endswith(".json"))
    except OSError:
        return []


def phase_of(w, gid):
    try:
        return w.group(gid)["phase"]
    except (OSError, ValueError):
        return None


def peak_live(w):
    live = peak = 0
    for e in w.events():
        if e["ev"] == "group_start":
            live += 1
            peak = max(peak, live)
        elif e["ev"] == "group_done":
            live -= 1
    return peak


def sc_chain_in_order():
    w = World("chain-order", mode="on", config=CHAIN, pending=3)
    for n in (1, 2, 3):
        w.pr(n, {"app/f%d.py" % n: "%d\n" % n})
    r = w.mq("add", "1", "2", "3")
    check("chain: add queues the PRs", r.returncode == 0 and r.stdout.count("queued") == 3, r.stdout + r.stderr)
    d = w.drive()
    check("chain: the driver exits 0", d.returncode == 0, d.stderr)
    g1, g2, g3 = w.group("g1"), w.group("g2"), w.group("g3")
    check("chain: three entries of one PR each, stacked: g2 on g1, g3 on g2", [len(g["members"]) for g in (g1, g2, g3)] == [1, 1, 1] and
          [g["stack_on"] for g in (g1, g2, g3)] == [None, "g1", "g2"], [g.get("stack_on") for g in (g1, g2, g3)])
    check("chain: each entry starts from the head of the entry ahead of it, and they share one base", g2["stack_base"] == g1["head"] and g3["stack_base"] == g2["head"] and
          g1["base"] == g2["base"] == g3["base"] and g3["ahead"] == [1, 2], (g2["stack_base"], g1["head"], g3["ahead"]))
    check("chain: entry k is entry k-1 plus one merge commit", w.git(w.origin, "rev-parse", g2["head"] + "^1") == g1["head"] and w.git(w.origin, "rev-parse", g3["head"] + "^1") == g2["head"])
    check("chain: main is the last entry's head, a fast-forward with the merge commits in line order", w.main_tip() == g3["head"] and
          subjects(w, "main")[:3] == ["Merge pull request #3 from acme/pr-3", "Merge pull request #2 from acme/pr-2", "Merge pull request #1 from acme/pr-1"], subjects(w, "main"))
    check("chain: all three PRs merged", w.states(1, 2, 3) == {1: "merged", 2: "merged", 3: "merged"}, w.queue())
    ev = [(e["ev"], e.get("group")) for e in w.events() if e["ev"] in ("pushed", "merged")]
    first_merge = ev.index(("merged", "g1"))
    check("chain: speculative: all three entries were pushed (tested side by side) before the first one merged", [x for x in ev[:first_merge] if x[0] == "pushed"] ==
          [("pushed", "g1"), ("pushed", "g2"), ("pushed", "g3")], ev)
    check("chain: merged strictly in line order", [g for e, g in ev if e == "merged"] == ["g1", "g2", "g3"], ev)
    check("chain: three entries were in flight together", peak_live(w) == 3, peak_live(w))
    check("chain: every queue branch is gone", w.branches() == ["main"], w.branches())
    st = [c for c in w.calls() if c.startswith("gh status")]
    check("chain: the pending status says what the entry sits on", any("testing in group g3 with #3 on top of #1 #2" in c for c in st) and any("testing in group g1 with #1" in c and "on top" not in c for c in st), st)
    check("chain: two GraphQL reads per entry (the build, the merge step), no comment", w.ncalls("gh graphql") == 6 and w.ncalls("gh comment") == 0, w.calls())
    wr = w.mq("wait", "3", "--timeout", "5")
    check("chain: wait on the last PR: merged, exit 0, its entry named", wr.returncode == 0 and "[g3]" in wr.stdout, (wr.returncode, wr.stdout))


def sc_chain_middle_fails():
    lockp = os.path.join(T, "chain-fail", "deploy.lock")
    w = World("chain-fail", mode="on", config=CHAIN, host_extra='deploy_lock = "%s"\n' % lockp)
    w.pr(1, {"app/f1.py": "1\n"})
    w.pr(2, {"app/BAD_2": "bad\n"})
    w.pr(3, {"app/f3.py": "3\n"})
    w.put("ci.never", "1")                               # the three entries are tested together: none gets a verdict until all three are built and pushed
    main0 = w.main_tip()
    w.mq("add", "1", "2", "3")
    held = os.open(lockp, os.O_RDWR | os.O_CREAT)
    fcntl.flock(held, fcntl.LOCK_EX)                     # entry 1 passes but cannot merge: it is still in flight when entry 2 fails
    p = spawn_driver(w)
    try:
        up = wait_until(lambda: all(phase_of(w, g) == "testing" for g in ("g1", "g2", "g3")), 30)
        check("chain: three entries testing at once", up, group_files(w))
        os.unlink(os.path.join(w.fake, "ci.never"))
        ok = wait_until(lambda: bool(w.events("restack")) and phase_of(w, "g4") in ("pushed", "testing", "verdict", "merging"), 30)
        check("chain: the middle entry failed and the one behind it was rebuilt while entry 1 was still unmerged", ok, w.events())
        g1, g2, g3 = w.group("g1"), w.group("g2"), w.group("g3")
        check("chain: the failing PR is failed alone, no bisect", g2["outcome"] == "failed" and not g2.get("children") and w.entry(2)["state"] == "failed", (g2["outcome"], w.entry(2)))
        check("chain: the entry behind it was sent back (restack), its tree held the failing PR", g3["outcome"] == "restack" and g3["state"] == "stale" and "PR #2" in g3["outcome_reason"], g3)
        check("chain: a restack is not counted as a rebuild", not w.entry(3).get("rebuilds"), w.entry(3))
        g4 = w.group("g4")
        check("chain: PR 3 was built again on the entry ahead of the failed one: g4 stacked on g1", g4["stack_on"] == "g1" and g4["stack_base"] == g1["head"] and
              [m["pr"] for m in g4["members"]] == [3] and g4["ahead"] == [1], g4)
        check("chain: the rebuilt tree has PR 1 and PR 3 and not the failing PR", (lambda t: "app/f1.py" in t and "app/f3.py" in t and "app/BAD_2" not in t)(
            w.git(w.origin, "ls-tree", "-r", "--name-only", g4["head"]).split()), g4)
        check("chain: nothing reached main while entry 1 waited on the lock", w.main_tip() == main0)
    finally:
        fcntl.flock(held, fcntl.LOCK_UN)
        os.close(held)
    check("chain: the driver finishes", finish_driver(p), w.queue())
    check("chain: PR 1 and PR 3 merged, PR 2 failed", w.states(1, 2, 3) == {1: "merged", 2: "failed", 3: "merged"}, w.queue())
    tree = w.git(w.origin, "ls-tree", "-r", "--name-only", "main").split()
    check("chain: main holds PR 1 and PR 3 and not the failing PR", "app/f1.py" in tree and "app/f3.py" in tree and "app/BAD_2" not in tree, tree)
    check("chain: main is g4's head, on top of g1's", w.main_tip() == w.group("g4")["head"] and w.git(w.origin, "rev-parse", w.group("g4")["head"] + "^1") == w.group("g1")["head"])
    check("chain: merged in order, g1 then g4", [e["group"] for e in w.events("merged")] == ["g1", "g4"], w.events("merged"))
    check("chain: the failing PR got one failure status and one comment, nobody else a comment", [c[0] for c in w.comments()] == ["2"] and
          sum(1 for c in w.calls() if c.startswith("gh status") and " failure " in c) == 1, (w.comments(), w.calls()))
    check("chain: the PR sent back was told it is back in the line", any("back in the line" in c for c in w.calls() if c.startswith("gh status")))
    check("chain: every queue branch is gone", w.branches() == ["main"], w.branches())
    wr = w.mq("wait", "2", "--timeout", "5")
    check("chain: wait on the failed PR: exit 1 with the group named", wr.returncode == 1 and "failed suites" in wr.stderr and "[g2]" in wr.stderr, (wr.returncode, wr.stderr))


def sc_chain_first_fails():
    w = World("chain-first", mode="on", config=CHAIN)
    w.pr(1, {"app/BAD_1": "bad\n"})
    w.pr(2, {"app/f2.py": "2\n"})
    w.pr(3, {"app/f3.py": "3\n"})
    w.put("ci.never", "1")
    w.mq("add", "1", "2", "3")
    p = spawn_driver(w)
    up = wait_until(lambda: all(phase_of(w, g) == "testing" for g in ("g1", "g2", "g3")), 30)
    check("chain, first fails: three entries testing at once", up, group_files(w))
    os.unlink(os.path.join(w.fake, "ci.never"))
    check("chain, first fails: the driver finishes", finish_driver(p), w.queue())
    check("chain, first fails: PR 1 failed, the two behind it were sent back and merged", w.states(1, 2, 3) == {1: "failed", 2: "merged", 3: "merged"}, w.queue())
    check("chain, first fails: both entries behind it were restacked", sorted(e["group"] for e in w.events("restack")) == ["g2", "g3"], w.events("restack"))
    check("chain, first fails: the PRs sent back are not rebuild-counted", not w.entry(2).get("rebuilds") and not w.entry(3).get("rebuilds"), (w.entry(2), w.entry(3)))
    tree = w.git(w.origin, "ls-tree", "-r", "--name-only", "main").split()
    check("chain, first fails: main has PR 2 and PR 3 only", "app/f2.py" in tree and "app/f3.py" in tree and "app/BAD_1" not in tree, tree)
    check("chain, first fails: the rebuilt entries stack as before (the second on the first of them)", w.group("g5")["stack_on"] == "g4" and w.group("g4")["stack_on"] is None, (w.group("g4").get("stack_on"), w.group("g5").get("stack_on")))
    check("chain, first fails: one comment, for PR 1", [c[0] for c in w.comments()] == ["1"], w.comments())


def sc_chain_conflict_ahead():
    w = World("chain-conflict", mode="on", config=CHAIN, pending=2)
    w.pr(1, {"app/shared.py": "from one\n"})
    w.pr(2, {"app/shared.py": "from two\n"})
    w.pr(3, {"app/f3.py": "3\n"})
    w.mq("add", "1", "2", "3")
    d = w.drive()
    check("chain, conflict: the driver exits 0", d.returncode == 0, d.stderr)
    check("chain, conflict: the PR that conflicts with the one ahead is ejected, the others merge", w.states(1, 2, 3) == {1: "merged", 2: "ejected", 3: "merged"}, w.queue())
    check("chain, conflict: the reason names the PR ahead of it", "conflicts with main or with PR #1 ahead of it" in w.entry(2)["reason"], w.entry(2))
    check("chain, conflict: PR 3 sits right on PR 1's head", w.git(w.origin, "rev-parse", w.group(w.entry(3)["group"])["head"] + "^1") == w.group("g1")["head"])
    check("chain, conflict: main has PR 1's file and PR 3's", w.git(w.origin, "show", "main:app/shared.py") == "from one" and "app/f3.py" in w.git(w.origin, "ls-tree", "-r", "--name-only", "main").split())


def sc_chain_drop():
    w = World("chain-drop", mode="on", config=CHAIN)
    for n in (1, 2, 3):
        w.pr(n, {"app/f%d.py" % n: "%d\n" % n})
    w.put("ci.never", "1")
    w.mq("add", "1", "2", "3")
    p = spawn_driver(w)
    up = wait_until(lambda: all(phase_of(w, g) == "testing" for g in ("g1", "g2", "g3")), 30)
    check("chain, drop: three entries testing at once", up, group_files(w))
    r = w.mq("drop", "2")
    check("chain, drop: PR 2 dropped", r.returncode == 0, r.stderr)
    os.unlink(os.path.join(w.fake, "ci.never"))
    check("chain, drop: the driver finishes", finish_driver(p), w.queue())
    check("chain, drop: the dropped PR is out, the one behind it was rebuilt without it and merged", w.states(1, 2, 3) == {1: "merged", 2: "dropped", 3: "merged"}, w.queue())
    tree = w.git(w.origin, "ls-tree", "-r", "--name-only", "main").split()
    check("chain, drop: main holds PR 1 and PR 3 only", "app/f1.py" in tree and "app/f3.py" in tree and "app/f2.py" not in tree, tree)


def sc_chain_inflight():
    # inflight_max = 2: only two entries exist at once
    w = World("chain-inflight2", mode="on", config='queue_mode = "chain"\ninflight_max = 2\n')
    for n in range(1, 6):
        w.pr(n, {"app/f%d.py" % n: "%d\n" % n})
    w.put("ci.never", "1")
    w.mq("add", "1", "2", "3", "4", "5")
    p = spawn_driver(w)
    up = wait_until(lambda: all(phase_of(w, g) == "testing" for g in ("g1", "g2")), 30)
    time.sleep(0.6)                                       # long enough for a third to start if the limit were not held
    check("chain, inflight_max = 2: two entries testing and no third started", up and group_files(w) == ["g1.json", "g2.json"], group_files(w))
    os.unlink(os.path.join(w.fake, "ci.never"))
    check("chain, inflight_max = 2: the driver finishes", finish_driver(p), w.queue())
    check("chain, inflight_max = 2: never more than two in flight, all five merged in order", peak_live(w) == 2 and w.states(1, 2, 3, 4, 5) == {n: "merged" for n in range(1, 6)} and
          subjects(w, "main")[:5] == ["Merge pull request #%d from acme/pr-%d" % (n, n) for n in (5, 4, 3, 2, 1)], (peak_live(w), subjects(w, "main")))
    ev = [(e["ev"], e.get("group")) for e in w.events() if e["ev"] in ("group_start", "group_done")]
    check("chain, inflight_max = 2: the third starts only after the first is done", ev.index(("group_start", "g3")) > ev.index(("group_done", "g1")), ev)
    # no inflight_max in the file: a chain defaults to six
    w2 = World("chain-inflight6", mode="on", config='queue_mode = "chain"\n')
    for n in range(1, 9):
        w2.pr(n, {"app/f%d.py" % n: "%d\n" % n})
    w2.put("ci.never", "1")
    w2.mq("add", *[str(n) for n in range(1, 9)])
    p2 = spawn_driver(w2)
    up = wait_until(lambda: all(phase_of(w2, "g%d" % k) == "testing" for k in range(1, 7)), 60)
    time.sleep(0.6)
    check("chain, default inflight_max: six entries testing at once and no seventh", up and group_files(w2) == ["g%d.json" % k for k in range(1, 7)], group_files(w2))
    os.unlink(os.path.join(w2.fake, "ci.never"))
    check("chain, default inflight_max: the driver finishes and all eight merged", finish_driver(p2, 120) and set(w2.states(*range(1, 9)).values()) == {"merged"} and peak_live(w2) == 6, (w2.queue(), peak_live(w2)))


def sc_chain_shadow():
    w = World("chain-shadow", mode="shadow", config=CHAIN, pending=2)
    main0 = w.main_tip()
    for n in (1, 2, 3):
        w.pr(n, {"app/f%d.py" % n: "%d\n" % n} if n != 2 else {"app/BAD_2": "bad\n"})
    w.mq("add", "1", "2", "3")
    w.drive()
    check("chain, shadow: main is untouched, the line is settled", w.main_tip() == main0 and w.states(1, 2, 3) == {1: "tested", 2: "failed", 3: "tested"}, w.queue())
    g4 = w.group(w.entry(3)["group"])
    check("chain, shadow: the PR behind the failing one was rebuilt without it and tested", g4["id"] == "g4" and "app/BAD_2" not in w.git(w.origin, "ls-tree", "-r", "--name-only", g4["head"]), g4["id"])
    check("chain, shadow: no status, no comment, every queue branch gone", w.ncalls("gh status") == 0 and not w.comments() and w.branches() == ["main"], w.calls())


def sc_chain_config():
    import mq_config as C
    cfg, errs, warns = C.parse_repo_config('queue_mode = "chain"\n')
    check("config: queue_mode = chain is accepted without a warning; six in flight", not errs and not warns and cfg["inflight_max"] == 6 and cfg["queue_mode"] == "chain", (cfg, errs, warns))
    cfg, errs, warns = C.parse_repo_config('queue_mode = "chain"\ninflight_max = 3\n')
    check("config: inflight_max is honoured", not errs and not warns and cfg["inflight_max"] == 3, (cfg, errs, warns))
    for v in (0, 17, "3", True):
        check("config: inflight_max = %r is an error" % (v,), any("inflight_max" in e for e in C.check_repo_config({"inflight_max": v})[1]))
    cfg, errs, warns = C.parse_repo_config("")
    check("config: an empty file is the defaults: a chain, six in flight, no warning", cfg["queue_mode"] == "chain" and cfg["inflight_max"] == 6 and not errs and not warns, (cfg, errs, warns))
    cfg, errs, warns = C.parse_repo_config('queue_mode = "line"\n')
    check("config: an unknown queue_mode is an error", any("queue_mode" in e for e in errs), errs)
    check("config: the replay rules take the key too", not C.check_repo_config({"queue_mode": "chain", "base": "practice/x"})[1])


def sc_retired_keys():
    """Group mode is gone. `group_max` and `bisect` in a repo file are read, ignored and warned about (the warning names the fix); `queue_mode = "group"` blocks the queue and names the fix;
    `queue_mode = "chain"` is silent. A replay file's rules take the retired keys without an error."""
    import mq_config as C
    for key, line in (("group_max", "group_max = 4\n"), ("bisect", "bisect = true\n")):
        cfg, errs, warns = C.parse_repo_config(line)
        check("config: %s alone is not an error; it is warned about once, naming the key and the fix, and it is not kept" % key, not errs and len(warns) == 1 and key in warns[0] and "delete the line" in warns[0] and key not in cfg, (errs, warns, cfg))
    cfg, errs, warns = C.parse_repo_config('queue_mode = "chain"\ngroup_max = 4\nbisect = false\ninflight_max = 3\n')
    check("config: with both keys beside a chain, the other keys still count", not errs and len(warns) == 2 and cfg["inflight_max"] == 3 and cfg["queue_mode"] == "chain", (errs, warns, cfg))
    cfg, errs, warns = C.parse_repo_config('queue_mode = "group"\n')
    check("config: queue_mode = group is an error that names the fix", len(errs) == 1 and "group mode was removed" in errs[0] and 'queue_mode = "chain"' in errs[0] and cfg["queue_mode"] == "chain", (errs, cfg))
    errs = C.check_repo_config({"group_max": 2, "bisect": True, "base": "practice/x"})[1]
    check("config: the rules of a replay file take the retired keys without an error", not errs, errs)

    # a repo file that still names them: the queue works, the journal and doctor say what to delete
    w = World("retired", config="group_max = 3\nbisect = true\ninflight_max = 2\n", ci_mode="going:1")
    for n in (1, 2, 3):
        w.pr(n, {"app/r%d.py" % n: "%d\n" % n})
    w.mq("add", "1", "2", "3")
    w.drive()
    check("retired keys: the PRs are tested, one entry each (the keys changed nothing), and the queue is not blocked", w.states(1, 2, 3) == {1: "tested", 2: "tested", 3: "tested"} and
          [len(w.group(g)["members"]) for g in ("g1", "g2", "g3")] == [1, 1, 1] and w.queue()["blocked"] is None, (w.queue(), w.events()))
    check("retired keys: inflight_max beside them still holds", peak_live(w) == 2, peak_live(w))
    ws = [x for e in w.events("repo_config_warning") for x in e["warnings"]]
    check("retired keys: the journal names both keys and the fix", any("group_max" in x and "delete the line" in x for x in ws) and any("bisect" in x and "delete the line" in x for x in ws), w.events("repo_config_warning"))
    r = w.mq("doctor")
    check("retired keys: doctor warns for each key and exits 1", r.returncode == 1 and "retired key 'group_max'" in r.stdout and "retired key 'bisect'" in r.stdout and "delete the line" in r.stdout, (r.returncode, r.stdout))
    w.main_commit({".github/mergequeue.toml": 'queue_mode = "chain"\ninflight_max = 2\n'})
    w.pr(4, {"app/r4.py": "4\n"})
    w.mq("add", "4")
    w.drive()                                             # the next driver fetches main, and doctor reads the file from that fetch
    r = w.mq("doctor")
    check("retired keys: with the lines deleted, doctor is all ok", r.returncode == 0 and "retired key" not in r.stdout and "all ok" in r.stdout, (r.returncode, r.stdout))

    # queue_mode = "chain" alone is silent
    w2 = World("chain-silent", config='queue_mode = "chain"\n', ci_mode="going:1")
    w2.pr(1, {"app/s.py": "1\n"})
    w2.mq("add", "1")
    w2.drive()
    r = w2.mq("doctor")
    check("queue_mode = chain: tested, no warning in the journal, doctor all ok", w2.states(1) == {1: "tested"} and not w2.events("repo_config_warning") and r.returncode == 0 and "all ok" in r.stdout, (w2.events(), r.stdout))

    # queue_mode = "group": the queue is blocked until the line is deleted or set to chain
    w3 = World("group-refused", config='queue_mode = "group"\ngroup_max = 4\n')
    w3.pr(1, {"app/g.py": "1\n"})
    w3.mq("add", "1")
    d = w3.drive()
    q = w3.queue()
    check("queue_mode = group: the queue is blocked, the PR waits, nothing was fetched, the driver left", d.returncode == 0 and q["blocked"] and "group mode was removed" in q["blocked"]["reason"] and
          'queue_mode = "chain"' in q["blocked"]["reason"] and w3.entry(1)["state"] == "waiting" and w3.lock_free() and w3.ncalls("gh ") == 0, (q, d.stderr))
    st = w3.mq("status")
    check("queue_mode = group: status says BLOCKED and names the fix", "BLOCKED" in st.stdout and "delete the line" in st.stdout, st.stdout)
    wr = w3.mq("wait", "1", "--timeout", "5")
    check("queue_mode = group: wait is exit 2 with the reason", wr.returncode == 2 and "group mode was removed" in wr.stderr, (wr.returncode, wr.stderr))
    dr = w3.mq("doctor")
    check("queue_mode = group: doctor names the fix, exit 1", dr.returncode == 1 and "group mode was removed" in dr.stdout, dr.stdout)
    w3.main_commit({".github/mergequeue.toml": 'queue_mode = "chain"\n'})
    w3.drive()
    check("queue_mode = group, fixed on main: the next driver tests the PR and the block is cleared", w3.entry(1)["state"] == "tested" and w3.queue()["blocked"] is None, w3.queue())


# ---- replay (host key `replay`: the rules and the PR facts come from a file; lib/mq/mq_replay.py) --------------------------------------------------

PRACTICE, QPREFIX = "practice/r1/c01", "queue/practice/r1/c01/"


def orphan(w, files, base_sha, msg="recorded head"):
    """A commit that NO branch holds: made off base_sha, pushed to a throwaway branch, which is then deleted (the object stays in origin). → its sha."""
    w.git(w.src, "checkout", "-q", "-B", "orphan-tmp", base_sha)
    w.write_files(files)
    w.git(w.src, "add", "-A")
    w.git(w.src, "commit", "-q", "-m", msg)
    sha = w.git(w.src, "rev-parse", "HEAD")
    w.git(w.src, "push", "-q", "origin", "HEAD:refs/heads/orphan-tmp")
    w.git(w.src, "push", "-q", "origin", "--delete", "orphan-tmp")
    return sha


def replay_prs(**heads):
    return {str(n): {"state": "OPEN", "draft": False, "head": h, "branch": "pr-%s" % n, "owner": "acme", "checks": {"suites": "pass"}} for n, h in heads.items()}


def replay_doc(prs, rules=None, ci="real", run="r1", case="c01"):
    r = {"base": PRACTICE, "queue_prefix": QPREFIX}
    r.update(rules or {})
    return {"version": 1, "run": run, "case": case, "ci": ci, "rules": r, "prs": prs}


def replay_world(name, doc=None, ci_mode="going:1", config=None, host_mode="shadow", **kw):
    """A World whose host file names a replay file (w.rfile; written from doc when given) and has a practice base branch at main's tip."""
    w = World(name, mode=None, ci_mode=ci_mode, config=config, **kw)
    w.rfile = os.path.join(w.d, "replay.json")
    w.base_sha = w.main_tip()
    w.git(w.origin, "update-ref", "refs/heads/" + PRACTICE, w.base_sha)
    if doc is not None:
        w.write_replay(doc)
    os.makedirs(os.path.join(w.cfg, "mergequeue"), exist_ok=True)
    with open(os.path.join(w.cfg, "mergequeue", "acme__widgets.toml"), "w") as f:
        f.write(('mode = "%s"\n' % host_mode if host_mode else "") + 'remote = "%s"\nreplay = "%s"\n' % (w.origin, w.rfile))
    return w


def _watch_pushes(self):
    """From now on a pre-receive hook on origin logs every ref a push touches (pushed_refs()): call it after the setup, whose own pushes are not the queue's."""
    hook = os.path.join(self.origin, "hooks", "pre-receive")
    with open(hook, "w") as f:
        f.write('#!/bin/sh\nwhile read old new ref; do echo "$ref" >> "%s"; done\n' % os.path.join(self.fake, "pushed"))
    os.chmod(hook, 0o755)


def _write_replay(self, doc):
    with open(self.rfile, "w") as f:
        json.dump(doc, f)


def _pushed_refs(self):
    try:
        with open(os.path.join(self.fake, "pushed")) as f:
            return f.read().split()
    except OSError:
        return []


World.write_replay = _write_replay
World.watch_pushes = _watch_pushes
World.pushed_refs = _pushed_refs


def sc_replay_facts_from_file():
    """PR facts from the file though GitHub says MERGED; heads fetched by sha (one on no branch, one that refs/pull/N/head does not hold); rules from the file."""
    w = replay_world("replay-facts", config="this is = not [valid toml\n")      # origin/main's rules file is garbage: a replay must not read it
    main0 = w.main_tip()
    a = orphan(w, {"app/one.py": "one\n"}, w.base_sha)
    b = orphan(w, {"app/two.py": "two\n"}, w.base_sha)
    w.pr(1, {"app/ghost1.py": "x\n"}, state="MERGED", base_sha=w.base_sha)      # GitHub's side: merged, its base is main; refs/pull/1/head holds another commit
    w.pr(2, {"app/other2.py": "y\n"}, state="CLOSED", base_sha=w.base_sha)
    w.git(w.origin, "update-ref", "-d", "refs/pull/1/head")
    check("the recorded head is on no branch of origin", w.git(w.origin, "branch", "--contains", a) == "" and w.git(w.origin, "cat-file", "-t", a) == "commit")
    w.write_replay(replay_doc(replay_prs(**{"1": a, "2": b}), rules={"group_max": 2}))
    r = w.mq("add", "1", "2")
    check("add: replay mode is shadow, said in one line", r.returncode == 0 and "replay file" in r.stdout and "mode shadow" in r.stdout, (r.stdout, r.stderr))
    d = w.drive()
    check("the driver exits 0", d.returncode == 0, d.stderr)
    check("both PRs join and are tested though GitHub says MERGED / CLOSED", w.states(1, 2) == {1: "tested", 2: "tested"}, (w.queue(), w.events()))
    g, g2 = w.group("g1"), w.group("g2")
    check("the entries are built on the practice base and pushed as queue/practice/ branches", g["base_branch"] == PRACTICE and g["base"] == w.base_sha and g["branch"] == QPREFIX + "g1" and
          g2["branch"] == QPREFIX + "g2" and g["verdict"]["result"] == "pass" and g2["verdict"]["result"] == "pass", (g, g2))
    check("a retired key in the rules (stackshot's replay still writes group_max) is accepted and ignored: no replay error, no block", not w.queue()["blocked"] and "group_max" not in json.dumps(w.events("host_config_invalid")), w.events())
    check("no GraphQL call: the facts came from the file, once to build and once to recheck, for each entry", w.ncalls("gh graphql") == 0 and "graphql" not in g["gh_calls"] and len(w.events("replay_facts")) == 4, (w.calls(), g["gh_calls"], w.events("replay_facts")))
    tree = w.git(os.path.join(w.sdir(), "work"), "ls-tree", "-r", "--name-only", g2["head"]).split()
    check("the entries hold the heads fetched by sha, not what refs/pull/N/head or GitHub would give", "app/one.py" in tree and "app/two.py" in tree and "app/ghost1.py" not in tree and "app/other2.py" not in tree, tree)
    check("the members' heads are the recorded shas", [m["head"] for m in g["members"]] + [m["head"] for m in g2["members"]] == [a, b], (g["members"], g2["members"]))
    check("origin main and the practice base are untouched, every queue branch is gone", w.main_tip() == main0 and w.git(w.origin, "rev-parse", "refs/heads/" + PRACTICE) == w.base_sha and
          w.branches() == sorted(["main", PRACTICE]), w.branches())
    wr = w.mq("wait", "1", "--timeout", "5")
    check("ci real: wait says the entry passed, exit 3 (as always)", wr.returncode == 3 and "tested" in wr.stdout, (wr.returncode, wr.stdout, wr.stderr))


def sc_replay_missing_and_ejected():
    """A PR the file lacks is 'not found'; a recorded MERGED/draft state, a failed check and a sha origin does not have eject like on GitHub."""
    w = replay_world("replay-eject", ci_mode="going:1")
    ok = orphan(w, {"app/ok.py": "ok\n"}, w.base_sha)
    prs = replay_prs(**{"1": ok, "2": ok, "3": ok, "4": ok, "5": "1" * 40})
    prs["2"]["state"] = "MERGED"
    prs["3"]["draft"] = True
    prs["4"]["checks"] = {"tool-text": "fail", "suites": "pass"}
    w.write_replay(replay_doc(prs, rules={"group_max": 6}))
    w.mq("add", "1", "2", "3", "4", "5", "6")           # 6 is not in the file
    w.drive()
    st = w.states(1, 2, 3, 4, 5, 6)
    check("the PR missing from the file is ejected, the recorded ones as the facts say", st == {1: "tested", 2: "ejected", 3: "ejected", 4: "ejected", 5: "ejected", 6: "ejected"}, st)
    reasons = {p: w.entry(p)["reason"] for p in (2, 3, 4, 5, 6)}
    check("a missing PR reads as on GitHub: 'pull request not found'", reasons[6] == "pull request not found", reasons)
    check("a recorded MERGED state and a draft eject as they would", reasons[2] == "pull request is merged" and reasons[3] == "pull request is a draft", reasons)
    check("a recorded failed check refuses the PR in the words of the log line", reasons[4] == "refused: a check failed: tool-text=fail", reasons)
    check("a sha origin does not hold is ejected with that said", "cannot be fetched" in reasons[5] and "1111111" in reasons[5], reasons)
    check("the failed-check PR is not commented on or given a status (a replay never writes)", w.ncalls("gh status") == 0 and w.ncalls("gh comment") == 0 and not w.comments(), w.calls())


def sc_replay_guard_blocks():
    for tag, rules, word in (("base", {"base": "main"}, "rules.base"), ("base2", {"base": "release/1"}, "rules.base"), ("prefix", {"queue_prefix": "queue/main/"}, "rules.queue_prefix"),
                             ("prefix2", {"queue_prefix": "queue/other/"}, "rules.queue_prefix")):
        w = replay_world("replay-guard-" + tag)
        sha = orphan(w, {"app/x.py": "x\n"}, w.base_sha)
        w.write_replay(replay_doc(replay_prs(**{"1": sha}), rules=rules))
        w.watch_pushes()
        w.mq("add", "1")
        d = w.drive()
        q = w.queue()
        check("%s: a rules block outside practice/ blocks the queue with the reason" % tag, d.returncode == 0 and q["blocked"] and word in q["blocked"]["reason"] and "must start with" in q["blocked"]["reason"], (q, d.stderr))
        check("%s: nothing was built, fetched or pushed" % tag, w.entry(1)["state"] == "waiting" and not os.path.exists(os.path.join(w.sdir(), "groups", "g1.json")) and w.ncalls("gh ") == 0 and
              w.pushed_refs() == [] and not os.path.isdir(os.path.join(w.sdir(), "work")), (w.pushed_refs(), w.events()))
        wr = w.mq("wait", "1", "--timeout", "2")
        check("%s: wait says the queue is blocked, exit 2" % tag, wr.returncode == 2 and "blocked" in wr.stderr, (wr.returncode, wr.stderr))
        st = w.mq("status")
        check("%s: status says BLOCKED" % tag, "BLOCKED" in st.stdout and "REPLAY" in st.stdout, st.stdout)
        dr = w.mq("doctor")
        check("%s: doctor names it too" % tag, dr.returncode == 1 and word in dr.stdout, dr.stdout)


def sc_replay_bad_file():
    sha = "a" * 40
    good = replay_doc(replay_prs(**{"1": sha}))
    cases = [("an unknown top-level key", dict(good, bogus=1), "unknown key 'bogus'"),
             ("a wrong version", dict(good, version=2), "version must be 1"),
             ("a bad run id", dict(good, run="a b"), "run must be"),
             ("a bad ci", dict(good, ci="maybe"), "ci must be one of real|skip"),
             ("a bad rules value", replay_doc(replay_prs(**{"1": sha}), rules={"inflight_max": 0}), "inflight_max = 0 is not valid"),
             ("a bad rules list", replay_doc(replay_prs(**{"1": sha}), rules={"required": []}), "required = [] is not valid"),
             ("an unknown rules key (an error here, a warning in the repo file)", replay_doc(replay_prs(**{"1": sha}), rules={"nope": 1}), "unknown key 'nope'"),
             ("a short head sha", replay_doc(replay_prs(**{"1": "abc123"})), "head must be a full 40-hex sha"),
             ("an unknown PR key", replay_doc({"1": dict(replay_prs(**{"1": sha})["1"], extra=1)}), "unknown key 'extra'"),
             ("a bad check bucket", replay_doc({"1": dict(replay_prs(**{"1": sha})["1"], checks={"suites": "green"})}), "checks must map"),
             ("a PR key that is not a number", replay_doc({"one": replay_prs(**{"1": sha})["1"]}), "not a PR number")]
    w = replay_world("replay-badfile")
    for what, doc, word in cases:
        w.write_replay(doc)
        r = w.mq("add", "1")
        check("%s: add is refused with the message, nothing queued" % what, r.returncode == 1 and word in r.stderr and "replay file" in r.stderr and not os.path.exists(os.path.join(w.sdir(), "queue.json")) and
              w.ncalls("systemd-run") == 0, (r.returncode, r.stderr))
    with open(w.rfile, "w") as f:
        f.write("{not json")
    r = w.mq("add", "1")
    check("a file that is not JSON is refused", r.returncode == 1 and "not JSON" in r.stderr, r.stderr)
    os.unlink(w.rfile)
    r = w.mq("add", "1")
    check("a missing file is refused", r.returncode == 1 and "cannot be read" in r.stderr, r.stderr)
    with open(os.path.join(w.cfg, "mergequeue", "acme__widgets.toml"), "w") as f:
        f.write('mode = "shadow"\nremote = "%s"\nreplay = "relative/replay.json"\n' % w.origin)
    r = w.mq("add", "1")
    check("a relative path is refused", r.returncode == 1 and "absolute path" in r.stderr, r.stderr)
    w.write_replay(good)
    with open(os.path.join(w.cfg, "mergequeue", "acme__widgets.toml"), "w") as f:
        f.write('mode = "shadow"\nremote = "%s"\nreplay = 5\n' % w.origin)
    r = w.mq("add", "1")
    check("replay must be a string like the other host keys", r.returncode == 1 and "replay must be a string" in r.stderr, r.stderr)
    # a good file with a driver that finds the file broken later: the driver does nothing (mode off), as for a bad host file
    w2 = replay_world("replay-badlater", doc=good)
    w2.mq("add", "1")
    w2.write_replay(dict(good, bogus=1))
    w2.drive()
    check("a driver whose replay file went bad builds nothing", w2.entry(1)["state"] == "waiting" and w2.ncalls("gh ") == 0 and bool(w2.events("host_config_invalid")), w2.events())
    r = w2.mq("status", "--json")
    check("status shows the file's problems", "bogus" in json.dumps(json.loads(r.stdout)["host_config_errors"]), r.stdout)


def sc_replay_mode():
    w = replay_world("replay-mode", host_mode="on")
    sha = orphan(w, {"app/x.py": "x\n"}, w.base_sha)
    w.write_replay(replay_doc(replay_prs(**{"1": sha})))
    r = w.mq("add", "1")
    check('mode "on" with replay is refused, nothing queued, no driver asked for', r.returncode == 1 and "not allowed while replay is set" in r.stderr and not os.path.exists(os.path.join(w.sdir(), "queue.json")) and
          w.ncalls("systemd-run") == 0, (r.returncode, r.stderr))
    w2 = replay_world("replay-mode2", host_mode=None)
    w2.write_replay(replay_doc(replay_prs(**{"1": sha})))
    st = json.loads(w2.mq("status", "--json").stdout)
    check("no mode key with replay is shadow, not off", st["mode"] == "shadow" and st["replay"] == w2.rfile, st)
    w3 = replay_world("replay-mode3", host_mode="off")
    w3.write_replay(replay_doc(replay_prs(**{"1": sha})))
    r = w3.mq("add", "1")
    check("mode off stays off with replay", r.returncode == 1 and "mode is off" in r.stderr, r.stderr)
    # defence in depth: even a host dict that says on, with replay set, never merges or tells; and mq_git refuses a push outside queue/practice/
    import mq_driver
    import mq_git
    os.environ["XDG_STATE_HOME"] = w.state
    try:
        d = mq_driver.Driver(REPO)
        d.host = {"mode": "on", "replay": w.rfile}
        check("the driver never merges for a replay, whatever the mode says", d.merging() is False)
        d.host = {"mode": "on", "replay": None}
        check("(without replay the mode on still merges)", d.merging() is True)
    finally:
        os.environ.pop("XDG_STATE_HOME", None)
    g = mq_git.Git(os.path.join(w.d, "nowhere"), w.origin, "n", "e@x", only_push="queue/practice/")
    for what, fn in (("push_branch to main", lambda: g.push_branch("HEAD", "main")), ("push_fast_forward to the base", lambda: g.push_fast_forward("HEAD", PRACTICE)),
                     ("delete of main", lambda: g.delete_remote_branch("main"))):
        try:
            fn()
            ok = False
        except mq_git.GitError as e:
            ok = "outside queue/practice/" in str(e)
        check("mq_git refuses a %s while the replay guard is set" % what, ok)


def sc_replay_never_writes():
    """A replay with a failing PR, a refused PR and a conflict: no status, no comment, and every ref pushed to origin is a queue/practice/ entry branch."""
    w = replay_world("replay-nowrite", ci_mode="going:1")
    main0 = w.main_tip()
    good = {n: orphan(w, {"app/f%d.py" % n: "%d\n" % n}, w.base_sha) for n in (1, 2, 4)}
    bad = orphan(w, {"app/BAD_3": "bad\n"}, w.base_sha)
    refused = orphan(w, {"app/f5.py": "5\n"}, w.base_sha)
    clash_a = orphan(w, {"app/core.py": "def core():\n    return 'a'\n"}, w.base_sha)
    clash_b = orphan(w, {"app/core.py": "def core():\n    return 'b'\n"}, w.base_sha)
    prs = replay_prs(**{"1": good[1], "2": good[2], "3": bad, "4": good[4], "5": refused, "6": clash_a, "7": clash_b})
    prs["5"]["checks"] = {"suites": "fail"}
    w.write_replay(replay_doc(prs, rules={"inflight_max": 8}))
    w.watch_pushes()
    w.mq("add", "1", "2", "3", "4", "5", "6", "7")
    w.drive()
    st = w.states(1, 2, 3, 4, 5, 6, 7)
    check("the scenario ran: #3 failed alone, #5 was refused, #7 conflicts with #6", st == {1: "tested", 2: "tested", 3: "failed", 4: "tested", 5: "ejected", 6: "tested", 7: "ejected"}, (st, w.events("eject")))
    check("no commit status and no comment, though the PRs were refused, failed and ejected", w.ncalls("gh status") == 0 and w.ncalls("gh comment") == 0 and not w.comments(), w.calls())
    refs = w.pushed_refs()
    check("something was pushed (the entry branches)", len(refs) >= 4, refs)
    check("every ref a push touched is a queue/practice/ entry branch: not main, not the base", all(r.startswith("refs/heads/" + QPREFIX) for r in refs), refs)
    check("main and the practice base are exactly as they were, and every entry branch is gone", w.main_tip() == main0 and w.git(w.origin, "rev-parse", "refs/heads/" + PRACTICE) == w.base_sha and
          w.branches() == sorted(["main", PRACTICE]), w.branches())
    check("the only GitHub calls are the check-runs reads of the entry heads", all(c.startswith("gh check-runs") for c in w.calls() if c.startswith("gh ")), w.calls())


def sc_replay_unit_name():
    w = replay_world("replay-unit")
    sha = orphan(w, {"app/x.py": "x\n"}, w.base_sha)
    w.write_replay(replay_doc(replay_prs(**{"1": sha}), run="run-7", case="c13"))
    r = w.mq("add", "1")
    units = [c.split()[1] for c in w.calls() if c.startswith("systemd-run")]
    check("add: the driver's unit carries the run and the case, so it never collides with the repo's live driver", units == ["unit=mq-acme__widgets-run-7-c13"] and "mq-acme__widgets-run-7-c13" in r.stdout, (units, r.stdout))
    w.mq("wait", "1", "--timeout", "0.3")
    units = [c.split()[1] for c in w.calls() if c.startswith("systemd-run")]
    check("wait asks for a driver under the same name", len(units) >= 2 and set(units) == {"unit=mq-acme__widgets-run-7-c13"}, units)
    w.mq("pause")
    w.mq("resume")
    units = [c.split()[1] for c in w.calls() if c.startswith("systemd-run")]
    check("resume does too", set(units) == {"unit=mq-acme__widgets-run-7-c13"} and len(units) >= 3, units)
    w2 = World("noreplay-unit")
    w2.pr(1, {"a.py": "1\n"})
    w2.mq("add", "1")
    check("without replay the unit name is what it was", [c.split()[1] for c in w2.calls() if c.startswith("systemd-run")] == ["unit=mq-acme__widgets"], w2.calls())
    import mq_cli
    check("one function names the unit", mq_cli.unit_name(REPO, {}) == "mq-acme__widgets" and mq_cli.unit_name(REPO, {"replay_data": {"run": "a", "case": "b"}}) == "mq-acme__widgets-a-b")


def sc_replay_ci_skip():
    w = replay_world("replay-skip", ci_mode="unavailable")
    a = orphan(w, {"app/a.py": "a\n"}, w.base_sha)
    b = orphan(w, {"app/b.py": "b\n"}, w.base_sha)
    w.write_replay(replay_doc(replay_prs(**{"1": a, "2": b}), ci="skip", rules={"group_max": 2}))
    w.watch_pushes()
    r = w.mq("add", "1", "2")
    check("add says that entries are built only", r.returncode == 0 and "ci = skip" in r.stdout, r.stdout)
    w.drive()
    g, g2 = w.group("g1"), w.group("g2")
    check("each entry ends after `built`: verdict skipped, done, a head, no push, no branch", g["phase"] == "done" and g["verdict"]["result"] == "skipped" and g["head"] and not g["push_started"] and
          "push" not in g["git_remote"] and g["outcome"] == "tested" and g2["verdict"]["result"] == "skipped", (g, g2))
    check("no push of any kind reached origin, and no CI or GitHub call at all", w.pushed_refs() == [] and w.ncalls("gh ") == 0 and w.ncalls("salamander") == 0 and w.branches() == sorted(["main", PRACTICE]), (w.pushed_refs(), w.calls()))
    check("the journal has built and ci_skipped and no pushed or verdict", sorted(e["ev"] for e in w.events() if e["ev"] in ("built", "ci_skipped", "pushed", "verdict")) == ["built", "built", "ci_skipped", "ci_skipped"], w.events())
    check("the PRs are tested (CI not run), marked so", all(w.entry(n)["state"] == "tested" and w.entry(n)["reason"].startswith("tested (CI not run)") and w.entry(n)["ci"] == "skipped" for n in (1, 2)), w.queue())
    tree = w.git(os.path.join(w.sdir(), "work"), "ls-tree", "-r", "--name-only", g2["head"]).split()
    check("the second built entry, stacked on the first, holds both heads' work", "app/a.py" in tree and "app/b.py" in tree, tree)
    wr = w.mq("wait", "1", "--timeout", "5")
    check("wait on a skipped PR: exit 4, never the 3 of an entry that passed", wr.returncode == 4 and "CI not run" in wr.stdout and "not a pass" in wr.stdout and "[g1]" in wr.stdout, (wr.returncode, wr.stdout, wr.stderr))
    st = w.mq("status")
    check("status shows the replay file in use and the PRs", "REPLAY" in st.stdout and "tested" in st.stdout, st.stdout)
    check("no worktree or local branch is left", not os.listdir(os.path.join(w.sdir(), "worktrees")) and w.git(os.path.join(w.sdir(), "work"), "branch", "--list", QPREFIX + "*") == "")


def sc_replay_doctor():
    # the real queue's doctor must not warn about a replay's queue/practice/ branches
    w = World("replay-doctor-real")
    w.pr(1, {"a.py": "1\n"})
    w.mq("add", "1")
    w.drive()
    w.git(w.origin, "update-ref", "refs/heads/queue/practice/r1/c01/g7", w.main_tip())
    r = w.mq("doctor")
    check("doctor (prefix queue/main/) ignores a queue/practice/ branch", r.returncode == 0 and "queue/practice" not in r.stdout and "all ok" in r.stdout, r.stdout)
    w.git(w.origin, "update-ref", "refs/heads/queue/main/g99", w.main_tip())
    r = w.mq("doctor")
    check("doctor still names its own stale queue/main/ branch", r.returncode == 1 and "queue/main/g99" in r.stdout and "queue/practice" not in r.stdout, r.stdout)
    # the replay's doctor lists its own prefix only
    w2 = replay_world("replay-doctor-own", ci_mode="going:1")
    sha = orphan(w2, {"app/x.py": "x\n"}, w2.base_sha)
    w2.write_replay(replay_doc(replay_prs(**{"1": sha})))
    w2.mq("add", "1")
    w2.drive()
    w2.git(w2.origin, "update-ref", "refs/heads/" + QPREFIX + "g9", w2.main_tip())
    w2.git(w2.origin, "update-ref", "refs/heads/queue/main/g8", w2.main_tip())
    w2.git(w2.origin, "update-ref", "refs/heads/queue/practice/r2/c05/g3", w2.main_tip())
    r = w2.mq("doctor")
    check("replay doctor: says the replay file is in use, in one line", r.returncode == 1 and sum(1 for ln in r.stdout.splitlines() if "replay file" in ln and "rules and PR facts come from it" in ln) == 1, r.stdout)
    check("replay doctor lists its own prefix, not another queue's", QPREFIX + "g9" in r.stdout and "queue/main/g8" not in r.stdout and "queue/practice/r2" not in r.stdout, r.stdout)
    check("replay doctor does not read origin/main's rules", "the rules of the replay file" in r.stdout and "repo config at origin/main" not in r.stdout, r.stdout)
    st = w2.mq("status")
    check("status says plainly that a replay file is in use", [ln for ln in st.stdout.splitlines() if ln.startswith("REPLAY")] == ["REPLAY: rules and PR facts come from %s (shadow only; docs/mq.md Replay)" % w2.rfile], st.stdout)
    w2.git(w2.origin, "update-ref", "-d", "refs/heads/" + QPREFIX + "g9")
    w2.git(w2.origin, "update-ref", "-d", "refs/heads/queue/main/g8")
    w2.git(w2.origin, "update-ref", "-d", "refs/heads/queue/practice/r2/c05/g3")
    r = w2.mq("doctor")
    check("replay doctor is all ok when its own prefix is clean", r.returncode == 0 and "all ok" in r.stdout, r.stdout)


def put_group(w, g):
    with open(os.path.join(w.sdir(), "groups", g["id"] + ".json"), "w") as f:
        json.dump(g, f)


def put_queue(w, q):
    with open(os.path.join(w.sdir(), "queue.json"), "w") as f:
        json.dump(q, f)


def live_worktrees(w):
    d = os.path.join(w.sdir(), "worktrees")
    return sorted(os.listdir(d)) if os.path.isdir(d) else []


def sc_legacy_group_state():
    """State a group-mode driver left on disk (a multi-PR record, the parent and halves of a bisect, a merge whose push had happened, a finished group) must not wedge the queue after the upgrade:
    a record that is not a single-PR entry is retired (its PRs go back to the line, no rebuild counted, branch and worktree cleaned), and a tested one whose head is already in main is merged as it always was."""
    # A: a group of two PRs, pushed and testing when the old driver died, a finished group in the history, and a PR waiting behind them
    w = World("legacy-a", ci_mode="going:1")
    sha = {}
    for n in (1, 2, 3):
        sha[n] = w.pr(n, {"app/l%d.py" % n: "%d\n" % n})
    w.mq("add", "1")
    w.drive(env={"MQ_CRASH_AT": "testing"})
    g = w.group("g1")
    g["members"].append({"pr": 2, "head": sha[2], "owner": "acme", "branch": "pr-2", "state": "in", "reason": None})
    put_group(w, g)
    done = dict(g, id="g8", seq=8, phase="done", state="merged", outcome="merged", done_at=int(time.time()), branch="queue/main/g8", members=[dict(m, pr=m["pr"] + 20) for m in g["members"]])
    put_group(w, done)
    q = w.queue()
    q["entries"].append(dict(q["entries"][0], pr=2, group="g1"))
    q["next_seq"] = 9
    put_queue(w, q)
    w.mq("add", "3")
    check("A: the old record is in place: a two-PR group in testing, its branch on origin", len(w.group("g1")["members"]) == 2 and "queue/main/g1" in w.branches() and w.states(1, 2) == {1: "grouped", 2: "grouped"}, (w.queue(), w.branches()))
    d = w.drive()
    check("A: the driver runs to the end and exits 0", d.returncode == 0, d.stderr)
    check("A: every PR is tested, nobody is stuck in the old group", w.states(1, 2, 3) == {1: "tested", 2: "tested", 3: "tested"}, w.queue())
    g = w.group("g1")
    check("A: the old record was retired, not run: stale, sent back, journaled once with its PRs", g["phase"] == "done" and g["outcome"] == "restack" and g["state"] == "stale" and "group mode was removed" in g["outcome_reason"] and
          [(e["group"], e["prs"]) for e in w.events("legacy_group_retired")] == [("g1", [1, 2])], (g, w.events("legacy_group_retired")))
    new = [w.group("g%d" % k) for k in (9, 10, 11)]
    check("A: the PRs were built again as entries of one PR each, numbered after the history", [[m["pr"] for m in x["members"]] for x in new] == [[1], [2], [3]] and
          all(x["verdict"]["result"] == "pass" for x in new), [(x["id"], [m["pr"] for m in x["members"]]) for x in new])
    check("A: sending them back did not count as a rebuild", not any(w.entry(n).get("rebuilds") for n in (1, 2, 3)), w.queue())
    check("A: the old branch and worktree are gone, and no queue branch is left", w.branches() == ["main"] and live_worktrees(w) == [], (w.branches(), live_worktrees(w)))
    check("A: the finished group in the history is left as it was", w.group("g8")["phase"] == "done" and w.group("g8")["outcome"] == "merged")
    st = w.mq("status")
    dr = w.mq("doctor")
    check("A: status and doctor still work on the mixed history", st.returncode == 0 and dr.returncode == 0 and "all ok" in dr.stdout, (st.stderr, dr.stdout))

    # B: a bisect in progress: the parent (failed, bisecting) and its two halves, one of them pushed and testing
    w = World("legacy-b", ci_mode="going:1")
    for n in (1, 2):
        sha[n] = w.pr(n, {"app/m%d.py" % n: "%d\n" % n})
    w.mq("add", "1", "2")
    w.drive(env={"MQ_CRASH_AT": "testing"})
    g1, g2 = w.group("g1"), w.group("g2")
    parent = dict(g1, id="g3", seq=3, phase="bisecting", state="bisecting", outcome=None, branch="queue/main/g3", head=None, push_started=False, children=["g1", "g2"],
                  members=[g1["members"][0], dict(g1["members"][0], pr=2, head=sha[2], branch="pr-2")], verdict={"result": "fail"})
    put_group(w, parent)
    g1.update(parent="g3", siblings=["g2"])
    g2.update(parent="g3", siblings=["g1"], stack_on=None, stack_base=None, ahead=[])
    put_group(w, g1)
    put_group(w, g2)
    q = w.queue()
    q["next_seq"] = 4
    put_queue(w, q)
    d = w.drive()
    check("B: the driver runs to the end and exits 0", d.returncode == 0, d.stderr)
    check("B: both PRs are tested", w.states(1, 2) == {1: "tested", 2: "tested"}, w.queue())
    check("B: the parent and both halves were retired and cleaned", sorted(e["group"] for e in w.events("legacy_group_retired")) == ["g1", "g2", "g3"] and
          all(w.group(x)["phase"] == "done" for x in ("g1", "g2", "g3")) and w.branches() == ["main"] and live_worktrees(w) == [], (w.events("legacy_group_retired"), w.branches(), live_worktrees(w)))
    check("B: the PRs were built again as entries of one PR each", sorted([m["pr"] for m in w.group(x)["members"]] for x in ("g4", "g5")) == [[1], [2]], [w.group(x)["members"] for x in ("g4", "g5")])

    # C: mode on, a group of two PRs tested and pushed to main, the old driver died before it wrote it down: merged as it always was, no second push, no rebuild
    w = World("legacy-c", ci_mode="going:1")
    for n in (1, 2):
        sha[n] = w.pr(n, {"app/n%d.py" % n: "%d\n" % n})
    w.mq("add", "1", "2")
    to_on(w)
    w.drive(env={"MQ_CRASH_AT": "merging"})
    g1, g2 = w.group("g1"), w.group("g2")
    check("C: the setup has g2 built on g1 (its head holds both PRs)", g1["phase"] == "merging" and g2["head"] and g2["stack_on"] == "g1", (g1["phase"], g2))
    tree = w.git(w.origin, "ls-tree", "-r", "--name-only", g2["head"]).split()
    check("C: that head holds both PRs", "app/n1.py" in tree and "app/n2.py" in tree, tree)
    g1.update(members=g1["members"] + [dict(g2["members"][0])], head=g2["head"])
    put_group(w, g1)
    os.unlink(os.path.join(w.sdir(), "groups", "g2.json"))
    w.git(os.path.join(w.sdir(), "work"), "worktree", "remove", "--force", os.path.join(w.sdir(), "worktrees", "g2"))
    w.git(w.origin, "update-ref", "-d", "refs/heads/queue/main/g2")
    q = w.queue()
    q["entries"][1]["group"] = "g1"
    put_queue(w, q)
    w.git(w.origin, "update-ref", "refs/heads/main", g1["head"])        # the push happened
    d = w.drive()
    check("C: the driver exits 0 and both PRs are merged, none rebuilt", d.returncode == 0 and w.states(1, 2) == {1: "merged", 2: "merged"} and not any(w.entry(n).get("rebuilds") for n in (1, 2)), (d.stderr, w.queue()))
    check("C: journaled as merged without a push, and nothing was retired", [(e["group"], e["prs"], e["pushed"]) for e in w.events("merged")] == [("g1", [1, 2], False)] and
          not w.events("legacy_group_retired") and w.main_tip() == g1["head"], (w.events("merged"), w.events("legacy_group_retired")))
    check("C: no queue branch or worktree is left", w.branches() == ["main"] and live_worktrees(w) == [], (w.branches(), live_worktrees(w)))


def identity_env(w, global_cfg=False, include_clone=False):
    """w.env as a real machine has it: no identity in the environment, a throwaway HOME whose .gitconfig is the "global" one (a fake person's, never a real one) and, when
    include_clone is set, an includeIf rule that gives the work clone a neutral identity, as the repo's own rules do on a real machine."""
    env = {k: v for k, v in w.env.items() if not k.startswith(("GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_", "GIT_AUTHOR_", "GIT_COMMITTER_", "GIT_CONFIG_GLOBAL"))}
    gc = os.path.join(w.home, ".gitconfig")
    if os.path.exists(gc):
        os.unlink(gc)
    text = "[user]\n\tname = Example Person\n\temail = person@example.invalid\n" if global_cfg else ""
    if include_clone:
        neutral = os.path.join(w.d, "neutral.gitconfig")
        with open(neutral, "w") as f:
            f.write("[user]\n\tname = Queue Neutral\n\temail = neutral@example.invalid\n")
        text += '[includeIf "gitdir:%s/"]\n\tpath = %s\n' % (os.path.join(w.sdir(), "work"), neutral)
    if text:
        with open(gc, "w") as f:
            f.write(text)
    return env


def queue_branch_idents(w, branch="queue/main/g1"):
    """The author and committer (name <email>) of the newest commit of the entry's branch on origin, or a note when the branch is not there."""
    if branch not in w.branches():
        return "(no branch)"
    return w.git(w.origin, "log", "-1", "--format=%an <%ae>|%cn <%ce>", "refs/heads/" + branch)


def sc_identity():
    """The merge commits never carry the global git identity (a person's own): the host file's git_name / git_email win, a key left unset is read from the work clone, and the queue
    refuses (naming git_name and git_email) when the result is empty or is the global one. The "global" identity here is a fake person's in a throwaway HOME."""
    import mq_git
    REFUSED = "refusing to make merge commits"

    # (a) a global identity is set, the host file has no identity keys, the work clone gets a neutral identity of its own (an includeIf rule): the commits carry the clone's
    w = World("ident-a", ci_mode="going:1")
    w.pr(1, {"a.py": "1\n"})
    w.env = identity_env(w, global_cfg=True, include_clone=True)
    w.mq("add", "1")
    d = w.drive(env={"MQ_CRASH_AT": "pushed"})
    ids = queue_branch_idents(w)
    check("identity (a): the entry's merge commit carries the work clone's identity, author and committer", ids == "Queue Neutral <neutral@example.invalid>|Queue Neutral <neutral@example.invalid>", (ids, d.stderr[-300:]))
    check("identity (a): the global identity is on no commit of the branch", "queue/main/g1" in w.branches() and "Example Person" not in w.git(w.origin, "log", "--format=%an %ae %cn %ce", "refs/heads/queue/main/g1"))
    check("identity (a): the queue is not blocked", not w.queue().get("blocked"), w.queue().get("blocked"))

    # (b) the same, but the clone has no identity of its own: only the global one resolves → refused, naming both host keys, nothing built or pushed, no traceback
    w = World("ident-b", ci_mode="going:1")
    w.pr(1, {"a.py": "1\n"})
    w.env = identity_env(w, global_cfg=True)
    w.mq("add", "1")
    d = w.drive()
    blocked = (w.queue().get("blocked") or {}).get("reason", "")
    check("identity (b): the driver ends cleanly, with no traceback", d.returncode == 0 and "Traceback" not in d.stderr, (d.returncode, d.stderr[-300:]))
    check("identity (b): the queue is blocked with the refusal, which names git_name and git_email", REFUSED in blocked and "git_name" in blocked and "git_email" in blocked, blocked)
    check("identity (b): the refusal says the clone's value is the global identity, and does not print the person's name or email", "global git user.name" in blocked and "global git user.email" in blocked and
          "Example Person" not in blocked and "person@example.invalid" not in blocked, blocked)
    check("identity (b): the refusal is in the journal and nothing was pushed", [e["reason"] for e in w.events("blocked")] == [blocked] and w.branches() == ["main"], (w.events("blocked"), w.branches()))
    check("identity (b): the PR is still waiting, not ejected", w.entry(1)["state"] == "waiting", w.entry(1))
    r = w.mq("wait", "1", "--timeout", "1")
    check("identity (b): `mq wait` says the queue is blocked, exit 2", r.returncode == 2 and REFUSED in r.stderr, (r.returncode, r.stderr))
    r = w.mq("doctor")
    check("identity (b): `mq doctor` prints the same message as an error line, exit 1, no traceback", r.returncode == 1 and "FAIL" in r.stdout and REFUSED in r.stdout and "git_name" in r.stdout and "git_email" in r.stdout and
          "Traceback" not in r.stderr, (r.returncode, r.stdout[-500:], r.stderr[-300:]))

    # (c) the host file's keys win (same world: only the global identity resolves for the clone; the block lifts at the next start)
    w.host_mode("shadow", 'git_name = "Host Named"\ngit_email = "host@example.invalid"\n')
    r = w.mq("doctor")
    check("identity (c): with the host keys set, `mq doctor` has no identity error (the old block is still named, as a warning, until the queue starts again)",
          "FAIL" not in r.stdout and "merge commit identity" in r.stdout, r.stdout)
    d = w.drive(env={"MQ_CRASH_AT": "pushed"})
    ids = queue_branch_idents(w)
    check("identity (c): the commits carry the host file's identity, never the global one", ids == "Host Named <host@example.invalid>|Host Named <host@example.invalid>", (ids, d.stderr[-300:]))
    check("identity (c): the block is cleared", not w.queue().get("blocked"), w.queue().get("blocked"))

    # (c2) the host file's keys win over a neutral clone identity too
    w = World("ident-c2", ci_mode="going:1", host_extra='git_name = "Host Named"\ngit_email = "host@example.invalid"\n')
    w.pr(1, {"a.py": "1\n"})
    w.env = identity_env(w, global_cfg=True, include_clone=True)
    w.mq("add", "1")
    w.drive(env={"MQ_CRASH_AT": "pushed"})
    ids = queue_branch_idents(w)
    check("identity (c2): the host file's identity wins over the work clone's", ids == "Host Named <host@example.invalid>|Host Named <host@example.invalid>", ids)

    # (d) nothing resolves at all (no global identity, no clone identity, no host keys) → refused; with one host key set, the other is named
    w = World("ident-d", ci_mode="going:1")
    w.pr(1, {"a.py": "1\n"})
    w.env = identity_env(w)
    w.mq("add", "1")
    d = w.drive()
    blocked = (w.queue().get("blocked") or {}).get("reason", "")
    check("identity (d): nothing resolves → refused, naming git_name and git_email, no fallback identity used", REFUSED in blocked and "git_name" in blocked and "git_email" in blocked and "user.name is not set" in blocked and
          "user.email is not set" in blocked and w.branches() == ["main"] and "Traceback" not in d.stderr, (blocked, w.branches(), d.stderr[-300:]))
    w.host_mode("shadow", 'git_name = "Host Named"\n')
    d = w.drive()
    blocked = (w.queue().get("blocked") or {}).get("reason", "")
    check("identity (d): with only git_name set the refusal is about the email", REFUSED in blocked and "user.email is not set" in blocked and "user.name is not set" not in blocked, blocked)
    r = w.mq("doctor")
    check("identity (d): `mq doctor` says the same", r.returncode == 1 and "user.email is not set" in r.stdout and "Traceback" not in r.stderr, (r.stdout[-400:], r.stderr[-300:]))

    # the class itself: no clone yet and a key unset → no verdict yet (the clone is asked once it exists); both keys set → fine with no clone; a commit verb with no identity raises
    nowhere = os.path.join(T, "ident-none", "work")
    check("identity (unit): no clone yet and keys unset → no verdict yet", mq_git.Git(nowhere, "x").identity_problem() is None)
    check("identity (unit): both host keys set → no problem, even with no clone", mq_git.Git(nowhere, "x", "A Name", "a@example.invalid").identity_problem() is None)
    try:
        mq_git.Git(nowhere, "x").run(["commit", "-m", "x"], cwd=T)
        raised = False
    except mq_git.IdentityError as e:
        raised = REFUSED in str(e) and "git_name" in str(e) and "git_email" in str(e)
    check("identity (unit): a commit with no safe identity raises IdentityError naming both host keys", raised)
    check("identity (unit): IdentityError is a GitError, so no caller lets it through as a crash", issubclass(mq_git.IdentityError, mq_git.GitError))


SCENARIOS = [sc_state_files, sc_entry_passes, sc_etag_without_poller, sc_failing_entry, sc_lone_pr_and_rerun, sc_conflicts, sc_snapshot_hook, sc_graphql_ejections,
             sc_pr_checks_refuse, sc_conflict_after_main_moves,
             sc_head_moved, sc_config_inflight, sc_invalid_config_blocks, sc_gh_failures, sc_no_verdict_in_time, sc_crash_recovery, sc_code_reexec, sc_driver_lock, sc_driver_start_race, sc_drop,
             sc_wait_codes, sc_modes, sc_status_and_default_repo, sc_doctor, sc_merge_on, sc_stale_and_pr_checks, sc_crash_after_push, sc_deploy_lock,
             sc_pause_resume, sc_push_failure_pauses, sc_status_best_effort, sc_conflict_on_notifies, sc_rebuild_limit,
             sc_replay_facts_from_file, sc_replay_missing_and_ejected, sc_replay_guard_blocks, sc_replay_bad_file, sc_replay_mode, sc_replay_never_writes, sc_replay_unit_name,
             sc_replay_ci_skip, sc_replay_doctor,
             sc_chain_config, sc_retired_keys, sc_chain_in_order, sc_chain_middle_fails, sc_chain_first_fails, sc_chain_conflict_ahead, sc_chain_drop, sc_chain_inflight, sc_chain_shadow, sc_legacy_group_state, sc_identity]


def main():
    only = sys.argv[1:]
    for sc in SCENARIOS:
        if only and sc.__name__ not in only:
            continue
        t0 = time.time()
        n0, f0 = len(ran), len(fails)
        try:
            sc()
        except Exception as e:      # a scenario that raises is a failure, not a crash of the rest
            import traceback
            fails.append(sc.__name__ + " raised")
            print("FAIL %s raised: %s" % (sc.__name__, e))
            traceback.print_exc()
        print("%s %s: %d checks, %.1fs" % ("ok  " if len(fails) == f0 else "FAIL", sc.__name__, len(ran) - n0, time.time() - t0), flush=True)


try:
    main()
finally:
    # the drivers a fake systemd-run started end on their own (the line empties); wait for their locks, then remove the folder. Nothing is killed.
    for w in SPAWNED:
        wait_until(w.lock_free, 60)
    os.close(_lock)
    shutil.rmtree(T, ignore_errors=True)
print("mq scenarios: %d checks, %d failed" % (len(ran), len(fails)))
sys.exit(1 if fails else 0)
