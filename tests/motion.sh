#!/usr/bin/env bash
# tests/motion.sh — `sala motion` (lib/motion.sh, lib/motion.py; docs/subcommands.md). Everything runs in one temporary tree (locked while the suite
# runs, removed at its end); nothing touches the real state folder, systemd or the board. No process is killed, no tmux.
#   add       a line is stored in <state>/motion/<session>.json (folder 700, file 600) and nothing else is left in the folder but the lock; the same line
#             again changes nothing (not listed twice, and `at` stays the time it was first added); white space is folded to single spaces; an empty line,
#             a line of 121 characters and a ninth line are refused with a sentence and change nothing; exactly 120 characters and exactly 8 lines are taken
#   done      by exact text and by number; the line stays, marked done (list says so), and the sentence says where it went; a done line is refused
#             again; --link keeps an https, /path or page-anchor address; a bad link is refused (exit 2); an unknown line or number is refused; add of
#             the same text after done starts a new open line and leaves the done one
#   clear     (the chat session, which every section but "elsewhere" is run as) takes the open lines off and leaves each done one with its time and link, saying how many stayed (also when the full list holds only done
#             lines, where a ninth is still refused); an emptied list says "nothing right now"; --json is an array of {n, text, at}
#   kept      nothing expires a line (the clock injected): a month later it is listed and a write keeps it with its first time
#   session   --for NAME names the session; with none and outside a session the command asks for it (exit 1); a name that is not one is refused;
#             one session's lines are not another's; a file that is not the format reads as no lines
#   parallel  several adds at once under the lock: every one lands, none is lost, the file is always whole JSON
#   elsewhere a session that is not the chat session (another is set, or none): done takes the line off, so eight add and done leave room for a ninth;
#             done lines left from when it was the chat session are taken off by done and by clear; the setting is read from the config file too, the
#             what that file assigns counting over a value the shell had; a link is checked and not kept
#   text      control characters, DEL and U+0080-U+009F among them, are not kept in a line
#   usage     the help, a wrong verb, a missing argument (exit 2)
# Usage: bash tests/motion.sh   (exit 0 = pass; a few seconds)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
. "$ROOT/tests/lib.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/sala-motion.XXXXXX")
exec 8< "$T"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
trap 'exec 8<&-; rm -rf "$T"' EXIT
export HOME=$T/home SALA_CONFIG=/dev/null XDG_STATE_HOME=$T/state SALA_STATE_DIR=$T/state/salamander
unset SALA_MOTION_DIR SALA_MOTION_NOW SALA_MOTION_SELF
export SALA_CHAT_SESSION=chat-test   # the chat session: its done lines wait for the owner
mkdir -p "$HOME"
S="bash $ROOT/bin/salamander motion"
D=$SALA_STATE_DIR/motion
NOW=1800000000

# -- add -----------------------------------------------------------------------------------------------------------------------------------
export SALA_MOTION_NOW=$NOW
out=$($S add "Slide 4 is being redrawn" --for chat-test 2>"$T/err"); rc=$?
[ "$rc" = 0 ] && has "$out" "added (1 of 8)" && ok "add: one line is stored" || bad "add: rc=$rc out=[$out] err=[$(cat "$T/err")]"
[ "$(stat -c %a "$D")" = 700 ] && [ "$(stat -c %a "$D/chat-test.json")" = 600 ] && ok "modes: folder 700, file 600" || bad "modes: $(stat -c %a "$D" "$D/chat-test.json")"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d=={"v":1,"lines":[{"text":"Slide 4 is being redrawn","at":int(sys.argv[2])}]}, d' "$D/chat-test.json" "$NOW" \
    && ok "the file is the documented JSON" || bad "file content: $(cat "$D/chat-test.json")"
ls -A "$D" | grep -v '^\.lock$' | grep -v '^chat-test\.json$' | grep -q . && bad "add left something besides the file and the lock: $(ls -A "$D")" || ok "add leaves no temporary file"
before=$(cat "$D/chat-test.json")
out=$(SALA_MOTION_NOW=$((NOW + 600)) $S add "  Slide 4 is   being redrawn " --for chat-test 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "already listed" && [ "$($S list --json --for chat-test | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)))')" = 1 ] \
    && ok "the same line again is not listed twice" || bad "duplicate add: rc=$rc [$out]"
[ "$(cat "$D/chat-test.json")" = "$before" ] && [ "$($S list --json --for chat-test | python3 -I -c 'import json,sys; print(json.load(sys.stdin)[0]["at"])')" = "$NOW" ] \
    && ok "the same line again keeps the time it was first added" || bad "re-add moved the time: $(cat "$D/chat-test.json")"
$S clear --for chat-test >/dev/null
$S add "  two   spaces
and a newline  " --for chat-test >/dev/null 2>&1
[ "$($S list --for chat-test)" = "1. two spaces and a newline" ] && ok "white space is folded to single spaces" || bad "fold: [$($S list --for chat-test)]"
$S clear --for chat-test >/dev/null

# refusals change nothing
$S add "x" --for chat-test >/dev/null
before=$(cat "$D/chat-test.json")
$S add "" --for chat-test >/dev/null 2>"$T/err"; rc=$?
[ "$rc" = 1 ] && [ -s "$T/err" ] && ok "an empty line is refused (exit 1, a sentence)" || bad "empty: rc=$rc"
long=$(printf 'a%.0s' $(seq 1 121))
$S add "$long" --for chat-test >/dev/null 2>"$T/err"; rc=$?
[ "$rc" = 1 ] && has "$(cat "$T/err")" "121 characters" && ok "121 characters are refused, not cut, and the sentence says how long it was" || bad "121 chars: rc=$rc err=[$(cat "$T/err")]"
[ "$(cat "$D/chat-test.json")" = "$before" ] && ok "a refused line changes nothing" || bad "file changed by a refusal"
exact=$(printf 'b%.0s' $(seq 1 120))
$S add "$exact" --for chat-test >/dev/null 2>&1 && ok "exactly 120 characters are taken" || bad "120 chars refused"
$S clear --for chat-test >/dev/null
for n in 1 2 3 4 5 6 7 8; do $S add "line $n" --for chat-test >/dev/null 2>&1 || bad "add line $n refused"; done
$S add "line 9" --for chat-test >/dev/null 2>"$T/err"; rc=$?
[ "$rc" = 1 ] && has "$(cat "$T/err")" "8 lines are already listed" && ok "a ninth line is refused with a sentence" || bad "ninth: rc=$rc err=[$(cat "$T/err")]"
[ "$($S list --for chat-test | wc -l)" = 8 ] && ok "eight lines stay eight" || bad "list after a ninth: $($S list --for chat-test | wc -l)"

# -- done ----------------------------------------------------------------------------------------------------------------------------------
$S clear --for chat-test >/dev/null
for n in 1 2 3 4; do $S add "line $n" --for chat-test >/dev/null 2>&1; done
out=$($S done 3 --for chat-test 2>&1); has "$out" "done: line 3" && has "$out" "my turn" && [ "$($S list --for chat-test | sed -n 3p)" = "3. line 3  [done, waiting for the owner's confirm or reply]" ] && [ "$($S list --for chat-test | wc -l)" = 4 ] \
    && ok "done N keeps the line, marked done, and the sentence says where it went" || bad "done 3: [$out] [$($S list --for chat-test)]"
$S done "line 1" --for chat-test >/dev/null 2>&1 && [ "$($S list --for chat-test | head -1)" = "1. line 1  [done, waiting for the owner's confirm or reply]" ] && ok "done takes a line by its exact text" || bad "done by text: [$($S list --for chat-test)]"
$S done "line 1" --for chat-test >/dev/null 2>"$T/err"; rc=$?
[ "$rc" = 1 ] && has "$(cat "$T/err")" "already done" && ok "done on a done line is refused (exit 1, a sentence)" || bad "done twice: rc=$rc err=[$(cat "$T/err")]"
$S done "line 9" --for chat-test >/dev/null 2>"$T/err"; rc=$?
[ "$rc" = 1 ] && [ -s "$T/err" ] && ok "done on a line that is not there is refused" || bad "done unknown: rc=$rc"
$S done 99 --for chat-test >/dev/null 2>&1; [ $? = 1 ] && ok "done on a number out of range is refused" || bad "done 99"
$S done "line" --for chat-test >/dev/null 2>&1; [ $? = 1 ] && ok "done does not match part of a line" || bad "done partial"
out=$($S done 4 --link https://example.com/r --for chat-test 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$($S list --json --for chat-test | python3 -I -c 'import json,sys; r=json.load(sys.stdin)[3]; print(r["link"], r["done"] is not None)')" = "https://example.com/r True" ] \
    && ok "done --link keeps the address with the line" || bad "done link: rc=$rc [$out]"
$S done 2 --link "javascript:alert" --for chat-test >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && [ "$($S list --json --for chat-test | python3 -I -c 'import json,sys; print(json.load(sys.stdin)[1]["done"])')" = None ] && ok "a link that is not https, /path or a page anchor is refused (exit 2, nothing done)" || bad "bad link: rc=$rc"
refused=""
for l in "#nope" "#" "#s=" "#lane=a&b" "//example.com/x" "/\\example.com/x"; do
    $S done 2 --link "$l" --for chat-test >/dev/null 2>"$T/err"; rc=$?
    [ "$rc" = 2 ] && has "$(cat "$T/err")" "#s=SESSION" && has "$(cat "$T/err")" "#sessions" && has "$(cat "$T/err")" "https address" || refused="$refused [$l rc=$rc]"
done
[ -z "$refused" ] && [ "$($S list --json --for chat-test | python3 -I -c 'import json,sys; print(json.load(sys.stdin)[1]["done"])')" = None ] \
    && ok "an anchor that names no view, and another site written as a path, are refused with the forms that are taken (nothing done)" || bad "bad anchors:$refused"
$S done 2 --link "#s=chat-test" --for chat-test >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$($S list --json --for chat-test | python3 -I -c 'import json,sys; print(json.load(sys.stdin)[1]["link"])')" = "#s=chat-test" ] \
    && ok "done --link keeps one of the page's own anchors" || bad "anchor link: rc=$rc"
out=$($S add "line 1" --for chat-test 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$($S list --json --for chat-test | python3 -I -c 'import json,sys; r=json.load(sys.stdin); print(len(r), [x["done"] is None for x in r if x["text"]=="line 1"])')" = "5 [False, True]" ] \
    && ok "add after done starts a new open line and leaves the done one" || bad "add after done: rc=$rc [$out]"

# -- clear, list ---------------------------------------------------------------------------------------------------------------------------
# the list now: line 1 (done), line 2 (done, link), line 3 (done), line 4 (done, link), line 1 (open)
want=$(python3 -I -c 'import json,sys; print(json.dumps([x for x in json.load(open(sys.argv[1]))["lines"] if "done" in x], sort_keys=True))' "$D/chat-test.json")
out=$($S clear --for chat-test 2>&1); rc=$?
got=$(python3 -I -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["lines"], sort_keys=True))' "$D/chat-test.json")
[ "$rc" = 0 ] && [ "$got" = "$want" ] && ok "clear takes the open line off and leaves every done one as it was" || bad "clear with done lines: rc=$rc kept=[$got]"
has "$out" "cleared 1 line for chat-test; 4 done lines kept until the owner confirms or replies" && ok "clear says how many done lines it kept" || bad "clear sentence: [$out]"
for n in 5 6 7 8; do $S add "line $n" --for chat-test >/dev/null 2>&1; done
$S done "line 5" --for chat-test >/dev/null 2>&1; $S done "line 6" --for chat-test >/dev/null 2>&1; $S done "line 7" --for chat-test >/dev/null 2>&1; $S done "line 8" --for chat-test >/dev/null 2>&1
out=$($S clear --for chat-test 2>&1)
$S add "line 9" --for chat-test >/dev/null 2>"$T/err"; rc=$?
has "$out" "cleared 0 lines" && has "$out" "8 done lines kept" && [ "$rc" = 1 ] && has "$(cat "$T/err")" "done ones stay" \
    && ok "a list full of done lines stays full through clear, and the ninth line's refusal says done ones stay" || bad "full of done: [$out] rc=$rc err=[$(cat "$T/err")]"
has "$($S --help 2>&1)" "In the chat session a done line the owner has not acknowledged stays" && ok "the help says clear leaves the chat session's unacknowledged done lines" || bad "help on clear"
rm -f "$D/chat-test.json"   # no command takes a done line off: the file is removed for the checks below
$S add "one" --for chat-test >/dev/null
out=$($S clear --for chat-test 2>&1)
[ "$out" = "motion: cleared 1 line for chat-test" ] && ok "clear of open lines alone says only what it took off" || bad "clear open: [$out]"
[ "$($S list --for chat-test)" = "nothing right now" ] && ok "list on an empty list says nothing right now" || bad "empty list: [$($S list --for chat-test)]"
[ "$($S list --json --for chat-test)" = "[]" ] && ok "list --json on an empty list is []" || bad "empty json"
$S add "one" --for chat-test >/dev/null; $S add "two" --for chat-test >/dev/null
python3 -I -c 'import json,sys; r=json.loads(sys.argv[1]); assert [x["n"] for x in r]==[1,2] and [x["text"] for x in r]==["one","two"] and all(isinstance(x["at"],int) for x in r), r' "$($S list --json --for chat-test)" \
    && ok "list --json is an array of {n, text, at}" || bad "json shape"

# -- kept ------------------------------------------------------------------------------------------------------------------------------------
$S clear --for chat-test >/dev/null
$S add "old line" --for chat-test >/dev/null
later=$((NOW + 30 * 86400))
[ "$(SALA_MOTION_NOW=$later $S list --for chat-test)" = "1. old line" ] && ok "a line a month old is still listed" || bad "expired: [$(SALA_MOTION_NOW=$later $S list --for chat-test)]"
SALA_MOTION_NOW=$later $S add "new line" --for chat-test >/dev/null
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); n=int(sys.argv[2]); assert [(x["text"], x["at"]) for x in d["lines"]]==[("old line", n), ("new line", n + 30 * 86400)], d' "$D/chat-test.json" "$NOW" \
    && ok "a write keeps the old line with its first time" || bad "old line dropped or moved: $(cat "$D/chat-test.json")"
SALA_MOTION_NOW=$later $S done "old line" --for chat-test >/dev/null 2>&1
[ "$(SALA_MOTION_NOW=$later $S list --for chat-test | head -1)" = "1. old line  [done, waiting for the owner's confirm or reply]" ] && ok "done keeps an old line, marked done" || bad "done old: [$($S list --for chat-test)]"

# -- session ---------------------------------------------------------------------------------------------------------------------------------
rm -f "$D/chat-test.json"   # it holds a done line
$S add "mine" --for chat-test >/dev/null; $S add "theirs" --for chat-other >/dev/null
[ "$($S list --for chat-test)" = "1. mine" ] && [ "$($S list --for chat-other)" = "1. theirs" ] && ok "one session's lines are not another's" || bad "sessions mixed"
$S list >/dev/null 2>"$T/err"; rc=$?
[ "$rc" = 1 ] && has "$(cat "$T/err")" "--for NAME" && ok "outside a session --for is asked for" || bad "no session: rc=$rc err=[$(cat "$T/err")]"
SALA_MOTION_SELF=chat-test $S list | grep -q mine && ok "inside a session the default is that session" || bad "default session"
SALA_MOTION_SELF=chat-test $S list --for chat-other | grep -q theirs && ok "--for wins over the session's own name" || bad "--for precedence"
$S list --for ../x >/dev/null 2>&1; [ $? = 1 ] && ok "a name that is not a session name is refused" || bad "bad name"
$S list --for=chat-test | grep -q mine && ok "--for=NAME is the same as --for NAME" || bad "--for=NAME"
printf 'not json' > "$D/chat-test.json"
[ "$($S list --for chat-test)" = "nothing right now" ] && ok "a file that is not the format reads as no lines" || bad "foreign file"
printf '{"v":1,"lines":[{"text":"ok","at":%s},{"text":5,"at":1},{"text":"no clock"}]}' "$NOW" > "$D/chat-test.json"
[ "$($S list --for chat-test)" = "1. ok" ] && ok "a malformed row is skipped, the rest read" || bad "malformed row: [$($S list --for chat-test)]"

# -- parallel --------------------------------------------------------------------------------------------------------------------------------
$S clear --for chat-par >/dev/null
for n in 1 2 3 4 5 6; do $S add "p$n" --for chat-par >/dev/null 2>&1 & done
wait
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); t=sorted(x["text"] for x in d["lines"]); assert t==["p%d"%i for i in range(1,7)], t' "$D/chat-par.json" \
    && ok "six adds at once all land and the file is whole JSON" || bad "parallel: $(cat "$D/chat-par.json")"

# -- elsewhere: a session whose lines no page shows ----------------------------------------------------------------------------------------
W=work-test
count() { $S list --json --for "$W" | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)))'; }
for chat in chat-test ""; do
    rm -f "$D/$W.json"; refused=""
    for n in 1 2 3 4 5 6 7 8 9; do
        SALA_CHAT_SESSION=$chat $S add "job $n" --for $W >/dev/null 2>&1 || refused="$refused add$n"
        SALA_CHAT_SESSION=$chat $S done "job $n" --for $W >/dev/null 2>&1 || refused="$refused done$n"
    done
    [ -z "$refused" ] && [ "$(count)" = 0 ] && ok "elsewhere (chat session '$chat'): done takes the line off, nine add and done all go through" || bad "elsewhere '$chat':$refused $(cat "$D/$W.json")"
done
$S add "a" --for $W >/dev/null; $S add "b" --for $W >/dev/null
out=$($S done 1 --link https://example.com/r --for $W 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "motion: done: a" && has "$out" "link is not kept" && [ "$($S list --for $W)" = "1. b" ] && ok "elsewhere: done N with a link takes the line off and says the link is not kept" || bad "elsewhere link: rc=$rc [$out]"
$S done 1 --link "javascript:alert" --for $W >/dev/null 2>&1; [ $? = 2 ] && [ "$(count)" = 1 ] && ok "elsewhere: a bad link is still refused" || bad "elsewhere bad link"
out=$($S clear --for $W 2>&1)
[ "$out" = "motion: cleared 1 line for $W" ] && [ "$(count)" = 0 ] && ok "elsewhere: clear empties the list" || bad "elsewhere clear: [$out]"
# eight done lines held from when the session was the chat session, two of them of one text
held() {
    rm -f "$D/$W.json"
    for n in 1 2 3 4 5 6 7; do SALA_CHAT_SESSION=$W $S add "old $n" --for $W >/dev/null; SALA_CHAT_SESSION=$W $S done "old $n" --for $W >/dev/null; done
    SALA_CHAT_SESSION=$W $S add "old 7" --for $W >/dev/null; SALA_CHAT_SESSION=$W $S done "old 7" --for $W >/dev/null
}
held
SALA_CHAT_SESSION=$W $S add "next" --for $W >/dev/null 2>&1; [ $? = 1 ] && [ "$(count)" = 8 ] && ok "as the chat session, eight done lines fill the list" || bad "held setup: $(cat "$D/$W.json")"
[ "$($S list --for $W | head -1)" = "1. old 1  [done, on no page: \`done\` or \`clear\` takes it off]" ] && ok "elsewhere: list says a held done line is on no page" || bad "held list: [$($S list --for $W | head -1)]"
$S add "next" --for $W >/dev/null 2>"$T/err"; rc=$?
[ "$rc" = 1 ] && has "$(cat "$T/err")" "sala motion done N" && has "$(cat "$T/err")" "sala motion clear" && ! has "$(cat "$T/err")" "owner" \
    && ok "elsewhere: a full list of held done lines names the two ways out" || bad "held full: rc=$rc err=[$(cat "$T/err")]"
$S done 1 --for $W >/dev/null 2>&1; rc=$?
$S done "old 7" --for $W >/dev/null 2>&1; rc2=$?
[ "$rc$rc2" = 00 ] && [ "$(count)" = 6 ] && $S add "next" --for $W >/dev/null 2>&1 && ok "elsewhere: done takes a held done line off, by number and by a text two lines hold" || bad "held done: rc=$rc$rc2 $(cat "$D/$W.json")"
held
out=$($S clear --for $W 2>&1)
[ "$out" = "motion: cleared 8 lines for $W" ] && [ "$(count)" = 0 ] && ok "elsewhere: clear takes held done lines off too" || bad "held clear: [$out]"
# the setting in sala's config file, as sala-web reads it; a changed setting counts at the next command
printf 'export SALA_CHAT_SESSION="%s"   # the chat\n' "$W" > "$T/config"
conf() { env -u SALA_CHAT_SESSION SALA_CONFIG="$T/config" bash "$ROOT/bin/salamander" motion "$@" --for $W; }
conf add "from config" >/dev/null; conf done "from config" >/dev/null 2>&1; conf clear >/dev/null
[ "$(count)" = 1 ] && ok "a chat session set in the config file keeps its done line" || bad "config chat: $(cat "$D/$W.json")"
SALA_CONFIG="$T/config" $S clear --for $W >/dev/null
[ "$(count)" = 1 ] && ok "what the config file assigns counts over a value the shell had" || bad "config over shell: $(cat "$D/$W.json")"
printf 'SALA_CHAT_SESSION=another\n' > "$T/config"
conf clear >/dev/null
[ "$(count)" = 0 ] && ok "after the config file names another session, clear empties the list" || bad "config change: $(cat "$D/$W.json")"

# -- text -----------------------------------------------------------------------------------------------------------------------------------
$S add "$(printf 'a\x7fb\xc2\x9bc\xc2\x85d\x01e')" --for $W >/dev/null 2>&1
[ "$($S list --for $W)" = "1. abc de" ] && ok "control characters, DEL and U+0080-U+009F among them, are not kept" || bad "control characters: $(cat "$D/$W.json")"
printf '{"v":1,"lines":[{"text":"x\\u009by","at":%s}]}' "$NOW" > "$D/chat-test.json"
$S done "xy" --for chat-test >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && python3 -I -c 'import json,sys; assert json.load(open(sys.argv[1]))["lines"][0]["text"]=="xy"' "$D/chat-test.json" \
    && ok "a stored line with such a character is cleaned when it is marked done" || bad "stored control character: rc=$rc $(cat "$D/chat-test.json")"

# -- usage -----------------------------------------------------------------------------------------------------------------------------------
out=$($S --help 2>&1); rc=$?; [ "$rc" = 0 ] && has "$out" "sala motion add" && ok "--help prints the usage" || bad "help: rc=$rc"
$S >/dev/null 2>&1; [ $? = 2 ] && ok "no verb: exit 2" || bad "no verb"
$S frobnicate >/dev/null 2>&1; [ $? = 2 ] && ok "an unknown verb: exit 2" || bad "unknown verb"
$S add --for chat-test >/dev/null 2>&1; [ $? = 2 ] && ok "add with no line: exit 2" || bad "add no arg"
$S clear extra --for chat-test >/dev/null 2>&1; [ $? = 2 ] && ok "clear with an argument: exit 2" || bad "clear arg"
$S add "x" --json --for chat-test >/dev/null 2>&1; [ $? = 2 ] && ok "--json on add: exit 2" || bad "--json on add"

echo "motion: $([ $fail = 0 ] && echo pass || echo FAIL)"
exit $fail
