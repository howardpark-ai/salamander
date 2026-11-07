# lib/continuedin.sh — watch's CONTINUED-IN follow: a live pane that moved to a new transcript id keeps its row.
# Sourced by lib/watch.sh (like barepane.sh); cont_tick runs once per watch tick, before bare_tick, and alone as
# `sala watch --continued` (lib/follow.py runs that the moment a registry row's sessionId changes).
#
# WHY: Claude Code 2.1.31x can move a LIVE pane to a new transcript id without
# restarting the process (same pane, same pid): it appends {"type":"continued-in","timestamp":…,"sessionId":"<old>",
# "continuedInSessionId":"<new>"} to the OLD transcript, ~/.claude/projects/<cwd-slug>/<old>.jsonl, and the new transcript begins
# with a history-suppression record. The pane map (sidecar_uuid_for_session) and the session registry (sessions.json) kept the old
# id until a revive three hours later, and stackshot saw two live sessions under one name. The only follow there was
# was write_sidecar (revive --save-map), which runs on a recycle, not on a timer.
#
# NOT NECESSARILY THE LAST LINE: the record is followed by whatever the old transcript still gets (the real one had four more lines,
# written hours later), so this reads a window from the end of the file (tail -c, SALA_CONTINUED_TAIL, 256 KiB; a transcript can
# pass 200 MB, never read whole), finds the record lines in it with a stream search (grep, never bash string slicing, which is
# O(n^2): 66 s a call at 256 KiB) and takes the LAST one whose sessionId is the transcript's own. A record pushed out of the window
# (more than 256 KiB of later lines) is not seen here; write_sidecar (revive --save-map) repairs that case, at a recycle.
#
# WHAT IT DOES: for every mapped pane with a live claude, starting from the pane map's conversation M, it follows the continued-in
# records through the transcripts (a chain: M → N1 → N2 …, at most SALA_CONTINUED_HOPS, a loop stops it). A hop is TAKEN only when
# the pid's registry row (registry_conv_r, Claude Code's own record of the conversation) is that hop's id or a deeper one in the
# chain. That is the only evidence: a registry row that still names M (or an id outside the chain: a /clear, a hand --resume) is
# not followed, however new the record or the next transcript is, because a record can belong to ANOTHER process's switch (a hand
# `claude --resume M` in a second pane), and because write_sidecar follows the registry, so following against it would ping-pong.
# With the last taken hop T different from M it runs `ledger_write follow` (the pane map: one row = one conversation, a refusal is
# logged) and records every new id in order as a `resume` of the session registry row, which makes the old id a non-current
# transcript there (the last transcript of a row is the current one; there is no per-transcript flag). One line in the watch log.
# While the pane map is frozen (a recycle or reboot holds it) a pane is skipped entirely: no follow, no log line, no session
# record; the first tick after the freeze does it.
#
# OTHER STATE KEYED BY THE CONVERSATION needs nothing: the busy marker (the Stop hook writes the new id's, busy_prune sweeps the
# old), the waiting flag and ready marker (short-lived, pruned), holders (by pid), a parked pane (skipped: its registry
# conversation is the job's) and the stackshot session row (sessions.json, above). The ledger log carries the follow line.
#
# NEVER: while the kill switch SALA_CONTINUED_IN=off; on a tmux server that is not the fleet's; for the Remote Control session, a
# Remote Control child, a session in SALA_NO_RELAUNCH, a parked pane, a session with no pane-map row; while the pane map is frozen.

: "${SALA_CONTINUED_IN:=on}" "${SALA_CONTINUED_TAIL:=262144}" "${SALA_CONTINUED_HOPS:=8}"

# cont_record <uuid> → 0 with CONT_NEXT (the new conversation id) and CONT_EP (the record's time, epoch s, 0 if unreadable) set
# from the LAST continued-in record in the tail of <uuid>'s transcript whose sessionId is <uuid>; 1 when there is none
cont_record() {
    local f rec re ts
    CONT_NEXT=""; CONT_EP=0
    f=$(transcript_for_uuid "$1"); [ -n "$f" ] || return 1
    # a stream search, not string slicing of the window (bash's ${win#"$before"} is O(n^2): 1.7 s a call at 64 KiB, 66 s at 256 KiB):
    # the window's lines that hold a record, narrowed to this transcript's own id, the last one
    { rec=$(LC_ALL=C tail -c "$SALA_CONTINUED_TAIL" "$f" | LC_ALL=C grep -a -F '"type":"continued-in"' | LC_ALL=C grep -a -F "\"sessionId\":\"$1\"" | tail -n 1) || true; } 2>/dev/null
    [ -n "$rec" ] || return 1
    re='"sessionId":"([^"]*)"'
    [[ $rec =~ $re ]] && [ "${BASH_REMATCH[1]}" = "$1" ] || return 1
    re='"continuedInSessionId":"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"'
    [[ $rec =~ $re ]] || return 1
    CONT_NEXT=${BASH_REMATCH[1]}
    re='"timestamp":"([^"]+)"'
    if [[ $rec =~ $re ]]; then ts=$(date -u -d "${BASH_REMATCH[1]}" +%s 2>/dev/null) && CONT_EP=$ts; fi
    return 0
}

# cont_say <key> <line> — a log line once per change of its text (a refused follow is not logged every tick)
cont_say() {
    local k="contwhy.$1"
    [ "$(st_get "$k")" = "$2" ] && return 0
    st_set "$k" "$2"; wlog "continued-in: $2"
}

# cont_pane <session> <claude pid> — the chain, the hops taken, the follow
cont_pane() {
    local sess="$1" pid="$2" m r key cur i h ridx=-1 t n rc fr cwd old
    local -a chain=()
    local -A seen=()
    ledger_frozen && return 0      # a recycle or reboot holds the pane map: nothing is followed, logged or recorded (the next tick does it)
    m=$(sidecar_uuid_for_session "$sess"); [ -n "$m" ] || return 0
    registry_conv_r r "$pid"; [ -n "$r" ] && [ "$r" != null ] || return 0
    chain=("$m"); seen[$m]=1; cur=$m
    for ((h = 0; h < SALA_CONTINUED_HOPS; h++)); do
        cont_record "$cur" || break
        [ -z "${seen[$CONT_NEXT]+x}" ] || break
        seen[$CONT_NEXT]=1; chain+=("$CONT_NEXT"); cur=$CONT_NEXT
    done
    [ ${#chain[@]} -gt 1 ] || return 0
    for i in "${!chain[@]}"; do [ "${chain[$i]}" = "$r" ] && ridx=$i; done
    [ "$ridx" -ge 0 ] || return 0                                  # the registry names an id outside the chain: not this tick's
    t=$m; n=0
    for ((i = 1; i < ${#chain[@]}; i++)); do
        [ "$ridx" -ge "$i" ] || break                              # the pid's own registry row is the only evidence of a hop
        t=${chain[$i]}; n=$i
    done
    _key_r key "$sess"
    if [ "$t" = "$m" ]; then
        cont_say "$key" "$sess: a continued-in record names ${chain[1]}, but the pid's registry row still says $r — not followed"
        return 0
    fi
    registry_field_r cwd "$pid" cwd; [ "$cwd" = null ] && cwd=""
    old=$m
    fr=$(SALA_LEDGER_CALLER="watch, continued-in" ledger_write follow "$sess" "$t" "$cwd" 2>&1); rc=$?
    if [ "$rc" != 0 ]; then
        cont_say "$key" "$sess: conversation $old → $t ($n hop(s)) — pane map NOT followed (exit $rc: $(printf '%s' "$fr" | tr '\n\t' '  ' | cut -c1-200))"
        return 0
    fi
    for ((i = 1; i <= n; i++)); do sessions_record_soft "$sess" "${chain[$i]}" resume; done
    st_del "contwhy.$key"
    wlog "continued-in: $sess: conversation $old → $t ($n hop(s)); pane map followed, session registry recorded"
}

cont_tick() {
    [ "${SALA_CONTINUED_IN:-on}" = off ] && return 0
    [ -s "$SALA_SIDECAR" ] || return 0
    on_fleet_server || return 0
    tmux has-session 2>/dev/null || return 0
    ( flock -n 8 || exit 0; cont_locked ) 8>>"$SALA_LOG_DIR/salamander-continuedin.lock"
}
cont_locked() {
    local tbl sess pane pid parked
    local -A done_=()
    _claude_panes_r tbl
    while IFS='|' read -r sess pane pid; do
        [ -n "$sess" ] && [ -n "$pid" ] || continue
        [ -z "${done_[$sess]+x}" ] || continue; done_[$sess]=1
        [ "$sess" = "$SALA_RC_SESSION" ] && continue
        no_relaunch "$sess" && continue
        is_rc_child "$pid" && continue
        parked_job_r parked "$pid" && continue
        [ -n "$(ledger_row "$sess")" ] || continue
        cont_pane "$sess" "$pid"
    done <<< "$tbl"
}
