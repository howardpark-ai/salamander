#!/usr/bin/env bash
# THE PAUSE (lib/common.sh "THE PAUSE", lib/revive.sh pause_try, lib/watch.sh pause_watch_due, lib/pauseinfo.py, lib/note.sh):
# a relaunch that has waited SALA_PAUSE_AFTER seconds (default 900) for a busy pane interrupts the turn with ONE Escape, relaunches the
# session through the ordinary path and leaves it a note, written by the relaunch, saying what it was doing. Checked here with a short
# SALA_PAUSE_AFTER (6 s) and a fake claude whose Esc turns a busy registry row idle (FAKE_ESC_IDLE):
#   - the knobs: SALA_PAUSE_AFTER (seconds; 0/off/no = the old wait; junk = the default 900), SALA_PAUSE_SCOPE (all | background | off), the
#     clock (starts on the first pass, restarts when the pane was last seen held longer ago than SALA_PAUSE_GAP, stops when the pane is free);
#   - before the deadline: nothing is sent, the pane waits as before, its stackshot inbox is held; at the deadline: one Escape, the pane
#     relaunched (same conversation), the held inbox released, the note written for the session and handed over after the resume, the row
#     and the set say "paused at …", the exit dialog's background work stopped by the pause;
#   - who is never paused: a pane with unsent text, a session in SALA_NO_PAUSE, the pane the recycle runs from, a pane whose Escape does not
#     bring it out of its turn (nothing more is typed, no /exit);
#   - off keeps the old wait; scope off and background (no back-agent role here) keep a front agent waiting; the dry run says what it would do;
#   - lib/pauseinfo.py: the descriptions of the calls in flight and the last line, never a command or a result; the inbox's sender and first line;
#   - a deferred pane (watch) is paused the same way, once its clock runs out.
# Slack stubbed to a file; isolated HOME, a private tmux socket, the compiled fake claude (tests/fake-claude.c). Usage: bash tests/pause.sh
# (exit 0 = pass; ~2 min)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SET SALA_SET_SELF SALA_POST_RECYCLE_CMD SALA_RECYCLE SALA_RETRY_WORKER SALA_NO_RELAUNCH SALA_SKIP_PANE SALA_NO_PAUSE SALA_NO_PAUSE_PANE
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, tmux_socket_rm
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
as_op_unit
HOLD_A=anchor   # the inbox hold folder is named from two words, so the literal path is not in this file
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOME/.local/state/stackshot/${HOLD_A}-hub" "$HOME/.local/state/stackshot/inbox/msg" "$HOME/.local/state/stackshot/inbox/hub"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"
printf '#!/bin/sh\necho "$*" >> "%s/systemd-run.txt"\n' "$HOME" > "$HOME/.local/bin/systemd-run"; chmod +x "$HOME/.local/bin/systemd-run"   # watch launches nothing
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log" FAKE_SOCK_LOG="$HOME/sock.log" FAKE_TYPED_LOG="$HOME/typed.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off SALA_MOD_WAIT=1
export SALA_PAUSE_SCOPE=all SALA_PAUSE_AFTER=6 SALA_PAUSE_IDLE_WAIT=4 SALA_IDLE_SETTLE=2 SALA_PAUSE_QUIET=0   # the production values are 900, 20, 10 and 120
export SALA_DEFERRED_TRY=1   # a direct `revive --only` that skips a busy pane starts no retry worker of its own: the passes are the test's, and the retry worker is started by hand where it is checked
SALA="$ROOT/bin/salamander"; SOCK="sala-pause-$$"; T="tmux -L $SOCK -f /dev/null"; WLOG="$HOME/.claude/salamander-watch.log"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"
cleanup() {
    local p f; for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done   # a retry worker this suite started, by its pid file
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    for p in $(pgrep -x claude); do [ "$HOME/.local/share/claude/versions/9.9.9" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done   # by pid, and only our own fake binary
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux
. "$ROOT/lib/common.sh"
PD="$SALA_STATE_DIR/pause"; NOTES="$SALA_LOG_DIR/salamander-notes.tsv"; HM="$SALA_INBOX_HOLD_DIR/held-msg.txt"
wait_lock() { lock_wait "$SALA_RECYCLE_LOCK" 80; }
mk() { local n="$1" u="$2"; shift 2; $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="sala-test-$n" -e FAKE_LOG="$FAKE_LOG" -e FAKE_SOCK_LOG="$FAKE_SOCK_LOG" -e FAKE_TYPED_LOG="$FAKE_TYPED_LOG" "$@"; $T send-keys -t "sala-test-$n" 'claude' Enter; }
busy() { set_reg_status "$(cpid "$1")" busy; }
escs() { local n; n=$(grep -c "^esc $1 " "$FAKE_LOG" 2>/dev/null); echo "${n:-0}"; }       # <uuid> → the Escapes the fake took while busy
typed() { local n; n=$(grep -c "^$1 $2\$" "$FAKE_TYPED_LOG" 2>/dev/null); echo "${n:-0}"; }   # <uuid> <line> → times that line was typed
age_clock() { mkdir -p "$PD"; printf '%s %s\n' "$(( $(date +%s) - ${2:-100} ))" "$(date +%s)" > "$PD/$1.wait"; }   # <uuid> [secs] → its clock has run that long
revive_only() { OUT=$("$SALA" revive --force --only "$1" 2>&1); RC=$?; }
nsock() { grep -c "^$1 .*sala note" "$FAKE_SOCK_LOG" 2>/dev/null || true; }
UA=$(uuid 31); UD=$(uuid 32); UN=$(uuid 33); UI=$(uuid 34); UW=$(uuid 35); UE=$(uuid 36); UR=$(uuid 37)

echo "== the knobs"
SALA_PAUSE_AFTER=off pause_after_r v; [ "$v" = 0 ] && ok "SALA_PAUSE_AFTER=off reads as 0 (the old wait)" || bad "off → $v"
SALA_PAUSE_AFTER=0 pause_after_r v; [ "$v" = 0 ] && ok "SALA_PAUSE_AFTER=0 reads as 0" || bad "0 → $v"
SALA_PAUSE_AFTER=45 pause_after_r v; [ "$v" = 45 ] && ok "SALA_PAUSE_AFTER=45 reads as 45 s" || bad "45 → $v"
SALA_PAUSE_AFTER=soon pause_after_r v; [ "$v" = 900 ] && ok "a word that is no number reads as the default, 15 min" || bad "junk → $v"
grep -q ': "${SALA_PAUSE_AFTER:=900}"' "$ROOT/lib/common.sh" && grep -q ': "${SALA_PAUSE_SCOPE:=background}"' "$ROOT/lib/common.sh" && ok "the defaults are 900 s (15 min) and scope background" || bad "defaults in lib/common.sh"
SALA_PAUSE_SCOPE=off pause_after_r v; [ "$v" = 0 ] && ok "SALA_PAUSE_SCOPE=off switches the pause off too" || bad "scope off → $v"
ORIG_BLN=$(declare -f back_lane_names); back_lane_names() { echo sala-test-back; }   # the registry's back agents, stubbed
SALA_PAUSE_SCOPE=all pause_scope_ok sala-test-front && ok "scope all: a front agent may be paused (only when asked for)" || bad "scope all refused a front agent"
SALA_PAUSE_SCOPE=background pause_scope_ok sala-test-front && bad "scope background let a front agent through" || ok "scope background: a front agent is not paused"
SALA_PAUSE_SCOPE=background pause_scope_ok sala-test-back && ok "scope background: a back agent is" || bad "scope background refused a back agent"
SALA_PAUSE_SCOPE=off pause_scope_ok sala-test-back && bad "scope off let a back agent through" || ok "scope off: nobody"
(unset SALA_PAUSE_SCOPE; pause_scope_ok sala-test-front) && bad "the default scope let a front agent through" || ok "the default scope: a front agent is never paused"
(unset SALA_PAUSE_SCOPE; pause_scope_ok sala-test-back) && ok "the default scope: a back agent may be" || bad "the default scope refused a back agent"
(SALA_PAUSE_SCOPE=everyone; pause_scope_ok sala-test-front) && bad "a word that is no scope let a front agent through" || ok "a word that is no scope reads as the narrower default, background"
eval "$ORIG_BLN"

echo "== the clock"
rm -rf "$PD"
pause_clock_age_r v "$UA"; [ "$v" = -1 ] && ok "no clock: -1" || bad "no clock → $v"
pause_clock_r v "$UA"; [ "$v" = 0 ] && [ -s "$PD/$UA.wait" ] && ok "the first pass starts it (0 s on it)" || bad "start → $v"
age_clock "$UA" 100; pause_clock_age_r v "$UA"; [ "$v" -ge 100 ] && pause_due "$UA" && ok "a clock with 100 s on it is due at 6 s" || bad "aged → $v"
printf '%s %s\n' "$(( $(date +%s) - 4000 ))" "$(( $(date +%s) - 3000 ))" > "$PD/$UA.wait"; pause_clock_age_r v "$UA"; [ "$v" = -1 ] && ! pause_due "$UA" && ok "last seen held 3000 s ago (over SALA_PAUSE_GAP): the clock is stale, not due" || bad "stale → $v"
pause_clock_r v "$UA"; [ "$v" = 0 ] && ok "and the next pass restarts it: busy continuously, not on and off" || bad "restart → $v"
age_clock "$UA" 4; pause_next_in_r v "$UA" "" "$UD"; [ "$v" = 2 ] && ok "pause_next_in_r: 2 s to go on a 4 s clock (the retry worker's sleep)" || bad "next_in → $v"
pause_clock_clear "$UA"; pause_next_in_r v "$UA"; [ "$v" = -1 ] && ok "a cleared clock: none" || bad "cleared → $v"

echo "== lib/pauseinfo.py: descriptions and the last line, never a command or a result"
J="$HOME/t.jsonl"
{
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"older line"}}'
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"build the copy switch page and ship it, token=hunter2hunter2hunter2"}}'
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Agent","input":{"description":"Build page-creation PR for copy switch","prompt":"SECRET_PROMPT_TEXT","run_in_background":true}}]}}'
    printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"Async agent launched"}]}}'
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"description":"Wait for the release unit","command":"SECRET_COMMAND_TEXT --wait"}}]}}'
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"description":"Run the finished check","command":"echo done"}}]}}'
    printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t3","content":"SECRET_RESULT_TEXT"}]}}'
} > "$J"
out=$(SALA_SCRUB_PY="$SALA_SCRUB_PY" python3 -I -S "$ROOT/lib/pauseinfo.py" "$J")
has "$out" $'trigger\tbuild the copy switch page and ship it' && ok "the last human line is the trigger" || bad "trigger: $out"
has "$out" $'pending\tBash: Wait for the release unit' && ok "a call with no result yet is listed by its description" || bad "pending: $out"
has "$out" $'started\tAgent: Build page-creation PR for copy switch' && ok "a call that went to the background is listed as started" || bad "started: $out"
has "$out" 'Run the finished check' && bad "an answered call listed: $out" || ok "an answered call is not in flight"
has "$out" 'hunter2' && bad "a token reached the output: $out" || ok "a token in the last line is masked"
has "$out" SECRET && bad "a command, a prompt or a result reached the output: $out" || ok "no command, prompt or tool result is printed"
has "$out" 'older line' && bad "an older turn's line shows: $out" || ok "an older turn is not the trigger"
[ "$(python3 -I -S "$ROOT/lib/pauseinfo.py" "$HOME/none.jsonl"; echo $?)" = 0 ] && ok "an unreadable transcript: nothing printed, exit 0" || bad "missing transcript"
IB="$HOME/.local/state/stackshot/inbox"
printf '{"id":"a","ts":1000.5,"src":"msg","to":"sala-test-a","uuid":"%s","name":"sala-test-a","text":"\\n\\nplease look at the release\\nsecond line","from":"infra-x"}\n' "$UA" > "$IB/msg/1-a.json"
printf '{"id":"b","ts":900.5,"src":"hub","to":"sala-test-other","uuid":"zzz","name":"sala-test-other","text":"not for it","from":"someone"}\n' > "$IB/hub/2-b.json"
printf '{"id":"c","ts":1100.5,"src":"msg","to":"sala-test-a-extra","uuid":"yyy","name":"sala-test-a-extra","text":"for the extra one","from":"someone"}\n' > "$IB/msg/3-c.json"
out=$(python3 -I -S "$ROOT/lib/pauseinfo.py" inbox "$IB" sala-test-a "$UA")
[ "$out" = $'inbox\tinfra-x\tplease look at the release' ] && ok "the inbox lines for the session: sender and first line only, no other session's" || bad "inbox: $out"
rm -f "$IB"/msg/*.json "$IB"/hub/*.json

echo "== the note's words"
txt=$(pause_note_text "recycle" 1700000000 900 <<< $'trigger\tbuild it\nsubagent\tbuilder: PR 12\npending\tAgent: Build page\nstarted\tBash: Wait for the unit\nprocs\t2\t600\ninbox\tinfra-x\tplease look\ninbox\t(and 1 more)\t')
for w in '[paused] Your turn was paused by a recycle' 'The last line you were working from: "build it"' 'Subagents running when it was paused' 'builder: PR 12' 'Calls of that turn still waiting for a result: Agent: Build page' 'Wait for the unit' '2 background process(es)' 'infra-x: "please look"' 'in its own systemd unit goes on without you'; do
    has "$txt" "$w" && ok "the note says: $w" || bad "note lacks '$w': $txt"
done
txt=$(pause_note_text "recycle" 1700000000 60 <<< $'inboxkind\tmsg'); has "$txt" 'A msg line was waiting in your inbox' && ok "a server-mode box (no inbox folder): the note says a line waits" || bad "inboxkind: $txt"

echo "== the panes: a (the pause), d (a draft), n (SALA_NO_PAUSE), i (an Escape that does nothing), e (the switches), w (deferred), r (the retry worker)"
mk a "$UA" -e FAKE_ESC_IDLE=1 -e FAKE_EXIT_DIALOG='subagent · worker'
mk d "$UD" -e FAKE_ESC_IDLE=1; mk n "$UN" -e FAKE_ESC_IDLE=1; mk i "$UI"; mk e "$UE" -e FAKE_ESC_IDLE=1; mk w "$UW" -e FAKE_ESC_IDLE=1; mk r "$UR" -e FAKE_ESC_IDLE=1
fake_up sala-test-a sala-test-d sala-test-n sala-test-i sala-test-e sala-test-w sala-test-r
for p in a d n i e w r; do busy "$p"; done
# the transcript the note reads: the pane's cwd is $HOME
TD="$SALA_PROJECTS/$(slug_for_cwd "$HOME")"; mkdir -p "$TD"; cp "$J" "$TD/$UA.jsonl"

echo "== a: before the deadline nothing is sent; the inbox is held; at the deadline one Escape, the relaunch, the note"
printf '{"id":"m1","ts":1000.5,"src":"msg","to":"sala-test-a","uuid":"%s","name":"sala-test-a","text":"is the release done?\\nmore","from":"infra-x"}\n' "$UA" > "$IB/msg/1-m1.json"
revive_only sala-test-a
has "$OUT" "sala-test-a:0: registry says 'busy'" && ok "the first pass: busy, left on its version, as before" || bad "pass 1: $OUT"
[ "$(escs "$UA")" = 0 ] && [ "$(starts "$UA")" = 1 ] && ok "nothing sent, not relaunched" || bad "pass 1: escs $(escs "$UA") starts $(starts "$UA")"
[ -s "$PD/$UA.wait" ] && ok "the clock started" || bad "no clock"
grep -qF "$UA" "$HM" 2>/dev/null && ok "its stackshot inbox is held while the relaunch waits" || bad "no hold: $(cat "$HM" 2>/dev/null)"
wait_lock; revive_only sala-test-a
[ "$(escs "$UA")" = 0 ] && [ "$(starts "$UA")" = 1 ] && ok "a second pass before the deadline: still nothing sent" || bad "pass 2: escs $(escs "$UA")"
age_clock "$UA" 100; wait_lock; revive_only sala-test-a
has "$OUT" "sala-test-a:0: paused after" && has "$OUT" 'its turn was interrupted with one Escape' && ok "at the deadline: paused, said in the output" || bad "pass 3: $OUT"
[ "$(escs "$UA")" = 1 ] && ok "exactly one Escape reached the pane" || bad "escs: $(escs "$UA")"
has "$OUT" 'pause — the exit dialog listed background work (subagent · worker), stopped by the pause' && ok "the exit dialog's background work is stopped by the pause, said" || bad "dialog: $OUT"
waitfor '[ "$(starts "$UA")" = 2 ]' 40 && fake_up sala-test-a && has "$OUT" 'sala-test-a:0: 9.9.9 → 9.9.9' && ok "relaunched on the same conversation" || bad "relaunch: starts $(starts "$UA") $OUT"
[ "$(typed "$UA" /exit)" = 1 ] && ok "/exit typed once, after the Escape" || bad "/exit typed $(typed "$UA" /exit)"
has "$OUT" 'paused at ' && has "$OUT" 'resumes on relaunch' && ok "the row says it was paused" || bad "row: $OUT"
nl=$(grep -c '^' "$NOTES" 2>/dev/null); [ "${nl:-0}" = 1 ] && ok "one note was left" || bad "notes: $(cat "$NOTES" 2>/dev/null)"
note=$(slurp "$NOTES")
has "$note" $'\tsala-test-a\t'"$UA"$'\t' && has "$note" '[paused] Your turn was paused by a' && ok "the note is for that conversation and starts [paused]" || bad "note: $note"
has "$note" 'Build page-creation PR for copy switch' && has "$note" 'Wait for the release unit' && has "$note" 'build the copy switch page' && ok "it names the subagent and call descriptions and the line it was working from" || bad "note text: $note"
has "$note" 'infra-x: "is the release done?"' && ok "it names the message held for it: sender and first line" || bad "inbox in note: $note"
has "$note" SECRET && bad "the note carries a command or a result" || ok "no command or result in the note"
has "$note" hunter2 && bad "a token in the note" || ok "no token in the note"
grep -qF "$UA" "$HM" 2>/dev/null && bad "the inbox is still held: $(cat "$HM")" || ok "the held inbox was released with the relaunch"
[ ! -e "$PD/$UA.wait" ] && [ ! -e "$PD/$UA.paused" ] && [ -s "$PD/$UA.resumed" ] && ok "the clock is gone, the pause is over (resumed marker)" || bad "pause files: $(ls "$PD")"
waitfor '[ "$(nsock "$UA")" -ge 1 ]' 40 && ok "the note reached the relaunched session (delivered through its messaging socket)" || { "$SALA" note --deliver >/dev/null 2>&1; waitfor '[ "$(nsock "$UA")" -ge 1 ]' 20 && ok "the note reached the relaunched session (delivered by the next tick)" || bad "not delivered: $(cat "$FAKE_SOCK_LOG" 2>/dev/null | tail -3)"; }
has "$(slurp "$FAKE_SOCK_LOG")" 'written by the relaunch' && ok "and it says the relaunch wrote it, not the session" || bad "delivery text: $(tail -2 "$FAKE_SOCK_LOG")"
wait_lock

echo "== d: unsent text at the prompt is never interrupted"
$T send-keys -t sala-test-d -l 'half typed sentence'; sleep 1
age_clock "$UD" 100; revive_only sala-test-d
has "$OUT" 'not paused — unsent text is sitting at its prompt' && [ "$(escs "$UD")" = 0 ] && [ "$(starts "$UD")" = 1 ] && ok "a draft: not paused, no Escape, said why" || bad "draft: escs $(escs "$UD") $OUT"
grep -qF "$UD" "$HM" 2>/dev/null && bad "a pane that is never paused had its inbox held" || ok "and its inbox was not held for a pause that cannot come"
wait_lock

echo "== n: a session in SALA_NO_PAUSE waits as before"
age_clock "$UN" 100; OUT=$(SALA_NO_PAUSE="sala-test-x sala-test-n" "$SALA" revive --force --only sala-test-n 2>&1)
has "$OUT" 'not paused — it is in SALA_NO_PAUSE' && [ "$(escs "$UN")" = 0 ] && [ "$(starts "$UN")" = 1 ] && ok "SALA_NO_PAUSE: not paused, said why" || bad "no-pause: escs $(escs "$UN") $OUT"
wait_lock
age_clock "$UN" 100; OUT=$(SALA_SKIP_PANE="$(tmux display -p -t sala-test-n '#{pane_id}')" "$SALA" revive --force --only sala-test-n 2>&1)
[ "$(escs "$UN")" = 0 ] && ok "the pane the recycle runs from: never interrupted" || bad "own pane: escs $(escs "$UN") $OUT"
pause_refusal_r v "$(tmux display -p -t sala-test-n '#{pane_id}')" sala-test-n "$(cpid n)"; [ -z "$v" ] && ok "(control: no refusal for it without the switches)" || bad "control refusal: $v"
SALA_SKIP_PANE="$(tmux display -p -t sala-test-n '#{pane_id}')" pause_refusal_r v "$(tmux display -p -t sala-test-n '#{pane_id}')" sala-test-n "$(cpid n)"; has "$v" 'pane this recycle runs from' && ok "pause_refusal_r names SALA_SKIP_PANE" || bad "skip-pane refusal: $v"
SALA_NO_PAUSE_PANE="$(tmux display -p -t sala-test-n '#{pane_id}')" pause_refusal_r v "$(tmux display -p -t sala-test-n '#{pane_id}')" sala-test-n "$(cpid n)"; has "$v" 'pane that asked for this relaunch' && ok "and SALA_NO_PAUSE_PANE (the self-worker's hand-off)" || bad "no-pause-pane refusal: $v"
wait_lock

echo "== i: an Escape that does not bring the pane out of its turn: nothing more is sent, no /exit"
age_clock "$UI" 100; revive_only sala-test-i
has "$OUT" 'not paused — one Escape did not bring the pane out of its turn within 4s' && ok "the Escape did nothing: said, the pane waits as before" || bad "no-idle: $OUT"
[ "$(typed "$UI" /exit)" = 0 ] && [ "$(starts "$UI")" = 1 ] && [ ! -e "$PD/$UI.paused" ] && [ ! -e "$PD/$UI.wait" ] && ok "no /exit typed into a pane still in its turn; the pause marker removed, the clock restarted" || bad "i: /exit $(typed "$UI" /exit) starts $(starts "$UI") $(ls "$PD")"
wait_lock

echo "== e: the dry run, off, the scope"
rm -f "$PD/$UE.wait"; OUT=$("$SALA" revive --dry-run --force --only sala-test-e 2>&1)
has "$OUT" '[dry-run] sala-test-e:0: held' && has "$OUT" 'would wait 6 s' && has "$OUT" 'then pause its turn (one Escape)' && ok "the plan says it would wait, then pause its turn" || bad "dry run: $OUT"
[ ! -e "$PD/$UE.wait" ] && [ "$(escs "$UE")" = 0 ] && ok "the dry run writes no clock and sends nothing" || bad "dry run wrote: $(ls "$PD")"
OUT=$(env -u SALA_PAUSE_SCOPE "$SALA" revive --dry-run --force --only sala-test-e 2>&1)
has "$OUT" 'it would not be paused' && has "$OUT" 'a front agent is never paused' && has "$OUT" 'SALA_PAUSE_SCOPE=all pauses every session' && ok "the plan under the default scope says a front agent is never paused, and how to change it" || bad "dry run, default scope: $OUT"
age_clock "$UE" 100; OUT=$(SALA_PAUSE_AFTER=off "$SALA" revive --force --only sala-test-e 2>&1)
[ "$(escs "$UE")" = 0 ] && [ "$(starts "$UE")" = 1 ] && has "$OUT" "registry says 'busy'" && ok "SALA_PAUSE_AFTER=off: the old wait, nothing sent" || bad "off: escs $(escs "$UE") $OUT"
wait_lock; OUT=$(SALA_PAUSE_SCOPE=off "$SALA" revive --force --only sala-test-e 2>&1)
[ "$(escs "$UE")" = 0 ] && [ "$(starts "$UE")" = 1 ] && ok "SALA_PAUSE_SCOPE=off: nothing sent" || bad "scope off: escs $(escs "$UE") $OUT"
wait_lock; OUT=$(env -u SALA_PAUSE_SCOPE "$SALA" revive --force --only sala-test-e 2>&1)
[ "$(escs "$UE")" = 0 ] && [ "$(starts "$UE")" = 1 ] && ok "the default scope: a front agent (no back-agent role) waits as before, nothing sent" || bad "default scope: escs $(escs "$UE") $OUT"
wait_lock; OUT=$(SALA_PAUSE_SCOPE=background "$SALA" revive --force --only sala-test-e 2>&1)
[ "$(escs "$UE")" = 0 ] && [ "$(starts "$UE")" = 1 ] && ok "SALA_PAUSE_SCOPE=background: a session with no back-agent role waits as before" || bad "scope background: escs $(escs "$UE") $OUT"
wait_lock

echo "== w: a deferred pane (watch) is paused once its clock has run out"
now=$(date +%s)
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' sala-test-w "$((now - 600))" "background work is running (a subagent)" "$(cpid w)" 1 - 0 0 0 > "$SALA_DEFERRED"
rm -f "$PD/$UW.wait" "$PD/$UW.tried"
"$SALA" watch >/dev/null 2>&1
[ -s "$PD/$UW.wait" ] && [ "$(escs "$UW")" = 0 ] && [ "$(starts "$UW")" = 1 ] && ok "watch's first look starts the clock and sends nothing" || bad "watch 1: $(ls "$PD") escs $(escs "$UW")"
grep -qF "$UW" "$HM" 2>/dev/null && ok "and holds its inbox while it waits" || bad "no hold for the deferred pane: $(cat "$HM" 2>/dev/null)"
age_clock "$UW" 100; "$SALA" watch >/dev/null 2>&1
has "$(slurp "$WLOG")" 'sala-test-w held' && has "$(slurp "$WLOG")" "pause's deadline" && ok "the next look: the deadline reached, revive --only asked to pause it (watch's log)" || bad "watch log: $(tail -5 "$WLOG")"
waitfor '[ "$(starts "$UW")" = 2 ]' 40 && [ "$(escs "$UW")" = 1 ] && ok "one Escape, the pane relaunched" || bad "w: escs $(escs "$UW") starts $(starts "$UW")"
grep -qF "$UW" "$NOTES" && ok "its note is written" || bad "no note for w: $(cat "$NOTES")"
[ ! -s "$SALA_DEFERRED" ] && ok "the row left the deferred list (relaunched)" || bad "deferred: $(cat "$SALA_DEFERRED")"

echo "== r: the retry worker wakes for the pause's deadline, not at its next SALA_RETRY_EVERY (300 s)"
revive_only sala-test-r; age_clock "$UR" 100; wait_lock
RP=$(tmux display -p -t sala-test-r '#{pane_id}'); : > "$POSTS"
setsid "$SALA" revive --retry-worker --force -- "$RP|sala-test-r|sala-test-r:0|$(cpid r)" </dev/null >> "$HOME/worker.log" 2>&1 &
waitfor '[ "$(starts "$UR")" = 2 ]' 120 && [ "$(escs "$UR")" = 1 ] && ok "the worker tried the pane at the clock's deadline (a sleep of 30 s, not 300 s) and the pause relaunched it" || bad "r: starts $(starts "$UR") escs $(escs "$UR") $(tail -5 "$HOME/worker.log")"
waitfor 'has "$(slurp "$HOME/worker.log")" "sala-test-r:0: relaunched on"' 30 && has "$(slurp "$HOME/worker.log")" 'paused after' && ok "the worker's log says the pane was paused and relaunched" || bad "worker log: $(tail -5 "$HOME/worker.log")"
waitfor 'has "$(slurp "$POSTS")" "paused at"' 60 && ok "the closure post says the session was paused" || bad "closure: $(slurp "$POSTS")"

echo "== the set and the op's result carry the pause"
set_create 9999-1 Recycle all 2 0 9.9.9 1 "out=sala-test-a"
set_paused 9999-1 "sala-test-a: paused at 13:12 after 15 min of holding the relaunch"
[ "$(set_val 9999-1 paused)" = "sala-test-a: paused at 13:12 after 15 min of holding the relaunch" ] && ok "set_paused records the line in the set" || bad "set: $(cat "$SALA_SET_DIR/9999-1")"
set_paused 0000-none "x" ; [ ! -e "$SALA_SET_DIR/0000-none" ] && ok "no set, no line" || bad "a set was made"
grep -q 'OP_PL+=("$y")' "$ROOT/lib/op.sh" && grep -q 'set_vals "$set" paused' "$ROOT/lib/op.sh" && ok "op_finish names the paused sessions in the post and in the hearing session's line" || bad "op.sh does not read the set's paused lines"

[ "$fail" = 0 ] && echo "pause: all passed" || echo "pause: FAILED"
exit "$fail"
