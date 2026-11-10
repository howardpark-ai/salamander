#!/bin/bash
# Release watcher → Slack. Runs release-watch.sh beside it (zero-LLM probes + the
# cross-session ping to the owning Claude session) and posts anything that is
# not the NO_REPLY token. Daily (sala-briefing-release.timer).
# Lives in salamander contrib/briefing/.
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib.sh"   # sets BRIEFING_DIR
BRIEFING_CHANNEL="${BRIEFING_CHANNEL:-reports}"   # this job posts to the reports channel; BRIEFING_CHANNEL in the unit environment names another (README.md, Slack channels)
OUT=$("$BRIEFING_DIR/release-watch.sh" 2>"$LOGDIR/release-watch.err"); RC=$?
if [ -n "$OUT" ] && [ "$OUT" != "NO_REPLY" ]; then post_slack "$OUT" >/dev/null; fi
if [ $RC -ne 0 ]; then
  post_slack "⚠️ *Release watcher: a check failed*
$(head -5 "$LOGDIR/release-watch.err" | cut -c1-200 | sed 's/^/    • /')
    • Details: $LOGDIR/release-watch.err on $(briefing_box)" >/dev/null
fi
exit $RC
