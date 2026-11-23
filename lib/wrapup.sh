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
    _claude_panes_r tbl   # fresh: a relaunch earlier in this tick has changed pids. Only panes with a claude process are listed: a SLEEPING session (common.sh) has none, so it is never wrapped up or cleared
    while IFS='|' read -r sess pane pid; do
        [ -n "$sess" ] && [ -n "${isback[$sess]+x}" ] || continue
        [ "$sess" != "${SALA_RC_SESSION:-}" ] || continue
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
    tmux_server_up || return 0
    if bare_busy; then [ "${WRAP_DRY:-0}" = 1 ] && echo "standing aside — $BARE_BUSY_WHY"; return 0; fi
    ( flock -n 8 || exit 0; wrapup_locked ) 8>>"$SALA_LOG_DIR/salamander-wrapup.lock"
}

# ── SLEEP_READY (the verdict `sala sleep` asks, lib/sleep.sh, and the idle sleep tick of the watch, sleep_tick below) ─────────────────────────────────────────────────
# sleep_ready <tmux session> [project] → 0 when the session may go to sleep now (common.sh, THE SLEEPING SESSIONS); else 1 with the FIRST refusing reason
# as one short text in SLEEP_WHY and on stdout. It reuses wrap_ready (stage clear: idle in the registry, not waiting on a background job, no background work,
# no dialog, nothing typed; the wrap-up's own idle-age window and its warm bound do not apply) and adds what
# a sleep must not lose, cheap checks first. A claude that ends takes with it: a scheduled job (cron), a queued or running operation naming
# it, a note not yet delivered, a pending relaunch (the deferred list, an open recycle set, the waiting flag), a stackshot inbox message
# for it, a limit or network stop it is sitting on, and a question open on its screen. The session's own kinds are refused first: the
# Remote Control session, a Remote Control served session, the sdk lane, SALA_NO_RELAUNCH and the shell session, a side session, a front agent (sleep_is_front).
# With the word `project` (the sleep of an inactive project, below: the project is asked as a whole and decides who sleeps) a front agent is no refusal: front agents sleep
# with their project; every other check is the same. SALA_SLEEP_AFTER (3600): the settle time, how long the session has been idle.
# A sleep the owner asked for in words (`sala op sleep`, lib/sleep.sh THE ASKED SLEEP) waives the settle time: SLEEP_SETTLE_WAIVE holds `all` or the names it is waived for, and those
# sessions then need only SLEEP_ASKED_SETTLE (3) seconds of idle, so a pane that has just ended its turn is not mistaken for a busy one. A third word, `asker`, asks only what can
# be known while the asking session is still in the turn that queued the sleep (the static refusals: kind, front agent, no pane, no claude, sdk lane): the plan uses it, the runner asks the whole question once the turn has ended. SALA_STACKSHOT_INBOX: the directory of stackshot's inbox (hub/ and msg/ under it; it may be missing).
: "${SALA_STACKSHOT_INBOX:=$HOME/.local/state/stackshot/inbox}"
SLEEP_WHY=""; SLEEP_SETTLE_WAIVE=""; SLEEP_QUIET_WAIVE=0; SLEEP_ASKER_LATER=""; SLEEP_ASKED_SETTLE=3
_sleep_no() { SLEEP_WHY=$1; printf '%s\n' "$1"; return 1; }
# the seams of the two scans that need the watch's own tables: a missing one says "not stopped" (a test replaces either)
_sleep_limit_stopped() {  # <session> <claude pid> <lane> → 0 when the limit scan finds the pane stopped on a limit
    if ! declare -F lw_scan >/dev/null 2>&1; then
        # outside the watch (`sala sleep`) there is no scan: the limit watch's own record of the panes it holds stopped (SALA_LIMIT_STATE, keyed by conversation id) answers instead
        local c; registry_conv_r c "$2"; [ -n "$c" ] && [ "$c" != null ] && [ -r "$SALA_LIMIT_STATE" ] || return 1
        python3 -I -S -c 'import json, sys
try: d = json.load(open(sys.argv[1])).get("panes") or {}
except Exception: sys.exit(1)
sys.exit(0 if sys.argv[2] in d else 1)' "$SALA_LIMIT_STATE" "$c" 2>/dev/null
        return
    fi
    local o; o=$(printf '%s|%s|%s\n' "$1" "$2" "$3" | lw_scan 2>/dev/null) || return 1
    [[ $o == "stop "* || $o == *$'\n'"stop "* ]]
}
# sleep_is_front <session> → 0 for a front agent, which the owner talks to and which never sleeps: a registry row with role front (or no role and a front entry
# of the project record or the roles file: back_lane_names front), or the name of a project's -main agent
sleep_is_front() {
    case "${1:-}" in *-main) return 0;; esac
    back_lane_names front 2>/dev/null | grep -qxF -- "$1"
}
# inbox_line_waiting <session> <conversation uuid> → 0 when a message line of stackshot's inbox (hub/ and msg/ under SALA_STACKSHOT_INBOX) is routed to the session or its
# conversation, with the kind (hub or msg) in INBOX_WAIT_KIND. A line is one JSON file whose routing fields are `to`, `uuid` and `name` (the address as the sender gave it,
# the transcript id and the pane name); one of them must EQUAL the session name or the uuid. A line for `worker-extra`, or one whose text only mentions `worker`, does not
# wait for `worker`. A held key (the inbox's held-*.txt files) only stops delivery: the line is still waiting, so held or not it counts.
# THE ONE PREDICATE for "a line waits for it": sleep_ready refuses a session by it, and the watch's wake_tick wakes a sleeper by it. A cheap grep finds the files that
# contain either text at all and only those are parsed (a file that is not a JSON object counts for nothing).
# IN SERVER MODE (SALA_INBOX_MODE, lib/common.sh: this box is not the server's, so the inbox folders here are nobody's) the same question is `client.py get inbox-waiting NAME,UUID`
# (lib/inboxhold.py), whose predicate is this one: to, uuid, name or pid equals a key, held or not. THE FAIL-SAFE: a server that cannot be asked (not reached in 5 s, an error, an
# answer in no known shape) is NO ANSWER, never "nothing waits": the function returns 0 (so sleep_ready refuses the sleep) with INBOX_WAIT_UNKNOWN=1 and the reason in
# INBOX_WAIT_WHY, and wake_candidates, which must not wake a session on a line nobody saw, passes over it. A server without the call (an older stackshot) is asked of the
# inbox folder on this box when there is one, and is no answer when there is none.
INBOX_WAIT_KIND=""
INBOX_WAIT_UNKNOWN=0
INBOX_WAIT_WHY=""
inbox_line_waiting() {
    local tw cand m rc; INBOX_WAIT_KIND=""; INBOX_WAIT_UNKNOWN=0; INBOX_WAIT_WHY=""
    [ -n "${1:-}" ] || [ -n "${2:-}" ] || return 1
    inbox_mode_r m
    if [ "$m" = server ]; then
        _inbox_call waiting "${1:-}" "${2:-}"; rc=$?
        case $rc in
            0) INBOX_WAIT_KIND=$INBOX_OUT; return 0 ;;
            1) return 1 ;;
            3) [ -d "$SALA_STACKSHOT_INBOX" ] || { INBOX_WAIT_UNKNOWN=1; INBOX_WAIT_WHY="$INBOX_OUT, and this box has no inbox folder to look into instead"; return 0; } ;;   # an older server: the folder here
            *) INBOX_WAIT_UNKNOWN=1; INBOX_WAIT_WHY=$INBOX_OUT; return 0 ;;
        esac
    fi
    for tw in hub msg; do
        mapfile -t cand < <(grep -lsF -e "$1" -e "$2" "$SALA_STACKSHOT_INBOX/$tw"/*.json 2>/dev/null)
        [ "${#cand[@]}" -gt 0 ] || continue
        if python3 -I -S -c 'import json, sys
want = {a for a in sys.argv[1:3] if a}
for f in sys.argv[3:]:
    try: d = json.load(open(f, encoding="utf-8"))
    except Exception: continue
    if isinstance(d, dict) and any(isinstance(d.get(k), str) and d[k] in want for k in ("to", "uuid", "name")): sys.exit(0)
sys.exit(1)' "$1" "$2" "${cand[@]}" 2>/dev/null; then INBOX_WAIT_KIND=$tw; return 0; fi
    done
    return 1
}
_sleep_net_stopped() { local o; o=$(net_stopped_sessions "$1" 2>/dev/null); [ -n "$o" ]; }   # <session> → 0 when its claude is stopped on a network error
sleep_ready() {
    local sess="${1:-}" pane ppid pid conv uuid stamp age k v f id lane crons tw st settle
    SLEEP_WHY=""
    [ -n "$sess" ] || { _sleep_no "no session named"; return 1; }
    tmux has-session -t "=$sess" 2>/dev/null || { _sleep_no "no tmux session '$sess'"; return 1; }
    is_sleeping "$sess" && { _sleep_no "already asleep"; return 1; }
    [ "$sess" != "${SALA_RC_SESSION:-}" ] || { _sleep_no "the Remote Control session"; return 1; }
    no_relaunch "$sess" && { _sleep_no "managed outside sala (SALA_NO_RELAUNCH or the web UI's shell)"; return 1; }
    side_is "$sess" && { _sleep_no "a side session"; return 1; }
    if [ "${2:-}" != project ]; then sleep_is_front "$sess" && { _sleep_no "a front agent: the owner talks to it, so it sleeps only with its whole project (sala op sleep --project KEY --from YOU --words \"<the owner's words>\")"; return 1; }; fi
    sleeping_uuid_r uuid "$sess" || { _sleep_no "not in the pane map"; return 1; }
    pane=$(tmux list-panes -t "$(tmux_win_t "$sess")" -F '#{pane_id}' 2>/dev/null | head -1)
    ppid=$(tmux list-panes -t "$(tmux_win_t "$sess")" -F '#{pane_pid}' 2>/dev/null | head -1)
    [ -n "$pane" ] && [ -n "$ppid" ] || { _sleep_no "no tmux pane"; return 1; }
    pid=$(claude_pid_under "$ppid" 2>/dev/null)
    [ -n "$pid" ] || { _sleep_no "no claude is running in its pane"; return 1; }
    is_rc_child "$pid" && { _sleep_no "a Remote Control served session"; return 1; }
    _proc_lane_r lane "$pid"
    [ "$lane" != sdk ] || { _sleep_no "on the sdk lane"; return 1; }
    registry_conv_r conv "$pid"; [ -n "$conv" ] && [ "$conv" != null ] || { _sleep_no "no conversation id in its registry row"; return 1; }
    [ "${3:-}" != asker ] || return 0   # the asking session, still in its turn: the plan's question ends here
    registry_field_r stamp "$pid" statusUpdatedAt
    if [[ ${stamp:0:10} =~ ^[0-9]{10}$ ]]; then _stamp_age_r age "$stamp"; else _sleep_no "no idle time in its registry row"; return 1; fi
    settle=${SALA_SLEEP_AFTER:-3600}
    case " ${SLEEP_SETTLE_WAIVE:-} " in *" all "*|*" $sess "*) settle=$SLEEP_ASKED_SETTLE;; esac
    [ "$age" -ge "$settle" ] || { _sleep_no "idle for $((age / 60)) min, not yet $settle s"; return 1; }
    if ! wrap_ready "$sess" "$pane" "$pid" "$conv" "$age" clear; then _sleep_no "${WRAP_WHY:-not idle}"; return 1; fi
    # a scheduled job: the Stop hook's record of its last turn (a cron dies with the conversation's process)
    _kv_first_r crons "$SALA_BUSY_DIR/$conv" crons
    if [ "${crons:-0}" -gt 0 ] 2>/dev/null || grep -q '^cron=' "$SALA_BUSY_DIR/$conv" 2>/dev/null; then _sleep_no "its last turn left a scheduled job"; return 1; fi
    # a queued, running or waiting operation that names it (the marker's arg= lines: its sessions, old and new names alike)
    for f in "${SALA_OP_DIR:-$SALA_STATE_DIR/ops}"/*.op; do
        [ -f "$f" ] || continue
        [ "${f##*/}" != "${SALA_OP_ID:-}.op" ] || continue   # the operation this very run belongs to (a queued sleep names its session): its own marker never refuses it
        _kv_first_r st "$f" state
        case "$st" in queued|running|waiting) ;; *) continue;; esac
        if grep -qxF -- "arg=$sess" "$f" 2>/dev/null; then id=${f##*/}; _sleep_no "operation ${id%.op} ($st) names it"; return 1; fi
    done
    # a note not yet handled (the store holds only unhandled ones): by its conversation, or by the session name
    if [ -s "$SALA_LOG_DIR/salamander-notes.tsv" ] && awk -F'\t' -v u="$uuid" -v c="$conv" -v s="$sess" '$3 == u || $3 == c || $2 == s {f = 1} END {exit !f}' "$SALA_LOG_DIR/salamander-notes.tsv" 2>/dev/null; then
        _sleep_no "a note waits for it (sala note --list)"; return 1
    fi
    # a relaunch that waits for it: the deferred list, an open recycle or revive set, the waiting flag
    if [ -s "$SALA_DEFERRED" ] && awk -F'\t' -v s="$sess" '$1 == s {f = 1} END {exit !f}' "$SALA_DEFERRED" 2>/dev/null; then _sleep_no "on the deferred list (a relaunch waits for it)"; return 1; fi
    for f in "$SALA_SET_DIR"/*; do
        id=${f##*/}; [[ $id =~ ^[0-9]+-[0-9]+$ ]] || continue
        [ "$(set_val "$id" closed)" != 1 ] || continue
        if _set_out "$id" "$sess"; then _sleep_no "an open relaunch set ($id) waits for it"; return 1; fi
    done
    waiting_for "$conv" && { _sleep_no "a relaunch flag waits for it (waiting/)"; return 1; }
    waiting_for "$uuid" && { _sleep_no "a relaunch flag waits for it (waiting/)"; return 1; }
    # a stackshot inbox message for it (hub/ and msg/ under the inbox; the directory may not exist on this box)
    if inbox_line_waiting "$sess" "$uuid"; then
        if [ "$INBOX_WAIT_UNKNOWN" = 1 ]; then _sleep_no "the stackshot server could not be asked whether a message waits for it ($INBOX_WAIT_WHY)"; return 1; fi
        _sleep_no "a stackshot $INBOX_WAIT_KIND message waits for it"; return 1
    fi
    # stopped on a limit or on the network: its last turn ended on an error, and the conversation must stay in its pane for the resume that follows
    _sleep_limit_stopped "$sess" "$pid" "$lane" && { _sleep_no "stopped on a usage limit"; return 1; }
    _sleep_net_stopped "$sess" && { _sleep_no "stopped on a network error"; return 1; }
    # a question open on its screen (stuck.state: the watch's record of a dialog or a "Your move" row)
    _key_r k "$sess"
    _kv_first_r v "$SALA_STATE_DIR/stuck.state" "s.$k.row"; [ -z "$v" ] || { _sleep_no "a question is open on its screen"; return 1; }
    _kv_first_r v "$SALA_STATE_DIR/stuck.state" "s.$k.hash"; [ -z "$v" ] || { _sleep_no "a question is open on its screen"; return 1; }
    return 0
}

# ── THE WATCH'S SLEEP PASSES (stage 5) ───────────────────────────────────────────────────────────────────────────────────────────────────
# Two passes of the watch, run after wrapup_tick, both through the verbs' own code (`sala sleep --project KEY`, `sala wake NAME`, run as the CLI as the watch runs
# `revive --only`), so the same refusals and the same re-checks apply, and neither needs a queue marker or the owner's words: they are the system's own routine.
#
#   sleep_tick  (OFF BY DEFAULT: SALA_IDLE_SLEEP=on|1|yes|true turns it on) puts to sleep INACTIVE PROJECTS (THE SLEEP OF INACTIVE PROJECTS, below): every session of a project
#               that has had no external anchor notice and no input from its owner for SALA_SLEEP_QUIET (172800 s, 2 days), whose sessions are all idle with nothing in
#               flight and which is not pinned, the quietest project first, at most SALA_SLEEP_PER_TICK (1) PROJECT per watch run so a first run does not stop the whole
#               fleet at once. A session woken less than SALA_SLEEP_AFTER ago holds its project back (common.sh, THE WAKE STAMP: the registry row of a resumed claude
#               should read active, the stamp makes sure). A project whose sleep was refused or failed is asked again after SALA_SLEEP_RETRY (1800) s, and meanwhile the next
#               ones take its place. One watch-log line per project ("sleep: ..."). Off: nothing is read or kept.
#   wake_tick   (ALWAYS ON: a sleeper may come from a manual `sala sleep`) wakes a sleeping session that has a message line waiting in stackshot's inbox
#               (inbox_line_waiting, the predicate sleep_ready uses), at most SALA_WAKE_PER_RUN (5) per run; a failed wake is not retried before SALA_WAKE_RETRY
#               (600) s. The line stays in the inbox, untouched: the resumed pane takes it. A notice (sala notice) does not wake. One log line per wake. Waking is per
#               session: the others of its project stay asleep until a line waits for them. With nobody asleep it costs a directory check.
# Both stand aside while a revive, retire, rename, spawn, lane, model or reboot or a queued operation runs, the pane map is frozen or a restore runs
# (bare_busy), and on a tmux server that is not the fleet's; one flock keeps two watch runs apart. `sala watch --sleep [--dry-run]` and
# `sala watch --wake [--dry-run]` run one alone; a dry run prints what the pass would do, on or off, and changes nothing. `sala sleep --candidates` prints the
# sleep list, one line per project.
sleep_on() { case "${SALA_IDLE_SLEEP:-off}" in on|1|yes|true) return 0;; esac; return 1; }
sleep_cap() { case "${SALA_SLEEP_PER_TICK:-1}" in ''|*[!0-9]*) echo 1;; *) echo "$SALA_SLEEP_PER_TICK";; esac; }   # PROJECTS per run; junk = 1; 0 = none
wake_cap() { case "${SALA_WAKE_PER_RUN:-5}" in ''|*[!0-9]*) echo 5;; *) echo "$SALA_WAKE_PER_RUN";; esac; }
sleep_quiet() { case "${SALA_SLEEP_QUIET:-172800}" in ''|*[!0-9]*) echo 172800;; *) echo "$SALA_SLEEP_QUIET";; esac; }   # junk = 2 days

# ── THE SLEEP OF INACTIVE PROJECTS ───────────────────────────────────────────────────────────────────────────────────────────────────────
# The unit of sleep is a PROJECT, never one session: a project's sessions (its front agents and its background agents, as the session registry groups them,
# `sessions.py project-sessions`) sleep together, and a background agent is never put to sleep alone. A project sleeps when ALL of this holds:
#   (a) it is QUIET: its last external anchor notice and its owner's last input (a front chat, a board action) are both older than SALA_SLEEP_QUIET (172800 s,
#       2 days). Audits, router notices and agent-to-agent messages are not activity. Both times come from stackshot, read-only, through ONE function
#       (sleep_activity_load): `client.py project-activity --json`, or the command SALA_ACTIVITY_CMD names. A project the answer does not list has had neither
#       (never). It FAILS SAFE: a command that fails, times out, prints nothing or prints something that is not the answer (an empty `projects` object counts
#       as nothing) means no project sleeps, and the dry run says why, with the command's own stderr line. Two things the call decides, not sala: a CI result on an
#       agent's own pull request counts as an external anchor notice (it keeps the project awake), and a front agent whose chat stamps do not sync (a Slack-surface
#       one) is invisible to it, so a project its owner talks to only there can look quiet: pin it;
#   (b) every one of its sessions that runs a claude is ready: sleep_ready (below, in its project form: the front-agent refusal does not apply, the
#       settle time SALA_SLEEP_AFTER still does) accepts it, and none was woken less than SALA_SLEEP_AFTER ago; one session with a turn, a background task, a queued
#       operation, a waiting note or message line, a question and so on holds the whole project awake;
#   (c) it is not pinned (`sala sleep --pin PROJECT [--why TEXT]`, one file per project under SALA_SLEEP_PIN_DIR, which a reboot keeps; a slash of the key is %2F in the file name),
#   (d) its key is one sala can sleep (sleep_project_id_r): a key the verb would refuse is never marked a candidate, and a project refused before anything was touched does not use up the run's place.
# A session with no project in the registry (and the project record and roles file that complete it) is never a candidate for the tick. Waking is per session
# (wake_tick, below): a message line wakes the one session it is for, and the rest of its project stays asleep.
SP_KEYS=(); SP_WHY_LOAD=""
SP_STATE=""; SP_WHY=""; SP_AAGE=-1; SP_OAGE=-1; SP_LIVE=(); SP_NMEM=0; SP_NSLEEP=0
sleep_project_id_r() {  # <var> <text> → the project key in <var>: the page key without its `projects/` prefix; 1 when it is not a key stackshot can have
    # A key is one or more words (A-Za-z0-9 first, then A-Za-z0-9._-) joined by single slashes (`solo`, `plain-key-12-34`, `team/alpha`): no empty word, no `..`, no leading or
    # trailing slash, no space, no shell metacharacter, no control character. At most 200 bytes, so the pin file name (below) stays far inside a file name's 255.
    local LC_ALL=C _p=${2:-}; _p=${_p#projects/}
    if [ "${#_p}" -gt 200 ] || ! [[ $_p =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$ ]]; then printf -v "$1" %s ""; return 1; fi
    printf -v "$1" %s "$_p"
}
# sleep_pin_name_r <var> <project key> → the file name of the key's pin: the key with each `/` written %2F (a key has no % in it, so two keys never share a name and a name never
# makes a folder; a plain key keeps its old file). sleep_pin_key_r <var> <file name> is the way back: 1 when the name is not the name of a valid key.
sleep_pin_name_r() { printf -v "$1" %s "${2//\//%2F}"; }
sleep_pin_key_r() {
    local _d=${2//%2F//} _k=""
    sleep_project_id_r _k "$_d" && [ "$_k" = "$_d" ] && [ "${_k//\//%2F}" = "$2" ] || { printf -v "$1" %s ""; return 1; }
    printf -v "$1" %s "$_k"
}
# sleep_state_key_r <var> <project key> → the key as a watch-state key (A-Za-z0-9_- only) that no other project key shares: _ is written _u, / _s and . _p. (The generic
# _key_r turns every other byte into _, so `a/b`, `a.b` and `a_b` would share one failure time.)
sleep_state_key_r() { local LC_ALL=C _k=$2; _k=${_k//_/_u}; _k=${_k//\//_s}; _k=${_k//./_p}; printf -v "$1" %s "$_k"; }
# the pins: one file per project, $SALA_SLEEP_PIN_DIR/<pin name of the key>, `<ISO-Z time><TAB><why>`. A folder beside the marker folder, never in it.
sleep_pin_set() {  # <project key> [why] → 0 written
    local nm tmp; sleep_pin_name_r nm "$1"; mkdir -p "$SALA_SLEEP_PIN_DIR" 2>/dev/null || return 1
    tmp=$(mktemp "$SALA_SLEEP_PIN_DIR/.pin.XXXXXX") || return 1
    printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(printf '%s' "${2:-}" | tr -d '\n\t' | cut -c1-300)" > "$tmp" && mv -f "$tmp" "$SALA_SLEEP_PIN_DIR/$nm" || { rm -f "$tmp"; return 1; }
}
sleep_pin_clear() { local nm; sleep_pin_name_r nm "$1"; rm -f "$SALA_SLEEP_PIN_DIR/$nm" 2>/dev/null; return 0; }   # <project key>
sleep_pin_r() {  # <var> <project key> → "<ISO-Z time><TAB><why>" in <var>; 1 when the project is not pinned
    local _nm _l=""; printf -v "$1" %s ""
    sleep_project_id_r _l "$2" && [ "$_l" = "$2" ] || return 1   # a text that is not a key is never pinned, and never names a file outside the folder
    sleep_pin_name_r _nm "$2"; _l=""
    [ -f "$SALA_SLEEP_PIN_DIR/$_nm" ] || return 1
    IFS= read -r _l < "$SALA_SLEEP_PIN_DIR/$_nm" 2>/dev/null || true
    printf -v "$1" %s "$_l"
}
sleep_pin_list() {  # → one line per pin: `<key> TAB <ISO-Z time> TAB <why>`
    local f nm k l t w
    for f in "$SALA_SLEEP_PIN_DIR"/*; do
        [ -f "$f" ] || continue; nm=${f##*/}; sleep_pin_key_r k "$nm" || continue
        sleep_pin_r l "$k" || continue; t=${l%%$'\t'*}; w=""; [[ $l == *$'\t'* ]] && w=${l#*$'\t'}
        printf '%s\t%s\t%s\n' "$k" "$t" "$w"
    done
}
# sleep_ago_r <var> <seconds> → "3 d 4 h" · "5 h 10 min" · "12 min" · "under a minute"; the age as words, never a clock time
sleep_ago_r() {
    local s=$2 d h m; d=$((s / 86400)); h=$(( (s % 86400) / 3600 )); m=$(( (s % 3600) / 60 ))
    if [ "$d" -gt 0 ]; then printf -v "$1" '%s d %s h' "$d" "$h"
    elif [ "$h" -gt 0 ]; then printf -v "$1" '%s h %s min' "$h" "$m"
    elif [ "$m" -gt 0 ]; then printf -v "$1" '%s min' "$m"
    else printf -v "$1" %s "under a minute"; fi
}
# sleep_activity_load → 0 with SLEEP_ACT[<project key>]="<anchor epoch or -> <owner epoch or ->" filled; 1 with SLEEP_ACT_WHY saying why nothing may sleep.
# THE ONE CALL to the activity source. The answer is `{"projects": {"<key>": {"anchor": <epoch|null>, "owner": <epoch|null>}}}` (client.py project-activity --json).
SLEEP_ACT_WHY=""
sleep_activity_load() {
    declare -gA SLEEP_ACT=(); SLEEP_ACT_WHY=""
    local cmd c out rc parsed k a h errf err
    cmd=${SALA_ACTIVITY_CMD:-}
    if [ -z "$cmd" ]; then
        c=$(stackshot_client) || { SLEEP_ACT_WHY="there is no activity source: SALA_ACTIVITY_CMD is unset and this box has no stackshot client.py"; return 1; }
        printf -v cmd 'python3 %q project-activity --json' "$c"
    fi
    errf=$(mktemp "${TMPDIR:-/tmp}/sala-activity.XXXXXX") || errf=/dev/null   # its stderr is the reason a failed call is shown with
    out=$(timeout "${SALA_ACTIVITY_TIMEOUT:-30}" sh -c "$cmd" 2>"$errf" </dev/null); rc=$?
    err=$(grep . "$errf" 2>/dev/null | tail -1 | cut -c1-200); [ "$errf" = /dev/null ] || rm -f "$errf"
    if [ "$rc" = 124 ]; then SLEEP_ACT_WHY="the activity command did not answer within ${SALA_ACTIVITY_TIMEOUT:-30} s"; return 1; fi
    if [ "$rc" != 0 ]; then SLEEP_ACT_WHY="the activity command failed (exit $rc${err:+: $err})"; return 1; fi
    if [ -z "$(printf '%s' "$out" | tr -d ' \t\r\n')" ]; then SLEEP_ACT_WHY="the activity command printed nothing"; return 1; fi
    parsed=$(printf '%s\n' "$out" | python3 -I -S -c '
import json, sys
txt = sys.stdin.read()
try:
    d = json.loads(txt)
except Exception:
    try: d = json.loads([l for l in txt.splitlines() if l.strip()][-1])
    except Exception: sys.exit(2)
p = d.get("projects") if isinstance(d, dict) else None
if not isinstance(p, dict) or not p: sys.exit(3)
def ep(v):
    if v is None: return "-"
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v < 0: raise ValueError
    return str(int(v))
try:
    for k, e in p.items():
        if not isinstance(k, str) or not isinstance(e, dict): raise ValueError
        k = k[len("projects/"):] if k.startswith("projects/") else k
        print("%s\t%s\t%s" % (k, ep(e.get("anchor")), ep(e.get("owner"))))
except ValueError: sys.exit(4)
' 2>/dev/null); rc=$?
    case "$rc" in
        0) ;;
        3) SLEEP_ACT_WHY="the activity answer lists no project (an empty answer is not trusted)"; return 1 ;;
        *) SLEEP_ACT_WHY="the activity answer is not the shape sala reads ({\"projects\": {key: {\"anchor\": epoch|null, \"owner\": epoch|null}}})"; return 1 ;;
    esac
    while IFS=$'\t' read -r k a h; do [ -n "$k" ] && SLEEP_ACT[$k]="$a $h"; done <<< "$parsed"
    return 0
}
# sleep_projects_load → SP_KEYS (the projects with a session that has a tmux session here, in the registry's order) and SP_MEM[<key>] ("name:role name:role …"); 1 with SP_WHY_LOAD when the registry cannot say
sleep_projects_load() {
    declare -gA SP_MEM=(); SP_KEYS=(); SP_WHY_LOAD=""
    local out k n r
    sessions_on && [ -r "$SALA_SESSIONS_FILE" ] || { SP_WHY_LOAD="the session registry is off or has no file, so no session is placed in a project"; return 1; }
    out=$(sessions_py project-sessions --record "$SALA_PROJECT_RECORD" --record-max-age "$SALA_PROJECT_RECORD_MAX_AGE" --roles "$SALA_ROLES_FILE" --roles-max-age "$SALA_ROLES_FILE_MAX_AGE" 2>/dev/null) || { SP_WHY_LOAD="the session registry could not be read"; return 1; }
    while IFS=$'\t' read -r k n r; do
        [ -n "$k" ] && [ -n "$n" ] || continue
        tmux has-session -t "=$n" 2>/dev/null || continue
        [ -n "${SP_MEM[$k]+x}" ] || SP_KEYS+=("$k")
        SP_MEM[$k]+="$n:$r "
    done <<< "$out"
    return 0
}
# sleep_project_check <project key> → 0 when the project may be put to sleep now. Always sets SP_STATE (sleeping · awake · pinned), SP_NMEM / SP_NSLEEP (its sessions with
# a tmux session here, and how many of them sleep), SP_AAGE and SP_OAGE (seconds since its last anchor notice and its owner's last input; -1 = never; -2 = not read),
# and for a refusal SP_WHY: the FIRST reason it is not a candidate, in this order: pinned · asleep already · no activity reading · not quiet · a session that is not ready.
# For a candidate SP_LIVE holds the names to put to sleep. Needs sleep_projects_load; sleep_activity_load sets SLEEP_ACT (a failed one leaves SLEEP_ACT_WHY set).
sleep_project_check() {
    local key=$1 m n a h now q pin t uuid w ck
    SP_STATE=awake; SP_WHY=""; SP_AAGE=-2; SP_OAGE=-2; SP_LIVE=(); SP_NMEM=0; SP_NSLEEP=0; _now_r now; q=$(sleep_quiet)
    for m in ${SP_MEM[$key]:-}; do
        n=${m%:*}; SP_NMEM=$((SP_NMEM + 1))
        if is_sleeping "$n"; then SP_NSLEEP=$((SP_NSLEEP + 1)); else SP_LIVE+=("$n"); fi
    done
    if [ -z "${SLEEP_ACT_WHY:-}" ] && declare -p SLEEP_ACT >/dev/null 2>&1; then
        read -r a h <<< "${SLEEP_ACT[$key]:--  -}"; a=${a:--}; h=${h:--}
        if [[ $a =~ ^[0-9]+$ ]]; then SP_AAGE=$(( now > a ? now - a : 0 )); else SP_AAGE=-1; fi
        if [[ $h =~ ^[0-9]+$ ]]; then SP_OAGE=$(( now > h ? now - h : 0 )); else SP_OAGE=-1; fi
    fi
    # the same key check `sleep --project` makes first, so a project the tick could never sleep is never marked a candidate (and never spends a run)
    if ! sleep_project_id_r ck "$key" || [ "$ck" != "$key" ]; then SP_WHY="not a project key sala can sleep ($(printf '%q' "$key")): words of letters, digits, . _ - joined by single slashes"; return 1; fi
    if sleep_pin_r pin "$key"; then
        SP_STATE=pinned; t=${pin#*$'\t'}; [ "$t" != "$pin" ] || t=""
        if [ -n "$t" ]; then SP_WHY="pinned ($t): it never sleeps on its own (sala sleep --unpin $key lifts it)"; else SP_WHY="pinned: it never sleeps on its own (sala sleep --unpin $key lifts it)"; fi
        [ "${SLEEP_QUIET_WAIVE:-0}" != 1 ] || SP_WHY="${SP_WHY%)}; the owner's words do not lift a pin: unpin it first)"
        return 1
    fi
    if [ "$SP_NMEM" -gt 0 ] && [ "$SP_NSLEEP" = "$SP_NMEM" ]; then SP_STATE=sleeping; SP_WHY="already asleep"; return 1; fi
    if [ "$SP_NMEM" = 0 ]; then SP_WHY="no session of it runs here"; return 1; fi
    if [ -n "${SLEEP_ACT_WHY:-}" ] || ! declare -p SLEEP_ACT >/dev/null 2>&1; then SP_WHY="no reading of its activity: ${SLEEP_ACT_WHY:-the activity source was not asked}, so nothing sleeps"; return 1; fi
    # THE ASKED SLEEP (lib/sleep.sh): with the owner's words (SLEEP_QUIET_WAIVE=1) the quiet rule does not apply, and neither does the settle time (SLEEP_SETTLE_WAIVE=all); the activity reading above still has to be there
    if [ "${SLEEP_QUIET_WAIVE:-0}" != 1 ]; then
        if [ "$SP_AAGE" -ge 0 ] && [ "$SP_AAGE" -lt "$q" ]; then sleep_ago_r t "$SP_AAGE"; SP_WHY="not quiet: an external anchor notice $t ago (it needs $((q / 3600)) h of quiet)"; return 1; fi
        if [ "$SP_OAGE" -ge 0 ] && [ "$SP_OAGE" -lt "$q" ]; then sleep_ago_r t "$SP_OAGE"; SP_WHY="not quiet: input from its owner $t ago (it needs $((q / 3600)) h of quiet)"; return 1; fi
    fi
    for n in "${SP_LIVE[@]}"; do
        if [ -n "${SLEEP_ASKER_LATER:-}" ] && [ "$n" = "$SLEEP_ASKER_LATER" ]; then   # the asking session, still in its turn (the plan): only what is true of it now
            sleep_ready "$n" project asker >/dev/null || { SP_WHY="$n: $SLEEP_WHY"; return 1; }
            continue
        fi
        sleep_ready "$n" project >/dev/null || { SP_WHY="$n: $SLEEP_WHY"; return 1; }
        if [ "${SLEEP_SETTLE_WAIVE:-}" != all ] && sleeping_uuid_r uuid "$n" && sleeping_woke_age_r w "$uuid" && [ "$w" -lt "${SALA_SLEEP_AFTER:-3600}" ]; then SP_WHY="$n: woken $((w / 60)) min ago, left alone for $((${SALA_SLEEP_AFTER:-3600} / 60)) min"; return 1; fi
    done
    [ "${#SP_LIVE[@]}" -gt 0 ] || { SP_WHY="no session of it runs a claude"; return 1; }
    return 0
}
# sleep_eval_all → asks sleep_project_check of every project in SP_KEYS once (sleep_projects_load and sleep_activity_load come first) and keeps the answers in EV_OK[<key>] (0 = candidate),
# EV_LIVE[<key>] (the sessions to put to sleep), EV_LINE[<key>] (what the preview says of it) and EV_ORDER, the candidates `<quiet seconds> TAB <key>` (never = a large number),
# the quietest first. THE one list the tick works down and the one `sala sleep --candidates` and the dry runs print.
EV_ORDER=""
sleep_eval_all() {
    declare -gA EV_OK=() EV_LIVE=() EV_LINE=(); EV_ORDER=""
    local k a h aw hw state ord=""
    for k in "${SP_KEYS[@]}"; do
        sleep_project_check "$k"; EV_OK[$k]=$?
        if [ "$SP_AAGE" = -2 ]; then aw="not read"; elif [ "$SP_AAGE" -ge 0 ]; then sleep_ago_r aw "$SP_AAGE"; aw="$aw ago"; else aw=never; fi
        if [ "$SP_OAGE" = -2 ]; then hw="not read"; elif [ "$SP_OAGE" -ge 0 ]; then sleep_ago_r hw "$SP_OAGE"; hw="$hw ago"; else hw=never; fi
        state=$SP_STATE; [ "$SP_NSLEEP" -gt 0 ] && [ "$state" != sleeping ] && state="$state ($SP_NSLEEP of $SP_NMEM asleep)"
        EV_LINE[$k]="$k: $state — last anchor notice: $aw; owner's last input: $hw — "
        if [ "${EV_OK[$k]}" = 0 ]; then
            a=$SP_AAGE; h=$SP_OAGE; [ "$a" -ge 0 ] || a=9999999999; [ "$h" -ge 0 ] || h=9999999999
            EV_LIVE[$k]="${SP_LIVE[*]}"
            ord="$ord$(( a < h ? a : h ))"$'\t'"$k"$'\n'
        else
            EV_LINE[$k]+="not a candidate: $SP_WHY"
        fi
    done
    EV_ORDER=$(printf '%s' "$ord" | LC_ALL=C sort -s -t$'\t' -k1,1nr)
}
# sleep_candidates → `<quiet seconds> TAB <project key>` for every project sleep_project_check accepts, the quietest first. Nothing is listed when the registry cannot place a
# session or the activity source cannot answer.
sleep_candidates() {
    sleep_projects_load || return 0
    sleep_activity_load || return 0
    sleep_eval_all
    [ -z "$EV_ORDER" ] || printf '%s\n' "$EV_ORDER"
}
# _retry_backoff <state key prefix> <session or project> <retry s> → 0 when the watch's state holds a failure time for it younger than the retry time (sleepfail.* and wakefail.*,
# written by sleep_locked and wake_locked; a sleep's is keyed by the project). Read only: the passes and their previews share it, so a preview skips what the real run skips.
# The watch's state file is the one the watch uses (WSTATE), or the same file by its path when the verb runs outside the watch (`sala sleep --candidates`).
_retry_backoff() {
    local k v now; if [ "$1" = sleepfail ]; then sleep_state_key_r k "$2"; else _key_r k "$2"; fi; _now_r now   # a sleep's is keyed by the project key, written so that no two keys share one
    v=$(_kv_first "${WSTATE:-$SALA_LOG_DIR/salamander-watch.state}" "$1.$k")
    [[ $v =~ ^[0-9]+$ ]] && [ $((now - v)) -lt "$3" ]
}
# sleep_report → what sleep_tick would do now: one line per project (sleeping, awake or pinned; how long since its last anchor notice and its owner's last input; the first
# reason it is not a candidate, or that it would be put to sleep), the candidates marked in the order the tick takes them. Says so when the pass is off or has no activity reading.
sleep_report() {
    local cap q qh n=0 k age; local -A rank=()
    cap=$(sleep_cap); q=$(sleep_quiet); qh=$((q / 3600))
    sleep_on || echo "SALA_IDLE_SLEEP is off: the watch puts nothing to sleep. This is what it would do with it on (at most $cap project(s) per watch run; a project must be quiet for $qh h):"
    sleep_projects_load || { echo "no project can sleep: $SP_WHY_LOAD"; return 0; }
    [ "${#SP_KEYS[@]}" -gt 0 ] || { echo "no project has a session running here (a session sleeps only as part of its project)"; return 0; }
    sleep_activity_load || echo "no project can sleep: $SLEEP_ACT_WHY"
    sleep_eval_all
    while IFS=$'\t' read -r age k; do
        [ -n "$k" ] || continue
        if _retry_backoff sleepfail "$k" "${SALA_SLEEP_RETRY:-1800}"; then rank[$k]=skip; continue; fi
        n=$((n + 1)); if [ "$n" -le "$cap" ]; then rank[$k]=now; else rank[$k]=later; fi
    done <<< "$EV_ORDER"
    for k in "${SP_KEYS[@]}"; do
        case "${rank[$k]:-}" in
            now)   echo "${EV_LINE[$k]}would be put to sleep (${EV_LIVE[$k]// /, })" ;;
            later) echo "${EV_LINE[$k]}ready, waits for a later run (at most $cap project(s) per run; ${EV_LIVE[$k]// /, })" ;;
            skip)  echo "${EV_LINE[$k]}asked lately and not put to sleep, skipped until its retry time ($((${SALA_SLEEP_RETRY:-1800} / 60)) min) has passed" ;;
            *)     echo "${EV_LINE[$k]}" ;;
        esac
    done
    return 0
}
sleepstate_prune() {  # <key prefix> <ttl s> → drops the watch-state keys of that kind whose time is older than the ttl (a retired session or a project leaves its key behind)
    local kk v now; _now_r now
    for kk in $(grep -o "^$1\\.[^=]*" "$WSTATE" 2>/dev/null); do
        v=$(st_get "$kk"); if ! [[ $v =~ ^[0-9]+$ ]] || [ $((now - v)) -ge "$2" ]; then st_del "$kk"; fi
    done
}
sleep_locked() {
    local age key k now n=0 cap out rc last slept
    cap=$(sleep_cap); _now_r now
    while IFS=$'\t' read -r age key; do
        [ -n "$key" ] || continue
        [ "$n" -lt "$cap" ] || break
        if _retry_backoff sleepfail "$key" "${SALA_SLEEP_RETRY:-1800}"; then continue; fi   # asked lately and not put to sleep: the next one takes its turn (the preview skips it too)
        sleep_state_key_r k "$key"
        out=$("$SALA_BIN" sleep --project "$key" 2>&1 </dev/null); rc=$?
        slept=$(printf '%s\n' "$out" | grep -c '^✅ [^p]')
        if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q '^✅ project '; then
            n=$((n + 1)); st_del "sleepfail.$k"; wlog "sleep: put project $key to sleep ($slept session(s); quiet for $((age / 3600)) h)"
        else
            st_set "sleepfail.$k" "$now"; last=$(printf '%s\n' "$out" | grep . | tail -1 | cut -c1-240)
            wlog "sleep: project $key not put to sleep — ${last:-no answer}; asked again after $((${SALA_SLEEP_RETRY:-1800} / 60)) min"
            # The cap keeps a first run from stopping the whole fleet at once, so it counts a project the run started: one with a session put to sleep, or one that failed after
            # the checks passed. A project refused before anything was touched (the one-line `✗ project KEY: not put to sleep — …` of `sleep --project`, which the checks of
            # sleep_project_check make the exception) stopped nothing and leaves its place to the next candidate of this run.
            if [ "$slept" -gt 0 ] || ! printf '%s\n' "$out" | grep -q '^✗ project [^ ]*: not put to sleep — '; then n=$((n + 1)); fi
        fi
    done < <(sleep_candidates)
    sleepstate_prune sleepfail "${SALA_SLEEP_RETRY:-1800}"
    return 0
}
sleep_tick() {
    if [ "${SLEEP_DRY:-0}" = 1 ]; then sleep_report; return 0; fi
    sleep_on || return 0
    [ -s "$SALA_SIDECAR" ] || return 0
    on_fleet_server || return 0
    tmux_server_up || return 0
    bare_busy && return 0
    ( flock -n 8 || exit 0; sleep_locked ) 8>>"$SALA_LOG_DIR/salamander-sleep.lock"
}
# wake_candidates → `<session> TAB <conversation uuid> TAB <kind>` for each sleeper on the pane map with a message line waiting for it (inbox_line_waiting) whose
# pane runs no claude (a sleep still ending is left to finish). Nothing asleep: a directory check.
wake_candidates() {
    local u t nm sess pp
    [ -d "$SALA_SLEEP_DIR" ] && compgen -G "$SALA_SLEEP_DIR/*" >/dev/null 2>&1 && [ -r "$SALA_SIDECAR" ] || return 0
    while IFS=$'\t' read -r u t nm; do
        [ -n "$u" ] || continue
        sess=$(awk -F'\t' -v u="$u" '$2 == u {print $1; exit}' "$SALA_SIDECAR" 2>/dev/null); [ -n "$sess" ] || continue
        inbox_line_waiting "$sess" "$u" || continue
        [ "$INBOX_WAIT_UNKNOWN" = 0 ] || continue   # the server could not be asked: no line was seen, so nothing wakes (and no failed wake is counted)
        if tmux has-session -t "=$sess" 2>/dev/null; then
            pp=$(tmux list-panes -t "$(tmux_win_t "$sess")" -F '#{pane_pid}' 2>/dev/null | head -1)
            [ -z "$pp" ] || [ -z "$(claude_pid_under "$pp" 2>/dev/null)" ] || continue
        fi
        printf '%s\t%s\t%s\n' "$sess" "$u" "$INBOX_WAIT_KIND"
    done < <(sleeping_list)
}
wake_report() {
    local c sess u kind n=0 cap; cap=$(wake_cap); c=$(wake_candidates)
    [ -n "$c" ] || { echo "no sleeping session has a message line waiting"; return 0; }
    while IFS=$'\t' read -r sess u kind; do
        if _retry_backoff wakefail "$sess" "${SALA_WAKE_RETRY:-600}"; then echo "$sess: a stackshot $kind message line waits for it — a wake failed lately, skipped until its retry time ($((${SALA_WAKE_RETRY:-600} / 60)) min) has passed"; continue; fi
        n=$((n + 1))
        if [ "$n" -le "$cap" ]; then echo "$sess: a stackshot $kind message line waits for it — would be woken"
        else echo "$sess: a stackshot $kind message line waits for it — waits for a later run (at most $cap per run)"; fi
    done <<< "$c"
    return 0
}
wake_locked() {
    local sess u kind k cur now n=0 cap out rc last
    cap=$(wake_cap); _now_r now
    while IFS=$'\t' read -r sess u kind; do
        [ -n "$sess" ] || continue
        [ "$n" -lt "$cap" ] || break
        if _retry_backoff wakefail "$sess" "${SALA_WAKE_RETRY:-600}"; then continue; fi   # a wake that failed lately is not tried again at once (the preview skips it too)
        # the candidate was picked by conversation id but `sala wake` acts on the name: the row for the name must still hold that id (a row replaced since is not this
        # conversation's message; skipped with no failure stamp, the next run picks again)
        sleeping_uuid_r cur "$sess" && [ "$cur" = "$u" ] || continue
        _key_r k "$sess"
        n=$((n + 1))
        out=$("$SALA_BIN" wake "$sess" 2>&1 </dev/null); rc=$?
        if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q "^✅ "; then
            st_del "wakefail.$k"; wlog "wake: woke $sess — inbox line waiting (a stackshot $kind message); the line stays in the inbox for the pane to take"
        else
            st_set "wakefail.$k" "$now"; last=$(printf '%s\n' "$out" | grep . | tail -1 | cut -c1-240)
            wlog "wake: $sess not woken (inbox line waiting) — ${last:-no answer}; tried again after $((${SALA_WAKE_RETRY:-600} / 60)) min"
        fi
    done < <(wake_candidates)
    sleepstate_prune wakefail "${SALA_WAKE_RETRY:-600}"
    return 0
}
wake_tick() {
    if [ "${SLEEP_DRY:-0}" = 1 ]; then wake_report; return 0; fi
    [ -d "$SALA_SLEEP_DIR" ] && compgen -G "$SALA_SLEEP_DIR/*" >/dev/null 2>&1 || return 0   # nobody asleep: nothing else is read
    [ -s "$SALA_SIDECAR" ] || return 0
    on_fleet_server || return 0
    tmux_server_up || return 0
    bare_busy && return 0
    ( flock -n 8 || exit 0; wake_locked ) 8>>"$SALA_LOG_DIR/salamander-sleep.lock"
}
