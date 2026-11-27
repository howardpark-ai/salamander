#!/usr/bin/env bash
# Sleeping sessions, THE ASKED SLEEP (lib/sleep.sh --asked, lib/wrapup.sh SLEEP_QUIET_WAIVE / SLEEP_SETTLE_WAIVE / the `asker` mode of sleep_ready, lib/op.sh `sleep --project KEY`):
# a session puts its own project to sleep on the owner's words, with no quiet rule. `sala op sleep --project KEY --from YOU --words "…"` queues `sleep --project KEY --asked`: the
# WHOLE project (front and background agents together, never one session of it) sleeps now; the owner's words lift the quiet rule (SALA_SLEEP_QUIET, two days) and the settle
# time (SALA_SLEEP_AFTER) and nothing else. The asking session may be one of the sleepers: the queue's runner (outside every pane) waits up to SALA_SLEEP_ASKER_WAIT for its
# turn to end, then sleeps everything with the asker last. What is checked, on a private tmux server with the compiled fake claude and a stub of stackshot's project-activity
# (the owner's last input 39 min ago, which the plain verb refuses as not quiet):
#  - the plain verb is as it was: `sleep --project KEY --dry-run` refuses "not quiet: input from its owner"; a raw `--asked` from a Claude session is refused with the queue line;
#  - `--asked --dry-run` passes the same project (the quiet rule and the settle time waived: a session idle for a minute is no refusal), and still refuses what the words do not lift:
#    a pinned project (the pin named), a project with no reading of its activity, a session with a scheduled job in flight, a message line waiting; nothing touched;
#  - the real asked run (the queue's runner, SALA_OP_ID) of a project the asker is not in: every session asleep together, front agent included, markers written, tmux sessions and
#    pane-map rows kept; the same run again is "already asleep";
#  - the asker among the sleepers: the plan says "the asking session sleeps once idle" and still refuses a project that has a session with work in flight; the runner waits
#    for the asker's turn to end (busy at first, idle 4 s later), then sleeps the whole project with the asker last; an asker that stays busy past SALA_SLEEP_ASKER_WAIT leaves
#    the whole project untouched; a member asking without the queue's runner (no SALA_OP_ID) is refused as before;
#  - `--only YOU` with the words: a background agent that asks about itself sleeps once idle; a front agent alone is still refused (a front agent sleeps only with its project);
#  - the queue: `op sleep --project KEY` with no words, with --item or --why, with --only beside it, with a bad key, or twice is refused and queues nothing; the plan names the
#    asker; with the words it queues one marker (verb sleep, arg --project KEY, the words verbatim, no reason fields), the runner puts the project to sleep, the operation ends
#    done and archived, the post says "put project … to sleep"; when the asker was one of the sleepers no line is sent into its inbox (it would wake it) and the log says so;
#  - the teaching text: `sala sleep --help`, `sala op --help`, the refusal of a plain `sleep --project` and of a raw `sleep` of a front agent all name the verb.
# SAFETY: every kill is a `kill -9` of ONE pid whose /proc/<pid>/exe is this suite's own compiled fake and whose environment names this suite's temporary HOME
# (kill_fake_claude); the tmux server is a private socket (tmux -L sala-sleepasked-<pid> -f /dev/null, SALA_TMUX_SOCKET pointing at it), HOME is a mktemp -d held with flock,
# the claude is tests/fake-claude.c; the "Claude session" that makes a raw call is a copy of bash named claude in the fake versions folder; no real pane, server, ~/.claude or
# claude process is read or touched. Posts go to a file, the activity source is a stub file inside that HOME.
# Usage: bash tests/sleepasked.sh   (exit 0 = pass)
set -u
unset TMUX TMUX_PANE XDG_STATE_HOME SALA_MASTER SALA_SET SALA_SET_SELF SALA_RECYCLE SALA_RETRY_WORKER SALA_LOCK_WHO SALA_LOCK_WAIT SALA_RELAUNCH_KIND SALA_SLEEP_DIR \
      SALA_FLEET_HOSTS SALA_CGROUP_FILE SALA_OP_QUEUE SALA_NO_RELAUNCH SALA_BOOT_ID SALA_CONFIG SALA_BARE_REVIVE SALA_IDLE_WRAPUP SALA_SESSION_ID SALA_STACKSHOT_INBOX \
      SALA_STACKSHOT_DIR SALA_STACKSHOT_CLIENT SALA_AGENT_CHECK_SCRIPT SALA_PROJECT_RECORD SALA_ROLES_FILE SALA_OP_ID SALA_OP_FROM SALA_OP_PLAN SALA_OP_REASON_FROM \
      SALA_IDLE_SLEEP SALA_SLEEP_AFTER SALA_SLEEP_PER_TICK SALA_WAKE_PER_RUN SALA_SLEEP_RETRY SALA_WAKE_RETRY SALA_SLEEP_QUIET SALA_ACTIVITY_CMD SALA_ACTIVITY_TIMEOUT SALA_SLEEP_PIN_DIR \
      SALA_SLEEP_ASKER_WAIT
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
SANDBOX=""; SOCK="sala-sleepasked-$$"; T="tmux -L $SOCK -f /dev/null"
cleanup() {
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    [ -z "$SANDBOX" ] || { kill_fake_claude "$FAKEBIN"; exec 8<&-; rm -rf "$SANDBOX" 2>/dev/null; }
    true
}; trap cleanup EXIT   # set before the temp folder exists
SANDBOX=$(mktemp -d); export HOME=$SANDBOX SALA_TZ=Etc/UTC SALA_CONFIG=/dev/null
case "$HOME" in /tmp/*|"${TMPDIR:-/tmp}"/*) ;; *) echo "sleepasked: HOME is not a temporary directory ($HOME) - refusing to run"; exit 1;; esac
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
export SALA_OP_STUCK=off SALA_OP_QUEUE=off SALA_BARE_REVIVE=off   # a queued marker is written and nothing starts it
SALA="$ROOT/bin/salamander"
export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's
case "$SOCK" in sala-sleepasked-*) ;; *) echo "sleepasked: not a private socket - refusing to run"; exit 1;; esac
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux    # literal socket: the children run set -u
$T new-session -d -s sala-test-keep -x 200 -y 50 -c "$HOME"; $T set -g exit-empty off   # a server that outlives its last fake
. "$ROOT/lib/common.sh"; . "$ROOT/lib/wrapup.sh"
MAP="$SALA_SIDECAR"; OPS="$SALA_STATE_DIR/ops"; DONE="$OPS/done"
now0=$(date +%s); START=$((now0 - 10800)); TURN=$((now0 - 7200))   # the fakes' process started 3 h ago; their last turn ended 2 h ago
mk() {  # <suffix> <uuid n> [tmux -e options…] → a fake claude in sala-test-<suffix>
    local n="$1" u; u=$(uuid "$2"); shift 2
    $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="sala-test-$n" -e FAKE_LOG="$FAKE_LOG" -e FAKE_TYPED_LOG="$FAKE_TYPED_LOG" \
        -e FAKE_STARTED_AT="$START" -e FAKE_TURN_MS=1500 "$@"
    $T send-keys -t "sala-test-$n" 'claude' Enter
}
hasclaude() { local pp; pp=$($T list-panes -t "=sala-test-$1" -F '#{pane_pid}' 2>/dev/null | head -1); [ -n "$pp" ] && [ -n "$(claude_pid_under "$pp" 2>/dev/null)" ]; }   # <suffix>
cpid() { local pp; pp=$($T list-panes -t "=sala-test-$1" -F '#{pane_pid}' 2>/dev/null | head -1); claude_pid_under "$pp" 2>/dev/null; }   # <suffix> → its claude's pid
regstatus() { set_reg_status "$(cpid "$1")" "$2"; }   # <suffix> <busy|idle>
row() { awk -F'\t' -v s="$1" '$1==s' "$MAP" 2>/dev/null; }
run() { OUT=$("$SALA" "$@" 2>&1); RC=$?; }   # → OUT, RC (stderr in OUT)
stoprec() { mkdir -p "$SALA_BUSY_DIR"; printf 'id=t%s\nepoch=%s\nseen=\nseen_status=idle\ntasks=0\ncrons=%s\n' "$1" "$TURN" "${2:-0}" > "$SALA_BUSY_DIR/$(uuid "$1")"; }   # <uuid n> [crons]: the Stop hook's record of a finished turn
mval() { awk -F= -v k="$2" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$1" 2>/dev/null; }   # <marker file> <key> → its first value
mvals() { awk -F= -v k="$2" '$1==k {sub(/^[^=]*=/, ""); print}' "$1" 2>/dev/null; }
nmarkers() { ls "$SALA_SLEEP_DIR" 2>/dev/null | grep -c . || true; }
asleep() { [ -f "$SALA_SLEEP_DIR/$(uuid "$1")" ]; }   # <uuid n>
allasleep() { local u; for u in "$@"; do asleep "$u" || return 1; done; }   # <uuid n>…
noneasleep() { local u; for u in "$@"; do ! asleep "$u" || return 1; done; }
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
export SALA_ACTIVITY_CMD="cat $ACT"
SOLD="$SALA_SLEEP_DIR"
OPUNIT="env SALA_OP_ID=1760000000-7"   # the queue's runner: the unit's cgroup file (as_op_unit) and the operation's id

# THE CALLER: a "Claude session's call" is a command run as a CHILD of a process named claude that is the pane process of a window of the asking session (as tests/sleepverbs.sh).
cat > "$HOME/drv-claude" <<'EOF'
#!/bin/bash
d=$1
while :; do
    for f in "$d"/*.cmd; do
        [ -e "$f" ] || continue
        b=${f%.cmd}
        bash "$f" > "$b.out" 2>&1; echo $? > "$b.rc.tmp"; mv "$b.rc.tmp" "$b.rc"; rm -f "$f"
    done
    sleep 0.2
done
EOF
mkdir -p "$HOME/drv" "$HOME/drv-calls"; cp "$(command -v bash)" "$HOME/.local/share/claude/versions/drv-bash"; ln -sf "$HOME/.local/share/claude/versions/drv-bash" "$HOME/drv/claude"
$T new-session -d -s sala-test-asker "$HOME/drv/claude $HOME/drv-claude $HOME/drv-calls"
callin() {  # <argv…> → OUT, RC of that command run from inside the session sala-test-asker (a Claude session's call)
    local id f; id=$(date +%s%N)-$RANDOM; f="$HOME/drv-calls/$id"
    printf '%q ' "$@" > "$f.tmp"; echo >> "$f.tmp"; mv "$f.tmp" "$f.cmd"
    waitfor "[ -e '$f.rc' ]" 300 || { OUT="(the driver did not answer)"; RC=99; return; }
    OUT=$(<"$f.out"); RC=$(<"$f.rc"); rm -f "$f.out" "$f.rc"
}
printf '#!/bin/sh\ncat %s\n' "$ACT" > "$HOME/activity.sh"; chmod +x "$HOME/activity.sh"
RAW="env SALA_CGROUP_FILE=/dev/null SALA_ACTIVITY_CMD=$HOME/activity.sh"   # a call that is not the queue's runner: the unit's cgroup file of this suite names none; the driver window reads the same stub

echo "== setup: private tmux server, isolated HOME, the compiled fake claude, six projects (one: main + eng · two: main + eng, idle a minute · three: pinned · four: eng with a job · five, six: main + eng · solo: a background agent, no project)"
IDLE=4000
mk one-main 61 -e FAKE_IDLE_AGE=$IDLE; mk one-eng 62 -e FAKE_IDLE_AGE=$IDLE
mk two-main 63 -e FAKE_IDLE_AGE=60;    mk two-eng 64 -e FAKE_IDLE_AGE=60
mk thr-main 65 -e FAKE_IDLE_AGE=$IDLE; mk thr-eng 66 -e FAKE_IDLE_AGE=$IDLE
mk fou-main 67 -e FAKE_IDLE_AGE=$IDLE; mk fou-eng 68 -e FAKE_IDLE_AGE=$IDLE
mk fiv-main 69 -e FAKE_IDLE_AGE=$IDLE; mk fiv-eng 70 -e FAKE_IDLE_AGE=$IDLE
mk six-main 71 -e FAKE_IDLE_AGE=$IDLE; mk six-eng 72 -e FAKE_IDLE_AGE=$IDLE
mk sol-eng 73 -e FAKE_IDLE_AGE=$IDLE; mk sol-main 74 -e FAKE_IDLE_AGE=$IDLE; mk ctl 75 -e FAKE_IDLE_AGE=$IDLE
ALL="one-main one-eng two-main two-eng thr-main thr-eng fou-main fou-eng fiv-main fiv-eng six-main six-eng sol-eng sol-main ctl"
fake_up $(for n in $ALL; do printf 'sala-test-%s ' "$n"; done) || exit 1
for n in $ALL; do "$SALA" adopt "sala-test-$n" >/dev/null 2>&1 || bad "adopt sala-test-$n failed"; done
for p in "one one-main front" "one one-eng back" "two two-main front" "two two-eng back" "thr thr-main front" "thr thr-eng back" "fou fou-main front" "fou fou-eng back" \
         "fiv fiv-main front" "fiv fiv-eng back" "six six-main front" "six six-eng back"; do
    set -- $p; "$SALA" sessions tag "sala-test-$2" --project "projects/p-$1" --role "$3" >/dev/null 2>&1 || bad "tag $2 failed"
done
"$SALA" sessions tag sala-test-sol-eng --role back >/dev/null 2>&1 || bad "tag sol-eng failed"      # a background role and no project: it may sleep, being asked about itself
"$SALA" sessions tag sala-test-sol-main --role front >/dev/null 2>&1 || bad "tag sol-main failed"   # a front agent and no project
for u in 61 62 63 64 65 66 67 69 70 71 72 73 74 75; do stoprec "$u"; done; stoprec 68 1   # fou-eng: its last turn left a scheduled job
for u in 63 64; do mkdir -p "$SALA_BUSY_DIR"; sed -i "s/^epoch=.*/epoch=$((now0 - 60))/" "$SALA_BUSY_DIR/$(uuid "$u")"; done   # two: its last turn ended a minute ago
setact p-one - 2340  p-two - 2340  p-thr - 2340  p-fou - 2340  p-fiv - 2340  p-six - 2340   # the owner's last input 39 min ago: not quiet for the 2 days
[ "$($T display -p '#{socket_path}')" = "$SALA_TMUX_SOCKET" ] && ok "the tmux server is the suite's private socket ($SOCK)" || bad "socket: $($T display -p '#{socket_path}')"
callin bash -c 'echo up'; [ "$RC" = 0 ] && [ "$OUT" = up ] && ok "a call runs inside a Claude session's driver window" || { bad "driver: rc=$RC $OUT"; exit 1; }
U_ONE="61 62"; U_TWO="63 64"; U_THR="65 66"; U_FOU="67 68"; U_FIV="69 70"; U_SIX="71 72"

echo "== the plain verb is as it was: the quiet rule refuses, and a Claude session cannot run an asked sleep raw"
run sleep --project p-one --dry-run
[ "$RC" = 1 ] && has "$OUT" "would refuse: project p-one: not quiet: input from its owner 39 min ago (it needs 48 h of quiet)" && ok "sleep --project p-one --dry-run: refused, not quiet (39 min ago, needs 48 h)" || bad "plain dry: rc=$RC $OUT"
run sleep --project p-one
[ "$RC" = 1 ] && has "$OUT" "not quiet" && noneasleep $U_ONE && ok "the real plain run: refused, nothing touched" || bad "plain real: rc=$RC $OUT"
run sleep --asked --dry-run
[ "$RC" != 0 ] && has "$OUT" "--asked goes with --project" && ok "--asked with no --project: refused" || bad "asked alone: rc=$RC $OUT"
callin $RAW "$SALA" sleep --project p-one --asked
[ "$RC" != 0 ] && has "$OUT" "sala op sleep --project p-one --from" && has "$OUT" "--words" && noneasleep $U_ONE && hasclaude one-main && ok "raw --asked from a Claude session: refused, the line names the queued verb with the owner's words" || bad "raw asked: rc=$RC $OUT"
callin $RAW "$SALA" sleep --project p-one
[ "$RC" != 0 ] && has "$OUT" "sala op sleep --project p-one --from" && ok "a raw plain --project from a Claude session: the same line" || bad "raw plain: rc=$RC $OUT"
callin $RAW "$SALA" sleep sala-test-one-main
[ "$RC" != 0 ] && has "$OUT" "sala op sleep" && noneasleep 61 && ok "a raw sleep of one session from a Claude session: refused with the sala op line" || bad "raw name: rc=$RC $OUT"
callin $RAW "$SALA" sleep --project p-one --asked --dry-run
[ "$RC" = 0 ] && has "$OUT" "would put 2 session(s) to sleep together" && ok "a dry run passes the guard from a Claude session" || bad "raw dry: rc=$RC $OUT"

echo "== --asked --dry-run: the quiet rule and the settle time are waived, the rest of the checks stay"
run sleep --project p-one --asked --dry-run
[ "$RC" = 0 ] && has "$OUT" "project p-one: asked in " && has "$OUT" "project p-one: would put 2 session(s) to sleep together: sala-test-one-eng sala-test-one-main" && has "$OUT" "nothing was changed" && ok "p-one: would sleep both (front agent included), the owner's input 39 min ago no refusal" || bad "asked dry: rc=$RC $OUT"
noneasleep $U_ONE && hasclaude one-main && hasclaude one-eng && ok "and the dry run touched nothing" || bad "dry touched"
run sleep --project p-two --dry-run
[ "$RC" = 1 ] && ok "p-two without the words: refused (the quiet rule first)" || bad "two plain: rc=$RC $OUT"
run sleep --project p-two --asked --dry-run
[ "$RC" = 0 ] && has "$OUT" "project p-two: would put 2 session(s) to sleep together" && ok "p-two, idle only a minute: the settle time is waived with the words, so it would sleep" || bad "two asked dry: rc=$RC $OUT"
run sleep --project projects/p-two --asked --dry-run
[ "$RC" = 0 ] && has "$OUT" "project p-two: would put 2 session(s) to sleep together" && ok "the KEY as projects/p-two resolves to the same project as p-two" || bad "two key form: rc=$RC $OUT"
run sleep sala-test-two-main --dry-run
[ "$RC" != 0 ] && has "$OUT" "a front agent" && has "$OUT" "sala op sleep --project KEY" && ok "its front agent by name is still refused, the line pointing at the project's sleep" || bad "front by name: rc=$RC $OUT"
"$SALA" sleep --pin p-thr --why "release week" >/dev/null 2>&1
run sleep --project p-thr --asked --dry-run
[ "$RC" = 1 ] && has "$OUT" "pinned (release week)" && has "$OUT" "the owner's words do not lift a pin: unpin it first" && ok "a pinned project: refused with the pin named, and the words do not lift it" || bad "pinned: rc=$RC $OUT"
run sleep --project p-fou --asked --dry-run
[ "$RC" = 1 ] && has "$OUT" "sala-test-fou-eng:" && has "$OUT" "scheduled job" && ok "a session with a scheduled job in flight keeps its whole project awake, words or not" || bad "in flight: rc=$RC $OUT"
OUT=$(SALA_ACTIVITY_CMD="exit 3" "$SALA" sleep --project p-one --asked --dry-run 2>&1); RC=$?
[ "$RC" = 1 ] && has "$OUT" "no reading of its activity" && ok "no reading of the project's activity: refused with the words too, nothing sleeps" || bad "no reading: rc=$RC $OUT"
export SALA_STACKSHOT_INBOX="$HOME/inbox"; mkdir -p "$SALA_STACKSHOT_INBOX/hub" "$SALA_STACKSHOT_INBOX/msg" "$SALA_INBOX_HOLD_DIR"
printf '{"id":"a1","src":"msg","to":"sala-test-one-eng","uuid":"%s","name":"sala-test-one-eng","pid":"","text":"look at this","from":"x"}\n' "$(uuid 62)" > "$SALA_STACKSHOT_INBOX/msg/m1.json"
run sleep --project p-one --asked --dry-run
[ "$RC" = 1 ] && has "$OUT" "sala-test-one-eng: a stackshot msg message waits for it" && ok "a message line waiting for one session: the project stays awake" || bad "message line: rc=$RC $OUT"
rm -f "$SALA_STACKSHOT_INBOX/msg/m1.json"
run sleep --project p-nosuch --asked --dry-run
[ "$RC" = 1 ] && has "$OUT" "no session of it runs on this box" && ok "a project nothing runs here: refused" || bad "nosuch: rc=$RC $OUT"

echo "== the real asked run (the queue's runner) of a project the asker is not in"
OUT=$(SALA_OP_ID=1760000000-7 SALA_OP_FROM=sala-test-ctl "$SALA" sleep --project p-one --asked 2>&1); RC=$?
[ "$RC" = 0 ] && has "$OUT" "project p-one: asleep — 2 session(s)" && allasleep $U_ONE && ok "p-one asleep together: both markers written (the front agent too)" || bad "asked real: rc=$RC $OUT"
! hasclaude one-main && ! hasclaude one-eng && $T has-session -t "=sala-test-one-main" 2>/dev/null && $T has-session -t "=sala-test-one-eng" 2>/dev/null && ok "their claudes ended, their tmux sessions stay" || bad "claude/tmux state after the sleep"
[ -n "$(row sala-test-one-main)" ] && [ -n "$(row sala-test-one-eng)" ] && ok "their pane-map rows stay" || bad "rows gone"
OUT=$(SALA_OP_ID=1760000000-7 SALA_OP_FROM=sala-test-ctl "$SALA" sleep --project p-one --asked 2>&1); RC=$?
[ "$RC" != 0 ] && has "$OUT" "already asleep" && ok "asked again: already asleep, nothing more done" || bad "again: rc=$RC $OUT"
hasclaude two-main && hasclaude fiv-main && hasclaude six-main && noneasleep $U_TWO $U_FIV $U_SIX && ok "no other project was touched" || bad "others touched"

echo "== the asker is one of the sleepers: the plan says so, and refuses what a turn's end cannot change"
OUT=$(SALA_OP_PLAN=1 SALA_OP_FROM=sala-test-two-eng "$SALA" sleep --project p-two --asked --dry-run 2>&1); RC=$?
[ "$RC" = 0 ] && has "$OUT" "the asking session sleeps once idle" && has "$OUT" "sala wake sala-test-two-eng" && has "$OUT" "would put 2 session(s) to sleep together" && ok "plan from the asker (p-two): the asking session sleeps once idle, both sessions listed" || bad "asker plan: rc=$RC $OUT"
OUT=$(SALA_OP_PLAN=1 SALA_OP_FROM=sala-test-fou-main "$SALA" sleep --project p-fou --asked --dry-run 2>&1); RC=$?
[ "$RC" = 1 ] && has "$OUT" "sala-test-fou-eng:" && has "$OUT" "scheduled job" && ! has "$OUT" "would put 2 session(s)" && ok "an asker whose project has another session with a job in flight: the plan refuses" || bad "asker plan, in flight: rc=$RC $OUT"
OUT=$(SALA_OP_FROM=sala-test-two-eng "$SALA" sleep --project p-two --asked --dry-run 2>&1); RC=$?
[ "$RC" = 1 ] && has "$OUT" "is one of its sessions and the session this command runs in" && ok "a member's dry run outside the queue's plan: refused as before" || bad "member dry: rc=$RC $OUT"
OUT=$(SALA_OP_FROM=sala-test-two-eng "$SALA" sleep --project p-two --asked 2>&1); RC=$?
[ "$RC" = 1 ] && has "$OUT" "is one of its sessions and the session this command runs in" && noneasleep $U_TWO && ok "a member asking with no SALA_OP_ID (not the runner): refused, nothing touched" || bad "member real: rc=$RC $OUT"

echo "== the runner waits for the asker's turn to end, then sleeps the whole project with the asker last"
regstatus two-eng busy; ( sleep 4; regstatus two-eng idle ) &
OUT=$(SALA_OP_ID=1760000000-7 SALA_OP_FROM=sala-test-two-eng SALA_SLEEP_ASKER_WAIT=30 "$SALA" sleep --project p-two --asked 2>&1); RC=$?
wait
[ "$RC" = 0 ] && has "$OUT" "the asking session 'sala-test-two-eng' is still in its turn" && has "$OUT" "project p-two: asleep — 2 session(s): sala-test-two-main sala-test-two-eng" && allasleep $U_TWO && ok "busy at first, idle 4 s later: p-two asleep, asker named last" || bad "asker wait: rc=$RC $OUT"
L1=$(grep -n "two-main: asleep" <<< "$OUT" | cut -d: -f1); L2=$(grep -n "two-eng: asleep" <<< "$OUT" | cut -d: -f1)
[ -n "$L1" ] && [ -n "$L2" ] && [ "$L1" -lt "$L2" ] && ok "the asker's own line comes after the other session's" || bad "order: main line $L1, asker line $L2: $OUT"
! hasclaude two-main && ! hasclaude two-eng && ok "both claudes ended" || bad "claudes of p-two still run"

echo "== an asker that stays busy past SALA_SLEEP_ASKER_WAIT: the whole project is left as it is"
regstatus fiv-eng busy
OUT=$(SALA_OP_ID=1760000000-7 SALA_OP_FROM=sala-test-fiv-eng SALA_SLEEP_ASKER_WAIT=3 "$SALA" sleep --project p-fiv --asked 2>&1); RC=$?
[ "$RC" = 1 ] && has "$OUT" "the asking session 'sala-test-fiv-eng' is not ready within 3s" && has "$OUT" "nothing was touched" && noneasleep $U_FIV && hasclaude fiv-main && hasclaude fiv-eng && ok "refused after 3 s: no session of p-fiv touched, the line says ask again" || bad "asker timeout: rc=$RC $OUT"
regstatus fiv-eng idle
OUT=$(SALA_OP_ID=1760000000-8 SALA_OP_FROM=sala-test-ctl SALA_SLEEP_ASKER_WAIT=3 "$SALA" sleep --project p-fiv --asked 2>&1); RC=$?
[ "$RC" = 0 ] && has "$OUT" "project p-fiv: asleep" && allasleep $U_FIV && ok "idle again, asked by a session outside it: p-fiv asleep at once" || bad "fiv again: rc=$RC $OUT"

echo "== --only YOU with the words: a background agent that asks about itself sleeps once idle; a front agent alone is still refused"
OUT=$(SALA_OP_PLAN=1 SALA_OP_FROM=sala-test-sol-eng "$SALA" sleep sala-test-sol-eng --dry-run 2>&1); RC=$?
[ "$RC" = 0 ] && has "$OUT" "the asking session sleeps once idle" && ok "plan: the asker's own sleep says it sleeps once idle" || bad "only plan: rc=$RC $OUT"
OUT=$(SALA_OP_FROM=sala-test-sol-eng "$SALA" sleep sala-test-sol-eng 2>&1); RC=$?
[ "$RC" = 1 ] && has "$OUT" "the session this command runs in" && ! asleep 73 && ok "outside the queue's runner it is refused as before" || bad "only raw: rc=$RC $OUT"
regstatus sol-eng busy; ( sleep 3; regstatus sol-eng idle ) &
OUT=$(SALA_OP_ID=1760000000-9 SALA_OP_FROM=sala-test-sol-eng SALA_SLEEP_ASKER_WAIT=30 "$SALA" sleep sala-test-sol-eng 2>&1); RC=$?
wait
[ "$RC" = 0 ] && has "$OUT" "still in its turn" && has "$OUT" "sala-test-sol-eng: asleep" && asleep 73 && ok "the runner waited for its turn to end, then put it to sleep" || bad "only real: rc=$RC $OUT"
OUT=$(SALA_OP_PLAN=1 SALA_OP_FROM=sala-test-sol-main "$SALA" sleep sala-test-sol-main --dry-run 2>&1); RC=$?
[ "$RC" = 1 ] && has "$OUT" "a front agent" && has "$OUT" "sala op sleep --project KEY" && ok "a front agent asking about itself alone: refused, the line points at its whole project" || bad "front alone: rc=$RC $OUT"
OUT=$(SALA_OP_ID=1760000000-9 SALA_OP_FROM=sala-test-sol-main "$SALA" sleep sala-test-sol-main 2>&1); RC=$?
[ "$RC" = 1 ] && has "$OUT" "a front agent" && ! asleep 74 && hasclaude sol-main && ok "and the runner refuses it too: nothing touched" || bad "front alone real: rc=$RC $OUT"
OUT=$(SALA_OP_ID=1760000000-9 SALA_OP_FROM=sala-test-ctl "$SALA" sleep sala-test-sol-main 2>&1); RC=$?
[ "$RC" = 1 ] && has "$OUT" "a front agent" && ok "a front agent by name for another asker: refused as before" || bad "front by name: rc=$RC $OUT"

echo "== the queue: what op sleep --project refuses, queues nothing"
q0=$(ls "$OPS"/*.op 2>/dev/null | wc -l)
enq sleep --project p-six --from sala-test-ctl
[ "$RC" != 0 ] && has "$OUT" "no --words" && has "$OUT" "a whole project's sleep, \`op sleep --project KEY\`, has no such door" && ok "no words: refused, and the refusal says a project's sleep has no reason door" || bad "no words: rc=$RC $OUT"
enq sleep --project p-six --why "release is done now" --from sala-test-ctl
[ "$RC" != 0 ] && has "$OUT" "no --words" && ok "--why: no door either" || bad "--why: rc=$RC $OUT"
enq sleep --project p-six --item board#${SEVEN:-7} --from sala-test-ctl
[ "$RC" != 0 ] && has "$OUT" "no --words" && ok "--item: no door either" || bad "--item: rc=$RC $OUT"
enq sleep --project p-six --only sala-test-six-eng --from sala-test-ctl --words "owner: sleep it"
[ "$RC" != 0 ] && has "$OUT" "each stand alone" && ok "--project beside --only: refused" || bad "project+only: rc=$RC $OUT"
enq sleep --project 'bad key' --from sala-test-ctl --words "owner: sleep it"
[ "$RC" != 0 ] && has "$OUT" "is not a project key" && ok "a bad key: refused" || bad "bad key: rc=$RC $OUT"
enq sleep --project p-six --project p-fiv --from sala-test-ctl --words "owner: sleep it"
[ "$RC" != 0 ] && has "$OUT" "names its project once" && ok "two projects in one call: refused" || bad "two projects: rc=$RC $OUT"
enq wake --project p-six --from sala-test-ctl --words "owner: wake it"
[ "$RC" != 0 ] && has "$OUT" "wake takes --only NAME only" && ok "wake takes no --project" || bad "wake project: rc=$RC $OUT"
[ "$(ls "$OPS"/*.op 2>/dev/null | wc -l)" = "$q0" ] && ok "none of them left a marker" || bad "markers: $(ls "$OPS")"
enq sleep --project p-fou --from sala-test-ctl --words "owner: sleep it"
[ "$RC" != 0 ] && has "$OUT" "the plan" && has "$OUT" "did not pass" && [ "$(ls "$OPS"/*.op 2>/dev/null | wc -l)" = "$q0" ] && ok "a project the plan refuses (a job in flight): nothing queued" || bad "plan refuses: rc=$RC $OUT"

echo "== the plan, then the queued asked sleep of a project the asker is not in, and the runner"
run op --plan sleep --project projects/p-six --from sala-test-ctl
[ "$RC" = 0 ] && has "$OUT" "would put every session of project p-six to sleep together, its front agents too" && has "$OUT" "would put 2 session(s) to sleep together" && ! has "$OUT" "this pane" && ok "op --plan: the whole project, its front agent too, and the plan below it (sleep --project p-six --asked --dry-run)" || bad "op plan: rc=$RC $OUT"
enq sleep --project projects/p-six --from sala-test-ctl --words "owner: put it to sleep now"
[ "$RC" = 0 ] && [ -n "$ID" ] && ok "queued with the words, the KEY given as projects/p-six ($ID)" || bad "queue: rc=$RC $OUT"
M="$OPS/$ID.op"
[ "$(mval "$M" verb)" = sleep ] && [ "$(mvals "$M" arg | paste -sd' ')" = "--project p-six" ] && [ "$(mval "$M" words)" = "owner: put it to sleep now" ] && [ "$(mval "$M" from)" = sala-test-ctl ] && [ -z "$(mval "$M" nowords)$(mval "$M" reason)$(mval "$M" item)$(mval "$M" ownrow)" ] && ok "the marker (the key without projects/): verb=sleep, arg=--project p-six, the words verbatim, from the asker, no reason fields, no row ids" || bad "marker: $(cat "$M")"
! has "$OUT" "this pane" && ok "the asker is not a sleeper: no 'sleeps with it' line" || bad "sleeps-with-it line shown: $OUT"
run sleep sala-test-six-main --dry-run
[ "$RC" != 0 ] && has "$OUT" "a front agent" && ok "before the run: the front agent six-main alone is refused by name" || bad "six-main alone: rc=$RC $OUT"
SALA_OP_STUCK=off SALA_SLEEP_ASKER_WAIT=5 "$SALA" op --run "$ID" >/dev/null 2>&1
[ -f "$DONE/$ID.op" ] && ok "the runner ended it: archived" || bad "not archived: $(ls "$OPS" "$DONE" 2>&1 | tr '\n' ' ') $(tail -5 "$SALA_LOG_DIR/salamander-op-$ID.log" 2>/dev/null)"
allasleep $U_SIX && ok "p-six asleep, both sessions" || bad "p-six: $(ls "$SALA_SLEEP_DIR")"
run sleep --list
[ "$RC" = 0 ] && has "$OUT" "sala-test-six-main" && has "$OUT" "sala-test-six-eng" && ok "sala sleep --list shows both the front agent (six-main) and the background agent (six-eng)" || bad "list: rc=$RC $OUT"
[ "$(mval "$DONE/$ID.op" state)" = done ] && ok "state=done" || bad "state: $(mval "$DONE/$ID.op" state)"
grep -q "put project p-six to sleep" "$POSTS" && ok "the post says it put project p-six to sleep" || bad "post: $(tail -5 "$POSTS")"

echo "== the asker is one of the sleepers: the plan names it, the queue says it sleeps once idle, no line goes into its inbox afterwards"
# a project with a fresh pair of sessions: g-main (front) asks about its own project, g-eng is the other
mk gam-main 76 -e FAKE_IDLE_AGE=$IDLE; mk gam-eng 77 -e FAKE_IDLE_AGE=$IDLE
fake_up sala-test-gam-main sala-test-gam-eng || exit 1
for n in gam-main gam-eng; do "$SALA" adopt "sala-test-$n" >/dev/null 2>&1 || bad "adopt sala-test-$n failed"; done
"$SALA" sessions tag sala-test-gam-main --project projects/p-gam --role front >/dev/null 2>&1; "$SALA" sessions tag sala-test-gam-eng --project projects/p-gam --role back >/dev/null 2>&1
stoprec 76; stoprec 77; setact p-one - 2340 p-two - 2340 p-thr - 2340 p-fou - 2340 p-fiv - 2340 p-six - 2340 p-gam - 2340
run op --plan sleep --project p-gam --from sala-test-gam-main
[ "$RC" = 0 ] && has "$OUT" "the asking session sleeps once idle" && ok "op --plan from a member: the asking session sleeps once idle" || bad "member plan: rc=$RC $OUT"
enq sleep --project p-gam --from sala-test-gam-main --words "owner: sleep this project"
[ "$RC" = 0 ] && has "$OUT" "this pane ('sala-test-gam-main') sleeps with it once it is idle" && has "$OUT" "sala wake sala-test-gam-main resumes it" && ok "queued: the answer says the asker's pane sleeps with it once idle, and how it wakes" || bad "member queue: rc=$RC $OUT"
MID=$ID
SALA_OP_STUCK=off SALA_SLEEP_ASKER_WAIT=10 "$SALA" op --run "$MID" >/dev/null 2>&1
[ -f "$DONE/$MID.op" ] && ok "the runner ended it: archived" || bad "member op not archived: $(ls "$OPS" "$DONE" 2>&1 | tr '\n' ' ') $(tail -5 "$SALA_LOG_DIR/salamander-op-$MID.log" 2>/dev/null)"
allasleep 76 77 && ok "p-gam asleep, front agent (the asker) included" || bad "p-gam: $(ls "$SALA_SLEEP_DIR")"
grep -q "no reply sent: sala-test-gam-main went to sleep with op $MID" "$SALA_LOG_DIR/salamander-op.log" 2>/dev/null && ok "the log says no reply was sent to the sleeping asker" || bad "no 'no reply sent' line: $(grep "$MID" "$SALA_LOG_DIR/salamander-op.log" 2>/dev/null | tail -5)"
grep -q "put project p-gam to sleep" "$POSTS" && ok "the Slack post stands" || bad "post p-gam: $(tail -5 "$POSTS")"
! grep -q "salamander op $MID\]" "$HOME/.local/state/stackshot/inbox"/*/* 2>/dev/null && ok "and nothing was written to a stackshot inbox for it" || bad "an inbox line was written"

echo "== the teaching text names the verb"
run sleep --help
[ "$RC" = 0 ] && has "$OUT" "--project KEY [--asked]" && has "$OUT" "sala op sleep --project KEY --from YOU --words" && ok "sleep --help: --asked, and the queued line with the owner's words" || bad "sleep help: $OUT"
run op --help --full
has "$OUT" "op sleep --project KEY --from YOU --words" && has "$OUT" "sleep --project KEY                       every session of one project" && ok "op --help: the project's sleep in the list and in the shapes" || bad "op help: $(grep -n 'sleep' <<< "$OUT" | head -5)"
run sleep --project p-one --asked --dry-run   # (asleep already) the plan still says why
[ "$RC" = 1 ] && has "$OUT" "already asleep" && ok "a plan for a project that is asleep says so" || bad "asleep plan: rc=$RC $OUT"
run sleep sala-test-six-eng
[ "$RC" != 0 ] && ok "a plain sleep of a session that is asleep is still refused" || bad "plain sleep of a sleeper: rc=$RC $OUT"

[ "$fail" = 0 ] && echo "sleepasked: pass" || echo "sleepasked: FAIL"
exit $fail
