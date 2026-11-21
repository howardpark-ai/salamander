#!/usr/bin/env bash
# tests/bgagents.sh — `sala bg-agents` (lib/bgagents.sh, lib/bgagents.py, docs/bg-agents.md): the fleet job that lists and starts a project's background
# engineer agent when stackshot's want list names the project. Everything runs in one temporary tree (locked while the suite runs, removed at its end):
# a fake want list, a fake listing call, a fake spawn, a fake liveness check, a fake load average and a fake clock (SALA_BGAGENTS_NOW). Nothing reaches
# stackshot, no session is started, no tmux, no process is signalled.
#   off       the switch unset or off: one line, nothing read or written (the list command is never called); --status still reads the ledger
#   list      an empty list, a failed read (the ledger untouched, no failure counted), a client-less box, a malformed line
#   one       one project: the listing call and the start with their exact arguments, the ledger (attempts, created, started, mode 600), the log
#   many      two projects: one agent a run; the second gets its turn on the next run
#   load      at and above SALA_BGAGENTS_MAX_LOAD (a skip, nothing counted, no ledger), just under it (runs), an unreadable load
#   backoff   a failure waits 10 min, doubling per failure, up to the cap; no call while it waits
#   max       the maximum attempts: given up, left alone, shown in the status
#   failures  an HTTP 409 and a 403 on the listing, a project listed again after created-and-retired, still listed after a started pane (no retire, no second start)
#   reset     the ledger entry goes only after the project has been off the list for the cooldown (and not before; a return clears the mark)
#   retire    the marked step: an agent this job listed whose start failed says `retire needed: NAME` and the run exits 1; nothing is ever taken off a project
#             (no call but the listing); never for an agent the job did not list, a 409 or a load skip; the next try finds the entry and does not list it twice
#   onmap     an agent already on the project record: no second listing, straight to the start
#   record    a start that stackshot's record has not caught up with is waited out (no failure) and finished from the ledger when the project has left the list
#   dry       --dry-run decides and writes, lists and starts nothing
#   status    the ledger, one line a project, times in SALA_TZ
#   ledger    mode 600, a crash between the temporary file and the rename leaves the old whole file, a crash mid-attempt leaves the attempt counted
#   mandate   the default line (the owner's name from SALA_OWNER_NAME), an override, a bad override refused
# Usage: bash tests/bgagents.sh   (exit 0 = pass; a few seconds)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
. "$ROOT/tests/lib.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/sala-bgagents.XXXXXX")
exec 8< "$T"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
trap 'exec 8<&-; rm -rf "$T"' EXIT
export HOME=$T/home SALA_CONFIG=/dev/null XDG_STATE_HOME=$T/state SALA_STATE_DIR=$T/state/salamander SALA_TZ=Asia/Seoul SALA_OWNER_NAME=Pat
mkdir -p "$HOME" "$T/bin" "$SALA_STATE_DIR"
L=$SALA_STATE_DIR/bgagents.json
KEY=projects/example; NAME=example-engineer; KEY2=projects/second; NAME2=second-engineer
N0=1800000000   # the fake clock: Fri Jan 15th 2027, 08:00 UTC
MAND='Handles outside events (mail, Slack, GitHub) for this project and builds what needs no decision of Pat, so the front agent serves only Pat'

# -- the fakes --------------------------------------------------------------------------------------------------------------------------------
# list: prints $T/list.txt, exit $T/list.rc. post: logs its arguments; $T/post.mode = ok | same | 409 | 403 | slow. spawn: logs its arguments; $T/spawn.mode =
# ok | dead (exit 0, never live) | fail (exit 1) | norecord (exit 3). alive: live when the name is a line of $T/alive.txt.
cat > "$T/bin/list" <<'EOF'
#!/usr/bin/env bash
echo x >> "$T/list.calls"
[ -f "$T/list.txt" ] && cat "$T/list.txt"
exit "$(cat "$T/list.rc" 2>/dev/null || echo 0)"
EOF
cat > "$T/bin/post" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$T/post.log"
case "$(cat "$T/post.mode" 2>/dev/null || echo ok)" in
    ok) echo '{"project": "prj_1", "agent": {}, "note": "listed"}'; exit 0 ;;
    same) echo '{"project": "prj_1", "note": "example-engineer is already listed on projects/example: nothing changed"}'; exit 0 ;;
    409) echo "[409] example-engineer is already listed on the project as front (engineer): 'x'" >&2; exit 1 ;;
    403) echo "[403] refused: the project is hidden: list it first with post project-list" >&2; exit 1 ;;
esac
EOF
cat > "$T/bin/spawn" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$T/spawn.log"
case "$(cat "$T/spawn.mode" 2>/dev/null || echo ok)" in
    ok) printf '%s\n' "$1" >> "$T/alive.txt"; exit 0 ;;
    dead) exit 0 ;;
    fail) echo "claude did not start in $1:0 within 45s" >&2; exit 1 ;;
    norecord) echo "not on the agents map" >&2; exit 3 ;;
esac
EOF
cat > "$T/bin/alive" <<'EOF'
#!/usr/bin/env bash
grep -qx -- "$1" "$T/alive.txt" 2>/dev/null
EOF
chmod +x "$T/bin"/*
export T
export SALA_BGAGENTS_LIST_CMD=$T/bin/list SALA_BGAGENTS_POST_CMD=$T/bin/post SALA_BGAGENTS_SPAWN_CMD=$T/bin/spawn SALA_BGAGENTS_ALIVE_CMD=$T/bin/alive
export SALA_BGAGENTS_LOADAVG=$T/loadavg SALA_BGAGENTS_ALIVE_WAIT=0 SALA_PROJECT_RECORD=$T/projects.json SALA_BGAGENTS_NOW=$N0
export SALA_BGAGENTS_MAX_ATTEMPTS=5 SALA_BGAGENTS_COOLDOWN=600 SALA_BGAGENTS_COOLDOWN_MAX=86400 SALA_BGAGENTS_MAX_LOAD=10 SALA_BGAGENTS_RECORD_GRACE=900
unset SALA_BGAGENTS SALA_BGAGENTS_MANDATE SALA_BGAGENTS_SENDER SALA_BGAGENTS_LEDGER

S="bash $ROOT/bin/salamander bg-agents"
OUT=""; RC=0
run() {   # [args] → OUT (stdout+stderr), RC; the clock is $NOW (default N0)
    OUT=$(SALA_BGAGENTS_NOW=${NOW:-$N0} $S "$@" 2>&1); RC=$?
}
reset() {   # a clean slate: no ledger, no call logs, a quiet load, an empty list, nothing alive, no project record
    rm -rf "$SALA_STATE_DIR" "$T/list.txt" "$T/list.rc" "$T/list.calls" "$T/post.log" "$T/post.mode" "$T/spawn.log" "$T/spawn.mode" "$T/alive.txt" "$T/projects.json"
    mkdir -p "$SALA_STATE_DIR"; echo "0.50 0.40 0.30 1/200 12345" > "$T/loadavg"; NOW=$N0
    export SALA_BGAGENTS=on
}
calls() { [ -f "$1" ] && wc -l < "$1" || echo 0; }
led() {   # <key> <field> → the ledger's value (empty when there is none)
    python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))["projects"][sys.argv[2]][sys.argv[3]]
    print(json.dumps(d) if isinstance(d,(dict,list)) else d)
except Exception: pass' "$L" "$1" "$2"
}
has_entry() { python3 -c 'import json,sys; sys.exit(0 if sys.argv[2] in json.load(open(sys.argv[1]))["projects"] else 1)' "$L" "$1" 2>/dev/null; }
record() {   # <key> <agent…> → a fresh project record (written at the fake clock) that lists those agents on the key
    python3 - "$T/projects.json" "$NOW" "$@" <<'PY'
import datetime, json, sys
path, now, key, *agents = sys.argv[1:]
gen = datetime.datetime.fromtimestamp(float(now), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"schema": 1, "generated": gen, "projects": {"prj_1": {"id": "prj_1", "key": key, "agents": {a: {"front": False, "role": "engineer", "mandate_line": "x"} for a in agents}}}, "by_key": {key: "prj_1"}}, open(path, "w"))
PY
}
printf '%s\n' "$KEY $(echo "${NAME%-engineer}") example-main" > "$T/list.txt"

# -- off ------------------------------------------------------------------------------------------------------------------------------------
reset; unset SALA_BGAGENTS; printf '%s\n' "$KEY example example-main" > "$T/list.txt"
run; [ "$RC" = 0 ] && [ "$(printf '%s\n' "$OUT" | wc -l)" = 1 ] && [[ $OUT == *"is off"* ]] && ok "off (unset): one line, exit 0" || bad "off unset: rc=$RC [$OUT]"
[ "$(calls "$T/list.calls")" = 0 ] && [ ! -e "$L" ] && [ ! -e "$SALA_STATE_DIR/bgagents.log" ] && [ ! -e "$L.lock" ] && ok "off: the list is never read, no ledger, no log, no lock" || bad "off touched something"
export SALA_BGAGENTS=off; run; [ "$RC" = 0 ] && [[ $OUT == *"is off"* ]] && [ "$(calls "$T/post.log")" = 0 ] && ok "off (explicit): the same" || bad "off explicit: rc=$RC [$OUT]"
export SALA_BGAGENTS=ON; run; [[ $OUT == *"is live"* ]] && ok "the switch reads on in any case" || bad "ON: [$OUT]"
export SALA_BGAGENTS=off; run --dry-run; [[ $OUT == *"is off"* ]] && [ "$(calls "$T/list.calls")" = 1 ] && ok "off: --dry-run is a run too (one line, the list not read again)" || bad "off dry-run: [$OUT]"
run --status; [[ $OUT == *"attempts 1/5"* ]] && ok "off: --status still shows the ledger (read-only)" || bad "off status: [$OUT]"

# -- list -----------------------------------------------------------------------------------------------------------------------------------
reset; : > "$T/list.txt"
run; [ "$RC" = 0 ] && [[ $OUT == *"nobody"* ]] && [ "$(calls "$T/post.log")" = 0 ] && [ ! -e "$L" ] && ok "an empty list: nothing posted, no ledger" || bad "empty list: rc=$RC [$OUT]"
printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo 1 > "$T/list.rc"
run; [ "$RC" = 0 ] && [[ $OUT == *"not read"* ]] && [ "$(calls "$T/post.log")" = 0 ] && [ ! -e "$L" ] && ok "a failed list read: one line, exit 0, nothing started, no ledger made" || bad "failed read: rc=$RC [$OUT]"
echo 0 > "$T/list.rc"; run >/dev/null; sum=$(cksum < "$L"); echo 1 > "$T/list.rc"; NOW=$((N0+5000)) run
[ "$RC" = 0 ] && [ "$(cksum < "$L")" = "$sum" ] && [ "$(led $KEY failures)" = 0 ] && ok "a failed read leaves an existing ledger byte for byte as it was and counts no failure" || bad "failed read changed the ledger"
echo 0 > "$T/list.rc"
( export SALA_BGAGENTS_LIST_CMD=; run; [ "$RC" = 0 ] && [[ $OUT == *"no stackshot client"* ]] && echo yes ) > "$T/o" 2>&1; NOW=$N0
# the subshell lost OUT/RC: run again in this shell
export SALA_BGAGENTS_LIST_CMD=; run; [ "$RC" = 0 ] && [[ $OUT == *"no stackshot client"* ]] && ok "no client on the box: said, exit 0" || bad "no client: rc=$RC [$OUT]"
export SALA_BGAGENTS_LIST_CMD=$T/bin/list
reset; printf 'garbage\nprojects/Upper x y\n%s example example-main\n' "$KEY" > "$T/list.txt"
run; [ "$RC" = 0 ] && [ "$(grep -c 'not <project key>' <<<"$OUT")" = 2 ] && [ "$(calls "$T/post.log")" = 1 ] && ok "a malformed line is said and ignored; the good line is served" || bad "malformed: rc=$RC [$OUT]"

# -- one project ----------------------------------------------------------------------------------------------------------------------------
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"
run
[ "$RC" = 0 ] && ok "one project: exit 0" || bad "one: rc=$RC [$OUT]"
[ "$(cat "$T/post.log")" = "$KEY $NAME --role engineer --back --mandate $MAND --sender sala-web" ] && ok "the listing call: key, name, role engineer, --back, the mandate line, the form's label" || bad "post args: [$(cat "$T/post.log" 2>/dev/null)]"
[ "$(cat "$T/spawn.log")" = "$NAME --project $KEY --role back --mandate $MAND" ] && ok "the start: sala spawn NAME --project KEY --role back --mandate LINE" || bad "spawn args: [$(cat "$T/spawn.log" 2>/dev/null)]"
[ "$(led $KEY attempts)" = 1 ] && [ "$(led $KEY created)" = True ] && [ "$(led $KEY agent)" = "$NAME" ] && [ "$(led $KEY started_at)" = "$N0" ] && [ "$(led $KEY last)" = started ] && [ "$(led $KEY failures)" = 0 ] && ok "the ledger: attempt 1, created by this job, started, no failure" || bad "ledger: $(cat "$L")"
[ "$(stat -c %a "$L")" = 600 ] && ok "the ledger is mode 600" || bad "ledger mode $(stat -c %a "$L")"
[ "$(wc -l < "$SALA_STATE_DIR/bgagents.log")" -ge 2 ] && grep -q ' start ' "$SALA_STATE_DIR/bgagents.log" && ok "the log has a line per decision" || bad "log: $(cat "$SALA_STATE_DIR/bgagents.log")"
grep -qiE 'token|secret|bearer' <<<"$OUT$(cat "$SALA_STATE_DIR/bgagents.log")" && bad "a log line mentions a token" || ok "no token or secret word in the output or the log"
ls -A "$SALA_STATE_DIR" | grep -q '^\.bgagents\..*\.tmp$' && bad "a temporary file was left" || ok "no temporary file left behind"

# -- many projects: one a run --------------------------------------------------------------------------------------------------------------
reset; printf '%s\n%s\n' "$KEY example example-main" "$KEY2 second second-main" > "$T/list.txt"
run
[ "$(calls "$T/post.log")" = 1 ] && [ "$(calls "$T/spawn.log")" = 1 ] && grep -q "^$KEY " "$T/post.log" && ! has_entry $KEY2 && ok "two projects: only the first (list order) is taken in a run, the second untouched" || bad "two: post=[$(cat "$T/post.log")] $(cat "$L")"
NOW=$((N0+60)) run
[ "$(calls "$T/post.log")" = 2 ] && grep -q "^$KEY2 $NAME2 " "$T/post.log" && [ "$(led $KEY2 attempts)" = 1 ] && [ "$(led $KEY attempts)" = 1 ] && ok "the next run takes the second (the first, started, only waits)" || bad "two, run 2: post=[$(cat "$T/post.log")]"

# -- load ---------------------------------------------------------------------------------------------------------------------------------
for ld in 10.00 10.01 25.30; do
    reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo "$ld 9.00 8.00 3/400 99" > "$T/loadavg"
    run; [ "$RC" = 0 ] && [[ $OUT == *"load $ld"* || $OUT == *"load ${ld%.*}."* ]] && [ "$(calls "$T/post.log")" = 0 ] && [ ! -e "$L" ] && ok "load $ld: skipped with one line, nothing listed, no ledger, no failure" || bad "load $ld: rc=$RC [$OUT]"
done
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo "9.99 1 1 1/1 1" > "$T/loadavg"
run; [ "$(calls "$T/post.log")" = 1 ] && ok "load 9.99 (under 10): the run goes on" || bad "load 9.99: [$OUT]"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo "50.0 1 1 1/1 1" > "$T/loadavg"; echo fail > "$T/spawn.mode"
run; NOW=$((N0+100)) run; [ "$(calls "$T/post.log")" = 0 ] && [ ! -e "$L" ] && ok "a high load skips again and again without a ledger or a failure" || bad "repeated load skip"
echo 5 > "$T/loadavg"; NOW=$((N0+200)) run; [ "$(led $KEY attempts)" = 1 ] && ok "when the load drops the project is taken at attempt 1" || bad "after the load drop: $(cat "$L" 2>/dev/null)"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; rm -f "$T/loadavg"
run; [ "$RC" = 0 ] && [[ $OUT == *"load average could not be read"* ]] && [ "$(calls "$T/post.log")" = 0 ] && ok "an unreadable load average: a skip, never a guess" || bad "no loadavg: [$OUT]"

# -- back-off ---------------------------------------------------------------------------------------------------------------------------------
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo 409 > "$T/post.mode"; export SALA_BGAGENTS_MAX_ATTEMPTS=20 SALA_BGAGENTS_COOLDOWN_MAX=2500
t=$N0; want=(600 1200 2400 2500 2500)
for i in 0 1 2 3 4; do
    NOW=$t run
    f=$((i+1)); nt=$(led $KEY next_try)
    [ "$(led $KEY failures)" = "$f" ] && [ "$nt" = "$((t + ${want[$i]}))" ] && ok "failure $f: waits ${want[$i]} s (10 min, doubling, capped at 2500 here)" || bad "failure $f: next_try=$nt (want $((t + ${want[$i]}))) $(cat "$L")"
    NOW=$((t+${want[$i]}-1)) run; [ "$(calls "$T/post.log")" = "$f" ] && [[ $OUT == *"backing off"* ]] || bad "a call was made while backing off (failure $f): [$OUT]"
    t=$((t + ${want[$i]}))
done
ok "no listing call while a project waits (checked after every failure)"
export SALA_BGAGENTS_COOLDOWN_MAX=86400
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo 409 > "$T/post.mode"; t=$N0
for i in $(seq 1 12); do NOW=$t run; t=$(($(led $KEY next_try))); done
[ "$(( $(led $KEY next_try) - $(led $KEY last_at) ))" = 86400 ] && ok "the default cap is 24 hours" || bad "cap: $(( $(led $KEY next_try) - $(led $KEY last_at) ))"
export SALA_BGAGENTS_MAX_ATTEMPTS=5

# -- max attempts ------------------------------------------------------------------------------------------------------------------------------
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo 409 > "$T/post.mode"; export SALA_BGAGENTS_MAX_ATTEMPTS=3; t=$N0
for i in 1 2 3; do NOW=$t run; t=$((t + 100000)); done
[ "$(led $KEY attempts)" = 3 ] && [[ $OUT == *"given up"* ]] && ok "the third failed attempt says it is given up" || bad "max: [$OUT]"
n=$(calls "$T/post.log"); NOW=$((t + 9999999)) run
[ "$RC" = 0 ] && [ "$(calls "$T/post.log")" = "$n" ] && [ "$(calls "$T/spawn.log")" = 0 ] && [[ $OUT == *"given up after 3 attempts"* ]] && ok "given up: left alone however long it waits (one log line, no call)" || bad "given up still tried: [$OUT]"
run --status; [[ $OUT == *"attempts 3/3"* && $OUT == *"given up"* ]] && ok "the status shows it as given up" || bad "status given up: [$OUT]"
export SALA_BGAGENTS_MAX_ATTEMPTS=5

# -- the failures -------------------------------------------------------------------------------------------------------------------------------
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo 409 > "$T/post.mode"
run; [ "$RC" = 0 ] && [ "$(led $KEY failures)" = 1 ] && [[ $(led $KEY last) == *"HTTP 409"* ]] && [ "$(calls "$T/spawn.log")" = 0 ] && ok "an HTTP 409 on the listing counts as a failure (no start, exit 0)" || bad "409: rc=$RC $(cat "$L")"
[[ $OUT != *"retire needed"* ]] && [ "$(led $KEY created)" = False ] && ok "a 409 is no start failure of an agent this job listed: no retire step" || bad "409 retire"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo 403 > "$T/post.mode"
run; [ "$(led $KEY failures)" = 1 ] && [[ $(led $KEY last) == *"HTTP 403"* && $(led $KEY last) == *"hidden"* ]] && ok "a 403 (a hidden project) counts as a failure and its reason is logged" || bad "403: $(cat "$L")"
# relisted after created and retired
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"
printf '{"schema":1,"projects":{"%s":{"prefix":"example","agent":"%s","attempts":1,"failures":0,"created":true,"retired":true,"posted_at":%s,"started_at":0,"last":"x","last_at":%s}}}\n' "$KEY" "$NAME" "$((N0-9000))" "$((N0-9000))" > "$L"
run; [ "$(led $KEY failures)" = 1 ] && [ "$(led $KEY attempts)" = 2 ] && [ "$(led $KEY retired)" = False ] && [ "$(calls "$T/post.log")" = 0 ] && [[ $OUT == *"created and retired"* ]] && ok "listed again after this job created and retired its agent: a failure, nothing posted this run" || bad "relisted: rc=$RC [$OUT] $(cat "$L")"
NOW=$((N0+601)) run; [ "$(calls "$T/post.log")" = 1 ] && ok "after its back-off the project gets its next attempt" || bad "relisted next attempt"
# still listed after a started pane
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"
run; NOW=$((N0+100)) run
[ "$(led $KEY failures)" = 0 ] && [[ $OUT == *"waiting for the project to leave the list"* ]] && ok "still listed 100 s after the start: only waited for" || bad "still listed early: [$OUT]"
NOW=$((N0+700)) run
[ "$(led $KEY failures)" = 1 ] && [ "$(led $KEY attempts)" = 2 ] && [[ $(led $KEY last) == *"still on the want list"* ]] && ok "still listed after the cooldown: a failure" || bad "still listed late: $(cat "$L")"
[ "$(calls "$T/spawn.log")" = 1 ] && [ "$(calls "$T/post.log")" = 1 ] && grep -qx "$NAME" "$T/alive.txt" && [[ $OUT != *"retire"* ]] && ok "...and the running agent is left running: no second start, no second listing, no retire" || bad "still listed side effects: spawn=$(calls "$T/spawn.log") [$OUT]"
NOW=$((N0+701)) run; [ "$(led $KEY failures)" = 1 ] && ok "the failure is counted once per back-off, not once per run" || bad "counted twice"

# -- reset ---------------------------------------------------------------------------------------------------------------------------------------
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"
run; : > "$T/list.txt"
NOW=$((N0+1000)) run; [ "$(led $KEY absent_since)" = $((N0+1000)) ] && [ "$(led $KEY attempts)" = 1 ] && ok "off the list: absent_since is marked, the entry kept" || bad "absent mark: $(cat "$L")"
NOW=$((N0+1599)) run; has_entry $KEY && ok "absent for 599 s (under the cooldown): the entry stays" || bad "reset early"
printf '%s\n' "$KEY example example-main" > "$T/list.txt"; NOW=$((N0+1599)) run; [ "$(led $KEY absent_since)" = 0 ] && ok "back on the list: the mark is cleared" || bad "mark not cleared: $(cat "$L")"
: > "$T/list.txt"; NOW=$((N0+2000)) run; NOW=$((N0+2599)) run; has_entry $KEY && ok "the clock of the absence starts again from the new mark" || bad "absence clock"
NOW=$((N0+2600)) run; ! has_entry $KEY && ok "absent for the whole cooldown: the entry is cleared (the only reset)" || bad "no reset: $(cat "$L")"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo 409 > "$T/post.mode"; run; : > "$T/list.txt"
NOW=$((N0+700)) run; NOW=$((N0+1300)) run; ! has_entry $KEY && ok "a failed project's entry resets by the same rule (absent for the cooldown), not by waiting" || bad "failed entry reset"

# -- retire: the marked step -------------------------------------------------------------------------------------------------------------------
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo fail > "$T/spawn.mode"
run
[ "$RC" = 1 ] && grep -q "retire needed: $NAME" <<<"$OUT" && ok "a failed start of an agent this job listed: \`retire needed: NAME\` and exit 1" || bad "retire needed: rc=$RC [$OUT]"
[ "$(led $KEY retire_needed)" = True ] && [ "$(led $KEY failures)" = 1 ] && [ "$(led $KEY created)" = True ] && ok "the ledger keeps retire_needed and counts the failure" || bad "retire ledger: $(cat "$L")"
[ "$(calls "$T/post.log")" = 1 ] && ! grep -qi retire "$T/post.log" "$T/spawn.log" && ok "nothing is taken off the project: the only call to stackshot was the listing" || bad "a retire-like call: $(cat "$T/post.log")"
NOW=$((N0+601)) run; [ "$(calls "$T/post.log")" = 1 ] && [ "$(calls "$T/spawn.log")" = 2 ] && [ "$RC" = 1 ] && ok "the next try finds the entry (listed by the ledger): no second listing, the start tried again" || bad "retry after retire: post=$(calls "$T/post.log") spawn=$(calls "$T/spawn.log") rc=$RC [$OUT]"
echo ok > "$T/spawn.mode"; NOW=$((N0+2000)) run; [ "$RC" = 0 ] && [ "$(led $KEY retire_needed)" = False ] && [ "$(led $KEY started_at)" != 0 ] && ok "a start that works clears the mark: nothing left to retire" || bad "retire cleared: rc=$RC $(cat "$L")"
# a spawn that says up but never is live
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo dead > "$T/spawn.mode"
run; [ "$RC" = 1 ] && [[ $OUT == *"did not come up"* && $OUT == *"retire needed: $NAME"* ]] && ok "a pane that spawn reports up but is never live is a failed start too" || bad "dead: rc=$RC [$OUT]"
# not this job's agent: already on the map
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo fail > "$T/spawn.mode"; record "$KEY" "$NAME"
run; [ "$RC" = 0 ] && [[ $OUT != *"retire needed"* && $OUT == *"left as it is"* ]] && [ "$(calls "$T/post.log")" = 0 ] && [ "$(led $KEY created)" = False ] && ok "an agent the job did not list: a failed start counts, but it is never marked for retire" || bad "not own: rc=$RC [$OUT]"
# listed by stackshot's own 'already listed' answer: not created by this job
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo same > "$T/post.mode"; echo fail > "$T/spawn.mode"
run; [ "$RC" = 0 ] && [ "$(led $KEY created)" = False ] && [[ $OUT != *"retire needed"* ]] && ok "stackshot's \"already listed: nothing changed\" is no creation: no retire step" || bad "same: rc=$RC [$OUT]"
# load skip and 409: never
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo 99 > "$T/loadavg"; run; [[ $OUT != *"retire"* ]] && [ "$RC" = 0 ] && ok "a load skip never retires" || bad "load retire"

# -- agent already on the map ------------------------------------------------------------------------------------------------------------------
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; record "$KEY" "$NAME"
run; [ "$(calls "$T/post.log")" = 0 ] && [ "$(calls "$T/spawn.log")" = 1 ] && [[ $OUT == *"already on the project's map"* ]] && [ "$(led $KEY started_at)" = "$N0" ] && ok "the agent is on the project record: no second listing, straight to the start" || bad "onmap: [$OUT]"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; record "$KEY" other-agent
run; [ "$(calls "$T/post.log")" = 1 ] && ok "a fresh record that does not list the name: it is listed" || bad "onmap other"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; record "$KEY" "$NAME"; NOW=$((N0+5000)) run
[ "$(calls "$T/post.log")" = 1 ] && ok "a stale record (older than SALA_PROJECT_RECORD_MAX_AGE) answers nothing: the idempotent listing is made" || bad "stale record"

# -- the record's lag ----------------------------------------------------------------------------------------------------------------------------
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo norecord > "$T/spawn.mode"
run; [ "$RC" = 0 ] && [ "$(led $KEY failures)" = 0 ] && [ "$(led $KEY awaiting_record)" = True ] && [[ $OUT == *"does not show it yet"* ]] && ok "spawn exit 3 right after the listing: waited out, no failure, no retire" || bad "norecord: rc=$RC [$OUT] $(cat "$L")"
: > "$T/list.txt"; echo ok > "$T/spawn.mode"   # stackshot's list drops the project: its agent is on the map
NOW=$((N0+300)) run
[ "$(led $KEY started_at)" = $((N0+300)) ] && [ "$(led $KEY attempts)" = 1 ] && [ "$(calls "$T/post.log")" = 1 ] && [ "$(calls "$T/spawn.log")" = 2 ] && ok "the start is finished from the ledger although the project is off the list (attempts stay 1, no second listing)" || bad "finish: $(cat "$L") post=$(calls "$T/post.log")"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo norecord > "$T/spawn.mode"; run; : > "$T/list.txt"
NOW=$((N0+1000)) run; [ "$RC" = 1 ] && [ "$(led $KEY failures)" = 1 ] && [[ $OUT == *"retire needed"* ]] && ok "the record never caught up (past the grace): a failure and the marked retire" || bad "grace over: rc=$RC [$OUT]"

# -- dry run ---------------------------------------------------------------------------------------------------------------------------------------
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"
run --dry-run
[ "$RC" = 0 ] && [[ $OUT == *"would list $NAME"* && $OUT == *"nothing was posted"* ]] && [ "$(calls "$T/post.log")" = 0 ] && [ "$(calls "$T/spawn.log")" = 0 ] && ok "--dry-run: the decision is said, nothing listed or started" || bad "dry: rc=$RC [$OUT]"
[ ! -e "$L" ] && [ ! -e "$SALA_STATE_DIR/bgagents.log" ] && [ ! -e "$L.lock" ] && ok "--dry-run writes no ledger, no log, no lock" || bad "dry wrote: $(ls -A "$SALA_STATE_DIR")"
run; sum=$(cksum < "$L"); : > "$T/list.txt"; NOW=$((N0+9000)) run --dry-run
[ "$(cksum < "$L")" = "$sum" ] && ok "--dry-run leaves an existing ledger as it was (also what a real run would reset)" || bad "dry changed the ledger"
echo 30 > "$T/loadavg"; printf '%s\n' "$KEY2 second second-main" > "$T/list.txt"; run --dry-run; [[ $OUT == *"load 30.00"* && $OUT == *"nothing attempted"* ]] && ok "--dry-run applies the load check too" || bad "dry load: [$OUT]"
run --dry-run --status; [ "$RC" = 2 ] && ok "--dry-run with --status is a usage error" || bad "dry+status rc=$RC"
run --bogus; [ "$RC" = 2 ] && ok "an unknown option is a usage error (exit 2)" || bad "bogus rc=$RC"

# -- status ---------------------------------------------------------------------------------------------------------------------------------------
reset; run --status; [ "$RC" = 0 ] && [[ $OUT == "the ledger is empty"* ]] && ok "--status of no ledger: one line" || bad "empty status: [$OUT]"
printf '{"schema":1,"projects":{"projects/a-one":{"prefix":"a-one","agent":"a-one-engineer","attempts":2,"failures":2,"next_try":%s,"last":"failed: x","last_at":%s},"projects/b-two":{"prefix":"b-two","agent":"b-two-engineer","attempts":5,"failures":5,"next_try":0},"projects/c-three":{"prefix":"c-three","agent":"c-three-engineer","attempts":1,"failures":0,"started_at":%s,"posted_at":%s,"created":true}}}\n' "$((N0+4000))" "$N0" "$((N0-60))" "$((N0-60))" > "$L"
run --status
[ "$(printf '%s\n' "$OUT" | wc -l)" = 3 ] && ok "--status: one line a project" || bad "status lines: [$OUT]"
grep -q "^projects/a-one  a-one-engineer  attempts 2/5  failures 2  next try Fri Jan 15th 18:06 KST  backing off" <<<"$OUT" && ok "--status: attempts, failures, next try in KST (SALA_TZ), state" || bad "status a: [$OUT]"
grep -q "^projects/b-two .*attempts 5/5 .*given up" <<<"$OUT" && grep -q "^projects/c-three .*next try -  started" <<<"$OUT" && ok "--status: given up, and a started agent waiting for the list" || bad "status b/c: [$OUT]"

# -- the ledger file -----------------------------------------------------------------------------------------------------------------------------
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; run
cp "$L" "$T/before.json"
# a crash between the temporary file and the rename (a forked child dies there) leaves the old whole ledger, then the next save sweeps the leftover
python3 -I - "$ROOT/lib" "$L" <<'PY' || bad "the crash probe itself failed"
import os, sys
sys.path.insert(0, sys.argv[1]); import bgagents
path = sys.argv[2]
pid = os.fork()
if pid == 0:
    led = bgagents.Ledger(path, False)
    led.entry("projects/example")["attempts"] = 99
    os.replace = lambda *a, **k: os._exit(9)      # the process dies after the temporary file is written and fsynced, before the rename
    led.save()
    os._exit(0)
_, st = os.waitpid(pid, 0)
assert os.WEXITSTATUS(st) == 9, st
PY
cmp -s "$L" "$T/before.json" && [ "$(led $KEY attempts)" = 1 ] && [ "$(stat -c %a "$L")" = 600 ] && ok "a crash before the rename leaves the old ledger whole (still attempt 1, mode 600)" || bad "crash left a changed ledger"
ls -A "$SALA_STATE_DIR" | grep -q '^\.bgagents\..*\.tmp$' && ok "...and only an unlinked temporary file behind" || bad "no temp leftover from the simulated crash"
NOW=$((N0+3000)) run; ls -A "$SALA_STATE_DIR" | grep -q '^\.bgagents\..*\.tmp$' && bad "the leftover survived the next save" || ok "the next save sweeps the leftover temporary file"
# a crash in the middle of an attempt (the child dies inside the start) leaves the attempt counted and the listing recorded
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"
python3 -I - "$ROOT/lib" "$L" "$T" <<'PY' || bad "the mid-attempt crash probe failed"
import os, sys
sys.path.insert(0, sys.argv[1]); import bgagents
os.environ.update(SALA_BGAGENTS="on", SALA_BGAGENTS_LEDGER=sys.argv[2], SALA_BGAGENTS_NOW="1800000000", SALA_BGAGENTS_LOADAVG=sys.argv[3] + "/loadavg",
                  SALA_BGAGENTS_LIST_CMD=sys.argv[3] + "/bin/list", SALA_BGAGENTS_POST_CMD=sys.argv[3] + "/bin/post", SALA_BGAGENTS_SPAWN_CMD=sys.argv[3] + "/bin/spawn",
                  SALA_BGAGENTS_ALIVE_CMD=sys.argv[3] + "/bin/alive")
pid = os.fork()
if pid == 0:
    real = bgagents.run
    def run(cmd, timeout):
        if cmd and cmd[0].endswith("/spawn"):
            os._exit(9)               # a hard death inside the start: no cleanup, no ledger write
        return real(cmd, timeout)
    bgagents.run = run
    os.environ["SALA_STATE_DIR"] = os.path.dirname(sys.argv[2])
    bgagents.main(["bgagents.py"])
    os._exit(0)
_, st = os.waitpid(pid, 0)
assert os.WEXITSTATUS(st) == 9, st
PY
[ "$(led $KEY attempts)" = 1 ] && [ "$(led $KEY created)" = True ] && [ "$(led $KEY posted_at)" = "$N0" ] && ok "a death inside the start leaves a whole ledger with the attempt counted and the listing recorded" || bad "mid-attempt crash: $(cat "$L" 2>/dev/null)"
NOW=$((N0+10)) run; [ "$(calls "$T/post.log")" = 1 ] && [ "$(calls "$T/spawn.log")" = 1 ] && [ "$(led $KEY started_at)" != 0 ] && ok "the next run finishes it without listing the agent twice" || bad "after the crash: post=$(calls "$T/post.log") $(cat "$L")"
# two runs at once: the second one stands aside
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; mkdir -p "$SALA_STATE_DIR"
( flock -n 9 || exit 1; run; [[ $OUT == *"another run holds the lock"* ]] && [ "$(calls "$T/post.log")" = 0 ] && echo held ) 9> "$L.lock" > "$T/o" 2>&1
[ "$(cat "$T/o")" = held ] && ok "a run that finds another one running stands aside (nothing listed)" || bad "lock: [$(cat "$T/o")]"

# -- the mandate --------------------------------------------------------------------------------------------------------------------------------
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; export SALA_OWNER_NAME="Sam Lee"; run
grep -q -- "--mandate Handles outside events (mail, Slack, GitHub) for this project and builds what needs no decision of Sam Lee, so the front agent serves only Sam Lee --sender" "$T/post.log" && ok "the default mandate takes the owner's name from SALA_OWNER_NAME (one line, in one place)" || bad "owner mandate: $(cat "$T/post.log")"
export SALA_OWNER_NAME=Pat
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; export SALA_BGAGENTS_MANDATE="Keeps example tidy"; run
[ "$(awk '{for(i=1;i<=NF;i++) if($i=="--mandate"){print $(i+1),$(i+2),$(i+3)}}' "$T/post.log")" = "Keeps example tidy" ] && grep -q -- "--mandate Keeps example tidy$" "$T/spawn.log" && ok "SALA_BGAGENTS_MANDATE overrides it for the listing and the start alike" || bad "override: $(cat "$T/post.log")"
for bad_m in "$(printf 'two\nlines')" 'has \ backslash' "$(printf 'x%.0s' $(seq 1 601))"; do
    reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; export SALA_BGAGENTS_MANDATE="$bad_m"; run
    [ "$RC" = 2 ] && [ "$(calls "$T/post.log")" = 0 ] && [ ! -e "$L" ] || bad "a bad mandate was taken: rc=$RC"
done
ok "a mandate with a line break, a backslash or over 600 characters is refused (exit 2, nothing done)"
unset SALA_BGAGENTS_MANDATE
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; export SALA_BGAGENTS_SENDER=sala-other; run; grep -q -- "--sender sala-other$" "$T/post.log" && ok "SALA_BGAGENTS_SENDER changes the label" || bad "sender override"
unset SALA_BGAGENTS_SENDER
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; export SALA_BGAGENTS_LEDGER=$T/elsewhere/ledger.json; run; [ -f "$T/elsewhere/ledger.json" ] && [ "$(stat -c %a "$T/elsewhere/ledger.json")" = 600 ] && [ ! -e "$L" ] && ok "SALA_BGAGENTS_LEDGER moves the ledger (mode 600)" || bad "ledger path"
unset SALA_BGAGENTS_LEDGER

# -- the help and the entry ----------------------------------------------------------------------------------------------------------------------
$S --help > "$T/h" 2>&1; rc=$?; [ "$rc" = 0 ] && grep -q '^usage: sala bg-agents' "$T/h" && grep -q 'SALA_BGAGENTS_MAX_LOAD' "$T/h" && ok "--help prints the usage (exit 0)" || bad "help rc=$rc"
bash "$ROOT/bin/salamander" --help | grep -q 'salamander bg-agents' && ok "sala --help lists the subcommand" || bad "top-level help"
grep -rn 'board#[0-9]' "$ROOT/lib/bgagents.py" "$ROOT/lib/bgagents.sh" "$ROOT/tests/bgagents.sh" "$ROOT/docs/bg-agents.md" 2>/dev/null | grep -v 'board#[0-9]*[^0-9]*$' >/dev/null; \
    ! grep -nE 'board#[0-9]' "$ROOT/lib/bgagents.py" "$ROOT/lib/bgagents.sh" "$ROOT/tests/bgagents.sh" "$ROOT/docs/bg-agents.md" 2>/dev/null | grep -v 'grep' >/dev/null && ok "no literal board id in the job's files" || bad "a literal board id is in a new file"

echo "bgagents: $([ $fail = 0 ] && echo pass || echo FAIL)"
exit $fail
