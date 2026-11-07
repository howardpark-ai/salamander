#!/usr/bin/env bash
# tests/jobs.sh — `sala job` and the unit-gap watcher (lib/job.sh, lib/unitjob.py, lib/unit-repos.tsv, lib/watch.sh unit_gaps_tick,
# systemd/sala-unit-gaps.{path,service}; docs/units.md). Everything runs in one temporary tree: temporary git repos stand for team-config (flow
# main), salamander (flow pr, with a worktree) and stackshot (no unit folder), the unit folders are temporary
# (SALA_JOB_USER_DIR, SALA_JOB_SYSTEM_DIR), systemctl is a stub that logs its arguments (SALA_JOB_SYSTEMCTL) and stackshot's client.py a stub
# that parses `post job-gap open|clear` as strictly as the real one (two-argument options, a known repo, 600 characters) and logs its argv.
# Nothing touches the real unit folders, systemd or the board.
#   add      refusals (no description, no or bad lane, no or bad project, unknown repo, missing script, taken name, a repo with no unit folder, a pr repo
#            without a worktree) write nothing; a good add writes the two files with Description=, X-Model-Lane= and X-Project=, links them,
#            daemon-reload + enable --now, prints the git steps and commits nothing; --scope system calls no systemctl and prints the root line
#   list/remove/relink    the table, the removal (links, files, the commit steps), the relink after a pull request is deployed
#   check    the gaps (no Description=, no lane, a bad lane, no X-Project=, not in git; a package's unit ignored; a tracked twin and a stackshot-rendered file
#            are in git), the owner builder from the script's repo, one `post job-gap open` per timer and gap (the repo's GitHub owner/name, the `*`
#            row as example-org/team-config, a detail of at most 600 characters), deduped, at most three a pass, a failed open or clear retried (the
#            record kept as it was), a fixed gap closed with `post job-gap clear` and its record dropped, a record of the message era opened once,
#            no client or an old client = exit 0; the sala-watch tick (`watch --unit-gaps`) doing the same, off with SALA_UNIT_GAPS=off
#   X-Project the no-project gap in check and check --post, `sala job set-project` (insert, replace, idempotent, --quiet, a pr repo
#            through a worktree, a system-scope job, refusals), with_project, and contrib/backfill-job-projects.sh (dry run, set, already, skipped, failed)
# Usage: bash tests/jobs.sh   (exit 0 = pass; a few seconds). The temporary tree is locked while the suite runs and removed at its end.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
. "$ROOT/tests/lib.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/sala-jobs.XXXXXX")
exec 8< "$T"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
trap 'exec 8<&-; rm -rf "$T"' EXIT
export HOME=$T/home SALA_CONFIG=/dev/null XDG_STATE_HOME=$T/state
export SALA_JOB_USER_DIR=$T/u SALA_JOB_SYSTEM_DIR=$T/s SALA_JOB_SYSTEMCTL=$T/bin/systemctl SALA_JOB_REPOS=$T/repos.tsv
export SALA_STATE_DIR=$T/state/salamander SALA_STACKSHOT_CLIENT=$T/bin/client SALA_LOG_DIR=$T/log
mkdir -p "$HOME" "$T/bin" "$T/u" "$T/s" "$SALA_LOG_DIR"
S="bash $ROOT/bin/salamander"
G="git -c user.name=t -c user.email=t@t -c commit.gpgsign=false"

# stand-ins: systemctl logs its arguments; the client is a fake stackshot client.py with only `post job-gap open|clear` (below)
printf '#!/bin/sh\necho "$*" >> "%s/ctl.log"\nexit 0\n' "$T" > "$T/bin/systemctl"
export JOBS_T=$T
cat > "$T/bin/client" <<'PY'
#!/usr/bin/env python3
# A fake stackshot client.py: `post job-gap open <timer> <code> --repo R [--detail T] [--sender L]` and `... clear <timer> <code> [--sender L]`, parsed as strictly as
# the real one (client.py job_gap and _opts: `--name value` in two argv slots, never `--name=value`; anything left over prints the usage and exits 1; --repo needed
# for an open and one of the three repos stackshot lists; a detail of at most 600 characters). Appends its argv, TAB-joined, to $JOBS_T/client.log; keeps one open
# item per "timer|code" in $JOBS_T/client.items (open: the same id for a repeat; clear: closes it, "no open item" and exit 0 when there is none); refuses the verb named in
# the file $JOBS_T/client.fail (open, clear or all), after logging the call.
import os, sys, zlib
T = os.environ["JOBS_T"]; a = sys.argv[1:]
USAGE = ('usage: client.py post job-gap open <timer> <code> --repo <owner/name> [--detail "<text, at most 600 characters>"] [--sender <label>]\n'
         '       client.py post job-gap clear <timer> <code> [--sender <label>]')
KNOWN = ("example-org/team-config", "example-org/salamander", "example-org/stackshot")
open(os.path.join(T, "client.log"), "a").write("\t".join(a) + "\n")
def die(m): print(m, file=sys.stderr); sys.exit(1)
if a[:2] != ["post", "job-gap"]: die(USAGE)
a = a[2:]; verb = a[0] if a else ""
if verb not in ("open", "clear") or len(a) < 3 or a[1].startswith("--") or a[2].startswith("--"): die(USAGE)
timer, code, r, opt = a[1].strip(), a[2].strip(), a[3:], {}
for k in (("repo", "detail", "sender") if verb == "open" else ("sender",)):
    if "--" + k in r:
        i = r.index("--" + k)
        if i + 1 >= len(r): die("--" + k + " needs a value\n" + USAGE)
        opt[k] = r[i + 1]; del r[i:i + 2]
if r: die(USAGE)
repo, detail = opt.get("repo", "").strip(), opt.get("detail", "").strip()
if not timer or not code or (verb == "open" and not repo): die(USAGE)
if len(detail) > 600: die("the detail is %d characters and at most 600 are taken: shorten it" % len(detail))
if verb == "open" and repo not in KNOWN: die("stackshot: job gap not opened [400] unknown repo %s (known: %s)" % (repo, ", ".join(KNOWN)))
fp = os.path.join(T, "client.fail")
if os.path.exists(fp) and open(fp).read().strip() in (verb, "all"): die("stackshot: job gap not %s [0] refused (test)" % ("opened" if verb == "open" else "cleared"))
ip = os.path.join(T, "client.items")
items = dict(l.rstrip("\n").split("\t") for l in open(ip)) if os.path.exists(ip) else {}
key = timer + "|" + code
if verb == "open":
    if key not in items: items[key] = "board#%d" % (500 + zlib.crc32(key.encode()) % 9000)
    print(items[key])
elif key in items: print(items.pop(key))
else: print("stackshot: no open item for that gap; nothing was closed", file=sys.stderr)
open(ip, "w").write("".join("%s\t%s\n" % kv for kv in items.items()))
PY
chmod +x "$T/bin/systemctl" "$T/bin/client"

# three repos: hub (flow main), sal (flow pr, a worktree), ss (no unit folder)
for r in hub sal ss; do mkdir -p "$T/$r"; $G -C "$T/$r" init -q -b main; echo "# $r" > "$T/$r/README.md"; $G -C "$T/$r" add README.md; $G -C "$T/$r" commit -q -m init; done
mkdir -p "$T/hub/scripts" "$T/sal/bin" "$T/ss/units"
printf '#!/bin/sh\necho hi\n' > "$T/hub/scripts/job.sh"; chmod +x "$T/hub/scripts/job.sh"
printf '#!/bin/sh\necho hi\n' > "$T/sal/bin/tool.sh"; chmod +x "$T/sal/bin/tool.sh"
printf 'print(1)\n' > "$T/hub/scripts/run.py"
printf '[Unit]\nDescription=r\nX-Model-Lane=none\n' > "$T/ss/units/r.service.in"
$G -C "$T/sal" worktree add -q "$T/sal-wt" -b topic
{ printf '# test table\n'
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' hub "$T/hub" 'units/{name}/systemd' units/systemd-system main projects/example cfg-agent 'hub note NAME' example-org/team-config
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' sal "$T/sal" systemd - pr projects/tool-a tool-agent 'sal note for NAME: relink' example-org/salamander
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' ss "$T/ss" - - pr projects/tool-b ui-agent 'ss renders its units from templates' example-org/stackshot
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' '*' - - - - projects/example misc-agent 'no known repo' example-org/team-config; } > "$T/repos.tsv"

count_files() { find "$T/hub/units" "$T/sal/systemd" "$T/sal-wt/systemd" "$T/u" "$T/s" -mindepth 1 2>/dev/null | wc -l; }
ADD=(--repo hub --script "$T/hub/scripts/job.sh" --schedule '*-*-* 03:30:00 UTC' --description 'nightly thing' --lane none --project projects/example)
refused() {  # <label> <want exit> <stderr substring> <args…>: the refusal's exit code and wording, and that it wrote nothing
    local label=$1 want=$2 sub=$3 before after out rc; shift 3
    before=$(count_files); out=$($S job add "$@" 2>&1); rc=$?; after=$(count_files)
    [ "$rc" = "$want" ] && case "$out" in *"$sub"*) true;; *) false;; esac && [ "$before" = "$after" ] && ok "refused: $label" || bad "refused: $label (exit $rc, want $want, wrote $((after-before)) file(s)): $out"
}

# ---- add: refusals ------------------------------------------------------------------------------------------------------------------
refused "no description" 2 "--description is required" j1 --project projects/example --repo hub --script "$T/hub/scripts/job.sh" --schedule daily --lane none
refused "usage line printed" 2 "usage: sala job add NAME" j1 --project projects/example --repo hub --script "$T/hub/scripts/job.sh" --schedule daily --lane none
refused "no lane" 2 "--lane is required" j1 --project projects/example --repo hub --script "$T/hub/scripts/job.sh" --schedule daily --description d
refused "no project" 2 "--project is required" j1 --repo hub --script "$T/hub/scripts/job.sh" --schedule daily --description d --lane none
refused "a project with no scope" 2 "--project 'general' is not scope/project" j1 --repo hub --script "$T/hub/scripts/job.sh" --schedule daily --description d --lane none --project general
refused "a project in capitals" 2 "--project 'Projects/General' is not scope/project" j1 --repo hub --script "$T/hub/scripts/job.sh" --schedule daily --description d --lane none --project Projects/General
refused "bad lane" 2 "--lane 'llm' is none of" j1 --project projects/example --repo hub --script "$T/hub/scripts/job.sh" --schedule daily --description d --lane llm
refused "empty description" 2 "--description is required" j1 --project projects/example --repo hub --script "$T/hub/scripts/job.sh" --schedule daily --description "" --lane none
refused "unknown repo" 2 "unknown repo 'nope' (known: hub | sal | ss)" j1 --project projects/example --repo nope --script "$T/hub/scripts/job.sh" --schedule daily --description d --lane none
refused "script is not there" 2 "does not exist" j1 --project projects/example --repo hub --script "$T/nothing.sh" --schedule daily --description d --lane none
refused "no schedule" 2 "--schedule is required" j1 --project projects/example --repo hub --script "$T/hub/scripts/job.sh" --description d --lane none
refused "bad name" 2 "name 'Bad Name'" "Bad Name" "${ADD[@]}"
refused "a repo with no unit folder" 1 "ss renders its units from templates" j1 --project projects/example --repo ss --script "$T/hub/scripts/job.sh" --schedule daily --description d --lane none
refused "a pr repo without a worktree" 2 "worktree add" j1 --project projects/example --repo sal --script "$T/sal/bin/tool.sh" --schedule daily --description d --lane none
refused "a script that cannot run" 2 "not executable" j1 --project projects/example --repo hub --script "$T/hub/README.md" --schedule daily --description d --lane none
if command -v systemd-analyze >/dev/null 2>&1; then refused "a schedule systemd rejects" 2 "systemd does not accept" j1 --project projects/example --repo hub --script "$T/hub/scripts/job.sh" --schedule 'not a time' --description d --lane none; fi
[ ! -s "$T/ctl.log" ] && ok "no systemctl call for any refusal" || bad "systemctl was called for a refusal: $(cat "$T/ctl.log")"

# ---- add: a good one (hub, flow main) -----------------------------------------------------------------------------------------------
out=$($S job add nightly "${ADD[@]}" --note "no model" 2>&1); rc=$?
SVC=$T/hub/units/nightly/systemd/nightly.service; TMR=$T/hub/units/nightly/systemd/nightly.timer
[ "$rc" = 0 ] && [ -f "$SVC" ] && [ -f "$TMR" ] && ok "add wrote the service and the timer into the repo's unit folder" || bad "add failed (exit $rc): $out"
[ "$(grep -c '^Description=nightly thing$' "$SVC")" = 1 ] && [ "$(grep -c '^X-Model-Lane=none$' "$SVC")" = 1 ] && [ "$(grep -c '^X-Model-Note=no model$' "$SVC")" = 1 ] && ok "service: Description=, X-Model-Lane= and X-Model-Note= in [Unit]" || bad "service text: $(cat "$SVC")"
[ "$(grep -c '^X-Project=projects/example$' "$SVC")" = 1 ] && [ "$(sed -n '1,/^\[Service\]/p' "$SVC" | grep -c '^X-Project=')" = 1 ] && ok "service: X-Project= once, in [Unit]" || bad "service has no X-Project= in [Unit]: $(cat "$SVC")"
grep -q "^ExecStart=$T/hub/scripts/job.sh\$" "$SVC" && grep -q '^Type=oneshot$' "$SVC" && ok "service: oneshot, ExecStart is the script" || bad "ExecStart: $(grep ExecStart "$SVC")"
grep -q '^OnCalendar=\*-\*-\* 03:30:00 UTC$' "$TMR" && grep -q '^Persistent=true$' "$TMR" && grep -q '^Unit=nightly.service$' "$TMR" && grep -q '^WantedBy=timers.target$' "$TMR" && ok "timer: OnCalendar, Persistent, Unit, [Install]" || bad "timer text: $(cat "$TMR")"
[ "$(readlink "$T/u/nightly.service")" = "$SVC" ] && [ "$(readlink "$T/u/nightly.timer")" = "$TMR" ] && ok "linked into the user unit folder" || bad "links: $(ls -l "$T/u")"
grep -qx -- '--user daemon-reload' "$T/ctl.log" && grep -qx -- '--user enable --now nightly.timer' "$T/ctl.log" && ok "daemon-reload, then enable --now the timer" || bad "systemctl calls: $(cat "$T/ctl.log")"
case "$out" in *"git -C $T/hub add -- units/nightly/systemd/nightly.service units/nightly/systemd/nightly.timer"*"pull --rebase --autostash"*"hub note nightly"*) ok "prints the git status, the commit steps for a main repo and the repo's note" ;; *) bad "git steps: $out" ;; esac
[ "$($G -C "$T/hub" log --oneline | wc -l)" = 1 ] && [ -z "$($G -C "$T/hub" diff --cached --name-only)" ] && ok "nothing committed, nothing staged" || bad "add committed or staged something"
refused "a taken name" 1 "is taken" nightly "${ADD[@]}"
# a python script and the other schedule forms
out=$($S job add pyjob --repo hub --script "$T/hub/scripts/run.py" --schedule OnBootSec=5min --schedule OnUnitActiveSec=1h --description 'py thing' --lane api --project projects/example --args 'merge' 2>&1)
PYS=$T/hub/units/pyjob/systemd
grep -qx "ExecStart=%h/.local/bin/uv run --script $T/hub/scripts/run.py merge" "$PYS/pyjob.service" && grep -qx 'OnBootSec=5min' "$PYS/pyjob.timer" && grep -qx 'OnUnitActiveSec=1h' "$PYS/pyjob.timer" \
    && ! grep -q 'Persistent' "$PYS/pyjob.timer" && ok "a .py goes through uv; monotonic schedules are written as given (no Persistent)" || bad "pyjob: $out"

# ---- list -----------------------------------------------------------------------------------------------------------------------------
out=$($S job list 2>&1)
case "$out" in *PROJECT*nightly*hub*"OnCalendar=*-*-* 03:30:00 UTC"*none*projects/example*yes*user*) ok "list: name, repo, schedule, lane, project, in git" ;; *) bad "list: $out" ;; esac

# ---- SALA_UNIT_PROJECT_MAP: a unit's X-Project= shown as another project; unset, empty or malformed = as written -------------------------
out=$(SALA_UNIT_PROJECT_MAP="projects/example=team/docs" $S job list 2>&1)
case "$out" in *nightly*hub*team/docs*) ok "SALA_UNIT_PROJECT_MAP maps the project in list" ;; *) bad "project map list: $out" ;; esac
out=$(SALA_UNIT_PROJECT_MAP="projects/other=team/x projects/example=team/docs" $S job list 2>&1)
case "$out" in *nightly*team/docs*) ok "a map with several pairs: the one that matches applies" ;; *) bad "project map pairs: $out" ;; esac
for m in "" "   " "projects/example" "projects/example=" "=team/docs" "bogus=" "projects/other=team/x" "x==y"; do
    out=$(SALA_UNIT_PROJECT_MAP="$m" $S job list 2>&1); rc=$?
    case "$out" in *nightly*projects/example*) [ "$rc" = 0 ] && ok "map '$m': no mapping, no error" || bad "map '$m': exit $rc" ;; *) bad "map '$m': $out" ;; esac
done
printf 'SALA_UNIT_PROJECT_MAP="projects/example=team/cfg"\n' > "$T/map.cfg"
out=$(SALA_CONFIG=$T/map.cfg $S job list 2>&1)
case "$out" in *nightly*team/cfg*) ok "SALA_UNIT_PROJECT_MAP read from the sala config line" ;; *) bad "project map from config: $out" ;; esac
out=$(SALA_UNIT_PROJECT_MAP="projects/example=team/docs" $S job check 2>&1)
case "$out" in *"no-project"*) bad "a mapped project is flagged no-project: $out" ;; *) ok "a mapped project is not a no-project gap" ;; esac

# ---- add: system scope (prints, calls nothing) --------------------------------------------------------------------------------------
: > "$T/ctl.log"
out=$($S job add sysjob "${ADD[@]}" --scope system 2>&1)
[ -f "$T/hub/units/systemd-system/sysjob.service" ] && [ -f "$T/hub/units/systemd-system/sysjob.timer" ] && [ ! -e "$T/s/sysjob.timer" ] && [ ! -s "$T/ctl.log" ] \
    && case "$out" in *"sudo install -m 0644"*"enable --now sysjob.timer"*) true;; *) false;; esac && ok "system scope: files in the repo's system folder, the root command printed, no systemctl call, nothing in /etc" || bad "system scope: $out"
refused "system scope in a repo with none" 1 "no system-scope unit folder" j9 --project projects/example --repo sal --checkout "$T/sal-wt" --script "$T/sal/bin/tool.sh" --schedule daily --description d --lane none --scope system

# ---- add: a pr repo from a worktree, then relink ------------------------------------------------------------------------------------
out=$($S job add saljob --repo sal --checkout "$T/sal-wt" --script "$T/sal/bin/tool.sh" --schedule daily --description 'sal thing' --lane subscription-1 --project projects/demo 2>&1); rc=$?
[ "$rc" = 0 ] && [ -f "$T/sal-wt/systemd/saljob.service" ] && [ ! -e "$T/sal/systemd/saljob.service" ] && ok "pr repo: the files go into the worktree, never the production checkout" || bad "pr add (exit $rc): $out"
case "$out" in *"git -C $T/sal-wt push -u origin HEAD"*"gh pr create"*"sal note for saljob: relink"*) ok "prints the branch + pull request steps and the repo's note" ;; *) bad "pr steps: $out" ;; esac
out=$($S job relink saljob 2>&1); rc=$?
[ "$rc" = 1 ] && case "$out" in *"not in the production checkout"*) true;; *) false;; esac && ok "relink refuses before the release deployed the files" || bad "relink early (exit $rc): $out"
mkdir -p "$T/sal/systemd"; cp "$T/sal-wt/systemd/saljob.service" "$T/sal-wt/systemd/saljob.timer" "$T/sal/systemd/"
: > "$T/ctl.log"
out=$($S job relink saljob 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(readlink "$T/u/saljob.timer")" = "$T/sal/systemd/saljob.timer" ] && [ "$(readlink "$T/u/saljob.service")" = "$T/sal/systemd/saljob.service" ] && grep -qx -- '--user daemon-reload' "$T/ctl.log" && ok "relink points the links at the production checkout and reloads" || bad "relink (exit $rc): $out"

# ---- remove -----------------------------------------------------------------------------------------------------------------------------
out=$($S job remove saljob 2>&1); rc=$?
[ "$rc" = 2 ] && case "$out" in *"--checkout"*) true;; *) false;; esac && [ -L "$T/u/saljob.timer" ] && ok "remove of a pr repo's job needs the worktree (and touched nothing)" || bad "remove without worktree (exit $rc): $out"
out=$($S job remove saljob --checkout "$T/sal" 2>&1); rc=$?
[ "$rc" = 2 ] && [ -L "$T/u/saljob.timer" ] && ok "remove refuses the production checkout" || bad "remove on production (exit $rc): $out"
: > "$T/ctl.log"
out=$($S job remove saljob --checkout "$T/sal-wt" 2>&1); rc=$?
[ "$rc" = 0 ] && [ ! -e "$T/u/saljob.timer" ] && [ ! -L "$T/u/saljob.service" ] && [ ! -e "$T/sal-wt/systemd/saljob.timer" ] && [ -f "$T/sal/systemd/saljob.timer" ] && grep -qx -- '--user disable --now saljob.timer' "$T/ctl.log" \
    && case "$out" in *"git -C $T/sal-wt add -- systemd/saljob.service systemd/saljob.timer"*"gh pr create"*) true;; *) false;; esac && ok "remove: disabled, unlinked, deleted from the worktree only, the commit steps printed" || bad "remove (exit $rc): $out"
out=$($S job remove nightly 2>&1); rc=$?
[ "$rc" = 0 ] && [ ! -e "$T/u/nightly.timer" ] && [ ! -e "$SVC" ] && [ ! -e "$TMR" ] && case "$out" in *"git -C $T/hub add -- units/nightly/systemd/nightly.service"*"pull --rebase --autostash"*) true;; *) false;; esac && ok "remove of a main repo's job" || bad "remove nightly (exit $rc): $out"
out=$($S job remove nothere 2>&1); rc=$?
[ "$rc" = 1 ] && ok "remove of an unknown job refused" || bad "remove nothere (exit $rc): $out"
# a real `systemctl disable` removes the link of a linked unit file by itself: remove must not die on the missing link, must still delete
# the repo copies and print the git steps, and must reset-failed afterwards
$S job add unlinker "${ADD[@]}" > /dev/null 2>&1
UNL=$T/hub/units/unlinker/systemd
printf '#!/bin/sh\necho "$*" >> "%s/ctl.log"\n[ "$2" = disable ] && rm -f "%s/u/$4"\nexit 0\n' "$T" "$T" > "$T/bin/systemctl-disable-unlinks"
chmod +x "$T/bin/systemctl-disable-unlinks"
: > "$T/ctl.log"
out=$(SALA_JOB_SYSTEMCTL=$T/bin/systemctl-disable-unlinks $S job remove unlinker 2>&1); rc=$?
[ "$rc" = 0 ] && [ ! -L "$T/u/unlinker.timer" ] && [ ! -L "$T/u/unlinker.service" ] && [ ! -e "$UNL/unlinker.timer" ] && [ ! -e "$UNL/unlinker.service" ] \
    && grep -qx -- '--user reset-failed unlinker.timer unlinker.service' "$T/ctl.log" \
    && case "$out" in *"unlinked "*"unlinker.service"*"unlinker.timer was already removed by systemctl disable"*"git -C $T/hub add -- units/unlinker/systemd/unlinker.service"*) true;; *) false;; esac \
    && ok "remove survives a disable that already removed the link, deletes the repo copies, runs reset-failed" || bad "remove after a disable that unlinks (exit $rc): $out; ctl: $(cat "$T/ctl.log")"
$S job remove pyjob > /dev/null 2>&1; rm -rf "$T/hub/units"; rm -f "$T/u"/* "$T/s"/*

# ---- check: the gaps ---------------------------------------------------------------------------------------------------------------
unit() {  # <dir> <name> <service [Unit] extra lines…>: a service + timer pair as regular files; the script is $SCRIPT; X-Project=projects/example unless NOPROJ=1
    local d=$1 n=$2; shift 2
    { echo '[Unit]'; for l in "$@"; do echo "$l"; done; [ "${NOPROJ:-}" = 1 ] || echo 'X-Project=projects/example'; printf '[Service]\nType=oneshot\nExecStart=%s\n' "$SCRIPT"; } > "$d/$n.service"
    printf '[Unit]\nDescription=t\n[Timer]\nOnCalendar=daily\n[Install]\nWantedBy=timers.target\n' > "$d/$n.timer"
}
SCRIPT=$T/sal/bin/tool.sh; unit "$T/u" bad1 'Description=has no lane'                       # no lane, not in git; the script is salamander's
SCRIPT=$T/hub/scripts/job.sh
mkdir -p "$T/hub/units/bad2/systemd"; unit "$T/hub/units/bad2/systemd" bad2 'X-Model-Lane=none'  # in the repo, linked: only the missing Description=
ln -s "$T/hub/units/bad2/systemd/bad2.service" "$T/u/bad2.service"; ln -s "$T/hub/units/bad2/systemd/bad2.timer" "$T/u/bad2.timer"
unit "$T/u" bad3 'Description=bad lane' 'X-Model-Lane=llm'                                  # a lane that is none of the seven
mkdir -p "$T/hub/units/twin"; unit "$T/hub/units/twin" twin 'Description=twin' 'X-Model-Lane=none'; $G -C "$T/hub" add units/twin; $G -C "$T/hub" commit -q -m twin
cp "$T/hub/units/twin/twin.service" "$T/hub/units/twin/twin.timer" "$T/u/"                      # regular files, byte for byte a tracked file's: in git
mkdir -p "$T/hub/units/diff1"; unit "$T/hub/units/diff1" diff1 'Description=differs' 'X-Model-Lane=none'; $G -C "$T/hub" add units/diff1; $G -C "$T/hub" commit -q -m diff1
cp "$T/hub/units/diff1/diff1.service" "$T/hub/units/diff1/diff1.timer" "$T/u/"; echo '# edited by hand' >> "$T/u/diff1.service"   # a copy that differs from its git file
printf '# Rendered by install.sh from units/r.service.in — edit the template, not this file.\n[Unit]\nDescription=r\nX-Model-Lane=none\nX-Project=projects/example\n[Service]\nExecStart=%s\n' "$SCRIPT" > "$T/u/r.service"
printf '# Rendered by install.sh from units/r.timer.in — edit the template, not this file.\n[Unit]\nDescription=r\n[Timer]\nOnCalendar=daily\n' > "$T/u/r.timer"
cp "$T/ss/units/r.service.in" "$T/ss/units/r.timer.in"                                      # (the template stackshot renders from)
ln -s /usr/bin/true "$T/u/pkg.timer"; ln -s /usr/bin/true "$T/u/pkg.service"               # a package's unit: ignored whatever it holds
SCRIPT=$T/nowhere/x.sh; unit "$T/s" sysbad 'Description=system one'                         # the system folder is read too: no lane, not in git, owner = the * row
out=$($S job check 2>&1); rc=$?
want=$'bad1.timer\tno-lane\ttool-agent\nbad1.timer\tnot-git\ttool-agent\nbad2.timer\tno-description\tcfg-agent\ndiff1.timer\tgit-differs\tcfg-agent\nbad3.timer\tbad-lane\tcfg-agent\nbad3.timer\tnot-git\tcfg-agent\nsysbad.timer\tno-lane\tmisc-agent\nsysbad.timer\tnot-git\tmisc-agent'
got=$(printf '%s\n' "$out" | cut -f1-3 | sort)
[ "$rc" = 1 ] && [ "$got" = "$(printf '%s\n' "$want" | sort)" ] && ok "check: every gap found once, the owner builder from the script's repo, a package's unit and the tracked/rendered files left out; a copy that differs from its git file is git-differs" || bad "check (exit $rc):
$out
want:
$want"

# ---- check --post: one board item per timer and gap (client.py post job-gap open / clear) -------------------------------------------
# the log lines are the client's argv, TAB-joined: 1 post, 2 job-gap, 3 open|clear, 4 timer, 5 code, then for an open 6 --repo 7 <repo> 8 --detail 9 <text> 10 --sender 11 <label>
calls() { wc -l < "$T/client.log"; }
detail_of() {  # <timer> <code>: the --detail of the (last) open for that gap
    awk -F'\t' -v t="$1" -v c="$2" '$3 == "open" && $4 == t && $5 == c {d = $9} END {print d}' "$T/client.log"
}
repo_of() { awk -F'\t' -v t="$1" -v c="$2" '$3 == "open" && $4 == t && $5 == c {d = $7} END {print d}' "$T/client.log"; }
: > "$T/client.log"; rm -f "$T/client.items" "$T/client.fail" "$T/state/salamander/unit-gaps.tsv"
# the stub itself is as strict as the real client: a --repo=X form, an unknown repo or a 601-character detail is refused
"$T/bin/client" post job-gap open x.timer no-lane --repo=example-org/team-config > /dev/null 2>&1; r1=$?
"$T/bin/client" post job-gap open x.timer no-lane --repo some/where > /dev/null 2>&1; r2=$?
"$T/bin/client" post job-gap open x.timer no-lane --repo example-org/team-config --detail "$(printf 'x%.0s' $(seq 601))" > /dev/null 2>&1; r3=$?
"$T/bin/client" message cfg-agent - --sender sala-unit-gaps > /dev/null 2>&1 < /dev/null; r4=$?
[ "$r1$r2$r3$r4" = 1111 ] && [ ! -s "$T/client.items" ] && ok "the stub client refuses --repo=X, an unlisted repo, a 601-character detail and the old message call" || bad "stub strictness: $r1 $r2 $r3 $r4"
: > "$T/client.log"
out=$($S job check --post 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(calls)" = 3 ] && ok "check --post: at most three opens in one pass (eight gaps)" || bad "first pass (exit $rc, $(calls) calls): $out"
[ "$(awk -F'\t' '$1 == "post" && $2 == "job-gap" && $3 == "open" && $6 == "--repo" && $8 == "--detail" && $10 == "--sender" && $11 == "sala-unit-gaps" && NF == 11' "$T/client.log" | wc -l)" = 3 ] \
    && ok "the call is: client.py post job-gap open <timer> <code> --repo <owner/name> --detail <text> --sender sala-unit-gaps (two-argument options)" || bad "client calls: $(cat "$T/client.log")"
$S job check --post > /dev/null 2>&1; $S job check --post > /dev/null 2>&1
[ "$(calls)" = 8 ] && [ "$(cut -f1 "$T/state/salamander/unit-gaps.tsv" | sort -u | wc -l)" = 8 ] && [ "$(sort -u "$T/client.items" | wc -l)" = 8 ] && ok "the next passes open the other five and then nothing: deduped by timer + gap code" || bad "dedupe: $(calls) calls; state: $(cat "$T/state/salamander/unit-gaps.tsv")"
n=$(calls); $S job check --post > /dev/null 2>&1
[ "$(calls)" = "$n" ] && ok "a pass with nothing new makes no call (a repeat open never happens)" || bad "a repeat pass called the client: $(tail -2 "$T/client.log")"
# the state records the item id the client printed (the 4th column)
item=$(awk -F'\t' '$1 == "bad1.timer|no-lane" {print $4}' "$T/state/salamander/unit-gaps.tsv")
[ -n "$item" ] && [ "$item" = "$(awk -F'\t' '$1 == "bad1.timer|no-lane" {print $2}' "$T/client.items")" ] && ok "unit-gaps.tsv keeps the item id the open printed ($item)" || bad "item id: '$item'; state: $(cat "$T/state/salamander/unit-gaps.tsv")"
# the repo: the owner of the script's repo, GitHub owner/name from the table's last column; the * row (a script in no known repo) is team-config
[ "$(repo_of bad1.timer no-lane)" = example-org/salamander ] && [ "$(repo_of bad2.timer no-description)" = example-org/team-config ] && [ "$(repo_of diff1.timer git-differs)" = example-org/team-config ] \
    && ok "--repo is the GitHub owner/name of the script's repo (salamander -> example-org/salamander, team-config -> example-org/team-config)" || bad "repos: $(awk -F'\t' '{print $4, $5, $7}' "$T/client.log")"
[ "$(repo_of sysbad.timer no-lane)" = example-org/team-config ] && [ "$(repo_of sysbad.timer not-git)" = example-org/team-config ] && ok "a script in no known repo (the * row) goes in as example-org/team-config" || bad "* row: $(repo_of sysbad.timer no-lane)"
for r in $(awk -F'\t' '$3 == "open" {print $7}' "$T/client.log" | sort -u); do case "$r" in example-org/team-config|example-org/salamander|example-org/stackshot) ;; *) bad "an open named a repo stackshot does not list: $r";; esac; done
# every detail is one line of at most 600 characters, and says the gap and the fix
python3 -I -c 'import sys
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1], encoding="utf-8")]
sys.exit(1 if any(len(r) != 11 or not (40 <= len(r[8]) <= 600 and "Fix: " in r[8]) for r in rows if r[2] == "open") else 0)' "$T/client.log" && ok "every --detail is one line of 40 to 600 characters with the fix in it" || bad "a detail out of shape: $(cat "$T/client.log")"
# the Fix text follows the scope: a system unit (/etc/systemd/system) gets root commands, a user unit the user-scope ones (unchanged)
sysmsg=$(detail_of sysbad.timer no-lane); usrmsg=$(detail_of diff1.timer git-differs)
sysdiff=$(PYTHONDONTWRITEBYTECODE=1 python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import unitjob
print(unitjob.gap_fix({"unit": "x.timer", "scope": "system", "code": "git-differs", "text": "t", "repo": "hub", "path": "/etc/systemd/system/x.timer", "script": None}))' "$ROOT/lib")
sysclean() { ! printf '%s\n' "$1" | grep -q -e '--user' && ! printf '%s\n' "$1" | grep -o '.\{5\}ln -sf' | grep -qv 'sudo ln -sf'; }   # no --user, no ln -sf without sudo before it
sysclean "$sysmsg" && sysclean "$sysdiff" && case "$sysmsg" in *'sudo systemctl daemon-reload'*'sudo install -m 0644 <the git file> /etc/systemd/system/'*) true;; *) false;; esac \
    && case "$sysdiff" in *'sudo systemctl link <the git file>'*'sudo ln -sf <the git file> <the unit file>'*'sudo systemctl daemon-reload'*) true;; *) false;; esac \
    && ok "a system-scope gap (no-lane, git-differs): root commands only (sudo systemctl link / ln -sf / install, sudo daemon-reload), no --user" || bad "system-scope text: $sysmsg
$sysdiff"
case "$usrmsg" in *'`ln -sf <the git file> <the unit file>`, then `systemctl --user daemon-reload`'*) ok "a user-scope git-differs gap keeps the user-scope text" ;; *) bad "user-scope text changed: $usrmsg" ;; esac
# a gap fixed: its item is closed, its record goes; a gap still open stays recorded and is not opened again
printf '[Unit]\nDescription=has a lane\nX-Model-Lane=none\nX-Project=projects/example\n[Service]\nExecStart=%s\n' "$T/sal/bin/tool.sh" > "$T/u/bad1.service"
n=$(calls); out=$($S job check --post 2>&1)
case "$out" in *"closed bad1.timer no-lane"*) true;; *) false;; esac && ! grep -q '^bad1.timer|no-lane' "$T/state/salamander/unit-gaps.tsv" && grep -q '^bad1.timer|not-git' "$T/state/salamander/unit-gaps.tsv" && [ "$(calls)" = $((n + 1)) ] \
    && [ "$(tail -1 "$T/client.log")" = $'post\tjob-gap\tclear\tbad1.timer\tno-lane\t--sender\tsala-unit-gaps' ] && ! grep -q '^bad1.timer|no-lane' "$T/client.items" \
    && ok "a fixed gap: client.py post job-gap clear <timer> <code> --sender sala-unit-gaps, the item closed, the record dropped; the others stay, nothing re-opened" || bad "fix pass: $out; last call: $(tail -1 "$T/client.log")"
printf '[Unit]\nDescription=again\nX-Project=projects/example\n[Service]\nExecStart=%s\n' "$T/sal/bin/tool.sh" > "$T/u/bad1.service"
n=$(calls); $S job check --post > /dev/null 2>&1
[ "$(calls)" = $((n + 1)) ] && tail -1 "$T/client.log" | grep -q $'^post\tjob-gap\topen\tbad1.timer\tno-lane\t' && grep -q '^bad1.timer|no-lane' "$T/state/salamander/unit-gaps.tsv" && ok "the gap coming back is opened again" || bad "a returning gap: $(tail -2 "$T/client.log")"
# a record of the message era (3 columns, no item id) is opened once as an item; one for a gap that is gone is cleared (the client says "no open item", exit 0) and dropped
awk -F'\t' -v OFS='\t' '$1 == "bad3.timer|bad-lane" {print $1, $2, $3; next} {print}' "$T/state/salamander/unit-gaps.tsv" > "$T/state/salamander/unit-gaps.new"; mv "$T/state/salamander/unit-gaps.new" "$T/state/salamander/unit-gaps.tsv"
printf 'gone.timer|no-lane\tcfg-agent\t1\n' >> "$T/state/salamander/unit-gaps.tsv"
n=$(calls); out=$($S job check --post 2>&1)
[ "$(calls)" = $((n + 2)) ] && [ "$(awk -F'\t' -v n="$n" 'NR > n && $3 == "open" && $4 == "bad3.timer" && $5 == "bad-lane"' "$T/client.log" | wc -l)" = 1 ] && [ "$(awk -F'\t' -v n="$n" 'NR > n && $3 == "clear" && $4 == "gone.timer"' "$T/client.log" | wc -l)" = 1 ] \
    && awk -F'\t' '$1 == "bad3.timer|bad-lane" && $4 != "" {f=1} END {exit !f}' "$T/state/salamander/unit-gaps.tsv" && ! grep -q '^gone.timer' "$T/state/salamander/unit-gaps.tsv" \
    && ok "a record from the message era: opened once as an item (now with its id); a gone one is cleared and dropped" || bad "legacy records: $out; $(tail -2 "$T/client.log")"
# an open that fails is not recorded and is tried at the next pass
rm -f "$T/state/salamander/unit-gaps.tsv" "$T/client.items"; : > "$T/client.log"; echo open > "$T/client.fail"
out=$($S job check --post 2>&1); rc=$?
[ "$rc" = 0 ] && [ ! -s "$T/state/salamander/unit-gaps.tsv" ] && [ "$(calls)" = 1 ] && case "$out" in *"could not open"*"refused (test)"*) true;; *) false;; esac && ok "a failed open: exit 0, nothing recorded, one call only, said so with the client's reason" || bad "failed open (exit $rc, $(calls) calls): $out"
rm -f "$T/client.fail"; : > "$T/client.log"
$S job check --post > /dev/null 2>&1
[ "$(calls)" = 3 ] && [ "$(wc -l < "$T/state/salamander/unit-gaps.tsv")" = 3 ] && ok "and opened at the next pass" || bad "retry: $(calls) calls"
# a clear that fails keeps the record (and files nothing else that pass); it is tried at the next pass
printf '[Unit]\nDescription=has a lane\nX-Model-Lane=none\nX-Project=projects/example\n[Service]\nExecStart=%s\n' "$T/sal/bin/tool.sh" > "$T/u/bad1.service"
before=$(cat "$T/state/salamander/unit-gaps.tsv"); : > "$T/client.log"; echo clear > "$T/client.fail"
out=$($S job check --post 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(cat "$T/state/salamander/unit-gaps.tsv")" = "$before" ] && [ "$(calls)" = 1 ] && grep -q '^bad1.timer|no-lane' "$T/client.items" && case "$out" in *"could not close bad1.timer no-lane"*"the record stays"*) true;; *) false;; esac \
    && ok "a failed clear: exit 0, the record and the item stay, one call only, said so" || bad "failed clear (exit $rc, $(calls) calls): $out"
rm -f "$T/client.fail"; : > "$T/client.log"
$S job check --post > /dev/null 2>&1
[ "$(head -1 "$T/client.log")" = $'post\tjob-gap\tclear\tbad1.timer\tno-lane\t--sender\tsala-unit-gaps' ] && ! grep -q '^bad1.timer|no-lane' "$T/state/salamander/unit-gaps.tsv" && ! grep -q '^bad1.timer|no-lane' "$T/client.items" && ok "and closed at the next pass" || bad "clear retry: $(cat "$T/client.log")"
# no client on the box: fail-soft, nothing recorded
rm -f "$T/state/salamander/unit-gaps.tsv"; : > "$T/client.log"
out=$(SALA_STACKSHOT_CLIENT=$T/bin/none $S job check --post 2>&1); rc=$?
[ "$rc" = 0 ] && [ ! -s "$T/state/salamander/unit-gaps.tsv" ] && [ ! -s "$T/client.log" ] && ok "no stackshot client: exit 0, nothing recorded" || bad "no client (exit $rc): $out"
# an old client (no job-gap call): exit 0 with a log line, nothing called, the records kept
printf '#!/bin/sh\necho "$*" >> "%s/old.log"\necho "usage: client.py message <to> <text>" >&2\nexit 1\n' "$T" > "$T/bin/client-old"; chmod +x "$T/bin/client-old"
printf 'bad1.timer|no-lane\ttool-agent\t1\t%s\n' board#9009 > "$T/state/salamander/unit-gaps.tsv"; before=$(cat "$T/state/salamander/unit-gaps.tsv")
out=$(SALA_STACKSHOT_CLIENT=$T/bin/client-old $S job check --post --quiet 2>&1); rc=$?
[ "$rc" = 0 ] && [ ! -e "$T/old.log" ] && [ "$(cat "$T/state/salamander/unit-gaps.tsv")" = "$before" ] && case "$out" in *"has no job-gap call"*) true;; *) false;; esac && ok "an old client without job-gap: exit 0, one log line, no call, the records kept" || bad "old client (exit $rc): $out"
# the 600-character cut: a long unit name makes a long head; the call still goes through (the stub refuses over 600) and the fix survives the cut
rm -f "$T/state/salamander/unit-gaps.tsv" "$T/client.items"; : > "$T/client.log"; mkdir -p "$T/ulong" "$T/slong" "$T/statelong"
long=$(printf 'x%.0s' $(seq 200)); SCRIPT=$T/sal/bin/tool.sh; unit "$T/ulong" "$long" 'Description=long name'
out=$(SALA_JOB_USER_DIR=$T/ulong SALA_JOB_SYSTEM_DIR=$T/slong SALA_STATE_DIR=$T/statelong $S job check --post 2>&1); rc=$?
d=$(awk -F'\t' '$3 == "open" && $5 == "no-lane" {print $9}' "$T/client.log")
[ "$rc" = 0 ] && [ "${#d}" -gt 560 ] && [ "${#d}" -le 600 ] && [[ $d == *"... Fix: add \`X-Model-Lane=<lane>\`"*"Rule: docs/units.md of salamander." ]] && [[ $d != *$'\n'* ]] && [ "$(calls)" = 2 ] \
    && ok "a detail over 600 characters is cut to ${#d}: the head is cut with "...", the fix kept, the call accepted" || bad "long detail (exit $rc, ${#d} chars, $(calls) calls): $out / $d"
rm -rf "$T/ulong" "$T/slong" "$T/statelong"
# the cut itself, with a fix of its own longer than the limit and a head that is empty
cut=$(PYTHONDONTWRITEBYTECODE=1 python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import unitjob
d = unitjob.gap_detail({"unit": "x.timer", "scope": "system", "code": "no-lane", "text": "y" * 3000, "repo": "*", "path": "/etc/systemd/system/x.timer", "script": None})
print(len(d), "\n" in d, d.endswith("Rule: docs/units.md of salamander."), "Fix: " in d)' "$ROOT/lib")
[ "$cut" = "600 False True True" ] && ok "gap_detail: 600 characters at most, one line, the fix kept whole when the head is huge" || bad "gap_detail cut: $cut"
# a repo table without the github column falls back to SALA_JOB_GITHUB (empty when unset); the column is read when present
printf 'a\t-\t-\t-\tpr\tp/a\tab\tn\nb\t-\t-\t-\tpr\tp/b\tbb\tn\tfoo/bar\n' > "$T/repos8.tsv"
col=$(SALA_JOB_REPOS=$T/repos8.tsv PYTHONDONTWRITEBYTECODE=1 python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import unitjob
r = unitjob.load_repos(); print("[" + r["a"]["github"] + "]", r["b"]["github"])' "$ROOT/lib")
[ "$col" = "[] foo/bar" ] && ok "the github column: read when there, empty when a row has none and SALA_JOB_GITHUB is unset" || bad "github column: $col"
col=$(SALA_JOB_GITHUB=alice/fallback SALA_JOB_REPOS=$T/repos8.tsv PYTHONDONTWRITEBYTECODE=1 python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import unitjob
r = unitjob.load_repos(); print(r["a"]["github"], r["b"]["github"])' "$ROOT/lib")
[ "$col" = "alice/fallback foo/bar" ] && ok "SALA_JOB_GITHUB is the github of a row that has none" || bad "SALA_JOB_GITHUB: $col"

# ---- X-Project=: the no-project gap, set-project, with_project, the backfill script --------------------------------------
# its own unit folders and state folder: nothing above is touched
PU=$T/pu; PS=$T/ps; PSTATE=$T/pstate; mkdir -p "$PU" "$PS" "$PSTATE"
penv() { SALA_JOB_USER_DIR=$PU SALA_JOB_SYSTEM_DIR=$PS SALA_STATE_DIR=$PSTATE "$@"; }
SCRIPT=$T/hub/scripts/job.sh
NPD=$T/hub/units/np/systemd; NPS=$NPD/np.service; mkdir -p "$NPD"; NOPROJ=1 unit "$NPD" np 'Description=no project yet' 'X-Model-Lane=none'
ln -s "$NPS" "$PU/np.service"; ln -s "$NPD/np.timer" "$PU/np.timer"
cp "$NPS" "$T/np.service.orig"
out=$(penv $S job check 2>&1); rc=$?
[ "$rc" = 1 ] && [ "$(printf '%s\n' "$out" | cut -f1-3)" = $'np.timer\tno-project\tcfg-agent' ] && case "$out" in *"np.service has no X-Project= in its [Unit] section"*) true;; *) false;; esac \
    && ok "check: a timer whose service has no X-Project= is a no-project gap (its owner builder, the service named)" || bad "no-project check (exit $rc): $out"
: > "$T/client.log"; rm -f "$T/client.items" "$T/state/salamander/unit-gaps.tsv"   # (the state folder is the suite's one: start it clean)
out=$(penv $S job check --post 2>&1); rc=$?
d=$(detail_of np.timer no-project)
[ "$rc" = 0 ] && [ "$(calls)" = 1 ] && [ "$(repo_of np.timer no-project)" = example-org/team-config ] && [[ $d == *"X-Project="* ]] && [[ $d == *"Fix: "*"sala job set-project np <scope/project>"* ]] \
    && ok "check --post: the no-project gap opens one item with the fix in its detail" || bad "no-project post (exit $rc, $(calls) calls): $out / $d"
# set-project: inserted after X-Model-Lane=, the rest of the file as it was, daemon-reload, the commit steps
: > "$T/ctl.log"
out=$(penv $S job set-project np projects/example 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(sed -n '3,4p' "$NPS")" = $'X-Model-Lane=none\nX-Project=projects/example' ] && [ "$(grep -c '^X-Project=' "$NPS")" = 1 ] && [ -z "$(diff <(grep -v '^X-Project=' "$NPS") "$T/np.service.orig")" ] \
    && grep -qx -- '--user daemon-reload' "$T/ctl.log" && case "$out" in *"git -C $T/hub add -- units/np/systemd/np.service"*"pull --rebase --autostash"*) true;; *) false;; esac \
    && ok "set-project: X-Project= added right after X-Model-Lane=, the rest of the file untouched, daemon-reload, the git steps printed" || bad "set-project (exit $rc): $out; $(cat "$NPS")"
out=$(penv $S job check 2>&1); rc=$?
[ "$rc" = 0 ] && ok "check: the gap is gone once the project is set" || bad "np.timer still has a gap (exit $rc): $out"
out=$(penv $S job set-project np projects/example 2>&1); rc=$?
[ "$rc" = 0 ] && case "$out" in *"already has X-Project=projects/example"*) true;; *) false;; esac && ok "set-project twice with the same value: nothing to do" || bad "set-project again (exit $rc): $out"
out=$(penv $S job set-project np projects/board 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(grep -c '^X-Project=' "$NPS")" = 1 ] && grep -qx 'X-Project=projects/board' "$NPS" && ok "set-project with another value replaces the line (still one)" || bad "set-project replace (exit $rc): $out; $(cat "$NPS")"
out=$(penv $S job set-project np projects/example --quiet 2>&1); rc=$?
[ "$rc" = 0 ] && grep -qx 'X-Project=projects/example' "$NPS" && case "$out" in *"git -C"*) false;; *"set X-Project=projects/example in "*) true;; *) false;; esac && ok "set-project --quiet: changes the file, prints no git steps" || bad "set-project --quiet (exit $rc): $out"
# refusals: nothing changes
out=$(penv $S job set-project np Bad 2>&1); rc=$?
[ "$rc" = 2 ] && case "$out" in *"not scope/project"*) true;; *) false;; esac && grep -qx 'X-Project=projects/example' "$NPS" && ok "set-project refuses a project that is not scope/project" || bad "set-project bad project (exit $rc): $out"
out=$(penv $S job set-project nothere projects/example 2>&1); rc=$?
[ "$rc" = 1 ] && case "$out" in *"no job 'nothere'"*) true;; *) false;; esac && ok "set-project refuses a job that does not exist" || bad "set-project unknown job (exit $rc): $out"
NOPROJ=1 unit "$PU" plainj 'Description=a copy'; cp "$PU/plainj.service" "$T/plainj.orig"
out=$(penv $S job set-project plainj projects/example 2>&1); rc=$?
[ "$rc" = 1 ] && case "$out" in *"put it in git first"*) true;; *) false;; esac && cmp -s "$PU/plainj.service" "$T/plainj.orig" && ok "set-project refuses a unit that is not a link into git (a plain copy), writes nothing" || bad "set-project plain copy (exit $rc): $out"
printf '# Rendered by install.sh from units/rr.service.in — edit the template, not this file.\n[Unit]\nDescription=rr\n[Service]\nExecStart=%s\n' "$SCRIPT" > "$PU/rr.service"; cp "$PU/rr.service" "$T/rr.orig"
out=$(penv $S job set-project rr projects/example 2>&1); rc=$?
[ "$rc" = 1 ] && cmp -s "$PU/rr.service" "$T/rr.orig" && ok "set-project refuses a unit rendered from a template" || bad "set-project rendered (exit $rc): $out"
# a flow-pr repo: only through a worktree, the production checkout never edited
SCRIPT=$T/sal/bin/tool.sh; mkdir -p "$T/sal/systemd" "$T/sal-wt/systemd"; NOPROJ=1 unit "$T/sal/systemd" salx 'Description=sal job' 'X-Model-Lane=none'
cp "$T/sal/systemd/salx.service" "$T/sal/systemd/salx.timer" "$T/sal-wt/systemd/"
ln -sf "$T/sal/systemd/salx.service" "$PU/salx.service"; ln -sf "$T/sal/systemd/salx.timer" "$PU/salx.timer"
out=$(penv $S job set-project salx projects/demo 2>&1); rc=$?
[ "$rc" = 2 ] && case "$out" in *"--checkout"*) true;; *) false;; esac && ! grep -q '^X-Project=' "$T/sal/systemd/salx.service" && ok "set-project on a pr repo's job needs --checkout" || bad "set-project pr without checkout (exit $rc): $out"
out=$(penv $S job set-project salx projects/demo --checkout "$T/sal" 2>&1); rc=$?
[ "$rc" = 2 ] && ! grep -q '^X-Project=' "$T/sal/systemd/salx.service" && ok "set-project refuses the production checkout as --checkout" || bad "set-project pr on production (exit $rc): $out"
out=$(penv $S job set-project salx projects/demo --checkout "$T/sal-wt" 2>&1); rc=$?
[ "$rc" = 0 ] && grep -qx 'X-Project=projects/demo' "$T/sal-wt/systemd/salx.service" && ! grep -q '^X-Project=' "$T/sal/systemd/salx.service" && case "$out" in *"gh pr create"*) true;; *) false;; esac \
    && ok "set-project on a pr repo: the worktree's copy is edited, the production checkout is not, the pull request steps are printed" || bad "set-project pr (exit $rc): $out"
# a system-scope job whose unit file links to its git file: edited the same way, no systemctl call
SCRIPT=$T/hub/scripts/job.sh; SPD=$T/hub/units/sysp; mkdir -p "$SPD"; NOPROJ=1 unit "$SPD" sysp 'Description=sys' 'X-Model-Lane=none'
ln -s "$SPD/sysp.service" "$PS/sysp.service"; ln -s "$SPD/sysp.timer" "$PS/sysp.timer"; : > "$T/ctl.log"
out=$(penv $S job set-project sysp projects/example 2>&1); rc=$?
[ "$rc" = 0 ] && grep -qx 'X-Project=projects/example' "$SPD/sysp.service" && [ ! -s "$T/ctl.log" ] && ok "set-project on a system-scope job: the git file edited, no systemctl call (no root)" || bad "set-project system (exit $rc): $out; ctl: $(cat "$T/ctl.log")"
# with_project itself
wp=$(PYTHONDONTWRITEBYTECODE=1 python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import unitjob as u
a = u.with_project("[Unit]\nDescription=d\nX-Model-Lane=subscription-1\n[Service]\nExecStart=/x\n", "a/b")
b = u.with_project(a, "c/d")
c = u.with_project("[Unit]\nDescription=d\n\n[Service]\nExecStart=/x\n", "a/b")
d = u.with_project("[Service]\nExecStart=/x\n", "a/b")
e = u.with_project("[Unit]\n[Service]\n", "a/b")
print(a.split("\n")[3], b.count("X-Project="), b.split("\n")[3], c.split("\n")[2], d, e.split("\n")[1], a.endswith("ExecStart=/x\n"))' "$ROOT/lib")
[ "$wp" = "X-Project=a/b 1 X-Project=c/d X-Project=a/b None X-Project=a/b True" ] && ok "with_project: after X-Model-Lane=, else after Description=, else at the end of [Unit]; replaces a line; no [Unit] = None; the rest kept" || bad "with_project: $wp"
# the backfill script (contrib/backfill-job-projects.sh): its own folders, a few of the listed names present, all the others missing
BU=$T/bu; BS=$T/bs; mkdir -p "$BU" "$BS" "$T/hub/units/demo-sync-a" "$T/hub/units/demo-state-copy"; SCRIPT=$T/hub/scripts/job.sh
NOPROJ=1 unit "$T/hub/units/demo-sync-a" demo-sync-a 'Description=dream' 'X-Model-Lane=bedrock'
ln -s "$T/hub/units/demo-sync-a/demo-sync-a.service" "$BU/demo-sync-a.service"; ln -s "$T/hub/units/demo-sync-a/demo-sync-a.timer" "$BU/demo-sync-a.timer"
NOPROJ=1 unit "$T/hub/units/demo-state-copy" demo-state-copy 'Description=backup'     # a system-scope job in the map's terms (here: in the system folder)
ln -s "$T/hub/units/demo-state-copy/demo-state-copy.service" "$BS/demo-state-copy.service"; ln -s "$T/hub/units/demo-state-copy/demo-state-copy.timer" "$BS/demo-state-copy.timer"
unit "$T/sal/systemd" sala-watch 'Description=watch' 'X-Model-Lane=none' 'X-Project=sala/salamander'; sed -i '/^X-Project=projects\/general$/d' "$T/sal/systemd/sala-watch.service"
ln -s "$T/sal/systemd/sala-watch.service" "$BU/sala-watch.service"; ln -s "$T/sal/systemd/sala-watch.timer" "$BU/sala-watch.timer"
printf '# Rendered by install.sh from units/demo-render.service.in — edit the template.\n[Unit]\nDescription=audit\n[Service]\nExecStart=/bin/true\n' > "$BU/demo-render.service"
NOPROJ=1 unit "$BU" demo-sweeper 'Description=a plain copy'
# the box's map (made-up projects and jobs): three of its jobs are not on this box
printf '%s\n' '# made-up map' 'sala/salamander: sala-watch demo-missing-a' 'team/demo: demo-sync-a demo-missing-b' 'team/audit: demo-render' \
    'team/example: demo-state-copy demo-sweeper demo-missing-c' 'rendered: demo-render' > "$T/bf.map"
bf() { SALA_BACKFILL_MAP=${SALA_BACKFILL_MAP-$T/bf.map} SALA_JOB_USER_DIR=$BU SALA_JOB_SYSTEM_DIR=$BS SALA_BACKFILL_SALAMANDER="$ROOT/bin/salamander" bash "$ROOT/contrib/backfill-job-projects.sh" "$@"; }
cp "$T/hub/units/demo-sync-a/demo-sync-a.service" "$T/gd.orig"
out=$(bf --dry-run 2>&1); rc=$?
[ "$rc" = 1 ] && cmp -s "$T/hub/units/demo-sync-a/demo-sync-a.service" "$T/gd.orig" \
    && case "$out" in *"would set demo-sync-a: X-Project=team/demo"*"would set demo-sweeper: X-Project=team/example"*) true;; *) false;; esac \
    && case "$out" in *"already   sala-watch: X-Project=sala/salamander"*"skipped   demo-render"*"missing   demo-missing-c"*"3 would be set, 1 already set, 1 skipped, 3 missing, 0 failed"*) true;; *) false;; esac \
    && ok "backfill --dry-run: says what it would set (a job of another repo, the system one, the plain copy), what is already set, skipped (rendered) and missing; changes nothing" || bad "backfill dry run (exit $rc): $out"
out=$(bf 2>&1); rc=$?
[ "$rc" = 1 ] && grep -qx 'X-Project=team/demo' "$T/hub/units/demo-sync-a/demo-sync-a.service" && grep -qx 'X-Project=team/example' "$T/hub/units/demo-state-copy/demo-state-copy.service" \
    && case "$out" in *"set       demo-sync-a: X-Project=team/demo"*"set       demo-state-copy: X-Project=team/example"*"FAILED    demo-sweeper:"*"put it in git first"*"2 set, 1 already set, 1 skipped, 3 missing, 1 failed"*) true;; *) false;; esac \
    && case "$out" in *"git -C $T/hub add -- "*"units/demo-sync-a/demo-sync-a.service"*"units/demo-state-copy/demo-state-copy.service"*"git -C $T/hub commit -m "*"git -C $T/hub pull --rebase --autostash"*) true;; *) false;; esac \
    && ok "backfill: the listed jobs get their project (team/demo, team/example), a plain copy is reported FAILED, one set of commit steps for the repo" || bad "backfill (exit $rc): $out"
out=$(bf 2>&1)
case "$out" in *"0 set, 3 already set, 1 skipped, 3 missing, 1 failed"*) ok "backfill again: nothing rewritten (3 already set)" ;; *) bad "backfill again: $out" ;; esac
out=$(bf --bogus 2>&1); rc=$?
[ "$rc" = 2 ] && ok "backfill: an unknown argument is refused" || bad "backfill --bogus (exit $rc): $out"
# no map: nothing to do; a map that names a job twice or has a bad line is refused before anything is done
out=$(SALA_BACKFILL_MAP= SALA_CONFIG=/dev/null bf 2>&1); rc=$?
[ "$rc" = 0 ] && case "$out" in *"no map (SALA_BACKFILL_MAP is not set): nothing to do"*) true;; *) false;; esac && ok "backfill without a map: nothing to do, exit 0" || bad "backfill no map (exit $rc): $out"
printf 'team/demo: demo-sync-a\nteam/example: demo-sync-a\n' > "$T/bf-dup.map"
out=$(SALA_BACKFILL_MAP="$T/bf-dup.map" bf 2>&1); rc=$?
[ "$rc" = 2 ] && case "$out" in *"a job is named twice"*"demo-sync-a"*) true;; *) false;; esac && ok "backfill: a map that names a job twice is refused" || bad "backfill dup map (exit $rc): $out"
printf 'Not A Project: demo-sync-a\n' > "$T/bf-bad.map"
out=$(SALA_BACKFILL_MAP="$T/bf-bad.map" bf 2>&1); rc=$?
[ "$rc" = 2 ] && ok "backfill: a map line that is not scope/project is refused" || bad "backfill bad map (exit $rc): $out"
printf 'SALA_BACKFILL_MAP=%s   # from the config\n' "$T/bf.map" > "$T/bf.config"
out=$(env -u SALA_BACKFILL_MAP SALA_CONFIG="$T/bf.config" SALA_JOB_USER_DIR=$BU SALA_JOB_SYSTEM_DIR=$BS SALA_BACKFILL_SALAMANDER="$ROOT/bin/salamander" bash "$ROOT/contrib/backfill-job-projects.sh" --dry-run 2>&1)
case "$out" in *"3 already set, 1 skipped, 3 missing"*) ok "backfill: the map comes from the sala config's SALA_BACKFILL_MAP line when the environment has none";; *) bad "backfill map from the config: $out";; esac

# ---- the sala-watch tick -----------------------------------------------------------------------------------------------------------
rm -f "$T/state/salamander/unit-gaps.tsv" "$T/client.items"; : > "$T/client.log"
SALA_UNIT_GAPS=off $S watch --unit-gaps > /dev/null 2>&1
[ ! -s "$T/client.log" ] && ok "watch --unit-gaps with SALA_UNIT_GAPS=off posts nothing" || bad "the off switch did not hold"
SALA_UNIT_GAPS=on $S watch --unit-gaps > /dev/null 2>&1
[ "$(calls)" = 3 ] && grep -q 'unit-gaps: opened ' "$SALA_LOG_DIR/salamander-watch.log" && ok "watch --unit-gaps: the same pass, its lines in the watch log" || bad "watch tick: $(calls) calls; log: $(tail -3 "$SALA_LOG_DIR/salamander-watch.log" 2>/dev/null)"

# ---- the tracked repo table (lib/unit-repos.tsv) is neutral; the user's table replaces it; no github = no post -----------------------------------
rows=$(awk -F'\t' '/^#/ || NF == 0 {next} {n++} END {print n + 0}' "$ROOT/lib/unit-repos.tsv")
[ "$rows" = 0 ] && ok "lib/unit-repos.tsv lists no repo (a neutral default)" || bad "lib/unit-repos.tsv has $rows data row(s)"
mkdir -p "$T/xdg/salamander"; printf 'mine\t-\t-\t-\tpr\tp/mine\tmb\tn\talice/mine\n' > "$T/xdg/salamander/unit-repos.tsv"
got=$(env -u SALA_JOB_REPOS XDG_CONFIG_HOME=$T/xdg PYTHONDONTWRITEBYTECODE=1 python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import unitjob
print(",".join(unitjob.load_repos()))' "$ROOT/lib"); none=$(env -u SALA_JOB_REPOS XDG_CONFIG_HOME=$T/none PYTHONDONTWRITEBYTECODE=1 python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import unitjob
print(len(unitjob.load_repos()))' "$ROOT/lib")
[ "$got" = mine ] && [ "$none" = 0 ] && ok "~/.config/salamander/unit-repos.tsv replaces the tracked table (and with none, the table is empty)" || bad "user table: got=$got none=$none"
printf 'hub\t%s\t-\t-\tpr\tp/hub\thb\tn\n' "$T/hub" > "$T/repos-nogh.tsv"
: > "$T/client.log"; rm -f "$T/client.items" "$T/client.fail" "$T/state/salamander/unit-gaps.tsv"
out=$(env -u SALA_JOB_GITHUB SALA_JOB_REPOS=$T/repos-nogh.tsv $S job check --post 2>&1); rc=$?
[ "$rc" = 0 ] && [ ! -s "$T/client.log" ] && case "$out" in *"not posted: no GitHub owner/name"*"SALA_JOB_GITHUB"*) true;; *) false;; esac \
    && ok "check --post with no GitHub owner/name for a gap posts nothing and says what is unset" || bad "no github: exit $rc, calls $(calls): $out"
: > "$T/client.log"; rm -f "$T/client.items" "$T/client.fail" "$T/state/salamander/unit-gaps.tsv"

# ---- the units ---------------------------------------------------------------------------------------------------------------------
grep -q '^PathChanged=%h/.config/systemd/user$' "$ROOT/systemd/sala-unit-gaps.path" && grep -q '^PathChanged=/etc/systemd/system$' "$ROOT/systemd/sala-unit-gaps.path" && grep -q '^Unit=sala-unit-gaps.service$' "$ROOT/systemd/sala-unit-gaps.path" \
    && grep -q '^ExecStart=%h/.local/bin/salamander job check --post --quiet$' "$ROOT/systemd/sala-unit-gaps.service" && ok "sala-unit-gaps.path watches both unit folders and starts the check" || bad "the path unit or its service changed shape"
# the burst guard (the path unit once hit its start limit and stayed failed): the service debounces, the limit tolerates a burst
lim=$(awk -F= '$1 == "TriggerLimitBurst" {print $2}' "$ROOT/systemd/sala-unit-gaps.path"); ivl=$(awk -F= '$1 == "TriggerLimitIntervalSec" {print $2}' "$ROOT/systemd/sala-unit-gaps.path")
grep -q '^ExecStartPre=/bin/sleep [1-9][0-9]*$' "$ROOT/systemd/sala-unit-gaps.service" && [ "${ivl%s}" -ge 60 ] 2>/dev/null && [ "${lim:-0}" -ge 20 ] \
    && ok "sala-unit-gaps: the service waits before it checks (debounce) and the path unit allows $lim starts in $ivl" || bad "sala-unit-gaps burst guard: sleep line missing or limit ($lim in $ivl) too low"
echo "jobs: $([ $fail = 0 ] && echo pass || echo FAIL)"
exit $fail
