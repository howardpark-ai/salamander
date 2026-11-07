#!/usr/bin/env bash
# contrib/briefing/systemd: three oneshot services (the lean summary, among them) and their daily timers load, and each ExecStart is an executable
# script (a unit that fails to load or start sends no post). systemd-analyze verify runs on copies whose %h paths point at
# this checkout; skipped where systemd is absent. Each service runs through `salamander lane exec bedrock --`. (the key-by-key greps and the calendar echoes were dropped.)
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd); U=$ROOT/contrib/briefing/systemd
fail=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
for job in defunct release summary-lean; do
    s=$U/sala-briefing-$job.service; t=$U/sala-briefing-$job.timer
    [ -f "$s" ] && [ -f "$t" ] || { bad "sala-briefing-$job.{service,timer} missing"; continue; }
    # the unit itself runs the briefing with no SDK try (no drop-in needed): on the bedrock lane, from sala's lane config
    grep -qE "^ExecStart=%h/.local/bin/salamander lane exec bedrock -- %h/salamander/contrib/briefing/" "$s" && grep -qxF "X-Model-Lane=bedrock" "$s" && ok "sala-briefing-$job.service: bedrock lane through salamander lane exec" || bad "sala-briefing-$job.service: not on bedrock through lane exec"
    for line in 'Environment=BRIEFING_CLAUDE_CONFIG_DIR=' 'Environment=BRIEFING_CRON_LOG=1' \
                'UnsetEnvironment=ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS'; do
        grep -qxF "$line" "$s" && ok "sala-briefing-$job.service: $line" || bad "sala-briefing-$job.service lacks: $line"
    done
    # the two units whose turn goes through lib.sh / release-watch.sh try the API key while it has credit, so they do not force
    # the login path; the lean summary calls claude -p itself (no SDK path) and keeps BRIEFING_BACKEND=cli
    if [ "$job" = summary-lean ]; then grep -qxF 'Environment=BRIEFING_BACKEND=cli' "$s" && ok "sala-briefing-$job.service: no SDK try (claude -p itself)" || bad "sala-briefing-$job.service lacks BRIEFING_BACKEND=cli"
    else grep -q '^Environment=BRIEFING_BACKEND' "$s" && bad "sala-briefing-$job.service forces a backend: the key would never be tried" || ok "sala-briefing-$job.service: no forced backend (the API key is tried while it has credit)"; fi
    # the output goes to cron.log in the script's own log directory (BRIEFING_CRON_LOG): the unit names no directory
    grep -q '^Standard\(Output\|Error\)=' "$s" && bad "sala-briefing-$job.service names an output path" || ok "sala-briefing-$job.service: no output path of its own (BRIEFING_CRON_LOG)"
    mkdir -p "$T/u" "$T/cache"
    for f in "$s" "$t"; do sed -e "s#%h/.local/bin/salamander#$ROOT/bin/salamander#g" -e "s#%h/salamander#$ROOT#g" "$f" > "$T/u/$(basename "$f")"; done
done
if command -v systemd-analyze >/dev/null 2>&1; then
    # verify loads the system's own units too; only lines naming ours count
    out=$(systemd-analyze verify "$T"/u/* 2>&1); rc=$?
    ours=$(printf '%s\n' "$out" | grep 'sala-briefing' || true)
    if [ $rc = 0 ] && [ -z "$ours" ]; then ok "systemd-analyze verify (6 units)"
    elif printf '%s\n' "$out" | grep -qiE 'failed to (connect|initialize)|no such file or directory.*/run/systemd|not been booted'; then
        echo "  skip systemd-analyze verify (no usable systemd here): $(printf '%s\n' "$out" | head -1)"
    elif [ -z "$ours" ] && printf '%s\n' "$out" | grep -qiE "failed to create directory '?/run/systemd"; then
        echo "  skip systemd-analyze verify (unprivileged on a box not booted by systemd, as the WSL2 CI runner: it cannot create /run/systemd): $(printf '%s\n' "$out" | head -1)"
    else bad "systemd-analyze verify rc=$rc: $out"; fi
else
    echo "  skip systemd-analyze not installed"
fi
exit $fail
