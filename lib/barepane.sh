# lib/barepane.sh — watch's BARE-PANE heal: a mapped pane whose tmux session is up but whose claude is gone is revived.
# Sourced by lib/watch.sh (like op.sh and settings-apply.sh); bare_tick runs once per watch tick, after the deferred panes.
#
# WHY: a mass SIGKILL once hit every claude process (exit 137) at once; tmux and
# its panes stayed up as bare shells and nothing brought them back. revive runs on a reboot, a CLI update or recycle and the
# deferred list, and nothing else watched a pane that died on its own
# A mass SIGKILL looks like this: every pane of the pane map sits at a shell prompt (the pane's foreground command
# is bash, zsh or the like, no claude under it), the claude panes' last words in the revive log are gone with no /exit, and the
# tmux server's uptime is far older than the claudes' death. This tick is what heals it.
#
# WHAT IT DOES: for every row of the pane map (the Remote Control server's is not here: the RC code keeps it) whose tmux session exists and has exactly one pane, the pane's foreground command a shell, no
# claude process under any pane of the session and no child process under the shell, it starts a clock in the watch state
# (bare.<session> = first-seen epoch, tries, last try). The pane is revived once it has been bare for SALA_BARE_GRACE seconds
# (default 180: the third tick of the 2-minute timer, so a recycle's brief shell between /exit and the resume, a pane being
# renamed or spawned, never counts) with ONE `revive --only A --only B …` — resume by explicit UUID, the dedupe guard, the lane
# line, the inbox hold, all revive's own; no launcher is written here. At most SALA_BARE_MAX (6) panes start per tick, the
# longest bare first, so a mass death is healed over several ticks and not by every claude starting together. A pane revive left
# bare is tried again no sooner than SALA_BARE_RETRY (600 s) and at most SALA_BARE_TRIES (3) times; the third failure is posted
# once and the pane is left (the episode ends when it has a claude again or leaves the map).
#
# NEVER: while a recycle holds the lock, a revive, restore or rename runs, the pane map is frozen, or a retire, spawn, lane,
# model, reboot, reauth or queued operation runs (the clock restarts afterwards); on a tmux server that is not the fleet's; a
# session in SALA_NO_RELAUNCH; a session whose registry row says retired; a side session that wrote its `side done` marker; a
# session whose conversation is live in another pane; a session with more than one pane (revive would treat the other panes
# as shells to resume into); a pane running anything but a shell (an editor, an ssh, an sdk wrapper) or holding a child.
# SALA_BARE_REVIVE=off turns the whole tick off.
#
# ONE POST per tick that revived anything: "watch: revived N panes whose claude had died: a, b, c", and a "could not revive" post
# when a pane used up its tries. Every decision (first seen, waiting, capped, left alone, revived, still bare) is a log line.

: "${SALA_BARE_REVIVE:=on}" "${SALA_BARE_GRACE:=180}" "${SALA_BARE_MAX:=6}" "${SALA_BARE_RETRY:=600}" "${SALA_BARE_TRIES:=3}"

# bare_state_reset — forget every clock (a tick that stood aside: the grace counts uninterrupted bare ticks)
bare_state_reset() {
    local k; [ -r "$WSTATE" ] || return 0
    for k in $(grep -o '^bare\.[^=]*' "$WSTATE" 2>/dev/null); do st_del "$k"; done
}
# bare_busy → 0 (with BARE_BUSY_WHY) when something else owns the panes right now
bare_busy() {
    BARE_BUSY_WHY=""
    if [ "${AUTO_LAUNCHED:-0}" != 0 ]; then BARE_BUSY_WHY="this run launched an update, relaunch or operation"
    elif recycle_locked; then BARE_BUSY_WHY="the recycle lock is held"
    elif ledger_frozen; then BARE_BUSY_WHY="the pane map is frozen ($(ledger_freeze_line))"
    elif pgrep_mine 'tmux-resurrect/scripts/[r]estore.sh' >/dev/null; then BARE_BUSY_WHY="a resurrect restore is running"
    elif pgrep_mine 'bin/(sala|salamander) (revive|rename|retire|close-shell|forget-row|spawn|restore|lane|model|reboot|reauth|unpark|adopt|op --run)( |$)' | grep -qv -- '--retry-worker\|--self-worker\|--save-map'; then BARE_BUSY_WHY="a sala revive, rename, retire, spawn, lane, model, reboot or queued operation is running"
    fi
    [ -n "$BARE_BUSY_WHY" ]
}
# bare_retired <session> → 0 when the session registry holds the name only as a retired row (lib/sessions.py resolve)
bare_retired() {
    sessions_on && [ -r "$SALA_SESSIONS_FILE" ] || return 1
    local out; out=$(sessions_py resolve "$1" 2>/dev/null) || return 1
    grep -q '^state:   retired' <<< "$out"
}

bare_tick() {
    [ "${SALA_BARE_REVIVE:-on}" = off ] && return 0
    [ -s "$SALA_SIDECAR" ] || return 0
    on_fleet_server || return 0
    tmux_server_up || return 0
    if bare_busy; then wlog "bare panes: standing aside — $BARE_BUSY_WHY"; bare_state_reset; return 0; fi
    local k now sess uuid key v first tries last age pp cmd s tbl panes kids i n
    local -A pcount=() pfirst=() hasclaude=() seen=() bfirst=() btries=()
    local due=() go=() sorted=() back=() failed=() later=()
    now=$(date +%s)
    panes=$(tmux list-panes -a -F '#{session_name}|#{pane_pid}|#{pane_current_command}' 2>/dev/null)
    while IFS='|' read -r s pp cmd; do
        [ -n "$s" ] || continue
        pcount[$s]=$(( ${pcount[$s]:-0} + 1 ))
        [ -n "${pfirst[$s]+x}" ] || pfirst[$s]="$pp|$cmd"
    done <<< "$panes"
    _claude_panes_r tbl
    while IFS='|' read -r s _ _; do [ -n "$s" ] && hasclaude[$s]=1; done <<< "$tbl"
    while IFS=$'\t' read -r sess uuid _; do
        [ -n "$sess" ] || continue
        [ "$sess" = "$SALA_RC_SESSION" ] && continue
        # a SLEEPING session is a bare shell on purpose (common.sh, THE SLEEPING SESSIONS): never revived, never "could not revive". It is not
        # marked seen, so the clock loop below clears its bare.* state key (a clock started before it slept would otherwise run on to a revive)
        is_sleeping "$sess" && continue
        no_relaunch "$sess" && continue
        [ -n "${pfirst[$sess]+x}" ] || continue                                 # no tmux session: `sala restore --missing` recreates it
        [ -z "${hasclaude[$sess]+x}" ] || continue                               # a claude lives under it: healthy
        IFS='|' read -r pp cmd <<< "${pfirst[$sess]}"
        case "$cmd" in bash|sh|zsh|fish|dash) ;; *) continue;; esac              # running something else: not a bare shell
        kids=$(pgrep -P "$pp" 2>/dev/null); [ -z "$kids" ] || continue           # busy with a child process
        _key_r key "$sess"; key="bare.$key"
        if [ "${pcount[$sess]}" != 1 ]; then
            [ -n "$(st_get "$key.multi")" ] || { st_set "$key.multi" 1; wlog "bare panes: '$sess' has ${pcount[$sess]} panes and no claude — left alone (revive would treat every pane as a shell to resume into); sala revive --only $sess by hand"; }
            seen["$key.multi"]=1; continue
        fi
        [ -n "$uuid" ] || { wlog "bare panes: '$sess' has no conversation id in the pane map — left alone"; continue; }
        [ ! -f "$(side_done_file "$sess")" ] || continue                         # a finished side session waits for the owner's retire, not for a revive
        if live_pane_for_uuid "$uuid" >/dev/null; then
            wlog "bare panes: '$sess' has no claude, but its conversation $uuid is live in another pane — left alone (a conversation is never resumed twice)"; continue
        fi
        seen[$key]=1
        v=$(st_get "$key")
        if [ -z "$v" ]; then
            st_set "$key" "$now 0 0"
            wlog "bare panes: '$sess' is at a shell with no claude (first seen) — revived if it is still bare ${SALA_BARE_GRACE}s from now"
            continue
        fi
        read -r first tries last <<< "$v"
        : "${first:=$now}" "${tries:=0}" "${last:=0}"
        bfirst[$sess]=$first; btries[$sess]=$tries
        age=$((now - first))
        [ "$age" -ge "$SALA_BARE_GRACE" ] || { wlog "bare panes: '$sess' bare for ${age}s of ${SALA_BARE_GRACE}s — waiting"; continue; }
        [ "$tries" -lt "$SALA_BARE_TRIES" ] || continue                          # used up its tries (posted when it did)
        [ $((now - last)) -ge "$SALA_BARE_RETRY" ] || continue                   # tried a moment ago: revive's own verdict is in the log
        due+=("$first|$sess")
    done < "$SALA_SIDECAR"
    # clocks of panes that are healthy now, retired, gone from the map or left alone
    for k in $(grep -o '^bare\.[^=]*' "$WSTATE" 2>/dev/null); do [ -n "${seen[$k]+x}" ] || { st_del "$k"; wlog "bare panes: ${k#bare.} is no longer bare (or no longer eligible) — clock cleared"; }; done
    [ ${#due[@]} -gt 0 ] || return 0
    mapfile -t sorted < <(printf '%s\n' "${due[@]}" | sort -t'|' -k1,1n)         # the longest bare first
    for i in "${!sorted[@]}"; do
        sess=${sorted[$i]#*|}
        if bare_retired "$sess"; then wlog "bare panes: '$sess' is retired in the session registry — left alone"; continue; fi
        if is_sleeping "$sess"; then wlog "bare panes: '$sess' went to sleep since it was listed — left alone"; continue; fi   # the marker came after the first loop: never revived, never posted
        if [ ${#go[@]} -lt "$SALA_BARE_MAX" ]; then go+=("$sess"); else later+=("$sess"); fi
    done
    [ ${#later[@]} -gt 0 ] && wlog "bare panes: cap of $SALA_BARE_MAX per tick — ${#later[@]} more wait for a later tick: ${later[*]}"
    [ ${#go[@]} -gt 0 ] || return 0
    local args=()
    for sess in "${go[@]}"; do
        _key_r key "$sess"; st_set "bare.$key" "${bfirst[$sess]} $(( ${btries[$sess]} + 1 )) $now"
        args+=(--only "$sess")
    done
    wlog "bare panes: reviving ${#go[@]} — ${go[*]} (bare since $(local_human "${bfirst[${go[0]}]}") and longer)"
    local t=(); command -v timeout >/dev/null 2>&1 && t=(timeout 900)
    ${t[@]+"${t[@]}"} "$SALA_BIN" revive "${args[@]}" </dev/null >> "$WLOG" 2>&1 \
        || wlog "bare panes: revive exited $? (its own lines above say why)"
    for sess in "${go[@]}"; do
        IFS='|' read -r pp _ <<< "$(tmux list-panes -t "$(tmux_win_t "$sess")" -F '#{pane_pid}|' 2>/dev/null | head -1)"
        _key_r key "$sess"
        if [ -n "$pp" ] && claude_pid_under "$pp" >/dev/null 2>&1; then
            back+=("$sess"); st_del "bare.$key"; wlog "bare panes: '$sess' has its claude back"
        else
            failed+=("$sess"); wlog "bare panes: '$sess' is still without a claude after try $(( ${btries[$sess]} + 1 )) of $SALA_BARE_TRIES"
        fi
    done
    if [ ${#back[@]} -gt 0 ]; then
        n=${#back[@]}
        notify "🩹 *watch: revived $n pane$([ "$n" = 1 ] || echo s) whose claude had died: $(printf '%s, ' "${back[@]}" | sed 's/, $//')*" \
            "each was at a bare shell for ${SALA_BARE_GRACE}s or more and was resumed on its own conversation (revive --only)" \
            "$([ ${#later[@]} -gt 0 ] && echo "${#later[@]} more wait for the next tick (at most $SALA_BARE_MAX start per tick)")" \
            "Details: $WLOG"
    fi
    local giveup=()
    for sess in ${failed[@]+"${failed[@]}"}; do [ $(( ${btries[$sess]} + 1 )) -ge "$SALA_BARE_TRIES" ] && giveup+=("$sess"); done
    if [ ${#giveup[@]} -gt 0 ]; then
        notify "🚨 *watch could not revive ${#giveup[@]} pane$([ ${#giveup[@]} = 1 ] || echo s): $(printf '%s, ' "${giveup[@]}" | sed 's/, $//')*" \
            "revive --only ran $SALA_BARE_TRIES times and left each without a claude; watch leaves it now" \
            "look at its pane, or run: sala revive --only <name>" "Details: $WLOG (revive's own reason lines)"
    fi
    return 0
}

# THE GONE-SESSION FLAG: a mapped session whose tmux SESSION is gone (not a bare shell: bare_tick above needs the session) is said once.
# A host-wide out-of-memory stop killed one small child in each of three panes' systemd scopes; a scope stops as a whole when one of its
# processes is killed (OOMPolicy=stop, the user manager's default), so three tmux sessions closed with their claude, the server stayed up,
# and nothing noticed: bare_tick sees only a session that exists, and `ledger_missing` fed only the post-boot report and `restore --missing`.
# This tick runs BEFORE watch's busy_elsewhere exit (a revive worker that runs for hours keeps that exit true for hours): a row whose
# session has been gone for SALA_MISSING_GRACE seconds (default 180, the third tick: a rename, a retire, a spawn or a recycle's brief gap
# never counts) is posted ONCE per session per incident (gone.<session> = first-seen epoch + the epoch it was posted, 0 before; the key goes
# the moment the session exists again, the row leaves the map, or it sleeps, so a later loss is a new incident), all the sessions of one
# tick in one post naming `sala restore --missing`. It NEVER restores anything itself: a restore resumes a conversation, the owner's call.
# Stands aside (no clock kept, a posted flag stays) while a recycle holds its lock, the pane map is frozen, a resurrect restore runs, a
# shutdown is under way, or the boot is still inside SALA_BOOT_GRACE with its report not made (that report counts the same gap).
# Left out, like ledger_missing: a sleeping session, SALA_NO_RELAUNCH, a shell session, the Remote Control server's; and a session the
# registry marks retired or whose side session wrote its `side done` marker. SALA_MISSING_CHECK=off turns it off. One log line per decision.
: "${SALA_MISSING_CHECK:=on}" "${SALA_MISSING_GRACE:=180}" "${SALA_MISSING_LIST:=15}"

# gone_busy → 0 (with GONE_BUSY_WHY) when sessions are legitimately absent right now. Not busy_elsewhere: a revive or an operation
# running says nothing about whether a session should exist, and that exit is the very one this tick must come before.
gone_busy() {
    GONE_BUSY_WHY=""
    if recycle_locked; then GONE_BUSY_WHY="the recycle lock is held"
    elif ledger_frozen; then GONE_BUSY_WHY="the pane map is frozen ($(ledger_freeze_line))"
    elif pgrep_mine 'tmux-resurrect/scripts/[r]estore.sh' >/dev/null; then GONE_BUSY_WHY="a resurrect restore is running"
    elif shutting_down; then GONE_BUSY_WHY="a shutdown is under way"
    elif boot_pending && [ "${BOOT_AGE:-0}" -lt "${SALA_BOOT_GRACE:-900}" ]; then GONE_BUSY_WHY="the boot report is still to come (it counts the sessions without a tmux session)"
    fi
    [ -n "$GONE_BUSY_WHY" ]
}
# gone_clear_unposted → forget the clocks of sessions not yet posted (a flag already posted stays: the incident goes on)
gone_clear_unposted() {
    local k v first posted; [ -r "$WSTATE" ] || return 0
    for k in $(grep -o '^gone\.[^=]*' "$WSTATE" 2>/dev/null); do
        v=$(st_get "$k"); read -r first posted <<< "$v"; [ "${posted:-0}" = 0 ] && st_del "$k"
    done
    return 0
}

gone_tick() {
    [ "${SALA_MISSING_CHECK:-on}" = off ] && return 0
    [ -s "$SALA_SIDECAR" ] || return 0
    on_fleet_server || return 0
    tmux_server_up || return 0
    if gone_busy; then wlog "gone sessions: standing aside — $GONE_BUSY_WHY"; gone_clear_unposted; return 0; fi
    local line sess key v first posted now age n k names
    local -A seen=()
    local fresh=() waiting=()
    now=$(date +%s)
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        sess=${line%%$'\t'*}
        [ ! -f "$(side_done_file "$sess")" ] || continue                         # a finished side session waits for the owner's retire
        ! bare_retired "$sess" || continue                                       # retired in the registry: its row is on the way out
        _key_r key "$sess"; key="gone.$key"; seen[$key]=1
        v=$(st_get "$key")
        if [ -z "$v" ]; then
            st_set "$key" "$now 0"
            wlog "gone sessions: '$sess' is in the pane map but has no tmux session (first seen) — said if it is still gone ${SALA_MISSING_GRACE}s from now"
            continue
        fi
        read -r first posted <<< "$v"; : "${first:=$now}" "${posted:=0}"
        [ "$posted" = 0 ] || continue                                            # said already, once for this incident
        age=$((now - first))
        if [ "$age" -lt "$SALA_MISSING_GRACE" ]; then waiting+=("$sess"); wlog "gone sessions: '$sess' gone for ${age}s of ${SALA_MISSING_GRACE}s — waiting"; continue; fi
        fresh+=("$sess"); st_set "$key" "$first $now"
    done < <(ledger_missing)
    # an incident ends when the session exists again, leaves the map, sleeps, is retired or is no longer eligible
    for k in $(grep -o '^gone\.[^=]*' "$WSTATE" 2>/dev/null); do [ -n "${seen[$k]+x}" ] || { st_del "$k"; wlog "gone sessions: ${k#gone.} is back (or no longer eligible) — incident closed"; }; done
    [ ${#fresh[@]} -gt 0 ] || return 0
    n=${#fresh[@]}
    names=$(printf '%s, ' "${fresh[@]:0:$SALA_MISSING_LIST}" | sed 's/, $//'); [ "$n" -gt "$SALA_MISSING_LIST" ] && names="$names, and $((n - SALA_MISSING_LIST)) more"
    wlog "gone sessions: $n session(s) have been without a tmux session for ${SALA_MISSING_GRACE}s or more — posting: ${fresh[*]}"
    notify "⚠️ *watch: $n mapped session$([ "$n" = 1 ] || echo s) lost $([ "$n" = 1 ] && echo its || echo their) tmux session: $names*" \
        "each is in the pane map but has no tmux session (the conversation is not lost: its row keeps the id and the directory)" \
        "\`sala restore --missing\` recreates $([ "$n" = 1 ] && echo it || echo them) in the same directories and resumes the conversations (\`--dry-run\` lists what it would do); watch does not do it by itself" \
        "$([ ${#waiting[@]} -gt 0 ] && echo "${#waiting[@]} more are gone for less than ${SALA_MISSING_GRACE}s and are said when they pass it")" \
        "Details: $WLOG"
    return 0
}
