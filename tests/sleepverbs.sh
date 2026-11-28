#!/usr/bin/env bash
# Sleeping sessions, stage 2 (lib/sleep.sh, lib/wake.sh, lib/op.sh): the verbs that put an idle session to sleep and wake it, and their way through the operation
# queue. `sala sleep NAME` ends the claude of a session that sleep_ready (lib/wrapup.sh) passes (idle, nothing in flight, never a front agent), keeps its tmux
# session and pane-map row and writes the marker; `sala wake NAME` takes the marker off and resumes the row's conversation by its uuid through revive. Nothing
# sleeps on its own here: the watch's tick is stage 5 (tests/sleeptick.sh). What is checked, on a private tmux server with the compiled fake claude:
#  - sleep refuses, with one line saying why and nothing changed (claude still running, no marker): a session not idle for SALA_SLEEP_AFTER, a front agent, the
#    session the command runs in, a session already asleep; --dry-run says the same as "[dry-run] would refuse: ..." and changes nothing;
#  - sleep of a ready session ends its claude, keeps the tmux session and the pane-map row byte for byte, writes the marker and `sleep --list` shows it;
#  - wake --dry-run changes nothing; wake takes the marker off and the fake starts again on the SAME conversation uuid (one more start line, no other uuid);
#    a name that is not asleep is a message and no action (no start); a sleeper whose claude already runs only loses its marker; a sleeper whose tmux session
#    is gone is recreated and resumed;
#  - a wake without --cwd writes no folder, whatever folder a recreated pane stands in; `wake --only NAME --cwd DIR` resumes the sleeper in DIR and writes it
#    into the row, a target that is not relaunched writes nothing; each refusal; a raw --cwd from a Claude session is refused; the queue takes --cwd with the
#    owner's words only, its marker, runner, helper brief and done-check carry the folder (spaces and shell characters in its name);
#  - the queue: `op sleep|wake --only NAME…` takes only --only, plans with the verb's --dry-run, and with no words needs a reason (--item or --why) and a caller
#    placed by process ancestry (a plain shell is refused), never the asker itself; a wake of a session that is not asleep queues nothing; the queued marker
#    carries the reason, one ownrow= per name and no words; the runner (op --run) puts the session to sleep although its own marker names it, and wakes it;
#  - a raw `sleep` or `wake` from a Claude session is refused with the `sala op` line, and its --dry-run passes;
#  - `sala op --help`, `sala sleep --help` and `sala wake --help` name the verbs.
# SAFETY: every kill is a `kill -9` of ONE pid whose /proc/<pid>/exe is this suite's own compiled fake and whose environment names this suite's temporary HOME
# (kill_fake_claude); the tmux server is a private socket (tmux -L sala-sleepverbs-<pid> -f /dev/null, SALA_TMUX_SOCKET pointing at it), HOME is a mktemp -d
# held with flock, the claude is tests/fake-claude.c; the "Claude session" that asks is a copy of bash named claude in the fake versions folder; no real pane,
# server, ~/.claude or claude process is read or touched. Posts go to a file.
# Usage: bash tests/sleepverbs.sh   (exit 0 = pass)
set -u
unset TMUX TMUX_PANE XDG_STATE_HOME SALA_MASTER SALA_SET SALA_SET_SELF SALA_RECYCLE SALA_RETRY_WORKER SALA_LOCK_WHO SALA_LOCK_WAIT SALA_RELAUNCH_KIND SALA_SLEEP_DIR \
      SALA_FLEET_HOSTS SALA_CGROUP_FILE SALA_OP_QUEUE SALA_NO_RELAUNCH SALA_BOOT_ID SALA_CONFIG SALA_BARE_REVIVE SALA_IDLE_WRAPUP SALA_SESSION_ID SALA_STACKSHOT_INBOX \
      SALA_STACKSHOT_DIR SALA_STACKSHOT_CLIENT SALA_AGENT_CHECK_SCRIPT SALA_PROJECT_RECORD SALA_OP_ID SALA_OP_FROM SALA_OP_REASON_FROM
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
SANDBOX=""; SOCK="sala-sleepverbs-$$"; T="tmux -L $SOCK -f /dev/null"
cleanup() {
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    [ -z "$SANDBOX" ] || { kill_fake_claude "$FAKEBIN"; exec 8<&-; rm -rf "$SANDBOX" 2>/dev/null; }
    true
}; trap cleanup EXIT   # set before the temp folder exists
SANDBOX=$(mktemp -d); export HOME=$SANDBOX SALA_TZ=Etc/UTC SALA_CONFIG=/dev/null
case "$HOME" in /tmp/*|"${TMPDIR:-/tmp}"/*) ;; *) echo "sleepverbs: HOME is not a temporary directory ($HOME) - refusing to run"; exit 1;; esac
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
export SALA_OP_STUCK=off SALA_OP_QUEUE=off   # a queued marker is written and nothing starts it
SALA="$ROOT/bin/salamander"
export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's
case "$SOCK" in sala-sleepverbs-*) ;; *) echo "sleepverbs: not a private socket - refusing to run"; exit 1;; esac
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
n_starts() { starts "$(uuid "$1")"; }
row() { awk -F'\t' -v s="$1" '$1==s' "$MAP" 2>/dev/null; }
run() { OUT=$("$SALA" "$@" 2>&1); RC=$?; }   # → OUT, RC (stderr in OUT)
stoprec() { mkdir -p "$SALA_BUSY_DIR"; printf 'id=t%s\nepoch=%s\nseen=\nseen_status=idle\ntasks=0\ncrons=0\n' "$1" "$TURN" > "$SALA_BUSY_DIR/$(uuid "$1")"; }   # <uuid n>: the Stop hook's record of a finished turn
mval() { awk -F= -v k="$2" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$1" 2>/dev/null; }   # <marker file> <key> → its first value
mvals() { awk -F= -v k="$2" '$1==k {sub(/^[^=]*=/, ""); print}' "$1" 2>/dev/null; }
opfiles() { ls "$OPS"/*.op 2>/dev/null; }
export SALA_SLEEP_DIR   # the children read the same directory (its default under SALA_STATE_DIR)

# THE CALLER (as tests/retire-own.sh): a "Claude session's call" is a command run as a CHILD of a process named claude that is the pane process of a window of the
# asking session. The driver is a copy of bash installed in the versions folder and started through a symlink named claude; it runs each command file it is
# handed as its own child. callin <command…> hands it one and waits.
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
RAW="env SALA_CGROUP_FILE=/dev/null"   # a call that is not the queue's runner: the unit's cgroup file of this suite names none

echo "== setup: private tmux server, isolated HOME, the compiled fake claude (s, s2, q, g: idle and ready · n: idle only a minute · x-main: a front agent · d: control)"
mk s 6 -e FAKE_IDLE_AGE=4000; mk s2 12 -e FAKE_IDLE_AGE=4000; mk q 16 -e FAKE_IDLE_AGE=4000; mk g 15 -e FAKE_IDLE_AGE=4000
mk n 13 -e FAKE_IDLE_AGE=60; mk x-main 14 -e FAKE_IDLE_AGE=4000; mk d 4 -e FAKE_IDLE_AGE=4000
fake_up sala-test-s sala-test-s2 sala-test-q sala-test-g sala-test-n sala-test-x-main sala-test-d || exit 1
for n in s s2 q g n x-main d; do "$SALA" adopt "sala-test-$n" >/dev/null 2>&1 || bad "adopt sala-test-$n failed"; done
for u in 6 12 16 15 14 4; do stoprec "$u"; done
[ "$($T display -p '#{socket_path}')" = "$SALA_TMUX_SOCKET" ] && ok "the tmux server is the suite's private socket ($SOCK)" || bad "socket: $($T display -p '#{socket_path}')"
callin bash -c 'echo up'; [ "$RC" = 0 ] && [ "$OUT" = up ] && ok "a call runs inside the asker's driver window" || { bad "driver: rc=$RC $OUT"; exit 1; }
US=$(uuid 6); US2=$(uuid 12); UQ=$(uuid 16); UG=$(uuid 15); UD=$(uuid 4)

echo "== sleep refuses, says why in one line, and changes nothing"
s0=$(n_starts 6)
run sleep sala-test-n
[ "$RC" = 1 ] && has "$OUT" "not put to sleep" && has "$OUT" "idle for" && hasclaude n && [ -z "$(ls -A "$SALA_SLEEP_DIR" 2>/dev/null)" ] && ok "n (idle a minute): refused, its claude still runs, no marker ($OUT)" || bad "sleep n: rc=$RC — $OUT"
run sleep sala-test-n --dry-run
[ "$RC" = 1 ] && has "$OUT" "[dry-run] would refuse: sala-test-n: idle for" && has "$OUT" "nothing was changed" && ok "n --dry-run: the same refusal as a dry-run line, exit 1" || bad "sleep n dry: rc=$RC — $OUT"
run sleep sala-test-x-main
[ "$RC" = 1 ] && has "$OUT" "front agent" && hasclaude x-main && [ ! -e "$SALA_SLEEP_DIR/$(uuid 14)" ] && ok "x-main: a front agent, refused in one line, claude still runs" || bad "sleep x-main: rc=$RC — $OUT"
run sleep sala-test-x-main --dry-run
[ "$RC" = 1 ] && has "$OUT" "would refuse" && has "$OUT" "front agent" && ok "x-main --dry-run: the same" || bad "sleep x-main dry: rc=$RC — $OUT"
OUT=$(SALA_OP_FROM=sala-test-s "$SALA" sleep sala-test-s 2>&1); RC=$?
[ "$RC" = 1 ] && has "$OUT" "the session this command runs in" && hasclaude s && [ ! -e "$SALA_SLEEP_DIR/$US" ] && ok "a session never sleeps itself: refused, nothing changed" || bad "sleep self: rc=$RC — $OUT"
run sleep
[ "$RC" != 0 ] && has "$OUT" "usage: salamander sleep" && ok "sleep with no name: the usage" || bad "sleep none: rc=$RC — $OUT"
run sleep sala-test-s --force
[ "$RC" != 0 ] && has "$OUT" "unknown option" && hasclaude s && ok "there is no --force: an unknown option, nothing changed" || bad "sleep --force: rc=$RC — $OUT"
run sleep sala-test-nosuch
[ "$RC" = 1 ] && has "$OUT" "no tmux session" && ok "no such session: refused" || bad "sleep nosuch: rc=$RC — $OUT"

echo "== sleep when the stackshot server does not answer (SALA_INBOX_MODE=server, tests/fake-inbox-client.py): refused in one line, nothing changed"
export FAKE_INBOX_DIR="$HOME/fakeinbox"; mkdir -p "$FAKE_INBOX_DIR/inbox/hub" "$FAKE_INBOX_DIR/inbox/msg"
SRV="env SALA_INBOX_MODE=server SALA_STACKSHOT_CLIENT=$ROOT/tests/fake-inbox-client.py SALA_INBOX_TIMEOUT=2 SALA_INBOX_BREAKER=0"
OUT=$($SRV FAKE_INBOX_FAIL=hold FAKE_INBOX_HOW=down "$SALA" sleep sala-test-s 2>&1); RC=$?
[ "$RC" = 1 ] && has "$OUT" "not put to sleep" && has "$OUT" "inbox could not be held" && hasclaude s && [ ! -e "$SALA_SLEEP_DIR/$US" ] && ok "the hold call fails: sleep s is refused (a sleep may not go on with its inbox open), claude running, no marker ($OUT)" || bad "sleep s, hold down: rc=$RC — $OUT"
OUT=$($SRV FAKE_INBOX_FAIL=waiting FAKE_INBOX_HOW=down "$SALA" sleep sala-test-s 2>&1); RC=$?
[ "$RC" = 1 ] && has "$OUT" "could not be asked whether a message waits" && hasclaude s && [ ! -e "$SALA_SLEEP_DIR/$US" ] && ok "the waiting check cannot be asked: refused as 'could not be asked', not taken for nothing waiting" || bad "sleep s, waiting down: rc=$RC — $OUT"
printf '{"to":"sala-test-s","text":"hello"}\n' > "$FAKE_INBOX_DIR/inbox/msg/m1.json"
OUT=$($SRV "$SALA" sleep sala-test-s 2>&1); RC=$?
[ "$RC" = 1 ] && has "$OUT" "a stackshot msg message waits for it" && hasclaude s && ok "a line waiting on the server refuses the sleep, as a line in the local inbox does" || bad "sleep s, line on the server: rc=$RC — $OUT"
rm -f "$FAKE_INBOX_DIR/inbox/msg/m1.json"; rm -rf "$FAKE_INBOX_DIR"; unset FAKE_INBOX_DIR

echo "== sleep --dry-run of a ready session changes nothing"
run sleep sala-test-s --dry-run
[ "$RC" = 0 ] && has "$OUT" "[dry-run]" && has "$OUT" "would hold its stackshot inbox" && hasclaude s && [ ! -e "$SALA_SLEEP_DIR/$US" ] && [ "$(n_starts 6)" = "$s0" ] && ok "s --dry-run: says what it would do, exit 0, claude running, no marker" || bad "sleep s dry: rc=$RC — $OUT"

echo "== sleep: the claude ends, the tmux session and the pane-map row stay, the marker is written"
row0=$(row sala-test-s); [ -n "$row0" ] || bad "no pane-map row for s before the sleep"
run sleep sala-test-s
[ "$RC" = 0 ] && has "$OUT" "asleep" && ok "sleep s: exit 0, 'asleep' ($OUT)" || bad "sleep s: rc=$RC — $OUT"
! hasclaude s && ok "its claude has ended" || bad "s still has a claude"
$T has-session -t "=sala-test-s" 2>/dev/null && ok "its tmux session stays" || bad "tmux session of s is gone"
[ "$(row sala-test-s)" = "$row0" ] && ok "its pane-map row is byte for byte the same" || bad "row changed: '$row0' → '$(row sala-test-s)'"
[ -f "$SALA_SLEEP_DIR/$US" ] && [[ $(<"$SALA_SLEEP_DIR/$US") =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ sala-test-s$ ]] && ok "the marker is '<ISO-Z time> sala-test-s'" || bad "marker: $(<"$SALA_SLEEP_DIR/$US" 2>/dev/null)"
is_sleeping sala-test-s && ok "is_sleeping says so" || bad "is_sleeping s false"
case "$($T display -p -t =sala-test-s: '#{pane_current_command}')" in bash|sh|zsh|fish) ok "the pane is back at its shell" ;; *) bad "pane command: $($T display -p -t =sala-test-s: '#{pane_current_command}')" ;; esac
run sleep --list
[ "$RC" = 0 ] && has "$OUT" "sala-test-s" && has "$OUT" "asleep since" && has "$OUT" "$US" && ! has "$OUT" "sala-test-d" && ok "sleep --list shows s, when it went to sleep and its conversation" || bad "sleep --list: rc=$RC — $OUT"
echo "== sleep --list --json: the lane and the model a wake would launch each sleeper on, read as resume_cmd reads them (the web page's Agents table shows them)"
cp -f "$SALA_LANES" "$HOME/lanes.tsv.keep" 2>/dev/null; cp -f "$SALA_MODELS" "$HOME/models.tsv.keep" 2>/dev/null
printf 'sala-test-s\tsubscription-2\n' >> "$SALA_LANES"; printf 'sala-test-s\topus\thigh\n' >> "$SALA_MODELS"
run sleep --list --json
JS=$(python3 -c 'import json,sys
d = json.loads(sys.stdin.read()); r = [x for x in d if x["name"] == "sala-test-s"]
print(len(d), len(r), r[0]["conversation"], r[0]["lane"], r[0]["model"], r[0]["effort"], len(r[0]["env"]), r[0]["since"][:2])' <<< "$OUT" 2>&1)
[ "$RC" = 0 ] && [ "$JS" = "1 1 $US subscription-2 opus high 0 20" ] && ok "sleep --list --json: one object, the sleeper's lanes.tsv row as its lane, its models.tsv row as model and effort ($JS)" || bad "sleep --list --json: rc=$RC js=$JS — $OUT"
! has "$OUT" "claude --resume" && ! has "$OUT" "--model" && ok "the launch line itself is never printed" || bad "the json holds the launch line: $OUT"
rm -f "$SALA_LANES" "$SALA_MODELS"; mv -f "$HOME/lanes.tsv.keep" "$SALA_LANES" 2>/dev/null; mv -f "$HOME/models.tsv.keep" "$SALA_MODELS" 2>/dev/null
run sleep --list --json
JS=$(python3 -c 'import json,sys
d = json.loads(sys.stdin.read()); r = [x for x in d if x["name"] == "sala-test-s"]
print(r[0]["lane"], r[0]["model"] or "-")' <<< "$OUT" 2>&1)
[ "$RC" = 0 ] && [ "${JS%% *}" = "$(lane_for_session sala-test-s)" ] && ok "with no row: the default lane, as lane_for_session says ($JS)" || bad "sleep --list --json, no row: rc=$RC js=$JS"
[ -f "$SALA_SLEEP_DIR/$US" ] && ok "listing it is read-only: the marker is still there" || bad "the marker is gone after --list --json"
run sleep --json
[ "$RC" != 0 ] && has "$OUT" "--json goes with --list" && ok "--json alone is refused" || bad "sleep --json: rc=$RC — $OUT"
run sleep sala-test-s
[ "$RC" = 1 ] && has "$OUT" "already asleep" && ok "asking again: 'already asleep', refused" || bad "sleep s again: rc=$RC — $OUT"
sleep 1; [ "$(n_starts 6)" = "$s0" ] && ! hasclaude s && ok "nothing revived it in the meantime" || bad "s started again? starts $(n_starts 6) vs $s0"

echo "== wake: --dry-run changes nothing; the real wake resumes the same conversation"
run wake sala-test-s --dry-run
[ "$RC" = 0 ] && has "$OUT" "[dry-run]" && has "$OUT" "revive --only sala-test-s resumes conversation $US" && [ -f "$SALA_SLEEP_DIR/$US" ] && ! hasclaude s && ok "wake s --dry-run: the plan, marker still there, no claude" || bad "wake s dry: rc=$RC — $OUT"
run wake sala-test-s
[ "$RC" = 0 ] && has "$OUT" "awake" && ok "wake s: exit 0, 'awake' ($OUT)" || bad "wake s: rc=$RC — $OUT"
[ ! -e "$SALA_SLEEP_DIR/$US" ] && ! is_sleeping sala-test-s && ok "the marker is off" || bad "marker still there"
waitfor 'hasclaude s' 40; hasclaude s && ok "a claude runs in the pane again" || bad "no claude after the wake"
[ "$(n_starts 6)" = "$((s0 + 1))" ] && ok "the fake started once more, on the same conversation uuid ($US)" || bad "starts of $US: $(n_starts 6), was $s0"
[ "$(row sala-test-s)" = "$row0" ] && ok "the pane-map row is still the same" || bad "row after wake: '$(row sala-test-s)'"
s1=$(n_starts 6)
run wake sala-test-s
[ "$RC" = 0 ] && has "$OUT" "not sleeping, nothing done" && [ "$(n_starts 6)" = "$s1" ] && ok "wake of a session that is not asleep: a message, exit 0, no action" || bad "wake s again: rc=$RC starts=$(n_starts 6) — $OUT"
run wake sala-test-nosuch
[ "$RC" = 0 ] && has "$OUT" "not sleeping" && ok "wake of a name nobody knows: the same message" || bad "wake nosuch: rc=$RC — $OUT"
run wake sala-test-s sala-test-nosuch --dry-run
[ "$RC" = 0 ] && has "$OUT" "would do nothing" && ok "wake --dry-run of non-sleepers: nothing to do, exit 0" || bad "wake dry non-sleepers: rc=$RC — $OUT"
run wake
[ "$RC" != 0 ] && has "$OUT" "usage: salamander wake" && ok "wake with no name: the usage" || bad "wake none: rc=$RC — $OUT"

echo "== wake of a sleeper whose claude already runs takes the marker off and starts nothing"
sleeping_mark "$UD" sala-test-d; d0=$(n_starts 4)
run wake sala-test-d
[ "$RC" = 0 ] && has "$OUT" "already running" && [ ! -e "$SALA_SLEEP_DIR/$UD" ] && [ "$(n_starts 4)" = "$d0" ] && ok "d: marker off, no second claude on the conversation" || bad "wake d: rc=$RC starts=$(n_starts 4)/$d0 — $OUT"

echo "== wake of a sleeper whose tmux session is gone recreates the session and resumes the conversation"
run sleep sala-test-g
[ "$RC" = 0 ] && ! hasclaude g && is_sleeping sala-test-g && ok "g is asleep" || bad "sleep g: rc=$RC — $OUT"
g0=$(n_starts 15); $T kill-session -t "=sala-test-g"
run wake sala-test-g --dry-run
[ "$RC" = 0 ] && has "$OUT" "its tmux session is gone" && has "$OUT" "recreate the session" && is_sleeping sala-test-g && ok "wake g --dry-run: would recreate the session, marker stays" || bad "wake g dry: rc=$RC — $OUT"
run wake sala-test-g
[ "$RC" = 0 ] && has "$OUT" "awake" && $T has-session -t "=sala-test-g" 2>/dev/null && ! is_sleeping sala-test-g && ok "wake g: the tmux session is back, the marker off" || bad "wake g: rc=$RC — $OUT"
waitfor 'hasclaude g' 40; [ "$(n_starts 15)" = "$((g0 + 1))" ] && hasclaude g && ok "the conversation $UG resumed in it (one more start)" || bad "g starts: $(n_starts 15) vs $g0"

echo "== a raw sleep or wake from a Claude session is refused with the sala op line; its dry run passes"
# (a target named sala-test-* passes the guard from any pane, ops_guard: so the raw calls name a plain one, which the guard refuses before it looks at anything)
callin $RAW "$SALA" sleep plain-nosuch
[ "$RC" != 0 ] && has "$OUT" "sleep is a fleet operation" && has "$OUT" "sala op sleep --only NAME" && has "$OUT" "--from sala-test-asker" && ok "raw sleep: refused, points to 'sala op sleep --only NAME …' with the asker's name" || bad "raw sleep: rc=$RC — $OUT"
callin $RAW "$SALA" sleep plain-nosuch --dry-run
[ "$RC" = 1 ] && has "$OUT" "[dry-run] would refuse" && ! has "$OUT" "fleet operation" && ok "raw sleep --dry-run passes the guard (and refuses on its own: no such session)" || bad "raw sleep dry: rc=$RC — $OUT"
callin $RAW "$SALA" wake plain-nosuch
[ "$RC" != 0 ] && has "$OUT" "wake is a fleet operation" && has "$OUT" "sala op wake --only NAME" && ok "raw wake: refused, points to 'sala op wake --only NAME …'" || bad "raw wake: rc=$RC — $OUT"
callin $RAW "$SALA" wake plain-nosuch --dry-run
[ "$RC" = 0 ] && has "$OUT" "[dry-run]" && ! has "$OUT" "fleet operation" && ok "raw wake --dry-run passes the guard" || bad "raw wake dry: rc=$RC — $OUT"
callin $RAW "$SALA" sleep --list
[ "$RC" = 0 ] && ok "sleep --list is read-only: it needs no queue" || bad "raw sleep --list: rc=$RC — $OUT"

echo "== the queue: shape, plan, and the words policy"
rm -rf "$OPS"; mkdir -p "$OPS"
run op --plan sleep --only sala-test-s2
[ "$RC" = 0 ] && has "$OUT" "plan: salamander sleep sala-test-s2" && has "$OUT" "[dry-run]" && has "$OUT" "plan only: nothing queued" && [ -z "$(opfiles)" ] && ok "op --plan sleep: the verb's dry run, nothing queued" || bad "op --plan sleep: rc=$RC — $OUT"
run op sleep --only sala-test-s2 --force --why "a reason of words" --from sala-test-asker
[ "$RC" != 0 ] && has "$OUT" "takes --only NAME only" && [ -z "$(opfiles)" ] && ok "op sleep takes --only and nothing else (--force refused)" || bad "op sleep --force: rc=$RC — $OUT"
run op sleep sala-test-s2 --why "a reason of words" --from sala-test-asker
[ "$RC" != 0 ] && has "$OUT" "takes --only NAME only" && ok "op sleep NAME (no --only): refused" || bad "op sleep NAME: rc=$RC — $OUT"
run op sleep --only sala-test-s2 --only sala-test-s2 --why "a reason of words" --from sala-test-asker
[ "$RC" != 0 ] && has "$OUT" "twice" && ok "a name twice: refused" || bad "op sleep twice: rc=$RC — $OUT"
run op sleep --only sala-test-s2 --from sala-test-asker
[ "$RC" != 0 ] && has "$OUT" "no --words" && has "$OUT" "op sleep --only NAME" && [ -z "$(opfiles)" ] && ok "no words and no reason: refused, the refusal names the sleep and wake door" || bad "op sleep no reason: rc=$RC — $OUT"
run op sleep --only sala-test-s2 --why "a reason of words" --from sala-test-asker
[ "$RC" != 0 ] && [ -z "$(opfiles)" ] && ok "a reason from a plain shell (no Claude session above the call): refused, nothing queued ($(printf '%s' "$OUT" | tail -1 | cut -c1-120))" || bad "op sleep from a shell: rc=$RC — $OUT"
run op sleep --only sala-test-s2 --why "two words" --from sala-test-asker
[ "$RC" != 0 ] && has "$OUT" "three words or more" && ok "--why of two words: refused" || bad "op sleep --why short: rc=$RC — $OUT"
run op wake --only sala-test-s2 --item board#abc --from sala-test-asker
[ "$RC" != 0 ] && has "$OUT" "not a board item id" && ok "--item must be board#N" || bad "op wake bad item: rc=$RC — $OUT"
run op rename sala-test-s2 sala-test-s9 --why "a reason of words" --from sala-test-asker
[ "$RC" != 0 ] && has "$OUT" "only with revive, restore, sleep and wake" && ok "--why is for revive, restore, sleep and wake only" || bad "op rename --why: rc=$RC — $OUT"
callin "$SALA" op sleep --only sala-test-asker --why "a reason of words" --from sala-test-asker
[ "$RC" != 0 ] && has "$OUT" "asking session itself" && [ -z "$(opfiles)" ] && ok "the asker itself is refused (a sleep of yourself would end the call)" || bad "op sleep self: rc=$RC — $OUT"
callin "$SALA" op sleep --only sala-test-x-main --why "a reason of words" --from sala-test-asker
[ "$RC" != 0 ] && has "$OUT" "front agent" && has "$OUT" "nothing queued" && [ -z "$(opfiles)" ] && ok "a front agent: the plan (sleep --dry-run) refuses before anything is queued" || bad "op sleep front: rc=$RC — $OUT"
callin "$SALA" op sleep --only sala-test-n --why "a reason of words" --from sala-test-asker
[ "$RC" != 0 ] && has "$OUT" "idle for" && [ -z "$(opfiles)" ] && ok "a session idle only a minute: refused by the plan, nothing queued" || bad "op sleep n: rc=$RC — $OUT"
callin "$SALA" op sleep --only sala-test-s2 --why "a reason of words" --from sala-test-other
[ "$RC" != 0 ] && [ -z "$(opfiles)" ] && ok "--from naming another session than the caller: refused" || bad "op sleep wrong from: rc=$RC — $OUT"
callin "$SALA" op wake --only sala-test-s2 --why "a reason of words" --from sala-test-asker
[ "$RC" = 0 ] && has "$OUT" "not sleeping, nothing to wake" && [ -z "$(opfiles)" ] && ok "op wake of a session that is not asleep: said, exit 0, nothing queued" || bad "op wake awake: rc=$RC — $OUT"
run op wake --only sala-test-s2 --words "wake it" --from sala-test-asker
[ "$RC" = 0 ] && has "$OUT" "not sleeping" && [ -z "$(opfiles)" ] && ok "the same with the owner's words: nothing queued" || bad "op wake words: rc=$RC — $OUT"

echo "== the queue: a no-words sleep through the reason door, and the runner"
callin "$SALA" op sleep --only sala-test-s2 --why "idle for the whole afternoon" --from sala-test-asker
if [ "$RC" = 0 ]; then ok "op sleep --only s2 --why … from the asker: queued ($(printf '%s' "$OUT" | grep -m1 '^queued' | cut -c1-100))"; else bad "op sleep s2: rc=$RC — $OUT"; fi
M=$(opfiles | head -1)
if [ -n "$M" ]; then
    [ "$(mval "$M" verb)" = sleep ] && [ "$(mvals "$M" arg | paste -sd, -)" = "--only,sala-test-s2" ] && ok "the marker: verb=sleep, arg=--only, arg=sala-test-s2" || bad "marker verb/args: $(cat "$M")"
    [ -z "$(mval "$M" words)" ] && [ "$(mval "$M" nowords)" = "words: none (reason: idle for the whole afternoon)" ] && [ "$(mval "$M" reason)" = "idle for the whole afternoon" ] && [ -z "$(mval "$M" item)" ] && ok "no words; nowords= and reason= carry the reason" || bad "marker words: $(cat "$M")"
    [ "$(mvals "$M" ownrow | grep -c .)" = 1 ] && [ "$(mval "$M" from)" = sala-test-asker ] && [ "$(mval "$M" state)" = queued ] && ok "one ownrow= (the registry row), from=sala-test-asker, state=queued" || bad "marker rows: $(cat "$M")"
    OPID=$(basename "$M" .op)
    SALA_OP_STUCK=off "$SALA" op --run "$OPID" >/dev/null 2>&1
    is_sleeping sala-test-s2 && ! hasclaude s2 && ok "the runner (op --run) put s2 to sleep although its own queued marker names it" || bad "runner: is_sleeping=$(is_sleeping sala-test-s2 && echo y || echo n) claude=$(hasclaude s2 && echo y || echo n) — $(tail -3 "$SALA_LOG_DIR/salamander-op-$OPID.log" 2>/dev/null)"
    [ -f "$DONE/$OPID.op" ] && [ "$(mval "$DONE/$OPID.op" state)" = done ] && ok "the operation ended done and was archived" || bad "after the run: $(cat "$M" "$DONE/$OPID.op" 2>/dev/null | tr '\n' ' ')"
    grep -q "put sala-test-s2 to sleep" "$POSTS" 2>/dev/null && ok "the post says it put s2 to sleep" || bad "post: $(tail -4 "$POSTS" | tr '\n' ' ')"
else bad "no marker was queued"; fi

ITEM="board#$((9100 + 1))"
echo "== the queue: a no-words wake (--item), the plan, and the runner"
run op --plan wake --only sala-test-s2
[ "$RC" = 0 ] && has "$OUT" "plan: salamander wake sala-test-s2" && has "$OUT" "resume" && has "$OUT" "plan only: nothing queued" && ok "op --plan wake: the plan" || bad "op --plan wake: rc=$RC — $OUT"
callin "$SALA" op wake --only sala-test-s2 --item $ITEM --from sala-test-asker
if [ "$RC" = 0 ]; then ok "op wake --only s2 --item $ITEM: queued"; else bad "op wake s2: rc=$RC — $OUT"; fi
M=$(opfiles | head -1)
if [ -n "$M" ]; then
    [ "$(mval "$M" verb)" = wake ] && [ "$(mval "$M" item)" = $ITEM ] && [ -z "$(mval "$M" words)" ] && [ "$(mval "$M" nowords)" = "words: none ($ITEM: wake of one session)" ] && ok "the marker: verb=wake, item=$ITEM, no words" || bad "wake marker: $(cat "$M")"
    [ "$(mval "$M" ownrow)" = "$US2" ] && ok "ownrow= is the sleeper's conversation id" || bad "wake ownrow: '$(mval "$M" ownrow)' vs $US2"
    OPID=$(basename "$M" .op); w0=$(n_starts 12)
    SALA_OP_STUCK=off "$SALA" op --run "$OPID" >/dev/null 2>&1
    waitfor 'hasclaude s2' 40
    ! is_sleeping sala-test-s2 && hasclaude s2 && [ "$(n_starts 12)" = "$((w0 + 1))" ] && ok "the runner woke s2: marker off, its claude resumed on $US2" || bad "wake runner: sleeping=$(is_sleeping sala-test-s2 && echo y || echo n) starts=$(n_starts 12)/$w0 — $(tail -3 "$SALA_LOG_DIR/salamander-op-$OPID.log" 2>/dev/null)"
    [ -f "$DONE/$OPID.op" ] && [ "$(mval "$DONE/$OPID.op" state)" = done ] && ok "the wake ended done and was archived" || bad "after the wake: $(cat "$M" "$DONE/$OPID.op" 2>/dev/null | tr '\n' ' ')"
else bad "no wake marker was queued"; fi

echo "== a reason-door marker is judged again by the runner: a changed row goes stuck with nothing done"
sleeping_mark "$UQ" sala-test-q; rm -f "$OPS"/*.op
callin "$SALA" op wake --only sala-test-q --why "wake it for the check" --from sala-test-asker
M=$(opfiles | head -1)
if [ "$RC" = 0 ] && [ -n "$M" ]; then
    OPID=$(basename "$M" .op); sed -i "s/^ownrow=.*/ownrow=not-the-conversation/" "$M"; q0=$(n_starts 16)
    SALA_OP_STUCK=off "$SALA" op --run "$OPID" >/dev/null 2>&1
    is_sleeping sala-test-q && [ "$(n_starts 16)" = "$q0" ] && grep -q "nothing was woken" "$DONE/$OPID.op" 2>/dev/null && ok "the row replaced since it was queued: stuck, nothing woken, q still asleep" || bad "stuck wake: sleeping=$(is_sleeping sala-test-q && echo y || echo n) $(cat "$DONE/$OPID.op" "$M" 2>/dev/null | tr '\n' ' ')"
else bad "op wake q: rc=$RC — $OUT"; fi
sleeping_clear "$UQ"

echo "== a relaunch writes a folder only when --cwd names it: wake, the guard and the queue (lib/wake.sh, lib/op.sh; revive itself: ledger-recycle.sh)"
rm -rf "$OPS"; mkdir -p "$OPS" "$HOME/saved" "$HOME/wt" "$HOME/short-lived"
NEW="$HOME/new role's \$HOME; (a) & \"b\" c\\d"; NEW2="$HOME/second role"; mkdir -p "$NEW" "$NEW2"
mk f 17 -c "$HOME/saved"; fake_up sala-test-f; "$SALA" adopt sala-test-f >/dev/null 2>&1
UF=$(uuid 17)
frow() { printf 'sala-test-f\t%s\tsala-test-f\t%s' "$UF" "$1"; }                      # <folder> → the row f should have
rowis() { [ "$(row sala-test-f)" = "$(frow "$1")" ]; }                                # <folder>
fpane() { $T display -p -t sala-test-f '#{pane_current_path}'; }
fcwd() { readlink "/proc/$(cpid f)/cwd" 2>/dev/null; }                                # the folder the claude of f runs in
end_f() { local c; c=$(cpid f 2>/dev/null); [ -z "$c" ] || { $T send-keys -t sala-test-f '/exit' Enter; waitfor "! kill -0 $c 2>/dev/null" 20; }; }
down_f() { end_f; sleeping_mark "$UF" sala-test-f; }                                  # a sleeper: its claude ended, its marker on
gone_f() { local c; c=$(cpid f 2>/dev/null); $T kill-session -t "=sala-test-f" 2>/dev/null; [ -z "$c" ] || waitfor "! kill -0 $c 2>/dev/null" 20; return 0; }
recreate_f() {  # <folder> [tmux -e options…] → f as tmux-resurrect leaves it after a reboot: a bare shell in <folder>
    local d=$1; shift; gone_f
    $T new-session -d -s sala-test-f -x 200 -y 50 -c "$d" -e FAKE_SESSION_ID="$UF" -e FAKE_NAME=sala-test-f -e FAKE_LOG="$FAKE_LOG" -e FAKE_STARTED_AT="$START" "$@"
    waitfor '[ -n "$(fpane)" ]' 20; }
wakef() { f0=$(n_starts 17); run wake "$@"; }
woken() { waitfor 'hasclaude f' 40; [ "$RC" = 0 ] && hasclaude f && [ "$(n_starts 17)" = "$((f0 + 1))" ] && ! is_sleeping sala-test-f; }   # → the last wake started the conversation once
untouched() { rowis "$1" && [ "$(n_starts 17)" = "$f0" ]; }                           # <folder> → the row as it was and no start
rowis "$HOME/saved" || bad "setup: row '$(row sala-test-f)'"

down_f; rmdir "$HOME/saved"; recreate_f "$HOME"
wakef sala-test-f; woken && rowis "$HOME/saved" && ok "(A) saved folder gone, the pane recreated in \$HOME: a wake without --cwd leaves the row" || bad "wake (A): rc=$RC row='$(row sala-test-f)' — $OUT"
mkdir -p "$HOME/saved"; down_f; recreate_f "$HOME/wt"
wakef sala-test-f; woken && rowis "$HOME/saved" && ok "(B) the pane recreated in a worktree: a wake without --cwd leaves the row" || bad "wake (B): rc=$RC row='$(row sala-test-f)' — $OUT"
rmdir "$HOME/wt"

down_f; wakef --only sala-test-f --cwd "$NEW" --dry-run
[ "$RC" = 0 ] && has "$OUT" "pane-map folder $HOME/saved → $NEW" && is_sleeping sala-test-f && untouched "$HOME/saved" && ok "wake --cwd --dry-run: the plan shows old → new, nothing changed" || bad "wake --cwd dry: rc=$RC row='$(row sala-test-f)' — $OUT"
wakef --only sala-test-f --cwd "$NEW"
woken && [ "$(fcwd)" = "$NEW" ] && rowis "$NEW" && has "$OUT" "resumed conversation $UF in $NEW" && ok "wake --cwd: resumed in that folder (spaces, quotes, a backslash, \$ ; & in its name) and the row carries it" || bad "wake --cwd: rc=$RC cwd='$(fcwd)' row='$(row sala-test-f)' — $OUT"
wakef --only sala-test-f --cwd "$NEW2"
[ "$RC" = 1 ] && has "$OUT" "not sleeping" && has "$OUT" "unchanged" && untouched "$NEW" && ok "wake --cwd of a session that is not asleep: said, exit 1, nothing written" || bad "wake --cwd awake: rc=$RC row='$(row sala-test-f)' — $OUT"
wakef --only sala-test-f --cwd "$NEW2" --dry-run
[ "$RC" = 1 ] && has "$OUT" "would refuse" && untouched "$NEW" && ok "its dry run says it would refuse" || bad "wake --cwd awake dry: rc=$RC — $OUT"
sleeping_mark "$UF" sala-test-f; wakef --only sala-test-f --cwd "$NEW2" --dry-run
[ "$RC" = 1 ] && has "$OUT" "would refuse" && is_sleeping sala-test-f && ok "a marked sleeper whose claude runs: the dry run refuses and keeps the marker" || bad "wake --cwd running dry: rc=$RC — $OUT"
wakef --only sala-test-f --cwd "$NEW2"
[ "$RC" = 1 ] && has "$OUT" "not relaunched" && has "$OUT" "unchanged" && ! is_sleeping sala-test-f && untouched "$NEW" && ok "the real run takes the marker off, relaunches nothing and writes nothing" || bad "wake --cwd running: rc=$RC row='$(row sala-test-f)' — $OUT"
down_f; gone_f; wakef --only sala-test-f --cwd "$NEW2" --dry-run
[ "$RC" = 0 ] && has "$OUT" "recreate the session in the new folder" && has "$OUT" "pane-map folder $NEW → $NEW2" && ! $T has-session -t =sala-test-f 2>/dev/null && untouched "$NEW" && ok "tmux session gone, dry run: old → new, nothing created" || bad "wake --cwd gone dry: rc=$RC — $OUT"
wakef --only sala-test-f --cwd "$NEW2"
woken && [ "$(fpane)" = "$NEW2" ] && [ "$(fcwd)" = "$NEW2" ] && rowis "$NEW2" && ok "tmux session gone: created in the folder, resumed, the row carries it" || bad "wake --cwd gone: rc=$RC pane='$(fpane)' row='$(row sala-test-f)' — $OUT"
down_f; recreate_f "$HOME" -e FAKE_RESUME_FAIL=1; wakef --only sala-test-f --cwd "$NEW"
[ "$RC" = 1 ] && has "$OUT" "pane-map folder is unchanged" && has "$OUT" "salamander revive --only sala-test-f --cwd" && rowis "$NEW2" && ok "a resume that fails writes nothing and says how to finish the move" || bad "wake --cwd failed resume: rc=$RC row='$(row sala-test-f)' — $OUT"

recreate_f "$HOME"; sleeping_mark "$UF" sala-test-f; f0=$(n_starts 17)
refused() {  # <what the refusal says> <wake or revive arguments…> → refused, f still asleep, nothing started or written
    local want=$1; shift; run "$@"
    [ "$RC" != 0 ] && has "$OUT" "$want" && is_sleeping sala-test-f && untouched "$NEW2" && ok "refused: $* → $want" || bad "$*: rc=$RC row='$(row sala-test-f)' — $OUT"; }
refused "exactly one --only" wake sala-test-f --cwd "$NEW"
refused "exactly one --only" wake --cwd "$NEW"
refused "exactly one --only" wake --only sala-test-f --only sala-test-s --cwd "$NEW"
refused "exactly one --only" wake --only sala-test-f sala-test-s --cwd "$NEW"
refused "needs an absolute path" wake --only sala-test-f --cwd saved
refused "not an existing directory" wake --only sala-test-f --cwd "$HOME/no-such-folder"
refused "unknown option: --only" wake --only sala-test-f
refused "salamander wake --only sala-test-f --cwd" revive --only sala-test-f --cwd "$NEW"
# a name outside sala-test-*: the guard lets test sessions through (common.sh, ops_guard)
callin $RAW "$SALA" wake --only plain-nosuch --cwd "$NEW"
[ "$RC" != 0 ] && has "$OUT" "sala op wake" && ok "a raw wake --cwd from a Claude session: refused with the queue's line" || bad "raw wake --cwd: rc=$RC — $OUT"
callin $RAW "$SALA" revive --only plain-nosuch --cwd "$NEW"
[ "$RC" != 0 ] && has "$OUT" "sala op revive" && ok "a raw revive --cwd from a Claude session: refused" || bad "raw revive --cwd: rc=$RC — $OUT"
callin $RAW SALA_RECYCLE=1 SALA_RETRY_WORKER=1 "$SALA" revive --only plain-nosuch --cwd "$NEW"
[ "$RC" != 0 ] && has "$OUT" "sala op revive" && ok "also with the environment of a recycle or a retry worker" || bad "raw revive --cwd, worker env: rc=$RC — $OUT"
callin $RAW "$SALA" revive --only plain-nosuch --cwd "$NEW" --dry-run
[ "$RC" != 0 ] && has "$OUT" "not in the pane map" && ! $T has-session -t =plain-nosuch 2>/dev/null && ok "its --dry-run passes the guard (and finds no row)" || bad "raw revive --cwd dry: rc=$RC — $OUT"

noop() { [ -z "$(opfiles)" ] && untouched "$NEW2"; }                                  # → nothing queued, nothing done
down_f; f0=$(n_starts 17)
run op --plan wake --only sala-test-f --cwd "$NEW"
[ "$RC" = 0 ] && has "$OUT" "plan: salamander wake --only sala-test-f --cwd" && has "$OUT" "pane-map folder $NEW2 → $NEW" && noop && ok "op --plan wake --cwd: old → new, nothing queued" || bad "op --plan wake --cwd: rc=$RC — $OUT"
for door in "--item $ITEM" "--why=move" --auto; do
    case "$door" in --why=move) callin "$SALA" op wake --only sala-test-f --cwd "$NEW" --why "move it to the new role" --from sala-test-asker ;;
        --auto) run op wake --only sala-test-f --cwd "$NEW" --auto ;;
        *) callin "$SALA" op wake --only sala-test-f --cwd "$NEW" --item "$ITEM" --from sala-test-asker ;; esac
    [ "$RC" != 0 ] && has "$OUT" "--cwd moves a session to another folder" && is_sleeping sala-test-f && noop && ok "op wake --cwd ${door%%[ =]*} with no words: refused, nothing queued" || bad "op wake --cwd $door: rc=$RC — $OUT"
done
oprefused() {  # <what the refusal says> <op arguments…> → refused although the words are there
    local want=$1; shift; callin "$SALA" op "$@" --words "move it to the new role" --from sala-test-asker
    [ "$RC" != 0 ] && has "$OUT" "$want" && noop && ok "op refused: $* → $want" || bad "op $*: rc=$RC — $OUT"; }
oprefused "exactly one --only" wake --only sala-test-f --only sala-test-s --cwd "$NEW"
oprefused "exactly one --only" wake --cwd "$NEW"
oprefused "exactly one --only" revive --cwd "$NEW"
oprefused "exactly one --only" revive --only sala-test-f --only sala-test-s --cwd "$NEW"
oprefused "needs an absolute path" wake --only sala-test-f --cwd saved
oprefused "not an existing directory" revive --only sala-test-f --cwd "$HOME/no-such-folder"
oprefused "--cwd is given once" revive --only sala-test-f --cwd "$NEW" --cwd "$NEW2"
oprefused "takes --only NAME only" sleep --only sala-test-s --cwd "$NEW"
oprefused "sala op wake --only sala-test-f --cwd" revive --only sala-test-f --cwd "$NEW"

queue() { rm -rf "$OPS"; mkdir -p "$OPS"; callin "$SALA" op "$@" --words "move it to the new role" --from sala-test-asker; M=$(opfiles | head -1); OPID=""; [ -z "$M" ] || OPID=$(basename "$M" .op); }
runop() { f0=$(n_starts 17); SALA_OP_STUCK=off "$SALA" op --run "$OPID" >/dev/null 2>&1; }
queue wake --only sala-test-f --cwd "$NEW"
[ "$RC" = 0 ] && [ -n "$M" ] && [ "$(mvals "$M" arg)" = "$(printf '%s\n' --only sala-test-f --cwd "$NEW")" ] && [ -n "$(mval "$M" words)" ] && ok "op wake --cwd with words: queued, the marker holds the folder as given, one argument a line" || bad "op wake --cwd queue: rc=$RC marker='$(cat "$M" 2>/dev/null)' — $OUT"
if [ -n "$OPID" ]; then
    sed -i 's/^words=.*/words=/' "$M"; runop
    is_sleeping sala-test-f && untouched "$NEW2" && grep -q "the marker carries none" "$DONE/$OPID.op" 2>/dev/null && ok "the runner refuses a --cwd marker that carries no words: stuck, nothing woken" || bad "runner without words: row='$(row sala-test-f)' $(cat "$DONE/$OPID.op" 2>/dev/null | tr '\n' ' ')"
fi
queue wake --only sala-test-f --cwd "$HOME/short-lived"; rmdir "$HOME/short-lived"
if [ -n "$OPID" ]; then
    runop; is_sleeping sala-test-f && untouched "$NEW2" && grep -q "not an existing directory" "$DONE/$OPID.op" 2>/dev/null && ok "a folder removed after the queueing: the runner goes stuck, nothing woken" || bad "runner, folder gone: row='$(row sala-test-f)' $(cat "$DONE/$OPID.op" 2>/dev/null | tr '\n' ' ')"
else bad "op wake --cwd short-lived: rc=$RC — $OUT"; fi
queue wake --only sala-test-f --cwd "$NEW"
if [ -n "$OPID" ]; then
    runop; waitfor 'hasclaude f' 40
    ! is_sleeping sala-test-f && [ "$(fcwd)" = "$NEW" ] && rowis "$NEW" && [ "$(mval "$DONE/$OPID.op" state)" = done ] && ok "the runner wakes it in the folder and writes the row: done" || bad "runner wake --cwd: cwd='$(fcwd)' row='$(row sala-test-f)' $(cat "$DONE/$OPID.op" 2>/dev/null | tr '\n' ' ')"
    cp "$DONE/$OPID.op" "$OPS/$OPID.op"; v=$(. "$ROOT/lib/op.sh"; op_verify "$OPID" && echo verified || echo "$OP_VERIFY_WHY"); rm -f "$OPS/$OPID.op"
    [ "$v" = verified ] && ok "the check of a helper's done reads the wake's name and folder apart" || bad "op_verify wake --cwd: $v"
else bad "op wake --cwd: rc=$RC — $OUT"; fi
f0=$(n_starts 17); callin "$SALA" op wake --only sala-test-f --cwd "$NEW2" --words "move it to the new role" --from sala-test-asker
rm -rf "$OPS"; mkdir -p "$OPS"
[ "$RC" != 0 ] && has "$OUT" "not sleeping" && has "$OUT" "pane-map folder is unchanged" && untouched "$NEW" && ok "op wake --cwd of a session that is awake: said, exit 1, nothing queued" || bad "op wake --cwd awake: rc=$RC — $OUT"
f0=$(n_starts 17); run revive --only sala-test-f --cwd "$NEW2"
[ "$RC" = 1 ] && has "$OUT" "pane-map folder is unchanged" && untouched "$NEW" && ok "revive --cwd of a live current claude without --force: not relaunched, said, nothing written" || bad "revive --cwd no force: rc=$RC row=$(row sala-test-f) — $OUT"
queue revive --only sala-test-f --cwd "$NEW2"
[ "$RC" != 0 ] && [ -z "$OPID" ] && has "$OUT" "would refuse" && untouched "$NEW" && ok "op revive --cwd of a live current claude without --force: the plan refuses, nothing queued" || bad "op revive --cwd no force: rc=$RC — $OUT"
queue revive --force --only sala-test-f --cwd "$NEW2"
[ "$RC" = 0 ] && has "$OUT" "pane-map folder $NEW → $NEW2" && [ -n "$OPID" ] && ok "op revive --force --cwd with words: queued, the plan shows old → new" || bad "op revive --cwd queue: rc=$RC — $OUT"
if [ -n "$OPID" ]; then
    v=$(. "$ROOT/lib/op.sh"; op_verify "$OPID" && echo verified || echo "$OP_VERIFY_WHY"; op_brief "$OPID" "a failure of the test")
    has "$v" "does not carry the folder" && has "$v" "$(cwd_quote "$NEW2")" && ok "before the run the check of a done fails, and the helper's brief carries the folder quoted for a shell" || bad "op_verify/op_brief: $(printf '%s' "$v" | head -c 600)"
    runop; waitfor 'hasclaude f' 40
    [ "$(n_starts 17)" = "$((f0 + 1))" ] && [ "$(fcwd)" = "$NEW2" ] && rowis "$NEW2" && [ "$(mval "$DONE/$OPID.op" state)" = done ] && ok "the runner relaunches it in the folder and writes the row: done" || bad "runner revive --cwd: cwd='$(fcwd)' row='$(row sala-test-f)' $(cat "$DONE/$OPID.op" 2>/dev/null | tr '\n' ' ')"
fi
gone_f; rm -rf "$OPS"; mkdir -p "$OPS"

echo "== a project's back agent starts in SALA_BACK_CWD on a wake and every relaunch; every other session keeps its folder (common.sh, THE FOLDER OF A BACK AGENT)"
BK="$HOME/back role"; FR="$HOME/front role"; mkdir -p "$BK" "$FR"; export SALA_BACK_CWD='~/back role'
tagf() { "$SALA" sessions tag sala-test-f "$@" >/dev/null 2>&1 || bad "sessions tag $*"; }
sleeper() { recreate_f "$FR"; sleeping_mark "$UF" sala-test-f; }                       # f asleep, its pane a bare shell in the front folder
kept() { woken && [ "$(fcwd)" = "$FR" ] && rowis "$NEW2"; }                           # → woken where the pane stood, the row as it was
moved() { waitfor 'hasclaude f && [ "$(fcwd)" = "$BK" ]' 40; [ "$(fcwd)" = "$BK" ] && rowis "$BK"; }   # → the claude runs in the back folder, the row carries it
away() { run revive --force --only sala-test-f --cwd "$NEW"; waitfor 'hasclaude f' 40; [ "$(fcwd)" = "$NEW" ] && rowis "$NEW" || bad "setup, f moved away: rc=$RC cwd='$(fcwd)' row='$(row sala-test-f)' — $OUT"; }
keeps() { sleeper; wakef sala-test-f; kept && ok "$1: woken in its own folder" || bad "$1: rc=$RC cwd='$(fcwd)' row='$(row sala-test-f)' — $OUT"; }
keeps "no role"
tagf --project projects/demo --role front; keeps "a front agent"
tagf --role back   # tagged back, as a retag does it
sessions_set sala-test-f project= >/dev/null 2>&1; keeps "the role word back with no project"
sessions_set sala-test-f project=projects/demo side=1 >/dev/null 2>&1; keeps "a side session"
sessions_set sala-test-f side= >/dev/null 2>&1
SALA_BACK_CWD='' keeps "SALA_BACK_CWD unset"
SALA_BACK_CWD="$HOME/no-such-folder" keeps "SALA_BACK_CWD naming no directory"
sleeper; wakef sala-test-f --dry-run
[ "$RC" = 0 ] && has "$OUT" "in $BK (a back agent: SALA_BACK_CWD)" && is_sleeping sala-test-f && untouched "$NEW2" && ok "wake --dry-run of a back agent names the folder and changes nothing" || bad "back wake dry: rc=$RC row='$(row sala-test-f)' — $OUT"
wakef sala-test-f
woken && moved && has "$OUT" "resumed conversation $UF in $BK" && ok "a plain wake of an agent tagged back: the same conversation in SALA_BACK_CWD, the row carries it" || bad "back wake: rc=$RC cwd='$(fcwd)' row='$(row sala-test-f)' — $OUT"
down_f; wakef --only sala-test-f --cwd "$NEW"
woken && [ "$(fcwd)" = "$NEW" ] && rowis "$NEW" && ok "wake --cwd of a back agent: the folder given wins" || bad "back wake --cwd: rc=$RC cwd='$(fcwd)' row='$(row sala-test-f)' — $OUT"
run revive --force --only sala-test-f --dry-run
has "$OUT" "in $BK (a back agent: SALA_BACK_CWD)" && rowis "$NEW" && ok "revive --dry-run names the folder" || bad "back revive dry: rc=$RC — $OUT"
f0=$(n_starts 17); run revive --force --only sala-test-f
moved && [ "$(n_starts 17)" = "$((f0 + 1))" ] && has "$OUT" "pane-map folder $NEW → $BK" && ok "a relaunch of the running claude (recycle, lane and model moves): in SALA_BACK_CWD" || bad "back revive: rc=$RC cwd='$(fcwd)' row='$(row sala-test-f)' — $OUT"
away; FP=$($T list-panes -t =sala-test-f -F '#{pane_id}' | head -1); f0=$(n_starts 17)
OUT=$(SALA_SELF_WAIT=60 "$SALA" revive --self-worker "$FP" 2>&1); RC=$?
[ "$RC" = 0 ] && moved && [ "$(n_starts 17)" = "$((f0 + 1))" ] && has "$OUT" "pane-map folder $NEW → $BK" && ok "the self-worker relaunches there too" || bad "back self-worker: rc=$RC cwd='$(fcwd)' row='$(row sala-test-f)' — $OUT"
away; gone_f; run restore sala-test-f --dry-run
has "$OUT" "detached in $BK" && rowis "$NEW" && ok "restore --dry-run: the session would be made in SALA_BACK_CWD" || bad "back restore dry: rc=$RC — $OUT"
f0=$(n_starts 17); run restore sala-test-f
[ "$RC" = 0 ] && moved && [ "$(fpane)" = "$BK" ] && [ "$(n_starts 17)" = "$((f0 + 1))" ] && ok "restore (a reboot's boot half): made and resumed there" || bad "back restore: rc=$RC pane='$(fpane)' row='$(row sala-test-f)' — $OUT"
away; down_f; gone_f; wakef sala-test-f --dry-run
has "$OUT" "recreate the session in SALA_BACK_CWD" && ! $T has-session -t =sala-test-f 2>/dev/null && ok "wake --dry-run with the tmux session gone names it" || bad "back wake gone dry: rc=$RC — $OUT"
wakef sala-test-f
woken && moved && [ "$(fpane)" = "$BK" ] && ok "wake with the tmux session gone: made and resumed there" || bad "back wake gone: rc=$RC pane='$(fpane)' row='$(row sala-test-f)' — $OUT"
unset SALA_BACK_CWD; gone_f

echo "== the teaching text names the verbs"
run op --help --full
has "$OUT" "op sleep --only NAME" && has "$OUT" "op wake --only NAME" && ok "sala op --help --full lists sleep and wake" || bad "op --help: $OUT"
run sleep --help
[ "$RC" = 0 ] && has "$OUT" "usage: salamander sleep" && ok "sleep --help" || bad "sleep --help: rc=$RC — $OUT"
run wake --help
[ "$RC" = 0 ] && has "$OUT" "usage: salamander wake" && ok "wake --help" || bad "wake --help: rc=$RC — $OUT"
run --help
has "$OUT" "salamander sleep NAME" && has "$OUT" "salamander wake NAME" && ok "the top-level help lists both verbs" || bad "--help lacks the verbs"
run op --help --full
has "$OUT" "op revive|wake --only NAME --cwd DIR" && has "$OUT" "wake --only NAME --cwd DIR" && ok "sala op --help --full teaches --cwd" || bad "op --help lacks --cwd: $OUT"
run wake --help; has "$OUT" "wake --only NAME --cwd DIR" && ok "wake --help names --cwd" || bad "wake --help: $OUT"
run revive --help; has "$OUT" "revive --only NAME --cwd DIR" && ok "revive --help names --cwd" || bad "revive --help: $OUT"
run --help; has "$OUT" "wake --only NAME --cwd DIR" && has "$OUT" "revive --only NAME --cwd DIR" && ok "the top-level help names --cwd" || bad "--help lacks --cwd"

[ "$fail" = 0 ] && echo "sleepverbs: pass" || echo "sleepverbs: FAIL"
exit $fail
