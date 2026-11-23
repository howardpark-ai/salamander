#!/usr/bin/env python3
"""lib/jobalert.py — a failed scheduled job reaches stackshot through systemd's OnFailure=, and its next success closes it (docs/units.md).

Standard library only, no model call; run as `python3 -I -S jobalert.py <verb> …` by lib/job.sh.

  alert failed UNIT   what systemd/sala-job-failed@.service runs when UNIT fails: drops the marker `failed/UNIT` in the state folder and posts ONE call,
                      `client.py job-failed UNIT HOST TIME PROJECT` (TIME = when the failing run ended, ISO-8601 UTC with a Z; PROJECT = the unit's X-Project=
                      value, or a single `-` when it has none)
  alert ok UNIT       what a job's ExecStopPost= runs after every run: nothing, unless the run succeeded (SERVICE_RESULT) and the marker exists; then it posts
                      `client.py job-ok UNIT HOST TIME` (TIME = now) and removes the marker (a failed post keeps the marker: the next success tries again)
  set-alert NAME [--checkout DIR] [--quiet]   write the two lines (OnFailure=, ExecStopPost=) into an existing job's service file in git; prints what to commit
  (`sala job add` writes the same two lines into every new service: with_alert_lines)

Both alert verbs fail soft: a missing or refusing client, a state folder that cannot be written, any error at all is one log line on stderr (the journal) and
exit 0, so a failed post never fails the job or the template unit. No polling anywhere: the template starts only when a unit fails, and ExecStopPost= after a run.

The stackshot client's verbs are named once, in CLIENT_VERBS: if stackshot renames them (or files them under `post`), change that line.

Environment (the tests point these at a temporary tree): SALA_STATE_DIR, SALA_JOB_USER_DIR, SALA_JOB_SYSTEM_DIR, SALA_JOB_SYSTEMCTL, SALA_STACKSHOT_CLIENT /
SALA_STACKSHOT_DIR (as for `sala job check`), SALA_UNIT_PROJECT_MAP (the project is written as the Schedules tab shows it).
"""
import os, re, socket, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)   # run with -I -S: the script's folder is not on the path by itself

# the stackshot client's calls: the argv words after client.py for each kind. The one place to change when stackshot names them otherwise.
CLIENT_VERBS = {"failed": ("job-failed",), "ok": ("job-ok",)}
CLIENT_TIMEOUT = 30
TEMPLATE = "sala-job-failed@.service"
ONFAILURE_LINE = "OnFailure=sala-job-failed@%n.service"
STOPPOST_LINE = "ExecStopPost=-%h/salamander/bin/salamander job alert ok %n"
UNIT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9:_.@\\-]{0,200}$")   # a unit name: also the marker's file name, so no slash and no leading dot
USAGE = {"alert": "usage: sala job alert failed UNIT | sala job alert ok UNIT   (run by systemd: OnFailure= and ExecStopPost=; docs/units.md)",
         "set-alert": "usage: sala job set-alert NAME [--checkout DIR] [--quiet]"}


def uj():
    """unitjob, imported when needed: unitjob imports this file for with_alert_lines, so neither can import the other at the top."""
    import unitjob
    return unitjob


def log(msg):
    print("sala job alert: " + msg, file=sys.stderr)


def iso_z(epoch=None):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() if epoch is None else epoch))


# ---- the two lines in a service file ---------------------------------------------------------------------------------------------------

def with_alert(text):
    """The service text with `OnFailure=sala-job-failed@%n.service` at the end of [Unit] and `ExecStopPost=-… job alert ok %n` at the end of [Service]; a line
    that is there already (an OnFailure= naming the template, an ExecStopPost= running `job alert ok`) is not added again. Everything else is kept byte for
    byte. None when the text has no [Unit] or no [Service] section."""
    lines = text.split("\n")

    def span(name):
        s = next((i for i, l in enumerate(lines) if l.strip() == "[%s]" % name), None)
        if s is None:
            return None
        return s, next((i for i in range(s + 1, len(lines)) if lines[i].strip().startswith("[")), len(lines))

    if span("Unit") is None or span("Service") is None:
        return None
    for name, key, mark, new in (("Service", "ExecStopPost=", "job alert ok", STOPPOST_LINE), ("Unit", "OnFailure=", "sala-job-failed@", ONFAILURE_LINE)):   # the later section first: an insert there moves no index of the earlier one
        s, e = span(name)
        if any(l.strip().startswith(key) and mark in l for l in lines[s + 1:e]):
            continue
        at = e
        while at > s + 1 and not lines[at - 1].strip():
            at -= 1
        lines.insert(at, new)
    return "\n".join(lines)


def with_alert_lines(service):
    """with_alert for the list of lines `sala job add` builds (the same lines back; the list unchanged when it has no [Service])."""
    out = with_alert("\n".join(service))
    return service if out is None else out.split("\n")


def template_note(unit_dir):
    """A line for the owner when the template unit is not installed in the unit folder the job's links go into, else ''."""
    if os.path.lexists(os.path.join(unit_dir, TEMPLATE)):
        return ""
    home = os.path.expanduser("~")
    shown = "~" + unit_dir[len(home):] if unit_dir.startswith(home + "/") else unit_dir
    return ("note: %s is not installed in %s: the job's OnFailure= has nothing to start until it is (docs/units.md, 'A failed run reaches stackshot')"
            % (TEMPLATE, shown))


# ---- the alert verbs --------------------------------------------------------------------------------------------------------------------

def marker_path(unit):
    return os.path.join(uj().state_dir(), "failed", unit)


def failed_at(unit):
    """When the unit's last run ended, as an ISO-8601 UTC string: systemd's ExecMainExitTimestamp (else StateChangeTimestamp) of the unit, asked in the user
    manager and then in the system one; now when systemd does not say."""
    u = uj()
    for scope in (("--user",), ()):
        p = u.run(u.systemctl_argv(*scope, "show", "--timestamp=unix", "-p", "ExecMainExitTimestamp", "-p", "StateChangeTimestamp", unit), 10)
        got = dict(l.split("=", 1) for l in p.stdout.splitlines() if "=" in l) if p.returncode == 0 else {}
        for key in ("ExecMainExitTimestamp", "StateChangeTimestamp"):
            m = re.match(r"^@(\d+)$", got.get(key, "").strip())
            if m and int(m.group(1)) > 0:
                return iso_z(int(m.group(1)))
    return iso_z()


def project_of(unit):
    """The unit's X-Project= (as the Schedules tab shows it: SALA_UNIT_PROJECT_MAP applied) when it is scope/project, else `-`."""
    u = uj()
    for d in (u.user_dir(), u.system_dir()):
        p = os.path.join(d, unit)
        if os.path.exists(p):
            v = u.mapped_project((u.last_value(u.unit_sections(u.read_text(p)), "Unit", "X-Project") or "").strip())
            return v if u.PROJECT_RE.match(v) and len(v) <= 80 else "-"
    return "-"


def client_call(kind, unit, host, when, project="-"):
    """The one call to stackshot's client: `client.py <CLIENT_VERBS[kind]> UNIT HOST TIME [PROJECT]` (PROJECT for `failed` only). → (exit code, one line of what it said)."""
    u = uj()
    c = u.client_path()
    if not c or not os.path.isfile(c):
        return 127, "no stackshot client.py on this box (SALA_STACKSHOT_CLIENT, SALA_STACKSHOT_DIR)"
    p = u.run(u.client_argv() + list(CLIENT_VERBS[kind]) + [unit, host, when] + ([project] if kind == "failed" else []), CLIENT_TIMEOUT)
    return p.returncode, u.one_line(p.stderr or p.stdout)[:200]


def alert_failed(unit):
    u = uj()
    host, when, project = socket.gethostname(), failed_at(unit), project_of(unit)
    c = u.client_path()
    if not c or not os.path.isfile(c):
        log("%s failed at %s: no stackshot client.py on this box, nothing posted" % (unit, when))
        return
    m = marker_path(unit)
    try:
        os.makedirs(os.path.dirname(m), exist_ok=True)
        with open(m, "w", encoding="utf-8") as f:   # what a person looking needs to know: when it failed, and under which project
            f.write("%s\t%s\n" % (when, project))
    except OSError as e:   # no marker means the next success cannot close the item; the failure is still posted
        log("%s: the marker %s could not be written (%s)" % (unit, u.tilde(m), e.strerror or type(e).__name__))
    rc, said = client_call("failed", unit, host, when, project)
    if rc != 0:
        log("%s failed at %s: the post to stackshot did not go (client exit %s%s)" % (unit, when, rc, ": " + said if said else ""))


def alert_ok(unit):
    if os.environ.get("SERVICE_RESULT", "success") != "success":   # ExecStopPost= also runs after a failed run: that one is the template's
        return
    m = marker_path(unit)
    if not os.path.isfile(m):
        return
    rc, said = client_call("ok", unit, socket.gethostname(), iso_z())
    if rc != 0:
        log("%s succeeded after a failure: the post to stackshot did not go (client exit %s%s); the marker stays, the next success tries again" % (unit, rc, ": " + said if said else ""))
        return
    try:
        os.unlink(m)
    except OSError:
        pass


def cmd_alert(args):
    if len(args) != 2 or args[0] not in ("failed", "ok") or not UNIT_RE.match(args[1]) or ".." in args[1]:
        print(USAGE["alert"], file=sys.stderr)
        return 2
    try:
        (alert_failed if args[0] == "failed" else alert_ok)(args[1])
    except Exception as e:   # fail soft: whatever went wrong, the job and the template unit do not fail for it
        log("%s %s: %s: %s" % (args[0], args[1], type(e).__name__, e))
    return 0


# ---- set-alert ----------------------------------------------------------------------------------------------------------------------------

def cmd_set_alert(args):
    """The same walk as `sala job set-project`: the job's service file in its repo (a worktree for a flow-pr repo), edited in place, the commit steps printed."""
    u = uj()
    quiet = "--quiet" in args
    pos, o = u.parse_flags([a for a in args if a != "--quiet"], {"--checkout": ("checkout", 0)}, "set-alert")
    if len(pos) != 1:
        u.die("give the job's name\n" + USAGE["set-alert"], "set-alert")
    name = pos[0][:-8] if pos[0].endswith(".service") else pos[0]
    repos = u.load_repos()
    svc, scope = os.path.join(u.user_dir(), name + ".service"), "user"
    if not os.path.lexists(svc):   # a system-scope job whose unit file links to its git file is edited the same way (no root: the git file is the user's)
        svc, scope = os.path.join(u.system_dir(), name + ".service"), "system"
    if not os.path.lexists(svc):
        u.die("no job %r: no %s.service in %s or %s" % (name, name, u.tilde(u.user_dir()), u.tilde(u.system_dir())), "set-alert", 1)
    real = os.path.realpath(svc)
    if u.is_packaged(real):
        u.die("%s is a package's unit, not ours" % name, "set-alert", 1)
    if not os.path.islink(svc) or not u.git_root(real):
        why = u.in_git(svc, repos, None)[1] or "its unit file is not a link into a git repo"
        u.die("%s: %s; put it in git first (`sala job check` says how), or, for a unit rendered from a template, edit the template" % (name, why), "set-alert", 1)
    repo = u.repo_of(real, repos)
    if not repo:
        u.die("%s: its git file %s is in none of the repos in the repo table (%s)" % (name, u.tilde(real), u.tilde(u.repos_path())), "set-alert", 1)
    rec = repos[repo]
    if rec["flow"] == "pr":
        if not o.get("checkout"):
            u.die("%s goes by branch and pull request: pass the worktree as --checkout (the copy there is edited, not the production one)" % repo, "set-alert")
        ck = u.checkout_for(rec, repo, o, "set-alert")
        if os.path.realpath(ck) == rec["checkout"]:
            u.die("--checkout is the production checkout of %s; use a worktree" % repo, "set-alert")
        target = os.path.join(ck, os.path.relpath(real, u.git_root(real)))
    else:
        ck = os.path.realpath(os.path.expanduser(o["checkout"])) if o.get("checkout") else rec["checkout"]
        target = real
    if not os.path.isfile(target):
        u.die("%s is not in %s (the worktree is not on a branch that has the job)" % (u.tilde(target), u.tilde(ck)), "set-alert", 1)
    text = u.read_text(target)
    out = with_alert(text)
    if out is None:
        u.die("%s has no [Unit] and [Service] section" % u.tilde(target), "set-alert", 1)
    if out == text:
        u.say("%s already has the alert lines (%s, %s): nothing to do" % (name, ONFAILURE_LINE.split("=")[0] + "=", STOPPOST_LINE.split("=")[0] + "="))
        return 0
    tmp = target + ".tmp.%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(out)
    os.replace(tmp, target)
    u.say("set OnFailure= and ExecStopPost= in %s" % u.tilde(target))
    if scope == "user":   # systemd reads the new lines at the reload
        u.ctl("daemon-reload")
    note = template_note(u.user_dir() if scope == "user" else u.system_dir())
    if note:
        u.say(note)
    if not quiet:
        u.git_steps(ck, rec, repo, [target], "%s: failure alert, OnFailure= and ExecStopPost= (sala job set-alert)" % name, name)
    return 0


def main(argv):
    verb = argv[0] if argv else ""
    if verb == "alert":
        return cmd_alert(argv[1:])
    if verb == "set-alert":
        return cmd_set_alert(argv[1:]) or 0
    print("usage: sala job alert failed|ok UNIT | sala job set-alert NAME …  (sala job --help)", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
