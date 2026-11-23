#!/usr/bin/env bash
# Sleeping sessions, stage 1 (lib/common.sh "THE SLEEPING SESSIONS", lib/wrapup.sh sleep_ready): the predicate and every exclusion. A session that has
# been idle a long time may sleep: its claude process ends, its tmux session and pane-map row stay, and a later stage wakes it by resuming its
# conversation. Nothing here puts a session to sleep or wakes one: a marker ($SALA_SLEEP_DIR/<conversation uuid>, one line `<ISO-Z time> <name>`) is made
# by hand, and with it NOTHING in sala may revive, restore, fail or count the session as missing. Every case runs a marked pane next to an unmarked control
# (the control is still handled as before). What is checked, on a private tmux server with the compiled fake claude:
#  - the predicate: a tmux session name or a session name resolves through the pane map to the conversation's marker; no marker (or no marker directory) is
#    not asleep; a marker is one path component (no slash, no leading dot); mark / clear / list / rename keep the one-line format; no_relaunch is true for it;
#    the pane map's four columns, the session registry and the published state carry no word of it, byte for byte;
#  - 1 the bare-pane heal: a clock started before the marker is cleared, the pane is never revived and no "could not revive" is posted; the control is revived;
#  - 2 revive: `--only NAME` is refused by name as sleeping (as for SALA_NO_RELAUNCH), never resumed; the sweep counts it as `sleeping`, never as
#    skipped; the control is resumed;
#  - 3 restore: not missing (ledger_missing, restore --missing), not recreated (restore NAME, ledger_compare_restore), not resumed; the control is;
#  - 4 the deferred list and the recycle set: a deferred row of a sleeping pane is dropped and the set no longer counts it (not gave, not left behind);
#  - 5 stale_panes does not list it; 6 lane and model: the table row only, no relaunch (`sala lane X NAME`, `sala model NAME X`), the control's plan relaunches;
#  - 7 retire, close-shell, forget-row, rename work with no /exit and no live claude and clear the marker (rename rewrites its name text); adopt and box say
#    "sleeping" instead of "no claude"; 8 `sala op revive|restore --only NAME` says "sleeping: its claude ended on purpose" and queues nothing;
#  - 9 the wrap-up tick lists no pane with no claude; 10 `sala sessions` and `sala spawn --list` show `sleeping` (display; since stage 3 the JSON adds a `sleeping` key too);
#  - sleep_ready: yes for an idle, free pane; and each refusal with its reason: no session, already asleep, the Remote Control session, SALA_NO_RELAUNCH,
#    a side session, no pane-map row, no claude, the sdk lane, idle too short, a busy registry row, a draft in the box, a scheduled job, a queued operation naming it,
#    a note waiting, the deferred list, an open set, the waiting flag, a stackshot inbox message (routed by `to`, `uuid` or `name` exactly: a line for a longer
#    name or a text that only mentions the session refuses nothing), a limit stop, a network stop, a question open on its screen.
# SAFETY: every kill is a `kill -9` of ONE pid whose /proc/<pid>/exe is this suite's own compiled fake and whose environment names this suite's temporary HOME
# (killfake, kill_fake_claude); the tmux server is a private socket (tmux -L sala-sleeping-<pid> -f /dev/null, SALA_TMUX_SOCKET pointing at it), HOME is a
# mktemp -d held with flock, the claude is tests/fake-claude.c; no real pane, server, ~/.claude or claude process is read or touched. Posts go to a file.
# Usage: bash tests/sleeping.sh   (exit 0 = pass)
set -u
unset TMUX TMUX_PANE XDG_STATE_HOME SALA_SET SALA_SET_SELF SALA_RECYCLE SALA_RETRY_WORKER SALA_LOCK_WHO SALA_LOCK_WAIT SALA_RELAUNCH_KIND SALA_SLEEP_DIR \
      SALA_FLEET_HOSTS SALA_CGROUP_FILE SALA_OP_QUEUE SALA_NO_RELAUNCH SALA_BOOT_ID SALA_CONFIG SALA_BARE_REVIVE SALA_IDLE_WRAPUP SALA_SESSION_ID SALA_STACKSHOT_INBOX \
      SALA_STACKSHOT_DIR SALA_STACKSHOT_CLIENT SALA_AGENT_CHECK_SCRIPT SALA_PROJECT_RECORD
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
SANDBOX=""; SOCK="sala-sleeping-$$"; T="tmux -L $SOCK -f /dev/null"
cleanup() {
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    [ -z "$SANDBOX" ] || { kill_fake_claude "$FAKEBIN"; exec 8<&-; rm -rf "$SANDBOX" 2>/dev/null; }
    true
}; trap cleanup EXIT   # set before the temp folder exists
SANDBOX=$(mktemp -d); export HOME=$SANDBOX SALA_TZ=Etc/UTC SALA_CONFIG=/dev/null
case "$HOME" in /tmp/*|"${TMPDIR:-/tmp}"/*) ;; *) echo "sleeping: HOME is not a temporary directory ($HOME) - refusing to run"; exit 1;; esac
exec 8< "$SANDBOX"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
as_op_unit   # the guarded verbs this suite runs itself stand for the queue's runner (tests/lib.sh, 5)
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOME/.claude-team" "$HOME/work"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
printf '{"fake":true}\n' > "$HOME/.claude-team/.credentials.json"   # the team lane is signed in, so a lane record for it is accepted
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
case "$SOCK" in sala-sleeping-*) ;; *) echo "sleeping: not a private socket - refusing to run"; exit 1;; esac
WLOG="$HOME/.claude/salamander-watch.log"; ST="$HOME/.claude/salamander-watch.state"; : > "$WLOG"
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux    # literal socket: the children run set -u
$T new-session -d -s sala-test-keep -x 200 -y 50 -c "$HOME"; $T set -g exit-empty off   # a server that outlives its last fake
. "$ROOT/lib/common.sh"; . "$ROOT/lib/wrapup.sh"
MAP="$SALA_SIDECAR"; OPS="$SALA_STATE_DIR/ops"
now0=$(date +%s); START=$((now0 - 10800)); TURN=$((now0 - 7200))   # the fakes' process started 3 h ago; their last turn ended 2 h ago
# mk <suffix> <uuid n> [tmux -e options…] → a fake claude in sala-test-<suffix>
mk() {
    local n="$1" u; u=$(uuid "$2"); shift 2
    $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="sala-test-$n" -e FAKE_LOG="$FAKE_LOG" -e FAKE_TYPED_LOG="$FAKE_TYPED_LOG" \
        -e FAKE_STARTED_AT="$START" -e FAKE_TURN_MS=1500 "$@"
    $T send-keys -t "sala-test-$n" 'claude' Enter
}
killfake() {  # <tmux session> → SIGKILL of this suite's fake under that session's pane, and only it (kill_fake_claude's checks, for one pane)
    local pp p
    pp=$($T list-panes -t "=$1" -F '#{pane_pid}' 2>/dev/null | head -1); [ -n "$pp" ] || return 1
    for p in $(pgrep -P "$pp" -x claude); do
        [ "$FAKEBIN" -ef "/proc/$p/exe" ] && grep -qz "^HOME=$HOME\$" "/proc/$p/environ" 2>/dev/null && kill -9 "$p"
    done
    return 0
}
hasclaude() { local pp; pp=$($T list-panes -t "=sala-test-$1" -F '#{pane_pid}' 2>/dev/null | head -1); [ -n "$pp" ] && [ -n "$(claude_pid_under "$pp" 2>/dev/null)" ]; }   # <suffix>
n_starts() { starts "$(uuid "$1")"; }
tick() { "$SALA" watch >/dev/null 2>&1; }
wlogn() { grep -c -- "$1" "$WLOG" 2>/dev/null || true; }
row() { awk -F'\t' -v s="$1" '$1==s' "$MAP" 2>/dev/null; }
run() { OUT=$("$SALA" "$@" 2>&1); RC=$?; }   # → OUT, RC (stderr in OUT)
stoprec() { mkdir -p "$SALA_BUSY_DIR"; printf 'id=t%s\nepoch=%s\nseen=\nseen_status=idle\ntasks=0\ncrons=%s\n%s' "$1" "${2:-$TURN}" "${3:-0}" "${4:-}" > "$SALA_BUSY_DIR/$(uuid "$1")"; }   # <uuid n> [epoch] [crons] [extra lines]
set_reg_stamp() {  # <pid> <epoch s> → statusUpdatedAt of that claude's row = that second
    local f="$HOME/.claude/sessions/$1.json" t; t=$(slurp "$f")
    [[ $t =~ \"statusUpdatedAt\":[0-9]+ ]] && t=${t/"${BASH_REMATCH[0]}"/\"statusUpdatedAt\":${2}000}
    printf '%s' "$t" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
}
# the stubs of the two scans that need the watch's own tables (lib/wrapup.sh _sleep_limit_stopped, _sleep_net_stopped): a flag file says "stopped"
lw_scan() { cat >/dev/null; [ -f "$HOME/t_limit" ] && echo "stop x"; return 0; }
net_stopped_sessions() { [ -f "$HOME/t_net" ] && echo "$1|1"; return 0; }
[ "$SALA_SLEEP_DIR" = "$SALA_STATE_DIR/sleeping" ] && ok "SALA_SLEEP_DIR defaults to \$SALA_STATE_DIR/sleeping" || bad "SALA_SLEEP_DIR=$SALA_SLEEP_DIR"
export SALA_SLEEP_DIR   # the children read the same directory

echo "== setup: private tmux server, isolated HOME, the compiled fake claude (a, b: to sleep · c: control · d: always live · e: restore control · s, u, t: sleep_ready)"
mk a 1; mk b 2; mk c 3; mk d 4; mk e 5
mk s 6 -e FAKE_IDLE_AGE=4000; mk u 8 -e FAKE_IDLE_AGE=4000; mk t 7 -e FAKE_IDLE_AGE=4000
fake_up sala-test-a sala-test-b sala-test-c sala-test-d sala-test-e sala-test-s sala-test-u sala-test-t || exit 1
for n in a b c d e s u; do "$SALA" adopt "sala-test-$n" >/dev/null 2>&1 || bad "adopt sala-test-$n failed"; done   # t stays out of the pane map on purpose
[ "$($T display -p '#{socket_path}')" = "$SALA_TMUX_SOCKET" ] && ok "the tmux server is the suite's private socket ($SOCK)" || bad "socket: $($T display -p '#{socket_path}')"
UA=$(uuid 1); UB=$(uuid 2); UC=$(uuid 3); UE=$(uuid 5)

echo "== the predicate: a marker per conversation, found by tmux session or by name"
is_sleeping sala-test-a && bad "a is asleep with no marker directory" || ok "no marker directory: not asleep"
mkdir -p "$SALA_SLEEP_DIR"; is_sleeping sala-test-a && bad "a is asleep with an empty marker directory" || ok "an empty marker directory: not asleep"
sleeping_mark "$UA" sala-test-a && ok "sleeping_mark wrote a marker" || bad "sleeping_mark failed"
is_sleeping sala-test-a && ok "a is asleep (found by its tmux session name)" || bad "a not asleep after its marker"
is_sleeping sala-test-c && bad "c is asleep with no marker of its own" || ok "c (no marker): not asleep, whatever is marked beside it"
no_relaunch sala-test-a && ok "no_relaunch is true for a sleeping session (the one choke point)" || bad "no_relaunch false for a"
no_relaunch sala-test-c && bad "no_relaunch true for c" || ok "no_relaunch stays false for c"
[ "$(wc -l < "$SALA_SLEEP_DIR/$UA")" = 1 ] && [[ $(<"$SALA_SLEEP_DIR/$UA") =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ sala-test-a$ ]] && ok "the marker is one line, '<ISO-Z time> <name>'" || bad "marker: $(<"$SALA_SLEEP_DIR/$UA")"
sleeping_list | grep -q "^$UA	.*Z	sala-test-a$" && ok "sleeping_list: uuid, time, name" || bad "list: $(sleeping_list)"
sleeping_mark ../x name 2>/dev/null && bad "a path was taken as a conversation id" || ok "a marker name with a slash is refused (one path component only)"
sleeping_mark .hid name 2>/dev/null && bad "a leading dot was taken" || ok "a leading dot is refused"
[ -z "$(ls -A "$SALA_SLEEP_DIR" | grep -v "^$UA\$")" ] && ok "nothing but the one marker is in the directory (no temp left)" || bad "directory: $(ls -A "$SALA_SLEEP_DIR")"
sleeping_rename "$UA" sala-test-aa; [[ $(<"$SALA_SLEEP_DIR/$UA") =~ Z\ sala-test-aa$ ]] && ok "sleeping_rename rewrites the name text, keeps the time" || bad "renamed marker: $(<"$SALA_SLEEP_DIR/$UA")"
sleeping_rename "$UA" sala-test-a
sleeping_clear "$UA"; is_sleeping sala-test-a && bad "a still asleep after sleeping_clear" || ok "sleeping_clear removes it"
sleeping_clear "$UA"; sleeping_mark "$UA" sala-test-a; sleeping_mark "$UB" sala-test-b
cp "$MAP" "$HOME/map.before"; cp "$SALA_SESSIONS_FILE" "$HOME/reg.before" 2>/dev/null || : > "$HOME/reg.before"
run sessions; run spawn --list; sleeping_clear "$UB"; sleeping_mark "$UB" sala-test-b
same_file "$MAP" "$HOME/map.before" && ok "the pane map is byte for byte as before (four columns, no marker column)" || bad "pane map changed: $(diff "$HOME/map.before" "$MAP")"
{ [ ! -e "$SALA_SESSIONS_FILE" ] && [ ! -s "$HOME/reg.before" ]; } || same_file "$SALA_SESSIONS_FILE" "$HOME/reg.before" && ok "the session registry is byte for byte as before" || bad "registry changed"
[ "$(grep -ci sleep "$MAP" "$SALA_SESSIONS_FILE" 2>/dev/null | awk -F: '{n+=$NF} END {print n+0}')" = 0 ] && ok "neither the map nor the registry says 'sleep'" || bad "the word is in a published file"

echo "== 10: display only — sala sessions and sala spawn --list show the state"
run sessions
a_line=$(grep 'sala-test-a ' <<< "$OUT"); c_line=$(grep 'sala-test-c ' <<< "$OUT")
has "$a_line" sleeping && ok "sala sessions: a's STATE is 'sleeping'" || bad "sessions a: $a_line"
has "$c_line" live && ! has "$c_line" sleeping && ok "sala sessions: the control's STATE stays 'live'" || bad "sessions c: $c_line"
run sessions --json; has "$OUT" '"state": "live"' && has "$OUT" '"sleeping": "' && [ "$(grep -c '"sleeping"' <<< "$OUT")" = 2 ] && ok "sala sessions --json: a and b carry 'sleeping' (stage 3), state stays live; c has none (tests/sleepshow.sh checks the shape)" || bad "json: $(head -c 300 <<< "$OUT")"

echo "== 1: the bare-pane heal — a clock started before the marker is cleared, the pane never revived, nothing posted"
a0=$(n_starts 1); b0=$(n_starts 2); c0=$(n_starts 3)
sleeping_clear "$UA"; sleeping_clear "$UB"
for n in a b c; do killfake "sala-test-$n"; done
waitfor '! hasclaude a && ! hasclaude b && ! hasclaude c' 40 || bad "the fakes did not die"
export SALA_BARE_GRACE=3 SALA_BARE_MAX=6 SALA_BARE_RETRY=1 SALA_BARE_TRIES=1
tick
grep -q "^bare.sala-test-a=" "$ST" && grep -q "^bare.sala-test-c=" "$ST" && ok "a and c are bare: a clock each" || bad "state: $(grep bare "$ST")"
sleeping_mark "$UA" sala-test-a; sleeping_mark "$UB" sala-test-b
sleep 4; tick
waitfor 'hasclaude c' 40 && [ "$(n_starts 3)" = "$((c0 + 1))" ] && ok "the control c (bare, no marker) is revived once" || bad "c: starts $(n_starts 3) vs $c0; $(tail -5 "$WLOG")"
! hasclaude a && ! hasclaude b && [ "$(n_starts 1)" = "$a0" ] && [ "$(n_starts 2)" = "$b0" ] && ok "a and b (sleeping) are not revived" || bad "starts a=$(n_starts 1)/$a0 b=$(n_starts 2)/$b0"
! grep -q "^bare.sala-test-a=\|^bare.sala-test-b=" "$ST" && ok "the clock a started before it slept is gone from the watch state" || bad "state: $(grep bare "$ST")"
tick; sleep 2; tick
[ "$(nposts 'could not revive')" = 0 ] && ! grep -q "sala-test-a\|sala-test-b" "$POSTS" && ok "no 'could not revive' and no post naming a sleeper, past the grace and the tries" || bad "posts: $(<"$POSTS")"
[ "$(wlogn "bare panes: reviving.*sala-test-a")" = 0 ] && ok "the log never names a in a revive" || bad "log: $(grep sala-test-a "$WLOG" | tail -3)"
killfake sala-test-c; waitfor '! hasclaude c' 40; c0=$(n_starts 3)

echo "== 2: revive --only — resumed never, listed as sleeping, never as skipped; the sweep's plan lists it"
run revive --only sala-test-a
[ "$RC" != 0 ] && has "$OUT" "sala-test-a: sleeping" && has "$OUT" "--only refused" && ! hasclaude a && [ "$(n_starts 1)" = "$a0" ] && ok "revive --only a: refused by name as sleeping (as a SALA_NO_RELAUNCH session is), no claude, no start" || bad "revive a: rc=$RC starts $(n_starts 1)/$a0 — $OUT"
run revive --only sala-test-a --dry-run
[ "$RC" != 0 ] && has "$OUT" "sala-test-a: sleeping" && ! has "$OUT" "shell pane" && ok "revive --only a --dry-run: refused the same way, nothing planned" || bad "dry run: rc=$RC — $OUT"
run revive --only sala-test-c
waitfor 'hasclaude c' 40 && [ "$(n_starts 3)" = "$((c0 + 1))" ] && ok "the control c is resumed by the same call" || bad "revive c: rc=$RC starts $(n_starts 3)/$c0 — $OUT"
run revive --dry-run
has "$OUT" "; 2 sleeping" && ! has "$OUT" "sala-test-a:0: would" && ok "the sweep's plan counts a and b as sleeping, and plans neither for a relaunch" || bad "sweep plan: $OUT"
killfake sala-test-c; waitfor '! hasclaude c' 40; c0=$(n_starts 3)

echo "== 3: restore — a sleeping session is not missing, not recreated, not resumed"
$T kill-session -t "=sala-test-b"; $T kill-session -t "=sala-test-e"; killfake sala-test-e
ledger_missing | cut -f1 > "$HOME/missing.txt"
grep -qx sala-test-e "$HOME/missing.txt" && ! grep -qx sala-test-b "$HOME/missing.txt" && ok "ledger_missing: e (control) is missing, b (sleeping, its tmux session gone) is not" || bad "missing: $(<"$HOME/missing.txt")"
run restore --missing --dry-run
has "$OUT" "sala-test-e" && ! has "$OUT" "sala-test-b" && ok "restore --missing --dry-run names e and not b" || bad "dry: $OUT"
run restore sala-test-b
[ "$RC" = 0 ] && has "$OUT" "sleeping" && ! $T has-session -t "=sala-test-b" 2>/dev/null && [ "$(n_starts 2)" = "$b0" ] && ok "restore b: left alone (sleeping), no tmux session made, no claude started" || bad "restore b: rc=$RC — $OUT"
run restore sala-test-b --dry-run
has "$OUT" "sleeping" && ok "restore b --dry-run: says sleeping" || bad "restore dry: $OUT"
printf '%s\n%s\n' "$(row sala-test-b)" "$(row sala-test-e)" > "$HOME/roster.tsv"
out=$(ledger_compare_restore Reboot "$HOME/roster.tsv" 2>&1)
waitfor 'hasclaude e' 60 && ! $T has-session -t "=sala-test-b" 2>/dev/null && has "$out" "sleeping" && ok "ledger_compare_restore: e recreated and resumed, b named as sleeping and left" || bad "compare: $out"
sleeping_mark "$UB" sala-test-b

echo "== 4: the deferred list and the recycle set — a sleeping pane no longer counts; a control still does"
$T new-session -d -s sala-test-b -c "$HOME"   # b's pane again (a bare shell), still asleep
S1="$(date +%s)-901"; set_create "$S1" Recycle recycle 2 0 9.9.9 1 out=sala-test-a out=sala-test-c hook=1
printf 'sala-test-a\t%s\tbackground work\t0\t0\t%s\n' "$(date +%s)" "$S1" > "$SALA_DEFERRED"
export SALA_BARE_REVIVE=off
tick
export SALA_BARE_REVIVE=on
! grep -q '^sala-test-a	' "$SALA_DEFERRED" 2>/dev/null && ok "a's deferred row is dropped" || bad "deferred: $(<"$SALA_DEFERRED")"
grep -q "sala-test-a is sleeping" "$WLOG" && ok "the log says why: 'sala-test-a is sleeping'" || bad "log: $(tail -4 "$WLOG")"
[ "$(set_count "$S1" gave)" = 0 ] && ! _set_out "$S1" sala-test-a && [ "$(set_val "$S1" total)" = 1 ] && _set_out "$S1" sala-test-c && ok "the set: a is neither gave nor outstanding, the total is 1, c (control) is still outstanding" || bad "set: $(<"$SALA_SET_DIR/$S1")"
! grep -qE 'sala-test-a.*(not relaunched|still waiting|could not|gave up)' "$POSTS" && ok "no 'not relaunched' or 'gave up' post for a sleeper" || bad "posts: $(<"$POSTS")"
run revive --only sala-test-a --force; [ "$(set_count "$S1" gave)" = 0 ] && ok "a forced revive of a leaves no skip in the set either" || bad "set after revive: $(<"$SALA_SET_DIR/$S1")"

echo "== 5: stale_panes — a sleeping session is never stale"
sp=$(stale_panes 0.0.1)
has "$sp" sala-test-d && ! has "$sp" sala-test-a && ! has "$sp" sala-test-b && ok "stale_panes lists the live control d, not the sleepers" || bad "stale: $sp"

echo "== 6: lane and model — the table row only, no relaunch"
run lane team sala-test-a
[ "$RC" = 0 ] && has "$OUT" sleeping && [ "$(lane_row sala-test-a)" = subscription-2 ] && ! hasclaude a && [ "$(n_starts 1)" = "$a0" ] && ok "sala lane team a: row written, 'sleeping' said, nothing relaunched" || bad "lane a: rc=$RC row=$(lane_row sala-test-a) — $OUT"
run lane team sala-test-c --dry-run
[ "$RC" = 0 ] && has "$OUT" "revive --force --only sala-test-c" && ok "the control c's lane plan relaunches it" || bad "lane c dry: rc=$RC — $OUT"
run model sala-test-a sonnet --effort medium
[ "$RC" = 0 ] && has "$OUT" sleeping && has "$(model_row sala-test-a)" sonnet && ! hasclaude a && [ "$(n_starts 1)" = "$a0" ] && ok "sala model a sonnet: row written, 'sleeping' said, nothing relaunched" || bad "model a: rc=$RC row=$(model_row sala-test-a) — $OUT"
run lane
has "$OUT" "sleeping" && ok "the lane list says sleeping beside a" || bad "lane list: $OUT"

echo "== 7: adopt and box say 'sleeping' where they said 'no claude'; rename works with no claude"
run adopt sala-test-a
[ "$RC" != 0 ] && has "$OUT" sleeping && ! has "$OUT" "runs no claude" && ok "adopt a: refused as sleeping, not as 'no claude'" || bad "adopt a: rc=$RC — $OUT"
run box sala-test-a
[ "$RC" = 3 ] && has "$OUT" sleeping && ok "box a: exit 3, the sleeping message" || bad "box a: rc=$RC — $OUT"
run box sala-test-c
[ "$RC" = 3 ] && has "$OUT" "no claude in the pane" && ! has "$OUT" sleeping && ok "box c (control): exit 3, the old message" || bad "box c: rc=$RC — $OUT"
run rename sala-test-a sala-test-a2 --dry-run
[ "$RC" = 0 ] && has "$OUT" "sleeping" && has "$OUT" "nothing is typed" && ok "rename a --dry-run: sleeping, nothing typed" || bad "rename dry: rc=$RC — $OUT"
run rename sala-test-a sala-test-a2
[ "$RC" = 0 ] && $T has-session -t "=sala-test-a2" 2>/dev/null && [ "$(sidecar_uuid_for_session sala-test-a2)" = "$UA" ] && [ -z "$(row sala-test-a)" ] && ok "rename a → a2: tmux session and map row follow, same conversation" || bad "rename a: rc=$RC — $OUT"
is_sleeping sala-test-a2 && [[ $(<"$SALA_SLEEP_DIR/$UA") =~ Z\ sala-test-a2$ ]] && [ "$(lane_row sala-test-a2)" = subscription-2 ] && ok "still asleep under the new name, the marker's name text and the lane row followed" || bad "after rename: $(<"$SALA_SLEEP_DIR/$UA") lane=$(lane_row sala-test-a2)"
! hasclaude a2 && [ "$(n_starts 1)" = "$a0" ] && ok "and still no claude" || bad "a2 has a claude?"
run rename sala-test-a2 sala-test-a
[ "$RC" = 0 ] && is_sleeping sala-test-a && ok "renamed back" || bad "rename back: rc=$RC — $OUT"

echo "== 7: retire, close-shell, forget-row — no /exit, no live claude; the marker goes with the row"
printf '#!/bin/bash\necho %s\n' "'{\"items\":[]}'" > "$HOME/items-stub.sh"; export SALA_RETIRE_ITEMS_CMD="bash $HOME/items-stub.sh" SALA_RETIRE_ITEMS_TIMEOUT=3
run retire sala-test-a --dry-run
[ "$RC" = 0 ] && has "$OUT" sleeping && has "$OUT" "no /exit to type" && has "$OUT" "sleeping marker" && is_sleeping sala-test-a && ok "retire a --dry-run: sleeping, no /exit, would clear the marker; nothing changed" || bad "retire dry: rc=$RC — $OUT"
run retire sala-test-a --keep-web
[ "$RC" = 0 ] && ! $T has-session -t "=sala-test-a" 2>/dev/null && [ -z "$(row sala-test-a)" ] && [ ! -e "$SALA_SLEEP_DIR/$UA" ] && ok "retire a: the tmux session killed, the row gone, the marker gone" || bad "retire a: rc=$RC marker=$(ls "$SALA_SLEEP_DIR") — $OUT"
# b: a shell session with a row and a marker, closed with close-shell; f: a row and a marker with no tmux session, dropped with forget-row
$T send-keys -t sala-test-b 'echo' Enter
run close-shell sala-test-b --dry-run
[ "$RC" = 0 ] && has "$OUT" "marker would be cleared" && ok "close-shell b --dry-run: the marker is named" || bad "close-shell dry: rc=$RC — $OUT"
run close-shell sala-test-b
[ "$RC" = 0 ] && ! $T has-session -t "=sala-test-b" 2>/dev/null && [ -z "$(row sala-test-b)" ] && [ ! -e "$SALA_SLEEP_DIR/$UB" ] && ok "close-shell b: closed, row gone, marker gone" || bad "close-shell b: rc=$RC — $OUT"
UF=$(uuid 9); ledger_write add sala-test-f "$UF" sala-test-f "$HOME" >/dev/null 2>&1; sleeping_mark "$UF" sala-test-f
run forget-row sala-test-f --dry-run
[ "$RC" = 0 ] && has "$OUT" "marker would be cleared" && [ -n "$(row sala-test-f)" ] && ok "forget-row f --dry-run: the marker is named, nothing changed" || bad "forget dry: rc=$RC — $OUT"
run forget-row sala-test-f
[ "$RC" = 0 ] && [ -z "$(row sala-test-f)" ] && [ ! -e "$SALA_SLEEP_DIR/$UF" ] && ok "forget-row f: row gone, marker gone" || bad "forget-row f: rc=$RC — $OUT"
[ -z "$(ls -A "$SALA_SLEEP_DIR")" ] && ok "no marker is left for a retired session" || bad "markers: $(ls -A "$SALA_SLEEP_DIR")"

echo "== 8: sala op revive|restore --only NAME — 'sleeping', nothing queued, not refused as 'no claude'"
sleeping_mark "$UC" sala-test-c   # c is bare again (killed above): now it sleeps
rm -f "$OPS"/*.op 2>/dev/null
run op revive --only sala-test-c --from sala-test-d --words "test words"
[ "$RC" = 0 ] && has "$OUT" "sala-test-c: sleeping: its claude ended on purpose" && ! has "$OUT" "no claude" && [ -z "$(ls "$OPS"/*.op 2>/dev/null)" ] && ok "op revive c: said, exit 0, nothing queued" || bad "op revive c: rc=$RC queued=$(ls "$OPS" 2>/dev/null) — $OUT"
run op restore --only sala-test-c --from sala-test-d --words "test words"
[ "$RC" = 0 ] && has "$OUT" "its claude ended on purpose" && [ -z "$(ls "$OPS"/*.op 2>/dev/null)" ] && ok "op restore c: the same" || bad "op restore c: rc=$RC — $OUT"
run op revive --only sala-test-c --only sala-test-d --from sala-test-d --words "test words"
[ "$RC" != 0 ] && has "$OUT" "nothing queued" && [ -z "$(ls "$OPS"/*.op 2>/dev/null)" ] && ok "a sleeper and a live name together: nothing queued, the other named" || bad "op mixed: rc=$RC — $OUT"
sleeping_clear "$UC"
run op --plan revive --only sala-test-c --from sala-test-d --words "test words"
has "$OUT" "plan: salamander revive" && ! has "$OUT" "its claude ended on purpose" && ok "the control c (no marker): the plan is the plan it was" || bad "op plan c: rc=$RC — $OUT"

echo "== 9: the wrap-up tick lists no pane with no claude"
sleeping_mark "$UC" sala-test-c
out=$(SALA_IDLE_WRAPUP=on "$SALA" watch --wrapup --dry-run 2>&1)
! has "$out" sala-test-c && ok "watch --wrapup --dry-run says nothing of the sleeping pane c" || bad "wrapup dry: $out"
sleeping_clear "$UC"

echo "== sleep_ready: an idle, free pane may sleep"
stoprec 6; stoprec 8
sp=$(sleep_ready sala-test-s); rc=$?
[ "$rc" = 0 ] && [ -z "$sp" ] && ok "s: idle over an hour, nothing holds it: ready, no text" || bad "s: rc=$rc '$sp' ($SLEEP_WHY)"
why() { sleep_ready "$1" 2>&1 | head -1; }   # <session> → the refusing reason
expect() {  # <label> <session> <text of the reason> → ok when sleep_ready refuses with that text in its reason
    local r; r=$(why "$2"); [ "$(sleep_ready "$2" >/dev/null 2>&1; echo $?)" = 1 ] && has "$r" "$3" && ok "refused: $1 ($r)" || bad "$1: expected '$3', got '$r'"
}
expect "no such session" sala-test-nosuch "no tmux session"
sleeping_mark "$(uuid 6)" sala-test-s; expect "already asleep" sala-test-s "already asleep"; sleeping_clear "$(uuid 6)"
r=$(SALA_RC_SESSION=sala-test-s why sala-test-s); has "$r" "Remote Control" && ok "refused: the Remote Control session ($r)" || bad "rc: $r"
r=$(SALA_NO_RELAUNCH=sala-test-s why sala-test-s); has "$r" "SALA_NO_RELAUNCH" && ok "refused: managed outside sala ($r)" || bad "no_relaunch: $r"
mkdir -p "$SALA_SIDE_DIR"; echo "kind=fork" > "$(side_file sala-test-s)"; expect "a side session" sala-test-s "side session"; rm -f "$(side_file sala-test-s)"
expect "not in the pane map" sala-test-t "not in the pane map"
expect "no claude in its pane" sala-test-c "no claude"
mk x 10 -e FAKE_IDLE_AGE=4000 -e CLAUDE_CODE_ENTRYPOINT=sdk-py; fake_up sala-test-x && "$SALA" adopt sala-test-x >/dev/null 2>&1
expect "the sdk lane" sala-test-x "sdk lane"
$T new-session -d -s sala-test-y -c "$HOME" -e FAKE_SESSION_ID="$(uuid 11)" -e FAKE_NAME=sala-test-y -e FAKE_LOG="$FAKE_LOG" -e FAKE_STARTED_AT="$START" -e FAKE_IDLE_AGE=4000
$T send-keys -t sala-test-y 'claude --sdk-url http://127.0.0.1:9/x' Enter; fake_up sala-test-y && ledger_write add sala-test-y "$(uuid 11)" sala-test-y "$HOME" >/dev/null 2>&1
expect "a Remote Control served session (its claude runs with --sdk-url)" sala-test-y "Remote Control served"
sp=$(cpid s)
reg_swap() { local f="$HOME/.claude/sessions/$1.json" t; t=$(slurp "$f"); printf '%s' "${t//$2/$3}" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"; }   # <pid> <from> <to> → that registry row with the text swapped
reg_swap "$sp" '"sessionId"' '"sessionIx"'; expect "no conversation id in its registry row" sala-test-s "no conversation id"; reg_swap "$sp" '"sessionIx"' '"sessionId"'
reg_swap "$sp" '"statusUpdatedAt"' '"statusUpdatedAx"'; expect "no idle time in its registry row" sala-test-s "no idle time"; reg_swap "$sp" '"statusUpdatedAx"' '"statusUpdatedAt"'
set_reg_stamp "$sp" $((now0 - 600)); expect "idle for too short a time" sala-test-s "idle for"; set_reg_stamp "$sp" $((now0 - 4000))
set_reg_status "$sp" busy; expect "a busy registry row (wrap_ready's own check)" sala-test-s "registry says"; set_reg_status "$sp" idle
$T send-keys -t "=sala-test-u:" -l 'half typed words'; waitfor '[ -n "$(pane_draft "$($T list-panes -t =sala-test-u -F "#{pane_id}" | head -1)" "$(cpid u)")" ]' 40
expect "text typed in the input box (wrap_ready's own check)" sala-test-u "typed"
stoprec 6 "$TURN" 1; expect "a scheduled job from its last turn" sala-test-s "scheduled job"; stoprec 6
mkdir -p "$OPS"; printf 'verb=revive\narg=--only\narg=sala-test-s\nstate=queued\n' > "$OPS/1-1.op"; expect "a queued operation naming it" sala-test-s "operation 1-1 (queued)"
printf 'verb=revive\narg=--only\narg=sala-test-s\nstate=done\n' > "$OPS/1-1.op"; sp2=$(why sala-test-s); [ -z "$sp2" ] && ok "a finished operation does not hold it" || bad "done op: $sp2"; rm -f "$OPS/1-1.op"
printf 'n1\tsala-test-s\t%s\t%s\t0\t0\t0\twrite the report\n' "$(uuid 6)" "$now0" > "$SALA_LOG_DIR/salamander-notes.tsv"; expect "a note waiting" sala-test-s "note"; : > "$SALA_LOG_DIR/salamander-notes.tsv"
printf 'sala-test-s\t%s\tbackground work\t0\t0\t-\n' "$now0" > "$SALA_DEFERRED"; expect "on the deferred list" sala-test-s "deferred list"; : > "$SALA_DEFERRED"
SX="$((now0 - 5))-1"; set_create "$SX" Recycle recycle 1 0 9.9.9 1 out=sala-test-s; expect "an open recycle set" sala-test-s "open relaunch set"; rm -f "$SALA_SET_DIR/$SX"
waiting_raise "$(uuid 6)" reboot reboot-1 $$; expect "the relaunch-waiting flag" sala-test-s "relaunch flag"; waiting_clear "$(uuid 6)"
export SALA_STACKSHOT_INBOX="$HOME/inbox"; r=$(why sala-test-s); [ -z "$r" ] && ok "a missing stackshot inbox directory is no refusal" || bad "no inbox dir: $r"
mkdir -p "$SALA_STACKSHOT_INBOX/hub"; printf '{"to":"sala-test-s","text":"hello"}\n' > "$SALA_STACKSHOT_INBOX/hub/m1.json"; expect "a stackshot inbox message" sala-test-s "stackshot hub message"; rm -f "$SALA_STACKSHOT_INBOX/hub/m1.json"
# the routing fields are matched exactly: a line for a longer name or one whose text only mentions the session does not refuse it; a line routed by name or by conversation id does
mkdir -p "$SALA_STACKSHOT_INBOX/hub" "$SALA_STACKSHOT_INBOX/msg"
printf '{"id":"x1","src":"msg","to":"sala-test-s-extra","uuid":"","name":"sala-test-s-extra","pid":"","text":"for the longer name","from":"x"}\n' > "$SALA_STACKSHOT_INBOX/msg/x1.json"
printf '{"id":"x2","src":"hub","to":"somebody-else","uuid":"","name":"somebody-else","pid":"","text":"mentions sala-test-s and %s only in its text","from":"x"}\n' "$(uuid 6)" > "$SALA_STACKSHOT_INBOX/hub/x2.json"
r=$(why sala-test-s); [ -z "$r" ] && ok "a line for sala-test-s-extra and a text that only mentions the session's name and id do not refuse it" || bad "mention-only lines refused it: $r"
printf '{"id":"x3","src":"msg","to":"sala-test-s","uuid":"","name":"sala-test-s","pid":"","text":"for s","from":"x"}\n' > "$SALA_STACKSHOT_INBOX/msg/x3.json"; expect "a stackshot msg line routed to its name" sala-test-s "stackshot msg message"; rm -f "$SALA_STACKSHOT_INBOX/msg/x3.json"
printf '{"id":"x4","src":"hub","to":"somebody-else","uuid":"%s","name":"somebody-else","pid":"","text":"for the conversation","from":"x"}\n' "$(uuid 6)" > "$SALA_STACKSHOT_INBOX/hub/x4.json"; expect "a stackshot hub line routed to its conversation id" sala-test-s "stackshot hub message"; rm -f "$SALA_STACKSHOT_INBOX/hub/x4.json"
rm -f "$SALA_STACKSHOT_INBOX/msg/x1.json" "$SALA_STACKSHOT_INBOX/hub/x2.json"
# on a box that is not stackshot's server (SALA_INBOX_MODE=server, lib/inboxhold.py) the server answers the question: a line waiting there refuses the sleep, nothing waiting allows it,
# and a server that cannot be asked refuses it too (no answer is never "nothing waits"); the local folder is not looked into. tests/inboxserver.sh has the whole matrix.
rm -f "$SALA_STACKSHOT_INBOX"/hub/*.json "$SALA_STACKSHOT_INBOX"/msg/*.json
export FAKE_INBOX_DIR="$HOME/fakeinbox" SALA_INBOX_MODE=server SALA_STACKSHOT_CLIENT="$ROOT/tests/fake-inbox-client.py" SALA_INBOX_TIMEOUT=2 SALA_INBOX_BREAKER=0
mkdir -p "$FAKE_INBOX_DIR/inbox/hub" "$FAKE_INBOX_DIR/inbox/msg"
r=$(why sala-test-s); [ -z "$r" ] && ok "server mode, nothing waits on the stackshot server: no refusal" || bad "server nothing waits: $r"
printf '{"to":"sala-test-s","text":"hello"}\n' > "$FAKE_INBOX_DIR/inbox/msg/m1.json"; expect "a message waiting on the stackshot server" sala-test-s "stackshot msg message"
printf '{"to":"sala-test-s","text":"hello"}\n' > "$SALA_STACKSHOT_INBOX/hub/m1.json"; rm -f "$FAKE_INBOX_DIR/inbox/msg/m1.json"
r=$(why sala-test-s); [ -z "$r" ] && ok "a line in the local inbox folder is not looked at in server mode" || bad "server mode read the local folder: $r"
rm -f "$SALA_STACKSHOT_INBOX/hub/m1.json"
for how in down e500 hang garbage; do
    export FAKE_INBOX_FAIL=waiting FAKE_INBOX_HOW=$how SALA_INBOX_TIMEOUT=1
    expect "a stackshot server that cannot be asked ($how) refuses the sleep" sala-test-s "could not be asked"
done
unset FAKE_INBOX_FAIL FAKE_INBOX_HOW SALA_STACKSHOT_CLIENT; export SALA_INBOX_MODE=files; rm -rf "$FAKE_INBOX_DIR"; unset FAKE_INBOX_DIR SALA_INBOX_TIMEOUT
: > "$HOME/t_limit"; expect "stopped on a usage limit" sala-test-s "usage limit"; rm -f "$HOME/t_limit"
: > "$HOME/t_net"; expect "stopped on a network error" sala-test-s "network"; rm -f "$HOME/t_net"
_key_r k sala-test-s; printf 's.%s.hash=abc123\n' "$k" > "$SALA_STATE_DIR/stuck.state"; expect "a question open on its screen" sala-test-s "question"; rm -f "$SALA_STATE_DIR/stuck.state"
sp=$(sleep_ready sala-test-s); [ -z "$sp" ] && ok "every flag cleared: s is ready again" || bad "s after the cases: $sp"
SALA_SLEEP_AFTER=100000 expect "idle shorter than SALA_SLEEP_AFTER" sala-test-s "idle for"

[ "$fail" = 0 ] && echo "sleeping: pass" || echo "sleeping: FAIL"
exit $fail
