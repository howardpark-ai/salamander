#!/usr/bin/env bash
# The rescue (Wed Oct 14th 2026; lib/lane.sh "THE RESCUE", lib/revive.sh "THE RESCUE", lib/common.sh lane_out,
# is_idle_reason and pane_exit under SALA_RESCUE): another session moves the master off a lane that is out, and a stale
# background-task row no longer holds a pane whose claude has no child process. What is checked guards the relaunch of the
# master and the panes a rescue touches: `lane_out` reading sala's own state (lane_check, the sign-in watch's state, the
# limit watch's state: the master's own stop decisive, another pane's only for a lane-wide limit); `sala lane --rescue`
# refused while the master's lane looks fine, from the master's own pane, onto a lane that cannot launch or is out, with no
# master configured; allowed when the limit watch has the master stopped (the master moved while another session runs it,
# the recycle lock held by the run and its holder line naming the caller, the `rescue` line in lanes.log, the other pane
# untouched); `--force` moving it anyway and saying so in the log; `--dry-run` writing, logging and relaunching nothing; the
# table's warning under its rows when the master's lane is out. The stale row: a pane whose /exit opens the exit dialog over
# rows that are no scheduled task (the fake's FAKE_EXIT_DIALOG, drawn as 2.1.299 draws it) is left alone by a plain relaunch
# (Esc, the session stays) and relaunched by `--rescue` (the dialog read off the screen, 'Exit and stop tasks' confirmed,
# said in the output), through `revive --only` and through `sala lane … --rescue`; a pane with a live child process
# (FAKE_CHILD) is still refused with it; the Stop hook's record listing a task is passed over by `--rescue` and not without
# it; the mod's background refusal goes by keys under the rescue and stands without it or with a child; scheduled rows alone
# still take the dialog's Enter without any flag (the control); `--rescue` refused without --only and for a recycle. Posts
# stubbed to a file; isolated HOME, a private tmux socket, the compiled fake claude. Usage: bash tests/rescue.sh (exit 0 =
# pass; ~90 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SET SALA_SET_SELF SALA_POST_RECYCLE_CMD SALA_RECYCLE SALA_RETRY_WORKER SALA_NO_RELAUNCH SALA_MASTER SALA_RESCUE
unset ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS CLAUDE_CONFIG_DIR SALA_LANE_API_KEY_FILE SALA_LANE_API_WORKSPACE_FILE SALA_LANE_API_MCP_CONFIG SALA_LANE_TEAM_DIR
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, tmux_socket_rm
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC XDG_RUNTIME_DIR="$HOME/run"
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$XDG_RUNTIME_DIR"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"
printf '#!/bin/sh\necho "$*" >> "%s/systemd-run.txt"\n' "$HOME" > "$HOME/.local/bin/systemd-run"; chmod +x "$HOME/.local/bin/systemd-run"
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log" FAKE_LANE_LOG="$HOME/fake-lane.log" FAKE_TYPED_LOG="$HOME/typed.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off SALA_MOD_WAIT=1
SALA="$ROOT/bin/salamander"; SOCK="sala-rescue-$$"; T="tmux -L $SOCK -f /dev/null"; RLOG="$HOME/.claude/salamander-revive.log"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's (common.sh, on_fleet_server)
KEYF="$HOME/.config/anthropic/api-key"; WSF="$HOME/.config/anthropic/workspace-id"; DUMMY="dummy-key-NOT-REAL-$$"; WSID="wsid_dummy_$$"
mkdir -p "$HOME/.config/anthropic" "$HOME/.claude-team"; (umask 077; printf '%s\n' "$DUMMY" > "$KEYF"); printf '%s\n' "$WSID" > "$WSF"
printf '{"fake":true}\n' > "$HOME/.claude-team/.credentials.json"
FAKEMOD=""
cleanup() {
    local f p; for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done
    [ -n "$FAKEMOD" ] && kill "$FAKEMOD" 2>/dev/null
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    for p in $(pgrep -x claude); do [ "$HOME/.local/share/claude/versions/9.9.9" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done
    pkill -x fakechild 2>/dev/null   # a fake's child outliving a killed fake (PDEATHSIG covers the usual case)
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux
. "$ROOT/lib/common.sh"
wait_lock() { lock_wait "$SALA_RECYCLE_LOCK" 80; }
mk() { local n="$1" u="$2" env="${3:-}"; shift 3; $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="sala-test-$n" -e FAKE_LOG="$FAKE_LOG" -e FAKE_LANE_LOG="$FAKE_LANE_LOG" -e FAKE_TYPED_LOG="$FAKE_TYPED_LOG" "$@"; $T send-keys -t "sala-test-$n" "${env:+$env }claude" Enter; }
pane() { tmux display -p -t "sala-test-$1" '#{pane_id}'; }
lanelog() { grep "^$1 " "$FAKE_LANE_LOG" 2>/dev/null | tail -1 | cut -d' ' -f2-; }
rescues() { local n; n=$(grep -c $'\trescue\t' "$SALA_LANE_LOG" 2>/dev/null); echo "${n:-0}"; }   # the `rescue` lines in lanes.log
loglines() { local n; n=$(grep -c . "$SALA_LANE_LOG" 2>/dev/null); echo "${n:-0}"; }
screen() { tmux capture-pane -p -t "$(pane "$1")" | grep -v '^[[:space:]]*$'; }
NOW=$(date +%s)
# the two watches' state, written as the watches write it (lib/watch.sh: LW_PY's json, sw_set's key=value)
limit_state() {  # <session> <lane> <limit> [<since>] [<reset>] → the limit watch holding that pane stopped; no arguments: no state
    [ $# -gt 0 ] || { rm -f "$SALA_LIMIT_STATE"; return; }
    printf '{"panes":{"%s":{"s":"%s","since":%s,"reset":%s,"lane":"%s","lim":"%s","e":"e1"}},"done":{},"seen":{},"pok":{},"laneok":{},"headless":{},"pseen":{},"hseen":{},"episode":0}\n' \
        "$(uuid 77)" "$1" "${4:-$((NOW-1800))}" "${5:-$((NOW+3600))}" "$2" "$3" > "$SALA_LIMIT_STATE"
}
signin_state() { mkdir -p "$SALA_STATE_DIR"; if [ $# -gt 0 ]; then printf '%s.seen=%s\n%s.since=%s\n' "$1" "$2" "$1" "$((NOW-600))" > "$SALA_SIGNIN_STATE"; else rm -f "$SALA_SIGNIN_STATE"; fi; }   # <lane> "<wrong: …>"
UM=$(uuid 1); UO=$(uuid 2); UX=$(uuid 3); UY=$(uuid 4); UZ=$(uuid 5); US=$(uuid 6)

echo "== lane_out: sala's own readings of a lane that is out"
lane_out subscription-2 sala-test-m >/dev/null; [ $? = 1 ] && ok "no watch state, the directory signed in: subscription-2 looks fine (1, nothing said)" || bad "lane_out subscription-2 with no state: $(lane_out subscription-2 sala-test-m)"
out=$(lane_out bedrock); [ $? = 0 ] && grep -q 'no \[example-bedrock\] profile' <<< "$out" && ok "bedrock (no profile in the credentials file): out, by lane_check" || bad "lane_out bedrock: $out"
out=$(lane_out aws-platform); [ $? = 0 ] && grep -q 'no workspace id yet' <<< "$out" && ok "aws-platform (no workspace id): out, by lane_check" || bad "lane_out aws-platform: $out"
signin_state subscription-2 "wrong: a Max account (a personal organization)"
out=$(lane_out subscription-2 sala-test-m); [ $? = 0 ] && grep -q 'sign-in watch sees the Team lane a Max account' <<< "$out" && grep -q 'since' <<< "$out" && ok "the sign-in watch saw subscription-2 on another account: out, the reason and since when" || bad "signin wrong: $out"
signin_state subscription-2 "ok: a Team account (the ExampleOrg organization)"
lane_out subscription-2 sala-test-m >/dev/null; [ $? = 1 ] && ok "the sign-in watch saw it right: fine" || bad "signin ok read as out: $(lane_out subscription-2 sala-test-m)"
signin_state api "wrong: the key is refused (HTTP 401)"
out=$(lane_out api); [ $? = 0 ] && grep -q 'key is refused' <<< "$out" && ok "the api key refused by the API: api out" || bad "api refused: $out"
signin_state
limit_state sala-test-m subscription-2 seven_day
out=$(lane_out subscription-2 sala-test-m); [ $? = 0 ] && grep -q 'limit watch has sala-test-m stopped on it: Team weekly limit since' <<< "$out" && grep -q 'resets' <<< "$out" && ok "the master's own pane stopped on subscription-2 by the weekly limit: out, named with its reset" || bad "own stop: $out"
out=$(lane_out subscription-2); [ $? = 0 ] && grep -q 'limit watch has 1 pane stopped on it (sala-test-m): Team weekly limit' <<< "$out" && ok "asked for the lane alone: another pane's lane-wide stop counts" || bad "lane-wide stop: $out"
lane_out subscription-1 sala-test-m >/dev/null; [ $? = 1 ] && ok "subscription-1: nothing stopped on it, fine" || bad "subscription-1 read as out: $(lane_out subscription-1 sala-test-m)"
limit_state sala-test-other subscription-2 seven_day_opus
lane_out subscription-2 sala-test-m >/dev/null; [ $? = 1 ] && ok "another pane stopped by one model's limit (seven_day_opus): not the master's lane going out" || bad "per-model stop of another pane read as out: $(lane_out subscription-2 sala-test-m)"
limit_state sala-test-m subscription-2 seven_day_opus
out=$(lane_out subscription-2 sala-test-m); [ $? = 0 ] && grep -q 'Team Opus weekly limit' <<< "$out" && ok "the master's own pane stopped by one model's limit: out (its own stop is decisive)" || bad "own per-model stop: $out"
limit_state sala-test-m api credit
out=$(lane_out sdk sala-test-m); [ $? = 0 ] && grep -q 'API credit ran out' <<< "$out" && ok "sdk is judged by the api lane's stops (the credit)" || bad "sdk via api: $out"
limit_state
[ "$(lanes_working)" = "subscription-1 api subscription-2" ] && ok "lanes_working: subscription-1, api and subscription-2 (bedrock and aws-platform not set up, sdk cannot launch here)" || bad "lanes_working: '$(lanes_working)'"

echo "== the panes: m the master on subscription-2 (its row subscription-2), o another session, x a stale dialog, y a live child, z a plain pane, s scheduled rows"
mk m "$UM" "CLAUDE_CONFIG_DIR=$HOME/.claude-team"; mk o "$UO" ""; lane_write sala-test-m team
mk x "$UX" "" -e FAKE_EXIT_DIALOG='shell · sleep 600;subagent · worker'
mk y "$UY" "" -e FAKE_EXIT_DIALOG='shell · sleep 600' -e FAKE_CHILD=1
mk z "$UZ" ""; mk s "$US" "" -e FAKE_EXIT_DIALOG='scheduled task · daily at 09:00'
fake_up sala-test-m sala-test-o sala-test-x sala-test-y sala-test-z sala-test-s
MP=$(pane m); OP=$(pane o)
[ "$(proc_lane "$(cpid m)")" = subscription-2 ] && [ "$(lane_row sala-test-m)" = subscription-2 ] && ok "m runs on subscription-2 with its row" || bad "m: $(proc_lane "$(cpid m)") row '$(lane_row sala-test-m)'"
[ -n "$(work_children "$(cpid y)")" ] && [ -z "$(work_children "$(cpid x)")" ] && ok "y has a live child process (fakechild), x none" || bad "children: y='$(work_children "$(cpid y)")' x='$(work_children "$(cpid x)")'"

echo "== sala lane --rescue: the refusals that record and relaunch nothing"
export SALA_MASTER=sala-test-m
out=$(SALA_MASTER= TMUX_PANE="$OP" "$SALA" lane --rescue api 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'no master session is configured' <<< "$out" && ok "no master configured: refused" || bad "no master ($rc): $out"
out=$(TMUX_PANE="$OP" "$SALA" lane --rescue bogus 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q "unknown lane" <<< "$out" && ok "an unknown lane: refused" || bad "bogus ($rc): $out"
out=$(TMUX_PANE="$OP" "$SALA" lane --rescue bedrock 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'no \[example-bedrock\] profile' <<< "$out" && ok "a lane that cannot launch (bedrock, no profile): refused by lane_check" || bad "bedrock ($rc): $out"
out=$(TMUX_PANE="$OP" "$SALA" lane --rescue api 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'sits on the Team lane, which looks fine to sala' <<< "$out" && grep -q -- '--force' <<< "$out" && ok "the master's lane looks fine: refused, --force named" || bad "looks fine ($rc): $out"
out=$(TMUX_PANE="$MP" "$SALA" lane --rescue api --force 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q "master's own pane" <<< "$out" && grep -q 'salamander lane api sala-test-m' <<< "$out" && ok "from the master's own pane: refused, the ordinary switch (the self-worker) named" || bad "own pane ($rc): $out"
out=$(TMUX_PANE="$OP" "$SALA" lane --rescue subscription-2 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'runs on the Team lane already' <<< "$out" && ok "onto the lane it runs on: refused" || bad "same lane ($rc): $out"
out=$(TMUX_PANE="$OP" "$SALA" lane api sala-test-o --force 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q -- '--force belongs to the rescue' <<< "$out" && ok "--force on an ordinary switch: refused" || bad "force on switch ($rc): $out"
out=$(TMUX_PANE="$OP" "$SALA" lane api --all --rescue 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'never --all' <<< "$out" && ok "--rescue with --all: refused" || bad "rescue --all ($rc): $out"
limit_state sala-test-m subscription-2 seven_day; signin_state api "wrong: the key is refused (HTTP 401)"
out=$(TMUX_PANE="$OP" "$SALA" lane --rescue api 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'api lane is out as well' <<< "$out" && grep -q 'key is refused' <<< "$out" && grep -q 'subscription-1' <<< "$out" && ok "the target lane out too (the key refused): refused, the lanes that work named" || bad "target out ($rc): $out"
signin_state
[ "$(lane_row sala-test-m)" = subscription-2 ] && [ "$(starts "$UM")" = 1 ] && [ "$(rescues)" = 0 ] && ok "after every refusal: the row subscription-2, no relaunch, no rescue line in lanes.log" || bad "after refusals: row '$(lane_row sala-test-m)' starts $(starts "$UM") rescues $(rescues)"

echo "== the table's warning: the master on a lane that is out"
limit_state
out=$("$SALA" lane 2>&1); ! grep -q '⚠ the master' <<< "$out" && ok "no watch state: no warning under the table" || bad "a warning with nothing wrong: $out"
limit_state sala-test-m subscription-2 seven_day
out=$("$SALA" lane 2>&1)
grep -q '⚠ the master sala-test-m sits on the Team lane, which is out: the limit watch has sala-test-m stopped on it: Team weekly limit since' <<< "$out" \
    && grep -q 'salamander lane --rescue <lane> (lanes that work: subscription-1, api)' <<< "$out" && ok "the master stopped on subscription-2: one line under the table — the lane, why, the rescue, the lanes that work" || bad "table warning: $out"

echo "== allowed when out: the master moved from another session, under the recycle lock, logged"
tsv0=$(<"$SALA_LANES"); log0=$(loglines)
out=$(TMUX_PANE="$OP" "$SALA" lane --rescue api --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'DRY RUN' <<< "$out" && grep -q '\[dry-run\] would record sala-test-m on the api lane' <<< "$out" && grep -qF "would /exit (9.9.9) and resume $UM on 9.9.9 · lane: subscription-2 → subscription-2" <<< "$out" \
    && ok "--dry-run: the plan and the sweep's verdict (the row still subscription-2: the dry run records nothing, so the line says subscription-2 → subscription-2)" || bad "dry run ($rc): $out"
[ "$(<"$SALA_LANES")" = "$tsv0" ] && [ "$(loglines)" = "$log0" ] && [ "$(starts "$UM")" = 1 ] && [ "$(rescues)" = 0 ] && ok "and it wrote nothing: lanes.tsv, lanes.log and the fake's starts unchanged" || bad "dry run wrote: tsv '$(<"$SALA_LANES")' log $log0 → $(loglines) starts $(starts "$UM") rescues $(rescues)"
TMUX_PANE="$OP" "$SALA" lane --rescue api > "$HOME/rescue.out" 2>&1 & RP=$!
# THE POLL (a run under the suites' load, Wed Oct 14th 2026: "lock during the rescue" with the file's earlier content): the
# lock is taken (recycle_lock: flock on fd 9) a moment before its holder line is written (recycle_lock_note: a `date`, then a
# printf that truncates the file first), and under load that moment is wide enough for a poll to see the lock held and read
# the file before the line is there (empty, or the previous holder's). So the poll waits for both at once — the lock held
# and the line naming this caller — rather than for the lock alone and then one read; the line stays once written, so
# reading it again after the poll is safe. The cap is 30 s (a positive wait: the rescue's own checks before it takes the
# lock — the lanes' state, the master's process — are a dozen process starts, slow under the same load).
waitfor '! flock -n "$SALA_RECYCLE_LOCK" true && [ "$(cut -f3 "$SALA_RECYCLE_LOCK" 2>/dev/null)" = sala-test-o ]' 60 && IFS=$'\t' read -r hpid hstart hwho hlog < "$SALA_RECYCLE_LOCK" && [ "$hwho" = sala-test-o ] && ok "the recycle lock is held while the rescue runs, its holder line naming the caller (sala-test-o)" || bad "lock during the rescue: $(slurp "$SALA_RECYCLE_LOCK")"
wait "$RP"; rc=$?; out=$(<"$HOME/rescue.out")
[ "$rc" = 0 ] && grep -q 'rescue: the master sala-test-m, subscription-2 → api' <<< "$out" && grep -q 'why: subscription-2 is out: the limit watch has sala-test-m stopped' <<< "$out" && ok "sala lane --rescue api from sala-test-o: exit 0, the plan said" || bad "rescue ($rc): $out"
waitfor '[ "$(starts "$UM")" = 2 ]' 40 && fake_up sala-test-m && [ "$(lanelog "$UM")" = "key=y hdr=y cfg=-" ] && ok "the master relaunched on api (the key in its environment)" || bad "master after the rescue: starts $(starts "$UM") lane $(lanelog "$UM") $(tail -5 "$RLOG")"
grep -qF "sala-test-m:0: /exit (9.9.9) → resume $UM · lane: subscription-2 → api" <<< "$out" && ok "the sweep's line: subscription-2 → api" || bad "sweep line: $out"
[ "$(lane_row sala-test-m)" = api ] && ok "recorded: sala-test-m → api" || bad "row: '$(lane_row sala-test-m)'"
l=$(grep $'\trescue\t' "$SALA_LANE_LOG" | tail -1)
[ "$(rescues)" = 1 ] && grep -q $'\trescue\tsala-test-m\tsubscription-2 → api: subscription-2 is out: the limit watch has sala-test-m stopped on it' <<< "$l" && grep -q $'\tsala-test-o$' <<< "$l" && ok "lanes.log: one rescue line — when, rescue, the master, from → to, why, who (sala-test-o)" || bad "lanes.log: $l"
[ "$(starts "$UO")" = 1 ] && [ -z "$(lane_row sala-test-o)" ] && ok "sala-test-o (the caller) untouched, unrecorded" || bad "o: starts $(starts "$UO") row '$(lane_row sala-test-o)'"
wait_lock; flock -n "$SALA_RECYCLE_LOCK" true && ok "the lock released once the sweep is done" || bad "lock still held: $(<"$SALA_RECYCLE_LOCK")"
! grep -qF "$DUMMY" <<< "$out" && ! grep -qsF "$DUMMY" "$SALA_LANE_LOG" "$RLOG" && ok "the key value is in none of the output or the logs" || bad "the key value leaked"

echo "== --force: the lane looks fine, moved anyway, said in the log"
limit_state
out=$(TMUX_PANE="$OP" "$SALA" lane --rescue subscription-2 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'api lane, which looks fine' <<< "$out" && [ "$(starts "$UM")" = 2 ] && ok "api looks fine now: refused" || bad "api fine ($rc): $out"
out=$(TMUX_PANE="$OP" "$SALA" lane --rescue subscription-2 --force 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'why: --force: the api lane looked fine to sala' <<< "$out" && ok "--force: the move goes, the override said" || bad "force ($rc): $out"
waitfor '[ "$(starts "$UM")" = 3 ]' 40 && fake_up sala-test-m && [ "$(lanelog "$UM")" = "key=n hdr=n cfg=$HOME/.claude-team" ] && [ "$(lane_row sala-test-m)" = subscription-2 ] && ok "the master back on subscription-2, recorded" || bad "after --force: starts $(starts "$UM") lane $(lanelog "$UM") row '$(lane_row sala-test-m)'"
[ "$(rescues)" = 2 ] && grep $'\trescue\t' "$SALA_LANE_LOG" | tail -1 | grep -q 'api → subscription-2: --force: the api lane looked fine' && ok "lanes.log: the rescue line carries the --force" || bad "lanes.log: $(grep $'\trescue\t' "$SALA_LANE_LOG" | tail -1)"
wait_lock

echo "== the stale dialog: a plain relaunch leaves the pane (Esc), --rescue reads the dialog and confirms it"
out=$("$SALA" revive --force --only sala-test-x 2>&1)
grep -q 'sala-test-x:0: background work is running (a shell, monitor or subagent), which /exit would stop — /exit cancelled' <<< "$out" && ok "without the flag: the dialog cancelled with Esc, the row as before" || bad "plain revive on x: $out"
waitfor '[ "$(screen x | tail -1)" = "❯" ]' 20 && [ "$(starts "$UX")" = 1 ] && proc_alive "$(cpid x)" && ok "x's session stays: the dialog gone, the ❯ prompt back, the same process" || bad "x after Esc: starts $(starts "$UX") screen: $(screen x)"
wait_lock
out=$("$SALA" revive --force --only sala-test-x --rescue 2>&1); rc=$?
grep -qF "sala-test-x:0: rescue — the exit dialog listed background work (shell · sleep 600; subagent · worker), but no child process ran under the claude: stale rows, 'Exit and stop tasks' confirmed (--rescue)" <<< "$out" \
    && ok "with --rescue: the dialog's rows read off the screen, no child under the claude, 'Exit and stop tasks' confirmed — said in the output" || bad "rescue on x ($rc): $out"
waitfor '[ "$(starts "$UX")" = 2 ]' 40 && fake_up sala-test-x && grep -q 'sala-test-x:0: 9.9.9 → 9.9.9' <<< "$out" && ok "x relaunched, the same conversation" || bad "x after the rescue: starts $(starts "$UX") $out"
wait_lock
out=$("$SALA" lane api sala-test-x --rescue 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q -- '--rescue: a stale background-task row will not hold' <<< "$out" && waitfor '[ "$(starts "$UX")" = 3 ]' 40 && fake_up sala-test-x && [ "$(lanelog "$UX")" = "key=y hdr=y cfg=-" ] && [ "$(lane_row sala-test-x)" = api ] \
    && ok "sala lane api sala-test-x --rescue: the flag reaches the sweep; x recorded and relaunched on api through its dialog" || bad "lane --rescue on x ($rc): starts $(starts "$UX") lane $(lanelog "$UX") $out"
grep -q 'sala-test-x:0: rescue — the exit dialog listed' <<< "$out" && ok "and says the dialog was confirmed" || bad "no rescue line: $out"
wait_lock

echo "== a live child: still refused with --rescue (the refusal names the child)"
out=$("$SALA" revive --force --only sala-test-y --rescue 2>&1)
grep -q 'sala-test-y:0: a background task is running (child pids:' <<< "$out" && [ "$(starts "$UY")" = 1 ] && proc_alive "$(cpid y)" && ok "y: skipped for its live child, not relaunched, the session untouched" || bad "y with --rescue: $out"
for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; rm -f "$f"; done   # the retry worker it left (a passing reason)
wait_lock

echo "== the Stop hook's record listing a task: passed over by --rescue when no child runs, not without it"
printf '{"session_id":"%s","background_tasks":[{"id":"t","type":"shell","status":"running","description":"a loop stopped by hand","command":"while true; do sleep 60; done"}]}' "$UZ" | "$SALA" hook stop
waitfor 'busy_state "$(cpid z)" "$UZ" >/dev/null' 20 && ok "the record for z says a shell is in flight (the flip stamped)" || bad "no busy record for z: $(slurp "$SALA_BUSY_DIR/$UZ")"
out=$("$SALA" revive --force --only sala-test-z 2>&1)
grep -q 'sala-test-z:0: background work in flight when its last turn ended (1 task, by the Stop hook'"'"'s record)' <<< "$out" && [ "$(starts "$UZ")" = 1 ] && ok "without the flag: skipped on the record, as before" || bad "plain revive on z: $out"
for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; rm -f "$f"; done
wait_lock
out=$("$SALA" revive --force --only sala-test-z --rescue 2>&1)
grep -q 'sala-test-z:0: rescue — background work in flight when its last turn ended (1 task' <<< "$out" && grep -q 'read as stale and passed over' <<< "$out" && ok "with --rescue: the record passed over, said" || bad "rescue on z: $out"
waitfor '[ "$(starts "$UZ")" = 2 ]' 40 && ok "z relaunched" || bad "z not relaunched: $out"
wait_lock

echo "== the mod's background refusal (pane_exit): by keys under the rescue, standing without it or with a live child"
RUN="$XDG_RUNTIME_DIR/sala/mod"; MODE="$HOME/fakemod.mode"; MSOCK="$HOME/fakemod.sock"
cat > "$HOME/rsc-fakemod.py" <<'PY'
import json, os, socket, sys, threading
sock, run, mode, home = sys.argv[1:5]
try: os.unlink(sock)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX); s.bind(sock); s.listen(8)
def rd(p, d=""):
    try: return open(p).read().strip()
    except Exception: return d
def serve(c):
    data = b""
    while not data.endswith(b"\n"):
        b = c.recv(65536)
        if not b: break
        data += b
    c.close()
    try: text = json.loads(data)["message"]["content"]
    except Exception: return
    if not text.startswith("[sala-mod] "): return
    verb, req, *rest = text[len("[sala-mod] "):].split("\n")[0].split(" ")
    sid = rd(os.path.join(home, "fakemod.sid")); out = {"reqid": req, "ok": True}
    if verb == "draft": out["text"] = ""
    elif verb == "exit" and rd(mode, "ok") == "background": out = {"reqid": req, "ok": False, "reason": "background", "tasks": ["shell running"]}
    os.makedirs(run, exist_ok=True); tmp = os.path.join(run, "%s.%s.reply.json.tmp" % (sid, req))
    open(tmp, "w").write(json.dumps(out) + "\n"); os.replace(tmp, os.path.join(run, "%s.%s.reply.json" % (sid, req)))
while True:
    c, _ = s.accept(); threading.Thread(target=serve, args=(c,), daemon=True).start()
PY
python3 "$HOME/rsc-fakemod.py" "$MSOCK" "$RUN" "$MODE" "$HOME" & FAKEMOD=$!
waitfor '[ -S "$MSOCK" ]' 20 || bad "the fake mod did not start"
point_socket() { python3 -c 'import json,sys; f=sys.argv[1]; d=json.load(open(f)); d["messagingSocketPath"]=sys.argv[2]; json.dump(d,open(f,"w"))' "$HOME/.claude/sessions/$1.json" "$MSOCK"; }
stamp() { mkdir -p "$RUN"; printf '{"present":true,"version":1,"sessionId":"%s","at":%s}\n' "$1" "$(date +%s)000" > "$RUN/$1.json"; }
C=$(cpid z); echo "$UZ" > "$HOME/fakemod.sid"; point_socket "$C"; stamp "$UZ"; echo background > "$MODE"; : > "$SALA_MOD_LOG"; n0=$(grep -c "^$UZ /exit$" "$FAKE_TYPED_LOG" 2>/dev/null || echo 0)
pane_exit "$(pane z)" "$C" >/dev/null; rc=$?
[ "$rc" = 2 ] && grep -q 'exit sala-test-z via mod (refused: background work)' "$SALA_MOD_LOG" && [ "$(grep -c "^$UZ /exit$" "$FAKE_TYPED_LOG" 2>/dev/null || echo 0)" = "$n0" ] && ok "no flag: the mod's refusal stands (rc 2), nothing typed" || bad "mod refusal without the flag: rc=$rc $(<"$SALA_MOD_LOG")"
: > "$SALA_MOD_LOG"
SALA_RESCUE=1 pane_exit "$(pane z)" "$C" >/dev/null; rc=$?
[ "$rc" = 0 ] && grep -q 'exit sala-test-z via keys (rescue: the mod refused for background work (\["shell running"\]), but no child process runs under the claude — a stale task row)' "$SALA_MOD_LOG" \
    && waitfor '[ "$(grep -c "^$UZ /exit$" "$FAKE_TYPED_LOG")" = $((n0+1)) ]' 10 && ok "SALA_RESCUE=1, no child: the refusal read as a stale row, /exit typed by keys, logged" || bad "mod refusal under the rescue: rc=$rc $(<"$SALA_MOD_LOG") typed $(grep -c "^$UZ /exit$" "$FAKE_TYPED_LOG")"
waitfor '[ "$(tmux display -p -t "$(pane z)" "#{pane_current_command}")" = bash ]' 20 && ok "z exited on it (no dialog on z: the keys' /exit ended it)" || bad "z still up after the keys' /exit"
CY=$(cpid y); echo "$UY" > "$HOME/fakemod.sid"; point_socket "$CY"; stamp "$UY"; : > "$SALA_MOD_LOG"
SALA_RESCUE=1 pane_exit "$(pane y)" "$CY" >/dev/null; rc=$?
[ "$rc" = 2 ] && grep -q 'exit sala-test-y via mod (refused: background work)' "$SALA_MOD_LOG" && proc_alive "$CY" && ok "SALA_RESCUE=1 with a live child (y): the mod's refusal stands" || bad "mod refusal with a child under the rescue: rc=$rc $(<"$SALA_MOD_LOG")"
kill "$FAKEMOD" 2>/dev/null; FAKEMOD=""

echo "== scheduled rows alone: the dialog's Enter without any flag (the control), and the flag's own refusals"
out=$("$SALA" revive --force --only sala-test-s 2>&1)
waitfor '[ "$(starts "$US")" = 2 ]' 40 && grep -q 'sala-test-s:0: 9.9.9 → 9.9.9' <<< "$out" && ! grep -q 'rescue' <<< "$out" && ok "a dialog of scheduled tasks only: exited and resumed as before, no rescue involved" || bad "scheduled rows: starts $(starts "$US") $out"
wait_lock
out=$("$SALA" revive --force --rescue 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q -- '--rescue needs --only' <<< "$out" && ok "revive --rescue without --only: refused" || bad "rescue without --only ($rc): $out"
out=$("$SALA" recycle --force --rescue 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'never a recycle' <<< "$out" && ! grep -q 'recycle started' <<< "$out" && ok "recycle --rescue: refused before anything starts" || bad "recycle --rescue ($rc): $out"

[ "$fail" = 0 ] && echo "rescue: pass" || echo "rescue: FAIL"
exit $fail
