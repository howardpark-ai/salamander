#!/usr/bin/env bash
# lib/cipoll-tell.sh <session> — the CI-run poller's message (stdin) into that session's inbox as a turn, with sala's own inbox push
# (lib/common.sh _inbox_push). Run by lib/cipoll.py only (docs/ci-runs.md, "A stuck run").
# Exit 0 delivered, 2 the session is not live, 3 it is paused (a message would start a turn before its relaunch), 4 no inbox or the push failed.
set -u
SALA_ROOT=$(cd "$(dirname "$0")/.." && pwd); SALA_BIN="$SALA_ROOT/bin/salamander"; export SALA_BIN SALA_ROOT
. "$SALA_ROOT/lib/common.sh"
pane=$(tmux list-panes -t "$(tmux_win_t "$1")" -F '#{pane_id}' 2>/dev/null | head -1)
pid=""; [ -z "$pane" ] || pid=$(claude_pid_under "$(tmux display -p -t "$pane" '#{pane_pid}')" 2>/dev/null)
[ -z "$pid" ] || ! pause_active "$pid" || exit 3
_inbox_push "$1" "$(cat)"
