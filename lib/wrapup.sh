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
# sleep_ready <tmux session> → 0 when the session may go to sleep now (common.sh, THE SLEEPING SESSIONS); else 1 with the FIRST refusing reason
# as one short text in SLEEP_WHY and on stdout. It reuses wrap_ready (stage clear: idle in the registry, not waiting on a background job, no background work,
# no dialog, nothing typed; the wrap-up's own idle-age window and its warm bound do not apply, a sleep comes after an hour) and adds what
# a sleep must not lose, cheap checks first. A claude that ends takes with it: a scheduled job (cron), a queued or running operation naming
# it, a note not yet delivered, a pending relaunch (the deferred list, an open recycle set, the waiting flag), a stackshot inbox message
# for it, a limit or network stop it is sitting on, and a question open on its screen. The session's own kinds are refused first: the
# Remote Control session, a Remote Control served session, the sdk lane, SALA_NO_RELAUNCH and the shell session, a side session, a front agent (sleep_is_front).
# SALA_SLEEP_AFTER (3600): the idle age. SALA_STACKSHOT_INBOX: the directory of stackshot's inbox (hub/ and msg/ under it; it may be missing).
: "${SALA_STACKSHOT_INBOX:=$HOME/.local/state/stackshot/inbox}"
SLEEP_WHY=""
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
INBOX_WAIT_KIND=""
inbox_line_waiting() {
    local tw cand; INBOX_WAIT_KIND=""
    [ -n "${1:-}" ] || [ -n "${2:-}" ] || return 1
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
    local sess="${1:-}" pane ppid pid conv uuid stamp age k v f id lane crons tw st
    SLEEP_WHY=""
    [ -n "$sess" ] || { _sleep_no "no session named"; return 1; }
    tmux has-session -t "=$sess" 2>/dev/null || { _sleep_no "no tmux session '$sess'"; return 1; }
    is_sleeping "$sess" && { _sleep_no "already asleep"; return 1; }
    [ "$sess" != "${SALA_RC_SESSION:-}" ] || { _sleep_no "the Remote Control session"; return 1; }
    no_relaunch "$sess" && { _sleep_no "managed outside sala (SALA_NO_RELAUNCH or the web UI's shell)"; return 1; }
    side_is "$sess" && { _sleep_no "a side session"; return 1; }
    sleep_is_front "$sess" && { _sleep_no "a front agent: the owner talks to it, so it never sleeps"; return 1; }
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
    registry_field_r stamp "$pid" statusUpdatedAt
    if [[ ${stamp:0:10} =~ ^[0-9]{10}$ ]]; then _stamp_age_r age "$stamp"; else _sleep_no "no idle time in its registry row"; return 1; fi
    [ "$age" -ge "${SALA_SLEEP_AFTER:-3600}" ] || { _sleep_no "idle for $((age / 60)) min, not yet ${SALA_SLEEP_AFTER:-3600} s"; return 1; }
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
    if inbox_line_waiting "$sess" "$uuid"; then _sleep_no "a stackshot $INBOX_WAIT_KIND message waits for it"; return 1; fi
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
# Two passes of the watch, run after wrapup_tick, both through the verbs' own code (`sala sleep NAME`, `sala wake NAME`, run as the CLI as the watch runs
# `revive --only`), so the same refusals and the same re-checks apply, and neither needs a queue marker or the owner's words: they are the system's own routine.
#
#   sleep_tick  (OFF BY DEFAULT: SALA_IDLE_SLEEP=on|1|yes|true turns it on) puts to sleep the live sessions that sleep_ready accepts (idle for SALA_SLEEP_AFTER,
#               3600 s, nothing in flight, no front agent, nothing a sleep would lose), the longest idle first, at most SALA_SLEEP_PER_TICK (3) per watch run
#               so a first run does not stop the whole fleet at once. A session woken less than SALA_SLEEP_AFTER ago is never one (common.sh, THE WAKE STAMP:
#               the registry row of a resumed claude should read active, the stamp makes sure). A session whose sleep was refused or failed is asked again after
#               SALA_SLEEP_RETRY (1800) s, and meanwhile the next ones take its place. One watch-log line per session ("sleep: ..."). Off: nothing is read or kept.
#   wake_tick   (ALWAYS ON: a sleeper may come from a manual `sala sleep`) wakes a sleeping session that has a message line waiting in stackshot's inbox
#               (inbox_line_waiting, the predicate sleep_ready uses), at most SALA_WAKE_PER_RUN (5) per run; a failed wake is not retried before SALA_WAKE_RETRY
#               (600) s. The line stays in the inbox, untouched: the resumed pane takes it. A notice (sala notice) does not wake. One log line per wake.
#               With nobody asleep it costs a directory check.
# Both stand aside while a revive, retire, rename, spawn, lane, model or reboot or a queued operation runs, the pane map is frozen or a restore runs
# (bare_busy), and on a tmux server that is not the fleet's; one flock keeps two watch runs apart. `sala watch --sleep [--dry-run]` and
# `sala watch --wake [--dry-run]` run one alone; a dry run prints what the pass would do, on or off, and changes nothing. `sala sleep --candidates` prints the
# sleep list.
sleep_on() { case "${SALA_IDLE_SLEEP:-off}" in on|1|yes|true) return 0;; esac; return 1; }
sleep_cap() { case "${SALA_SLEEP_PER_TICK:-3}" in ''|*[!0-9]*) echo 3;; *) echo "$SALA_SLEEP_PER_TICK";; esac; }   # junk = 3; 0 = none
wake_cap() { case "${SALA_WAKE_PER_RUN:-5}" in ''|*[!0-9]*) echo 5;; *) echo "$SALA_WAKE_PER_RUN";; esac; }
# sleep_candidates → `<idle seconds> TAB <session>` for every live session sleep_ready accepts and no wake stamp holds back, the longest idle first.
# THE list the tick works down, and the one `sala sleep --candidates` and the dry runs print.
sleep_candidates() {
    local tbl sess pane pid uuid stamp age w seen=" "
    _claude_panes_r tbl
    while IFS='|' read -r sess pane pid; do
        [ -n "$sess" ] || continue
        case "$seen" in *" $sess "*) continue;; esac; seen="$seen$sess "
        sleep_ready "$sess" >/dev/null || continue
        if sleeping_uuid_r uuid "$sess" && sleeping_woke_age_r w "$uuid" && [ "$w" -lt "${SALA_SLEEP_AFTER:-3600}" ]; then continue; fi
        registry_field_r stamp "$pid" statusUpdatedAt
        if [[ ${stamp:0:10} =~ ^[0-9]{10}$ ]]; then _stamp_age_r age "$stamp"; else age=0; fi
        printf '%s\t%s\n' "$age" "$sess"
    done <<< "$tbl" | LC_ALL=C sort -s -t$'\t' -k1,1nr
}
# _retry_backoff <state key prefix> <session> <retry s> → 0 when the watch's state holds a failure time for the session younger than the retry time (sleepfail.* and wakefail.*,
# written by sleep_locked and wake_locked). Read only: the passes and their previews share it, so a preview skips the sessions the real run skips. The watch's state file
# is the one the watch uses (WSTATE), or the same file by its path when the verb runs outside the watch (`sala sleep --candidates`).
_retry_backoff() {
    local k v now; _key_r k "$2"; _now_r now
    v=$(_kv_first "${WSTATE:-$SALA_LOG_DIR/salamander-watch.state}" "$1.$k")
    [[ $v =~ ^[0-9]+$ ]] && [ $((now - v)) -lt "$3" ]
}
# sleep_report → what sleep_tick would do now, one line per ready session; says so when the pass is off
sleep_report() {
    local c age sess n=0 cap; cap=$(sleep_cap)
    sleep_on || echo "SALA_IDLE_SLEEP is off: the watch puts nothing to sleep. This is what it would do with it on (at most $cap per watch run):"
    c=$(sleep_candidates)
    [ -n "$c" ] || { echo "no session is ready to sleep (idle for ${SALA_SLEEP_AFTER:-3600}s or more, nothing in flight, not a front agent)"; return 0; }
    while IFS=$'\t' read -r age sess; do
        if _retry_backoff sleepfail "$sess" "${SALA_SLEEP_RETRY:-1800}"; then echo "$sess: idle $((age / 60)) min — asked lately and not put to sleep, skipped until its retry time ($((${SALA_SLEEP_RETRY:-1800} / 60)) min) has passed"; continue; fi
        n=$((n + 1))
        if [ "$n" -le "$cap" ]; then echo "$sess: idle $((age / 60)) min — would be put to sleep"
        else echo "$sess: idle $((age / 60)) min — ready, waits for a later run (at most $cap per run)"; fi
    done <<< "$c"
    return 0
}
# sleepstate_prune <key prefix> <ttl s> → drops the watch-state keys of that kind whose time is older than the ttl (a retired session leaves its key behind)
sleepstate_prune() {
    local kk v now; _now_r now
    for kk in $(grep -o "^$1\\.[^=]*" "$WSTATE" 2>/dev/null); do
        v=$(st_get "$kk"); if ! [[ $v =~ ^[0-9]+$ ]] || [ $((now - v)) -ge "$2" ]; then st_del "$kk"; fi
    done
}
sleep_locked() {
    local age sess k now n=0 cap out rc last
    cap=$(sleep_cap); _now_r now
    while IFS=$'\t' read -r age sess; do
        [ -n "$sess" ] || continue
        [ "$n" -lt "$cap" ] || break
        if _retry_backoff sleepfail "$sess" "${SALA_SLEEP_RETRY:-1800}"; then continue; fi   # asked lately and not put to sleep: the next one takes its turn (the preview skips it too)
        _key_r k "$sess"
        n=$((n + 1))
        out=$("$SALA_BIN" sleep "$sess" 2>&1 </dev/null); rc=$?
        if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q '^✅ '; then
            st_del "sleepfail.$k"; wlog "sleep: put $sess to sleep (idle $((age / 60)) min)"
        else
            st_set "sleepfail.$k" "$now"; last=$(printf '%s\n' "$out" | grep . | tail -1 | cut -c1-240)
            wlog "sleep: $sess not put to sleep — ${last:-no answer}; asked again after $((${SALA_SLEEP_RETRY:-1800} / 60)) min"
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
