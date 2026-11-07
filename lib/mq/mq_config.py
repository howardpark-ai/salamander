"""lib/mq/mq_config.py — the two config files of mq (docs/mq.md).

Host config, $XDG_CONFIG_HOME/mergequeue/<owner>__<repo>.toml (this machine's settings, never in the repo):
    mode = "off" | "shadow" | "on"     default off. "on" is open: the driver merges for it (ON_OPEN is True; with False, `mq add` refuses "on"). "off" is the default and the instant fallback.
    remote = "git@github.com:owner/name.git"   where the work clone fetches from and pushes to (default: that, built from the repo name)
    clone = "/path"                    the work clone (default: <state>/work)
    git_name, git_email                the identity of the merge commits (default: git's own, else "mergequeue")
    deploy_lock = "/path"              a file the merge push flocks (the repo's deploy lock) so a push and a deploy never overlap; deploy_hook is read and checked only
    replay = "/abs/path/replay.json"   rules and PR facts from that file instead of origin/main and GitHub; shadow only (lib/mq/mq_replay.py, docs/mq.md "Replay")

Repo config, .github/mergequeue.toml, read from origin/<main>'s tip at the start of each group (a PR cannot change its own rules):
    base = "main"  required = ["suites"]  pr_required = "all" | ["name", …]  queue_prefix = "queue/main/"  inflight_max = 6  suites = "all" | "select"
    queue_mode = "chain"               the only mode, and the default: one entry per PR, each stacked on the entry ahead of it, all tested at once (up to inflight_max),
                                       merged in order. "group" is refused (it was removed); a file that names it blocks the queue until the line is deleted or set to "chain"
    on_conflict = "command"            run in the entry's worktree when the only conflicted files are conflict_paths
    conflict_paths = ["tests/tool_text.snapshot.json"]
    pr_required = "all"                the checks of a PR's own head that must not have failed for it to join or stay in the line: every check reported on the head ("all", what the
                                       release script's `gh pr checks` reads), or only the named ones. A failed, cancelled or timed-out one refuses the PR
    group_max, bisect                  retired with group mode: read, ignored, and a warning names the fix (delete the line)
    flaky = ["suite", …]  fast_allow = "command"   read and checked, used by later steps
Standard library only (tomllib, Python 3.11 or newer).
"""
import os
import re
import shlex

import tomllib

from mq_state import config_dir, slug

MODES = ("off", "shadow", "on")
# True: `mq add` accepts mode "on" and the driver merges (flipped after groups ran the PR-level checks; docs/mq.md "Migration", step 5).
# With False, `mq add` refuses mode "on" (the switch stays as one line, and a test sets it False to reach that refusal). The driver merges for a host file that says "on" either way.
ON_OPEN = True

HOST_KEYS = {"mode", "remote", "clone", "git_name", "git_email", "deploy_lock", "deploy_hook", "replay"}
REPO_DEFAULTS = {
    "base": "main",
    "required": ["suites"],
    "pr_required": "all",
    "queue_prefix": "queue/main/",
    "inflight_max": 6,      # the entries are tested side by side, so two would leave the runners idle
    "queue_mode": "chain",
    "suites": "all",
    "on_conflict": None,
    "conflict_paths": ["tests/tool_text.snapshot.json"],
    "flaky": [],
    "fast_allow": None,
}
QUEUE_MODES = ("chain",)
# Keys of the group mode that was removed. A rules file that still carries one keeps working: the key is read, ignored and warned about (the warning names the fix).
RETIRED_KEYS = ("group_max", "bisect")
RETIRED_WARNING = "retired key '%s' (ignored): group mode was removed and the queue is a chain, one PR per entry; delete the line"
GROUP_MODE_ERROR = 'queue_mode = "group" is not supported: group mode was removed and the queue is a chain, one PR per entry; delete the line or set queue_mode = "chain"'
BRANCH_RE = re.compile(r"^[A-Za-z0-9._/-]+$")


def host_path(repo):
    return os.path.join(config_dir(), slug(repo) + ".toml")


def load_host(repo):
    """→ (config dict with defaults, [problems]). A missing file is the default: mode off."""
    cfg = {"mode": "off", "remote": "git@github.com:%s.git" % repo, "clone": None, "git_name": None, "git_email": None,
           "deploy_lock": None, "deploy_hook": None, "replay": None, "replay_data": None}
    errs = []
    path = host_path(repo)
    try:
        with open(path, "rb") as f:
            data = tomllib.load(f)
    except FileNotFoundError:
        return cfg, errs
    except (OSError, tomllib.TOMLDecodeError) as e:
        return cfg, ["%s: %s" % (path, e)]
    for k, v in data.items():
        if k not in HOST_KEYS:
            errs.append("%s: unknown key '%s'" % (path, k))
        elif k == "mode" and v not in MODES:
            errs.append("%s: mode must be one of %s, not %r" % (path, "|".join(MODES), v))
        elif not isinstance(v, str):
            errs.append("%s: %s must be a string" % (path, k))
        else:
            cfg[k] = v
    if cfg["replay"] is not None:
        errs += _load_replay(cfg, path, "mode" in data)
    return cfg, errs


def _load_replay(cfg, path, mode_set):
    """The replay key: read the file into cfg["replay_data"] (→ [errors]). A replay is shadow only: mode defaults to shadow, and "on" is an error."""
    import mq_replay
    errs = []
    if not mode_set:
        cfg["mode"] = "shadow"
    elif cfg["mode"] == "on":
        errs.append('%s: mode "on" is not allowed while replay is set (a replay never merges, posts or comments); use "shadow"' % path)
    if not os.path.isabs(cfg["replay"]):
        return errs + ["%s: replay must be an absolute path, not %r" % (path, cfg["replay"])]
    cfg["replay_data"], rerrs = mq_replay.load(cfg["replay"])
    return errs + rerrs


def _str_list(v):
    return isinstance(v, list) and all(isinstance(x, str) and x for x in v)


def parse_repo_config(text):
    """→ (config with defaults, [errors], [warnings]). text None = no file = the defaults."""
    if text is None:
        return check_repo_config({})
    try:
        data = tomllib.loads(text)
    except tomllib.TOMLDecodeError as e:
        return check_repo_config({})[0], [".github/mergequeue.toml: %s" % e], []
    return check_repo_config(data)


def check_repo_config(data):
    """The checks of parse_repo_config on an already parsed dict (also the rules of a replay file) → (config with defaults, [errors], [warnings])."""
    cfg = {k: (list(v) if isinstance(v, list) else v) for k, v in REPO_DEFAULTS.items()}
    errs, warns = [], []
    for k, v in data.items():
        if k in RETIRED_KEYS:
            warns.append(RETIRED_WARNING % k)
            continue
        if k not in REPO_DEFAULTS:
            warns.append("unknown key '%s' (ignored)" % k)
            continue
        ok = True
        if k == "queue_mode" and v == "group":
            errs.append(GROUP_MODE_ERROR)
            continue
        if k == "inflight_max":
            ok = isinstance(v, int) and not isinstance(v, bool) and 1 <= v <= 16
        elif k in ("required", "flaky", "conflict_paths"):
            ok = _str_list(v) and (k != "required" or bool(v))
        elif k == "pr_required":
            ok = v == "all" or (_str_list(v) and bool(v))
        elif k == "suites":
            ok = v in ("all", "select")
        elif k == "queue_mode":
            ok = v in QUEUE_MODES
        elif k == "base":
            ok = isinstance(v, str) and bool(BRANCH_RE.match(v)) and not v.startswith("queue/")
        elif k == "queue_prefix":
            ok = isinstance(v, str) and bool(BRANCH_RE.match(v)) and v.startswith("queue/") and v.endswith("/")
        elif k in ("on_conflict", "fast_allow"):
            ok = isinstance(v, str) and bool(v.strip())
        if ok and k in ("on_conflict", "fast_allow"):
            try:
                shlex.split(v)
            except ValueError:
                ok = False
        if ok:
            cfg[k] = v
        else:
            errs.append("%s = %r is not valid" % (k, v))
    return cfg, errs, warns
