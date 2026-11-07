"""lib/mq/mq_cli.py — the commands of `salamander mq` (docs/mq.md). Nothing here calls GitHub: add, status, drop and wait read and write the
files under $XDG_STATE_HOME/mergequeue/, and start the driver (mq drive) when there is work and none is alive.
"""
import argparse
import os
import re
import subprocess
import sys
import time

import mq_config as C
import mq_replay as R
import mq_state as S

USAGE = """usage: salamander mq add N… [--flag recycle] [--repo OWNER/NAME]
       salamander mq status [--json] [--repo OWNER/NAME]
       salamander mq drop N [--repo OWNER/NAME]
       salamander mq pause [--reason TEXT] [--repo OWNER/NAME]
       salamander mq resume [--repo OWNER/NAME]
       salamander mq wait N [--timeout SECS] [--repo OWNER/NAME]
       salamander mq doctor [--repo OWNER/NAME]
       salamander mq drive --repo OWNER/NAME        (internal: the driver, started for you)"""

PASS_ENV = ("HOME", "PATH", "LANG", "SSH_AUTH_SOCK", "XDG_STATE_HOME", "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR", "GIT_CONFIG_GLOBAL",
            "GIT_CONFIG_NOSYSTEM", "GIT_SSH_COMMAND", "SALA_BIN")


class Parser(argparse.ArgumentParser):
    def error(self, message):
        print("salamander mq: %s\n%s" % (message, USAGE), file=sys.stderr)
        sys.exit(2)


def repo_from_cwd():
    try:
        r = subprocess.run(["git", "remote", "get-url", "origin"], capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return None
    m = re.search(r"[:/]([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?$", r.stdout.strip()) if r.returncode == 0 else None
    return "%s/%s" % m.groups() if m else None


def resolve(a):
    repo = a.repo or repo_from_cwd()
    if not repo or not S.valid_repo(repo):
        print("salamander mq: no usable --repo OWNER/NAME (and the current folder has no GitHub origin)", file=sys.stderr)
        sys.exit(2)
    return repo, S.Paths(repo)


RACE_WAIT_SECS = 2.0      # how long a failed start waits for the lock of a unit that is just coming up


def unit_state(unit):
    """`systemctl --user is-active` for the unit: its word (active, activating, inactive, …), or "" when it cannot be asked."""
    try:
        r = subprocess.run(["systemctl", "--user", "is-active", unit], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return (r.stdout or "").strip()


def driver_came_up(paths, unit, stderr):
    """After a failed systemd-run: is the driver in fact alive, a racing `mq add` having started the unit a moment before? The lock is the truth.
    A unit that exists or is active/activating may not hold the lock yet, so that case polls for it (RACE_WAIT_SECS); any other failure asks once."""
    if S.driver_alive(paths):
        return True
    if "exist" not in (stderr or "").lower() and unit_state(unit) not in ("active", "activating", "reloading"):
        return False
    end = time.time() + RACE_WAIT_SECS
    while time.time() < end:
        time.sleep(0.1)
        if S.driver_alive(paths):
            return True
    return False


def unit_name(repo, host):
    """The driver's systemd unit: mq-<owner>__<repo>, and with a replay file mq-<owner>__<repo>-<run>-<case>, so it never collides with the live driver of the repo.
    Every start, check and message of the unit uses this one name."""
    return "mq-" + S.slug(repo) + R.unit_suffix((host or {}).get("replay_data"))


def ensure_driver(repo, paths, host):
    """Start the driver as a transient user unit unless one is alive (the lock is the liveness). → a word for the message.
    Two calls in the same second both try: the loser's systemd-run fails because the unit exists, and if the driver is alive after all
    that is the same answer as when it was already running (the race is journaled as driver_start_raced)."""
    if S.driver_alive(paths):
        return "driver running"
    unit = unit_name(repo, host)
    here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "main.py")
    setenv = ["--setenv=%s=%s" % (k, os.environ[k]) for k in PASS_ENV if os.environ.get(k)]
    setenv += ["--setenv=%s=%s" % (k, v) for k, v in os.environ.items() if k.startswith("MQ_")]
    cmd = ["systemd-run", "--user", "--unit", unit, "--description", "merge queue driver for " + repo, "--collect", "--quiet"] + setenv + \
          [sys.executable, "-I", here, "drive", "--repo", repo]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as e:
        S.journal(paths, "driver_start_failed", unit=unit, error=type(e).__name__)
        return "driver NOT started (%s); run `salamander mq doctor`" % type(e).__name__
    if r.returncode != 0:
        if driver_came_up(paths, unit, r.stderr):
            S.journal(paths, "driver_start_raced", unit=unit, status=r.returncode)
            return "driver running"
        S.journal(paths, "driver_start_failed", unit=unit, status=r.returncode, tail=" ".join((r.stderr or "").strip().splitlines()[-1:])[:140])
        return "driver NOT started (systemd-run: %s)" % " ".join((r.stderr or "").strip().splitlines()[-1:])[:120]
    S.journal(paths, "driver_requested", unit=unit)
    return "driver started (%s)" % unit


def host_or_exit(repo):
    host, errs = C.load_host(repo)
    if errs:
        for e in errs:
            print("salamander mq: " + e, file=sys.stderr)
        sys.exit(1)
    return host


def ago(ts):
    if not ts:
        return ""
    d = max(0, int(time.time() - ts))
    return "%ds ago" % d if d < 90 else "%dm ago" % (d // 60) if d < 5400 else "%dh ago" % (d // 3600)


# ---- add / drop ----------------------------------------------------------------------------------------------------------------------

def cmd_add(argv):
    p = Parser(prog="mq add", add_help=False)
    p.add_argument("prs", nargs="+", type=int)
    p.add_argument("--repo")
    p.add_argument("--flag", action="append", default=[], choices=["recycle"])
    a = p.parse_args(argv)
    repo, paths = resolve(a)
    host = host_or_exit(repo)
    if host["mode"] == "off":
        print("salamander mq: mode is off for %s (host config %s); nothing was queued. Set mode = \"shadow\" there to run the queue without merging." %
              (repo, C.host_path(repo)), file=sys.stderr)
        return 1
    if host["mode"] == "on" and not C.ON_OPEN:
        print("salamander mq: mode \"on\" is not open yet (the merge step is built, the switch to it is a step of its own: docs/mq.md, Migration); "
              "use mode = \"shadow\". Nothing was queued.", file=sys.stderr)
        return 1
    notes = []

    def fn(q):
        for n in a.prs:
            if S.find_entry(q, n, active_only=True):
                notes.append((n, "already in the line"))
                continue
            q["entries"].append({"pr": n, "state": S.WAITING, "flags": sorted(set(a.flag)), "added": int(time.time()), "group": None,
                                 "reason": None, "ended": None})
            notes.append((n, "queued"))
    S.update_queue(paths, fn)
    S.journal(paths, "add", prs=[n for n, w in notes if w == "queued"], flags=sorted(set(a.flag)))
    for n, w in notes:
        print("PR %d: %s" % (n, w))
    print("mode %s: %s; %s" % (host["mode"], "entries are built and tested, nothing is merged" if host["mode"] == "shadow" else "tested entries are merged into main",
                              ensure_driver(repo, paths, host)))
    if host.get("replay"):
        rp = host["replay_data"]
        print("%s; %s" % (R.describe(rp), "entries are pushed to %s* and CI decides" % rp["rules"]["queue_prefix"] if rp["ci"] == "real"
                          else "ci = skip: entries are built only, no push, no CI (mq wait exits 4)"))
    return 0


def cmd_drop(argv):
    p = Parser(prog="mq drop", add_help=False)
    p.add_argument("pr", type=int)
    p.add_argument("--repo")
    a = p.parse_args(argv)
    repo, paths = resolve(a)
    res = []

    def fn(q):
        e = S.find_entry(q, a.pr, active_only=True)
        if e is None:
            return
        res.append(e.get("group"))
        S.finish_entry(e, S.DROPPED, "dropped by hand")
    S.update_queue(paths, fn)
    if not res:
        print("PR %d is not in the line" % a.pr, file=sys.stderr)
        return 1
    S.journal(paths, "drop", pr=a.pr, group=res[0])
    if res[0]:
        print("PR %d dropped; it was in %s, which the driver ends at its next step; the entries behind it are rebuilt without it" % (a.pr, res[0]))
    else:
        print("PR %d dropped" % a.pr)
    return 0


# ---- pause / resume ------------------------------------------------------------------------------------------------------------------

def cmd_pause(argv):
    p = Parser(prog="mq pause", add_help=False)
    p.add_argument("--reason", default="paused by hand")
    p.add_argument("--repo")
    a = p.parse_args(argv)
    repo, paths = resolve(a)
    done = []

    def fn(q):
        if q.get("paused"):
            done.append(q["paused"]["reason"])
        else:
            q["paused"] = {"reason": a.reason[:200], "since": int(time.time()), "by": "hand"}
    S.update_queue(paths, fn)
    if done:
        print("already paused: %s" % done[0])
        return 0
    S.journal(paths, "paused", reason=a.reason[:200], by="hand")
    print("paused: no entry starts and nothing is pushed to main; entries in flight finish testing and wait. `salamander mq resume` goes on.")
    return 0


def cmd_resume(argv):
    p = Parser(prog="mq resume", add_help=False)
    p.add_argument("--repo")
    a = p.parse_args(argv)
    repo, paths = resolve(a)
    was = []

    def fn(q):
        if q.get("paused"):
            was.append(q["paused"])
            q["paused"] = None
    S.update_queue(paths, fn)
    if not was:
        print("the queue is not paused")
        return 0
    S.journal(paths, "resumed", was=was[0].get("reason"))
    host = host_or_exit(repo)
    print("resumed (it was paused: %s)%s" % (was[0].get("reason"), "; " + ensure_driver(repo, paths, host) if host["mode"] in ("shadow", "on") else ""))
    return 0


# ---- status --------------------------------------------------------------------------------------------------------------------------

def status_data(repo, paths):
    host, errs = C.load_host(repo)
    q = S.load_queue(paths)
    groups = S.list_groups(paths)
    live = [g for g in groups if g["phase"] != "done"]
    recent = [g for g in groups if g["phase"] == "done"][-5:]
    return {"repo": repo, "mode": host["mode"], "replay": host["replay"], "host_config_errors": errs, "driver": {"alive": S.driver_alive(paths), "info": S.lock_holder_info(paths)},
            "blocked": q.get("blocked"), "paused": q.get("paused"), "queue": q["entries"], "groups": live + recent}


def cmd_status(argv):
    p = Parser(prog="mq status", add_help=False)
    p.add_argument("--json", action="store_true")
    p.add_argument("--repo")
    a = p.parse_args(argv)
    repo, paths = resolve(a)
    d = status_data(repo, paths)
    if a.json:
        import json
        print(json.dumps(d, indent=1, sort_keys=True))
        return 0
    drv = "driver running (pid %s)" % ((d["driver"]["info"] or {}).get("pid", "?")) if d["driver"]["alive"] else "no driver running"
    print("%s  mode %s  %s" % (repo, d["mode"], drv))
    if d["replay"]:
        print("REPLAY: rules and PR facts come from %s (shadow only; docs/mq.md Replay)" % d["replay"])
    if d["blocked"]:
        print("BLOCKED: %s (%s)" % (d["blocked"]["reason"], ago(d["blocked"]["since"])))
    if d["paused"]:
        print("PAUSED: %s (%s; `salamander mq resume`)" % (d["paused"]["reason"], ago(d["paused"]["since"])))
    for e in d["host_config_errors"]:
        print("host config: " + e)
    live = [e for e in d["queue"] if e["state"] in S.ACTIVE]
    print("line: %s" % ("empty" if not live else ""))
    for e in live:
        print("  #%-5d %-8s %s" % (e["pr"], e["state"], e.get("group") or ""))
    open_groups = [g for g in d["groups"] if g["phase"] != "done"]
    if open_groups:
        print("entries in flight:")
        for g in open_groups:
            prs = " ".join("#%d%s" % (m["pr"], "" if m["state"] == "in" else "(" + m["state"] + ")") for m in g["members"])
            st = g.get("state") or g["phase"]
            print("  %-5s %-9s %s  head %s  members %s%s" % (g["id"], st if st == g["phase"] else "%s/%s" % (st, g["phase"]), g["branch"], (g["head"] or "-")[:7], prs,
                                                          "  (on %s)" % g["stack_on"] if g.get("stack_on") else ""))
            if g.get("note"):
                print("        %s" % g["note"])
    done = [e for e in d["queue"] if e["state"] in S.TERMINAL]
    if done:
        print("recently finished:")
        for e in done[-8:]:
            print("  #%-5d %-8s %s  %s" % (e["pr"], e["state"], ago(e.get("ended")), e.get("reason") or ""))
    return 0


# ---- wait ----------------------------------------------------------------------------------------------------------------------------

WAIT_EXIT = {S.MERGED: 0, S.TESTED: 3}


def cmd_wait(argv):
    p = Parser(prog="mq wait", add_help=False)
    p.add_argument("pr", type=int)
    p.add_argument("--timeout", type=float, default=0)
    p.add_argument("--repo")
    a = p.parse_args(argv)
    repo, paths = resolve(a)
    host = host_or_exit(repo)
    nap = S.env_float("MQ_WAIT_SLEEP", 1)
    deadline = time.time() + a.timeout if a.timeout else None
    checked = 0.0
    while True:
        q = S.load_queue(paths)
        e = S.find_entry(q, a.pr)
        if e is None:
            print("PR %d is not in the line" % a.pr, file=sys.stderr)
            return 2
        if e["state"] in S.TERMINAL:
            line = "PR %d %s%s%s" % (a.pr, e["state"], ": " + e["reason"] if e.get("reason") else "", " [%s]" % e["group"] if e.get("group") else "")
            if e["state"] == S.TESTED and e.get("ci") == "skipped":      # a replay with ci = "skip": built, never tested; not the exit 3 of a group that passed CI
                print("PR %d %s (replay ci = skip: the entry was built, nothing was pushed or tested; this is not a pass)%s" % (
                    a.pr, R.SKIPPED_NOTE, " [%s]" % e["group"] if e.get("group") else ""))
                return R.WAIT_EXIT_SKIPPED
            print(line)
            rc = WAIT_EXIT.get(e["state"], 1)
            if rc == 1:
                print(line, file=sys.stderr)
            return rc
        if q.get("blocked"):
            print("PR %d is waiting and the queue is blocked: %s" % (a.pr, q["blocked"]["reason"]), file=sys.stderr)
            return 2
        if time.time() - checked > 30 and host["mode"] in ("shadow", "on") and not q.get("paused"):
            checked = time.time()
            if not S.driver_alive(paths):
                print(ensure_driver(repo, paths, host), file=sys.stderr)
        if deadline and time.time() >= deadline:
            print("PR %d: gave up waiting after %gs (still %s)" % (a.pr, a.timeout, e["state"]), file=sys.stderr)
            return 2
        time.sleep(nap)


# ---- doctor --------------------------------------------------------------------------------------------------------------------------

def cmd_doctor(argv):
    p = Parser(prog="mq doctor", add_help=False)
    p.add_argument("--repo")
    a = p.parse_args(argv)
    repo, paths = resolve(a)
    problems = 0

    def line(level, text):
        nonlocal problems
        if level != "ok":
            problems += 1
        print("  %-4s %s" % (level, text))
    host, errs = C.load_host(repo)
    for e in errs:
        line("FAIL", "host config: " + e)
    line("ok", "host config %s: mode %s%s" % (C.host_path(repo), host["mode"], "" if os.path.exists(C.host_path(repo)) else " (no file: the default)"))
    rp = host.get("replay_data") if host["replay"] else None
    if host["replay"]:
        line("ok", R.describe(rp) if rp else "replay file %s is in use but not valid (see the host config line above)" % host["replay"])
        for why in R.guard(rp["rules"]) if rp else []:
            line("FAIL", why)
    import shutil
    for tool in ("git", "gh", "systemd-run"):
        line("ok" if shutil.which(tool) else "FAIL", "%s on PATH" % tool if shutil.which(tool) else "%s is not on PATH" % tool)
    import mq_gh
    sal = mq_gh.salamander_bin()
    line("ok" if shutil.which(sal) or os.access(sal, os.X_OK) else "WARN", "salamander for the poller's file: %s" % sal)
    try:
        q = S.load_queue(paths)
    except S.StateError as e:
        line("FAIL", str(e))
        return 1
    groups = S.list_groups(paths)
    alive = S.driver_alive(paths)
    info = S.lock_holder_info(paths) or {}
    line("ok", "driver running (pid %s)" % info.get("pid", "?") if alive else "no driver running")
    if q.get("blocked"):
        line("WARN", "the queue is blocked: %s" % q["blocked"]["reason"])
    if q.get("paused"):
        line("ok", "PAUSED (%s, %s): `salamander mq resume` goes on" % (q["paused"]["reason"], ago(q["paused"]["since"])))
    live = [g for g in groups if g["phase"] != "done" and g.get("seq", 0) < q["next_seq"]]
    waiting = [e for e in q["entries"] if e["state"] == S.WAITING]
    if (live or waiting) and not alive and host["mode"] in ("shadow", "on") and not q.get("blocked") and not q.get("paused"):
        line("WARN", "%d entry(ies) in flight and %d PR(s) waiting, but no driver is running: any `mq add` or `mq wait` starts one" % (len(live), len(waiting)))
    for g in groups:
        if g.get("seq", 0) >= q["next_seq"]:
            line("WARN", "%s.json is an entry the line never recorded (a crash while claiming); the next entry of that number replaces it" % g["id"])
    for e in q["entries"]:
        if e["state"] == S.GROUPED and not any(g["id"] == e.get("group") and g["phase"] != "done" for g in groups):
            line("WARN", "PR %d is marked as in %s, which is not a live entry" % (e["pr"], e.get("group")))
    clone = host["clone"] or paths.work
    if not os.path.isdir(os.path.join(clone, ".git")):
        line("ok", "no work clone yet (%s): the first entry makes it" % clone)
    else:
        import mq_git
        git = mq_git.Git(clone, host["remote"], host["git_name"], host["git_email"])
        if rp:
            cfg = rp["rules"]
            line("ok", "repo config: the rules of the replay file (origin/main's .github/mergequeue.toml is not read)")
        else:
            text = git.show_file("refs/remotes/origin/main", ".github/mergequeue.toml")
            cfg, cerrs, cwarns = C.parse_repo_config(text)
            for e in cerrs:
                line("FAIL", "repo config at origin/main (as of the last fetch): " + e)
            for w in cwarns:
                line("WARN", "repo config: " + w)
            if not cerrs:
                line("ok", "repo config at origin/main (as of the last fetch): %s" % ("defaults, no .github/mergequeue.toml" if text is None else "valid"))
        try:       # only the branches of THIS queue's own prefix: another queue's (a replay's queue/practice/…) are not this queue's to warn about
            out = git.out(["ls-remote", "--heads", "origin", "refs/heads/" + cfg["queue_prefix"] + "*"], timeout=60)
        except mq_git.GitError as e:
            line("WARN", "cannot list the remote's queue branches: %s" % e)
            out = ""
        known = {g["branch"] for g in live}
        for ln in out.splitlines():
            ref = ln.split("\t")[-1][len("refs/heads/"):]
            if not ref.startswith(cfg["queue_prefix"]):
                continue
            if ref in known:
                line("ok", "queue branch %s belongs to a live entry" % ref)
            else:
                line("WARN", "queue branch %s has no live entry record (a crash left it; delete it with: git push origin --delete %s)" % (ref, ref))
        wts = git.out(["worktree", "list", "--porcelain"], check=False)
        live_wt = {os.path.join(paths.wt, g["id"]) for g in live}
        for ln in wts.splitlines():
            if ln.startswith("worktree ") and ln[9:].startswith(paths.wt) and ln[9:] not in live_wt:
                line("WARN", "worktree %s has no live entry (git -C %s worktree remove --force %s)" % (ln[9:], clone, ln[9:]))
    print("doctor: %s" % ("all ok" if not problems else "%d problem(s)" % problems))
    return 0 if not problems else 1


def cmd_drive(argv):
    p = Parser(prog="mq drive", add_help=False)
    p.add_argument("--repo", required=True)
    a = p.parse_args(argv)
    if not S.valid_repo(a.repo):
        print("salamander mq: '%s' is not owner/name" % a.repo, file=sys.stderr)
        return 2
    import mq_driver
    return mq_driver.Driver(a.repo).run()


COMMANDS = {"add": cmd_add, "status": cmd_status, "drop": cmd_drop, "pause": cmd_pause, "resume": cmd_resume, "wait": cmd_wait, "doctor": cmd_doctor, "drive": cmd_drive}


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(USAGE, file=sys.stderr if not argv else sys.stdout)
        return 2 if not argv else 0
    fn = COMMANDS.get(argv[0])
    if fn is None:
        print("salamander mq: unknown command '%s'\n%s" % (argv[0], USAGE), file=sys.stderr)
        return 2
    try:
        return fn(argv[1:])
    except S.StateError as e:
        print("salamander mq: %s" % e, file=sys.stderr)
        return 1
