#!/usr/bin/env bash
# Sleeping sessions, the SLEEP OF INACTIVE PROJECTS (lib/wrapup.sh sleep_project_check, sleep_candidates, sleep_report, sleep_locked, sleep_activity_load; lib/sleep.sh --project,
# --pin, --unpin, --pins, --candidates; lib/sessions.py project-sessions): the watch's idle sleep tick sleeps whole PROJECTS, never one session. A project sleeps, all of its
# sessions together (front agents too), only when it is quiet (no external anchor notice and no input from its owner for SALA_SLEEP_QUIET, from a stub of stackshot's
# `client.py project-activity --json` named by SALA_ACTIVITY_CMD), every one of its sessions is idle with nothing in flight, and it is not pinned. What is checked, on a
# private tmux server with the compiled fake claude and eight projects (p-alpha 3 sessions, p-beta, p-gamma, p-delta, p-eps, p-theta, p-iota 2 each, and one background
# agent with no project):
#  - the grouping: `sessions.py project-sessions` lists each live agent under its project with its role, and leaves out a row with no project;
#  - `sala config` prints SALA_SLEEP_QUIET (172800), SALA_SLEEP_PER_TICK (1) and SALA_ACTIVITY_CMD;
#  - off (the default): a full tick and `watch --sleep` put nothing to sleep, however quiet the projects are;
#  - the candidates: `sala sleep --candidates` and `watch --sleep --dry-run` print one line per project (sleeping, awake or pinned; the two quiet ages; the first reason it is
#    not a candidate): a recent anchor notice, a recent input from the owner, a pin and one session with work in flight each keep their whole project awake, the quietest
#    project is marked for the next run and the others wait (one project per run); a background agent with no project is on no line;
#  - fail safe: an activity command that fails (with its stderr line shown), prints nothing, prints something that is not the answer, an empty answer or does not answer in
#    time sleeps nothing, on or off the dry run; a project the answer does not list has had neither (never) and is quiet; a key written `projects/<key>` is read as `<key>`;
#  - in flight in any one session blocks the whole project (a message line waiting for one background agent holds its project, front agent included);
#  - on: SALA_SLEEP_PER_TICK=0 sleeps nothing; a tick puts the quietest project's sessions to sleep together (markers, claude ended, tmux sessions and pane-map rows kept, one
#    watch-log line for the project), a project in its retry wait is skipped and the next one takes its turn, the others run on; a background agent is never put to sleep
#    alone: not with its project awake, not with no project;
#  - `sala sleep --project`: refused with the reason for a project that is not a candidate (and as a dry run), nothing touched;
#  - pins: `--pin KEY [--why TEXT]`, `--unpin KEY`, `--pins`; a pinned project never sleeps and is shown as pinned, a `projects/` prefix is read as the key, a bad key is
#    refused, the files live beside the marker folder, never in it, and an unpinned quiet project is a candidate again;
#  - waking is per session: a message line for one sleeper wakes that session only, the rest of its project stays asleep, the woken one holds the project back for
#    SALA_SLEEP_AFTER and sleeps again, alone, once its wake stamp is old.
# SAFETY: every kill is a `kill -9` of ONE pid whose /proc/<pid>/exe is this suite's own compiled fake and whose environment names this suite's temporary HOME
# (kill_fake_claude); the tmux server is a private socket (tmux -L sala-sleepproject-<pid> -f /dev/null, SALA_TMUX_SOCKET pointing at it), HOME is a mktemp -d
# held with flock, the claude is tests/fake-claude.c; the activity source is a stub file or command inside that HOME; no real pane, server, ~/.claude or claude process is
# read or touched. Posts go to a file.
# Usage: bash tests/sleepproject.sh   (exit 0 = pass)
set -u
unset TMUX TMUX_PANE XDG_STATE_HOME SALA_MASTER SALA_SET SALA_SET_SELF SALA_RECYCLE SALA_RETRY_WORKER SALA_LOCK_WHO SALA_LOCK_WAIT SALA_RELAUNCH_KIND SALA_SLEEP_DIR \
      SALA_FLEET_HOSTS SALA_CGROUP_FILE SALA_OP_QUEUE SALA_NO_RELAUNCH SALA_BOOT_ID SALA_CONFIG SALA_BARE_REVIVE SALA_IDLE_WRAPUP SALA_SESSION_ID SALA_STACKSHOT_INBOX \
      SALA_STACKSHOT_DIR SALA_STACKSHOT_CLIENT SALA_AGENT_CHECK_SCRIPT SALA_PROJECT_RECORD SALA_ROLES_FILE SALA_OP_ID SALA_OP_FROM SALA_OP_REASON_FROM \
      SALA_IDLE_SLEEP SALA_SLEEP_AFTER SALA_SLEEP_PER_TICK SALA_WAKE_PER_RUN SALA_SLEEP_RETRY SALA_WAKE_RETRY SALA_SLEEP_QUIET SALA_ACTIVITY_CMD SALA_ACTIVITY_TIMEOUT SALA_SLEEP_PIN_DIR
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
SANDBOX=""; SOCK="sala-sleepproject-$$"; T="tmux -L $SOCK -f /dev/null"
cleanup() {
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    [ -z "$SANDBOX" ] || { kill_fake_claude "$FAKEBIN"; exec 8<&-; rm -rf "$SANDBOX" 2>/dev/null; }
    true
}; trap cleanup EXIT   # set before the temp folder exists
SANDBOX=$(mktemp -d); export HOME=$SANDBOX SALA_TZ=Etc/UTC SALA_CONFIG=/dev/null
case "$HOME" in /tmp/*|"${TMPDIR:-/tmp}"/*) ;; *) echo "sleepproject: HOME is not a temporary directory ($HOME) - refusing to run"; exit 1;; esac
exec 8< "$SANDBOX"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
as_op_unit   # the guarded verbs this suite runs itself stand for the queue's runner (tests/lib.sh, 5)
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOME/.claude-team" "$HOME/work"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
printf '{"fake":true}\n' > "$HOME/.claude-team/.credentials.json"
FAKEBIN="$HOME/.local/share/claude/versions/9.9.9"
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$FAKEBIN" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }
ln -s "$FAKEBIN" "$HOME/.local/bin/claude"
printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/systemd-run"
cat > "$HOME/.local/bin/systemctl" <<'EOF'
#!/bin/bash
case "$*" in *is-active*) exit 3 ;; *is-system-running*) echo running; exit 0 ;; *cat*tmux.service*) exit 1 ;; *) exit 0 ;; esac
EOF
chmod +x "$HOME/.local/bin/systemd-run" "$HOME/.local/bin/systemctl"
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log" FAKE_TYPED_LOG="$HOME/typed.log"
POSTS="$HOME/posts.txt"; : > "$POSTS"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off SALA_SNAPSHOT_CMD="touch $HOME/snap.done"
export SALA_LIMIT_ALERT=off SALA_LIMIT_RESUME=off SALA_STUCK_POST=off   # the other watches: not under test
export SALA_OP_STUCK=off SALA_OP_QUEUE=off SALA_BARE_REVIVE=off   # a queued marker is written and nothing starts it; no bare-pane heal runs beside the passes under test
SALA="$ROOT/bin/salamander"
export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's
case "$SOCK" in sala-sleepproject-*) ;; *) echo "sleepproject: not a private socket - refusing to run"; exit 1;; esac
WLOG="$HOME/.claude/salamander-watch.log"; : > "$WLOG"
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux    # literal socket: the children run set -u
$T new-session -d -s sala-test-keep -x 200 -y 50 -c "$HOME"; $T set -g exit-empty off   # a server that outlives its last fake
. "$ROOT/lib/common.sh"; . "$ROOT/lib/wrapup.sh"
MAP="$SALA_SIDECAR"
now0=$(date +%s); START=$((now0 - 10800)); TURN=$((now0 - 7200))   # the fakes' process started 3 h ago; their last turn ended 2 h ago
mk() {  # <suffix> <uuid n> [tmux -e options…] → a fake claude in sala-test-<suffix>
    local n="$1" u; u=$(uuid "$2"); shift 2
    $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="sala-test-$n" -e FAKE_LOG="$FAKE_LOG" -e FAKE_TYPED_LOG="$FAKE_TYPED_LOG" \
        -e FAKE_STARTED_AT="$START" -e FAKE_TURN_MS=1500 "$@"
    $T send-keys -t "sala-test-$n" 'claude' Enter
}
hasclaude() { local pp; pp=$($T list-panes -t "=sala-test-$1" -F '#{pane_pid}' 2>/dev/null | head -1); [ -n "$pp" ] && [ -n "$(claude_pid_under "$pp" 2>/dev/null)" ]; }   # <suffix>
n_starts() { starts "$(uuid "$1")"; }
row() { awk -F'\t' -v s="$1" '$1==s' "$MAP" 2>/dev/null; }
run() { OUT=$("$SALA" "$@" 2>&1); RC=$?; }   # → OUT, RC (stderr in OUT)
tick() { "$SALA" watch >/dev/null 2>&1; }
stoprec() { mkdir -p "$SALA_BUSY_DIR"; printf 'id=t%s\nepoch=%s\nseen=\nseen_status=idle\ntasks=0\ncrons=%s\n' "$1" "$TURN" "${2:-0}" > "$SALA_BUSY_DIR/$(uuid "$1")"; }   # <uuid n> [crons]: the Stop hook's record of a finished turn
wlogn() { grep -c -- "$1" "$WLOG" 2>/dev/null || true; }
nmarkers() { ls "$SALA_SLEEP_DIR" 2>/dev/null | grep -c . || true; }
asleep() { [ -f "$SALA_SLEEP_DIR/$(uuid "$1")" ]; }   # <uuid n>
export SALA_SLEEP_DIR   # the children read the same directory (its default under SALA_STATE_DIR)
ACT="$HOME/activity.json"
setact() {  # <key seconds-ago-of-the-anchor-or--  seconds-ago-of-the-owner's-input-or--> … → the stub's answer: stackshot's `project-activity --json` shape
    python3 -I - "$ACT" "$(date +%s)" "$@" <<'PY'
import json, sys
out, now, args = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
d = {}
for i in range(0, len(args), 3):
    k, a, o = args[i:i + 3]
    d[k] = {"anchor": None if a == "-" else now - int(a), "owner": None if o == "-" else now - int(o)}
json.dump({"projects": d}, open(out, "w"))
PY
}
D=86400
export SALA_ACTIVITY_CMD="cat $ACT"
mkp() {  # <project> <suffix> <role> <uuid n> [idle age] → a fake claude in sala-test-<suffix>, tagged into the project after the adopt (below)
    mk "$2" "$4" -e FAKE_IDLE_AGE="${5:-4000}"
}

echo "== setup: private tmux server, isolated HOME, the compiled fake claude, eight projects (alp: main + 2 back · bet, gam, del, eps, the, iot: main + back · orp: a back agent with no project)"
mk alp-main 41 -e FAKE_IDLE_AGE=4000; mk alp-eng 42 -e FAKE_IDLE_AGE=4000; mk alp-aud 43 -e FAKE_IDLE_AGE=4000
mk bet-main 44 -e FAKE_IDLE_AGE=4000; mk bet-eng 45 -e FAKE_IDLE_AGE=4000
mk gam-main 46 -e FAKE_IDLE_AGE=4000; mk gam-eng 47 -e FAKE_IDLE_AGE=4000
mk del-main 48 -e FAKE_IDLE_AGE=4000; mk del-eng 49 -e FAKE_IDLE_AGE=4000
mk eps-main 50 -e FAKE_IDLE_AGE=4000; mk eps-eng 51 -e FAKE_IDLE_AGE=4000
mk the-main 52 -e FAKE_IDLE_AGE=4000; mk the-eng 53 -e FAKE_IDLE_AGE=4000
mk iot-main 54 -e FAKE_IDLE_AGE=4000; mk iot-eng 55 -e FAKE_IDLE_AGE=4000
mk orp-eng 56 -e FAKE_IDLE_AGE=4000
ALL="alp-main alp-eng alp-aud bet-main bet-eng gam-main gam-eng del-main del-eng eps-main eps-eng the-main the-eng iot-main iot-eng orp-eng"
fake_up $(for n in $ALL; do printf 'sala-test-%s ' "$n"; done) || exit 1
for n in $ALL; do "$SALA" adopt "sala-test-$n" >/dev/null 2>&1 || bad "adopt sala-test-$n failed"; done
for p in "alpha alp-main front" "alpha alp-eng back" "alpha alp-aud back" "beta bet-main front" "beta bet-eng back" "gamma gam-main front" "gamma gam-eng back" "delta del-main front" "delta del-eng back" \
         "eps eps-main front" "eps eps-eng back" "theta the-main front" "theta the-eng back" "iota iot-main front" "iota iot-eng back"; do
    set -- $p; "$SALA" sessions tag "sala-test-$2" --project "projects/p-$1" --role "$3" >/dev/null 2>&1 || bad "tag $2 failed"
done
"$SALA" sessions tag sala-test-orp-eng --role back >/dev/null 2>&1 || bad "tag orp-eng failed"   # a background role and no project
for u in 41 42 43 44 45 46 47 48 49 50 52 53 54 55 56; do stoprec "$u"; done; stoprec 51 1   # eps-eng: its last turn left a scheduled job
[ "$($T display -p '#{socket_path}')" = "$SALA_TMUX_SOCKET" ] && ok "the tmux server is the suite's private socket ($SOCK)" || bad "socket: $($T display -p '#{socket_path}')"
rows0=$(for n in $ALL; do row "sala-test-$n"; done)

echo "== the grouping: sessions.py project-sessions lists each live agent under its project with its role, and not a row with no project"
G=$(sessions_py project-sessions 2>&1 | paste -sd' ')
WANT="p-alpha sala-test-alp-aud back p-alpha sala-test-alp-eng back p-alpha sala-test-alp-main front p-beta sala-test-bet-eng back p-beta sala-test-bet-main front p-delta sala-test-del-eng back p-delta sala-test-del-main front p-eps sala-test-eps-eng back p-eps sala-test-eps-main front p-gamma sala-test-gam-eng back p-gamma sala-test-gam-main front p-iota sala-test-iot-eng back p-iota sala-test-iot-main front p-theta sala-test-the-eng back p-theta sala-test-the-main front"
G=$(sessions_py project-sessions 2>&1 | tr '\t\n' '  ' | sed 's/ $//')
[ "$G" = "$WANT" ] && ok "15 agents under 7 projects, key without its projects/ prefix, roles as tagged; orp-eng (a role, no project) is not listed" || bad "project-sessions: $G"
cp "$SALA_SESSIONS_FILE" "$HOME/reg.before"; sessions_py project-sessions >/dev/null 2>&1; cmp -s "$SALA_SESSIONS_FILE" "$HOME/reg.before" && ok "project-sessions is read-only (the registry file is as before)" || bad "project-sessions wrote"

echo "== sala config prints the knobs; SALA_IDLE_SLEEP is off unless it is set"
run config
echo "$OUT" | grep -qE '^SALA_IDLE_SLEEP +off$' && echo "$OUT" | grep -qE '^SALA_SLEEP_QUIET +172800$' && echo "$OUT" | grep -qE '^SALA_SLEEP_PER_TICK +1$' && has "$OUT" "SALA_ACTIVITY_CMD" && ok "config: SALA_IDLE_SLEEP off, SALA_SLEEP_QUIET 172800, SALA_SLEEP_PER_TICK 1, SALA_ACTIVITY_CMD listed" || bad "config: $(echo "$OUT" | grep SLEEP)"
grep -q '^#SALA_SLEEP_QUIET=' "$ROOT/config.example" && grep -q '^#SALA_ACTIVITY_CMD=' "$ROOT/config.example" && ok "config.example documents SALA_SLEEP_QUIET and SALA_ACTIVITY_CMD" || bad "config.example lacks them"

echo "== the pins (before anything runs): --pin, --pins, a projects/ prefix, a bad key; the files stand beside the marker folder"
run sleep --pins; [ "$RC" = 0 ] && has "$OUT" "no project is pinned" && ok "--pins with none: says so" || bad "pins none: rc=$RC $OUT"
run sleep --pin projects/p-delta --why "keeps its own hours"
[ "$RC" = 0 ] && has "$OUT" "p-delta: pinned" && has "$OUT" "keeps its own hours" && [ -f "$SALA_SLEEP_DIR.pins/p-delta" ] && ok "--pin projects/p-delta: pinned as p-delta, the file stands in $(basename "$SALA_SLEEP_DIR").pins, beside the marker folder" || bad "pin: rc=$RC $OUT; $(ls -A "$SALA_SLEEP_DIR.pins" 2>&1)"
run sleep --pins; [ "$RC" = 0 ] && has "$OUT" "p-delta" && has "$OUT" "pinned since" && has "$OUT" "keeps its own hours" && ok "--pins lists it with its time and its reason" || bad "pins: rc=$RC $OUT"
run sleep --pin "../x"; [ "$RC" != 0 ] && has "$OUT" "not a project key" && [ ! -e "$HOME/x" ] && ok "a key with a slash is refused" || bad "bad key: rc=$RC $OUT"
run sleep --pin p-a --unpin p-b; [ "$RC" != 0 ] && has "$OUT" "stand alone" && ok "--pin and --unpin together are refused" || bad "two modes: rc=$RC $OUT"
run sleep --pin p-eps sala-test-alp-main; [ "$RC" != 0 ] && has "$OUT" "takes no session name" && ok "--pin with a session name is refused" || bad "pin + name: rc=$RC $OUT"
run sleep --why because; [ "$RC" != 0 ] && has "$OUT" "--why goes with --pin" && ok "--why alone is refused" || bad "why alone: rc=$RC $OUT"
[ ! -e "$SALA_SLEEP_DIR" ] || [ "$(nmarkers)" = 0 ] && ok "no marker was written by a pin" || bad "markers: $(ls "$SALA_SLEEP_DIR")"

echo "== the activity (a stub): alpha 3 d since an anchor notice and 5 d since the owner · beta an anchor notice 1 h ago · gamma the owner 1 h ago · delta quiet but pinned · eps quiet, one session with a scheduled job · theta 10 d · iota 8 d (never an input)"
setact p-alpha $((3 * D)) $((5 * D))  p-beta 3600 -  p-gamma - 3600  p-delta $((9 * D)) $((9 * D))  p-eps $((6 * D)) $((6 * D))  p-theta $((10 * D)) $((12 * D))  p-iota $((8 * D)) -

echo "== OFF (the default): a full tick and watch --sleep put nothing to sleep, however quiet the projects are"
tick; "$SALA" watch --sleep >/dev/null 2>&1; SALA_IDLE_SLEEP=maybe tick; SALA_IDLE_SLEEP=off "$SALA" watch --sleep >/dev/null 2>&1
[ "$(nmarkers)" = 0 ] && ok "no marker was written" || bad "markers: $(ls "$SALA_SLEEP_DIR")"
ALLUP=1; for n in $ALL; do hasclaude "$n" || { ALLUP=0; bad "$n lost its claude with the tick off"; }; done; [ "$ALLUP" = 1 ] && ok "every claude still runs (off, unset, garbage and =off alike)"
[ "$(wlogn 'sleep:')" = 0 ] && ok "the watch log has no 'sleep:' line" || bad "log: $(grep 'sleep:' "$WLOG")"

echo "== the candidates: one line per project, on or off, nothing changed"
run sleep --candidates; CAND=$OUT; CRC=$RC
[ "$CRC" = 0 ] && has "$CAND" "SALA_IDLE_SLEEP is off" && has "$CAND" "at most 1 project(s)" && ok "sleep --candidates: exit 0, says the tick is off and that it takes one project per run" || bad "candidates: rc=$CRC — $CAND"
[ "$(grep -c '^p-' <<< "$CAND")" = 7 ] && ok "seven lines, one per project" || bad "lines: $CAND"
L=$(grep '^p-theta:' <<< "$CAND"); has "$L" "would be put to sleep" && has "$L" "awake" && has "$L" "10 d" && has "$L" "12 d" && has "$L" "sala-test-the-main" && has "$L" "sala-test-the-eng" && ok "theta (the quietest, 10 d): would be put to sleep, with its two quiet ages and its two sessions, the front agent too" || bad "theta: $L"
L=$(grep '^p-iota:' <<< "$CAND"); has "$L" "waits for a later run" && has "$L" "8 d" && has "$L" "never" && ok "iota (8 d, never an input): ready, waits for a later run (the cap is one project)" || bad "iota: $L"
L=$(grep '^p-alpha:' <<< "$CAND"); has "$L" "waits for a later run" && has "$L" "3 d" && has "$L" "5 d" && ok "alpha (3 d / 5 d): ready, waits for a later run" || bad "alpha: $L"
L=$(grep '^p-beta:' <<< "$CAND"); has "$L" "not a candidate" && has "$L" "not quiet: an external anchor notice 1 h" && ok "beta: a recent anchor notice keeps the whole project awake, and the line says how long ago" || bad "beta: $L"
L=$(grep '^p-gamma:' <<< "$CAND"); has "$L" "not a candidate" && has "$L" "not quiet: input from its owner 1 h" && ok "gamma: a recent input from the owner keeps the whole project awake" || bad "gamma: $L"
L=$(grep '^p-delta:' <<< "$CAND"); has "$L" "pinned" && has "$L" "not a candidate" && has "$L" "keeps its own hours" && has "$L" "--unpin p-delta" && ok "delta: shown as pinned, with the reason and how to lift it" || bad "delta: $L"
L=$(grep '^p-eps:' <<< "$CAND"); has "$L" "not a candidate" && has "$L" "sala-test-eps-eng: its last turn left a scheduled job" && ok "eps: one session with work in flight (eps-eng, a scheduled job) keeps the whole project awake, eps-main (idle) with it" || bad "eps: $L"
! has "$CAND" "orp-eng" && ok "the background agent with no project is on no line: it is never a candidate alone" || bad "orp-eng listed: $CAND"
DRY=$("$SALA" watch --sleep --dry-run 2>&1); [ "$DRY" = "$CAND" ] && ok "watch --sleep --dry-run (off): the same lines" || bad "watch --sleep --dry-run: $DRY"
DRYON=$(SALA_IDLE_SLEEP=on "$SALA" watch --sleep --dry-run 2>&1); [ "$(grep -c '^p-' <<< "$DRYON")" = 7 ] && ! has "$DRYON" "is off" && ok "watch --sleep --dry-run (on): the same project lines, no 'off' line" || bad "dry on: $DRYON"
OUT=$(SALA_SLEEP_PER_TICK=2 "$SALA" sleep --candidates 2>&1); [ "$(grep -c 'would be put to sleep' <<< "$OUT")" = 2 ] && has "$(grep '^p-iota:' <<< "$OUT")" "would be put to sleep" && ok "the cap is the knob: with SALA_SLEEP_PER_TICK=2 theta and iota are marked" || bad "cap 2: $OUT"
OUT=$(SALA_SLEEP_QUIET=$((6 * D)) "$SALA" sleep --candidates 2>&1); has "$(grep '^p-alpha:' <<< "$OUT")" "not quiet: an external anchor notice 3 d" && has "$(grep '^p-iota:' <<< "$OUT")" "would be put to sleep" || true
has "$(grep '^p-alpha:' <<< "$OUT")" "it needs 144 h of quiet" && ok "SALA_SLEEP_QUIET is the knob: with 6 days alpha (3 d) is no longer quiet, iota (8 d) still is" || bad "quiet 6 d: $OUT"
run sleep --candidates sala-test-alp-main; [ "$RC" != 0 ] && has "$OUT" "takes no session name" && ok "--candidates with a name: refused" || bad "candidates + name: rc=$RC — $OUT"
[ "$(nmarkers)" = 0 ] && [ "$(for n in $ALL; do row "sala-test-$n"; done)" = "$rows0" ] && ok "nothing changed: no marker, the pane map as before" || bad "state changed"

echo "== the activity call fails SAFE: whatever goes wrong, nothing sleeps, and the dry run says why"
failcase() {  # <label> <command> <text the dry run must carry>
    local out; out=$(SALA_ACTIVITY_CMD="$2" SALA_ACTIVITY_TIMEOUT=2 "$SALA" sleep --candidates 2>&1)
    has "$out" "no project can sleep: $3" && ! has "$out" "would be put to sleep" && ok "$1: the dry run says '$3' and no project is marked" || bad "$1: $out"
    SALA_IDLE_SLEEP=on SALA_ACTIVITY_CMD="$2" SALA_ACTIVITY_TIMEOUT=2 "$SALA" watch --sleep >/dev/null 2>&1
    [ "$(nmarkers)" = 0 ] && ok "$1: the tick put nothing to sleep" || bad "$1: markers: $(ls "$SALA_SLEEP_DIR")"
}
failcase "a command that fails" "echo 'server unreachable (401)' >&2; exit 3" "the activity command failed (exit 3: server unreachable (401))"
failcase "a command that prints nothing" "true" "the activity command printed nothing"
failcase "an answer that is not JSON" "echo not-json" "the activity answer is not the shape sala reads"
failcase "an empty answer" "echo '{\"projects\": {}}'" "the activity answer lists no project"
failcase "an answer of the wrong shape" "echo '{\"projects\": {\"p-alpha\": {\"anchor\": \"yesterday\"}}}'" "the activity answer is not the shape sala reads"
failcase "a command that does not answer in time" "exec sleep 20" "the activity command did not answer within 2 s"
failcase "no activity source at all (no command, no stackshot client)" "" "there is no activity source"
ALLUP=1; for n in $ALL; do hasclaude "$n" || ALLUP=0; done; [ "$ALLUP" = 1 ] && ok "after all of them every claude still runs" || bad "a claude ended"
OUT=$(SALA_ACTIVITY_CMD="exit 3" "$SALA" sleep --project p-theta --dry-run 2>&1); RC=$?
[ "$RC" != 0 ] && has "$OUT" "would refuse: project p-theta: no reading of its activity" && ok "sleep --project --dry-run with a failing call: refused, with the reason" || bad "project dry, failing call: rc=$RC $OUT"

echo "== a project the answer does not list has had neither: it is quiet (never); a key written projects/<key> is read as <key>"
python3 -I - "$ACT" "$(date +%s)" <<'PY'
import json, sys
json.dump({"projects": {"projects/p-beta": {"anchor": int(sys.argv[2]) - 3600, "owner": None}}}, open(sys.argv[1], "w"))
PY
OUT=$("$SALA" sleep --candidates 2>&1)
has "$(grep '^p-beta:' <<< "$OUT")" "not quiet: an external anchor notice 1 h" && ok "projects/p-beta is read as p-beta: its anchor notice holds it" || bad "prefix: $(grep '^p-beta:' <<< "$OUT")"
L=$(grep '^p-theta:' <<< "$OUT"); has "$L" "last anchor notice: never; owner's last input: never" && (has "$L" "would be put to sleep" || has "$L" "ready, waits for a later run") && ok "theta, not in the answer: both never, a candidate" || bad "never: $L"
has "$(grep '^p-gamma:' <<< "$OUT")" "never" && has "$(grep '^p-gamma:' <<< "$OUT")" "ready" && ok "gamma (listed nowhere now) is quiet too" || bad "gamma: $(grep '^p-gamma:' <<< "$OUT")"
setact p-alpha $((3 * D)) $((5 * D))  p-beta 3600 -  p-gamma - 3600  p-delta $((9 * D)) $((9 * D))  p-eps $((6 * D)) $((6 * D))  p-theta $((10 * D)) $((12 * D))  p-iota $((8 * D)) -

echo "== in flight in any one session blocks the whole project: a message line waiting for alpha's background agent holds alpha, its front agent included"
export SALA_STACKSHOT_INBOX="$HOME/inbox"; mkdir -p "$SALA_STACKSHOT_INBOX/hub" "$SALA_STACKSHOT_INBOX/msg" "$SALA_INBOX_HOLD_DIR"
printf '{"id":"a1","src":"msg","to":"sala-test-alp-aud","uuid":"%s","name":"sala-test-alp-aud","pid":"","text":"look at this","from":"x"}\n' "$(uuid 43)" > "$SALA_STACKSHOT_INBOX/msg/m1.json"
OUT=$("$SALA" sleep --candidates 2>&1); L=$(grep '^p-alpha:' <<< "$OUT")
has "$L" "not a candidate" && has "$L" "sala-test-alp-aud: a stackshot msg message waits for it" && ok "alpha: not a candidate while alp-aud has a message line waiting (alp-main and alp-eng are idle)" || bad "alpha with a line: $L"
OUT=$("$SALA" sleep --project p-alpha 2>&1); RC=$?; [ "$RC" != 0 ] && has "$OUT" "project p-alpha: not put to sleep" && has "$OUT" "alp-aud" && [ "$(nmarkers)" = 0 ] && hasclaude alp-main && hasclaude alp-eng && ok "sleep --project p-alpha: refused with the reason, nothing touched (not even the two idle sessions)" || bad "project alpha: rc=$RC $OUT"
rm -f "$SALA_STACKSHOT_INBOX/msg/m1.json"
OUT=$("$SALA" sleep --candidates 2>&1); has "$(grep '^p-alpha:' <<< "$OUT")" "ready" && ok "the line gone: alpha is ready again" || bad "alpha after: $(grep '^p-alpha:' <<< "$OUT")"

echo "== a background agent alone never sleeps; a project that is not a candidate is refused"
OUT=$("$SALA" sleep --project p-beta 2>&1); RC=$?; [ "$RC" != 0 ] && has "$OUT" "project p-beta: not put to sleep — not quiet" && ok "sleep --project p-beta: refused (not quiet), nothing touched" || bad "beta: rc=$RC $OUT"
OUT=$("$SALA" sleep --project p-beta --dry-run 2>&1); RC=$?; [ "$RC" != 0 ] && has "$OUT" "[dry-run] would refuse: project p-beta: not quiet" && ok "sleep --project p-beta --dry-run: '[dry-run] would refuse: project p-beta: not quiet…'" || bad "beta dry: rc=$RC $OUT"
OUT=$("$SALA" sleep --project p-delta 2>&1); RC=$?; [ "$RC" != 0 ] && has "$OUT" "pinned" && ok "sleep --project p-delta: refused, it is pinned" || bad "delta: rc=$RC $OUT"
OUT=$("$SALA" sleep --project p-eps 2>&1); RC=$?; [ "$RC" != 0 ] && has "$OUT" "eps-eng: its last turn left a scheduled job" && ok "sleep --project p-eps: refused, one session has work in flight" || bad "eps: rc=$RC $OUT"
OUT=$("$SALA" sleep --project p-nosuch 2>&1); RC=$?; [ "$RC" != 0 ] && has "$OUT" "no session of it runs on this box" && ok "a project nothing runs here: refused" || bad "nosuch: rc=$RC $OUT"
OUT=$("$SALA" sleep --project "a/b" 2>&1); RC=$?; [ "$RC" != 0 ] && has "$OUT" "not a project key" && ok "a bad key: refused" || bad "bad key: rc=$RC $OUT"
OUT=$("$SALA" sleep --project p-theta sala-test-the-eng 2>&1); RC=$?; [ "$RC" != 0 ] && has "$OUT" "takes no session name" && ok "--project with a session name: refused" || bad "project + name: rc=$RC $OUT"
OUT=$("$SALA" sleep sala-test-orp-eng --dry-run 2>&1); has "$OUT" "claude pid" && ok "(a person may still name the project-less agent: sala sleep NAME is the per-session verb, unchanged; the tick never picks it)" || bad "orp by name: $OUT"
[ "$(nmarkers)" = 0 ] && ok "no refusal wrote a marker" || bad "markers: $(ls "$SALA_SLEEP_DIR")"

echo "== ON: SALA_SLEEP_PER_TICK=0 sleeps nothing; a tick puts the quietest project's sessions to sleep together"
SALA_IDLE_SLEEP=on SALA_SLEEP_PER_TICK=0 "$SALA" watch --sleep >/dev/null 2>&1
[ "$(nmarkers)" = 0 ] && ok "a cap of 0: nothing slept" || bad "cap 0 slept: $(ls "$SALA_SLEEP_DIR")"
SALA_IDLE_SLEEP=on tick
asleep 52 && asleep 53 && [ "$(nmarkers)" = 2 ] && ok "theta's two sessions (the quietest project, front agent included) have a marker, and nothing else has" || bad "markers: $(ls "$SALA_SLEEP_DIR")"
! hasclaude the-main && ! hasclaude the-eng && ok "their claude has ended" || bad "a claude still runs in theta"
{ $T has-session -t "=sala-test-the-main" && $T has-session -t "=sala-test-the-eng"; } 2>/dev/null && [ "$(for n in $ALL; do row "sala-test-$n"; done)" = "$rows0" ] && ok "their tmux sessions and the pane-map rows are kept, byte for byte" || bad "sessions or rows changed"
[ "$(wlogn 'sleep: put project p-theta to sleep (2 session(s)')" = 1 ] && [ "$(wlogn 'sleep: put ')" = 1 ] && ok "one watch-log line for the project ('sleep: put project p-theta to sleep (2 session(s); quiet for 10 h…')" || bad "log: $(grep 'sleep:' "$WLOG")"
ALLUP=1; for n in alp-main alp-eng alp-aud bet-main bet-eng gam-main gam-eng del-main del-eng eps-main eps-eng iot-main iot-eng orp-eng; do hasclaude "$n" || ALLUP=0; done
[ "$ALLUP" = 1 ] && ok "every other project, and the background agent with no project, keep running (one project per run)" || bad "another claude ended"
OUT=$("$SALA" sleep --candidates 2>&1); L=$(grep '^p-theta:' <<< "$OUT"); has "$L" "sleeping" && has "$L" "already asleep" && ok "the candidates now show theta as sleeping" || bad "theta after: $L"
has "$(grep '^p-iota:' <<< "$OUT")" "would be put to sleep" && ok "iota is next" || bad "iota: $(grep '^p-iota:' <<< "$OUT")"

echo "== the retry wait: a project asked lately and not put to sleep is skipped, the next one takes its turn (preview and run alike)"
WST="$SALA_LOG_DIR/salamander-watch.state"
printf 'sleepfail.p-iota=%s\n' "$(date +%s)" >> "$WST"      # a sleep of iota failed a moment ago
OUT=$("$SALA" sleep --candidates 2>&1); DRYS=$("$SALA" watch --sleep --dry-run 2>&1)
has "$(grep '^p-iota:' <<< "$OUT")" "skipped" && has "$(grep '^p-alpha:' <<< "$OUT")" "would be put to sleep" && [ "$(grep -c 'would be put to sleep' <<< "$OUT")" = 1 ] && ok "sleep --candidates, cap 1: iota (in its retry wait) is skipped and alpha is the one that would be put to sleep" || bad "retry preview: $OUT"
[ "$(grep '^p-alpha:' <<< "$DRYS")" = "$(grep '^p-alpha:' <<< "$OUT")" ] && ok "watch --sleep --dry-run names the same project" || bad "watch --sleep --dry-run: $DRYS"
SALA_IDLE_SLEEP=on "$SALA" watch --sleep >/dev/null 2>&1
asleep 41 && asleep 42 && asleep 43 && [ "$(nmarkers)" = 5 ] && hasclaude iot-main && hasclaude iot-eng && ok "the real run put alpha's three sessions (front agent and both background agents) to sleep together, the one the preview named, and did not try iota" || bad "retry run: markers $(ls "$SALA_SLEEP_DIR"); iota up: $(hasclaude iot-main && echo y)"
[ "$(wlogn 'sleep: put project p-alpha to sleep (3 session(s)')" = 1 ] && [ "$(wlogn 'not put to sleep')" = 0 ] && ok "one 'put project p-alpha to sleep (3 session(s)…' line and no failure line" || bad "log: $(grep 'sleep:' "$WLOG")"
sed -i '/^sleepfail\.p-iota=/d' "$WST"
SALA_IDLE_SLEEP=on "$SALA" watch --sleep >/dev/null 2>&1
asleep 54 && asleep 55 && [ "$(nmarkers)" = 7 ] && ok "with the wait over the next run sleeps iota" || bad "iota: markers $(ls "$SALA_SLEEP_DIR")"
hasclaude bet-main && hasclaude bet-eng && hasclaude gam-main && hasclaude gam-eng && hasclaude del-main && hasclaude del-eng && hasclaude eps-main && hasclaude eps-eng && hasclaude orp-eng && ok "beta (an anchor notice), gamma (input from the owner), delta (pinned), eps (work in flight) and the project-less background agent still run: a background agent never sleeps alone" || bad "a protected session lost its claude"
OUT=$("$SALA" sleep --candidates 2>&1); [ "$(grep -c 'would be put to sleep' <<< "$OUT")" = 0 ] && ok "no project is left to put to sleep" || bad "candidates after: $OUT"
SALA_IDLE_SLEEP=on tick; [ "$(nmarkers)" = 7 ] && ok "a further full tick sleeps nothing more" || bad "extra sleep: $(ls "$SALA_SLEEP_DIR")"
[ -z "$(ls -A "$SALA_SLEEP_DIR" | grep -v "^$(uuid 41)\$\|^$(uuid 42)\$\|^$(uuid 43)\$\|^$(uuid 52)\$\|^$(uuid 53)\$\|^$(uuid 54)\$\|^$(uuid 55)\$")" ] && ok "the marker folder holds markers only (the pins stand beside it)" || bad "marker folder: $(ls -A "$SALA_SLEEP_DIR")"

echo "== pins again: unpinned, delta (quiet 9 d) is a candidate; pinned, it is not; unpin of a project that is not pinned says so"
run sleep --unpin p-delta; [ "$RC" = 0 ] && has "$OUT" "p-delta: unpinned" && [ ! -e "$SALA_SLEEP_DIR.pins/p-delta" ] && ok "--unpin p-delta: the file is gone" || bad "unpin: rc=$RC $OUT"
OUT=$("$SALA" sleep --candidates 2>&1); has "$(grep '^p-delta:' <<< "$OUT")" "would be put to sleep" && ok "unpinned, delta is a candidate" || bad "delta unpinned: $(grep '^p-delta:' <<< "$OUT")"
run sleep --unpin p-delta; [ "$RC" = 0 ] && has "$OUT" "was not pinned" && ok "a second --unpin: 'was not pinned', exit 0" || bad "unpin twice: rc=$RC $OUT"
run sleep --pin p-delta; [ "$RC" = 0 ] && has "$OUT" "p-delta: pinned" && ok "pinned again (no reason)" || bad "re-pin: rc=$RC $OUT"
OUT=$("$SALA" sleep --candidates 2>&1); L=$(grep '^p-delta:' <<< "$OUT"); has "$L" "pinned" && has "$L" "not a candidate" && ok "pinned, delta is not a candidate" || bad "delta pinned: $L"
SALA_IDLE_SLEEP=on tick; [ "$(nmarkers)" = 7 ] && hasclaude del-main && hasclaude del-eng && ok "a tick leaves the pinned project running" || bad "pinned project slept: $(ls "$SALA_SLEEP_DIR")"
run sleep --pin p-nosuch --why "typo?"; [ "$RC" = 0 ] && has "$OUT" "no session of p-nosuch runs on this box" && ok "a pin of a project nothing runs here is kept, with a note (a typo is visible)" || bad "pin unknown: rc=$RC $OUT"
run sleep --unpin p-nosuch

echo "== waking is per session: a message line for one sleeper wakes that session only; the rest of its project stays asleep"
printf '{"id":"w1","src":"msg","to":"sala-test-alp-eng","uuid":"%s","name":"sala-test-alp-eng","pid":"","text":"for alp-eng","from":"x"}\n' "$(uuid 42)" > "$SALA_STACKSHOT_INBOX/msg/w1.json"
s41=$(n_starts 41); s42=$(n_starts 42); s43=$(n_starts 43)
tick
waitfor 'hasclaude alp-eng' 60
hasclaude alp-eng && ! asleep 42 && [ "$(n_starts 42)" = "$((s42 + 1))" ] && ok "alp-eng woke, once, on its own conversation" || bad "alp-eng: starts $(n_starts 42)/$s42; log: $(grep 'wake:' "$WLOG")"
asleep 41 && asleep 43 && ! hasclaude alp-main && ! hasclaude alp-aud && [ "$(n_starts 41)" = "$s41" ] && [ "$(n_starts 43)" = "$s43" ] && ok "alp-main (the front agent) and alp-aud stay asleep, not started" || bad "the others: asleep $(asleep 41 && echo y)/$(asleep 43 && echo y); starts $(n_starts 41)/$s41 $(n_starts 43)/$s43"
[ "$(wlogn 'wake: woke sala-test-alp-eng')" = 1 ] && [ "$(wlogn 'wake: woke ')" = 1 ] && ok "one wake line, for alp-eng" || bad "log: $(grep 'wake:' "$WLOG")"
OUT=$("$SALA" sleep --candidates 2>&1); L=$(grep '^p-alpha:' <<< "$OUT")
has "$L" "awake (2 of 3 asleep)" && has "$L" "not a candidate" && ok "alpha shows as awake (2 of 3 asleep); the line for alp-eng still waits, so it is held" || bad "alpha half awake: $L"
rm -f "$SALA_STACKSHOT_INBOX/msg/w1.json"
OUT=$("$SALA" sleep --candidates 2>&1); L=$(grep '^p-alpha:' <<< "$OUT")
has "$L" "sala-test-alp-eng: woken" && has "$L" "left alone for 60 min" && ok "the line gone, alp-eng's wake stamp still holds alpha back for SALA_SLEEP_AFTER" || bad "alpha stamp: $L"
SALA_IDLE_SLEEP=on tick; sleep 1
hasclaude alp-eng && ! asleep 42 && ok "a tick with the tick on leaves the woken session running" || bad "alp-eng was put to sleep again"
printf '%s\n' "$(( $(date +%s) - 4000 ))" > "$SALA_SLEEP_DIR.woke/$(uuid 42)"
OUT=$("$SALA" sleep --candidates 2>&1); L=$(grep '^p-alpha:' <<< "$OUT")
has "$L" "would be put to sleep (sala-test-alp-eng)" && ok "with the stamp aged, alpha is a candidate again, with its one awake session" || bad "alpha aged: $L"
SALA_IDLE_SLEEP=on "$SALA" watch --sleep >/dev/null 2>&1
asleep 41 && asleep 42 && asleep 43 && ! hasclaude alp-eng && ok "the tick puts the last awake session of the project back to sleep (as part of its project)" || bad "alp-eng not asleep again"

echo "== the unit of the tick is the project: no sleep line ever names a single session"
! grep -q 'sleep: put sala-test' "$WLOG" && ok "no 'sleep: put <session>' line in the watch log" || bad "log: $(grep 'sleep: put sala-test' "$WLOG")"

[ "$fail" = 0 ] && echo "sleepproject: pass" || echo "sleepproject: FAIL"
exit $fail
