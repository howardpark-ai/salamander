# lib/where.sh — `sala where`: which machine ("box") the owner is working from right now. Sourced by bin/salamander; the record and the
# scan are lib/where.py. A step meant for the owner's own machine (a browser pick, a step bound to his network) goes to that box.
where_usage() {
    cat <<'USAGE'
usage: sala where [--json]
       sala where --scan
       sala where set <box> [--by <session>]
       sala where clear

  (no verb)  prints one line: the box the owner is on, who told it or that it was seen over ssh, the time and its age, "(stale)" when the
             record is older than 12 hours; "no record" when there is none. --json prints the record plus age_s. A plain read runs the scan
             first. Times are in the zone of TZ.
  set        records <box>, which must be a fleet machine name (the fleet names file; an unknown name is refused and the known ones listed).
             When the box differs from the record, the old where notice is dropped and one new `sala notice` is added (12 hours), so every
             live session learns of the change once; the same box only refreshes the time and adds no notice. --by: your own session name.
  --scan     the second source: the ssh-attached tmux client with the newest activity in the last 10 minutes, its SSH_CONNECTION address
             mapped to a fleet box through `tailscale status --json`; a different box than the record, with newer activity, is recorded
             as above (via ssh). Any failure (no tmux, no tailscale, an unknown address) is silent and changes nothing. The watch tick runs it.
  clear      removes the record and its notice.
  The record is $SALA_STATE_DIR/where.json: {"box","at","via":"told"|"ssh","by"}.
USAGE
}
case "${1:-}" in
    -h|--help|help) where_usage; exit 0 ;;
esac
SALA_STATE_DIR="$SALA_STATE_DIR" SALA_FLEET_NAMES="${SALA_FLEET_NAMES:-}" SALA_MACHINE_FOLLOW_MACHINES="${SALA_MACHINE_FOLLOW_MACHINES:-}" \
    python3 -I -S "$SALA_ROOT/lib/where.py" "$@"
exit $?
