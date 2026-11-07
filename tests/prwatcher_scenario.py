"""Scenario test for the PR-watcher cleanup job (lib/pr_watcher_cleanup.py, systemd/sala-pr-watcher-cleanup.{service,timer}, docs/units.md), run by tests/prwatcher.sh.

The job runs as its own command (`python3 -I lib/pr_watcher_cleanup.py`) against a fake API: a local http server that serves GET /v1/code/triggers (two pages),
GET /v1/code/sessions/<id> and DELETE /v1/code/triggers/<id> from a table the scenario edits, a fake `gh` that answers a pull request's state from a file, and a
fake message command that logs what it was asked to send. The clock is injected (SALA_PRWATCH_NOW). No network beyond 127.0.0.1, no tmux, no claude, no process is killed.

What it covers: a fired-and-off task of an archived, of a missing and of a not-connected session deleted at once with no message; the same of a live session: ONE
message, nothing deleted, no second message at the next pass, deleted 24 h after the ask (the clock moved), and a failed message tried again next pass with the
deletion 24 h after the task was first seen done; a pull request merged or closed (and a mix of both), a pull request still open left alone, a session
archived; an active task (not fired, PR open, session live) untouched; a task it cannot place (switched off and never fired, another account's, a pull request
it cannot read) untouched and logged once; a recurring routine and a one-time task that names no pull request never looked at; an API error (the list, a
session, GitHub, the delete itself) leaving that task as it was while the others go on, with exit 1; an expired token touching nothing; --dry-run deleting,
asking and writing nothing; the token appearing nowhere in the log, the state or the output; the request headers (bearer, the beta header, the organization).
"""
import fcntl
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = str(pathlib.Path(__file__).resolve().parent.parent)
SCRIPT = os.path.join(ROOT, "lib", "pr_watcher_cleanup.py")
fails, ran = [], []


def check(name, cond, got=None):
    ran.append(name)
    if not cond:
        fails.append(name)
        print("FAIL " + name + (": " + str(got)[:700] if got is not None else ""))


# the scratch folder: its own, locked while this runs (systemd-tmpfiles ageing honours flock) and removed on every exit
T = pathlib.Path(tempfile.mkdtemp(prefix="prwatchscen-"))
_lock = os.open(str(T), os.O_RDONLY)
fcntl.flock(_lock, fcntl.LOCK_EX)
TOKEN = "tok-b827-UNIQUE-secret-value-0123456789"
ORG, ME, OTHER = "org-0000-test", "acct-me-test", "acct-someone-else"
T0 = 1_793_700_000.0   # the injected clock's start

SRV = {"triggers": [], "sessions": {}, "deleted": [], "calls": [], "fail": {}, "pages": False}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, obj=None):
        body = json.dumps(obj if obj is not None else {}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path
        SRV["calls"].append(("GET", path, self.headers.get("Authorization") == "Bearer " + TOKEN, self.headers.get("anthropic-beta"), self.headers.get("x-organization-uuid")))
        if path.startswith("/v1/code/triggers"):
            if SRV["fail"].get("list"):
                return self.reply(500, {"error": {"message": "boom", "type": "api_error"}})
            ts = SRV["triggers"]
            if SRV["pages"]:
                if "cursor=p2" in path:
                    return self.reply(200, {"data": ts[1:], "has_more": False})
                return self.reply(200, {"data": ts[:1], "has_more": True, "next_cursor": "p2"})
            return self.reply(200, {"data": ts, "has_more": False})
        if path.startswith("/v1/code/sessions/"):
            sid = path.rsplit("/", 1)[1]
            if sid in SRV["fail"].get("sessions", ()):
                return self.reply(500, {"error": {"message": "session boom"}})
            s = SRV["sessions"].get(sid)
            if s is None:
                return self.reply(404, {"error": {"message": "Session %s not found" % sid, "type": "not_found_error"}})
            return self.reply(200, {"response_shape": {"id": sid, "status": s[0], "connection_status": s[1]}})
        self.reply(404)

    def do_DELETE(self):
        tid = self.path.rsplit("/", 1)[1]
        SRV["calls"].append(("DELETE", self.path, self.headers.get("Authorization") == "Bearer " + TOKEN, self.headers.get("anthropic-beta"), self.headers.get("x-organization-uuid")))
        if tid in SRV["fail"].get("delete", ()):
            return self.reply(500, {"error": {"message": "delete boom"}})
        if tid in SRV["fail"].get("delete404", ()):
            return self.reply(404, {"error": {"message": "no such task"}})
        SRV["deleted"].append(tid)
        SRV["triggers"] = [t for t in SRV["triggers"] if t["id"] != tid]
        self.reply(200, {})


httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=httpd.serve_forever, daemon=True).start()
PORT = httpd.server_address[1]

BIN = T / "bin"
BIN.mkdir()
GHDB = T / "gh.json"
MSGLOG = T / "messages.log"
(BIN / "gh").write_text('#!/bin/sh\n# fake gh: gh api repos/<o>/<r>/pulls/<n>; answers from $FAKE_GH_DB\nexec python3 -I %s "$@"\n' % (T / "fakegh.py"))
(T / "fakegh.py").write_text(
    "import json, os, sys\n"
    "a = sys.argv[1:]\n"
    "key = a[1].replace('repos/', '', 1).replace('/pulls/', '#')\n"
    "db = json.load(open(os.environ['FAKE_GH_DB']))\n"
    "v = db.get(key)\n"
    "if v is None: sys.stderr.write('gh: Not Found (HTTP 404)\\n'); sys.exit(1)\n"
    "print(json.dumps(v))\n")
(BIN / "gh").chmod(0o755)
(BIN / "msg").write_text('#!/bin/sh\n# fake message command: logs "<to> | <text>"; exits 1 when the file msg.fail exists\n'
                         'if [ -e %s ]; then echo "delivery failed" >&2; exit 1; fi\n'
                         'printf "%%s | %%s\\n" "$1" "$(cat)" >> %s\nexit 0\n' % (T / "msg.fail", MSGLOG))
(BIN / "msg").chmod(0o755)
CREDS = T / "credentials.json"
CREDS.write_text(json.dumps({"claudeAiOauth": {"accessToken": TOKEN, "expiresAt": int((T0 + 86400 * 5) * 1000)}}))
ACCT = T / "claude.json"
ACCT.write_text(json.dumps({"oauthAccount": {"organizationUuid": ORG, "accountUuid": ME}}))
(T / "tmp").mkdir()

N = [0]


def sid(tag):
    return "cse_01" + (tag + "X" * 22)[:22]


def trig(tag, prompt, enabled=False, ended="run_once_fired", session=None, cron="", creator=ME, name=None):
    return {"id": "trig_" + tag, "name": name or ("Check " + tag), "enabled": enabled, "ended_reason": ended, "cron_expression": cron,
            "persistent_session_id": session or "", "creator": {"account_uuid": creator},
            "derived_state": {"prompt": prompt},
            "job_config": {"ccr": {"events": [{"data": {"message": {"role": "user", "content": prompt}}}]}}}


def job(state, now, *args, extra=None, clock=True):
    env = {**os.environ, "HOME": str(T / "home"), "TMPDIR": str(T / "tmp"), "PATH": str(BIN) + os.pathsep + os.environ.get("PATH", ""),
           "SALA_PRWATCH_API": "http://127.0.0.1:%d" % PORT, "SALA_PRWATCH_CREDS": str(CREDS), "SALA_PRWATCH_ACCOUNT_FILE": str(ACCT),
           "SALA_PRWATCH_STATE_DIR": str(state), "SALA_PRWATCH_GH": str(BIN / "gh"), "SALA_PRWATCH_MSG_CMD": str(BIN / "msg"),
           "FAKE_GH_DB": str(GHDB), "no_proxy": "127.0.0.1", "NO_PROXY": "127.0.0.1", **(extra or {})}
    for k in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "CLAUDE_CONFIG_DIR", "SALA_STACKSHOT_CLIENT", "SALA_STACKSHOT_DIR"):
        env.pop(k, None)
    if clock:
        env["SALA_PRWATCH_NOW"] = str(now)
    else:
        env.pop("SALA_PRWATCH_NOW", None)
    r = subprocess.run([sys.executable, "-I", SCRIPT, *args], capture_output=True, text=True, env=env, timeout=90)
    return r.returncode, r.stdout, r.stderr


def fresh(triggers, sessions=None, prs=None, fail=None, pages=False):
    N[0] += 1
    SRV.update(triggers=list(triggers), sessions=dict(sessions or {}), deleted=[], calls=[], fail=dict(fail or {}), pages=pages)
    GHDB.write_text(json.dumps(prs or {}))
    MSGLOG.unlink(missing_ok=True)
    (T / "msg.fail").unlink(missing_ok=True)
    st = T / ("state%d" % N[0])
    return st


def messages():
    return MSGLOG.read_text().splitlines() if MSGLOG.exists() else []


def logtext(st):
    p = st / "pr-watcher-cleanup.log"
    return p.read_text() if p.exists() else ""


def main():
    # 1. fired and off, creator archived / missing / not connected: deleted at once, nobody is messaged
    s_arch, s_idle = sid("arch"), sid("idle")
    st = fresh([trig("a1", "Safety check-in on PR example-org/repo-a#11: re-check CI.", session=s_arch),
                trig("a2", "Re-check PR example-org/repo-a#12", session=sid("gone")),
                trig("a3", "Re-check https://github.com/example-org/repo-a/pull/13 later", session=s_idle),
                trig("a4", "Check PR #14 again", session="")],
               sessions={s_arch: ("archived", "disconnected"), s_idle: ("active", "disconnected")},
               prs={"example-org/repo-a#11": {"state": "open"}, "example-org/repo-a#12": {"state": "open"}, "example-org/repo-a#13": {"state": "open"}})
    rc, out, err = job(st, T0)
    check("fired+off tasks of an archived, a missing, a not-connected and an unnamed session: all four deleted at once, exit 0", sorted(SRV["deleted"]) == ["trig_a1", "trig_a2", "trig_a3", "trig_a4"] and rc == 0, (rc, SRV["deleted"], out, err))
    check("... nobody is messaged", messages() == [], messages())
    lg = logtext(st)
    check("... one log line per deletion with the task id, session, pull request and reason", all(x in lg for x in ("id=trig_a1 session=%s pr=example-org/repo-a#11 reason=fired and off; creator archived" % s_arch, "id=trig_a2", "creator not found", "creator not connected", "no session named", "pr=example-org/repo-a#13", "pr=#14")), lg)
    check("... the log lines carry the zone offset", " delete id=trig_a1" in lg and re.search(r"[+-][0-9]{2}:[0-9]{2} delete", lg) is not None, lg)
    check("... the requests carried the bearer, the beta header and the organization",
          SRV["calls"] and all(c[2] and c[3] == "ccr-triggers-2026-01-30" and c[4] == ORG for c in SRV["calls"]), SRV["calls"][:3])
    leak = [p.name for p in [st / "pr-watcher-cleanup.log", st / "state.json"] if p.exists() and TOKEN in p.read_text()]
    check("... the token is in no log, state file or output", not leak and TOKEN not in out and TOKEN not in err, leak)
    rc, out, err = job(st, T0 + 1800)
    check("... a second pass finds nothing to do", rc == 0 and SRV["deleted"].count("trig_a1") == 1 and "0 deleted" in out, out)

    # 2. fired and off, creator live: one message, then 24 h, then deleted; the message is not repeated
    s_live = sid("live")
    st = fresh([trig("b1", "Re-check PR example-org/repo-b#21 (CI)", session=s_live)], sessions={s_live: ("active", "connected")},
               prs={"example-org/repo-b#21": {"state": "open"}})
    rc, out, err = job(st, T0)
    m = messages()
    check("live creator: the first pass asks once and deletes nothing", rc == 0 and len(m) == 1 and SRV["deleted"] == [], (rc, m, SRV["deleted"], out))
    check("... the message goes to the creating session, names the task and says when it is deleted anyway", m and m[0].startswith(s_live + " | ") and "trig_b1" in m[0] and "example-org/repo-b#21" in m[0] and re.search(r"[0-9]{2}:[0-9]{2} [A-Z+0-9-]+", m[0]) and "automatically after" in m[0], m)
    rc, out, err = job(st, T0 + 3600)
    check("... an hour later: no second message, nothing deleted", len(messages()) == 1 and SRV["deleted"] == [], (messages(), SRV["deleted"]))
    rc, out, err = job(st, T0 + 86400 - 60)
    check("... a minute short of 24 h: still nothing deleted", SRV["deleted"] == [] and len(messages()) == 1, SRV["deleted"])
    rc, out, err = job(st, T0 + 86400 + 60)
    check("... past 24 h from the ask: deleted by the job, still one message in all", SRV["deleted"] == ["trig_b1"] and len(messages()) == 1 and "did not delete it within 24 h of the ask" in logtext(st), (SRV["deleted"], logtext(st)))
    check("... the state forgets the task", "trig_b1" not in json.loads((st / "state.json").read_text())["done"], (st / "state.json").read_text())

    # 2b. the creator deletes it itself between passes: nothing left to do
    st = fresh([trig("b2", "Re-check PR example-org/repo-b#22", session=s_live)], sessions={s_live: ("active", "connected")}, prs={})
    job(st, T0)
    SRV["triggers"] = []
    rc, out, err = job(st, T0 + 7200)
    check("a task the creator deleted: no call to delete it, its record dropped", SRV["deleted"] == [] and rc == 0 and "trig_b2" not in json.loads((st / "state.json").read_text())["done"], (SRV["deleted"], out))

    # 2c. the message cannot be delivered: tried again next pass; deletion 24 h after the task was first seen done
    st = fresh([trig("b3", "Re-check PR example-org/repo-b#23", session=s_live)], sessions={s_live: ("active", "connected")}, prs={})
    (T / "msg.fail").write_text("")
    rc, out, err = job(st, T0)
    check("a failed message: logged, nothing deleted, exit 0", rc == 0 and SRV["deleted"] == [] and "error id=trig_b3 ask" in logtext(st) and messages() == [], (rc, logtext(st)))
    (T / "msg.fail").unlink()
    rc, out, err = job(st, T0 + 1800)
    check("... the next pass asks again and the ask is then recorded", len(messages()) == 1, messages())
    rc, out, err = job(st, T0 + 1800 + 86400 + 60)
    check("... deleted 24 h after the ask that worked", SRV["deleted"] == ["trig_b3"], SRV["deleted"])
    st = fresh([trig("b4", "Re-check PR example-org/repo-b#24", session=s_live)], sessions={s_live: ("active", "connected")}, prs={})
    (T / "msg.fail").write_text("")
    job(st, T0)
    job(st, T0 + 86400 + 60)
    check("... with the message never delivered, deleted 24 h after first seen done", SRV["deleted"] == ["trig_b4"] and messages() == [], (SRV["deleted"], messages()))

    # 3. not yet fired: a merged / closed pull request, a mix, an open one, an archived session
    st = fresh([trig("c1", "Check PR example-org/repo-c#31", enabled=True, ended=""),
                trig("c2", "Check PR example-org/repo-c#32", enabled=True, ended=""),
                trig("c3", "Check PRs example-org/repo-c#33 and example-org/repo-c#34", enabled=True, ended=""),
                trig("c4", "Check PR example-org/repo-c#35", enabled=True, ended=""),
                trig("c5", "Check PR example-org/repo-c#36", enabled=True, ended="", session=s_arch),
                trig("c6", "Check PRs example-org/repo-c#37 and example-org/repo-c#38", enabled=True, ended="")],
               sessions={s_arch: ("archived", "disconnected")},
               prs={"example-org/repo-c#31": {"state": "closed", "merged": True}, "example-org/repo-c#32": {"state": "closed", "merged": False},
                    "example-org/repo-c#33": {"state": "closed", "merged": True}, "example-org/repo-c#34": {"state": "closed", "merged": False},
                    "example-org/repo-c#35": {"state": "open"}, "example-org/repo-c#36": {"state": "open"},
                    "example-org/repo-c#37": {"state": "closed", "merged": True}, "example-org/repo-c#38": {"state": "open"}})
    rc, out, err = job(st, T0)
    lg = logtext(st)
    check("unfired tasks: merged, closed, merged-and-closed and archived-session ones deleted; an open PR and a half-open pair left",
          sorted(SRV["deleted"]) == ["trig_c1", "trig_c2", "trig_c3", "trig_c5"], SRV["deleted"])
    check("... the reasons say PR merged / PR closed / PR merged or closed / session archived",
          "id=trig_c1 session=- pr=example-org/repo-c#31 reason=PR merged;" in lg and "reason=PR closed;" in lg and "reason=PR merged or closed;" in lg and "reason=session archived;" in lg, lg)
    check("... the open one and the half-open pair are not logged at all", "trig_c4" not in lg and "trig_c6" not in lg, lg)

    # 4. an active task: PR open, session live
    st = fresh([trig("d1", "Check PR example-org/repo-d#41", enabled=True, ended="", session=s_live)], sessions={s_live: ("active", "connected")}, prs={"example-org/repo-d#41": {"state": "open"}})
    rc, out, err = job(st, T0)
    check("an active task (not fired, PR open, session live): untouched, nobody asked, no log line", rc == 0 and SRV["deleted"] == [] and messages() == [] and logtext(st) == "", (rc, logtext(st), SRV["deleted"]))

    # 5. tasks it cannot place, or must never look at
    st = fresh([trig("e1", "Check PR example-org/repo-e#51", enabled=False, ended=""),
                trig("e2", "Check PR example-org/repo-e#52", creator=OTHER),
                trig("e3", "Check PR example-org/repo-e#53", enabled=True, ended=""),
                trig("e4", "Every morning, summarize PR example-org/repo-e#54", cron="0 9 * * *", enabled=True, ended=""),
                trig("e5", "Remind me to water the plants", ended="run_once_fired"),
                trig("e6", "Check PR example-org/repo-e#56", enabled=True, ended="", session=sid("a3"))],
               sessions={}, prs={"example-org/repo-e#53": {"state": "open"}}, fail={"sessions": [sid("a3")]})
    rc, out, err = job(st, T0)
    lg = logtext(st)
    check("a task it cannot place or must not touch (switched off never fired, another account's, a PR it cannot read, a recurring routine, a task with no PR) is never deleted", SRV["deleted"] == [], SRV["deleted"])
    check("... the switched-off one and the other account's are logged as left alone, with the reason", "id=trig_e1" in lg and "never fired" in lg and "id=trig_e2" in lg and "created by another account" in lg, lg)
    check("... a session lookup that errors leaves its task and exits 1", "error id=trig_e6" in lg and rc == 1, (rc, lg))
    check("... the recurring routine and the task with no PR are not even logged", "trig_e4" not in lg and "trig_e5" not in lg, lg)
    n_before = logtext(st).count(" skip id=")
    rc, out, err = job(st, T0 + 1800)
    check("... a left-alone task is said once: the next pass adds no skip line", n_before == 2 and logtext(st).count(" skip id=") == 2, (n_before, logtext(st)))
    st = fresh([trig("e7", "Check PR example-org/repo-e#57", enabled=True, ended="")], prs={})
    rc, out, err = job(st, T0)
    check("a PR that GitHub cannot be asked about: the task stays, the error is logged, exit 1", SRV["deleted"] == [] and rc == 1 and "error id=trig_e7" in logtext(st), (rc, logtext(st)))

    # 6. API errors leave everything as it was
    st = fresh([trig("f1", "Check PR example-org/repo-f#61", session=s_arch)], sessions={s_arch: ("archived", "x")}, fail={"list": True})
    rc, out, err = job(st, T0)
    check("the list fails: nothing deleted, exit 1, said", rc == 1 and SRV["deleted"] == [] and "list triggers: HTTP 500" in logtext(st), (rc, logtext(st)))
    st = fresh([trig("f2", "Check PR example-org/repo-f#62", session=s_arch), trig("f3", "Check PR example-org/repo-f#63", session=s_arch)], sessions={s_arch: ("archived", "x")}, fail={"delete": ["trig_f2"]})
    rc, out, err = job(st, T0)
    check("a delete that fails keeps its task and the pass goes on to the next; exit 1", SRV["deleted"] == ["trig_f3"] and rc == 1 and "error id=trig_f2 delete: HTTP 500" in logtext(st), (rc, SRV["deleted"], logtext(st)))
    SRV["fail"] = {}
    rc, out, err = job(st, T0 + 1800)
    check("... the failed one is tried again at the next pass and goes when the server allows", SRV["deleted"] == ["trig_f3", "trig_f2"] and rc == 0, (rc, SRV["deleted"]))
    st = fresh([trig("f4", "Check PR example-org/repo-f#64", session=s_arch)], sessions={s_arch: ("archived", "x")}, fail={"delete404": ["trig_f4"]})
    rc, out, err = job(st, T0)
    check("a delete answered 404 (already gone) counts as done", rc == 0 and "(it was already gone)" in logtext(st), (rc, logtext(st)))

    # 7. the list is two pages
    st = fresh([trig("g1", "Check PR example-org/repo-g#71", session=s_arch), trig("g2", "Check PR example-org/repo-g#72", session=s_arch)], sessions={s_arch: ("archived", "x")}, pages=True)
    rc, out, err = job(st, T0)
    check("a list of two pages (next_cursor) is read whole", sorted(SRV["deleted"]) == ["trig_g1", "trig_g2"] and any("cursor=p2" in c[1] for c in SRV["calls"]), (SRV["deleted"], [c[1] for c in SRV["calls"]]))

    # 8. --dry-run
    st = fresh([trig("h1", "Check PR example-org/repo-h#81", session=s_arch), trig("h2", "Check PR example-org/repo-h#82", session=s_live)],
               sessions={s_arch: ("archived", "x"), s_live: ("active", "connected")})
    rc, out, err = job(st, T0, "--dry-run")
    check("--dry-run: nothing deleted, nobody asked, no log or state file written, the output says what it would do",
          rc == 0 and SRV["deleted"] == [] and messages() == [] and not (st / "pr-watcher-cleanup.log").exists() and not (st / "state.json").exists()
          and "would-delete id=trig_h1" in out and "would-ask id=trig_h2" in out and "(dry run)" in out, (rc, out, SRV["deleted"]))
    check("... and no DELETE call was made", not any(c[0] == "DELETE" for c in SRV["calls"]), SRV["calls"])

    # 8b. --only
    st = fresh([trig("j1", "Check PR example-org/repo-j#101", session=s_arch), trig("j2", "Check PR example-org/repo-j#102", session=s_arch)], sessions={s_arch: ("archived", "x")})
    rc, out, err = job(st, T0, "--only", "trig_j2")
    check("--only: just the named task is looked at and deleted", SRV["deleted"] == ["trig_j2"] and "trig_j1" not in logtext(st) and rc == 0, (SRV["deleted"], logtext(st)))
    rc, out, err = job(st, T0, "--only", "j1")
    check("--only with something that is not a task id: usage, exit 2, nothing deleted", rc == 2 and SRV["deleted"] == ["trig_j2"], (rc, SRV["deleted"]))

    # 9. the sign-in: an expired token touches nothing
    CREDS.write_text(json.dumps({"claudeAiOauth": {"accessToken": TOKEN, "expiresAt": 1000}}))
    try:
        st = fresh([trig("i1", "Check PR example-org/repo-i#91", session=s_arch)], sessions={s_arch: ("archived", "x")})
        rc, out, err = job(st, T0, clock=False)
        check("an expired token: nothing touched, no API call, exit 0, said", rc == 0 and SRV["deleted"] == [] and SRV["calls"] == [] and "expired" in out, (rc, out, SRV["calls"]))
    finally:
        CREDS.write_text(json.dumps({"claudeAiOauth": {"accessToken": TOKEN, "expiresAt": int((T0 + 86400 * 5) * 1000)}}))
    rc, out, err = job(T / "state-nocreds", T0, extra={"SALA_PRWATCH_CREDS": str(T / "nope.json")})
    check("no sign-in file: nothing touched, exit 1, said", rc == 1 and "no readable sign-in" in out, (rc, out))
    rc, out, err = job(T / "state-usage", T0, "--bogus")
    check("an unknown flag: usage, exit 2", rc == 2 and "usage" in err, (rc, err))

    # 10. nothing is left in the job's temp folder
    check("the job left nothing in TMPDIR", not list((T / "tmp").iterdir()), list((T / "tmp").iterdir()))


try:
    main()
finally:
    httpd.shutdown()
    os.close(_lock)                       # drops the lock; the folder goes with it
    shutil.rmtree(T, ignore_errors=True)

print("%d/%d checks passed" % (len(ran) - len(fails), len(ran)))
sys.exit(1 if fails else 0)
