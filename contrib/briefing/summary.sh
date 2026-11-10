#!/bin/bash
# Morning Email Summary (retired; the lean script, summary-lean.sh, runs from sala-briefing-summary-lean.timer).
# Lives in salamander contrib/briefing/.
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib.sh"   # sets BRIEFING_DIR
BRIEFING_CHANNEL="${BRIEFING_CHANNEL:-reports}"   # this job posts to the reports channel; BRIEFING_CHANNEL in the unit environment names another (README.md, Slack channels)
fetch_new_holds   # stackshot's new holds, fetched here (holds.py), never by the model; HOLDS_BLOCK is '' when none or on a failure
briefing_need_connector summary || exit 0
PROMPT="$(briefing_prompt "$BRIEFING_DIR/summary.prompt.md")

Current local time: $(now_local)."
[ -n "$HOLDS_BLOCK" ] && PROMPT="$PROMPT

$HOLDS_BLOCK"
run_claude_retry summary "$PROMPT"
[ -n "$HOLDS_NOTE" ] && printf '%(%F %T)T %s\n' -1 "$HOLDS_NOTE" >> "$LOGDIR/summary.$(printf '%(%Y%m%d)T' -1).jsonl.err"   # after the run: it overwrites the file
deliver summary "Morning Email Summary"
