"""lib/mq/mq_gh.py — every call mq makes to GitHub or to the CI-run poller goes through this file, and every call is counted (docs/mq.md).

  graphql_prs     one GraphQL read for all the PRs of a group: state, draft, head sha and branch, base branch, and the checks reported on the head.  (kind "graphql")
                  With a replay file the same answer comes from the file (mq_replay.pr_facts) and nothing is called or counted.
  check_runs      the check runs of the group head, with the last ETag as If-None-Match; a 304 is counted as its own kind.  (kind "check-runs", "check-runs-304")
  post_status     a commit status on a PR head (mode on only).  (kind "status")
  post_comment    the one comment on a PR taken out of the line.  (kind "comment")
  ci_runs         `salamander ci-runs`: the poller's file, no GitHub call. Only ever says "a run of this commit is still going".  (kind "ci-runs", in salamander_calls)

The counts go into the group record (gh_calls, salamander_calls) and each call is one line in the journal, so "how many calls did this group cost"
is a count of the record, and the tests assert it. The tool is `gh` (MQ_GH overrides the path); the poller's reader is `salamander` (MQ_SALAMANDER,
else `salamander` on PATH, else `sala`, else the sala that started mq).
"""
import json
import os
import re
import shutil
import subprocess

import mq_replay

SECRET_RE = re.compile(r"(gh[pousr]_[A-Za-z0-9]{8,}|github_pat_[A-Za-z0-9_]{8,}|Bearer\s+\S+)")


STATUS_CONTEXT = "merge queue"      # the commit status the queue posts on a PR head (mode on)


class GhError(Exception):
    pass


def clean(s):
    return SECRET_RE.sub("<hidden>", s or "")


def gh_bin():
    return os.environ.get("MQ_GH") or "gh"


def salamander_bin():
    for c in (os.environ.get("MQ_SALAMANDER"), shutil.which("salamander"), shutil.which("sala"), os.environ.get("SALA_BIN")):
        if c:
            return c
    return "salamander"


def bump(counter, kind):
    counter[kind] = counter.get(kind, 0) + 1


QUERY_ONE = ("p%d: pullRequest(number: %d) { number state isDraft headRefOid headRefName baseRefName headRepositoryOwner { login } "
             "commits(last: 1) { nodes { commit { oid statusCheckRollup { contexts(first: 100) { nodes { __typename "
             "... on CheckRun { name status conclusion databaseId } ... on StatusContext { context state } } } } } } } }")

# check buckets, the words gh's `pr checks` and release.sh use: pass | fail | cancel | pending
FAIL_CONCLUSIONS = ("FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED")


def check_buckets(contexts):
    """The checks reported on a PR head, from the GraphQL rollup nodes → {name: 'pass' | 'fail' | 'cancel' | 'pending'}. A check name seen twice (a re-run) is judged by its newest
    run. Our own commit status (STATUS_CONTEXT) is left out: a refusal posted by the queue must not refuse the PR a second time."""
    newest, out = {}, {}
    for c in contexts or []:
        if not isinstance(c, dict):
            continue
        if c.get("__typename") == "CheckRun":
            name, rank = c.get("name"), c.get("databaseId") or 0
            if c.get("status") != "COMPLETED":
                b = "pending"
            elif c.get("conclusion") == "CANCELLED":
                b = "cancel"
            elif c.get("conclusion") in FAIL_CONCLUSIONS:
                b = "fail"
            else:
                b = "pass"
        elif c.get("__typename") == "StatusContext":
            name, rank = c.get("context"), 0
            b = "fail" if c.get("state") in ("FAILURE", "ERROR") else ("pending" if c.get("state") in ("PENDING", "EXPECTED") else "pass")
        else:
            continue
        if not name or name == STATUS_CONTEXT:
            continue
        if name not in newest or rank >= newest[name]:
            newest[name], out[name] = rank, b
    return out


def failed_checks(checks, pr_required="all"):
    """The checks of a PR head that count against it → 'name=fail' / 'name=cancel' strings, in the words of release.sh's FAILED line. pr_required: 'all' or a list of check names.
    A check not reported yet, or still running, is not a failure here (the group's own run tests the tree)."""
    names = sorted(checks) if pr_required == "all" else [n for n in pr_required if n in checks]
    return ["%s=%s" % (n, checks[n]) for n in names if checks[n] in ("fail", "cancel")]


def graphql_prs(repo, numbers, calls, journal, replay=None):
    """One GraphQL read for every PR in numbers. → {pr: info or None (not found)}. info: state, draft, head, branch, base, owner, checks ({name: bucket}, see check_buckets).
    replay (the parsed replay file, mq_replay.py): the facts come from it and there is no GraphQL call, no count."""
    if replay is not None:
        return mq_replay.pr_facts(replay, numbers, journal)
    owner, name = repo.split("/", 1)
    q = "query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { %s } }" % " ".join(QUERY_ONE % (n, n) for n in numbers)
    bump(calls, "graphql")
    try:
        r = subprocess.run([gh_bin(), "api", "graphql", "-f", "query=" + q, "-f", "owner=" + owner, "-f", "name=" + name],
                           capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        journal("gh", kind="graphql", status=0, err=type(e).__name__)
        raise GhError("graphql: %s" % type(e).__name__)
    try:
        repo_data = json.loads(r.stdout)["data"]["repository"]
        if not isinstance(repo_data, dict):
            raise ValueError
    except (ValueError, KeyError, TypeError):
        journal("gh", kind="graphql", status=r.returncode, err="no repository data")
        raise GhError("graphql: no usable answer (%s)" % clean(" ".join((r.stderr or "").strip().splitlines()[-1:]))[:200])
    journal("gh", kind="graphql", status=200, prs=list(numbers))
    out = {}
    for n in numbers:
        p = repo_data.get("p%d" % n)
        if not isinstance(p, dict):
            out[n] = None
            continue
        nodes = ((p.get("commits") or {}).get("nodes")) or [{}]
        rollup = (((nodes[0] or {}).get("commit") or {}).get("statusCheckRollup")) or {}
        out[n] = {"state": p.get("state"), "draft": bool(p.get("isDraft")), "head": p.get("headRefOid"), "branch": p.get("headRefName"),
                  "base": p.get("baseRefName"), "owner": ((p.get("headRepositoryOwner") or {}).get("login")) or owner,
                  "checks": check_buckets(((rollup.get("contexts") or {}).get("nodes")) or [])}
    return out


def _parse_i(out):
    sep = "\r\n\r\n" if "\r\n\r\n" in out else "\n\n"
    head, _, body = out.partition(sep)
    lines = head.splitlines()
    m = re.match(r"HTTP/\S+\s+(\d+)", lines[0]) if lines else None
    headers = {}
    for ln in lines[1:]:
        k, s, v = ln.partition(":")
        if s:
            headers[k.strip().lower()] = v.strip()
    return (int(m.group(1)) if m else 0), headers, body


def check_runs(repo, sha, etag, calls, journal):
    """Read the check runs of a commit. → (status, etag, runs or None). status 304 = unchanged since etag (runs None: the caller keeps its last answer);
    status 0 = no answer. A 200 with a body that is not a check-run list raises GhError."""
    cmd = [gh_bin(), "api", "repos/%s/commits/%s/check-runs?per_page=100" % (repo, sha), "-i"] + (["-H", "If-None-Match: " + etag] if etag else [])
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        bump(calls, "check-runs")
        journal("gh", kind="check-runs", status=0, err=type(e).__name__)
        raise GhError("check-runs: %s" % type(e).__name__)
    status, headers, body = _parse_i(r.stdout)
    bump(calls, "check-runs-304" if status == 304 else "check-runs")
    journal("gh", kind="check-runs-304" if status == 304 else "check-runs", status=status, sha=sha[:7])
    if status == 304:
        return 304, etag, None
    if status != 200:
        raise GhError("check-runs: HTTP %s %s" % (status or "?", clean(" ".join((r.stderr or "").strip().splitlines()[-1:]))[:200]))
    try:
        runs = json.loads(body)["check_runs"]
        if not isinstance(runs, list):
            raise ValueError
    except (ValueError, KeyError, TypeError):
        raise GhError("check-runs: 200 but not a check-run list")
    return 200, headers.get("etag") or None, runs


def evaluate(runs, required):
    """The verdict of a commit from its check runs. → (verdict, detail): verdict 'pass' (every required check completed with success),
    'fail' (one completed without success), or 'pending' (not reported yet, or not completed). A check is judged by its newest run (the same name can have
    several on one commit: a re-run supersedes the older one). detail: {name: 'pass'|'pending'|'missing'|<conclusion>}."""
    newest = {}
    for r in runs:
        if not isinstance(r, dict):
            continue
        k = ((r.get("app") or {}).get("id"), r.get("name", ""))
        t = (r.get("id") or 0, r.get("started_at") or "")
        if k not in newest or t >= newest[k][0]:
            newest[k] = (t, r)
    detail, run_url = {}, None
    for name in required:
        mine = [v[1] for k, v in newest.items() if k[1] == name]
        if not mine:
            detail[name] = "missing"
            continue
        r = max(mine, key=lambda x: x.get("id") or 0)
        run_url = run_url or r.get("html_url") or r.get("details_url")
        if r.get("status") != "completed":
            detail[name] = "pending"
        else:
            detail[name] = "pass" if r.get("conclusion") == "success" else (r.get("conclusion") or "unknown")
    bad = [n for n, d in detail.items() if d not in ("pass", "pending", "missing")]
    if bad:
        return "fail", detail, run_url
    if all(d == "pass" for d in detail.values()):
        return "pass", detail, run_url
    return "pending", detail, run_url


def _write(kind, args, calls, journal, **fields):
    """A POST through `gh api` (the -f fields make it one). Counted whether or not it works; raises GhError when it does not."""
    bump(calls, kind)
    try:
        r = subprocess.run([gh_bin(), "api"] + args, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        journal("gh", kind=kind, status=0, err=type(e).__name__, **fields)
        raise GhError("%s: %s" % (kind, type(e).__name__))
    journal("gh", kind=kind, status=200 if r.returncode == 0 else r.returncode, **fields)
    if r.returncode != 0:
        raise GhError("%s: %s" % (kind, clean(" ".join((r.stderr or r.stdout or "").strip().splitlines()[-1:]))[:200]))


def post_status(repo, sha, state, description, target_url, calls, journal):
    """state: pending | success | failure | error. One commit status under the context "merge queue"; the same state and text again changes nothing at GitHub."""
    args = ["repos/%s/statuses/%s" % (repo, sha), "-f", "state=" + state, "-f", "context=" + STATUS_CONTEXT, "-f", "description=" + description[:140]]
    if target_url:
        args += ["-f", "target_url=" + target_url]
    _write("status", args, calls, journal, sha=sha[:7], state=state)


def post_comment(repo, pr, body, calls, journal):
    _write("comment", ["repos/%s/issues/%d/comments" % (repo, pr), "-f", "body=" + body], calls, journal, pr=pr)


def ci_runs(repo, sha, calls, journal):
    """Ask the poller's file (no GitHub call). → ('going', info) a run of the commit is listed and not completed; ('listed', info) listed and all completed;
    ('none', None) fresh file with no run of it; ('unavailable', None) no file, stale, unreadable or no salamander. info: {id, url}."""
    bump(calls, "ci-runs")
    try:
        r = subprocess.run([salamander_bin(), "ci-runs", repo, "--sha", sha], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        journal("ci-runs", status=-1, err=type(e).__name__)
        return "unavailable", None
    if r.returncode != 0:
        journal("ci-runs", status=r.returncode)
        return "unavailable", None
    try:
        runs = json.loads(r.stdout)["runs"]
        runs = [x for x in runs if isinstance(x, dict) and str(x.get("head_sha", "")).startswith(sha[:7])]
    except (ValueError, KeyError, TypeError):
        journal("ci-runs", status=-2)
        return "unavailable", None
    if not runs:
        journal("ci-runs", status=0, runs=0)
        return "none", None
    info = {"id": runs[0].get("id"), "url": runs[0].get("html_url")}
    going = [x for x in runs if x.get("status") != "completed"]
    journal("ci-runs", status=0, runs=len(runs), going=len(going))
    return ("going" if going else "listed"), info
