# OFF BY DEFAULT: the step below does nothing unless SALA_IDLE_WRAPUP=on. The CLI's
# own compaction is the only limit on a background agent's conversation. The code stays, for a later decision to turn it back on.
#
# lib/wrapup.sh — watch's IDLE WRAP-UP AND CLEAR: a background agent that has sat idle for about 50 minutes is asked to write down what
# only it knows, and once that turn has ended its conversation is cleared. Sourced by lib/watch.sh (like barepane.sh); wrapup_tick runs
# once per watch tick, after bare_tick, and alone as `sala watch --wrapup [--dry-run]`.
#
# WHY (before a fresh start, each builder is asked to wrap up and clear its write debts):
# a background agent wakes on a notice, and when the wake comes after its prompt cache has expired the CLI reloads the whole
# conversation (about 200k tokens). Over two weeks, a fifth of the builders' wakes started cold, and a third of their cost. The cache
# lives an hour, so a turn at the 50th minute is still cheap, and the conversation that follows it is empty: the next wake starts from
# the mandate, the rules and the board (the background brief in the agent's CLAUDE.md, its page's Current state from the SessionStart
# keeper hook, and the one line `hook session-start` adds for a cleared background agent, lib/hook.sh).
#
# WHICH PANES: only a pane whose session-registry row (sessions.json) is LIVE with role `back`: never a front agent (the owner talks to
# those), never a side session, never a pane on the sdk lane, never a session in SALA_NO_RELAUNCH, never one outside the pane map.
#
# THE TWO STEPS, one per tick for a pane (a state per session in the watch state, keys wrap.<session>):
#   1. WRAP-UP. The pane's registry row says idle and has said so for SALA_IDLE_WRAPUP_MIN minutes (50) but not longer than
#      SALA_IDLE_WRAPUP_MAX_AGE minutes (58: the warm window; past it the prompt cache is cold, a wrap-up turn would itself reload the
#      whole conversation uncached, so the pane is left ALONE: no wrap-up, no clear, one log line), AND all of this holds: no
#      background command, task or subagent holds it (is_idle: the Stop hook's record, the process tree, lib/holders.py), it is not parked
#      on a background job (registry `parkedJobId`, status `shell`), no dialog is showing (pane_prompt), nothing is typed in its input
#      box (pane_draft), its last turn's Stop record lists no scheduled job (a cron dies with the conversation), and it has HAD A REAL
#      TURN since its process started or since sala last cleared it (the Stop hook's record for its conversation, $SALA_BUSY_DIR/<id>,
#      is newer than both: a relaunched or just-cleared pane has nothing to write down and a cold cache, so it is left alone, and sala
#      never wraps up and clears one pane twice with no wake in between). Then the text below is typed into the pane (tui_send: marked
#      `<!-- sala -->`, never over a draft) and the state says `sent`.
#   2. CLEAR. A later tick finds the pane's turn over: the row says idle again with a stamp newer than the typed text, and the same
#      checks as above hold (idle, no dialog, empty input box). `/clear` is typed (tui_send) and the tick waits for the CLI to give the
#      row its new conversation id (probed on 2.1.312: the same row and pid, the name and nameSource kept, a new sessionId within
#      a second, a new transcript carrying the /clear record, SessionStart source=clear fired with the new id). The pane map then follows
#      the new conversation at once (ledger_write follow; it would be applied by the next `revive --save-map` all the same), the session
#      registry gets it as `clear` (idempotent: the SessionStart hook records it too), and the state says `cleared`.
#   A turn is never interrupted: a pane that is busy, in a dialog or has a draft is skipped and looked at again at the next tick. A
#   wrap-up that produced no turn within SALA_WRAPUP_START_WAIT is dropped and tried again after SALA_WRAPUP_RETRY; a /clear that the CLI does not take is tried
#   SALA_CLEAR_TRIES times, then recorded as `failed <time> <conversation> <pid>`: the pane is not wrapped up again while its conversation
#   and pid are unchanged and no Stop record is newer than the failure (a /clear that never takes would otherwise cost a wrap-up every
#   50+ minutes). A pane relaunched or cleared by someone else between the two steps drops its state. The warm-window bound applies to
#   every wrap-up, a retry after a dropped one included; the /clear after a wrap-up turn is not bound (it makes no model call).
#
# NEVER: while a recycle holds the lock, a revive, rename, retire, spawn, lane, model, reboot or queued operation runs, the pane map is
# frozen or a resurrect restore runs (bare_busy, lib/barepane.sh); on a tmux server that is not the fleet's. At most SALA_IDLE_WRAPUP_MAX
# actions (a wrap-up typed, a /clear typed) per tick.
#
# NO POST, NO WAKE: each wrap-up and each clear is ONE LINE in the watch log (~/.claude/salamander-watch.log, "wrapup: …"), and the
# follow is a line in the pane-map ledger log; nothing goes to Slack and no message is sent to any other session. (What the agent writes
# during its wrap-up turn is its own board and page work, as in any turn.)
#
# KNOBS: SALA_IDLE_WRAPUP is OFF by default (the CLI's own compaction is the limit); SALA_IDLE_WRAPUP=on turns the step on.
# Before turning it back on, delete the wrap.* keys from ~/.claude/salamander-watch.state, or a pane left in phase `sent` is cleared without a fresh wrap-up.
# With it off (or SALA_IDLE_WRAPUP_MIN=0) nothing is read, typed or kept. SALA_IDLE_WRAPUP_MIN
# (50), SALA_IDLE_WRAPUP_MAX_AGE (58; 0 or off = no upper bound), SALA_IDLE_WRAPUP_MAX (3), SALA_WRAPUP_START_WAIT (300), SALA_WRAPUP_RETRY (1800), SALA_CLEAR_WAIT (20), SALA_CLEAR_TRIES (3).
# `sala watch --wrapup --dry-run` prints, for every back pane, what the step would do or why it would not; it changes nothing.

: "${SALA_IDLE_WRAPUP:=off}" "${SALA_IDLE_WRAPUP_MIN:=50}" "${SALA_IDLE_WRAPUP_MAX_AGE:=58}" "${SALA_IDLE_WRAPUP_MAX:=3}" "${SALA_WRAPUP_START_WAIT:=300}" "${SALA_WRAPUP_RETRY:=1800}" "${SALA_CLEAR_WAIT:=20}" "${SALA_CLEAR_TRIES:=3}"

# THE WRAP-UP TEXT — the one place it lives (the PR body quotes it). tui_send puts the `<!-- sala -->` marker in front, as for every message sala types.
wrapup_text() {
    printf 'sala: you have been idle %s minutes; your conversation is cleared after this turn. Write anything only you know to your items and pages (board update, page Current state or timeline line), then reply done.' "${SALA_IDLE_WRAPUP_MIN:-50}"
}

wrapup_on() {
    case "${SALA_IDLE_WRAPUP:-off}" in on|1|yes|true) ;; *) return 1;; esac   # off by default; only an explicit on turns it on
    case "${SALA_IDLE_WRAPUP_MIN:-50}" in ''|0|off|no|false|*[!0-9]*) return 1;; esac
    return 0
}

# wrap_back_names → the names of the live back-role rows of the session registry (sessions.json), one per line; side sessions never
wrap_back_names() {
    sessions_on && [ -r "$SALA_SESSIONS_FILE" ] || return 0
    python3 -I -S -c 'import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
rows = d.get("sessions") if isinstance(d, dict) else None
for r in (rows.values() if isinstance(rows, dict) else []):
    if isinstance(r, dict) and r.get("state") == "live" and r.get("role") == "back" and not r.get("side") and r.get("name"): print(r["name"])' "$SALA_SESSIONS_FILE" 2>/dev/null
}

# wrap_maxage_s → the upper bound of the idle age in seconds, or 0 for none (SALA_IDLE_WRAPUP_MAX_AGE: minutes; 0/off/no/false = none; junk = 58)
wrap_maxage_s() {
    case "${SALA_IDLE_WRAPUP_MAX_AGE:-58}" in
        0|off|no|false) echo 0;;
        ''|*[!0-9]*) echo $((58 * 60));;
        *) echo $(( SALA_IDLE_WRAPUP_MAX_AGE * 60 ));;
    esac
}

WRAP_WHY=""
# wrap_ready <session> <pane> <claude pid> <conversation> <idle age> → 0 when the pane may be spoken to now; else 1 with WRAP_WHY (one
# short reason, empty for "not interesting yet"). Cheap checks first: a file read each; tmux and the process tree only after them.
# <stage> is wrap (a first wrap-up) or clear (the turn is over; the idle-age and turn-since rules do not apply, the rest does).
wrap_ready() {
    local sess="$1" pane="$2" pid="$3" conv="$4" age="$5" stage="$6" st started stop e crons base v ph a b c lane hold d mx
    WRAP_WHY=""
    registry_field_r st "$pid" status
    if parked_job_r hold "$pid"; then WRAP_WHY="parked on a background job ($hold)"; return 1; fi
    [ "$st" = idle ] || { WRAP_WHY="registry says '${st:-?}' (a turn, a dialog or background work)"; return 1; }
    if [ "$stage" = wrap ]; then
        [ "$age" -ge $(( SALA_IDLE_WRAPUP_MIN * 60 )) ] || return 1
        mx=$(wrap_maxage_s)
        if [ "$mx" -gt 0 ] && [ "$age" -gt "$mx" ]; then WRAP_WHY="past the warm window (over $((mx / 60)) min, the prompt cache is cold): left alone, no wrap-up and no clear"; return 1; fi
        registry_field_r started "$pid" startedAt
        [[ ${started:0:10} =~ ^[0-9]{10}$ ]] || { WRAP_WHY="no start time in its registry row"; return 1; }
        started=${started:0:10}; base=$started
        _key_r v "$sess"; v=$(st_get "wrap.$v"); read -r ph a b c <<< "$v"
        if [ "$ph" = cleared ] && [ "$b" = "$conv" ] && [ "$c" = "$pid" ]; then [ "$a" -gt "$base" ] && base=$a; fi
        stop="$SALA_BUSY_DIR/$conv"
        _kv_first_r e "$stop" epoch
        [[ $e =~ ^[0-9]+$ ]] && [ "$e" -gt "$base" ] || { WRAP_WHY="no turn since $([ "$base" = "$started" ] && echo "its claude started" || echo "sala cleared it")"; return 1; }
        _kv_first_r crons "$stop" crons
        if [ "${crons:-0}" -gt 0 ] 2>/dev/null || grep -q '^cron=' "$stop" 2>/dev/null; then WRAP_WHY="its last turn left a scheduled job (a clear would end it)"; return 1; fi
    fi
    _proc_lane_r lane "$pid"
    [ "$lane" != sdk ] || { WRAP_WHY="on the sdk lane"; return 1; }
    is_idle "$pid" || { WRAP_WHY=$(is_idle_reason "$pid"); WRAP_WHY=${WRAP_WHY%%;*}; WRAP_WHY=${WRAP_WHY:-"not idle"}; return 1; }
    if pane_prompt "$pane"; then WRAP_WHY="a dialog is showing"; return 1; fi
    d=$(pane_draft "$pane" "$pid")
    if [ -n "$d" ] && ! [[ $d == "$SALA_MSG_MARK"* || $d == /clear ]]; then WRAP_WHY="text is typed in its input box"; return 1; fi
    return 0
}

# wrap_say <key> <line> [<reason>] — a skip reason, logged when it changes for that pane (the dry run prints it every time). What is compared
# is the reason (default: the whole line), never the idle minutes in the line: a pane idle for hours would log it again every minute.
wrap_say() {
    local k="$1" line="$2" why="${3:-$2}" prev
    if [ "${WRAP_DRY:-0}" = 1 ]; then printf '%s\n' "$line"; return 0; fi
    prev=$(st_get "wrapwhy.$k")
    [ "$prev" = "$why" ] && return 0
    st_set "wrapwhy.$k" "$why"; wlog "wrapup: $line"
}

# wrap_clear_one <session> <pane> <pid> <conversation> <key> <sent epoch> <tries> → types /clear and follows the new conversation
wrap_clear_one() {
    local sess="$1" pane="$2" pid="$3" conv="$4" k="$5" t0="$6" tries="${7:-0}" out rc nc i cwd fr now
    tries=$(( tries + 1 ))
    if [ "$tries" -gt "$SALA_CLEAR_TRIES" ]; then
        _now_r now; st_set "wrap.$k" "failed $now $conv $pid"; wlog "wrapup: $sess did not take /clear in $SALA_CLEAR_TRIES tries — given up, not wrapped up again until its conversation has a new turn"; return 0
    fi
    st_set "wrap.$k" "sent $t0 $conv $pid $tries"
    out=$(tui_send "$pane" /clear 2>&1); rc=$?
    if [ "$rc" != 0 ]; then wlog "wrapup: /clear into $sess failed (try $tries of $SALA_CLEAR_TRIES): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"; return 0; fi
    nc=""
    for ((i = 0; i < SALA_CLEAR_WAIT * 2; i++)); do
        registry_conv_r nc "$pid"
        [ -n "$nc" ] && [ "$nc" != "$conv" ] && break
        _nap 0.5
    done
    if [ -z "$nc" ] || [ "$nc" = "$conv" ]; then wlog "wrapup: /clear typed into $sess but its conversation is still $conv after ${SALA_CLEAR_WAIT}s (try $tries of $SALA_CLEAR_TRIES)"; return 0; fi
    registry_field_r cwd "$pid" cwd; [ "$cwd" = null ] && cwd=""
    fr=$(ledger_write follow "$sess" "$nc" "$cwd" 2>&1); rc=$?
    sessions_record_soft "$sess" "$nc" clear
    _now_r now; st_set "wrap.$k" "cleared $now $nc $pid"; st_del "wrapwhy.$k"
    wlog "wrapup: cleared $sess: conversation $conv → $nc; pane map $([ "$rc" = 0 ] && echo followed || echo "NOT followed (exit $rc: $(printf '%s' "$fr" | tr '\n' ' ' | cut -c1-160))")"
}

wrapup_locked() {
    local tbl sess pane pid k v ph a b c d conv st stamp age now acts=0 line seenk=" " q kk e
    local -A isback=()
    _now_r now
    while IFS= read -r line; do [ -n "$line" ] && isback[$line]=1; done < <(wrap_back_names)
    _claude_panes_r tbl   # fresh: a relaunch earlier in this tick has changed pids
    while IFS='|' read -r sess pane pid; do
        [ -n "$sess" ] && [ -n "${isback[$sess]+x}" ] || continue
        [ "$sess" != "${SALA_RC_SESSION:-}" ] || continue
        [ -z "${SALA_MASTER:-}" ] || [ "$sess" != "$SALA_MASTER" ] || continue
        _key_r k "$sess"
        case "$seenk" in *" $k "*) continue;; esac; seenk="$seenk$k "
        no_relaunch "$sess" && continue                                                   # managed outside sala: nothing is typed into it
        is_rc_child "$pid" && continue
        registry_conv_r conv "$pid"; [ -n "$conv" ] && [ "$conv" != null ] || continue
        v=$(st_get "wrap.$k"); ph=""; a=""; b=""; c=""; d=""; read -r ph a b c d <<< "$v"
        registry_field_r st "$pid" status; registry_field_r stamp "$pid" statusUpdatedAt
        if [[ ${stamp:0:10} =~ ^[0-9]{10}$ ]]; then _stamp_age_r age "$stamp"; else age=0; fi
        # a pane the pane map does not know has no row to follow and no revive: left alone (sala adopt registers it)
        if [ -z "$(ledger_row "$sess")" ]; then
            [ "$age" -ge $(( SALA_IDLE_WRAPUP_MIN * 60 )) ] && wrap_say "$k" "$sess: not in the pane map — left alone"
            continue
        fi
        case "$ph" in
            sent)
                if [ "$c" != "$pid" ] || [ "$b" != "$conv" ]; then
                    if [ "${WRAP_DRY:-0}" = 1 ]; then echo "$sess: was asked to wrap up, then relaunched or cleared by someone else — the ask would be dropped"; continue; fi
                    st_del "wrap.$k"; wlog "wrapup: $sess was relaunched or cleared after its wrap-up was typed — dropped"; continue
                fi
                if ! { [ "$st" = idle ] && [ "${stamp:0:10}" -ge "$a" ] 2>/dev/null; }; then      # its turn has not ended (or never began)
                    if [ "$st" = idle ] && [ $(( now - a )) -gt "$SALA_WRAPUP_START_WAIT" ]; then
                        if [ "${WRAP_DRY:-0}" = 1 ]; then echo "$sess: the wrap-up produced no turn in ${SALA_WRAPUP_START_WAIT}s — it would be dropped"; continue; fi
                        st_set "wrap.$k" "retry $now"; wlog "wrapup: the wrap-up typed into $sess produced no turn in ${SALA_WRAPUP_START_WAIT}s — dropped, tried again after $((SALA_WRAPUP_RETRY / 60)) min"
                    elif [ "${WRAP_DRY:-0}" = 1 ]; then echo "$sess: its wrap-up turn is running"; fi
                    continue
                fi
                if ! wrap_ready "$sess" "$pane" "$pid" "$conv" "$age" clear; then wrap_say "$k" "$sess: wrap-up turn over, clear waits — $WRAP_WHY"; continue; fi
                if [ "${WRAP_DRY:-0}" = 1 ]; then echo "$sess: wrap-up turn over — /clear would be typed now"; continue; fi
                if [ "$acts" -ge "$SALA_IDLE_WRAPUP_MAX" ]; then wlog "wrapup: cap of $SALA_IDLE_WRAPUP_MAX actions per tick — $sess waits for the next"; continue; fi
                acts=$((acts + 1)); wrap_clear_one "$sess" "$pane" "$pid" "$conv" "$k" "$a" "${d:-0}" ;;
            *)
                if [ "$ph" = retry ] && [ $(( now - a )) -lt "$SALA_WRAPUP_RETRY" ]; then continue; fi
                if [ "$ph" = failed ] && [ "$b" = "$conv" ] && [ "$c" = "$pid" ]; then          # its /clear never took: waits for a new turn
                    _kv_first_r e "$SALA_BUSY_DIR/$conv" epoch
                    if ! { [[ $e =~ ^[0-9]+$ ]] && [ "$e" -gt "$a" ]; }; then wrap_say "$k" "$sess: not wrapped up — its /clear was not taken; waits for a new turn" "/clear not taken, waits for a new turn"; continue; fi
                fi
                if ! wrap_ready "$sess" "$pane" "$pid" "$conv" "$age" wrap; then
                    if [ -n "$WRAP_WHY" ]; then wrap_say "$k" "$sess: idle $((age / 60)) min, not wrapped up — $WRAP_WHY" "$WRAP_WHY"
                    elif [ "${WRAP_DRY:-0}" = 1 ] && [ "$st" = idle ]; then echo "$sess: idle ${age}s of $((SALA_IDLE_WRAPUP_MIN * 60))s — not yet"; fi
                    continue
                fi
                if [ "${WRAP_DRY:-0}" = 1 ]; then echo "$sess: idle $((age / 60)) min — the wrap-up would be typed now"; continue; fi
                if [ "$acts" -ge "$SALA_IDLE_WRAPUP_MAX" ]; then wlog "wrapup: cap of $SALA_IDLE_WRAPUP_MAX actions per tick — $sess waits for the next"; continue; fi
                acts=$((acts + 1))
                q=$(tui_send "$pane" "$(wrapup_text)" 2>&1) || { wlog "wrapup: the wrap-up was not typed into $sess: $(printf '%s' "$q" | tr '\n' ' ' | cut -c1-200)"; continue; }
                _now_r now; st_set "wrap.$k" "sent $now $conv $pid 0"; st_del "wrapwhy.$k"
                wlog "wrapup: typed the wrap-up into $sess (idle $((age / 60)) min, conversation $conv)" ;;
        esac
    done <<< "$tbl"
    [ "${WRAP_DRY:-0}" = 1 ] && return 0
    # states of sessions that are no longer back-role panes with a claude (retired, gone): dropped. Not when either list came back empty:
    # an unreadable sessions.json or a failed tmux read is no sign that every pane is gone, and the purge would drop in-flight states.
    [ "${#isback[@]}" -gt 0 ] && [ -n "$tbl" ] || return 0
    for kk in $(grep -o '^wrap\(why\)\?\.[^=]*' "$WSTATE" 2>/dev/null); do
        case "$seenk" in *" ${kk#*.} "*) ;; *) st_del "$kk";; esac
    done
    return 0
}

wrapup_tick() {
    wrapup_on || return 0
    [ -s "$SALA_SIDECAR" ] || return 0
    on_fleet_server || return 0
    tmux has-session 2>/dev/null || return 0
    if bare_busy; then [ "${WRAP_DRY:-0}" = 1 ] && echo "standing aside — $BARE_BUSY_WHY"; return 0; fi
    ( flock -n 8 || exit 0; wrapup_locked ) 8>>"$SALA_LOG_DIR/salamander-wrapup.lock"
}
