# lib/recycle-request.sh — a session's request for an automatic recycle.
# The flag keeps its name, but the wait is per pane now: the recycle relaunches each pane once it is idle.
#
# THE USAGE: `recycle --when-idle --help` prints a blank line, then from its first `salamander recycle --when-idle` line through the `--cancel` line, so keep it contiguous.
#   salamander recycle --when-idle [--from NAME] [--change REF] "<reason>"   record a request; any session may run it
#       (--change REF: the change it waits for, a commit sha or pr<N>, optionally <repo>:REF; nothing is recycled until it is in the checkout)
#   salamander recycle --when-idle --list                      the open requests
#   salamander recycle --when-idle --cancel [ID]               drop one request, or all of them
#
# It only records: one marker file per request under $SALA_STATE_DIR/recycle-requests (the time, who asked, why). It
# never recycles and never needs the master. `sala watch` (lib/watch.sh, AUTO-RECYCLE) starts the recycle the master's
# cue would at its next run (no whole-box idle wait; a busy pane is skipped and retried once idle),
# at most once an hour, and clears the markers it served.
# A request older than 24 h expires with a line in the watch log.
# TWO GUARDS (Tue Nov 3rd 2026; lib/watch.sh, auto_recycle applies them to a request and to a board flag alike):
#  - a flag that names its change (--change here, `~<ref>` on a board token) is held back while that change is not in the
#    production checkout's HEAD: a recycle before the deploy relaunches every pane on the code it already runs, and the one
#    after the deploy relaunches them all again (rr_change_state, below). Held at most SALA_RECYCLE_REF_WAIT s after the
#    flag (24 h), so a change that never lands cannot hold it forever.
#  - a flag that every live pane was relaunched after is served without a recycle: the request is dropped, the board is told.
# The marker is one TSV line: epoch, who, why, and the change reference when there is one (a 3-field marker of an older sala reads as before).
# Sourced by bin/salamander (rr_main) and by lib/watch.sh (the helpers).

RR_DIR="$SALA_STATE_DIR/recycle-requests"
RR_TTL=86400
: "${SALA_RECYCLE_REF_WAIT:=86400}"    # a flag that names a change holds the recycle back at most this long after it was raised (0 = the reference is ignored)
: "${SALA_RECYCLE_REF_SLACK:=300}"     # the deploy runs a little after the merge: a pane started within this long of the merge does not count as carrying the change
: "${SALA_RECYCLE_REF_REPOS:=}"        # "name=path name=path": the checkouts for a reference written <name>:REF; no prefix, `salamander` and `sala` mean this one
rr_files() { local f; for f in "$RR_DIR"/*.req; do [ -e "$f" ] && printf '%s\n' "$f"; done; return 0; }   # oldest first (the name starts with the epoch, and a glob comes sorted): no ls and sort
rr_expire() {  # removes requests older than RR_TTL; prints "<who>: <why> (asked <when>)" for each
    local f ep by why chg now; _now_r now
    for f in $(rr_files); do
        IFS=$'\t' read -r ep by why chg < "$f" || true
        case "$ep" in ''|*[!0-9]*) ep=0;; esac
        [ $((now - ep)) -ge "$RR_TTL" ] || continue
        rm -f "$f" && echo "${by:-?}: ${why:-no reason given} (asked $(local_human "$ep"))"
    done
}
# rr_ref_parse <ref> → RR_REPO (may be empty), RR_KIND (pr|sha) and RR_VAL set; 1 when the text is not a change reference.
# A reference is a commit sha (7-40 hex characters) or a pull request number written pr<N> (or #<N>), either one optionally
# prefixed with its repository's name and a colon (stackshot:pr12): the name picks the checkout it is looked up in.
rr_ref_parse() {
    local r="$1"; RR_REPO=""; RR_KIND=""; RR_VAL=""
    case "$r" in *:*) RR_REPO=${r%%:*}; r=${r#*:};; esac
    case "$r" in
        [Pp][Rr][0-9]*|'#'[0-9]*) r=${r#[Pp][Rr]}; r=${r#'#'}; case "$r" in *[!0-9]*) return 1;; esac; RR_KIND=pr; RR_VAL=$((10#$r));;
        *) case "$r" in ''|*[!0-9a-fA-F]*) return 1;; esac; [ ${#r} -ge 7 ] && [ ${#r} -le 40 ] || return 1; RR_KIND=sha; RR_VAL=$r;;
    esac
    return 0
}
rr_ref_dir() {  # RR_REPO → the checkout it names; nothing when no checkout is known for it
    local kv p
    case "$RR_REPO" in ''|salamander|sala) echo "$SALA_ROOT"; return 0;; esac
    for kv in $SALA_RECYCLE_REF_REPOS; do
        [ "${kv%%=*}" = "$RR_REPO" ] || continue
        p=${kv#*=}; case "$p" in "~/"*) p="$HOME/${p#\~/}";; esac
        echo "$p"; return 0
    done
    return 0
}
# rr_change_state <ref> → one line: `live <epoch>` (the change is in the checkout's HEAD; the epoch is when it landed: its merge
# commit's time), `pending <HEAD short sha>` (not in it yet: not merged, or merged and not deployed), or `unknown <why>` (the
# reference cannot be read, or no checkout is known for its repository: the caller treats that as live, so a flag never waits on
# what sala cannot check). A pull request is in when HEAD's history holds its merge commit ("Merge pull request #N from …",
# which release.sh's merge makes) or its squash commit (a subject ending "(#N)"); a sha, when it is an ancestor of HEAD.
rr_change_state() {
    local d head ct=""; rr_ref_parse "$1" || { echo "unknown not a commit sha or pr<N>"; return 0; }
    d=$(rr_ref_dir)
    { [ -n "$d" ] && git -C "$d" rev-parse --git-dir >/dev/null 2>&1; } || { echo "unknown no checkout known for ${RR_REPO:-this one}"; return 0; }
    head=$(git -C "$d" rev-parse --short HEAD 2>/dev/null)
    if [ "$RR_KIND" = pr ]; then
        ct=$(git -C "$d" log HEAD -n1 -E --format=%ct --grep="(^Merge pull request #$RR_VAL from |\\(#$RR_VAL\\)\$)" 2>/dev/null)
    elif git -C "$d" rev-parse -q --verify "$RR_VAL^{commit}" >/dev/null 2>&1 && git -C "$d" merge-base --is-ancestor "$RR_VAL" HEAD 2>/dev/null; then
        ct=$(git -C "$d" log HEAD --ancestry-path --merges --reverse --format=%ct "$RR_VAL..HEAD" 2>/dev/null | head -1)   # the merge that brought it onto the branch
        [ -n "$ct" ] || ct=$(git -C "$d" log -n1 --format=%ct "$RR_VAL" 2>/dev/null)
    fi
    case "$ct" in ''|*[!0-9]*) echo "pending ${head:-?}";; *) echo "live $ct";; esac
}
rr_requester() {  # the session that runs this: its tmux session name, else a plain shell
    local s; [ -n "${TMUX_PANE:-}" ] && s=$(tmux display -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null) && [ -n "$s" ] && { echo "$s"; return; }
    local _un; _uname_r _un; echo "a shell (${_un:-user})"
}
rr_main() {
    local from="" act=add reason="" id="" change="" f ep by why chg n=0
    while [ $# -gt 0 ]; do case "$1" in
        --when-idle) ;;
        --from) from="${2:-}"; [ -n "$from" ] || die "--from needs a session name"; shift ;;
        --change) change="${2:-}"; rr_ref_parse "$change" || die "--change takes the change this request waits for: a commit sha (7-40 hex characters) or pr<N>, optionally <repo>:… (got '$change')"; shift ;;
        --list) act=list ;;
        --cancel) act=cancel; case "${2:-}" in ''|-*) ;; *) id="$2"; shift ;; esac ;;
        -h|--help) echo; awk '/^#   salamander recycle --when-idle \[--from /{p=1} p{print} /^#   salamander recycle --when-idle --cancel /{exit}' "$SALA_ROOT/lib/recycle-request.sh" | sed 's/^# \{0,1\}//'; return 0 ;;
        -*) die "unknown option for recycle --when-idle: $1 (see: salamander recycle --when-idle --help)" ;;
        *) [ -z "$reason" ] && reason="$1" || reason="$reason $1" ;;
    esac; shift; done
    mkdir -p "$RR_DIR"
    case "$act" in
        list)
            rr_expire >/dev/null
            for f in $(rr_files); do
                IFS=$'\t' read -r ep by why chg < "$f" || true; n=$((n+1))
                printf '%s\t%s\t%s\t%s%s\n' "$(basename "$f" .req)" "$(local_human "${ep:-0}")" "${by:-?}" "${why:-}" "${chg:+$'\t'change: $chg}"
            done
            [ "$n" -gt 0 ] || echo "no recycle requests"
            ;;
        cancel)
            if [ -n "$id" ]; then
                [ -f "$RR_DIR/$id.req" ] || die "no recycle request '$id' (see: salamander recycle --when-idle --list)"
                rm -f "$RR_DIR/$id.req"; echo "dropped recycle request $id"
            else
                n=$(rr_files | wc -l | tr -d ' '); rm -f "$RR_DIR"/*.req; echo "dropped $n recycle request(s)"
            fi
            ;;
        add)
            [ -n "$reason" ] || die "usage: salamander recycle --when-idle [--from NAME] [--change REF] \"<reason>\"  (or --list, --cancel [ID])"
            [ -n "$from" ] || from=$(rr_requester)
            reason=$(printf '%s' "$reason" | tr '\t\n\r' '   ' | cut -c1-300); from=$(printf '%s' "$from" | tr '\t\n\r' '   ')
            ep=$(date +%s); id="$ep-$$"
            printf '%s\t%s\t%s%s\n' "$ep" "$from" "$reason" "${change:+$'\t'$change}" >"$RR_DIR/$id.req.tmp" && mv -f "$RR_DIR/$id.req.tmp" "$RR_DIR/$id.req" || die "could not write $RR_DIR/$id.req"
            echo "recorded recycle request $id from $from: $reason${change:+ (it waits until $change is in the checkout)}"
            if [ "${SALA_AUTO_RECYCLE:-on}" = on ]; then
                echo "sala watch starts the recycle at its next run (every 2 min); each busy pane is relaunched once it is idle (at most one an hour; the request expires after 24 h)"
            else
                echo "⚠ SALA_AUTO_RECYCLE is off in $SALA_CONFIG: nothing will act on it until it is on, or the master runs a recycle"
            fi
            ;;
    esac
}
