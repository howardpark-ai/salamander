"""lib/mq/mq_replay.py — replay support: the queue takes its rules and its PR facts from a file (docs/mq.md "Replay").

stackshot replays past PRs through the real queue on a practice branch of the same repo. A merged PR is MERGED on GitHub (the queue would eject it) and the rules of
origin/main do not fit a practice branch, so one host key, `replay = "/abs/path/replay.json"`, swaps both for the file, and nothing is written to GitHub.

replay.json, version 1:
  {"version": 1, "run": "<[A-Za-z0-9._-]+>", "case": "<same charset>", "ci": "real" | "skip",
   "rules": {the keys of .github/mergequeue.toml; a key left out is the default; checked by the SAME code as the file (mq_config.check_repo_config)},
   "prs": {"<number>": {"state": "OPEN", "draft": false, "head": "<40 hex>", "branch": "<head branch>", "owner": "<login>", "checks": {"<name>": "pass|fail|pending|cancel"}}}}
An unknown key or a bad value is an error (the queue is blocked with the message, as for a bad host file).

What `replay` changes (the hooks are in mq_config, mq_driver, mq_gh, mq_git and mq_cli):
  rules      from the file, not from origin/main; base must start with practice/ and queue_prefix with queue/practice/ (guard), else the queue is blocked
  PR facts   pr_facts(): the file's, with base = rules.base; no GraphQL call. A number the file lacks is None = "pull request not found"
  PR content fetched by its recorded sha (git fetch origin <sha>), not refs/pull/N/head
  mode       shadow only: `on` is an error; the driver never merges, never posts a status or a comment; mq_git refuses a push outside queue/practice/
  ci         "real" = as always; "skip" = an entry ends after phase `built` (no push, no CI): verdict skipped, the PR `tested (CI not run)`, `mq wait` exit 4
  unit       the driver's systemd unit is mq-<owner>__<repo>-<run>-<case>, so it never collides with the live driver of the repo
Standard library only.
"""
import json
import os
import re

import mq_config as C

NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
TOP_KEYS = {"version", "run", "case", "ci", "rules", "prs"}
PR_KEYS = {"state", "draft", "head", "branch", "owner", "checks"}
STATES = ("OPEN", "MERGED", "CLOSED")
BUCKETS = ("pass", "fail", "pending", "cancel")
CI_MODES = ("real", "skip")
BASE_PREFIX = "practice/"             # the only base a replay may use
QUEUE_PREFIX = "queue/practice/"      # the only entry branches a replay may push or delete
SKIPPED_NOTE = "tested (CI not run)"  # the PR's reason after a ci = "skip" entry
WAIT_EXIT_SKIPPED = 4                 # `mq wait` for such a PR (3 stays "its entry passed CI")


def load(path):
    """Read and check the replay file. → (replay dict or None, [errors]). replay: path, run, case, ci, rules (a full repo config), prs ({int: facts})."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except OSError as e:
        return None, ["replay file %s: cannot be read (%s)" % (path, e.strerror or type(e).__name__)]
    except ValueError as e:
        return None, ["replay file %s: not JSON (%s)" % (path, e)]
    errs = []
    if not isinstance(data, dict):
        return None, ["replay file %s: must be a JSON object" % path]
    errs += ["replay file %s: unknown key '%s'" % (path, k) for k in sorted(data) if k not in TOP_KEYS]
    if data.get("version") != 1 or isinstance(data.get("version"), bool):
        errs.append("replay file %s: version must be 1, not %r" % (path, data.get("version")))
    for k in ("run", "case"):
        if not isinstance(data.get(k), str) or not NAME_RE.match(data[k]):
            errs.append("replay file %s: %s must be a string of [A-Za-z0-9._-], not %r" % (path, k, data.get(k)))
    if data.get("ci") not in CI_MODES:
        errs.append("replay file %s: ci must be one of %s, not %r" % (path, "|".join(CI_MODES), data.get("ci")))
    rules_in = data.get("rules", {})
    rules = None
    if not isinstance(rules_in, dict):
        errs.append("replay file %s: rules must be an object" % path)
    else:
        rules, rerrs, rwarns = C.check_repo_config(rules_in)      # the same checks as .github/mergequeue.toml; here an unknown key is an error too
        # a retired key (group_max, bisect) stays a warning, not an error: replay files written before group mode was removed still carry them, and they change nothing
        errs += ["replay file %s: rules: %s" % (path, e.replace(" (ignored)", "")) for e in rerrs + [w for w in rwarns if not w.startswith("retired key ")]]
    prs_in = data.get("prs")
    prs = {}
    if not isinstance(prs_in, dict):
        errs.append("replay file %s: prs must be an object of PR numbers" % path)
    else:
        for num, p in prs_in.items():
            why = _check_pr(p)
            if not re.fullmatch(r"[1-9][0-9]*", str(num)):
                errs.append("replay file %s: prs key %r is not a PR number" % (path, num))
            elif why:
                errs.append("replay file %s: prs[%s]: %s" % (path, num, why))
            else:
                prs[int(num)] = {"state": p.get("state", "OPEN"), "draft": p.get("draft", False), "head": p["head"], "branch": p["branch"], "owner": p["owner"],
                                 "checks": dict(p.get("checks") or {})}
    if errs:
        return None, errs
    return {"path": path, "run": data["run"], "case": data["case"], "ci": data["ci"], "rules": rules, "prs": prs}, []


def _check_pr(p):
    if not isinstance(p, dict):
        return "must be an object"
    bad = sorted(set(p) - PR_KEYS)
    if bad:
        return "unknown key '%s'" % bad[0]
    if p.get("state", "OPEN") not in STATES:
        return "state must be one of %s, not %r" % ("|".join(STATES), p.get("state"))
    if not isinstance(p.get("draft", False), bool):
        return "draft must be true or false"
    if not isinstance(p.get("head"), str) or not SHA_RE.match(p["head"]):
        return "head must be a full 40-hex sha, not %r" % (p.get("head"),)
    for k in ("branch", "owner"):
        if not isinstance(p.get(k), str) or not p[k]:
            return "%s must be a non-empty string" % k
    checks = p.get("checks", {})
    if not isinstance(checks, dict) or any(not isinstance(n, str) or not n or b not in BUCKETS for n, b in checks.items()):
        return "checks must map a name to one of %s" % "|".join(BUCKETS)
    return None


def guard(rules):
    """→ [problems] with the rules of a replay: its base and its entry branches must be on the practice side, so it cannot touch main or a real queue branch."""
    out = []
    if not rules["base"].startswith(BASE_PREFIX):
        out.append("replay rules.base %r must start with %s" % (rules["base"], BASE_PREFIX))
    if not rules["queue_prefix"].startswith(QUEUE_PREFIX):
        out.append("replay rules.queue_prefix %r must start with %s" % (rules["queue_prefix"], QUEUE_PREFIX))
    return out


def pr_facts(rp, numbers, journal=None):
    """The PR facts of the file, in the shape of mq_gh.graphql_prs: {pr: info or None}. ONE function for the build and the recheck, so both agree. No call of any kind."""
    out = {}
    for n in numbers:
        p = rp["prs"].get(n)
        out[n] = None if p is None else dict(p, base=rp["rules"]["base"], checks=dict(p["checks"]))
    if journal:
        journal("replay_facts", prs=list(numbers), file=rp["path"])
    return out


def unit_suffix(rp):
    return "-%s-%s" % (rp["run"], rp["case"]) if rp else ""


def describe(rp):
    return "replay file %s (run %s, case %s, ci %s, %d PR(s)): rules and PR facts come from it, shadow only" % (rp["path"], rp["run"], rp["case"], rp["ci"], len(rp["prs"]))
