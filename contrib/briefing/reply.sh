#!/bin/bash
# reply.sh <thread_ts> [text]  — a reply in the thread of a briefing-channel message (a fast-lane chat with
# the briefing session). The text is the argument, or stdin when it is omitted or `-`. It goes out through post_slack, so
# the same formatter and linker as every other post, with BRIEFING_THREAD_TS adding "thread_ts" to the payload.
# Prints Slack's answer ("ok"); a bad ts or an empty text is a one-line error and exit 2, before anything is posted.
# Lives in salamander contrib/briefing/.
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib.sh"   # sets BRIEFING_DIR
ts=${1-}
[[ $ts =~ ^[0-9]+\.[0-9]+$ ]] || { echo "reply.sh: bad thread_ts '$ts' (want digits.digits, e.g. 1760000000.123456)" >&2; exit 2; }
if [ $# -lt 2 ] || [ "$2" = - ]; then text=$(cat); else text=$2; fi
[ -n "${text//[[:space:]]/}" ] || { echo "reply.sh: empty text, nothing posted" >&2; exit 2; }
BRIEFING_THREAD_TS=$ts post_slack "$text"
