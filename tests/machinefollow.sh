#!/usr/bin/env bash
# tests/machinefollow.sh — machine-follow, the fleet-follow dispatcher (lib/machine-follow.py, systemd/machine-follow.{path,timer,service},
# systemd/machine-follow@.service, docs/units.md "machine-follow").
# tests/machinefollow_scenario.py imports the script and drives it with the steps, the probe and the systemd calls faked, in a locked temporary folder
# (removed on every exit, pass or fail), under made-up machine names: the data file (its shape, a wrong entry named, the setting that finds it, a missing
# one), the units against the script and the data, who is due and who is started, the settle rule, a skip (75) versus a failure, the state file written on
# success only, the two steps of one entry, the real runner, the real systemctl calls against a stub, the real fingerprints against throwaway git
# repositories, and the real script as a command with an isolated HOME. No ssh, no systemd, no real machine, no real data file, no tmux, no claude; the one
# process killed is the step the runner test started itself, by its own process group.
# Usage: bash tests/machinefollow.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
command -v python3 >/dev/null 2>&1 || { echo "  SKIP no python3"; echo "machinefollow: skipped"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "  SKIP no git"; echo "machinefollow: skipped"; exit 0; }
python3 -I "$ROOT/tests/machinefollow_scenario.py"; rc=$?
[ "$rc" = 0 ] && echo "machinefollow: pass" || echo "machinefollow: FAIL"
exit $rc
