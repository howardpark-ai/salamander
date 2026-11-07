# lib/mockup.sh — `sala mockup`: an HTML mockup served by sala-web as a numbered page, so a session without the Artifact tool hands a reader a link
# instead of a picture (docs/mockup.md). Sourced by bin/salamander; the work is lib/mockup.py (standard library, no model call).
mockup_usage() {
    cat <<'USAGE'
usage: sala mockup add FILE|-
       sala mockup FILE            (the same as add; a file called add, list, remove or clean is written ./add …)
       sala mockup list [--json]
       sala mockup remove N
       sala mockup clean [--dry-run] [--days N] [--max-bytes N]

  add     stores an HTML file (a path, or - for stdin) under the next number and prints the page's address, https://<sala's address>/mockup/<n>, on
          stdout and nothing else (so $(sala mockup add page.html) is the link). sala-web serves it behind the same sign-in as the rest of the site, in a
          sandbox: the page's own scripts and styles run, but it cannot reach sala's API or cookies and fetches nothing (no network, no external
          script or stylesheet); data: images work, and Google Fonts (fonts.googleapis.com, fonts.gstatic.com). Put
          <meta name="viewport" content="width=device-width, initial-scale=1"> in the page so a phone shows it at its own width (add notes when it is missing).
          Refused: an empty file, one over 5 MiB, one that is not UTF-8 or holds a NUL byte. Numbers go up by one and are never given twice, also after a
          page is deleted. The address is SALA_SESSION_URL's scheme and host; without that setting the path /mockup/<n> is printed and a note says so.
          Pages are stored under $SALA_STATE_DIR/mockups (mode 700), on this machine only.
  list    the stored pages: number, size, age, address (--json: the same as an array).
  remove  delete one page now (its number stays used).
  clean   the daily pass (sala-mockup-clean.timer), two rules in this order: delete the pages older than --days (default SALA_MOCKUP_KEEP_DAYS, 7) that
          no open board item links; then, if the folder still holds more than --max-bytes (default SALA_MOCKUP_MAX_BYTES, 1 GB = 1073741824), delete
          the oldest pages first, a page an open board item links last (only when every other page is gone and it is still over).
          SALA_MOCKUP_REFERENCES says how to tell what is linked: unset = keep every page (both rules) and say why; none = nobody links a page;
          otherwise a command (run without a shell) whose output holds the open items' text: every /mockup/<n> in it counts as linked. A command
          that fails keeps every page (exit 1). --dry-run deletes nothing.
USAGE
}
case "${1:-}" in
    ''|-h|--help|help) mockup_usage; [ -n "${1:-}" ] || exit 2; exit 0 ;;
    add|list|remove|clean) ;;
    -) set -- add "$@" ;;
    -*) echo "salamander mockup: unknown option '$1'" >&2; mockup_usage >&2; exit 2 ;;
    *) set -- add "$@" ;;
esac
export SALA_STATE_DIR
# the config file is sourced (common.sh), so a `NAME=value` line there is a shell variable, not part of the environment lib/mockup.py reads: export the
# three settings it takes (a no-op for one that is unset; the systemd service has only PATH in its environment, so the config is its only source)
export SALA_MOCKUP_KEEP_DAYS SALA_MOCKUP_MAX_BYTES SALA_MOCKUP_REFERENCES
SALA_MOCKUP_TEMPLATE=$(session_url_template); export SALA_MOCKUP_TEMPLATE
exec python3 -I -S "$SALA_ROOT/lib/mockup.py" "$@"
