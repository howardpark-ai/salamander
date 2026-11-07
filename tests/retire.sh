#!/usr/bin/env bash
# `sala retire` (Claude sessions only, by the exact tmux session name or by --id), and the two verbs it was split from (Sun Nov 1st 2026): the registry
# resolving a conversation id (or its prefix, 8+ hex) with --id to its tmux session and pane, said before anything is done; a registry name no longer a
# name (refused, --id named); an ambiguous id (two live rows, a prefix on several, a session that also holds another live claude) refused with the
# candidates and nothing touched; a dead row or one without a tmux pane not acted on; `--dry-run` in every form touching nothing; an orphan row refused by
# retire (forget-row named) and dropped by `forget-row`; the master guard on the resolved name. The last sections: a successful retire tells stackshot to take the session off its project (a stub
# client.py: called once with project, name and sender sala-retire; not in --dry-run; stackshot's answers since its page-write release: 200 line
# removed / dropped / not listed, said in words; 502 (the page write failed), 422 and 409 (in progress) said and logged; a failing client or a missing
# one, or a session with no project, changes nothing about the retire). The guardrails (--busy, --skip-writeup, --self, --leave-items, close-shell) are tests/retire-verbs.sh's.
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
as_op_unit   # no master: the guarded verbs this suite runs itself stand for the queue's runner (tests/lib.sh, 5)
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

echo "== the master guard reads the resolved name (--id)"
hand sala-test-mst "$UM" sala-test-mstname; c=$(pane_claude sala-test-mst); s0=$(state)
out=$(SALA_MASTER=sala-test-mst "$SALA" retire --id "$UM" 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -q "'sala-test-mst' is the master session the watchdog keeps alive" && kill -0 "$c" 2>/dev/null && ok "refused by the resolved tmux session's name, the master left alone" || bad "master by conversation id: rc=$rc $out"
untouched "$s0" "retire --id <master's conversation>"

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
open(home + "/client-calls.txt", "a").write("\x1f".join(sys.argv[1:]) + "\n")
mode = open(home + "/client-mode").read().strip() if os.path.exists(home + "/client-mode") else "ok"
refused = {"fail": "stackshot: agent not retired [0] URLError: <urlopen error [Errno 111] Connection refused>",
            "409": "stackshot: agent not retired [409] a rename or retire of projects/foo is in progress; try again",
            "422": "stackshot: agent not retired [422] the agents block is in a shape that cannot be edited in place; nothing was changed: remove sala-test-q2's line from projects/foo by hand",
            "502": "stackshot: agent not retired [502] gbrain refused the page write for projects/foo (revision moved on); the line of sala-test-q2 is still on the page: ask again",
            "502tl": "stackshot: agent not retired [502] the line of sala-test-q2 is off projects/foo, but the timeline line was not written (" + "gbrain said no, " * 60 + "): TAIL-MARK add the timeline line by hand"}
if mode in refused: print(refused[mode]); sys.exit(1)
print({"ok": '{"result": "line removed"}', "dropped": '{"result": "dropped"}', "notlisted": '{"result": "not listed"}'}.get(mode, mode)); sys.exit(0)
PY
CALLS="$HOME/client-calls.txt"; RLOGF="$SALA_LOG_DIR/salamander-retire.log"; : > "$CALLS"
export SALA_STACKSHOT_CLIENT="$HOME/fake-client.py"
mode() { printf '%s\n' "$1" > "$HOME/client-mode"; }
ncalls() { wc -l < "$CALLS" | tr -d ' '; }
lastcall() { tail -1 "$CALLS" | tr '\037' ' '; }
UQ1=0a000011-0000-4000-8000-000000000091 UQ2=0a000012-0000-4000-8000-000000000092 UQ3=0a000013-0000-4000-8000-000000000093
UQ4=0a000014-0000-4000-8000-000000000094 UQ5=0a000015-0000-4000-8000-000000000095 UQ6=0a000016-0000-4000-8000-000000000096
tagged() {  # <session> <uuid> [project] — a session by hand with a registry row (adopt), tagged with a project unless none is given
    hand "$1" "$2" "$1"; "$SALA" adopt "$1" >/dev/null 2>&1; [ -z "${3:-}" ] || "$SALA" sessions tag "$1" --project "$3" --role front >/dev/null 2>&1; }
mode ok
tagged sala-test-q1 "$UQ1" projects/foo; s0=$(state); n0=$(ncalls)
out=$("$SALA" retire sala-test-q1 --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -qF "would tell stackshot to drop 'sala-test-q1' from projects/foo's agents" && [ "$(ncalls)" = "$n0" ] && ok "--dry-run: says the call it would make, makes none" || bad "dry run: rc=$rc calls=$(ncalls) $out"
untouched "$s0" "retire sala-test-q1 --dry-run"
out=$("$SALA" retire sala-test-q1 --keep-web 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
[ "$rc" = 0 ] && [ "$(ncalls)" = $((n0 + 1)) ] && [ "$(lastcall)" = "post project-agent-retire projects/foo sala-test-q1 --sender sala-retire" ] && ok "retire in a project: project-agent-retire called once, with project, name and sender sala-retire" || bad "retire call: rc=$rc calls=$(ncalls) last=$(lastcall)"
echo "$out" | grep -q "^retired 'sala-test-q1'; the transcript stays" && echo "$out" | grep -qF "ℹ stackshot removed 'sala-test-q1' from projects/foo's agents (its line is off the page" && ! tmux has-session -t =sala-test-q1 2>/dev/null \
    && ok "the retire's line first, then stackshot's answer; the session gone" || bad "retire output: $out"
grep -qF "sala-test-q1: project-agent-retire projects/foo (label sala-retire) → exit 0: {\"result\": \"line removed\"}" "$RLOGF" && ok "the outcome is a line in salamander-retire.log" || bad "retire log: $(cat "$RLOGF" 2>/dev/null)"

echo "== the agent entry: none of stackshot's answers fails the retire (200 line removed, dropped, not listed; 502 page write failed, 422, 409 in progress); --busy calls too; the label is overridable"
for m in dropped notlisted; do   # the other two 200 answers: said in words (the first, line removed, is the q1 case above)
    mode "$m"; tagged sala-test-q2 "$UQ2" projects/foo; n0=$(ncalls)
    out=$("$SALA" retire sala-test-q2 --keep-web 2>&1); rc=$?
    case $m in dropped) want="ℹ stackshot dropped 'sala-test-q2' from projects/foo (it was only pending" ;; *) want="ℹ 'sala-test-q2' is not on projects/foo's agents and not pending in stackshot" ;; esac
    [ "$rc" = 0 ] && [ "$(ncalls)" = $((n0 + 1)) ] && echo "$out" | grep -qF "$want" && ! echo "$out" | grep -q "was not told" && ! tmux has-session -t =sala-test-q2 2>/dev/null && ok "answer $m (exit 0): the retire succeeds (rc 0), one call, said in words" || bad "answer $m: rc=$rc calls=$(ncalls) $out"
done
for m in 422 409; do   # the real client.py exits 1 with the reason on stderr for these: said and logged, the retire untouched
    mode "$m"; tagged sala-test-q2 "$UQ2" projects/foo; n0=$(ncalls)
    out=$("$SALA" retire sala-test-q2 --keep-web 2>&1); rc=$?
    [ "$rc" = 0 ] && [ "$(ncalls)" = $((n0 + 1)) ] && echo "$out" | grep -q "^retired 'sala-test-q2'; the transcript stays" && echo "$out" | grep -qF "ℹ stackshot refused ($m): " && echo "$out" | grep -qF "; the retire itself is done" && ! echo "$out" | grep -q "was not told" \
        && ! tmux has-session -t =sala-test-q2 2>/dev/null && [ -z "$(row sala-test-q2)" ] && grep -qF "[$m]" "$RLOGF" && ok "answer $m (exit 1): the retire still succeeds (rc 0), session and row gone, said as a refusal with its reason, logged" || bad "answer $m: rc=$rc calls=$(ncalls) $out"
done
mode 502; tagged sala-test-q2 "$UQ2" projects/foo; n0=$(ncalls)
out=$("$SALA" retire sala-test-q2 --keep-web 2>&1); rc=$?; l=$(echo "$out" | grep "^ℹ")
[ "$rc" = 0 ] && [ "$(ncalls)" = $((n0 + 1)) ] && echo "$out" | grep -q "^retired 'sala-test-q2'; the transcript stays" && ! tmux has-session -t =sala-test-q2 2>/dev/null && [ -z "$(row sala-test-q2)" ] \
    && [ "$(echo "$l" | wc -l)" = 1 ] && echo "$l" | grep -qF "ℹ stackshot could not finish taking 'sala-test-q2' off projects/foo's agents (502: gbrain refused the page write for projects/foo" && echo "$l" | grep -qF "the line of sala-test-q2 is still on the page: ask again): the retire itself is done; if the line is still on the page, ask again: python3 $HOME/fake-client.py post project-agent-retire projects/foo sala-test-q2 --sender sala-retire; if the reason says the timeline line was not written, the line is gone" && echo "$l" | grep -qF "add the timeline line by hand" && ! echo "$l" | grep -q "asking again is safe" \
    && ! echo "$out" | grep -q "was not told" && grep -qF "sala-test-q2: project-agent-retire projects/foo (label sala-retire) → exit 1: stackshot: agent not retired [502] gbrain refused" "$RLOGF" \
    && ok "answer 502 (exit 1): the retire still succeeds (rc 0), session and row gone, the failure said as its own line with the reason and the command to ask again, logged" || bad "answer 502: rc=$rc calls=$(ncalls) $out"
mode 502tl; tagged sala-test-q2 "$UQ2" projects/foo; n0=$(ncalls)
out=$("$SALA" retire sala-test-q2 --keep-web 2>&1); rc=$?; l=$(echo "$out" | grep "^ℹ")
[ "$rc" = 0 ] && [ "$(ncalls)" = $((n0 + 1)) ] && [ "$(echo "$l" | wc -l)" = 1 ] && echo "$l" | grep -qF "TAIL-MARK add the timeline line by hand" && echo "$l" | grep -qF "…" && [ "${#l}" -lt 1300 ] \
    && grep -qF "TAIL-MARK add the timeline line by hand" "$RLOGF" && ok "a long 502 reason is cut in the middle: its end (the timeline-line hint) is kept in the line and in the log" || bad "long 502: rc=$rc len=${#l} $out"
mode ok; tagged sala-test-q2 "$UQ2" projects/foo; n0=$(ncalls)
out=$(SALA_RETIRE_SENDER=sala-test-label "$SALA" retire sala-test-q2 --busy --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(ncalls)" = $((n0 + 1)) ] && [ "$(lastcall)" = "post project-agent-retire projects/foo sala-test-q2 --sender sala-test-label" ] && ok "--busy retire calls too, with SALA_RETIRE_SENDER as the label" || bad "busy: rc=$rc calls=$(ncalls) last=$(lastcall)"

echo "== the agent entry: a failing client (exit 1) and a missing client.py change nothing about the retire"
mode fail; tagged sala-test-q3 "$UQ3" projects/foo; n0=$(ncalls)
out=$("$SALA" retire sala-test-q3 --keep-web 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
[ "$rc" = 0 ] && [ "$(ncalls)" = $((n0 + 1)) ] && echo "$out" | grep -q "^retired 'sala-test-q3'; the transcript stays" && ! tmux has-session -t =sala-test-q3 2>/dev/null && [ -z "$(row sala-test-q3)" ] \
    && echo "$out" | grep -q "^ℹ stackshot was not told to drop 'sala-test-q3' from projects/foo's agents (exit 1" && grep -q "sala-test-q3: project-agent-retire projects/foo (label sala-retire) → exit 1: stackshot: agent not retired" "$RLOGF" \
    && ok "client exit 1: the retire still exits 0, the session gone, the row gone; the failure is said and logged" || bad "failing client: rc=$rc calls=$(ncalls) $out"
mode ok; tagged sala-test-q4 "$UQ4" projects/foo; n0=$(ncalls)
out=$(SALA_STACKSHOT_CLIENT="$HOME/nowhere.py" SALA_STACKSHOT_DIR= "$SALA" retire sala-test-q4 --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(ncalls)" = "$n0" ] && ! tmux has-session -t =sala-test-q4 2>/dev/null && grep -q "sala-test-q4: no stackshot client.py on this box" "$RLOGF" && ok "no client.py: the retire is done, one log line, no call" || bad "no client: rc=$rc $out"

echo "== the agent entry: a session with no project makes no call (one log line)"
tagged sala-test-q5 "$UQ5"; n0=$(ncalls)
out=$("$SALA" retire sala-test-q5 --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(ncalls)" = "$n0" ] && ! echo "$out" | grep -q "stackshot" && ! tmux has-session -t =sala-test-q5 2>/dev/null && grep -q "sala-test-q5: no project known for it" "$RLOGF" && ok "no project: retired, no call, nothing said, one log line" || bad "no project: rc=$rc calls=$(ncalls) $out"

echo "== the agent entry: a row without a project (what migrate imported) takes the project from stackshot's roles list: the client first, the file when the client gives none"
NROLES() { [ -f "$HOME/roles-calls.txt" ] && wc -l < "$HOME/roles-calls.txt" | tr -d ' ' || echo 0; }
UQ7=0a000017-0000-4000-8000-000000000097 UQ8=0a000018-0000-4000-8000-000000000098 UQ9=0a000019-0000-4000-8000-000000000099
# (a) the row has a project: the roles list is not read
mode ok; r0=$(NROLES); tagged sala-test-q1 "$UQ1" projects/foo; n0=$(ncalls)
out=$("$SALA" retire sala-test-q1 --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(NROLES)" = "$r0" ] && [ "$(lastcall)" = "post project-agent-retire projects/foo sala-test-q1 --sender sala-retire" ] && grep -qF "sala-test-q1: its project projects/foo came from its registry row" "$RLOGF" \
    && ok "(a) project on the row: used, source logged, the roles list not read" || bad "(a) rc=$rc roles-reads=$(NROLES) last=$(lastcall) $out"
# (b) no project on the row, the client's roles list gives one
printf '%s\n' '{"generated": "2026-10-31T00:00:00Z", "sessions": {"sala-test-q7": {"project": "projects/bar", "role": "front"}, "sala-test-other": {"project": "projects/baz"}}}' > "$HOME/roles-client.json"
tagged sala-test-q7 "$UQ7"; n0=$(ncalls); r0=$(NROLES)
out=$("$SALA" retire sala-test-q7 --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -qF "would tell stackshot to drop 'sala-test-q7' from projects/bar's agents" && [ "$(ncalls)" = "$n0" ] && ok "(b) --dry-run: the roles list's project is the one it would tell" || bad "(b) dry run: rc=$rc $out"
out=$("$SALA" retire sala-test-q7 --keep-web 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
[ "$rc" = 0 ] && [ "$(ncalls)" = $((n0 + 1)) ] && [ "$(lastcall)" = "post project-agent-retire projects/bar sala-test-q7 --sender sala-retire" ] && ! tmux has-session -t =sala-test-q7 2>/dev/null \
    && grep -qF "sala-test-q7: its project projects/bar came from stackshot's roles list (client.py get roles)" "$RLOGF" && ! grep -q "sala-test-q7: no project known" "$RLOGF" \
    && ok "(b) no project on the row: stackshot asked with the roles list's project, the source logged" || bad "(b) rc=$rc calls=$(ncalls) last=$(lastcall) log=$(grep sala-test-q7 "$RLOGF")"
# (d) the client gives nothing (exit 1), the file does
rm -f "$HOME/roles-client.json"; printf '%s\n' '{"sessions": {"sala-test-q8": {"project": "projects/qux", "retired": true}}}' > "$HOME/roles-file.json"
tagged sala-test-q8 "$UQ8"; n0=$(ncalls)
out=$(SALA_ROLES_FILE="$HOME/roles-file.json" "$SALA" retire sala-test-q8 --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(ncalls)" = $((n0 + 1)) ] && [ "$(lastcall)" = "post project-agent-retire projects/qux sala-test-q8 --sender sala-retire" ] \
    && grep -qF "sala-test-q8: its project projects/qux came from stackshot's roles list (the file $HOME/roles-file.json)" "$RLOGF" && ok "(d) client failing: the roles file's project used, source logged" || bad "(d) rc=$rc calls=$(ncalls) last=$(lastcall) $out"
# (c) neither gives one: the client fails, the file is bad JSON / lacks the name / is missing: today's line, no call, the retire done
printf '%s\n' '{"sessions": {"sala-test-q9": ' > "$HOME/roles-bad.json"
for f in "$HOME/roles-bad.json" "$HOME/roles-file.json" "$HOME/no-such-roles.json"; do
    tagged sala-test-q9 "$UQ9"; n0=$(ncalls); l0=$(wc -l < "$RLOGF")
    out=$(SALA_ROLES_FILE="$f" "$SALA" retire sala-test-q9 --keep-web 2>&1); rc=$?
    [ "$rc" = 0 ] && [ "$(ncalls)" = "$n0" ] && ! echo "$out" | grep -q "stackshot" && ! tmux has-session -t =sala-test-q9 2>/dev/null && [ -z "$(row sala-test-q9)" ] \
        && tail -n +$((l0 + 1)) "$RLOGF" | grep -q "sala-test-q9: no project known for it" && ok "(c) client failing, roles file $(basename "$f"): no project, no call, the retire done, today's log line" || bad "(c) $f: rc=$rc calls=$(ncalls) $out"
done
# the client answering a name the list lacks, and a roles list with no project for it, are no project either
printf '%s\n' '{"sessions": {"sala-test-q9": {"role": "front"}}}' > "$HOME/roles-client.json"
tagged sala-test-q9 "$UQ9"; n0=$(ncalls); l0=$(wc -l < "$RLOGF")
out=$(SALA_ROLES_FILE="$HOME/no-such-roles.json" "$SALA" retire sala-test-q9 --keep-web 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(ncalls)" = "$n0" ] && tail -n +$((l0 + 1)) "$RLOGF" | grep -q "sala-test-q9: no project known for it" && ok "(c) the list names the session but gives no project: today's line, no call" || bad "(c) no project in the list: rc=$rc $out"
rm -f "$HOME/roles-client.json"

echo "== the agent entry: forget-row of an orphan row calls too (its registry row's project)"
ledger_write add sala-test-q6 "$UQ6" sala-test-q6 "$HOME/work" >/dev/null 2>&1; "$SALA" sessions tag sala-test-q6 --project projects/foo --role front >/dev/null 2>&1; n0=$(ncalls); s0=$(state)
out=$("$SALA" forget-row sala-test-q6 --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -qF "would tell stackshot to drop 'sala-test-q6' from projects/foo's agents" && [ "$(ncalls)" = "$n0" ] && ok "orphan --dry-run: the call said, none made" || bad "orphan dry run: rc=$rc $out"
untouched "$s0" "forget-row sala-test-q6 --dry-run"
out=$("$SALA" forget-row sala-test-q6 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$(row sala-test-q6)" ] && [ "$(ncalls)" = $((n0 + 1)) ] && echo "$out" | grep -q "^ℹ stackshot removed 'sala-test-q6' from projects/foo's agents" && ok "orphan forget-row: row gone, one call after it" || bad "orphan forget-row: rc=$rc calls=$(ncalls) $out"

[ "$fail" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
