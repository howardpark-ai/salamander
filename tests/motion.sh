#!/usr/bin/env bash
# tests/motion.sh — `sala motion` (lib/motion.sh, lib/motion.py; docs/subcommands.md). Everything runs in one temporary tree (locked while the suite
# runs, removed at its end); nothing touches the real state folder, systemd or the board. No process is killed, no tmux.
#   add       a line is stored in <state>/motion/<session>.json (folder 700, file 600) and nothing else is left in the folder but the lock; the same line
#             again changes nothing (not listed twice, and `at` stays the time it was first added); white space is folded to single spaces; an empty line,
#             a line of 121 characters and a ninth line are refused with a sentence and change nothing; exactly 120 characters and exactly 8 lines are taken
#   done      by exact text and by number; an unknown line or number is refused; the lines after it move up
#   clear     empties the list; list says "nothing right now"; --json is an array of {n, text, at}
#   kept      nothing expires a line (the clock injected): a month later it is listed and a write keeps it with its first time; only done and clear take it off
#   session   --for NAME names the session; with none and outside a session the command asks for it (exit 1); a name that is not one is refused;
#             one session's lines are not another's; a file that is not the format reads as no lines
#   parallel  several adds at once under the lock: every one lands, none is lost, the file is always whole JSON
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
out=$($S done 3 --for chat-test 2>&1); has "$out" "done: line 3" && [ "$($S list --for chat-test | sed -n 3p)" = "3. line 4" ] && ok "done N takes the numbered line off and the rest move up" || bad "done 3: [$out]"
$S done "line 1" --for chat-test >/dev/null 2>&1 && [ "$($S list --for chat-test | head -1)" = "1. line 2" ] && ok "done takes a line off by its exact text" || bad "done by text"
$S done "line 9" --for chat-test >/dev/null 2>"$T/err"; rc=$?
[ "$rc" = 1 ] && [ -s "$T/err" ] && ok "done on a line that is not there is refused" || bad "done unknown: rc=$rc"
$S done 99 --for chat-test >/dev/null 2>&1; [ $? = 1 ] && ok "done on a number out of range is refused" || bad "done 99"
$S done "line" --for chat-test >/dev/null 2>&1; [ $? = 1 ] && ok "done does not match part of a line" || bad "done partial"

# -- clear, list ---------------------------------------------------------------------------------------------------------------------------
$S clear --for chat-test >/dev/null
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
[ "$(SALA_MOTION_NOW=$later $S list --for chat-test)" = "1. new line" ] && ok "done takes an old line off" || bad "done old: [$($S list --for chat-test)]"

# -- session ---------------------------------------------------------------------------------------------------------------------------------
$S clear --for chat-test >/dev/null
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

# -- usage -----------------------------------------------------------------------------------------------------------------------------------
out=$($S --help 2>&1); rc=$?; [ "$rc" = 0 ] && has "$out" "sala motion add" && ok "--help prints the usage" || bad "help: rc=$rc"
$S >/dev/null 2>&1; [ $? = 2 ] && ok "no verb: exit 2" || bad "no verb"
$S frobnicate >/dev/null 2>&1; [ $? = 2 ] && ok "an unknown verb: exit 2" || bad "unknown verb"
$S add --for chat-test >/dev/null 2>&1; [ $? = 2 ] && ok "add with no line: exit 2" || bad "add no arg"
$S clear extra --for chat-test >/dev/null 2>&1; [ $? = 2 ] && ok "clear with an argument: exit 2" || bad "clear arg"
$S add "x" --json --for chat-test >/dev/null 2>&1; [ $? = 2 ] && ok "--json on add: exit 2" || bad "--json on add"

echo "motion: $([ $fail = 0 ] && echo pass || echo FAIL)"
exit $fail
