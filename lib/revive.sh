# lib/revive.sh — bring tmux-hosted Claude Code sessions back after a reboot or CLI update.
#
#   1. REBOOT: tmux-resurrect/continuum restore panes as bare shells (`claude` deliberately
#      NOT in @resurrect-processes — see below). This starts each pane back into its OWN
#      conversation. Wire it to @resurrect-hook-post-restore-all.
#   2. CLI UPDATE: after `claude update`, live processes keep running the old binary (only the
#      launcher symlink moved). This gracefully /exits each stale claude when idle and resumes
#      the same conversation on the new binary.
#
# WHY resume by UUID, not `claude --continue`: panes commonly share a cwd, and "continue the
# most recent conversation in this directory" would hand every pane the same one.
#
# PANE → CONVERSATION, in order of authority:
#   a. LIVE REGISTRY  ~/.claude/sessions/<pid>.json (sessionId inside the process — right even
#      after /clear or an in-process resume; plus status and the tmux pane)
#   b. THE PANE MAP  $SALA_SIDECAR — tmux session → sessionId → name → cwd, for dead panes. A ledger only honored
#      paths change (common.sh, "pane-map ledger"); --save-map (wired to @resurrect-hook-post-save-all) only observes
#   c. TITLE FALLBACK  grep the saved pane title against transcripts. Ambiguous → newest + warning.
# DEDUPE GUARD: never --resume a sessionId that is already live anywhere (two writers, one file).
# IDLE GUARD: /exit is typed only when the registry says idle for ≥10 s, the process has no
# children, and no task/subagent output was written in the last 2 min — background work counts.
#
# --self: relaunch the session this command runs INSIDE, once it goes idle (detached worker).
#
# RETRY: a recycle comes back for the panes it skipped for a
# TRANSIENT reason (a turn running, idle < 10 s, a background child or agent, an unsubmitted draft,
# a composer that would not take /exit) instead of leaving them until the next manual run. The
# driver hands them to a detached retry worker that re-runs the same sweep (`--only <session>`, same
# flags, no gate relaxed) every SALA_RETRY_EVERY s for SALA_RETRY_WINDOW s, logs every attempt and
# says one thing at the end: all relaunched, or who is DEFERRED and why (Thu Oct 22nd 2026: the window's end used
# to give a pane up as "still skipped"; a builder said `sala ready` ~20 times in the 07:47 recycle and was given
# up at 09:54, its background Bash loops holding the registry at 'shell', which this worker read as transient). A pane that
# said ready and is held by background shells only (registry 'shell', ready_shell_hold) goes on the deferred list at once, a pane
# pending at the window's end goes there too: both stay outstanding in their set, watch relaunches them once they are free
# (deferred_revive), and only the 8-day drop of that list gives one up. Nothing relaunches a pane earlier than before. A terminal prompt, an
# unmappable pane, or a /exit that may be queued are NOT retried — those need a human.
# A direct `revive --only <session>` does the same for its one pane (a busy pane was skipped
# and nobody came back for it), in a Revive set of its own (common.sh, "recycle sets"), so it never stops a recycle's
# worker; a new recycle stops every worker, since its sweep covers those panes again.
# SETS: every post after a recycle's first names that recycle and counts n/N (common.sh,
# "recycle sets"). The driver names the set (SALA_SET) before its sweep; the sweep writes it; every worker, the self-worker
# and watch's deferred relaunch settle their panes in it. Each worker has its own pid file (salamander-retry.<pid>.pid).
# THE LANE LINE (Wed Oct 14th 2026, a coordinating session: `revive --force --only 56` put pane 56 on the api default — it had no
# lane row, and only its environment knew it ran on subscription-2, then called team). Every relaunch plan prints "lane: <runs on now> → <relaunched
# on>" for its pane (lane_plan below), the first from the process (proc_lane), the second from the resume line's source
# (lane_for_session: the row, else the default), and when the two differ and no row records the intent, THAT PANE is refused
# — not the sweep: the default would silently move it to another account. The refusal names both lanes and the fix:
# `salamander lane <running lane> <session>` records and relaunches it, or --lane-default accepts the default. A row wins as
# before (it is the recorded intent); a shell pane runs nowhere ("none"); "?" (environment unreadable) is never a mismatch.
# A DRY RUN schedules nothing and writes nothing, in every form: the sweep ends after its check phase, `--self` prints what
# the self-worker would do and starts none, recycle's driver skips the freeze, the self-worker and the retry-worker purge.
# THE RESCUE (Wed Oct 14th 2026; `--rescue`, with --only or --self; `sala lane … --rescue` passes
# it): the CLI's task registry keeps a row for a shell stopped by hand or a subagent long gone, so its /exit
# opens the "Background work is running" dialog over nothing, and exit_wait, which cancels that dialog with Esc unless every
# row is a scheduled job, left a builder (a stale subagent row) and a maintainer (a stale
# shell-loop row) on a dead lane with no child process under either. Under --rescue, when NO child process runs under
# the pane's claude (work_children, common.sh: the one live reading sala has), the dialog is confirmed instead — Enter on
# its selected "1. Exit and stop tasks", the key the scheduled-job case already presses — and the Stop hook's record and
# the mod's refusal, both copies of the same registry, are read as stale by the same test (is_idle_reason and pane_exit,
# common.sh, SALA_RESCUE=1). A live child keeps every refusal as it is; a scratch file written in the last 2 min too. Each
# pass-over is said in the sweep's output (the revive log), and the row's note names it. Never for a recycle: a whole
# fleet confirmed blind is not a rescue.

DRY=0; FORCE=0; SELF_WORKER=0; SELF_PANE=""; ONLY=""; ONLY_LIST=(); RESCUE=0; RESCUE_NOTE=""; PAUSE_NOTE=""; DRAFTS_NOTE=""; RELAUNCH_CWD=""; CWD_PLAN=""
# read ahead of the flag loop: `--self` acts the moment the loop reaches it, before a `--rescue` that
# follows it on the line would have been seen (lib/lane.sh writes `revive --self $RESCUEFLAG`)
for a in "$@"; do case "$a" in --rescue) RESCUE=1; export SALA_RESCUE=1;; esac; done
LANE_DEFAULT_OK="${SALA_LANE_DEFAULT_OK:-0}"   # --lane-default (exported for the self-worker and the workers): accept the default for a pane without a row
# --only may be given more than once (Tue Oct 13th 2026: `sala lane <lane> A B` relaunches just those panes in one
# sweep); ONLY_LIST holds the names, ONLY the same joined by commas for a set's scope and the messages
only_has() { local s; for s in ${ONLY_LIST[@]+"${ONLY_LIST[@]}"}; do [ "$s" = "$1" ] && return 0; done; return 1; }
# lane_plan <session> <claude pid, or "" for a shell pane> → LANE_LINE ("lane: Team → api"); 0 to relaunch, 1 refused with
# LANE_WHY (the header, THE LANE LINE). A row that is not a known lane (hand-edited) counts as no row, as lane_for_session reads it.
lane_plan() {
    local sess="$1" cpid="${2:-}" now to row; LANE_WHY=""
    to=$(lane_for_session "$sess"); row=$(lane_row "$sess"); lane_known "$row" || row=""
    if [ -n "$cpid" ]; then now=$(proc_lane "$cpid"); else now=none; fi
    LANE_LINE="lane: $now → $to"
    [ -n "$row" ] && return 0
    case "$now" in none|"?"|"$to") return 0;; esac
    [ "$LANE_DEFAULT_OK" = 1 ] && { LANE_LINE="$LANE_LINE (no lane row; the default accepted: --lane-default)"; return 0; }
    if [ "$now" = other ]; then
        LANE_WHY="runs in a config directory sala does not know (CLAUDE_CONFIG_DIR) and has no lane row, so a relaunch would put it on $to (the default) — list it in SALA_NO_RELAUNCH, or accept the default: salamander revive --force --only $sess --lane-default"
    else
        LANE_WHY="runs on the $now lane but has no lane row, so a relaunch would put it on $to (the default) — record its lane first: salamander lane $now $sess (relaunches it on $now), or accept the default: salamander revive --force --only $sess --lane-default"
    fi
    return 1
}
LOG="$SALA_LOG_DIR/salamander-revive.log"
RETRY_WHAT="${SALA_RETRY_WHAT:-Recycle}"   # the kind of a set a worker started by hand (no SALA_SET) makes for itself
pane_exists() { tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qxF "$1"; }
# transient_skip <skip line> → 0 when the reason clears by itself (worth retrying)
transient_skip() { case "$1" in *"registry says"*|*"idle for only"*|*"background task is running"*|*"background work in flight"*|*"background agent or task wrote"*|*"no registry status"*|*"unsubmitted text"*|*"did not take /exit"*|*"a turn is running"*|*"a subagent is running"*|*"resting until"*) return 0;; *) return 1;; esac; }
# rest_applies → 0 when this run relaunches for a ROUTINE flag, so a pane that started less than SALA_RECYCLE_REST ago waits (common.sh,
# recycle_rest_left): a recycle's sweep, or a retry worker's re-run of a recycle's pane, unless the flag came from the owner's
# words (`sala op recycle`, src op-recycle). A direct revive, a lane or model switch and the reboot are explicit relaunches: no rest.
rest_applies() {
    [ "${SALA_RECYCLE_REST:-0}" -gt 0 ] 2>/dev/null || return 1
    [ -n "${SALA_RECYCLE:-}" ] || [ -n "${SALA_RETRY_WORKER:-}" ] || return 1
    case "$(flag_src)" in op-recycle|revive|lane|model|reboot) return 1;; esac
    return 0
}
# exit_wait <pane> <secs> [<claude-pid>] → 0 once the pane is back at its shell; 2 when /exit opened Claude's "Background work
# is running" dialog for work that cannot be carried (a background shell, a monitor, a subagent): sala cancels its own
# /exit with Esc, so the session stays as it was; 1 on timeout. When everything the dialog lists is a scheduled task, sala
# picks "1. Exit and stop tasks": `claude --resume` re-arms the session's scheduled jobs itself (holding a job must not make a
# pane immune to recycle; tested on 2.1.289). The list's rows start with their kind, and a
# narrow pane wraps "scheduled task" over two rows, so every row must start with "scheduled" or "task".
# THE RESCUE (the header): with --rescue and the claude's pid, a dialog listing other rows is confirmed the same way when
# no child process runs under that claude — the rows are the registry's leftovers — and RESCUE_NOTE says so for the row.
# The dialog's text, read from the 2.1.299 binary (its exit prompt): the title, "The following will stop when you exit:",
# one row per task (its label, " · " and a detail), then the choices, "Exit and stop tasks" selected first, "Stay" last.
# THE DRAFTS GATE (lib/feedback.sh): a /exit that stops at the unsent-feedback prompt, drafts the drain could not send, is
# passed keeping them all (common.sh, drafts_gate_pass), and DRAFTS_NOTE says so.
exit_wait() {
    local t=0 scr list
    while [ "$t" -lt "$2" ]; do
        wait_for "$1" shell 2 && return 0
        if drafts_gate_pass "$1"; then DRAFTS_NOTE="the exit stopped at the unsent feedback drafts prompt: passed, the drafts stay queued"; t=$((t+2)); continue; fi
        scr=$(tmux capture-pane -p -t "$1" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -14)
        if grep -q 'Background work is running' <<< "$scr" && grep -q 'Esc to cancel' <<< "$scr"; then
            list=$(sed -n '/will stop when you exit/,/❯ 1\./p' <<< "$scr" | sed '1d;$d')
            if [ -n "$list" ] && ! grep -qvE '^[[:space:]]*(scheduled|task)\b' <<< "$list" && grep -q '❯ 1\. Exit and stop tasks' <<< "$scr"; then
                tmux send-keys -t "$1" Enter   # option 1 is selected: exit; the resume brings the jobs back
            elif [ -n "${3:-}" ] && pause_active "$3" && grep -q '❯ 1\. Exit and stop tasks' <<< "$scr"; then
                # A PAUSED PANE (common.sh, THE PAUSE): its turn was interrupted so the relaunch could go on, and the work this dialog lists is what
                # the relaunch cuts (a subagent the resume note tells the session to dispatch again, a shell, a monitor)
                PAUSE_NOTE="the exit dialog listed background work ($(printf '%s\n' "$list" | sed 's/^[[:space:]]*//' | paste -sd';' - | sed 's/;/; /g')), stopped by the pause"
                tmux send-keys -t "$1" Enter
            elif [ "$RESCUE" = 1 ] && [ -n "${3:-}" ] && [ -z "$(work_children "$3")" ] && grep -q '❯ 1\. Exit and stop tasks' <<< "$scr"; then
                RESCUE_NOTE="the exit dialog listed background work ($(printf '%s\n' "$list" | sed 's/^[[:space:]]*//' | paste -sd';' - | sed 's/;/; /g')), but no child process ran under the claude: stale rows, 'Exit and stop tasks' confirmed (--rescue)"
                tmux send-keys -t "$1" Enter
            else
                tmux send-keys -t "$1" Escape; return 2
            fi
        fi
        t=$((t+2))
    done
    return 1
}
# retry_worker [FLAGS…] -- "pane|session|label|claude-pid"…  (detached; see RETRY above). SALA_SET names the set it settles
# its panes in; a worker started without one (by hand) makes a set of its own.
retry_worker() {
    local flags=() e pane sess label oldpid last tries lastwhy panepid npid nv out why still res dl round=0 dforce nap pn pus _cv pw
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do flags+=("$1"); shift; done; shift || true
    local pending=("$@") deadline=$(( $(date +%s) + SALA_RETRY_WINDOW )) SET="${SALA_SET:-}" pidf="$SALA_LOG_DIR/salamander-retry.$$.pid" kind
    rlog() { echo "[$(date -Is)] retry: $*"; }
    if ! set_has "$SET"; then
        SET="$(date +%s)-$$"
        set_create "$SET" "$RETRY_WHAT" "worker.$$" ${#pending[@]} 0 "$(claude_ver)" 1 "why=$(relaunch_kind)" "src=$(flag_src)" \
            "fscope=$(for e in "${pending[@]}"; do IFS='|' read -r _ sess _ <<< "$e"; echo "$sess"; done | paste -sd, -)" \
            $(for e in "${pending[@]}"; do IFS='|' read -r _ sess _ <<< "$e"; echo "out=$sess"; done)
    fi
    export SALA_SET="$SET"   # the re-runs below record it with a pane they defer (defer_add)
    kind=$(set_val "$SET" kind); kind=${kind,,}
    # the flag's source goes to every re-run (rest_applies): a recycle's pane rests like the sweep's, an op recycle's and a revive's do not
    local fsrc; fsrc=$(set_val "$SET" src); [ -n "$fsrc" ] || { [ "$kind" = revive ] && fsrc=revive || fsrc=$(relaunch_kind); }; export SALA_FLAG_SRC="$fsrc"
    # the path goes into the trap as text: pidf is a local, gone under set -u by the time the EXIT trap runs
    echo $$ > "$pidf"; trap "rm -f $(printf %q "$pidf"); waiting_end_owner $$" EXIT
    # THE FLAG (common.sh, "the relaunch-waiting flag"): every pane this worker waits for gets waiting/<uuid>, naming the
    # relaunch (SALA_RELAUNCH_KIND from the starter, else the set's `why`): its session's PostToolUse hook tells it once, and
    # its Stop hook, ending a turn with nothing in flight, wakes this worker as `sala ready` does. Cleared as each pane leaves
    # the list (relaunched, given up, deferred to watch), and at the worker's end.
    # A pane that leaves the list without a relaunch, and one still waited for when the worker stops, ends its hold (common.sh,
    # hold_ended); a newer recycle taking over does not.
    local rk; rk=$(relaunch_kind "${SALA_RELAUNCH_KIND:-$(set_val "$SET" why)}")
    local -A conv=() ends=()   # pane → its conversation (read now: a relaunched pid's row is gone) · pane → "mode|why" when it leaves with no relaunch
    for e in "${pending[@]}"; do IFS='|' read -r pane _ _ oldpid _ <<< "$e"; registry_conv_r _cv "$oldpid"; conv[$pane]=$_cv; waiting_raise "$_cv" "$rk" "$SET" $$; done
    rlog "watching ${#pending[@]} skipped pane(s) of the $kind set $(set_val "$SET" label) ($SET): every $((SALA_RETRY_EVERY/60)) min, or at once when a pane says \`sala ready\` (or its Stop hook sees nothing in flight), for up to $((SALA_RETRY_WINDOW/60)) min (flags: ${flags[*]:-none}; told as: $(relaunch_what "$rk"))"
    local now uuid due woke=0 sp
    dforce=0; [[ " ${flags[*]-} " == *" --force "* ]] && dforce=1   # what a deferred pane's row carries (defer_add)
    trap 'woke=1; kill "${sp:-}" 2>/dev/null' USR1          # `sala ready` in a pending pane, or its Stop hook's record, wakes the worker
    while [ ${#pending[@]} -gt 0 ] && [ "$(date +%s)" -lt "$deadline" ]; do
        # the sleep ends at the next retry, or earlier when a pane's pause clock runs out before it (pause_next_in_r; never under 30 s)
        nap=$SALA_RETRY_EVERY; pus=(); for e in "${pending[@]}"; do IFS='|' read -r _ _ _ oldpid _ <<< "$e"; registry_conv_r _cv "$oldpid"; pus+=("$_cv"); done
        pause_next_in_r pn ${pus[@]+"${pus[@]}"}; if [ "$pn" -ge 0 ] && [ "$pn" -lt "$nap" ]; then nap=$(( pn < 30 ? 30 : pn )); fi
        woke=0; sleep "$nap" & sp=$!; wait "$sp" 2>/dev/null; sp=""
        still=(); res=(); dl=(); ends=(); now=$(date +%s); [ "$woke" = 1 ] && rlog "woken (a pending pane said \`sala ready\`, or its Stop hook saw nothing in flight)"
        set_superseded "$SET" && { rlog "a newer $kind took over ($(cat "$(_set_scope_file "$(set_val "$SET" scope)")" 2>/dev/null)) — stopping"; waiting_clear_owner $$; exit 0; }
        for e in "${pending[@]}"; do
            IFS='|' read -r pane sess label oldpid last tries lastwhy <<<"$e"; : "${last:=0}" "${tries:=0}"
            pane_exists "$pane" || { res+=(gave "$sess" "$sess: its pane is gone"); continue; }
            # the flag closed one short with this pane as the straggler (common.sh, _set_short_close): it is on the deferred list now, watch relaunches it
            if [ "$(set_val "$SET" closed)" = 1 ] && set_vals "$SET" short | grep -q "^$sess[: ]"; then ends[$pane]="deferred|the recycle closed without it"; rlog "$label: the flag closed one short — on the deferred list, watch relaunches it once it is free"; continue; fi
            # listed after this worker started (common.sh, no_relaunch): never relaunched; given up so the set can close
            # a session that went to sleep since: nothing to relaunch, and it no longer counts in the set (not "given up": it is not left behind)
            is_sleeping "$sess" && { ends[$pane]="ended|it went to sleep"; res+=(gone "$sess" "$sess is sleeping, so it no longer counts"); rlog "$(sleeping_line "$sess")"; continue; }
            no_relaunch "$sess" && { ends[$pane]="dropped|sala is now set never to relaunch it (SALA_NO_RELAUNCH)"; res+=(gave "$sess" "$(no_relaunch_line "$sess")"); rlog "$(no_relaunch_line "$sess")"; continue; }
            # a pane that said `ready`, or whose last turn ended with nothing in flight (the Stop hook's record, busy_hook_idle),
            # is tried now (once its turn has ended and settled); the others every SALA_RETRY_EVERY
            registry_conv_r uuid "$oldpid"; due=0
            if [ -n "$uuid" ] && { ready_for "$uuid" || busy_hook_idle "$oldpid" "$uuid"; }; then
                due=1; local w=0; while [ -n "$(is_idle_reason "$oldpid")" ] && ! ready_shell_hold "$oldpid" && [ "$w" -lt "$SALA_READY_WAIT" ]; do sleep 2; w=$((w+2)); done
                # said ready, its turn is over, and background shells alone hold it (registry 'shell'): no retry will
                # clear that in minutes. DEFERRED, not skipped: watch relaunches it once the shells are done, and it stays
                # outstanding in the set; nothing is relaunched earlier than before (the shells still hold the pane)
                if ready_shell_hold "$oldpid"; then
                    local hl; hl=$(holders_inline "$oldpid")   # the processes holding it, named
                    defer_add "$sess" "said ready, but background shell(s) are still running (registry state 'shell')${hl:+: $hl}" "$dforce" "$SET"
                    # the post says it in the one short form (common.sh, hold_bullet: no pids, uptimes or commands); the log keeps the holders
                    dl+=("$(hold_bullet "$sess" "$oldpid" "registry says 'shell'")"); ends[$pane]="deferred|background shells are still running in it"
                    rlog "$label: said ready, held only by background shells (registry 'shell')${hl:+ ($hl)} — on the deferred list, watch relaunches it once they are done"; continue
                fi
                [ "$w" -ge "$SALA_READY_WAIT" ] && rlog "$label: ready by its own word but still not idle after ${SALA_READY_WAIT}s — $(is_idle_reason "$oldpid")"
            elif [ $((now - last)) -ge "$SALA_RETRY_EVERY" ]; then due=1
            # THE PAUSE (common.sh): a pane whose clock has run out is tried now, not at the next SALA_RETRY_EVERY (at most every 2 min: a pane
            # the pause refused is not tried over and over)
            elif [ -n "$uuid" ] && [ $((now - last)) -ge 120 ] && pause_due "$uuid"; then due=1; rlog "$label: the pause's deadline is reached — tried now"; fi
            [ "$due" = 1 ] || { still+=("$pane|$sess|$label|$oldpid|$last|$tries|$lastwhy"); continue; }
            round=$((round+1)); tries=$((tries+1))
            panepid=$(tmux display -p -t "$pane" '#{pane_pid}' 2>/dev/null); npid=$(claude_pid_under "$panepid")
            pw=""; [ -z "$uuid" ] || pw=$(pause_words "$uuid"); pw=${pw:+, $pw}   # THE PAUSE: a pane whose turn was paused says so in its closure line
            if relaunched_from "$oldpid" "$npid"; then res+=(ok "$sess" "$sess relaunched meanwhile, on $(proc_version "$npid"), $(set_after "$SET")$pw"); rlog "$label: already relaunched (pid $oldpid → $npid)"; continue; fi
            out=$(SALA_RETRY_WORKER=1 "$SALA_BIN" revive --only "$sess" ${flags[@]+"${flags[@]}"} 2>&1); printf '%s\n' "$out" | grep -F "$label" | sed 's/^ */    /'
            npid=$(claude_pid_under "$(tmux display -p -t "$pane" '#{pane_pid}' 2>/dev/null)")
            if relaunched_from "$oldpid" "$npid"; then
                nv=$(proc_version "$npid"); pw=""; [ -z "$uuid" ] || pw=$(pause_words "$uuid"); pw=${pw:+, $pw}
                res+=(ok "$sess" "$sess relaunched on $nv, retry $tries, $(set_after "$SET")$pw"); rlog "$label: relaunched on $nv${pw}"; continue
            fi
            why=$(printf '%s\n' "$out" | grep -F "$label: " | tail -1 | sed 's/^ *//')
            case "$why" in *": already "*|*"own session"*) ends[$pane]="ended|it is already on the current version, so there is nothing to relaunch"; res+=(ok "$sess" "$sess already on $(proc_version "$oldpid"), $(set_after "$SET")"); rlog "$label: already current"; continue;; esac
            case "$why" in *"background work is running"*)   # work /exit would stop: watch relaunches it once that work is done; still outstanding in the set
                defer_add "$sess" "${why#*: }" "$dforce" "$SET"; ends[$pane]="deferred|${why#*: }"; rlog "$label: holds background work (${why#*: }) — on the deferred list, watch relaunches it once that work is done"; continue;; esac
            if [ -n "$why" ] && ! transient_skip "$why"; then ends[$pane]="ended|${why#*: }"; res+=(gave "$sess" "$(set_bullet "$why")"); rlog "not transient, giving up — $why"; continue; fi
            rlog "$label: still skipped (retry $tries) — ${why:-no verdict}"; still+=("$pane|$sess|$label|$oldpid|$now|$tries|${why#*: }")
        done
        # the flag comes down for every pane that left the list this pass: back or gone (silently), or with no relaunch (given up,
        # watch's now: hold_ended)
        for e in "${pending[@]}"; do IFS='|' read -r pane _ _ _ <<<"$e"
            case " $(printf '%s ' ${still[@]+"${still[@]}"})" in *" $pane|"*) continue;; esac
            if [ -n "${ends[$pane]:-}" ]; then hold_ended "${conv[$pane]:-}" "${ends[$pane]%%|*}" "${ends[$pane]#*|}"; else waiting_clear "${conv[$pane]:-}"; fi
        done
        pending=(${still[@]+"${still[@]}"})
        # CLOSURE (a follow-up report on the retry, when the retry actually passes through): the panes back in this pass in ONE post, one bullet each, the set's count in the headline
        [ ${#res[@]} -gt 0 ] && set_resolve "$SET" "${res[@]}"
        [ ${#dl[@]} -gt 0 ] && set_deferred "$SET" "${dl[@]}"
    done
    # THE WINDOW'S END: a pane still pending is DEFERRED, not given up. Its reason was transient (a turn running, a
    # background task, a draft) and is still its last word, so it goes on the deferred list with that reason, outstanding in the
    # set, and watch relaunches it once it is free (the 8-day drop of deferred_revive is the only give-up left for it). The post
    # names each as deferred, with the reason; the set stays open until watch settles them.
    dl=()
    for e in ${pending[@]+"${pending[@]}"}; do
        IFS='|' read -r pane sess label oldpid _ _ lastwhy <<<"$e"
        defer_add "$sess" "${lastwhy:-still busy when the retry window ended}" "$dforce" "$SET"
        hold_ended "${conv[$pane]:-}" deferred "the retry window ended with it still held (${lastwhy:-no verdict})"
        # the same words as the first post and the 🔄 follow-ups (common.sh, hold_bullet); a reason of neither kind (a draft, a prompt) keeps its own text
        b=$(hold_bullet "$sess" "$oldpid" "${lastwhy:-}") || b="$sess: ${lastwhy:-no verdict}; sala relaunches it once it is free"
        dl+=("$b")
        rlog "$label: window over, still skipped — on the deferred list (${lastwhy:-no verdict}), watch relaunches it once it is free"
    done
    [ ${#dl[@]} -gt 0 ] && set_deferred "$SET" "${dl[@]}"
    rlog "finished after $round attempt(s); the set: $(set_val "$SET" done)/$(set_val "$SET" total) back, $(set_count "$SET" out) outstanding, $(set_count "$SET" gave) given up"
}

# THE FLEET'S SERVER ONLY (common.sh, fleet_only): revive is tmux's post-restore-all and post-save-all
# hook (--save-map), so a probe server started with ~/.tmux.conf ran it against its own panes and scrambled the map. On any
# server but the fleet's, every form of it (recycle included) leaves at once, with one ledger-log line.
fleet_only "revive${1:+ $1}"

# --cwd DIR (common.sh, THE FOLDER OF A RELAUNCH): one named session and a folder that can hold it, checked here, before the lock, the
# update and the flags that act or detach inside the loop below
ncwd=0; nonly=0; with=""; prev=""
for a in "$@"; do
    case "$prev" in --cwd) RELAUNCH_CWD=$a; prev=""; continue ;; --only) prev=""; continue ;; esac
    case "$a" in
        --cwd) ncwd=$((ncwd+1)); prev=$a ;;
        --only) nonly=$((nonly+1)); prev=$a ;;
        --self|--self-worker|--retry-worker|--all|--save-map|--map-history) with=$a ;;
    esac
done
if [ "$ncwd" -gt 0 ]; then
    [ "$ncwd" = 1 ] || die "--cwd is given once"
    [ -z "$with" ] || die "--cwd moves the one session --only names; it does not go with $with"
    [ "$nonly" = 1 ] || die "--cwd moves one session: it needs exactly one --only NAME"
    relaunch_dir_ok "$RELAUNCH_CWD" || die "$RD_WHY"
fi

# THE RECYCLE LOCK (common.sh), before `claude update` and before any detach: whatever relaunches panes takes it here —
# recycle, a direct revive (--only, --self), the boot hook's revive (which waits for it) — and holds it to the end of the
# driver it starts (fd 9 is inherited; SALA_RECYCLE_LOCKED tells those children, and update's recycle, not to take it
# again). Read-only runs and the retry worker's re-runs never lock. Held by someone else → one line and exit 75.
LOCK_FREE=0; for a in "$@"; do case "$a" in --dry-run|--save-map|--map-history|--retry-worker|-h|--help) LOCK_FREE=1;; esac; done
if [ "$LOCK_FREE" = 0 ] && [ -z "${SALA_RETRY_WORKER:-}" ] && [ -z "${SALA_RECYCLE_LOCKED:-}" ]; then
    recycle_lock "$(lock_who)" "${SALA_LOCK_WAIT:-$(invoked_by_hook && echo 600 || echo 0)}" || recycle_refuse
    export SALA_RECYCLE_LOCKED=1
fi

# --update: update the CLI FIRST, then sweep. Handled before the flag loop because `--all` (recycle)
# detaches and exits inside it, and the driver must see the new launcher target. A live process keeps
# the binary it started with — only a relaunch moves it — so "update the CLI" and "relaunch the panes"
# are one operation; this is the whole of the owner's "recycle claude" cue.
# --dry-run is read here too, before the update (Wed Oct 14th 2026, a coordinating session: `revive --update --dry-run` ran
# `claude update`, since the flag loop that sets DRY comes after this block); it stays in the arguments, so the flag loop
# and recycle's driver still see it.
DO_UPDATE=0; ARGS=()
for a in "$@"; do case "$a" in --update) DO_UPDATE=1 ;; --dry-run) DRY=1; ARGS+=("$a") ;; *) ARGS+=("$a") ;; esac; done
set -- ${ARGS+"${ARGS[@]}"}
if [ "$DO_UPDATE" = 1 ] && [ "$DRY" = 1 ]; then
    # nothing is fetched on a dry run: the target is whatever `claude update` would find
    echo "[dry-run] would update the CLI: $(claude_ver) → the latest release (claude update; not checked on a dry run)"
elif [ "$DO_UPDATE" = 1 ]; then
    before=$(claude_ver)
    echo "updating the CLI ($before) ..."
    if out=$(cli_update); then printf '%s\n' "$out" | tail -2; else   # 9>&-: a child the updater leaves behind must not hold the recycle lock
        printf '%s\n' "$out" | tail -3; die "claude update failed — not sweeping (panes keep working on $before)"; fi
    after=$(claude_ver)
    # the post-update hook (a heartbeat + SALA_POST_UPDATE_CMD, ~10 s) must not hold the sweep:
    # nothing moved → the tracker has nothing to learn, skip it; moved → run it detached, its lines in the log
    if [ "$after" = "$before" ]; then echo "already current: $after"
    else
        echo "launcher now $after (was $before)"; mkdir -p "$SALA_LOG_DIR"
        setsid bash -c 'echo "[$(date -Is)] post-update hook: $2"; . "$1/lib/common.sh"; post_update_hook "$2" "$3"' _ "$SALA_ROOT" "$(hostname) claude $before → $after" "$(hostname)" </dev/null >>"$LOG" 2>&1 9>&- &
        disown   # not one of the sweep's jobs: nothing below waits for it, and it does not hold the recycle lock (9>&-)
    fi
fi

write_sidecar() {  # OBSERVE ONLY: the live registry against the pane map; the one change it may make is the FOLLOW
    # (the map is a ledger — common.sh, "pane-map ledger"). It used to REBUILD the map from the
    # live registry on every save (carrying forward the rows of panes whose claude had died while their tmux session
    # lived), so the first save after a boot, with only some sessions back, dropped the other rows. Now a
    # mapped session whose live claude reports a different conversation than its row (a /clear, a hand --resume) has its
    # row follow the process; nothing is added (an unmapped live session is reported by `sala watch`; `sala adopt`
    # registers it) and nothing is dropped (a crash, a dead claude or a missing tmux session leaves its row in place),
    # so the carry-forward is no longer needed. The write itself, with its guards, is ledger_write's.
    local f pid sid tm cwd sess have n=0 nf=0 nr="" rc=0
    OBSERVED="no pane map yet"; [ -r "$SALA_SIDECAR" ] || return 0
    for f in "$SALA_REG_DIR"/*.json; do
        [ -r "$f" ] || continue
        pid=${f##*/}; pid=${pid%.json}; case "$pid" in ''|*[!0-9]*) continue;; esac
        kill -0 "$pid" 2>/dev/null || continue
        tm=$(registry_field "$pid" tmux); [ -n "$tm" ] || continue
        registry_conv_r sid "$pid"; [ -n "$sid" ] || continue   # a parked pane follows its job
        is_rc_child "$pid" && continue
        [ "${tm%%:*}" = "$SALA_RC_SESSION" ] && continue
        # the registry's `tmux` is cached at start and ignores rename-session; the pane id in it
        # is stable, so resolve the CURRENT session name from tmux
        sess=$(tmux display -p -t "${tm##*.}" '#{session_name}' 2>/dev/null)
        [ -n "$sess" ] || sess=${tm%%:*}
        # A PANE ID IS PER SERVER (a probe on a private tmux socket, pane %1, was once read as the fleet's %1):
        # the claude must descend from that fleet pane's shell, else it lives on another server and is none of the map's
        is_under "$pid" "$(tmux display -p -t "${tm##*.}" '#{pane_pid}' 2>/dev/null)" || continue
        n=$((n+1))
        have=$(sidecar_uuid_for_session "$sess"); [ -n "$have" ] || continue   # unmapped: never added from here
        [ "$have" = "$sid" ] && continue
        cwd=$(registry_field "$pid" cwd); [ -n "$cwd" ] && [ "$cwd" != null ] || cwd=""
        # a refused follow (2: its conversation is another row's, common.sh) is the ledger doing its job, not a failed save
        if ledger_write follow "$sess" "$sid" "$cwd"; then nf=$((nf+1)); else [ $? = 2 ] && nr=$((nr+1)) || rc=1; fi
    done
    OBSERVED="$(wc -l < "$SALA_SIDECAR" | tr -d ' ') row(s), $n live pane(s) seen, $nf followed${nr:+, $nr refused (see $SALA_LEDGER_LOG)}"
    return $rc
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1 ;;
        --force)   FORCE=1 ;;
        --lane-default) LANE_DEFAULT_OK=1; export SALA_LANE_DEFAULT_OK=1 ;;   # the self-worker and the workers this run starts see it
        --rescue)  RESCUE=1; export SALA_RESCUE=1 ;;   # read ahead too (above); is_idle_reason and pane_exit (common.sh) see it
        --only)    [ -n "${2:-}" ] || die "--only needs a tmux session name"
                   only_has "$2" || { ONLY_LIST+=("$2"); ONLY="${ONLY:+$ONLY,}$2"; }
                   shift ;;
        --cwd)     shift ;;   # read and checked ahead of the loop
        --map-history)   # compared on the first three columns: older maps have no cwd column
            echo "current: $SALA_SIDECAR"; echo "log: $SALA_LEDGER_LOG"; ls -t "$SALA_LEDGER_HISTORY"/*pane-map.*.tsv 2>/dev/null | head -20 | while read -r f; do
                echo "--- $(basename "$f" .tsv | sed 's/^.*pane-map\.//') → rows only in this older map (bindings since replaced or dropped):"
                comm -23 <(cut -f1-3 "$f" | LC_ALL=C sort) <(cut -f1-3 "$SALA_SIDECAR" | LC_ALL=C sort) | sed 's/^/    /'
            done; exit 0 ;;
        --save-map) shutting_down && { echo "pane map not saved: a reboot is under way (the drain's map stands)"; exit 0; }; write_sidecar || exit 1; echo "pane map: $OBSERVED → $SALA_SIDECAR"; exit 0 ;;
        --self)
            [ -z "${TMUX_PANE:-}" ] && die "--self must run from inside a tmux pane (TMUX_PANE unset)"
            ss=$(tmux display -p -t "$TMUX_PANE" '#{session_name}')
            no_relaunch "$ss" && die "$(no_relaunch_line "$ss") — --self refused; $(no_relaunch_fix "$ss" "relaunch it the way it was launched")"
            ops_guard revive "$ss" $([ "$DRY" = 1 ] && echo --dry-run)
            # the lane line, before anything is scheduled (the header, THE LANE LINE); the self-worker checks it again when it fires
            scpid=$(claude_pid_under "$(tmux display -p -t "$TMUX_PANE" '#{pane_pid}' 2>/dev/null)")
            lane_plan "$ss" "$scpid" || die "$ss: $([ "$DRY" = 1 ] && echo "[dry-run] --self would be refused" || echo "--self refused") — $LANE_WHY ($LANE_LINE)"
            # --dry-run: what the self-worker would do, and no worker (Wed Oct 14th 2026, a coordinating session: `revive --self
            # --dry-run` scheduled the real self-relaunch — an earlier version read --dry-run before the update, but this branch never looked)
            if [ "$DRY" = 1 ]; then
                if [ -n "$scpid" ]; then
                    echo "[dry-run] $ss: would schedule the self-relaunch of pane $TMUX_PANE — once this session is idle, /exit ($(proc_version "$scpid")) and resume $(registry_field "$scpid" sessionId) on $(claude_ver) · $LANE_LINE"
                else
                    echo "[dry-run] $ss: no claude runs in pane $TMUX_PANE — the self-worker would find nothing to relaunch · $LANE_LINE"
                fi
                echo "[dry-run] nothing scheduled: no self-worker started, nothing written"; exit 0
            fi
            mkdir -p "$SALA_LOG_DIR"
            setsid "$SALA_BIN" revive --self-worker "$TMUX_PANE" $([ "$RESCUE" = 1 ] && echo --rescue) </dev/null >>"$LOG" 2>&1 &
            recycle_lock_repid $!   # the worker holds the recycle lock (inherited fd 9) until it is done
            echo "⏳ self-relaunch scheduled for pane $TMUX_PANE — fires once this session goes idle · $LANE_LINE$([ "$RESCUE" = 1 ] && echo " · --rescue: a stale task row will not hold it") (log: $LOG)"; exit 0 ;;
        --all)
            # ONE detached driver: sweep every other pane now, then relaunch the invoking pane once it
            # goes idle. The invoker is just one more pane; no special case in the UX (`sala recycle`).
            mkdir -p "$SALA_LOG_DIR"
            # remaining flags (--force, --only …) go to the sweep; the invoker is always relaunched
            sweep_args=("${@:2}")
            # options are checked HERE, before anything starts or is announced (`recycle --help` said
            # "recycle started" and the driver then died on the unknown option)
            i=0; while [ "$i" -lt ${#sweep_args[@]} ]; do case "${sweep_args[$i]}" in
                --force|--dry-run|--lane-default) ;; --only) i=$((i+1)); [ -n "${sweep_args[$i]:-}" ] || die "--only needs a tmux session name" ;;
                --rescue) die "--rescue is for one pane at a time (salamander revive --force --only <session> --rescue, or salamander lane … --rescue), never a recycle: a whole fleet's exit dialogs confirmed blind is not a rescue" ;;
                -h|--help) awk '/^#   salamander recycle \[--update\]/{p=1} p{print} /^#.*\(--force:/{exit}' "$SALA_BIN" | sed 's/^# \{0,1\}//'; exit 0 ;;   # the usage block only: from the recycle line to the --force line, then stop (a sed range restarted at the next "salamander recycle" line and ran to the end of the file)
                *) die "unknown option for recycle: ${sweep_args[$i]} (see: salamander recycle --help)" ;; esac; i=$((i+1)); done
            fleet_guard recycle "${@:2}"
            # the invoker follows the same rule as every pane: without --force it is relaunched only
            # when it runs an older version than the installed CLI
            selfpane="${TMUX_PANE:-}"
            if [ -n "$selfpane" ] && ! printf '%s\n' "${sweep_args[@]+"${sweep_args[@]}"}" | grep -qxE -- '--force|--update'; then   # with --update the CLI is about to change: compare after, i.e. relaunch
                sv=$(registry_field "$(claude_pid_under "$(tmux display -p -t "$selfpane" '#{pane_pid}')" 2>/dev/null)" version 2>/dev/null)
                [ -n "$sv" ] && [ "$sv" = "$(claude_ver)" ] && selfpane=""
            fi
            # an invoker managed outside sala (common.sh, no_relaunch) is never relaunched, nor counted in the set
            if [ -n "$selfpane" ] && ss=$(tmux display -p -t "$selfpane" '#{session_name}' 2>/dev/null) && no_relaunch "$ss"; then
                echo "$(no_relaunch_line "$ss") (the invoking pane)"; selfpane=""
            fi
            # THE FREEZE: the pane map is frozen before the sweep and lifted after the self-worker — the
            # frozen roster is what the end of the sweep brings back (ledger_compare_restore); meanwhile the map takes no add,
            # rename, retire or adopt, and a follow waits (common.sh, ledger_freeze). The driver's own pid owns the freeze, so
            # a driver that dies leaves a freeze `watch` can tell is stale.
            # THE POST-RECYCLE HOOK: SALA_POST_RECYCLE_CMD fires after the unfreeze (common.sh,
            # post_recycle_hook), through the set since Mon Oct 12th 2026; common.sh, set_recycled: it names the
            # panes the set still has not relaunched, and a pane a retry worker or watch brings back later fires it again
            # with this same `started`. The sweep and the self-worker still name the tmux sessions they left behind in
            # SALA_RECYCLE_SKIPPED_FILE (this driver's own file; a self-worker that fails counts as one), which stands in
            # when the sweep wrote no set. Not on a dry run.
            # THE SET (common.sh, "recycle sets"): the driver names it (SALA_SET, its start and pid)
            # and makes it the current recycle set, which stops an earlier recycle's workers; the sweep writes it, the invoking
            # pane counting in it (SALA_SET_SELF) when the self-worker will relaunch it. A clean recycle stays one post:
            # with the invoking pane the only one outstanding, the self-worker makes the set's first post once that
            # pane is settled. The first-post-at-once rule applies when a pane besides the invoking one is left behind: the
            # sweep posts, the invoking pane in it as "not relaunched yet", and the self-worker settles it like any other.
            # Fallback: a self-worker that died before posting leaves the set unreported, and the driver posts it here.
            # A DRY RUN (Wed Oct 14th 2026; the header, THE LANE LINE): the sweep's check phase and the self-worker's plan for the
            # invoking pane, nothing else — no freeze (until today a dry run froze the map for its length), no self-worker (until
            # today `recycle --force --dry-run` from a pane relaunched that pane for real), no set, no hook.
            SALA_RECYCLE=1 SALA_SKIP_PANE="${TMUX_PANE:-}" setsid bash -c '
                . "$1/lib/common.sh"; dry=0; case " ${*:3} " in *" --dry-run "*) dry=1 ;; esac
                case " ${*:3} " in *" --lane-default "*) export SALA_LANE_DEFAULT_OK=1 ;; esac   # the self-worker is a sibling of the sweep, not its child
                [ "$dry" = 1 ] || ledger_freeze recycle $$ || echo "[$(date -Is)] pane map not frozen for this recycle: $(ledger_freeze_line)"
                export SALA_RECYCLE_SKIPPED_FILE="$SALA_LOG_DIR/salamander-recycle-skipped.$$"; : > "$SALA_RECYCLE_SKIPPED_FILE"; started=$(date +%s)
                export SALA_SET="$started-$$"; [ "$dry" = 1 ] || set_point recycle "$SALA_SET"
                SALA_SET_SELF="$2" "$0" revive "${@:3}"
                if [ "$dry" = 1 ]; then [ -n "$2" ] && "$0" revive --self-worker "$2" --dry-run
                elif [ -n "$2" ] && ! "$0" revive --self-worker "$2"; then tmux display -p -t "$2" "#{session_name}" >> "$SALA_RECYCLE_SKIPPED_FILE" 2>/dev/null || echo "$2" >> "$SALA_RECYCLE_SKIPPED_FILE"; fi
                [ -n "$2" ] && [ "$dry" = 0 ] && set_report "$SALA_SET"   # no-op once reported
                [ "$dry" = 1 ] || ledger_unfreeze "recycle done"
                [ "$dry" = 1 ] || set_recycled "$SALA_SET" "$SALA_LOG_DIR/salamander-revive.log" "$started" $(cat "$SALA_RECYCLE_SKIPPED_FILE" 2>/dev/null)
                rm -f "$SALA_RECYCLE_SKIPPED_FILE"' "$SALA_BIN" "$SALA_ROOT" "$selfpane" ${sweep_args[@]+"${sweep_args[@]}"} </dev/null >>"$LOG" 2>&1 &
            # the driver holds the recycle lock (inherited fd 9) through the sweep and the self-worker; `kill -- -<pid>` ends it. A
            # dry run took no lock (LOCK_FREE), so it leaves the holder line alone: a real recycle may be running
            [ "$LOCK_FREE" = 1 ] || recycle_lock_repid $!
            if [ "$DRY" = 1 ]; then echo "⏳ recycle DRY RUN started as a detached driver — the relaunch verdict of every pane, including this one${TMUX_PANE:+ ($TMUX_PANE)}; nothing relaunched, nothing written${2:+; flags: ${*:2}}; log: $LOG"
            else echo "⏳ recycle started as a detached driver — every pane, including this one${TMUX_PANE:+ ($TMUX_PANE, once idle)}${2:+; flags: ${*:2}}; log: $LOG"; fi; exit 0 ;;
        --self-worker) SELF_WORKER=1; SELF_PANE="${2:-}"; [ -z "$SELF_PANE" ] && die "--self-worker needs a pane id"; shift ;;
        --retry-worker) shift; retry_worker "$@"; exit 0 ;;
        -h|--help) sed -n 's/^#   \(salamander revive .*\)/usage: \1/p' "$SALA_BIN"
                   echo "  (no option) every pane on an older CLI · --force: every idle pane · --only NAME: just that session"
                   echo "  --cwd DIR (with exactly one --only NAME; an absolute, existing, readable directory): the relaunch is made in DIR (a missing tmux session is created there)"
                   echo "  and, once the claude is up, DIR is written into the session's pane-map row, so a later restore starts there; without it no relaunch writes a folder."
                   echo "  A live claude on the current version needs --force too; a --cwd run is never retried or deferred"
                   echo "  every plan says \"lane: <runs on now> → <relaunched on>\"; a pane with no lane row that runs on another lane than the default is refused"
                   echo "  (salamander lane <lane> <session> records it; --lane-default accepts the default) · --dry-run: the verdicts, nothing relaunched or written"
                   echo "  a pane skipped for a passing reason (a turn running, a background child, a running subagent) is retried every $((SALA_RETRY_EVERY/60)) min for up to $((SALA_RETRY_WINDOW/60)) min, then deferred (watch relaunches it once it is free); one that said ready but is held by background shells only is deferred at once"
                   echo "  a running subagent is never cut: it holds the pane until it ends, the skip line and watch's one log line name it, and the in-session mod's own answer (the busy probe) is asked before an exit is tried; an exit the mod refuses for a turn it cannot name, with every other check idle, goes by keys after $SALA_STALE_TURN_AFTER refusals, then the tries thin out (10 min, then 30 min)"
                   echo "  --rescue (with --only or --self): a stale background-task row — the exit dialog, the Stop hook's record or the mod listing work while NO child process runs under the claude — no longer holds the pane: the dialog is confirmed"
                   exit 0 ;;
        *) die "unknown option: $1 (see: salamander revive --help)" ;;
    esac
    shift
done

# a direct revive (not recycle's own sweep, not a worker) is a fleet operation: queued, never run raw, when a session calls it
# (--cwd asks it whatever the environment says: no recycle or retry worker ever carries the flag)
if [ -n "$RELAUNCH_CWD" ] || { [ -z "${SALA_RECYCLE:-}" ] && [ "$SELF_WORKER" = 0 ] && [ -z "${SALA_RETRY_WORKER:-}" ]; }; then
    ops_guard revive "${ONLY_LIST[0]:-all}" $([ "$DRY" = 1 ] && echo --dry-run)
fi
# the rescue names its panes (the header): a sweep of every pane with it is a recycle in all but name
[ "$RESCUE" = 1 ] && [ ${#ONLY_LIST[@]} -eq 0 ] && [ "$SELF_WORKER" = 0 ] && die "--rescue needs --only <session> (or --self): it confirms the exit dialog of the named panes only"
CWD_MISSING=""
for s in ${ONLY_LIST[@]+"${ONLY_LIST[@]}"}; do
    if ! tmux has-session -t "=$s" 2>/dev/null; then
        [ -n "$RELAUNCH_CWD" ] || die "no tmux session '$s'"
        CWD_MISSING=1   # created in the folder further down, as restore creates one in its row's
    fi
    [ -z "$RELAUNCH_CWD" ] || ! is_sleeping "$s" || die "$(no_relaunch_line "$s") — --only refused; wake it there instead: salamander wake --only $s --cwd $(cwd_quote "$RELAUNCH_CWD")"
    # managed outside sala (common.sh, no_relaunch): `--only` names it, so it refuses outright rather than sweeping nothing
    no_relaunch "$s" && die "$(no_relaunch_line "$s") — --only refused; $(no_relaunch_fix "$s" "relaunch it the way it was launched, or take it out of SALA_NO_RELAUNCH")"
done
# a NEW recycle stops the previous one's retry worker; never the self-worker, which runs after its own recycle's sweep
# and inherits SALA_RECYCLE (it killed the worker its own sweep had started a second before, so a skipped
# pane was never retried — the board's main session waited 25 min after the 03:17 recycle). Never a dry run (Wed Oct 14th 2026:
# `recycle --dry-run` stopped a live recycle's worker and cleared its waiting flags).
if [ "$DRY" = 0 ] && [ -n "${SALA_RECYCLE:-}" ] && [ -z "${SALA_RETRY_WORKER:-}" ] && [ "$SELF_WORKER" = 0 ]; then
    waiting_clear_all   # their relaunch-waiting flags go first, so a stopped worker ends no hold: this sweep covers every pane and raises its own
    for f in "$SALA_LOG_DIR"/salamander-retry*.pid; do
        [ -s "$f" ] || continue
        rp=$(cat "$f"); kill -0 "$rp" 2>/dev/null && { echo "stopping an earlier retry worker (pid $rp)"; kill "$rp" 2>/dev/null; }; rm -f "$f"
    done
fi
CURRENT_BIN=$(readlink -f "$SALA_CLAUDE" 2>/dev/null)
[ -n "$CURRENT_BIN" ] && [ -x "$CURRENT_BIN" ] || die "claude launcher not found at $SALA_CLAUDE"
CURRENT_VER=${CURRENT_BIN##*/}
# --cwd: the one target has a row to carry the folder; a missing tmux session is created in it, and the sweep below resumes the row's conversation
if [ -n "$RELAUNCH_CWD" ]; then
    s=${ONLY_LIST[0]}
    [ "$s" != "$SALA_RC_SESSION" ] || die "--cwd: $s is the Remote Control server, not a conversation with a folder of its own"
    row=$(ledger_row "$s")
    [ -n "$row" ] || die "--cwd: $s is not in the pane map, so no row can carry the folder (salamander adopt $s registers a live session) — nothing relaunched"
    old=$(cut -f4 <<< "$row"); CWD_PLAN="in $RELAUNCH_CWD · pane-map folder ${old:-none} → $RELAUNCH_CWD"
    if [ -n "$CWD_MISSING" ]; then
        uuid=$(cut -f2 <<< "$row")
        [ -n "$uuid" ] || die "--cwd: $s: its pane-map row has no conversation id"
        if live=$(live_pane_for_uuid "$uuid"); then die "$s: its conversation is live already (pid ${live%% *} in ${live#* }); a conversation is never resumed twice — nothing created, nothing written"; fi
        tmux_server_up || die "no tmux server running — start it first (systemctl --user start tmux.service); nothing created, nothing written"
        if [ "$DRY" = 1 ]; then
            lane_plan "$s" ""
            echo "[dry-run] $s: no tmux session — would create it and resume $uuid on $CURRENT_VER · $LANE_LINE · $CWD_PLAN"
            echo "[dry-run] nothing created, nothing written"; exit 0
        fi
        tmux new-session -d -s "$s" -c "$RELAUNCH_CWD" || die "$s: tmux new-session failed"
        # the new shell's startup files may still be running a child, which the shell-pane gate below reads as busy
        _nap 0.5; pp=$(tmux display -p -t "$(tmux_win_t "$s")" '#{pane_pid}' 2>/dev/null)
        for ((i=0; i<50; i++)); do [ -n "$(pgrep -P "$pp" 2>/dev/null)" ] || break; _nap 0.2; done
    fi
fi
tmux_server_up || { echo "no tmux server running; nothing to revive"; exit 0; }
LATEST_SAVE=$(ls -t "$SALA_RESURRECT_DIR"/tmux_resurrect_*.txt 2>/dev/null | head -1)

ANCESTORS=""; p=$$
while [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "1" ]; do ANCESTORS="$ANCESTORS $p"; p=$(proc_ppid "$p"); done
is_ancestor() { case " $ANCESTORS " in *" $1 "*) return 0;; *) return 1;; esac; }

# ordered_panes — LEAST-recently-active first, so the pane the user is most likely to return to
# is disturbed last — and so claude.ai's session list comes back in its own order: it sorts by each session's
# `last_event_at`, newest on top, and a relaunch (resume + bridge reattach) is itself an event, so sessions relaunched
# oldest-first re-stack exactly as they were (verified on a recycle: the sessions were re-stamped
# in sweep order). Key = claude.ai's `last_event_at` for the pane's bridged session (the sessions
# API, read-only); transcript mtime when the API or the bridge id is unavailable (registry statusUpdatedAt resets on
# every relaunch, so it is never the key).
ordered_panes() {
    tmux list-panes -a -F '#{pane_id}|#{session_name}|#{window_index}|#{pane_title}|#{pane_current_command}|#{pane_pid}|#{pane_current_path}' \
    | REG="$SALA_REG_DIR" SIDE="$SALA_SIDECAR" PROJ="$SALA_PROJECTS" python3 -c '
import sys, os, json, glob
reg = {}
for f in glob.glob(os.path.join(os.environ["REG"], "*.json")):
    try: d = json.load(open(f, encoding="utf-8")); reg[str(d.get("pid"))] = d
    except Exception: pass
import subprocess
kids = {}
for line in subprocess.run(["ps","-axo","pid=,ppid="],capture_output=True,text=True).stdout.splitlines():
    f = line.split()
    if len(f) == 2: kids.setdefault(f[1], []).append(f[0])
def descendants(root):
    out, stack = [], [root]
    while stack:
        x = stack.pop(); out.append(x); stack.extend(kids.get(x, []))
    return out
side = {}
try:
    for line in open(os.environ["SIDE"]):
        c = line.rstrip("\n").split("\t")
        if len(c) >= 2: side[c[0]] = c[1]
except Exception: pass
# claude.ai last_event_at per bridged session (cse_… = session_…); empty on any failure → transcript mtime
cloud = {}
try:
    import datetime
    if os.environ.get("SALA_CLOUD_SESSIONS_FILE"):   # the sessions API answer from a file (the tests; no network, no token)
        d = json.load(open(os.environ["SALA_CLOUD_SESSIONS_FILE"], encoding="utf-8"))
    else:
        import urllib.request
        tok = json.load(open(os.path.expanduser("~/.claude/.credentials.json")))["claudeAiOauth"]["accessToken"]
        H = {"Authorization": "Bearer " + tok, "anthropic-version": "2023-06-01", "anthropic-client-platform": "cli"}
        d = json.load(urllib.request.urlopen(urllib.request.Request("https://api.anthropic.com/v1/code/sessions?limit=100", headers=H), timeout=10))
    for x in d.get("data", []):
        t = x.get("last_event_at")
        if x.get("id") and t:
            cloud[x["id"].split("_", 1)[1]] = int(datetime.datetime.fromisoformat(t.replace("Z", "+00:00")).timestamp())
except Exception:
    cloud = {}
import re
# The bridge id is read from the END of the transcript, a piece at a time: the last record is almost always in the newest
# megabytes. The transcript was once read whole into one string, for every pane on every revive: a conversation of 850 MB
# took about 6 GB of memory and a host-wide out-of-memory stop followed. Memory is one piece (BR_CHUNK) whatever the size; a
# transcript whose last bridge record is further from the end than SALA_BRIDGE_SCAN_MAX bytes (64 MiB) has none for this purpose and
# falls back to its mtime, like a pane with no bridge at all.
BR = re.compile(rb"\"type\":\"remote_session_change\",\"url\":\"https://claude\.ai/code/(?:session|cse)_([A-Za-z0-9]+)")
BR_CHUNK, BR_OVER = 4 << 20, 4096   # BR_OVER: a record cut by a piece boundary is whole in the piece before it
BR_MAX = int(os.environ.get("SALA_BRIDGE_SCAN_MAX") or 64 << 20)
def last_bridge(path):  # the last remote_session_change in one transcript → its claude.ai id (no prefix), or ""
    with open(path, "rb") as f:
        f.seek(0, 2); size = f.tell(); end = size; floor = max(0, size - BR_MAX)
        while end > floor:
            start = max(floor, end - BR_CHUNK)
            f.seek(start); found = BR.findall(f.read(min(end + BR_OVER, size) - start))
            if found: return found[-1].decode("ascii", "replace")
            end = start
    return ""
def bridge_of(uuid, hits):  # the last remote_session_change in the conversation → its claude.ai id, no prefix
    if not cloud: return ""
    last = ""
    try:
        for h in hits: last = last_bridge(h) or last
    except Exception: pass
    return last
rows = []
for i, line in enumerate(sys.stdin):
    line = line.rstrip("\n")
    if not line: continue
    f = line.split("|"); sess, ppid = f[1], f[5]
    uuid = ""
    for pid in descendants(ppid):
        d = reg.get(pid)
        if d and d.get("tmux"):
            uuid = d.get("sessionId", "")
            pj = d.get("parkedJobId")   # parked on a background job: the conversation of the job row is the live one
            if pj:
                for j in reg.values():
                    if j is not d and (j.get("jobId") == pj or j.get("sessionId") == pj):
                        uuid = j.get("sessionId") or uuid; break
            break
    uuid = uuid or side.get(sess, "")
    key = 0
    if uuid:
        hits = glob.glob(os.path.join(os.environ["PROJ"], "*", uuid + ".jsonl"))
        if hits:
            key = int(max(os.path.getmtime(h) for h in hits))
            br = bridge_of(uuid, hits)
            if br and br in cloud: key = cloud[br]
    rows.append((key, i, line))
for _, _, line in sorted(rows): print(line)
'
}

strip_marker() { echo "$1" | sed 's/^[^[:alnum:]]*[[:space:]]//'; }
uuid_for_title() {  # FALLBACK only: title → transcript grep; multiple hits → newest
    local title="$1" cwd="$2" proj hits
    [ -n "$title" ] || return 1
    proj="$SALA_PROJECTS/$(slug_for_cwd "$cwd")"; [ -d "$proj" ] || return 1
    hits=$(grep -l -F "\"$title\"" "$proj"/*.jsonl 2>/dev/null); [ -z "$hits" ] && return 1
    if [ "$(echo "$hits" | wc -l)" -gt 1 ]; then
        echo "  ⚠ title \"$title\" matched multiple transcripts; using newest (title fallback is unreliable — sidecar missing?)" >&2
        hits=$(ls -t $hits | head -1)
    fi
    basename "$hits" .jsonl
}
saved_title_for_session() { [ -n "$LATEST_SAVE" ] && awk -F'\t' -v s="$1" '$1=="pane" && $2==s {print $7; exit}' "$LATEST_SAVE"; }
saved_ran_claude() { [ -n "$LATEST_SAVE" ] && awk -F'\t' -v s="$1" '$1=="pane" && $2==s {print $NF; exit}' "$LATEST_SAVE" | grep -q '^:claude'; }
uuid_for_live_pane() {  # <claude-pid> <title> <cwd> → registry first, title fallback
    local u; registry_conv_r u "$1"; [ -n "$u" ] && { echo "$u"; return 0; }
    uuid_for_title "$(strip_marker "$2")" "$3"
}
dedupe_ok() {  # <uuid> <label> → fails (and records) if the uuid is live elsewhere
    local live; live=$(live_pane_for_uuid "$1") || return 0
    SKIPPED+=("$2: conversation $1 is ALREADY LIVE (pid ${live%% *} in ${live#* }) — refusing duplicate resume"); return 1
}
# resume_cmd <uuid>: lib/common.sh (the line carries the mod)

: "${SALA_RC_SERVED_WAIT:=120}"
# served_back <served TSV> <array> — wait for each served session to be live again on CURRENT_VER; one row each
served_back() {
    local want="$1" arr="$2" sid st web sver first now i left row
    [ -n "$want" ] || return 0
    for ((i=0; i<SALA_RC_SERVED_WAIT; i+=5)); do
        now=$(rc_served 2>/dev/null); left=0
        while IFS=$'\t' read -r sid st web sver first; do
            [ -n "$sid" ] || continue
            printf '%s\n' "$now" | awk -F'\t' -v s="$sid" -v v="$CURRENT_VER" '$1==s && $4==v {f=1} END {exit !f}' || left=1
        done <<< "$want"
        [ "$left" = 0 ] && break; sleep 5
    done
    while IFS=$'\t' read -r sid st web sver first; do
        [ -n "$sid" ] || continue
        if printf '%s\n' "$now" | awk -F'\t' -v s="$sid" -v v="$CURRENT_VER" '$1==s && $4==v {f=1} END {exit !f}'; then
            row="$label ⤷ served \"$first\" ($web): back on $CURRENT_VER, same conversation"
            if [ "$arr" = UPDATED ]; then UPDATED+=("$row"); else REVIVED+=("$row"); fi
        else
            SKIPPED+=("$label ⤷ served \"$first\" ($web): not back on $CURRENT_VER within ${SALA_RC_SERVED_WAIT}s — open it on claude.ai (a message re-dispatches it), or promote it: salamander spawn <name> --fork $sid")
        fi
    done <<< "$want"
    rc_served_snapshot
}
REVIVED=(); UPDATED=(); OK=(); SKIPPED=(); RETRY=()
skip() { SKIPPED+=("$1"); transient_skip "$1" && RETRY+=("$pane|$sess|$label|${cpid:-}"); return 0; }

if [ "$SELF_WORKER" = 1 ]; then
    [ "$DRY" = 1 ] || echo "[$(date -Is)] self-worker: waiting for pane $SELF_PANE to go idle"
    pane_exists() { tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qxF "$1"; }
    # every abort here is unattended: say it out loud, never only in the log (a background watch-loop in the invoking pane
    # once held it "busy" for a long time and nothing said so)
    label=$(tmux display -p -t "$SELF_PANE" '#{session_name}' 2>/dev/null); label=${label:-$SELF_PANE}
    # under a recycle driver the invoking pane is one outstanding pane of the set, settled like any other: relaunched, a
    # closure; failed, a give-up (towards "closed at n/N"); handed to a retry worker, nothing more until that worker settles
    # it. When a pane besides it was left behind, the sweep's first post already listed it as "not relaunched yet";
    # when it is the only one outstanding, a clean recycle stays one post: the self-worker makes the set's
    # first post here, after settling it — "✅ *Recycle done*", "closed at n/N", or "· n/N relaunched" with its reason and
    # the retry note. Alone (`revive --self`) it posts for itself.
    DSET=""; set_has "${SALA_SET:-}" && _set_out "$SALA_SET" "$label" && DSET="$SALA_SET"
    wabort() {
        # the hold is the uuid's; a pane with no registry name has an empty hname and its hold is still released (Fri Oct 30th 2026)
        if [ -n "${uuid:-}" ]; then inbox_release "$uuid" "${hname:-}"; fi; echo "[$(date -Is)] self-worker: $1"
        if [ -n "$DSET" ]; then set_resolve "$DSET" gave "$label" "$label: $1"; set_report "$DSET"
        else sala_post "🚨 *Recycle didn't finish for $label*" "$1" "Details: ~/.claude/salamander-revive.log"; fi
        local hu="${uuid:-}"; [ -n "$hu" ] || [ -z "${cpid:-}" ] || registry_conv_r hu "$cpid"
        hold_ended "$hu" ended "$1"   # silent when the pane's claude is gone (common.sh)
        exit 1
    }
    pane_exists "$SELF_PANE" || wabort "pane $SELF_PANE not found"
    cpid=$(claude_pid_under "$(tmux display -p -t "$SELF_PANE" '#{pane_pid}')")
    # the lane line (the header, THE LANE LINE), before the wait: a refusal here is the pane given up in its set, or alone its own
    # post, never a silent skip. On a dry run (recycle's driver) the plan is said and nothing waited for or typed.
    if [ "$DRY" = 1 ]; then
        lane_plan "$label" "$cpid" || { echo "[$(date -Is)] self-worker: [dry-run] $label would be refused — $LANE_WHY ($LANE_LINE)"; exit 1; }
        if [ -n "$cpid" ]; then echo "[$(date -Is)] self-worker: [dry-run] $label: would wait for pane $SELF_PANE to go idle, then /exit ($(proc_version "$cpid")) and resume $(registry_field "$cpid" sessionId) on $CURRENT_VER · $LANE_LINE — nothing waited for, nothing typed"
        else echo "[$(date -Is)] self-worker: [dry-run] $label: no claude runs in pane $SELF_PANE — nothing to relaunch · $LANE_LINE"; fi
        exit 0
    fi
    lane_plan "$label" "$cpid" || wabort "not relaunched — $LANE_WHY ($LANE_LINE)"
    # the pane cannot be relaunched now ($1 says why): the retry worker takes it (the first wait and the re-check after the hold both end here)
    self_handoff() {
        local why="$1" sess rnote hb
        sess=$(tmux display -p -t "$SELF_PANE" '#{session_name}' 2>/dev/null)
        echo "[$(date -Is)] self-worker: not relaunchable within ${SELF_WAIT_WORDS} ($why) — handing to the retry worker"
        rnote="sala retries $label every $((SALA_RETRY_EVERY/60)) min for up to $(dur_words "$SALA_RETRY_WINDOW") and says when it is back"
        hb=$(hold_bullet "$label" "$cpid" "$why") || hb="$label: $why"   # the one short form for a held pane (common.sh, hold_bullet); $why stays in the log above
        if [ -n "$DSET" ]; then echo "[$(date -Is)] self-worker: $rnote (set $DSET)"; set_left "$DSET" "$hb" "$rnote"; set_report "$DSET"   # still outstanding; the first post, if it is not out yet
        else   # `revive --self` alone: a Revive set of one, the post now
            DSET="$(date +%s)-$$"; set_create "$DSET" Revive "only.$label" 1 0 "$CURRENT_VER" 1 "out=$label" "why=$(relaunch_kind)" "src=revive" "fscope=$label"; set_point "only.$label" "$DSET"
            sala_post "⏳ *Revive $(set_val "$DSET" label) · 0/1 relaunched*" "$hb" "$rnote"
        fi
        # detached, not exec'd: the driver waits on this pid, and an exec'd worker would keep the recycle lock for its whole 2 h
        # window. Its own pid file, the same set as the driver's worker: the two coexist (this one's start once
        # stopped the driver's worker)
        SALA_SET="$DSET" SALA_NO_PAUSE_PANE="$SELF_PANE" setsid "$SALA_BIN" revive --retry-worker --force -- "$SELF_PANE|$sess|$label|$cpid" </dev/null >>"$LOG" 2>&1 9>&- &
        [ -n "${SALA_RECYCLE_SKIPPED_FILE:-}" ] && [ -n "$sess" ] && echo "$sess" >> "$SALA_RECYCLE_SKIPPED_FILE"   # not relaunched by this recycle
        exit 0
    }
    SELF_WAIT_WORDS="$((SALA_SELF_WAIT/60)) min"
    idle=0; t=""; drained=-1000; why=""
    for ((i=0; i<SALA_SELF_WAIT; i++)); do
        pane_exists "$SELF_PANE" || wabort "pane $SELF_PANE disappeared while waiting"
        t=$(tmux display -p -t "$SELF_PANE" '#{pane_title}' 2>/dev/null)
        why=$(is_idle_reason "$cpid")
        if [ -z "$why" ]; then
            # drain ONCE per idle stretch (re-arm after 5 min), never on every tick: each drain types
            # /feedback into the pane, and a per-second drain once filled a session with them
            if [ $((i - drained)) -ge 300 ]; then send_feedback_drafts "$SELF_PANE"; drained=$i; fi
            if pane_prompt "$SELF_PANE"; then why="a terminal prompt is showing"
            elif d=$(pane_draft "$SELF_PANE" "$cpid") && [ -n "$d" ]; then why="unsubmitted text is sitting at the prompt: \"$d\""
            else idle=1; break; fi
        fi
        [ $((i % 120)) -eq 0 ] && echo "[$(date -Is)] self-worker: waiting — $why"
        sleep 1
    done
    [ "$idle" = 1 ] || self_handoff "$why"
    cwd=$(tmux display -p -t "$SELF_PANE" '#{pane_current_path}')
    uuid=$(uuid_for_live_pane "$cpid" "$t" "$cwd")
    [ -z "$uuid" ] && wabort "no registry entry or transcript match for the pane (title \"$t\")"
    hname=$(registry_field "$cpid" name); inbox_hold "$uuid" "$hname"   # stackshot's lines wait out the relaunch (a dead worker's hold: watch drops it after 10 min)
    _nap "$SALA_HOLD_SETTLE"   # held BEFORE the pause, as the sweep holds before its first /exit: a line handed out just before the hold is a turn by now, and pane_exit's mod refuses it (rc 4, waited out below)
    waiting_clear "$uuid"   # a flag a retry worker raised for this pane comes down with the relaunch
    # the re-check of close_pane (Fri Oct 30th 2026), waited out here as the turn below is: a pane that is not idle once its inbox is held
    # The waits stack: up to SALA_SELF_WAIT for the first idle, again here, and again for a turn pane_exit's mod refuses (rc 4, below),
    # so a pane that keeps being busy is held for up to three times SALA_SELF_WAIT; the hold's ledger row is written again every minute
    # so watch's 10-minute stale drop (inbox_release_stale) never takes it from a pane still waiting. A pane still busy at the end of
    # this wait is released and handed to the retry worker, as at the first wait, not given up.
    for ((i=0; i<SALA_SELF_WAIT; i+=5)); do
        why=$(is_idle_reason "$cpid"); [ -z "$why" ] && break
        [ $((i % 60)) -eq 0 ] && inbox_touch "$uuid" "$hname"
        sleep 5
    done
    why=$(is_idle_reason "$cpid")   # the loop ends on a sleep: one last look, so a pane that went idle in its final seconds is not handed off
    if [ -n "$why" ]; then inbox_release "$uuid" "$hname"; self_handoff "$why — it was not idle once its inbox was held"; fi
    draft=$(pane_exit "$SELF_PANE" "$cpid"); rc=$?   # the mod first, else /exit typed (lib/common.sh)
    for ((i=0; rc==4 && i<SALA_SELF_WAIT; i+=5)); do [ $((i % 60)) -eq 0 ] && inbox_touch "$uuid" "$hname"; sleep 5; draft=$(pane_exit "$SELF_PANE" "$cpid"); rc=$?; done   # a turn started after the idle check: wait it out
    [ "$rc" = 4 ] && wabort "a turn is still running after $((SALA_SELF_WAIT/60)) min${draft:+ (held by $draft)} — /exit not sent, the session stays on its version"
    [ "$rc" = 2 ] && wabort "background work is running (${draft:-a shell, monitor or subagent}), which /exit would stop — /exit not sent, the session stays on its version"
    [ "$rc" = 3 ] && wabort "unsubmitted text is sitting at the prompt: \"$draft\" — /exit not sent, the session stays on its version"
    [ "$rc" = 0 ] || wabort "the pane did not take /exit (composer not empty, or the Enter was dropped twice)"
    RESCUE_NOTE=""; DRAFTS_NOTE=""; exit_wait "$SELF_PANE" "$SALA_EXIT_WAIT" "$cpid"; rc=$?   # the pid: the rescue's child-process test (the header)
    [ "$rc" = 2 ] && { wabort "background work is running (a shell, monitor or subagent), which /exit would stop — /exit cancelled, the session stays on its version"; }
    [ -n "$RESCUE_NOTE" ] && echo "[$(date -Is)] self-worker: $label: rescue — $RESCUE_NOTE"
    [ -n "$DRAFTS_NOTE" ] && echo "[$(date -Is)] self-worker: $label: feedback — $DRAFTS_NOTE"
    if [ "$rc" != 0 ]; then
        # the /exit is typed and fires whenever whatever holds the pane clears; abandoning now would
        # leave an unattended exit with no resume — keep waiting so the resume follows it
        echo "[$(date -Is)] self-worker: /exit not landed after ${SALA_EXIT_WAIT}s (a prompt may hold the pane); waiting up to 15 min"
        wait_exit "$SELF_PANE" 900 || wabort "claude did not exit within 15 min — a /exit may still be queued in the pane, check it"
    fi
    why=$(resume_send "$SELF_PANE" "$uuid" "$(resume_cmd "$uuid" "$label")") || wabort "$why"   # on the session's lane (common.sh, lanes)
    resume_wait "$SELF_PANE" "$uuid" "$SALA_RESUME_WAIT"; rc=$?   # live, not merely started (once a false "Recycle done")
    [ "$rc" = 2 ] && wabort "the resume started and died within ${SALA_RESUME_WAIT}s — the pane is back at a shell, the error above its prompt; resume it with: claude --resume $uuid"
    [ "$rc" = 0 ] || wabort "resume did not start within ${SALA_RESUME_WAIT}s — the pane is at a shell; resume it with: claude --resume $uuid"
    inbox_release "$uuid" "$hname" wait
    [ -n "$DSET" ] && { set_resolve "$DSET" ok "$label" "$label relaunched on $(proc_version "$RESUMED_PID"), $(set_after "$DSET")"; set_report "$DSET"; }
    echo "[$(date -Is)] self-worker: pane $SELF_PANE relaunched on conversation $uuid → $CURRENT_VER$(lane_note "$label") · $LANE_LINE"; exit 0
fi

# ── THE SWEEP, in three phases (a 35-pane recycle took 8 min at 12–17 s a pane, nearly
# all of it waiting — tui_send's sleeps, a drain that found nothing, wait_for's 1 s polls — strictly one pane at a time).
#   1. CHECK   every gate the serial loop applied before typing /exit, for all panes IN PARALLEL: the OK/SKIPPED rows,
#              and the eligible panes in ordered_panes' order. The RC server block and a dry-run end here.
#   2. CLOSE   first the inbox of EVERY eligible claude pane is held (and SALA_HOLD_SETTLE s waited out), then the panes in
#              parallel: drain, re-check that the pane is still idle, /exit, wait for the shell, dedupe. Every skip and
#              failure releases its hold and records the SKIPPED row it always did.
#   3. RESUME  in ordered_panes' order, one every SALA_RESUME_GAP s (a fixed gap, not a wait for each bridge):
#              claude.ai sorts sessions by last event and a resume is one, so least-recent-first re-stacks the list as it
#              was; then every resume is verified in parallel (claude up within 30 s, inbox released).
# Panes are independent, so a phase's jobs are plain background subshells, at most SALA_SWEEP_JOBS at once. A subshell's
# arrays never reach the parent: each job writes its rows to a file (NUL-separated KIND, text) that the parent folds back
# in pane order, so the summary reads as before. The invoking pane (SALA_SKIP_PANE) and the self-worker are untouched:
# the invoking pane is relaunched last, after this sweep.
: "${SALA_RESUME_GAP:=1}"; : "${SALA_SWEEP_JOBS:=12}"
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/sala-revive.XXXXXX"); trap 'rm -rf "$TMPD"' EXIT
emit() { printf '%s\0%s\0' "$1" "$2" >> "$RES"; }
dump_rows() {
    local l
    for l in ${REVIVED[@]+"${REVIVED[@]}"}; do emit REVIVED "$l"; done
    for l in ${UPDATED[@]+"${UPDATED[@]}"}; do emit UPDATED "$l"; done
    for l in ${OK[@]+"${OK[@]}"}; do emit OK "$l"; done
    for l in ${SKIPPED[@]+"${SKIPPED[@]}"}; do emit SKIPPED "$l"; done
    for l in ${RETRY[@]+"${RETRY[@]}"}; do emit RETRY "$l"; done
}
fold_rows() {  # <file> — a job's rows into the summary arrays; ECHO lines printed here, in pane order; any other kind → FOUND_*
    local kind text; FOUND_KIND=""; FOUND_TEXT=""
    [ -s "$1" ] || return 0
    while IFS= read -r -d '' kind && IFS= read -r -d '' text; do
        case "$kind" in
            REVIVED) REVIVED+=("$text");; UPDATED) UPDATED+=("$text");; OK) OK+=("$text");; SKIPPED) SKIPPED+=("$text");; RETRY) RETRY+=("$text");;
            ECHO) echo "$text";;
            *) FOUND_KIND=$kind; FOUND_TEXT=$text;;
        esac
    done < "$1"
}
JOBS=()
run_job() {  # <result file> <function> [args…] — a background subshell with summary arrays of its own, SALA_SWEEP_JOBS at a time
    local res="$1"; shift
    local _rj; while _rj=($(jobs -rp)); [ "${#_rj[@]}" -ge "$SALA_SWEEP_JOBS" ]; do _nap 0.2; done   # (no wc and sleep process per poll)
    ( RES="$res"; REVIVED=(); UPDATED=(); OK=(); SKIPPED=(); RETRY=(); "$@"; dump_rows ) </dev/null &
    JOBS+=($!)
}
wait_jobs() { wait ${JOBS[@]+"${JOBS[@]}"} 2>/dev/null; JOBS=(); }   # this phase's jobs only (a bare `wait` would also wait for a detached hook)
# pause_try <pane> <sess> <label> <cpid> <why> → 0 when the pane's turn was paused just now (the caller reads the pane again: it is idle, its background
# work no longer holds it), 1 otherwise. <why> is what holds the pane (is_idle_reason's words, or the mod's), empty for a pane that is free. THE PAUSE (common.sh):
# a pane held for a turn or its background work has a clock; every pass starts or refreshes it, holds the pane's inbox while it runs (pause_hold) and
# fires it once it is SALA_PAUSE_AFTER old. The recycle's first sweep only starts it; the retry worker's passes and watch's (the deferred list) get there.
# A dry run reads the clock and writes nothing. A refusal (pause_refusal_r) leaves the pane waiting as before, said once the clock is due. An interrupt that did
# not take (the Escape did not bring the pane out of its turn, or it was not idle once interrupted) keeps the clock and is tried again after SALA_PAUSE_RETRY s
# (pause_failed), said in the line each try prints; the pane is waited for meanwhile.
pause_try() {
    local pane="$1" sess="$2" label="$3" cpid="$4" why="${5:-}" a uuid hname held ref pm
    pause_after_r a; [ "$a" -gt 0 ] || return 1
    registry_conv_r uuid "$cpid"; [ -n "$uuid" ] && [ "$uuid" != null ] || return 1
    hname=$(registry_field "$cpid" name)
    if [ -z "$why" ]; then   # free: the clock stops, and the inbox hold the wait took comes off (a sweep that goes on holds it again itself)
        pause_clock_age_r held "$uuid"
        if [ "$held" -ge 0 ] && [ "$DRY" != 1 ]; then pause_clock_clear "$uuid"; inbox_release "$uuid" "$hname" 2>/dev/null; fi
        return 1
    fi
    pause_reason_ok "$why" || return 1
    if ! pause_scope_ok "$sess"; then
        if [ "$DRY" = 1 ]; then   # the plan names the rule: a front agent is never paused unless the scope says all
            case "${SALA_PAUSE_SCOPE:-background}" in
                off|no|false|0) ref="the pause is off (SALA_PAUSE_SCOPE=off)";;
                *) ref="SALA_PAUSE_SCOPE=${SALA_PAUSE_SCOPE:-background} pauses only the back agents; a front agent is never paused and waits for its turn to end (SALA_PAUSE_SCOPE=all pauses every session)";;
            esac
            emit ECHO "[dry-run] $label: held ($why); it would not be paused: $ref"
        fi
        return 1
    fi
    if [ "$DRY" = 1 ]; then
        pause_clock_age_r held "$uuid"
        if [ "$a" -ge 60 ]; then pm="$(( a / 60 )) min"; else pm="$a s"; fi
        pause_refusal_r ref "$pane" "$sess" "$cpid"
        if [ -n "$ref" ]; then emit ECHO "[dry-run] $label: held ($why); it would not be paused: $ref"
        else emit ECHO "[dry-run] $label: held ($why); the relaunch would wait $pm$([ "$held" -gt 0 ] && echo " (it has waited $(( held / 60 )) min already)") for it, then pause its turn (one Escape), relaunch it and leave it a note saying what it was doing"; fi
        return 1
    fi
    pause_refusal_r ref "$pane" "$sess" "$cpid"
    if [ -n "$ref" ]; then pause_clock_age_r held "$uuid"; [ "$held" -lt "$a" ] || emit ECHO "$label: not paused — $ref; it is waited for as before"; return 1; fi
    pause_hold "$uuid" "$hname"
    pause_clock_r held "$uuid"
    [ "$held" -ge "$a" ] || return 1
    pause_retry_in_r ref "$uuid"; [ "$ref" -le 0 ] || return 1   # a try that did not take is tried again SALA_PAUSE_RETRY s later (common.sh, pause_failed), not at every pass
    if pause_pane "$pane" "$sess" "$cpid" "$uuid"; then
        emit ECHO "$label: paused after $(hold_age_words "$held") of holding the relaunch ($why) — its turn was interrupted with one Escape; it is relaunched next and a note leaves it what it was doing"
        set_paused "${SALA_SET:-}" "$sess: paused at $(local_clock "$PAUSE_AT") after $(hold_age_words "$PAUSE_HELD") of holding the relaunch"
        return 0
    fi
    emit ECHO "$label: not paused — $PAUSE_WHY; it is waited for as before"
    return 1
}
# check_pane <pane> <sess> <win> <title> <cmd> <panepid> <cwd> — phase 1: the per-pane gates (the serial loop's body up to the
# first keystroke, `continue` → return). A pane that passes them emits CLAUDE pane|sess|label|cpid|ver|uuid|name, or
# SHELL pane|sess|label|uuid|resume command for a post-restore shell, which only needs phase 3.
check_pane() {
    local pane="$1" sess="$2" win="$3" title="$4" cmd="$5" panepid="$6" cwd="$7" label="$2:$3" cpid="" ver uuid why mh draft served spid busy out sid st web sver first rest
    if [ "$sess" = "$SALA_RC_SESSION" ]; then
        if [ -e "$SALA_LOG_DIR/salamander-rc.stopped" ]; then   # stopped or retired (on the coordinator machine): a server someone
            OK+=("$label: Remote Control server stopped (sala rc --start resumes it) — left alone"); return   # runs by hand is theirs
        fi
        # Remote Control server pane: up → restart on version change (its loop relaunches on the current binary and the
        # server re-dispatches its served sessions itself: same conversation, same claude.ai id); down → start it.
        # SERVED SESSIONS (a recycle covers them too) are rows of their own:
        # a restart is held while any of them is mid-turn (it would cut the turn; transient → retried), and after it
        # each one must be back on the new binary within SALA_RC_SERVED_WAIT s, or the summary says which is not.
        served=$(rc_served 2>/dev/null); cpid=""
        if spid=$(rc_server_pid_under "$panepid"); then
            cpid=$spid; ver=$(proc_version "$spid")
            if [ "$ver" = "$CURRENT_VER" ] && [ "$FORCE" = 0 ]; then
                OK+=("$label: Remote Control server, already $CURRENT_VER")
                while IFS=$'\t' read -r sid st web sver first; do [ -n "$sid" ] && OK+=("$label ⤷ served \"$first\" ($web): $st, $sver"); done <<< "$served"
                return
            fi
            busy=$(printf '%s\n' "$served" | awk -F'\t' '$1!="" && $2!="idle" {printf "\"%s\" (%s); ", $5, $2}')
            if [ -n "$busy" ]; then skip "$label: served session(s) not idle — ${busy%; } — a restart would cut the turn; registry says busy"; return; fi
            if [ "$DRY" = 1 ]; then emit ECHO "[dry-run] $label: would restart the Remote Control server ($ver → $CURRENT_VER) and wait for $(printf '%s\n' "$served" | grep -c .) served session(s)"; return; fi
            [ -n "$served" ] && printf '%s\n' "$served" > "$SALA_RC_SERVED"
            if out=$("$SALA_BIN" rc --restart 2>&1); then UPDATED+=("$label: $out"); served_back "$served" UPDATED
            else SKIPPED+=("$label: Remote Control server restart failed — $out"); fi
        else
            if [ "$DRY" = 1 ]; then emit ECHO "[dry-run] $label: Remote Control server is down — would start it"; return; fi
            if out=$("$SALA_BIN" rc --ensure 2>&1); then REVIVED+=("$label: $out"); served_back "$(cat "$SALA_RC_SERVED" 2>/dev/null)" REVIVED
            else SKIPPED+=("$label: Remote Control server did not start — $out"); fi
        fi
        return
    fi
    # THE SDK LANE'S PANE (common.sh "lanes", lib/sdk-pane.sh): its foreground program reads `sala-sdk` (the
    # wrapper, renamed so no reader takes it for a shell), and the claude under it is the SDK's CLI, registered as any
    # pane's: swept as a claude pane — the same idle gates, /exit typed into the wrapper's box, resume_cmd's own line.
    case "$cmd" in
        claude|bash|sh|zsh|fish) ;;
        *) cpid=$(claude_pid_under "$panepid" 2>/dev/null) && [ "$(proc_lane "$cpid")" = sdk ] && cmd=claude ;;
    esac
    case "$cmd" in
    claude)
        cpid=$(claude_pid_under "$panepid")
        [ -z "$cpid" ] && { SKIPPED+=("$label: claude pane but pid not found"); return; }
        is_rc_server "$cpid" && { SKIPPED+=("$label: a Remote Control server outside $SALA_RC_SESSION — left alone (use: salamander rc)"); return; }
        ver=$(proc_version "$cpid")
        # the pane this command runs in is never relaunched by its own sweep (Wed Oct 14th 2026, a coordinating session: `revive --force
        # --only <own session>` answered "own session, already current", which read as done): with --force or on an older CLI
        # it is a skip that says so and names the way, `salamander revive --self`
        if is_ancestor "$cpid"; then
            if [ "$ver" != "$CURRENT_VER" ]; then SKIPPED+=("$label: this command's own session (on $ver) — not relaunched: a sweep never relaunches the pane it runs in; to relaunch it: salamander revive --self")
            elif [ "$FORCE" = 1 ]; then SKIPPED+=("$label: this command's own session (already $CURRENT_VER) — not relaunched: a sweep never relaunches the pane it runs in, --force or not; to relaunch it: salamander revive --self")
            else OK+=("$label: own session, already $CURRENT_VER — not relaunched by a sweep (salamander revive --self does that)"); fi
            return
        fi
        if [ "$ver" = "$CURRENT_VER" ] && [ "$FORCE" = 0 ]; then OK+=("$label: already $CURRENT_VER"); return; fi
        # THE REST: a pane relaunched less than SALA_RECYCLE_REST ago waits its time out for a routine flag
        if rest_applies && rest=$(recycle_rest_left "$cpid") && [ -n "$rest" ]; then
            skip "$label: relaunched only $(( (SALA_RECYCLE_REST - rest) / 60 )) min ago (on $ver) — resting until $(local_clock $(( $(date +%s) + rest ))); sala relaunches it then (SALA_RECYCLE_REST $(dur_words "$SALA_RECYCLE_REST"))"; return
        fi
        # the lane line (the header, THE LANE LINE): a mismatch with no row refuses this pane, dry run and real alike
        lane_plan "$sess" "$cpid" || { SKIPPED+=("$label: not relaunched — $LANE_WHY ($LANE_LINE)"); return; }
        why=$(is_idle_reason "$cpid"); mh=""
        [ -n "$why" ] || { mh=$(mod_hold "$cpid") || mh=""; }
        # THE PAUSE (common.sh): a pane held by its turn or its background work has a clock; one that has held the relaunch SALA_PAUSE_AFTER seconds is paused
        # here (one Escape, a note for the session), and the checks below then read it again, now out of its turn
        if pause_try "$pane" "$sess" "$label" "$cpid" "${why:-$mh}"; then
            why=$(is_idle_reason "$cpid"); mh=""
            [ -n "$why" ] || { mh=$(mod_hold "$cpid") || mh=""; }
        fi
        [ -n "$why" ] && { skip "$label: $why"; return; }
        # the in-session mod's own answer, asked before the exit is: a turn it names (a subagent the registry, the children and the transcripts
        # could not show) or the background work it lists (a shell, a monitor, a subagent: "4 subagents, 6 monitors and 1 shell are in flight")
        # holds the pane, said once here with its holder, and the pane's inbox is never held and released for an exit that is refused.
        # Only a turn is counted in the refusal memory (it thins out the tries of a mod whose turn list is stale); work in flight is not
        if [ -n "$mh" ]; then why=$mh; case "$why" in "a turn is running"*) refusal_note "$(registry_field "$cpid" sessionId)" "$why" >/dev/null;; esac; skip "$label: $why — left on $ver"; return; fi
        # the rescue passed over the Stop hook's record (common.sh, is_idle_reason): said here, so the log shows what was read as stale
        if [ "$RESCUE" = 1 ] && why=$(busy_state "$cpid" "$(registry_field "$cpid" sessionId)" 2>/dev/null) && [ -n "$why" ]; then
            emit ECHO "$label: rescue — $why; no child process runs under the claude, so the record is read as stale and passed over (--rescue)"
        fi
        uuid=$(uuid_for_live_pane "$cpid" "$title" "$cwd")
        [ -z "$uuid" ] && { SKIPPED+=("$label: no registry entry and no transcript matches title \"$(strip_marker "$title")\""); return; }
        draft=$(pane_draft "$pane" "$cpid")
        [ -n "$draft" ] && { skip "$label: unsubmitted text at the prompt (\"$draft\") — typing /exit would append to it and send the lot; submit or clear it, then rerun"; return; }
        if [ "$DRY" = 1 ]; then emit ECHO "[dry-run] $label: would /exit ($ver) and resume $uuid on $CURRENT_VER · $LANE_LINE${RELAUNCH_CWD:+ · $CWD_PLAN}$([ "${SALA_EXIT_END:-1}" = 1 ] && echo " · a claude still running ${SALA_EXIT_WAIT}s after /exit: will end a stuck process (that one pid: TERM, then KILL after ${SALA_EXIT_TERM_WAIT}s) and resume the session")"; emit WOULD ""; return; fi
        emit CLAUDE "$pane|$sess|$label|$cpid|$ver|$uuid|$LANE_LINE|$(registry_field "$cpid" name)"   # the lane line is said when the /exit is typed (phase 2)
        ;;
    bash|sh|zsh|fish)
        # a sleeping pane never gets here (phase 1 lists it as `sleeping` first); the guard keeps it from being resumed if a caller ever does
        is_sleeping "$sess" && return 0
        uuid=$(sidecar_uuid_for_session "$sess")
        if [ -z "$uuid" ]; then
            saved_ran_claude "$sess" || { SKIPPED+=("$label: shell pane, not a claude session (done with it? sala close-shell $sess)"); return; }
            uuid=$(uuid_for_title "$(strip_marker "$(saved_title_for_session "$sess")")" "$cwd")
            [ -z "$uuid" ] && { SKIPPED+=("$label: shell pane, no sidecar entry and no transcript matches saved title"); return; }
        fi
        [ -n "$(pgrep -P "$panepid" 2>/dev/null)" ] && { SKIPPED+=("$label: shell busy with a child process"); return; }
        lane_plan "$sess" ""   # a shell runs on no lane: never refused, the line still said
        if [ "$DRY" = 1 ]; then emit ECHO "[dry-run] $label: would resume $uuid on $CURRENT_VER (post-restore shell) · $LANE_LINE${RELAUNCH_CWD:+ · $CWD_PLAN}"; emit WOULD ""; return; fi
        dedupe_ok "$uuid" "$label" || return 0
        emit SHELL "$pane|$sess|$label|$uuid|$LANE_LINE|$(resume_cmd "$uuid" "$sess")"   # on the session's lane (common.sh, lanes); the resume line last: it may hold any character
        ;;
    *) SKIPPED+=("$label: running '$cmd' — left alone") ;;
    esac
}
# close_pane <pane> <sess> <label> <cpid> <ver> <uuid> <name> — phase 2: drain, re-check, /exit, wait for the shell, dedupe;
# emits CLOSED …|resume command. The pane's inbox was held with every other pane's before any /exit was typed (phase 2 below), so
# every skip and failure here RELEASES the hold and records the row the serial loop recorded; the hold of a pane that is closed
# is released after its resume (verify_pane).
close_pane() {
    local pane="$1" sess="$2" label="$3" cpid="$4" ver="$5" uuid="$6" hname="$7" rc draft jpid why
    # a draft the drain cannot send holds nothing up: it stays queued on disk through the relaunch, and exit_wait passes the gate (lib/feedback.sh)
    unmode "$pane"; send_feedback_drafts "$pane" "$uuid" || emit ECHO "$label: feedback draft(s) not sent (see $SALA_LOG_DIR/salamander-feedback.log) — they stay queued through the relaunch"
    if ! prompt_clears "$pane" 10; then inbox_release "$uuid" "$hname"; SKIPPED+=("$label: a terminal prompt is showing — dismiss it (attach) and rerun"); return; fi
    # THE RE-CHECK, just before the /exit: phase 1 read the pane some seconds before its
    # inbox was held. A line the puller handed out in between has started a turn by now (or the registry's idle stamp is fresh), and an
    # /exit typed by keys would kill that turn: the mod's own turn gate is absent on that path ("exit … via keys (no stamp)"). The same
    # reading as phase 1 (is_idle_reason: registry status, the idle settle, the Stop hook's record of background work), and the same
    # outcome: a transient skip, retried later, its hold released.
    inbox_touch "$uuid" "$hname"   # a long sweep (SALA_SWEEP_JOBS panes at a time) must not age this hold past watch's 10-minute stale drop before its /exit
    why=$(is_idle_reason "$cpid")
    if [ -n "$why" ]; then inbox_release "$uuid" "$hname"; skip "$label: $why — it was not idle once its inbox was held, /exit not sent, left on $ver"; return; fi
    local parked="" named=""
    # An ordinary revive also passes --name <session> when the pane's CURRENT row carries another name that sala did not get from a hand
    # rename (a builder's conversation had stored the job's title "background-4a", so its next resume would take
    # that title again). nameSource "user" is left alone: rename-sync follows a hand rename (lib/rename.sh). Read before the pane is closed.
    local rname rsrc; registry_field_r rname "$cpid" name; registry_field_r rsrc "$cpid" nameSource
    [ -n "$rname" ] && [ "$rname" != null ] && [ "$rname" != "$sess" ] && [ "$rsrc" != user ] && named=1
    if parked_job_pid_r jpid "$cpid"; then
        parked=1; named=1
        # A PARKED PANE (common.sh parked_close): the conversation lives in the background job, idle (check phase). The job is
        # ended and the viewer left; the resume below then takes the job's conversation (uuid) into the pane as an ordinary session
        draft=$(parked_close "$pane" "$cpid" "$jpid" 2>&1); rc=$?
        case "$rc" in
            0) emit ECHO "$label: parked on background job $jpid — the job ended, its conversation $uuid resumes in the pane";;
            4) inbox_release "$uuid" "$hname"; skip "$label: the background job started a turn after the idle check — left as it is"; return;;
            *) inbox_release "$uuid" "$hname"; SKIPPED+=("$label: parked on a background job, which could not be ended — $draft"); return;;
        esac
        rc=0
    else
    # the mod first (it refuses over a draft or background work itself), else /exit typed as before (lib/common.sh pane_exit).
    # A mod that has refused this pane's exit for a turn it could not name SALA_STALE_TURN_AFTER times (the refusal memory, common.sh) is
    # no longer believed while sala's own idle check agrees the pane is idle: pane_exit then goes by keys
    local rn=""; refusal_get rn "$uuid"; rn=${rn%%$'\t'*}
    if [ "${rn:-0}" -ge "$SALA_STALE_TURN_AFTER" ] 2>/dev/null; then
        refusal_note "$uuid" "the exit went by keys after $rn refusals for a turn the mod could not name" >/dev/null   # counted, so the next try waits its gap (watch)
        draft=$(SALA_STALE_TURN_OK=1 SALA_STALE_TURN_N="$rn" pane_exit "$pane" "$cpid" 2>/dev/null); rc=$?
    else draft=$(pane_exit "$pane" "$cpid" 2>/dev/null); rc=$?; fi
    fi
    case "$rc" in
        0) ;;
        2) inbox_release "$uuid" "$hname"; SKIPPED+=("$label: background work is running (${draft:-a shell, monitor or subagent}), which /exit would stop — /exit not sent, left on $ver$([ -n "$RELAUNCH_CWD" ] || echo "; sala relaunches it once that work is done")"); return ;;
        3) inbox_release "$uuid" "$hname"; skip "$label: unsubmitted text at the prompt (\"$draft\") — /exit would run over it and lose it; submit or clear it, then rerun"; return ;;
        4) inbox_release "$uuid" "$hname"; refusal_note "$uuid" "a turn is running${draft:+: $draft}" >/dev/null
           skip "$label: a turn is running (it started after the idle check${draft:+; held by $draft}) — /exit not sent, left on $ver"; return ;;
        *) inbox_release "$uuid" "$hname"; skip "$label: the pane did not take /exit (composer not empty, or the Enter was dropped twice)"; return ;;
    esac
    ready_clear "$uuid"; waiting_clear "$uuid"   # the relaunch consumes the ready marker and takes the waiting flag down
    RESCUE_NOTE=""; PAUSE_NOTE=""; DRAFTS_NOTE=""; exit_wait "$pane" "$SALA_EXIT_WAIT" "$cpid"; rc=$?   # the pid: the rescue's child-process test (the header)
    [ "$rc" = 2 ] && { inbox_release "$uuid" "$hname"; SKIPPED+=("$label: background work is running (a shell, monitor or subagent), which /exit would stop — /exit cancelled, left on $ver$([ -n "$RELAUNCH_CWD" ] || echo "; sala relaunches it once that work is done")"); return; }
    if [ "$rc" = 1 ]; then
        # THE STUCK CLAUDE (common.sh, end_stuck_claude): the /exit was typed and the claude is still running after the wait. That one
        # process is ended by its pid (TERM, then KILL), the conversation resumes by its id below as for any pane; every gate that
        # refuses leaves the pane skipped as before, with the reason said.
        local erc=0; end_stuck_claude "$pane" "$sess" "$cpid" || erc=$?
        if [ "$erc" = 0 ]; then
            rc=0
            if [ -n "$STUCK_HOW" ]; then
                local slane; slane=$(lane_shown "$(lane_for_session "$sess")")
                emit ECHO "$label: claude (pid $cpid) was still running ${SALA_EXIT_WAIT}s after /exit — ended by its pid (SIG$STUCK_HOW); resuming $uuid on the $slane lane"
                sala_post "🛑 *Ended a Claude process that ignored /exit*" "${label%:0}: pid $cpid ended (SIG$STUCK_HOW); the session resumes on the $slane lane"
            fi
        else
            inbox_release "$uuid" "$hname"; SKIPPED+=("$label: claude didn't exit within ${SALA_EXIT_WAIT}s — a /exit may be queued behind a prompt; attach and check before rerunning (by pid: $STUCK_WHY)"); return
        fi
    fi
    [ "$rc" = 0 ] || { inbox_release "$uuid" "$hname"; SKIPPED+=("$label: claude didn't exit within ${SALA_EXIT_WAIT}s — a /exit may be queued behind a prompt; attach and check before rerunning"); return; }
    [ -n "$RESCUE_NOTE" ] && emit ECHO "$label: rescue — $RESCUE_NOTE"
    [ -n "$PAUSE_NOTE" ] && emit ECHO "$label: pause — $PAUSE_NOTE"
    [ -n "$DRAFTS_NOTE" ] && emit ECHO "$label: feedback — $DRAFTS_NOTE"
    dedupe_ok "$uuid" "$label" || { inbox_release "$uuid" "$hname"; return; }
    # a parked pane resumes with --name <session>: the job's conversation carries the job's own title, which would become the pane's registry name;
    # so does a pane whose row name differs from its session and is not a hand rename (named, above)
    emit CLOSED "$pane|$sess|$label|$cpid|$ver|$uuid|$hname|$(resume_cmd "$uuid" "$sess" ${named:+named})"   # on the session's lane (common.sh, lanes)
}
# verify_pane <claude|shell> <pane> <label> <ver> <uuid> <name> [write] — phase 3, after the resume was typed: claude live in the
# pane within 30 s (resume_wait: registered and still there, or alive at the window's end; one that came up and died is a
# skip, not an UPDATED row), then (--cwd, and only with <write>) the row's folder set to the one the caller named, and (a
# relaunched claude pane) the inbox released once the new process owns its socket
verify_pane() {
    local kind="$1" pane="$2" label="$3" ver="$4" uuid="$5" hname="$6" write="${7:-}" cwdnote="" newver rc
    resume_wait "$pane" "$uuid" "$SALA_RESUME_WAIT"; rc=$?
    if [ "$rc" != 0 ]; then
        [ "$kind" = claude ] && inbox_release "$uuid" "$hname"
        local last; pane_last_line_r last "$pane" 2; [ -z "$last" ] || last=" (last lines of the pane: \"$last\")"   # a line still at the prompt, or the error above a fresh one, says why
        if [ "$rc" = 2 ]; then SKIPPED+=("$label: the resume started and died within ${SALA_RESUME_WAIT}s — the pane is back at a shell, the error above its prompt; check manually$last")
        else SKIPPED+=("$label: resume didn't start within ${SALA_RESUME_WAIT}s — check manually$last"); fi
        return
    fi
    if [ -n "$write" ]; then   # the folder the caller named (common.sh, THE FOLDER OF A RELAUNCH), only now that the claude is up
        if ledger_cwd "${label%:*}" "$uuid" "$RELAUNCH_CWD"; then emit CWDSET ""; else emit CWDNOT ""; fi
        cwdnote=" · $CWD_SAID"
    fi
    if [ "$kind" = claude ]; then
        inbox_release "$uuid" "$hname" wait
        newver=$(proc_version "$RESUMED_PID"); refusal_clear "$uuid"   # a relaunch ends the refusal memory (common.sh)
        local pw; pw=$(pause_words "$uuid" live)   # THE PAUSE (common.sh): a pane THIS relaunch paused says so in its row; the note it was left is handed over now, not at watch's next tick
        UPDATED+=("$label: $ver → $newver$(lane_note "${label%:*}")$cwdnote${pw:+ · $pw}")   # the lane named when it is not subscription-1 (common.sh, lanes)
        pause_clock_clear "$uuid"
        # a relaunch that did not pause the pane forgets the .resumed marker an earlier relaunch left (it would read as this one's pause for 30 min)
        if [ -n "$pw" ]; then pause_resumed "$uuid"; "$SALA_BIN" note --deliver >/dev/null 2>&1 || true; else rm -f "$SALA_PAUSE_DIR/$uuid.resumed" 2>/dev/null; fi
        # a recurring job is carried across the recycle (the resume re-arms it), and the session is told once, in one line, to move it
        local rec np sock; rec=$(scheduled_jobs 0 "$uuid" | awk -F'\t' '$2=="recurring" {printf "%s (%s), ", $1, $4}')
        if [ -n "$rec" ] && np=$(claude_pid_under "$(tmux display -p -t "$pane" '#{pane_pid}')") && sock=$(session_socket "$np") && [ -n "$sock" ]; then
            session_push "$sock" "[sala] This session holds recurring scheduled job(s) ${rec%, }, carried across the recycle. A session's job dies with its conversation: move it to a systemd user timer or a scheduled task, then CronDelete it here. (Automatic salamander message, not ${SALA_OWNER_NAME}'s.)" \
                && UPDATED+=("$label ⤷ told: holds recurring job(s) ${rec%, } (rule break)")
        fi
    else REVIVED+=("$label: resumed $uuid$(lane_note "${label%:*}")$cwdnote"); fi
}

ROWS=(); NOREL=(); SLEEPING=(); while IFS= read -r line; do [ -n "$line" ] && ROWS+=("$line"); done < <(ordered_panes)
# phase 1: check
T0=$(date +%s); D1=0; D2=0; D3=0; N=0; ELIG=(); RESUMED=(); nclaude=0; nshell=0; nwould=0; CWD_END=""
for line in ${ROWS[@]+"${ROWS[@]}"}; do
    IFS='|' read -r pane sess win title cmd panepid cwd <<<"$line"; label="$sess:$win"
    [ -n "$ONLY" ] && ! only_has "$sess" && continue
    is_shell_session "$sess" && continue   # the web UI's shell drawer: a plain bash, not a Claude session and not "done with" either: no row, no skip line
    # NOT RELAUNCHED (Tue Oct 13th 2026; common.sh, no_relaunch): a SALA_NO_RELAUNCH session is excluded,
    # not skipped: its own summary row, never in SKIPPED, RETRY, the deferred list, the set's count or the skipped file
    # A SLEEPING session (common.sh, THE SLEEPING SESSIONS) is a shell with no claude on purpose: never resumed here (a wake does that), not
    # skipped-failed, not in the set's count. It has its own line in the plan and the summary, `sleeping`, apart from SALA_NO_RELAUNCH's.
    is_sleeping "$sess" && { SLEEPING+=("$(sleeping_line "$label")"); continue; }
    no_relaunch "$sess" && { NOREL+=("$(no_relaunch_line "$label")"); continue; }
    [ -n "${SALA_SKIP_PANE:-}" ] && [ "$pane" = "$SALA_SKIP_PANE" ] && { OK+=("$label: invoking pane — the driver relaunches it once idle"); continue; }
    N=$((N+1)); run_job "$TMPD/1.$N" check_pane "$pane" "$sess" "$win" "$title" "$cmd" "$panepid" "$cwd"
done
wait_jobs
for ((i=1; i<=N; i++)); do
    fold_rows "$TMPD/1.$i"
    case "$FOUND_KIND" in CLAUDE) ELIG[$i]="CLAUDE|$FOUND_TEXT"; nclaude=$((nclaude+1));; SHELL) ELIG[$i]="SHELL|$FOUND_TEXT"; nshell=$((nshell+1));; WOULD) nwould=$((nwould+1));; esac
done
if [ "$DRY" = 1 ]; then echo "[$(date -Is)] phase 1 (check): $N pane(s) → $nwould would be relaunched, ${#OK[@]} current, ${#SKIPPED[@]} skipped, in $(( $(date +%s) - T0 ))s${SLEEPING[0]:+; ${#SLEEPING[@]} sleeping}"
else D1=$(( $(date +%s) - T0 )); echo "[$(date -Is)] phase 1 (check): $N pane(s) → $nclaude claude + $nshell shell to relaunch, ${#OK[@]} current, ${#SKIPPED[@]} skipped, in ${D1}s${NOREL[0]:+; ${#NOREL[@]} not relaunched (SALA_NO_RELAUNCH)}${SLEEPING[0]:+; ${#SLEEPING[@]} sleeping}"; fi
# phase 2: close
if [ "$nclaude" -gt 0 ]; then
    T1=$(date +%s); closed=0
    # THE HOLDS FIRST (docs/stackshot-contracts.md, interface 3): every pane of the set is held
    # here, before the first /exit of the phase. Held one at a time right before its own /exit, a pane was open to stackshot's poll until
    # that second: a notice handed out and acked then was off the queue, and the /exit killed the turn that would have acted on it. A held
    # key is skipped by the poll, so no new line reaches the pane from here on; a line handed out just before this (already in the
    # pane) is a turn by the end of the settle, which close_pane's re-check reads. The holds of a pane that is skipped, deferred or
    # fails are released by close_pane on that path; a pane that is closed is released after its resume (verify_pane).
    # A sweep killed in this phase (INT, TERM, an error) releases the holds of the panes that have not exited yet: they would stay held
    # until watch's 10-minute stale drop. A pane whose claude is already gone keeps its hold, as a closed pane does (released after its
    # resume), so the exit trap composes with the cleanup of TMPD above.
    HELD_PAIRS=()
    release_unexited_holds() {
        local pr hu hn hc
        for pr in ${HELD_PAIRS[@]+"${HELD_PAIRS[@]}"}; do
            IFS='|' read -r hu hn hc <<<"$pr"
            [ -n "$hc" ] && [ -d "/proc/$hc" ] && inbox_release "$hu" "$hn"
        done
        return 0
    }
    trap 'release_unexited_holds; rm -rf "$TMPD"' EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
    nheld=0
    for ((i=1; i<=N; i++)); do
        case "${ELIG[$i]:-}" in "CLAUDE|"*) ;; *) continue;; esac
        IFS='|' read -r pane sess label cpid ver uuid lline hname <<<"${ELIG[$i]#"CLAUDE|"}"
        HELD_PAIRS+=("$uuid|$hname|$cpid"); inbox_hold "$uuid" "$hname"; nheld=$((nheld+1))
    done
    if inbox_holding; then   # the hold folder here, or the stackshot server's hold calls (SALA_INBOX_MODE); a hold the server did not answer is said on stderr by inbox_hold, and the pane goes on through close_pane's idle re-check
        echo "[$(date -Is)] phase 2 (hold): inbox held for $nheld claude pane(s) before the first /exit; settling ${SALA_HOLD_SETTLE}s"
        _nap "$SALA_HOLD_SETTLE"
    fi
    for ((i=1; i<=N; i++)); do
        case "${ELIG[$i]:-}" in "CLAUDE|"*) ;; *) continue;; esac
        IFS='|' read -r pane sess label cpid ver uuid lline hname <<<"${ELIG[$i]#"CLAUDE|"}"
        echo "$label: /exit ($ver) → resume $uuid · $lline ..."
        run_job "$TMPD/2.$i" close_pane "$pane" "$sess" "$label" "$cpid" "$ver" "$uuid" "$hname"
    done
    wait_jobs
    for ((i=1; i<=N; i++)); do
        case "${ELIG[$i]:-}" in "CLAUDE|"*) ;; *) continue;; esac
        fold_rows "$TMPD/2.$i"
        if [ "$FOUND_KIND" = CLOSED ]; then ELIG[$i]="CLOSED|$FOUND_TEXT"; closed=$((closed+1)); else ELIG[$i]=""; fi
    done
    HELD_PAIRS=(); trap - INT TERM; trap 'rm -rf "$TMPD"' EXIT   # phase 2 is over: what is still held is a closed pane's, released after its resume
    D2=$(( $(date +%s) - T1 )); echo "[$(date -Is)] phase 2 (close): $closed of $nclaude claude pane(s) at a shell in ${D2}s"
fi
# phase 3: resume, in order, a fixed gap apart; then verify in parallel
if [ $((nclaude + nshell)) -gt 0 ]; then
    T2=$(date +%s); sent=0; back0=$(( ${#UPDATED[@]} + ${#REVIVED[@]} ))
    for ((i=1; i<=N; i++)); do
        case "${ELIG[$i]:-}" in
            "CLOSED|"*) IFS='|' read -r pane sess label cpid ver uuid hname rcmd <<<"${ELIG[$i]#"CLOSED|"}"; kind=claude;;
            "SHELL|"*)  IFS='|' read -r pane sess label uuid lline rcmd <<<"${ELIG[$i]#"SHELL|"}"; ver=""; hname=""; kind=shell; echo "$label: resuming $uuid (post-restore shell) · $lline ...";;
            *) continue;;
        esac
        [ "$sent" -gt 0 ] && sleep "$SALA_RESUME_GAP"
        [ -z "$RELAUNCH_CWD" ] || rcmd="cd $(cwd_quote "$RELAUNCH_CWD") && $rcmd"   # sala puts the relaunch there; a cd that fails starts nothing
        if ! why=$(resume_send "$pane" "$uuid" "$rcmd"); then
            [ "$kind" = claude ] && inbox_release "$uuid" "$hname"
            SKIPPED+=("$label: $why"); continue
        fi
        sent=$((sent+1)); RESUMED[$i]="$kind|$pane|$label|$ver|$uuid|$hname"
    done
    # --cwd: the row takes the folder with the conversation resumed in it. A session whose panes hold two conversations has one row:
    # when more than one line was sent, only the conversation the row carries now writes
    rowuuid=""; [ -z "$RELAUNCH_CWD" ] || rowuuid=$(sidecar_uuid_for_session "${ONLY_LIST[0]}")
    for ((i=1; i<=N; i++)); do
        [ -n "${RESUMED[$i]:-}" ] || continue
        IFS='|' read -r kind pane label ver uuid hname <<<"${RESUMED[$i]}"
        write=""; if [ -n "$RELAUNCH_CWD" ] && { [ "$sent" = 1 ] || [ "$uuid" = "$rowuuid" ]; }; then write=1; fi
        run_job "$TMPD/3.$i" verify_pane "$kind" "$pane" "$label" "$ver" "$uuid" "$hname" "$write"
    done
    wait_jobs
    for ((i=1; i<=N; i++)); do
        [ -n "${RESUMED[$i]:-}" ] || continue
        fold_rows "$TMPD/3.$i"
        case "$FOUND_KIND" in CWDSET) CWD_END=set ;; CWDNOT) [ "$CWD_END" = set ] || CWD_END=unwritten ;; esac
    done
    echo "[$(date -Is)] phase 3 (resume): $sent sent ${SALA_RESUME_GAP}s apart, $(( ${#UPDATED[@]} + ${#REVIVED[@]} - back0 )) back, in $(( D3 = $(date +%s) - T2 ))s"
fi

[ "$DRY" = 1 ] || write_sidecar 2>&1 | grep "^pane map not" | sed "s/^/  ⚠ /"
if [ "$DRY" = 0 ] && [ ! -e "$SALA_LOG_DIR/salamander-rc.stopped" ] && ! tmux has-session -t "$(tmux_sess_t "$SALA_RC_SESSION")" 2>/dev/null; then   # stopped = retired (on the coordinator machine): never restarted
    if out=$("$SALA_BIN" rc --ensure 2>&1); then REVIVED+=("$SALA_RC_SESSION: $out"); else SKIPPED+=("$SALA_RC_SESSION: $out"); fi
fi
# COMPARE AND RESTORE (a missing session is recreated on its own, then reported): at the end of a recycle's sweep the roster
# frozen by the driver (common.sh, ledger_freeze) is held against tmux, and every session of it that is gone is recreated
# in its directory and resumed by uuid — one post says what came back. A session that exists but ran no claude was this
# sweep's shell-pane business already. The driver lifts the freeze after the self-worker.
if [ "$DRY" = 0 ] && [ -n "${SALA_RECYCLE:-}" ] && [ -z "$ONLY" ] && [ -z "${SALA_RETRY_WORKER:-}" ] && [ -s "$SALA_LEDGER_FROZEN" ]; then
    echo "[$(date -Is)] compare: the frozen roster ($(grep -c . "$SALA_LEDGER_FROZEN") rows) against tmux"; ledger_compare_restore Recycle
fi

echo; echo "── salamander revive (target $CURRENT_VER)"
[ ${#REVIVED[@]} -gt 0 ] && { echo "  ↺ revived (${#REVIVED[@]}):"; printf '      %s\n' "${REVIVED[@]}"; }
[ ${#UPDATED[@]} -gt 0 ] && { echo "  ↻ updated (${#UPDATED[@]}):"; printf '      %s\n' "${UPDATED[@]}"; }
[ ${#OK[@]} -gt 0 ] && { echo "  ✓ already current (${#OK[@]}):"; printf '      %s\n' "${OK[@]}"; }
[ ${#SKIPPED[@]} -gt 0 ] && { echo "  ⚠ skipped (${#SKIPPED[@]}):"; printf '      %s\n' "${SKIPPED[@]}"; }
[ ${#NOREL[@]} -gt 0 ] && { echo "  ⊘ not relaunched, managed outside sala (${#NOREL[@]}):"; printf '      %s\n' "${NOREL[@]}"; }
[ ${#SLEEPING[@]} -gt 0 ] && { echo "  ☾ sleeping (${#SLEEPING[@]}):"; printf '      %s\n' "${SLEEPING[@]}"; }
# a detached driver's summary is read by nobody, so say it out loud when panes were left behind —
# and come back for the transient ones (RETRY above): a detached worker, same flags, same gates.
notes=()
# THE SET this sweep settles in (common.sh, "recycle sets"): a recycle's sweep writes the one its
# driver named (one of its own when run outside a driver); a direct `revive --only` joins the set watch's deferred relaunch
# hands it, else gets a Revive set of its own once it leaves its pane to a worker or to watch. A worker's re-run, the
# self-worker and a plain sweep (the boot hook's) have none.
SET=""; SET_KIND=""; SET_SCOPE=""; selfsess=""
if [ "$DRY" = 0 ] && [ -z "${SALA_RETRY_WORKER:-}" ] && [ "$SELF_WORKER" = 0 ]; then
    if [ -n "${SALA_RECYCLE:-}" ]; then SET="${SALA_SET:-$T0-$$}"; SET_KIND=Recycle; SET_SCOPE=recycle
    elif [ -n "$ONLY" ]; then
        if set_has "${SALA_SET:-}"; then SET="$SALA_SET"; else SET="$T0-$$"; SET_KIND=Revive; SET_SCOPE="only.$ONLY"; fi
    fi
fi
# DEFERRED (so a held pane is never forgotten): a pane skipped because it holds
# scheduled work (a one-shot can be hours away, past the retry window) goes on the deferred list, and `watch` relaunches
# it once the work is done, however long that takes. It counts as left behind in its set until it is back.
# A --cwd run leaves nothing for later: the retry worker and watch relaunch with no folder, so it ends here and says to run it again
ndef=0; DEFS=()
if [ "$DRY" = 0 ] && [ -z "$RELAUNCH_CWD" ]; then
    for l in ${SKIPPED[@]+"${SKIPPED[@]}"}; do
        case "$l" in *"background work is running"*) defer_add "${l%%:*}" "${l#*: }" "$FORCE" "${SET:-${SALA_SET:-}}"; DEFS+=("${l%%:*}"); ndef=$((ndef+1));; esac
    done
    [ "$ndef" -gt 0 ] && notes+=("sala relaunches the $ndef holding background work once that work is done")
fi
START_WORKER=0
if [ "$DRY" = 0 ] && [ -z "${SALA_RETRY_WORKER:-}" ] && [ -z "${SALA_DEFERRED_TRY:-}" ] && [ "$SELF_WORKER" = 0 ] && [ ${#RETRY[@]} -gt 0 ] \
   && { [ -n "${SALA_RECYCLE:-}" ] || [ -n "$ONLY" ]; } && [ -z "$RELAUNCH_CWD" ]; then
    START_WORKER=1; notes+=("sala retries ${#RETRY[@]} of them every $((SALA_RETRY_EVERY/60)) min for up to $(dur_words "$SALA_RETRY_WINDOW")")
fi
# the set, written whole before any worker is told its id: N = the panes this sweep meant to relaunch (back, left behind,
# and the invoking pane when the self-worker comes next), n = those back; outstanding = the retried, the deferred and
# the invoking pane; every other pane left behind is given up at once. A Revive set exists only when a pane is left to come
# back for, and has no first post (a direct revive never posted one): its closures are its posts.
if [ -n "$SET" ] && ! set_has "$SET" && { [ "$SET_KIND" = Recycle ] || [ "$START_WORKER" = 1 ] || [ "$ndef" -gt 0 ]; }; then
    nback=0; for l in ${UPDATED[@]+"${UPDATED[@]}"} ${REVIVED[@]+"${REVIVED[@]}"}; do case "$l" in *"⤷ told:"*) ;; *) nback=$((nback+1));; esac; done
    outs=" "; for e in ${RETRY[@]+"${RETRY[@]}"}; do IFS='|' read -r _ s _ <<< "$e"; outs="$outs$s "; done
    for s in ${DEFS[@]+"${DEFS[@]}"}; do outs="$outs$s "; done
    [ -n "${SALA_SET_SELF:-}" ] && [ "$SET_KIND" = Recycle ] && selfsess=$(tmux display -p -t "$SALA_SET_SELF" '#{session_name}' 2>/dev/null) && outs="$outs$selfsess "
    kv=(); for s in $outs; do case " ${kv[*]-} " in *" out=$s "*) ;; *) kv+=("out=$s");; esac; done
    for l in ${SKIPPED[@]+"${SKIPPED[@]}"}; do
        b=$(hold_bullet_sess "${l%%:*}" "${l#*: }") || b=$(set_bullet "$l")   # a held pane in the one short form (common.sh, hold_bullet)
        kv+=("skip=$b"); case "$outs" in *" ${l%%:*} "*) ;; *) kv+=("gave=$b");; esac
    done
    for l in ${notes[@]+"${notes[@]}"}; do kv+=("note=$l"); done
    for l in ${UPDATED[@]+"${UPDATED[@]}"}; do case "$l" in *" · paused at "*) kv+=("paused=${l%%:*}: paused at ${l##* · paused at }");; esac; done   # THE PAUSE: the panes this sweep paused (the set did not exist yet when they were)
    kv+=("src=$(flag_src)" "fscope=${ONLY:-all}")   # the flag (common.sh, "recycle sets"): its source, and its scope - every live pane, or the --only list
    [ -n "${SALA_FLAG_ROUTINE:-}" ] && kv+=("routine=1")   # raised by the watchdog (an automatic CLI update): may close one pane short (common.sh, _set_short_pane)
    kv+=("force=$FORCE")   # what the straggler's deferred row carries when the flag closes one short
    kv+=("why=$(relaunch_kind)" "took=$(( $(date +%s) - T0 ))" "timing=check ${D1}s · close ${D2}s · resume ${D3}s")   # why: which relaunch this is, for the waiting flag
    set_create "$SET" "$SET_KIND" "$SET_SCOPE" $(( nback + ${#SKIPPED[@]} + $([ -n "$selfsess" ] && echo 1 || echo 0) )) "$nback" "$CURRENT_VER" "$([ "$SET_KIND" = Revive ] && echo 1 || echo 0)" "${kv[@]}"
    [ "$SET_KIND" = Revive ] && set_point "$SET_SCOPE" "$SET"
fi
if [ "$START_WORKER" = 1 ]; then
    wenv=(SALA_SET="$SET"); [ -z "${SALA_RECYCLE:-}" ] && wenv+=(SALA_RETRY_WHAT=Revive)
    env "${wenv[@]}" setsid "$SALA_BIN" revive --retry-worker $([ "$FORCE" = 1 ] && echo --force) $([ "$LANE_DEFAULT_OK" = 1 ] && echo --lane-default) $([ "$RESCUE" = 1 ] && echo --rescue) -- "${RETRY[@]}" </dev/null >>"$LOG" 2>&1 9>&- &   # 9>&-: it never holds the recycle lock; the rescue's retries stay a rescue
    echo "  ↻ retry worker started for ${#RETRY[@]} pane(s) (set $SET)"
fi
# the recycle driver's post-recycle hook reads the sessions this sweep left behind (the driver block above)
if [ "$DRY" = 0 ] && [ -n "${SALA_RECYCLE_SKIPPED_FILE:-}" ] && [ -z "${SALA_RETRY_WORKER:-}" ] && [ "$SELF_WORKER" = 0 ]; then
    for l in ${SKIPPED[@]+"${SKIPPED[@]}"}; do echo "${l%%:*}"; done >> "$SALA_RECYCLE_SKIPPED_FILE" 2>/dev/null || true
fi
# THE HOLDS THIS SWEEP ENDS (common.sh, hold_ended): a session told it is held that this sweep neither relaunched nor leaves to its retry
# worker or the self-worker. A worker's re-run of one pane and watch's deferred try end nothing here: their caller decides.
hold_sweep_end() {
    local f u s l why mode own=""
    [ -z "${SALA_SKIP_PANE:-}" ] || own=$(tmux display -p -t "$SALA_SKIP_PANE" '#{session_name}' 2>/dev/null)
    for f in "$SALA_HELD_DIR"/*; do
        [ -f "$f" ] || continue; u=${f##*/}; case "$u" in *.t.*) continue;; esac
        _kv_first_r s "$f" session; [ -n "$s" ] && [ "$s" != "$own" ] || continue
        if [ "$START_WORKER" = 1 ]; then case " ${RETRY[*]-} " in *"|$s|"*) continue;; esac; fi
        case " ${DEFS[*]-} " in *" $s "*) hold_ended "$u" deferred "it holds background work"; continue;; esac
        why=""; mode=ended
        for l in ${NOREL[@]+"${NOREL[@]}"}; do [ "${l%%:*}" != "$s" ] || { why="sala is set never to relaunch it (SALA_NO_RELAUNCH)"; mode=dropped; break; }; done
        [ -n "$why" ] || for l in ${SKIPPED[@]+"${SKIPPED[@]}"}; do [ "${l%%:*}" != "$s" ] || { why=${l#*: }; break; }; done
        [ -n "$why" ] || for l in ${OK[@]+"${OK[@]}"}; do [ "${l%%:*}" != "$s" ] || { why="it is already on the current version, so there is nothing to relaunch"; break; }; done
        [ -z "$why" ] || hold_ended "$u" "$mode" "$why"
    done
    return 0
}
[ "$DRY" = 1 ] || [ -n "${SALA_RETRY_WORKER:-}" ] || [ -n "${SALA_DEFERRED_TRY:-}" ] || [ "$SELF_WORKER" = 1 ] || hold_sweep_end
# BOOT RECORD: the first full sweep of each boot — the resurrect
# post-restore hook's — leaves its summary for `watch`, which posts the post-boot report once
# revive is done. A hook's stdout goes nowhere, so this is also its only record.
if [ "$DRY" = 0 ] && [ -z "$ONLY" ] && [ -z "${SALA_RECYCLE:-}" ] && [ -z "${SALA_RETRY_WORKER:-}" ] \
   && bid=$(boot_id) && [ -n "$bid" ] && [ "$(head -1 "$SALA_BOOT_REC" 2>/dev/null)" != "$bid" ]; then
    # THE NETWORK STOP: a pane brought back whose turn ended on "Can't reach the API server" stays stopped until the
    # watch wakes it, so the line says how many were (common.sh, net_stopped_sessions reads the transcripts; nothing read: nothing said)
    netn() { local l; mapfile -t _ns < <(for l in "$@"; do case "$l" in *"⤷"*) ;; *) echo "${l%%:*}";; esac; done | sort -u); [ ${#_ns[@]} -gt 0 ] && net_stopped_sessions "${_ns[@]}" | wc -l || echo 0; }
    nr=$(netn ${REVIVED[@]+"${REVIVED[@]}"}); nu=$(netn ${UPDATED[@]+"${UPDATED[@]}"})
    nw="stopped on a network error; woken once the network is back"
    { echo "$bid"; date +%s
      echo "${#REVIVED[@]} resumed$([ "${nr:-0}" -gt 0 ] && echo ", $nr of them $nw") · ${#UPDATED[@]} updated$([ "${nu:-0}" -gt 0 ] && echo ", $nu of them $nw") · ${#OK[@]} already running · ${#SKIPPED[@]} skipped (target $CURRENT_VER)"
      for l in ${SKIPPED[@]+"${SKIPPED[@]}"}; do echo "skipped: $l"; done
      for l in ${NOREL[@]+"${NOREL[@]}"}; do echo "excluded: $l"; done   # not "skipped: " (reboot.sh reads those as left behind)
      for l in ${REVIVED[@]+"${REVIVED[@]}"} ${UPDATED[@]+"${UPDATED[@]}"}; do case "$l" in *"⤷ served"*) echo "served: $l";; esac; done
    } > "$SALA_BOOT_REC.tmp" && mv -f "$SALA_BOOT_REC.tmp" "$SALA_BOOT_REC"
fi
# THE FIRST POST of a recycle's set (common.sh, set_report): CLEAN RECYCLE (reported like a clean provision or a clean
# CLI update), one phone-width post when nothing was left behind;
# else the panes left behind, one bullet each (panes held for one reason: one line with a count, post_group_bullets), under the set's label and count. A clean recycle stays one post;
# the first-post-at-once rule applies when a pane besides the invoking one is left behind: then the invoking
# pane, which the self-worker relaunches next, is in it as "<session>: not relaunched yet", its relaunch a closure like any
# other. Nothing left behind but the invoking pane → no post here: the self-worker makes the first post once it is settled.
[ -n "$SET" ] && [ "$SET_KIND" = Recycle ] && ! { [ -n "$selfsess" ] && [ ${#SKIPPED[@]} -eq 0 ]; } && set_report "$SET"
# --cwd that did not end with the row written says so last and fails: a queued operation is then stuck, and a wake shows the line
if [ -n "$RELAUNCH_CWD" ] && [ "$CWD_END" != set ]; then
    if [ "$DRY" = 1 ]; then [ "$nwould" -gt 0 ] || { echo "[dry-run] would refuse: ${ONLY_LIST[0]}: nothing would be relaunched now, so the pane map would stay as it is (the reason is above; a live claude on the current version is relaunched only with --force)"; exit 1; }
    elif [ "$CWD_END" = unwritten ]; then echo "✗ ${ONLY_LIST[0]}: relaunched in $RELAUNCH_CWD, but the pane-map folder was not written (the line above says why)"; exit 1
    else echo "✗ ${ONLY_LIST[0]}: not relaunched, so the pane-map folder is unchanged (the reason is above; a live claude on the current version is relaunched only with --force): run it again"; exit 1; fi
fi
exit 0
