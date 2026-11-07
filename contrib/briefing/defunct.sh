#!/bin/bash
# Defunct Address Unsubscribe Queue: the unread mail under the Gmail label BRIEFING_FORWARD_LABEL (a former address that still
# forwards here), classified, read only (sala-briefing-defunct.timer). No label set: no digest.
# Lives in salamander contrib/briefing/.
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib.sh"   # sets BRIEFING_DIR
briefing_need_connector defunct || exit 0
briefing_need_label defunct || exit 0
PROMPT="$(briefing_prompt "$BRIEFING_DIR/defunct.prompt.md")

Current local time: $(now_local)."
run_claude_retry defunct "$PROMPT"
deliver defunct "Defunct Address Queue"
