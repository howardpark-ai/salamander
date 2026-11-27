# lib/notice.sh — `sala notice`: a one-time line every LIVE session sees at its next turn, with no relaunch. Sourced by bin/salamander;
# the store and the delivery are lib/notice.py, the delivery's fast path is `salamander hook post-tool` and `hook prompt` (lib/hook.sh).
notice_usage() {
    cat <<'USAGE'
usage: sala notice add "<text>" --from <sender> [--until <when>]     (-h, --help or help as the first word after add prints this)
       sala notice list [--json]
       sala notice drop <id>

  add     appends a notice: one line of at most 400 characters (no newline or tab). Every live session gets it once, as
          "[sala notice <id> from <sender>] <text>", at its next tool call or prompt, with no relaunch; several due at once come in
          one block, oldest first. A session whose conversation started after the notice was created skips it (it loaded the
          current rules and memory at its start). --from is required: your own session name. --until: when it expires, an
          epoch, a span (90m, 12h, 7d) or an ISO 8601 time (no zone = UTC); default 7 days. Prints the id and how many live
          sessions it will reach. A text that starts with "-" is refused (exit 2, nothing posted) because it looks like an option
          ("--help", "-5 degrees" and "- a bullet" alike): start the text with another character.
  list    the active notices, each with how many live sessions have had it (or started after it) and how many are still due.
  drop    withdraws a notice: a session not yet reached never gets it.
  Delivery needs the hooks `hook post-tool` (PostToolUse, already registered) and `hook prompt` (UserPromptSubmit; docs/notices-and-hooks.md,
  "Telling every session something"). Notices live in $SALA_STATE_DIR/notices.tsv;
  a notice every live session has had or skipped is dropped after a day; otherwise it expires at --until (default 7 days). Pruning runs on add, list, drop and a watch tick.
USAGE
}
_notice_py() { SALA_STATE_DIR="$SALA_STATE_DIR" SALA_REG_DIR="$SALA_REG_DIR" python3 -I -S "$SALA_ROOT/lib/notice.py" "$@"; }
case "${1:-}" in
    ''|-h|--help|help) notice_usage; [ -n "${1:-}" ] || exit 2; exit 0 ;;
    add)
        shift
        case "${1:-}" in -h|--help|help) notice_usage; exit 0 ;; esac   # never the text of a notice: "sala notice add --help" once posted "--help" to every session
        _o=$(_notice_py add "$@") || exit $?
        IFS=$'\t' read -r _id _until _reach <<< "$_o"
        echo "✓ notice $_id added, expires $(local_human "$_until"); it reaches $_reach live session$([ "$_reach" = 1 ] || echo s) at their next turn (sala notice list; sala notice drop $_id)" ;;
    list)
        shift
        if [ "${1:-}" = --json ]; then _notice_py list --json; exit $?; fi
        [ -z "${1:-}" ] || { notice_usage >&2; exit 2; }
        _o=$(_notice_py list) || exit 1
        [ -n "$_o" ] || { echo "no active notices"; exit 0; }
        while IFS=$'\t' read -r _id _at _from _until _had _due _text; do
            echo "$_id  from $_from, written $(local_human "$_at"), expires $(local_human "$_until"): had it or started after it $_had, still due $_due"
            echo "    $_text"
        done <<< "$_o" ;;
    drop)
        shift; _o=$(_notice_py drop "$@") || exit 1
        echo "✓ notice $_o withdrawn: a session not yet reached never gets it" ;;
    prune) _notice_py prune ;;
    *) echo "salamander notice: unknown verb '$1'" >&2; notice_usage >&2; exit 2 ;;
esac
