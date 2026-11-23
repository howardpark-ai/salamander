#!/usr/bin/env bash
# tests/box.sh — `sala box SESSION [--json]` (lib/box.sh) and the helper under it, dim_from_capture (lib/common.sh): what is in a
# session's pane input box, as empty, suggestion (dim text: Claude Code's own suggested prompt, which counts as empty) or typed.
#   helper   dim_from_capture on captures with the attributes (`capture-pane -e`): the dim span of the input line is returned, typed
#            text and a dim completion are told apart, no box and no dim text read as empty, a shell-mode placeholder is dim text, so is the placeholder with its cursor cell (reverse first character, dim rest; tmux ESC[0;2m), the cursor after or inside typed text is typed, a colour own 2 is no dim; and
#            draft_from_capture answers what it always did on the same captures (the suggestion is no draft)
#   verb     a fake claude pane (a script named claude, on a PRIVATE tmux server) draws a box between two rules: an empty box, a dim
#            suggestion, typed text, typed text with a dim completion after it, a dim suggestion with typed text after it, each as the
#            human output and as --json; a session that is not live, a session whose pane runs no claude, bad calls, --help
#   readonly the run leaves the screen as it was, sends no key (the fake logs none) and writes nothing under HOME
# A fake `claude` is a bash script of that name run by its own path (`#!/bin/bash`, not `env bash`, whose comm would be bash): its comm is
# `claude`, which is all claude_pid_under looks for. Its processes are
# ended by pid (every pane pid is recorded when the pane is made), and the private tmux server by its own kill-server.
# Usage: bash tests/box.sh   (exit 0 = pass; a few seconds)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SET SALA_RECYCLE SALA_RETRY_WORKER CLAUDE_CODE_PLUGIN_DIRS SALA_MOD_DIR
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/sala-box.XXXXXX")
exec 8< "$T"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
export HOME=$T/home SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC XDG_RUNTIME_DIR=$T/run SALA_MOD_WAIT=1
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$T/bin" "$T/screens"
SOCK="sala-box-$$"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off
SALA="$ROOT/bin/salamander"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"
PANEPIDS="$T/panepids"; : > "$PANEPIDS"
cleanup() {
    local p
    command tmux -L "$SOCK" -f /dev/null kill-server 2>/dev/null
    while read -r p; do
        { [ -n "$p" ] && [[ $(tr '\0' ' ' < "/proc/$p/cmdline") == *"$T/bin/claude"* ]] && kill -9 "$p"; } 2>/dev/null
    done < "$PANEPIDS"
    tmux_socket_rm; exec 8<&-; rm -rf "$T" 2>/dev/null; true
}
trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux
. "$ROOT/lib/common.sh"

# the fake claude: draws the screen file once, then sits; a key typed into it is logged (the verb must type none)
cat > "$T/bin/claude" <<'FAKE'
#!/bin/bash
cat "$BOX_SCREEN"
while IFS= read -r -n1 -s k; do printf '%s\n' "$k" >> "$BOX_KEYS"; done
FAKE
chmod +x "$T/bin/claude"
E=$'\e'; NB=$'\xc2\xa0'; G=$'\xe2\x9d\xaf'; R=$'\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80'
GREY="${E}[38;5;246m${R}${E}[39m"
KEYS="$T/keys"; : > "$KEYS"
screen() {  # <the box line> → a screen: an old prompt above, the box between two rules, the footer
    printf '%s\n' "${E}[38;5;246m${G}${NB}an old message already sent${E}[39m" "" "$GREY" "$1" "$GREY" "  ${E}[2m? for shortcuts${E}[0m"
}
mkbox() {  # <session> <screen text> → a session whose pane runs the fake claude and shows that screen
    local f="$T/screens/$1"; printf '%s' "$2" > "$f"
    command tmux -L "$SOCK" -f /dev/null new-session -d -s "$1" -x 100 -y 20 "env BOX_SCREEN=$f BOX_KEYS=$KEYS $T/bin/claude" || { bad "could not start the fake pane $1"; return 1; }
    command tmux -L "$SOCK" -f /dev/null display -p -t "=$1:" '#{pane_pid}' >> "$PANEPIDS"
    DRAWN=$1; waitfor '[ -n "$(tmux capture-pane -p -t "=$DRAWN:" | tr -d "[:space:]")" ]' 20   # (waitfor evaluates its condition inside itself: a global, not $1)
}
box() { OUT=$("$SALA" box "$@" 2>"$T/err"); RC=$?; ERR=$(<"$T/err"); }   # → OUT (stdout), ERR (stderr), RC

echo "== dim_from_capture: the dim span of the input line (and draft_from_capture unchanged)"
chk() {  # <what> <capture> <dim text wanted> <draft wanted>
    local d g; d=$(printf '%s\n' "$2" | dim_from_capture); g=$(printf '%s\n' "$2" | draft_from_capture)
    [ "$d" = "$3" ] && [ "$g" = "$4" ] && ok "$1" || bad "$1: dim '$d' (want '$3'), draft '$g' (want '$4')"
}
chk "an empty box: no dim text, no draft"            "$(screen "${E}[39m${G}${NB}")"                                               ""                          ""
chk "a dim suggestion alone: the suggestion, no draft" "$(screen "${E}[39m${G}${NB}${E}[2mrun the fleet cli update${E}[0m")"     "run the fleet cli update"  ""
chk "a dim span closed by SGR 22"                    "$(screen "${E}[39m${G}${NB}${E}[2mtry a thing${E}[22m")"                     "try a thing"               ""
chk "a dim span that runs to the end of the line"    "$(screen "${E}[39m${G}${NB}${E}[2mno reset at the end")"                     "no reset at the end"       ""
chk "typed text, no dim: no suggestion"              "$(screen "${E}[39m${G}${NB}my own unsent note")"                              ""                          "my own unsent note"
chk "typed text with a dim completion after it"      "$(screen "${E}[39m${G}${NB}show ${E}[2m/etc/adduser.conf${E}[0m")"           "/etc/adduser.conf"         "show"
chk "a dim part first, typed text after it"          "$(screen "${E}[39m${G}${NB}${E}[2mthe suggestion${E}[0m typed after")"       "the suggestion"            "typed after"
chk "two dim spans are joined by a space"            "$(screen "${E}[39m${G}${NB}${E}[2mone${E}[0m and ${E}[2mtwo${E}[0m")"        "one two"                   "and"
chk "a dim notice outside the box is not read"       "$(printf '%s\n' "$GREY" "${E}[39m${G}${NB}" "$GREY" "${E}[2m! Auto-update failed${E}[0m")"  ""     ""
chk "a shell-mode placeholder (dim) is dim text"     "$(printf '%s\n' "${E}[38;5;211m${R}" "!${NB}${E}[2m${E}[39mTry \"fix typecheck errors\"${E}[0m" "${E}[38;5;211m${R}" "  ${E}[38;5;211m! for shell mode${E}[39m")" 'Try "fix typecheck errors"' ""
# Claude Code draws its placeholder with the cursor on the first character: that cell is reverse-video, the rest dim. tmux 3.6 writes the
# change from one to the other as `ESC[0;2m` (a reset and the dim in one sequence), which is not `ESC[2m` alone.
PH="Once fixed, resend your message"
chk "the placeholder as tmux captures it (reverse first cell, then ESC[0;2m dim)" "$(screen "${E}[39m${G}${NB}${E}[7mO${E}[0;2mnce fixed, resend your message${E}[0m")" "$PH" ""
chk "the placeholder with SGR 27 and SGR 22"         "$(screen "${E}[39m${G}${NB}${E}[7mO${E}[27m${E}[2mnce fixed, resend your message${E}[22m")" "$PH" ""
chk "the placeholder with the cursor cell closed by SGR 0" "$(screen "${E}[39m${G}${NB}${E}[7mO${E}[0m${E}[2mnce fixed, resend your message${E}[0m")" "$PH" ""
chk "the placeholder, cursor cell dim and reverse at once (ESC[2;7m)" "$(screen "${E}[39m${G}${NB}${E}[2;7mO${E}[0;2mnce fixed, resend your message${E}[0m")" "$PH" ""
chk "a dim span opened by ESC[0;2m with no cursor cell" "$(screen "${E}[39m${G}${NB}${E}[0;2mrun the fleet cli update${E}[0m")"  "run the fleet cli update"  ""
chk "typed text with the cursor after it (a reverse blank): typed" "$(screen "${E}[39m${G}${NB}my own unsent note${E}[7m ${E}[0m")"  ""            "my own unsent note"
chk "typed text with the cursor on one of its letters: typed" "$(screen "${E}[39m${G}${NB}my ${E}[7mo${E}[0mwn note")"           ""                          "my own note"
chk "typed text, then the cursor on the first letter of a dim completion" "$(screen "${E}[39m${G}${NB}show ${E}[7m/${E}[0;2metc/adduser.conf${E}[0m")" "/etc/adduser.conf" "show"
chk "a colour's own 2 (38;2;r;g;b) is no dim"        "$(screen "${E}[39m${G}${NB}${E}[38;2;10;20;30mcoloured typed${E}[0m")"       ""                          "coloured typed"
chk "a 256-colour 2 (38;5;2) is no dim"              "$(screen "${E}[39m${G}${NB}${E}[38;5;2mgreen typed${E}[0m")"                  ""                          "green typed"
chk "no box on the screen, a dim word elsewhere"     "$(printf '%s\n' "some output ${E}[2mdim${E}[0m" "more")"                      ""                          ""
chk "an old dim line above the box is not read"      "$(printf '%s\n' "${E}[39m${G}${NB}${E}[2mold${E}[0m" "$GREY" "${E}[39m${G}${NB}" "$GREY")" ""           ""

echo "== sala box on a fake claude pane"
mkbox empty "$(screen "${E}[39m${G}${NB}")" || exit 1
mkbox sugg "$(screen "${E}[39m${G}${NB}${E}[2mrun the fleet cli update${E}[0m")"
mkbox typed "$(screen "${E}[39m${G}${NB}my own unsent note")"
mkbox over "$(screen "${E}[39m${G}${NB}show ${E}[2m/etc/adduser.conf${E}[0m")"
mkbox after "$(screen "${E}[39m${G}${NB}${E}[2mthe suggestion${E}[0m typed after")"
mkbox cursor "$(screen "${E}[39m${G}${NB}${E}[7mO${E}[0;2mnce fixed, resend your message${E}[0m")"
mkbox quote "$(screen "${E}[39m${G}${NB}say \"hi\" \\ there")"
command tmux -L "$SOCK" -f /dev/null new-session -d -s noclaude -x 100 -y 20 "sleep 600" && command tmux -L "$SOCK" -f /dev/null display -p -t "=noclaude:" '#{pane_pid}' >> "$PANEPIDS"

snap() { ( cd "$HOME" && find . -mindepth 1 -printf '%p %T@ %s\n' | sort ); }   # what is under HOME, with times and sizes
before=$(snap); screen_before=$(tmux capture-pane -pe -t =sugg:)
box empty;  [ "$RC" = 0 ] && [ "$OUT" = empty ] && [ -z "$ERR" ] && ok "empty box: 'empty', exit 0" || bad "empty: rc=$RC out='$OUT' err='$ERR'"
box sugg;   [ "$RC" = 0 ] && [ "$(sed -n 1p <<< "$OUT")" = suggestion ] && [ "$(sed -n 2p <<< "$OUT")" = "Claude Code's own suggestion, not typed by anyone: run the fleet cli update" ] && [ "$(wc -l <<< "$OUT")" = 2 ] \
    && ok "dim suggestion: 'suggestion', its text labelled on the next line" || bad "suggestion: rc=$RC out='$OUT'"
box cursor; [ "$RC" = 0 ] && [ "$(sed -n 1p <<< "$OUT")" = suggestion ] && [ "$(sed -n 2p <<< "$OUT")" = "Claude Code's own suggestion, not typed by anyone: Once fixed, resend your message" ] && [ "$(wc -l <<< "$OUT")" = 2 ] \
    && ok "the placeholder with its cursor cell (reverse first character, dim rest): a suggestion, whole" || bad "placeholder with cursor cell: rc=$RC out='$OUT'"
box typed;  [ "$RC" = 0 ] && [ "$OUT" = $'typed\nmy own unsent note' ] && ok "typed text: 'typed' and the text" || bad "typed: rc=$RC out='$OUT'"
box over;   [ "$RC" = 0 ] && [ "$OUT" = $'typed\nshow' ] && ok "typed text with a dim completion after it: typed, the typed part" || bad "typed over a suggestion: rc=$RC out='$OUT'"
box after;  [ "$RC" = 0 ] && [ "$OUT" = $'typed\ntyped after' ] && ok "a dim part, then typed text: typed, the typed part" || bad "typed after a suggestion: rc=$RC out='$OUT'"
sleep 1
[ "$(tmux capture-pane -pe -t =sugg:)" = "$screen_before" ] && [ ! -s "$KEYS" ] && [ "$(snap)" = "$before" ] && ok "read-only: the screen is as it was, no key reached any pane, nothing written under HOME" || bad "read-only: keys '$(<"$KEYS")' home diff: $(diff <(echo "$before") <(snap) | head -5)"

echo "== --json"
box --json empty;  [ "$RC" = 0 ] && [ "$OUT" = '{"session":"empty","state":"empty","text":""}' ] && ok "json, empty" || bad "json empty: rc=$RC $OUT"
box sugg --json;   [ "$RC" = 0 ] && [ "$OUT" = '{"session":"sugg","state":"suggestion","text":"run the fleet cli update"}' ] && ok "json, suggestion (the option may come after the name)" || bad "json suggestion: rc=$RC $OUT"
box --json cursor; [ "$RC" = 0 ] && [ "$OUT" = '{"session":"cursor","state":"suggestion","text":"Once fixed, resend your message"}' ] && ok "json, the placeholder with its cursor cell" || bad "json cursor: rc=$RC $OUT"
box --json typed;  [ "$RC" = 0 ] && [ "$OUT" = '{"session":"typed","state":"typed","text":"my own unsent note"}' ] && ok "json, typed" || bad "json typed: rc=$RC $OUT"
box --json over;   [ "$RC" = 0 ] && [ "$OUT" = '{"session":"over","state":"typed","text":"show"}' ] && ok "json, typed over a suggestion" || bad "json over: rc=$RC $OUT"
box --json quote;  [ "$RC" = 0 ] && [ "$(python3 -I -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["state"], d["text"])' <<< "$OUT")" = 'typed say "hi" \ there' ] && ok "json: a quote and a backslash in the text parse back" || bad "json quote: rc=$RC $OUT"

echo "== refusals and calls"
box nosuchsession; [ "$RC" = 2 ] && [ -z "$OUT" ] && [ "$ERR" = "sala box: no live session 'nosuchsession'" ] && ok "a session that is not live: one plain line on stderr, exit 2" || bad "not live: rc=$RC out='$OUT' err='$ERR'"
box --json nosuchsession; [ "$RC" = 2 ] && [ -z "$OUT" ] && ok "--json does not print an object for a session that is not live" || bad "not live json: rc=$RC out='$OUT'"
box noclaude;      [ "$RC" = 3 ] && [ -z "$OUT" ] && [ "$ERR" = "sala box: no claude in the pane of 'noclaude'" ] && ok "a pane with no claude in it: says so, exit 3" || bad "no claude: rc=$RC out='$OUT' err='$ERR'"
box;               [ "$RC" = 2 ] && [[ $ERR == *"usage: sala box SESSION"* ]] && ok "no session: usage, exit 2" || bad "no arg: rc=$RC err='$ERR'"
box --bogus empty; [ "$RC" = 2 ] && [[ $ERR == *"unknown option --bogus"* ]] && ok "an unknown option: refused, exit 2" || bad "bogus: rc=$RC err='$ERR'"
box empty typed;   [ "$RC" = 2 ] && [[ $ERR == *"one session name only"* ]] && ok "two names: refused, exit 2" || bad "two names: rc=$RC err='$ERR'"
box --help;        [ "$RC" = 0 ] && [[ $OUT == *"empty"* && $OUT == *"suggestion"* && $OUT == *"typed"* && $OUT == *"counts as empty"* && $OUT == *"never raw"* ]] && ok "--help: the three states, the suggestion counting as empty, and never raw capture-pane" || bad "help: rc=$RC $OUT"
OUT=$(cd / && env -u TMUX "$SALA" box --help 2>&1 </dev/null); [ "$?" = 0 ] && ok "--help needs no tmux" || bad "help without tmux"

echo "box: $([ "$fail" = 0 ] && echo pass || echo FAIL)"
exit $fail
