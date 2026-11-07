# shellcheck shell=bash
# sala_board_links <base>  — stdin to stdout: every bare board item id `board#N` becomes the Slack mrkdwn link
# `<base/items/N|board#N>`, so an id in a post opens its item in one click. base is the board's web address
# (SALA_STACKSHOT_WEB; a trailing / is dropped); empty, or one a Slack link cannot carry (a space, <, > or |), passes the text
# through unchanged. An id already inside a Slack link (`<…|board#N>`, `<…/items/N>`), in a code span or in a bare URL is left
# alone, so a second pass never doubles a link; the characters around an id stay (`*board#N*` → `*<…|board#N>*`, still bold).
# A whole id only: `xboard#1` and `board#1a` are not ids.
# The board server's own link carries the store id `g<N>` (item board#N is stored as g<N>): a Slack link whose target is
# `<base>/items/g<N>` (this base only) is rewritten to `<base>/items/N`, and its label to `board#N` when the label is empty,
# `g<N>` or `board#N`; any other label keeps its text. A bare `g<N>` word is not touched (too ambiguous), nor a link on another host.
# One awk process per post, no python. Sourced by lib/common.sh (sala_notify_raw, `sala alert`, the stuck-question post) and by
# contrib/briefing/lib.sh (post_slack), which does not source lib/common.sh: the one implementation both send paths run.
sala_board_links() {
    local base="${1%/}"
    case "$base" in ''|*[[:space:]\<\>\|]*) cat; return 0 ;; esac
    LC_ALL=C awk -v base="$base" '
function ids(t,   out, pre, id, rest, c) {
    out = ""
    while (match(t, /board#[0-9]+/)) {
        pre = substr(t, 1, RSTART - 1); id = substr(t, RSTART + 6, RLENGTH - 6); rest = substr(t, RSTART + RLENGTH)
        c = substr(pre, length(pre), 1)
        if (c ~ /[A-Za-z0-9_]/ || rest ~ /^[A-Za-z0-9_]/) out = out pre "board#" id
        else out = out pre "<" base "/items/" id "|board#" id ">"
        t = rest
    }
    return out t
}
function fixlink(seg,   pre, rest, num, lab) {   # <base/items/gN|label> → <base/items/N|board#N> (label kept when it is prose)
    pre = "<" base "/items/g"
    if (substr(seg, 1, length(pre)) != pre) return seg
    rest = substr(seg, length(pre) + 1)
    if (!match(rest, /^[0-9]+/)) return seg
    num = substr(rest, 1, RLENGTH); rest = substr(rest, RLENGTH + 1)
    if (rest == ">") lab = ""
    else if (substr(rest, 1, 1) == "|") lab = substr(rest, 2, length(rest) - 2)
    else return seg
    if (lab == "" || lab == "g" num || lab == "board#" num) lab = "board#" num
    return "<" base "/items/" num "|" lab ">"
}
{
    s = $0; out = ""
    while (match(s, /<[^<>]*>|`[^`]*`|https?:\/\/[^ \t<>`]+/)) {   # a Slack link, a code span or a bare URL: kept as it is
        st = RSTART; n = RLENGTH                                        # (ids() runs match too)
        seg = substr(s, st, n); if (substr(seg, 1, 1) == "<") seg = fixlink(seg)
        out = out ids(substr(s, 1, st - 1)) seg; s = substr(s, st + n)
    }
    print out ids(s)
}'
}
