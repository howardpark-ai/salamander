#!/usr/bin/env bash
# Recycle sets, the master's own pane (split out of tests/sets.sh so the two halves run side by side). The
# set's state and that its posts go out, never their wording: the master's pane counted outstanding at once while
# the first post goes out, its relaunch by the self-worker settling it; a clean recycle from the master's pane relaunching
# that pane too; the master's pane failing outright → the set closed at 1/2, posted once; the master's pane handed to a
# retry worker → the worker relaunches it and closes the set. Slack stubbed to a file (SALA_NOTIFY_CMD), no post-recycle
# command. Isolated HOME, a private tmux socket, the compiled fake claude (tests/fake-claude.c).
# Usage: bash tests/sets-master.sh   (exit 0 = pass)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SET SALA_SET_SELF SALA_POST_RECYCLE_CMD SALA_RECYCLE SALA_RETRY_WORKER
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, tmux_socket_rm
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
as_op_unit   # no master: the guarded verbs this suite runs itself stand for the queue's runner (tests/lib.sh, 5)
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"   # as the CLI installs it: the launcher target's name is the version
printf '#!/bin/sh\necho "$*" >> "%s/systemd-run.txt"\n' "$HOME" > "$HOME/.local/bin/systemd-run"; chmod +x "$HOME/.local/bin/systemd-run"   # watch launches nothing
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"   # one post per record, '%%' between them
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off
SALA="$ROOT/bin/salamander"; SOCK="sala-setsmaster-$$"; T="tmux -L $SOCK -f /dev/null"; RLOG="$HOME/.claude/salamander-revive.log"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's (common.sh, on_fleet_server)
cleanup() {
    local f p; kill "${HBW:-}" "${HDW:-}" 2>/dev/null; for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    for p in $(pgrep -x claude); do [ "$HOME/.local/share/claude/versions/9.9.9" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux    # literal socket: the children run set -u
. "$ROOT/lib/common.sh"
show() { sed 's/^/      | /' "$POSTS" 2>/dev/null | grep -v '| %%$'; }
wait_lock() { lock_wait "$HOME/.claude/salamander-recycle.lock" 60; }
# exit-empty off, set once the first session has started the server: a section's last kill-session no longer empties the private
# server, so the next section's new-session never races a server that is still going away ("server exited unexpectedly",
# "fake claude 'sf' did not come up", total=1 instead of 2: seen on a loaded CI runner).
# The cleanup's kill-server still ends it.
mk() { local n="$1" u="$2"; shift 2; $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="$n" -e FAKE_LOG="$FAKE_LOG" "$@"; $T set -s exit-empty off; $T send-keys -t "sala-test-$n" 'claude' Enter; }
draft() {  # typed, never submitted: a transient skip (once the fake is up; until the text shows in the pane)
    fake_up "$1"; $T send-keys -t "sala-test-$1" -l 'half a thought'; waitfor "$T capture-pane -p -t sala-test-$1 | grep -q 'half a thought'" 20; }
undraft() { $T send-keys -t "sala-test-$1" Enter; }                         # submitted: the composer is empty again
workers() { local f n=0; for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill -0 "$(<"$f")" 2>/dev/null && n=$((n+1)); done; echo $n; }

echo "== the master's own pane: counted in the set at once, its relaunch settles it"
mk sm "$(uuid 11)"; mk s1 "$(uuid 12)"; mk s2 "$(uuid 13)"; draft s2; fake_up sm s1
export SALA_RETRY_EVERY=4 SALA_RETRY_WINDOW=120
SP=$(tmux display -p -t sala-test-sm '#{pane_id}'); S5="$(date +%s)-$$"; set_point recycle "$S5"
SALA_RECYCLE=1 SALA_SET="$S5" SALA_SET_SELF="$SP" SALA_SKIP_PANE="$SP" "$SALA" revive --force >/dev/null 2>&1
[ "$(set_val "$S5" total)" = 3 ] && [ "$(set_val "$S5" done)" = 1 ] && grep -qx 'out=sala-test-sm' "$SALA_SET_DIR/$S5" && ok "the sweep wrote N=3 (the master's pane counted, outstanding), n=1" || bad "set after the sweep: $(<"$SALA_SET_DIR/$S5")"
[ -n "$(post 'relaunched*')" ] && ok "the sweep's first post is out at once, before the master's pane is back" || bad "first post: $(show)"
SALA_SET="$S5" "$SALA" revive --self-worker "$SP" >/dev/null 2>&1 && ok "the self-worker relaunched the master's pane" || bad "self-worker failed: $(tail -5 "$RLOG")"
[ "$(set_val "$S5" done)" = 2 ] && ! grep -qx 'out=sala-test-sm' "$SALA_SET_DIR/$S5" && [ "$(set_val "$S5" closed)" = 0 ] && ok "its relaunch settled it in the set: 2/3, still open for s2" || bad "master closure: $(<"$SALA_SET_DIR/$S5")"
set_report "$S5"; [ "$(nposts 'relaunched*')" = 1 ] && ok "the first post is made once" || bad "first post made twice"
undraft s2; waitfor '[ -n "$(post "· 3/3 · set closed*")" ]' 60 && ok "s2's closure closes the set: · 3/3 · set closed" || bad "no s2 closure: $(show)"
show; waitfor '[ "$(workers)" = 0 ]' 20 || bad "the retry worker did not finish"
$T kill-session -t sala-test-sm; $T kill-session -t sala-test-s1; $T kill-session -t sala-test-s2; : > "$POSTS"
echo "== a clean recycle from the master's pane: the master's pane relaunched too, its claude slow to register"
# the master's resumed claude registers 6 s in, after SALA_RESUME_WAIT (5 s) has run out: slow to start is never a failure
mk cm "$(uuid 14)" -e FAKE_RESUME_DELAY=6000; mk c1 "$(uuid 15)"; fake_up cm c1
CP=$(tmux display -p -t sala-test-cm '#{pane_id}')
out=$(TMUX_PANE="$CP" "$SALA" recycle --force 2>&1); echo "$out" | grep -q 'recycle started' || bad "recycle did not start: $out"
waitfor '[ "$(nposts Recycle)" -ge 1 ]' 120; wait_lock
waitfor '[ "$(grep -c "^start $(uuid 14)" "$FAKE_LOG")" = 2 ] && [ "$(grep -c "^start $(uuid 15)" "$FAKE_LOG")" = 2 ]' 40 && ok "both panes relaunched, the master's own included" || bad "clean recycle: $(cat "$FAKE_LOG"; tail -20 "$RLOG")"
CS=$(cat "$(_set_scope_file recycle)" 2>/dev/null); [ "$(set_val "$CS" done)" = 2 ] && ! grep -q '^out=' "$SALA_SET_DIR/$CS" && ok "the set: 2/2, nothing outstanding (the master counted relaunched although its row landed past the window)" || bad "clean recycle set: $(slurp "$SALA_SET_DIR/$CS")"
show; $T kill-session -t sala-test-cm; $T kill-session -t sala-test-c1; : > "$POSTS"
echo "== the master's pane fails outright, nothing else left behind: the set closed at 1/2, once"
# the resume comes up and dies 10 s in (the pane's foreground command reads `claude` meanwhile): a 1 s poll once
# inside that window counted the pane as relaunched and the set closed at 2/2, "Recycle done" (lib/revive.sh, resume_wait).
# The fake lives 10 s, not 3, and the self-worker that resumes sf waits 20 s, not 5: resume_wait sees it only if one poll
# (tmux display, claude_pid_under, sleep 1) lands inside its life, and on a loaded runner a poll outlasts 3 s (seen
# in CI: phases.sh "FAIL f: no 'started and died' row"). A fake living past the wait would read
# as slow to register, so only that command gets the longer wait; the --force line before it skips sf (SALA_SKIP_PANE).
mk sf "$(uuid 16)" -e FAKE_RESUME_FAIL=1 -e FAKE_RESUME_DELAY=10000; mk f1 "$(uuid 17)"; fake_up sf f1
SP=$(tmux display -p -t sala-test-sf '#{pane_id}'); S6="$(date +%s)-$$"; set_point recycle "$S6"
SALA_RECYCLE=1 SALA_SET="$S6" SALA_SET_SELF="$SP" SALA_SKIP_PANE="$SP" "$SALA" revive --force >/dev/null 2>&1
swout=$(SALA_RESUME_WAIT=20 SALA_SET="$S6" "$SALA" revive --self-worker "$SP" 2>&1) && bad "the self-worker did not fail: $swout" || ok "the self-worker failed (the resume started, then died)"
[ "$(set_val "$S6" done)" = 1 ] && [ "$(set_val "$S6" closed)" = 1 ] && [ "$(nposts 'closed at')" = 1 ] && ok "the self-worker gave it up: the set 1/2 (the master not counted relaunched), closed, posted once" || bad "master give-up: $(cat "$SALA_SET_DIR/$S6"; show)"
show; $T kill-session -t sala-test-sf; $T kill-session -t sala-test-f1; : > "$POSTS"
echo "== the master's pane handed to a retry worker, nothing else left behind: the worker relaunches it and closes the set"
mk sh "$(uuid 18)"; mk h1 "$(uuid 19)"; draft sh; fake_up h1
export SALA_RETRY_EVERY=3 SALA_RETRY_WINDOW=120
SP=$(tmux display -p -t sala-test-sh '#{pane_id}'); S7="$(date +%s)-$$"; set_point recycle "$S7"
SALA_RECYCLE=1 SALA_SET="$S7" SALA_SET_SELF="$SP" SALA_SKIP_PANE="$SP" "$SALA" revive --force >/dev/null 2>&1
SALA_SELF_WAIT=3 SALA_SET="$S7" "$SALA" revive --self-worker "$SP" >/dev/null 2>&1
undraft sh; waitfor '[ -n "$(post "· 2/2 · set closed*")" ]' 60 && ok "the retry worker relaunched it and closed the set: · 2/2 · set closed" || bad "no closure: $(show; tail -10 "$RLOG")"
show; waitfor '[ "$(workers)" = 0 ]' 20 || bad "the retry worker did not finish"
$T kill-session -t sala-test-sh; $T kill-session -t sala-test-h1; : > "$POSTS"
echo "== the self-worker holds the inbox first: a pane busy once its inbox is held is released and handed to the retry worker; an abort releases the hold too, with no registry name (Fri Oct 30th 2026)"
HOLD="$HOME/.local/state/stackshot/anchor-hub"; mkdir -p "$HOLD"      # the default SALA_INBOX_HOLD_DIR: present, so the hold is taken (a missing dir is a no-op)
LEDGER="$HOME/.claude/salamander-inbox-holds.tsv"
# FAKE_NAME= (empty): the registry has no name for the pane, so the hold's second key is empty (hname="")
mk hb "$(uuid 23)" -e FAKE_NAME= -e FAKE_TURN_MS=40000; waitfor "reg_live '\"sessionId\":\"$(uuid 23)\"'" 40
SP=$(tmux display -p -t sala-test-hb '#{pane_id}')
( while ! grep -qxF "$(uuid 23)" "$HOLD/held-msg.txt" 2>/dev/null; do sleep 0.02; done
  $T send-keys -t sala-test-hb -l 'a notice arrives'; $T send-keys -t sala-test-hb Enter ) & HBW=$!   # the line a puller handed out just before the hold: a turn once held
swout=$(SALA_SELF_WAIT=3 SALA_HOLD_SETTLE=1 "$SALA" revive --self-worker "$SP" 2>&1) && ok "the self-worker handed a busy pane over (exit 0), it did not give up" || bad "self-worker failed: $swout"
kill "$HBW" 2>/dev/null; wait "$HBW" 2>/dev/null
echo "$swout" | grep -q "self-worker: not relaunchable within .*registry says 'busy'.*it was not idle once its inbox was held" && ok "it saw the turn at the re-check after the hold (not at its first wait)" || bad "no re-check hand-off line: $swout"
waitfor '[ "$(workers)" = 1 ]' 10 && ok "the retry worker was started for it (the pane is queued, not dropped)" || bad "retry workers: $(workers)"
! grep -q "$(uuid 23)" "$HOLD/held-msg.txt" "$HOLD/held-hub.txt" 2>/dev/null && [ ! -s "$LEDGER" ] && ok "its hold is released before the hand-off (held lists and ledger empty), with an empty registry name" || bad "hold left behind: $(cat "$HOLD/held-msg.txt" "$LEDGER" 2>/dev/null)"
! grep -q "^exit $(uuid 23) " "$FAKE_LOG" && ok "no /exit was typed over the turn" || bad "an /exit was typed over the turn"
for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done; waitfor '[ "$(workers)" = 0 ]' 20 || bad "the retry worker did not stop"
$T kill-session -t sala-test-hb; : > "$POSTS"
# an abort after the hold (text typed at the prompt once held: pane_exit refuses, rc 3) releases it as well, with no name
mk hd "$(uuid 24)" -e FAKE_NAME=; waitfor "reg_live '\"sessionId\":\"$(uuid 24)\"'" 40
SP=$(tmux display -p -t sala-test-hd '#{pane_id}')
( while ! grep -qxF "$(uuid 24)" "$HOLD/held-msg.txt" 2>/dev/null; do sleep 0.02; done
  $T send-keys -t sala-test-hd -l 'half a thought' ) & HDW=$!
swout=$(SALA_SELF_WAIT=3 SALA_HOLD_SETTLE=1 "$SALA" revive --self-worker "$SP" 2>&1) && bad "the self-worker did not abort over text at the prompt: $swout" || ok "the self-worker aborted (exit 1) over text typed at the prompt after the hold"
kill "$HDW" 2>/dev/null; wait "$HDW" 2>/dev/null
echo "$swout" | grep -q "self-worker: unsubmitted text is sitting at the prompt" && ok "it said why" || bad "no abort line: $swout"
! grep -q "$(uuid 24)" "$HOLD/held-msg.txt" "$HOLD/held-hub.txt" 2>/dev/null && [ ! -s "$LEDGER" ] && ok "wabort released the hold by the uuid although the registry name is empty" || bad "hold left behind: $(cat "$HOLD/held-msg.txt" "$LEDGER" 2>/dev/null)"
$T kill-session -t sala-test-hd; : > "$POSTS"
echo "== SALA_NO_RELAUNCH: a listed session is excluded from a recycle's sweep, not skipped (Tue Oct 13th 2026)"
mk nm "$(uuid 20)"; mk n1 "$(uuid 21)"; mk n2 "$(uuid 22)"; fake_up nm n1 n2
SP=$(tmux display -p -t sala-test-nm '#{pane_id}'); S8="$(date +%s)-$$"; set_point recycle "$S8"; SK="$HOME/skipped.txt"; : > "$SK"
out=$(SALA_NO_RELAUNCH="other sala-test-n2" SALA_RECYCLE=1 SALA_SET="$S8" SALA_SET_SELF="$SP" SALA_SKIP_PANE="$SP" SALA_RECYCLE_SKIPPED_FILE="$SK" "$SALA" revive --force 2>&1)
[ "$(grep -c "^start $(uuid 21)" "$FAKE_LOG")" = 2 ] && ok "the unlisted pane was relaunched" || bad "n1 not relaunched: $out"
[ "$(grep -c "^start $(uuid 22)" "$FAKE_LOG")" = 1 ] && echo "$out" | grep -q 'sala-test-n2:0: not relaunched — SALA_NO_RELAUNCH' && ok "the listed pane was not relaunched, and the summary says so" || bad "n2: $(grep "$(uuid 22)" "$FAKE_LOG"); $out"
! grep -q 'sala-test-n2' "$SK" && ! echo "$out" | sed -n '/⚠ skipped/,/⊘/p' | grep -q 'sala-test-n2' && ok "not in the skipped list nor the post-recycle hook's skipped file" || bad "n2 counted as skipped: $(<"$SK"); $out"
[ "$(set_val "$S8" total)" = 2 ] && [ "$(set_val "$S8" done)" = 1 ] && ! grep -q 'sala-test-n2' "$SALA_SET_DIR/$S8" && ok "the set: N=2 (n1 and the master's pane), the listed pane neither counted nor outstanding" || bad "set: $(<"$SALA_SET_DIR/$S8")"
out=$(SALA_NO_RELAUNCH="sala-test-n2" "$SALA" revive --only sala-test-n2 --force 2>&1) && bad "--only on a listed session did not refuse: $out" || { echo "$out" | grep -q 'not relaunched — SALA_NO_RELAUNCH' && [ "$(grep -c "^start $(uuid 22)" "$FAKE_LOG")" = 1 ] && ok "--only on a listed session refuses, nothing relaunched" || bad "--only refusal: $out"; }
out=$(SALA_NO_RELAUNCH="sala-test-n2"; restore_session sala-test-n2) && bad "restore of a listed session did not refuse: $out" || ok "restore_session refuses a listed session"
$T kill-session -t sala-test-nm; $T kill-session -t sala-test-n1; $T kill-session -t sala-test-n2; : > "$POSTS"
[ "$fail" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
