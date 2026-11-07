# lib/feedback.sh — send Claude-drafted feedback automatically, transcript OFF. The CLI never sends
# a draft on its own; its only send path is the /feedback panel, so this drives that panel through
# tmux in the session's own pane. A queued draft otherwise becomes a terminal-only gate at /exit
# ("You have N unsent feedback draft · Enter to review & send · Esc to discard") that nobody watching
# from Remote Control can answer — and a queued /exit behind it exits with no resume.
#
# THE USAGE: `feedback` with no or an unknown verb prints from its `feedback mark` line through the `exit-time gate` line, so keep it contiguous.
#   feedback mark                  PostToolUse hook (matcher SendFeedback): this session queued a draft
#   feedback stop                  Stop hook: if marked, hand the pane to a detached `drain` once idle 3 s
#   feedback drain <pane> [sid]    drive /feedback in <pane>: review each queued draft (any session's),
#                                  set "Send transcript" to no, send, until none is queued; also answers
#                                  the exit-time gate with Enter so a pending /exit completes
# Receipts: $SALA_LOG_DIR/salamander-feedback.log. `revive`/`recycle` drain before typing /exit.
# Observed screens (Claude Code 2.1.x): drafts list "❯ [type] title · Enter to review · d to discard";
# review "Send transcript: ◀ yes ▶" (Left = no), "❯ Send feedback"; "Feedback sent (receipt …) · Any key".
# Panel rows: 2.1.27x "❯ [bug] title"; 2.1.28x "❯ title   bug · 1d" + a "+ Write new feedback" row (never select it).

STATE="$SALA_LOG_DIR/feedback-state"; FLOG="$SALA_LOG_DIR/salamander-feedback.log"
flog() { mkdir -p "$SALA_LOG_DIR"; echo "[$(date -Is)] $*" >> "$FLOG"; }
cap() { tmux capture-pane -p -t "$1" 2>/dev/null | tail -40; }
wait_screen() { local i; for ((i=0; i<$3*2; i++)); do cap "$1" | grep -qE "$2" && return 0; sleep 0.5; done; return 1; }
sid_from_stdin() { python3 -c 'import json,sys; print(json.load(sys.stdin).get("session_id",""))' 2>/dev/null; }
reg() {  # reg <pane|status> <session_id> → registry value
    REG="$SALA_REG_DIR" python3 - "$1" "$2" <<'PY'
import json, glob, os, sys
field, sid = sys.argv[1], sys.argv[2]
for f in glob.glob(os.path.join(os.environ["REG"], "*.json")):
    try: d = json.load(open(f))
    except Exception: continue
    if d.get("sessionId") == sid:
        if field == "pane":
            t = d.get("tmux", "") or ""; print("%" + t.rsplit("%", 1)[1] if "%" in t else "")
        else: print(d.get("status", ""))
        break
PY
}
case "${1:-}" in
    mark)  sid=$(sid_from_stdin); [ -n "$sid" ] && { mkdir -p "$STATE"; touch "$STATE/$sid"; }; exit 0 ;;
    stop)  sid=$(sid_from_stdin); { [ -n "$sid" ] && [ -f "$STATE/$sid" ]; } || exit 0
           rm -f "$STATE/$sid"; pane=$(reg pane "$sid")
           [ -n "$pane" ] || { flog "stop: no tmux pane for session $sid; draft stays queued"; exit 0; }
           setsid nohup "$SALA_BIN" feedback drain "$pane" "$sid" >/dev/null 2>&1 < /dev/null &
           exit 0 ;;
    drain) ;;
    *) awk '/^#   feedback mark /{p=1} p{print} p && /the exit-time gate with Enter/{exit}' "$SALA_ROOT/lib/feedback.sh" | sed 's/^# \{0,1\}//'; exit 2 ;;   # by pattern, not a line range
esac
pane="${2:-}"; sid="${3:-}"; [ -n "$pane" ] || die "drain needs a pane id"
# whose drafts: the given session id, else the conversation the pane's claude process is on. Drafts carry
# source_session_id, so a pane is only opened for ITS OWN drafts (a global check once opened
# /feedback in a pane with none, that panel has no draft rows, and the drain reported "did not open")
given="$sid"; [ -n "$sid" ] || sid=$(registry_field "$(claude_pid_under "$(tmux display -p -t "$pane" '#{pane_pid}' 2>/dev/null)" 2>/dev/null)" sessionId 2>/dev/null)
# nothing queued for this conversation and no panel/gate already showing → nothing to do, and say so AT ONCE: before the
# idle wait and the resize below, which cost a recycle seconds per pane for every pane that had nothing to send
if ! drafts_queued "$sid" && ! cap "$pane" | grep -qE 'Feedback drafts|unsent feedback draft'; then exit 0; fi
if [ -n "$given" ]; then   # wait until the session has been idle for 3 s (up to 10 min) before touching its input
    ok=0
    for ((i=0; i<600; i++)); do
        if [ "$(reg status "$sid")" = idle ]; then sleep 3; [ "$(reg status "$sid")" = idle ] && { ok=1; break; }; else sleep 1; fi
    done
    [ "$ok" = 1 ] || { flog "drain: $pane never went idle; draft stays queued"; exit 1; }
fi
# A detached pane (no client attached) is 80x24, and the review screen overflows it: the "Send feedback" line
# scrolls off, the drain cannot select it, and the draft stays queued. Give the window room for
# the panel, then put the size back (and drop the per-window manual size so it follows a client again).
ow=$(tmux display -p -t "$pane" '#{window_width}'); oh=$(tmux display -p -t "$pane" '#{window_height}'); resized=0
if [ "${oh:-0}" -lt 45 ] || [ "${ow:-0}" -lt 100 ]; then
    tmux resize-window -t "$pane" -x $(( ow < 120 ? 120 : ow )) -y $(( oh < 50 ? 50 : oh )) 2>/dev/null && resized=1; sleep 1
fi
restore_size() { [ "$resized" = 1 ] || return 0; tmux resize-window -t "$pane" -x "$ow" -y "$oh" 2>/dev/null; tmux set-option -w -t "$pane" -u window-size 2>/dev/null; }
trap restore_size EXIT
tmux send-keys -X -t "$pane" cancel 2>/dev/null
screen=$(cap "$pane")
# the same gate again on the screen as it is after the wait: sent meanwhile → nothing to do; do not open /feedback
if ! drafts_queued "$sid" && ! echo "$screen" | grep -qE 'Feedback drafts|unsent feedback draft'; then exit 0; fi
if ! echo "$screen" | grep -q 'Feedback drafts'; then
    if echo "$screen" | grep -q 'unsent feedback draft'; then tmux send-keys -t "$pane" Enter   # exit-time gate
    else tui_send "$pane" "/feedback" || { flog "drain: could not open /feedback in $pane (see stderr)"; exit 1; }; fi
    wait_screen "$pane" 'Feedback drafts' 10 || { flog "drain: the /feedback panel did not open in $pane"; tmux send-keys -t "$pane" Escape; exit 1; }
fi
sent=0
for ((n=0; n<10; n++)); do
    s=$(cap "$pane")
    echo "$s" | grep -q 'No feedback drafts queued' && break
    # a draft row under the cursor: 2.1.27x "❯ [bug] title", 2.1.28x "❯ title   bug · 1d"; the cursor on
    # "+ Write new feedback" (2.1.28x) means the list is empty
    echo "$s" | grep -E '^ *❯ ' | grep -q 'Write new feedback' && break
    echo "$s" | grep -qE '^ *❯ [^ ]' || { flog "drain: unexpected panel state in $pane"; break; }
    tmux send-keys -t "$pane" Enter
    wait_screen "$pane" 'Send transcript' 5 || { flog "drain: the review did not open in $pane"; break; }
    tmux send-keys -t "$pane" Up; sleep 0.5
    cap "$pane" | grep -qE 'Send transcript: ◀ yes' && { tmux send-keys -t "$pane" Left; sleep 0.5; }
    cap "$pane" | grep -qE 'Send transcript: ◀ no' || { flog "drain: could not set transcript=no in $pane; leaving the draft"; tmux send-keys -t "$pane" Escape; break; }
    tmux send-keys -t "$pane" Down; sleep 0.5
    cap "$pane" | grep -qE '❯ Send feedback' || { flog "drain: send line not selected in $pane; leaving the draft"; tmux send-keys -t "$pane" Escape; break; }
    tmux send-keys -t "$pane" Enter
    if wait_screen "$pane" 'Feedback sent \(receipt' 30; then
        flog "sent from $pane (transcript: no): $(cap "$pane" | grep -oE 'receipt [0-9a-f-]+' | tail -1)"; sent=$((sent+1))
    else flog "drain: send did not confirm in $pane"; tmux send-keys -t "$pane" Escape; break; fi
    tmux send-keys -t "$pane" Enter; sleep 1                       # "Any key to continue"
    cap "$pane" | grep -q 'Feedback drafts' || break                # panel closed, or a pending /exit completed
done
# close the panel and WAIT until it is gone: a caller that checks the screen right after us must not
# see our own panel and mistake it for a prompt (a recycle once skipped panes that way)
for ((n=0; n<10; n++)); do
    cap "$pane" | grep -q 'Feedback drafts' || break
    tmux send-keys -t "$pane" Escape; sleep 1
done
# leave the composer exactly as empty as we found it — residue here swallows the next command silently
[ "$(pane_draft_screen "$pane")" = "/feedback" ] && tmux send-keys -t "$pane" C-u
flog "drain done: $sent sent from $pane"
# still queued for this conversation → its /exit would stop at the drafts gate; tell the caller (revive skips the pane)
if [ -n "$sid" ] && drafts_queued "$sid"; then flog "drain: draft(s) still queued for $sid in $pane"; exit 2; fi
exit 0
