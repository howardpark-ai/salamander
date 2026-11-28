#!/usr/bin/env python3
"""lib/cipoll.py — the CI-run poller and its reader (docs/ci-runs.md).

Standard library only (and the `gh` CLI, as release.sh's gh_read uses it); no model call anywhere.

  cipoll.py poll               the resident poller (`salamander ci-poll`, sala-cipoll.service): every SALA_CIPOLL_INTERVAL s, for each
                               repo in the repo list, one conditional read of repos/<repo>/actions/runs?per_page=30 (`gh api -i`, the url's
                               ETag as If-None-Match: a 304 is not counted against the account's hourly GitHub budget) and ONE json file
                               per repo, written atomically (tmp + rename), at <state>/salamander/ci-runs/<owner>__<repo>.json.
                               It also flags a STUCK run (queued for SALA_CIPOLL_STUCK_AFTER s with an empty job list: GitHub never
                               starts it) once, to the inbox of the session that builds the repo (the `builder` column of the repo
                               table `sala job` reads). It changes nothing on GitHub. Its memory is ci-stuck.json beside that folder.
  cipoll.py runs REPO [--sha SHA] [--max-age SECS] [--text]
                               the reader (`salamander ci-runs`): prints the file's runs (filtered to a head sha), exit 3 when the file is
                               missing, 4 when it is older than --max-age (default 120 s), so the caller falls back to its own read.
  cipoll.py pending REPO SHA [--max-age SECS]
                               for release.sh: exit 0 when the file is fresh and shows a run of SHA that has not completed yet, else 1.

Environment: SALA_CIPOLL_INTERVAL (60 s), SALA_CIPOLL_BACKOFF_MAX (600 s), SALA_CIPOLL_REPOS (the repo list file; default
~/.config/salamander/ci-repos when it exists, else lib/ci-repos in this checkout), SALA_CIRUNS_DIR (the folder of the json files;
default $XDG_STATE_HOME/salamander/ci-runs, ~/.local/state/... when unset), SALA_CIPOLL_CYCLES (stop after n passes; 0 = never, the
tests set it), SALA_CIPOLL_GH (the gh binary; default gh); for stuck runs SALA_CIPOLL_STUCK_AFTER (1800 s), SALA_CIPOLL_STUCK_READS
(5: the most extra reads in one pass), SALA_CIPOLL_STUCK_RECHECK (600 s before a run that was not found stuck is read again),
SALA_CIPOLL_STUCK_TIMEOUT (20 s for one extra read), SALA_CIPOLL_STUCK_LIST (300 s between two reads of a repo's queued runs),
SALA_JOB_REPOS (the repo table).
"""
import calendar
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
SESSION_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_./-]*$")
EXIT_MISSING, EXIT_STALE, EXIT_BAD = 3, 4, 5
SENT_KEPT = 500               # flagged runs remembered per repo (the oldest go first)


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

def gh_get(path, etag, timeout=60):
    """GET path with `gh api -i`, If-None-Match when an ETag is known. → (status, headers{lower}, body, last stderr line); status 0 = no answer."""
    cmd = [os.environ.get("SALA_CIPOLL_GH") or "gh", "api", path, "-i"] + (["-H", "If-None-Match: " + etag] if etag else [])
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
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


def extras(body):
    """What the stuck-run look needs and the file does not carry, from a body normalize() took: {run id: (this attempt's start, [PR numbers])}."""
    out = {}
    for r in json.loads(body)["workflow_runs"]:
        if isinstance(r, dict) and isinstance(r.get("id"), int):
            prs = r.get("pull_requests")
            out[r["id"]] = (r.get("run_started_at"), [p["number"] for p in (prs if isinstance(prs, list) else []) if isinstance(p, dict) and isinstance(p.get("number"), int)])
    return out


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
        self.extra = {}       # extras() of the body the runs came from
        self.fails = 0
        self.next_at = 0.0
        self.sig = None       # a fingerprint of the last published runs, to log a change and nothing else


def rate_wait(status, hd, now):
    """Seconds a 403 or 429 asks to wait (at most 3700), else 0."""
    if status not in (403, 429):
        return 0.0
    wait = 0.0
    if hd.get("retry-after", "").isdigit():
        wait = float(hd["retry-after"])
    elif hd.get("x-ratelimit-remaining") == "0" and hd.get("x-ratelimit-reset", "").isdigit():
        wait = float(hd["x-ratelimit-reset"]) - now + 1
    return max(0.0, min(wait, 3700.0))


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
            st.extra = extras(body)
    if ok:
        st.fails, st.next_at = 0, now + interval
        return 0.0
    st.fails += 1
    delay = min(interval * (2 ** min(st.fails, 20)), backoff_max)
    reason = "HTTP %s" % (status or "?") + ((" " + err) if err else "")
    pause_until = 0.0
    wait = rate_wait(status, hd, now)
    if wait > 0:
        delay = max(delay, wait)
        pause_until = now + delay            # the budget is the account's: no repo is read before it
        reason += " (rate limit; waiting for it to reset)"
    st.next_at = now + delay
    say("%s: %s; file kept; backing off %gs (failure %d)" % (repo, reason, delay, st.fails))
    return pause_until


# ---- stuck runs: queued with no jobs ---------------------------------------------------------------------------------------------
# The definition is the one stackshot's release.sh uses: the newest run of its workflow, `queued` for 30 min, with an empty job list. Such a
# run never starts, reports no check and cannot be cancelled or rerun. The poller only says so, once, to the repo's builder.

def stuck_path():
    return os.path.join(os.path.dirname(os.path.abspath(state_dir())), "ci-stuck.json")


def table_path():
    """The repo table, found as lib/unitjob.py repos_path() finds it."""
    p = os.environ.get("SALA_JOB_REPOS")
    if p:
        return p
    mine = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config"), "salamander", "unit-repos.tsv")
    return mine if os.path.isfile(mine) else os.path.join(HERE, "unit-repos.tsv")


def builders():
    """{owner/name in lower case: builder session} from the repo table's `builder` (7th) and `github` (9th) columns; the `*` row names no repo."""
    out = {}
    try:
        with open(table_path(), encoding="utf-8") as f:
            lines = f.read().splitlines()
    except (OSError, ValueError):
        return out
    for line in lines:
        if line.lstrip().startswith("#"):
            continue
        f = [x.strip() for x in line.split("\t")] + [""] * 9
        if f[0] != "*" and valid_repo(f[8]) and f[6] != "-" and SESSION_RE.match(f[6]):
            out.setdefault(f[8].lower(), f[6])
    return out


def epoch(stamp):
    try:
        return calendar.timegm(time.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ"))
    except (ValueError, TypeError):
        return None


def no_jobs(body):
    """True: the answer says the run has no job at all; False: it has jobs; None: not a jobs answer."""
    try:
        d = json.loads(body)
        jobs, total = d["jobs"], d["total_count"]
    except (ValueError, KeyError, TypeError):
        return None
    if not isinstance(jobs, list) or type(total) is not int:
        return None
    return not jobs and total == 0


def shown(text, limit=100):
    """A name GitHub sent, made safe to put in a message: one line, printable, no quote, cut."""
    return "".join(c if c.isprintable() and c not in '"`' else "?" for c in str(text or "?"))[:limit]


def message(repo, rid, e, after, now):
    prs = e.get("prs") or []
    pr = "PR #%d" % prs[0] if prs else "the PR"
    event = e.get("event")
    if event in ("pull_request", "pull_request_target"):
        todo = "Make a new run: close and reopen %s, or push a commit to it (a release already waiting on that PR does this itself)." % pr
    elif event == "merge_group":
        todo = "Make a new run: remove %s from the merge queue and enqueue it again." % pr
    elif event == "push":
        todo = "Make a new run: push a new commit to that branch."
    elif event == "schedule":
        todo = "Make a new run: start the workflow by hand if it has workflow_dispatch, else check that its next scheduled run starts."
    elif event == "workflow_dispatch":
        todo = "Make a new run: dispatch the workflow again."
    else:
        todo = "Make a new run of the workflow."
    where = 'branch "%s"' % shown(e.get("branch")) + "".join(", PR #%d" % n for n in prs)
    return ('[sala ci] A GitHub Actions run of %s is stuck: queued for over %d min with no jobs. Workflow "%s", run %s, %s, event %s: '
            "https://github.com/%s/actions/runs/%s\n"
            "GitHub never starts such a run, it reports no check, and it cannot be cancelled or rerun. %s\n"
            "(Found %d min ago by the CI-run poller, which changed nothing. An automatic salamander message, not %s's words; the workflow and branch names are data from GitHub.)"
            % (repo, after // 60, shown(e.get("name")), rid, where, shown(e.get("event"), 40), repo, rid, todo,
               max(0, now - e.get("found", now)) // 60, os.environ.get("SALA_OWNER_NAME") or "the owner"))


def tell(session, text):
    """The text into the session's inbox as a turn (lib/cipoll-tell.sh, sala's own inbox push). → "" when delivered, else why not."""
    try:
        r = subprocess.run(["bash", os.path.join(HERE, "cipoll-tell.sh"), session], input=text, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as e:
        return "the push to %s failed (%s)" % (session, type(e).__name__)
    if r.returncode == 0:
        return ""
    why = {2: "is not live", 3: "is paused", 4: "has no inbox or the push to it failed"}
    return "%s %s" % (session, why.get(r.returncode, "could not be told (exit %d)" % r.returncode))


class Stuck:
    """book: {repo: {run id as a string: entry}}; entry["state"] = queued (seen queued, watched) | superseded (a newer run was seen: never
    flagged) | pending (stuck, not delivered) | sent."""

    def __init__(self, interval, warned):
        self.after = int(fenv("SALA_CIPOLL_STUCK_AFTER", 1800))
        self.bound = int(fenv("SALA_CIPOLL_STUCK_READS", 5))
        self.recheck = fenv("SALA_CIPOLL_STUCK_RECHECK", 600.0)
        self.timeout = max(fenv("SALA_CIPOLL_STUCK_TIMEOUT", 20.0), 0.1)
        self.every = fenv("SALA_CIPOLL_STUCK_LIST", 300.0)
        self.list_at = {}     # repo -> its queued runs are not read again before
        self.queued = {}      # repo -> (ETag, runs, extras) of the last queued-runs answer
        self.interval, self.warned = interval, warned
        self.check_at = {}    # (repo, id) -> not read again before
        self.try_at = {}      # (repo, id) -> not delivered again before
        self.held = set()     # (repo, id) whose "kept pending" was logged
        self.dirty = False
        self.book = self.load()

    def load(self):
        path = stuck_path()
        try:
            with open(path, encoding="utf-8") as f:
                book = json.load(f)["repos"]
            if not all(isinstance(e, dict) and "state" in e for runs in book.values() for e in runs.values()):
                raise ValueError
            return book
        except FileNotFoundError:
            return {}
        except (ValueError, KeyError, TypeError, AttributeError):
            say("%s is not a stuck-run record: moved to %s.bad, starting empty" % (path, path))
            os.replace(path, path + ".bad")
            return {}

    def save(self):
        """False: the record could not be written, so nothing may be sent (a restart would send it again)."""
        if self.dirty:
            try:
                write_atomic(stuck_path(), {"repos": self.book})
                self.dirty = False
            except OSError as e:
                if ("stuck-write",) not in self.warned:
                    self.warned.add(("stuck-write",))
                    say("cannot write %s: %s; no stuck-run message is sent until it can be" % (stuck_path(), type(e).__name__))
        return not self.dirty

    def drop(self, repo, rid):
        del self.book[repo][rid]
        self.dirty = True

    def listing(self, fresh, now):
        """The list of 30 covers well under an hour on a busy repo: every SALA_CIPOLL_STUCK_LIST s, one conditional read (a 304 is free) of
        each repo's QUEUED runs, so a stuck run this poller never saw there is found too. Only a repo with a builder. → ({repo: (runs,
        extras)} as just read, a rate limit's end else 0)."""
        got = {}
        due = [r for r in fresh if now >= self.list_at.get(r, 0.0)]
        who = builders() if due else {}
        for repo in due:
            if repo.lower() not in who:
                continue
            self.list_at[repo] = now + self.every
            old = self.queued.get(repo)
            status, hd, body, err = gh_get("repos/%s/actions/runs?status=queued&per_page=100" % repo, old[0] if old else None, self.timeout)
            runs = normalize(body) if status == 200 else None
            if runs is not None:
                self.queued[repo] = (hd.get("etag") or None, runs, extras(body))
            elif not (status == 304 and old):
                wait = rate_wait(status, hd, time.time())
                say("%s: queued runs not read, HTTP %s%s%s" % (repo, status or "?", (" " + err) if err else "", " (rate limit; waiting for it to reset)" if wait else ""))
                return got, time.time() + wait if wait else 0.0   # as unread(): the first that gets no answer ends them for this pass
            got[repo] = self.queued[repo][1:]
        return got, 0.0

    def watch(self, repo, st, queued=None):
        """Remember the queued runs of the lists just read, so that one that leaves them before the limit is still judged."""
        mine = self.book.setdefault(repo, {})
        runs, extra = list(st.runs), dict(st.extra)
        if queued:
            have = {r["id"] for r in runs}
            runs += [r for r in queued[0] if r["id"] not in have]
            for k, v in queued[1].items():
                extra.setdefault(k, v)
        newest = {}           # (workflow, event, branch) -> [created_at, id] of its newest run listed
        for r in runs:
            if isinstance(r["id"], int):
                key = (r["name"], r["event"], r["head_branch"])
                newest[key] = max(newest.get(key, ["", 0]), [r["created_at"] or "", r["id"]])
        listed = set()
        for r in runs:
            if not isinstance(r["id"], int):
                continue
            rid = str(r["id"])
            listed.add(rid)
            old = mine.get(rid)
            if old and old["state"] != "queued":
                continue
            started, prs = extra.get(r["id"], (None, []))
            since = epoch(started) or epoch(r["created_at"])
            if r["status"] != "queued" or not since:
                if old:
                    self.drop(repo, rid)
            elif newest[(r["name"], r["event"], r["head_branch"])][1] != r["id"]:
                mine[rid], self.dirty = {"state": "superseded"}, True
            else:
                m = re.match(r"gh-readonly-queue/.+/pr-(\d+)-", str(r["head_branch"] or ""))
                e = {"state": "queued", "name": r["name"], "event": r["event"], "branch": r["head_branch"], "created": r["created_at"] or "",
                     "since": since, "prs": prs or ([int(m.group(1))] if m else [])}
                if e != old:
                    mine[rid], self.dirty = e, True
        for rid, e in list(mine.items()):     # one that left the lists and has a newer run of its workflow on its branch is superseded
            if e["state"] == "queued" and rid not in listed and newest.get((e["name"], e["event"], e["branch"]), ["", 0]) > [e["created"], int(rid)]:
                mine[rid], self.dirty = {"state": "superseded"}, True
        for rid in sorted((i for i, e in mine.items() if e["state"] == "superseded"), key=int)[:-SENT_KEPT]:
            self.drop(repo, rid)

    def check(self, fresh, now):
        """Read the jobs of watched runs past the limit, in the repos whose list was just read. → a rate limit's end, else 0."""
        due = sorted((self.check_at.get((repo, rid), 0.0), e["since"], repo, rid) for repo in fresh for rid, e in self.book.get(repo, {}).items()
                     if e["state"] == "queued" and now - e["since"] >= self.after and now >= self.check_at.get((repo, rid), 0.0))
        if not due:
            return 0.0
        who, left = builders(), self.bound
        for _, _, repo, rid in due:
            if repo.lower() not in who:
                if ("nobuilder", repo) not in self.warned:
                    self.warned.add(("nobuilder", repo))
                    say("no builder for %s in the repo table %s (its builder and github columns): a run queued there with no jobs is not flagged" % (repo, table_path()))
                continue
            listed = any(str(r["id"]) == rid for r in fresh[repo].runs)
            need = 1 if listed else 2
            if need > left:
                continue
            e = self.book[repo][rid]
            self.check_at[(repo, rid)] = now + self.recheck
            base = "repos/%s/actions/runs/%s" % (repo, rid)
            if not listed:                # no list says it is queued now: ask for the run itself first
                left -= 1
                status, hd, body, err = gh_get(base, None, self.timeout)
                if status == 404:
                    self.drop(repo, rid)
                    continue
                try:
                    run = json.loads(body) if status == 200 else None
                    going, started = run["status"], epoch(run.get("run_started_at"))
                except (ValueError, KeyError, TypeError, AttributeError):
                    return self.unread(repo, rid, status, hd, err)
                if going != "queued":
                    self.drop(repo, rid)
                    continue
                if started and started != e["since"]:
                    e["since"], self.dirty = started, True
                    if now - started < self.after:
                        continue
            left -= 1
            status, hd, body, err = gh_get(base + "/jobs?per_page=1", None, self.timeout)
            empty = no_jobs(body) if status == 200 else None
            if empty is None:
                return self.unread(repo, rid, status, hd, err)
            if empty:
                e.update(state="pending", found=int(now))
                self.dirty = True
                say("stuck run %s %s: queued over %d min with no jobs; to tell %s" % (repo, rid, self.after // 60, who[repo.lower()]))
        return 0.0

    def unread(self, repo, rid, status, hd, err):
        """An extra read with no usable answer flags nothing and ends this pass's reads (so a pass waits out one timeout at most)."""
        now = time.time()
        wait = rate_wait(status, hd, now)
        say("stuck run %s %s: not judged, HTTP %s%s%s" % (repo, rid, status or "?", (" " + err) if err else "", " (rate limit; waiting for it to reset)" if wait else ""))
        return now + wait if wait else 0.0

    def deliver(self, now):
        """Hand each pending message to its builder; it is marked sent only once it was taken."""
        pending = sorted((e.get("found", 0), repo, rid) for repo, runs in self.book.items() for rid, e in runs.items()
                         if e["state"] == "pending" and now >= self.try_at.get((repo, rid), 0.0))
        if not pending or not self.save():
            return
        who, away = builders(), set()
        for _, repo, rid in pending:
            e, to = self.book[repo][rid], who.get(repo.lower())
            if to and to in away:
                continue
            self.try_at[(repo, rid)] = now + self.interval
            why = tell(to, message(repo, rid, e, self.after, int(now))) if to else "the repo table names no builder for it"
            if why:
                away.add(to)
                if (repo, rid) not in self.held:
                    self.held.add((repo, rid))
                    say("stuck run %s %s: kept pending, %s" % (repo, rid, why))
                continue
            e.update(state="sent", sent=int(now), to=to)
            self.dirty = True
            say("stuck run %s %s: told %s" % (repo, rid, to))
            sent = sorted((x.get("sent", 0), i) for i, x in self.book[repo].items() if x["state"] == "sent")
            for _, i in sent[:-SENT_KEPT]:
                self.drop(repo, i)
            if not self.save():
                return

    def look(self, fresh, pause):
        """One pass, after the lists were read. → the time before which no repo may be read."""
        queued = {}
        if time.time() >= pause:
            queued, until = self.listing(fresh, time.time())
            pause = max(pause, until)
        for repo, st in fresh.items():
            self.watch(repo, st, queued.get(repo))
        if time.time() >= pause:
            pause = max(pause, self.check(fresh, time.time()))
        self.save()
        self.deliver(time.time())
        return pause


def cmd_poll(argv):
    interval = max(fenv("SALA_CIPOLL_INTERVAL", 60.0), 0.05)
    backoff_max = max(fenv("SALA_CIPOLL_BACKOFF_MAX", 600.0), interval)
    cycles = int(fenv("SALA_CIPOLL_CYCLES", 0))
    states, warned, pause, n = {}, set(), 0.0, 0
    # a tmp file a killed poller left (ours are <name>.json.<pid>.tmp)
    for folder, prefix in ((state_dir(), ""), (os.path.dirname(stuck_path()), "ci-stuck.json.")):
        try:
            for f in os.listdir(folder):
                if f.startswith(prefix) and f.endswith(".tmp"):
                    try:
                        os.unlink(os.path.join(folder, f))
                    except OSError:
                        pass
        except OSError:
            pass
    say("starts: every %gs, repo list %s, files in %s" % (interval, repo_list_path(), state_dir()))
    stuck = None
    while True:
        repos = load_repos(warned)
        if not repos and ("empty", repo_list_path()) not in warned:
            warned.add(("empty", repo_list_path()))
            say("the repo list %s names no repo: nothing is polled; add owner/name lines to ~/.config/salamander/ci-repos" % repo_list_path())
        for gone in [r for r in states if r not in repos]:
            del states[gone]
        fresh = {}
        for repo in repos:
            st = states.setdefault(repo, Repo())
            now = time.time()
            if now < st.next_at or now < pause:
                continue
            pause = max(pause, poll_one(repo, st, now, interval, backoff_max))
            if not st.fails:
                fresh[repo] = st
        try:                                 # the stuck-run look never stops the files from being kept
            stuck = stuck or Stuck(interval, warned)
            pause = stuck.look(fresh, pause)
        except Exception as e:
            if ("stuck", type(e).__name__) not in warned:
                warned.add(("stuck", type(e).__name__))
                say("the stuck-run look failed (%s: %s); polling goes on" % (type(e).__name__, e))
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
        # the run's url is one prefix and the run id when every row says so (GitHub's own form): the prefix goes once in the header, column 7 is dropped
        # a row with any other url (a renamed repo, an odd file) keeps column 7 on every row, and the header names no prefix
        pre = None
        if runs:
            u = str(runs[0].get("html_url") or "")
            i = str(runs[0].get("id"))
            if i and u.endswith(i) and all(str(r.get("html_url") or "") == u[:len(u) - len(i)] + str(r.get("id")) for r in runs):
                pre = u[:len(u) - len(i)]
        print("# %s, updated %s (%ds ago), %d run(s)%s%s" % (data.get("repo", repo), data.get("updated_iso", "?"), data["_age"], len(runs), (" of " + sha) if sha else "",
                                                          (", run url = %s<id>" % pre) if pre else ""))
        for r in runs:
            row = "%s\t%s/%s\t%s\t%s\t%s" % (r.get("id"), r.get("status"), r.get("conclusion") or "-", r.get("head_branch"), (r.get("head_sha") or "")[:7], r.get("name"))
            print(row if pre else row + "\t%s" % r.get("html_url"))
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
