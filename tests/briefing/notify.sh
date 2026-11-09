#!/usr/bin/env bash
# The notify command never evaluates a notice. sala pipes each notice into SALA_WATCH_NOTIFY_CMD / SALA_NOTIFY_CMD on stdin and runs the
# command with `sh -c`; the command contrib/briefing/README.md tells an owner to set (contrib/briefing/post-stdin.sh) must hand that text to
# post_slack as data. Checked through `sala alert` (sala_post's path: board links, then the command) with the README's own command line
# read out of the README and sourced as config: a notice carrying backticks, $( ), a double quote and a newline arrives intact at a stub
# post_slack, and the commands inside it (touching marker files, a stub `claude` that would wait for a sign-in) do not run. The control is
# the old documented shape, `bash -c "… post_slack \"$(cat)\" …"` under `sh -c`, which does run them: the check can fail. Last, a notify
# command that never returns is stopped at SALA_NOTIFY_TIMEOUT (a hung post cannot hold the watch's tick).
# A temporary HOME holds a stand-in checkout (the real post-stdin.sh beside a stub lib.sh); nothing outside it is touched.
# Usage: bash tests/briefing/notify.sh   (exit 0 = pass; a few seconds)
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd); D=$ROOT/contrib/briefing
fail=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
exec 8<"$T"; flock -n 8   # systemd-tmpfiles ageing honours a held flock on the folder
export HOME=$T/home POSTED=$T/posted
unset SALA_NOTIFY_CMD SALA_WATCH_NOTIFY_CMD SALA_STACKSHOT_WEB
mkdir -p "$HOME/salamander/contrib/briefing" "$T/bin" "$T/log"
cp "$D/post-stdin.sh" "$HOME/salamander/contrib/briefing/post-stdin.sh"
printf '%s\n' 'post_slack() { printf "%s" "$1" > "$POSTED"; }' > "$HOME/salamander/contrib/briefing/lib.sh"   # the stub: keeps the exact argument
# a `claude` that would hang on a browser sign-in: here it only leaves a marker
printf '#!/bin/sh\ntouch "%s/ran-claude"\n' "$T" > "$T/bin/claude"; chmod +x "$T/bin/claude"
export PATH=$T/bin:$PATH

# the notice: backticks (a command and a sign-in command), $( ), a double quote, a single quote, a backslash, a newline
HEAD='🚨 *The lane is not signed in* `touch '"$T"'/ran-head`'
BULLET='fix: `claude auth login --claudeai` then $(touch '"$T"'/ran-sub) and `touch '"$T"'/ran-tick`, say "hi" it'"'"'s \n ok'$'\nsecond line ${HOME}'
WANT=$HEAD$'\n''    • '$BULLET
ran() { ls "$T" | grep -c '^ran-'; }

line=$(grep -m1 '^SALA_WATCH_NOTIFY_CMD=' "$D/README.md")
[ -n "$line" ] && ok "the README gives a SALA_WATCH_NOTIFY_CMD line" || bad "no SALA_WATCH_NOTIFY_CMD line in the README"
printf '%s\n' "$line" > "$T/config"

rm -f "$POSTED"
SALA_CONFIG=$T/config SALA_LOG_DIR=$T/log bash "$ROOT/bin/salamander" alert "$HEAD" "$BULLET" >/dev/null 2>&1; rc=$?
[ $rc = 0 ] && ok "sala alert through the README's command: posted (exit 0)" || bad "sala alert exit $rc"
[ "$(cat "$POSTED" 2>/dev/null)" = "$WANT" ] && ok "the notice arrives at post_slack byte for byte (backticks, \$( ), quotes, newlines)" || bad "notice mangled: got [$(cat "$POSTED" 2>/dev/null)] want [$WANT]"
[ "$(ran)" = 0 ] && ok "no command inside the notice ran" || bad "a command inside the notice ran: $(ls "$T" | grep '^ran-' | tr '\n' ' ')"

# the same notice through sala_post (what the watch uses), the command set as SALA_NOTIFY_CMD
rm -f "$POSTED"
( SALA_NOTIFY_CMD=$HOME/salamander/contrib/briefing/post-stdin.sh SALA_CONFIG=/dev/null SALA_LOG_DIR=$T/log
  . "$ROOT/lib/common.sh" >/dev/null 2>&1; sala_post "$HEAD" "$BULLET" )
[ "$(cat "$POSTED" 2>/dev/null)" = "$WANT" ] && [ "$(ran)" = 0 ] && ok "sala_post: intact, nothing ran" || bad "sala_post: got [$(cat "$POSTED" 2>/dev/null)], ran: $(ls "$T" | grep '^ran-' | tr '\n' ' ')"

# the real post_slack (no webhook: BRIEFING_NO_POST writes the finished text to a file): nothing in the notice runs either
mkdir -p "$T/real/contrib" "$T/real-home"
cp -r "$D" "$T/real/contrib/briefing"
mkdir -p "$T/blog"
printf 'x\n' > "$T/blog/.keep"
printf '%s\n' "$HEAD"$'\n'"$BULLET" | env HOME=$T/real-home BRIEFING_LOGDIR=$T/blog BRIEFING_NO_POST=1 BRIEFING_SESSIONS_CMD=true BRIEFING_BOARD_DIR= BRIEFING_COMMIT_REPOS= \
    bash "$T/real/contrib/briefing/post-stdin.sh" >/dev/null 2>&1
[ -s "$T/blog/would-post.log" ] && [ "$(ran)" = 0 ] && ok "the real post_slack: the notice is posted, nothing in it ran" || bad "real post_slack: log [$(cat "$T/blog/would-post.log" 2>/dev/null)], ran: $(ls "$T" | grep '^ran-' | tr '\n' ' ')"

# an empty notice posts nothing
rm -f "$POSTED"; printf '\n  \n' | bash "$HOME/salamander/contrib/briefing/post-stdin.sh" >/dev/null 2>&1; rc=$?
[ $rc = 0 ] && [ ! -e "$POSTED" ] && ok "an empty notice posts nothing" || bad "empty notice: rc=$rc posted=$(cat "$POSTED" 2>/dev/null)"

# control: the old documented shape, a double-quoted bash -c with $(cat) in it, run by `sh -c` as sala runs a notify command, does run them
OLD='bash -c ". '"$HOME"'/salamander/contrib/briefing/lib.sh; post_slack \"$(cat)\" >/dev/null"'
printf '%s\n' 'x `touch '"$T"'/ran-old` y' | sh -c "$OLD" >/dev/null 2>&1
[ -e "$T/ran-old" ] && ok "control: the old double-quoted bash -c form does run the notice's backticks (this check can fail)" || bad "control: the old form did not run the marker, so this test would not catch it"
rm -f "$T"/ran-*

# a notify command that never returns is stopped: the post fails (exit 1 from `sala alert`) after the bound, not after the command's own time
t0=$(date +%s)
SALA_NOTIFY_CMD='sleep 60' SALA_NOTIFY_TIMEOUT=1 SALA_CONFIG=/dev/null SALA_LOG_DIR=$T/log bash "$ROOT/bin/salamander" alert '*stuck post*' >/dev/null 2>&1; rc=$?
dt=$(( $(date +%s) - t0 ))
[ $rc = 1 ] && [ $dt -lt 20 ] && ok "a notify command that hangs is stopped at SALA_NOTIFY_TIMEOUT (exit 1 after ${dt}s)" || bad "hung notify command: rc=$rc after ${dt}s"
exit $fail
