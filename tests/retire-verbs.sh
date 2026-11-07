#!/usr/bin/env bash
# The three verbs `sala retire` was split into, and the guardrails each carries (lib/retire.sh, lib/close-shell.sh, lib/forget-row.sh, lib/op.sh).
#   retire <tmux-session>   a Claude session, by the exact tmux name (or --id <conversation id>, which tests/retire.sh covers)
#   close-shell <session>   a session with no Claude in it
#   forget-row <name>       a pane-map row whose tmux session is gone
# Checked here:
#   - every refusal points at the verb that does the job: a shell session → close-shell, an orphan row → forget-row, a live session or a Claude in it →
#     retire / close-shell; an unknown name → --id; the old --force refused by all three, and by the queue, with a sentence naming --busy and --skip-writeup;
#   - the bypasses each lift only their own check: --busy the idle check (not the side-session write-up gate, not the open-items check), --skip-writeup the
#     write-up gate (not the idle check), --leave-items the open-items check (not the idle check); --busy of close-shell lifts only the running-children check;
#   - the open-items check against a stackshot stub that answers with items (a mover's, a needs-only and a held one are not counted), none, a failure, a hang
#     and an answer that is not the list, and with no client at all: refused with the ids or the reason, --leave-items goes past it, a dry run asks too,
#     the key is the tmux name and the conversation id;
#   - self-retire: refused without --self (placed by process ancestry through a trusted claude, never by TMUX_PANE alone); with --self done, no /exit typed
#     into its own pane, the tail of the output in the retire log; --self from another session changes nothing;
#   - close-shell: dry run and real (kill, row, lane and model rows, snapshot), the refusals (a Claude pane, the master, the RC session, the caller's own
#     session, a prefix, a session still running something), the exact name;
#   - forget-row: dry run and real (the row, lane and model rows), refusals (a live session either kind, no row, the master, the RC name);
#   - the queue (`sala op`): close-shell and forget-row are verbs with the same words rules, their plans are the dry runs, the new flags reach the marker.
# Isolated HOME, a private tmux socket (sala-retverbs-<pid>), the compiled fake claude (tests/fake-claude.c), a stackshot stub (a script); nothing real is
# touched. Every file, session and process it made is removed at the end, pass or fail.
# Usage: bash tests/retire-verbs.sh   (exit 0 = pass; ~90 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SESSION_ID SALA_MASTER SALA_SET SALA_SET_SELF SALA_RECYCLE SALA_RETRY_WORKER SALA_LOCK_WHO SALA_LOCK_WAIT \
      SALA_RELAUNCH_KIND SALA_FLEET_HOSTS SALA_CGROUP_FILE SALA_OP_QUEUE SALA_OP_REBOOT SALA_OP_STUCK SALA_REBOOT_HOOKS SALA_NO_RELAUNCH \
      SALA_STACKSHOT_DIR SALA_STACKSHOT_CLIENT SALA_AGENT_CHECK_SCRIPT SALA_PROJECT_RECORD
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, fake_up, tmux_socket_rm, as_op_unit
SANDBOX=""; SOCK="sala-retverbs-$$"; T="tmux -L $SOCK -f /dev/null"
cleanup() {
    local e p
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    if [ -n "$SANDBOX" ]; then
        for e in /proc/[0-9]*/exe; do   # only our own fakes and drivers, found by their exe (never by name)
            [ "$e" -ef "$SANDBOX/.local/share/claude/versions/2.1.0-test" ] || [ "$e" -ef "$SANDBOX/.local/share/claude/versions/drv-bash" ] || continue
            p=${e#/proc/}; kill -9 "${p%/exe}" 2>/dev/null
        done
        exec 8<&-; rm -rf "$SANDBOX" 2>/dev/null
    fi; true
}; trap cleanup EXIT   # set before the temp folder exists
SANDBOX=$(mktemp -d); export HOME=$SANDBOX; export SALA_CONFIG=/dev/null
exec 8< "$SANDBOX"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
as_op_unit   # the guarded verbs this suite runs itself stand for the queue's runner (tests/lib.sh, 5)
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOME/work" "$HOME/.local/share/claude/versions"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
# the fake claude lives where a real install does (the caller check trusts a claude by its exe path, common.sh claude_exe_trusted)
cc -o "$HOME/.local/share/claude/versions/2.1.0-test" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -sf "$HOME/.local/share/claude/versions/2.1.0-test" "$HOME/.local/bin/claude"
export PATH="$HOME/.local/bin:$PATH"; export FAKE_LOG="$HOME/fake.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="cat >> $POSTS"   # no post leaves the box
export SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_SNAPSHOT_CMD="touch $HOME/snap.done"
export SALA_OP_STUCK=off SALA_OP_QUEUE=off   # a queued marker is written and nothing starts it
SALA="$ROOT/bin/salamander"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's
. "$ROOT/lib/common.sh"; MAP="$SALA_SIDECAR"
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux   # literal socket: the children run set -u
tmux new-session -d -s sala-test-anchor -c "$HOME/work"   # a plain shell that outlives every case
OPS="$SALA_STATE_DIR/ops"
row() { awk -F'\t' -v s="$1" '$1==s' "$MAP" 2>/dev/null; }
pane_claude() { claude_pid_under "$(tmux display -p -t "=$1:" '#{pane_pid}' 2>/dev/null)"; }   # <session> → its claude's pid
hand() {  # <session> <uuid> [env=val…] — a session with a fake claude in it, registered under its own name
    local s="$1" u="$2"; shift 2; local e=(); local kv; for kv in "$@"; do e+=(-e "$kv"); done
    tmux new-session -d -s "$s" -c "$HOME/work" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="$s" -e FAKE_LOG="$FAKE_LOG" ${e[@]+"${e[@]}"}; tmux send-keys -t "=$s:" 'claude' Enter
    waitfor "reg_live '\"sessionId\":\"$u\"'" 40 || echo "  (fake claude in $s did not come up)"; }
shell() { tmux new-session -d -s "$1" -c "$HOME/work"; }   # <session> → a plain shell session, no claude
gone() { ! tmux has-session -t "=$1" 2>/dev/null; }
state() {  # everything the verbs touch: the map and its logs, the lane and model tables, every pane, the registry files, the snapshot marker, the fake's events
    local f; for f in "$MAP" "$SALA_LEDGER_LOG" "$SALA_LANES" "$SALA_MODELS" "$FAKE_LOG"; do echo "== $f"; cat "$f" 2>/dev/null; done
    tmux list-panes -a -F '#{session_name} #{pane_id} #{pane_pid} #{pane_current_command}' 2>/dev/null; ls "$HOME/.claude/sessions" 2>/dev/null; ls "$HOME/snap.done" 2>/dev/null; }
untouched() {  # <state before> <label>
    [ "$(state)" = "$1" ] && ok "$2: nothing touched" || bad "$2: something changed — $(diff <(echo "$1") <(state) | head -12)"; }
queued() { ls "$OPS"/*.op 2>/dev/null | wc -l; }
dropall() { local f; for f in "$OPS"/*.op; do [ -e "$f" ] && rm -f "$f"; done; true; }
mval() { local f="$OPS/$1.op"; awk -F= -v k="$2" '$1==k {print substr($0, length(k)+2); exit}' "$f" 2>/dev/null; }
margs() { local f="$OPS/$1.op"; awk -F= '$1=="arg" {print substr($0, 5)}' "$f" 2>/dev/null | paste -sd' ' -; }   # <id> → the marker's argv, one line
run() {  # <argv…> → OUT, RC of a sala call (stderr in OUT)
    OUT=$("$SALA" "$@" 2>&1); RC=$?; }

# the stackshot stub: `get items <key>` answers by $HOME/items.mode; every key it is asked is noted in $HOME/items.keys
cat > "$HOME/items-stub.sh" <<'EOF'
#!/bin/bash
# the retire items check's client stub (SALA_RETIRE_ITEMS_CMD): the key is $1; the mode file says what stackshot would answer
echo "$1" >> "$HOME/items.keys"
case "$(cat "$HOME/items.mode" 2>/dev/null)" in
    items) echo '{"items":[{"shown":"board#9007","roles":["mover"],"held":false},{"shown":"board#9008","roles":["needs"],"held":false},{"shown":"board#9009","roles":["mover"],"held":true},{"shown":"board#11","roles":["then","mover"],"held":false}]}' ;;
    needs) echo '{"items":[{"shown":"board#9008","roles":["needs"],"held":false},{"shown":"board#9009","roles":["mover"],"held":true}]}' ;;
    none) echo '{"items":[]}' ;;
    down) echo "stackshot: connection refused" >&2; exit 3 ;;
    hang) sleep 30 ;;
    garbage) echo "<html>502 Bad Gateway</html>" ;;
esac
EOF
chmod +x "$HOME/items-stub.sh"
export SALA_RETIRE_ITEMS_CMD="bash $HOME/items-stub.sh"; export SALA_RETIRE_ITEMS_TIMEOUT=3
mode() { echo "$1" > "$HOME/items.mode"; : > "$HOME/items.keys"; }
mode none
U1=0b000001-0000-4000-8000-000000000001; U2=0b000002-0000-4000-8000-000000000002; U3=0b000003-0000-4000-8000-000000000003
U4=0b000004-0000-4000-8000-000000000004; U5=0b000005-0000-4000-8000-000000000005; U6=0b000006-0000-4000-8000-000000000006
U7=0b000007-0000-4000-8000-000000000007; U8=0b000008-0000-4000-8000-000000000008; UH=0b000009-0000-4000-8000-000000000009
UO=0b00000a-0000-4000-8000-00000000000a; UL=0b00000b-0000-4000-8000-00000000000b; UQ=0b00000c-0000-4000-8000-00000000000c; U9=0b00000d-0000-4000-8000-00000000000d; UQI=0b00000e-0000-4000-8000-00000000000e
FORCEMSG="--force is gone"

echo "== --force is gone from all three verbs: refused with a sentence naming --busy and --skip-writeup; nothing touched"
hand sala-test-f1 "$U1"; s0=$(state)
run retire sala-test-f1 --force
[ "$RC" != 0 ] && has "$OUT" "$FORCEMSG" && has "$OUT" "--busy" && has "$OUT" "--skip-writeup" && ok "retire --force: refused, --busy and --skip-writeup named" || bad "retire --force: rc=$RC — $OUT"
run retire sala-test-f1 --keep-web --force --dry-run
[ "$RC" != 0 ] && has "$OUT" "$FORCEMSG" && ok "retire --force --dry-run: refused too" || bad "retire --force --dry-run: rc=$RC — $OUT"
run close-shell sala-test-anchor --force
[ "$RC" != 0 ] && has "$OUT" "no --force" && has "$OUT" "--busy" && ok "close-shell --force: refused, --busy named" || bad "close-shell --force: rc=$RC — $OUT"
run forget-row sala-test-f1 --force
[ "$RC" != 0 ] && has "$OUT" "no --force" && ok "forget-row --force: refused" || bad "forget-row --force: rc=$RC — $OUT"
untouched "$s0" "the --force refusals"
tmux kill-session -t =sala-test-f1

echo "== each refusal points at the verb that does the job"
shell sala-test-sh1; hand sala-test-c1 "$U2"; "$SALA" adopt sala-test-c1 >/dev/null 2>&1
ledger_write add sala-test-orph "$UO" sala-test-orph "$HOME/work" >/dev/null 2>&1; printf 'sala-test-orph\tapi\n' >> "$SALA_LANES"; printf 'sala-test-orph\topus\thigh\n' >> "$SALA_MODELS"
s0=$(state)
for fl in "" --dry-run; do
    run retire sala-test-sh1 $fl
    [ "$RC" != 0 ] && has "$OUT" "runs no Claude session" && has "$OUT" "sala close-shell sala-test-sh1" && ok "retire <a shell session> $fl: refused, close-shell named" || bad "retire shell $fl: rc=$RC — $OUT"
    run retire sala-test-orph $fl
    [ "$RC" != 0 ] && has "$OUT" "no tmux session 'sala-test-orph'" && has "$OUT" "sala forget-row sala-test-orph" && ok "retire <an orphan row> $fl: refused, forget-row named" || bad "retire orphan $fl: rc=$RC — $OUT"
    run retire sala-test-nosuch $fl
    [ "$RC" != 0 ] && has "$OUT" "no tmux session 'sala-test-nosuch'" && has "$OUT" "sala retire --id <conversation-id>" && ok "retire <unknown name> $fl: refused, --id named" || bad "retire unknown $fl: rc=$RC — $OUT"
    run close-shell sala-test-c1 $fl
    [ "$RC" != 0 ] && has "$OUT" "runs a Claude session" && has "$OUT" "sala retire sala-test-c1" && ok "close-shell <a Claude session> $fl: refused, retire named" || bad "close-shell claude $fl: rc=$RC — $OUT"
    run close-shell sala-test-orph $fl
    [ "$RC" != 0 ] && has "$OUT" "sala forget-row sala-test-orph" && ok "close-shell <an orphan row> $fl: refused, forget-row named" || bad "close-shell orphan $fl: rc=$RC — $OUT"
    run close-shell sala-test-nosuch $fl
    [ "$RC" != 0 ] && has "$OUT" "no tmux session 'sala-test-nosuch'" && ok "close-shell <unknown name> $fl: refused" || bad "close-shell unknown $fl: rc=$RC — $OUT"
    run forget-row sala-test-c1 $fl
    [ "$RC" != 0 ] && has "$OUT" "sala retire sala-test-c1" && ok "forget-row <a Claude session> $fl: refused, retire named" || bad "forget-row claude $fl: rc=$RC — $OUT"
    run forget-row sala-test-sh1 $fl
    [ "$RC" != 0 ] && has "$OUT" "sala close-shell sala-test-sh1" && ok "forget-row <a shell session> $fl: refused, close-shell named" || bad "forget-row shell $fl: rc=$RC — $OUT"
    run forget-row sala-test-nosuch $fl
    [ "$RC" != 0 ] && has "$OUT" "no pane-map row" && ok "forget-row <no row> $fl: refused" || bad "forget-row unknown $fl: rc=$RC — $OUT"
done
untouched "$s0" "every refusal, real and dry"
run retire sala-test-c1 --dry-run
[ "$RC" = 0 ] && has "$OUT" "[dry-run] would kill tmux session 'sala-test-c1'" && ok "the Claude session's own dry run goes through (the control)" || bad "control dry run: rc=$RC — $OUT"
untouched "$s0" "retire sala-test-c1 --dry-run"

echo "== exact names only: a prefix, a registry name and a number are no session"
run retire sala-test-c --dry-run
[ "$RC" != 0 ] && has "$OUT" "no tmux session 'sala-test-c'" && ! has "$OUT" "sala-test-c1" && ok "retire <a prefix of a session>: refused, the session not named" || bad "retire prefix: rc=$RC — $OUT"
run close-shell sala-test-sh --dry-run
[ "$RC" != 0 ] && has "$OUT" "no tmux session 'sala-test-sh'" && ! has "$OUT" "sala-test-sh1" && ok "close-shell <a prefix of a session>: refused" || bad "close-shell prefix: rc=$RC — $OUT"
untouched "$s0" "the prefix refusals"

echo "== --busy lifts only the idle check; --skip-writeup only the write-up gate; neither lifts the other"
c=$(pane_claude sala-test-c1); set_reg_status "$c" busy; s0=$(state)
run retire sala-test-c1 --dry-run
[ "$RC" != 0 ] && has "$OUT" "is not idle" && has "$OUT" "--busy" && ok "a busy session: the dry run says it would refuse, --busy named" || bad "busy dry: rc=$RC — $OUT"
run retire sala-test-c1 --skip-writeup --dry-run
[ "$RC" != 0 ] && has "$OUT" "is not idle" && ok "--skip-writeup does not lift the idle check" || bad "busy + skip-writeup: rc=$RC — $OUT"
run retire sala-test-c1 --leave-items
[ "$RC" != 0 ] && has "$OUT" "is not idle" && ok "--leave-items does not lift the idle check" || bad "busy + leave-items: rc=$RC — $OUT"
untouched "$s0" "the busy refusals"
run retire sala-test-c1 --busy --dry-run
[ "$RC" = 0 ] && has "$OUT" "while it is not idle" && ok "--busy: the dry run says it would retire the busy session" || bad "busy + busy dry: rc=$RC — $OUT"
# the side-session gate: a side record with no marker, an idle session
hand sala-test-sd1 "$U3"; mkdir -p "$SALA_SIDE_DIR"; printf 'project=projects/foo\nitem=board#12\n' > "$(side_file sala-test-sd1)"; s1=$(state)
run retire sala-test-sd1 --busy --dry-run
[ "$RC" != 0 ] && has "$OUT" "is a side session and its write-up is not done" && has "$OUT" "--skip-writeup" && ok "--busy does not lift the write-up gate" || bad "side + busy: rc=$RC — $OUT"
run retire sala-test-sd1 --leave-items
[ "$RC" != 0 ] && has "$OUT" "write-up is not done" && ok "--leave-items does not lift the write-up gate" || bad "side + leave-items: rc=$RC — $OUT"
untouched "$s1" "the write-up refusals"
run retire sala-test-sd1 --skip-writeup --keep-web
[ "$RC" = 0 ] && has "$OUT" "without its write-up marker (--skip-writeup)" && gone sala-test-sd1 && ok "--skip-writeup: said, and the idle side session retired" || bad "side + skip-writeup: rc=$RC — $OUT"
# the busy session with --busy, for real
run retire sala-test-c1 --busy --keep-web
[ "$RC" = 0 ] && has "$OUT" "while it is not idle" && has "$OUT" "retired 'sala-test-c1'" && gone sala-test-c1 && [ -z "$(row sala-test-c1)" ] && ok "--busy for real: the busy session retired, its row gone" || bad "busy retire: rc=$RC — $OUT"

echo "== the open-items check against a stackshot stub: items, none, down, a hang, garbage, no client"
hand sala-test-i1 "$UH"; s0=$(state)
mode items
run retire sala-test-i1 --keep-web
[ "$RC" != 0 ] && has "$OUT" "mover of open board items: board#9007, board#11" && ! has "$OUT" "board#9008" && ! has "$OUT" "board#9009" && has "$OUT" "--leave-items" && ok "items: refused, the mover's ids listed (a needs-only and a held item are not counted), --leave-items named" || bad "items: rc=$RC — $OUT"
[ "$(grep -c . "$HOME/items.keys")" = 2 ] && [ "$(sed -n 1p "$HOME/items.keys")" = sala-test-i1 ] && [ "$(sed -n 2p "$HOME/items.keys")" = "$UH" ] && ok "stackshot was asked by the tmux name and by the conversation id" || bad "keys asked: $(paste -sd' ' "$HOME/items.keys")"
untouched "$s0" "retire with items"
run retire sala-test-i1 --dry-run
[ "$RC" != 0 ] && has "$OUT" "[dry-run] would refuse: 'sala-test-i1' is the mover of open board items" && ok "the dry run asks too, and says it would refuse" || bad "items dry: rc=$RC — $OUT"
untouched "$s0" "retire with items --dry-run"
run retire sala-test-i1 --busy --skip-writeup --dry-run
[ "$RC" != 0 ] && has "$OUT" "mover of open board items" && ok "--busy and --skip-writeup do not lift the items check" || bad "items + busy + skip-writeup: rc=$RC — $OUT"
mode needs
run retire sala-test-i1 --dry-run
[ "$RC" = 0 ] && ok "only a needs-only and a held item: not the session's to hand over, the dry run goes through" || bad "needs: rc=$RC — $OUT"
mode down
run retire sala-test-i1 --keep-web
[ "$RC" != 0 ] && has "$OUT" "stackshot could not be asked whether 'sala-test-i1' moves open board items" && has "$OUT" "connection refused" && has "$OUT" "--leave-items" && ok "stackshot down: refused with its reason, --leave-items named" || bad "down: rc=$RC — $OUT"
mode hang
run retire sala-test-i1 --keep-web
[ "$RC" != 0 ] && has "$OUT" "did not answer within 3 s" && ok "stackshot hangs: refused after the timeout, said" || bad "hang: rc=$RC — $OUT"
mode garbage
run retire sala-test-i1 --keep-web
[ "$RC" != 0 ] && has "$OUT" "is not the open-items list" && ok "an answer that is not the list: refused, said" || bad "garbage: rc=$RC — $OUT"
SAVE_CMD=$SALA_RETIRE_ITEMS_CMD; export SALA_RETIRE_ITEMS_CMD=""
run retire sala-test-i1 --keep-web
[ "$RC" != 0 ] && has "$OUT" "no stackshot client.py on this box" && has "$OUT" "--leave-items" && ok "no client on the box: refused with that reason" || bad "no client: rc=$RC — $OUT"
untouched "$s0" "the unreachable-stackshot refusals"
mode items; export SALA_RETIRE_ITEMS_CMD=$SAVE_CMD
run retire sala-test-i1 --leave-items --dry-run
[ "$RC" = 0 ] && has "$OUT" "--leave-items: would not ask stackshot" && ok "--leave-items --dry-run: goes past the check, says so" || bad "leave-items dry: rc=$RC — $OUT"
: > "$HOME/items.keys"
run retire sala-test-i1 --leave-items --keep-web
[ "$RC" = 0 ] && has "$OUT" "without asking whether it moves open board items (--leave-items)" && has "$OUT" "retired 'sala-test-i1'" && gone sala-test-i1 && [ ! -s "$HOME/items.keys" ] && ok "--leave-items: said, stackshot not asked, the session retired" || bad "leave-items: rc=$RC — $OUT"
mode down; export SALA_RETIRE_ITEMS_CMD=""
hand sala-test-i2 "$U4"
run retire sala-test-i2 --leave-items --keep-web
[ "$RC" = 0 ] && gone sala-test-i2 && ok "--leave-items also goes past an unreachable stackshot" || bad "leave-items + down: rc=$RC — $OUT"
export SALA_RETIRE_ITEMS_CMD=$SAVE_CMD; mode none
hand sala-test-i3 "$U5"
run retire sala-test-i3 --keep-web
[ "$RC" = 0 ] && gone sala-test-i3 && ok "no items: retired (the control)" || bad "none: rc=$RC — $OUT"

echo "== retire --id keeps the registry resolution and the same guardrails"
hand sala-test-d1 "$U6"; mode items; s0=$(state)
run retire --id "$U6" --keep-web
[ "$RC" != 0 ] && has "$OUT" "'$U6' → CLI registry" && has "$OUT" "mover of open board items" && ok "--id: resolved, said, then the items check refuses (the name resolved is the tmux session's)" || bad "id + items: rc=$RC — $OUT"
untouched "$s0" "retire --id with items"
mode none
run retire --id "$U6" --keep-web
[ "$RC" = 0 ] && has "$OUT" "retired 'sala-test-d1' (named as '$U6')" && gone sala-test-d1 && ok "--id with no items: retired" || bad "id: rc=$RC — $OUT"

echo "== the caller's own session: refused without --self; with --self done, no /exit typed into the pane"
# a Claude session's call is a child of a process named claude whose exe is under the install folder (common.sh claude_exe_trusted): a driver script in a window
cat > "$HOME/drv-claude" <<'EOF'
#!/bin/bash
# the argument is the folder of command files (<id>.cmd = one command line); each runs as a CHILD of this process, never exec'd
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
mkdir -p "$HOME/drv"; cp "$(command -v bash)" "$HOME/.local/share/claude/versions/drv-bash"; ln -sf "$HOME/.local/share/claude/versions/drv-bash" "$HOME/drv/claude"
driver_up() {  # <session> → a driver window in that tmux session
    mkdir -p "$HOME/drv-calls/$1"; tmux new-window -d -t "=$1:" "$HOME/drv/claude $HOME/drv-claude $HOME/drv-calls/$1"; }
callin() {  # <session> <argv…> → OUT, RC of that command run as a child of the session's driver (a call from inside that pane)
    local s=$1 id f; shift; id=$(date +%s%N)-$RANDOM; f="$HOME/drv-calls/$s/$id"
    printf '%q ' "$@" > "$f.tmp"; echo >> "$f.tmp"; mv "$f.tmp" "$f.cmd"
    waitfor "[ -e '$f.rc' ]" 300 || { OUT="(the driver in $s did not answer)"; RC=99; return; }
    OUT=$(<"$f.out"); RC=$(<"$f.rc"); rm -f "$f.out" "$f.rc"
}
hand sala-test-me "$U7"; hand sala-test-you "$U8"; driver_up sala-test-me; driver_up sala-test-you; mkdir -p "$SALA_LOG_DIR"
callin sala-test-me bash -c 'echo up'; [ "$RC" = 0 ] && [ "$OUT" = up ] || { bad "the driver in sala-test-me did not answer: rc=$RC $OUT"; }
s0=$(state)
callin sala-test-me "$SALA" retire sala-test-me --dry-run
[ "$RC" != 0 ] && has "$OUT" "[dry-run] would refuse: 'sala-test-me' is the session this command runs in" && has "$OUT" "--self" && ok "own session, --dry-run: it would refuse, --self named" || bad "self dry: rc=$RC — $OUT"
callin sala-test-me "$SALA" retire sala-test-me --keep-web
[ "$RC" != 0 ] && has "$OUT" "is the session this command runs in" && has "$OUT" "sala op retire sala-test-me --self" && tmux has-session -t =sala-test-me 2>/dev/null && ok "own session, real: refused, the queue's form named, the session still there" || bad "self real: rc=$RC — $OUT"
callin sala-test-me env TMUX_PANE="$(tmux display -p -t =sala-test-you: '#{pane_id}')" "$SALA" retire sala-test-me --dry-run
[ "$RC" != 0 ] && has "$OUT" "is the session this command runs in" && ok "TMUX_PANE naming another pane does not hide the caller (placed by ancestry)" || bad "self, spoofed pane: rc=$RC — $OUT"
callin sala-test-me "$SALA" retire sala-test-you --dry-run
[ "$RC" = 0 ] && has "$OUT" "would kill tmux session 'sala-test-you'" && ok "another session: not refused as the caller's (the control)" || bad "other from me: rc=$RC — $OUT"
callin sala-test-me "$SALA" retire sala-test-you --self --dry-run
[ "$RC" = 0 ] && has "$OUT" "--self given, but 'sala-test-you' is not the session this command runs in ('sala-test-me' is): it changes nothing" && ok "--self naming another session: said, changes nothing, the retire is the plain one" || bad "self on another: rc=$RC — $OUT"
callin sala-test-me "$SALA" retire sala-test-me --self --dry-run
[ "$RC" = 0 ] && has "$OUT" "--self: 'sala-test-me' is the session this command runs in; it would retire itself" && has "$OUT" "no /exit would be typed into pane" && ok "--self --dry-run: it would retire itself, no /exit" || bad "self --self dry: rc=$RC — $OUT"
untouched "$s0" "the own-session dry runs and refusals"
# the queue: the usual way a session ends itself. Refused at queue time without --self (retire's own dry run is the plan, and it runs in this very pane);
# with --self it is queued, and the runner (not in the pane's process tree) is passed --self as typed
callin sala-test-me "$SALA" op retire sala-test-me --from sala-test-me --words "retire myself"
[ "$RC" != 0 ] && has "$OUT" "'sala-test-me' is the asking session itself, the session this call runs in" && has "$OUT" "--self" && ! has "$OUT" "queued op" && ok "queue: a session's own retire without --self is refused, --self named" || bad "queue own without --self: rc=$RC — $OUT"
callin sala-test-me "$SALA" op retire sala-test-me --keep-web --from sala-test-me --words "retire myself"
[ "$RC" != 0 ] && ! has "$OUT" "queued op" && ok "queue: other flags do not stand in for --self" || bad "queue own with --keep-web: rc=$RC — $OUT"
callin sala-test-me "$SALA" op retire sala-test-me --self --from sala-test-me --words "retire myself"
[ "$RC" = 0 ] && has "$OUT" "queued op" && ok "queue: a session's own retire with --self is queued" || bad "queue own with --self: rc=$RC — $OUT"
OPID=$(sed -n 's/^queued op \([0-9-]*\):.*/\1/p' <<< "$OUT" | head -1)
[ -n "$OPID" ] && has "$(margs "$OPID")" "--self" && ok "queue: the marker carries --self for the runner" || bad "queue marker: id='$OPID'"
[ -n "$OPID" ] && "$SALA" op --cancel "$OPID" > /dev/null 2>&1
callin sala-test-me "$SALA" op retire sala-test-you --from sala-test-me --words "retire the other"
[ "$RC" = 0 ] && has "$OUT" "queued op" && ok "queue: another session's retire needs no --self (the control)" || bad "queue other: rc=$RC — $OUT"
OPID=$(sed -n 's/^queued op \([0-9-]*\):.*/\1/p' <<< "$OUT" | head -1); [ -n "$OPID" ] && "$SALA" op --cancel "$OPID" > /dev/null 2>&1
# --self from a pane that is mid-turn: its own running turn (registry "busy") is not a reason against; a dialog or a child process still is (--busy)
cme=$(pane_claude sala-test-me); set_reg_status "$cme" busy
callin sala-test-me "$SALA" retire sala-test-me --dry-run
[ "$RC" != 0 ] && has "$OUT" "is the session this command runs in" && ok "mid-turn, no --self: refused as the caller's own session (not as busy)" || bad "mid-turn no --self: rc=$RC — $OUT"
callin sala-test-me "$SALA" retire sala-test-me --self --dry-run
[ "$RC" = 0 ] && has "$OUT" "it would retire itself" && ! has "$OUT" "not idle" && ok "--self, its own turn running: the dry run passes, no idle refusal" || bad "mid-turn --self dry: rc=$RC — $OUT"
callin sala-test-me "$SALA" op retire sala-test-me --self --from sala-test-me --words "retire myself, mid-turn"
[ "$RC" = 0 ] && has "$OUT" "queued op" && ok "queued mid-turn with --self: the plan passes" || bad "queue mid-turn --self: rc=$RC — $OUT"
OPID=$(sed -n 's/^queued op \([0-9-]*\):.*/\1/p' <<< "$OUT" | head -1); [ -n "$OPID" ] && "$SALA" op --cancel "$OPID" > /dev/null 2>&1
callin sala-test-me "$SALA" retire sala-test-you --dry-run
[ "$RC" = 0 ] && has "$OUT" "would kill tmux session 'sala-test-you'" && ok "mid-turn, another session (idle): not affected" || bad "mid-turn other: rc=$RC — $OUT"
set_reg_status "$(pane_claude sala-test-you)" busy
callin sala-test-me "$SALA" retire sala-test-you --self --dry-run
[ "$RC" != 0 ] && has "$OUT" "'sala-test-you' is not idle" && ok "--self does not make ANOTHER busy session idle" || bad "self on busy other: rc=$RC — $OUT"
set_reg_status "$(pane_claude sala-test-you)" idle
set_reg_status "$cme" waiting
callin sala-test-me "$SALA" retire sala-test-me --self --dry-run
[ "$RC" != 0 ] && has "$OUT" "'sala-test-me' is not idle" && has "$OUT" "--busy" && ok "--self with a dialog showing (waiting): still not idle, --busy named" || bad "self waiting: rc=$RC — $OUT"
set_reg_status "$cme" busy
callin sala-test-me "$SALA" retire sala-test-me --self --busy --dry-run
[ "$RC" = 0 ] && has "$OUT" "it would retire itself" && ok "--self --busy on a dialog: passes" || bad "self busy waiting: rc=$RC — $OUT"
# a child process under the claude is another reason: --self alone does not lift it
hand sala-test-kid "$U9" FAKE_CHILD=1; driver_up sala-test-kid; set_reg_status "$(pane_claude sala-test-kid)" busy
callin sala-test-kid "$SALA" retire sala-test-kid --self --dry-run
[ "$RC" != 0 ] && has "$OUT" "'sala-test-kid' is not idle" && has "$OUT" "background task is running" && has "$OUT" "--busy" && ok "--self, its own turn running, a child process under it: still not idle, --busy named" || bad "self + child: rc=$RC — $OUT"
callin sala-test-kid "$SALA" retire sala-test-kid --self --busy --dry-run
[ "$RC" = 0 ] && has "$OUT" "it would retire itself" && ok "--self --busy with a child process: passes" || bad "self busy child: rc=$RC — $OUT"
tmux kill-session -t =sala-test-kid
set_reg_status "$cme" idle
# the queue's runner: retire --id resolves its session at run time and is not in the pane's tree; the asker is the op's own record (SALA_OP_FROM)
hand sala-test-qid "$UQI"; s0=$(state)
SALA_OP_FROM=sala-test-qid run retire --id "$UQI" --dry-run
[ "$RC" != 0 ] && has "$OUT" "'sala-test-qid' is the session that queued this retire" && has "$OUT" "--self" && ok "run time, --id resolving to the asker's own session: refused without --self" || bad "runner id no --self: rc=$RC — $OUT"
SALA_OP_FROM=sala-test-qid run retire --id "$UQI" --self --dry-run
[ "$RC" = 0 ] && has "$OUT" "queued this retire itself" && has "$OUT" "would kill tmux session 'sala-test-qid'" && ok "run time, --id with --self: the runner retires it" || bad "runner id --self: rc=$RC — $OUT"
SALA_OP_FROM=sala-test-other run retire --id "$UQI" --dry-run
[ "$RC" = 0 ] && ok "run time, --id resolving to another asker's session: not refused (the control)" || bad "runner id other: rc=$RC — $OUT"
untouched "$s0" "the run-time --id dry runs"
# for real: the queue's runner starts while the asker's turn runs; it waits for the turn to end, and refuses a pane that stays busy
set_reg_status "$(pane_claude sala-test-qid)" busy
SALA_RETIRE_SELF_WAIT=2 SALA_OP_FROM=sala-test-qid run retire --id "$UQI" --self --keep-web
[ "$RC" != 0 ] && has "$OUT" "mid-turn: waiting up to 2s" && has "$OUT" "'sala-test-qid' is not idle" && ! gone sala-test-qid && ok "runner, --self, the asker stays busy: waited, then refused like any busy pane" || bad "runner wait refuse: rc=$RC — $OUT"
# the turn ends only once the runner has said it is waiting (a fixed sleep raced a runner that reached its busy check late on a loaded box):
# the runner goes to the background with its output in a file, the flip to idle waits for its message, then OUT and RC are what `run` sets
qc=$(pane_claude sala-test-qid); qw="$HOME/retire-wait.out"; : > "$qw"
( SALA_RETIRE_SELF_WAIT=60 SALA_OP_FROM=sala-test-qid exec "$SALA" retire --id "$UQI" --self --keep-web > "$qw" 2>&1 ) & qwpid=$!
waitfor "grep -q 'mid-turn: waiting up to 60s' '$qw'" 120; qwrc=$?
set_reg_status "$qc" idle
wait "$qwpid"; RC=$?; OUT=$(<"$qw"); rm -f "$qw"
[ "$qwrc" = 0 ] || OUT="(the runner never printed its waiting message) $OUT"
[ "$RC" = 0 ] && has "$OUT" "mid-turn: waiting up to 60s" && has "$OUT" "retired 'sala-test-qid'" && gone sala-test-qid && ok "runner, --self, the asker's turn ends meanwhile: retired once it is idle" || bad "runner wait then retire: rc=$RC — $OUT"
tmux kill-session -t =sala-test-qid 2>/dev/null
: > "$FAKE_LOG"; : > "$SALA_LOG_DIR/salamander-retire.log"
# the real one: the driver is killed with its session, so no answer comes back; wait for the session to go and read the log
id=$(date +%s%N)-$RANDOM; f="$HOME/drv-calls/sala-test-me/$id"; printf '%q ' "$SALA" retire sala-test-me --self --keep-web > "$f.tmp"; echo >> "$f.tmp"; mv "$f.tmp" "$f.cmd"
waitfor "! tmux has-session -t =sala-test-me 2>/dev/null" 120 && ok "--self for real: the session is gone" || bad "--self for real: the session is still there"
waitfor "grep -q \"retired 'sala-test-me'\" '$SALA_LOG_DIR/salamander-retire.log'" 60 && ok "the rest of the output is in the retire log (it was written once the pane was gone)" || bad "retire log: $(cat "$SALA_LOG_DIR/salamander-retire.log" 2>/dev/null)"
grep -q "no /exit typed into its own pane" "$SALA_LOG_DIR/salamander-retire.log" 2>/dev/null && ! grep -q "^exit $U7" "$FAKE_LOG" && ok "no /exit was typed into its own pane" || bad "own pane: log=$(cat "$SALA_LOG_DIR/salamander-retire.log" 2>/dev/null) fake=$(cat "$FAKE_LOG")"
[ -z "$(row sala-test-me)" ] && [ -e "$HOME/snap.done" ] && ok "its row gone, the snapshot taken (the tail ran after the kill)" || bad "after self retire: row='$(row sala-test-me)'"
tmux has-session -t =sala-test-you 2>/dev/null && ok "the other session is untouched" || bad "sala-test-you went"
tmux kill-session -t =sala-test-you

echo "== close-shell: dry run and real (kill, row, lane and model rows, snapshot)"
shell sala-test-sh2; ledger_write add sala-test-sh2 "$UO" sala-test-sh2 "$HOME/work" >/dev/null 2>&1
printf 'sala-test-sh2\tapi\n' >> "$SALA_LANES"; printf 'sala-test-sh2\topus\thigh\n' >> "$SALA_MODELS"; rm -f "$HOME/snap.done"; s0=$(state)
run close-shell sala-test-sh2 --dry-run
[ "$RC" = 0 ] && has "$OUT" "'sala-test-sh2': 1 pane(s), none with a Claude session" && has "$OUT" "would kill tmux session 'sala-test-sh2'" && has "$OUT" "would remove its pane-map row" && has "$OUT" "would drop its lane row (sala-test-sh2 → api)" \
    && has "$OUT" "would drop its model row" && has "$OUT" "would take a resurrect snapshot" && has "$OUT" "nothing was changed" && ok "dry run: the kill, the row, the lane and model rows and the snapshot, as would-lines" || bad "close-shell dry: rc=$RC — $OUT"
untouched "$s0" "close-shell --dry-run"
run close-shell sala-test-sh2
[ "$RC" = 0 ] && has "$OUT" "'sala-test-sh2': tmux session killed" && has "$OUT" "pane map row removed" && has "$OUT" "closed 'sala-test-sh2'" && gone sala-test-sh2 && [ -z "$(row sala-test-sh2)" ] && [ -z "$(lane_row sala-test-sh2)" ] && [ -z "$(model_row sala-test-sh2)" ] && [ -e "$HOME/snap.done" ] \
    && ok "real: the session killed, its row, lane and model rows gone, the snapshot taken" || bad "close-shell real: rc=$RC — $OUT"
! has "$OUT" "stackshot" && ok "no stackshot agent-entry call (a shell session is on no agents map)" || bad "close-shell named stackshot: $OUT"

echo "== close-shell refusals: the master, the RC session, the caller's own session, a session still running something"
shell sala-test-m1; s0=$(state)
SALA_MASTER=sala-test-m1 run close-shell sala-test-m1
[ "$RC" != 0 ] && has "$OUT" "the master session the watchdog keeps alive" && has "$OUT" "sala op close-shell sala-test-m1" && ok "the master: refused outside the queue, the queue's form named" || bad "master: rc=$RC — $OUT"
SALA_MASTER=sala-test-m1 SALA_OP_PLAN=1 run close-shell sala-test-m1 --dry-run
[ "$RC" = 0 ] && has "$OUT" "the queue would unset SALA_MASTER first" && ok "the master's plan (the queue's dry run): would unset SALA_MASTER, then close" || bad "master plan: rc=$RC — $OUT"
shell "$SALA_RC_SESSION"
run close-shell "$SALA_RC_SESSION"
[ "$RC" != 0 ] && has "$OUT" "is the Remote Control server" && ok "the RC session: refused, rc --stop named" || bad "rc: rc=$RC — $OUT"
tmux kill-session -t "=$SALA_RC_SESSION"
tmux send-keys -t =sala-test-m1: 'sleep 600' Enter; waitfor "pgrep -P $(tmux display -p -t =sala-test-m1: '#{pane_pid}') >/dev/null" 20
run close-shell sala-test-m1
[ "$RC" != 0 ] && has "$OUT" "is a shell session still running: " && has "$OUT" "sleep" && has "$OUT" "--busy" && ! gone sala-test-m1 && ok "a shell still running sleep: refused, the child and --busy named, the session kept" || bad "running shell: rc=$RC — $OUT"
run close-shell sala-test-m1 --dry-run
[ "$RC" != 0 ] && has "$OUT" "[dry-run] would refuse" && ok "its dry run says it would refuse" || bad "running dry: rc=$RC — $OUT"
run close-shell sala-test-m1 --busy --dry-run
[ "$RC" = 0 ] && has "$OUT" "still running: " && ok "--busy --dry-run: it would close it, the child named" || bad "busy dry: rc=$RC — $OUT"
run close-shell sala-test-m1 --busy
[ "$RC" = 0 ] && has "$OUT" "closing 'sala-test-m1' while it is still running" && gone sala-test-m1 && ok "--busy: said, and closed" || bad "busy close: rc=$RC — $OUT"
# the caller's own session: a driver (a claude ancestor) in a plain shell session
shell sala-test-me2; driver_up sala-test-me2
callin sala-test-me2 bash -c 'echo up'; [ "$RC" = 0 ] || bad "the driver in sala-test-me2 did not answer: rc=$RC $OUT"
callin sala-test-me2 "$SALA" close-shell sala-test-me2
[ "$RC" != 0 ] && tmux has-session -t =sala-test-me2 2>/dev/null && ok "close-shell of the caller's own session: refused, the session kept" || bad "close-shell self: rc=$RC — $OUT"
tmux kill-session -t =sala-test-me2

echo "== forget-row: dry run and real (the row, the lane and model rows; nothing killed)"
ledger_write add sala-test-orph "$UO" sala-test-orph "$HOME/work" >/dev/null 2>&1; [ -n "$(lane_row sala-test-orph)" ] || printf 'sala-test-orph\tapi\n' >> "$SALA_LANES"; [ -n "$(model_row sala-test-orph)" ] || printf 'sala-test-orph\topus\thigh\n' >> "$SALA_MODELS"
s0=$(state)
run forget-row sala-test-orph --dry-run
[ "$RC" = 0 ] && has "$OUT" "'sala-test-orph': no tmux session — would remove its pane-map row" && has "$OUT" "would drop its lane row (sala-test-orph → api)" && has "$OUT" "would drop its model row" && has "$OUT" "nothing was changed" && ok "dry run: the row, the lane and model rows named, nothing changed" || bad "forget-row dry: rc=$RC — $OUT"
untouched "$s0" "forget-row --dry-run"
hand sala-test-live "$UL"; s1=$(state)
run forget-row sala-test-live
[ "$RC" != 0 ] && has "$OUT" "is live and runs a Claude session" && ok "a live session's name: refused" || bad "forget-row live: rc=$RC — $OUT"
untouched "$s1" "forget-row of a live session"
tmux kill-session -t =sala-test-live
run forget-row sala-test-orph
[ "$RC" = 0 ] && has "$OUT" "forgot 'sala-test-orph'" && [ -z "$(row sala-test-orph)" ] && [ -z "$(lane_row sala-test-orph)" ] && [ -z "$(model_row sala-test-orph)" ] && ok "real: the row, the lane row and the model row gone" || bad "forget-row real: rc=$RC — $OUT"
run forget-row sala-test-orph
[ "$RC" != 0 ] && has "$OUT" "no pane-map row for 'sala-test-orph'" && ok "again: nothing to forget, refused" || bad "forget-row again: rc=$RC — $OUT"
ledger_write add sala-test-m2 "$UO" sala-test-m2 "$HOME/work" >/dev/null 2>&1
SALA_MASTER=sala-test-m2 run forget-row sala-test-m2
[ "$RC" != 0 ] && has "$OUT" "the master session the watchdog keeps alive" && [ -n "$(row sala-test-m2)" ] && ok "the master's row: refused outside the queue, the row kept" || bad "forget-row master: rc=$RC — $OUT"
run forget-row "$SALA_RC_SESSION"
[ "$RC" != 0 ] && has "$OUT" "Remote Control" && ok "the RC session's name: refused" || bad "forget-row rc: rc=$RC — $OUT"
run forget-row sala-test-m2

echo "== the queue: close-shell and forget-row are verbs, with the words rules; the new flags reach the marker"
hand sala-test-h "$UQ"; shell sala-test-q1; ledger_write add sala-test-q2 "$UO" sala-test-q2 "$HOME/work" >/dev/null 2>&1; hand sala-test-q3 "$U3"; dropall
enq close-shell sala-test-q1 --from sala-test-h --words "close the shell"
[ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(queued)" = 1 ] && [ "$(mval "$ID" verb)" = close-shell ] && has "$OUT" "would kill tmux session 'sala-test-q1'" && [ "$(mval "$ID" words)" = "close the shell" ] && ok "close-shell with words: queued, the plan is its dry run, the words kept" || bad "enq close-shell: rc=$RC id=$ID — $OUT"
gone sala-test-q1 && bad "the queue closed it at once" || ok "nothing ran: the shell session is still there (SALA_OP_QUEUE=off)"
dropall
enq close-shell sala-test-q1 --busy --from sala-test-h --words "close it though it runs"
[ "$RC" = 0 ] && [ "$(queued)" = 1 ] && has "$(margs "$ID")" "--busy" && ok "close-shell --busy: queued, the flag in the marker" || bad "enq close-shell --busy: rc=$RC — $OUT / $(margs "$ID")"
dropall
enq close-shell sala-test-q1 --force --from sala-test-h --words "close it"
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && ok "close-shell --force: refused at queue time, nothing queued" || bad "enq close-shell --force: rc=$RC queued=$(queued) — $OUT"
enq close-shell sala-test-q1 --keep-web --from sala-test-h --words "close it"
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && ok "close-shell --keep-web: not a flag of this verb, refused" || bad "enq close-shell --keep-web: rc=$RC queued=$(queued) — $OUT"
enq close-shell sala-test-q3 --from sala-test-h --words "close it"
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "sala retire sala-test-q3" && ok "close-shell of a Claude session: the plan refuses, retire named, nothing queued" || bad "enq close-shell claude: rc=$RC queued=$(queued) — $OUT"
enq close-shell sala-test-q1 --from sala-test-h
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && ok "close-shell with no words (not a throwaway of the caller's): refused, nothing queued" || bad "enq close-shell no words: rc=$RC queued=$(queued) — $OUT"
enq forget-row sala-test-q2 --from sala-test-h --words "forget the row"
[ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(queued)" = 1 ] && [ "$(mval "$ID" verb)" = forget-row ] && has "$OUT" "'sala-test-q2': no tmux session — would remove its pane-map row" && ok "forget-row with words: queued, the plan is its dry run" || bad "enq forget-row: rc=$RC id=$ID — $OUT"
[ -n "$(row sala-test-q2)" ] && ok "the row is still there (nothing ran)" || bad "the row went at queue time"
dropall
enq forget-row sala-test-q3 --from sala-test-h --words "forget it"
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "sala retire sala-test-q3" && ok "forget-row of a live session: the plan refuses, nothing queued" || bad "enq forget-row live: rc=$RC queued=$(queued) — $OUT"
enq forget-row sala-test-q2 --busy --from sala-test-h --words "forget it"
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && ok "forget-row takes no flag: --busy refused" || bad "enq forget-row --busy: rc=$RC queued=$(queued) — $OUT"
enq forget-row sala-test-q2 --from sala-test-h
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && ok "forget-row with no words: refused" || bad "enq forget-row no words: rc=$RC queued=$(queued) — $OUT"
enq retire sala-test-q3 --force --from sala-test-h --words "retire it"
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "retire has no --force any more" && has "$OUT" "--busy" && has "$OUT" "--skip-writeup" && ok "retire --force: refused at queue time, even with words, the two flags named" || bad "enq retire --force: rc=$RC queued=$(queued) — $OUT"
enq retire sala-test-q3 --busy --skip-writeup --leave-items --keep-web --from sala-test-h --words "retire it, all bypasses"
[ "$RC" = 0 ] && [ "$(queued)" = 1 ] && has "$(margs "$ID")" "--busy" && has "$(margs "$ID")" "--skip-writeup" && has "$(margs "$ID")" "--leave-items" && has "$(margs "$ID")" "--keep-web" && ok "retire with the new flags and words: queued, every flag in the marker" || bad "enq retire flags: rc=$RC — $OUT / $(margs "$ID")"
dropall
enq retire sala-test-q3 --self --from sala-test-q3 --words "retire myself"
[ "$RC" = 0 ] && [ "$(queued)" = 1 ] && has "$(margs "$ID")" "--self" && ok "retire --self: queued (the usual way for a session to retire itself), the flag in the marker" || bad "enq retire --self: rc=$RC — $OUT / $(margs "$ID")"
dropall
enq retire --id "$U3" --from sala-test-h --words "retire by conversation"
[ "$RC" = 0 ] && [ "$(queued)" = 1 ] && has "$(margs "$ID")" "--id" && ok "retire --id with words: queued" || bad "enq retire --id: rc=$RC — $OUT / $(margs "$ID")"
dropall
enq retire --id "$U3" --from sala-test-h
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && ok "retire --id with no words: refused" || bad "enq retire --id no words: rc=$RC queued=$(queued) — $OUT"
run op --help
has "$OUT" "close-shell NAME" && has "$OUT" "forget-row NAME" && ok "sala op's help lists the two new verbs" || bad "op help: $OUT"

[ "$fail" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
