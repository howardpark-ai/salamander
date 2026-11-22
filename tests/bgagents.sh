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
#   placed    a live session is a start only when the project record, roles.json and sala's registry row all place it on the project (back): each of the three
#             disagreeing, a link that cannot answer (stale, unreadable, missing), all three agreeing, a link that lags (read again until the deadline), the miss told once per
#             attempt (one Slack post, one board item, one failed line, the pane left running), the next attempt counting it once they agree
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
# ok | dead (exit 0, never live) | fail (exit 1) | norecord (exit 3) | blind (exit 6: stackshot's project record cannot answer, no pane). alive: live when the name is a line of $T/alive.txt.
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
printf '%s\n' "$*" >> "$T/spawn.log"; echo spawn >> "$T/order.log"
case "$(cat "$T/spawn.mode" 2>/dev/null || echo ok)" in
    ok) printf '%s\n' "$1" >> "$T/alive.txt"; python3 "$T/place.py" "$@"; exit 0 ;;
    dead) exit 0 ;;
    fail) echo "claude did not start in $1:0 within 45s" >&2; exit 1 ;;
    norecord) echo "not on the agents map" >&2; exit 3 ;;
    blind) echo "spawn refused: stackshot's project record cannot answer (it is 3600 s old): retry when it is fresh, or SALA_AGENT_CHECK=off to start it unchecked" >&2; exit 6 ;;
esac
EOF
# a real start puts the new session in its project three ways: stackshot's record lists it (a back agent, front false), roles.json has a live entry for it, and its registry row (the alive stub with --json) carries the project and the role.
# $T/place.skip names the links the spawn leaves out (the words record and roles), so a case can make exactly one of them disagree
cat > "$T/place.py" <<'PYREG'
import datetime, json, os, sys
name, key = sys.argv[1], sys.argv[sys.argv.index("--project") + 1]
skip = open(os.environ["T"] + "/place.skip").read().split() if os.path.exists(os.environ["T"] + "/place.skip") else []
gen = datetime.datetime.fromtimestamp(float(os.environ["SALA_BGAGENTS_NOW"]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
def load(path, empty):
    try:
        return json.load(open(path))
    except (OSError, ValueError):
        return empty
if "record" not in skip:
    path = os.environ["SALA_PROJECT_RECORD"]
    d = load(path, {"schema": 1, "projects": {}, "by_key": {}})
    pid = d["by_key"].setdefault(key, "prj_" + str(len(d["by_key"]) + 1))
    p = d["projects"].setdefault(pid, {"id": pid, "key": key, "agents": {}})
    p["agents"][name] = {"front": False, "role": "engineer", "mandate_line": "x"}
    d["generated"] = gen
    json.dump(d, open(path, "w"))
if "roles" not in skip:
    path = os.environ["SALA_ROLES_FILE"]
    d = load(path, {"sessions": {}})
    d["sessions"][name] = {"role": "back", "project": key, "live": True}
    d["generated"] = gen
    json.dump(d, open(path, "w"))
PYREG
cat > "$T/bin/alert" <<'EOF'
#!/usr/bin/env bash
# the Slack post (sala alert): logs the headline and the line, one call a line pair; $T/alert.rc forces an exit code
printf '%s\n' "$1" >> "$T/alert.log"; printf '%s\n' "$2" >> "$T/alert.lines"
exit "$(cat "$T/alert.rc" 2>/dev/null || echo 0)"
EOF
cat > "$T/bin/alive" <<'EOF'
#!/usr/bin/env bash
# with --json a live answer carries the registry row: project projects/<name without -engineer> and role back by default; $T/row.project and $T/row.role replace them, and $T/row.lag = N makes the first N --json answers
# carry no project (a row the watch has not tagged yet); $T/row.name replaces the row's name (the registry also answers a renamed session's old name with the renamed session's row); every --json call is noted in row.calls
if [ "${3:-}" = --json ] || [ "${2:-}" = --json ]; then
    echo x >> "$T/row.calls"; lag=$(cat "$T/row.lag" 2>/dev/null || echo 0); nrow=$(wc -l < "$T/row.calls")
    if [ "$nrow" -le "$lag" ]; then rowproj=null; else rowproj="\"$(cat "$T/row.project" 2>/dev/null || echo "projects/${1%-engineer}")\""; fi
    ROWJSON="{\"name\": \"$(cat "$T/row.name" 2>/dev/null || echo "$1")\", \"project\": $rowproj, \"role\": \"$(cat "$T/row.role" 2>/dev/null || echo back)\"}"
    # $T/row.sleep = S makes every --json answer from call number $T/row.sleep.from (default 1) on take S seconds (a slow registry); the stub is replaced by the sleep (exec), so the job's timeout stops it at once
    if [ -s "$T/row.sleep" ] && [ "$nrow" -ge "$(cat "$T/row.sleep.from" 2>/dev/null || echo 1)" ]; then exec sleep "$(cat "$T/row.sleep")"; fi
fi
# exit 0 = live (the name is a line of alive.txt), 1 = none, like `sala sessions resolve --live`; $T/alive.rc forces any other exit (a check that cannot say);
# every call is noted in alive.log, and $T/alive.sleep seconds are waited after the answer is decided (a slow check); alive.ready.N is written once the answer and the delay are
# captured, so a test that changes alive.sleep waits for it; $T/alive.seq (one exit code a line) answers call N with line N (the last line after that); $T/alive.hold.N holds call N
# (after its answer is decided) until the test removes that file, for at most 15 s by the clock (half the 30 s the job allows a check).
# The call's number N is CLAIMED first, with an exclusive create (bash noclobber, O_EXCL: the first free alive.claim.N is taken; mkdir is NOT used: the uutils mkdir of Ubuntu 26.04 lets two concurrent calls both create the same directory), so two calls that start together never share a number; only then is anything
# signaled: alive.ready.N says call N has its answer, its delay and its hold decided; alive.holding.N that it entered the hold; alive.released.N says how it left its hold ("released" by the test removing the file, "bound" by the clock);
# alive.gate.N (a file the test creates with the hold file) stops call N after its delay and BEFORE its first look at the hold file until the test removes the gate file (at most 30 s by the clock), and alive.looking.N is written when the call comes
# to that first look, with what it saw ("gone" or "present", or "gate-expired" when the clock opened the gate and the test did not): a test that removes the hold file, then the gate file, and then waits for looking.N, has proved by the stub's own handshake, not by timing, that the file was gone at the first look
n=1; while ! ( set -o noclobber; : > "$T/alive.claim.$n" ) 2>/dev/null; do n=$((n + 1)); done
echo "$1" >> "$T/alive.log"
hold=0; [ -e "$T/alive.hold.$n" ] && hold=1
gate=0; [ -e "$T/alive.gate.$n" ] && gate=1
# the answer is decided first and given after the wait: a slow check reports what was true when it asked
if [ -f "$T/alive.seq" ]; then rc=$(sed -n "$n p" "$T/alive.seq"); [ -n "$rc" ] || rc=$(tail -n 1 "$T/alive.seq")
elif [ -f "$T/alive.rc" ]; then rc=$(cat "$T/alive.rc"); elif grep -qx -- "$1" "$T/alive.txt" 2>/dev/null; then rc=0; else rc=1; fi
delay=0; [ -f "$T/alive.sleep" ] && delay=$(cat "$T/alive.sleep")
echo "$1" > "$T/alive.ready.$n"
[ "$delay" != 0 ] && sleep "$delay"
if [ "$hold" = 1 ]; then
    gx=0; if [ "$gate" = 1 ]; then gu=$((SECONDS + 30)); while [ -e "$T/alive.gate.$n" ]; do if [ "$SECONDS" -ge "$gu" ]; then gx=1; break; fi; sleep 0.1; done; fi     # gx is set in the branch that ends the wait by the clock (as the hold loops set why), never decided by a later look at the file
    if [ "$gx" = 1 ]; then echo gate-expired > "$T/alive.looking.$n"; elif [ -e "$T/alive.hold.$n" ]; then echo present > "$T/alive.looking.$n"; else echo gone > "$T/alive.looking.$n"; fi
    echo holding > "$T/alive.holding.$n"; until=$((SECONDS + ${ALIVE_HOLD_BOUND:-15})); why=""
    while [ -z "$why" ]; do
        if [ "$SECONDS" -ge "$until" ]; then why=bound; elif [ ! -e "$T/alive.hold.$n" ]; then why=released; else sleep 0.1; fi     # the reason is set here, when the loop sees it, never decided by a later look at the file
    done
    echo "$why" > "$T/alive.released.$n"
fi
[ "$rc" = 0 ] && [ -n "${ROWJSON:-}" ] && echo "$ROWJSON"
exit "$rc"
EOF
cat > "$T/bin/ask" <<'EOF'
#!/usr/bin/env bash
# the board-item command: notes the call in order.log, waits $T/ask.sleep seconds when that file is there (a slow stackshot), then is the fake client's `post question`;
# the call's number N is CLAIMED first with an exclusive create (bash noclobber, O_EXCL, the first free ask.claim.N; not mkdir, which is not exclusive under uutils), so two calls that start together never share a number; only then is anything signaled:
# ask.ready.N is written once the call has its delay and its hold decided (a test that changes ask.sleep for the next caller, or releases a hold, waits for it); ask.hold.N is explained below
delay=0; [ -f "$T/ask.sleep" ] && delay=$(cat "$T/ask.sleep")
n=1; while ! ( set -o noclobber; : > "$T/ask.claim.$n" ) 2>/dev/null; do n=$((n + 1)); done
echo ask >> "$T/order.log"
hold=0; [ -e "$T/ask.hold.$n" ] && hold=1
gate=0; [ -e "$T/ask.gate.$n" ] && gate=1
echo ask > "$T/ask.ready.$n"
# $T/ask.failkey names one project the board refuses (a filing error that belongs to that key); every call's project is noted in ask.keys
prev=""
for a in "$@"; do
    if [ "$prev" = --project ]; then
        echo "$a" >> "$T/ask.keys"
        [ "$a" = "$(cat "$T/ask.failkey" 2>/dev/null)" ] && { echo "refused: $a" >&2; exit 1; }
    fi
    prev=$a
done
[ "$delay" != 0 ] && sleep "$delay"
# $T/ask.hold.N: call N waits until the test removes that file, however long the other runs take. The wait ends by the CLOCK (bash SECONDS, not a count of sleeps, which only
# gives a minimum) at half the filing timeout this call has (SALA_BGAGENTS_RAISE_TIMEOUT, 30 s when unset), so the job's own timeout can never end a hold first;
# ask.released.N records how the call left its hold: "released" (the loop saw the test had removed the file) or "bound" (the loop saw the clock's deadline first); it is set inside the loop
# at that moment, so a file removed just after the deadline cannot turn "bound" into "released"; ask.holding.N is written when the call enters the hold (after ready.N and the delay);
# ask.gate.N and ask.looking.N: as for the liveness stub (the gate file stops the call before its first look at the hold file until the test removes it; looking.N says what that look saw, or "gate-expired" when the clock opened the gate)
if [ "$hold" = 1 ]; then
    gx=0; if [ "$gate" = 1 ]; then gu=$((SECONDS + 30)); while [ -e "$T/ask.gate.$n" ]; do if [ "$SECONDS" -ge "$gu" ]; then gx=1; break; fi; sleep 0.1; done; fi     # gx is set in the branch that ends the wait by the clock (as the hold loops set why), never decided by a later look at the file
    if [ "$gx" = 1 ]; then echo gate-expired > "$T/ask.looking.$n"; elif [ -e "$T/ask.hold.$n" ]; then echo present > "$T/ask.looking.$n"; else echo gone > "$T/ask.looking.$n"; fi
    echo holding > "$T/ask.holding.$n"; rt=$SALA_BGAGENTS_RAISE_TIMEOUT; [ -n "$rt" ] || rt=30; until=$((SECONDS + rt / 2)); why=""
    while [ -z "$why" ]; do
        if [ "$SECONDS" -ge "$until" ]; then why=bound; elif [ ! -e "$T/ask.hold.$n" ]; then why=released; else sleep 0.1; fi     # the reason is set here, when the loop sees it, never decided by a later look at the file
    done
    echo "$why" > "$T/ask.released.$n"
fi
exec python3 "$ROOT/tests/fake-stackshot-client.py" post question "$@"
EOF
cat > "$T/bin/prefixes" <<'EOF'
#!/usr/bin/env bash
echo x >> "$T/prefixes.calls"
# $T/prefixes.sleep: a read that takes that many seconds. It records when it started (prefixes.start) and, every tenth of a second, the time of its last sign of life (prefixes.beat), in microseconds of its own clock:
# beat - start is how long the job let it live before cutting it off, which is the timeout the job passed (the stub is killed by the job's subprocess timeout and cannot be told the number any other way)
if [ -f "$T/prefixes.sleep" ]; then
    # each stamp is published by writing a temporary file in the same directory and renaming it over the real one, so a kill at any moment leaves the previous COMPLETE stamp (a plain `echo >` truncates first)
    publish() { echo "$2" > "$1.tmp"; mv -f "$1.tmp" "$1"; }
    t=${EPOCHREALTIME/./}; publish "$T/prefixes.start" "$t"; end=$((SECONDS + $(cat "$T/prefixes.sleep")))
    while [ "$SECONDS" -lt "$end" ]; do t=${EPOCHREALTIME/./}; publish "$T/prefixes.beat" "$t"; sleep 0.1; done; exit 0
fi
[ -f "$T/prefixes.rc" ] && exit "$(cat "$T/prefixes.rc")"
echo '{"subject": {"prefixes": ["[alpha] ", "[beta] "]}, "pages": {"flavor": "plain"}}'
EOF
chmod +x "$T/bin"/*
export T ROOT FAKE_CLIENT_DIR=$T/fake
export SALA_BGAGENTS_LIST_CMD=$T/bin/list SALA_BGAGENTS_POST_CMD=$T/bin/post SALA_BGAGENTS_SPAWN_CMD=$T/bin/spawn SALA_BGAGENTS_ALIVE_CMD=$T/bin/alive
export SALA_BGAGENTS_ASK_CMD=$T/bin/ask SALA_BGAGENTS_PREFIXES_CMD=$T/bin/prefixes SALA_DEFAULT_SCOPE=alpha
export SALA_BGAGENTS_ALERT_CMD=$T/bin/alert SALA_ROLES_FILE=$T/roles.json SALA_BGAGENTS_PLACE_WAIT=0 SALA_BGAGENTS_PLACE_POLL=0.1
export SALA_BGAGENTS_LOADAVG=$T/loadavg SALA_BGAGENTS_ALIVE_WAIT=0 SALA_PROJECT_RECORD=$T/projects.json SALA_BGAGENTS_NOW=$N0
export SALA_BGAGENTS_MAX_ATTEMPTS=5 SALA_BGAGENTS_COOLDOWN=600 SALA_BGAGENTS_COOLDOWN_MAX=86400 SALA_BGAGENTS_MAX_LOAD=10 SALA_BGAGENTS_RECORD_GRACE=900
unset SALA_BGAGENTS_RAISE_TIMEOUT SALA_BGAGENTS SALA_BGAGENTS_MANDATE SALA_BGAGENTS_SENDER SALA_BGAGENTS_LEDGER SALA_BGAGENTS_SUBJECT_PREFIX SALA_SCOPES FAKE_CLIENT_FAIL

S="bash $ROOT/bin/salamander bg-agents"
OUT=""; RC=0
run() {   # [args] → OUT (stdout+stderr), RC; the clock is $NOW (default N0)
    OUT=$(SALA_BGAGENTS_NOW=${NOW:-$N0} $S "$@" 2>&1); RC=$?
}
reset() {   # a clean slate: no ledger, no call logs, a quiet load, an empty list, nothing alive, no project record
    rm -rf "$SALA_STATE_DIR" "$T/list.txt" "$T/list.rc" "$T/list.calls" "$T/post.log" "$T/post.mode" "$T/spawn.log" "$T/spawn.mode" "$T/alive.txt" "$T/projects.json" "$T/roles.json" "$T/alert.log" "$T/alert.lines" "$T/alert.rc" "$T/place.skip" "$T/row.calls" "$T/row.lag" "$T/row.project" "$T/row.role" "$T/row.name" "$T/row.sleep" "$T/row.sleep.from" "$T/fake" "$T/prefixes.rc" "$T/prefixes.calls" "$T/prefixes.sleep" "$T/prefixes.start" "$T/prefixes.beat" "$T/prefixes.start.tmp" "$T/prefixes.beat.tmp" "$T/alive.rc" "$T/alive.log" "$T/alive.sleep" "$T/ask.sleep" "$T/ask.failkey" "$T/ask.keys" "$T/order.log" "$T/alive.seq" "$T"/ask.ready.* "$T"/ask.hold.* "$T"/ask.claim.* "$T"/ask.released.* "$T"/ask.holding.* "$T"/alive.holding.* "$T"/alive.ready.* "$T"/alive.hold.* "$T"/alive.claim.* "$T"/alive.released.* "$T"/ask.gate.* "$T"/ask.looking.* "$T"/alive.gate.* "$T"/alive.looking.*
    unset FAKE_CLIENT_FAIL
    mkdir -p "$SALA_STATE_DIR"; echo "0.50 0.40 0.30 1/200 12345" > "$T/loadavg"; NOW=$N0
    export SALA_BGAGENTS=on
}
await_file() { local _ tries=120; [ -n "$2" ] && tries=$2; for _ in $(seq 1 "$tries"); do [ -s "$1" ] && return 0; sleep 0.1; done; return 1; }   # a signal a stub wrote (bounded: 12 s, or the number of tenths of a second given)
# late_removal <ask|alive>: the (j2) setup, run by a handshake and not by timing: a call that is held and gated (its hold file and its gate file exist before it starts, and its deadline is already up when it enters the hold) signals ready.1;
# the test then removes the hold file, then the gate file, and waits for looking.1 (written after the gate went, with what the stub saw at its first look). Sets LATE_LOOK (gone or present) and LATE_WHY (the released.1 line); LATE_OK=0 when a signal never came
# (reported here as a setup failure, nothing removed after it is judged; a stub that never signals is killed by its PID (SIGKILL) and reaped, so no wait here is unbounded)
late_removal() {
    local kind=$1 pid; LATE_OK=0; LATE_LOOK=""; LATE_WHY=""
    reset; : > "$T/$kind.hold.1"; : > "$T/$kind.gate.1"
    if [ "$kind" = ask ]; then SALA_BGAGENTS_RAISE_TIMEOUT=0 "$T/bin/ask" --project k < /dev/null > /dev/null 2>&1 & pid=$!      # the stub itself is the background job (its PID is the one stopped below), not a subshell around it
    else ALIVE_HOLD_BOUND=0 "$T/bin/alive" some-name < /dev/null > /dev/null 2>&1 & pid=$!; fi
    if ! await_file "$T/$kind.ready.1" 600; then kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; bad "setup: the $kind stub never signalled ready (no $kind.ready.1 in 60 s; the stub was killed by its PID with SIGKILL, which it cannot trap): the removal was not made and the check was not run"; return; fi
    rm -f "$T/$kind.hold.1"; rm -f "$T/$kind.gate.1"
    if ! await_file "$T/$kind.looking.1" 600; then kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; bad "setup: the $kind stub never signalled looking (no $kind.looking.1 in 60 s after the hold file and the gate file were removed; the stub was killed by its PID with SIGKILL, which it cannot trap): the check was not run"; return; fi
    wait "$pid"; LATE_LOOK=$(cat "$T/$kind.looking.1" 2>/dev/null); LATE_WHY=$(cat "$T/$kind.released.1" 2>/dev/null)
    if [ "$LATE_LOOK" = gate-expired ]; then bad "setup: the $kind stub's gate expired (30 s by the clock) before the test lifted it, so what the stub saw proves nothing: the check was not judged"; return; fi
    LATE_OK=1
}
# need_held <ask|alive> <N>…: wait (60 s, bounded: a call can be slow to get here, e.g. the 6 s liveness wait below, on a loaded runner) until call N has ENTERED its hold. ready.N and holding.N are written in two steps, so a test that acts, and later samples whether the call
# is held, waits for holding.N (it implies ready.N); a call that never gets there fails its check by name
need_held() { local kind=$1 n; shift; for n in "$@"; do await_file "$T/$kind.holding.$n" 600 || bad "the $kind call $n never entered its hold (no holding signal in 60 s): the overlap checks that follow prove nothing"; done; }
# the proof that a run really overlapped a call, not only that the overlap was arranged: IN FLIGHT = the call has signaled it started, its hold file is still there and it has not left its hold
# (no released.N yet; holding.N says it entered the hold, and the test waited for it BEFORE acting), asked at the moment the other run is done: held before and still held after means held throughout; FREED = it left its hold because the test removed the file (not because the stub's own clock bound ended it)
ask_held() { [ -s "$T/ask.ready.$1" ] && [ -e "$T/ask.holding.$1" ] && [ -e "$T/ask.hold.$1" ] && [ ! -e "$T/ask.released.$1" ] && echo yes || echo no; }
ask_freed() { [ "$(cat "$T/ask.released.$1" 2>/dev/null)" = released ] && echo yes || echo no; }
alive_held() { [ -s "$T/alive.ready.$1" ] && [ -e "$T/alive.holding.$1" ] && [ -e "$T/alive.hold.$1" ] && [ ! -e "$T/alive.released.$1" ] && echo yes || echo no; }
alive_freed() { [ "$(cat "$T/alive.released.$1" 2>/dev/null)" = released ] && echo yes || echo no; }
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
# (no board-item client here: a raised project is left alone, which the raise section below covers; the retry of the start is what this block checks)
SAVED_ASK=$SALA_BGAGENTS_ASK_CMD; export SALA_BGAGENTS_ASK_CMD=
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo fail > "$T/spawn.mode"
run
[ "$RC" = 1 ] && grep -q "retire needed: $NAME" <<<"$OUT" && ok "a failed start of an agent this job listed: \`retire needed: NAME\` and exit 1" || bad "retire needed: rc=$RC [$OUT]"
[ "$(led $KEY retire_needed)" = True ] && [ "$(led $KEY failures)" = 1 ] && [ "$(led $KEY created)" = True ] && ok "the ledger keeps retire_needed and counts the failure" || bad "retire ledger: $(cat "$L")"
[ "$(calls "$T/post.log")" = 1 ] && ! grep -qi retire "$T/post.log" "$T/spawn.log" && ok "nothing is taken off the project: the only call to stackshot was the listing" || bad "a retire-like call: $(cat "$T/post.log")"
NOW=$((N0+601)) run; [ "$(calls "$T/post.log")" = 1 ] && [ "$(calls "$T/spawn.log")" = 2 ] && [ "$RC" = 1 ] && ok "the next try finds the entry (listed by the ledger): no second listing, the start tried again" || bad "retry after retire: post=$(calls "$T/post.log") spawn=$(calls "$T/spawn.log") rc=$RC [$OUT]"
echo ok > "$T/spawn.mode"; NOW=$((N0+2000)) run; [ "$RC" = 0 ] && [ "$(led $KEY retire_needed)" = False ] && [ "$(led $KEY started_at)" != 0 ] && ok "a start that works clears the mark: nothing left to retire" || bad "retire cleared: rc=$RC $(cat "$L")"
export SALA_BGAGENTS_ASK_CMD=$SAVED_ASK
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
NOW=$((N0+601)) run; NOW=$((N0+5000)) run; [ "$(qcalls)" = 1 ] && [ "$(calls "$T/spawn.log")" = 1 ] && [ "$(calls "$T/post.log")" = 1 ] && [[ $OUT == *"board item board#"*"raised; left alone until a session resets"* ]] && ok "once raised, no start is tried again and no second item is raised (one item per project)" || bad "retire second raise: calls=$(qcalls) spawn=$(calls "$T/spawn.log") [$OUT]"
echo ok > "$T/spawn.mode"; NOW=$((N0+20000)) run; [ "$(qcalls)" = 1 ] && [ "$(calls "$T/spawn.log")" = 1 ] && [ "$(led $KEY retire_needed)" = True ] && ok "...even when a start would work now: the project stays quiet until a session resets it" || bad "after raise: calls=$(qcalls) spawn=$(calls "$T/spawn.log")"
run --reset "$KEY" >/dev/null; NOW=$((N0+20001)) run; [ "$(qcalls)" = 1 ] && [ "$(calls "$T/spawn.log")" = 2 ] && [ "$(led $KEY retire_needed)" = False ] && [ "$(led $KEY raised)" = False ] && [ "$(led $KEY started_at)" != 0 ] && ok "after \`--reset\` the start is tried and works: the mark is cleared and nothing more is raised" || bad "after reset: calls=$(qcalls) $(cat "$L")"

# the raise fails: nothing is lost, it is no failure of the project, it does not take the run's attempt, and the next run tries again with the same request id
reset; printf '%s\n' "$KEY example example-main" "$KEY2 second second-main" > "$T/list.txt"; seed "$KEY" example; export FAKE_CLIENT_FAIL=1
run
[ "$RC" = 1 ] && grep -q "board item needed: $KEY (could not be raised: " <<<"$OUT" && [ "$(led $KEY raised)" = False ] && ok "the client refuses: \`board item needed: PROJECT\` said, exit 1, raised stays false" || bad "raise fails: rc=$RC [$OUT]"
[ "$(led $KEY attempts)" = 5 ] && [ "$(led $KEY failures)" = 5 ] && [ "$(led $KEY next_try)" = $((N0+9999)) ] && ok "a failed raise is no failure of the project: attempts, failures and back-off as they were" || bad "raise counted as failure: $(cat "$L")"
[ "$(calls "$T/post.log")" = 1 ] && grep -q "^$KEY2 " "$T/post.log" && [ "$(led $KEY2 attempts)" = 1 ] && ok "...and it did not take the run's one attempt: the next project was taken in the same run" || bad "attempt taken by the raise: post=[$(cat "$T/post.log" 2>/dev/null)]"
[ "$(grep -c 'board item needed' <<<"$OUT")" = 1 ] && ok "one line for it per run" || bad "lines: [$OUT]"
run --status; grep -q "$KEY .*given up (board item not raised yet)" <<<"$OUT" && ok "--status: \"given up (board item not raised yet)\"" || bad "status not raised: [$OUT]"
RID1=$(qfield 1 request-id); unset FAKE_CLIENT_FAIL; NOW=$((N0+60)) run
[ "$(qcalls)" = 1 ] && [ "$(led $KEY raised)" = False ] && [ "$(led $KEY raise_failures)" = 1 ] && [ "$(led $KEY raise_next_try)" = $((N0+600)) ] && [[ $OUT == *"board item still needed: $KEY (the last filing failed 1 time; next try "* ]] && ok "a failed filing waits out its own back-off: a run a minute later does not file again, and says so" || bad "filing back-off: calls=$(qcalls) [$OUT]"
NOW=$((N0+700)) run
[ "$(qcalls)" = 2 ] && [ "$(qfield 2 request-id)" = "$RID1" ] && [ "$(led $KEY raised)" = True ] && [ "$RC" = 0 ] && ok "the next run raises it, with the same request id (a repeat files nothing twice)" || bad "retry: rc=$RC calls=$(qcalls) [$OUT]"
NOW=$((N0+1400)) run; [ "$(qcalls)" = 2 ] && ok "and then never again" || bad "raised again after the retry"
# a timeout of the client counts as a failed raise as well
reset; seed "$KEY" example; printf '%s\n' "$KEY example example-main" > "$T/list.txt"
SALA_BGAGENTS_RAISE_TIMEOUT=1 FAKE_CLIENT_HANG=3 run; [ "$RC" = 1 ] && [[ $OUT == *"board item needed"* && $OUT == *"timed out"* ]] && [ "$(led $KEY raised)" = False ] && ok "a client that does not answer in time: the same (needed, exit 1, retried)" || bad "timeout: rc=$RC [$OUT]"
# no client at all
reset; seed "$KEY" example; printf '%s\n' "$KEY example example-main" > "$T/list.txt"
SALA_BGAGENTS_ASK_CMD= run; [ "$RC" = 1 ] && [[ $OUT == *"board item needed: $KEY (could not be raised: no stackshot client"* ]] && [ "$(led $KEY raised)" != True ] && ok "no stackshot client on the box: \`board item needed: PROJECT\`, exit 1, raised false" || bad "no ask client: rc=$RC [$OUT]"

# a raised entry is never pruned: the owner was asked, and the answer stands until a session resets the record, on the list or off it
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; SEED_POSTED=0 seed "$KEY" example raised; : > "$T/list.txt"
NOW=$((N0+1)) run; NOW=$((N0+700)) run; NOW=$((N0+200000)) run
[ "$(led $KEY raised)" = True ] && [ "$(led $KEY raised_item)" = item-seed ] && [ "$(qcalls)" = 0 ] && ok "off the list far past the cooldown: the raised entry is kept (and nothing is raised)" || bad "raised entry pruned: $(cat "$L")"
run --status; [[ $OUT == *"$KEY "*"given up (board item raised, not on the want list)"*"off the list since"* ]] && ok "--status shows it as raised and not on the want list" || bad "status raised off list: [$OUT]"
printf '%s\n' "$KEY example example-main" > "$T/list.txt"; NOW=$((N0+300000)) run
[ "$(calls "$T/post.log")" = 0 ] && [ "$(calls "$T/spawn.log")" = 0 ] && [ "$(qcalls)" = 0 ] && [ "$(led $KEY raised_item)" = item-seed ] && [ "$(led $KEY absent_since)" = 0 ] && ok "back on the list: nothing started, no second item (the owner's earlier decision stands)" || bad "returned raised project was acted on: post=$(calls "$T/post.log") spawn=$(calls "$T/spawn.log") calls=$(qcalls) $(cat "$L")"
run --reset "$KEY" >/dev/null; : > "$T/list.txt"; NOW=$((N0+300001)) run; NOW=$((N0+301000)) run; ! has_entry $KEY && ok "after \`--reset\` and the cooldown off the list the entry is cleared as before" || bad "reset entry kept: $(cat "$L")"
# the same after the reset: back on the list and given up again, raised again
printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo 409 > "$T/post.mode"; t=$((N0+400000))
for i in 1 2 3 4 5; do NOW=$t run; t=$((t+100000)); done
[ "$(led $KEY attempts)" = 5 ] && [ "$(qcalls)" = 1 ] && [ "$(led $KEY raised)" = True ] && ok "back on the list and given up again: raised again (a fresh entry)" || bad "raise after reset: calls=$(qcalls) $(cat "$L")"
# the fresh give-up names a new question: a request id the first entry did not use
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; SEED_POSTED=0 seed "$KEY" example; NOW=$N0 run; R1=$(qfield 1 request-id)
: > "$T/list.txt"; NOW=$((N0+10)) run; NOW=$((N0+700)) run; run --reset "$KEY" >/dev/null; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; SEED_POSTED=0 seed "$KEY" example; NOW=$((N0+900)) run; R2=$(qfield 2 request-id)
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

# -- review fixes: a raised project stays quiet, a live agent is no start failure, unique request ids, one bounded raise a run ----------------------------------
seedn() {   # <key=prefix>… → a ledger with one given-up entry per spec (agent <prefix>-engineer, listed, the raise not made)
    python3 - "$L" "$N0" "$@" <<'PY'
import json, sys
path, n0, *specs = sys.argv[1:]; n0 = int(n0); projects = {}
for sp in specs:
    key, prefix = sp.split("=")
    projects[key] = {"prefix": prefix, "agent": prefix + "-engineer", "attempts": 5, "failures": 5, "next_try": n0 + 9999, "created": True, "posted_at": n0 - 9999,
                     "last": "failed: x", "last_at": n0, "last_plain": "The agent's session could not be started."}
json.dump({"schema": 1, "projects": projects}, open(path, "w"))
PY
}
patch() {   # <key> <field>=<json value>… → the ledger entry with those fields set
    python3 - "$L" "$@" <<'PY'
import json, sys
path, key, *kv = sys.argv[1:]; d = json.load(open(path))
for x in kv:
    k, v = x.split("=", 1); d["projects"][key][k] = json.loads(v)
json.dump(d, open(path, "w"))
PY
}
mkdir -p "$T/fake"

# 1. once an item is raised, the project makes no start attempt until a session resets it (the owner's other two answers leave it raised)
for shape in 'retire_needed=true attempts=1' 'retire_needed=false attempts=2'; do
    want_att=$(echo "$shape" | sed 's/.*attempts=//'); reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seedn "$KEY=example"
    # shellcheck disable=SC2086
    patch "$KEY" next_try=0 raised=true raised_at=$N0 'raised_item="item-seed"' failures=1 $shape
    run; NOW=$((N0+700)) run; NOW=$((N0+999999)) run
    [ "$RC" = 0 ] && [ "$(calls "$T/post.log")" = 0 ] && [ "$(calls "$T/spawn.log")" = 0 ] && [ "$(qcalls)" = 0 ] && [[ $OUT == *"item-seed raised; left alone until a session resets"* ]] && [ "$(led $KEY attempts)" = "$want_att" ] \
        && ok "a raised project below the cap ($shape), due, however long it waits: no listing, no start, no second item, attempts as they were" || bad "raised project was tried ($shape): post=$(calls "$T/post.log") spawn=$(calls "$T/spawn.log") [$OUT]"
done
run --status; [[ $OUT == *"left alone until a session resets it (board item raised)"* ]] && ok "--status says it is left alone until a session resets it" || bad "status raised: [$OUT]"
run --reset "$KEY" >/dev/null; NOW=$((N0+10)) run; [ "$(calls "$T/spawn.log")" = 1 ] && [ "$(led $KEY started_at)" != 0 ] && ok "\`--reset\` (\"Keep trying later\") makes it tried again from the first attempt" || bad "after reset: spawn=$(calls "$T/spawn.log") $(cat "$L")"
reset; printf '%s\n%s\n' "$KEY example example-main" "$KEY2 second second-main" > "$T/list.txt"; seedn "$KEY=example"; patch "$KEY" next_try=0 raised=true 'raised_item="item-seed"' attempts=2
run; [ "$(calls "$T/post.log")" = 1 ] && grep -q "^$KEY2 " "$T/post.log" && ok "a raised project does not take the run's attempt: the next project is started" || bad "raised blocked the next project: [$(cat "$T/post.log" 2>/dev/null)]"

# 2. a project that stays on the want list while its agent's session is live is no start failure
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; run; patch "$KEY" attempts=4
NOW=$((N0+700)) run
[ "$RC" = 0 ] && [ "$(led $KEY attempts)" = 5 ] && [ "$(qcalls)" = 0 ] && [ "$(led $KEY raised)" = False ] && [ "$(led $KEY stale)" = True ] && [ "$(led $KEY last)" = "agent running, want list stale" ] && [[ $OUT == *"agent running, want list stale"* ]] \
    && ok "at the cap with a live pane: nothing raised, the ledger and the log say \`agent running, want list stale\`" || bad "stale: rc=$RC calls=$(qcalls) [$OUT] $(cat "$L")"
run --status; [[ $OUT == *"agent running, want list stale"* && $OUT != *"not raised yet"* ]] && ok "--status says so (not \"board item not raised yet\")" || bad "status stale: [$OUT]"
NOW=$((N0+999999)) run; [ "$(qcalls)" = 0 ] && [ "$(calls "$T/spawn.log")" = 1 ] && [ "$(calls "$T/post.log")" = 1 ] && [ "$(led $KEY attempts)" = 5 ] && ok "...and later runs raise nothing and attempt nothing while the pane stays alive" || bad "stale later: calls=$(qcalls) [$OUT]"
run --dry-run; [[ $OUT == *"agent running, want list stale"* && $OUT != *"would raise"* ]] && [ "$(qcalls)" = 0 ] && ok "--dry-run says the same and raises nothing" || bad "dry stale: [$OUT]"
: > "$T/alive.txt"; NOW=$((N0+1000000)) run
[ "$(qcalls)" = 1 ] && [ "$(led $KEY raised)" = True ] && [ "$(led $KEY stale)" = False ] && [[ $(qfield 1 subject) == *"its start failed 1 time" ]] && [[ $(qfield 1 stdin) == *"has failed 1 time."* ]] && ok "once the pane is gone the project is stuck like any other: the item is raised, saying the start failed" || bad "after the pane died: calls=$(qcalls) [$OUT] $(cat "$L")"
# an entry flagged stale (below the cap, retire needed) is kept out of the retry loop while its pane is alive, and goes back into it when the pane is gone
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seedn "$KEY=example"; patch "$KEY" next_try=0 attempts=1 failures=1 retire_needed=true stale=true; echo "$NAME" > "$T/alive.txt"
run; [ "$(calls "$T/post.log")" = 0 ] && [ "$(calls "$T/spawn.log")" = 0 ] && [ "$(qcalls)" = 0 ] && [ "$(led $KEY attempts)" = 1 ] && [[ $OUT == *"no attempt while its pane is alive"* ]] && ok "a stale project below the cap makes no attempt while its pane is alive" || bad "stale loop: [$OUT]"
: > "$T/alive.txt"; NOW=$((N0+10)) run; [ "$(led $KEY stale)" = False ] && [ "$(calls "$T/spawn.log")" = 1 ] && ok "...and is looked at as any other project once the pane is gone (the start is tried)" || bad "stale cleared: $(cat "$L")"
# the check cannot say: raised as today, saying only what is known
for how in "rc7" "nocmd"; do
    reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seed "$KEY" example
    if [ "$how" = rc7 ]; then echo 7 > "$T/alive.rc"; run; else SALA_BGAGENTS_ALIVE_CMD= run; fi
    [ "$(qcalls)" = 1 ] && [ "$(led $KEY raised)" = True ] && [[ $(qfield 1 subject) == "[alpha] example wants a background agent and its start did not finish" ]] && [[ $(qfield 1 stdin) == *"and the start did not finish."* && $(qfield 1 stdin) != *"failed"* && $(qfield 1 stdin) != *"without a background agent"* ]] \
        && [[ $(qfield 1 ask) == *"Stakes: the job does not try again until then"* ]] && ok "the liveness check cannot say ($how): the item is raised and says only that the start did not finish" || bad "uncertain ($how): calls=$(qcalls) $(qfield 1 all)"
done
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seed "$KEY" example; patch "$KEY" retire_needed=true; echo 2 > "$T/alive.rc"; run
[[ $(qfield 1 stdin) == *"The agent is still on the project, and the job may not take it off without your word."* && $(qfield 1 stdin) != *"not running"* ]] && ok "...a retire-needed item with an unknown session does not say the session is not running" || bad "uncertain retire text: $(qfield 1 stdin)"

# 3. the request id: the full project key, one token an escalation
reset; printf '%s\n%s\n' "projects/example example example-main" "infra/example example example-main" > "$T/list.txt"; seedn "projects/example=example" "infra/example=example"
run; run
RA=$(qfield 1 request-id); RB=$(qfield 2 request-id)
[ "$(qcalls)" = 2 ] && [ "$RA" != "$RB" ] && [[ $RA == bgagents-infra-example-$N0-* && $RB == bgagents-projects-example-$N0-* ]] && [ "$(led infra/example raised_item)" != "$(led projects/example raised_item)" ] && ok "two projects with one slug in different scopes, filed at the SAME clock second, get different request ids (they differ by the scope part) and two items" || bad "slug collision: [$RA] [$RB] calls=$(qcalls)"
SAME=$(python3 - "$T/fake/calls.jsonl" <<'PY'
import json, sys
print(len({json.loads(l)["argv"][json.loads(l)["argv"].index("--request-id") + 1] for l in open(sys.argv[1]) if '"post", "question"' in l}))
PY
)
[ "$SAME" = 2 ] && ok "...even in one second (the same run clock)" || bad "ids in one second: $SAME"
[[ $RA =~ ^bgagents-infra-example-$N0-[0-9a-f]{8}$ ]] && ok "the id is bgagents-<scope>-<slug>-<time>-<random>" || bad "id shape: $RA"
# a reset followed by another give-up in the same second does not reuse the id
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seed "$KEY" example; run; R1=$(qfield 1 request-id)
run --reset "$KEY" >/dev/null; seed "$KEY" example; run; R2=$(qfield 2 request-id)
[ "$(qcalls)" = 2 ] && [ -n "$R1" ] && [ "$R1" != "$R2" ] && ok "a reset and another give-up in the same second: a new request id, a second item" || bad "same-second reuse: [$R1] [$R2] calls=$(qcalls)"
# a retry of the same escalation keeps its id (the raise that failed, then worked) and the ledger holds it
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seed "$KEY" example; export FAKE_CLIENT_FAIL=1; run; T1=$(led $KEY raise_token); unset FAKE_CLIENT_FAIL
NOW=$((N0+700)) run; NOW=$((N0+1400)) run
[ -n "$T1" ] && [ "$(qfield 2 request-id)" = "$T1" ] && [ "$(qcalls)" = 2 ] && ok "a retry of the same escalation reuses the token the ledger kept (nothing filed twice)" || bad "retry id: [$T1] [$(qfield 2 request-id)]"

# 4. one bounded raise a run, after the start, without the ledger lock
reset; printf '%s\n%s\n' "$KEY example example-main" "$KEY2 second second-main" > "$T/list.txt"; seedn "$KEY=example" "$KEY2=second"
run; [ "$RC" = 0 ] && [ "$(qcalls)" = 1 ] && [[ $OUT == *"1 more project still needs a board item"* ]] && [ "$(led $KEY raised)" = True ] && [ "$(led $KEY2 raised)" = False ] && ok "two outstanding projects: ONE raise in the run (the first by key), the run says one more waits (exit 0)" || bad "one raise: rc=$RC calls=$(qcalls) [$OUT]"
NOW=$((N0+1)) run; [ "$(qcalls)" = 2 ] && [ "$(led $KEY2 raised)" = True ] && [ "$RC" = 0 ] && ok "the next run raises the second" || bad "second raise: calls=$(qcalls)"
NOW=$((N0+2)) run; [ "$(qcalls)" = 2 ] && ok "and then nothing more" || bad "third raise"
reset; printf '%s\n%s\n' "$KEY example example-main" "$KEY2 second second-main" > "$T/list.txt"; seedn "$KEY=example"
run; ORDER=$(tr '\n' ' ' < "$T/order.log")
[ "$ORDER" = "spawn ask " ] && [ "$(calls "$T/post.log")" = 1 ] && [ "$(led $KEY raised)" = True ] && ok "the start comes first: the next project is started, then the board item is raised" || bad "order: [$ORDER]"
# the ledger lock is not held across the raise: a reset of another project runs during a slow call, and wins over what the run writes afterwards
reset; printf '%s\n%s\n' "$KEY example example-main" "$KEY2 second second-main" > "$T/list.txt"; seedn "$KEY=example" "$KEY2=second"; patch "$KEY2" raised=true 'raised_item="item-seed"'; : > "$T/ask.hold.1"
export SALA_BGAGENTS_RAISE_TIMEOUT=90
( SALA_BGAGENTS_NOW=$N0 $S > "$T/bg.out" 2>&1; echo $? > "$T/bg.rc" ) & BG=$!
need_held ask 1
t0=$(date +%s%N); run --reset "$KEY2"; t1=$(date +%s%N); HELD=$(ask_held 1)
[ "$RC" = 0 ] && [[ $OUT == *"cleared the ledger entry"* ]] && [ $(( (t1 - t0) / 1000000 )) -lt 3000 ] && ok "a slow raise does not block \`--reset\` of another project (it ran during the call, in under 3 s)" || bad "reset blocked: rc=$RC [$OUT] $(( (t1 - t0) / 1000000 )) ms"
rm -f "$T/ask.hold.1"; wait "$BG"
[ "$HELD" = yes ] && [ "$(ask_freed 1)" = yes ] && ok "...proof of the overlap: the raise was still in flight (held) when the reset ran, and left its hold only when the test released it" || bad "reset overlap not proved: in flight=$HELD freed=$(ask_freed 1)"
[ "$(cat "$T/bg.rc")" = 0 ] && [ "$(led $KEY raised)" = True ] && [ "$(led $KEY2 attempts)" = 0 ] && [ "$(led $KEY2 raised)" = False ] && ok "...the run's result is written to the entry as it then is: the raise is recorded and the other project's reset is not written over" || bad "after the slow raise: rc=$(cat "$T/bg.rc") $(cat "$L")"
# a reset of the SAME project during the call wins: the result is set aside
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seedn "$KEY=example"; : > "$T/ask.hold.1"
( SALA_BGAGENTS_NOW=$N0 $S > "$T/bg.out" 2>&1; echo $? > "$T/bg.rc" ) & BG=$!
need_held ask 1
run --reset "$KEY"; HELD=$(ask_held 1); rm -f "$T/ask.hold.1"; wait "$BG"
[ "$HELD" = yes ] && [ "$(ask_freed 1)" = yes ] && ok "...proof of the overlap: the raise was in flight when the same project was reset, and left its hold only when the test released it" || bad "same-project reset overlap not proved: in flight=$HELD freed=$(ask_freed 1)"
[ "$RC" = 0 ] && [ "$(cat "$T/bg.rc")" = 0 ] && [ "$(led $KEY raised)" = False ] && [ "$(led $KEY raise_token)" = "" ] && [ "$(led $KEY attempts)" = 0 ] && grep -q "reset while the board item" "$T/bg.out" && ok "a \`--reset\` of the same project during the call wins: the entry stays cleared and the run says the result was not recorded" || bad "reset lost: $(cat "$L") [$(cat "$T/bg.out")]"
unset SALA_BGAGENTS_RAISE_TIMEOUT
# the raise has its own short timeout: the listing's timeout does not apply to it, and the prefixes call is bounded by it too
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seed "$KEY" example
SALA_BGAGENTS_POST_TIMEOUT=1 FAKE_CLIENT_HANG=2 run; [ "$RC" = 0 ] && [ "$(led $KEY raised)" = True ] && ok "SALA_BGAGENTS_POST_TIMEOUT does not bound the raise" || bad "post timeout applied to the raise: rc=$RC [$OUT]"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seed "$KEY" example
SALA_BGAGENTS_RAISE_TIMEOUT=1 FAKE_CLIENT_HANG=3 run; [ "$RC" = 1 ] && [[ $OUT == *"board item needed"*"timed out after 1 s"* ]] && ok "SALA_BGAGENTS_RAISE_TIMEOUT bounds the question's call" || bad "raise timeout: rc=$RC [$OUT]"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seed "$KEY" example; echo 40 > "$T/prefixes.sleep"      # a read that would take 40 s: the job cuts it off at the timeout it is given, and the stub's own clock says how long it was let live
SALA_BGAGENTS_RAISE_TIMEOUT=1 run; LIVED=$(( ($(cat "$T/prefixes.beat" 2>/dev/null || echo 0) - $(cat "$T/prefixes.start" 2>/dev/null || echo 0)) / 1000 ))      # ms the read was let live (a timeout of 1 s: about 1000; a hard-coded 10 s would give about 10000)
[ "$RC" = 0 ] && [ -s "$T/prefixes.start" ] && [ "$LIVED" -ge 0 ] && [ "$LIVED" -lt 5000 ] && [ "$(led $KEY raised)" = True ] && ok "...and so does the read of the instance's prefixes (a timeout there falls back to the default scope)" || bad "prefixes timeout: rc=$RC the read was let live $LIVED ms (started: $([ -s "$T/prefixes.start" ] && echo yes || echo no)) [$OUT]"
[ "$(env -u SALA_BGAGENTS_RAISE_TIMEOUT python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import bgagents; print(bgagents.config()["raise_timeout"])' "$ROOT/lib")" = 30.0 ] && ok "the raise timeout defaults to 30 s" || bad "default raise timeout"
grep -q 'SALA_BGAGENTS_RAISE_TIMEOUT=30' "$ROOT/config.example" && grep -q 'SALA_BGAGENTS_RAISE_TIMEOUT' "$ROOT/docs/bg-agents.md" && ok "the setting is in config.example and docs/bg-agents.md" || bad "setting undocumented"
rm -f "$T/ask.sleep" "$T/prefixes.sleep"

# 5. a project whose board item is being filed is left alone by every other run (the lock is given up for the call: its mark is `raising_at`)
mark() { patch "$KEY" next_try=0 attempts=2 failures=2 retire_needed=true; }   # below the cap, due, its start did not finish: it needs an item
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seedn "$KEY=example"; mark
echo 30 > "$T/loadavg"; : > "$T/ask.hold.1"; export SALA_BGAGENTS_RAISE_TIMEOUT=90
( SALA_BGAGENTS_NOW=$N0 $S > "$T/bg.out" 2>&1; echo $? > "$T/bg.rc" ) & BG=$!
need_held ask 1
MARK=$(led $KEY raising_at); echo "0.50 0.40 0.30 1/200 12345" > "$T/loadavg"
NOW=$((N0+1)) run; SECOND=$OUT; HELD=$(ask_held 1); rm -f "$T/ask.hold.1"; wait "$BG"
[ "$HELD" = yes ] && [ "$(ask_freed 1)" = yes ] && ok "...proof of the overlap: the filing was in flight (held) while the second run ran, and left its hold only when the test released it" || bad "second run overlap not proved: in flight=$HELD freed=$(ask_freed 1)"
[ "$MARK" -ge "$N0" ] && [ "$MARK" -lt $((N0+60)) ] && [ "$(calls "$T/spawn.log")" = 0 ] && [ "$(calls "$T/post.log")" = 0 ] && [[ $SECOND == *"another run is filing its board item"* ]] && ok "while the item is filed (lock released), a second run does not start the due project" || bad "overlap start: mark=$MARK spawn=$(calls "$T/spawn.log") post=$(calls "$T/post.log") [$SECOND]"
[ "$(cat "$T/bg.rc")" = 0 ] && [ "$(led $KEY raised)" = True ] && [ "$(qcalls)" = 1 ] && [ "$(led $KEY raising_at)" = 0 ] && [ "$(led $KEY retire_needed)" = True ] && ok "...and the first run records its item (the mark is cleared) with no start success told as a failure" || bad "overlap record: rc=$(cat "$T/bg.rc") calls=$(qcalls) $(cat "$L")"
run --status >/dev/null; reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seedn "$KEY=example"; mark; patch "$KEY" raising_at=$((N0-10)); run
[ "$(calls "$T/spawn.log")" = 0 ] && [ "$(qcalls)" = 0 ] && ok "a mark younger than the window (2 x the raise timeout and the wait for the lock) holds the project back, start and raise alike" || bad "young mark: spawn=$(calls "$T/spawn.log") calls=$(qcalls) [$OUT]"
run --status; [[ $OUT == *"a board item is being filed"* ]] && ok "--status says a board item is being filed" || bad "status raising: [$OUT]"
patch "$KEY" raising_at=$((N0-1000)); run
[ "$(calls "$T/spawn.log")" = 1 ] && [ "$(led $KEY retire_needed)" = False ] && ok "a mark older than the window is stale (the run that set it died): the project is looked at again" || bad "old mark: spawn=$(calls "$T/spawn.log") $(cat "$L")"
# a start that worked meanwhile (by a run that ignored a stale mark) is not told to the owner as a failure: the first run's item is not recorded
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seedn "$KEY=example"; mark; echo 30 > "$T/loadavg"; : > "$T/ask.hold.1"
( SALA_BGAGENTS_NOW=$N0 $S > "$T/bg.out" 2>&1; echo $? > "$T/bg.rc" ) & BG=$!
need_held ask 1
patch "$KEY" retire_needed=false attempts=0 failures=0 started_at=$N0; HELD=$(ask_held 1); rm -f "$T/ask.hold.1"; wait "$BG"
[ "$HELD" = yes ] && [ "$(ask_freed 1)" = yes ] && ok "...proof of the overlap: the filing was in flight when the start was recorded, and left its hold only when the test released it" || bad "recorded start overlap not proved: in flight=$HELD freed=$(ask_freed 1)"
[ "$(led $KEY raised)" = False ] && [ "$(led $KEY raising_at)" = 0 ] && [ "$(led $KEY started_at)" = "$N0" ] && grep -q "no longer stuck" "$T/bg.out" && ok "a success recorded during the call: the item is not recorded, the entry as it is stays" || bad "late failure item: $(cat "$L") [$(cat "$T/bg.out")]"
unset SALA_BGAGENTS_RAISE_TIMEOUT

# 6. a filing error that belongs to one project waits out that project's back-off, and the next project gets the run's one raise
reset; printf '%s\n%s\n' "$KEY example example-main" "$KEY2 second second-main" > "$T/list.txt"; seedn "$KEY=example" "$KEY2=second"; echo "$KEY" > "$T/ask.failkey"
run
[ "$RC" = 1 ] && [ "$(led $KEY raise_failures)" = 1 ] && [ "$(led $KEY raise_next_try)" = $((N0+600)) ] && [ "$(led $KEY raised)" = False ] && [ "$(led $KEY attempts)" = 5 ] && ok "a refused filing counts on its project: one failure, the next filing after the back-off (the cooldown), attempts untouched" || bad "filing failure: rc=$RC $(cat "$L")"
NOW=$((N0+1)) run
[ "$(led $KEY2 raised)" = True ] && [ "$(grep -cx "$KEY" "$T/ask.keys")" = 1 ] && [ "$(grep -cx "$KEY2" "$T/ask.keys")" = 1 ] && [[ $OUT == *"board item still needed: $KEY (the last filing failed 1 time"* ]] && ok "the next run does not retry the failing key: the project after it is raised" || bad "next project starved: keys=[$(tr '\n' ' ' < "$T/ask.keys")] [$OUT]"
NOW=$((N0+700)) run
[ "$(led $KEY raise_failures)" = 2 ] && [ "$(led $KEY raise_next_try)" = $((N0+700+1200)) ] && [ "$(grep -cx "$KEY" "$T/ask.keys")" = 2 ] && ok "once its back-off is over the key is tried again, and the back-off doubles (like a start's)" || bad "back-off growth: $(cat "$L")"
run --status; [[ $OUT == *"$KEY "*"the board item could not be filed 2 times, next try "* ]] && ok "--status shows the filing failures and the next try" || bad "status filing: [$OUT]"
rm -f "$T/ask.failkey"; NOW=$((N0+2000)) run
[ "$(led $KEY raised)" = True ] && [ "$(led $KEY raise_failures)" = 0 ] && [ "$(led $KEY raise_next_try)" = 0 ] && ok "a filing that works clears its failure count" || bad "recovered: $(cat "$L")"
run --reset "$KEY" >/dev/null; [ "$(led $KEY raise_failures)" = 0 ] && ok "\`--reset\` clears the filing failures too (they are in the reset fields)" || bad "reset fields"

# 7. liveness probes are made without the ledger lock, and at most SALA_BGAGENTS_MAX_PROBES (3) a run
reset; printf '%s\n%s\n' "$KEY example example-main" "$KEY2 second second-main" > "$T/list.txt"; seedn "$KEY=example" "$KEY2=second"
patch "$KEY" next_try=0 attempts=1 failures=1 retire_needed=true stale=true; patch "$KEY2" raised=true 'raised_item="item-seed"'; echo "$NAME" > "$T/alive.txt"; : > "$T/alive.hold.1"
( SALA_BGAGENTS_NOW=$N0 $S > "$T/bg.out" 2>&1; echo $? > "$T/bg.rc" ) & BG=$!
need_held alive 1
t0=$(date +%s%N); run --reset "$KEY2"; t1=$(date +%s%N); HELD=$(alive_held 1)
[ "$RC" = 0 ] && [[ $OUT == *"cleared the ledger entry"* ]] && [ $(( (t1 - t0) / 1000000 )) -lt 10000 ] && ok "a slow liveness check does not block \`--reset\` (it ran during the probe, in under 10 s: a blocked reset would wait out the probe's 15 s hold)" || bad "reset blocked by a probe: rc=$RC [$OUT] $(( (t1 - t0) / 1000000 )) ms"
rm -f "$T/alive.hold.1"; wait "$BG"
[ "$HELD" = yes ] && [ "$(alive_freed 1)" = yes ] && ok "...proof of the overlap: the liveness check was in flight (held) when the reset ran, and left its hold only when the test released it" || bad "probe overlap not proved: in flight=$HELD freed=$(alive_freed 1)"
[ "$(cat "$T/bg.rc")" = 0 ] && [ "$(led $KEY2 failures)" = 0 ] && [ "$(led $KEY2 raised)" = False ] && [ "$(led $KEY stale)" = True ] && ok "...the run re-reads the ledger after its probes: the reset is not written over (the reset project is started afresh), the probed project is kept as it was" || bad "after the probe: rc=$(cat "$T/bg.rc") $(cat "$L") [$(cat "$T/bg.out")]"
[ "$(grep -cx "$NAME" "$T/alive.log")" = 1 ] && ok "a project probed in the start phase is not probed again for the raise (one check)" || bad "double probe: $(cat "$T/alive.log")"
reset; seedn "projects/p1=p1" "projects/p2=p2" "projects/p3=p3" "projects/p4=p4" "projects/p5=p5" "projects/p6=p6"; : > "$T/list.txt"
for i in 1 2 3 4 5 6; do
    printf '%s\n' "projects/p$i p$i p$i-main" >> "$T/list.txt"; echo "p$i-engineer" >> "$T/alive.txt"
    patch "projects/p$i" next_try=0 attempts=1 failures=1 retire_needed=true stale=true
done
run; [ "$RC" = 0 ] && [ "$(calls "$T/alive.log")" = 3 ] && ok "six live projects: three checks in one run (the start phase two, the raise one)" || bad "probe cap: $(calls "$T/alive.log") calls [$OUT]"
NOW=$((N0+1)) run; [ "$(calls "$T/alive.log")" = 6 ] && [ "$(sort -u "$T/alive.log" | wc -l)" = 6 ] && [ "$(calls "$T/spawn.log")" = 0 ] && [ "$(qcalls)" = 0 ] && ok "the least recently checked go first: the rest are done at the next run, and none was started or raised for" || bad "probe rotation: $(tr '\n' ' ' < "$T/alive.log") spawn=$(calls "$T/spawn.log")"
rm -f "$T/alive.log"; SALA_BGAGENTS_MAX_PROBES=5 NOW=$((N0+2)) run; [ "$(calls "$T/alive.log")" = 5 ] && ok "SALA_BGAGENTS_MAX_PROBES sets the cap" || bad "max probes: $(calls "$T/alive.log")"
grep -q 'SALA_BGAGENTS_MAX_PROBES' "$ROOT/config.example" && grep -q 'SALA_BGAGENTS_MAX_PROBES' "$ROOT/docs/bg-agents.md" && grep -q 'SALA_BGAGENTS_MAX_PROBES' "$ROOT/lib/bgagents.sh" && ok "the setting is in config.example, docs/bg-agents.md and the wrapper's export list" || bad "max probes undocumented"

# 8. only a confirmed "not live" lets a running project back into the start path
for how in rc7 nocmd; do
    reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seedn "$KEY=example"; patch "$KEY" next_try=0 attempts=1 failures=1 retire_needed=true stale=true
    if [ "$how" = rc7 ]; then echo 7 > "$T/alive.rc"; run; else SALA_BGAGENTS_ALIVE_CMD= run; fi
    [ "$(led $KEY stale)" = True ] && [ "$(calls "$T/spawn.log")" = 0 ] && [ "$(calls "$T/post.log")" = 0 ] && [ "$(led $KEY attempts)" = 1 ] && [[ $OUT == *"could not be told: the entry is left as it is, no attempt"* ]] && ok "a stale project whose liveness cannot be told ($how): stale stays, no start attempt, the log says so" || bad "uncertain stale ($how): $(cat "$L") [$OUT]"
done
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seed "$KEY" example; patch "$KEY" stale=true; echo 7 > "$T/alive.rc"; run
[ "$(qcalls)" = 0 ] && [ "$(led $KEY stale)" = True ] && [ "$(led $KEY raised)" = False ] && [[ $OUT == *"could not be told; the entry is left as it is (stale, no board item, no attempt)"* ]] && ok "a given-up stale project whose liveness cannot be told: no board item, stale stays" || bad "uncertain given up: calls=$(qcalls) [$OUT] $(cat "$L")"
rm -f "$T/alive.rc"; NOW=$((N0+1)) run
[ "$(led $KEY stale)" = False ] && [ "$(qcalls)" = 1 ] && ok "...and a confirmed \"not live\" (exit 1) ends it: stale cleared, the item raised" || bad "confirmed not live: calls=$(qcalls) $(cat "$L")"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seedn "$KEY=example"; patch "$KEY" next_try=0 attempts=1 failures=0 retire_needed=false started_at=$((N0-100)); echo 7 > "$T/alive.rc"; run
[ "$(calls "$T/spawn.log")" = 0 ] && [ "$(led $KEY started_at)" = $((N0-100)) ] && [[ $OUT == *"was started; whether it is live could not be told: the entry is left as it is, no attempt"* ]] && ok "a started project whose liveness cannot be told: no second start, started_at kept" || bad "uncertain started: spawn=$(calls "$T/spawn.log") $(cat "$L") [$OUT]"
rm -f "$T/alive.rc"; NOW=$((N0+1)) run
[ "$(calls "$T/spawn.log")" = 1 ] && ok "...and a confirmed \"not live\" lets the start be tried again" || bad "started, confirmed dead: spawn=$(calls "$T/spawn.log") [$OUT]"

# 9. third review pass: the filing mark is read from the clock when filing begins, the filing has its own owner token, a cached liveness answer does not outlive another run's start,
#    the probe slots rotate without a command, and an inconclusive check blocks a failure item for a started pane too
# (a) the probes and the start before the filing take a run's time: the mark is read when the filing begins. Run A waits 6 s in its liveness check (a minimum of elapsed time, which
#     orders nothing: the mark must then be at least 6 s after A's start), then files, held; run B, whose clock is the window (195 s with a 90 s filing timeout) after A's START,
#     must still find the project marked
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seedn "$KEY=example"; mark
echo 30 > "$T/loadavg"; echo 6 > "$T/alive.sleep"; : > "$T/ask.hold.1"; export SALA_BGAGENTS_RAISE_TIMEOUT=90
( SALA_BGAGENTS_NOW=$N0 $S > "$T/bg.out" 2>&1; echo $? > "$T/bg.rc" ) & BG=$!
need_held ask 1; rm -f "$T/alive.sleep"; echo "0.50 0.40 0.30 1/200 12345" > "$T/loadavg"; MARK=$(led $KEY raising_at)
NOW=$((N0+195)) run; SECOND=$OUT; HELD=$(ask_held 1); rm -f "$T/ask.hold.1"; wait "$BG"; unset SALA_BGAGENTS_RAISE_TIMEOUT
[ "$HELD" = yes ] && [ "$(ask_freed 1)" = yes ] && ok "the first run's filing was in flight (held) when the second run ran, and left its hold only when the test released it" || bad "mark overlap not proved: in flight=$HELD freed=$(ask_freed 1)"
[ "$MARK" -ge $((N0+6)) ] && [ "$(calls "$T/spawn.log")" = 0 ] && [[ $SECOND == *"another run is filing its board item"* ]] && ok "the filing mark is the clock when filing begins (after the probes), so a run a whole window after the first one's start still leaves the project alone" || bad "mark at run start: mark=$MARK spawn=$(calls "$T/spawn.log") [$SECOND]"
[ "$(led $KEY raised)" = True ] && [ "$(qcalls)" = 1 ] && ok "...and the first run records its item" || bad "first filing: $(cat "$L")"
# (b) a retry has its own owner: run A's filing outlives its window and fails after run B (the retry, the same request id) took over; A writes nothing, B's mark stays, and a third run stays out.
#     Both filings are held (calls 1 and 2) and released by the test, A's first: the order is decided by the hold files alone
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seedn "$KEY=example"; mark; echo 30 > "$T/loadavg"; : > "$T/ask.hold.1"; : > "$T/ask.hold.2"; export SALA_BGAGENTS_RAISE_TIMEOUT=90
( FAKE_CLIENT_FAIL=1 SALA_BGAGENTS_NOW=$N0 $S > "$T/a.out" 2>&1; echo $? > "$T/a.rc" ) & PA=$!
need_held ask 1; MKA=$(led $KEY raising_at)      # B's clock is A's recorded mark plus the window (195 s), however long A took to get there
( SALA_BGAGENTS_NOW=$((MKA+195)) $S > "$T/b.out" 2>&1; echo $? > "$T/b.rc" ) & PB=$!
need_held ask 2; BOTH=$(ask_held 1)$(ask_held 2)      # both filings are in flight: A's (the expired one) and B's (the retry)
rm -f "$T/ask.hold.1"; wait "$PA"; echo "0.50 0.40 0.30 1/200 12345" > "$T/loadavg"
RF=$(led $KEY raise_failures); MK=$(led $KEY raising_at)
NOW=$((MKA+200)) run; THIRD=$OUT; HELD2=$(ask_held 2); rm -f "$T/ask.hold.2"; wait "$PB"; unset SALA_BGAGENTS_RAISE_TIMEOUT
[ "$BOTH" = yesyes ] && [ "$(ask_freed 1)" = yes ] && [ "$HELD2" = yes ] && [ "$(ask_freed 2)" = yes ] && ok "proof of the overlap: both filings were in flight together (the retry's call 2 held while the expired filing's call 1 failed and while the third run ran), each left its hold only when the test released it" || bad "takeover overlap not proved: both=$BOTH retry still held at the third run=$HELD2 freed=$(ask_freed 1)/$(ask_freed 2)"
[ "$RF" = 0 ] && [ "$MK" -ge $((MKA+195)) ] && ok "the expired filing that fails after its retry began writes nothing: no failure counted, the retry's mark kept" || bad "expired filer wrote: failures=$RF mark=$MK $(cat "$T/a.out")"
[ "$(calls "$T/spawn.log")" = 0 ] && [[ $THIRD == *"another run is filing its board item"* ]] && ok "...so a third run does not start the project under the retry" || bad "retry guard cleared: spawn=$(calls "$T/spawn.log") [$THIRD]"
[ "$(cat "$T/b.rc")" = 0 ] && [ "$(led $KEY raised)" = True ] && [ "$(led $KEY raising_by)" = "" ] && [ "$(led $KEY raise_failures)" = 0 ] && grep -q "took over while this one was in flight" "$T/a.out" && ok "the retry records its item (same request id), and the expired run says its result was not recorded" || bad "retry result: $(cat "$L") [$(cat "$T/a.out")]"
# (c) a liveness answer taken before another run started the same agent is dropped when the lock is taken again (run A's check is held after it decided its answer)
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seedn "$KEY=example"; patch "$KEY" next_try=0 attempts=1 failures=0 retire_needed=false started_at=$((N0-100)); : > "$T/alive.hold.1"
( SALA_BGAGENTS_NOW=$N0 $S > "$T/bg.out" 2>&1; echo $? > "$T/bg.rc" ) & BG=$!
need_held alive 1
NOW=$((N0+1)) run; HELD=$(alive_held 1); rm -f "$T/alive.hold.1"; wait "$BG"
[ "$HELD" = yes ] && [ "$(alive_freed 1)" = yes ] && ok "the first run's liveness check was in flight (held, its answer already decided) when the second run started the agent, and left its hold only when the test released it" || bad "overtaken answer overlap not proved: in flight=$HELD freed=$(alive_freed 1)"
[ "$(calls "$T/spawn.log")" = 1 ] && [ "$(led $KEY started_at)" = $((N0+1)) ] && [ "$(cat "$T/bg.rc")" = 0 ] && grep -q "was overtaken by another run" "$T/bg.out" && ok "a \"not live\" answer is dropped when another run started the agent meanwhile: one start, not two, and the log says so" || bad "stale answer used: spawn=$(calls "$T/spawn.log") $(cat "$L") [$(cat "$T/bg.out")]"
# (d) without a liveness command the names considered still advance probed_at, so the first names do not take the slots every run
reset; : > "$T/list.txt"
for i in 1 2 3; do printf '%s\n' "projects/p$i p$i p$i-main" >> "$T/list.txt"; done; printf '%s\n' "projects/p4 p4 p4-main" >> "$T/list.txt"
seedn "projects/p1=p1" "projects/p2=p2" "projects/p3=p3" "projects/p4=p4"
for i in 1 2 3; do patch "projects/p$i" next_try=0 attempts=1 failures=1 retire_needed=true stale=true; done
SALA_BGAGENTS_ALIVE_CMD= run; SALA_BGAGENTS_ALIVE_CMD= NOW=$((N0+1)) run
[ "$(led projects/p4 raised)" = True ] && [ "$(qcalls)" = 1 ] && [ "$(led projects/p3 probed_at)" = "$N0" ] && ok "no liveness command: the names considered rotate (probed_at advances), so a later project's board item is no longer deferred by the stale ones" || bad "probe slots starved: calls=$(qcalls) $(cat "$L")"
# (e) a check that cannot say blocks the failure item for a given-up project whose pane was started, as for a stale one
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seedn "$KEY=example"; patch "$KEY" started_at=$((N0-100)); echo 7 > "$T/alive.rc"; run
[ "$(qcalls)" = 0 ] && [ "$(led $KEY raised)" = False ] && [ "$(led $KEY started_at)" = $((N0-100)) ] && [[ $OUT == *"could not be told; the entry is left as it is (its pane was started, no board item, no attempt)"* ]] && ok "a given-up project whose pane was started and whose check cannot say: no failure item, nothing changed" || bad "uncertain started given-up: calls=$(qcalls) [$OUT] $(cat "$L")"
rm -f "$T/alive.rc"; NOW=$((N0+1)) run; [ "$(qcalls)" = 1 ] && [ "$(led $KEY raised)" = True ] && ok "...and a confirmed \"not live\" lets the item be filed" || bad "confirmed not live: calls=$(qcalls) $(cat "$L")"
# (g) a start the run attempted makes its earlier "not live" answer out of date: the spawn failed, but the pane is live when the raise looks (the answers, call by call: 1 the start
#     phase "not live", 2 the attempt's own check "not live", 3 the raise phase "live"); the old code kept answer 1 and filed a failed-start item for a live pane
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seedn "$KEY=example"; patch "$KEY" next_try=0 attempts=4 failures=4 retire_needed=false started_at=$((N0-100)); echo fail > "$T/spawn.mode"
printf '1\n1\n0\n' > "$T/alive.seq"; run
[ "$(calls "$T/spawn.log")" = 1 ] && [ "$(calls "$T/alive.log")" = 3 ] && [ "$(qcalls)" = 0 ] && [ "$(led $KEY raised)" = False ] && [ "$(led $KEY stale)" = True ] && [[ $OUT == *"is live while the project is still on the want list"* ]] && ok "a start that failed on its own check but left a live pane: the earlier \"not live\" answer is dropped, the raise phase asks again, no failed-start item" || bad "answer kept after the start: spawn=$(calls "$T/spawn.log") alive=$(calls "$T/alive.log") calls=$(qcalls) $(cat "$L") [$OUT]"
# (h) a filing that fails after another run started the project writes no failure: the retry count and back-off stay, no "board item needed" line
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seedn "$KEY=example"; mark; echo 30 > "$T/loadavg"; : > "$T/ask.hold.1"     # the first filing is held until the second run is done: no sleep decides who is first
# the stub ends a hold by the clock at half the filing timeout (45 s with the 90 s timeout below), so the timeout never fails the held filing; the window is then 2 x 90 + 15 = 195 s, which the second run's clock passes
export SALA_BGAGENTS_RAISE_TIMEOUT=90
( FAKE_CLIENT_FAIL=1 SALA_BGAGENTS_NOW=$N0 $S > "$T/a.out" 2>&1; echo $? > "$T/a.rc" ) & PA=$!
need_held ask 1; MKA=$(led $KEY raising_at); echo "0.50 0.40 0.30 1/200 12345" > "$T/loadavg"
NOW=$((MKA+195)) run; BOUT=$OUT; HELD=$(ask_held 1); rm -f "$T/ask.hold.1"; wait "$PA"; unset SALA_BGAGENTS_RAISE_TIMEOUT
[ "$HELD" = yes ] && [ "$(ask_freed 1)" = yes ] && ok "proof of the overlap: the first filing was still in flight (held) when the second run finished, and left its hold only when the test released it (not by its own clock)" || bad "recovery overlap not proved: in flight=$HELD freed=$(ask_freed 1)"
[ "$(calls "$T/spawn.log")" = 1 ] && [ "$(led $KEY started_at)" -ge $((MKA+195)) ] && ok "the window ran out, a second run started the project during the first one's filing" || bad "second run: spawn=$(calls "$T/spawn.log") $(cat "$L") [$BOUT]"
[ "$(led $KEY raise_failures)" = 0 ] && [ "$(led $KEY raise_next_try)" = 0 ] && [ "$(led $KEY raising_at)" = 0 ] && [ "$(led $KEY raising_by)" = "" ] && [ "$(cat "$T/a.rc")" = 0 ] && ! grep -q "board item needed" "$T/a.out" && grep -q "no longer stuck" "$T/a.out" && ok "the first run's failed filing, for a project that is running now, counts no failure, writes no back-off and says no board item is needed" || bad "late failure written: $(cat "$L") rc=$(cat "$T/a.rc") [$(cat "$T/a.out")]"
# the cap counts the checks made outside the lock (the two windows), not the attempt's own check of its start: with the smallest cap (2) the run above still makes three calls
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; seedn "$KEY=example"; patch "$KEY" next_try=0 attempts=4 failures=4 retire_needed=false started_at=$((N0-100)); echo fail > "$T/spawn.mode"
printf '1\n1\n0\n' > "$T/alive.seq"; SALA_BGAGENTS_MAX_PROBES=2 run
[ "$(calls "$T/alive.log")" = 3 ] && [ "$(qcalls)" = 0 ] && ok "SALA_BGAGENTS_MAX_PROBES counts the two windows (one start-phase and one raise-phase check at cap 2), not the attempt's own check: three calls in all" || bad "cap and the attempt's check: alive=$(calls "$T/alive.log") calls=$(qcalls) [$OUT]"
# ... and the budget is spent: a second project is due for a raise-phase check too, and the run's checks stop at the cap. At cap 2 the start phase took one check (answer dropped after
#     the attempt, still charged), so one raise-phase check is left: the least recently checked project (the second one) gets it, the first one's second check is deferred. Calls: the first
#     project twice (start phase, attempt), the second once. A cap that was ignored, or answers that were dropped and not charged, would make a fourth call.
reset; printf '%s\n%s\n' "$KEY example example-main" "$KEY2 second second-main" > "$T/list.txt"; seedn "$KEY=example" "$KEY2=second"; patch "$KEY" next_try=0 attempts=4 failures=4 retire_needed=false started_at=$((N0-100)); echo fail > "$T/spawn.mode"
printf '1\n1\n1\n1\n' > "$T/alive.seq"; SALA_BGAGENTS_MAX_PROBES=2 run
[ "$(calls "$T/alive.log")" = 3 ] && [ "$(grep -cx "$NAME" "$T/alive.log")" = 2 ] && [ "$(grep -cx "second-engineer" "$T/alive.log")" = 1 ] && [ "$(qcalls)" = 1 ] && [ "$(cat "$T/ask.keys")" = "$KEY2" ] && ok "at the cap the second project's raise-phase check is made and the first project's second check is deferred: three calls, one item (for the project that was checked)" || bad "budget spent: alive=$(tr '\n' ' ' < "$T/alive.log") calls=$(qcalls) keys=$(cat "$T/ask.keys" 2>/dev/null) [$OUT]"
# (i) the stubs claim their call number atomically (an exclusive create), before they signal anything: twelve calls of each stub started together get twelve different numbers, so no two calls can wait on
#     the same hold file or signal the same ready file (a call that counted the log after another had appended its line could take the other's number)
reset; echo pk > "$T/ask.failkey"
for i in $(seq 1 12); do "$T/bin/alive" "n$i" & "$T/bin/ask" --project pk 2>/dev/null & done; wait
got=""; for i in $(seq 1 12); do [ -s "$T/alive.ready.$i" ] && [ -s "$T/ask.ready.$i" ] && [ -e "$T/alive.claim.$i" ] && [ -e "$T/ask.claim.$i" ] && got="$got$i "; done
[ "$got" = "1 2 3 4 5 6 7 8 9 10 11 12 " ] && [ "$(ls "$T"/alive.claim.* "$T"/ask.claim.* | wc -l)" = 24 ] && ok "twelve concurrent calls of each stub take twelve different numbers (claimed before anything is signaled)" || bad "call numbers shared: got [$got] $(ls "$T" | grep -c claim) claims"
# (j) (stdin is /dev/null: the fake client reads its stdin for a question) the stubs record WHY a hold ended where the loop sees it: the clock's deadline is "bound" (nobody removed the file: a 2 s filing timeout gives a 1 s bound), the test's removal is "released"
reset; : > "$T/ask.hold.1"; SALA_BGAGENTS_RAISE_TIMEOUT=2 "$T/bin/ask" --project k < /dev/null > /dev/null 2>&1
[ "$(cat "$T/ask.released.1" 2>/dev/null)" = bound ] && ok "a hold nobody released ends by the clock and is recorded as bound" || bad "bound not recorded: [$(cat "$T/ask.released.1" 2>/dev/null)]"
reset; : > "$T/ask.hold.1"; : > "$T/alive.hold.1"
( SALA_BGAGENTS_RAISE_TIMEOUT=90 "$T/bin/ask" --project k < /dev/null > /dev/null 2>&1 ) & PK=$!; ( "$T/bin/alive" some-name < /dev/null > /dev/null 2>&1 ) & PL=$!
need_held ask 1; need_held alive 1; rm -f "$T/ask.hold.1" "$T/alive.hold.1"; wait "$PK" "$PL"
[ "$(cat "$T/ask.released.1" 2>/dev/null)" = released ] && [ "$(cat "$T/alive.released.1" 2>/dev/null)" = released ] && ok "a hold the test removed is recorded as released (board-item and liveness stubs)" || bad "released not recorded: [$(cat "$T/ask.released.1" 2>/dev/null)] [$(cat "$T/alive.released.1" 2>/dev/null)]"
# (j2) the deadline is read BEFORE the file: a hold whose file the test removes after the deadline has passed (here a deadline that is already up when the loop starts) is "bound", never "released".
#      A handshake, no timing: the stub is held at a gate before its first look; the test removes the hold file, then the gate file; the stub then writes looking.N with what it saw (the file is gone) and enters the loop.
#      The removal is thus certain to come before the first look, on any runner, and a stub that never signals is a setup failure of its own, not a pass or a fail of the check
late_removal ask
[ "$LATE_OK" = 0 ] || { [ "$LATE_LOOK" = gone ] && [ "$LATE_WHY" = bound ] && ok "a file removed after the deadline is recorded as bound (board-item stub)" || bad "ask: at its first look the file was [$LATE_LOOK], the hold was read as [$LATE_WHY]"; }
late_removal alive
[ "$LATE_OK" = 0 ] || { [ "$LATE_LOOK" = gone ] && [ "$LATE_WHY" = bound ] && ok "a file removed after the deadline is recorded as bound (liveness stub)" || bad "alive: at its first look the file was [$LATE_LOOK], the hold was read as [$LATE_WHY]"; }
# (f) the subcommand table describes the shipped timer
! grep -q "No timer is shipped" "$ROOT/docs/subcommands.md" && grep -q 'sala-bg-agents.timer' "$ROOT/docs/subcommands.md" && ok "docs/subcommands.md says the timer ships in systemd/ (not that none ships)" || bad "subcommands.md timer sentence"

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

# -- the record cannot answer (THE SPAWN GATE: sala reads the project record alone and fails closed) -----------------------------------------------
# A spawn that exits 6 because stackshot's record is stale or missing made no pane: it is a failed start (never "waiting for the record", which is exit 3 within the grace), the reason is on the ledger
# and in the output, and the job asks no page reader (there is none): the start is counted as NOT placed and says why.
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo blind > "$T/spawn.mode"
run; [ "$RC" = 1 ] && [ "$(led $KEY failures)" = 1 ] && [ "$(led $KEY awaiting_record)" = False ] && [ -z "$(led $KEY started_at)" -o "$(led $KEY started_at)" = 0 ] && [[ $OUT == *"exit 6"* && $OUT == *"project record cannot answer"* ]] \
    && ok "spawn exit 6 (the record cannot answer): a failed start with the record's reason, never waited out as a lag, no started time" || bad "blind spawn: rc=$RC [$OUT] $(cat "$L")"
echo ok > "$T/spawn.mode"

# -- placed: a live session is a start only when its project holds it three ways -----------------------------------------------------------------
# The links: (1) stackshot's project record lists the name on the project as a back agent, (2) roles.json has a live entry for it on the project, (3) sala's registry row (the alive stub's --json answer) carries the project and the role back.
# A real start (the spawn stub) sets all three; place.skip leaves one out, and a case then writes that link's wrong answer itself. A miss fails the attempt (no start counted, back-off as for any failure, the pane left running), is told once
# by a Slack post (the alert stub) and raises the board item (the fake client), and the reason names the link that disagrees.
roles() {   # <name> <project> <live: true|false> [role, default back] → a fresh roles.json (written at the fake clock) with that one entry
    python3 - "$T/roles.json" "$NOW" "$@" <<'PY'
import datetime, json, sys
path, now, name, proj, live, *role = sys.argv[1:]
gen = datetime.datetime.fromtimestamp(float(now), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"generated": gen, "sessions": {name: {"role": role[0] if role else "back", "project": proj, "live": live == "true"}}}, open(path, "w"))
PY
}
placed_miss() {   # <label> <what the reason says after "<name> started but "> [text the reason must NOT hold…]: the checks every failed read-back shares (a case has just run)
    local label=$1 want=$2 x why good=1; shift 2; why=$(led $KEY unplaced)
    [ "$RC" = 0 ] && [ "$(led $KEY started_at)" = 0 ] && [ "$(led $KEY attempts)" = 1 ] && [ "$(led $KEY failures)" = 1 ] || good=0       # not a start
    [ "$(led $KEY next_try)" -ge $((N0+600)) ] && [ "$(led $KEY next_try)" -le $((N0+660)) ] || good=0       # the back-off of any failure, counted from the failure (the fake clock runs on with the process: a run is a few seconds at most)
    [[ $why == "$NAME started but $want"* ]] && [ "$(led $KEY last)" = "failed: $why" ] || good=0
    for x in "$@"; do [[ $why == *"$x"* ]] && good=0; done
    grep -qx -- "$NAME" "$T/alive.txt" && [ "$(led $KEY retire_needed)" = False ] && [[ $OUT != *"retire needed"* ]] || good=0       # the pane is left running; nothing to retire
    [ "$(calls "$T/alert.log")" = 1 ] && [ "$(head -1 "$T/alert.log")" = "$why" ] || good=0       # one Slack post, the reason as its headline
    [ "$(qcalls)" = 1 ] && [[ $(qfield 1 stdin) == *"${why:1}"* ]] && [ "$(led $KEY raised)" = True ] || good=0       # one board item that says it
    [ "$(grep -c ' failed ' "$SALA_STATE_DIR/bgagents.log")" = 1 ] || good=0
    [ "$good" = 1 ] && ok "$label" || bad "$label: rc=$RC [$OUT] $(cat "$L" 2>/dev/null) alert=[$(cat "$T/alert.log" 2>/dev/null)]"
}
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; run
[ "$RC" = 0 ] && [ "$(led $KEY started_at)" = "$N0" ] && [ "$(led $KEY unplaced)" = "" ] && [ "$(led $KEY last)" = started ] && [[ $OUT == *"is live and placed"* ]] && [ "$(calls "$T/alert.log")" = 0 ] && [ "$(qcalls)" = 0 ] && ok "the record, roles.json and the row all place it: the start counts, no Slack post, no board item" || bad "all three agree: rc=$RC [$OUT] $(cat "$L")"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo record > "$T/place.skip"; record "$KEY" other-agent; run
placed_miss "the record does not list it (roles.json and the row do): the attempt fails with the record named" "the record does not list it on $KEY" "roles.json" "sala's row"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo record > "$T/place.skip"; record_front() { record "$@"; sed -i 's/"front": false/"front": true/' "$T/projects.json"; }; record_front "$KEY" "$NAME"; run
placed_miss "the record lists it as a front agent: it does not place a back agent" "the record does not list it on $KEY as a back agent" "roles.json" "sala's row"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo roles > "$T/place.skip"; roles other-agent "$KEY" true; run
placed_miss "roles.json does not list it (the record and the row do): the attempt fails with roles.json named" "roles.json does not list it on $KEY" "the record" "sala's row"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo roles > "$T/place.skip"; roles "$NAME" "$KEY" false; run
placed_miss "roles.json lists it but not as a live session: it does not place it" "roles.json does not list it on $KEY as a live session" "the record" "sala's row"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo roles > "$T/place.skip"; roles "$NAME" "${KEY#projects/}" true; run
[ "$(led $KEY started_at)" = "$N0" ] && [ "$(calls "$T/alert.log")" = 0 ] && ok "roles.json may name the project by its bare slug (the row's page key and the slug are the same project)" || bad "slug: [$OUT] $(cat "$L")"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo projects/other > "$T/row.project"; run
placed_miss "sala's row names another project: the attempt fails with the row named" "sala's row does not list it on $KEY" "the record" "roles.json"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo front > "$T/row.role"; run
placed_miss "sala's row carries the project but the role front: it does not place a back agent" "sala's row does not list it on $KEY as a back agent" "the record" "roles.json"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo roles > "$T/place.skip"; roles "$NAME" "$KEY" true front; run
placed_miss "roles.json lists it on the project, live, but with the role front: it does not place a back agent (only roles.json disagrees)" "roles.json does not list it on $KEY as a back agent" "the record" "sala's row"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo another-engineer > "$T/row.name"; run
placed_miss "sala's row is another session's (the registry answers a renamed session's old name with the renamed session's row): it does not place this one" "sala's row does not list it on $KEY under its own name" "the record" "roles.json"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo "record roles" > "$T/place.skip"; record "$KEY" other-agent; roles other-agent "$KEY" true; run
placed_miss "two links disagree: the reason names both and not the third" "the record does not list it on $KEY; roles.json does not list it on $KEY" "sala's row"
# a link that cannot answer is a miss, never a pass
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo record > "$T/place.skip"; NOW=$((N0-5000)) record "$KEY" "$NAME"; run
placed_miss "a stale record cannot answer: the attempt fails and says the record could not be read (stale)" "the record could not be read (it is stale" "roles.json" "sala's row"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo record > "$T/place.skip"; echo garbage > "$T/projects.json"; run
placed_miss "an unreadable record cannot answer: the attempt fails and says so" "the record could not be read (it is unreadable)" "roles.json" "sala's row"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo roles > "$T/place.skip"; run
placed_miss "a missing roles.json cannot answer: the attempt fails and says so" "roles.json could not be read (it is missing)" "the record" "sala's row"
# the read-back reads again until its deadline, and fails only then; the miss is told once per attempt, not once per read
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo 3 > "$T/row.lag"; SALA_BGAGENTS_PLACE_WAIT=20 run
[ "$(led $KEY started_at)" = "$N0" ] && [ "$(calls "$T/row.calls")" = 4 ] && [ "$(calls "$T/alert.log")" = 0 ] && [ "$(led $KEY failures)" = 0 ] && ok "a link that lags (the row has no project for three reads) is waited out inside the deadline: the start counts, no failure, no post" || bad "lag: [$OUT] reads=$(calls "$T/row.calls") $(cat "$L")"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo 1000 > "$T/row.lag"; t0=$SECONDS; SALA_BGAGENTS_PLACE_WAIT=2 run; el=$((SECONDS - t0))
placed_miss "a link that never catches up fails at the deadline (2 s here)" "sala's row does not list it on $KEY" "the record" "roles.json"
[ "$(calls "$T/row.calls")" -ge 3 ] && [ "$el" -ge 2 ] && ok "...after reading again and again (at least three reads) and not before the deadline, yet ONE Slack post, ONE board item and ONE failed line for the attempt" || bad "polls: reads=$(calls "$T/row.calls") elapsed=${el}s"
# the registry command is given only the time left to the deadline, never a fixed 30 s past it: a registry that answers slowly from the second read on ends the read-back at the deadline (4 s here), not half a minute later
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo 1000 > "$T/row.lag"; echo 40 > "$T/row.sleep"; echo 2 > "$T/row.sleep.from"; t0=$SECONDS; SALA_BGAGENTS_PLACE_WAIT=4 run; el=$((SECONDS - t0))
placed_miss "a slow registry: the read-back fails at its deadline with the row named as unreadable" "sala's row could not be read (the registry could not be asked (exit 124))" "the record" "roles.json"
[ "$el" -ge 3 ] && [ "$el" -le 12 ] && [ "$(calls "$T/row.calls")" = 2 ] && ok "...and returns near the 4 s deadline (took $el seconds, not 30 s after it): the slow read was cut at the time left" || bad "slow registry: read-back took $el seconds, reads=$(calls "$T/row.calls") [$OUT]"
# the back-off counts from the failure, not from the start of the run: a read-back that waited 3 s leaves next_try at the failure time plus the cooldown
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo 1000 > "$T/row.lag"; SALA_BGAGENTS_PLACE_WAIT=3 run
nt=$(led $KEY next_try); la=$(led $KEY last_at)
[ "$nt" -ge $((N0+603)) ] && [ "$nt" = $((la+600)) ] && [ "$la" -ge $((N0+3)) ] && ok "a placement failure after a 3 s wait: next_try is the failure's own time plus the cooldown (the wait is not taken out of it)" || bad "back-off from the run's start: next_try=$nt last_at=$la (run at $N0)"
# the pane is left running, so the next run's attempt reads the three links again and counts the start once they agree
rm -f "$T/row.lag" "$T/alert.log" "$T/alert.lines"; $S --reset "$KEY" >/dev/null 2>&1; run
[ "$(led $KEY started_at)" = "$N0" ] && [ "$(led $KEY unplaced)" = "" ] && [ "$(led $KEY raised)" = False ] && [ "$(calls "$T/alert.log")" = 0 ] && ok "after the owner's reset the pane (still running) is placed and the next attempt counts it as a start" || bad "retry: [$OUT] $(cat "$L")"
# the Slack post is the job's own report of a miss; the attempt fails the same without it, and a refused post changes nothing
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo projects/other > "$T/row.project"; SALA_BGAGENTS_ALERT_CMD= run
[ "$RC" = 0 ] && [ "$(led $KEY started_at)" = 0 ] && [ "$(led $KEY failures)" = 1 ] && [ "$(qcalls)" = 1 ] && [[ $OUT == *"no alert command"* ]] && ok "no alert command: said in one line, the attempt still fails and raises its board item" || bad "no alert cmd: rc=$RC [$OUT]"
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; echo projects/other > "$T/row.project"; echo 1 > "$T/alert.rc"; run
[ "$RC" = 0 ] && [ "$(led $KEY started_at)" = 0 ] && [ "$(led $KEY failures)" = 1 ] && [ "$(qcalls)" = 1 ] && [[ $OUT == *"the Slack post failed"* ]] && ok "a Slack post that fails is one line: the attempt, its back-off and its board item are as they were" || bad "alert fails: rc=$RC [$OUT]"
run --status; [[ $OUT == *"started but not placed on the project"* ]] && ok "--status shows the project as started but not placed" || bad "status unplaced: [$OUT]"

# a project that is unplaced and was already on the map (no listing, posted_at stays 0) and that left the want list still owes its board item: a filing that failed is tried again, and once it is raised it is not filed again
# (the fake client counts a refused filing as a call: one call for the failed filing, a second for the one that works)
reset; printf '%s\n' "$KEY example example-main" > "$T/list.txt"; record "$KEY" "$NAME"; echo projects/other > "$T/row.project"; export FAKE_CLIENT_FAIL=1; run
[ "$(led $KEY posted_at)" = 0 ] && [ "$(led $KEY unplaced)" != "" ] && [ "$(led $KEY raised)" = False ] && [ "$(led $KEY raise_failures)" = 1 ] && [ "$(calls "$T/post.log")" = 0 ] && ok "the agent was on the map (no listing made, posted_at 0), the start is unplaced and the first filing fails: raised stays false" || bad "premise: [$OUT] $(cat "$L")"
unset FAKE_CLIENT_FAIL; : > "$T/list.txt"; NOW=$((N0+100)) run
[ "$(qcalls)" = 1 ] && [ "$(led $KEY raised)" = False ] && [[ $OUT == *"board item still needed: $KEY"* ]] && ok "off the want list, within its filing back-off: the entry is kept and says the item is still needed" || bad "off the list: calls=$(qcalls) [$OUT] $(cat "$L")"
NOW=$((N0+800)) record "$KEY" "$NAME"; NOW=$((N0+800)) run
[ "$(qcalls)" = 2 ] && [ "$(led $KEY raised)" = True ] && [[ $(led $KEY raised_item) == board#* ]] && ok "the next run files it although the project left the want list (it is not pruned for being off it, and it is not forgotten)" || bad "refile: calls=$(qcalls) [$OUT] $(cat "$L")"
NOW=$((N0+5000)) record "$KEY" "$NAME"; NOW=$((N0+5000)) run
[ "$(qcalls)" = 2 ] && ok "and once raised it is not filed again" || bad "filed twice: calls=$(qcalls) [$OUT]"

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
