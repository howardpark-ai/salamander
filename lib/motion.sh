# lib/motion.sh — `sala motion`: the short lines a session sets itself to say what is in motion right now; sala-web's chat page shows them under
# "In motion" (web/README.md). Sourced by bin/salamander; the work is lib/motion.py (standard library, no model call).
motion_usage() {
    cat <<'USAGE'
usage: sala motion add "<line>" [--for NAME]
       sala motion done "<line>"|N [--for NAME]
       sala motion clear [--for NAME]
       sala motion list [--json] [--for NAME]

  add     puts a line on the session's list: one line of text, at most 120 characters (a longer one is refused, never cut). At most 8 lines are
          kept; a ninth is refused with a sentence. A line already listed only has its 24 hours started again.
  done    takes a line off, by its exact text or by its number in `list`.
  clear   takes every line off.
  list    the lines still in force, numbered ("nothing right now" when there are none); --json: the same as an array of {n, text, at}.

  The session is the one this command runs in; --for NAME says another's (and is required outside a session). A line expires 24 hours after it was
  set; an expired line is not listed and the next write drops it. The lines are the session's own words: nothing else writes them and no model
  filters them. Stored as one small file per session under $SALA_STATE_DIR/motion (mode 700, files 600), written whole and renamed into place.
USAGE
}
case "${1:-}" in
    ''|-h|--help|help) motion_usage; [ -n "${1:-}" ] || exit 2; exit 0 ;;
    add|done|clear|list) ;;
    -*) echo "salamander motion: unknown option '$1'" >&2; motion_usage >&2; exit 2 ;;
    *) echo "salamander motion: unknown verb '$1' (add, done, clear, list)" >&2; motion_usage >&2; exit 2 ;;
esac
export SALA_STATE_DIR
# the session this runs in, from sala's registry (the same walk up to the claude process `sala ready` makes); empty outside a session, and the
# program then asks for --for
if [ -z "${SALA_MOTION_SELF:-}" ]; then
    _mo_cpid=$(own_claude_pid 2>/dev/null) && SALA_MOTION_SELF=$(registry_field "$_mo_cpid" name 2>/dev/null)
    [ "${SALA_MOTION_SELF:-}" = null ] && SALA_MOTION_SELF=""
fi
export SALA_MOTION_SELF
exec python3 -I -S "$SALA_ROOT/lib/motion.py" "$@"
