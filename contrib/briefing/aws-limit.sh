#!/bin/bash
# API spend limit → state file. Runs aws_limit.py beside it: reads the newest "Monthly Claude API Spend Exceeding Thresholds" email of
# the owner's mailbox (through gmail_fetch.py's Portal, read only; no model call) and writes the limit, tier and pause-until date to
# ${XDG_STATE_HOME:-~/.local/state}/salamander/aws-api-limit.json, which sala's Overview card for the aws-platform lane shows
# (docs/overview.md). Several times a day (sala-briefing-aws-limit.timer). Lives in salamander contrib/briefing/.
# Settings (environment, else the sala config; config.example): BRIEFING_GMAIL_CONNECTOR (the mailbox's connector word, as the digests),
# BRIEFING_LEAN_PORTAL_URL (the portal's address), SALA_AWS_LIMIT_ORG (the organization the emails must name; unset: the job does nothing).
# No connector or no organization set is the job switched off, not a failure: one line on cron.log, exit 0.
. "$(_s=${BASH_SOURCE[0]}; [ -L "$_s" ] && _s=$(readlink -f "$_s"); [[ $_s == */* ]] || _s=./$_s; cd -P "${_s%/*}" && pwd -P)/lib.sh"   # sets BRIEFING_DIR
briefing_need_connector aws-limit || exit 0
ORG=$(briefing_setting SALA_AWS_LIMIT_ORG)
if [ -z "$ORG" ]; then cron_log "aws-limit: SALA_AWS_LIMIT_ORG is not set (config.example, the briefings): nothing read"; exit 0; fi
export SALA_AWS_LIMIT_ORG=$ORG
PORTAL_URL=$(briefing_setting BRIEFING_LEAN_PORTAL_URL); [ -n "$PORTAL_URL" ] && export BRIEFING_LEAN_PORTAL_URL=$PORTAL_URL
ERR=$(mktemp "$LOGDIR/aws-limit.XXXXXX") || exit 1; trap 'rm -f "$ERR"' EXIT
timeout "${BRIEFING_AWS_LIMIT_CAP:-300}" python3 -I "$BRIEFING_DIR/aws_limit.py" 2> "$ERR" </dev/null; RC=$?
LINE=$(grep -v '^\s*$' "$ERR" | tail -1 | cut -c1-200)
if [ $RC -ne 0 ]; then cron_log "aws-limit: failed (exit $RC): ${LINE:-no reason given}"
elif [ -n "$LINE" ]; then cron_log "$LINE"; fi
exit $RC
