#!/usr/bin/env bash
# `sala retire` (Claude sessions only, by the exact tmux session name or by --id), and the two verbs it was split from (Sun Nov 1st 2026): the registry
# resolving a conversation id (or its prefix, 8+ hex) with --id to its tmux session and pane, said before anything is done; a registry name no longer a
# name (refused, --id named); an ambiguous id (two live rows, a prefix on several, a session that also holds another live claude) refused with the
# candidates and nothing touched; a dead row or one without a tmux pane not acted on; `--dry-run` in every form touching nothing; an orphan row refused by
# retire (forget-row named) and dropped by `forget-row`. The last sections: a retire ASKS stackshot FIRST (a stub client.py: called once with project, name and sender sala-retire, before
# the pane is closed; not in --dry-run; 200 line removed / dropped / not listed and a 404 go on, said in words; 502, 422, 409, 403, 400, a failing client or a timeout REFUSE the retire
# with stackshot's reason and leave the pane, the row and the lane as they are; a missing client.py or a session with no project goes on; a throwaway's name, a side session and
# sala's shell are not asked; no second call after the pane is gone). The guardrails (--busy, --skip-writeup, --self, --leave-items, close-shell) are tests/retire-verbs.sh's.
# Isolated HOME, a private tmux socket, the compiled fake claude (tests/fake-claude.c).
# Usage: bash tests/retire.sh   (exit 0 = pass; ~40 s)
set -u
unset TMUX_PANE XDG_STATE_HOME
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, fake_up, tmux_socket_rm
SANDBOX=""; SLEEPER=""; SOCK="sala-retire-$$"; T="tmux -L $SOCK -f /dev/null"
cleanup() {
    local e p
    [ -n "$SLEEPER" ] && kill "$SLEEPER" 2>/dev/null
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    if [ -n "$SANDBOX" ]; then
        for e in /proc/[0-9]*/exe; do [ "$e" -ef "$SANDBOX/.local/bin/claude" ] || continue; p=${e#/proc/}; kill -9 "${p%/exe}" 2>/dev/null; done   # only our fakes, found by their exe
        rm -rf "$SANDBOX" 2>/dev/null
    fi; true
}; trap cleanup EXIT   # set before the temp folder exists
SANDBOX=$(mktemp -d); export HOME=$SANDBOX; export SALA_CONFIG=/dev/null
exec 8< "$SANDBOX"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
as_op_unit   # the guarded verbs this suite runs itself stand for the queue's runner (tests/lib.sh, 5)
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOME/work"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
cc -o "$HOME/.local/bin/claude" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
export PATH="$HOME/.local/bin:$PATH"; export FAKE_LOG="$HOME/fake.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="cat >> $POSTS"   # no post leaves the box
export SALA_AUTO_UPDATE=off SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_SNAPSHOT_CMD="touch $HOME/snap.done"
SALA="$ROOT/bin/salamander"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's
. "$ROOT/lib/common.sh"; MAP="$SALA_SIDECAR"; LOG="$SALA_LEDGER_LOG"
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux   # literal socket: the children run set -u
tmux new-session -d -s sala-test-anchor -c "$HOME/work"   # a plain shell that outlives every case: a server with no session left saves no snapshot (snapshot.sh do_save) and has no current session for tmux_socket
row() { awk -F'\t' -v s="$1" '$1==s' "$MAP" 2>/dev/null; }
pane_claude() { claude_pid_under "$(tmux display -p -t "$1" '#{pane_pid}' 2>/dev/null)"; }   # <session> → its claude's pid
hand() {  # <session> <uuid> <registry name> [env=val…] — a session made by hand, its claude registered under <registry name>
    local s="$1" u="$2" n="$3"; shift 3; local e=(); local kv; for kv in "$@"; do e+=(-e "$kv"); done
    tmux new-session -d -s "$s" -c "$HOME/work" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="$n" -e FAKE_LOG="$FAKE_LOG" ${e[@]+"${e[@]}"}; tmux send-keys -t "$s" 'claude' Enter
    waitfor "reg_live '\"sessionId\":\"$u\"'" 40 || echo "  (fake claude '$n' in $s did not come up)"; }   # by its conversation id: two fakes may share a name
kill_wait() { local s c; for s in "$@"; do c=$(pane_claude "$s"); tmux kill-session -t "=$s" 2>/dev/null; [ -n "$c" ] && waitfor "! kill -0 $c 2>/dev/null" 20; done; return 0; }
state() {  # everything retire touches: the map and its log, the lane and model tables and logs, every session's panes, the registry files, the snapshot marker, the fake's events
    local f; for f in "$MAP" "$LOG" "$SALA_LANES" "$SALA_MODELS" "$SALA_LANE_LOG" "$SALA_MODEL_LOG" "$FAKE_LOG"; do echo "== $f"; cat "$f" 2>/dev/null; done
    tmux list-panes -a -F '#{session_name} #{pane_id} #{pane_pid} #{pane_current_command}' 2>/dev/null; ls "$HOME/.claude/sessions" 2>/dev/null; ls "$HOME/snap.done" 2>/dev/null; }
untouched() {  # <state before> <label>
    [ "$(state)" = "$1" ] && ok "$2: nothing touched (map, lanes, models, logs, panes, registry, snapshot, the fake's events all as before)" || bad "$2: something changed — $(diff <(echo "$1") <(state) | head -20)"; }
lineno() { echo "$1" | grep -n -- "$2" | head -1 | cut -d: -f1; }   # <text> <pattern> → the first line's number, or nothing
PIDMAX=$(cat /proc/sys/kernel/pid_max 2>/dev/null || echo 99999)
UN1=0a000001-0000-4000-8000-000000000001 UR1=cafe0001-0000-4000-8000-000000000011 UR2=cafe0002-0000-4000-8000-000000000012
UA1=0a000003-0000-4000-8000-000000000021 UA2=0a000004-0000-4000-8000-000000000022
UP1=dead0000-0000-4000-8000-000000000031 UP2=dead0000-0000-4000-8000-000000000032
UG=0a000007-0000-4000-8000-000000000041 UH=0a000008-0000-4000-8000-000000000042
UW1=0a000009-0000-4000-8000-000000000051 UW2=0a00000a-0000-4000-8000-000000000052
UD1=0a00000b-0000-4000-8000-000000000061 UD2=0a00000c-0000-4000-8000-000000000062 UR3=0a00000d-0000-4000-8000-000000000063
UO=0a00000e-0000-4000-8000-000000000071 UM=0a00000f-0000-4000-8000-000000000081

echo "== the plain path: a tmux-session name, as it was (no registry lookup, the row, the lane and model rows, the snapshot)"
hand sala-test-n1 "$UN1" sala-test-n1; "$SALA" adopt sala-test-n1 >/dev/null 2>&1
[ -n "$(row sala-test-n1)" ] || bad "no row for sala-test-n1 to start from"
mkdir -p "$SALA_STATE_DIR"; printf 'sala-test-n1\tapi\n' >> "$SALA_LANES"; printf 'sala-test-n1\topus\thigh\n' >> "$SALA_MODELS"
rm -f "$HOME/snap.done"; c=$(pane_claude sala-test-n1)
out=$("$SALA" retire sala-test-n1 --keep-web 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
[ "$rc" = 0 ] && ! echo "$out" | grep -q "CLI registry" && echo "$out" | grep -q "^retired 'sala-test-n1'; the transcript stays" && ! tmux has-session -t =sala-test-n1 2>/dev/null \
    && ok "retired by its tmux session name: no registry line, the session gone, the line as before" || bad "plain retire: rc=$rc"
waitfor "! kill -0 $c 2>/dev/null" 20 && grep -q "^exit $UN1" "$FAKE_LOG" && ok "its claude took the /exit" || bad "the fake did not exit cleanly: $(grep "$UN1" "$FAKE_LOG")"
[ -z "$(row sala-test-n1)" ] && [ -z "$(lane_row sala-test-n1)" ] && [ -z "$(model_row sala-test-n1)" ] && [ -e "$HOME/snap.done" ] && ok "its pane-map, lane and model rows gone, the snapshot taken" || bad "after: map='$(row sala-test-n1)' lane='$(lane_row sala-test-n1)' model='$(model_row sala-test-n1)' snap=$([ -e "$HOME/snap.done" ] && echo yes || echo no)"

echo "== a registry name is not a tmux session: refused, nothing touched; --id resolves the conversation to its differently named tmux session, said before anything is done"
hand sala-test-r1 "$UR1" sala-test-alias; c=$(pane_claude sala-test-r1); p=$(tmux list-panes -t =sala-test-r1 -F '#{pane_id}' | head -1)
[ -z "$(row sala-test-r1)" ] || bad "sala-test-r1 should have no row"; s0=$(state)
out=$("$SALA" retire sala-test-alias --keep-web 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -qF "no tmux session 'sala-test-alias' (retire takes the exact name" && echo "$out" | grep -qF "use: sala retire --id <conversation-id>" && ok "the registry name is no tmux session: refused, --id named" || bad "registry name: rc=$rc $out"
untouched "$s0" "retire sala-test-alias"
out=$("$SALA" retire --id "$UR1" --keep-web 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
chosen="'$UR1' → CLI registry (name 'sala-test-alias', pid $c, conversation $UR1) → tmux session 'sala-test-r1', pane $p"
[ "$rc" = 0 ] && echo "$out" | grep -qF -- "$chosen" && ok "the choice said: id → registry row → tmux session, pane" || bad "no choice line: rc=$rc"
a=$(lineno "$out" "CLI registry"); b=$(lineno "$out" "'sala-test-r1': /exit"); k=$(lineno "$out" "tmux session killed")
[ -n "$a" ] && [ -n "$b" ] && [ -n "$k" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$k" ] && ok "said before acting (line $a, the /exit at $b, the kill at $k)" || bad "order: choice=$a exit=$b kill=$k"
! tmux has-session -t =sala-test-r1 2>/dev/null && waitfor "! kill -0 $c 2>/dev/null" 20 && grep -q "^exit $UR1" "$FAKE_LOG" && echo "$out" | grep -q "^retired 'sala-test-r1' (named as '$UR1')" \
    && ok "the tmux session retired through its own pane: /exit taken, session gone, the line names both" || bad "resolved retire: $(tmux list-sessions 2>/dev/null)"

echo "== by a prefix of the conversation id (8+ hex); the dry run first"
hand sala-test-r2 "$UR2" sala-test-r2name; c=$(pane_claude sala-test-r2); rm -f "$HOME/snap.done"; s0=$(state)
out=$("$SALA" retire --id cafe0002-0000 --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "'cafe0002-0000' → CLI registry (name 'sala-test-r2name', pid $c, conversation $UR2) → tmux session 'sala-test-r2'" && echo "$out" | grep -q "would kill tmux session 'sala-test-r2'" && echo "$out" | grep -q "no pane-map row to remove" \
    && ok "a prefix resolves; the dry run shows the choice and the kill it would do" || bad "prefix dry run: rc=$rc $out"
untouched "$s0" "retire --id <prefix> --dry-run"
out=$("$SALA" retire --id "${UR2:0:13}" --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "'${UR2:0:13}' → CLI registry" && ! tmux has-session -t =sala-test-r2 2>/dev/null && ok "the prefix retires it" || bad "by id: rc=$rc $out"
out=$("$SALA" retire --id cafe000 2>&1); rc=$?; [ "$rc" != 0 ] && echo "$out" | grep -q "'cafe000' is too short: a conversation id is a full uuid, or its first 8 or more hex characters" && ok "a 7-character prefix is not looked up" || bad "short prefix: rc=$rc $out"
out=$("$SALA" retire sala-test-x --id "$UR2" 2>&1); rc=$?; [ "$rc" != 0 ] && echo "$out" | grep -q "either by its tmux session name or by --id, not both" && ok "a name and --id together are refused" || bad "name and --id: rc=$rc $out"

echo "== a registry name is not a name retire takes: two live rows with the name → refused as no tmux session, nothing touched (for real and in the dry run)"
hand sala-test-a1 "$UA1" sala-test-dup; hand sala-test-a2 "$UA2" sala-test-dup; c1=$(pane_claude sala-test-a1); c2=$(pane_claude sala-test-a2); s0=$(state)
for flag in "" --dry-run; do
    out=$("$SALA" retire sala-test-dup $flag 2>&1); rc=$?; [ -z "$flag" ] && echo "$out" | sed 's/^/    /'
    [ "$rc" != 0 ] && echo "$out" | grep -qF "no tmux session 'sala-test-dup' (retire takes the exact name" && echo "$out" | grep -qF "use: sala retire --id <conversation-id>" \
        && ok "retire sala-test-dup $flag: refused (rc $rc), --id named" || bad "registry name ${flag:-for real}: rc=$rc $out"
    untouched "$s0" "retire sala-test-dup $flag"
done
tmux has-session -t =sala-test-a1 2>/dev/null && tmux has-session -t =sala-test-a2 2>/dev/null && kill -0 "$c1" && kill -0 "$c2" && ok "both sessions and their claudes still up" || bad "a session or claude is gone"
kill_wait sala-test-a1 sala-test-a2

echo "== ambiguous: a conversation-id prefix on two rows → refused; the full id takes exactly one"
hand sala-test-p1 "$UP1" sala-test-p1; hand sala-test-p2 "$UP2" sala-test-p2; s0=$(state)
out=$("$SALA" retire --id dead0000-0000 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -q "'dead0000-0000' is ambiguous — 2 live sessions" && echo "$out" | grep -q "conversation $UP1) → tmux session 'sala-test-p1'" && echo "$out" | grep -q "conversation $UP2) → tmux session 'sala-test-p2'" && ok "the prefix refused, both listed" || bad "prefix ambiguity: rc=$rc $out"
untouched "$s0" "retire --id <shared prefix>"
out=$("$SALA" retire --id "$UP1" --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && ! tmux has-session -t =sala-test-p1 2>/dev/null && tmux has-session -t =sala-test-p2 2>/dev/null && ok "the full id retired sala-test-p1 alone; sala-test-p2 stands" || bad "full id: rc=$rc $(tmux list-sessions)"
kill_wait sala-test-p2

echo "== a registry row whose process is gone, one with no tmux pane: said, not acted on (--id)"
printf '{"pid":%s,"sessionId":"%s","name":"sala-test-gone","tmux":"sala-test-x:@1.%%99","cwd":"%s"}\n' "$((PIDMAX+7))" "$UG" "$HOME" > "$HOME/.claude/sessions/$((PIDMAX+7)).json"
ledger_write add sala-test-xrow "$UG" sala-test-xrow "$HOME" >/dev/null 2>&1   # the map carries that conversation under another name: the hint
sleep 300 & SLEEPER=$!; printf '{"pid":%s,"sessionId":"%s","name":"sala-test-headless","cwd":"%s"}\n' "$SLEEPER" "$UH" "$HOME" > "$HOME/.claude/sessions/$SLEEPER.json"
s0=$(state)
for flag in "" --dry-run; do
    out=$("$SALA" retire --id "$UG" $flag 2>&1); rc=$?; [ -z "$flag" ] && echo "$out" | sed 's/^/    /'
    [ "$rc" != 0 ] && echo "$out" | grep -q "no live session has conversation id '$UG'; the CLI registry names it, but nothing there can be acted on" \
        && echo "$out" | grep -q "name 'sala-test-gone' (pid $((PIDMAX+7)), conversation $UG): its process (pid $((PIDMAX+7))) is gone — the pane map carries that conversation as row 'sala-test-xrow' (its tmux session is gone: sala forget-row sala-test-xrow)" \
        && ok "retire --id $UG $flag: refused (rc $rc), the dead row said, the map's row for its conversation pointed at with the verb that takes it" || bad "dead row ${flag:-for real}: rc=$rc $out"
    untouched "$s0" "retire --id $UG $flag"
done
out=$("$SALA" retire --id "$UH" 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
[ "$rc" != 0 ] && echo "$out" | grep -q "name 'sala-test-headless' (pid $SLEEPER, conversation $UH): no tmux pane recorded for it" && kill -0 "$SLEEPER" 2>/dev/null && ok "a row with no tmux pane: refused, its process left alone" || bad "headless row: rc=$rc $out"
untouched "$s0" "retire --id $UH"
[ -n "$(row sala-test-xrow)" ] && ok "the map row named in the hint still stands (retire --id never drops another row)" || bad "sala-test-xrow's row gone"
out=$("$SALA" retire sala-test-nothing 2>&1); rc=$?; [ "$rc" != 0 ] && echo "$out" | grep -q "no tmux session 'sala-test-nothing' (retire takes the exact name" && echo "$out" | grep -q "use: sala retire --id <conversation-id>" && ok "a name nothing knows: an error that names --id" || bad "nothing: rc=$rc $out"
out=$("$SALA" retire --id 0a0000ff-0000 2>&1); rc=$?; [ "$rc" != 0 ] && echo "$out" | grep -q "no live session has conversation id '0a0000ff-0000' (no CLI registry row carries it)" && ok "an id nothing carries: still an error" || bad "unknown id: rc=$rc $out"

echo "== the resolved tmux session also holds another live claude (a second window): refused, both left"
hand sala-test-w1 "$UW1" sala-test-w1name; c1=$(pane_claude sala-test-w1)
tmux new-window -t =sala-test-w1 -c "$HOME/work" -e FAKE_SESSION_ID="$UW2" -e FAKE_NAME=sala-test-w2name -e FAKE_LOG="$FAKE_LOG"; tmux send-keys -t =sala-test-w1: 'claude' Enter; fake_up sala-test-w2name
s0=$(state)
out=$("$SALA" retire --id "$UW1" 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
[ "$rc" != 0 ] && echo "$out" | grep -q "'$UW1' is in tmux session 'sala-test-w1'" && echo "$out" | grep -q "also holds another live session" && echo "$out" | grep -q "name 'sala-test-w2name' (pid [0-9]*, conversation $UW2) in pane %" \
    && ok "refused: the other claude in the session named with its pane" || bad "two in one session: rc=$rc"
untouched "$s0" "retire --id $UW1"
kill_wait sala-test-w1

echo "== --dry-run on a tmux-session name with every row: each action named, nothing done"
hand sala-test-d1 "$UD1" sala-test-d1; "$SALA" adopt sala-test-d1 >/dev/null 2>&1; c=$(pane_claude sala-test-d1); p=$(tmux list-panes -t =sala-test-d1 -F '#{pane_id}' | head -1)
printf 'sala-test-d1\tsubscription-2\n' >> "$SALA_LANES"; printf 'sala-test-d1\tsonnet\tmedium\n' >> "$SALA_MODELS"; rm -f "$HOME/snap.done"; s0=$(state)
out=$("$SALA" retire sala-test-d1 --dry-run 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
[ "$rc" = 0 ] && echo "$out" | grep -q "^\[dry-run\] would type /exit into pane $p and wait up to 30s" && echo "$out" | grep -q "^\[dry-run\] would kill tmux session 'sala-test-d1' (pane $p" \
    && echo "$out" | grep -q "^\[dry-run\] would remove its pane-map row from $MAP (tab-separated): sala-test-d1 $UD1 sala-test-d1 $HOME/work" \
    && echo "$out" | grep -q "^\[dry-run\] would drop its lane row (sala-test-d1 → subscription-2) from $SALA_LANES" && echo "$out" | grep -q "^\[dry-run\] would drop its model row (sala-test-d1 → sonnet/medium) from $SALA_MODELS" \
    && echo "$out" | grep -q "^\[dry-run\] would take a resurrect snapshot" && echo "$out" | grep -q "^\[dry-run\] would archive its claude.ai session session_01FAKE (salamander rc --archive session_01FAKE)" \
    && echo "$out" | grep -q "^\[dry-run\] the transcript would stay: claude --resume $UD1" && echo "$out" | grep -q "^\[dry-run\] nothing was changed" \
    && ok "the /exit, the kill, the pane-map row, the lane row, the model row, the snapshot, the archive, the transcript: each named" || bad "dry run lines: rc=$rc"
untouched "$s0" "retire sala-test-d1 --dry-run"
kill -0 "$c" 2>/dev/null && [ "$(pane_claude sala-test-d1)" = "$c" ] && [ ! -e "$HOME/snap.done" ] && ok "the same claude still in its pane, no snapshot" || bad "pane changed: claude $c → $(pane_claude sala-test-d1), snap=$([ -e "$HOME/snap.done" ] && echo yes || echo no)"
out=$("$SALA" retire sala-test-d1 --dry-run --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "^\[dry-run\] --keep-web: would leave the claude.ai session session_01FAKE as it is" && ! echo "$out" | grep -q "would archive" && ok "--keep-web --dry-run: the archive left out, said" || bad "keep-web dry run: rc=$rc $out"
untouched "$s0" "retire sala-test-d1 --dry-run --keep-web"

echo "== --dry-run on a pane that is not idle (a live child): the refusal said, then --busy's path, nothing done"
hand sala-test-d2 "$UD2" sala-test-d2 FAKE_CHILD=1; c=$(pane_claude sala-test-d2); s0=$(state)
out=$("$SALA" retire sala-test-d2 --dry-run 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -q "^\[dry-run\] would refuse: 'sala-test-d2' is not idle: " && echo "$out" | grep -q "pass --busy to retire it anyway" && ! echo "$out" | grep -q "would kill" && ok "would refuse (rc $rc), --busy named, no kill line" || bad "busy dry run: rc=$rc $out"
untouched "$s0" "retire sala-test-d2 --dry-run"
out=$("$SALA" retire sala-test-d2 --dry-run --busy --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "^\[dry-run\] would retire 'sala-test-d2' while it is not idle (" && echo "$out" | grep -q "would kill tmux session 'sala-test-d2'" && ok "--busy --dry-run: the override said, then the kill it would do" || bad "busy --busy dry run: rc=$rc $out"
untouched "$s0" "retire sala-test-d2 --dry-run --busy"
kill -0 "$c" 2>/dev/null && ok "the busy claude still runs" || bad "the busy claude is gone"

echo "== --dry-run on a conversation id"
hand sala-test-r3 "$UR3" sala-test-alias3; c=$(pane_claude sala-test-r3); s0=$(state)
out=$("$SALA" retire --id "$UR3" --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "'$UR3' → CLI registry (name 'sala-test-alias3', pid $c, conversation $UR3) → tmux session 'sala-test-r3'" && echo "$out" | grep -q "would kill tmux session 'sala-test-r3'" && echo "$out" | grep -q "nothing was changed" \
    && ok "the choice, then the would-lines on the resolved session" || bad "resolved dry run: rc=$rc $out"
untouched "$s0" "retire --id $UR3 --dry-run"
tmux has-session -t =sala-test-r3 2>/dev/null && kill -0 "$c" 2>/dev/null && ok "sala-test-r3 and its claude still up" || bad "sala-test-r3 gone"

echo "== an orphan row (no tmux session): retire refuses and names forget-row; forget-row --dry-run names the row and keeps it; forget-row drops it"
ledger_write add sala-test-orph "$UO" sala-test-orph "$HOME/work" >/dev/null 2>&1; printf 'sala-test-orph\tapi\n' >> "$SALA_LANES"; s0=$(state)
for flag in "" --dry-run; do
    out=$("$SALA" retire sala-test-orph $flag 2>&1); rc=$?
    [ "$rc" != 0 ] && echo "$out" | grep -qF "no tmux session 'sala-test-orph', but the pane map still holds a row for it (a leftover): drop it with: sala forget-row sala-test-orph" && ok "retire sala-test-orph $flag: refused (rc $rc), forget-row named" || bad "orphan retire ${flag:-for real}: rc=$rc $out"
    untouched "$s0" "retire sala-test-orph $flag"
done
out=$("$SALA" forget-row sala-test-orph --dry-run 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
[ "$rc" = 0 ] && echo "$out" | grep -q "^\[dry-run\] 'sala-test-orph': no tmux session — would remove its pane-map row from $MAP (tab-separated): sala-test-orph $UO sala-test-orph $HOME/work" \
    && echo "$out" | grep -q "^\[dry-run\] nothing to kill, no /exit, no snapshot, nothing archived" && echo "$out" | grep -q "^\[dry-run\] would drop its lane row (sala-test-orph → api)" && echo "$out" | grep -q "claude --resume $UO" \
    && ok "the orphan's row, lane row and transcript named" || bad "orphan dry run: rc=$rc"
untouched "$s0" "forget-row sala-test-orph --dry-run"
[ -n "$(row sala-test-orph)" ] && ok "the orphan row still there" || bad "the orphan row went in a dry run"
out=$("$SALA" forget-row sala-test-orph 2>&1); rc=$?; [ "$rc" = 0 ] && [ -z "$(row sala-test-orph)" ] && [ -z "$(lane_row sala-test-orph)" ] && echo "$out" | grep -q "^forgot 'sala-test-orph'" && ok "for real: the row and its lane row gone" || bad "orphan forget-row: rc=$rc $out"

echo "== the agent entry: a retire tells stackshot to drop the session's agent entry, once, after it succeeded; fails soft"
# stackshot's client.py, stubbed: logs its arguments (fields split by \x1f) and answers per mode in $HOME/client-mode, as the real one does: exit 0 on
# 200 (ok: line removed; dropped; notlisted), exit 1 with "stackshot: agent not retired [status] reason" on 502 (the page write failed), 422 (the agents block
# cannot be edited), 409 (a rename or retire of the page is in progress) and fail (not reached)
cat > "$HOME/fake-client.py" <<'PY'
import os, sys
home = os.environ["HOME"]
if sys.argv[1:3] == ["get", "roles"]:   # stackshot's roles list (the project fallback): counted apart from the posts; $HOME/roles-client.json is the answer, absent = exit 1
    open(home + "/roles-calls.txt", "a").write("get roles\n")
    if not os.path.exists(home + "/roles-client.json"): print("stackshot: roles not read [0] URLError: <urlopen error [Errno 111] Connection refused>", file=sys.stderr); sys.exit(1)
    sys.stdout.write(open(home + "/roles-client.json").read()); sys.exit(0)
if sys.argv[1:3] in (["get", "state-files"], ["get", "projects-record"]):   # the project record: sala asks stackshot for it first (lib/stackshot_record.py); this stub does not give it, so the file copy is read (tests/recordlive.sh tests the live answer); not counted
    print("stackshot: projects-record not read [0] URLError: <urlopen error [Errno 111] Connection refused>", file=sys.stderr); sys.exit(1)
open(home + "/client-calls.txt", "a").write("\x1f".join(sys.argv[1:]) + "\n")
mode = open(home + "/client-mode").read().strip() if os.path.exists(home + "/client-mode") else "ok"
refused = {"fail": "stackshot: agent not retired [0] URLError: <urlopen error [Errno 111] Connection refused>",
            "409": "stackshot: agent not retired [409] a rename or retire of projects/foo is in progress; try again",
            "422": "stackshot: agent not retired [422] the agents block is in a shape that cannot be edited in place; nothing was changed: remove sala-rq2's line from projects/foo by hand",
            "403": "stackshot: agent not retired [403] projects/foo is a retired page: its agents are not changed",
            "400": "stackshot: agent not retired [400] the name is not a valid agent name",
            "502": "stackshot: agent not retired [502] gbrain refused the page write for projects/foo (revision moved on); the line of sala-rq2 is still on the page: ask again",
            "502tl": "stackshot: agent not retired [502] the line of sala-rq2 is off projects/foo, but the timeline line was not written (" + "gbrain said no, " * 60 + "): TAIL-MARK add the timeline line by hand"}
if mode in refused: print(refused[mode]); sys.exit(1)
print({"ok": '{"result": "line removed"}', "dropped": '{"result": "dropped"}', "notlisted": '{"result": "not listed"}'}.get(mode, mode)); sys.exit(0)
PY
CALLS="$HOME/client-calls.txt"; RLOGF="$SALA_LOG_DIR/salamander-retire.log"; : > "$CALLS"
export SALA_STACKSHOT_CLIENT="$HOME/fake-client.py"
# stackshot's published project record (SALA_PROJECT_RECORD), written <age> seconds ago with one project (projects/foo) and no agents on it: a name that is on no project's map and has
# no project from its row, the side record or the roles list gets "listed nowhere" from it, which is an answer. A record that cannot answer (missing, stale) is the blind case (4c) below.
export SALA_PROJECT_RECORD="$HOME/projects.json"
mkfresh() { python3 - "$1" > "$SALA_PROJECT_RECORD" <<'PY'
import datetime, json, sys
t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=float(sys.argv[1]))
print(json.dumps({"schema": 1, "generated": t.strftime("%Y-%m-%dT%H:%M:%SZ"), "projects": {"prj_1": {"id": "prj_1", "key": "projects/foo", "agents": {}}}, "by_key": {"projects/foo": "prj_1"}}))
PY
}
mkfresh 0
mode() { printf '%s\n' "$1" > "$HOME/client-mode"; }
ncalls() { wc -l < "$CALLS" | tr -d ' '; }
lastcall() { tail -1 "$CALLS" | tr '\037' ' '; }
UQ1=0a000011-0000-4000-8000-000000000091 UQ2=0a000012-0000-4000-8000-000000000092 UQ3=0a000013-0000-4000-8000-000000000093
UQ4=0a000014-0000-4000-8000-000000000094 UQ5=0a000015-0000-4000-8000-000000000095 UQ6=0a000016-0000-4000-8000-000000000096
tagged() {  # <session> <uuid> [project] — a session by hand with a registry row (adopt), tagged with a project unless none is given
    hand "$1" "$2" "$1"; "$SALA" adopt "$1" >/dev/null 2>&1; [ -z "${3:-}" ] || "$SALA" sessions tag "$1" --project "$3" --role front >/dev/null 2>&1; }
mode ok
tagged sala-rq1 "$UQ1" projects/foo; s0=$(state); n0=$(ncalls)
out=$("$SALA" retire sala-rq1 --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -qF "would ask stackshot FIRST, before the pane is closed, to take 'sala-rq1' off projects/foo's agents" && [ "$(ncalls)" = "$n0" ] && ok "--dry-run: says the call it would make, first, makes none" || bad "dry run: rc=$rc calls=$(ncalls) $out"
untouched "$s0" "retire sala-rq1 --dry-run"
out=$("$SALA" retire sala-rq1 --keep-web 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
[ "$rc" = 0 ] && [ "$(ncalls)" = $((n0 + 1)) ] && [ "$(lastcall)" = "post project-agent-retire projects/foo sala-rq1 --sender sala-retire" ] && ok "retire in a project: project-agent-retire called once, with project, name and sender sala-retire" || bad "retire call: rc=$rc calls=$(ncalls) last=$(lastcall)"
a1=$(lineno "$out" "^ℹ stackshot removed 'sala-rq1' from projects/foo's agents (it is off the project record"); a2=$(lineno "$out" "/exit \.\.\."); a3=$(lineno "$out" "^retired 'sala-rq1'; the transcript stays")
[ -n "$a1" ] && [ -n "$a2" ] && [ -n "$a3" ] && [ "$a1" -lt "$a2" ] && [ "$a1" -lt "$a3" ] && ! tmux has-session -t =sala-rq1 2>/dev/null \
    && ok "stackshot's answer comes BEFORE the pane is touched (/exit), then the retire's lines; the session gone" || bad "retire output: $out"
grep -qF "sala-rq1: project-agent-retire projects/foo (label sala-retire) → exit 0: {\"result\": \"line removed\"}" "$RLOGF" && ok "the outcome is a line in salamander-retire.log" || bad "retire log: $(cat "$RLOGF" 2>/dev/null)"

echo "== the agent entry: none of stackshot's answers fails the retire (200 line removed, dropped, not listed; 502 page write failed, 422, 409 in progress); --busy calls too; the label is overridable"
for m in dropped notlisted; do   # the other two 200 answers: said in words (the first, line removed, is the q1 case above)
    mode "$m"; tagged sala-rq2 "$UQ2" projects/foo; n0=$(ncalls)
    out=$("$SALA" retire sala-rq2 --keep-web 2>&1); rc=$?
    case $m in dropped) want="ℹ stackshot dropped 'sala-rq2' from projects/foo (it was only pending" ;; *) want="ℹ 'sala-rq2' is not on projects/foo's agents and not pending in stackshot" ;; esac
    [ "$rc" = 0 ] && [ "$(ncalls)" = $((n0 + 1)) ] && echo "$out" | grep -qF "$want" && ! echo "$out" | grep -q "was not told" && ! tmux has-session -t =sala-rq2 2>/dev/null && ok "answer $m (exit 0): the retire succeeds (rc 0), one call, said in words" || bad "answer $m: rc=$rc calls=$(ncalls) $out"
done
refused_retire() {  # <mode> <status shown> — stackshot refuses: the retire stops (rc 1) with its reason, the pane, the row and the lane are as they were, one call, logged
    local m=$1 st=$2 n0 out rc s1
    kill_wait sala-rq2; mode "$m"; tagged sala-rq2 "$UQ2" projects/foo; n0=$(ncalls); s1=$(state)
    out=$("$SALA" retire sala-rq2 --keep-web 2>&1); rc=$?
    [ "$rc" != 0 ] && [ "$(ncalls)" = $((n0 + 1)) ] && echo "$out" | grep -qF "stackshot refused to take 'sala-rq2' off projects/foo ($st): " && echo "$out" | grep -qF "the pane is left as it is" && ! echo "$out" | grep -q "^retired " \
        && tmux has-session -t =sala-rq2 2>/dev/null && [ -n "$(row sala-rq2)" ] && [ "$(state)" = "$s1" ] && grep -qF "[$st]" "$RLOGF" && ok "answer $m: the retire is REFUSED with stackshot's reason, the pane and the row are left alone, one call, logged" || bad "answer $m: rc=$rc calls=$(ncalls) $out"
    LAST_REFUSAL=$out
}
for m in 422 409; do refused_retire "$m" "$m"; done
refused_retire 502 502
echo "$LAST_REFUSAL" | grep -qF "the line of sala-rq2 is still on the page: ask again" && ok "answer 502: the reason carries stackshot's own next step" || bad "502 reason: $LAST_REFUSAL"
kill_wait sala-rq2; mode 502tl; tagged sala-rq2 "$UQ2" projects/foo; n0=$(ncalls)
out=$("$SALA" retire sala-rq2 --keep-web 2>&1); rc=$?; l=$(echo "$out" | grep "stackshot refused")
[ "$rc" != 0 ] && [ "$(ncalls)" = $((n0 + 1)) ] && echo "$l" | grep -qF "TAIL-MARK add the timeline line by hand" && echo "$l" | grep -qF "…" && [ "${#l}" -lt 1300 ] && tmux has-session -t =sala-rq2 2>/dev/null \
    && grep -qF "TAIL-MARK add the timeline line by hand" "$RLOGF" && ok "a long 502 reason is cut in the middle: its end (the timeline-line hint) is kept in the refusal and in the log; the pane is left" || bad "long 502: rc=$rc len=${#l} $out"
for m in 403 400; do refused_retire "$m" "$m"; done
kill_wait sala-rq2
mode ok; tagged sala-rq2 "$UQ2" projects/foo; n0=$(ncalls)
out=$(SALA_RETIRE_SENDER=sala-test-label "$SALA" retire sala-rq2 --busy --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(ncalls)" = $((n0 + 1)) ] && [ "$(lastcall)" = "post project-agent-retire projects/foo sala-rq2 --sender sala-test-label" ] && ok "--busy retire calls too, with SALA_RETIRE_SENDER as the label" || bad "busy: rc=$rc calls=$(ncalls) last=$(lastcall)"

echo "== the agent entry: a failing client (exit 1) and a missing client.py change nothing about the retire"
kill_wait sala-rq2; mode fail; tagged sala-rq3 "$UQ3" projects/foo; n0=$(ncalls); s1=$(state)
out=$("$SALA" retire sala-rq3 --keep-web 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
[ "$rc" != 0 ] && [ "$(ncalls)" = $((n0 + 1)) ] && echo "$out" | grep -qF "stackshot could not be asked to take 'sala-rq3' off projects/foo (exit 1" && echo "$out" | grep -qF "the pane is left as it is" && tmux has-session -t =sala-rq3 2>/dev/null && [ -n "$(row sala-rq3)" ] && [ "$(state)" = "$s1" ] \
    && grep -q "sala-rq3: project-agent-retire projects/foo (label sala-retire) → exit 1: stackshot: agent not retired" "$RLOGF" \
    && ok "stackshot not reached (exit 1): the retire is REFUSED, the pane and the row are left alone, the failure is said and logged" || bad "failing client: rc=$rc calls=$(ncalls) $out"
# a 200 whose answer is not stackshot's JSON is unreadable: refused too (a retire never goes on on a yes it cannot read)
mode garbled; n0=$(ncalls)
out=$("$SALA" retire sala-rq3 --keep-web 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(ncalls)" = $((n0 + 1)) ] && tmux has-session -t =sala-rq3 2>/dev/null && ok "an answer that is not stackshot's JSON: refused, the pane left" || bad "garbled answer: rc=$rc $out"
# a timeout is a refusal too (the call is cut at SALA_RETIRE_ASK_TIMEOUT; stackshot is asked again on the next retire)
cat > "$HOME/slow-client.py" <<'PY'
import time; time.sleep(30)
PY
n0=$(ncalls); out=$(SALA_STACKSHOT_CLIENT="$HOME/slow-client.py" SALA_RETIRE_ASK_TIMEOUT=2 "$SALA" retire sala-rq3 --keep-web 2>&1); rc=$?
[ "$rc" != 0 ] && tmux has-session -t =sala-rq3 2>/dev/null && ok "stackshot too slow (a timeout): the retire is refused, the pane left" || bad "timeout: rc=$rc $out"
# once stackshot answers again, the same retire goes through: the refusal was no state of its own
mode ok; n0=$(ncalls)
out=$("$SALA" retire sala-rq3 --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(ncalls)" = $((n0 + 1)) ] && ! tmux has-session -t =sala-rq3 2>/dev/null && [ -z "$(row sala-rq3)" ] && ok "asked again once stackshot answers: the retire goes through (one call)" || bad "retry: rc=$rc $out"
mode ok; tagged sala-rq4 "$UQ4" projects/foo; n0=$(ncalls)
out=$(SALA_STACKSHOT_CLIENT="$HOME/nowhere.py" SALA_STACKSHOT_DIR= "$SALA" retire sala-rq4 --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(ncalls)" = "$n0" ] && ! tmux has-session -t =sala-rq4 2>/dev/null && grep -q "sala-rq4: no stackshot client.py on this box" "$RLOGF" && ok "no client.py: the retire is done, one log line, no call" || bad "no client: rc=$rc $out"

echo "== the agent entry: a session with no project makes no call (one log line)"
tagged sala-rq5 "$UQ5"; n0=$(ncalls)
out=$("$SALA" retire sala-rq5 --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(ncalls)" = "$n0" ] && ! echo "$out" | grep -q "stackshot" && ! tmux has-session -t =sala-rq5 2>/dev/null && grep -q "sala-rq5: no project known for it" "$RLOGF" && ok "no project: retired, no call, nothing said, one log line" || bad "no project: rc=$rc calls=$(ncalls) $out"

echo "== the agent entry: a row without a project (what migrate imported) takes the project from stackshot's roles list: the client first, the file when the client gives none"
NROLES() { [ -f "$HOME/roles-calls.txt" ] && wc -l < "$HOME/roles-calls.txt" | tr -d ' ' || echo 0; }
UQ7=0a000017-0000-4000-8000-000000000097 UQ8=0a000018-0000-4000-8000-000000000098 UQ9=0a000019-0000-4000-8000-000000000099
# (a) the row has a project: the roles list is not read
mode ok; r0=$(NROLES); tagged sala-rq1 "$UQ1" projects/foo; n0=$(ncalls)
out=$("$SALA" retire sala-rq1 --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(NROLES)" = "$r0" ] && [ "$(lastcall)" = "post project-agent-retire projects/foo sala-rq1 --sender sala-retire" ] && grep -qF "sala-rq1: its project projects/foo came from its registry row" "$RLOGF" \
    && ok "(a) project on the row: used, source logged, the roles list not read" || bad "(a) rc=$rc roles-reads=$(NROLES) last=$(lastcall) $out"
# (b) no project on the row, the client's roles list gives one
printf '%s\n' '{"generated": "2026-10-31T00:00:00Z", "sessions": {"sala-rq7": {"project": "projects/bar", "role": "front"}, "sala-test-other": {"project": "projects/baz"}}}' > "$HOME/roles-client.json"
tagged sala-rq7 "$UQ7"; n0=$(ncalls); r0=$(NROLES)
out=$("$SALA" retire sala-rq7 --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -qF "would ask stackshot FIRST, before the pane is closed, to take 'sala-rq7' off projects/bar's agents" && [ "$(ncalls)" = "$n0" ] && ok "(b) --dry-run: the roles list's project is the one it would tell" || bad "(b) dry run: rc=$rc $out"
out=$("$SALA" retire sala-rq7 --keep-web 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
[ "$rc" = 0 ] && [ "$(ncalls)" = $((n0 + 1)) ] && [ "$(lastcall)" = "post project-agent-retire projects/bar sala-rq7 --sender sala-retire" ] && ! tmux has-session -t =sala-rq7 2>/dev/null \
    && grep -qF "sala-rq7: its project projects/bar came from stackshot's roles list (client.py get roles)" "$RLOGF" && ! grep -q "sala-rq7: no project known" "$RLOGF" \
    && ok "(b) no project on the row: stackshot asked with the roles list's project, the source logged" || bad "(b) rc=$rc calls=$(ncalls) last=$(lastcall) log=$(grep sala-rq7 "$RLOGF")"
# (d) the client gives nothing (exit 1), the file does
rm -f "$HOME/roles-client.json"; printf '%s\n' '{"sessions": {"sala-rq8": {"project": "projects/qux", "retired": true}}}' > "$HOME/roles-file.json"
tagged sala-rq8 "$UQ8"; n0=$(ncalls)
out=$(SALA_ROLES_FILE="$HOME/roles-file.json" "$SALA" retire sala-rq8 --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(ncalls)" = $((n0 + 1)) ] && [ "$(lastcall)" = "post project-agent-retire projects/qux sala-rq8 --sender sala-retire" ] \
    && grep -qF "sala-rq8: its project projects/qux came from stackshot's roles list (the file copy: stackshot did not answer (" "$RLOGF" && grep -F "sala-rq8: its project" "$RLOGF" | grep -qF "the file copy $HOME/roles-file.json is " && ok "(d) client failing: the roles file's project used, source logged with the copy's age" || bad "(d) rc=$rc calls=$(ncalls) last=$(lastcall) $out"
# (c) neither gives one: the client fails, the file is bad JSON / lacks the name / is missing: today's line, no call, the retire done
printf '%s\n' '{"sessions": {"sala-rq9": ' > "$HOME/roles-bad.json"
for f in "$HOME/roles-bad.json" "$HOME/roles-file.json" "$HOME/no-such-roles.json"; do
    tagged sala-rq9 "$UQ9"; n0=$(ncalls); l0=$(wc -l < "$RLOGF")
    out=$(SALA_ROLES_FILE="$f" "$SALA" retire sala-rq9 --keep-web 2>&1); rc=$?
    [ "$rc" = 0 ] && [ "$(ncalls)" = "$n0" ] && ! echo "$out" | grep -q "stackshot" && ! tmux has-session -t =sala-rq9 2>/dev/null && [ -z "$(row sala-rq9)" ] \
        && tail -n +$((l0 + 1)) "$RLOGF" | grep -q "sala-rq9: no project known for it" && ok "(c) client failing, roles file $(basename "$f"): no project, no call, the retire done, today's log line" || bad "(c) $f: rc=$rc calls=$(ncalls) $out"
done
# the client answering a name the list lacks, and a roles list with no project for it, are no project either
printf '%s\n' '{"sessions": {"sala-rq9": {"role": "front"}}}' > "$HOME/roles-client.json"
tagged sala-rq9 "$UQ9"; n0=$(ncalls); l0=$(wc -l < "$RLOGF")
out=$(SALA_ROLES_FILE="$HOME/no-such-roles.json" "$SALA" retire sala-rq9 --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(ncalls)" = "$n0" ] && tail -n +$((l0 + 1)) "$RLOGF" | grep -q "sala-rq9: no project known for it" && ok "(c) the list names the session but gives no project: today's line, no call" || bad "(c) no project in the list: rc=$rc $out"
rm -f "$HOME/roles-client.json"

echo "== the agent entry: forget-row of an orphan row calls too (its registry row's project)"
ledger_write add sala-rq6 "$UQ6" sala-rq6 "$HOME/work" >/dev/null 2>&1; "$SALA" sessions tag sala-rq6 --project projects/foo --role front >/dev/null 2>&1; n0=$(ncalls); s0=$(state)
out=$("$SALA" forget-row sala-rq6 --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -qF "would tell stackshot to drop 'sala-rq6' from projects/foo's agents" && [ "$(ncalls)" = "$n0" ] && ok "orphan --dry-run: the call said, none made" || bad "orphan dry run: rc=$rc $out"
untouched "$s0" "forget-row sala-rq6 --dry-run"
out=$("$SALA" forget-row sala-rq6 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$(row sala-rq6)" ] && [ "$(ncalls)" = $((n0 + 1)) ] && echo "$out" | grep -q "^ℹ stackshot removed 'sala-rq6' from projects/foo's agents" && ok "orphan forget-row: row gone, one call after it" || bad "orphan forget-row: rc=$rc calls=$(ncalls) $out"

echo "== the agent entry: asked once, and FIRST (no second call after the pane is gone); a 404 and not listed go on; the closed exceptions are not asked"
mode ok; : > "$CALLS"; kill_wait sala-rq2
tagged sala-rq2 "$UQ2" projects/foo
out=$("$SALA" retire sala-rq2 --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(ncalls)" = 1 ] && ok "a retire makes exactly one project-agent-retire call (not asked again after the pane is gone)" || bad "one call: rc=$rc calls=$(ncalls) $out"
# the pane still exists when stackshot is asked: the fake records it
cat > "$HOME/order-client.py" <<'PY'
import os, subprocess, sys
home = os.environ["HOME"]
r = subprocess.run(["tmux", "-S", os.environ["SALA_TMUX_SOCKET"], "has-session", "-t", "=sala-rq2"], capture_output=True)
open(home + "/order.txt", "a").write("pane-existed\n" if r.returncode == 0 else "pane-gone\n")
print('{"result": "line removed"}')
PY
rm -f "$HOME/order.txt"; tagged sala-rq2 "$UQ2" projects/foo
out=$(SALA_STACKSHOT_CLIENT="$HOME/order-client.py" "$SALA" retire sala-rq2 --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(cat "$HOME/order.txt" 2>/dev/null)" = pane-existed ] && ! tmux has-session -t =sala-rq2 2>/dev/null && ok "stackshot is asked while the pane still exists (retire asks first), and the pane is closed after the answer" || bad "order: rc=$rc order=$(cat "$HOME/order.txt" 2>/dev/null) $out"
# a refusal leaves the pane in place: the same stub, refusing
cat > "$HOME/order-refuse.py" <<'PY'
import os, subprocess, sys
home = os.environ["HOME"]
r = subprocess.run(["tmux", "-S", os.environ["SALA_TMUX_SOCKET"], "has-session", "-t", "=sala-rq2"], capture_output=True)
open(home + "/order.txt", "a").write("pane-existed\n" if r.returncode == 0 else "pane-gone\n")
print("stackshot: agent not retired [409] in progress"); sys.exit(1)
PY
rm -f "$HOME/order.txt"; tagged sala-rq2 "$UQ2" projects/foo; c=$(pane_claude sala-rq2)
out=$(SALA_STACKSHOT_CLIENT="$HOME/order-refuse.py" "$SALA" retire sala-rq2 --keep-web 2>&1); rc=$?
[ "$rc" != 0 ] && tmux has-session -t =sala-rq2 2>/dev/null && kill -0 "$c" 2>/dev/null && ok "a refusal leaves the claude running and the pane open (it was not even sent /exit)" || bad "refusal left the pane: rc=$rc $out"
# not listed and a 404 (no such project) go on
for m in notlisted; do
    mode "$m"; n0=$(ncalls); out=$("$SALA" retire sala-rq2 --keep-web 2>&1); rc=$?
    [ "$rc" = 0 ] && [ "$(ncalls)" = $((n0 + 1)) ] && ! tmux has-session -t =sala-rq2 2>/dev/null && ok "answer $m: the retire goes on" || bad "answer $m: rc=$rc $out"
done
cat > "$HOME/c404.py" <<'PY'
import sys
print("stackshot: agent not retired [404] no such project projects/foo"); sys.exit(1)
PY
tagged sala-rq2 "$UQ2" projects/foo
out=$(SALA_STACKSHOT_CLIENT="$HOME/c404.py" "$SALA" retire sala-rq2 --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -qF "stackshot has no project projects/foo (404" && ! tmux has-session -t =sala-rq2 2>/dev/null && ok "a 404 (no such project): the retire goes on, said in words" || bad "404: rc=$rc $out"
# the exceptions: a throwaway's name, a side session; stackshot is not asked even when it would refuse
mode 409; n0=$(ncalls)
hand sala-test-thrw "$UQ4" sala-test-thrw; "$SALA" adopt sala-test-thrw >/dev/null 2>&1; "$SALA" sessions tag sala-test-thrw --project projects/foo --role front >/dev/null 2>&1
out=$("$SALA" retire sala-test-thrw --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(ncalls)" = "$n0" ] && echo "$out" | grep -qF "stackshot is not asked about 'sala-test-thrw'" && ! tmux has-session -t =sala-test-thrw 2>/dev/null && ok "exception: a throwaway's name (*-test-*): stackshot is not asked, the retire goes on" || bad "exception throwaway: rc=$rc calls=$(ncalls) $out"
out=$("$SALA" retire sala-test-thrw --dry-run 2>&1); true
hand sala-rq-side-wren "$UQ5" sala-rq-side-wren; "$SALA" adopt sala-rq-side-wren >/dev/null 2>&1; "$SALA" sessions tag sala-rq-side-wren --project projects/foo --role front >/dev/null 2>&1
out=$("$SALA" retire sala-rq-side-wren --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(ncalls)" = "$n0" ] && ! tmux has-session -t =sala-rq-side-wren 2>/dev/null && ok "exception: a side session: stackshot is not asked, the retire goes on" || bad "exception side: rc=$rc calls=$(ncalls) $out"
mode ok

echo "== a retire that asked stackshot revalidates BEFORE it types /exit: a pane that became busy while stackshot answered, or a session that replaced it under the same name, is left alone"
UQ10=0a00001a-0000-4000-8000-0000000000a0 UQ11=0a00001b-0000-4000-8000-0000000000a1 UQ12=0a00001c-0000-4000-8000-0000000000a2
cat > "$HOME/mid-client.py" <<'PY'
import glob, os, re, subprocess, sys
home = os.environ["HOME"]; mode = os.environ.get("MID_MODE", ""); name = sys.argv[4]
open(home + "/client-calls.txt", "a").write("\x1f".join(sys.argv[1:]) + "\n")
if mode == "busy":   # the stackshot call takes long: meanwhile a turn starts in the pane
    for f in glob.glob(home + "/.claude/sessions/*.json"):
        t = open(f).read()
        if '"name":"%s"' % name in t: open(f, "w").write(re.sub(r'"status":"[a-z]*"', '"status":"busy"', t, count=1))
elif mode == "replace":   # the session is closed by someone else and another one takes its name
    sock = os.environ["SALA_TMUX_SOCKET"]
    subprocess.run(["tmux", "-S", sock, "kill-session", "-t", "=" + name])
    subprocess.run(["tmux", "-S", sock, "new-session", "-d", "-s", name, "-c", home + "/work", "-e", "FAKE_SESSION_ID=" + os.environ["MID_UUID"], "-e", "FAKE_NAME=" + name, "-e", "FAKE_LOG=" + os.environ["FAKE_LOG"]])
    subprocess.run(["tmux", "-S", sock, "send-keys", "-t", "=" + name, "claude", "Enter"])
print('{"result": "line removed"}')
PY
mode ok; : > "$CALLS"; tagged sala-rq10 "$UQ10" projects/foo; c=$(pane_claude sala-rq10)
out=$(SALA_STACKSHOT_CLIENT="$HOME/mid-client.py" MID_MODE=busy "$SALA" retire sala-rq10 --keep-web 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
[ "$rc" != 0 ] && [ "$(ncalls)" = 1 ] && tmux has-session -t =sala-rq10 2>/dev/null && kill -0 "$c" 2>/dev/null && ! grep -q "^exit $UQ10" "$FAKE_LOG" && ! echo "$out" | grep -q "/exit \.\.\." && echo "$out" | grep -qF "'sala-rq10' is not idle any more" \
    && echo "$out" | grep -qF "the pane is left as it is" && echo "$out" | grep -qF "stackshot has already taken it off projects/foo's record" && echo "$out" | grep -qF "a retry is safe" && [ -n "$(row sala-rq10)" ] \
    && ok "a pane that became busy during the ask: no /exit, no kill, the row kept, the message says the record is already off and a retry is safe" || bad "busy after the ask: rc=$rc calls=$(ncalls) $out"
set_reg_status "$c" idle; n0=$(ncalls)
out=$("$SALA" retire sala-rq10 --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(ncalls)" = $((n0 + 1)) ] && ! tmux has-session -t =sala-rq10 2>/dev/null && ok "the retry once it is idle: asked again (idempotent on stackshot's side), retired" || bad "retry after busy: rc=$rc $out"
: > "$CALLS"; tagged sala-rq11 "$UQ11" projects/foo; s0=$(state)
out=$(SALA_STACKSHOT_CLIENT="$HOME/mid-client.py" MID_MODE=replace MID_UUID="$UQ12" "$SALA" retire sala-rq11 --keep-web 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
waitfor "reg_live '\"sessionId\":\"$UQ12\"'" 40 || echo "  (the replacement fake did not come up)"
[ "$rc" != 0 ] && [ "$(ncalls)" = 1 ] && tmux has-session -t =sala-rq11 2>/dev/null && ! grep -q "^exit $UQ12" "$FAKE_LOG" && ! echo "$out" | grep -q "/exit \.\.\." && ! echo "$out" | grep -q "tmux session killed" \
    && echo "$out" | grep -qF "'sala-rq11' is not the session this retire started on" && echo "$out" | grep -qF "stackshot has already taken it off projects/foo's record" \
    && ok "a session that replaced it under the same name during the ask: left alone (no /exit, no kill), the message says so" || bad "replaced during the ask: rc=$rc calls=$(ncalls) $out"
kill_wait sala-rq11

echo "== a plain spawn registered by name has no project on its registry row and no roles entry yet: the project RECORD's agents map gives the project, so the entry is taken off"
python3 - "$HOME/rec.json" <<'PY'
import datetime, json, sys
def agents(*ns): return {n: {"front": False, "role": n.rsplit("-", 1)[-1], "mandate_line": "m"} for n in ns}
t = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"schema": 1, "generated": t, "by_key": {"projects/foo": "prj_1", "projects/bar": "prj_2"},
           "projects": {"prj_1": {"id": "prj_1", "key": "projects/foo", "agents": agents("sala-rq13", "sala-rq14")}, "prj_2": {"id": "prj_2", "key": "projects/bar", "agents": agents("sala-rq14")}}}, open(sys.argv[1], "w"))
PY
UQ13=0a00001d-0000-4000-8000-0000000000a3 UQ14=0a00001e-0000-4000-8000-0000000000a4
mode ok; rm -f "$HOME/roles-client.json"; : > "$CALLS"; tagged sala-rq13 "$UQ13"; n0=$(ncalls)
out=$(SALA_PROJECT_RECORD="$HOME/rec.json" SALA_ROLES_FILE="$HOME/no-such-roles.json" "$SALA" retire sala-rq13 --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -qF "would ask stackshot FIRST, before the pane is closed, to take 'sala-rq13' off projects/foo's agents" && [ "$(ncalls)" = "$n0" ] && ok "--dry-run: the project the record gives is the one it would ask" || bad "record project dry run: rc=$rc $out"
out=$(SALA_PROJECT_RECORD="$HOME/rec.json" SALA_ROLES_FILE="$HOME/no-such-roles.json" "$SALA" retire sala-rq13 --keep-web 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
[ "$rc" = 0 ] && [ "$(ncalls)" = $((n0 + 1)) ] && [ "$(lastcall)" = "post project-agent-retire projects/foo sala-rq13 --sender sala-retire" ] && ! tmux has-session -t =sala-rq13 2>/dev/null \
    && grep -qF "sala-rq13: its project projects/foo came from stackshot's project record (the name is on its agents map)" "$RLOGF" && ! grep -q "sala-rq13: no project known" "$RLOGF" \
    && ok "no project on the row, none in the roles list: the project record's agents map gives it, stackshot is asked, the source logged" || bad "record project: rc=$rc calls=$(ncalls) last=$(lastcall) log=$(grep sala-rq13 "$RLOGF")"
# a name on the agents maps of two projects: no guess, no call; the retire is done as before and the log says why
tagged sala-rq14 "$UQ14"; n0=$(ncalls); l0=$(wc -l < "$RLOGF")
out=$(SALA_PROJECT_RECORD="$HOME/rec.json" SALA_ROLES_FILE="$HOME/no-such-roles.json" "$SALA" retire sala-rq14 --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(ncalls)" = "$n0" ] && ! tmux has-session -t =sala-rq14 2>/dev/null && tail -n +$((l0 + 1)) "$RLOGF" | grep -qF "sala-rq14: no project known for it (listed on projects/bar and projects/foo" && ok "a name on two projects' maps: stackshot is not asked (no guess), the log names both" || bad "ambiguous record: rc=$rc calls=$(ncalls) $out $(tail -n +$((l0 + 1)) "$RLOGF")"


echo "== (4a, 4b) after stackshot answered, a second claude in another pane, or a registry row that lost its conversation, leaves the pane alone (the record is already off: a retry is safe)"
UQ15=0a00001f-0000-4000-8000-0000000000a5 UQ16=0a000020-0000-4000-8000-0000000000a6 UQ17=0a000021-0000-4000-8000-0000000000a7 UQ18=0a000022-0000-4000-8000-0000000000a8
cat > "$HOME/mid2-client.py" <<'PY'
import glob, os, re, subprocess, sys, time
home = os.environ["HOME"]; mode = os.environ.get("MID_MODE", ""); name = sys.argv[4]; sock = os.environ["SALA_TMUX_SOCKET"]
open(home + "/client-calls.txt", "a").write("\x1f".join(sys.argv[1:]) + "\n")
if mode == "pane":   # a second claude starts in a new window of the same tmux session while stackshot answers
    subprocess.run(["tmux", "-S", sock, "new-window", "-d", "-t", "=" + name + ":", "-c", home + "/work", "-e", "FAKE_SESSION_ID=" + os.environ["MID_UUID"], "-e", "FAKE_NAME=" + name + "-b", "-e", "FAKE_LOG=" + os.environ["FAKE_LOG"], "claude"])
    for _ in range(100):
        o = subprocess.run(["tmux", "-S", sock, "list-panes", "-s", "-t", "=" + name + ":", "-F", "#{pane_current_command}"], capture_output=True, text=True).stdout
        if o.split().count("claude") >= 2: break
        time.sleep(0.1)
    time.sleep(1)
elif mode == "noconv":   # the registry row of the session loses its conversation id while stackshot answers
    for f in glob.glob(home + "/.claude/sessions/*.json"):
        t = open(f).read()
        if '"name":"%s"' % name in t: open(f, "w").write(re.sub(r'"sessionId":"[^"]*"', '"sessionId":""', t, count=1))
print('{"result": "line removed"}')
PY
mode ok; : > "$CALLS"; mkfresh 0; tagged sala-rq15 "$UQ15" projects/foo; c=$(pane_claude sala-rq15)
out=$(SALA_STACKSHOT_CLIENT="$HOME/mid2-client.py" MID_MODE=pane MID_UUID="$UQ16" "$SALA" retire sala-rq15 --keep-web 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
waitfor "reg_live '\"sessionId\":\"$UQ16\"'" 40 || echo "  (the second fake did not come up)"
[ "$rc" != 0 ] && [ "$(ncalls)" = 1 ] && tmux has-session -t =sala-rq15 2>/dev/null && kill -0 "$c" 2>/dev/null && ! grep -q "^exit $UQ15" "$FAKE_LOG" && ! grep -q "^exit $UQ16" "$FAKE_LOG" && ! echo "$out" | grep -q "/exit \.\.\." && ! echo "$out" | grep -q "tmux session killed" \
    && echo "$out" | grep -qF "another pane of it now runs a claude" && echo "$out" | grep -qF "the pane is left as it is" && echo "$out" | grep -qF "stackshot has already taken it off projects/foo's record" && echo "$out" | grep -qF "a retry is safe" && [ -n "$(row sala-rq15)" ] \
    && ok "(4a) a second claude in another pane after the ask: no /exit, no kill, both claudes alive, the row kept, the message names the pane and says the record is already off" || bad "(4a) rc=$rc calls=$(ncalls) $out"
kill_wait sala-rq15
mode ok; : > "$CALLS"; tagged sala-rq16 "$UQ17" projects/foo; c=$(pane_claude sala-rq16)
out=$(SALA_STACKSHOT_CLIENT="$HOME/mid2-client.py" MID_MODE=noconv "$SALA" retire sala-rq16 --keep-web 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
[ "$rc" != 0 ] && [ "$(ncalls)" = 1 ] && tmux has-session -t =sala-rq16 2>/dev/null && kill -0 "$c" 2>/dev/null && ! grep -q "^exit $UQ17" "$FAKE_LOG" && ! echo "$out" | grep -q "/exit \.\.\." \
    && echo "$out" | grep -qF "can no longer be read from the registry row" && echo "$out" | grep -qF "stackshot has already taken it off projects/foo's record" && [ -n "$(row sala-rq16)" ] \
    && ok "(4b) a registry row that gave its conversation at the start and gives none after the ask: left alone, no /exit, the row kept, said" || bad "(4b) rc=$rc calls=$(ncalls) $out"
kill_wait sala-rq16
# the control: a conversation the registry never gave (known only from the pane map) is no change: the retire goes on
tagged sala-rq16 "$UQ17" projects/foo
for f in "$HOME"/.claude/sessions/*.json; do grep -q '"name":"sala-rq16"' "$f" && sed -i 's/"sessionId":"[^"]*"/"sessionId":""/' "$f"; done
: > "$CALLS"; out=$("$SALA" retire sala-rq16 --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(ncalls)" = 1 ] && ! tmux has-session -t =sala-rq16 2>/dev/null && ok "(4b control) a registry row with no conversation from the start (the id only in the pane map): not a change, the retire goes on" || bad "(4b control) rc=$rc calls=$(ncalls) $out"

echo "== (4c) no project is known for a name and stackshot's project record cannot answer: loud (a warning, a log line, a dry-run line) and the retire goes on; a record that lists it nowhere, an exempt name and a box with no stackshot stay quiet"
UQ19=0a000023-0000-4000-8000-0000000000a9 UQ20=0a000024-0000-4000-8000-0000000000aa UQ21=0a000025-0000-4000-8000-0000000000ab
for how in missing stale; do
    case "$how" in missing) rm -f "$SALA_PROJECT_RECORD" ;; stale) mkfresh 3600 ;; esac
    tagged sala-rq19 "$UQ19"; : > "$CALLS"; l0=$(wc -l < "$RLOGF"); s0=$(state)
    out=$(SALA_ROLES_FILE="$HOME/no-such-roles.json" "$SALA" retire sala-rq19 --dry-run 2>&1); rc=$?
    [ "$rc" = 0 ] && echo "$out" | grep -qF "would WARN, not refuse: stackshot cannot be asked to take 'sala-rq19' off a project" && ok "(4c) record $how, --dry-run: the warning said, nothing refused" || bad "(4c) dry run, record $how: rc=$rc $out"
    untouched "$s0" "retire sala-rq19 --dry-run (record $how)"
    out=$(SALA_ROLES_FILE="$HOME/no-such-roles.json" "$SALA" retire sala-rq19 --keep-web 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
    [ "$rc" = 0 ] && [ "$(ncalls)" = 0 ] && ! tmux has-session -t =sala-rq19 2>/dev/null && echo "$out" | grep -qF "⚠ stackshot was NOT asked to take 'sala-rq19' off a project: no project is known for it and stackshot's project record cannot say which project lists it" && echo "$out" | grep -qF "post project-agent-retire <project page key> sala-rq19" \
        && tail -n +$((l0 + 1)) "$RLOGF" | grep -qF "sala-rq19: WARNING: the retire goes on although stackshot's project record could not say whether 'sala-rq19' is on a project" \
        && ok "(4c) record $how: the retire goes on, no call, a ⚠ line on stdout with the command to run later, a WARNING line in the retire log" || bad "(4c) record $how: rc=$rc calls=$(ncalls) $out"
done
mkfresh 0
tagged sala-rq19 "$UQ19"; : > "$CALLS"; l0=$(wc -l < "$RLOGF")
out=$(SALA_ROLES_FILE="$HOME/no-such-roles.json" "$SALA" retire sala-rq19 --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && ! echo "$out" | grep -qF "NOT asked" && ! tail -n +$((l0 + 1)) "$RLOGF" | grep -qF "WARNING" && ok "(4c control) a fresh record that lists the name nowhere is an answer: no warning" || bad "(4c control) rc=$rc $out"
rm -f "$SALA_PROJECT_RECORD"
hand sala-test-blind "$UQ20" sala-test-blind; "$SALA" adopt sala-test-blind >/dev/null 2>&1; : > "$CALLS"
out=$(SALA_ROLES_FILE="$HOME/no-such-roles.json" "$SALA" retire sala-test-blind --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && ! echo "$out" | grep -qF "NOT asked" && ok "(4c exempt) a throwaway's name (*-test-*) with no record: no warning (the gate does not apply to it)" || bad "(4c exempt) rc=$rc $out"
tagged sala-rq19 "$UQ19"; : > "$CALLS"
out=$(SALA_STACKSHOT_CLIENT="$HOME/nowhere.py" SALA_STACKSHOT_DIR= SALA_ROLES_FILE="$HOME/no-such-roles.json" "$SALA" retire sala-rq19 --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && ! echo "$out" | grep -qF "NOT asked" && ok "(4c no stackshot) no record and no client: a box with no stackshot has nothing to be blind to, no warning" || bad "(4c no stackshot) rc=$rc $out"
# a session with no agent role (spawn --role none: the row's no_role mark) is exempt from the agent gate: no call to stackshot, no warning, also with no record
UQ22=0a000026-0000-4000-8000-0000000000ac UQ23=0a000027-0000-4000-8000-0000000000ad
tagged sala-rq22 "$UQ22"; sessions_set sala-rq22 project=projects/foo no_role=1 >/dev/null 2>&1; : > "$CALLS"
out=$(SALA_ROLES_FILE="$HOME/no-such-roles.json" "$SALA" retire sala-rq22 --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -qF "would not ask stackshot to drop 'sala-rq22' from projects/foo's agents: it is a session with no agent role" && ok "(4c no_role) --dry-run: says stackshot is not asked, the reason named" || bad "(4c no_role) dry run: rc=$rc $out"
out=$(SALA_ROLES_FILE="$HOME/no-such-roles.json" "$SALA" retire sala-rq22 --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(ncalls)" = 0 ] && ! tmux has-session -t =sala-rq22 2>/dev/null && ! echo "$out" | grep -qF "NOT asked" && ok "(4c no_role) retire: goes on, stackshot is not called, no warning" || bad "(4c no_role) rc=$rc calls=$(ncalls) $out"
# the control: the same row with a role is an agent, and stackshot is asked
mode ok; tagged sala-rq23 "$UQ23" projects/foo; : > "$CALLS"
out=$("$SALA" retire sala-rq23 --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(ncalls)" = 1 ] && ok "(4c no_role control) a row with a role: stackshot is called once" || bad "(4c no_role control) rc=$rc calls=$(ncalls) $out"
# forget-row of an orphan row: the same warning, in the dry run and for real
ledger_write add sala-rq21 "$UQ21" sala-rq21 "$HOME/work" >/dev/null 2>&1; : > "$CALLS"
out=$(SALA_ROLES_FILE="$HOME/no-such-roles.json" "$SALA" forget-row sala-rq21 --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -qF "would WARN, not refuse: stackshot cannot be asked to take 'sala-rq21' off a project" && [ -n "$(row sala-rq21)" ] && ok "(4c forget-row) --dry-run: the warning said, the row kept" || bad "(4c forget-row dry) rc=$rc $out"
out=$(SALA_ROLES_FILE="$HOME/no-such-roles.json" "$SALA" forget-row sala-rq21 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$(row sala-rq21)" ] && [ "$(ncalls)" = 0 ] && echo "$out" | grep -qF "⚠ stackshot was NOT asked to take 'sala-rq21' off a project" && ok "(4c forget-row) real: the row forgotten, a ⚠ line says stackshot was not asked" || bad "(4c forget-row) rc=$rc calls=$(ncalls) $out"
# the same orphan row with the no_role mark: no warning (the gate does not apply to it)
UQ24=0a000028-0000-4000-8000-0000000000ae
ledger_write add sala-rq24 "$UQ24" sala-rq24 "$HOME/work" >/dev/null 2>&1; sessions_set sala-rq24 no_role=1 >/dev/null 2>&1; : > "$CALLS"
out=$(SALA_ROLES_FILE="$HOME/no-such-roles.json" "$SALA" forget-row sala-rq24 --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && ! echo "$out" | grep -qF "would WARN" && [ -n "$(row sala-rq24)" ] && ok "(4c forget-row no_role) --dry-run: no warning, the row kept" || bad "(4c forget-row no_role dry) rc=$rc $out"
out=$(SALA_ROLES_FILE="$HOME/no-such-roles.json" "$SALA" forget-row sala-rq24 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$(row sala-rq24)" ] && ! echo "$out" | grep -qF "NOT asked" && ok "(4c forget-row no_role) real: the row forgotten, no warning" || bad "(4c forget-row no_role) rc=$rc $out"
mkfresh 0

[ "$fail" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
