# lib/stuck.sh — the stuck-question helpers, sourced by lib/watch.sh (the 90 s post, stuck_tick) and lib/hook.sh (the instant
# alert, `salamander hook notify`; Thu Oct 22nd 2026). One definition of the state file, of how a pane's
# dialog is read and hashed, of how a post is composed and sent, so the two never disagree about what counts as one question.
# Needs common.sh first (SALA_STATE_DIR, SALA_PROMPT_RE, scrub_text, sala_post_text, session_url, registry_field).
: "${SALA_STUCK_POST:=on}"
SQ_STATE="$SALA_STATE_DIR/stuck.state"
sq_get() { _kv_first "$SQ_STATE" "$1"; }
sq_set() { _kv_set "$SQ_STATE" "$1" "$2"; }
sq_drop() { grep -v "^$1\." "$SQ_STATE" > "$SQ_STATE.tmp.$$" 2>/dev/null; mv -f "$SQ_STATE.tmp.$$" "$SQ_STATE"; }   # <key prefix> — every field of one session
sq_key() { local _k; _key_r _k "$1"; printf 's.%s' "$_k"; }   # <session> → its key prefix in the state
sq_key_r() { local _k; _key_r _k "$2"; printf -v "$1" 's.%s' "$_k"; }   # <var> <session>: as sq_key, no subshell
sq_get_r() { _kv_first_r "$1" "$SQ_STATE" "$2"; }   # <var> <key>
sq_on() { case "$SALA_STUCK_POST" in 0|off|no|false) return 1;; esac; return 0; }
sq_panes() {  # "<session>|<pane id>|<claude pid>" for every claude under a tmux pane (unmapped_report's walk, the pane id kept)
    local sqp; _panes_get_r sqp id; printf '%s' "$sqp" 2>/dev/null   # (a reader that exits early, `| awk … exit`, must not get an EPIPE message; the walk is the shell's own, _claude_panes_r in common.sh)
}
# sq_read <pane> → "<hash>\t<summary>" when a terminal-only prompt is on the screen (pane_prompt's reading of the same 30
# lines), nothing otherwise. The dialog is the run of non-blank lines ending at the last line the pattern matches, cut at
# the rule or box top above it and at 14 lines; its box characters are dropped. The summary is its lines from the title to
# the question (the first line that asks something), joined with " · ", scrubbed (scrub_text), cut to 200 characters; the
# hash is the whole dialog's scrubbed text, so another command in the same kind of dialog is another question.
sq_read() {
    # the last 30 lines up to the last non-blank one: a dialog on a fresh pane sits in the screen's upper half, with blank rows under it
    # that a plain `tail -30` would count (seen on 2.1.307 in a 50-row pane: AskUserQuestion's menu read as nothing)
    # (read by the shell: the awk that cut the last 30 lines and the grep of pane_prompt's pattern were two processes per pane and tick)
    local screen="" i last=0 first=1 hit=0; local -a L=()
    mapfile -t L < <(tmux capture-pane -p -t "$1" 2>/dev/null)
    for i in "${!L[@]}"; do [[ ${L[i]} == *[!$' \t']* ]] && last=$((i + 1)); done
    [ "$last" -gt 30 ] && first=$((last - 29))
    for ((i = first; i <= last; i++)); do screen+="${L[i-1]}"$'\n'; [[ ${L[i-1]} =~ $SALA_PROMPT_RE ]] && hit=1; done
    screen=${screen%$'\n'}
    [ "$hit" = 1 ] || return 1   # pane_prompt's own test first: python runs only for a pane that shows one
    printf '%s\n' "$screen" | RE="$SALA_PROMPT_RE" python3 -c "$SALA_SCRUB_PY"'
import hashlib, os, re, sys
pat = re.compile(os.environ["RE"]); ask = re.compile(r"Do you want to|\?\s*$|Press Enter|Any key to continue|Switch model|Send feedback|Draft preview|quality survey|Feedback drafts|unsent feedback draft")
raw = [l.replace(" ", " ").rstrip() for l in sys.stdin.read().split("\n")]
hits = [i for i, l in enumerate(raw) if pat.search(l)]
if not hits: sys.exit(1)
m = hits[-1]; s = m
box = lambda l: l.strip().strip("│┃║╭╮╰╯┌┐└┘─━═ ").strip()
if any(box(l).startswith("❯") and not re.match(r"❯\s*\d+\.", box(l)) for l in raw[m + 1:]): sys.exit(1)   # the composer below it: no dialog holds the pane (a question quoted in output)
rule = lambda l: re.fullmatch(r"[\s─━═╭╮┌┐]*", l)
while s > 0 and m - s < 14:
    if raw[s - 1].strip() and not rule(raw[s - 1]): s -= 1
    elif not raw[s - 1].strip() and s > 1 and raw[s - 2].strip() and not rule(raw[s - 2]): s -= 1   # one blank row inside the dialog (AskUserQuestion puts one between its question and its options)
    else: break
# a line made only of box-drawing characters, dashes, equals, underscores, dots and spaces is a border or a rule ("╌╌╌╌", "- - - -"
# the prompt box draws), never part of the question; a line with a letter or digit is never dropped, only its box sides are
side = re.compile(r"^[\s\u2500-\u257f]+|[\s\u2500-\u257f]+$"); border = re.compile(r"[\s\-=_·\u2500-\u257f]*")
lines = [re.sub(r"\s+", " ", side.sub("", l)) for l in raw[s:m + 1] if not border.fullmatch(l)]
lines = [l for l in lines if l]
if not lines: sys.exit(1)
q = next((i for i, l in enumerate(lines) if ask.search(l)), None)
head = lines[: (q + 1) if q is not None else 1]
summary = scrub(" · ".join(head))
if len(summary) > 200: summary = summary[:199] + "…"
print(hashlib.sha1(scrub("\n".join(lines)).encode()).hexdigest()[:16] + "\t" + summary.replace("\t", " "))'
}
sq_send() {  # <headline> [bullet…] → the notify command's exit code (sala_post swallows it; a failed post is retried here), 3 with none configured
    local cmd="${SALA_NOTIFY_CMD:-${SALA_WATCH_NOTIFY_CMD:-}}"
    [ -n "$cmd" ] || return 3
    sala_post_text "$@" | sala_board_links "${SALA_STACKSHOT_WEB:-}" | ${SQ_SEND_TIMEOUT:+timeout "$SQ_SEND_TIMEOUT"} sh -c "$cmd" >/dev/null 2>&1   # SQ_SEND_TIMEOUT: set by the hook, which must not hold a turn
}
sq_log() { if declare -F wlog >/dev/null 2>&1; then wlog "$@"; else echo "[$(date -Is)] $*" >> "${WLOG:-$SALA_LOG_DIR/salamander-watch.log}"; fi; }   # the watch's own log, from the hook too
# sq_compose <session> <claude pid> <summary> → SQ_HL and SQ_B (the post's headline and bullets): the one wording of the 90 s
# post and of the instant alert
sq_compose() {
    local url; url=$(session_url "$1" "$(registry_field "$2" bridgeSessionId 2>/dev/null | grep -v '^null$')")
    SQ_HL="⚠️ *$1 is waiting for an answer in its terminal*"
    # "sala" is the web UI's name (Wed Oct 14th 2026: the web UI took the name sala), the one the owner sees in the page
    SQ_B=("it asks: $3" "${url:+answer it in sala: $url}" "until then the session does nothing, and sala types nothing into a pane that shows a question")
}
# THE YOUR MOVE ROW: the same moment that posts the notice also opens a stackshot "Your move" row for the owner
# (`client.py post terminal-prompt open`), and the pane's leaving the wait closes it (`… clear`). stackshot's side may not exist on
# this box yet: a call that fails is logged to the sala log and never touches the notice, its retry or its dedup. The state keeps
# s.<session>.row (1 = the row is open; 2 to 4 = that many clears have failed and are tried again), .pane and .sess beside it.
: "${SALA_STUCK_SENDER:=sala-stuck}"
sq_row_run() {  # <open|clear> <client args…> → 0 when stackshot took the call; its answer goes to the sala log, never to the notice
    local verb=$1 c out rc; shift
    c=$(stackshot_client) || { sq_log "stuck: terminal-prompt $verb: no stackshot client.py on this box (SALA_STACKSHOT_CLIENT, SALA_STACKSHOT_DIR/client.py)"; return 1; }
    out=$(timeout "${SALA_STUCK_ROW_TIMEOUT:-10}" python3 "$c" post terminal-prompt "$verb" "$@" --sender "$SALA_STUCK_SENDER" 2>&1 </dev/null); rc=$?
    out=${out//$'\n'/ }; out=${out:0:300}
    if [ "$rc" = 0 ]; then sq_log "stuck: terminal-prompt $verb ok${out:+: $out}"; return 0; fi
    sq_log "stuck: terminal-prompt $verb failed (exit $rc)${out:+: $out}"; return 1
}
sq_row_open() {  # <session> <key prefix> <pane id> <summary> — opens (or updates) the session's row; row=1 in the state once stackshot took it
    local q; q=$(printf '%s' "$4" | tr -s '[:space:]' ' '); q=${q:0:200}   # one line, 200 characters at most (stackshot's TERMINAL_PROMPT_Q_MAX)
    # `--question` and its text are two arguments: client.py cuts `--name value` pairs out of argv, so `--question=…` is left over and
    # prints the usage (exit 1; seen on the first live run), while a text starting with "-" is fine, taken from the next slot as it is
    sq_row_run open --session "$1" --question "$q" || return 0
    sq_set "$2.row" 1; sq_set "$2.pane" "$3"; sq_set "$2.sess" "$1"
}
sq_settle() {  # <session> <key prefix> — the pane shows no question any more: close its row and drop its record (a failed clear keeps row, pane and sess for the next try, four at most)
    local sess=$1 k=$2 row pane
    sq_get_r row "$k.row"; sq_get_r pane "$k.pane"
    if [ -n "$row" ]; then
        [[ $row =~ ^[0-9]+$ ]] || row=1
        if sq_row_run clear --session "$sess"; then row=""
        elif [ "$row" -ge 4 ]; then sq_log "stuck: terminal-prompt clear for $sess given up after $row tries"; row=""
        else row=$(( row + 1 )); fi
    fi
    sq_drop "$k"
    [ -z "$row" ] || { sq_set "$k.row" "$row"; sq_set "$k.pane" "$pane"; sq_set "$k.sess" "$sess"; }
}
sq_row_hook() {  # <pane id> — a PostToolUse / Stop hook ran in this pane (run under the stuck lock): when it holds a row and shows no question, settle it
    local l kk k="" r sess
    while IFS= read -r l; do
        case $l in s.*.pane="$1") kk=${l%%=*}; k=${kk%.pane}; break ;; esac
    done < "$SQ_STATE" 2>/dev/null
    [ -n "$k" ] || return 0
    [ -n "$(sq_get "$k.row")" ] || return 0
    if r=$(sq_read "$1") && [ -n "$r" ]; then return 0; fi   # another tool finished while a dialog still holds the pane: the row stays
    sess=$(sq_get "$k.sess"); sq_settle "${sess:-${k#s.}}" "$k"
}
# sq_instant <session> <pane id> <claude pid> <notification type> <notification message> [dry] — the Notification hook's alert,
# run under the stuck lock. Claude Code raises permission_prompt only once a prompt has waited about 6 s with no keystroke, which
# is the wait the 90 s post needs a tick for. The dialog is read off the pane exactly as the watch reads it (sq_read), so the
# episode is the watch's own: this writes the same keys (hash, since, posted, tries) and the watch, finding the question
# posted, stays silent. The post goes out through the path the watch uses (sq_send: SALA_NOTIFY_CMD, else SALA_WATCH_NOTIFY_CMD).
# A screen sq_read cannot read (a dialog SALA_PROMPT_RE does not know) is still alerted, on the notification's own words, under a
# hash of its own. A post the notify command refuses is left as the watch's retry (posted empty, tries 1): its next tick sends it.
sq_instant() {
    local sess="$1" pane="$2" pid="$3" ntype="$4" msg="$5" dry="${6:-}" now k r hash sum prev since posted tries rc
    now=$(date +%s); k=$(sq_key "$sess")
    if r=$(sq_read "$pane") && [ -n "$r" ]; then hash=${r%%$'\t'*}; sum=${r#*$'\t'}
    else
        sum=$(printf '%s' "${msg:-$ntype}" | scrub_text | tr -s '[:space:]' ' ' | cut -c1-200)
        hash="n$(printf '%s|%s|%s' "$ntype" "$sum" "$(( now / 300 ))" | sha1sum | cut -c1-15)"   # no dialog to hash: the type and the words, per five minutes
    fi
    prev=$(sq_get "$k.hash"); posted=$(sq_get "$k.posted"); since=$(sq_get "$k.since"); tries=$(sq_get "$k.tries")
    if [ "$prev" = "$hash" ] && [ -n "$posted" ]; then
        [ -n "$dry" ] && echo "$sess: this question is posted already (by the watch or an earlier alert); nothing to send"
        return 0
    fi
    [ "$prev" = "$hash" ] || { since=$now; tries=0; }
    sq_compose "$sess" "$pid" "$sum"
    if [ -n "$dry" ]; then echo "would post for $sess (instant, $ntype):"; sala_post_text "$SQ_HL" "${SQ_B[@]}" | sed 's/^/    /'; return 0; fi
    sq_set "$k.hash" "$hash"; sq_set "$k.since" "${since:-$now}"
    sq_send "$SQ_HL" "${SQ_B[@]}"; rc=$?
    case "$rc" in
        0) sq_set "$k.posted" "$now"; sq_set "$k.tries" 0; sq_set "$k.instant" "$now"; sq_log "stuck: instant alert for $sess ($ntype): $sum"; sq_row_open "$sess" "$k" "$pane" "$sum" ;;
        3) sq_set "$k.posted" "$now"; sq_set "$k.tries" 0; sq_log "stuck: $sess shows a question ($ntype), but no notify command is configured (SALA_WATCH_NOTIFY_CMD): $sum"; sq_row_open "$sess" "$k" "$pane" "$sum" ;;
        *) sq_set "$k.posted" ""; sq_set "$k.tries" $(( ${tries:-0} + 1 )); sq_log "stuck: the instant alert for $sess failed (exit $rc) — the watch tries again at its next tick" ;;
    esac
    return 0
}
