# lib/feedback.sh — send Claude-drafted feedback automatically, report only (never the transcript). The CLI never sends
# a draft on its own; its only send path is the /feedback panel, so this drives that panel through
# tmux in the session's own pane. A queued draft otherwise becomes a terminal-only gate at /exit
# ("You have N unsent feedback draft · Enter to review & send · Esc to discard and exit") that nobody watching
# from Remote Control can answer — and a queued /exit behind it exits with no resume.
# A DRAFT THAT CANNOT BE SENT (the service is out of reach, the panel changed) STAYS QUEUED and holds nothing up: it is
# a file under ~/.claude/feedback/drafts that outlives the relaunch (checked on 2.1.332: /exit, --resume, /exit again;
# the CLI's own expiry and its cap on queued drafts apply as ever). revive, sleep and retire go on, and pass the exit
# gate with Enter (the drafts list; sends nothing) then Esc (closes the list, the exit goes on): common.sh,
# drafts_gate_pass. Esc AT THE GATE ITSELF DELETES the session's drafts: nothing in sala presses it there.
#
# THE USAGE: `feedback` with no or an unknown verb prints from its `feedback mark` line through the `exit-time gate` line, so keep it contiguous.
#   feedback mark                  PostToolUse hook (matcher SendFeedback): this session queued a draft
#   feedback stop                  Stop hook: if marked, hand the pane to a detached `drain` once idle 3 s
#   feedback drain <pane> [sid]    drive /feedback in <pane>: review each queued draft (any session's),
#                                  send it without its transcript, until none is queued; also answers
#                                  the exit-time gate with Enter so a pending /exit completes
# Receipts: $SALA_LOG_DIR/salamander-feedback.log. `revive`/`recycle` drain before typing /exit.
# Observed screens: drafts list "❯ [type] title" (2.1.27x) or "❯ title   bug · 1d" plus a "+ Write new feedback" row
# (2.1.28x on; never select it), footer "Enter to review · d to discard · Esc to close". The review, by version:
#   up to 2.1.331  a toggle "Send transcript: ◀ yes ▶" (Left = no; "expired (report only)" when there is none), then
#                  "❯ Send feedback"; footer "Enter to send · …"
#   2.1.332        no toggle, a choice list: "❯ Not now" / "Send feedback, report only" / "Send feedback with
#                  transcript"; footer "Enter to confirm · …". A long draft shows the choices after one Down.
# Then "Sending feedback…", and "Feedback sent (receipt …) · Any key" or "Couldn't send feedback … still queued".

STATE="$SALA_LOG_DIR/feedback-state"; FLOG="$SALA_LOG_DIR/salamander-feedback.log"
flog() { mkdir -p "$SALA_LOG_DIR"; echo "[$(date -Is)] $*" >> "$FLOG"; }
# screen: the whole visible screen, blank lines dropped (a tall window leaves them under the text); cap: its last 40 lines
screen() { tmux capture-pane -p -t "$1" 2>/dev/null | grep -v '^[[:space:]]*$'; }
cap() { screen "$1" | tail -40; }
# wait_screen <pane> <pattern> <secs> → 0 once the visible screen matches (a long review's marks are far above its end)
wait_screen() { local i; for ((i=0; i<$3*2; i++)); do screen "$1" | grep -qE "$2" && return 0; sleep 0.5; done; return 1; }
key() { tmux send-keys -t "$1" "$2"; sleep "${3:-0.6}"; }   # <pane> <key> [settle]: a panel redraws after every key
# panel_escape <pane>: Esc closes a review, then the list. NEVER at the exit gate, where Esc deletes the drafts
panel_escape() { drafts_gate_up "$1" && return 1; tmux send-keys -t "$1" Escape; }
# cursor_line <pane> → the text of the last "❯ …" line on the screen: the panel is under the transcript, so it is the panel's
cursor_line() { cap "$1" | grep -E '^ *❯ ' | tail -1 | sed 's/^ *❯ *//; s/[[:space:]]*$//'; }
# report_selected <pane> → 0 only when Enter now would send the report and no transcript
report_selected() {
    case "$(cursor_line "$1")" in
        'Send feedback, report only') cap "$1" | grep -q 'Enter to confirm' ;;
        'Send feedback') cap "$1" | grep 'Send transcript:' | tail -1 | grep -qE 'Send transcript: +(◀ )?(no\b|expired \(report only\))' ;;
        *) return 1 ;;
    esac
}
# grow <pane> <height>: a taller window for a review that does not fit (restore_size puts the size back)
grow() {
    [ "$(tmux display -p -t "$1" '#{window_height}')" -lt "$2" ] || return 0
    tmux resize-window -t "$1" -y "$2" 2>/dev/null && resized=1; sleep 1
}
# select_report <pane> → 0 with the cursor on the send that carries no transcript; 1 with WHY. No Enter is pressed here
select_report() {
    local p="$1" i
    screen "$p" | grep -qE 'Send transcript:|Send feedback, report only' || grow "$p" 150
    if screen "$p" | grep -q 'Send transcript:'; then   # up to 2.1.331: the toggle above the send line
        if ! cap "$p" | grep -q 'Send transcript: expired'; then
            key "$p" Up
            cap "$p" | grep -qE 'Send transcript: ◀ yes' && key "$p" Left
            cap "$p" | grep -qE 'Send transcript: ◀ no' || { WHY="could not set transcript=no"; return 1; }
            key "$p" Down
        fi
    else                                                # 2.1.332: the choice list, "Not now" selected first
        for ((i=0; i<4; i++)); do
            case "$(cursor_line "$p")" in
                'Send feedback, report only') break ;;
                'Send feedback with transcript') key "$p" Up ;;
                *) key "$p" Down ;;
            esac
        done
    fi
    report_selected "$p" || { WHY="send line not selected"; return 1; }
}
# confirm_report <pane> → 0 on the receipt, 1 with WHY. Enter is pressed only while report_selected holds, and a second
# time only when 3 s later the same line is still selected and nothing is being sent (the CLI drops a key within 500 ms
# of a move, and a first Enter on a view that is not at its end only scrolls it)
confirm_report() {
    local p="$1" i s
    sleep 0.7
    report_selected "$p" || { WHY="send line not selected"; return 1; }
    tmux send-keys -t "$p" Enter
    for ((i=1; i<=60; i++)); do
        sleep 0.5; s=$(cap "$p")
        grep -q 'Feedback sent (receipt' <<< "$s" && return 0
        grep -q "Couldn't send feedback" <<< "$s" && { WHY="the CLI could not send it ($(grep -o "Couldn't send feedback.*" <<< "$s" | head -1))"; return 1; }
        [ "$i" = 6 ] && ! grep -q 'Sending feedback' <<< "$s" && report_selected "$p" && tmux send-keys -t "$p" Enter
    done
    WHY="send did not confirm"; return 1
}
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
if ! drafts_queued "$sid" && ! drafts_panel_up "$pane" && ! drafts_gate_up "$pane"; then exit 0; fi
if [ -n "$given" ]; then   # wait until the session has been idle for 3 s (up to 10 min) before touching its input
    ok=0
    for ((i=0; i<600; i++)); do
        if [ "$(reg status "$sid")" = idle ]; then sleep 3; [ "$(reg status "$sid")" = idle ] && { ok=1; break; }; else sleep 1; fi
    done
    [ "$ok" = 1 ] || { flog "drain: $pane never went idle; draft stays queued"; exit 1; }
fi
# A detached pane (no client attached) is 80x24, and the review screen overflows it: the send lines
# scroll off, the drain cannot select one, and the draft stays queued. Give the window room for
# the panel, then put the size back (and drop the per-window manual size so it follows a client again).
ow=$(tmux display -p -t "$pane" '#{window_width}'); oh=$(tmux display -p -t "$pane" '#{window_height}'); resized=0
if [ "${oh:-0}" -lt 45 ] || [ "${ow:-0}" -lt 100 ]; then
    tmux resize-window -t "$pane" -x $(( ow < 120 ? 120 : ow )) -y $(( oh < 50 ? 50 : oh )) 2>/dev/null && resized=1; sleep 1
fi
restore_size() { [ "$resized" = 1 ] || return 0; tmux resize-window -t "$pane" -x "$ow" -y "$oh" 2>/dev/null; tmux set-option -w -t "$pane" -u window-size 2>/dev/null; }
trap restore_size EXIT
tmux send-keys -X -t "$pane" cancel 2>/dev/null
# the same gate again on the screen as it is after the wait: sent meanwhile → nothing to do; do not open /feedback
if ! drafts_queued "$sid" && ! drafts_panel_up "$pane" && ! drafts_gate_up "$pane"; then exit 0; fi
if ! drafts_panel_up "$pane"; then
    if drafts_gate_up "$pane"; then tmux send-keys -t "$pane" Enter   # exit-time gate
    else tui_send "$pane" "/feedback" || { flog "drain: could not open /feedback in $pane (see stderr)"; exit 1; }; fi
    wait_screen "$pane" "$SALA_DRAFTS_PANEL_RE" 10 || { flog "drain: the /feedback panel did not open in $pane"; panel_escape "$pane"; exit 1; }
fi
sent=0
for ((n=0; n<10; n++)); do
    screen "$pane" | grep -qE 'No feedback drafts (queued|yet)' && break
    # a draft row under the cursor; the cursor on "+ Write new feedback" (2.1.28x on) means the list is empty
    row=$(cursor_line "$pane")
    case "$row" in *'Write new feedback'*) break ;; '') flog "drain: unexpected panel state in $pane"; break ;; esac
    tmux send-keys -t "$pane" Enter
    wait_screen "$pane" 'Send transcript:|Send feedback, report only|Esc to (go back|later)|^ *Details:' 5 || { flog "drain: the review did not open in $pane"; break; }
    sleep 0.5
    if ! select_report "$pane" || ! confirm_report "$pane"; then flog "drain: $WHY in $pane; leaving the draft queued"; break; fi
    flog "sent from $pane (transcript: no): $(cap "$pane" | grep -oE 'receipt [0-9a-f-]+' | tail -1)"; sent=$((sent+1))
    tmux send-keys -t "$pane" Enter; sleep 1                       # "Any key to continue"
    drafts_panel_up "$pane" || break                               # panel closed, or a pending /exit completed
done
# close the panel and WAIT until it is gone: a caller that checks the screen right after us must not
# see our own panel and mistake it for a prompt (a recycle once skipped panes that way)
for ((n=0; n<10; n++)); do
    drafts_panel_up "$pane" || break
    panel_escape "$pane" || break
    sleep 1
done
# leave the composer exactly as empty as we found it — residue here swallows the next command silently
[ "$(pane_draft_screen "$pane")" = "/feedback" ] && tmux send-keys -t "$pane" C-u
flog "drain done: $sent sent from $pane"
# still queued for this conversation → say so by the exit code (the caller goes on: the drafts outlive the relaunch)
if [ -n "$sid" ] && drafts_queued "$sid"; then flog "drain: draft(s) still queued for $sid in $pane"; exit 2; fi
exit 0
