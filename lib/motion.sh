# lib/motion.sh — `sala motion`: the short topics a session has promised to report back and has not reported yet; sala-web's chat session view shows the chat
# session's in its strip under "On it" (web/README.md). Sourced by bin/salamander; the work is lib/motion.py (standard library, no model call).
motion_usage() {
    cat <<'USAGE'
usage: sala motion add "<line>" [--for NAME]
       sala motion done "<line>"|N [--link URL] [--for NAME]
       sala motion clear [--for NAME]
       sala motion list [--json] [--for NAME]

  The list of what a session has promised to report back and has not reported yet; sala-web shows the chat session's in its strip, under "On it".
  Add a line when you hand work off with a promise to report back in the chat, and
  mark it done only in the turn you give the result in the chat: a builder's done report or a closed item is the cue to report it, never the close itself.
  A line is one short topic in the owner's language, such as "research on X".

  add     puts a line on the session's list: one line of text, at most 120 characters (a longer one is refused, never cut). At most 8 lines are
          kept; a ninth is refused with a sentence. Adding a line already open changes nothing: it keeps the time it was first added. After a
          line is done, the same text added again starts a new open line; the done one stays until the owner confirms it.
  done    marks a line done, by its exact text or by its number in `list`. The line is not removed: it waits, with the time it was done and its
          result link, in the owner's "my turn" list on the chat page until he confirms it there. --link URL: the result's address (https, or an
          in-app path /... or anchor #...); without it the page links the first chat reply at or after the done time.
  clear   takes every line off, done ones included.
  list    the lines on the list, numbered ("nothing right now" when there are none); a done line is marked as waiting for the owner's confirm;
          --json: the same as an array of {n, text, at, done, link}.

  The session is the one this command runs in; --for NAME says another's (and is required outside a session). A done line stays until the owner
  confirms it or it is cleared: nothing expires it. The lines are the session's own words: nothing else writes them and no model filters them.
  Stored as one small file per session under $SALA_STATE_DIR/motion (mode 700, files 600), written whole and renamed into place.
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
