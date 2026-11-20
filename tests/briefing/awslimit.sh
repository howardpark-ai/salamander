#!/usr/bin/env bash
# The API spend limit job (contrib/briefing/aws-limit.sh, aws_limit.py): the email parser, the newest-email pick, the state file it writes, and the
# switched-off cases of the shell wrapper. Offline: made-up emails (organization "Example Org"), a temporary HOME; nothing reaches Gmail or the portal.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd); D=$ROOT/contrib/briefing
fail=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/logs"

python3 -I "$ROOT/tests/briefing/awslimit_check.py" || fail=1

# the wrapper is switched off (exit 0, one line on cron.log, nothing written) with no connector, and with a connector but no organization
run() { env -i HOME="$T/home" PATH="$PATH" BRIEFING_LOGDIR="$T/logs" XDG_STATE_HOME="$T/state" SALA_CONFIG="$T/none" "$@" bash "$D/aws-limit.sh"; }
run; rc=$?
[ $rc = 0 ] && grep -q 'aws-limit: no digest: BRIEFING_GMAIL_CONNECTOR is not set' "$T/logs/cron.log" && ok "no connector: exit 0 and a cron.log line" || bad "no connector: rc=$rc $(cat "$T/logs/cron.log" 2>/dev/null)"
: > "$T/logs/cron.log"
run BRIEFING_GMAIL_CONNECTOR=demo; rc=$?
[ $rc = 0 ] && grep -q 'SALA_AWS_LIMIT_ORG is not set' "$T/logs/cron.log" && [ ! -e "$T/state/salamander/aws-api-limit.json" ] && ok "no organization: exit 0, a cron.log line, no file" || bad "no organization: rc=$rc $(cat "$T/logs/cron.log" 2>/dev/null)"
# a connector and an organization but no login for the portal: the read fails (exit 3), is logged, and no file is written
: > "$T/logs/cron.log"
run BRIEFING_GMAIL_CONNECTOR=demo SALA_AWS_LIMIT_ORG="Example Org" BRIEFING_LEAN_CREDENTIALS="$T/no-such-credentials.json"; rc=$?
[ $rc = 3 ] && grep -q 'aws-limit: failed (exit 3)' "$T/logs/cron.log" && [ ! -e "$T/state/salamander/aws-api-limit.json" ] && ok "no portal login: exit 3, logged, no file" || bad "no portal login: rc=$rc $(cat "$T/logs/cron.log" 2>/dev/null)"

# the unit pair: no model call (lane none), the script it starts is executable, the timer fires four times a day, and systemd accepts both
U=$D/systemd; s=$U/sala-briefing-aws-limit.service; t=$U/sala-briefing-aws-limit.timer
[ -f "$s" ] && [ -f "$t" ] || bad "sala-briefing-aws-limit.{service,timer} missing"
grep -qxF "X-Model-Lane=none" "$s" && grep -qxF "ExecStart=%h/salamander/contrib/briefing/aws-limit.sh" "$s" && [ -x "$D/aws-limit.sh" ] && ok "the service: lane none, ExecStart is the executable aws-limit.sh" || bad "the service: lane or ExecStart"
grep -qxF "Environment=BRIEFING_CRON_LOG=1" "$s" && ! grep -q '^Standard\(Output\|Error\)=' "$s" && ok "the service: output goes to cron.log through BRIEFING_CRON_LOG" || bad "the service: output path"
grep -qxF "OnCalendar=*-*-* 02,08,14,20:10:00 UTC" "$t" && grep -qxF "Persistent=true" "$t" && ok "the timer: four times a day, zone named, persistent" || bad "the timer's schedule"
if command -v systemd-analyze >/dev/null 2>&1; then
    mkdir -p "$T/u"
    for f in "$s" "$t"; do sed -e "s#%h/salamander#$ROOT#g" "$f" > "$T/u/$(basename "$f")"; done
    out=$(systemd-analyze verify "$T"/u/sala-briefing-aws-limit.* 2>&1); ours=$(printf '%s\n' "$out" | grep 'sala-briefing-aws-limit' || true)
    if [ -z "$ours" ]; then ok "systemd-analyze verify (or no usable systemd here: nothing of ours reported)"; else bad "systemd-analyze verify: $ours"; fi
fi
exit $fail
