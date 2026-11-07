"""lib/mq/mq_driver.py — the driver: the one process per repo that turns the line into queue entries, tests them and writes the verdict down (docs/mq.md).

It is `mq drive`, started by `mq add` / `mq wait` as a transient user unit (systemd-run --user), holds driver.lock for its life and exits when the line is empty and
nothing is in flight. All progress is in the files: an entry's record names its phase (building, built, pushed, testing, verdict, cleaning, done; merging between verdict and
cleaning in mode on) and each phase is re-entered after a crash, so any CLI call that finds work and no live driver may start a fresh one.

The queue is a chain, as GitHub's merge queue is: every entry is ONE PR, stacked on the entry ahead of it (`stack_on`: the entry ahead, `stack_base`: its head, which this entry's
worktree starts from instead of main), so entry k is main plus PRs 1..k in line order. (The records are kept in groups/g<seq>.json and the entries are called groups in the code,
the journal and `mq status --json`: the names date from group mode, which was removed, and stackshot reads them.) What an entry goes through: claim the first waiting PR, read the
PR in ONE GraphQL call (open, not a draft, the base branch, the head sha, which is pinned), fetch main and refs/pull/N/head, `git merge --no-ff` the pinned head onto main or onto the
head of the entry ahead in a worktree of the work clone (the snapshot-only conflict hook; any other conflict ejects the PR), push queue/main/g<seq>, wait for the required check on
that head (the poller's file says "still going" for free; otherwise one check-runs read, with the last ETag), and write the verdict into the record and the journal. All entries
are built, pushed and tested side by side, up to inflight_max, in every mode. Then, by the verdict, once the entry ahead is settled:

  pass  mode shadow: the PR is `tested` and the journal says `would_merge`; nothing is pushed to main.
        mode on: phase `merging` pushes the tested head to main as a fast-forward (never forced) and the PR is `merged`. Before the push it takes the repo's
        deploy lock (host `deploy_lock`), fetches main and reads the PR once more (open, same head); if main moved since the entry's base, or the PR left or
        changed, the tested tree is no longer what main would get and the entry is STALE: its PR goes back to `waiting` (at its place in the line) to be
        rebuilt on the new main (`MQ_MAX_REBUILDS`, 3, then it fails). A tested head that is in main's history already (a crash after the push) is `merged` without a push.
  fail  the PR is `failed`, alone: its tree held only the PRs ahead of it, and those have passed. A failure is only the PR's own once the entry ahead has passed; until then the
        entry waits with its verdict, because the failure may be a PR ahead's.
  error, timeout, empty  the PR is `failed` with the reason.

The entries behind an entry that leaves (failed, ejected, dropped, stale, built again with another head) hold its PR in their trees, so they are RESTACKED: sent back to the line
(no rebuild counted) and built again on the entry ahead of the one that left, or on main.

A PR is also held to its own head: when it joins (the GraphQL read) and again before its verdict counts (the merge step in mode on, `recheck_shadow` in shadow), a PR with a
failed check ("refused: a check failed: <name>=fail", repo key pr_required) or one that no longer merges into the base branch ("refused: conflicts with main") is ejected, in the words of
release.sh's FAILED lines. Shadow does not rebuild the entry for it; mode on makes the entry stale and rebuilds it without the PR.

In mode on a PR's head also gets a commit status (context "merge queue": pending while its entry is tested, success when merged, failure when it fails or is
ejected for a conflict) and ONE comment when it is taken out of the line. Shadow mode posts neither. A paused queue (`mq pause`) starts no entry and pushes
nothing to main; entries in flight finish testing and wait in `merging`.

Records left by group mode (an entry with several PRs, or a half or parent of a bisect) are not run: the driver retires each at its next step, sends its PRs back to the line and
builds them again as entries (`retire_legacy`).

The driver outlives releases: a release that changes lib/mq/*.py does not reach a process already running, so at the top of each loop (between passes, every phase of the last
pass saved to its record; never inside one) it compares the (name, mtime_ns, size) of every *.py beside this file with what it started with. A change that stays the same for
MQ_CODE_SETTLE_SECS (2; a checkout replaces files one by one) journals `code_changed` and re-executes the same interpreter with the same arguments (os.execv: the PID, so the
systemd unit, stays). driver.lock is an flock on an open file description; the driver marks that descriptor inheritable and names it in MQ_LOCK_FD, so the new image holds the SAME
lock from its first instruction and a second driver can never slip in (releasing and re-taking would leave a gap). If the new code does not import, the process dies, the lock goes
with it, the unit ends failed, and the next `mq add` / `wait` / `resume` starts a driver; the crash recovery below takes the entry from its record. No loop of execs: the new image
fingerprints what it loaded. MQ_CRASH_AT=<phase> makes the driver exit (code 75, no cleanup) right after it writes that phase to the entry's record: the tests' crash injection.
Timing, all overridable (the tests shorten them): MQ_TICK_SECS 2, MQ_POLL_SECS 60, MQ_WAIT_CAP_SECS 6000, MQ_MAX_FAILS 5, MQ_BACKOFF_SECS 30, MQ_KEEP_SECS 86400,
MQ_MAX_REBUILDS 3.

Replay (host key `replay`, mq_replay.py): the rules and the PR facts come from a file, a PR's content is fetched by its recorded sha, nothing is ever merged, set as a status or commented
(merging() is False), and mq_git refuses a push outside queue/practice/. With `ci = "skip"` an entry ends after phase `built`: no push, no CI, the PR `tested (CI not run)`.
"""
import fcntl
import os
import shlex
import subprocess
import sys
import time

import mq_config as C
import mq_gh as H
import mq_git as G
import mq_replay as R
import mq_state as S

CRASH_EXIT = 75
LOCK_ENV = "MQ_LOCK_FD"      # "<fd>:<device>:<inode>" of driver.lock, handed to the next image of the driver across an exec
CODE_DIR = os.path.dirname(os.path.abspath(__file__))
LIVE = ("building", "built", "pushed", "testing", "verdict", "merging")      # the phases in which an entry can still be sent back to the line
MAIN = "main"      # the branch the repo config is read from (a PR cannot change its own rules)
# The words of a refusal, parallel to release.sh's FAILED lines ("a check failed: <name>=<bucket>"), so the shadow comparison reads both the same way
REFUSED_CHECK = "refused: a check failed: "
REFUSED_CONFLICT = "refused: conflicts with main"


def code_fingerprint(code_dir=CODE_DIR):
    """(name, mtime_ns, size) of every *.py in the driver's own folder, sorted; a stat per file, no hashing. () when the folder cannot be read."""
    out = []
    try:
        with os.scandir(code_dir) as it:
            for e in it:
                if e.name.endswith(".py") and e.is_file():
                    st = e.stat()
                    out.append((e.name, st.st_mtime_ns, st.st_size))
    except OSError:
        return ()
    return tuple(sorted(out))


def fingerprint_diff(old, new):
    """A short description of what differs between two fingerprints, for the journal."""
    o, n = {f[0]: f[1:] for f in old}, {f[0]: f[1:] for f in new}
    return sorted(k + ("" if k in o and k in n else " (added)" if k in n else " (removed)") for k in set(o) | set(n) if o.get(k) != n.get(k))[:8]


class Driver:
    def __init__(self, repo):
        self.repo = repo
        self.paths = S.Paths(repo)
        self.tick = S.env_float("MQ_TICK_SECS", 2)
        self.poll = S.env_float("MQ_POLL_SECS", 60)
        self.cap = S.env_float("MQ_WAIT_CAP_SECS", 6000)
        self.max_fails = int(S.env_float("MQ_MAX_FAILS", 5))
        self.backoff = S.env_float("MQ_BACKOFF_SECS", 30)
        self.keep = S.env_float("MQ_KEEP_SECS", 86400)
        self.max_rebuilds = int(S.env_float("MQ_MAX_REBUILDS", 3))
        self.lockfd = None
        self.host = None
        self.git = None
        self.cfg = None
        self.fails = {}
        self.not_before = {}
        self.last_poll = {}
        self.start_fails = 0
        self.start_not_before = 0.0
        self.blocked_now = False
        self.code_dir = CODE_DIR
        self.code_settle = S.env_float("MQ_CODE_SETTLE_SECS", 2)
        self.code_fp = code_fingerprint(self.code_dir)
        self.code_seen = None            # (fingerprint, first time seen) of a change waiting to settle
        self.reexeced = False

    def j(self, ev, **kw):
        S.journal(self.paths, ev, **kw)

    # ---- life ----
    def run(self):
        self.paths.ensure()
        fd = self.adopt_lock()
        self.reexeced = fd is not None
        if fd is None:
            fd = S.try_lock(self.paths.dlock, tries=4)    # a liveness check (driver_alive) holds the lock for an instant: wait that out, not a live driver
        if fd is None:
            self.j("driver_busy", pid=os.getpid(), note="another driver holds driver.lock; this one leaves")
            return 0
        self.lockfd = fd
        since = int(time.time())
        if self.reexeced:
            since = ((S.lock_holder_info(self.paths) or {}).get("since")) or since
        S.write_json_atomic(self.paths.dinfo, {"pid": os.getpid(), "since": since})
        if self.reexeced:
            self.j("driver_start", pid=os.getpid(), reexec=True)
        else:
            self.j("driver_start", pid=os.getpid())
        try:
            while True:
                self.reexec_if_changed()
                progressed = self.pass_once()
                if self.idle():
                    if self.leave():
                        return 0
                    continue
                if not progressed:
                    time.sleep(self.tick)
        except Exception as e:      # a bug, not a failed step: say so in the journal (the unit's own log has the trace) and let the next CLI call start a fresh driver
            self.j("driver_crash", pid=os.getpid(), error="%s: %s" % (type(e).__name__, str(e)[:200]))
            raise
        finally:
            if self.lockfd is not None:
                os.close(self.lockfd)
                self.lockfd = None

    def adopt_lock(self):
        """The previous image of this driver (reexec_if_changed) left driver.lock open and named it in MQ_LOCK_FD: take that descriptor over, if it is in fact driver.lock. → the fd, or None."""
        spec = os.environ.pop(LOCK_ENV, None)      # popped at once: nothing this process starts may read it
        if not spec:
            return None
        try:
            fd, dev, ino = (int(x) for x in spec.split(":"))
            st, now = os.fstat(fd), os.stat(self.paths.dlock)
            if (st.st_dev, st.st_ino) != (dev, ino) or (now.st_dev, now.st_ino) != (dev, ino):
                return None
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)      # the same open file description, so it is already ours and this returns at once; a stray one is only taken if free
            os.set_inheritable(fd, False)
            return fd
        except (ValueError, OSError):
            return None

    def reexec_if_changed(self):
        """The safe point: the top of the loop, every phase of the last pass saved to its record. A change in lib/mq/*.py that has stayed the same for code_settle seconds ends
        in an exec of this same interpreter and arguments (sys.orig_argv keeps -I), so the next pass runs the new code; the PID, and so the systemd unit, stays."""
        fp = code_fingerprint(self.code_dir)
        if not fp or fp == self.code_fp:
            self.code_seen = None
            return
        now = time.monotonic()
        if self.code_seen is None or self.code_seen[0] != fp:
            self.code_seen = (fp, now)             # a checkout replaces files one by one: wait for it to stop moving
            return
        if now - self.code_seen[1] < self.code_settle:
            return
        self.j("code_changed", pid=os.getpid(), files=fingerprint_diff(self.code_fp, fp), old_files=len(self.code_fp), new_files=len(fp),
               note="the driver's code changed on disk; it re-executes itself between passes")
        try:
            st = os.fstat(self.lockfd)
            # The lock is handed over, not released and re-taken: an flock belongs to the open file description, which survives exec once the descriptor is inheritable,
            # so the new image holds it from its first instruction and no second driver can start in a gap.
            os.set_inheritable(self.lockfd, True)
            os.environ[LOCK_ENV] = "%d:%d:%d" % (self.lockfd, st.st_dev, st.st_ino)
            sys.stdout.flush()
            sys.stderr.flush()
            os.execve(sys.executable, [sys.executable] + sys.orig_argv[1:], os.environ)
        except OSError as e:                       # the interpreter is gone or the like: go on with the code in memory, and do not try again for this change
            os.environ.pop(LOCK_ENV, None)
            try:
                os.set_inheritable(self.lockfd, False)
            except OSError:
                pass
            self.j("code_reexec_failed", pid=os.getpid(), error="%s: %s" % (type(e).__name__, str(e)[:160]))
            self.code_fp, self.code_seen = fp, None

    def refresh_host(self):
        host, errs = C.load_host(self.repo)
        if errs:
            self.j("host_config_invalid", errors=errs)
            host = dict(host, mode="off")                  # an unreadable host file does nothing
        self.host = host
        work = host["clone"] or self.paths.work
        only = R.QUEUE_PREFIX if host.get("replay") else None
        if self.git is None or self.git.work != work or self.git.remote != host["remote"] or self.git.only_push != only:
            self.git = G.Git(work, host["remote"], host["git_name"], host["git_email"], only_push=only)

    def replay(self):
        """The parsed replay file when the host key is set (and valid), else None."""
        return self.host.get("replay_data") if self.host and self.host.get("replay") else None

    def pr_facts(self, g, numbers):
        """The facts of the PRs, for the build, the merge step and the shadow recheck alike: one GraphQL read, or the replay file."""
        return H.graphql_prs(self.repo, numbers, g["gh_calls"], self.j, replay=self.replay())

    def fetch_head(self, g, m):
        """PR m's pinned head into refs/mq/pull/N: from refs/pull/N/head, or by its recorded sha in a replay. → the sha fetched."""
        return self.git.fetch_pr(m["pr"], g["git_remote"], sha=m["head"] if self.replay() else None)

    def can_start(self):
        return self.host["mode"] in ("shadow", "on")

    def merging(self):
        return self.host["mode"] == "on" and not self.host.get("replay")      # a replay never merges, posts a status or comments

    def startable(self, q):
        """A waiting PR can be made an entry now: the mode runs the queue, the queue is not paused or blocked."""
        return any(e["state"] == S.WAITING for e in q["entries"]) and self.can_start() and not self.blocked_now and not q.get("paused")

    def inflight_limit(self):
        """Entries in flight: inflight_max of the repo's rules (6 when the rules do not say). The entries are stacked on one another, so they are tested together, in every mode."""
        return (self.cfg or C.REPO_DEFAULTS)["inflight_max"]

    def snapshot(self):
        q = S.load_queue(self.paths)
        groups = [g for g in S.list_groups(self.paths) if g["phase"] != "done" and g.get("seq", 0) < q["next_seq"]]
        return q, groups

    def idle(self):
        q, groups = self.snapshot()
        if groups:
            return False
        return not self.startable(q)

    def leave(self):
        """Release the lock, look once more (an `mq add` that ran between the idle check and now saw this driver alive and started none), and either
        leave or take the lock back and go on."""
        self.prune()
        try:
            os.unlink(self.paths.dinfo)
        except OSError:
            pass
        self.j("driver_exit", pid=os.getpid())      # written while the lock is still held, so the journal's order is the lock's order
        os.close(self.lockfd)
        self.lockfd = None
        q, groups = self.snapshot()
        work = bool(groups) or self.startable(q)
        if work:
            fd = S.try_lock(self.paths.dlock)
            if fd is not None:
                self.lockfd = fd
                S.write_json_atomic(self.paths.dinfo, {"pid": os.getpid(), "since": int(time.time())})
                self.j("driver_start", pid=os.getpid(), resumed=True)
                return False
        return True

    def prune(self):
        cut = time.time() - self.keep

        def fn(q):
            q["entries"] = [e for e in q["entries"] if e["state"] in S.ACTIVE or (e.get("ended") or 0) >= cut]
        try:
            S.update_queue(self.paths, fn)
            for g in S.list_groups(self.paths):
                if g["phase"] == "done" and (g.get("done_at") or 0) < time.time() - 7 * 86400:
                    os.unlink(self.paths.group(g["id"]))
        except (S.StateError, OSError):
            pass

    # ---- one pass ----
    def pass_once(self):
        self.refresh_host()
        progressed = False
        q, groups = self.snapshot()
        for g in groups:
            if time.time() < self.not_before.get(g["id"], 0):
                continue
            if self.advance(g):
                progressed = True
        q, groups = self.snapshot()
        if self.startable(q) and len(groups) < self.inflight_limit() and time.time() >= self.start_not_before:
            if self.start_group():
                progressed = True
        return progressed

    def crash_point(self, phase):
        if os.environ.get("MQ_CRASH_AT") == phase:
            self.j("crash_injected", phase=phase)
            os._exit(CRASH_EXIT)

    def set_phase(self, g, phase):
        g["phase"] = phase
        S.save_group(self.paths, g)
        self.j("phase", group=g["id"], phase=phase)
        self.crash_point(phase)

    def block(self, reason):
        self.blocked_now = True
        if (S.load_queue(self.paths).get("blocked") or {}).get("reason") != reason:
            self.j("blocked", reason=reason)

        def fn(q):
            q["blocked"] = {"reason": reason, "since": int(time.time())}
        S.update_queue(self.paths, fn)

    # ---- claiming an entry ----
    def start_group(self):
        pre = {}
        rp = self.replay()
        if self.host.get("replay") and rp is None:
            return False                       # the replay file is unreadable: refresh_host has put the mode at off and the journal says why
        if rp is not None and R.guard(rp["rules"]):
            self.block("; ".join(R.guard(rp["rules"]))[:200])
            return False
        try:
            self.git.ensure_clone(pre)
            if rp is None:
                base_sha = self.git.fetch_base(MAIN, pre)
                text = self.git.show_file("refs/remotes/origin/" + MAIN, ".github/mergequeue.toml")
        except G.GitError as e:
            self.start_fails += 1
            self.j("sync_failed", error=str(e)[:200], count=self.start_fails)
            if self.start_fails >= self.max_fails:
                self.block("origin cannot be reached: " + str(e)[:140])
            self.start_not_before = time.time() + self.backoff * self.start_fails
            return False
        self.start_fails = 0
        if rp is not None:
            cfg, warns = {k: (list(v) if isinstance(v, list) else v) for k, v in rp["rules"].items()}, []      # the rules of the replay file, not origin/main's
        else:
            cfg, errs, warns = C.parse_repo_config(text)
            if errs:
                self.block("the repo config is not valid: " + "; ".join(errs)[:200])
                return False
        if warns:
            self.j("repo_config_warning", warnings=warns)
        base = cfg["base"]
        try:
            if rp is not None or base != MAIN:
                base_sha = self.git.fetch_base(base, pre)
        except G.GitError as e:
            self.block("base branch %s cannot be fetched: %s" % (base, str(e)[:120]))
            return False
        self.cfg = cfg
        if len(self.snapshot()[1]) >= self.inflight_limit():
            return False
        stack = self.chain_tail(base_sha)
        if stack is False:
            return False                   # the entries in flight are not ready to be stacked on (see chain_tail); the next pass looks again

        def claim(q):
            waiting = [e for e in q["entries"] if e["state"] == S.WAITING][:1]      # one PR an entry
            if not waiting:
                return None
            seq = q["next_seq"]
            keys = ("required", "pr_required", "suites", "on_conflict", "conflict_paths", "flaky", "queue_prefix", "inflight_max")
            g = self.new_group(seq, base, base_sha, {k: cfg[k] for k in keys},
                               [{"pr": e["pr"], "state": "in", "head": None, "branch": None, "owner": None, "reason": None} for e in waiting], stack=stack)
            g["git_remote"] = dict(pre)
            S.save_group(self.paths, g)     # inside queue.lock, before the line says so: a group file with seq >= next_seq is an orphan and ignored
            for e in waiting:
                e["state"], e["group"] = S.GROUPED, g["id"]
            q["next_seq"] = seq + 1
            q["blocked"] = None
            return g
        g = S.update_queue(self.paths, claim)
        if g is None:
            return False
        self.blocked_now = False
        self.j("group_start", group=g["id"], prs=[m["pr"] for m in g["members"]], base=g["base"][:7], branch=g["branch"], **({"stack_on": g["stack_on"]} if g["stack_on"] else {}))
        self.crash_point("building")
        return True

    # ---- the phases ----
    def advance(self, g):
        before = g["phase"]
        try:
            ph = g["phase"]
            if ph in LIVE + ("bisecting",) and self.legacy(g):
                self.retire_legacy(g)
                self.fails[g["id"]] = 0
                return True
            if ph in LIVE and self.chain_check(g):
                return True
            if ph == "building":
                self.build(g)
            elif ph == "built":
                self.push(g)
            elif ph in ("pushed", "testing"):
                self.test(g)
            elif ph == "verdict":
                self.resolve(g)
            elif ph == "merging":
                self.merge(g)
            elif ph == "cleaning":
                self.cleanup(g)
            self.fails[g["id"]] = 0
        except (G.GitError, H.GhError, S.StateError, OSError) as e:
            self.step_failed(g, e)
            return True
        return g["phase"] != before

    def step_failed(self, g, e):
        n = self.fails.get(g["id"], 0) + 1
        self.fails[g["id"]] = n
        self.j("step_failed", group=g["id"], phase=g["phase"], error=str(e)[:200], count=n)
        try:
            S.save_group(self.paths, g)       # the calls the failed step made are counted all the same
        except OSError:
            pass
        if n < self.max_fails:
            self.not_before[g["id"]] = time.time() + self.backoff * n
            return
        self.fails[g["id"]] = 0
        if g["phase"] == "merging":
            # a tested group is not a failed one: when the push to main keeps failing the queue pauses and the group waits in `merging` for `mq resume`
            self.pause("the merge push of %s failed %d times: %s" % (g["id"], n, str(e)[:100]), by="driver")
            return
        if g["phase"] == "cleaning":
            g["cleanup_incomplete"] = str(e)[:140]
            self.finalize_entries(g)
            g["done_at"] = int(time.time())
            self.set_phase(g, "done")
            return
        g["verdict"] = {"result": "error", "reason": "gave up in phase %s after %d failures: %s" % (g["phase"], n, str(e)[:100]), "at": int(time.time())}
        g["state"] = "error"
        self.set_phase(g, "verdict")

    def eject(self, g, m, reason, notify=False):
        m["state"], m["reason"] = "ejected", reason[:140]

        def fn(q):
            for e in q["entries"]:
                if e["pr"] == m["pr"] and e["state"] == S.GROUPED and e.get("group") == g["id"]:
                    S.finish_entry(e, S.EJECTED, reason[:140])
        S.update_queue(self.paths, fn)
        S.save_group(self.paths, g)
        self.j("eject", group=g["id"], pr=m["pr"], reason=reason[:140])
        if notify:
            self.tell_failure(g, m, reason[:120])

    def members_in(self, g):
        return [m for m in g["members"] if m["state"] == "in"]

    def no_members(self, g):
        g["verdict"] = {"result": "empty", "reason": "every PR was ejected from the group", "at": int(time.time())}
        self.set_phase(g, "verdict")

    def sync_dropped(self, g):
        """A PR dropped (mq drop) after the group was claimed leaves the group before it is built."""
        q = S.load_queue(self.paths)
        for m in self.members_in(g):
            gone = [e for e in q["entries"] if e["pr"] == m["pr"] and e.get("group") == g["id"] and e["state"] == S.DROPPED]
            if gone:
                m["state"], m["reason"] = "ejected", "dropped"
        S.save_group(self.paths, g)

    def build(self, g):
        git, counts = self.git, g["git_remote"]
        self.sync_dropped(g)
        if not self.members_in(g):
            return self.no_members(g)
        if not g["checked"]:
            members = self.members_in(g)
            info = self.pr_facts(g, [m["pr"] for m in members])
            S.save_group(self.paths, g)
            for m in members:
                p = info.get(m["pr"])
                why, told = None, False
                if p is None:
                    why = "pull request not found"
                elif p["state"] != "OPEN":
                    why = "pull request is %s" % (p["state"] or "?").lower()
                elif p["draft"]:
                    why = "pull request is a draft"
                elif p["base"] != g["base_branch"]:
                    why = "targets %s, not %s" % (p["base"], g["base_branch"])
                elif not p["head"]:
                    why = "no head commit"
                else:
                    bad = H.failed_checks(p["checks"], g["config"].get("pr_required", "all"))
                    if bad:
                        why, told = REFUSED_CHECK + ", ".join(bad), True
                        m.update(head=p["head"], branch=p["branch"], owner=p["owner"])      # the PR is told on the head whose checks failed
                if why:
                    self.eject(g, m, why, notify=told)
                else:
                    m.update(head=p["head"], branch=p["branch"], owner=p["owner"])
            g["checked"] = True
            S.save_group(self.paths, g)
        if not self.members_in(g):
            return self.no_members(g)
        if g["build_started"]:
            # a crash left this group half built: the branch may be on the remote with a sha a rebuild will not reproduce
            git.delete_remote_branch(g["branch"], counts)
        g["build_started"] = True
        S.save_group(self.paths, g)
        for m in self.members_in(g):
            try:
                sha = self.fetch_head(g, m)
            except G.GitError as e:
                if self.replay() and ("find remote ref" in str(e) or "not our ref" in str(e)):
                    self.eject(g, m, "head %s cannot be fetched from origin" % m["head"][:7])
                    continue
                if "find remote ref" in str(e):
                    self.eject(g, m, "refs/pull/%d/head does not exist" % m["pr"])
                    continue
                raise
            if sha != m["head"]:
                self.eject(g, m, "head moved since it was read (%s, now %s)" % (m["head"][:7], sha[:7]))
        if not self.members_in(g):
            return self.no_members(g)
        wt = os.path.join(self.paths.wt, g["id"])
        git.worktree_add(wt, g["branch"], g.get("stack_base") or g["base"])      # a chain entry starts from the head of the entry ahead of it
        m = self.members_in(g)[0]      # one PR an entry
        ok, why = self.merge_one(g, wt, m)
        if not ok:
            self.eject(g, m, why, notify=not why.startswith("its head is already"))
            git.worktree_remove(wt, g["branch"])
            return self.no_members(g)
        g["head"] = git.out(["rev-parse", "HEAD"], cwd=wt)
        self.j("built", group=g["id"], head=g["head"][:7], prs=[m["pr"]])
        g["state"] = "building"
        self.set_phase(g, "built")

    def merge_one(self, g, wt, m):
        git, cfg = self.git, g["config"]
        if git.run(["merge-base", "--is-ancestor", m["head"], "HEAD"], cwd=wt, check=False).returncode == 0:
            return False, "its head is already in main or in a PR ahead of it, nothing to merge"
        msg = "Merge pull request #%d from %s/%s" % (m["pr"], m["owner"], m["branch"])
        r = git.run(["merge", "--no-ff", "-m", msg, m["head"]], cwd=wt, check=False)
        if r.returncode == 0:
            return True, None
        files = [f for f in git.out(["diff", "--name-only", "--diff-filter=U"], cwd=wt, check=False).splitlines() if f]
        hook = cfg.get("on_conflict")
        if files and hook and all(f in cfg["conflict_paths"] for f in files):
            if self.run_hook(wt, hook, m["pr"], files):
                git.run(["add", "--"] + files, cwd=wt, check=False)
                if not git.out(["diff", "--name-only", "--diff-filter=U"], cwd=wt, check=False) and \
                        git.run(["commit", "--no-edit", "-q"], cwd=wt, check=False).returncode == 0:
                    self.j("conflict_resolved", group=g["id"], pr=m["pr"], files=files)
                    return True, None
        git.run(["merge", "--abort"], cwd=wt, check=False)
        git.run(["reset", "--hard", "-q", "HEAD"], cwd=wt, check=False)
        if not files:
            return False, "refused: cannot be merged: " + " ".join((r.stderr or r.stdout or "").strip().splitlines()[-1:])[:100]
        shown = ", ".join(files[:3]) + (" and %d more" % (len(files) - 3) if len(files) > 3 else "")
        ahead = (g.get("ahead") or [None])[-1]      # the PRs ahead are in other entries
        who = REFUSED_CONFLICT + (" or with PR #%d ahead of it" % ahead if ahead else "")
        return False, "%s (%s)" % (who, shown)

    def run_hook(self, wt, hook, pr, files):
        try:
            r = subprocess.run(shlex.split(hook), cwd=wt, capture_output=True, text=True, timeout=300,
                               env=dict(os.environ, MQ_PR=str(pr), MQ_CONFLICT_FILES="\n".join(files), MQ_WORKTREE=wt))
        except (OSError, subprocess.TimeoutExpired) as e:
            self.j("conflict_hook_failed", pr=pr, error=type(e).__name__)
            return False
        if r.returncode != 0:
            self.j("conflict_hook_failed", pr=pr, status=r.returncode, tail=" ".join((r.stderr or "").strip().splitlines()[-1:])[:140])
        return r.returncode == 0

    def push(self, g):
        git = self.git
        rp = self.replay()
        if rp is not None and rp["ci"] == "skip":
            return self.skip_ci(g)
        local = git.run(["rev-parse", "--verify", "-q", "refs/heads/" + g["branch"]], check=False).stdout.strip()
        if local != g["head"]:
            self.j("rebuild", group=g["id"], note="the local group branch is gone or moved")
            g["phase"] = "building"
            S.save_group(self.paths, g)
            return
        g["push_started"] = True
        S.save_group(self.paths, g)
        git.push_branch(g["branch"], g["branch"], g["git_remote"])
        g["pushed_at"] = time.time()
        self.j("pushed", group=g["id"], branch=g["branch"], head=g["head"][:7])
        g["state"] = "testing"
        self.set_phase(g, "pushed")

    def skip_ci(self, g):
        """Replay with ci = "skip": the group is built and ends there. No push and no CI; the verdict is `skipped` and the PRs are `tested (CI not run)` (`mq wait` exits 4)."""
        prs = [m["pr"] for m in self.members_in(g)]
        g["verdict"] = {"result": "skipped", "reason": "CI not run (replay ci = skip)", "at": int(time.time())}
        g["state"], g["ci_skipped"] = "skipped", True
        self.j("ci_skipped", group=g["id"], head=g["head"][:7], prs=prs, note="replay ci = skip: built, not pushed, not tested")
        self.set_phase(g, "verdict")

    def test(self, g):
        if g["phase"] == "pushed":
            under = " on top of %s" % " ".join("#%d" % n for n in g["ahead"][-3:]) if g.get("ahead") else ""
            self.tell_all(g, "pending", "testing in group %s with %s%s" % (g["id"], " ".join("#%d" % m["pr"] for m in self.members_in(g)), under))
            self.set_phase(g, "testing")
            return
        now = time.time()
        if now - self.last_poll.get(g["id"], 0) < self.poll:
            return
        self.last_poll[g["id"]] = now
        required = g["config"]["required"]
        # the poller's file first: it can only say "still going", which needs no GitHub call; anything else goes to the check-runs read, which alone decides
        st, info = H.ci_runs(self.repo, g["head"], g["salamander_calls"], self.j)
        if info and not g["run"]:
            g["run"] = info
        if st == "going":
            g["note"] = "run in progress (the poller's file)"
            S.save_group(self.paths, g)
            return self.check_cap(g, now)
        status, etag, runs = H.check_runs(self.repo, g["head"], g["check_etag"], g["gh_calls"], self.j)
        if status == 304:
            runs = g["last_runs"]
            if runs is None:
                g["check_etag"] = None
                S.save_group(self.paths, g)
                return
        else:
            g["check_etag"] = etag
            g["last_runs"] = [{k: r.get(k) for k in ("id", "name", "status", "conclusion", "started_at", "html_url", "details_url")} |
                              {"app": {"id": (r.get("app") or {}).get("id")}} for r in runs if isinstance(r, dict)]
            runs = g["last_runs"]
        verdict, detail, url = H.evaluate(runs, required)
        g["note"] = ", ".join("%s=%s" % kv for kv in sorted(detail.items()))
        if url and not g["run"]:
            g["run"] = {"id": None, "url": url}
        if verdict in ("pass", "fail"):
            g["verdict"] = {"result": verdict, "detail": detail, "run_url": (g["run"] or {}).get("url") or url, "at": int(now)}
            self.j("verdict", group=g["id"], result=verdict, detail=detail, gh_calls=g["gh_calls"], salamander_calls=g["salamander_calls"])
            self.set_phase(g, "verdict")
            return
        S.save_group(self.paths, g)
        self.check_cap(g, now)

    def check_cap(self, g, now):
        if g["pushed_at"] and now - g["pushed_at"] > self.cap:
            waited = "%d minutes" % (self.cap // 60) if self.cap >= 120 else "%gs" % self.cap
            g["verdict"] = {"result": "timeout", "reason": "no verdict %s after the push" % waited, "at": int(now)}
            g["state"] = "timeout"
            self.j("verdict", group=g["id"], result="timeout", gh_calls=g["gh_calls"], salamander_calls=g["salamander_calls"])
            self.set_phase(g, "verdict")


    # ---- what the verdict means ----
    def fail_reason(self, g):
        v = g.get("verdict") or {}
        if v.get("result") != "fail":
            return "group %s: %s" % (g["id"], v.get("reason") or v.get("result") or "no verdict")
        bad = ", ".join(sorted(n for n, d in (v.get("detail") or {}).items() if d != "pass")) or ", ".join(g["config"]["required"])
        return "group %s failed %s" % (g["id"], bad)

    def resolve(self, g):
        v = g.get("verdict") or {"result": "error", "reason": "no verdict"}
        res = v["result"]
        if not (self.parent_settled(g) if res in ("pass", "skipped") else self.parent_passed(g)):
            # An entry's verdict is on a tree that holds the PRs ahead of it. A pass counts once they are merged (tested, in shadow); a failure counts once the entry
            # ahead has passed, because then the tree under this PR is known to be good and the failure is its own. Until then it waits (a failure may be the PRs ahead's).
            if g.get("note") != "tested, waiting for %s" % g["stack_on"]:
                g["note"] = "tested, waiting for %s" % g["stack_on"]
                S.save_group(self.paths, g)
            return
        if res == "skipped":
            g["outcome"], g["state"] = "tested", "tested"
            g["outcome_reason"] = "%s: group %s was built, not pushed, no CI (replay ci = skip)" % (R.SKIPPED_NOTE, g["id"])
            self.set_phase(g, "cleaning")
            return
        if res == "pass":
            g["state"] = "passed"
            if self.merging():
                self.set_phase(g, "merging")
                return
            if self.recheck_shadow(g) and not self.members_in(g):
                return self.no_members(g)
            self.j("would_merge", group=g["id"], prs=[m["pr"] for m in self.members_in(g)], head=g["head"][:7], base=g["base"][:7], to=g["base_branch"])
            g["outcome"], g["state"] = "tested", "tested"
            g["outcome_reason"] = "group %s passed %s (shadow: nothing was merged)" % (g["id"], ", ".join(g["config"]["required"]))
            self.set_phase(g, "cleaning")
            return
        g["state"] = "failed" if res == "fail" else res
        g["outcome"], g["outcome_reason"] = "failed", self.fail_reason(g)
        self.set_phase(g, "cleaning")

    def new_group(self, seq, base_branch, base_sha, cfg, members, stack=None):
        gid = "g%d" % seq
        return {"id": gid, "seq": seq, "phase": "building", "state": "building", "base_branch": base_branch, "base": stack["base"] if stack else base_sha,
                "stack_on": stack["id"] if stack else None,                  # the entry ahead, whose head this one is built on
                "stack_base": stack["head"] if stack else None,              # that head, the commit the worktree starts from
                "ahead": (stack.get("ahead", []) + [m["pr"] for m in stack["members"] if m["state"] == "in"]) if stack else [],      # the PRs under this one, in line order
                "branch": cfg["queue_prefix"] + gid, "created": int(time.time()), "config": dict(cfg), "members": members,
                "head": None, "checked": False, "build_started": False, "push_started": False, "pushed_at": None,
                "check_etag": None, "last_runs": None, "note": None, "run": None, "verdict": None, "fails": 0,
                "gh_calls": {}, "salamander_calls": {}, "git_remote": {}}

    # ---- the chain: entries stacked on the entry ahead ----
    def parent_settled(self, g):
        """True for an entry with nothing ahead of it, or whose entry ahead is merged (shadow: tested)."""
        sid = g.get("stack_on")
        if not sid:
            return True
        p = S.load_group(self.paths, sid)
        return bool(p) and p.get("outcome") in ("merged", "tested")

    def parent_passed(self, g):
        """True for an entry with nothing ahead of it, or whose entry ahead has a passing verdict (or is merged / tested already): the tree under g's PR is known to be good."""
        sid = g.get("stack_on")
        if not sid:
            return True
        p = S.load_group(self.paths, sid)
        return bool(p) and (p.get("outcome") in ("merged", "tested") or (p.get("verdict") or {}).get("result") in ("pass", "skipped"))

    def group_failed(self, p):
        """Group p will not be merged as built: it failed, was ejected, went stale, or its own parent is gone."""
        v = p.get("verdict") or {}
        if p.get("outcome") in ("failed", "requeue", "restack") or v.get("result") in ("fail", "error", "timeout", "empty"):
            return True
        if p["phase"] in ("cleaning", "done") and p.get("outcome") not in ("merged", "tested"):
            return True
        return bool(p["phase"] in LIVE and (not self.members_in(p) or self.parent_gone(p)))

    def parent_gone(self, g):
        """Why the entry ahead of chain entry g no longer carries it (→ words), or None. The tree g was built on holds that entry's PR, so when the entry fails, is ejected,
        dropped, goes stale or is built again with another head, g has to be built again on what is left."""
        sid = g.get("stack_on")
        if not sid:
            return None
        p = S.load_group(self.paths, sid)
        if p is None:
            return "the entry ahead of it, %s, is gone" % sid
        who = "PR #%d" % p["members"][0]["pr"] if p.get("members") else sid
        if p.get("head") != g.get("stack_base"):
            return "%s ahead of it was built again" % who
        if p.get("outcome") in ("merged", "tested"):
            return None
        if self.group_failed(p):
            return "%s ahead of it left the line" % who
        return None

    def legacy(self, g):
        """A record group mode wrote: several PRs in one entry, or the half or the parent of a bisect. The chain has no such entry."""
        return len(g.get("members") or []) > 1 or bool(g.get("parent") or g.get("children") or g.get("siblings"))

    def retire_legacy(self, g):
        """A record left by group mode is not run. Its PRs go back to the line (no rebuild counted) and are built again as entries, its branch and worktree go with `cleaning`.
        The exception is a tested record in `merging`: a crash may have come after its push, and a head already in main is `merged` as it always was, not rebuilt."""
        if g["phase"] == "merging":
            tip = self.git.fetch_base(g["base_branch"], g["git_remote"])
            if g.get("head") and self.git.is_ancestor(g["head"], tip):
                self.j("legacy_group_merged", group=g["id"], prs=[m["pr"] for m in self.members_in(g)], note="a record of group mode whose head is in %s already" % g["base_branch"])
                return self.merged(g, g["head"], pushed=False)
        why = "group mode was removed: the queue tests one PR an entry, and this record was not run"
        g["outcome"], g["state"], g["outcome_reason"] = "restack", "stale", why
        self.j("legacy_group_retired", group=g["id"], phase=g["phase"], prs=[m["pr"] for m in self.members_in(g)], note=why)
        self.set_phase(g, "cleaning")

    def chain_check(self, g):
        """The top of every step of a chain entry: is what it stands on still there? → True when it moved the entry (back to the line, restacked or stale)."""
        why = self.parent_gone(g)
        if why:
            g["outcome"], g["state"], g["outcome_reason"] = "restack", "stale", why[:140]
            self.j("restack", group=g["id"], reason=why[:140], prs=[m["pr"] for m in self.members_in(g)])
            self.set_phase(g, "cleaning")
            return True
        if g["phase"] != "merging":
            q = S.load_queue(self.paths)
            dropped = [m for m in self.members_in(g) if any(e["pr"] == m["pr"] and e.get("group") == g["id"] and e["state"] == S.DROPPED for e in q["entries"])]
            if dropped:       # dropped by hand: its tree is no use to anyone, so end it now rather than at the merge step (the entries behind it follow, as they see it go)
                for m in dropped:
                    m["state"], m["reason"] = "ejected", "dropped"
                S.save_group(self.paths, g)
                self.stale(g, "PR %s was dropped from the line" % ", ".join("#%d" % m["pr"] for m in dropped))
                return True
        return False

    def chain_tail(self, tip):
        """The entry a new one is stacked on. → None when nothing is in flight (start a new chain on main), the newest entry, or False to wait: an entry in flight is still
        being built (no head to stack on), is failing or being sent back (its successors are about to be), or main moved under the chain (the tail will go stale)."""
        live = self.snapshot()[1]
        if not live:
            return None
        if any(self.legacy(g) for g in live):
            return False                       # records of group mode are still being retired
        tail = live[-1]
        for g in live:
            if g["phase"] not in LIVE or self.group_failed(g) or self.parent_gone(g):
                return False
        if not tail.get("head") or tail["phase"] == "building":
            return False
        if not self.git.is_ancestor(tip, tail["head"]):
            return False
        return tail

    # ---- the merge push ----
    def merge(self, g):
        if S.load_queue(self.paths).get("paused") or not self.parent_settled(g):
            return
        g["state"] = "merging"
        path, lockfd = self.host.get("deploy_lock"), None
        if path:
            lockfd = S.try_lock(path)
            if lockfd is None:
                if not g.get("lock_noted"):
                    g["lock_noted"] = True
                    S.save_group(self.paths, g)
                    self.j("deploy_lock_busy", group=g["id"], path=path)
                return
        try:
            self.merge_locked(g)
        finally:
            if lockfd is not None:
                os.close(lockfd)

    def merge_locked(self, g):
        git, counts, base = self.git, g["git_remote"], g["base_branch"]
        tip = git.fetch_base(base, counts)
        if git.is_ancestor(g["head"], tip):
            return self.merged(g, g["head"], pushed=False)       # a crash after the push: it is in main already
        if not (tip == g["base"] or git.is_ancestor(tip, g["head"])):
            return self.stale(g, "%s moved from %s to %s since the group was built" % (base, g["base"][:7], tip[:7]))
        members = self.members_in(g)
        q = S.load_queue(self.paths)
        dropped = [m for m in members if any(e["pr"] == m["pr"] and e.get("group") == g["id"] and e["state"] == S.DROPPED for e in q["entries"])]
        if dropped:       # `mq drop` took it out of the line after the group was built: the tested tree holds it, so it is not merged; the others are rebuilt without it
            for m in dropped:
                m["state"], m["reason"] = "ejected", "dropped"
            S.save_group(self.paths, g)
            return self.stale(g, "PR %s was dropped from the line" % ", ".join("#%d" % m["pr"] for m in dropped))
        info = self.pr_facts(g, [m["pr"] for m in members])
        S.save_group(self.paths, g)
        left = []
        for m in members:
            why = self.refusal(g, m, info.get(m["pr"]))
            if why:
                left.append(m)
                self.eject(g, m, why[0], notify=why[1])
        if left:
            return self.stale(g, "PR %s left the group before the merge" % ", ".join("#%d" % m["pr"] for m in left))
        try:
            git.push_fast_forward(g["head"], base, counts)
        except G.GitError:
            now = git.fetch_base(base, counts)
            if now != tip:
                return self.stale(g, "%s moved to %s while the group was being pushed" % (base, now[:7]))
            raise
        self.merged(g, g["head"], pushed=True)

    def refusal(self, g, m, p):
        """Why a PR, read again (p, from graphql_prs), may not stay in group g: → (reason, tell the PR) or None. Closed, a draft, another base, a failed check on its head, a head that
        moved. The failed check is named before a moved head: a PR whose own checks failed must not be merged on any head."""
        if p is None or p["state"] != "OPEN" or p["draft"] or p["base"] != g["base_branch"]:
            return "left the group before the merge (closed, changed or moved)", False
        bad = H.failed_checks(p["checks"], g["config"].get("pr_required", "all"))
        if bad:
            return REFUSED_CHECK + ", ".join(bad), True
        if p["head"] != m["head"]:
            return "left the group before the merge (closed, changed or moved)", False
        return None

    def conflicts_with_tip(self, g, m, tip):
        """Does PR m's pinned head still merge into the base branch's tip (main moved while the group was tested)? → the conflicted paths, or None when it merges or nothing can be said.
        A conflict on the files the repo's on_conflict hook mends (conflict_paths) is not one, as in the build."""
        git, cfg = self.git, g["config"]
        try:
            if self.fetch_head(g, m) != m["head"]:
                return None
            files = git.merge_conflicts(tip, m["head"])
        except G.GitError as e:
            self.j("conflict_check_failed", group=g["id"], pr=m["pr"], error=str(e)[:140])
            return None
        if files is None or (files and cfg.get("on_conflict") and all(f in cfg["conflict_paths"] for f in files)):
            return None
        return files

    def recheck_shadow(self, g):
        """Shadow only (mode on does the same in merge_locked, where it also pushes): before a passed group counts as tested, read its PRs again. A PR that is closed, a draft, has a
        failed check on its head, or moved on is ejected; and when the base branch moved since the group was built, a PR that no longer merges into its tip is ejected
        ('refused: conflicts with main'). The group is not rebuilt in shadow: the others stay `tested`. → the PRs ejected."""
        members = self.members_in(g)
        info = self.pr_facts(g, [m["pr"] for m in members])
        tip = self.git.fetch_base(g["base_branch"], g["git_remote"])
        S.save_group(self.paths, g)
        gone = []
        for m in members:
            why = self.refusal(g, m, info.get(m["pr"]))
            if not why and tip != g["base"]:
                files = self.conflicts_with_tip(g, m, tip)
                if files is not None:
                    shown = ", ".join(files[:3]) + (" and %d more" % (len(files) - 3) if len(files) > 3 else "")
                    why = (REFUSED_CONFLICT + (" (%s)" % shown if shown else ""), True)
            if why:
                gone.append(m["pr"])
                self.eject(g, m, why[0], notify=why[1])
        if gone:
            self.j("recheck_ejected", group=g["id"], prs=gone, note="shadow: the group was tested with them; the others stay tested, nothing is rebuilt")
        return gone

    def merged(self, g, sha, pushed):
        g["outcome"], g["state"], g["merged_sha"] = "merged", "merged", sha
        g["outcome_reason"] = "merged in group %s at %s" % (g["id"], sha[:7])
        self.j("merged", group=g["id"], sha=sha[:7], prs=[m["pr"] for m in self.members_in(g)], pushed=pushed, base=g["base"][:7], to=g["base_branch"])
        self.set_phase(g, "cleaning")

    def stale(self, g, why):
        """The tested tree is not what main would get any more: the PR still in the entry goes back to the line to be rebuilt on the new main."""
        g["outcome"], g["state"], g["outcome_reason"] = "requeue", "stale", why[:140]
        self.j("stale", group=g["id"], reason=why[:140], prs=[m["pr"] for m in self.members_in(g)])
        self.set_phase(g, "cleaning")

    def pause(self, reason, by):
        def fn(q):
            if not q.get("paused"):
                q["paused"] = {"reason": reason[:200], "since": int(time.time()), "by": by}
        S.update_queue(self.paths, fn)
        self.j("paused", reason=reason[:200], by=by)

    # ---- the PR's side: a commit status, and one comment on a failure (mode on only; best effort, it never stops the queue) ----
    def run_url(self, g):
        return ((g.get("verdict") or {}).get("run_url")) or ((g.get("run") or {}).get("url"))

    def tell(self, g, m, state, desc, url=None):
        if not self.merging() or not m.get("head"):
            return
        key = "%s|%s" % (state, desc)
        if m.get("status") == key:
            return
        try:
            H.post_status(self.repo, m["head"], state, desc, url or self.run_url(g), g["gh_calls"], self.j)
            m["status"] = key
            S.save_group(self.paths, g)
        except (H.GhError, OSError) as e:
            self.j("status_failed", group=g["id"], pr=m["pr"], error=str(e)[:140])

    def tell_all(self, g, state, desc):
        for m in self.members_in(g):
            self.tell(g, m, state, desc)

    def tell_failure(self, g, m, reason):
        self.tell(g, m, "failure", reason[:120])
        if not self.merging() or not m.get("head") or m.get("commented"):
            return
        url = self.run_url(g)
        body = "Merge queue: this PR was taken out of the line: %s (group %s%s). Push a fix and add it to the queue again." % (
            reason, g["id"], ", " + url if url else "")
        try:
            H.post_comment(self.repo, m["pr"], body, g["gh_calls"], self.j)
            m["commented"] = True
            S.save_group(self.paths, g)
        except (H.GhError, OSError) as e:
            self.j("comment_failed", group=g["id"], pr=m["pr"], error=str(e)[:140])

    # ---- the end of a group ----
    def finalize_entries(self, g):
        out, why = g.get("outcome"), g.get("outcome_reason") or "group %s ended" % g["id"]
        if out in (None, "split"):      # "split" is only on the parent record of a bisect that group mode ran to its end: its halves settled the PRs
            return
        ended = []

        def fn(q):
            for e in q["entries"]:
                if e["state"] != S.GROUPED or e.get("group") != g["id"]:
                    continue
                if out in ("requeue", "restack"):
                    if out == "requeue":      # a restack is not a rebuild because main kept moving: each one is caused by an entry ahead leaving, and each leaves once
                        e["rebuilds"] = e.get("rebuilds", 0) + 1
                    if e.get("rebuilds", 0) > self.max_rebuilds:
                        S.finish_entry(e, S.FAILED, ("gave up: its group was rebuilt %d times because main kept moving (%s)" % (e.get("rebuilds", 0) - 1, why))[:140])
                    else:
                        e["state"], e["group"], e["reason"] = S.WAITING, None, ("back in the line: " + why)[:140]
                else:
                    S.finish_entry(e, {"tested": S.TESTED, "merged": S.MERGED}.get(out, S.FAILED), why[:140])
                    if g.get("ci_skipped"):
                        e["ci"] = "skipped"      # `mq wait` tells a PR tested without CI from one whose group passed CI
                ended.append((e["pr"], e["state"], e["reason"]))
        S.update_queue(self.paths, fn)
        for pr, state, reason in ended:
            m = next((x for x in g["members"] if x["pr"] == pr), None)
            if m is None:
                continue
            if state == S.MERGED:
                self.tell(g, m, "success", "merged in group %s at %s" % (g["id"], (g.get("merged_sha") or "")[:7]))
            elif state == S.FAILED:
                self.tell_failure(g, m, reason)
            elif state == S.WAITING:
                self.tell(g, m, "pending", reason)

    def release_resources(self, g):
        git = self.git
        if g.get("released"):
            return
        if g["push_started"]:
            if git.delete_remote_branch(g["branch"], g["git_remote"]):
                self.j("branch_deleted", group=g["id"], branch=g["branch"])
        git.worktree_remove(os.path.join(self.paths.wt, g["id"]), g["branch"])
        git.drop_pr_refs([m["pr"] for m in g["members"]])
        g["released"] = True

    def cleanup(self, g):
        self.release_resources(g)
        self.finalize_entries(g)
        g["done_at"] = int(time.time())
        self.j("group_done", group=g["id"], result=(g.get("verdict") or {}).get("result"), outcome=g.get("outcome"), gh_calls=g["gh_calls"],
               salamander_calls=g["salamander_calls"], git_remote=g["git_remote"])
        self.set_phase(g, "done")
