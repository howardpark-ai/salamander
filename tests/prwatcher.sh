#!/usr/bin/env bash
# tests/prwatcher.sh — the PR-watcher cleanup job (lib/pr_watcher_cleanup.py, systemd/sala-pr-watcher-cleanup.{service,timer}, docs/units.md).
# tests/prwatcher_scenario.py runs the job as its own command in a locked temp folder (removed on every exit, pass or fail) against a fake API (a
# local http server on 127.0.0.1: the scheduled-task list, the sessions, the delete), a fake `gh` and a fake message command, with the clock injected:
# a done task of an archived, missing or not-connected session deleted at once; of a live session asked once and deleted 24 h later; a merged or closed
# pull request; an active task, a task it cannot place and a recurring routine left alone; API errors leaving every task as it was; --dry-run changing
# nothing; no token in any output. No network beyond 127.0.0.1, no tmux, no claude, no process is killed.
# Usage: bash tests/prwatcher.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
command -v python3 >/dev/null 2>&1 || { echo "  SKIP no python3"; echo "prwatcher: skipped"; exit 0; }
python3 -I "$ROOT/tests/prwatcher_scenario.py"; rc=$?
[ "$rc" = 0 ] && echo "prwatcher: pass" || echo "prwatcher: FAIL"
exit $rc
