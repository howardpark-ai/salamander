#!/usr/bin/env bash
# A queued relaunch whose pane's claude is still running after its /exit and the wait (lib/common.sh end_stuck_claude, called by
# lib/revive.sh close_pane): that one process is ended by its pid and the session resumes by its explicit id.
# Checked here on fakes only (the compiled fake claude in panes of a private tmux server, an isolated HOME, Slack a file):
#   THE SWEEP: `revive --force` over four panes. a ignores /exit (it leaves on SIGTERM): its pid is ended, the same conversation
#     resumes in its pane (a second start on its id), one Slack post and one log line name it and the pid. d ignores /exit and
#     SIGTERM too: SIGKILL, after the TERM wait. b exits on /exit as any pane does: nothing is signalled, no post names it. c ignores
#     /exit but its registry row says a turn is running: skipped with the reason, never signalled, still alive.
#   THE GATES: end_stuck_claude called directly refuses, with a reason and no signal, for a pid that is not the claude under the pane,
#     a process named claude whose binary is not a Claude Code install, the master session, the pane the caller runs in, a
#     registry row that says busy, and SALA_EXIT_END=0 (which also takes the step out of the dry run's text).
#   THE PLAN: a dry run says "will end a stuck process" (revive and the dormant-lane fallback), and leaves every process alone.
#   THE DORMANT LANE: with the aws-platform lane dormant, `lane fallback aws-platform` moves its two sessions to bedrock; the one
#     whose claude ignores /exit is ended by its pid and resumes on bedrock; the other (it exits on /exit) is not signalled; a
#     session on another lane is not touched at all.
# No process is killed by name: the suite signals only pids it read from its own panes, and its cleanup ends its own fakes with
# kill_fake_claude (exe and HOME checked).
# Usage: bash tests/stuckexit.sh   (exit 0 = pass)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_MASTER SALA_SET SALA_SET_SELF SALA_RECYCLE SALA_RETRY_WORKER SALA_LOCK_WHO SALA_LOCK_WAIT SALA_RELAUNCH_KIND \
      SALA_FLEET_HOSTS SALA_CGROUP_FILE SALA_OP_QUEUE SALA_NO_RELAUNCH SALA_RESCUE SALA_CLAUDE SALA_EXIT_END
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_CUSTOM_HEADERS CLAUDE_CONFIG_DIR CLAUDE_CODE_OAUTH_TOKEN SALA_LANE_API_KEY_FILE SALA_LANE_TEAM_DIR SALA_LANE_FALLBACK
unset AWS_PROFILE AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_BEARER_TOKEN_BEDROCK CLAUDE_CODE_USE_BEDROCK SALA_LANE_BEDROCK_CREDENTIALS_FILE
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings (SALA_EXIT_WAIT, SALA_EXIT_TERM_WAIT, SALA_EXIT_KILL_WAIT), ok/bad/waitfor, fake_up, kill_fake_claude
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
exec 7< "$HOME"; flock -n 7 || true   # the temp folder is locked while the suite runs (systemd-tmpfiles ageing honours it)
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOME/.aws" "$HOME/anc" "$HOME/.local/state/sala-web"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"
ln -s "$(command -v python3)" "$HOME/anc/claude"   # a process NAMED claude whose binary is python
FAKE="$HOME/.local/share/claude/versions/9.9.9"
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"   # one post per record, '%%' between them
export SALA_BIN="$ROOT/bin/salamander" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off SALA_SIGNIN_ALERT=off SALA_LANE_FALLBACK_AUTO=off
SALA="$ROOT/bin/salamander"; SOCK="sala-stuckexit-$$"; T="tmux -L $SOCK -f /dev/null"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's
SPIDS=()   # the sleeps this suite started (its own pids)
cleanup() {
    local p; for p in ${SPIDS[@]+"${SPIDS[@]}"}; do kill "$p" 2>/dev/null; done
    for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    kill_fake_claude "$FAKE"
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux    # literal socket: the children run set -u
. "$ROOT/lib/common.sh"
as_op_unit   # the guarded verbs this suite runs stand for the queue's runner (no master: tests/lib.sh)
mkdir -p "$SALA_STATE_DIR"; : > "$POSTS"
# mk <n> <uuid> <launch line> [tmux new-session options…]: pane sala-test-<n>, its claude started by the launch line
mk() { local n="$1" u="$2" line="$3"; shift 3; $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="sala-test-$n" -e FAKE_LOG="$FAKE_LOG" "$@"; $T send-keys -t "sala-test-$n" "$line" Enter; }
alive() { kill -0 "$1" 2>/dev/null; }
paneid() { $T display -p -t "=sala-test-$1:" '#{pane_id}'; }
logtext() { slurp "$HOME/.claude/salamander-revive.log"; }
UA=$(uuid 1) UB=$(uuid 2) UC=$(uuid 3) UD=$(uuid 4)
python3 - "$HOME/.claude/projects/x" "$UA" "$UB" "$UC" "$UD" <<'PY'
import os, sys, time
d = sys.argv[1]; now = time.time()
for i, u in enumerate(sys.argv[2:]):
    p = os.path.join(d, u + ".jsonl"); open(p, "w").close(); os.utime(p, (now - 100 - i, now - 100 - i))
PY

echo "== setup: a ignores /exit, b exits on it, c ignores it and shows a turn, d ignores it and SIGTERM"
mk a "$UA" claude -e FAKE_IGNORE_EXIT=1
mk b "$UB" claude
mk c "$UC" claude -e FAKE_IGNORE_EXIT=1
mk d "$UD" 'bash -c '"'"'trap "" TERM; exec claude'"'" -e FAKE_IGNORE_EXIT=1
fake_up sala-test-a sala-test-b sala-test-c sala-test-d || exit 1
PA=$(cpid a); PB=$(cpid b); PC=$(cpid c); PD=$(cpid d)
[ -n "$PA" ] && [ -n "$PB" ] && [ -n "$PC" ] && [ -n "$PD" ] && [ "$PA$PB$PC" != "$PD" ] && ok "four fake panes up (pids $PA $PB $PC $PD)" || { bad "panes not up: $PA $PB $PC $PD"; exit 1; }
set_reg_status "$PC" busy

echo "== the plan: a dry run says it will end a stuck process, and ends nothing"
out=$("$SALA" revive --dry-run --force --only sala-test-a 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "will end a stuck process" && has "$out" "TERM, then KILL after ${SALA_EXIT_TERM_WAIT}s" && alive "$PA" && ok "revive --dry-run: names the step, the pid stays" || bad "dry run ($rc): $out"
out=$(SALA_EXIT_END=0 "$SALA" revive --dry-run --force --only sala-test-a 2>&1)
has "$out" "would /exit" && ! has "$out" "will end a stuck process" && ok "SALA_EXIT_END=0: the plan does not promise it" || bad "dry run, step off: $out"

echo "== the sweep: revive --force"
: > "$POSTS"
out=$(SALA_RESUME_WAIT=15 "$SALA" revive --force 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
! alive "$PA" && [ "$(starts "$UA")" = 2 ] && ok "a: its pid is gone and the conversation started again in its pane (a second start on its id)" || bad "a: alive=$(alive "$PA" && echo y || echo n) starts=$(starts "$UA")"
NA=$(cpid a); [ -n "$NA" ] && [ "$NA" != "$PA" ] && alive "$NA" && ok "a: the new claude ($NA) is a different process under the same pane" || bad "a: new pid '$NA'"
has "$out" "sala-test-a:0: claude (pid $PA) was still running" && has "$out" "ended by its pid (SIGTERM)" && has "$out" "resuming $UA on the Ultra lane" && ok "a: the sweep's output names the session, the pid, the signal and the lane" || bad "a: no output line"
p=$(post "Ended a Claude process that ignored /exit"); [ -n "$p" ] && has "$p" "sala-test-a: pid $PA ended (SIGTERM)" && ! has "$p" "sala-test-a:0" && has "$p" "resumes on the Ultra lane" && [ "$(nposts "pid $PA ended")" = 1 ] && ok "a: one Slack post, with the session (no pane suffix), the pid and the lane" || bad "a: post: $(slurp "$POSTS")"
has "$(slurp "$POSTS")" "$PB" && bad "b's pid is in a post" || ok "no post names b's pid"
! alive "$PD" && [ "$(starts "$UD")" = 2 ] && has "$out" "sala-test-d:0: claude (pid $PD) was still running" && has "$out" "ended by its pid (SIGKILL)" && ok "d: SIGTERM ignored, SIGKILL after the wait: ended and resumed" || bad "d: alive=$(alive "$PD" && echo y || echo n) starts=$(starts "$UD")"
[ "$(nposts "pid $PD ended (SIGKILL)")" = 1 ] && ok "d: its own post" || bad "d: post"
! alive "$PB" && [ "$(starts "$UB")" = 2 ] && grep -q "^exit $UB " "$FAKE_LOG" && ok "b: left on /exit by itself and resumed" || bad "b: alive=$(alive "$PB" && echo y || echo n) starts=$(starts "$UB")"
! has "$out" "sala-test-b:0: claude (pid" && [ "$(nposts "sala-test-b")" = 0 ] && ok "b: nothing was ended, nothing posted" || bad "b: ended line or post"
alive "$PC" && [ "$(starts "$UC")" = 1 ] && has "$out" "sala-test-c:0: registry says 'busy'" && ok "c: a busy pane is skipped by the sweep's own gate: its pid is alive, no restart" || bad "c: alive=$(alive "$PC" && echo y || echo n) starts=$(starts "$UC")"
[ "$(nposts "Ended a Claude process")" = 2 ] && ok "two posts in all (a and d)" || bad "posts: $(nposts "Ended a Claude process")"

echo "== the gates: end_stuck_claude refuses, says why and signals nothing"
PA=$(cpid a); PB=$(cpid b); PD=$(cpid d); IDA=$(paneid a); IDB=$(paneid b)
SALA_EXIT_TERM_WAIT=1 SALA_EXIT_KILL_WAIT=1; export SALA_EXIT_TERM_WAIT SALA_EXIT_KILL_WAIT
end_stuck_claude "$IDA" sala-test-a "$PB"; rc=$?
[ "$rc" = 1 ] && has "$STUCK_WHY" "is not the claude under pane" && alive "$PA" && alive "$PB" && ok "another pane's claude pid: refused ($STUCK_WHY)" || bad "other pane's pid ($rc): $STUCK_WHY"
$T new-session -d -s sala-test-z -c "$HOME"; $T send-keys -t sala-test-z "$HOME/anc/claude -c 'import time; time.sleep(600)'" Enter
ZP=$($T display -p -t "=sala-test-z:" '#{pane_pid}'); ZC=""; for _ in 1 2 3 4 5 6 7 8 9 10; do ZC=$(pgrep -P "$ZP" 2>/dev/null | head -1); [ -n "$ZC" ] && break; sleep 1; done
SPIDS+=("$ZC"); zcomm=""; { read -r zcomm < "/proc/${ZC:-0}/comm"; } 2>/dev/null
end_stuck_claude "$($T display -p -t "=sala-test-z:" '#{pane_id}')" sala-test-z "$ZC"; rc=$?
[ "$zcomm" = claude ] && [ "$rc" = 1 ] && has "$STUCK_WHY" "binary" && alive "$ZC" && ok "a process named claude whose binary is not a Claude Code install: refused, still running ($STUCK_WHY)" || bad "named-claude python ($rc, comm '$zcomm'): $STUCK_WHY"
SALA_MASTER=sala-test-a end_stuck_claude "$IDA" sala-test-a "$PA"; rc=$?
[ "$rc" = 1 ] && has "$STUCK_WHY" "master" && alive "$PA" && ok "the master session: refused ($STUCK_WHY)" || bad "master ($rc): $STUCK_WHY"
TMUX_PANE="$IDA" end_stuck_claude "$IDA" sala-test-a "$PA"; rc=$?
[ "$rc" = 1 ] && has "$STUCK_WHY" "runs in" && alive "$PA" && ok "the pane this command runs in: refused ($STUCK_WHY)" || bad "own pane ($rc): $STUCK_WHY"
end_stuck_claude "$IDA" sala-test-a "$$"; rc=$?
[ "$rc" = 1 ] && alive "$$" && ok "the caller's own pid: refused ($STUCK_WHY)" || bad "own pid ($rc): $STUCK_WHY"
end_stuck_claude "$IDA" sala-test-a ""; rc=$?; [ "$rc" = 1 ] && ok "no pid: refused ($STUCK_WHY)" || bad "no pid ($rc)"
set_reg_status "$PA" busy
end_stuck_claude "$IDA" sala-test-a "$PA"; rc=$?
[ "$rc" = 1 ] && has "$STUCK_WHY" "registry row says 'busy'" && alive "$PA" && ok "a registry row that says busy: refused ($STUCK_WHY)" || bad "busy ($rc): $STUCK_WHY"
set_reg_status "$PA" idle
SALA_EXIT_END=0 end_stuck_claude "$IDA" sala-test-a "$PA"; rc=$?
[ "$rc" = 1 ] && has "$STUCK_WHY" "SALA_EXIT_END=0" && alive "$PA" && ok "SALA_EXIT_END=0: refused ($STUCK_WHY)" || bad "step off ($rc): $STUCK_WHY"
alive "$PB" && alive "$PD" && ok "every refused call left every claude running" || bad "a claude died in the gate checks"
$T kill-session -t sala-test-z 2>/dev/null

echo "== the dormant lane: lane fallback aws-platform → bedrock, a stuck session ended by its pid"
export SALA_EXIT_TERM_WAIT=3 SALA_EXIT_KILL_WAIT=3
UE=$(uuid 5) UF=$(uuid 6)
python3 - "$HOME/.claude/projects/x" "$UE" "$UF" <<'PY'
import os, sys, time
d = sys.argv[1]; now = time.time()
for i, u in enumerate(sys.argv[2:]):
    p = os.path.join(d, u + ".jsonl"); open(p, "w").close(); os.utime(p, (now - 100 - i, now - 100 - i))
PY
export SALA_LANE_BEDROCK_CREDENTIALS_FILE="$HOME/.aws/credentials"
printf '[example-bedrock]\naws_access_key_id = dummy-not-real-id-%s\naws_secret_access_key = dummy-not-real-%s\n' "$$" "$$" > "$SALA_LANE_BEDROCK_CREDENTIALS_FILE"
mk e "$UE" claude -e FAKE_IGNORE_EXIT=1 -e CLAUDE_CODE_USE_ANTHROPIC_AWS=1
mk f "$UF" claude -e CLAUDE_CODE_USE_ANTHROPIC_AWS=1
fake_up sala-test-e sala-test-f || exit 1
lane_write sala-test-e aws-platform; lane_write sala-test-f aws-platform
for n in a b d; do lane_write "sala-test-$n" subscription-1; done
PE=$(cpid e); PF=$(cpid f); PA=$(cpid a)
[ "$(proc_lane "$PE")" = aws-platform ] && [ "$(proc_lane "$PF")" = aws-platform ] && [ "$(proc_lane "$PA")" = subscription-1 ] && ok "e and f run on aws-platform, a on subscription-1" || bad "lanes: $(proc_lane "$PE") $(proc_lane "$PF") $(proc_lane "$PA")"
lane_dormant_set aws-platform "test: no access" hand
out=$("$SALA" lane fallback aws-platform --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "will end a stuck process" && has "$out" "resume the session on bedrock" && alive "$PE" && alive "$PF" && ok "the fallback's dry run names the step; nothing is signalled" || bad "fallback dry run ($rc): $out"
: > "$POSTS"
out=$(SALA_RESUME_WAIT=15 "$SALA" lane fallback aws-platform 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
! alive "$PE" && [ "$(starts "$UE")" = 2 ] && NE=$(cpid e) && [ -n "$NE" ] && [ "$(proc_lane "$NE")" = bedrock ] && ok "e: its pid ended, the conversation resumed on bedrock (new pid $NE)" || bad "e: alive=$(alive "$PE" && echo y || echo n) starts=$(starts "$UE") lane=$(proc_lane "$(cpid e)")"
has "$out" "sala-test-e:0: claude (pid $PE) was still running" && has "$out" "resuming $UE on the bedrock lane" && p=$(post "pid $PE ended") && has "$p" "resumes on the bedrock lane" && ok "e: the output line and the one post say session, pid and lane" || bad "e: no line or post: $(slurp "$POSTS")"
! alive "$PF" && [ "$(starts "$UF")" = 2 ] && [ "$(proc_lane "$(cpid f)")" = bedrock ] && [ "$(nposts "pid $PF ended")" = 0 ] && ok "f: left on /exit by itself, resumed on bedrock, never signalled and not named in a post" || bad "f: alive=$(alive "$PF" && echo y || echo n) starts=$(starts "$UF")"
alive "$PA" && [ "$(cpid a)" = "$PA" ] && [ "$(starts "$UA")" = 2 ] && ok "a (subscription-1): the same process, no relaunch" || bad "a was touched"
[ "$(lane_row sala-test-e)" = bedrock ] && [ "$(lane_row sala-test-f)" = bedrock ] && ok "both recorded on bedrock" || bad "rows: $(lane_row sala-test-e) $(lane_row sala-test-f)"

[ "${fail:-0}" = 0 ] && echo "stuckexit: pass" || { echo "stuckexit: FAIL"; exit 1; }
