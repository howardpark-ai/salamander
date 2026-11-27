# lib/sleep.sh — put idle sessions to sleep: end the claude of a session that has nothing in flight, keep its tmux session and pane-map row, and mark it
# sleeping (common.sh, THE SLEEPING SESSIONS). `salamander wake` (lib/wake.sh) resumes it.
#
#   salamander sleep NAME… [--dry-run]     the named sessions (exact tmux session names)
#   salamander sleep --project KEY [--dry-run]   every session of one project, together: what the watch's tick runs (below)
#   salamander sleep --list [--json]       the sleeping sessions, with the time each went to sleep; --json adds what a wake would launch each on (lane, model, effort), for the web page's Agents table
#   salamander sleep --candidates          per project, sleeping / awake / pinned, its two quiet ages and the first reason it is not a candidate; changes nothing
#   salamander sleep --pin KEY [--why TEXT] · --unpin KEY · --pins     hold a project off the automatic sleep, lift it, list the pins (a plain verb: a pin changes nothing that runs)
#
# WHEN A SESSION MAY SLEEP: sleep_ready (lib/wrapup.sh) says so. It is idle (the registry row says idle and has said so for SALA_SLEEP_AFTER seconds, 3600 by
# default), holds no background command, task or subagent, has no dialog showing and nothing typed in its input box, and has nothing a sleep would lose: no
# scheduled job, no queued operation or note naming it, no relaunch waiting for it, no stackshot inbox message for it, no limit or network stop, no open question.
# Refused outright: the Remote Control session, a side session, the sdk lane, a session in SALA_NO_RELAUNCH, and the session this command runs in (a sleep would end the
# call that made it); for a NAME given by hand also a front agent (a project's -main agent, or a registry row with role front: the owner talks to it). A refusal says why,
# in one line, and nothing is touched. There is no bypass flag: a busy session is asked again once it is idle.
#
# A project KEY is its page key without `projects/`, as stackshot's project-activity names it: words of letters, digits, . _ - joined by single slashes (`solo`, `team/alpha`); a pin keeps a slash as %2F in its file name.
# THE SLEEP OF A PROJECT (--project KEY; lib/wrapup.sh, THE SLEEP OF INACTIVE PROJECTS): the unit is the project, never one session. Its sessions (front agents too) sleep
# together, and only when the project is quiet (no external anchor notice and no input from its owner for SALA_SLEEP_QUIET, 2 days; stackshot's `client.py
# project-activity`, or SALA_ACTIVITY_CMD; no reading, nothing sleeps), every one of its sessions is ready (sleep_ready, in its project form) and it is not pinned.
# The whole project is checked first and nothing is touched when any member refuses; each session is then put to sleep as below, with its own checks again.
# Run raw from a Claude session it is refused like the rest (a project sleep is the watch's own routine, never queued); its --dry-run passes.
#
# HOW IT ENDS THE CLAUDE (as retire and revive do, never by name, never a kill): the stackshot inbox is held for the pane, queued feedback drafts are sent (one that cannot be sent stays queued), the
# idle check and sleep_ready are made again with the hold in place, the sleeping marker is written (so the bare-pane heal never revives the pane in the
# gap), and /exit is typed (common.sh pane_exit: the mod first, else the keys). The pane must be back at its shell within SALA_EXIT_WAIT seconds; if it is
# not, the marker is taken off again, the claude is left as it is and the command says so (nothing is ever signalled: a claude that ignores /exit is not
# a sleeper). The hold is released at the end, whatever the result.
#
# THE QUEUE: a session asks with `sala op sleep --only NAME… (--item board#N | --why "<reason>") --from YOU` (lib/op.sh); the queue's runner, a
# sala-op-<id> unit, passes ops_guard like every queued verb. Run raw from a Claude session this verb is refused and points there.
#
# THE ASKED SLEEP (the owner wants a project asleep now): `sala op sleep --project KEY --from YOU --words "<the owner's words>"` queues `sleep --project KEY --asked`, which is
# `--project` with the owner's words behind it: the project's quiet rule (SALA_SLEEP_QUIET) and the settle time (SALA_SLEEP_AFTER, and the left-alone time of a woken session)
# do not apply, and the whole project sleeps together, its front agents with it. Every other check stays: the activity reading must still be there (no reading, nothing sleeps),
# the project is not pinned (the owner's words do not lift a pin: `--unpin` first), and every session is ready (idle with nothing in flight, nothing waiting in its inbox, ...).
# Without --asked a project sleeps by the quiet rule only, as the watch's tick has it. The asking session may be one of the sessions that sleep (the one case the refusal "a sleep
# would end the call that made it" stood for): the queue's runner is outside every pane, so it waits, as a model switch waits for its asker (lib/model.sh), until the asking session has
# ended its turn (sleep_ready passes it; up to SALA_SLEEP_ASKER_WAIT seconds, 90), then puts the whole project to sleep with the asker last; a project the asker is not part of
# sleeps at once. The same wait serves `sala op sleep --only NAME --words …` when NAME is the asker. The plan (`sala op --plan sleep --project KEY`, this verb's --dry-run run in
# the asking pane under SALA_OP_PLAN) says "the asking session sleeps once idle". The result post goes to Slack; the line into the asker's inbox is not sent to a session that has
# gone to sleep (it would wake it).
#
# THE WATCH: with SALA_IDLE_SLEEP=on (off by default) the watch's sleep_tick (lib/wrapup.sh) runs `sleep --project KEY` itself for the projects that qualify, at most
# SALA_SLEEP_PER_TICK (1) PROJECT per run, the quietest first; --candidates prints that list. The watch's wake_tick (always on) runs
# `sala wake` for a sleeper with a stackshot message line waiting.
#
# --dry-run: nothing is typed, marked or changed; the same refusals as the real run, as "[dry-run] would refuse: …" (exit 1), and for a session that may sleep
# what the run would do. Read-only, so it passes the guard from a Claude session like every verb's dry run.

usage="usage: salamander sleep NAME… [--dry-run] | --project KEY [--asked] [--dry-run] | --list [--json] | --candidates | --pin KEY [--why TEXT] | --unpin KEY | --pins
  puts idle sessions to sleep: their claude ends, their tmux session and pane-map row stay; salamander wake NAME resumes one
  --project KEY: every session of one project, together; the watch's idle sleep tick (SALA_IDLE_SLEEP=on, off by default) sleeps a project only when it has had no external
    anchor notice and no input from its owner for SALA_SLEEP_QUIET (2 days), every one of its sessions is idle with nothing in flight, and it is not pinned
  --asked (with --project; \`sala op sleep --project KEY --from YOU --words \"<the owner's words>\"\` queues it): the owner asked for it now, so the quiet rule and the settle time do not apply;
    the activity reading, the pin and every in-flight check still do. A session of the project that asks is put to sleep once its turn has ended (a session cannot run this raw: queue it)
  --list --json: one JSON array, an object a sleeper (name, conversation, since, and the lane, model, effort and ANTHROPIC_DEFAULT_*_MODEL ids its wake would launch it with, read as the wake's own launch line reads them); changes nothing
  --candidates: per project, sleeping, awake or pinned, its two quiet ages and the first reason it is not a candidate; changes nothing
  --pin KEY [--why TEXT] / --unpin KEY / --pins: hold a project off the automatic sleep, lift it, list the pins (kept across a reboot)"
. "$SALA_ROOT/lib/wrapup.sh"
NAMES=(); DRY=0; DRYFLAG=""; LIST=0; LJSON=0; CAND=0; PROJ=""; PIN=""; UNPIN=""; PINS=0; WHY=""; HAVE_WHY=0; ASKED=0
while [ $# -gt 0 ]; do a="$1"; shift; case "$a" in
    --dry-run) DRY=1; DRYFLAG=--dry-run ;; --asked) ASKED=1 ;; --list) LIST=1 ;; --json) LJSON=1 ;; --candidates) CAND=1 ;; --pins) PINS=1 ;; -h|--help) echo "$usage"; exit 0 ;;
    --project) [ $# -gt 0 ] || die "--project takes a project key
$usage"; [ -n "$1" ] || die "an empty text is not a project key (the page key without projects/, like team/alpha)"; PROJ="$1"; shift ;;
    --pin) [ $# -gt 0 ] || die "--pin takes a project key
$usage"; [ -n "$1" ] || die "an empty text is not a project key (the page key without projects/, like team/alpha)"; PIN="$1"; shift ;;
    --unpin) [ $# -gt 0 ] || die "--unpin takes a project key
$usage"; [ -n "$1" ] || die "an empty text is not a project key (the page key without projects/, like team/alpha)"; UNPIN="$1"; shift ;;
    --why) [ $# -gt 0 ] || die "--why takes a text
$usage"; WHY="$1"; HAVE_WHY=1; shift ;;
    -*) die "unknown option: $a
$usage" ;;
    *) NAMES+=("$a") ;;
esac; done
modes=$(( CAND + LIST + PINS )); [ -z "$PROJ" ] || modes=$((modes + 1)); [ -z "$PIN" ] || modes=$((modes + 1)); [ -z "$UNPIN" ] || modes=$((modes + 1))
[ "$modes" -le 1 ] || die "--project, --list, --candidates, --pin, --unpin and --pins each stand alone
$usage"
[ "$LJSON" = 0 ] || [ "$LIST" = 1 ] || die "--json goes with --list
$usage"
[ "$HAVE_WHY" = 0 ] || [ -n "$PIN" ] || die "--why goes with --pin
$usage"
[ "$ASKED" = 0 ] || [ -n "$PROJ" ] || die "--asked goes with --project
$usage"
if [ "$modes" = 1 ] && [ "${#NAMES[@]}" -gt 0 ]; then die "that option takes no session name
$usage"; fi
if [ "$DRY" = 1 ] && { [ -n "$PIN" ] || [ -n "$UNPIN" ] || [ "$PINS" = 1 ] || [ "$CAND" = 1 ] || [ "$LIST" = 1 ]; }; then die "--dry-run goes with sleeping sessions (NAME… or --project), not with this option
$usage"; fi
if [ -n "$PIN" ] || [ -n "$UNPIN" ]; then
    sleep_project_id_r key "${PIN:-$UNPIN}" || die "$(printf '%q' "${PIN:-$UNPIN}") is not a project key (the page key without projects/: words of letters, digits, . _ - joined by single slashes, like team/alpha)"
    if [ -n "$PIN" ]; then
        sleep_pin_set "$key" "$WHY" || die "could not write the pin of $key under $SALA_SLEEP_PIN_DIR"
        echo "✅ $key: pinned — it never sleeps on its own${WHY:+ ($WHY)}; sala sleep --unpin $key lifts it"
        if sleep_projects_load 2>/dev/null && [ -z "${SP_MEM[$key]+x}" ]; then echo "ℹ no session of $key runs on this box now (the pin is kept; check the key with sala sleep --candidates)"; fi
    else
        if sleep_pin_r _p "$key"; then sleep_pin_clear "$key"; echo "✅ $key: unpinned — the watch's idle sleep tick may put it to sleep once it is quiet"; else echo "ℹ $key: was not pinned, nothing done"; fi
    fi
    exit 0
fi
if [ "$PINS" = 1 ]; then
    n=0
    while IFS=$'\t' read -r k t w; do
        [ -n "$k" ] || continue
        e=$(date -u -d "$t" +%s 2>/dev/null) || e=""
        printf '%s\tpinned since %s%s\n' "$k" "$([ -n "$e" ] && local_human "$e" || echo "${t:-?}")" "${w:+ ($w)}"; n=$((n + 1))
    done < <(sleep_pin_list)
    [ "$n" -gt 0 ] || echo "no project is pinned"
    exit 0
fi
if [ "$CAND" = 1 ]; then
    sleep_report
    exit 0
fi
# sleep_list_json → the sleepers as one JSON array, each with what its wake would launch it on. The lane is lane_for_session (its lanes.tsv row, else its pin, else
# the default) and the model, effort and the lane's model ids are read off the line resume_cmd builds for it, the line a wake's revive types: the same two functions,
# not a copy of their rules. The line itself is never printed (an api lane's holds the path of its key file). SALA_LANE_LOG=/dev/null: resume_cmd says a lane
# fallback in lanes.log, and a listing the web page reads every minute must not add a line each time.
sleep_list_json() {
    local u t nm lane line
    while IFS=$'\t' read -r u t nm; do
        [ -n "$u" ] && [ -n "$nm" ] || continue
        lane=$(lane_for_session "$nm")
        line=$(SALA_LANE_LOG=/dev/null resume_cmd "$u" "$nm")
        printf '%s\t%s\t%s\t%s\t%s\n' "$nm" "$u" "$t" "$lane" "$line"
    done < <(sleeping_list) | python3 -c '
import json, re, sys
out = []
for raw in sys.stdin:
    p = raw.rstrip("\n").split("\t", 4)
    if len(p) < 5:
        continue
    name, conv, since, lane, line = p
    m = re.search(r"(?:^|\s)--model\s+(\S+)", line)
    e = re.search(r"(?:^|\s)--effort\s+(\S+)", line)
    env = dict(re.findall(r"(?:^|\s)(ANTHROPIC_DEFAULT_[A-Z]+_MODEL)=(\S+)", line))
    out.append({"name": name, "conversation": conv, "since": since, "lane": lane, "model": m.group(1) if m else None,
                "effort": e.group(1) if e else None, "env": env})
print(json.dumps(out, ensure_ascii=False))'
}
if [ "$LIST" = 1 ] && [ "$LJSON" = 1 ]; then
    sleep_list_json
    exit 0
fi
if [ "$LIST" = 1 ]; then
    n=0
    while IFS=$'\t' read -r u t nm; do
        [ -n "$u" ] || continue
        e=$(date -u -d "$t" +%s 2>/dev/null) || e=""
        printf '%s\tasleep since %s\t(conversation %s)\n' "${nm:-?}" "$([ -n "$e" ] && local_human "$e" || echo "${t:-?}")" "$u"; n=$((n + 1))
    done < <(sleeping_list)
    [ "$n" -gt 0 ] || echo "no session is sleeping"
    exit 0
fi
[ "${#NAMES[@]}" -gt 0 ] || [ -n "$PROJ" ] || die "$usage"
if [ -n "$PROJ" ] && [ "$DRY" = 0 ] && ! op_unit_caller && claude_caller; then
    die "sleep --project is the watch's own routine (SALA_IDLE_SLEEP, off by default), not a verb a session runs: \`sala sleep --project $PROJ --dry-run\` shows what it would do, and a session asks the queue: \`sala op sleep --project $PROJ --from YOU --words \"<${SALA_OWNER_NAME}'s words>\"\` puts the whole project to sleep now, yours included once your turn has ended (\`sala op sleep --only NAME (--item board#N | --why \"<one line>\") --from YOU\` queues one other session)"
fi
ops_guard sleep "${PROJ:-${NAMES[0]}}" $DRYFLAG
dry() { echo "[dry-run] $*"; }
caller=$(ancestry_session 2>/dev/null || true); [ -n "$caller" ] || caller=${SALA_OP_FROM:-}   # the session that asks: by process ancestry, else the queue's own record of who asked
SMODE=""; pkey=""; ASKER=""
SALA_SLEEP_ASKER_WAIT=${SALA_SLEEP_ASKER_WAIT:-90}; case "$SALA_SLEEP_ASKER_WAIT" in ''|*[!0-9]*) SALA_SLEEP_ASKER_WAIT=90;; esac
# THE ASKING SESSION AMONG THE SLEEPERS (the header, THE ASKED SLEEP): allowed only for the queue (its runner, SALA_OP_ID, or its plan, a dry run under SALA_OP_PLAN that names the asker)
asker_ok() {  # <name> → 0 when <name> is the asking session and the queue is the one asking
    [ -n "$caller" ] && [ "$1" = "$caller" ] || return 1
    [ -n "${SALA_OP_ID:-}" ] && return 0
    [ "$DRY" = 1 ] && [ "${SALA_OP_PLAN:-}" = 1 ] && [ "${SALA_OP_FROM:-}" = "$1" ]
}
# asker_wait <name> → 0 once the asking session passes sleep_ready (its turn has ended); 1 when it does not within SALA_SLEEP_ASKER_WAIT s, or never can (its reason in SLEEP_WHY).
# The queue's runner starts while the asker is still finishing the turn that queued the sleep; as a model switch does (lib/model.sh), it waits for that one session.
asker_wait() {
    local n="$1" deadline said=0; deadline=$(( $(date +%s) + SALA_SLEEP_ASKER_WAIT ))
    sleep_ready "$n" "$SMODE" asker >/dev/null || return 1   # what a turn's end cannot change (a front agent, no claude, the sdk lane): no wait
    while ! sleep_ready "$n" "$SMODE" >/dev/null; do
        [ "$(date +%s)" -lt "$deadline" ] || return 1
        [ "$said" = 1 ] || { echo "  the asking session '$n' is still in its turn ($SLEEP_WHY): waiting up to ${SALA_SLEEP_ASKER_WAIT}s for it to be idle"; said=1; }
        sleep 1
    done
    return 0
}
if [ -n "$PROJ" ]; then
    # THE SLEEP OF A PROJECT: the whole project is judged first (quiet, not pinned, every session ready) and nothing is touched when it is not a candidate
    SMODE=project
    sleep_project_id_r pkey "$PROJ" || die "$(printf '%q' "$PROJ") is not a project key (the page key without projects/: words of letters, digits, . _ - joined by single slashes, like team/alpha)"
    pref() { if [ "$DRY" = 1 ]; then dry "would refuse: project $pkey: $1"; else echo "✗ project $pkey: not put to sleep — $1"; fi; exit 1; }
    sleep_projects_load || pref "$SP_WHY_LOAD"
    [ -n "${SP_MEM[$pkey]+x}" ] || pref "no session of it runs on this box"
    sleep_activity_load || true   # a failure stays in SLEEP_ACT_WHY, which sleep_project_check turns into the refusal
    for m in ${SP_MEM[$pkey]}; do
        if [ -n "$caller" ] && [ "${m%:*}" = "$caller" ]; then
            if [ "$ASKED" = 1 ] && asker_ok "$caller"; then ASKER=$caller
            else pref "'$caller' is one of its sessions and the session this command runs in: a sleep would end the call that made it (a session asks the queue: sala op sleep --project $pkey --from $caller --words \"<${SALA_OWNER_NAME}'s words>\"; it sleeps once its turn has ended)"; fi
        fi
    done
    if [ "$ASKED" = 1 ]; then SLEEP_QUIET_WAIVE=1; SLEEP_SETTLE_WAIVE=all; fi
    if [ -n "$ASKER" ]; then
        if [ "$DRY" = 1 ]; then SLEEP_ASKER_LATER=$ASKER
        else asker_wait "$ASKER" || pref "the asking session '$ASKER' is not ready within ${SALA_SLEEP_ASKER_WAIT}s: $SLEEP_WHY; nothing was touched (ask again once it is idle)"; fi
    fi
    sleep_project_check "$pkey" || pref "$SP_WHY"
    NAMES=()
    for m in "${SP_LIVE[@]}"; do [ "$m" = "$ASKER" ] || NAMES+=("$m"); done
    [ -z "$ASKER" ] || NAMES+=("$ASKER")   # the asking session last: the others' results are in before its pane ends
else
    for m in "${NAMES[@]}"; do if asker_ok "$m"; then ASKER=$m; SLEEP_SETTLE_WAIVE=$m; fi; done
    if [ -n "$ASKER" ] && [ "${#NAMES[@]}" -gt 1 ]; then
        _o=(); for m in "${NAMES[@]}"; do [ "$m" = "$ASKER" ] || _o+=("$m"); done; NAMES=("${_o[@]}" "$ASKER")
    fi
fi

# sleep_one <name> → 0 asleep (or, in a dry run, could be) · 1 refused or not done; its one line on stdout, the refusal on stderr in a dry run's form
sleep_one() {
    local n="$1" pane ppid pid uuid i rc scr why
    if [ -n "$caller" ] && [ "$caller" = "$n" ] && [ "$n" != "$ASKER" ]; then
        why="it is the session this command runs in: a sleep would end the call that made it (a session asks the queue: sala op sleep --only $n --from $n --words \"<${SALA_OWNER_NAME}'s words>\"; it sleeps once its turn has ended)"
        if [ "$DRY" = 1 ]; then dry "would refuse: '$n' is $why"; else echo "✗ $n: not put to sleep — $why"; fi
        return 1
    fi
    if [ "$n" = "$ASKER" ] && [ "$DRY" = 1 ]; then   # the plan: the asking session is in its turn now, so only what a turn's end cannot change is asked
        if ! sleep_ready "$n" "$SMODE" asker >/dev/null; then dry "would refuse: $n: $SLEEP_WHY"; return 1; fi
        dry "$n: the asking session sleeps once idle — the queue's runner waits up to ${SALA_SLEEP_ASKER_WAIT}s for its turn to end, then ends its claude${pkey:+ with the rest of the project}; it wakes with: sala wake $n"
        return 0
    fi
    if [ "$n" = "$ASKER" ] && [ -z "$pkey" ] && ! asker_wait "$n"; then   # (a project's asker was waited for before the project was judged)
        echo "✗ $n: not put to sleep — it is the asking session and was not ready within ${SALA_SLEEP_ASKER_WAIT}s: $SLEEP_WHY"; return 1
    fi
    if ! sleep_ready "$n" "$SMODE" >/dev/null; then
        if [ "$DRY" = 1 ]; then dry "would refuse: $n: $SLEEP_WHY"; else echo "✗ $n: not put to sleep — $SLEEP_WHY"; fi
        return 1
    fi
    pane=$(tmux list-panes -t "$(tmux_win_t "$n")" -F '#{pane_id}' 2>/dev/null | head -1)
    ppid=$(tmux list-panes -t "$(tmux_win_t "$n")" -F '#{pane_pid}' 2>/dev/null | head -1)
    pid=$(claude_pid_under "$ppid" 2>/dev/null); sleeping_uuid_r uuid "$n" || uuid=""
    if [ "$DRY" = 1 ]; then
        dry "$n: claude pid $pid in pane $pane, conversation $uuid, idle for at least ${SALA_SLEEP_AFTER}s with nothing in flight"
        dry "$n: would hold its stackshot inbox, send queued feedback drafts, write its sleeping marker, type /exit into pane $pane and wait up to ${SALA_EXIT_WAIT}s for the shell; the tmux session and the pane-map row stay"
        return 0
    fi
    # a hold that was not made (server mode, the stackshot server not answering) is no hold: a sleep with its inbox open would lose the line the puller hands the ended claude, so it is refused (a relaunch may go on after its idle re-check; a sleep may not)
    if ! inbox_hold "$uuid" "$n" 2>/dev/null; then inbox_release "$uuid" "$n" 2>/dev/null; echo "✗ $n: not put to sleep — its stackshot inbox could not be held: $INBOX_WHY"; return 1; fi
    unmode "$pane"
    send_feedback_drafts "$pane" "$uuid" || echo "• $n: feedback draft(s) not sent — they stay queued while it sleeps"   # a file on disk; the wait below passes the drafts gate
    if ! prompt_clears "$pane" 10; then inbox_release "$uuid" "$n"; echo "✗ $n: not put to sleep — a terminal prompt is showing"; return 1; fi
    # THE RE-CHECK, with the hold in place: a line handed out before it started a turn, and an /exit typed by keys would end that turn
    if ! sleep_ready "$n" "$SMODE" >/dev/null; then inbox_release "$uuid" "$n"; echo "✗ $n: not put to sleep — it was not ready once its inbox was held: $SLEEP_WHY"; return 1; fi
    if [ "$(claude_pid_under "$ppid" 2>/dev/null)" != "$pid" ]; then inbox_release "$uuid" "$n"; echo "✗ $n: not put to sleep — the claude in its pane changed since the check"; return 1; fi
    sleeping_mark "$uuid" "$n" || { inbox_release "$uuid" "$n"; echo "✗ $n: not put to sleep — its sleeping marker could not be written"; return 1; }
    scr=$(pane_exit "$pane" "$pid" 2>/dev/null); rc=$?
    case "$rc" in
        0) ;;
        2) why="background work is running (${scr:-a shell, monitor or subagent}), which /exit would stop" ;;
        3) why="unsubmitted text is at the prompt (\"$scr\"), which /exit would run over" ;;
        4) why="a turn is running${scr:+ (held by $scr)}" ;;
        *) why="the pane did not take /exit (composer not empty, or the Enter was dropped twice)" ;;
    esac
    if [ "$rc" != 0 ]; then sleeping_clear "$uuid"; inbox_release "$uuid" "$n"; echo "✗ $n: not put to sleep — $why; its claude is left as it is"; return 1; fi
    if ! wait_exit "$pane" "$SALA_EXIT_WAIT"; then
        sleeping_clear "$uuid"; inbox_release "$uuid" "$n"
        echo "✗ $n: not put to sleep — its claude was still running ${SALA_EXIT_WAIT}s after /exit (a dialog may hold it: attach and look); nothing was signalled and its marker is off again"; return 1
    fi
    inbox_release "$uuid" "$n"
    echo "✅ $n: asleep — its claude (pid $pid) ended, the pane and the pane-map row stay, conversation $uuid; wake it with: sala wake $n"
    return 0
}
bad=0
for n in "${NAMES[@]}"; do sleep_one "$n" || bad=$((bad + 1)); done
if [ -n "$pkey" ]; then
    if [ "$DRY" = 1 ]; then
        [ "$ASKED" = 0 ] || dry "project $pkey: asked in ${SALA_OWNER_NAME}'s words: the quiet rule (SALA_SLEEP_QUIET) and the settle time (SALA_SLEEP_AFTER) do not apply; the activity reading, the pin and every in-flight check still do"
        [ "$bad" = 0 ] && dry "project $pkey: would put ${#NAMES[@]} session(s) to sleep together: ${NAMES[*]}"
    elif [ "$bad" = 0 ]; then echo "✅ project $pkey: asleep — ${#NAMES[@]} session(s): ${NAMES[*]}"
    else echo "✗ project $pkey: only $((${#NAMES[@]} - bad)) of ${#NAMES[@]} sessions asleep — the others are left as they are and $([ "$ASKED" = 1 ] && echo "stay so until it is asked again" || echo "are asked again after the retry time")"; fi
fi
[ "$DRY" = 1 ] && dry "nothing was changed"
[ ${#NAMES[@]} -gt 1 ] && [ -z "$pkey" ] && echo "$((${#NAMES[@]} - bad)) of ${#NAMES[@]} asleep"
[ "$bad" = 0 ]
