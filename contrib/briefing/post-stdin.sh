#!/bin/bash
# post-stdin.sh — post the message on stdin to the briefing channel (post_slack: the formatter, the linker, the webhook).
# This is the command to set as sala's SALA_WATCH_NOTIFY_CMD (README.md, "To have sala's notices use this webhook"): sala
# pipes each notice into it as data on stdin, and nothing here ever hands the text to a shell to parse. Do not wrap post_slack in a
# `bash -c "… $(cat) …"` string instead: the outer shell expands $(cat) inside the double quotes, the notice's own text becomes part
# of the inner script, and a backtick or $( ) in it is run as a command.
# An empty message posts nothing; the exit code is post_slack's (a refused post is non-zero). Lives in salamander contrib/briefing/.
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib.sh"   # sets BRIEFING_DIR
text=$(cat)
[ -n "${text//[[:space:]]/}" ] || exit 0
post_slack "$text" >/dev/null
