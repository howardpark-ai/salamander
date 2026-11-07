#!/usr/bin/env bash
# The network-stop wake (lib/common.sh THE NETWORK STOP, lib/watch.sh NETWORK-STOP WAKE,
# lib/revive.sh and the post-boot report). A machine that reboots with DNS down can leave panes ending their
# first turn on "API Error: Can't reach the API server — check your internet or DNS (EAI_AGAIN)"; nothing retries such a turn,
# so they stay stopped for hours, and the revive post still counts them as resumed. Fake claudes (the compiled tests/fake-claude.c) run
# on a private tmux socket with transcripts written by hand around the REAL record (tests/fixtures/net-eai-again.jsonl, from
# a transcript, anonymised: the error record and the turn_duration record after it);
# what reached each one's messaging socket is read from FAKE_SOCK_LOG. DNS is a `getent` stub that answers while
# $HOME/dns.up exists. Slack is a file (SALA_NOTIFY_CMD), systemctl and systemd-run are stubs.
# Checked: the detector (net_stopped_sessions) names a pane whose newest assistant record is the error, with the first and
# last epoch of its run, and none of a pane that worked after the error, an ordinary answer that quotes the text, another API
# error (the usage limit), an error older than the lookback, or a pane with no claude; DNS down: no message (and the lookup is
# made once a tick, only while a pane waits); DNS up: exactly one message to each stopped pane, with the plain text, none to
# the others, a busy pane once it is idle; a second run: none; the woken turn failing again on the same error: none; the
# pane working again and stopping later (a new episode): one more; a pane whose session is gone skipped quietly; the knob
# off: nothing; a full `watch` tick runs the step; the post-boot report names the panes stopped right now; the boot
# revive's summary counts the resumed panes that stopped on it ("1 resumed, 1 of them stopped on a network error; woken once
# the network is back"). Usage: bash tests/netwake.sh   (exit 0 = pass)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_TZ ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS CLAUDE_CONFIG_DIR SALA_LANE_API_KEY_FILE SALA_LANE_TEAM_DIR SALA_MASTER
unset SALA_SET SALA_SET_SELF SALA_POST_RECYCLE_CMD SALA_RECYCLE SALA_RETRY_WORKER SALA_NO_RELAUNCH
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
as_op_unit
P="$HOME/.claude/projects/x"; mkdir -p "$HOME/.claude/sessions" "$P" "$HOME/.local/bin" "$HOME/work" "$HOME/.local/share/tmux/resurrect"
touch "$HOME/.claude/salamander-rc.stopped"
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" -lpthread || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"
cat > "$HOME/.local/bin/getent" <<EOF
#!/bin/bash
# stub: answers for a host while $HOME/dns.up exists (the lookups are counted), else fails as a resolver with no DNS does (exit 2)
echo "\$*" >> "$HOME/getent.log"
[ -e "$HOME/dns.up" ] && { echo "160.79.104.10    \$2"; exit 0; }
exit 2
EOF
cat > "$HOME/.local/bin/systemctl" <<'EOF'
#!/bin/bash
case "$*" in *is-active*) exit 3 ;; *is-system-running*) echo running; exit 0 ;; *cat*tmux.service*) exit 1 ;; *) exit 0 ;; esac
EOF
printf '#!/bin/sh\necho "$*" >> "%s/systemd-run.txt"\n' "$HOME" > "$HOME/.local/bin/systemd-run"
chmod +x "$HOME/.local/bin/getent" "$HOME/.local/bin/systemctl" "$HOME/.local/bin/systemd-run"
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log" FAKE_SOCK_LOG="$HOME/sock.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off
export SALA_LIMIT_ALERT=off SALA_LIMIT_RESUME=off SALA_STUCK_POST=off   # the other watches: not under test
SALA="$ROOT/bin/salamander"; SOCK="sala-netwake-$$"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"
cleanup() {
    local f p; for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done
    command tmux -L "$SOCK" kill-server 2>/dev/null; tmux_socket_rm; sleep 0.5
    for p in $(pgrep -x claude); do [ "$HOME/.local/share/claude/versions/9.9.9" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux
mk() {  # <letter> <uuid>: a fake claude pane (its registry row carries the conversation id and a messaging socket)
    local n="sala-test-$1" u="$2"; shift 2
    tmux new-session -d -s "$n" -c "$HOME/work" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="$n" -e FAKE_LOG="$FAKE_LOG" -e FAKE_SOCK_LOG="$FAKE_SOCK_LOG" "$@"
    tmux send-keys -t "$n" 'claude' Enter
}
UA=$(uuid 11) UB=$(uuid 12) UC=$(uuid 13) UD=$(uuid 14) UE=$(uuid 15) UF=$(uuid 16) UG=$(uuid 17) UH=$(uuid 18) UI=$(uuid 19) UJ=$(uuid 20) UK=$(uuid 21) US=$(uuid 22)
mk a "$UA"; mk b "$UB"; mk c "$UC"; mk d "$UD"; mk e "$UE"; mk f "$UF"; mk g "$UG"; mk h "$UH"
fake_up sala-test-a sala-test-b sala-test-c sala-test-d sala-test-e sala-test-f sala-test-g sala-test-h || exit 1
. "$ROOT/lib/common.sh"
NOW=$(date +%s)
user_rec() { printf '{"type":"user","uuid":"%s","timestamp":"%s","message":{"role":"user","content":"a message"}}\n' "$(rid)" "$(iso "$2")" >> "$P/$1.jsonl"; }   # <uuid> <epoch>
ok_rec() { printf '{"parentUuid":null,"isSidechain":false,"type":"assistant","uuid":"%s","timestamp":"%s","cwd":"%s","message":{"model":"claude-opus-5-5","role":"assistant","content":[{"type":"text","text":"done"}]},"sessionId":"%s"}\n' "$(rid)" "$(iso "$2")" "$HOME/work" "$1" >> "$P/$1.jsonl"; }   # <uuid> <epoch>
net_rec() {  # <uuid> <epoch>: the REAL record (the fixture: the error, then the turn_duration record after it), its placeholders filled
    sed -e "s|@UUID@|$(rid)|g" -e "s|@TS@|$(iso "$2")|g" -e "s|@CWD@|$HOME/work|g" -e "s|@SESSION@|$1|g" "$ROOT/tests/fixtures/net-eai-again.jsonl" >> "$P/$1.jsonl"; }
quote_rec() {  # <uuid> <epoch>: an ordinary answer that quotes the error text (no isApiErrorMessage)
    printf '{"parentUuid":null,"isSidechain":false,"type":"assistant","uuid":"%s","timestamp":"%s","cwd":"%s","message":{"model":"claude-opus-5-5","role":"assistant","content":[{"type":"text","text":"The pane said: API Error: Can'"'"'t reach the API server — check your internet or DNS (EAI_AGAIN)"}]},"sessionId":"%s"}\n' "$(rid)" "$(iso "$2")" "$HOME/work" "$1" >> "$P/$1.jsonl"; }
limit_rec() {  # <uuid> <epoch>: another API error, the weekly usage limit (the usage-limit watch's, not a network stop)
    printf '{"parentUuid":null,"isSidechain":false,"type":"assistant","uuid":"%s","timestamp":"%s","cwd":"%s","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"You'"'"'ve hit your weekly limit"}]},"error":"rate_limit","apiError":"usage_limit_reached","isApiErrorMessage":true,"sessionId":"%s"}\n' "$(rid)" "$(iso "$2")" "$HOME/work" "$1" >> "$P/$1.jsonl"; }
sent() { local n; n=$(grep -c "^$1 " "$FAKE_SOCK_LOG" 2>/dev/null); echo "${n:-0}"; }   # messages that reached a conversation's socket
dns_calls() { local n; n=$(grep -c . "$HOME/getent.log" 2>/dev/null); echo "${n:-0}"; }
regstatus() { local c; c=$(claude_pid_under "$(tmux display -p -t "$1" '#{pane_pid}')"); set_reg_status "$c" "$2"; }
nw() { "$SALA" watch --net >/dev/null 2>&1; }
WLOG="$HOME/.claude/salamander-watch.log"; NSTATE="$HOME/.claude/salamander-net.state"
TEXT="[sala] Your last turn ended on a network error (API unreachable). The network is back; continue what you were doing."

echo "== setup: the transcripts of eight panes around the real record"
T0=$((NOW-3000))
user_rec "$UA" $((T0-60)); net_rec "$UA" "$T0"                                   # a: stopped, one error
user_rec "$UB" $((T0-60)); net_rec "$UB" "$T0"; user_rec "$UB" $((T0+60)); ok_rec "$UB" $((T0+90))   # b: stopped, then worked after the error
user_rec "$UC" $((T0-60)); quote_rec "$UC" "$T0"                                 # c: an ordinary answer that quotes the text
user_rec "$UD" $((T0-60)); limit_rec "$UD" "$T0"                                 # d: another API error
user_rec "$UE" $((T0-60)); net_rec "$UE" "$T0"; net_rec "$UE" $((T0+100))        # e: two errors in a row, one run
user_rec "$UF" $((T0-60)); net_rec "$UF" $((NOW-5*86400)); touch -d "@$((NOW-5*86400))" "$P/$UF.jsonl"   # f: older than the lookback
user_rec "$UG" $((T0-60)); net_rec "$UG" "$T0"                                   # g: stopped, but busy
user_rec "$UH" $((T0-60)); net_rec "$UH" "$T0"                                   # h: stopped; its session is killed below
regstatus sala-test-g busy

echo "== the detector: the newest assistant record is the network error → stopped, with its run's first and last error"
out=$(net_stopped_sessions sala-test-a sala-test-b sala-test-c sala-test-d sala-test-e sala-test-f sala-test-g sala-test-h)
names=$(awk '{print $2}' <<< "$out" | sort | paste -sd' ' -)
[ "$names" = "sala-test-a sala-test-e sala-test-g sala-test-h" ] && ok "a, e, g and h are stopped; b (worked after), c (quotes the text), d (usage limit) and f (older than the lookback) are not" || bad "stopped: $names — $out"
awk -v u="$UA" -v t="$T0" '$1=="net" && $4==u && $5==t && $6==t {f=1} END {exit !f}' <<< "$out" && ok "a: the conversation, first and last error epoch" || bad "a's row: $(grep "$UA" <<< "$out")"
awk -v u="$UE" -v t="$T0" '$1=="net" && $4==u && $5==t && $6==t+100 {f=1} END {exit !f}' <<< "$out" && ok "e: two errors in a row are one run, first and last" || bad "e's row: $(grep "$UE" <<< "$out")"
[ -z "$(net_stopped_sessions sala-test-nosuch)" ] && ok "a session with no pane: nothing" || bad "a missing session was reported"
out=$(SALA_NET_LOOKBACK=100000000 net_stopped_sessions sala-test-f); grep -q " $UF " <<< "$out" && ok "f is stopped once the lookback covers its error (the lookback is what dropped it)" || bad "f with a long lookback: $out"
tmux kill-session -t sala-test-h; sleep 0.3

echo "== DNS down: no message, however many ticks; the lookup is made once a tick; each stop is logged once"
rm -f "$HOME/dns.up"; : > "$WLOG"; : > "$FAKE_SOCK_LOG"
nw; nw
[ "$(sent "$UA")$(sent "$UE")$(sent "$UG")" = 000 ] && ok "nobody told while the API does not resolve" || bad "told with DNS down: $(<"$FAKE_SOCK_LOG")"
[ "$(dns_calls)" = 2 ] && grep -q ' api.anthropic.com$' "$HOME/getent.log" && ok "api.anthropic.com asked once per tick" || bad "getent calls: $(<"$HOME/getent.log")"
[ "$(grep -c 'network: .* stopped on a network error since' "$WLOG")" = 3 ] && grep -q 'network: sala-test-a stopped on a network error since' "$WLOG" && grep -q 'network: sala-test-e stopped' "$WLOG" && grep -q 'network: sala-test-g stopped' "$WLOG" && ok "a, e and g (busy, but stopped) logged once each over two ticks"|| bad "log: $(<"$WLOG")"

echo "== DNS up: exactly one message each to a and e, with the plain text; none to the others; busy g waits"
touch "$HOME/dns.up"; nw
waitfor '[ "$(sent "$UA")" = 1 ] && [ "$(sent "$UE")" = 1 ]' 20 && ok "a and e: one message each" || bad "a $(sent "$UA"), e $(sent "$UE")"
grep "^$UA " "$FAKE_SOCK_LOG" | grep -qF "\"content\": \"$TEXT\"}" && grep "^$UE " "$FAKE_SOCK_LOG" | grep -qF "\"content\": \"$TEXT\"}" && ok "the text: the network is back, continue what you were doing" || bad "text: $(<"$FAKE_SOCK_LOG")"
[ "$(sent "$UB")$(sent "$UC")$(sent "$UD")$(sent "$UF")$(sent "$UG")$(sent "$UH")" = 000000 ] && ok "none to b, c, d, f (not stopped), g (busy), h (no pane)" || bad "stray: $(<"$FAKE_SOCK_LOG")"
grep -q 'network: woke sala-test-a ' "$WLOG" && ok "the watch log says who was woken" || bad "log: $(<"$WLOG")"
nw; nw
[ "$(sent "$UA")" = 1 ] && [ "$(sent "$UE")" = 1 ] && ok "a second and third run: nothing more (once per episode)" || bad "a $(sent "$UA"), e $(sent "$UE")"
regstatus sala-test-g idle; nw; nw
waitfor '[ "$(sent "$UG")" = 1 ]' 20 && sleep 1 && [ "$(sent "$UG")" = 1 ] && ok "g: told once, once it is idle" || bad "g told $(sent "$UG")×"
c0=$(dns_calls); nw
[ "$(dns_calls)" = "$c0" ] && ok "nothing waiting: no DNS lookup at all" || bad "a lookup with nothing due"

echo "== the woken turn fails again on the same error: the same episode, no second message"
net_rec "$UA" $((NOW-100)); nw; nw
[ "$(sent "$UA")" = 1 ] && ok "a's run goes on: still one message" || bad "a told $(sent "$UA")×"

echo "== a works again and stops again later: a new episode, one more message"
user_rec "$UA" $((NOW-80)); ok_rec "$UA" $((NOW-70)); nw
[ "$(sent "$UA")" = 1 ] && ok "while it works: nothing" || bad "told while working"
user_rec "$UA" $((NOW-60)); net_rec "$UA" $((NOW-50)); nw
waitfor '[ "$(sent "$UA")" = 2 ]' 20 && ok "stopped again: told a second time" || bad "a told $(sent "$UA")×"
nw; [ "$(sent "$UA")" = 2 ] && [ "$(sent "$UE")" = 1 ] && [ "$(sent "$UG")" = 1 ] && ok "and once only; e and g untouched" || bad "a $(sent "$UA") e $(sent "$UE") g $(sent "$UG")"
[ "$(grep -c "^$UA	" "$NSTATE")" = 1 ] && ok "the state keeps one line per conversation" || bad "state: $(<"$NSTATE")"

echo "== a pane that is retired meanwhile (its session gone) is skipped without a word; the knob off does nothing"
mk i "$UI"; fake_up sala-test-i || exit 1
user_rec "$UI" $((NOW-200)); net_rec "$UI" $((NOW-190))
tmux kill-session -t sala-test-i; sleep 0.3
l0=$(grep -c . "$WLOG"); nw
[ "$(sent "$UI")" = 0 ] && [ "$(grep -c . "$WLOG")" = "$l0" ] && ok "no pane, no message, no log line, exit 0" || bad "i: told $(sent "$UI"); log grew: $(tail -2 "$WLOG")"
mk j "$UJ"; fake_up sala-test-j || exit 1
user_rec "$UJ" $((NOW-200)); net_rec "$UJ" $((NOW-190))
SALA_NET_WAKE=off "$SALA" watch --net >/dev/null 2>&1; sleep 1
[ "$(sent "$UJ")" = 0 ] && ! grep -q "^$UJ	" "$NSTATE" && ok "SALA_NET_WAKE=off: nothing sent, nothing kept" || bad "knob off: told $(sent "$UJ")"
echo "== a full watch tick runs the step (j is stopped, the API resolves)"
"$SALA" watch >/dev/null 2>&1
waitfor '[ "$(sent "$UJ")" = 1 ]' 20 && ok "j told by a plain tick" || bad "j told $(sent "$UJ")×; log: $(tail -5 "$WLOG")"

echo "== the post-boot report names the panes stopped right now (the API still unreachable; everything else has answered)"
for u in $UA $UE $UG $UJ; do user_rec "$u" $((NOW-20)); ok_rec "$u" $((NOW-10)); done
mk k "$UK"; fake_up sala-test-k || exit 1
user_rec "$UK" $((NOW-30)); net_rec "$UK" $((NOW-25))
rm -f "$HOME/dns.up"
REC="$HOME/.claude/salamander-boot-revive"
printf 'boot-net-1\n%s\n2 resumed · 0 updated · 1 already running · 0 skipped (target 9.9.9)\n' "$(date +%s)" > "$REC"
: > "$POSTS"; SALA_BOOT_ID=boot-net-1 "$SALA" watch >/dev/null 2>&1
P1=$(awk -v RS='%%\n' 'index($0, "came back up") {printf "%s", $0; exit}' "$POSTS" 2>/dev/null)
grep -qF "Stopped on a network error right now: sala-test-k. sala sends each one message once the network is back." <<< "$P1" && ok "the report: k named, with what sala does" || bad "report: $P1"
grep -qF "sala-test-a" <<< "$P1" && bad "an answered pane named: $P1" || ok "the panes that answered since are not named"
[ "$(sent "$UK")" = 0 ] && ok "k not told: the API still does not resolve" || bad "k told with DNS down"

echo "== revive's boot summary counts the resumed panes that stopped on it"
mk s "$US"; fake_up sala-test-s || exit 1
"$SALA" adopt sala-test-s >/dev/null 2>&1 || bad "adopt sala-test-s failed"
user_rec "$US" $((NOW-40)); net_rec "$US" $((NOW-35))
cpid=$(claude_pid_under "$(tmux display -p -t sala-test-s '#{pane_pid}')"); kill -9 "$cpid"; waitfor '! kill -0 '"$cpid"' 2>/dev/null' 20; sleep 1   # its pane back at a shell, the way a reboot leaves it
rm -f "$REC"
SALA_BOOT_ID=boot-net-2 "$SALA" revive >/dev/null 2>&1
fake_up sala-test-s
grep -qF "1 resumed, 1 of them stopped on a network error; woken once the network is back · " "$REC" 2>/dev/null && ok "the boot record: \"1 resumed, 1 of them stopped on a network error; woken once the network is back\"" || bad "boot record: $(slurp "$REC") — log: $(tail -8 "$HOME/.claude/salamander-revive.log" 2>/dev/null)"
[ "$(sent "$US")" = 0 ] && ok "revive woke nothing itself (the watch does, once the API resolves)" || bad "revive pushed: $(grep "^$US" "$FAKE_SOCK_LOG")"
touch "$HOME/dns.up"; nw
waitfor '[ "$(sent "$US")" = 1 ] && [ "$(sent "$UK")" = 1 ]' 20 && ok "the API resolves: s and k told once each" || bad "s $(sent "$US"), k $(sent "$UK")"

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit $fail
