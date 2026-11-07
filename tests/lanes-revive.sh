#!/usr/bin/env bash
# Revive's lane line (lib/revive.sh, THE LANE LINE), split out of tests/lanes.sh so the two run side by
# side (the wall time of tests/run.sh is set by its slowest suite). Against panes launched BY HAND on subscription-2 (the lane's env on
# the launch line, as a hand-launched pane was; nothing recorded): matching lanes relaunched, a mismatch with no row refused by name with
# both lanes and both fixes (nothing relaunched, nothing recorded, no retry worker), a mismatch with a row relaunched on the
# row, --lane-default relaunching on the default, each in the dry run and for real; the dry runs of `revive --self` and
# `recycle --force` from a pane scheduling, relaunching, freezing and writing nothing, and leaving an earlier retry worker
# alone; a fleet recycle relaunching every other pane and naming the refused pane in its post. The setup mirrors where
# lanes.sh leaves its panes: a and b on the api lane with rows (the lanes themselves, the verb and the switches are
# lanes.sh's). Posts stubbed to a file; isolated HOME, a private tmux socket, the compiled fake claude (tests/fake-claude.c,
# FAKE_LANE_LOG). Usage: bash tests/lanes-revive.sh   (exit 0 = pass; ~55 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SET SALA_SET_SELF SALA_POST_RECYCLE_CMD SALA_RECYCLE SALA_RETRY_WORKER SALA_NO_RELAUNCH SALA_MASTER
unset ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS CLAUDE_CONFIG_DIR SALA_LANE_API_KEY_FILE SALA_LANE_API_WORKSPACE_FILE SALA_LANE_API_MCP_CONFIG SALA_LANE_TEAM_DIR
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, tmux_socket_rm
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
as_op_unit   # no master: the guarded verbs this suite runs itself stand for the queue's runner (tests/lib.sh, 5)
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"   # as the CLI installs it: the launcher target's name is the version
printf '#!/bin/sh\necho "$*" >> "%s/systemd-run.txt"\n' "$HOME" > "$HOME/.local/bin/systemd-run"; chmod +x "$HOME/.local/bin/systemd-run"   # watch launches nothing
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log" FAKE_LANE_LOG="$HOME/fake-lane.log" FAKE_TYPED_LOG="$HOME/typed.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off
SALA="$ROOT/bin/salamander"; SOCK="sala-lanes-revive-$$"; T="tmux -L $SOCK -f /dev/null"; RLOG="$HOME/.claude/salamander-revive.log"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's (common.sh, on_fleet_server)
# the lanes' files: a DUMMY key (never a real one), a workspace id, a subscription-2 directory signed in; no second login besides subscription-2
KEYF="$HOME/.config/anthropic/api-key"; WSF="$HOME/.config/anthropic/workspace-id"; DUMMY="dummy-key-NOT-REAL-$$"; WSID="wsid_dummy_$$"
mkdir -p "$HOME/.config/anthropic" "$HOME/.claude-team"; (umask 077; printf '%s\n' "$DUMMY" > "$KEYF"); printf '%s\n' "$WSID" > "$WSF"
printf '{"fake":true}\n' > "$HOME/.claude-team/.credentials.json"
cleanup() {
    local f p; for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    for p in $(pgrep -x claude); do [ "$HOME/.local/share/claude/versions/9.9.9" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux    # literal socket: the children run set -u
. "$ROOT/lib/common.sh"
wait_lock() { lock_wait "$HOME/.claude/salamander-recycle.lock" 80; }
lanelog() { grep "^$1 " "$FAKE_LANE_LOG" 2>/dev/null | tail -1 | cut -d' ' -f2-; }   # <uuid> → "key=… hdr=… cfg=…" of its latest start
mkh() { local n="$1" u="$2" env="${3:-}"; $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="sala-test-$n" -e FAKE_LOG="$FAKE_LOG" -e FAKE_LANE_LOG="$FAKE_LANE_LOG" -e FAKE_TYPED_LOG="$FAKE_TYPED_LOG"; $T send-keys -t "sala-test-$n" "${env:+$env }claude" Enter; }
workers() { local f n=0; for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill -0 "$(<"$f")" 2>/dev/null && n=$((n+1)); done; echo $n; }   # live retry workers
U1=$(uuid 1); U2=$(uuid 2); U4=$(uuid 4); U5=$(uuid 5); U6=$(uuid 6)

echo "== setup: a and b on the api lane with rows (where lanes.sh leaves them), launched by hand with the lane's env"
mkh a "$U1" "$(lane_env_prefix api)"; mkh b "$U2" "$(lane_env_prefix api)"; fake_up sala-test-a sala-test-b
lane_write sala-test-a api; lane_write sala-test-b api
: > "$RLOG"; : > "$POSTS"   # both exist by this point in lanes.sh (its recycle wrote and posted): the dry-run checks below count their lines before and after
[ "$(lanelog "$U1")" = "key=y hdr=y cfg=-" ] && [ "$(lanelog "$U2")" = "key=y hdr=y cfg=-" ] && [ "$(lane_row sala-test-a)" = api ] && [ "$(lane_row sala-test-b)" = api ] && [ "$(lane_default)" = subscription-1 ] \
    && ok "a and b run on api, recorded api; the default is subscription-1" || bad "setup: a=$(lanelog "$U1") b=$(lanelog "$U2") rows '$(lane_row sala-test-a)' '$(lane_row sala-test-b)' default $(lane_default)"

echo "== revive's lane line: the lane a pane runs on → the lane its resume line puts it on; a mismatch with no row refuses that pane"
# d is launched BY HAND on the subscription-2 lane (the env on its launch line, as pane 56 was; nothing recorded), e by hand on subscription-1
mkh d "$U4" "CLAUDE_CONFIG_DIR=$HOME/.claude-team"; mkh e "$U5"; fake_up sala-test-d sala-test-e
[ "$(proc_lane "$(cpid d)")" = subscription-2 ] && [ "$(proc_lane "$(cpid e)")" = subscription-1 ] && [ -z "$(lane_row sala-test-d)" ] && [ "$(lane_default)" = subscription-1 ] && ok "d runs on subscription-2 with no row, e on subscription-1; the default is subscription-1" || bad "setup: d=$(proc_lane "$(cpid d)") e=$(proc_lane "$(cpid e)") row='$(lane_row sala-test-d)' default=$(lane_default)"
out=$("$SALA" revive --force --only sala-test-e --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && grep -qF "sala-test-e:0: would /exit (9.9.9) and resume $U5 on 9.9.9 · lane: subscription-1 → subscription-1" <<< "$out" && [ "$(starts "$U5")" = 1 ] && ok "matching lanes, dry run: the line says subscription-1 → subscription-1, nothing relaunched" || bad "e dry run ($rc): $out"
out=$("$SALA" revive --force --only sala-test-e 2>&1); rc=$?
grep -qF "sala-test-e:0: /exit (9.9.9) → resume $U5 · lane: subscription-1 → subscription-1" <<< "$out" && ok "matching lanes, real: the line is printed with the /exit" || bad "e real ($rc): $out"
waitfor '[ "$(starts "$U5")" = 2 ]' 40 && ok "and e relaunched" || bad "e not relaunched: $(<"$FAKE_LOG")"
fake_up sala-test-e; [ "$(lanelog "$U5")" = "key=n hdr=n cfg=-" ] && ok "on subscription-1" || bad "e after: $(lanelog "$U5")"
out=$("$SALA" revive --force --only sala-test-d --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && grep -qF "sala-test-d:0: not relaunched — runs on the subscription-2 lane but has no lane row" <<< "$out" && grep -qF "salamander lane subscription-2 sala-test-d" <<< "$out" && grep -qF -- "--only sala-test-d --lane-default" <<< "$out" && grep -qF "(lane: subscription-2 → subscription-1)" <<< "$out" \
    && ok "mismatch without a row, dry run: refused by name, both lanes and both fixes named" || bad "d dry run ($rc): $out"
[ "$(starts "$U4")" = 1 ] && [ -z "$(lane_row sala-test-d)" ] && ok "nothing relaunched, nothing recorded" || bad "d after dry run: starts $(starts "$U4"), row '$(lane_row sala-test-d)'"
out=$("$SALA" revive --force --only sala-test-d 2>&1); rc=$?
grep -qF "sala-test-d:0: not relaunched — runs on the subscription-2 lane but has no lane row" <<< "$out" && ok "mismatch without a row, real: the same refusal" || bad "d real ($rc): $out"
sleep 3; [ "$(starts "$U4")" = 1 ] && [ "$(lanelog "$U4")" = "key=n hdr=n cfg=$HOME/.claude-team" ] && [ "$(workers)" = 0 ] && ok "d still on team, not relaunched, no retry worker (not a passing reason)" || bad "d after the real run: starts $(starts "$U4") lane $(lanelog "$U4") workers $(workers)"
lane_write sala-test-d api
out=$("$SALA" revive --force --only sala-test-d --dry-run 2>&1)
grep -qF "would /exit (9.9.9) and resume $U4 on 9.9.9 · lane: subscription-2 → api" <<< "$out" && [ "$(starts "$U4")" = 1 ] && ok "mismatch with a row (api), dry run: the row wins, the line says subscription-2 → api, nothing relaunched" || bad "d row dry run: $out"
out=$("$SALA" revive --force --only sala-test-d 2>&1)
grep -qF "sala-test-d:0: /exit (9.9.9) → resume $U4 · lane: subscription-2 → api" <<< "$out" && ok "mismatch with a row, real: the line printed" || bad "d row real: $out"
waitfor '[ "$(starts "$U4")" = 2 ]' 40 && fake_up sala-test-d && [ "$(lanelog "$U4")" = "key=y hdr=y cfg=-" ] && ok "relaunched on api (the row)" || bad "d after the row relaunch: starts $(starts "$U4") lane $(lanelog "$U4")"
grep -qF "sala-test-d:0: 9.9.9 → 9.9.9 (lane api)" <<< "$out" && ok "the summary row names the lane" || bad "summary: $out"
lane_drop sala-test-d   # d runs on api now with no row and the default subscription-1: a mismatch again
out=$("$SALA" revive --force --only sala-test-d --lane-default --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && grep -qF "would /exit (9.9.9) and resume $U4 on 9.9.9 · lane: api → subscription-1 (no lane row; the default accepted: --lane-default)" <<< "$out" && [ "$(starts "$U4")" = 2 ] && ok "--lane-default, dry run: accepted and said, nothing relaunched" || bad "d --lane-default dry run ($rc): $out"
"$SALA" revive --force --only sala-test-d --lane-default >/dev/null 2>&1
waitfor '[ "$(starts "$U4")" = 3 ]' 40 && fake_up sala-test-d && [ "$(lanelog "$U4")" = "key=n hdr=n cfg=-" ] && ok "--lane-default, real: relaunched on the default (subscription-1)" || bad "d --lane-default: starts $(starts "$U4") lane $(lanelog "$U4")"

echo "== a dry run schedules nothing (revive --self --dry-run scheduled the real self-relaunch; recycle --force --dry-run froze the map and ran the self-worker)"
mkh f "$U6" "CLAUDE_CONFIG_DIR=$HOME/.claude-team"; fake_up sala-test-f   # f: on team by hand, no row — a mismatch, for the refusals here and the fleet recycle below
EP=$(tmux display -p -t sala-test-e '#{pane_id}'); FP=$(tmux display -p -t sala-test-f '#{pane_id}')
LOCKF="$HOME/.claude/salamander-recycle.lock"; lock_before=$(slurp "$LOCKF"); sw0=$(grep -c 'self-worker: waiting for pane' "$RLOG" 2>/dev/null)
out=$(TMUX_PANE="$EP" "$SALA" revive --self --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && grep -qF "[dry-run] sala-test-e: would schedule the self-relaunch of pane $EP" <<< "$out" && grep -qF "resume $U5 on 9.9.9 · lane: subscription-1 → subscription-1" <<< "$out" && grep -q 'nothing scheduled' <<< "$out" && ok "revive --self --dry-run: says what the self-worker would do" || bad "--self --dry-run ($rc): $out"
sleep 3; [ "$(starts "$U5")" = 2 ] && [ "$(grep -c 'self-worker: waiting for pane' "$RLOG" 2>/dev/null)" = "$sw0" ] && [ "$(slurp "$LOCKF")" = "$lock_before" ] && ok "no self-worker started, e not relaunched, the lock's holder line untouched" || bad "after --self --dry-run: starts $(starts "$U5"), self-workers $(grep -c 'self-worker: waiting for pane' "$RLOG") (was $sw0), lock '$(slurp "$LOCKF")' (was '$lock_before')"
out=$(TMUX_PANE="$FP" "$SALA" revive --self --dry-run 2>&1); rc=$?
[ "$rc" = 1 ] && grep -qF "[dry-run] --self would be refused" <<< "$out" && grep -qF "(lane: subscription-2 → subscription-1)" <<< "$out" && ok "--self --dry-run on a mismatch without a row: would be refused, both lanes named" || bad "f --self --dry-run ($rc): $out"
out=$(TMUX_PANE="$FP" "$SALA" revive --self 2>&1); rc=$?
[ "$rc" = 1 ] && grep -qF "sala-test-f: --self refused" <<< "$out" && grep -qF "salamander lane subscription-2 sala-test-f" <<< "$out" && ok "--self for real on it: refused, the fix named" || bad "f --self ($rc): $out"
sleep 2; [ "$(starts "$U6")" = 1 ] && [ "$(grep -c 'self-worker: waiting for pane' "$RLOG" 2>/dev/null)" = "$sw0" ] && ok "f not relaunched, no self-worker" || bad "after f --self: starts $(starts "$U6"), self-workers $(grep -c 'self-worker: waiting for pane' "$RLOG") (was $sw0)"
# recycle --force --dry-run from e's pane: every pane's verdict and the self-worker's plan for e, and nothing else
fr0=$(grep -c $'\tfreeze\t' "$SALA_LEDGER_LOG" 2>/dev/null); sets0=$(ls "$SALA_SET_DIR" 2>/dev/null | wc -l); posts0=$(grep -c '^%%$' "$POSTS" 2>/dev/null); s1=$(starts "$U1"); s2=$(starts "$U2"); s4=$(starts "$U4"); s5=$(starts "$U5")
out=$(TMUX_PANE="$EP" "$SALA" recycle --force --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'recycle DRY RUN started' <<< "$out" && ok "recycle --force --dry-run from e's pane: a dry-run driver" || bad "recycle dry run ($rc): $out"
waitfor "grep -qF 'self-worker: [dry-run] sala-test-e: would wait for pane $EP' '$RLOG'" 60 && ok "the self-worker said its plan for e instead of relaunching it" || bad "no self-worker dry-run line: $(tail -5 "$RLOG")"
grep -qF "sala-test-f:0: not relaunched — runs on the subscription-2 lane but has no lane row" "$RLOG" && ok "the sweep's verdict on f is in the log" || bad "no verdict on f: $(grep 'sala-test-f' "$RLOG" | tail -3)"
sleep 2
[ "$(starts "$U1")" = "$s1" ] && [ "$(starts "$U2")" = "$s2" ] && [ "$(starts "$U4")" = "$s4" ] && [ "$(starts "$U5")" = "$s5" ] && [ "$(starts "$U6")" = 1 ] && ok "no pane relaunched" || bad "a dry-run recycle relaunched: a $s1→$(starts "$U1") b $s2→$(starts "$U2") d $s4→$(starts "$U4") e $s5→$(starts "$U5") f 1→$(starts "$U6")"
[ "$(grep -c $'\tfreeze\t' "$SALA_LEDGER_LOG" 2>/dev/null)" = "$fr0" ] && ! ledger_frozen && ok "the pane map was not frozen" || bad "frozen on a dry run: $(grep $'\tfreeze\t' "$SALA_LEDGER_LOG" | tail -1) / $(ledger_freeze_line)"
[ "$(ls "$SALA_SET_DIR" 2>/dev/null | wc -l)" = "$sets0" ] && [ "$(grep -c '^%%$' "$POSTS" 2>/dev/null)" = "$posts0" ] && [ "$(grep -c 'self-worker: waiting for pane' "$RLOG")" = "$sw0" ] && ok "no set, no post, no real self-worker" || bad "sets $sets0→$(ls "$SALA_SET_DIR" 2>/dev/null | wc -l) posts $posts0→$(grep -c '^%%$' "$POSTS") self-workers $sw0→$(grep -c 'self-worker: waiting for pane' "$RLOG")"
# a dry-run sweep inside a recycle never stops an earlier retry worker nor clears the waiting flags (a sleep with a pid file stands in for the worker)
SP=$( (sleep 300 >/dev/null 2>&1 & echo $!) ); echo "$SP" > "$HOME/.claude/salamander-retry.$SP.pid"; mkdir -p "$SALA_WAITING_DIR"; touch "$SALA_WAITING_DIR/test-flag"
SALA_RECYCLE=1 "$SALA" revive --dry-run >/dev/null 2>&1
kill -0 "$SP" 2>/dev/null && [ -s "$HOME/.claude/salamander-retry.$SP.pid" ] && [ -e "$SALA_WAITING_DIR/test-flag" ] && ok "a recycle's dry-run sweep leaves an earlier retry worker and its flags alone" || bad "the dry run purged the worker: alive=$(kill -0 "$SP" 2>/dev/null && echo y || echo n) pidfile=$([ -e "$HOME/.claude/salamander-retry.$SP.pid" ] && echo y || echo n) flag=$([ -e "$SALA_WAITING_DIR/test-flag" ] && echo y || echo n)"

echo "== a recycle of the whole fleet with a pane the lane line refuses: the others relaunched, the refused one in the set's post, never silently skipped"
s1=$(starts "$U1"); s2=$(starts "$U2"); s4=$(starts "$U4"); s5=$(starts "$U5")
"$SALA" recycle --force >/dev/null 2>&1 || bad "recycle --force did not start"
waitfor '[ "$(starts "$U1")" -gt "$s1" ] && [ "$(starts "$U2")" -gt "$s2" ] && [ "$(starts "$U4")" -gt "$s4" ] && [ "$(starts "$U5")" -gt "$s5" ]' 80 && ok "a, b, d, e relaunched" || bad "starts: a $s1→$(starts "$U1") b $s2→$(starts "$U2") d $s4→$(starts "$U4") e $s5→$(starts "$U5"); $(tail -20 "$RLOG")"
wait_lock; fake_up sala-test-a sala-test-b sala-test-d sala-test-e
[ "$(starts "$U6")" = 1 ] && [ "$(lanelog "$U6")" = "key=n hdr=n cfg=$HOME/.claude-team" ] && ok "f not relaunched, still on team" || bad "f: starts $(starts "$U6") lane $(lanelog "$U6")"
waitfor "grep -q 'sala-test-f: not relaunched — runs on the subscription-2 lane but has no lane row' '$POSTS'" 40 && ok "the recycle's post names f and why" || bad "posts: $(tail -c 1500 "$POSTS")"
[ "$(workers)" = 0 ] && ok "no retry worker for it (not a passing reason)" || bad "a retry worker holds f"
! kill -0 "$SP" 2>/dev/null && [ ! -e "$HOME/.claude/salamander-retry.$SP.pid" ] && [ ! -e "$SALA_WAITING_DIR/test-flag" ] && ok "the real recycle stopped the stand-in worker and cleared the flags (the control)" || bad "control: alive=$(kill -0 "$SP" 2>/dev/null && echo y || echo n) pidfile=$([ -e "$HOME/.claude/salamander-retry.$SP.pid" ] && echo y || echo n) flag=$([ -e "$SALA_WAITING_DIR/test-flag" ] && echo y || echo n)"
kill "$SP" 2>/dev/null; rm -f "$HOME/.claude/salamander-retry.$SP.pid"

[ "$fail" = 0 ] && echo "lanes-revive: pass" || echo "lanes-revive: FAIL"
exit $fail
