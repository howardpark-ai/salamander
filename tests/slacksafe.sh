#!/usr/bin/env bash
# A digit run between colons in a Slack post (lib/slacksafe.sh, sala_slack_safe): Slack reads `:NN:` as an emoji code and draws a gray
# box, so "<link|session>:0:" and "04:00:" showed one. The function puts a zero-width space (U+200B) before the closing colon of a colon,
# 1 or 2 digits, a colon. Checked on the function: escaped are name:0:, >:0:, 04:00:, :7:, " :12: ", (pane :1:), 10:00:30:, a link's label;
# left alone are :100:, :+1:, :-1:, :white_check_mark:, URLs and ports, a Slack link's URL part, code spans and blocks; an
# already-escaped text and a second pass change nothing; a byte that is not UTF-8 and a missing trailing newline pass through.
# Then on every send path: sala_post (sala_notify_raw, a stub notify command), `sala alert`, the stuck-question post (sq_send) and the
# briefings' post_slack (BRIEFING_NO_POST: the finished text goes to a file, nothing is sent). `sala dm` is checked in tests/dm.sh.
# The zero-width space is built at run time (Z): no invisible character sits in this file. A temporary HOME and config; nothing outside them
# is touched.
# Usage: bash tests/slacksafe.sh   (exit 0 = pass; a few seconds)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null
trap 'rm -rf "$HOME"' EXIT
. "$ROOT/lib/slacksafe.sh"
Z=$(printf '\xe2\x80\x8b')   # U+200B, written as bytes
safe() { printf '%s' "$1" | sala_slack_safe; }
show() { printf '%s' "$1" | sed "s/$Z/<Z>/g"; }
check() {  # <what> <input> <expected>
    local got; got=$(safe "$2")
    [ "$got" = "$3" ] && ok "$1" || bad "$1: got [$(show "$got")]"
}
same() { check "$1: left as written" "$2" "$2"; }   # <what> <input>

# escaped
check "name:0: (a pane after a session name)" 'sess-a:0: not relaunched' "sess-a:0${Z}: not relaunched"
check ">:0: (a pane after a Slack link)" '<https://sala.example/#s=sess-a|sess-a>:0: not relaunched' "<https://sala.example/#s=sess-a|sess-a>:0${Z}: not relaunched"
check "04:00: (a time with a colon after it)" '04:00: the weekly run' "04:00${Z}: the weekly run"
check "a lone :7:" 'tab :7: open' "tab :7${Z}: open"
check "a :12: with a space each side" 'x :12: y' "x :12${Z}: y"
check "(pane :1:)" 'the pane (pane :1:) is idle' "the pane (pane :1${Z}:) is idle"
check "10:00:30: gets one before each closing colon" 'at 10:00:30: sharp' "at 10:00${Z}:30${Z}: sharp"
check "12:30:45 (the second colon is a closing one)" '12:30:45' "12:30${Z}:45"
check "a run at the start of the text" ':5: first' ":5${Z}: first"
check "on every line of a multi-line post" $'a:0: x\n    • b:1: y' "a:0${Z}: x"$'\n'"    • b:1${Z}: y"
check "a Slack link's label is escaped, its URL is not" '<https://h.example:80:/p|a:5:b>' "<https://h.example:80:/p|a:5${Z}:b>"
check "text around a code span is escaped, the span is not" 'a:1: `b:2:` c:3: d' "a:1${Z}: \`b:2:\` c:3${Z}: d"
check "a less-than sign that opens no link does not hide what follows" 'a < b :0: c > d' "a < b :0${Z}: c > d"

# left alone
same ":100: (3 digits: a real emoji)" 'well done :100: team'
same ":1234:" 'x :1234: y'
same ":+1:" 'ok :+1: ok'
same ":-1:" 'no :-1: no'
same ":white_check_mark: and :tada:" ':white_check_mark: done :tada:'
same "a time with no colon after it" 'at 04:00 and 4:5 sharp'
same "host:22 and a URL with a port" 'ssh host:22 and https://host.example:8080/x?a=1 ok'
same "a URL that a colon and digits follow" 'see https://host.example:80: now'
same "a Slack link's URL part, no label" '<https://host.example:80:/p> next'
same "a Slack link's URL part with a port, a label with no digits" '<https://host.example:80/p|label> next'
same "a user and a channel mention" '<@U123ABC> in <#C123ABC|general>'
same "a code span" 'run `date +%H:%M:0:` now'
same "a code block" $'before\n```\n:3: and 10:00:\n```\nafter'
same "no colon at all" 'plain text, nothing here'
same "an empty text" ''
same "a less-than sign that is no link, with :100:" 'if a < b then :100: > c'

# idempotent, byte-safe
raw='a:0: <https://x.example/s|a>:1: 04:00: :100: `c:2:`'
once=$(safe "$raw"); twice=$(safe "$once")
[ "$once" = "$twice" ] && [ "$once" != "$raw" ] && ok "a second pass changes nothing" || bad "second pass: [$(show "$once")] then [$(show "$twice")]"
got=$(safe "an already-escaped name:0${Z}: text"); [ "$got" = "an already-escaped name:0${Z}: text" ] && ok "an already-escaped text is left as it is" || bad "already escaped: $(show "$got")"
back=$(safe 'a:0: b 04:00: c' | sed "s/$Z//g"); [ "$back" = 'a:0: b 04:00: c' ] && ok "taking the zero-width space out gives the original text back" || bad "round trip: $back"
got=$(printf 'name:0: 日本語 ✓ 🚨\n' | sala_slack_safe); [ "$got" = "name:0${Z}: 日本語 ✓ 🚨" ] && ok "multibyte text around a run is kept byte for byte" || bad "multibyte: $(show "$got")"
printf 'a:0: \xff\xfe b' | sala_slack_safe > "$HOME/inv"; printf 'a:0\xe2\x80\x8b: \xff\xfe b' | cmp -s - "$HOME/inv" && ok "a byte that is not UTF-8 passes through untouched" || bad "invalid bytes: $(od -An -c "$HOME/inv")"
[ "$(printf 'a:0: b' | sala_slack_safe | tail -c 1)" = b ] && ok "a text with no trailing newline gets none added" || bad "a trailing newline was added"

# the send paths
W=https://board.example.com; SESS=https://sala.example/#s=
BD=board   # the id is built at run time (${BD}#N): no literal board id sits in this file
POSTS=$HOME/posts.txt
(
    export SALA_NOTIFY_CMD="cat > $POSTS" SALA_STACKSHOT_WEB=$W
    . "$ROOT/lib/common.sh" >/dev/null 2>&1
    sala_post "🛑 *Ended a process*" "<${SESS}sess-a|sess-a>:0: pid 9 ended" "at 04:00: it resumes"
)
want="🛑 *Ended a process*"$'\n'"    • <${SESS}sess-a|sess-a>:0${Z}: pid 9 ended"$'\n'"    • at 04:00${Z}: it resumes"
[ "$(cat "$POSTS" 2>/dev/null)" = "$want" ] && ok "sala_post: a link then :0: posts the escaped text" || bad "sala_post: $(show "$(cat "$POSTS" 2>/dev/null)")"
rm -f "$POSTS"
(
    export SALA_NOTIFY_CMD="cat > $POSTS" SALA_STACKSHOT_WEB=$W
    . "$ROOT/lib/common.sh" >/dev/null 2>&1
    sala_notify_raw "<${SESS}sess-b|sess-b>:0: waits; ${BD}#7:"
)
[ "$(cat "$POSTS" 2>/dev/null)" = "<${SESS}sess-b|sess-b>:0${Z}: waits; <$W/items/7|${BD}#7>:" ] && ok "sala_notify_raw: the escape runs after the board links, a board link's URL is whole" || bad "sala_notify_raw: $(show "$(cat "$POSTS" 2>/dev/null)")"
rm -f "$POSTS"
SALA_NOTIFY_CMD="cat > $POSTS" SALA_LOG_DIR=$HOME/log "$ROOT/bin/salamander" alert "*alert*" "<${SESS}sess-c|sess-c>:0: failed" >/dev/null 2>&1
grep -qF "<${SESS}sess-c|sess-c>:0${Z}: failed" "$POSTS" 2>/dev/null && ok "sala alert: the post is escaped too" || bad "sala alert: $(show "$(cat "$POSTS" 2>/dev/null)")"
rm -f "$POSTS"
(
    export SALA_NOTIFY_CMD="cat > $POSTS" SALA_STACKSHOT_WEB=$W
    . "$ROOT/lib/common.sh" >/dev/null 2>&1; . "$ROOT/lib/stuck.sh" >/dev/null 2>&1
    sq_send "⚠️ *waits*" "sess-d:0: asks a question"
)
grep -qF "sess-d:0${Z}: asks a question" "$POSTS" 2>/dev/null && ok "sq_send (the stuck-question post): escaped" || bad "sq_send: $(show "$(cat "$POSTS" 2>/dev/null)")"
rm -f "$POSTS"

# a pane suffix that tells the reader nothing is dropped where a post is worded: an operation's output lines name pane 0 as "name:0:" (op_out_tail,
# the tail a stuck notice quotes); a pane other than 0 is information and stays
(
    . "$ROOT/lib/common.sh" >/dev/null 2>&1; . "$ROOT/lib/op.sh" >/dev/null 2>&1
    op_out() { echo "$HOME/op-out.$1"; }
    printf '[stamp] start\n  sess-f:0: not relaunched, busy\nsess-g:2: kept\nplain: a:0: b\n' > "$HOME/op-out.1"
    op_out_tail 1 5 > "$HOME/op-tail"
)
[ "$(cat "$HOME/op-tail" 2>/dev/null)" = 'start ·   sess-f: not relaunched, busy · sess-g:2: kept · plain: a:0: b' ] && ok "op_out_tail: a pane 0 suffix is dropped, pane 2 and a mid-line :0: stay" || bad "op_out_tail: $(cat "$HOME/op-tail" 2>/dev/null)"

# the briefings' post_slack: the escape is the last step, after slack_text and the links
mkdir -p "$HOME/blog"
BRIEFING_LOGDIR=$HOME/blog BRIEFING_NO_POST=1 SALA_STACKSHOT_WEB=$W BRIEFING_SESSIONS_CMD=true BRIEFING_BOARD_DIR= BRIEFING_COMMIT_REPOS= \
    bash -c '. "$1/contrib/briefing/lib.sh"; post_slack "$2"' _ "$ROOT" $'📬 *Summary*\n• <https://sala.example/#s=sess-e|sess-e>:0: idle; at 04:00: *'"${BD}#9"$'* waits; :100:' >/dev/null 2>&1
got=$(cat "$HOME/blog/would-post.log" 2>/dev/null)
want=$'📬 *Summary*\n• <https://sala.example/#s=sess-e|sess-e>:0'"$Z"': idle; at 04:00'"$Z"': *<'"$W"'/items/9|'"${BD}#9"'>* waits; :100:'
[ "$got" = "$want" ] && ok "briefing post_slack: escaped after the links, :100: and the link's URL kept" || bad "post_slack: $(show "$got")"
exit $fail
