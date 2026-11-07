# lib/model.sh — the model and effort a session is relaunched on, recorded (Wed Oct 14th 2026, asked by the project's coordinator session; common.sh,
# "models"). Built on lib/lane.sh's conventions: the record first, then the relaunch through the machinery every relaunch
# uses, the same guards, the same --dry-run and --not-master.
#
#   salamander model                                                           the table: every session with a model of its own —
#                                                                              the record, what its claude runs on, and
#                                                                              its transcript's last turn
#   salamander model <session> <model> [--effort <level>] [--dry-run] [--not-master]
#                                                                              record them, then put the session on them: switched in
#                                                                              place when its pane is idle with an empty input box,
#                                                                              else relaunched (resumed, same conversation); one
#                                                                              already running them is left alone
#   salamander model <session> <model> [--effort <level>] --record-only [--dry-run] [--not-master]
#                                                                              record them alone: nothing relaunched now, the row
#                                                                              holds at the session's next relaunch
#   salamander model <session> --clear [--dry-run] [--not-master]              drop the record: the transcript decides again, at the
#                                                                              session's next relaunch (nothing relaunched now)
#   salamander model <model> [--effort <level>] <session>… [--dry-run] [--not-master]   THE BATCH: the same switch for
#                                                                              several sessions in one command (see below)
#   salamander model --clear <session> <session>… [--dry-run] [--not-master]   drop the records of several sessions
#
# THE BATCH (a batch of model changes should not wake a front agent once per session; the
# queue's `sala op model <model> [--effort <level>] <session>…` runs it and sends ONE result notice). Which shape a command line has
# (model_batch_shape, common.sh): the first word is a model (opus · sonnet · haiku · fable · claude-…) → the batch; otherwise it
# is the session of the single-session shape above, which is unchanged. All sessions are checked first (a name sala does not know
# refuses the whole command, nothing recorded or touched). Then, under ONE recycle lock, each session goes through the single
# switch above in turn (a child `salamander model <session> <model>` with SALA_MODEL_BATCH_OUT set: the record, then the switch
# in place when idle with an empty input box); the ones that must be relaunched are not relaunched one by one but handed over,
# at the end, to ONE `revive --force --only A --only B …` sweep (and `revive --self` for this command's own pane), as
# `salamander lane <lane> <session>…` does: one set, one verdict. The session that asked (SALA_OP_FROM) goes last, so its wait for
# its own turn to end holds nobody else back. It prints one line per session, `RESULT <session>: <outcome>`, then a summary line
# `model batch: …`; a session that failed does not stop the others, and the exit status is 1 when any did. --clear takes any number
# of sessions the same way (`salamander model --clear A B`); `A --clear` is the single form. --record-only goes with the batch too.
#
# --record-only (Wed Oct 14th 2026, asked by the project's coordinator session): the panes of a per-pane model plan that are not to be relaunched
# now get their row all the same, so a relaunch that comes for another reason (a recycle, a lane move, the boot hook) brings
# them back on it instead of on whatever their transcript last ran (one session came back on opus after a lane move). The
# same checks, guard and recycle lock as the switch, the row written by model_write, no revive and no self-worker. It also
# takes a session with no tmux session right now, when sala knows the name (session_known below: a tmux session, a
# pane-map row, or a model row of its own): a restore or the boot hook brings it back through revive, whose resume line
# (resume_cmd) reads the row. A name sala has never seen is refused, as the switch refuses it.
#
# <model>: a family alias (opus · sonnet · haiku · fable: the family's latest version) or a full model id (claude-…), passed
# to `claude --model` as it is. --effort: low · medium · high · xhigh · max, passed as `claude --effort` — the flag
# resume_cmd already puts on every resume line (the transcript's effort, until now) and spawn takes. Without --effort the
# row's effort is "-": the transcript's effort is kept. The record wins over the transcript at every relaunch after this one
# (a recycle, revive, the boot hook, restore, a retry worker, watch's deferred relaunch, the self-worker, unpark: all build
# their line in resume_cmd).
#
# HOW IT RELAUNCHES — as `sala lane <lane> <session>`: `revive --force --only <session>` (the direct sweep, its retry worker
# for a busy pane), or `revive --self` when it is the invoking pane's own session (relaunched once it is idle). No
# post-recycle hook: the board is not told a recycle happened. "Already on it" is read off the running claude's own command
# line (its --model and, when one is recorded, its --effort): the line resume_cmd built for it, as the lane is read off the
# process's environment, or off the in-place switch sala itself made (below); a /model typed into the pane by hand is on
# neither; run `revive --force --only <session>` to relaunch it on the record regardless.
# THE RECORD COMES FIRST, under the recycle lock and before the pane is touched, so the relaunch that follows and every later
# one launch on it; a relaunch that cannot start now leaves the record in place and says so. --dry-run is read before
# anything is written: it prints the row it would record and the path that applies.
#
# SWITCHED IN PLACE FIRST. A pane that is idle with an EMPTY input box keeps its
# conversation process: `/model <model>` (and `/effort <level>`) are typed into its composer through tui_send, the record
# already written, and no relaunch follows. The gate is model_inplace_gate: the switch is on (SALA_MODEL_INPLACE), a claude
# runs in the pane, it is not this command's own pane (that one is mid-turn), not the sdk lane (no composer), is_idle says idle
# (unknown is never idle), no dialog is on the screen and the composer holds no unsent text. Anything else, and any failure
# after the first keystroke, is the relaunch below with the reason printed: nothing is lost by trying.
#   - `/model` opens a "Switch model?" dialog when the model differs from the last turn's; text typed into it is swallowed and
#     an Enter confirms it. Enter is sent ONLY when the screen shows "Switch model?"; any other dialog gets an Escape and
#     counts as a failure. Nothing is typed while a turn runs (the dialog would hang).
#   - Verified by the screen: a new "Set model to" line (and a new "Set effort level to" one for /effort), counted over the
#     pane's scrollback before and after.
#   - Each of those commands saves the lane's DEFAULT in its settings.json (the top-level `model`, `modelSettings.<id>.
#     effortLevel`), which would move every session started later onto it. The keys are snapshotted before the first
#     keystroke and put back afterwards (common.sh model_settings_restore: compare-and-restore, atomic, the file's other keys
#     and mode untouched), on the failure path too. The settings.json is the pane's own: the CLAUDE_CONFIG_DIR of its claude
#     (the subscription-2 lane's directory), else ~/.claude. The whole switch runs under the recycle lock the record is written under,
#     so a launch never reads the half-state.
#   - model-inplace.tsv remembers what a live claude was switched to (its command line no longer says): a second request for
#     the pair it runs on is "left alone", and the table shows it with a star.
# A pane asking about itself from the queue's runner (no TMUX_PANE: the unit is outside every pane) is switched in place like
# any other once it is idle; run from inside the pane the command relaunches it last (the self-worker), as before.

usage() {
    echo "usage: salamander model                                                       the table (each recorded session: record, launched with, last turn)"
    echo "       salamander model <session> <model> [--effort <level>] [--dry-run] [--not-master]   record + switch it in place (idle, empty input box) or relaunch it (already on them: left alone)"
    echo "       salamander model <session> <model> [--effort <level>] --record-only [--dry-run] [--not-master]   record alone, no relaunch (it holds at the next one)"
    echo "       salamander model <session> --clear [--dry-run] [--not-master]          drop the record (the transcript decides at the next relaunch)"
    echo "       salamander model <model> [--effort <level>] <session>… [--dry-run] [--not-master]   the same for several sessions at once: one lock, one sweep for the relaunches, one summary (the first word a model = this shape)"
    echo "       salamander model --clear <session> <session>… [--dry-run] [--not-master]   drop the records of several sessions"
    echo "  models: $SALA_MODEL_FAMILIES, or a full model id (claude-…) · efforts: $SALA_EFFORTS_KNOWN"
}

export SALA_FLAG_SRC=model   # the flag a relaunch here raises: one pane, explicit (common.sh, flag_src)
DRY=0; NOTMASTER=""; CLEAR=0; RECORD_ONLY=0; EFFORT=""; EFFORT_SET=0; args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1 ;; --not-master) NOTMASTER=--not-master ;; --clear) CLEAR=1 ;; --record-only) RECORD_ONLY=1 ;;
        --effort) [ $# -ge 2 ] || die "--effort needs a level ($SALA_EFFORTS_KNOWN)"; EFFORT="$2"; EFFORT_SET=1; shift ;;
        --effort=*) EFFORT="${1#--effort=}"; EFFORT_SET=1 ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $1 (see: salamander model --help)" ;;
        *) args+=("$1") ;;
    esac
    shift
done
set -- ${args[@]+"${args[@]}"}
# the batch's child (THE BATCH, the header): `salamander model <session> …` run by the batch driver below, with SALA_MODEL_SINGLE=1
# (always the single-session shape) and SALA_MODEL_BATCH_OUT naming the file where it notes its outcome, one tab-separated line
# `<session> <kind> <detail>`; it takes no recycle lock (the driver holds it) and leaves its relaunch to the driver's one sweep
batch_child() { [ -n "${SALA_MODEL_BATCH_OUT:-}" ]; }
batch_note() { batch_child || return 0; printf '%s\t%s\t%s\n' "$SESS" "$1" "${2:-}" >> "$SALA_MODEL_BATCH_OUT"; return 0; }   # <kind> [detail]

session_cpid() { local pp; pp=$(tmux list-panes -t "$(tmux_win_t "$1")" -F '#{pane_pid}' 2>/dev/null) || return 1; claude_pid_under "${pp%%$'\n'*}"; }   # <session> → the claude in its first pane
# launched_with <claude-pid> → "<model>\t<effort>" from the process's command line ("-" for a flag it does not carry)
launched_with() {   # the awk of old, in the shell: the --flag value pairs first, then a --flag=value overrides, words split as ps's line was
    local m=- e=- m2="" e2="" w prev="" words IFS=$' \t\n' line m2set="" e2set=""
    if [ -r /proc/self/stat ]; then _nul_read "/proc/$1/cmdline"; line="${_NUL[*]-}"; [ -n "$line" ] || line=$(proc_args "$1"); else line=$(proc_args "$1"); fi
    [ -n "$line" ] || return 0
    read -ra words <<< "$line"
    for w in ${words[@]+"${words[@]}"}; do
        case $prev in --model) m=$w ;; --effort) e=$w ;; esac
        case $w in --model=*) m2=${w#--model=}; m2set=1 ;; --effort=*) e2=${w#--effort=}; e2set=1 ;; esac
        prev=$w
    done
    [ -n "$m2set" ] && m=$m2; [ -n "$e2set" ] && e=$e2
    printf '%s\t%s\n' "$m" "$e"
}
# running_with <claude-pid> → "<model>\t<effort>\t<0|1>" it runs on: what sala switched it to in place (inplace_get; an effort
# not switched is the launch line's) with 1 in the third field, else the launch line's with 0
running_with() {
    local l ip m e; l=$(launched_with "$1"); ip=$(inplace_get "$1")
    [ -n "$ip" ] || { printf '%s\t0\n' "$l"; return; }
    m=${ip%%$'\t'*}; e=${ip#*$'\t'}; e=${e%%$'\t'*}; [ "$e" = - ] && { e=${l#*$'\t'}; e=${e%%$'\t'*}; }
    printf '%s\t%s\t1\n' "$m" "$e"
}
# last_turn <claude-pid> → "<family>/<effort>" of its conversation's transcript (what a relaunch without a record would take)
last_turn() {
    local u f; u=$(registry_field "$1" sessionId 2>/dev/null); [ -n "$u" ] && [ "$u" != null ] || { echo "?"; return; }
    f=$(_resume_flags_for_uuid "$u"); printf '%s/%s\n' "$(cut -f2 -s <<< "$f" | sed 's/^$/?/')" "$(cut -f1 <<< "$f" | sed 's/^$/?/')"
}
show_row() { printf '%s' "${1//$'\t'//}"; }   # "<model>\t<effort>" → "model/effort"
# session_known <session> → 0 when sala knows the name: a tmux session by it (what the switch, and lane.sh's switch, ask
# for), a pane-map row (the ledger: lane.sh's lane_sessions draws on the same rows, and restore and the boot hook bring such
# a session back), or a model row of its own already
session_known() { tmux has-session -t "=$1" 2>/dev/null || [ -n "$(ledger_row "$1")" ] || [ -n "$(model_row "$1")" ]; }

# ── the table ─────────────────────────────────────────────────────────────────
if [ $# -eq 0 ]; then
    [ "$CLEAR" = 0 ] && [ "$EFFORT_SET" = 0 ] && [ "$RECORD_ONLY" = 0 ] || die "which session? salamander model <session> …"
    echo "models: a session's own model and effort, which every relaunch takes over its transcript's (salamander model <session> <model> [--effort <level>])"
    rows=$( [ -r "$SALA_MODELS" ] && cut -f1 "$SALA_MODELS" | awk 'NF && !seen[$0]++' | LC_ALL=C sort)
    [ -n "$rows" ] || { echo "(nothing recorded: every session is relaunched on its transcript's model and effort)"; exit 0; }
    printf '%-30s %-22s %-22s %-18s %s\n' SESSION RECORDED LAUNCHED-WITH LAST-TURN ''
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        rec=$(model_row "$s"); rm_=$(cut -f1 <<< "$rec"); re_=$(cut -f2 -s <<< "$rec"); note=""; lw="-"; lt="-"
        if c=$(session_cpid "$s"); then
            l=$(running_with "$c"); lw=$(show_row "$(cut -f1,2 <<< "$l")"); [ "$(cut -f3 <<< "$l")" = 1 ] && lw="$lw*"; lt=$(last_turn "$c")
            lm=$(cut -f1 <<< "$l"); le=$(cut -f2 <<< "$l")
            if [ "$lm" != "$rm_" ] || { [ "$re_" != - ] && [ "$le" != "$re_" ]; }; then note="← a relaunch puts it on the record (salamander revive --force --only $s, or the next recycle)"; fi
        elif ! tmux has-session -t "=$s" 2>/dev/null; then note="no tmux session (a restore brings it back on the record)"
        else note="no claude running (a revive resumes it on the record)"; fi
        no_relaunch "$s" && note="$(no_relaunch_fix "$s" "managed outside sala (SALA_NO_RELAUNCH): sala never relaunches it")"
        printf '%-30s %-22s %-22s %-18s %s\n' "$s" "$(show_row "$rec")" "$lw" "$lt" "$note"
    done <<< "$rows"
    exit 0
fi


# ── the batch (THE BATCH, the header) ─────────────────────────────────────────
BATCH=""
if [ -z "${SALA_MODEL_SINGLE:-}" ]; then
    if [ "$CLEAR" = 1 ] && [ $# -ge 2 ]; then BATCH=clear
    elif [ "$CLEAR" = 0 ] && [ $# -ge 2 ] && model_batch_shape "$@"; then BATCH=switch; fi
fi
if [ -n "$BATCH" ]; then
    if [ "$BATCH" = switch ]; then
        MODEL="$1"; shift
        if [ "$EFFORT_SET" = 1 ]; then effort_known "$EFFORT" || die "invalid effort '$EFFORT' (one of: $SALA_EFFORTS_KNOWN)"; else EFFORT=-; fi
    else
        MODEL=""
        [ "$EFFORT_SET" = 0 ] || die "--clear takes no --effort"
        [ "$RECORD_ONLY" = 0 ] || die "--clear takes no --record-only: it never relaunches anything"
    fi
    # every session checked first: one that sala does not know (or cannot switch) refuses the whole batch, nothing recorded or touched
    BS=(); BAD=()
    for s in "$@"; do
        case "$s" in ''|-*|*[[:space:]:]*) BAD+=("invalid session name '$s'"); continue;; esac
        case " ${BS[*]-} " in *" $s "*) continue;; esac   # named twice: taken once
        BS+=("$s")
        if [ "$BATCH" = clear ]; then
            [ -n "$(model_row "$s")" ] || tmux has-session -t "=$s" 2>/dev/null || BAD+=("unknown session '$s': no tmux session, and no model recorded for it")
        else
            if [ "$RECORD_ONLY" = 1 ]; then session_known "$s" || BAD+=("unknown session '$s': no tmux session, no pane-map row and no model recorded for it (salamander spawn --list)")
            else tmux has-session -t "=$s" 2>/dev/null || BAD+=("unknown session '$s': no tmux session by that name (salamander spawn --list)"); fi
            [ "$s" = "$SALA_RC_SESSION" ] && BAD+=("'$s' is the Remote Control server's session — it has no model of its own (salamander rc)")
            no_relaunch "$s" && BAD+=("$(no_relaunch_line "$s") — $(no_relaunch_fix "$s" "it is launched by hand; take it out of SALA_NO_RELAUNCH to record a model for it")")
        fi
    done
    if [ ${#BAD[@]} -gt 0 ]; then printf '✗ %s\n' "${BAD[@]}" >&2; die "the batch is refused (${#BAD[@]} problem(s) in ${#BS[@]} session(s)) — nothing recorded, nothing relaunched"; fi
    ops_guard model "${BS[0]}" $NOTMASTER $([ "$DRY" = 1 ] && echo --dry-run)   # a fleet operation (common.sh): the master's, when a Claude session asks
    ORD=(); LASTS=""   # the asking session goes last: its wait for its own turn to end (below) holds nobody else back
    for s in "${BS[@]}"; do if [ -n "${SALA_OP_FROM:-}" ] && [ "$s" = "$SALA_OP_FROM" ]; then LASTS="$s"; else ORD+=("$s"); fi; done
    [ -z "$LASTS" ] || ORD+=("$LASTS")
    MS="$MODEL/$EFFORT"; [ "${EFFORT:-}" = - ] && MS="$MODEL"
    CARGS=()
    if [ "$BATCH" = clear ]; then CARGS=(--clear)
    else CARGS=("$MODEL"); [ "$EFFORT_SET" = 1 ] && CARGS+=(--effort "$EFFORT"); [ "$RECORD_ONLY" = 1 ] && CARGS+=(--record-only); fi
    if [ "$DRY" = 1 ]; then
        echo "model batch: ${#ORD[@]} session(s)$([ "$BATCH" = clear ] && echo ", records dropped" || echo " → $MS") — DRY RUN: nothing recorded, nothing relaunched"
        drc=0
        for s in "${ORD[@]}"; do
            echo "── $s"
            SALA_MODEL_SINGLE=1 "$SALA_BIN" model "$s" ${CARGS[@]+"${CARGS[@]}"} --dry-run $NOTMASTER 2>&1 </dev/null | sed 's/^/  /'; [ "${PIPESTATUS[0]}" = 0 ] || drc=1
        done
        [ "$BATCH" = clear ] || echo "[dry-run] the sessions that cannot be switched in place would be relaunched together, by one sweep: salamander revive --force --only … (one result for the batch)"
        exit "$drc"
    fi
    mkdir -p "$SALA_STATE_DIR" 2>/dev/null
    OUTF=$(mktemp "$SALA_STATE_DIR/model-batch.XXXXXX") && LOGF=$(mktemp "$SALA_STATE_DIR/model-batch.XXXXXX") || die "no scratch file for the batch ($SALA_STATE_DIR)"
    trap 'rm -f "$OUTF" "$LOGF"' EXIT
    if [ "$BATCH" = switch ]; then   # THE LOCK once for all (the single switch takes it per session); the children inherit it and the sweep keeps it
        recycle_lock "$(lock_who)" 0 || recycle_refuse
        export SALA_RECYCLE_LOCKED=1
    fi
    echo "model batch: ${#ORD[@]} session(s)$([ "$BATCH" = clear ] && echo ", records dropped" || echo " → $MS")"
    RK=(); RT=(); i=0
    for s in "${ORD[@]}"; do
        i=$((i+1)); : > "$OUTF"; : > "$LOGF"; echo "── [$i/${#ORD[@]}] $s"
        SALA_MODEL_SINGLE=1 SALA_MODEL_BATCH_OUT="$OUTF" "$SALA_BIN" model "$s" ${CARGS[@]+"${CARGS[@]}"} $NOTMASTER > "$LOGF" 2>&1 </dev/null; crc=$?
        sed 's/^/  /' "$LOGF"
        got=$(awk -F'\t' '{k=$2; d=$3} END {if (k != "") print k "\t" d}' "$OUTF"); k=${got%%$'\t'*}; d=${got#*$'\t'}
        if [ "$crc" != 0 ] || [ -z "$k" ]; then
            d=$(grep -v '^[[:space:]]*$' "$LOGF" | tail -1 | sed -E 's/^[^[:alnum:]]+//'); d=${d:-exited $crc}
            if command -v scrub_text >/dev/null 2>&1; then d=$(printf '%s' "$d" | scrub_text); fi
            k=failed; d="${d:0:200} (exit $crc)"
        fi
        RK+=("$k"); RT+=("$d")
    done
    # the relaunches, together: one sweep for the panes that could not be switched in place, then this command's own pane
    SW=(); NSW=0; SELFR=0
    for ((i=0; i<${#ORD[@]}; i++)); do case "${RK[i]}" in relaunch) SW+=(--only "${ORD[i]}"); NSW=$((NSW+1));; self) SELFR=1;; esac; done
    rrc=0
    if [ "$NSW" -gt 0 ]; then echo "── relaunch sweep: one revive for $NSW pane(s)"; "$SALA_BIN" revive --force "${SW[@]}" $NOTMASTER </dev/null || rrc=$?; fi
    if [ "$SELFR" = 1 ]; then "$SALA_BIN" revive --self $NOTMASTER || rrc=$?; fi
    # one line per session, then the summary (lib/op.sh reads both: the RESULT lines are the notice's body, the last line its result)
    nsw=0; nsame=0; nrl=0; nrec=0; ndrop=0; nnone=0; nfail=0; failed=()
    for ((i=0; i<${#ORD[@]}; i++)); do
        s=${ORD[i]}; k=${RK[i]}; d=${RT[i]}
        if [ "$rrc" != 0 ] && { [ "$k" = relaunch ] || [ "$k" = self ]; }; then k=failed; d="recorded on $MS, but the relaunch did not run through (exit $rrc): it comes onto them at its next relaunch"; fi
        case "$k" in
            inplace)  nsw=$((nsw+1));  o="switched in place to $MS" ;;
            same)     nsame=$((nsame+1)); o="already on $MS, left alone" ;;
            relaunch) nrl=$((nrl+1));  o="relaunch started on $MS (a busy pane is retried until it is idle)" ;;
            self)     nrl=$((nrl+1));  o="this pane: relaunched on $MS once it is idle" ;;
            recorded) nrec=$((nrec+1)); o="recorded $MS (no relaunch; it holds at the next one)" ;;
            cleared)  ndrop=$((ndrop+1)); o="record dropped (was $d)" ;;
            norecord) nnone=$((nnone+1)); o="no record (on its transcript's model already)" ;;
            *)        nfail=$((nfail+1)); failed+=("$s"); o="FAILED: $d" ;;
        esac
        echo "RESULT $s: $o"
    done
    sm=""; add() { [ "$1" -gt 0 ] && sm+="${sm:+, }$1 $2"; return 0; }
    add "$nsw" "switched in place"; add "$nsame" "already on it"; add "$nrl" "relaunching"; add "$nrec" "recorded"; add "$ndrop" "records dropped"; add "$nnone" "had no record"
    [ "$nfail" = 0 ] || sm+="${sm:+, }$nfail FAILED (${failed[*]})"
    echo "model batch: ${#ORD[@]} session(s)$([ "$BATCH" = clear ] || echo " → $MS"): $sm"
    [ "$nfail" = 0 ] && exit 0 || exit 1
fi

SESS="$1"; MODEL="${2:-}"
case "$SESS" in ''|-*|*[[:space:]:]*) die "invalid session name '$SESS'";; esac

# ── the clear ─────────────────────────────────────────────────────────────────
if [ "$CLEAR" = 1 ]; then
    [ $# -eq 1 ] || die "--clear takes the session alone: salamander model $SESS --clear"
    [ "$EFFORT_SET" = 0 ] || die "--clear takes no --effort"
    [ "$RECORD_ONLY" = 0 ] || die "--clear takes no --record-only: it never relaunches anything (salamander model $SESS --clear)"
    old=$(model_row "$SESS")
    if [ -z "$old" ]; then
        tmux has-session -t "=$SESS" 2>/dev/null || die "unknown session '$SESS': no tmux session, and no model recorded for it"
        echo "$SESS: no model recorded — it is relaunched on its transcript's model and effort already"; batch_note norecord; exit 0
    fi
    ops_guard model "$SESS" $NOTMASTER $([ "$DRY" = 1 ] && echo --dry-run)   # a fleet operation (common.sh): the master's, when a Claude session asks
    if [ "$DRY" = 1 ]; then echo "[dry-run] would drop the model record for $SESS ($(show_row "$old")) — nothing recorded, nothing relaunched"; exit 0; fi
    model_drop "$SESS" || die "could not drop the model record for '$SESS' ($SALA_MODELS)"
    batch_note cleared "$(show_row "$old")"
    echo "$SESS: model record dropped (was $(show_row "$old")) — its next relaunch takes its transcript's model and effort (nothing relaunched now)"
    echo "  the transcript's newest turns ran on the recorded model, so that is what it names until /model changes it in the pane"
    exit 0
fi

# ── the switch ────────────────────────────────────────────────────────────────
[ -n "$MODEL" ] || die "which model? salamander model $SESS <model> [--effort <level>]   (models: $SALA_MODEL_FAMILIES, or a full model id claude-…)"
[ $# -le 2 ] || die "one session and one model: salamander model <session> <model> [--effort <level>]"
model_valid "$MODEL" || die "unknown model '$MODEL' (a family alias: $SALA_MODEL_FAMILIES; or a full model id: claude- then lowercase letters, digits, dots, dashes)"
if [ "$EFFORT_SET" = 1 ]; then effort_known "$EFFORT" || die "invalid effort '$EFFORT' (one of: $SALA_EFFORTS_KNOWN)"; else EFFORT=-; fi
if [ "$RECORD_ONLY" = 1 ]; then
    session_known "$SESS" || die "unknown session '$SESS': no tmux session, no pane-map row and no model recorded for it (salamander spawn --list)"
else
    tmux has-session -t "=$SESS" 2>/dev/null || die "unknown session '$SESS': no tmux session by that name (salamander spawn --list)"
fi
[ "$SESS" = "$SALA_RC_SESSION" ] && die "'$SESS' is the Remote Control server's session — it has no model of its own (salamander rc)"
no_relaunch "$SESS" && die "$(no_relaunch_line "$SESS") — $(no_relaunch_fix "$SESS" "it is launched by hand; take it out of SALA_NO_RELAUNCH to record a model for it")"
ops_guard model "$SESS" $NOTMASTER $([ "$DRY" = 1 ] && echo --dry-run)   # a fleet operation (common.sh): the master's, when a Claude session asks

# ── the record alone (--record-only) ──────────────────────────────────────────
if [ "$RECORD_ONLY" = 1 ]; then
    old=$(model_row "$SESS"); was="(transcript)"; [ -n "$old" ] && was=$(show_row "$old")
    echo "model $SESS: $was → $MODEL/$EFFORT$([ "$EFFORT" = - ] && echo " (no effort of its own: the transcript's)") — record only, nothing relaunched$([ "$DRY" = 1 ] && echo " — DRY RUN: nothing recorded")"
    if c=$(session_cpid "$SESS"); then echo "  its claude was launched with: $(show_row "$(launched_with "$c")") (kept until its next relaunch)"
    elif ! tmux has-session -t "=$SESS" 2>/dev/null; then echo "  no tmux session now: a restore or the boot hook brings it back on the record"; fi
    if [ "$DRY" = 1 ]; then   # read before anything is written (the header)
        echo "[dry-run] would record $SESS → $MODEL/$EFFORT in $SALA_MODELS, the row (tab-separated): $SESS $MODEL $EFFORT"
        echo "[dry-run] nothing would be relaunched"
        exit 0
    fi
    batch_child || recycle_lock "$(lock_who)" 0 || recycle_refuse   # the row is written as the switch writes it: no relaunch driver meanwhile (a batch's child: the driver holds it)
    model_write "$SESS" "$MODEL" "$EFFORT" || die "could not record the model for '$SESS' (see above)"
    batch_note recorded
    echo "recorded: $SESS → $MODEL/$EFFORT ($SALA_MODELS) (not relaunched; takes effect at its next relaunch)"
    exit 0
fi

ME=""; [ -n "${TMUX_PANE:-}" ] && ME=$(tmux display -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)

# ── the in-place switch (the header) ──────────────────────────────────────────
INPLACE_PANE=""; INPLACE_CPID=""; INPLACE_WHY=""
# model_inplace_gate <session> → 0 the pane can be switched in place; 1 it cannot, and 2 it cannot just now (busy or unknown:
# the asking session's own turn, say). INPLACE_WHY says why; INPLACE_PANE and INPLACE_CPID name the pane and its claude.
# Read-only: the dry run asks it too.
model_inplace_gate() {
    local s="$1" r d
    INPLACE_PANE=""; INPLACE_CPID=""; INPLACE_WHY=""
    [ "$SALA_MODEL_INPLACE" = on ] || { INPLACE_WHY="in-place switching is off (SALA_MODEL_INPLACE=$SALA_MODEL_INPLACE)"; return 1; }
    INPLACE_CPID=$(session_cpid "$s") || { INPLACE_CPID=""; INPLACE_WHY="no claude is running in its pane"; return 1; }
    INPLACE_PANE=$(tmux list-panes -t "$(tmux_win_t "$s")" -F '#{pane_id}' 2>/dev/null | head -1)
    [ -n "$INPLACE_PANE" ] || { INPLACE_WHY="no pane to type into"; return 1; }
    [ "$s" = "$ME" ] && { INPLACE_WHY="this command's own pane (it is mid-turn: nothing can be typed into it now)"; return 2; }
    [ "$(proc_lane "$INPLACE_CPID")" = sdk ] && { INPLACE_WHY="an sdk-lane pane has no composer to type into"; return 1; }
    r=$(is_idle_reason "$INPLACE_CPID")   # unknown is never idle: a pane with no registry status gives a reason too
    [ -z "$r" ] || { INPLACE_WHY="not idle: $r"; return 2; }
    pane_prompt "$INPLACE_PANE" && { INPLACE_WHY="a dialog is showing in the pane"; return 1; }
    d=$(pane_draft "$INPLACE_PANE")
    [ -z "$d" ] || { INPLACE_WHY="its input box holds unsent text"; return 1; }
    return 0
}
_inplace_count() { tmux capture-pane -p -S - -t "$1" 2>/dev/null | grep -cE "$2" || :; }   # <pane> <regex> → how many lines of its whole scrollback match
_inplace_abort() {  # <pane> <typed text> — an Escape, and what we typed taken out of the composer if it is still there
    tmux send-keys -t "$1" Escape 2>/dev/null; sleep 0.5
    [ "$(pane_draft_screen "$1")" = "$2" ] && tmux send-keys -t "$1" C-u 2>/dev/null
    return 0
}
# _inplace_step <pane> <typed text> <confirmation regex> <1 when a "Switch model?" dialog may come> → 0 once a NEW line matching
# the regex is on the screen; 1 with INPLACE_WHY. Enter goes into the pane only while the screen shows "Switch model?" (once);
# any other dialog is answered with an Escape and is a failure; so is a confirmation that does not come within
# SALA_MODEL_INPLACE_WAIT seconds.
_inplace_step() {
    local pane="$1" text="$2" re="$3" dlg="$4" before after deadline scr confirmed=0 at=0
    before=$(_inplace_count "$pane" "$re")
    tui_send "$pane" "$text" || { INPLACE_WHY="'$text' could not be typed into the pane (see above)"; return 1; }
    deadline=$(( $(date +%s) + SALA_MODEL_INPLACE_WAIT ))
    while [ "$(date +%s)" -le "$deadline" ]; do
        scr=$(tmux capture-pane -p -t "$pane" 2>/dev/null | tail -40)
        after=$(_inplace_count "$pane" "$re")
        [ "$after" -gt "$before" ] && return 0
        if grep -q 'Switch model?' <<< "$scr"; then
            if [ "$dlg" = 1 ] && [ "$confirmed" = 0 ]; then
                tmux send-keys -t "$pane" Enter; confirmed=1; at=$(date +%s); sleep 1; continue
            elif [ "$confirmed" = 1 ] && [ $(( $(date +%s) - at )) -lt 5 ]; then sleep 0.5; continue   # the dialog is slow to go: not asked again
            fi
            INPLACE_WHY="the 'Switch model?' dialog $([ "$confirmed" = 1 ] && echo "stayed after its Enter" || echo "came where none was expected, after '$text'")"
            _inplace_abort "$pane" "$text"; return 1
        fi
        if grep -qE "$SALA_PROMPT_RE" <<< "$scr"; then INPLACE_WHY="an unexpected dialog is on the screen after '$text'"; _inplace_abort "$pane" "$text"; return 1; fi
        sleep 0.5
    done
    INPLACE_WHY="no new '${re}' line after '$text' within ${SALA_MODEL_INPLACE_WAIT}s"
    _inplace_abort "$pane" "$text"; return 1
}
# model_switch_inplace <session> <model> <effort or -> → 0 switched (and the saved defaults put back); 1 not done, INPLACE_WHY
# says why (the caller relaunches). model_inplace_gate has passed. Runs under the recycle lock (the caller holds it): the
# settings snapshot is taken before the first keystroke and put back on EVERY path out, success or failure.
model_switch_inplace() {
    local s="$1" model="$2" effort="$3" pane="$INPLACE_PANE" cpid="$INPLACE_CPID" sf snap out rc=0 rrc pass prev pe
    sf="$(model_config_dir "$cpid" "$s")/settings.json"
    mkdir -p "$SALA_STATE_DIR" 2>/dev/null; snap=$(mktemp "$SALA_STATE_DIR/model-settings.XXXXXX") || { INPLACE_WHY="no scratch file for the settings snapshot"; return 1; }
    if ! out=$(model_settings_snapshot "$sf" "$snap"); then
        INPLACE_WHY="its settings.json ($sf) cannot be read ($out), so the saved defaults could not be put back"; rm -f "$snap"; return 1
    fi
    if _inplace_step "$pane" "/model $model" 'Set model to' 1; then
        if [ "$effort" != - ]; then _inplace_step "$pane" "/effort $effort" 'Set effort level to' 0 || rc=1; fi
    else rc=1; fi
    # the CLI's own write of the defaults may land a moment after its "Set …" line: wait, put them back, wait, check again
    sleep "$SALA_MODEL_INPLACE_SETTLE"
    for pass in 1 2; do
        out=$(model_settings_restore "$sf" "$snap"); rrc=$?
        if [ "$rrc" = 0 ]; then [ "$out" = unchanged ] || echo "  saved defaults in $sf put back ($out)"
        else echo "⚠ could not put the saved defaults in $sf back ($out): check its model and modelSettings keys by hand" >&2; fi
        [ "$pass" = 1 ] && sleep "$SALA_MODEL_INPLACE_SETTLE"
    done
    rm -f "$snap"
    [ "$rc" = 0 ] || return 1
    prev=$(inplace_get "$cpid"); pe=${prev#*$'\t'}; pe=${pe%%$'\t'*}; if [ "$effort" = - ] && [ -n "$pe" ]; then effort="$pe"; fi
    inplace_put "$cpid" "$model" "$effort" || echo "⚠ could not write $SALA_MODEL_INPLACE_STATE: a second request for the same pair may switch again" >&2
    return 0
}

old=$(model_row "$SESS")
same=0; lw=""; ipw=0
if c=$(session_cpid "$SESS"); then
    l=$(running_with "$c"); ipw=${l##*$'\t'}; l=${l%$'\t'*}; lw=$(show_row "$l")
    # running on them already → left alone, whatever the old record said (lane.sh asks for both the row and the running
    # lane; here the launch line, or the in-place switch sala made since, is the whole of what decides the model, so a
    # relaunch onto the same flags would change nothing)
    [ "${l%%$'\t'*}" = "$MODEL" ] && { [ "$EFFORT" = - ] || [ "${l#*$'\t'}" = "$EFFORT" ]; } && same=1
fi
was="(transcript)"; [ -n "$old" ] && was=$(show_row "$old")
echo "model $SESS: $was → $MODEL/$EFFORT$([ "$EFFORT" = - ] && echo " (no effort of its own: the transcript's)")$([ "$DRY" = 1 ] && echo " — DRY RUN: nothing recorded, nothing relaunched")"
[ -n "$lw" ] && echo "  its claude $([ "$ipw" = 1 ] && echo "was switched in place to" || echo "was launched with"): $lw$([ "$same" = 1 ] && echo " — on the record already, left alone")"
if [ "$DRY" = 1 ]; then
    echo "[dry-run] would record $SESS → $MODEL/$EFFORT in $SALA_MODELS"
    if [ "$same" = 1 ]; then echo "[dry-run] it already runs on them — nothing would be relaunched"; exit 0; fi
    model_inplace_gate "$SESS"; gate=$?
    asker=0; [ "${SALA_OP_PLAN:-}" = 1 ] && [ -n "${SALA_OP_FROM:-}" ] && [ "$SESS" = "$SALA_OP_FROM" ] && asker=1
    efftxt=""; [ "$EFFORT" = - ] || efftxt=", /effort $EFFORT"
    if [ "$gate" = 0 ]; then
        echo "[dry-run] would switch in place: /model $MODEL$efftxt typed into the idle pane, its saved defaults ($(model_config_dir "$INPLACE_CPID" "$SESS")/settings.json) put back after, no relaunch; a relaunch only if that fails"
        exit 0
    elif [ "$asker" = 1 ] && [ "$gate" = 2 ]; then
        echo "[dry-run] would switch in place once the pane is idle (the asking session: the queue's runner reaches it after this turn): /model $MODEL$efftxt, its saved defaults put back after, no relaunch; a pane that cannot be switched then is relaunched (revive --force --only)"
        echo "    (right now: $INPLACE_WHY)"
        exit 0
    fi
    echo "[dry-run] would relaunch — it cannot be switched in place: $INPLACE_WHY"
    if [ "$SESS" = "$ME" ]; then echo "[dry-run] then: salamander revive --self (the self-worker relaunches this pane once it is idle)"
    else echo "[dry-run] then: salamander revive --force --only $SESS (the relaunch verdict)"
         "$SALA_BIN" revive --dry-run --force --only "$SESS" 2>&1 | sed 's/^/    /'; fi
    exit 0
fi

# THE LOCK, then the record, then the switch or the relaunch (the header; lib/lane.sh does the same): one relaunch driver at a
# time; the children (the direct sweep, the self-worker) inherit fd 9 and keep it until they are done
batch_child || recycle_lock "$(lock_who)" 0 || recycle_refuse   # (a batch's child: the driver holds it)
export SALA_RECYCLE_LOCKED=1
model_write "$SESS" "$MODEL" "$EFFORT" || die "could not record the model for '$SESS' (see above) — nothing relaunched"
echo "recorded: $SESS → $MODEL/$EFFORT ($SALA_MODELS)"
[ "$same" = 1 ] && { echo "it already runs on them — nothing relaunched"; batch_note same; exit 0; }
# in place when the pane allows it (the header); the record is written already, so a failure here costs nothing but the relaunch.
# The queue's runner is usually started while the asking session is still finishing the turn that queued it: that one session,
# and only from the runner (SALA_OP_ID), is waited for (SALA_MODEL_INPLACE_ASKER_WAIT) before the relaunch fallback is taken.
model_inplace_gate "$SESS"; gate=$?
if [ "$gate" = 2 ] && [ -n "${SALA_OP_ID:-}" ] && [ -n "${SALA_OP_FROM:-}" ] && [ "$SESS" = "$SALA_OP_FROM" ] && [ "$SESS" != "$ME" ]; then
    echo "  the asking session is still in its turn ($INPLACE_WHY): waiting up to ${SALA_MODEL_INPLACE_ASKER_WAIT}s for it to go idle"
    deadline=$(( $(date +%s) + SALA_MODEL_INPLACE_ASKER_WAIT ))
    while [ "$gate" = 2 ] && [ "$(date +%s)" -lt "$deadline" ]; do sleep 2; model_inplace_gate "$SESS"; gate=$?; done
fi
if [ "$gate" = 0 ]; then
    if model_switch_inplace "$SESS" "$MODEL" "$EFFORT"; then
        echo "switched in place: $SESS runs on $MODEL/$EFFORT with its conversation process kept (not relaunched; the saved defaults are as they were)"
        batch_note inplace
        exit 0
    fi
    echo "  the in-place switch did not complete ($INPLACE_WHY) — relaunching instead"
elif [ "$SESS" = "$ME" ]; then echo "  this command's own pane: relaunched last, once it is idle (the self-worker)"
else echo "  not switched in place ($INPLACE_WHY) — relaunching"; fi
if batch_child; then   # a batch's child: the relaunch is left to the driver's one sweep (THE BATCH, the header)
    if [ "$SESS" = "$ME" ]; then batch_note self; else batch_note relaunch "${INPLACE_WHY:-}"; fi
    exit 0
fi
rc=0
if [ "$SESS" = "$ME" ]; then "$SALA_BIN" revive --self $NOTMASTER || rc=$?
else "$SALA_BIN" revive --force --only "$SESS" $NOTMASTER || rc=$?; fi
if [ "$rc" != 0 ]; then
    echo "⚠ the model is recorded, but the relaunch did not run through (exit $rc, above): $SESS comes onto $MODEL/$EFFORT at its next relaunch — salamander revive --force --only $SESS, or the next recycle" >&2
    exit "$rc"
fi
exit 0
