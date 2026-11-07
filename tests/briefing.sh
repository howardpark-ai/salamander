#!/usr/bin/env bash
# The briefing contrib (contrib/briefing/): runs every tests/briefing/*.sh. Offline: a temporary HOME, a fake `claude`,
# posting stubbed or sent to a listener on 127.0.0.1; nothing reaches Slack, Gmail or the real webhook.
# Usage: bash tests/briefing.sh   (exit 0 = pass; a few seconds)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# A run from a pane on the api, sdk or a bedrock lane inherits that lane's variables, and the checks below read the child's environment
# (tests/briefing/sdk.sh: "credit rerun argv" fails on any ANTHROPIC_* left in it). CI's runner carries none of them: this keeps a run
# from any pane equal to CI's, as tests/lib.sh does for the sala suites. A check that wants one sets it itself.
# tests/briefing/sdk.sh carries the same list at its top, for a run of that file on its own (a shared file under tests/briefing/ would be
# run as a test by the glob below); keep the two lists in step.
unset ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS CLAUDE_CONFIG_DIR \
      ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_BEDROCK_REGION_PREFIX \
      AWS_PROFILE AWS_REGION CLAUDE_EFFORT ANTHROPIC_AUTH_TOKEN
fail=0
for t in "$ROOT"/tests/briefing/*.sh; do
    echo "== tests/briefing/$(basename "$t")"
    bash "$t" || { echo "== tests/briefing/$(basename "$t") FAILED"; fail=1; }
done
echo "briefing: $([ $fail = 0 ] && echo pass || echo FAIL)"
exit $fail
