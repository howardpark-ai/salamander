#!/usr/bin/env bash
# tests/mq.sh — `salamander mq`, our own merge queue in shadow mode (lib/mq.sh, lib/mq/, docs/mq.md). tests/mq_scenario.py builds, in its own locked temp
# folder (removed on every exit, pass or fail), a local bare repository standing in for origin, real git over it, and a fake `gh`, a fake `salamander` (the CI-run
# poller's reader) and a fake `systemd-run` on a fake PATH that answer from files and log every call; the call counts of an entry are asserted from those logs and
# from the entry's own record. The CLI runs through the real verb (`salamander mq …`); the driver runs as the unit would run it. A driver crash is injected with
# MQ_CRASH_AT=<phase>; nothing is killed, there is no tmux, no network, and no claude. Needs python3 3.11+ (tomllib), git and flock.
# Usage: bash tests/mq.sh   (a scenario by name: bash tests/mq.sh sc_doctor)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
command -v git >/dev/null 2>&1 || { echo "  SKIP no git"; echo "mq: skipped"; exit 0; }
python3 -c 'import sys, tomllib; sys.exit(sys.version_info < (3, 11))' 2>/dev/null || { echo "  SKIP python3 older than 3.11 (no tomllib), the version mq needs"; echo "mq: skipped"; exit 0; }
python3 -I "$ROOT/tests/mq_scenario.py" "$@"; rc=$?
[ "$rc" = 0 ] && echo "mq: pass" || echo "mq: FAIL"
exit $rc
