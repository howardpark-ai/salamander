#!/usr/bin/env bash
# tests/jobalert.sh — a failed scheduled run reaches stackshot through systemd's OnFailure=, and the next success closes it (lib/jobalert.py, lib/job.sh,
# lib/unitjob.py `add`, systemd/sala-job-failed@.service; docs/units.md, "A failed run reaches stackshot"). Everything runs in one temporary tree: a temporary git
# repo stands for a flow-main repo, the unit folders are temporary (SALA_JOB_USER_DIR, SALA_JOB_SYSTEM_DIR), systemctl is a stub (SALA_JOB_SYSTEMCTL) that logs
# its arguments and answers `show` with fixed timestamps, and stackshot's client.py is a stub that logs its argv and refuses on demand. Nothing touches the real
# unit folders, systemd or the board.
# systemd is played by `run_unit`: it runs the job's script, then the ExecStopPost= lines of the job's own service file (SERVICE_RESULT as systemd sets it), and after
# a failure the ExecStart= of the shipped template named by the file's OnFailure= line, each command read from the files, so the shipped lines are what runs.
#   add        a new service carries OnFailure= and ExecStopPost= (once each, in [Unit] and [Service]); a note when the template is not installed beside it, none when it is
#   failure    a deliberately failing job posts exactly one `job-failed <unit> <host> <ISO-Z time> <project>` and drops the marker failed/<unit>; the failing run's own
#              ExecStopPost= posts nothing; a second failure posts a second line; a unit with no X-Project= posts a single - ; SALA_UNIT_PROJECT_MAP applies
#   success    the next success posts `job-ok <unit> <host> <ISO-Z time>` once and removes the marker; a success with no marker posts nothing and starts no python
#   fail soft  a client that refuses or is missing, a state folder that cannot be written: the template unit and the helper exit 0, the job's own result is untouched; a refused
#              job-failed still drops the marker; a refused job-ok keeps it and the next success tries again; no client: no marker
#   set-alert  the two lines are written into an existing job's git file (and nothing else), idempotent, a pr repo through a worktree, refusals
#   with_alert the text function: trailing blank lines, no trailing newline, another OnFailure=, missing sections
# Usage: bash tests/jobalert.sh   (exit 0 = pass; a few seconds). The temporary tree is locked while the suite runs and removed at its end.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
. "$ROOT/tests/lib.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/sala-jobalert.XXXXXX")
exec 8< "$T"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
trap 'exec 8<&-; rm -rf "$T"' EXIT
export HOME=$T/home SALA_CONFIG=/dev/null XDG_STATE_HOME=$T/state
export SALA_JOB_USER_DIR=$T/u SALA_JOB_SYSTEM_DIR=$T/s SALA_JOB_SYSTEMCTL=$T/bin/systemctl SALA_JOB_REPOS=$T/repos.tsv
export SALA_STATE_DIR=$T/state/salamander SALA_STACKSHOT_CLIENT=$T/bin/client SALA_LOG_DIR=$T/log
unset SALA_STACKSHOT_DIR SALA_UNIT_PROJECT_MAP
mkdir -p "$HOME" "$T/bin" "$T/u" "$T/s" "$SALA_LOG_DIR"
S="bash $ROOT/bin/salamander"
G="git -c user.name=t -c user.email=t@t -c commit.gpgsign=false"
export JA_T=$T
FAILED_TS=1795399118; FAILED_Z=$(date -u -d "@$FAILED_TS" +%Y-%m-%dT%H:%M:%SZ)
HOST=$(hostname)
ISO_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

# stand-ins: systemctl logs its arguments and answers `show` with two timestamps (none when $T/show.none exists); the client logs its argv and takes exactly the shapes
# `job-failed UNIT HOST TIME PROJECT` and `job-ok UNIT HOST TIME`
cat > "$T/bin/systemctl" <<'SH'
#!/bin/sh
echo "$*" >> "$JA_T/ctl.log"
case " $* " in *" show "*) [ -e "$JA_T/show.none" ] || printf 'ExecMainExitTimestamp=@1795399118\nStateChangeTimestamp=@1795399120\n' ;; esac
exit 0
SH
cat > "$T/bin/client" <<'PY'
#!/usr/bin/env python3
# A fake stackshot client.py: `job-failed <unit> <host> <time> <project>` and `job-ok <unit> <host> <time>`, parsed strictly (the exact number of words, nothing else);
# appends its argv, TAB-joined, to $JA_T/client.log; refuses (exit 1) while $JA_T/client.fail exists, after logging the call.
import os, sys
T = os.environ["JA_T"]; a = sys.argv[1:]
open(os.path.join(T, "client.log"), "a").write("\t".join(a) + "\n")
USAGE = "usage: client.py job-failed <unit> <host> <time> <project> | client.py job-ok <unit> <host> <time>"
if not a or a[0] not in ("job-failed", "job-ok") or len(a) != (5 if a[0] == "job-failed" else 4) or any(not x.strip() for x in a):
    print(USAGE, file=sys.stderr); sys.exit(1)
if os.path.exists(os.path.join(T, "client.fail")):
    print("stackshot: refused (test)", file=sys.stderr); sys.exit(1)
print("ok")
PY
chmod +x "$T/bin/systemctl" "$T/bin/client"
LOG=$T/client.log; : > "$LOG"
calls() { wc -l < "$LOG" | tr -d ' '; }
marker() { echo "$SALA_STATE_DIR/failed/$1"; }

# a flow-main repo and a flow-pr repo (with a worktree), a job script that exits with the code it is told by $T/code
for r in hub sal; do mkdir -p "$T/$r"; $G -C "$T/$r" init -q -b main; echo "# $r" > "$T/$r/README.md"; $G -C "$T/$r" add README.md; $G -C "$T/$r" commit -q -m init; done
mkdir -p "$T/hub/scripts" "$T/sal/bin" "$T/sal/systemd"
printf '#!/bin/sh\nexit "$(cat "%s/code")"\n' "$T" > "$T/hub/scripts/job.sh"; chmod +x "$T/hub/scripts/job.sh"
printf '#!/bin/sh\nexit 0\n' > "$T/sal/bin/tool.sh"; chmod +x "$T/sal/bin/tool.sh"
$G -C "$T/sal" worktree add -q "$T/sal-wt" -b topic
{ printf '# test table\n'
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' hub "$T/hub" 'units/{name}/systemd' units/systemd-system main projects/example cfg-agent '' example-org/team-config
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' sal "$T/sal" systemd - pr projects/tool-a tool-agent '' example-org/salamander; } > "$T/repos.tsv"

# systemd, played: run_unit <unit> <exit code of the script>. The job's own ExecStopPost= lines run after the script (SERVICE_RESULT=success, else exit-code); after a
# failure the unit's OnFailure= template instance runs, its ExecStart= taken from the shipped template with %i = the unit. %n and %i are the unit, %h/salamander is
# this checkout. A leading - on a command is systemd's "ignore the exit status". Sets UNIT_RC (the template's exit status) and POST_RC (the last ExecStopPost=).
run_unit() {
    local unit=$1 code=$2 file=$T/u/$1 result=success line cmd tpl
    [ -e "$file" ] || file=$T/s/$1
    echo "$code" > "$T/code"; UNIT_RC=-; POST_RC=-
    [ "$code" = 0 ] || result=exit-code
    sh -c "exit $code" || true
    while IFS= read -r line; do
        cmd=${line#ExecStopPost=}; cmd=${cmd#-}; cmd=${cmd//%n/$unit}; cmd=${cmd//%h\/salamander/$ROOT}
        env SERVICE_RESULT=$result $cmd; POST_RC=$?
    done < <(grep '^ExecStopPost=' "$file")
    if [ "$code" != 0 ]; then
        tpl=$(sed -n 's/^OnFailure=\(sala-job-failed@\)%n\.service$/\1/p' "$file")
        [ -n "$tpl" ] || { UNIT_RC=no-OnFailure; return; }
        line=$(grep '^ExecStart=' "$ROOT/systemd/sala-job-failed@.service")
        cmd=${line#ExecStart=}; cmd=${cmd#-}; cmd=${cmd//%i/$unit}; cmd=${cmd//%h\/salamander/$ROOT}
        $cmd; UNIT_RC=$?
    fi
}
ADD=(--repo hub --script "$T/hub/scripts/job.sh" --schedule '*-*-* 03:30:00 UTC' --description 'flaky thing' --lane none --project projects/example)

# ---- the template unit ---------------------------------------------------------------------------------------------------------------------------
TPL=$ROOT/systemd/sala-job-failed@.service
[ "$(grep -c '^ExecStart=-%h/salamander/bin/salamander job alert failed %i$' "$TPL")" = 1 ] && grep -qx 'Type=oneshot' "$TPL" && grep -qx 'X-Model-Lane=none' "$TPL" \
    && ok "the template: oneshot, ignores its own exit status, runs 'job alert failed %i', no model lane" || bad "the template changed shape: $(cat "$TPL")"
! grep -q '^OnFailure=' "$TPL" && ok "the template has no OnFailure= of its own (no loop)" || bad "the template names an OnFailure="

# ---- add: the lines, and the note about the template ----------------------------------------------------------------------------------------------
out=$($S job add flaky "${ADD[@]}" 2>&1); rc=$?
SVC=$T/hub/units/flaky/systemd/flaky.service
[ "$rc" = 0 ] && [ "$(grep -c '^OnFailure=sala-job-failed@%n.service$' "$SVC")" = 1 ] && [ "$(sed -n '1,/^\[Service\]/p' "$SVC" | grep -c '^OnFailure=')" = 1 ] \
    && ok "add: OnFailure=sala-job-failed@%n.service once, in [Unit]" || bad "add (exit $rc): $out / $(cat "$SVC")"
[ "$(grep -c '^ExecStopPost=-%h/salamander/bin/salamander job alert ok %n$' "$SVC")" = 1 ] && [ "$(sed -n '/^\[Service\]/,$p' "$SVC" | grep -c '^ExecStopPost=')" = 1 ] \
    && ok "add: ExecStopPost=-…/salamander job alert ok %n once, in [Service]" || bad "add: no ExecStopPost=: $(cat "$SVC")"
grep -q '^ExecStart=' "$SVC" && grep -qx 'Type=oneshot' "$SVC" && grep -q '^X-Project=projects/example$' "$SVC" && ok "add: the rest of the service is as before (ExecStart, Type, X-Project)" || bad "add changed the rest: $(cat "$SVC")"
case "$out" in *"sala-job-failed@.service is not installed in"*) ok "add says the template is not installed beside the job's links" ;; *) bad "no template note: $out" ;; esac
ln -s "$TPL" "$T/u/sala-job-failed@.service"
out=$($S job add steady "${ADD[@]}" 2>&1)
case "$out" in *"is not installed"*) bad "a note although the template is installed: $out" ;; *) ok "no note once the template is beside the links" ;; esac
$S job remove steady > /dev/null 2>&1
out=$($S job add sysjob "${ADD[@]}" --scope system 2>&1)
grep -q '^OnFailure=sala-job-failed@%n.service$' "$T/hub/units/systemd-system/sysjob.service" && grep -q '^ExecStopPost=-' "$T/hub/units/systemd-system/sysjob.service" && ok "add --scope system writes the lines too" || bad "system scope: $out"
rm -f "$T/hub/units/systemd-system/sysjob."*
grep -q 'job alert ok' "$ROOT/lib/job.sh" && out=$($S job --help 2>&1) && case "$out" in *"sala job set-alert NAME"*"sala job alert failed|ok UNIT"*"alert failed UNIT"*) ok "sala job --help names set-alert and alert" ;; *) bad "help: $out" ;; esac

# ---- a failing run -------------------------------------------------------------------------------------------------------------------------------
: > "$T/ctl.log"
run_unit flaky.service 1
want=$(printf 'job-failed\tflaky.service\t%s\t%s\tprojects/example' "$HOST" "$FAILED_Z")
[ "$(calls)" = 1 ] && [ "$(cat "$LOG")" = "$want" ] && ok "a failing job posts exactly one job-failed line: unit, host, the failing run's time, project" || bad "client log: $(cat "$LOG") (want $want)"
[ "$UNIT_RC" = 0 ] && [ "$POST_RC" = 0 ] && ok "the template unit and the failing run's ExecStopPost= both exit 0" || bad "template rc $UNIT_RC, ExecStopPost rc $POST_RC"
[ -f "$(marker flaky.service)" ] && [ "$(cat "$(marker flaky.service)")" = "$(printf '%s\tprojects/example' "$FAILED_Z")" ] && ok "the marker failed/flaky.service is dropped (the time and the project)" || bad "marker: $(cat "$(marker flaky.service)" 2>&1)"
grep -q -- '--user show --timestamp=unix .*flaky.service' "$T/ctl.log" && ok "the time is asked of systemd (show --timestamp=unix), not taken from the clock" || bad "ctl log: $(cat "$T/ctl.log")"
run_unit flaky.service 1
[ "$(calls)" = 2 ] && [ "$(sed -n 2p "$LOG" | cut -f1)" = job-failed ] && ok "a second failing run posts a second job-failed (one per failing run) and still no job-ok" || bad "second failure: $(cat "$LOG")"

# ---- the next success ----------------------------------------------------------------------------------------------------------------------------
before=$(date +%s)
run_unit flaky.service 0
after=$(date +%s)
[ "$(calls)" = 3 ] && ok "the next success posts exactly one more line" || bad "calls after the success: $(calls): $(cat "$LOG")"
IFS=$'\t' read -r verb unit host ts extra < <(sed -n 3p "$LOG")
[ "$verb" = job-ok ] && [ "$unit" = flaky.service ] && [ "$host" = "$HOST" ] && [[ $ts =~ $ISO_RE ]] && [ -z "${extra:-}" ] && ok "the line is job-ok <unit> <host> <ISO-Z time>" || bad "job-ok line: $(sed -n 3p "$LOG")"
t=$(date -u -d "$ts" +%s 2>/dev/null || echo 0)
[ "$t" -ge "$before" ] && [ "$t" -le "$after" ] && ok "job-ok carries the time of the success (now)" || bad "job-ok time $ts outside [$before,$after]"
[ ! -e "$(marker flaky.service)" ] && ok "the marker is removed" || bad "the marker stayed"
[ "$POST_RC" = 0 ] && ok "the ExecStopPost= of the success exits 0" || bad "ExecStopPost rc $POST_RC"
run_unit flaky.service 0; run_unit flaky.service 0
[ "$(calls)" = 3 ] && ok "a success with no marker posts nothing (twice)" || bad "calls after two green runs: $(calls)"

# a green run with no marker ends in bin/salamander's shell, in no python: a python3 on PATH that records itself must never run for `job alert ok`
mkdir -p "$T/shim"; printf '#!/bin/sh\necho "$*" >> "%s/py.log"\nexec %s "$@"\n' "$T" "$(command -v python3)" > "$T/shim/python3"; chmod +x "$T/shim/python3"
: > "$T/py.log"; PATH=$T/shim:$PATH $S job alert ok flaky.service; rc=$?
[ "$rc" = 0 ] && [ ! -s "$T/py.log" ] && ok "a green run with no marker starts no python" || bad "python ran for a green run with no marker (exit $rc): $(cat "$T/py.log")"

# ---- no X-Project, and the project map ------------------------------------------------------------------------------------------------------------
printf '[Unit]\nDescription=bare\nOnFailure=sala-job-failed@%%n.service\n[Service]\nType=oneshot\nExecStart=%s/hub/scripts/job.sh\nExecStopPost=-%%h/salamander/bin/salamander job alert ok %%n\n' "$T" > "$T/u/bare.service"
: > "$LOG"; run_unit bare.service 1
[ "$(cat "$LOG")" = "$(printf 'job-failed\tbare.service\t%s\t%s\t-' "$HOST" "$FAILED_Z")" ] && ok "a unit with no X-Project= posts a single - as the project" || bad "no project: $(cat "$LOG")"
run_unit bare.service 0
[ "$(calls)" = 2 ] && [ ! -e "$(marker bare.service)" ] && ok "and its next success closes it" || bad "bare success: $(cat "$LOG")"
printf '[Unit]\nDescription=weird\nX-Project=Not A Project\nOnFailure=sala-job-failed@%%n.service\n[Service]\nExecStart=/bin/true\nExecStopPost=-%%h/salamander/bin/salamander job alert ok %%n\n' > "$T/u/weird.service"
: > "$LOG"; run_unit weird.service 1
[ "$(cut -f5 "$LOG")" = "-" ] && ok "an X-Project= that is not scope/project posts a single - too" || bad "weird project: $(cat "$LOG")"
run_unit weird.service 0
: > "$LOG"; SALA_UNIT_PROJECT_MAP="projects/example=lab/other" run_unit flaky.service 1
[ "$(cut -f5 "$LOG")" = "lab/other" ] && ok "SALA_UNIT_PROJECT_MAP applies: the project is the one the Schedules tab shows" || bad "mapped project: $(cat "$LOG")"
run_unit flaky.service 0
# a unit in the system folder is read the same way
printf '[Unit]\nDescription=sys\nX-Project=projects/sys\nOnFailure=sala-job-failed@%%n.service\n[Service]\nExecStart=/bin/true\nExecStopPost=-%%h/salamander/bin/salamander job alert ok %%n\n' > "$T/s/sysunit.service"
: > "$LOG"; run_unit sysunit.service 1
[ "$(cut -f2,5 "$LOG")" = "$(printf 'sysunit.service\tprojects/sys')" ] && ok "a unit that is only in the system unit folder is read for its project too" || bad "system unit: $(cat "$LOG")"
run_unit sysunit.service 0

# ---- fail soft ------------------------------------------------------------------------------------------------------------------------------------
: > "$LOG"; touch "$T/client.fail"
run_unit flaky.service 1 2> "$T/err"; out=$(cat "$T/err")
[ "$UNIT_RC" = 0 ] && ok "a client that refuses: the template unit exits 0" || bad "template rc $UNIT_RC with a refusing client"
case "$out" in *"the post to stackshot did not go (client exit 1: stackshot: refused (test))"*) ok "and says so, one line, with the client's words" ;; *) bad "no log line: $out" ;; esac
[ -f "$(marker flaky.service)" ] && ok "a refused job-failed still drops the marker" || bad "no marker after a refused job-failed"
: > "$LOG"; run_unit flaky.service 0 2> "$T/err"; out=$(cat "$T/err")
[ "$POST_RC" = 0 ] && [ -f "$(marker flaky.service)" ] && [ "$(calls)" = 1 ] && case "$out" in *"the marker stays, the next success tries again"*) true;; *) false;; esac \
    && ok "a refused job-ok: exit 0, the marker stays, one attempt, and it says so" || bad "refused job-ok: rc $POST_RC, marker $([ -f "$(marker flaky.service)" ] && echo kept || echo gone), calls $(calls): $out"
rm -f "$T/client.fail"; : > "$LOG"
run_unit flaky.service 0
[ "$(calls)" = 1 ] && [ "$(cut -f1 "$LOG")" = job-ok ] && [ ! -e "$(marker flaky.service)" ] && ok "the next success tries again, posts job-ok, removes the marker" || bad "retry: $(cat "$LOG")"
# the job itself: its own result is the script's, whatever the helper does (the helper's exit is 0 after a failure and after a success alike)
touch "$T/client.fail"
$S job alert failed flaky.service > /dev/null 2>&1; r1=$?; SERVICE_RESULT=success $S job alert ok flaky.service > /dev/null 2>&1; r2=$?
[ "$r1" = 0 ] && [ "$r2" = 0 ] && ok "job alert failed / ok exit 0 with a refusing client" || bad "exits $r1 $r2"
rm -f "$T/client.fail" "$(marker flaky.service)"
# no client at all: one log line, exit 0, no marker (nothing could close it)
: > "$LOG"
out=$(SALA_STACKSHOT_CLIENT=$T/bin/none $S job alert failed flaky.service 2>&1); rc=$?
[ "$rc" = 0 ] && [ ! -e "$(marker flaky.service)" ] && [ "$(calls)" = 0 ] && case "$out" in *"no stackshot client.py on this box, nothing posted"*) true;; *) false;; esac && ok "no client on the box: exit 0, one log line, no marker, no call" || bad "no client (exit $rc): $out"
# a state folder that cannot be written
rm -rf "$T/state/salamander"; touch "$T/state/salamander"   # a file where the state folder should be
: > "$LOG"; out=$($S job alert failed flaky.service 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(calls)" = 1 ] && case "$out" in *"could not be written"*) true;; *) false;; esac && ok "an unwritable state folder: still posts the failure, says the marker could not be written, exit 0" || bad "state folder a file (exit $rc, calls $(calls)): $out"
rm -f "$T/state/salamander"

# ---- the helper's own refusals --------------------------------------------------------------------------------------------------------------------
: > "$LOG"
out=$($S job alert failed ../evil 2>&1); r1=$?; out2=$($S job alert nope x 2>&1); r2=$?; out3=$($S job alert failed 2>&1); r3=$?
[ "$r1" = 2 ] && [ "$r2" = 2 ] && [ "$r3" = 2 ] && [ ! -e "$T/state/evil" ] && [ "$(calls)" = 0 ] && case "$out" in *"usage: sala job alert failed UNIT"*) true;; *) false;; esac && ok "a unit name with a slash, an unknown verb, a missing unit: usage, exit 2, nothing written or posted" || bad "refusals: $r1 $r2 $r3: $out"
mkdir -p "$SALA_STATE_DIR/failed"; printf 'x\ty\n' > "$(marker manual.service)"
out=$($S job alert ok manual.service 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(cut -f1 "$LOG")" = job-ok ] && [ ! -e "$(marker manual.service)" ] && ok "alert ok by hand (no SERVICE_RESULT) closes a marker" || bad "alert ok by hand (exit $rc): $out"
printf 'x\ty\n' > "$(marker manual.service)"; : > "$LOG"
for r in exit-code signal timeout core-dump watchdog start-limit-hit; do SERVICE_RESULT=$r $S job alert ok manual.service; done
[ "$(calls)" = 0 ] && [ -f "$(marker manual.service)" ] && ok "ExecStopPost= after any result but success posts nothing and keeps the marker" || bad "non-success results posted: $(cat "$LOG")"
rm -f "$(marker manual.service)"

# ---- set-alert ------------------------------------------------------------------------------------------------------------------------------------
printf '[Unit]\nDescription=old job\nX-Model-Lane=none\nX-Project=projects/example\n\n[Service]\nType=oneshot\nExecStart=%s/hub/scripts/job.sh\n' "$T" > "$T/hub/units/oldjob.service.src"
mkdir -p "$T/hub/units/oldjob/systemd"; mv "$T/hub/units/oldjob.service.src" "$T/hub/units/oldjob/systemd/oldjob.service"
printf '[Unit]\nDescription=old job (timer)\n[Timer]\nOnCalendar=daily\n[Install]\nWantedBy=timers.target\n' > "$T/hub/units/oldjob/systemd/oldjob.timer"
ln -s "$T/hub/units/oldjob/systemd/oldjob.service" "$T/u/oldjob.service"; ln -s "$T/hub/units/oldjob/systemd/oldjob.timer" "$T/u/oldjob.timer"
OLD=$T/hub/units/oldjob/systemd/oldjob.service; cp "$OLD" "$T/oldjob.orig"; : > "$T/ctl.log"
out=$($S job set-alert oldjob 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$(diff <(grep -v '^OnFailure=\|^ExecStopPost=' "$OLD") "$T/oldjob.orig")" ] && [ "$(grep -c '^OnFailure=sala-job-failed@%n.service$' "$OLD")" = 1 ] && [ "$(grep -c '^ExecStopPost=-%h/salamander/bin/salamander job alert ok %n$' "$OLD")" = 1 ] \
    && ok "set-alert adds the two lines and changes nothing else" || bad "set-alert (exit $rc): $out / $(diff "$T/oldjob.orig" "$OLD")"
[ "$(sed -n '1,/^\[Service\]/p' "$OLD" | grep -c '^OnFailure=')" = 1 ] && [ "$(sed -n '/^\[Service\]/,$p' "$OLD" | grep -c '^ExecStopPost=')" = 1 ] && ok "OnFailure= is in [Unit], ExecStopPost= in [Service]" || bad "wrong sections: $(cat "$OLD")"
case "$out" in *"git -C $T/hub add -- units/oldjob/systemd/oldjob.service"*"(sala job set-alert)"*"pull --rebase --autostash"*) ok "set-alert prints the commit steps of a main repo" ;; *) bad "git steps: $out" ;; esac
grep -qx -- '--user daemon-reload' "$T/ctl.log" && ok "set-alert reloads the user manager" || bad "ctl: $(cat "$T/ctl.log")"
cp "$OLD" "$T/oldjob.once"; out=$($S job set-alert oldjob 2>&1); rc=$?
[ "$rc" = 0 ] && cmp -s "$OLD" "$T/oldjob.once" && case "$out" in *"already has the alert lines"*) true;; *) false;; esac && ok "set-alert twice: nothing to do" || bad "second set-alert (exit $rc): $out"
cp "$T/oldjob.orig" "$OLD"; out=$($S job set-alert oldjob.service --quiet 2>&1)
case "$out" in *"git -C"*) bad "--quiet printed git steps: $out" ;; *) grep -q '^OnFailure=' "$OLD" && ok "set-alert --quiet (and NAME.service as the name): the lines, no git steps" || bad "--quiet: $out" ;; esac
out=$($S job set-alert nothere 2>&1); rc=$?
[ "$rc" = 1 ] && ok "set-alert of an unknown job is refused" || bad "unknown job (exit $rc): $out"
out=$($S job set-alert 2>&1); rc=$?
[ "$rc" = 2 ] && case "$out" in *"usage: sala job set-alert NAME"*) true;; *) false;; esac && ok "set-alert with no name: usage, exit 2" || bad "no name (exit $rc): $out"
# a unit rendered from a template, and a plain copy not in git, are refused
printf '# Rendered by install.sh from units/r.service.in — edit the template, not this file.\n[Unit]\nDescription=r\n[Service]\nExecStart=/bin/true\n' > "$T/u/rendered.service"
out=$($S job set-alert rendered 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'OnFailure' "$T/u/rendered.service" && bad "a rendered unit was edited" || { [ "$rc" = 1 ] && ok "a unit that is not a link into git (a rendered one) is refused and left alone" || bad "rendered (exit $rc): $out"; }
# a pr repo goes through its worktree
mkdir -p "$T/sal-wt/systemd"
printf '[Unit]\nDescription=sal job\nX-Model-Lane=none\nX-Project=projects/tool-a\n\n[Service]\nType=oneshot\nExecStart=%s/sal/bin/tool.sh\n' "$T" > "$T/sal-wt/systemd/saljob.service"
printf '[Unit]\nDescription=sal job (timer)\n[Timer]\nOnCalendar=daily\n[Install]\nWantedBy=timers.target\n' > "$T/sal-wt/systemd/saljob.timer"
ln -s "$T/sal-wt/systemd/saljob.service" "$T/u/saljob.service"; ln -s "$T/sal-wt/systemd/saljob.timer" "$T/u/saljob.timer"
out=$($S job set-alert saljob 2>&1); rc=$?
[ "$rc" = 2 ] && case "$out" in *"pass the worktree as --checkout"*) true;; *) false;; esac && ! grep -q '^OnFailure=' "$T/sal-wt/systemd/saljob.service" && ok "a pr repo without --checkout is refused and untouched" || bad "pr without checkout (exit $rc): $out"
out=$($S job set-alert saljob --checkout "$T/sal" 2>&1); rc=$?
[ "$rc" = 2 ] && ok "--checkout of the production checkout is refused" || bad "production checkout (exit $rc): $out"
out=$($S job set-alert saljob --checkout "$T/sal-wt" 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q '^OnFailure=sala-job-failed@%n.service$' "$T/sal-wt/systemd/saljob.service" && case "$out" in *"gh pr create"*) true;; *) false;; esac && ok "a pr repo: the worktree copy is edited and the branch + pull request steps are printed" || bad "pr set-alert (exit $rc): $out"
out=$($S job set-alert saljob --checkout "$T/sal-wt" 2>&1)
case "$out" in *"is not installed"*) bad "note although installed: $out" ;; *) ok "no template note when the template is installed" ;; esac
rm "$T/u/sala-job-failed@.service"; cp "$T/oldjob.orig" "$OLD"; out=$($S job set-alert oldjob --quiet 2>&1)
case "$out" in *"sala-job-failed@.service is not installed in"*) ok "set-alert notes a template that is not installed" ;; *) bad "no note: $out" ;; esac

# ---- with_alert: the text function ----------------------------------------------------------------------------------------------------------------
res=$(python3 -I -S -c '
import sys; sys.path.insert(0, sys.argv[1]); import jobalert as j
OF, SP = j.ONFAILURE_LINE, j.STOPPOST_LINE
a = j.with_alert("[Unit]\nDescription=d\n\n[Service]\nExecStart=/x\n\n[Install]\nWantedBy=x\n")
print(a.split("\n")[2] == OF, a.split("\n")[3] == "", a.count(SP) == 1, a.index(SP) < a.index("[Install]"), a.endswith("WantedBy=x\n"))
b = j.with_alert("[Unit]\nDescription=d\n[Service]\nExecStart=/x")          # no trailing newline, no blank line
print(b.split("\n") == ["[Unit]", "Description=d", OF, "[Service]", "ExecStart=/x", SP])
c = j.with_alert("[Unit]\nOnFailure=other.service\n[Service]\nExecStart=/x\nExecStopPost=/bin/true\n")
print(c.count("OnFailure=") == 2 and "OnFailure=other.service" in c and c.count("ExecStopPost=") == 2 and c.index("ExecStopPost=/bin/true") < c.index(SP))
print(j.with_alert(c) == c)                                                  # idempotent
print(j.with_alert("[Service]\nExecStart=/x\n") is None, j.with_alert("[Unit]\nDescription=d\n") is None)
src = ["[Unit]", "X=1", "", "[Service]", "ExecStart=/x", ""]
print(j.with_alert_lines(src) == ["[Unit]", "X=1", OF, "", "[Service]", "ExecStart=/x", SP, ""])
' "$ROOT/lib" 2>&1)
[ "$res" = "$(printf 'True True True True True\nTrue\nTrue\nTrue\nTrue True\nTrue')" ] && ok "with_alert: blank lines kept, no trailing newline, another OnFailure= kept, idempotent, a file without [Unit] or [Service] is None" || bad "with_alert: $res"

echo "jobalert: $([ $fail = 0 ] && echo pass || echo FAIL)"
exit $fail
