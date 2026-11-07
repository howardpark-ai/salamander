#!/usr/bin/env bash
# The idle wrap-up and clear of background agents (Thu Oct 29th 2026; lib/wrapup.sh, called by lib/watch.sh; the cleared
# agent's context line in lib/hook.sh `session-start`). A background agent that has been idle for SALA_IDLE_WRAPUP_MIN is asked to write
# down what only it knows, and when that turn is over its conversation is cleared; the pane map follows the new conversation. What is
# checked, on a private tmux server with the compiled fake claude (a registry row aged by FAKE_IDLE_AGE, a message that is a turn by
# FAKE_TURN_MS, /clear as the real CLI does it: the same row and pid, a new sessionId; the Stop hook's record written by hand):
#  - an idle back-role pane with a turn behind it gets the exact wrap-up text (marked), its turn runs, then /clear is typed, in that
#    order; the row's name stays, the registry shows a new sessionId, the pane map follows it (and the session registry records it as
#    `clear`), one log line each, no post;
#  - left alone, each with its reason in the log: a front agent, a side session, a pane mid-turn, a pane with a background process, text
#    typed in its input box (still there afterwards), a parked pane, one idle for less than the threshold, one relaunched with no turn
#    since (the Stop record older than its start), a dialog on the screen, an sdk-lane pane, a last turn that left a scheduled job;
#  - never twice with no wake between: the cleared pane, idle again for an hour, is left alone until its new conversation has had a
#    turn; after one it is wrapped up again (this time by a plain `watch` tick: the wiring);
#  - the off switches (SALA_IDLE_WRAPUP=off, SALA_IDLE_WRAPUP_MIN=0) type nothing; so does SALA_IDLE_WRAPUP unset or garbage (off by default; the suite exports =on); --dry-run says what it would do and changes nothing;
#  - a pane relaunched or cleared between the two steps drops its state; a wrap-up that produced no turn is dropped and not tried again
#    at once; a /clear the CLI does not take is tried SALA_CLEAR_TRIES times, recorded `failed`, and the pane is not wrapped up again
#    until its conversation has a new Stop record;
#  - a pane idle past SALA_IDLE_WRAPUP_MAX_AGE (the warm window) gets neither a wrap-up nor a clear, one log line; the bound is a knob;
#  - an empty list of back names (an unreadable sessions.json) keeps the in-flight states; a healthy list still purges a gone session;
#  - the SessionStart hook: source clear in a back row prints the context line (name and project), a front row, a start and
#    SALA_CLEAR_CONTEXT=off print nothing.
# SAFETY: the tmux server is a private socket (tmux -L sala-wrapup-<pid> -f /dev/null, SALA_TMUX_SOCKET pointing at it), HOME is a mktemp -d,
# the claude is tests/fake-claude.c, every kill goes through kill_fake_claude (tests/lib.sh: /proc/<pid>/exe is the suite's own fake and its
# environment names this HOME); no real pane, server, ~/.claude or claude process is read or touched. Posts go to a file.
# Usage: bash tests/wrapup.sh   (exit 0 = pass)
set -u
unset TMUX TMUX_PANE XDG_STATE_HOME SALA_MASTER SALA_SET SALA_SET_SELF SALA_RECYCLE SALA_RETRY_WORKER SALA_LOCK_WHO SALA_LOCK_WAIT SALA_RELAUNCH_KIND \
      SALA_FLEET_HOSTS SALA_CGROUP_FILE SALA_OP_QUEUE SALA_NO_RELAUNCH SALA_BOOT_ID SALA_CONFIG SALA_IDLE_WRAPUP SALA_IDLE_WRAPUP_MIN SALA_CLEAR_CONTEXT SALA_SESSION_ID
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME=$(mktemp -d); export SALA_TZ=Etc/UTC SALA_CONFIG=/dev/null
case "$HOME" in /tmp/*|"${TMPDIR:-/tmp}"/*) ;; *) echo "wrapup: HOME is not a temporary directory ($HOME) - refusing to run"; exit 1;; esac
as_op_unit
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect"
touch "$HOME/.claude/salamander-rc.stopped"
FAKEBIN="$HOME/.local/share/claude/versions/9.9.9"
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$FAKEBIN" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$FAKEBIN" "$HOME/.local/bin/claude"
printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/systemd-run"
cat > "$HOME/.local/bin/systemctl" <<'EOF'
#!/bin/bash
case "$*" in *is-active*) exit 3 ;; *is-system-running*) echo running; exit 0 ;; *cat*tmux.service*) exit 1 ;; *) exit 0 ;; esac
EOF
chmod +x "$HOME/.local/bin/systemd-run" "$HOME/.local/bin/systemctl"
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log" FAKE_TYPED_LOG="$HOME/typed.log"
POSTS="$HOME/posts.txt"; : > "$POSTS"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off
export SALA_LIMIT_ALERT=off SALA_LIMIT_RESUME=off SALA_STUCK_POST=off SALA_BARE_REVIVE=off   # the other watches: not under test
export SALA_IDLE_WRAPUP=on   # off by default since the suite turns the step on explicitly, and the OFF-BY-DEFAULT check below unsets it
export SALA_IDLE_SETTLE=2 SALA_CLEAR_WAIT=6 SALA_WRAPUP_START_WAIT=300 SALA_IDLE_WRAPUP_MAX=10
# Rows are aged 55 min (FAKE_IDLE_AGE=3300) and keep aging while the suite runs; with the default bound of 58 min a slow runner (a
# run of 300 s) drifted them past the warm window. 65 min leaves 10 min of slack; the r section's 70 min row is still past it.
export SALA_IDLE_WRAPUP_MAX_AGE=65
SALA="$ROOT/bin/salamander"; SOCK="sala-wrapup-$$"; T="tmux -L $SOCK -f /dev/null"
export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's
case "$SOCK" in sala-wrapup-*) ;; *) echo "wrapup: not a private socket - refusing to run"; exit 1;; esac
WLOG="$HOME/.claude/salamander-watch.log"; ST="$HOME/.claude/salamander-watch.state"; : > "$WLOG"
cleanup() {
    $T kill-server 2>/dev/null; tmux_socket_rm
    kill_fake_claude "$FAKEBIN"
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux    # literal socket: the children run set -u
$T new-session -d -s sala-test-keep -x 200 -y 50 -c "$HOME"; $T set -g exit-empty off   # a server that outlives its last fake
. "$ROOT/lib/common.sh"
now0=$(date +%s); START=$((now0 - 10800)); TURN=$((now0 - 7200))   # the fakes' process started 3 h ago; their last turn ended 2 h ago
WRAP_TEXT="sala: you have been idle 50 minutes; your conversation is cleared after this turn. Write anything only you know to your items and pages (board update, page Current state or timeline line), then reply done."

# mk <suffix> <uuid n> [tmux -e options…] → a fake claude in sala-test-<suffix>, idle for 55 minutes, process started 3 h ago, a message is a 1.5 s turn
mk() {
    local n="$1" u; u=$(uuid "$2"); shift 2
    $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="sala-test-$n" -e FAKE_LOG="$FAKE_LOG" -e FAKE_TYPED_LOG="$FAKE_TYPED_LOG" \
        -e FAKE_IDLE_AGE=3300 -e FAKE_STARTED_AT="$START" -e FAKE_TURN_MS=1500 "$@"
    $T send-keys -t "sala-test-$n" 'claude' Enter
}
stoprec() { mkdir -p "$SALA_BUSY_DIR"; printf 'id=t%s\nepoch=%s\nseen=\nseen_status=idle\ntasks=0\ncrons=%s\n%s' "$1" "${2:-$TURN}" "${3:-0}" "${4:-}" > "$SALA_BUSY_DIR/$(uuid "$1")"; }   # <uuid n> [epoch] [crons] [extra lines]
set_reg_stamp() {  # <pid> <epoch s> → statusUpdatedAt of that claude's row = that second (a temp file and a rename)
    local f="$HOME/.claude/sessions/$1.json" t; t=$(slurp "$f")
    [[ $t =~ \"statusUpdatedAt\":[0-9]+ ]] && t=${t/"${BASH_REMATCH[0]}"/\"statusUpdatedAt\":${2}000}
    printf '%s' "$t" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
}
conv() { registry_field "$(cpid "$1")" sessionId; }                      # <suffix> → the conversation its claude is in now
typed() { local u="$1" l; { while IFS= read -r l || [ -n "$l" ]; do [[ $l == "$u "* ]] && echo "${l#"$u "}"; done < "$FAKE_TYPED_LOG"; } 2>/dev/null; }   # <uuid> → what reached its composer
tick() { "$SALA" watch --wrapup >/dev/null 2>&1; }
# The idle minutes in an output are wall-clock: a slow run (a loaded CI runner) crosses a minute boundary between the fake's setup and the tick,
# so a pane set to be idle 55 minutes may be reported as 56. norm turns every `idle <n> min` into `idle N min` (stdin to stdout), and every
# assertion on the log or the dry-run output matches and counts on the normalized text, with `idle N min` in the expected string.
norm() { sed -E 's/idle [0-9]+ min/idle N min/g'; }
wlogq() { norm < "$WLOG" | grep -qF -- "$1"; }   # <text with idle N min> -> is it in the log (normalized)
wlogn() { local n=0 l p; p=$(printf '%s' "$1" | norm); { while IFS= read -r l || [ -n "$l" ]; do [[ $l == *"$p"* ]] && n=$((n + 1)); done < <(norm < "$WLOG"); } 2>/dev/null; echo "$n"; }
wstate() { _kv_first "$ST" "$1"; }
_wu() { case "$1" in *-*) printf '%s' "$1" ;; *) uuid "$1" ;; esac; }   # a number → the fake's first uuid; a uuid → itself
nwrap() { local n=0 l; while IFS= read -r l; do [[ $l == *"sala: you have been idle"* ]] && n=$((n + 1)); done < <(typed "$(_wu "$1")"); echo "$n"; }   # <uuid n | uuid> → wrap-up texts typed into that conversation
nclear() { local n=0 l; while IFS= read -r l; do [ "$l" = /clear ] && n=$((n + 1)); done < <(typed "$(_wu "$1")"); echo "$n"; }

echo "== setup: private tmux server, isolated HOME, the compiled fake claude (sala-test-a..l)"
printf 'Do you want to proceed?\n \xe2\x9d\xaf 1. Yes\n   2. No\n' > "$HOME/prompt.txt"
mk a 1; mk b 2; mk c 3; mk d 4; mk e 5 -e FAKE_CHILD=1; mk f 6; mk g 7; mk h 8 -e FAKE_IDLE_AGE=600; mk i 9
mk j 10 -e FAKE_PROMPT_FILE="$HOME/prompt.txt"; mk k 11 -e CLAUDE_CODE_ENTRYPOINT=sdk-py; mk l 12
fake_up sala-test-a sala-test-b sala-test-c sala-test-d sala-test-e sala-test-f sala-test-g sala-test-h sala-test-i sala-test-j sala-test-k sala-test-l || exit 1
for n in a b c d e f g h i j k l; do "$SALA" adopt "sala-test-$n" >/dev/null 2>&1 || bad "adopt sala-test-$n failed"; done
for n in a c d e f g h i j k l; do "$SALA" sessions tag "sala-test-$n" --project projects/wrapup-test --role back >/dev/null 2>&1 || bad "tag sala-test-$n back failed"; done
"$SALA" sessions tag sala-test-b --project projects/wrapup-test --role front >/dev/null 2>&1 || bad "tag sala-test-b front failed"
sessions_py set sala-test-c side=1 >/dev/null 2>&1 || bad "could not mark sala-test-c a side session"
for n in 1 2 3 4 5 6 7 8 10 11 12; do stoprec "$n"; done
stoprec 9 "$((START - 100))"                                   # i: its last turn ended BEFORE its claude started: relaunched, no turn since
stoprec 12 "$TURN" 1 'cron=*/30 * * * * recurring: check the board'   # l: its last turn left a scheduled job
set_reg_status "$(cpid d)" busy                                # d: mid-turn
$T send-keys -t sala-test-f -l "half a thought"                # f: text typed in the input box, not sent
g=$(cpid g); gt=$(slurp "$HOME/.claude/sessions/$g.json"); gt=${gt/'"status":"idle"'/'"status":"shell"'}; gt=${gt%\}*}; printf '%s,"parkedJobId":"abcd1234"}\n' "$gt" > "$HOME/.claude/sessions/$g.json"   # g: parked on a background job
waitfor '[ "$($T capture-pane -p -t sala-test-f | grep -c "half a thought")" -ge 1 ]' 40 || bad "f's typed text is not on its screen"
waitfor '$T capture-pane -p -t sala-test-j | grep -q "Do you want to"' 40 || bad "j's dialog is not on its screen"
[ "$($T display -p '#{socket_path}')" = "$SALA_TMUX_SOCKET" ] && ok "the tmux server is the suite's private socket ($SOCK)" || bad "socket: $($T display -p '#{socket_path}')"

echo "== the off switches: an eligible pane (a) is spoken to by neither SALA_IDLE_WRAPUP=off nor SALA_IDLE_WRAPUP_MIN=0"
SALA_IDLE_WRAPUP=off tick; SALA_IDLE_WRAPUP_MIN=0 tick
[ "$(nwrap 1)" = 0 ] && [ ! -s "$FAKE_TYPED_LOG" ] && [ -z "$(wstate wrap.sala-test-a)" ] && ok "nothing typed, nothing kept with either switch" || bad "typed: $(<"$FAKE_TYPED_LOG"); state: $(grep '^wrap' "$ST")"

echo "== off by default: with SALA_IDLE_WRAPUP unset or garbage, a tick and a dry run do nothing"
env -u SALA_IDLE_WRAPUP "$SALA" watch --wrapup >/dev/null 2>&1; SALA_IDLE_WRAPUP=maybe tick
env -u SALA_IDLE_WRAPUP "$SALA" watch >/dev/null 2>&1   # the full tick path (wrapup_tick is one step of it), the variable unset
DRYOFF=$(env -u SALA_IDLE_WRAPUP "$SALA" watch --wrapup --dry-run 2>&1 | norm)
[ "$(nwrap 1)" = 0 ] && [ ! -s "$FAKE_TYPED_LOG" ] && [ -z "$(grep '^wrap' "$ST" 2>/dev/null)" ] && [ "$(wlogn 'wrapup:')" = 0 ] && ok "unset: nothing typed, no state, no log line" || bad "typed: $(<"$FAKE_TYPED_LOG"); state: $(grep '^wrap' "$ST"); log: $(<"$WLOG")"
[ -z "$DRYOFF" ] && ok "unset: a dry run prints nothing" || bad "dry run printed: $DRYOFF"

echo "== --dry-run: says what it would do and changes nothing"
DRY=$("$SALA" watch --wrapup --dry-run 2>&1 | norm)
has "$DRY" "sala-test-a: idle N min — the wrap-up would be typed now" && ok "a: the wrap-up would be typed now" || bad "dry run: $DRY"
has "$DRY" "sala-test-f: idle N min, not wrapped up — text is typed in its input box" && has "$DRY" "s of 3000s — not yet" && ok "f and h: their reasons" || bad "dry run: $DRY"
[ ! -s "$FAKE_TYPED_LOG" ] && [ -z "$(grep '^wrap' "$ST" 2>/dev/null)" ] && [ "$(wlogn 'wrapup:')" = 0 ] && ok "no keys typed, no state, no log line" || bad "typed: $(<"$FAKE_TYPED_LOG"); state: $(grep '^wrap' "$ST"); log: $(<"$WLOG")"

echo "== the first tick: only a is asked to wrap up"
tick
waitfor '[ "$(nwrap 1)" = 1 ]' 40 && ok "a got the wrap-up text" || bad "a: typed '$(typed "$(uuid 1)")'; log: $(<"$WLOG")"
[ "$(typed "$(uuid 1)" | head -1)" = "<!-- sala --> $WRAP_TEXT" ] && ok "the exact text, behind the sala marker" || bad "typed: $(typed "$(uuid 1)" | head -1)"
all=""; for n in 2 3 4 5 6 7 8 9 10 11 12; do all+="$(typed "$(uuid "$n")")"; done
[ -z "$all" ] && ok "nothing was typed into b..l (the draft of f is still its own: $($T capture-pane -p -t sala-test-f | grep -c 'half a thought') line on its screen)" || bad "typed into the others: $all"
$T capture-pane -p -t sala-test-f | grep -q "half a thought" && ok "f's typed text is still in its input box" || bad "f's text is gone"
[ "$(wlogn "typed the wrap-up into sala-test-a (idle N min")" = 1 ] && ok "one log line for the wrap-up" || bad "log: $(<"$WLOG")"
for r in "sala-test-d: idle N min, not wrapped up — registry says 'busy'" "sala-test-e: idle N min, not wrapped up — a background task is running" \
         "sala-test-f: idle N min, not wrapped up — text is typed in its input box" "sala-test-g: idle N min, not wrapped up — parked on a background job (abcd1234)" \
         "sala-test-i: idle N min, not wrapped up — no turn since its claude started" "sala-test-j: idle N min, not wrapped up — a dialog is showing" \
         "sala-test-k: idle N min, not wrapped up — on the sdk lane" "sala-test-l: idle N min, not wrapped up — its last turn left a scheduled job"; do
    wlogq "$r" && ok "logged: ${r#*: idle N min, not wrapped up — }  (${r%%:*})" || bad "no log line '$r'; log: $(<"$WLOG")"
done
! grep -q "sala-test-b\|sala-test-c\|sala-test-h" "$WLOG" && ok "b (front), c (side) and h (idle 10 min) have no line at all" || bad "log: $(grep 'sala-test-[bch]' "$WLOG")"
tick
[ "$(nwrap 1)" = 1 ] && [ "$(wlogn "typed the wrap-up into sala-test-a")" = 1 ] && ok "a second tick does not ask a again, and logs its skip reasons once" || bad "wraps $(nwrap 1); $(<"$WLOG")"
[ "$(wlogn "sala-test-f: idle N min")" = 1 ] && ok "a reason is logged once, not at every tick" || bad "f lines: $(wlogn 'sala-test-f: idle N min')"

echo "== its turn runs, then /clear is typed, and the pane map follows the new conversation"
old=$(uuid 1)
# t0, the second the wrap-up was typed, comes from its own log line (written at that moment, never rewritten). It is NOT read from the
# watch state: by now a slow run's second tick may already have cleared the pane, and the state then reads `cleared <the clear's end>`,
# a second or more AFTER the registry stamp the fake wrote at the /clear (seen in CI: "stamp vs <t0>").
wl=$(grep -m1 -F "wrapup: typed the wrap-up into sala-test-a" "$WLOG"); wl=${wl#\[}; t0=$(date -d "${wl%%]*}" +%s 2>/dev/null)
waitfor 'tick; [ "$(nclear 1)" -ge 1 ]' 80 && ok "/clear was typed" || bad "no /clear; state: $(grep '^wrap' "$ST"); log: $(<"$WLOG")"
a=$(cpid a); new=$(registry_field "$a" sessionId)
[ "$new" != "$old" ] && [ -n "$new" ] && ok "the registry row has a new conversation ($new), same process" || bad "sessionId $new (was $old)"
[ "$(registry_field "$a" name)" = sala-test-a ] && ok "the row keeps its name" || bad "name: $(registry_field "$a" name)"
[ "$(sidecar_uuid_for_session sala-test-a)" = "$new" ] && ok "the pane map follows the new conversation" || bad "pane map: $(sidecar_uuid_for_session sala-test-a)"
mapfile -t ty < <(typed "$old"; typed "$new")
[ "${ty[0]}" = "<!-- sala --> $WRAP_TEXT" ] && [ "${ty[1]:-}" = /clear ] && ok "in order: the wrap-up, then /clear" || bad "typed: ${ty[*]}"
[[ $t0 =~ ^[0-9]{10}$ ]] && [ "$(registry_field "$a" statusUpdatedAt | cut -c1-10)" -ge "$t0" ] && ok "the clear came after the wrap-up was sent" || bad "stamp '$(registry_field "$a" statusUpdatedAt)' vs the wrap-up's second '$t0' (log: $wl)"
grep -q "wrapup: cleared sala-test-a: conversation $old → $new; pane map followed" "$WLOG" && ok "one log line for the clear" || bad "log: $(<"$WLOG")"
sessions_py list --json 2>/dev/null | grep -q "$new" && ok "the session registry lists the new conversation" || bad "sessions.json: $(grep -c . "$SALA_SESSIONS_FILE") lines"
grep -q "follow	sala-test-a	$old → $new" "$SALA_LEDGER_LOG" && ok "the ledger log has the follow" || bad "ledger log: $(tail -3 "$SALA_LEDGER_LOG")"
[ "$(nposts x)" = 0 ] && [ ! -s "$POSTS" ] && ok "no post: nobody is woken" || bad "posts: $(<"$POSTS")"
[ "$(wstate wrap.sala-test-a | cut -d' ' -f1)" = cleared ] && ok "its state says cleared" || bad "state: $(wstate wrap.sala-test-a)"

echo "== never twice with no wake between: idle for an hour again, the cleared pane is left alone"
set_reg_stamp "$a" "$(( $(date +%s) - 3300 ))"; stoprec 1 "$(( $(date +%s) - 60 ))"   # the OLD conversation's record is not the new one's
tick; tick
[ "$(nwrap 1)" = 1 ] && [ "$(nclear 1)" = 1 ] && ok "nothing more typed into a" || bad "wraps $(nwrap 1), clears $(nclear 1)"
wlogq "sala-test-a: idle N min, not wrapped up — no turn since sala cleared it" && ok "logged: no turn since sala cleared it" || bad "log: $(tail -4 "$WLOG")"

echo "== a wake: the new conversation has a turn; idle for an hour again, a plain watch tick wraps it up a second time"
$T send-keys -t sala-test-a -l "a job from the router"; sleep 0.3; $T send-keys -t sala-test-a Enter     # a message is a 1.5 s turn in the fake
waitfor '[ "$(registry_field "$a" status)" = idle ] && [ "$(registry_field "$a" statusUpdatedAt | cut -c1-10)" -gt "$(( $(date +%s) - 20 ))" ]' 60 || bad "a: the wake's turn did not end (status $(registry_field "$a" status))"
sleep 1.2; printf 'id=t\nepoch=%s\nseen=\nseen_status=idle\ntasks=0\ncrons=0\n' "$(date +%s)" > "$SALA_BUSY_DIR/$new"
set_reg_stamp "$a" "$(( $(date +%s) - 3300 ))"
"$SALA" watch >/dev/null 2>&1
waitfor '[ "$(nwrap "$new")" = 1 ] || { set_reg_stamp "$a" "$(( $(date +%s) - 3300 ))"; "$SALA" watch >/dev/null 2>&1; [ "$(nwrap "$new")" = 1 ]; }' 40 && ok "a is wrapped up again (by a plain watch tick), after its wake" || bad "wraps in the new conversation $(nwrap "$new"); log: $(tail -5 "$WLOG")"
waitfor 'tick; [ "$(wstate wrap.sala-test-a | cut -d" " -f1)" = cleared ] && [ "$(conv a)" != "$new" ]' 80 && ok "and cleared again onto a third conversation ($(conv a))" || bad "state $(wstate wrap.sala-test-a); log: $(tail -5 "$WLOG")"
[ "$(sidecar_uuid_for_session sala-test-a)" = "$(conv a)" ] && ok "the pane map follows that one too" || bad "pane map: $(sidecar_uuid_for_session sala-test-a)"

echo "== a pane relaunched or cleared between the steps drops its state; a wrap-up that produced no turn is dropped and waits"
mk o 21; mk p 22; fake_up sala-test-o sala-test-p || exit 1
for n in o p; do "$SALA" adopt "sala-test-$n" >/dev/null 2>&1; "$SALA" sessions tag "sala-test-$n" --project projects/wrapup-test --role back >/dev/null 2>&1; stoprec "$([ $n = o ] && echo 21 || echo 22)"; done
now=$(date +%s)
_kv_set "$ST" wrap.sala-test-o "sent $((now - 100)) $(uuid 21) 99999 0"     # asked to wrap up, then its claude (pid) changed
_kv_set "$ST" wrap.sala-test-p "sent $((now - 1000)) $(uuid 22) $(cpid p) 0" # asked, and no turn since (the row's stamp is 55 min old)
tick
[ -z "$(wstate wrap.sala-test-o)" ] && grep -q "sala-test-o was relaunched or cleared after its wrap-up was typed — dropped" "$WLOG" && ok "o: state dropped, said in the log" || bad "o: $(wstate wrap.sala-test-o); $(tail -3 "$WLOG")"
[ "$(wstate wrap.sala-test-p | cut -d' ' -f1)" = retry ] && grep -q "the wrap-up typed into sala-test-p produced no turn" "$WLOG" && ok "p: dropped to retry, said in the log" || bad "p: $(wstate wrap.sala-test-p); $(tail -3 "$WLOG")"
tick; tick
[ "$(nwrap 22)" = 0 ] && [ "$(nclear 22)" = 0 ] && ok "p is not asked again before SALA_WRAPUP_RETRY" || bad "p wraps $(nwrap 22) clears $(nclear 22)"
[ "$(nwrap 21)" = 1 ] && ok "o (state dropped, still eligible) is asked afresh" || ok "o: wraps $(nwrap 21) (asked afresh or still waiting)"

echo "== a /clear the CLI does not take: tried SALA_CLEAR_TRIES times, then dropped"
mk q 31 -e FAKE_NO_CLEAR=1; fake_up sala-test-q || exit 1
"$SALA" adopt sala-test-q >/dev/null 2>&1; "$SALA" sessions tag sala-test-q --project projects/wrapup-test --role back >/dev/null 2>&1; stoprec 31
export SALA_CLEAR_TRIES=2 SALA_CLEAR_WAIT=2
waitfor 'tick; [ "$(wstate wrap.sala-test-q | cut -d" " -f1)" = failed ]' 160 && ok "q: recorded as failed after its tries" || bad "q state: $(wstate wrap.sala-test-q); log: $(grep sala-test-q "$WLOG" | tail -5)"
[ "$(nclear 31)" = 2 ] && grep -q "sala-test-q did not take /clear in 2 tries" "$WLOG" && ok "q: /clear typed twice, then given up, said in the log" || bad "q clears $(nclear 31); $(grep sala-test-q "$WLOG" | tail -4)"
[ "$(conv q)" = "$(uuid 31)" ] && [ "$(sidecar_uuid_for_session sala-test-q)" = "$(uuid 31)" ] && ok "its conversation and its pane map row are untouched" || bad "q conv $(conv q)"
[ "$(wstate wrap.sala-test-q | cut -d' ' -f3-4)" = "$(uuid 31) $(cpid q)" ] && ok "q: the failed state names its conversation and pid" || bad "q state: $(wstate wrap.sala-test-q)"

echo "== a failed /clear: no second wrap-up while nothing changed, until a Stop record newer than the failure"
q=$(cpid q); set_reg_stamp "$q" "$(( $(date +%s) - 3300 ))"        # idle 55 min again, no turn since the failure
tick; tick
[ "$(nwrap 31)" = 1 ] && ok "q: not wrapped up a second time (idle 55 min, state failed)" || bad "q wraps $(nwrap 31); log: $(grep sala-test-q "$WLOG" | tail -3)"
wlogq "sala-test-q: not wrapped up — its /clear was not taken; waits for a new turn" && [ "$(wlogn "sala-test-q: not wrapped up — its /clear was not taken")" = 1 ] && ok "q: the reason is logged once" || bad "log: $(grep sala-test-q "$WLOG" | tail -3)"
fa=$(wstate wrap.sala-test-q | cut -d' ' -f2); now=$(date +%s); [ "$now" -gt "$fa" ] || now=$((fa + 1))
stoprec 31 "$now"                                                   # a wake: a Stop record STRICTLY newer than the failure (same second = not newer)
set_reg_stamp "$q" "$(( $(date +%s) - 3300 ))"
waitfor 'tick; [ "$(nwrap 31)" = 2 ]' 40 && ok "q: wrapped up again once its conversation had a new turn" || bad "q wraps $(nwrap 31); state: $(wstate wrap.sala-test-q); log: $(grep sala-test-q "$WLOG" | tail -3)"

echo "== idle past SALA_IDLE_WRAPUP_MAX_AGE (65 min here): neither a wrap-up nor a clear, one log line; the bound is a knob"
mk r 41 -e FAKE_IDLE_AGE=4200; fake_up sala-test-r || exit 1       # idle 70 minutes: the prompt cache is cold
"$SALA" adopt sala-test-r >/dev/null 2>&1; "$SALA" sessions tag sala-test-r --project projects/wrapup-test --role back >/dev/null 2>&1; stoprec 41
tick; tick
[ "$(nwrap 41)" = 0 ] && [ "$(nclear 41)" = 0 ] && [ -z "$(wstate wrap.sala-test-r)" ] && ok "r: nothing typed, no state" || bad "r wraps $(nwrap 41) clears $(nclear 41) state '$(wstate wrap.sala-test-r)'"
wlogq "sala-test-r: idle N min, not wrapped up — past the warm window (over 65 min" && [ "$(wlogn "sala-test-r: idle N min, not wrapped up — past the warm window")" = 1 ] && ok "r: one log line with the reason, not one per tick" || bad "log: $(grep sala-test-r "$WLOG")"
DRY=$("$SALA" watch --wrapup --dry-run 2>&1 | norm)
has "$DRY" "sala-test-r: idle N min, not wrapped up — past the warm window" && ok "--dry-run says so too" || bad "dry run: $DRY"
# a retry after a dropped wrap-up respects the bound: r's state is a retry that has run out; it is still past the window
_kv_set "$ST" wrap.sala-test-r "retry $(( $(date +%s) - 4000 ))"
tick
[ "$(nwrap 41)" = 0 ] && [ "$(nclear 41)" = 0 ] && ok "r: a retry whose wait is over is held back by the same bound" || bad "r wraps $(nwrap 41)"
SALA_IDLE_WRAPUP_MAX_AGE=80 tick
waitfor '[ "$(nwrap 41)" = 1 ]' 40 && ok "r: with SALA_IDLE_WRAPUP_MAX_AGE=80 the same pane is wrapped up" || bad "r wraps $(nwrap 41); log: $(grep sala-test-r "$WLOG" | tail -3)"

echo "== an empty list of back names (sessions.json unreadable) keeps the in-flight states; a healthy list purges a gone session"
_kv_set "$ST" wrap.sala-test-zz "sent $(date +%s) $(uuid 91) 99998 0"; _kv_set "$ST" wrapwhy.sala-test-zz "some reason"
cp "$SALA_SESSIONS_FILE" "$HOME/sessions.good"; printf 'not json' > "$SALA_SESSIONS_FILE"
tick; tick
[ -n "$(wstate wrap.sala-test-zz)" ] && [ -n "$(wstate wrapwhy.sala-test-zz)" ] && ok "unreadable sessions.json: the states of a session not in the list are kept" || bad "state: $(grep '^wrap' "$ST")"
cp "$HOME/sessions.good" "$SALA_SESSIONS_FILE"
tick
[ -z "$(wstate wrap.sala-test-zz)" ] && [ -z "$(wstate wrapwhy.sala-test-zz)" ] && ok "a healthy list: the state of a session that is gone is dropped" || bad "state: $(grep '^wrap' "$ST")"

unset SALA_CLEAR_TRIES; export SALA_CLEAR_WAIT=6

echo "== the SessionStart hook: source clear in a back row prints the context line; nothing for a front row, a start or the off switch"
ida=$("$SALA" sessions resolve sala-test-a --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
idb=$("$SALA" sessions resolve sala-test-b --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
payload() { printf '{"session_id":"%s","source":"%s","cwd":"/tmp"}' "$(uuid 77)" "$1"; }   # <source>
out=$(payload clear | SALA_SESSION_ID=$ida "$SALA" hook session-start 2>/dev/null)
has "$out" '"hookEventName": "SessionStart"' && has "$out" "You are sala-test-a, a background agent of the gbrain page projects/wrapup-test" && has "$out" 'under `background:`' && ok "a back row: one additionalContext line naming the agent and its project" || bad "out: $out"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["hookSpecificOutput"]["additionalContext"].startswith("[sala] ")' "$out" 2>/dev/null && ok "it is one JSON object a SessionStart hook can return" || bad "not JSON: $out"
[ -z "$(payload clear | SALA_SESSION_ID=$idb "$SALA" hook session-start 2>/dev/null)" ] && ok "a front row: nothing printed" || bad "front printed something"
[ -z "$(payload startup | SALA_SESSION_ID=$ida "$SALA" hook session-start 2>/dev/null)" ] && [ -z "$(payload resume | SALA_SESSION_ID=$ida "$SALA" hook session-start 2>/dev/null)" ] && ok "a start and a resume: nothing printed" || bad "start printed something"
[ -z "$(payload clear | SALA_SESSION_ID=$ida SALA_CLEAR_CONTEXT=off "$SALA" hook session-start 2>/dev/null)" ] && ok "SALA_CLEAR_CONTEXT=off: nothing printed" || bad "off printed something"
[ -z "$(printf 'garbage' | SALA_SESSION_ID=$ida "$SALA" hook session-start 2>/dev/null)" ] && ok "garbage in: nothing printed, exit 0" || bad "garbage printed something"
[ "$(nposts x)" = 0 ] && ok "and still no post from anything above" || bad "posts: $(<"$POSTS")"

[ "$fail" = 0 ] && echo "wrapup: pass" || echo "wrapup: FAIL"
exit $fail
