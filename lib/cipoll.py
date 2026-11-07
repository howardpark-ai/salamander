#!/usr/bin/env python3
"""lib/cipoll.py — the CI-run poller and its reader (docs/ci-runs.md).

Standard library only (and the `gh` CLI, as release.sh's gh_read uses it); no model call anywhere.

  cipoll.py poll               the resident poller (`salamander ci-poll`, sala-cipoll.service): every SALA_CIPOLL_INTERVAL s, for each
                               repo in the repo list, one conditional read of repos/<repo>/actions/runs?per_page=30 (`gh api -i`, the url's
                               ETag as If-None-Match: a 304 is not counted against the account's hourly GitHub budget) and ONE json file
                               per repo, written atomically (tmp + rename), at <state>/salamander/ci-runs/<owner>__<repo>.json.
  cipoll.py runs REPO [--sha SHA] [--max-age SECS] [--text]
                               the reader (`salamander ci-runs`): prints the file's runs (filtered to a head sha), exit 3 when the file is
                               missing, 4 when it is older than --max-age (default 120 s), so the caller falls back to its own read.
  cipoll.py pending REPO SHA [--max-age SECS]
                               for release.sh: exit 0 when the file is fresh and shows a run of SHA that has not completed yet, else 1.

Environment: SALA_CIPOLL_INTERVAL (60 s), SALA_CIPOLL_BACKOFF_MAX (600 s), SALA_CIPOLL_REPOS (the repo list file; default
~/.config/salamander/ci-repos when it exists, else lib/ci-repos in this checkout), SALA_CIRUNS_DIR (the folder of the json files;
default $XDG_STATE_HOME/salamander/ci-runs, ~/.local/state/... when unset), SALA_CIPOLL_CYCLES (stop after n passes; 0 = never, the
tests set it), SALA_CIPOLL_GH (the gh binary; default gh).
"""
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
FIELDS = ("id", "name", "head_sha", "head_branch", "event", "status", "conclusion", "created_at", "updated_at", "html_url", "run_attempt")
REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
SECRET_RE = re.compile(r"(gh[pousr]_[A-Za-z0-9]{8,}|github_pat_[A-Za-z0-9_]{8,}|Bearer\s+\S+)")
EXIT_MISSING, EXIT_STALE, EXIT_BAD = 3, 4, 5


# ---- paths and settings ----------------------------------------------------------------------------------------------------------

def state_dir():
    d = os.environ.get("SALA_CIRUNS_DIR")
    if d:
        return d
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "salamander", "ci-runs")


def valid_repo(repo):
    return bool(REPO_RE.match(repo)) and not any(p in (".", "..") for p in repo.split("/"))


def file_for(repo):
    return os.path.join(state_dir(), repo.replace("/", "__") + ".json")


def fenv(name, default):
    try:
        v = float(os.environ.get(name, "") or default)
        return v if v >= 0 else default
    except ValueError:
        return default


def say(msg):
    print("cipoll: " + SECRET_RE.sub("<hidden>", msg), flush=True)


def repo_list_path():
    p = os.environ.get("SALA_CIPOLL_REPOS")
    if p:
        return p
    mine = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config"), "salamander", "ci-repos")
    return mine if os.path.isfile(mine) else os.path.join(HERE, "ci-repos")


def load_repos(warned):
    """The repos to poll, in file order: one owner/name a line, # starts a comment. Read every pass, so a repo added needs no restart."""
    path, repos = repo_list_path(), []
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError as e:
        if ("read", path) not in warned:
            warned.add(("read", path))
            say("cannot read the repo list %s: %s" % (path, type(e).__name__))
        return []
    for line in lines:
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        if not valid_repo(line):
            if ("bad", line) not in warned:
                warned.add(("bad", line))
                say("repo list %s: '%s' is not owner/name, skipped" % (path, line))
            continue
        if line not in repos:
            repos.append(line)
    return repos


# ---- one conditional read --------------------------------------------------------------------------------------------------------

def gh_get(path, etag):
    """GET path with `gh api -i`, If-None-Match when an ETag is known. → (status, headers{lower}, body, last stderr line); status 0 = no answer."""
    cmd = [os.environ.get("SALA_CIPOLL_GH") or "gh", "api", path, "-i"] + (["-H", "If-None-Match: " + etag] if etag else [])
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except Exception as e:
        return 0, {}, "", type(e).__name__
    out = r.stdout
    sep = "\r\n\r\n" if "\r\n\r\n" in out else "\n\n"
    head, _, body = out.partition(sep)
    lines = head.splitlines()
    m = re.match(r"HTTP/\S+\s+(\d+)", lines[0]) if lines else None
    headers = {}
    for ln in lines[1:]:
        k, sep2, v = ln.partition(":")
        if sep2:
            headers[k.strip().lower()] = v.strip()
    err = "".join((r.stderr or "").strip().splitlines()[-1:])
    return (int(m.group(1)) if m else 0), headers, body, err


def normalize(body):
    """The workflow runs of an actions/runs answer, cut to FIELDS; None when the body is not that."""
    try:
        wr = json.loads(body)["workflow_runs"]
        return [{k: r.get(k) for k in FIELDS} for r in wr if isinstance(r, dict)]
    except (ValueError, KeyError, TypeError):
        return None


def write_atomic(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, separators=(",", ":"))
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)           # only still there when the write or the rename failed
        except OSError:
            pass


def publish(repo, runs, now):
    write_atomic(file_for(repo), {"repo": repo, "updated": int(now), "updated_iso": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)), "runs": runs})


class Repo:
    def __init__(self):
        self.etag = None      # the url's last ETag, kept with the runs it belongs to
        self.runs = None
        self.fails = 0
        self.next_at = 0.0
        self.sig = None       # a fingerprint of the last published runs, to log a change and nothing else


def poll_one(repo, st, now, interval, backoff_max):
    """One read of one repo. Updates st.next_at; returns the epoch before which NO repo may be read (a rate limit), else 0."""
    status, hd, body, err = gh_get("repos/%s/actions/runs?per_page=30" % repo, st.etag if st.runs is not None else None)
    ok = False
    if status == 304 and st.runs is not None:
        publish(repo, st.runs, now)          # nothing changed: the data is as fresh as this look
        ok = True
        if st.fails:
            say("%s: reachable again (304)" % repo)
    elif status == 200:
        runs = normalize(body)
        if runs is None:
            err = "200 but not a workflow-run list"
        else:
            publish(repo, runs, now)
            ok = True
            sig = [(r["id"], r["status"], r["conclusion"], r["run_attempt"]) for r in runs]
            if st.fails:
                say("%s: reachable again, %d runs" % (repo, len(runs)))
            elif sig != st.sig:
                say("%s: %d runs, %d not completed" % (repo, len(runs), sum(1 for r in runs if r["status"] != "completed")))
            st.runs, st.etag, st.sig = runs, hd.get("etag") or None, sig
    if ok:
        st.fails, st.next_at = 0, now + interval
        return 0.0
    st.fails += 1
    delay = min(interval * (2 ** min(st.fails, 20)), backoff_max)
    reason = "HTTP %s" % (status or "?") + ((" " + err) if err else "")
    pause_until = 0.0
    if status in (403, 429):
        wait = 0.0
        if hd.get("retry-after", "").isdigit():
            wait = float(hd["retry-after"])
        elif hd.get("x-ratelimit-remaining") == "0" and hd.get("x-ratelimit-reset", "").isdigit():
            wait = float(hd["x-ratelimit-reset"]) - now + 1
        if wait > 0:
            delay = max(delay, min(wait, 3700.0))
            pause_until = now + delay        # the budget is the account's: no repo is read before it
            reason += " (rate limit; waiting for it to reset)"
    st.next_at = now + delay
    say("%s: %s; file kept; backing off %gs (failure %d)" % (repo, reason, delay, st.fails))
    return pause_until


def cmd_poll(argv):
    interval = max(fenv("SALA_CIPOLL_INTERVAL", 60.0), 0.05)
    backoff_max = max(fenv("SALA_CIPOLL_BACKOFF_MAX", 600.0), interval)
    cycles = int(fenv("SALA_CIPOLL_CYCLES", 0))
    states, warned, pause, n = {}, set(), 0.0, 0
    try:
        for f in os.listdir(state_dir()):    # a tmp file a killed poller left (ours are <name>.json.<pid>.tmp)
            if f.endswith(".tmp"):
                try:
                    os.unlink(os.path.join(state_dir(), f))
                except OSError:
                    pass
    except OSError:
        pass
    say("starts: every %gs, repo list %s, files in %s" % (interval, repo_list_path(), state_dir()))
    while True:
        repos = load_repos(warned)
        if not repos and ("empty", repo_list_path()) not in warned:
            warned.add(("empty", repo_list_path()))
            say("the repo list %s names no repo: nothing is polled; add owner/name lines to ~/.config/salamander/ci-repos" % repo_list_path())
        for gone in [r for r in states if r not in repos]:
            del states[gone]
        for repo in repos:
            st = states.setdefault(repo, Repo())
            now = time.time()
            if now < st.next_at or now < pause:
                continue
            pause = max(pause, poll_one(repo, st, now, interval, backoff_max))
        n += 1
        if cycles and n >= cycles:
            return 0
        now = time.time()
        due = min([max(s.next_at, pause) for s in states.values()] or [now + interval])
        time.sleep(min(interval, max(0.02, due - now)))


# ---- the reader ------------------------------------------------------------------------------------------------------------------

def read_file(repo, max_age):
    """→ (data, None) or (None, (exit code, message))."""
    if not valid_repo(repo):
        return None, (2, "ci-runs: '%s' is not owner/name" % repo)
    path = file_for(repo)
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        updated = float(data["updated"])
        data["runs"] = list(data["runs"])
    except FileNotFoundError:
        return None, (EXIT_MISSING, "ci-runs: no file for %s (%s): the poller (sala-cipoll.service) has not written it, or does not poll that repo (list: %s)" % (repo, path, repo_list_path()))
    except (OSError, ValueError, KeyError, TypeError) as e:
        return None, (EXIT_BAD, "ci-runs: %s is unreadable (%s)" % (path, type(e).__name__))
    age = time.time() - updated
    if max_age > 0 and age > max_age:
        return None, (EXIT_STALE, "ci-runs: %s is %ds old (more than --max-age %gs): the poller is not keeping it fresh" % (path, age, max_age))
    data["_age"] = age
    return data, None


def sha_match(run, sha):
    return bool(sha) and len(sha) >= 7 and (run.get("head_sha") or "").startswith(sha)


def cmd_runs(argv):
    usage = "usage: salamander ci-runs <owner/repo> [--sha SHA (7 or more characters)] [--max-age SECS] [--text]"
    repo, sha, max_age, text = None, None, 120.0, False
    it = iter(argv)
    for a in it:
        if a == "--sha":
            sha = next(it, None)
        elif a == "--max-age":
            try:
                max_age = float(next(it, ""))
            except ValueError:
                print("ci-runs: --max-age takes a number of seconds", file=sys.stderr)
                return 2
        elif a == "--text":
            text = True
        elif a.startswith("-") or repo:
            print(usage, file=sys.stderr)
            return 2
        else:
            repo = a
    if not repo or (sha is not None and len(sha) < 7):
        print(usage, file=sys.stderr)
        return 2
    data, err = read_file(repo, max_age)
    if err:
        print(err[1], file=sys.stderr)
        return err[0]
    runs = [r for r in data["runs"] if sha_match(r, sha)] if sha else data["runs"]
    if text:
        print("# %s, updated %s (%ds ago), %d run(s)%s" % (data.get("repo", repo), data.get("updated_iso", "?"), data["_age"], len(runs), (" of " + sha) if sha else ""))
        for r in runs:
            print("%s\t%s/%s\t%s\t%s\t%s\t%s" % (r.get("id"), r.get("status"), r.get("conclusion") or "-", r.get("head_branch"), (r.get("head_sha") or "")[:7], r.get("name"), r.get("html_url")))
    else:
        out = {k: v for k, v in data.items() if k != "_age"}
        out["runs"] = runs
        print(json.dumps(out, separators=(",", ":")))
    return 0


def cmd_pending(argv):
    """release.sh: 0 = the file is fresh and a run of SHA is still going (so there is nothing to ask GitHub), 1 = ask GitHub."""
    if len(argv) < 2:
        return 2
    repo, sha, max_age = argv[0], argv[1], 120.0
    if len(argv) >= 4 and argv[2] == "--max-age":
        try:
            max_age = float(argv[3])
        except ValueError:
            return 2
    if max_age <= 0 or len(sha) < 7:
        return 1
    data, err = read_file(repo, max_age)
    if err:
        return 1
    mine = [r for r in data["runs"] if sha_match(r, sha)]
    going = [r for r in mine if r.get("status") != "completed"]
    if not going:
        return 1
    print("%d of %d run(s) of %s not completed (file %ds old)" % (len(going), len(mine), sha[:7], data["_age"]))
    return 0


def main(argv):
    if not argv or argv[0] not in ("poll", "runs", "pending"):
        print("usage: cipoll.py poll | runs REPO [--sha SHA] [--max-age SECS] [--text] | pending REPO SHA [--max-age SECS]", file=sys.stderr)
        return 2
    if argv[0] == "poll":
        import signal
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))      # systemd stop: leave through the finally blocks
        try:
            return cmd_poll(argv[1:])
        except KeyboardInterrupt:
            return 0
    return {"runs": cmd_runs, "pending": cmd_pending}[argv[0]](argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
