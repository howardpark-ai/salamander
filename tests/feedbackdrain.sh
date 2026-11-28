#!/usr/bin/env bash
# The feedback drafts drain and the exit-time drafts gate (lib/feedback.sh; lib/common.sh drafts_gate_pass, wait_exit;
# lib/revive.sh exit_wait). Checked on fakes only (the compiled fake claude in panes of a private tmux server, its drafts
# panel tests/fake-drafts-panel.py, an isolated HOME): nothing is ever sent anywhere.
#   THE DRAIN, report only: both review layouts (the choice list; the transcript toggle), with and without a transcript, a
#     review longer than the screen, a dropped Enter: every draft is sent without its transcript and never with it.
#   THE DRAFT THAT CANNOT BE SENT: a review the drain does not know, and a service out of reach: nothing is sent, nothing
#     discarded, the panel is closed again, and the exit code says drafts are still queued.
#   THE GATE: /exit with queued drafts stops at the gate; wait_exit passes it with the drafts kept; a drain that meets the
#     gate sends the drafts and the exit goes on.
#   THE RELAUNCH: `revive` over a pane whose draft cannot be sent relaunches it, the draft still queued; nothing is asked of
#     the owner.
#   THE DRAIN'S OWN STAMP: the panel moves the row's idle stamp, and the same `revive` that sent the draft relaunches the pane,
#     also one whose Stop hook record says nothing is in flight over a long-lived child. A turn after the send, running or
#     already over, and a record a turn wrote during the send: the pane is not read as idle.
# No process is killed by name; the cleanup ends this suite's own fakes with kill_fake_claude (exe and HOME checked).
# Usage: bash tests/feedbackdrain.sh   (exit 0 = pass)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SET SALA_SET_SELF SALA_RECYCLE SALA_RETRY_WORKER SALA_LOCK_WHO SALA_LOCK_WAIT SALA_RELAUNCH_KIND \
      SALA_FLEET_HOSTS SALA_CGROUP_FILE SALA_OP_QUEUE SALA_NO_RELAUNCH SALA_RESCUE SALA_CLAUDE SALA_EXIT_END
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_CUSTOM_HEADERS CLAUDE_CONFIG_DIR CLAUDE_CODE_OAUTH_TOKEN SALA_LANE_API_KEY_FILE SALA_LANE_TEAM_DIR SALA_LANE_FALLBACK
unset AWS_PROFILE AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_BEARER_TOKEN_BEDROCK CLAUDE_CODE_USE_BEDROCK SALA_LANE_BEDROCK_CREDENTIALS_FILE
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
exec 7< "$HOME"; flock -n 7 || true   # the temp folder is locked while the suite runs (systemd-tmpfiles ageing honours it)
DRAFTS="$HOME/.claude/feedback/drafts"
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$DRAFTS" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOME/.local/state/sala-web"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"
FAKE="$HOME/.local/share/claude/versions/9.9.9"
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log"
export SALA_NOTIFY_CMD="cat >> $HOME/posts.txt"
export SALA_BIN="$ROOT/bin/salamander" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off SALA_SIGNIN_ALERT=off SALA_LANE_FALLBACK_AUTO=off
SALA="$ROOT/bin/salamander"; SOCK="sala-feedbackdrain-$$"; T="tmux -L $SOCK -f /dev/null"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's
cleanup() {
    local f; for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    kill_fake_claude "$FAKE"
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux    # literal socket: the children run set -u
. "$ROOT/lib/common.sh"
as_op_unit
mkdir -p "$SALA_STATE_DIR"
FLOG="$HOME/.claude/salamander-feedback.log"
alive() { kill -0 "$1" 2>/dev/null; }
# draft <session> <title>…: queued drafts of that conversation, and no others
drafts() {
    local sid="$1" t i=0; shift; rm -f "$DRAFTS"/*.json
    for t in "$@"; do i=$((i+1)); printf '{"id":"d%s","status":"queued","source_session_id":"%s","title":"%s","transcript_ref":null}\n' "$i" "$sid" "$t" > "$DRAFTS/d$i.json"; done
}
ndrafts() { local f n=0; for f in "$DRAFTS"/*.json; do [ -e "$f" ] && n=$((n+1)); done; echo "$n"; }
# mk <n> <uuid> [KEY=VALUE…]: pane sala-test-<n> running the fake claude with its drafts panel, an 80x24 window
mk() {
    local n="$1" u="$2" kv; shift 2; local -a e=()
    for kv in "$@"; do e+=(-e "$kv"); done
    : > "$HOME/.claude/projects/x/$u.jsonl"; : > "$HOME/panel-$n.log"
    $T new-session -d -s "sala-test-$n" -x 80 -y 24 -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="sala-test-$n" -e FAKE_LOG="$FAKE_LOG" \
        -e FAKE_DRAFTS_PANEL="$ROOT/tests/fake-drafts-panel.py" -e FAKE_PANEL_LOG="$HOME/panel-$n.log" ${e[@]+"${e[@]}"}
    $T send-keys -t "sala-test-$n" claude Enter
}
paneid() { $T display -p -t "=sala-test-$1:" '#{pane_id}'; }
panel() { slurp "$HOME/panel-$1.log"; }
count() { grep -c -- "$2" "$HOME/panel-$1.log"; }
end() { local p; p=$(cpid "$1"); $T kill-session -t "=sala-test-$1" 2>/dev/null; waitfor '! alive "$p"' 20 || :; }
# sends <n> <name> <knob…>: two drafts, one drain: both sent report only, the panel closed, the window as it was
sends() {
    local n="$1" what="$2" u p rc size; u=$(uuid "$3"); shift 3
    mk "$n" "$u" "$@"; fake_up "sala-test-$n" || { bad "$what: the pane did not come up"; return; }
    p=$(paneid "$n"); drafts "$u" "first-$n" "second-$n"
    "$SALA" feedback drain "$p" "$u"; rc=$?
    [ "$rc" = 0 ] && [ "$(ndrafts)" = 0 ] && [ "$(count "$n" "^sent first-$n transcript=no\$")" = 1 ] && [ "$(count "$n" "^sent second-$n transcript=no\$")" = 1 ] \
        && ok "$what: both drafts sent, report only" || bad "$what ($rc, $(ndrafts) left): $(panel "$n") / $(tail -4 "$FLOG")"
    [ "$(count "$n" 'transcript=yes')" = 0 ] && [ "$(count "$n" '^discard')" = 0 ] && ok "$what: no transcript sent, nothing discarded" || bad "$what: $(panel "$n")"
    size=$($T display -p -t "$p" '#{window_width}x#{window_height}')
    ! drafts_panel_up "$p" && [ "$size" = 80x24 ] && ok "$what: the panel is closed and the window is 80x24 again" || bad "$what: size $size; $($T capture-pane -p -t "$p")"
    end "$n"
}
# keeps <n> <name> <why in the log> <knob…>: a draft that cannot be sent stays queued and the panel is closed
keeps() {
    local n="$1" what="$2" why="$3" u p rc; u=$(uuid "$4"); shift 4
    mk "$n" "$u" "$@"; fake_up "sala-test-$n" || { bad "$what: the pane did not come up"; return; }
    p=$(paneid "$n"); drafts "$u" "kept-$n"; : > "$FLOG"
    "$SALA" feedback drain "$p" "$u"; rc=$?
    [ "$rc" = 2 ] && [ "$(ndrafts)" = 1 ] && [ "$(count "$n" '^sent')" = 0 ] && [ "$(count "$n" '^discard')" = 0 ] \
        && ok "$what: exit 2, nothing sent, the draft still queued" || bad "$what ($rc, $(ndrafts) left): $(panel "$n") / $(slurp "$FLOG")"
    has "$(slurp "$FLOG")" "$why" && ! drafts_panel_up "$p" && alive "$(cpid "$n")" && ok "$what: the log says why, the panel is closed, the session lives" || bad "$what: $(slurp "$FLOG") / $($T capture-pane -p -t "$p")"
    end "$n"
}

echo "== the drain sends the report and never the transcript"
sends a "choice list" 1
sends b "choice list, long review, dropped Enter" 2 FAKE_LONG=1 FAKE_DROP_ENTER=1
sends c "choice list, expired transcript" 3 FAKE_TRANSCRIPT=0
sends d "toggle" 4 FAKE_PANEL_STYLE=toggle
sends e "toggle, expired transcript" 5 FAKE_PANEL_STYLE=toggle FAKE_TRANSCRIPT=0
sends f "toggle, long review" 6 FAKE_PANEL_STYLE=toggle FAKE_LONG=1

echo "== a draft that cannot be sent stays queued"
keeps g "unknown review" "send line not selected" 7 FAKE_PANEL_STYLE=unknown
keeps h "service out of reach" "the CLI could not send it" 8 FAKE_SEND=fail
[ "$(count h '^failed kept-h$')" = 1 ] && ok "service out of reach: one attempt" || bad "attempts: $(panel h)"

echo "== the exit gate"
U=$(uuid 9); mk i "$U"; fake_up sala-test-i || exit 1; P=$(paneid i); PI=$(cpid i)
drafts_gate_up "$P"; [ $? = 1 ] && ! drafts_gate_pass "$P" && ok "no gate showing: drafts_gate_pass does nothing" || bad "a gate reported at the composer"
drafts "$U" one-i two-i
tui_send "$P" "/exit"; waitfor 'drafts_gate_up "$P"' 20 && alive "$PI" && ok "/exit with queued drafts stops at the gate" || bad "no gate: $($T capture-pane -p -t "$P")"
wait_exit "$P" 20; rc=$?
[ "$rc" = 0 ] && grep -q "^exit $U " "$FAKE_LOG" && ok "wait_exit passes the gate and the session exits" || bad "gate not passed ($rc): $($T capture-pane -p -t "$P")"
[ "$(ndrafts)" = 2 ] && [ "$(count i '^discard')" = 0 ] && [ "$(count i '^sent')" = 0 ] && ok "both drafts kept: nothing discarded, nothing sent" || bad "$(ndrafts) left: $(panel i)"
end i
U=$(uuid 10); mk j "$U"; fake_up sala-test-j || exit 1; P=$(paneid j)
drafts "$U" one-j
tui_send "$P" "/exit"; waitfor 'drafts_gate_up "$P"' 20 || bad "j: no gate"
"$SALA" feedback drain "$P"  "$U"; rc=$?
[ "$rc" = 0 ] && [ "$(count j '^sent one-j transcript=no$')" = 1 ] && [ "$(ndrafts)" = 0 ] && wait_for "$P" shell 10 && grep -q "^exit $U " "$FAKE_LOG" \
    && ok "a drain that meets the gate sends the draft, report only, and the pending exit goes on" || bad "drain at the gate ($rc): $(panel j) / $($T capture-pane -p -t "$P")"
end j

echo "== a relaunch goes on over a draft that cannot be sent"
U=$(uuid 11); mk r "$U" FAKE_SEND=fail FAKE_PANEL_STAMP=1; fake_up sala-test-r || exit 1; PR=$(cpid r)
drafts "$U" kept-r
out=$(SALA_RESUME_WAIT=20 SALA_EXIT_WAIT=30 "$SALA" revive --force --only sala-test-r 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
! alive "$PR" && [ "$(starts "$U")" = 2 ] && NR=$(cpid r) && [ -n "$NR" ] && ok "revive: the session relaunched on its conversation" || bad "no relaunch ($rc, starts $(starts "$U"))"
[ "$(ndrafts)" = 1 ] && [ "$(count r '^discard')" = 0 ] && [ "$(count r '^sent')" = 0 ] && ok "the draft is still queued after the relaunch" || bad "$(ndrafts) left: $(panel r)"
has "$out" "feedback draft(s) not sent" && has "$out" "the drafts stay queued" && ! has "$out" "by hand" && ok "the output says so and asks nothing of the owner" || bad "output: $out"
end r

echo "== the drain's own stamp is not activity"
# record <uuid> <id> <flip>: the Stop hook's record of a turn that left nothing in flight
record() { mkdir -p "$SALA_BUSY_DIR"; printf 'id=%s\nflip=%s\ntasks=0\ncrons=0\n' "$2" "$3" > "$SALA_BUSY_DIR/$1"; }
relaunch() { SALA_IDLE_SETTLE=12 SALA_RESUME_WAIT=20 SALA_EXIT_WAIT=30 "$SALA" revive --force --only "sala-test-$1" 2>&1; }
# relaunched <n> <name> <session> <record: yes|no> <knob…>: one `revive` sends the draft and relaunches the pane
relaunched() {
    local n="$1" what="$2" u pid out rec="$4"; u=$(uuid "$3"); shift 4
    mk "$n" "$u" FAKE_PANEL_STAMP=1 "$@"; fake_up "sala-test-$n" || { bad "$what: the pane did not come up"; return; }
    pid=$(cpid "$n"); drafts "$u" "own-$n"
    [ "$rec" = no ] || record "$u" "turn-$n" "$(registry_field "$pid" statusUpdatedAt)"
    out=$(relaunch "$n"); echo "$out" | sed 's/^/    /'
    [ "$(count "$n" "^sent own-$n transcript=no\$")" = 1 ] && ! alive "$pid" && [ "$(starts "$u")" = 2 ] \
        && ok "$what: the draft sent and the pane relaunched in the same run" || bad "$what (starts $(starts "$u")): $out"
    end "$n"
}
relaunched s "drain then relaunch" 12 no
relaunched t "drain then relaunch, a record of nothing in flight over a long-lived child" 13 yes FAKE_CHILD=1
# left <n> <name> <session> <skip words> <after ms,turn ms>: a turn after the send holds the pane
left() {
    local n="$1" what="$2" u pid out why="$4"; u=$(uuid "$3")
    mk "$n" "$u" FAKE_PANEL_STAMP=1 FAKE_PANEL_TURN="$5"; fake_up "sala-test-$n" || { bad "$what: the pane did not come up"; return; }
    pid=$(cpid "$n"); drafts "$u" "real-$n"
    out=$(relaunch "$n"); echo "$out" | sed 's/^/    /'
    [ "$(count "$n" "^sent real-$n transcript=no\$")" = 1 ] && alive "$pid" && [ "$(starts "$u")" = 1 ] && [[ $out =~ $why ]] && has "$out" "/exit not sent" \
        && ok "$what: the draft sent, the pane left alone" || bad "$what (starts $(starts "$u")): $out"
    end "$n"
}
left u "a turn running after the send" 14 "registry says 'busy'" 5000,30000
# a turn this short is read as ended (a new idle stamp), or as running when the one-second look lands inside it
left v "a short turn after the send" 15 "idle for only|registry says 'busy'" 5000,50
U=$(uuid 16); mk w "$U" FAKE_PANEL_STAMP=1; fake_up sala-test-w || exit 1; P=$(paneid w); PW=$(cpid w)
drafts "$U" one-w; WAS=$(registry_field "$PW" statusUpdatedAt); record "$U" before-w "$WAS"
drain_mark MARK "$PW" "$U"; "$SALA" feedback drain "$P" "$U"
record "$U" during-w "$WAS"; drain_settle "$PW" "$U" "$MARK"; why=$(is_idle_reason "$PW")
[ "$MARK" = "$WAS before-w" ] && has "$why" "idle for only" && grep -qx "flip=$WAS" "$SALA_BUSY_DIR/$U" \
    && ok "a record written during the send: no wait, the record left as it is" || bad "mark '$MARK', why '$why': $(slurp "$SALA_BUSY_DIR/$U")"
end w

[ "${fail:-0}" = 0 ] && echo "feedbackdrain: pass" || { echo "feedbackdrain: FAIL"; exit 1; }
