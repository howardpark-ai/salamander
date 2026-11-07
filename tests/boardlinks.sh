#!/usr/bin/env bash
# Board item ids in Slack posts (lib/boardlinks.sh, sala_board_links): every bare board#N a post carries leaves as the Slack
# link <SALA_STACKSHOT_WEB/items/N|board#N>. Checked on the function: a bare id links; several ids in one post all link; an
# id already inside a Slack link (labelled or not), a code span or a URL is not linked again, so a second pass changes
# nothing; *board#N* stays bold with the link inside the asterisks; a trailing / on the address is dropped; an unset or
# unusable address leaves the text as it is; a longer word is not an id. Then on the send paths: sala_notify_raw (sala_post),
# `sala alert`, and the briefings' post_slack (BRIEFING_NO_POST: the finished text goes to a file, no webhook).
# A temporary HOME and config; nothing outside them is touched.
# Usage: bash tests/boardlinks.sh   (exit 0 = pass; a second or two)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null
trap 'rm -rf "$HOME"' EXIT
. "$ROOT/lib/boardlinks.sh"
W=https://board.example.com; I=$W/items
bl() { printf '%s\n' "$1" | sala_board_links "${2-$W}"; }
check() {  # <what> <input> <expected> [address]
    local got; got=$(bl "$2" "${4-$W}")
    [ "$got" = "$3" ] && ok "$1" || bad "$1: got [$got]"
}

check "a bare board#N leaves as a link to its item" 'see board#12 now' "see <$I/12|board#12> now"
check "several ids in one post all link" $'board#9001, board#22\n  • and board#33.' "<$I/9001|board#9001>, <$I/22|board#22>"$'\n'"  • and <$I/33|board#33>."
check "bold stays bold: the link goes inside the asterisks" '*board#9007* is done' "*<$I/9007|board#9007>* is done"
check "an id already in a labelled Slack link is not doubled" "<$I/12|board#12> and board#13" "<$I/12|board#12> and <$I/13|board#13>"
check "an id in a link's longer label is not doubled" "<$I/12|see board#12> here" "<$I/12|see board#12> here"
check "a Slack link to an item with no label is left as it is" "<$I/12> board#12" "<$I/12> <$I/12|board#12>"
check "a code span and a bare URL are left alone" 'run `x board#9005` at https://x.test/board#9005 ok' 'run `x board#9005` at https://x.test/board#9005 ok'
check "a longer word is not an id" 'xboard#9004 board#9004a board#' 'xboard#9004 board#9004a board#'
check "a trailing / on the address is dropped" 'board#9009' "<$I/9009|board#9009>" "$W/"
check "SALA_STACKSHOT_WEB unset or empty: the text is left as it is" '*board#12* and board#9003' '*board#12* and board#9003' ''
check "an address a Slack link cannot carry: the text is left as it is" 'board#12' 'board#12' 'https://x y|z'
once=$(bl 'a *board#9002* b'); twice=$(bl "$once")
[ "$once" = "$twice" ] && ok "a second pass changes nothing" || bad "second pass: [$once] → [$twice]"
got=$(bl '🚨 *board#9008* — 日本語 ✓'); [ "$got" = "🚨 *<$I/9008|board#9008>* — 日本語 ✓" ] && ok "multibyte text around an id is kept byte for byte" || bad "multibyte: $got"

# the board server's store id g<N> (item board#N): a link built from it is rewritten to the shown id; the base must match
check "store-id target, label g46: link to items/46 labelled board#46" "<$I/g46|g46> done" "<$I/46|board#46> done"
check "store-id target, label board#46: link to items/46" "<$I/g46|board#46> done" "<$I/46|board#46> done"
check "store-id target, no label: link to items/46 labelled board#46" "<$I/g46> done" "<$I/46|board#46> done"
check "store-id target, prose label: the text stays, the target is rewritten" "<$I/g46|the recycle item> done" "<$I/46|the recycle item> done"
check "a store-id link on another host is left alone" "<https://other.example.com/items/g46|g46> done" "<https://other.example.com/items/g46|g46> done"
check "a store-id link on a longer host is left alone" "<https://board.example.com.evil/items/g46|g46>" "<https://board.example.com.evil/items/g46|g46>"
check "a bare g46 word is not touched" "see g46 and (g47)" "see g46 and (g47)"
check "g46 inside a plain URL or code span is not touched" 'at https://board.example.com/items/g46 and `g46`' 'at https://board.example.com/items/g46 and `g46`'
check "several store-id links and a bare id in one post" "<$I/g9001|g9001>, board#9002, <$I/g9003>" "<$I/9001|board#9001>, <$I/9002|board#9002>, <$I/9003|board#9003>"
once=$(bl "<$I/g46|g46> <$I/g9007> <$I/g9008|see this> board#9009"); twice=$(bl "$once")
[ "$once" = "<$I/46|board#46> <$I/9007|board#9007> <$I/9008|see this> <$I/9009|board#9009>" ] && [ "$once" = "$twice" ] && ok "a second pass over rewritten store-id links changes nothing" || bad "store-id second pass: [$once] → [$twice]"

# the send paths: sala_notify_raw (sala_post), `sala alert`, the briefings' post_slack
POSTS=$HOME/posts.txt
(
    export SALA_NOTIFY_CMD="cat > $POSTS" SALA_STACKSHOT_WEB=$W
    . "$ROOT/lib/common.sh" >/dev/null 2>&1
    sala_post "⚠️ *board#40 needs you*" "see board#41"
)
[ "$(cat "$POSTS" 2>/dev/null)" = "⚠️ *<$I/40|board#40> needs you*"$'\n'"    • see <$I/41|board#41>" ] && ok "sala_post: the post's ids leave as links" || bad "sala_post: $(cat "$POSTS" 2>/dev/null)"
rm -f "$POSTS"
( export SALA_NOTIFY_CMD="cat > $POSTS"; unset SALA_STACKSHOT_WEB; . "$ROOT/lib/common.sh" >/dev/null 2>&1; sala_notify_raw "*board#40*" )
[ "$(cat "$POSTS" 2>/dev/null)" = '*board#40*' ] && ok "sala_notify_raw with no board address: the post is unchanged" || bad "no address: $(cat "$POSTS" 2>/dev/null)"
rm -f "$POSTS"
SALA_NOTIFY_CMD="cat > $POSTS" SALA_STACKSHOT_WEB=$W SALA_LOG_DIR=$HOME/log "$ROOT/bin/salamander" alert "*board#50 failed*" "see board#51" >/dev/null 2>&1
grep -qF "<$I/50|board#50>" "$POSTS" 2>/dev/null && grep -qF "<$I/51|board#51>" "$POSTS" && ok "sala alert: the post's ids leave as links" || bad "sala alert: $(cat "$POSTS" 2>/dev/null)"
mkdir -p "$HOME/blog"
BRIEFING_LOGDIR=$HOME/blog BRIEFING_NO_POST=1 SALA_STACKSHOT_WEB=$W BRIEFING_SESSIONS_CMD=true BRIEFING_BOARD_DIR= BRIEFING_COMMIT_REPOS= \
    bash -c '. "$1/contrib/briefing/lib.sh"; post_slack "$2"' _ "$ROOT" $'📬 *Summary*\n• *board#60* waits; board#61 too' >/dev/null 2>&1
grep -qF "*<$I/60|board#60>* waits; <$I/61|board#61> too" "$HOME/blog/would-post.log" 2>/dev/null && ok "briefing post_slack: the post's ids leave as links, bold kept" || bad "post_slack: $(cat "$HOME/blog/would-post.log" 2>/dev/null)"
exit $fail
