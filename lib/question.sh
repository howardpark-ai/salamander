# lib/question.sh — a background `claude -p` run that asks the owner a question parks until the answer arrives.
# Dispatched by bin/salamander as `salamander question …` and `salamander resume-answer`.
#
#   salamander question run [--cwd DIR] [--label TEXT] [--model M] [--json] [PROMPT… | < prompt] [-- claude args…]
#                           start `claude -p` the way a parkable run needs (below) and print its result text; exit 0 finished,
#                           10 parked on a question (the line says its id and the command that answers it), 1 failed
#   salamander resume-answer QID [--answer TEXT | --answer-file FILE|- | --decline [WHY]] [--free-text] [--dry-run] [-- claude args…]
#                           the owner's answer in, the run on: validate the words against the parked call, then `claude -p --resume`
#                           with the hook returning allow + the answer. No answer given → the answer seam (SALA_QUESTION_ANSWER_CMD);
#                           none yet → exit 3 and the run stays parked, nothing run, nothing granted. Exit 0 finished · 10 parked
#                           again (another question) · 3 no answer yet · 4 the words do not fit (the options are printed) · 2 no
#                           such question · 1 the run failed (the answer is kept; run it again to retry)
#   salamander question list | show QID | sweep | file QID
#                           the open questions · one record · every parked question that has an item and an answer seam is asked
#                           for its answer and resumed if it has one (the watch tick runs it, below, every SALA_QUESTION_SWEEP_EVERY seconds while a question is open) · (re)file one (what the
#                           hook runs; also for one whose filing failed)
#
# THE FLOW (verified on Claude Code 2.1.307; docs/stuck-question-recovery.md):
#   1. `question run` starts `claude -p` with SALA_DEFER_QUESTIONS=1, `--permission-prompt-tool mcp__salahost__approve` (lib/permission-host.py,
#      which denies everything: a `-p` run is offered AskUserQuestion only when it has a permission host) and `--settings` carrying a
#      PreToolUse hook, matcher SALA_DEFER_TOOLS (default AskUserQuestion), command `salamander hook ask`.
#   2. The hook (lib/question.py) defers the call: the turn ends with terminal_reason "tool_deferred" and a deferred_tool_use (no stop_reason key) and the call stays in the transcript.
#      It records the call under $SALA_STATE_DIR/questions/<qid>/ and files the question (below). Nothing is granted.
#   3. `resume-answer` stores the owner's answer (checked against the options) and resumes the session; the same call fires the hook
#      again, which returns allow with updatedInput {questions, answers}, or deny when the owner declined. A parked call with no answer is
#      deferred again, so a resume without one changes nothing.
#   A listed tool other than AskUserQuestion (SALA_DEFER_TOOLS="AskUserQuestion Bash") is parked the same way and answered yes (allow this
#   exact call) or no (deny it). PreToolUse fires before the permission check, so it cannot tell a call that would prompt from one that
#   would not: every call of a listed tool is parked. The PermissionRequest hook can only allow or deny, never defer, so it is not used.
#
# THE TWO SEAMS. Each is a command the operator may set; the board's are the default (stackshot's client.py has `post question` and
# `get answer`, live in stackshot, and contrib/question-board-*.sh call them):
#   SALA_QUESTION_FILE_CMD    files the question. The question text is on stdin (secrets masked); the environment carries SALA_QUESTION_ID,
#                             SALA_QUESTION_SESSION, SALA_QUESTION_LABEL, SALA_QUESTION_SCOPE (the subject prefix: SALA_DEFAULT_SCOPE, else the first of SALA_SCOPES; none = no prefix), SALA_QUESTION_RESUME (the command that answers it) and SALA_STATE_DIR.
#                             Its first stdout line is the board item id, kept in the record. Exit non-zero: not filed, kept retryable.
#   SALA_QUESTION_ANSWER_CMD  reads the owner's answer. SALA_QUESTION_ID, SALA_QUESTION_ITEM, SALA_QUESTION_SESSION and SALA_STATE_DIR in the
#                             environment; the answer on stdout; empty or a non-zero exit means "not yet".
#   Unset (or empty) and the stackshot client exists (SALA_STACKSHOT_CLIENT, default stackshot/fleet/client.py under SALA_STACKSHOT_DIR, client.py there on an older checkout; ~/stackshot when unset): the board scripts above run.
#   Unset and no client: the file seam is a post through the notify command (SALA_NOTIFY_CMD / SALA_WATCH_NOTIFY_CMD, the stuck watch's
#   path) and only `resume-answer --answer` supplies an answer. `off` turns a seam off the same way (no board scripts even with a client).
. "$SALA_ROOT/lib/stuck.sh"   # sq_send: the post path the stuck watch uses
QS_DIR="$SALA_STATE_DIR/questions"
# settings-json and host-json are fixed text of the environment: the shell writes them when every part is plain (the python program's own
# output, byte for byte, which tests/boardseam.sh compares), and asks python otherwise (two python starts per run).
_qs_settings_json() {
    local t w tools="" sb=${SALA_BIN:-}; [ -n "$sb" ] || sb=salamander
    [[ $sb =~ ^[A-Za-z0-9_@%+=:,./-]+$ ]] || return 1
    for w in ${SALA_DEFER_TOOLS:-AskUserQuestion}; do [[ $w =~ ^[A-Za-z0-9_]+$ ]] && tools+="${tools:+|}$w"; done
    [ -n "$tools" ] || tools=AskUserQuestion
    printf '{"hooks": {"PreToolUse": [{"matcher": "%s", "hooks": [{"type": "command", "command": "%s hook ask"}]}]}}\n' "$tools" "$sb"
}
_qs_host_json() {
    local py; py=$(command -v python3 2>/dev/null) || return 1
    [[ $py =~ ^/[A-Za-z0-9_./-]+$ && $SALA_ROOT =~ ^/[A-Za-z0-9_./-]+$ ]] || return 1
    [[ $py$SALA_ROOT == *//* || $py$SALA_ROOT == *'/./'* || $py$SALA_ROOT == *'/../'* || $SALA_ROOT == */ ]] && return 1
    printf '{"mcpServers": {"salahost": {"command": "%s", "args": ["-I", "-S", "%s/lib/permission-host.py"]}}}\n' "$py" "$SALA_ROOT"
}
qpy() {
    case ${1-} in
        settings-json) _qs_settings_json && return 0 ;;
        host-json) _qs_host_json && return 0 ;;
    esac
    SALA_STATE_DIR="$SALA_STATE_DIR" SALA_DEFER_TOOLS="${SALA_DEFER_TOOLS:-AskUserQuestion}" SALA_BIN="$SALA_BIN" python3 -I -S "$SALA_ROOT/lib/question.py" "$@"; }
qlog() { local _t; _iso_now_r _t; echo "[$_t] $*" >> "$SALA_LOG_DIR/salamander-question.log"; }
# Scratch files (the stderr of the file seam and of the run): each is named in QS_TMPS the moment it exists, and qs_main's EXIT trap
# removes whatever is still there on ANY exit, a stop included (SIGTERM from a `timeout` or a cancelled CI job runs an EXIT trap at once,
# but not a plain `rm` after the command). A path that returns early or is stopped between the mktemp and its own `rm -f` used to
# leave `sala-qfile.XXXXXX` / `sala-qerr.XXXXXX` in $TMPDIR.
QS_TMPS=()
qs_tmp() {  # <var> <prefix> → var = a new empty file $TMPDIR/<prefix>.XXXXXX, registered for removal at exit; 1 when it cannot be made
    local _f; _f=$(mktemp "${TMPDIR:-/tmp}/$2.XXXXXX") || return 1
    QS_TMPS+=("$_f"); printf -v "$1" '%s' "$_f"
}
qs_tmp_clean() { [ "${#QS_TMPS[@]}" -eq 0 ] || rm -f -- "${QS_TMPS[@]}"; QS_TMPS=(); }
_qs_dirs() {  # the state, question and log folders (private: 0700 on the question one when made here); a mkdir and a chmod on every call were four processes
    [ -d "$SALA_STATE_DIR" ] && [ -d "$QS_DIR" ] && [ -d "$SALA_LOG_DIR" ] && return 0
    mkdir -p "$SALA_STATE_DIR" "$QS_DIR" "$SALA_LOG_DIR" 2>/dev/null; chmod 700 "$QS_DIR" 2>/dev/null; return 0
}
qs_seam() {  # <FILE|ANSWER> → the seam's command on stdout, nothing when there is none: the setting; unset/empty → the board script when the client exists; off → none
    local v w; eval "v=\${SALA_QUESTION_${1}_CMD:-}"
    case "$v" in off) return 0 ;; '') ;; *) printf '%s\n' "$v"; return 0 ;; esac
    local c; c=$(stackshot_client) || return 0   # SALA_STACKSHOT_CLIENT, else the client under SALA_STACKSHOT_DIR (common.sh); none: no board seam
    w=${1,,}; printf "'%s'\n" "$SALA_ROOT/contrib/question-board-$w.sh"
}
# _qs_seam_argv <command> → QS_SEAM, the words to run it with: the default seam is one quoted path (qs_seam), run as it is; any other setting is shell text
_qs_seam_argv() { if [[ $1 =~ ^\'([^\']+)\'$ ]]; then QS_SEAM=("${BASH_REMATCH[1]}"); else QS_SEAM=(sh -c "$1"); fi; }
qs_flags() {  # → QS_FLAGS: what a parkable run is started with (a run and its resume alike)
    QS_FLAGS=(--output-format json --mcp-config "$(qpy host-json)" --permission-prompt-tool mcp__salahost__approve --settings "$(qpy settings-json)")
}
qs_bin() {  # → the claude binary on stdout, resolved without trusting this process's PATH: $SALA_CLAUDE when executable, else the PATH's, else ~/.local/bin/claude
    # The watch launches the sweep as a transient `systemd-run --user` unit, whose PATH is the system default (no ~/.local/bin): a bare `claude` is not found there.
    local c
    for c in "${SALA_CLAUDE:-}" "$(command -v claude 2>/dev/null)" "$HOME/.local/bin/claude"; do
        [ -n "$c" ] && [ -x "$c" ] && [ ! -d "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}
qs_claude() {  # <cwd> <label> <prompt|-> [claude arg…] → QS_OUT (claude's stdout: the result JSON), QS_ERR (the tail of its stderr), the exit code; the prompt "-" reads nothing (a resume has none)
    local cwd="$1" label="$2" prompt="$3" bin bdir errf rc je=(); shift 3; QS_OUT=""; QS_ERR=""
    if [ -n "${QS_ON_JOB_LANE:-}" ]; then   # the sweep (a scheduled job): the run goes out on SALA_JOB_LANE; a lane not ready leaves the question parked for the next sweep
        job_env_args "$SALA_JOB_LANE" || { QS_OUT="the $(lane_shown "$SALA_JOB_LANE") lane (SALA_JOB_LANE) is not ready: $JOB_ENV_WHY"; return 1; }; je=(${JOB_ENV[@]+"${JOB_ENV[@]}"})
    fi
    bin=$(qs_bin) || { QS_OUT="claude was not found (SALA_CLAUDE=${SALA_CLAUDE:-unset}, not on the PATH, no $HOME/.local/bin/claude)"; return 127; }
    [ -d "$cwd" ] || cwd="$HOME"   # the run's folder is gone: the session is found by its id wherever it runs
    bdir=${bin%/*}; [ "$bdir" != "$bin" ] || bdir=.   # dirname, in the shell
    qs_flags
    qs_tmp errf sala-qerr || errf=/dev/null
    # stdout is the result JSON and nothing else; stderr (a hook or node warning) is kept apart so it cannot make the JSON unreadable.
    # The run's PATH gets claude's own folder in front, so what the run starts (the hook, its tools) finds the tools beside it.
    if [ "$prompt" = "-" ]; then
        QS_OUT=$(cd "$cwd" 2>/dev/null && PATH="$bdir:$PATH" SALA_DEFER_QUESTIONS=1 SALA_QUESTION_LABEL="$label" ${je[@]+env "${je[@]}"} "$bin" -p "${QS_FLAGS[@]}" "$@" </dev/null 2>"$errf"); rc=$?
    elif [ -n "$prompt" ]; then
        QS_OUT=$(cd "$cwd" 2>/dev/null && printf '%s' "$prompt" | PATH="$bdir:$PATH" SALA_DEFER_QUESTIONS=1 SALA_QUESTION_LABEL="$label" ${je[@]+env "${je[@]}"} "$bin" -p "${QS_FLAGS[@]}" "$@" 2>"$errf"); rc=$?
    else
        QS_OUT=$(cd "$cwd" 2>/dev/null && PATH="$bdir:$PATH" SALA_DEFER_QUESTIONS=1 SALA_QUESTION_LABEL="$label" ${je[@]+env "${je[@]}"} "$bin" -p "${QS_FLAGS[@]}" "$@" 2>"$errf"); rc=$?
    fi
    [ "$errf" = /dev/null ] || { QS_ERR=$(tail -c 1500 "$errf" 2>/dev/null | scrub_text); rm -f "$errf"; }
    return "$rc"
}
qs_report() {  # <claude's stdout> <raw?> [its stderr tail] → prints the run's outcome; the exit code is the flow's (0 finished · 10 parked · 1 failed)
    local res first rest qid sid kind
    res=$(printf '%s' "$1" | qpy result); first=${res%%$'\n'*}; rest=""; [[ $res != *$'\n'* ]] || rest=${res#*$'\n'}   # head -1 and tail -n +2, in the shell
    IFS=$'\t' read -r kind qid sid <<< "$first"
    [ "${2:-}" != 1 ] || printf '%s\n' "$1"   # --json: the raw result, and the exit code alone says the rest
    case "$kind" in
        parked) [ "${2:-}" = 1 ] || { echo "parked: question $qid (session $sid) waits for ${SALA_OWNER_NAME}'s answer"
                echo "  answer it: sala resume-answer $qid --answer \"<an option's label or number>\"   (sala question show $qid)"; }
                qlog "parked: $qid (session $sid)"; return 10 ;;
        done)   [ "${2:-}" = 1 ] || printf '%s\n' "$rest"; return 0 ;;
        *)      [ "${2:-}" = 1 ] || { echo "the run failed:" >&2; printf '%s\n' "$1" | tail -c 1500 >&2; echo >&2
                                      [ -z "${3:-}" ] || { echo "its error output:" >&2; printf '%s\n' "$3" >&2; }; }
                qlog "the run failed: $(printf '%s %s' "$1" "${3:-}" | tr '\n' ' ' | tail -c 300 | scrub_text)"; return 1 ;;
    esac
}
qs_run() {
    local cwd="$PWD" label="" prompt="" raw=0 extra=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --cwd) cwd="${2:?--cwd needs a directory}"; shift 2 ;;
            --label) label="${2:?--label needs text}"; shift 2 ;;
            --model) extra+=(--model "${2:?--model needs a model}"); shift 2 ;;
            --json) raw=1; shift ;;
            --) shift; extra+=("$@"); break ;;
            -*) die "question run: unknown option $1" ;;
            *) prompt="${prompt:+$prompt }$1"; shift ;;
        esac
    done
    [ -d "$cwd" ] || die "question run: no directory $cwd"
    if [ -z "$prompt" ] && [ -t 0 ]; then die "usage: salamander question run [--cwd DIR] [--label TEXT] [--model M] [--json] PROMPT… [-- claude args…]   (or the prompt on stdin)"; fi
    _qs_dirs
    qs_claude "$cwd" "${label:-$(basename "$cwd")}" "$prompt" ${extra[@]+"${extra[@]}"}
    qs_report "$QS_OUT" "$raw" "$QS_ERR"
}
qs_file() {  # <qid> — file the question: the seam, else a post through the notify command; the record keeps what was done
    local qid="$1" row text label sess cmd item rc b errf why scope
    row=$(qpy show "$qid") || { echo "no parked question $qid" >&2; return 2; }
    IFS=$'\t' read -r _ sess _ _ _ _ label _ <<< "$row"
    text=$(qpy text "$qid" | scrub_text)
    cmd=$(qs_seam FILE)
    if [ -n "$cmd" ]; then
        _qs_seam_argv "$cmd"
        scope=$(qs_scope)
        if [ -z "$scope" ] && [ "$cmd" = "'$SALA_ROOT/contrib/question-board-file.sh'" ]; then   # the board refuses a subject with no scope bracket: say which setting is missing instead of retrying
            why="no scope to open the board subject with: set SALA_DEFAULT_SCOPE (or SALA_SCOPES) in the sala config"
            echo "sala question file: $why" >&2; qlog "filing refused: $qid ($label), $why"
            qs_failed "$qid" "$label" "$text" 2 "$why"; return 1
        fi
        if [ -z "${SALA_QUESTION_PROJECT:-}" ] && [ "$cmd" = "'$SALA_ROOT/contrib/question-board-file.sh'" ]; then   # no default project page: the board takes none empty, so name the setting
            why="no project page to file the board item under: set SALA_QUESTION_PROJECT in the sala config"
            echo "sala question file: $why" >&2; qlog "filing refused: $qid ($label), $why"
            qs_failed "$qid" "$label" "$text" 2 "$why"; return 1
        fi
        qs_tmp errf sala-qfile || errf=""
        item=$(printf '%s\n' "$text" | SALA_STATE_DIR="$SALA_STATE_DIR" SALA_STACKSHOT_CLIENT="${SALA_STACKSHOT_CLIENT:-}" SALA_STACKSHOT_DIR="${SALA_STACKSHOT_DIR-}" SALA_QUESTION_PROJECT="${SALA_QUESTION_PROJECT:-}" SALA_QUESTION_SCOPE="$scope" SALA_QUESTION_ID="$qid" SALA_QUESTION_SESSION="$sess" SALA_QUESTION_LABEL="$label" SALA_QUESTION_RESUME="sala resume-answer $qid" \
               timeout 60 "${QS_SEAM[@]}" 2>"$errf"); rc=$?
        cat "$errf" >> "$SALA_LOG_DIR/salamander-question.log" 2>/dev/null
        if [ "$rc" = 0 ]; then
            rm -f "$errf" "$QS_DIR/$qid/fails"
            item=$(head -1 <<< "$item" | awk '{print $1}' | tr -cd 'A-Za-z0-9#_.:/-' | cut -c1-80)   # the first word of its first line
            qpy set "$qid" item "$item" filed seam; qlog "filed: $qid ($label)${item:+ as $item} by the file seam"; return 0
        fi
        why=$(tail -1 "$errf" | scrub_text | tr -d '\r' | cut -c1-300); rm -f "$errf"
        qpy set "$qid" filed ""; qlog "filing failed: $qid, the file seam exit $rc — \`sala question sweep\` or \`sala question file $qid\` tries again"
        qs_failed "$qid" "$label" "$text" "$rc" "$why"; return 1
    fi
    b=("it asks: $(tr '\n' '|' <<< "$text" | sed 's/|$//; s/|/ · /g')" "answer it: sala resume-answer $qid --answer \"<an option's label or number>\"" "until it is answered, the run stays parked and nothing is granted")
    sq_send "⏸ *$label is waiting for ${SALA_OWNER_NAME}'s answer*" "${b[@]}"; rc=$?
    case "$rc" in
        0) qpy set "$qid" filed post; qlog "filed: $qid ($label) as a post (no file seam)" ;;
        3) qpy set "$qid" filed none; qlog "filed: $qid ($label) nowhere — neither a file seam nor a notify command is configured; \`sala question list\` shows it" ;;
        *) qpy set "$qid" filed ""; qlog "filing failed: $qid, the post failed (exit $rc)"; return 1 ;;
    esac
    return 0
}
qs_scope() {  # → the scope word a board subject opens with: SALA_DEFAULT_SCOPE, else the first word of SALA_SCOPES (leading blanks ignored); nothing when neither is set
    local s="${SALA_DEFAULT_SCOPE:-}"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%%[[:space:]]*}"
    [ -n "$s" ] || { s="${SALA_SCOPES:-}"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%%[[:space:]]*}"; }
    printf '%s' "$s"
}
qs_failed() {  # <qid> <label> <text> <rc> <why> — a filing that failed: counted; at SALA_QUESTION_FILE_TRIES in a row, ONE post says the board did not take it
    local qid="$1" label="$2" text="$3" rc="$4" why="$5" n tries="${SALA_QUESTION_FILE_TRIES:-3}" b prc
    mkdir -p "$QS_DIR/$qid"; n=$(( $(cat "$QS_DIR/$qid/fails" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$QS_DIR/$qid/fails"
    case "$tries" in ''|*[!0-9]*|0) tries=1 ;; esac
    { [ "$n" -ge "$tries" ] && [ ! -e "$QS_DIR/$qid/announced" ]; } || return 0
    [ "$rc" != 124 ] || why="${why:+$why; }it did not answer in time"
    b=("the board did not take it after $n tries${why:+: $why}" "it asks: $(tr '\n' '|' <<< "$text" | sed 's/|$//; s/|/ · /g')" "answer it: sala resume-answer $qid --answer \"<an option's label or number>\"" "sala keeps trying to put it on the board; until it is answered, the run stays parked and nothing is granted")
    sq_send "⏸ *$label is waiting for ${SALA_OWNER_NAME}'s answer*" "${b[@]}"; prc=$?
    case "$prc" in
        0|3) : > "$QS_DIR/$qid/announced"; qlog "announced: $qid ($label) as a post, the board did not take it after $n tries" ;;
        *) qlog "announcing $qid failed: the post failed (exit $prc), tried again at the next failed filing" ;;
    esac
}
qs_fetch() {  # <qid> [show row] → the owner's answer on stdout through the seam; empty when none (yet)
    local row="${2:-}" item sess cmd
    cmd=$(qs_seam ANSWER); [ -n "$cmd" ] || return 0
    _qs_seam_argv "$cmd"
    [ -n "$row" ] || row=$(qpy show "$1") || return 0; IFS=$'\t' read -r _ sess _ _ _ item _ <<< "$row"; [ "$item" != - ] || item=""
    SALA_STATE_DIR="$SALA_STATE_DIR" SALA_STACKSHOT_CLIENT="${SALA_STACKSHOT_CLIENT:-}" SALA_STACKSHOT_DIR="${SALA_STACKSHOT_DIR-}" SALA_QUESTION_ID="$1" SALA_QUESTION_ITEM="$item" SALA_QUESTION_SESSION="$sess" timeout 60 "${QS_SEAM[@]}" 2>>"$SALA_LOG_DIR/salamander-question.log" </dev/null || true
}
qs_resume() {
    local qid="${1:-}" ans="" have=0 free=() decline="" dry=0 extra=() chk pm row state sid cwd pmode tool item label filed rc aout
    [ -n "$qid" ] && [ "${qid#-}" = "$qid" ] || die "usage: salamander resume-answer QID [--answer TEXT | --answer-file FILE|- | --decline [WHY]] [--free-text] [--dry-run] [-- claude args…]"
    shift
    while [ $# -gt 0 ]; do
        case "$1" in
            --answer) ans="${2:?--answer needs the words}"; have=1; shift 2 ;;
            --answer-file) if [ "${2:?--answer-file needs a file}" = - ]; then ans=$(cat); else ans=$(cat "$2") || die "resume-answer: cannot read $2"; fi; have=1; shift 2 ;;
            --decline) decline=1; have=1; ans=""; if [ $# -ge 2 ] && [ "${2#--}" = "$2" ]; then ans="$2"; shift; fi; shift ;;
            --free-text) free=(--free-text); shift ;;
            --dry-run) dry=1; shift ;;
            --) shift; extra=("$@"); break ;;
            *) die "resume-answer: unknown argument $1" ;;
        esac
    done
    row=$(qpy show "$qid") || { echo "no parked question $qid (sala question list)" >&2; return 2; }
    IFS=$'\t' read -r state sid cwd pmode tool item label filed <<< "$row"
    [ "$state" != done ] || { echo "question $qid is finished already" >&2; return 4; }
    mkdir -p "$QS_DIR/$qid"; exec 9>>"$QS_DIR/$qid/lock"
    flock -n 9 || { echo "question $qid is being resumed right now" >&2; return 4; }
    if [ "$have" = 0 ]; then
        ans=$(qs_fetch "$qid"); ans=$(sed -e 's/[[:space:]]*$//' <<< "$ans")
        if [ -n "$ans" ]; then have=1
        elif [ "$state" != answered ]; then echo "still parked: question $qid has no answer yet (nothing was run, nothing granted)"; return 3; fi
    fi
    chk=(); [ "$dry" = 1 ] && chk=(--check)
    if [ "$have" = 1 ]; then
        if [ -n "$decline" ]; then aout=$(qpy answer "$qid" ${chk[@]+"${chk[@]}"} --decline ${ans:+"$ans"} 2>&1); rc=$?
        else aout=$(qpy answer "$qid" ${chk[@]+"${chk[@]}"} ${free[@]+"${free[@]}"} "$ans" 2>&1); rc=$?; fi
        if [ "$rc" != 0 ]; then printf '%s\n' "$aout" >&2; [ "$rc" != 3 ] || rc=4; return "$rc"; fi   # the words do not fit: 4 here (3 is "no answer yet")
        [ "$dry" = 1 ] || qlog "answer stored: $qid ($label)"
    fi
    pm=(); [ "$pmode" = default ] || [ "$pmode" = - ] || [ "$pmode" = bypassPermissions ] || pm=(--permission-mode "$pmode")   # a resume starts in the default mode (docs): asked again
    if [ "$dry" = 1 ]; then echo "would resume session $sid in $cwd: claude -p --resume $sid ${pm[*]-} …  (the answer fits: $aout)"; return 0; fi
    qs_claude "$cwd" "$label" - --resume "$sid" ${pm[@]+"${pm[@]}"} ${extra[@]+"${extra[@]}"}
    qs_report "$QS_OUT" 0 "$QS_ERR"; rc=$?
    [ "$rc" = 0 ] && { qpy finish "$qid"; qlog "resumed: $qid ($label) finished"; }   # the hook marks it done when it allows; this covers a hook that did not
    return "$rc"
}
qs_sweep() {
    local qid st n=0 done_=0 ans row f8 line QS_ON_JOB_LANE=1   # dynamic scope: qs_resume → qs_claude see it (a user's own `question run` / `resume-answer` does not)
    [ -d "$QS_DIR" ] || { echo "sweep: nothing parked"; return 0; }
    while IFS= read -r line; do   # <qid> TAB <its show row>: one python start for the whole list
        qid=${line%%$'\t'*}; row=${line#*$'\t'}; st=${row%%$'\t'*}
        [ -n "$qid" ] || continue; n=$((n+1))
        case "$st" in
            parked) ans=$(qs_fetch "$qid" "$row")
                    [ -n "$ans" ] || { IFS=$'\t' read -r _ _ _ _ _ _ _ f8 _ <<< "$row"; f8=${f8//-/}; [ -z "$f8" ] && qs_file "$qid" >/dev/null 2>&1; continue; }
                    echo "sweep: $qid has an answer"; qs_resume "$qid" --answer "$ans" && done_=$((done_+1)) ;;
            answered) echo "sweep: $qid was answered but not resumed"; qs_resume "$qid" && done_=$((done_+1)) ;;
        esac
    done < <(qpy sweep)
    echo "sweep: $n open, $done_ finished"; return 0
}
qs_main() {
    local verb="${1:-}"; [ $# -gt 0 ] && shift
    trap qs_tmp_clean EXIT   # this is the whole process's entry (bin/salamander dispatches `question` and `resume-answer` here): the scratch files go on any exit, a stop included
    _qs_dirs
    case "$verb" in
        run) qs_run "$@" ;;
        resume-answer|answer) qs_resume "$@" ;;
        file) [ -n "${1:-}" ] || die "usage: salamander question file QID"; qs_file "$1" ;;
        list) qpy list | { column -t -s $'\t' 2>/dev/null || cat; } ;;
        show) [ -n "${1:-}" ] || die "usage: salamander question show QID"
              row=$(qpy show "$1") || { echo "no parked question $1" >&2; exit 2; }
              IFS=$'\t' read -r st sid cwd pm tool item label filed <<< "$row"
              printf 'state: %s\nsession: %s\ncwd: %s\npermission mode: %s\ntool: %s\nitem: %s\nrun: %s\nfiled: %s\nasks:\n' "$st" "$sid" "$cwd" "$pm" "$tool" "$item" "$label" "$filed"
              qpy text "$1" | scrub_text | sed 's/^/  /' ;;
        sweep) qs_sweep ;;
        -h|--help) sed -n '2,/^# THE FLOW/p' "$SALA_ROOT/lib/question.sh" | sed '$d; s/^# \{0,1\}//' ;;
        *) sed -n '2,/^# THE FLOW/p' "$SALA_ROOT/lib/question.sh" | sed '$d; s/^# \{0,1\}//' >&2; exit 2 ;;
    esac
}
