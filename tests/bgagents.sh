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
#   raise     a project it cannot start (given up, or a retire needed) never stays silent: ONE board item for the owner through the client's `post question`
#             (stub: tests/fake-stackshot-client.py, which enforces the board's limits), once per project, in plain words (no exit code, no command in it); a second run raises
#             nothing more; a raise that fails leaves `raised` false, says `board item needed`, exits 1, is retried with the same request id and is no failure and no attempt of
#             the project; again after the ledger's reset and a second give-up; --dry-run raises nothing; the subject's bracket (setting, the project's scope, the default scope,
#             the instance's prefixes); --status says "board item raised" / "not raised yet"
#   reset     `--reset KEY`: one project's ledger entry cleared (attempts, failures, back-off, given up, retire needed, the board item, the last outcome), the agent's entry kept,
#             the next run goes to the start; one line; a key with no entry refused (exit 1); with the switch off; atomic; --dry-run writes nothing; the item says a session resets it
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
cat > "$T/bin/prefixes" <<'EOF'
#!/usr/bin/env bash
echo x >> "$T/prefixes.calls"
[ -f "$T/prefixes.rc" ] && exit "$(cat "$T/prefixes.rc")"
echo '{"subject": {"prefixes": ["[alpha] ", "[beta] "]}, "pages": {"flavor": "plain"}}'
EOF
chmod +x "$T/bin"/*
export T FAKE_CLIENT_DIR=$T/fake
export SALA_BGAGENTS_LIST_CMD=$T/bin/list SALA_BGAGENTS_POST_CMD=$T/bin/post SALA_BGAGENTS_SPAWN_CMD=$T/bin/spawn SALA_BGAGENTS_ALIVE_CMD=$T/bin/alive
export SALA_BGAGENTS_ASK_CMD="python3 $ROOT/tests/fake-stackshot-client.py post question" SALA_BGAGENTS_PREFIXES_CMD=$T/bin/prefixes SALA_DEFAULT_SCOPE=alpha
export SALA_BGAGENTS_LOADAVG=$T/loadavg SALA_BGAGENTS_ALIVE_WAIT=0 SALA_PROJECT_RECORD=$T/projects.json SALA_BGAGENTS_NOW=$N0
export SALA_BGAGENTS_MAX_ATTEMPTS=5 SALA_BGAGENTS_COOLDOWN=600 SALA_BGAGENTS_COOLDOWN_MAX=86400 SALA_BGAGENTS_MAX_LOAD=10 SALA_BGAGENTS_RECORD_GRACE=900
unset SALA_BGAGENTS SALA_BGAGENTS_MANDATE SALA_BGAGENTS_SENDER SALA_BGAGENTS_LEDGER SALA_BGAGENTS_SUBJECT_PREFIX SALA_SCOPES FAKE_CLIENT_FAIL

S="bash $ROOT/bin/salamander bg-agents"
OUT=""; RC=0
run() {   # [args] → OUT (stdout+stderr), RC; the clock is $NOW (default N0)
    OUT=$(SALA_BGAGENTS_NOW=${NOW:-$N0} $S "$@" 2>&1); RC=$?
}
reset() {   # a clean slate: no ledger, no call logs, a quiet load, an empty list, nothing alive, no project record
    rm -rf "$SALA_STATE_DIR" "$T/list.txt" "$T/list.rc" "$T/list.calls" "$T/post.log" "$T/post.mode" "$T/spawn.log" "$T/spawn.mode" "$T/alive.txt" "$T/projects.json" "$T/fake" "$T/prefixes.rc" "$T/prefixes.calls"
    unset FAKE_CLIENT_FAIL
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

qcalls() { [ -f "$T/fake/calls.jsonl" ] && grep -c '"post", "question"' "$T/fake/calls.jsonl" || echo 0; }
qfield() {   # <n> <field> → the nth `post question` call's value: subject | ask | project | request-id | sender | recommended | stdin | options (one a line) | all (every value, as the owner reads it)
    python3 - "$T/fake/calls.jsonl" "$1" "$2" <<'PY'
import json, sys
calls = [json.loads(l) for l in open(sys.argv[1]) if '"post", "question"' in l]
c = calls[int(sys.argv[2]) - 1]; a = c["argv"][2:]; opts = []; kv = {}
while a:
    k = a.pop(0); v = a.pop(0)
    (opts.append(v) if k == "--option" else kv.__setitem__(k[2:], v))
f = sys.argv[3]
print("\n".join(opts) if f == "options" else c["stdin"].rstrip("\n") if f == "stdin" else "\n".join([kv["subject"], kv["ask"], *opts, c["stdin"]]) if f == "all" else kv.get(f, ""))
PY
}
seed() {   # <key> <prefix> [raised] → a ledger entry at the cap that this job could not start (the last problem in plain words)
    printf '{"schema":1,"projects":{"%s":{"prefix":"%s","agent":"%s-engineer","attempts":5,"failures":5,"next_try":%s,"created":%s,"posted_at":%s,"last":"failed: listing x failed: HTTP 409: x","last_at":%s,"last_plain":"The agent'"'"'s name is already taken on a project, or waiting there for another sender."%s}}}\n' \
        "$1" "$2" "$2" "$((N0+9999))" "$([ "${SEED_POSTED:-1}" = 0 ] && echo false || echo true)" "$([ "${SEED_POSTED:-1}" = 0 ] && echo 0 || echo $((N0-9999)))" "$N0" "${3:+,\"raised\":true,\"raised_at\":$N0,\"raised_item\":\"item-seed\"}" > "$L"
}
record_scope() {   # <key> <scope> → a fresh project record that names the project's scope
    python3 - "$T/projects.json" "$NOW" "$1" "$2" <<'PY'
import datetime, json, sys
path, now, key, scope = sys.argv[1:]
gen = datetime.datetime.fromtimestamp(float(now), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"schema": 1, "generated": gen, "projects": {"prj_1": {"id": "prj_1", "key": key, "scope": scope, "agents": {}}}, "by_key": {key: "prj_1"}}, open(path, "w"))
PY
}

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

# -- the board item for a project it cannot start ---------------------------------------------------------------------------------------------------
# given up: the third failed attempt (cap 3) raises ONE item in the same run, in plain words
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo 409 > "$T/post.mode"; export SALA_BGAGENTS_MAX_ATTEMPTS=3; t=$N0
NOW=$t run; NOW=$((t+100000)) run
[ "$(qcalls)" = 0 ] && [ "$(led $KEY raised)" = False ] && ok "two failed attempts of three: nothing raised yet" || bad "raised too early: $(cat "$L")"
NOW=$((t+200000)) run; ITEM=$(qfield 1 all); NOW0=$((t+200000))
[ "$RC" = 0 ] && [ "$(qcalls)" = 1 ] && [ "$(led $KEY raised)" = True ] && [ "$(led $KEY raised_at)" = "$NOW0" ] && [[ $(led $KEY raised_item) == board#* ]] && ok "given up: ONE board item raised in that run (exit 0), the ledger keeps raised, the time and the item id" || bad "raise on give-up: rc=$RC calls=$(qcalls) [$OUT] $(cat "$L")"
[[ $OUT == *"raised for the owner (given up)"* ]] && ok "the run says so in one line" || bad "raise line: [$OUT]"
[ "$(qfield 1 project)" = "$KEY" ] && [ "$(qfield 1 sender)" = sala-bg-agents ] && [[ $(qfield 1 subject) == "[alpha] example wants a background agent and its start failed 3 times" ]] && ok "the call: the want list's project page, the sender label, a subject with the bracket and \"<project> wants a background agent and its start failed N times\"" || bad "args: $(qfield 1 subject) / $(qfield 1 project) / $(qfield 1 sender)"
[ "$(qfield 1 recommended)" = "Keep trying later" ] && [ "$(qfield 1 options | wc -l)" = 3 ] && qfield 1 options | grep -q '^Leave it without one=' && qfield 1 options | grep -q '^I will start it by hand=' && ok "three options (keep trying later, recommended / leave it without one / start it by hand), exactly one recommended" || bad "options: $(qfield 1 options)"
printf '%s\n' "$ITEM" | grep -qiE 'exit|--|sala |sala$|client|python|spawn|HTTP|409|403|/usr|\.py|\.sh|\$' && bad "the item has an exit code, a command or a path in it: $ITEM" || ok "the item carries no exit code, no raw command, no path"
[[ $(qfield 1 stdin) == *"example wants a background agent (example-engineer), and starting it has failed 3 times."* && $(qfield 1 stdin) == *"The last problem: The agent's name is already taken on a project, or waiting there for another sender."* && $(qfield 1 stdin) == *"The job has stopped trying"* ]] && ok "the text: what happened and the agent, the last problem in one plain sentence, that the job stopped" || bad "text: $(qfield 1 stdin)"
[ "$(led $KEY attempts)" = 3 ] && [ "$(led $KEY failures)" = 3 ] && ok "the raise is no attempt and no failure of the project (3 and 3, as before)" || bad "raise counted: $(cat "$L")"
run --status; [[ $OUT == *"given up (board item raised)"* ]] && ok "--status: \"given up (board item raised)\"" || bad "status raised: [$OUT]"
# never twice
NOW=$((t+300000)) run; NOW=$((t+9999999)) run
[ "$(qcalls)" = 1 ] && [ "$(led $KEY raised_item)" != "" ] && [[ $OUT == *"given up after 3 attempts"* ]] && ok "later runs: the project is left alone and no second item is raised" || bad "second raise: calls=$(qcalls) [$OUT]"
export SALA_BGAGENTS_MAX_ATTEMPTS=5

# retire_needed raises once too (the failed start of an agent this job listed), the same item for the same project
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo fail > "$T/spawn.mode"
run
[ "$RC" = 1 ] && [[ $OUT == *"retire needed: $NAME"* ]] && [ "$(qcalls)" = 1 ] && [ "$(led $KEY raised)" = True ] && ok "retire needed: ONE board item raised (the run still exits 1 for the retire)" || bad "raise on retire: rc=$RC calls=$(qcalls) [$OUT]"
[[ $(qfield 1 stdin) == *"The last problem: The agent's session could not be started."* && $(qfield 1 stdin) == *"may not take it off without your word"* && $(qfield 1 stdin) != *"stopped trying"* ]] && ok "its text says the agent is still on the project and the job may not take it off without the owner's word" || bad "retire text: $(qfield 1 stdin)"
[ "$(qfield 1 subject)" = "[alpha] example wants a background agent and its start failed 1 time" ] && ok "...its subject says \"1 time\", not \"1 times\"" || bad "retire subject: $(qfield 1 subject)"
printf '%s\n' "$(qfield 1 all)" | grep -qiE 'exit|--|sala |client|python|spawn|HTTP|\.py' && bad "the retire item has a raw word in it: $(qfield 1 all)" || ok "...and, like the other, no exit code or command in it"
run --status; [[ $OUT == *"retire needed"* && $OUT == *"board item board#"* ]] && ok "--status: a retire-needed project shows its raised item" || bad "retire status: [$OUT]"
NOW=$((N0+601)) run; NOW=$((N0+5000)) run; [ "$(qcalls)" = 1 ] && [ "$(calls "$T/spawn.log")" -ge 2 ] && ok "the retry of the start does not raise again (one item per project)" || bad "retire second raise: calls=$(qcalls)"
echo ok > "$T/spawn.mode"; NOW=$((N0+20000)) run; [ "$(qcalls)" = 1 ] && [ "$(led $KEY retire_needed)" = False ] && ok "a start that works later raises nothing either" || bad "after start: calls=$(qcalls)"

# the raise fails: nothing is lost, it is no failure of the project, it does not take the run's attempt, and the next run tries again with the same request id
reset; printf '%s\n' "$KEY example example-main" "$KEY2 second second-main" > "$T/list.txt"; seed "$KEY" example; export FAKE_CLIENT_FAIL=1
run
[ "$RC" = 1 ] && grep -q "board item needed: $KEY (could not be raised: " <<<"$OUT" && [ "$(led $KEY raised)" = False ] && ok "the client refuses: \`board item needed: PROJECT\` said, exit 1, raised stays false" || bad "raise fails: rc=$RC [$OUT]"
[ "$(led $KEY attempts)" = 5 ] && [ "$(led $KEY failures)" = 5 ] && [ "$(led $KEY next_try)" = $((N0+9999)) ] && ok "a failed raise is no failure of the project: attempts, failures and back-off as they were" || bad "raise counted as failure: $(cat "$L")"
[ "$(calls "$T/post.log")" = 1 ] && grep -q "^$KEY2 " "$T/post.log" && [ "$(led $KEY2 attempts)" = 1 ] && ok "...and it did not take the run's one attempt: the next project was taken in the same run" || bad "attempt taken by the raise: post=[$(cat "$T/post.log" 2>/dev/null)]"
[ "$(grep -c 'board item needed' <<<"$OUT")" = 1 ] && ok "one line for it per run" || bad "lines: [$OUT]"
run --status; grep -q "$KEY .*given up (board item not raised yet)" <<<"$OUT" && ok "--status: \"given up (board item not raised yet)\"" || bad "status not raised: [$OUT]"
RID1=$(qfield 1 request-id); unset FAKE_CLIENT_FAIL; NOW=$((N0+60)) run
[ "$(qcalls)" = 2 ] && [ "$(qfield 2 request-id)" = "$RID1" ] && [ "$(led $KEY raised)" = True ] && [ "$RC" = 0 ] && ok "the next run raises it, with the same request id (a repeat files nothing twice)" || bad "retry: rc=$RC calls=$(qcalls) [$OUT]"
NOW=$((N0+120)) run; [ "$(qcalls)" = 2 ] && ok "and then never again" || bad "raised again after the retry"
# a timeout of the client counts as a failed raise as well
reset; seed "$KEY" example; printf '%s\n' "$KEY example example-main" > "$T/list.txt"
SALA_BGAGENTS_POST_TIMEOUT=1 FAKE_CLIENT_HANG=3 run; [ "$RC" = 1 ] && [[ $OUT == *"board item needed"* && $OUT == *"timed out"* ]] && [ "$(led $KEY raised)" = False ] && ok "a client that does not answer in time: the same (needed, exit 1, retried)" || bad "timeout: rc=$RC [$OUT]"
# no client at all
reset; seed "$KEY" example; printf '%s\n' "$KEY example example-main" > "$T/list.txt"
SALA_BGAGENTS_ASK_CMD= run; [ "$RC" = 1 ] && [[ $OUT == *"board item needed: $KEY (could not be raised: no stackshot client"* ]] && [ "$(led $KEY raised)" != True ] && ok "no stackshot client on the box: \`board item needed: PROJECT\`, exit 1, raised false" || bad "no ask client: rc=$RC [$OUT]"

# reset after absence: the entry goes, and it can raise again after giving up again
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; SEED_POSTED=0 seed "$KEY" example raised; : > "$T/list.txt"
NOW=$((N0+1)) run; NOW=$((N0+700)) run; ! has_entry $KEY && [ "$(qcalls)" = 0 ] && ok "off the list for the cooldown: the entry (and its raised mark) is cleared, nothing raised" || bad "reset: $(cat "$L")"
printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo 409 > "$T/post.mode"; t=$((N0+1000))
for i in 1 2 3 4 5; do NOW=$t run; t=$((t+100000)); done
[ "$(led $KEY attempts)" = 5 ] && [ "$(qcalls)" = 1 ] && [ "$(led $KEY raised)" = True ] && ok "back on the list and given up again: raised again (a fresh entry)" || bad "raise after reset: calls=$(qcalls) $(cat "$L")"
# the fresh give-up names a new question: a request id the first entry did not use
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; SEED_POSTED=0 seed "$KEY" example; NOW=$N0 run; R1=$(qfield 1 request-id)
: > "$T/list.txt"; NOW=$((N0+10)) run; NOW=$((N0+700)) run; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; SEED_POSTED=0 seed "$KEY" example; NOW=$((N0+900)) run; R2=$(qfield 2 request-id)
[ "$(qcalls)" = 2 ] && [ -n "$R1" ] && [ "$R1" != "$R2" ] && ok "after a reset the second give-up is a new question (a different request id)" || bad "request ids: [$R1] [$R2] calls=$(qcalls)"
# a project off the list with no agent of ours waiting is not asked about
reset; : > "$T/list.txt"; SEED_POSTED=0 seed "$KEY" example; NOW=$((N0+1)) run; [ "$(qcalls)" = 0 ] && has_entry $KEY && ok "a given-up project that has left the list (no agent of ours waiting): nothing raised" || bad "off-list raise: calls=$(qcalls)"

# dry run
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seed "$KEY" example; sum=$(cksum < "$L")
run --dry-run; [ "$RC" = 0 ] && [[ $OUT == *"would raise one board item for the owner"* ]] && [ "$(qcalls)" = 0 ] && [ "$(cksum < "$L")" = "$sum" ] && [ ! -e "$SALA_STATE_DIR/bgagents.log" ] && ok "--dry-run: says it would raise, raises nothing, writes nothing" || bad "dry raise: rc=$RC calls=$(qcalls) [$OUT]"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo fail > "$T/spawn.mode"; run >/dev/null; run --dry-run; [ "$(qcalls)" = 1 ] && [ "$RC" = 0 ] && ok "--dry-run after a raise: nothing more, and no word about raising" || bad "dry after raise: [$OUT]"

# the subject's bracket
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seed "$KEY" example; run; [[ $(qfield 1 subject) == "[alpha] "* ]] && ok "the bracket: SALA_DEFAULT_SCOPE when the project record names no scope" || bad "default scope: $(qfield 1 subject)"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seed "$KEY" example; record_scope "$KEY" beta; run; [[ $(qfield 1 subject) == "[beta] "* ]] && ok "the bracket: the project's own scope from the project record, when the instance takes it" || bad "project scope: $(qfield 1 subject)"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seed "$KEY" example; record_scope "$KEY" infra; run; [[ $(qfield 1 subject) == "[alpha] "* ]] && ok "a scope the instance has no prefix for (infra) falls back to the default scope" || bad "unknown scope: $(qfield 1 subject)"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seed "$KEY" example; SALA_BGAGENTS_SUBJECT_PREFIX='[beta]' run; [[ $(qfield 1 subject) == "[beta] "* ]] && ok "SALA_BGAGENTS_SUBJECT_PREFIX wins (and is not looked up: no read of the instance's prefixes)" || bad "setting: $(qfield 1 subject)"
[ ! -e "$T/prefixes.calls" ] && ok "...the prefixes were not even asked for" || bad "prefixes asked with a setting"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seed "$KEY" example; SALA_DEFAULT_SCOPE=zzz run; [[ $(qfield 1 subject) == "[alpha] "* ]] && ok "no scope the instance takes: the instance's first prefix" || bad "first prefix: $(qfield 1 subject)"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seed "$KEY" example; echo 1 > "$T/prefixes.rc"; SALA_DEFAULT_SCOPE=zzz run; [[ $(qfield 1 subject) == "[zzz] "* ]] && ok "the instance's prefixes unreadable: the first scope is used as it is" || bad "no prefixes: $(qfield 1 subject)"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seed "$KEY" example; echo 1 > "$T/prefixes.rc"; ( unset SALA_DEFAULT_SCOPE; export SALA_BGAGENTS_NOW=$N0; $S > "$T/o" 2>&1; echo $? > "$T/rc" )
[ "$(cat "$T/rc")" = 1 ] && grep -q 'no subject prefix' "$T/o" && [ "$(qcalls)" = 0 ] && [ "$(led $KEY raised)" != True ] && ok "no prefix to be had: said (set SALA_BGAGENTS_SUBJECT_PREFIX), exit 1, nothing filed, retried later" || bad "no prefix: rc=$(cat "$T/rc") [$(cat "$T/o")]"
for bad_p in 'no brackets' '[a b]' '[]'; do
    reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seed "$KEY" example; SALA_BGAGENTS_SUBJECT_PREFIX=$bad_p run
    [ "$RC" = 2 ] && [ "$(qcalls)" = 0 ] || bad "a bad subject prefix was taken: [$bad_p] rc=$RC"
done
ok "a subject prefix that is not one bracket word is refused (exit 2, nothing done)"

# --reset KEY: a ledger edit that makes the next run try the project afresh
full_entry() {   # <key> → a stuck entry with every field the reset clears set (an agent this job listed that never started, given up, the item raised)
    printf '{"schema":1,"projects":{"%s":{"prefix":"example","agent":"%s","attempts":5,"failures":5,"next_try":%s,"created":true,"posted_at":%s,"retire_needed":true,"raised":true,"raised_at":%s,"raised_item":"item-seed","raise_token":"tok-seed","last":"failed: x","last_at":%s,"last_plain":"The agent'"'"'s session could not be started."}}}\n' \
        "$1" "$NAME" "$((N0+9999))" "$((N0-100))" "$((N0-50))" "$((N0-60))" > "$L"
}
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; full_entry "$KEY"
run --reset "$KEY"
[ "$RC" = 0 ] && [ "$(printf '%s\n' "$OUT" | wc -l)" = 1 ] && [[ $OUT == *"$KEY: cleared the ledger entry (was: attempts 5, failures 5, given up, board item raised)"* && $OUT == *"left as it is"* ]] && ok "--reset: one line says what was cleared (exit 0)" || bad "reset: rc=$RC [$OUT]"
all_clear=1; for f in attempts failures next_try raised_at; do [ "$(led $KEY $f)" = 0 ] || all_clear=0; done
for f in retire_needed raised; do [ "$(led $KEY $f)" = False ] || all_clear=0; done
for f in raised_item raise_token last last_plain; do [ -z "$(led $KEY $f)" ] || all_clear=0; done; [ "$(led $KEY last_at)" = 0 ] || all_clear=0
[ "$all_clear" = 1 ] && ok "--reset clears attempts, failures, back-off, retire_needed, the board item (raised, time, item, request id) and the last outcome" || bad "not cleared: $(cat "$L")"
[ "$(led $KEY agent)" = "$NAME" ] && [ "$(led $KEY created)" = True ] && [ "$(led $KEY posted_at)" = "$((N0-100))" ] && ok "...the agent, its listing by this job and the time of it are kept (the agent's entry on the project is left as it is)" || bad "kept fields: $(cat "$L")"
[ "$(stat -c %a "$L")" = 600 ] && ! ls -A "$SALA_STATE_DIR" | grep -q '^\.bgagents\..*\.tmp$' && grep -q ' reset ' "$SALA_STATE_DIR/bgagents.log" && ok "--reset writes the ledger atomically (mode 600, no temporary file left) and logs the line" || bad "reset write: $(ls -A "$SALA_STATE_DIR")"
run --status; [[ $OUT == *"attempts 0/5"* && $OUT != *"given up"* ]] && ok "--status after the reset: attempts 0, no longer given up" || bad "status after reset: [$OUT]"
run; [ "$RC" = 0 ] && [ "$(calls "$T/post.log")" = 0 ] && [ "$(calls "$T/spawn.log")" = 1 ] && [ "$(led $KEY attempts)" = 1 ] && [ "$(led $KEY started_at)" = "$N0" ] && ok "the next run sees the agent already listed, goes straight to the start and tries it afresh (attempt 1, no second listing)" || bad "run after reset: rc=$RC post=$(calls "$T/post.log") spawn=$(calls "$T/spawn.log") [$OUT]"
[ "$(qcalls)" = 0 ] && ok "...and nothing is raised for it" || bad "raised after reset"
# the reset project that gets stuck again raises a new item
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; full_entry "$KEY"; run --reset "$KEY" >/dev/null; echo fail > "$T/spawn.mode"; export SALA_BGAGENTS_MAX_ATTEMPTS=1
run; [ "$RC" = 1 ] && [ "$(qcalls)" = 1 ] && [ "$(led $KEY raised)" = True ] && ok "stuck again after a reset: a new item is raised" || bad "raise after reset: rc=$RC calls=$(qcalls) [$OUT]"
export SALA_BGAGENTS_MAX_ATTEMPTS=5
# an unknown key, with and without a ledger
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; full_entry "$KEY"; sum=$(cksum < "$L")
run --reset projects/nothere; [ "$RC" = 1 ] && [ "$(printf '%s\n' "$OUT" | wc -l)" = 1 ] && [[ $OUT == *"no ledger entry for projects/nothere; nothing cleared"* ]] && [ "$(cksum < "$L")" = "$sum" ] && ok "--reset of a key with no entry: one plain line, exit 1, the ledger untouched" || bad "unknown key: rc=$RC [$OUT]"
reset; run --reset "$KEY"; [ "$RC" = 1 ] && [[ $OUT == *"no ledger entry"* ]] && [ ! -e "$L" ] && [ ! -e "$L.lock" ] && ok "...also with no ledger at all (nothing created)" || bad "no ledger: rc=$RC [$OUT] $(ls -A "$SALA_STATE_DIR")"
run --reset 'Not A Key'; [ "$RC" = 1 ] && ok "a key that cannot be one is just a key with no entry" || bad "odd key: rc=$RC"
# the switch off
reset; full_entry "$KEY"; export SALA_BGAGENTS=off; run --reset "$KEY"; [ "$RC" = 0 ] && [[ $OUT == *"cleared the ledger entry"* ]] && [ "$(led $KEY attempts)" = 0 ] && [ "$(calls "$T/list.calls")" = 0 ] && ok "--reset works with SALA_BGAGENTS off (a ledger edit, not a run: the want list is not read)" || bad "reset off: rc=$RC [$OUT]"
unset SALA_BGAGENTS
# dry run
reset; full_entry "$KEY"; sum=$(cksum < "$L")
run --reset "$KEY" --dry-run; [ "$RC" = 0 ] && [[ $OUT == *"would clear the ledger entry (was: attempts 5, failures 5, given up, board item raised)"* ]] && [ "$(cksum < "$L")" = "$sum" ] && [ ! -e "$SALA_STATE_DIR/bgagents.log" ] && [ ! -e "$L.lock" ] && ok "--reset --dry-run: says what it would clear, writes nothing (no ledger change, no log, no lock)" || bad "reset dry: rc=$RC [$OUT]"
run --dry-run --reset "$KEY"; [[ $OUT == *"would clear"* ]] && [ "$(cksum < "$L")" = "$sum" ] && ok "...in either order" || bad "reset dry order: [$OUT]"
# a run holding the lock
( flock -n 9 || exit 1; run --reset "$KEY"; [ "$RC" = 1 ] && [[ $OUT == *"another run holds the lock"* ]] && echo held ) 9> "$L.lock" > "$T/o" 2>&1
[ "$(cat "$T/o")" = held ] && [ "$(cksum < "$L")" = "$sum" ] && ok "--reset stands aside while a run holds the lock (exit 1, nothing cleared)" || bad "reset lock: [$(cat "$T/o")]"
# usage
run --reset; [ "$RC" = 2 ] && run --reset --dry-run && [ "$RC" = 2 ] && run --reset "$KEY" --status && [ "$RC" = 2 ] && run --reset a b && [ "$RC" = 2 ] && ok "--reset without a key, with --status, or with two keys is a usage error (exit 2)" || bad "reset usage: rc=$RC"
# a project stuck for both reasons: the item still fits the board's five lines, and says a session (not the owner) resets the record
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; full_entry "$KEY"; sed -i 's/"raised":true,"raised_at":[0-9]*,"raised_item":"item-seed","raise_token":"tok-seed",/"raised":false,/' "$L"; run
[ "$(qcalls)" = 1 ] && [ "$(qfield 1 stdin | wc -l)" = 5 ] && [[ $(qfield 1 stdin) == *'If you pick "Keep trying later", a session resets the project'"'"'s record and the job tries again.' ]] && ok "the item's last line says a session resets the record and the job tries again (five lines at most, given up and retire needed together)" || bad "item lines: calls=$(qcalls) [$OUT] $(qfield 1 stdin)"
qfield 1 all | grep -qiE 'bg-agents|--reset|sala ' && bad "the item names the command: $(qfield 1 all)" || ok "...and the item names no command (the owner never runs it)"
qfield 1 options | grep -q '^Keep trying later=A session resets' && ok "the option says a session resets the record" || bad "option: $(qfield 1 options)"

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
