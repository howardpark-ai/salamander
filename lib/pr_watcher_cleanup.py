#!/usr/bin/env python3
"""lib/pr_watcher_cleanup.py — delete the one-time scheduled tasks that cloud sessions leave behind to watch a pull request (docs/units.md).

A cloud session that wants a pull request checked later sets a one-time scheduled task ("trigger") on the signed-in Claude account. When it
fires, the account gets a "turned off" notice and a switched-off task stays behind. This job (a systemd user timer, sala-pr-watcher-cleanup)
lists the account's tasks, finds the finished PR watchers and deletes them.

Standard library only (and the `gh` CLI for a pull request's state); no model call. Run as `python3 -I pr_watcher_cleanup.py [--dry-run] [--only TASK_ID]…`
(--only limits the pass to the named tasks, for a check by hand; the timer passes nothing).

Only a PR WATCHER is ever looked at: a task with no cron expression (one-time) whose prompt names a pull request (`owner/repo#N`, a
github.com/.../pull/N link, or `PR #N`). Every other task (a recurring routine, a one-time reminder about something else) is never touched.

A watcher is DONE when it fired and is off (ended_reason run_once_fired), OR (not yet fired) every pull request it names is merged or closed,
OR its session is archived or gone. What happens to a done task depends on whether its creating session is live:
  * no live creator (the session is archived, gone, not named, or not connected): deleted at once, the session is never woken;
  * a live creator (status active and connected): the creator is asked ONCE, through stackshot's `client.py message`, to delete it; the job
    deletes it itself after SALA_PRWATCH_GRACE_S (24 h) from the ask.
A task the job cannot place (switched off but never fired, a pull request it cannot read, an account other than the signed-in one) is left alone
and logged once. An API error (listing, a session, GitHub, the delete itself) leaves that task as it was. --dry-run deletes, asks and writes nothing.

Each action is one line of `<state>/pr-watcher-cleanup.log` and of stdout (journald): time (SALA_TZ, else the machine's own zone), action (delete, ask, skip, error), task id,
session, pull requests, reason. The state file keeps what was asked and when. No token is ever written anywhere.

Credentials: the same sign-in the other API readers use (lib/rc.sh, lib/revive.sh, web/src/sala_web/quota.py): the OAuth access token in
`<claude config dir>/.credentials.json` as a bearer token, plus the account's organization uuid (`.claude.json`) as `x-organization-uuid`.
The API is the one the CLI's scheduled-task tool uses: GET /v1/code/triggers (header anthropic-beta: ccr-triggers-2026-01-30),
DELETE /v1/code/triggers/<id>, GET /v1/code/sessions/<id>.

Environment (all optional; the SALA_PRWATCH_* names below the first line are for tests): SALA_PRWATCH_GRACE_S (86400), SALA_PRWATCH_STATE_DIR
(default $XDG_STATE_HOME/salamander/pr-watcher-cleanup), SALA_STACKSHOT_CLIENT / SALA_STACKSHOT_DIR (the client for the ask; none: nobody is asked
and a live creator's task waits the grace from when it was first seen done), CLAUDE_CONFIG_DIR.
Tests: SALA_PRWATCH_API, SALA_PRWATCH_CREDS, SALA_PRWATCH_ACCOUNT_FILE, SALA_PRWATCH_GH, SALA_PRWATCH_MSG_CMD, SALA_PRWATCH_NOW.
Exit: 0 = the pass ran (also with tasks left alone), 1 = an API error stopped part of it or all of it, 2 = usage.
"""
import fcntl
import json
import os
import re
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime
from zoneinfo import ZoneInfo

BETA = "ccr-triggers-2026-01-30"
SENDER = "pr-watcher-cleanup"
GRACE_S = 86400

URL_PR = re.compile(r"github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)/pull/(\d+)")
REPO_PR = re.compile(r"(?<![\w./-])([A-Za-z0-9_][A-Za-z0-9_-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*)#(\d+)")
BARE_PR = re.compile(r"(?:\bPRs?\b|\bpull requests?\b)\s*#?(\d+)", re.I)
SESSION_ID = re.compile(r"\b(?:cse|session)_[A-Za-z0-9]{20,}\b")


class ApiError(Exception):
    """An API or GitHub call that did not give an answer: the task it was for stays as it was."""


# ---- settings ------------------------------------------------------------------------------------------------------------------

def fenv(name, default):
    try:
        v = float(os.environ.get(name, "") or default)
        return v if v >= 0 else default
    except ValueError:
        return default


def now_s():
    v = os.environ.get("SALA_PRWATCH_NOW")
    try:
        return float(v) if v else time.time()
    except ValueError:
        return time.time()


def state_dir():
    d = os.environ.get("SALA_PRWATCH_STATE_DIR")
    if d:
        return d
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "salamander", "pr-watcher-cleanup")


def claude_dir():
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")


def creds_path():
    return os.environ.get("SALA_PRWATCH_CREDS") or os.path.join(claude_dir(), ".credentials.json")


def account_path():
    p = os.environ.get("SALA_PRWATCH_ACCOUNT_FILE")
    if p:
        return p
    return os.path.join(os.environ["CLAUDE_CONFIG_DIR"], ".claude.json") if os.environ.get("CLAUDE_CONFIG_DIR") else os.path.join(os.path.expanduser("~"), ".claude.json")


def _local(epoch):
    """The moment in SALA_TZ (an IANA name) when it is set and valid, else in this machine's own zone."""
    z = os.environ.get("SALA_TZ")
    if z:
        try:
            return datetime.fromtimestamp(epoch, ZoneInfo(z))
        except Exception:
            pass
    return datetime.fromtimestamp(epoch).astimezone()


def local_text(epoch):
    """`Thu Nov 5th 12:00 UTC`: the date form prose uses, with the zone's own label."""
    d = _local(epoch)
    n = d.day
    suf = "th" if 11 <= n % 100 <= 13 else {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")
    return "%s %s %d%s %s %s" % (d.strftime("%a"), d.strftime("%b"), n, suf, d.strftime("%H:%M"), d.strftime("%Z"))


def local_iso(epoch):
    return _local(epoch).isoformat(timespec="seconds")


# ---- the API -------------------------------------------------------------------------------------------------------------------

class Api:
    """Bearer calls to the account's code endpoints. The token lives only in this object's headers and is never printed."""

    def __init__(self, base, token, org=""):
        self.base = base.rstrip("/")
        self.h = {"Authorization": "Bearer " + token, "anthropic-version": "2023-06-01", "anthropic-client-platform": "cli", "anthropic-beta": BETA}
        if org:
            self.h["x-organization-uuid"] = org

    def call(self, method, path, timeout=20):
        """→ (status, parsed json or None). A network failure raises ApiError; an HTTP error status is returned."""
        req = urllib.request.Request(self.base + path, headers=self.h, method=method)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                raw = r.read()
                status = r.status
        except urllib.error.HTTPError as e:
            raw = e.read()
            status = e.code
        except Exception as e:  # URLError, timeout, reset
            raise ApiError("%s %s: %s" % (method, path.split("?")[0], type(e).__name__))
        try:
            return status, json.loads(raw.decode("utf-8", "replace")) if raw.strip() else None
        except ValueError:
            return status, None


def err_text(body):
    """The API's own error message (no token is ever in one), cut short."""
    if isinstance(body, dict):
        e = body.get("error")
        if isinstance(e, dict):
            return str(e.get("message") or e.get("type") or "")[:160]
    return ""


def load_api():
    """→ (Api, own account uuid) or raises ApiError("no sign-in…" / "token expired"). Reads the files, prints nothing."""
    try:
        with open(creds_path(), encoding="utf-8") as f:
            oauth = json.load(f).get("claudeAiOauth") or {}
    except (OSError, ValueError):
        raise ApiError("no readable sign-in at %s" % creds_path())
    token = oauth.get("accessToken")
    if not token:
        raise ApiError("the sign-in has no access token")
    exp = oauth.get("expiresAt")
    if isinstance(exp, (int, float)) and exp / 1000.0 < now_s() + 30 and "SALA_PRWATCH_NOW" not in os.environ:
        raise ApiError("the access token is expired (the CLI refreshes it the next time a session on this login runs)")
    org = acct = ""
    try:
        with open(account_path(), encoding="utf-8") as f:
            oa = json.load(f).get("oauthAccount") or {}
        org, acct = str(oa.get("organizationUuid") or ""), str(oa.get("accountUuid") or "")
    except (OSError, ValueError):
        pass
    return Api(os.environ.get("SALA_PRWATCH_API") or "https://api.anthropic.com", token, org), acct


def list_triggers(api):
    out, cursor = [], ""
    for _ in range(20):  # 2000 tasks; a longer list is cut and said
        status, d = api.call("GET", "/v1/code/triggers?limit=100" + ("&cursor=" + cursor if cursor else ""))
        if status != 200 or not isinstance(d, dict) or not isinstance(d.get("data"), list):
            raise ApiError("list triggers: HTTP %s %s" % (status, err_text(d)))
        out.extend(x for x in d["data"] if isinstance(x, dict) and x.get("id"))
        cursor = str(d.get("next_cursor") or "")
        if not d.get("has_more") or not cursor:
            return out, True
    return out, False


# ---- reading a task ------------------------------------------------------------------------------------------------------------

def prompt_text(t):
    parts = []
    ds = t.get("derived_state")
    if isinstance(ds, dict) and ds.get("prompt"):
        parts.append(str(ds["prompt"]))
    jc = t.get("job_config")
    if jc:
        parts.append(json.dumps(jc, ensure_ascii=False))
    parts.append(str(t.get("name") or ""))
    return "\n".join(parts)


def pr_refs(text):
    """→ sorted [(repo or "", number)]: every pull request the text names; a bare `PR #N` has no repo."""
    found = set()
    for m in URL_PR.finditer(text):
        found.add((m.group(1), int(m.group(2))))
    for m in REPO_PR.finditer(text):
        found.add((m.group(1), int(m.group(2))))
    qualified = {n for _, n in found}
    for m in BARE_PR.finditer(text):
        if int(m.group(1)) not in qualified:
            found.add(("", int(m.group(1))))
    return sorted(found)


def session_of(t):
    s = str(t.get("persistent_session_id") or "")
    if not s:
        m = SESSION_ID.search(json.dumps(t.get("job_config") or {}))
        s = m.group(0) if m else ""
    return "cse_" + s.split("_", 1)[1] if s.startswith("session_") else s


def pr_label(refs):
    return ",".join(("%s#%d" % (r, n)) if r else "#%d" % n for r, n in refs) or "-"


def gh_pr_state(repo, number):
    """→ "open" | "merged" | "closed", from `gh api repos/<repo>/pulls/<n>`. Raises ApiError when GitHub gives no answer."""
    gh = shlex.split(os.environ.get("SALA_PRWATCH_GH") or "gh")
    try:
        p = subprocess.run(gh + ["api", "repos/%s/pulls/%d" % (repo, number)], capture_output=True, text=True, timeout=30)
        if p.returncode != 0:
            raise ApiError("gh api repos/%s/pulls/%d: exit %d" % (repo, number, p.returncode))
        d = json.loads(p.stdout)
        st = d.get("state")
        if st == "open":
            return "open"
        if st == "closed":
            return "merged" if d.get("merged") or d.get("merged_at") else "closed"
    except (OSError, subprocess.TimeoutExpired, ValueError):
        pass
    raise ApiError("gh api repos/%s/pulls/%d: no readable answer" % (repo, number))


# ---- the pass ------------------------------------------------------------------------------------------------------------------

class Run:
    def __init__(self, api, own_account, dry, grace_s, now, state, say, pr_state, ask, session_info):
        self.api, self.own, self.dry, self.grace, self.now, self.state = api, own_account, dry, grace_s, now, state
        self.say, self.pr_state, self.ask = say, pr_state, ask
        self.session_info = session_info
        self.prs, self.sessions = {}, {}
        self.errors = 0
        self.deleted = self.asked = 0

    def pr(self, repo, n):
        if (repo, n) not in self.prs:
            self.prs[(repo, n)] = self.pr_state(repo, n)
        return self.prs[(repo, n)]

    def session(self, sid):
        """→ "live" | "idle" (exists, not archived, not connected) | "archived" | "gone". Raises ApiError on any other answer."""
        if sid not in self.sessions:
            self.sessions[sid] = self.session_info(sid)
        return self.sessions[sid]

    def classify(self, t, refs, sid):
        """→ (kind, why): kind "done" | "active" | "skip"."""
        fired = (not t.get("enabled")) and t.get("ended_reason") == "run_once_fired"
        if fired:
            return "done", "fired and off"
        if not t.get("enabled"):
            return "skip", "switched off but never fired (ended_reason %r)" % (t.get("ended_reason") or "")
        if sid:
            s = self.session(sid)
            if s in ("archived", "gone"):
                return "done", "session %s" % ("archived" if s == "archived" else "not found")
        if refs and all(r for r, _ in refs):
            states = [self.pr(r, n) for r, n in refs]
            if all(x != "open" for x in states):
                return "done", "PR %s" % ("merged" if all(x == "merged" for x in states) else "closed" if all(x == "closed" for x in states) else "merged or closed")
        return "active", ""

    def delete(self, t, sid, refs, why):
        line = "id=%s session=%s pr=%s reason=%s" % (t["id"], sid or "-", pr_label(refs), why)
        if self.dry:
            self.say("would-delete", line)
            return True
        status, d = self.api.call("DELETE", "/v1/code/triggers/" + t["id"])
        if status in (200, 202, 204):
            self.say("delete", line)
        elif status == 404:
            self.say("delete", line + " (it was already gone)")
        else:
            self.say("error", "id=%s delete: HTTP %s %s" % (t["id"], status, err_text(d)))
            self.errors += 1
            return False
        self.state["done"].pop(t["id"], None)
        self.deleted += 1
        return True

    def handle(self, t):
        tid = t["id"]
        text = prompt_text(t)
        refs = pr_refs(text)
        if t.get("cron_expression") or not refs:
            return  # a recurring routine, or a task that names no pull request: not a PR watcher, never looked at
        creator = (t.get("creator") or {}).get("account_uuid") if isinstance(t.get("creator"), dict) else ""
        sid = session_of(t)
        if creator and self.own and creator != self.own:
            self.skip(tid, "created by another account", sid, refs)
            return
        kind, why = self.classify(t, refs, sid)
        if kind == "skip":
            self.skip(tid, why, sid, refs)
            return
        self.state["skipped"].pop(tid, None)
        if kind == "active":
            self.state["done"].pop(tid, None)
            return
        live, how = False, "no session named"
        if sid:
            s = self.session(sid)
            live = s == "live"
            how = {"live": "live", "idle": "creator not connected", "archived": "creator archived", "gone": "creator not found"}[s]
        if not live:
            self.delete(t, sid, refs, "%s; %s: deleted at once" % (why, how))
            return
        rec = self.state["done"].setdefault(tid, {"first_done_at": self.now, "session": sid})
        if not rec.get("asked_at"):
            if self.dry:
                self.say("would-ask", "id=%s session=%s pr=%s reason=%s" % (tid, sid, pr_label(refs), why))
            else:
                ok, out = self.ask(sid, self.message(t, refs, why))
                if ok:
                    rec["asked_at"] = self.now
                    self.asked += 1
                    self.say("ask", "id=%s session=%s pr=%s reason=%s; will delete it after %s" % (tid, sid, pr_label(refs), why, local_text(self.now + self.grace)))
                else:
                    self.say("error", "id=%s ask %s: %s (tried again next run)" % (tid, sid, out))
        base = rec.get("asked_at") or rec["first_done_at"]
        if self.now >= base + self.grace:
            self.delete(t, sid, refs, "%s; the creator did not delete it within %d h of %s" % (why, round(self.grace / 3600), "the ask" if rec.get("asked_at") else "first seen done"))

    def message(self, t, refs, why):
        return ("Your one-time scheduled task %s (%s) for %s is finished (%s). Please delete it: it only leaves a switched-off task behind. "
                "If you cannot, nothing is needed: it is deleted automatically after %s. (Automatic message from the pr-watcher-cleanup job; no reply needed.)"
                % (t["id"], t.get("name") or "-", pr_label(refs), why, local_text(self.now + self.grace)))

    def skip(self, tid, why, sid, refs):
        if self.state["skipped"].get(tid) != why:   # said once per reason, not every pass
            self.state["skipped"][tid] = why
            self.say("skip", "id=%s session=%s pr=%s left alone: %s" % (tid, sid or "-", pr_label(refs), why))


def session_info_for(api):
    def info(sid):
        status, d = api.call("GET", "/v1/code/sessions/" + sid)
        if status == 404:
            return "gone"
        if status == 400:   # not a session id the API knows: nothing can be live there
            return "gone"
        if status != 200 or not isinstance(d, dict):
            raise ApiError("session %s: HTTP %s %s" % (sid, status, err_text(d)))
        rs = d.get("response_shape") if isinstance(d.get("response_shape"), dict) else d
        st = rs.get("status")
        if st == "archived":
            return "archived"
        if st == "active" and rs.get("connection_status") == "connected":
            return "live"
        return "idle"
    return info


def stackshot_client():
    c = os.environ.get("SALA_STACKSHOT_CLIENT")
    if c:
        return c
    d = os.environ.get("SALA_STACKSHOT_DIR")
    if d is None:
        d = os.path.join(os.path.expanduser("~"), "stackshot")
    return os.path.join(d, "client.py") if d else ""


def ask_via_client(sid, text):
    """→ (delivered, short output). `client.py message <session> - --sender pr-watcher-cleanup`, the text on stdin."""
    cmd = os.environ.get("SALA_PRWATCH_MSG_CMD")
    if cmd:
        argv = shlex.split(cmd)
    else:
        c = stackshot_client()
        if not c or not os.path.isfile(c):
            return False, "no stackshot client.py on this box (SALA_STACKSHOT_CLIENT, SALA_STACKSHOT_DIR)"
        argv = [sys.executable, "-I", c, "message"]
    try:
        p = subprocess.run(argv + [sid, "-", "--sender", SENDER], input=text, capture_output=True, text=True, timeout=150)
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, type(e).__name__
    out = " ".join((p.stdout + " " + p.stderr).split())[:160]
    return p.returncode == 0, out


# ---- state and log -------------------------------------------------------------------------------------------------------------

def load_state(path):
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        if isinstance(d, dict):
            return {"done": d.get("done") if isinstance(d.get("done"), dict) else {}, "skipped": d.get("skipped") if isinstance(d.get("skipped"), dict) else {}}
    except (OSError, ValueError):
        pass
    return {"done": {}, "skipped": {}}


def save_state(path, state):
    tmp = "%s.%d.tmp" % (path, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(state, f, ensure_ascii=False, indent=1, sort_keys=True)
            f.write("\n")
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def main(argv):
    dry, grace, only = False, fenv("SALA_PRWATCH_GRACE_S", GRACE_S), set()
    args = argv[1:]
    while args:
        a = args.pop(0)
        if a == "--dry-run":
            dry = True
        elif a == "--only" and args and args[0].startswith("trig_"):
            only.add(args.pop(0))
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            print("usage: pr_watcher_cleanup.py [--dry-run] [--only TASK_ID]…", file=sys.stderr)
            return 2
    d = state_dir()
    os.makedirs(os.path.dirname(d), exist_ok=True)
    os.makedirs(d, mode=0o700, exist_ok=True)
    lock = os.open(os.path.join(d, "lock"), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("another pass holds the lock: nothing done")
        return 0
    now = now_s()
    log_path, state_path = os.path.join(d, "pr-watcher-cleanup.log"), os.path.join(d, "state.json")

    def say(action, text):
        line = "%s %s %s" % (local_iso(now), action, text)
        print(line, flush=True)
        if not dry:
            try:
                with open(log_path, "a", encoding="utf-8") as f:
                    f.write(line + "\n")
            except OSError:
                pass

    try:
        api, own = load_api()
    except ApiError as e:
        say("error", str(e) + ": nothing touched")
        return 0 if "expired" in str(e) else 1
    state = load_state(state_path)
    try:
        tasks, complete = list_triggers(api)
    except ApiError as e:
        say("error", "%s: nothing touched" % e)
        return 1
    if not complete:
        say("error", "the task list is longer than 2000: only the first part was read")
    if only:
        tasks = [t for t in tasks if t["id"] in only]
        complete = False   # a partial look forgets no record
    run = Run(api, own, dry, grace, now, state, say, gh_pr_state, ask_via_client, session_info_for(api))
    for t in tasks:
        try:
            run.handle(t)
        except ApiError as e:
            run.errors += 1
            say("error", "id=%s left as it was: %s" % (t.get("id"), e))
    if complete and not run.errors:   # forget the records of tasks that are gone
        ids = {t["id"] for t in tasks}
        for k in [k for k in state["done"] if k not in ids]:
            del state["done"][k]
        for k in [k for k in state["skipped"] if k not in ids]:
            del state["skipped"][k]
    if not dry:
        save_state(state_path, state)
    print("%s: %d task(s) listed, %d deleted, %d asked, %d error(s)%s" % (local_iso(now), len(tasks), run.deleted, run.asked, run.errors, " (dry run)" if dry else ""))
    return 1 if run.errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
