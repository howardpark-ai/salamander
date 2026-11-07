# lib/snapshot.sh — event-driven tmux-resurrect snapshot.
#
# tmux-continuum's periodic autosave rides the status-line refresh, which only ticks while a
# tmux CLIENT is attached. On a box driven entirely through Remote Control nobody is attached,
# the autosave silently stops, and the next boot restores a days-old layout: every pane created
# since is gone and revive never sees it. So snapshot on EVENTS instead — wire this
# to tmux's session-created / session-closed / session-renamed hooks and to Claude Code's
# SessionStart hook (a new or resumed conversation changes the pane→conversation binding) — and
# keep any timer only as the safety net. `spawn` already saves on its own.
#
#   salamander snapshot        debounced save a few seconds from now (safe to fire in bursts)
#   salamander snapshot --now  save immediately, in the foreground
#
# Rules: never save while a resurrect RESTORE is running (a half-restored layout would become
# `last`); coalesce bursts (20 SessionStart hooks after a boot revive) into one save; saves are
# serialised with a lock. SALA_SNAPSHOT_CMD replaces the direct save.sh call (e.g. a systemd user
# service that a timer shares) — it is run through `sh -c`.

# the stamp lives in the user's runtime dir: $XDG_RUNTIME_DIR, else /run/user/<uid> when it exists (a tmux hook or a timer
# often runs without XDG_RUNTIME_DIR set), and only else /tmp
if [ -n "${XDG_RUNTIME_DIR:-}" ]; then STAMP_DIR=$XDG_RUNTIME_DIR
elif [ -d "/run/user/$(id -u)" ]; then STAMP_DIR=/run/user/$(id -u)
else STAMP_DIR=/tmp; fi
STAMP="$STAMP_DIR/salamander-snapshot.stamp"
: "${SALA_SNAPSHOT_DELAY:=4}"
restore_running() { pgrep_mine 'tmux-resurrect/scripts/[r]estore.sh' >/dev/null; }   # this instance's restore only (common.sh)
# SHUTDOWN GUARD: once `sala reboot` has written its marker for THIS boot, the box is going down; tmux's
# session-closed hooks then fire as the panes die, and a save then (with only some sessions left) became `last`,
# so the boot restored only those. No save between the marker and the reboot: the drain's own snapshot stands (shutting_down: common.sh).
do_save() {
    tmux has-session 2>/dev/null || return 0
    restore_running && return 0
    shutting_down && return 0
    mkdir -p "$SALA_RESURRECT_DIR"
    if [ -n "${SALA_SNAPSHOT_CMD:-}" ]; then sh -c "$SALA_SNAPSHOT_CMD"; return; fi
    [ -x "$SALA_RESURRECT_SAVE" ] || die "tmux-resurrect save script not found at $SALA_RESURRECT_SAVE"
    if command -v flock >/dev/null 2>&1; then flock -w 60 "$SALA_RESURRECT_DIR/.snapshot.lock" "$SALA_RESURRECT_SAVE" >/dev/null 2>&1
    else "$SALA_RESURRECT_SAVE" >/dev/null 2>&1; fi
}
# THE FLEET'S SERVER ONLY (common.sh, fleet_only): the session hooks of a probe server started with
# ~/.tmux.conf would save ITS layout over the fleet's restore point, which the next boot restores. Elsewhere: nothing saved.
fleet_only snapshot
case "${1:-}" in
    --now) do_save; exit ;;
    '')
        restore_running && exit 0
        shutting_down && exit 0
        # debounce: a delayed save already pending covers this event too
        if [ -f "$STAMP" ] && [ $(( $(date +%s) - $(stat -c %Y "$STAMP" 2>/dev/null || echo 0) )) -lt $((SALA_SNAPSHOT_DELAY + 2)) ]; then exit 0; fi
        touch "$STAMP"
        setsid nohup bash -c 'sleep "$1"; exec "$0" snapshot --now' "$SALA_BIN" "$SALA_SNAPSHOT_DELAY" >/dev/null 2>&1 </dev/null &
        exit 0 ;;
    *) die "usage: salamander snapshot [--now]" ;;
esac
