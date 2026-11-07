#!/usr/bin/env bash
# tests/mockup.sh — `sala mockup` (lib/mockup.sh, lib/mockup.py, systemd/sala-mockup-clean.{service,timer}; docs/mockup.md). Everything runs in one temporary
# tree (locked while the suite runs, removed at its end); nothing touches the real state folder, systemd or the board. No process is killed, no tmux.
#   add       numbering from 1, one URL on stdout and nothing else, parallel adds taking different numbers (the counter under its lock), a number never
#             given again after a page is deleted (also with the counter file lost), modes 700/600, stdin, the refusals (empty, over 5 MiB, not UTF-8, NUL byte,
#             a missing file, a directory) writing nothing and taking no number, the viewport note, the address from SALA_SESSION_URL (path only without it)
#   list      table and --json; remove
#   clean     the age rule (old and unlinked deleted, old and linked kept, young kept), SALA_MOCKUP_REFERENCES unset = keep everything and say why, `none`,
#             a failing or silent-unreadable command = keep everything + exit 1, --dry-run, a stale half-written page removed
#   cap       the 1 GB rule (here a small cap, fake sizes and ages, the clock injected): oldest first, a linked page last, an unlinked young page before a
#             linked old one, stopping as soon as the folder is under the cap, the age rule running first, the cap's own unconfigured case, a folder still
#             over with only linked pages left going down to the last one, --max-bytes and SALA_MOCKUP_MAX_BYTES, the 1 GB default
#   units     the daily timer and its service (lane, project, ExecStart)
# Usage: bash tests/mockup.sh   (exit 0 = pass; a few seconds)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
. "$ROOT/tests/lib.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/sala-mockup.XXXXXX")
exec 8< "$T"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
trap 'exec 8<&-; rm -rf "$T"' EXIT
export HOME=$T/home SALA_CONFIG=/dev/null XDG_STATE_HOME=$T/state SALA_STATE_DIR=$T/state/salamander
unset SALA_SESSION_URL SALA_MOCKUP_DIR SALA_MOCKUP_NOW SALA_MOCKUP_REFERENCES SALA_MOCKUP_KEEP_DAYS SALA_MOCKUP_MAX_BYTES SALA_MOCKUP_TEMPLATE
mkdir -p "$HOME" "$T/in"
S="bash $ROOT/bin/salamander mockup"
D=$SALA_STATE_DIR/mockups
PAGE='<!doctype html><meta name="viewport" content="width=device-width, initial-scale=1"><title>t</title><p>hi'
printf '%s' "$PAGE" > "$T/in/a.html"

# -- add -----------------------------------------------------------------------------------------------------------------------------------
out=$($S add "$T/in/a.html" 2>"$T/err"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "/mockup/1" ] && ok "add: first page is 1; with no SALA_SESSION_URL the path alone is printed" || bad "add 1: rc=$rc out=[$out]"
grep -q 'SALA_SESSION_URL' "$T/err" && ok "add: without an address a note on stderr says what to prefix" || bad "add: no stderr note without SALA_SESSION_URL"
export SALA_SESSION_URL='https://sala.example.com/#s={name}'
out=$($S add "$T/in/a.html" 2>"$T/err"); [ "$out" = "https://sala.example.com/mockup/2" ] && [ ! -s "$T/err" ] && ok "add: the address is SALA_SESSION_URL's scheme and host; stdout holds the URL and nothing else" || bad "add 2: out=[$out] err=[$(cat "$T/err")]"
out=$($S "$T/in/a.html" 2>/dev/null); [ "$out" = "https://sala.example.com/mockup/3" ] && ok "sala mockup FILE is add" || bad "bare FILE form: [$out]"
out=$(printf '%s' "$PAGE" | $S add - 2>/dev/null); [ "$out" = "https://sala.example.com/mockup/4" ] && [ "$(cat "$D/4.html")" = "$PAGE" ] && ok "add -: stdin is stored as it came" || bad "stdin add: [$out]"
[ "$(stat -c %a "$D")" = 700 ] && [ "$(stat -c %a "$D/1.html")" = 600 ] && [ "$(stat -c %a "$D/counter")" = 600 ] && ok "modes: folder 700, pages and counter 600" || bad "modes: $(stat -c %a "$D" "$D/1.html" "$D/counter" | tr '\n' ' ')"
[ "$(cat "$D/counter")" = 4 ] && ok "the counter holds the last number given" || bad "counter: [$(cat "$D/counter")]"
ls -A "$D" | grep -q '^\.tmp-' && bad "add left a temporary file" || ok "add leaves no temporary file"

# viewport note
printf '<p>no meta' > "$T/in/nv.html"
$S add "$T/in/nv.html" >/dev/null 2>"$T/err"; grep -qi 'viewport' "$T/err" && ok "add: a page without a viewport meta gets a note on stderr" || bad "no viewport note"
$S remove 5 >/dev/null

# refusals write nothing and take no number
before=$(cat "$D/counter"); n_before=$(ls "$D" | grep -c '\.html$')
: > "$T/in/empty.html"; head -c $((5*1024*1024+1)) /dev/zero | tr '\0' 'x' > "$T/in/big.html"; printf 'a\000b' > "$T/in/nul.html"; printf '\377\376bad' > "$T/in/latin.html"
for f in empty big nul latin missing; do
    $S add "$T/in/$f.html" >/dev/null 2>"$T/err"; rc=$?
    [ "$rc" = 1 ] && [ -s "$T/err" ] && ok "add refuses $f.html (exit 1, a sentence)" || bad "add $f: rc=$rc"
done
$S add "$T/in" >/dev/null 2>&1; [ $? = 1 ] && ok "add refuses a directory" || bad "add a directory"
head -c $((5*1024*1024)) /dev/zero | tr '\0' 'x' > "$T/in/limit.html"
out=$($S add "$T/in/limit.html" 2>/dev/null); [ -n "$out" ] && ok "add takes a page of exactly 5 MiB" || bad "5 MiB page refused"
$S remove "${out##*/}" >/dev/null
after=$(cat "$D/counter")
# the exactly-5-MiB add took one number (and was removed); the refusals took none
[ "$after" = "$((before + 1))" ] && [ "$(ls "$D" | grep -c '\.html$')" = "$n_before" ] && ok "refusals take no number and write no page" || bad "counter $before -> $after, pages $n_before -> $(ls "$D" | grep -c '\.html$')"
ls -A "$D" | grep -q '^\.tmp-' && bad "a refusal left a temporary file" || ok "a refusal leaves no temporary file"
$S --x >/dev/null 2>&1; [ $? = 2 ] && ok "an unknown option is a usage error (exit 2)" || bad "unknown option exit"
$S >/dev/null 2>&1; [ $? = 2 ] && ok "no argument prints the usage and exits 2" || bad "no-argument exit"
$S --help 2>&1 | grep -q 'max-bytes' && ok "--help describes the cap" || bad "help lacks --max-bytes"

# never reused
$S remove 4 >/dev/null; out=$($S add "$T/in/a.html" 2>/dev/null); n=${out##*/}
[ "$n" -gt 4 ] && ok "a deleted page's number is not given again ($n)" || bad "number reused: $n"
$S remove "$n" >/dev/null; rm -f "$D/counter"
out=$($S add "$T/in/a.html" 2>/dev/null); m=${out##*/}
[ "$m" -gt 3 ] && ok "a lost counter file is rebuilt from the highest page (next $m)" || bad "lost counter: $m"
$S remove 99999 >/dev/null 2>&1; [ $? = 1 ] && ok "remove of an unknown page exits 1" || bad "remove unknown"

# parallel adds take different numbers
rm -rf "$D"; mkdir -p "$T/par"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do ( $S add "$T/in/a.html" > "$T/par/$i" 2>/dev/null ) & done; wait
got=$(cat "$T"/par/* | sed 's#.*/##' | sort -n | tr '\n' ' ')
[ "$got" = "1 2 3 4 5 6 7 8 9 10 11 12 " ] && [ "$(ls "$D" | grep -c '\.html$')" = 12 ] && [ "$(cat "$D/counter")" = 12 ] && ok "12 parallel adds take 12 different numbers 1..12 (counter under its lock)" || bad "parallel: [$got]"

# list / remove
$S list | grep -q '/mockup/12' && ok "list shows the pages" || bad "list"
$S list --json | python3 -I -c 'import json,sys; r=json.load(sys.stdin); assert len(r)==12 and r[0]["n"]==1 and r[0]["url"].endswith("/mockup/1") and r[0]["bytes"]>0' 2>/dev/null && ok "list --json is an array of pages" || bad "list --json"
$S remove 12 >/dev/null && [ ! -e "$D/12.html" ] && ok "remove deletes the page" || bad "remove"

# -- clean ---------------------------------------------------------------------------------------------------------------------------------
NOW=2000000000; export SALA_MOCKUP_NOW=$NOW
DAY=86400
mkpage() {      # mkpage N BYTES AGE_DAYS: a fake page of that size and age
    head -c "$2" /dev/zero | tr '\0' 'x' > "$D/$1.html"; touch -d "@$((NOW - $3 * DAY))" "$D/$1.html"; }
reset() { rm -rf "$D"; mkdir -p "$D"; chmod 700 "$D"; echo "${1:-100}" > "$D/counter"; }
pages() { ls "$D" | grep '\.html$' | sed 's/\.html//' | sort -n | tr '\n' ' '; }
cat > "$T/refs" <<'SH'
#!/bin/sh
# a stand-in for the host's board reader: prints a board item's text with a link for each number in $REFS_FILE
echo "open item: see the mockup"
for n in $(cat "$REFS_FILE" 2>/dev/null); do echo "  https://sala.example.com/mockup/$n (the draft)"; done
SH
chmod +x "$T/refs"; export REFS_FILE=$T/linked
printf '3\n' > "$T/linked"

reset; mkpage 1 100 10; mkpage 2 100 8; mkpage 3 100 9; mkpage 4 100 2; mkpage 5 100 0
out=$($S clean 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(pages)" = "1 2 3 4 5 " ] && echo "$out" | grep -q 'SALA_MOCKUP_REFERENCES is not set' && ok "clean, reference unset: keeps every page and says why (exit 0)" || bad "unset: rc=$rc pages=[$(pages)] $out"
echo "$out" | grep -q '1, 2, 3' && ok "the unset message names the pages it kept" || bad "unset message: $out"

SALA_MOCKUP_REFERENCES="$T/refs" $S clean --dry-run >/dev/null 2>&1; [ "$(pages)" = "1 2 3 4 5 " ] && ok "--dry-run deletes nothing" || bad "dry-run deleted: $(pages)"
out=$(SALA_MOCKUP_REFERENCES="$T/refs" $S clean --dry-run 2>&1); echo "$out" | grep -q 'would delete 1' && echo "$out" | grep -q 'would delete 2' && ok "--dry-run names what it would delete" || bad "dry-run text: $out"
out=$(SALA_MOCKUP_REFERENCES="$T/refs" $S clean 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(pages)" = "3 4 5 " ] && ok "clean: pages over 7 days old go, except the one an open item links (3); young ones stay" || bad "age rule: rc=$rc pages=[$(pages)] $out"
echo "$out" | grep -q 'kept 3: an open board item links it' && ok "the kept page is named with its reason" || bad "kept line: $out"

reset; mkpage 1 100 30; mkpage 2 100 1
SALA_MOCKUP_REFERENCES=none $S clean >/dev/null 2>&1; [ "$(pages)" = "2 " ] && ok "SALA_MOCKUP_REFERENCES=none: age alone decides" || bad "none: $(pages)"
reset; mkpage 1 100 30; mkpage 2 100 9
SALA_MOCKUP_REFERENCES=none SALA_MOCKUP_KEEP_DAYS=10 $S clean >/dev/null 2>&1; [ "$(pages)" = "2 " ] && ok "SALA_MOCKUP_KEEP_DAYS sets the keep time" || bad "keep days env: $(pages)"
reset; mkpage 1 100 30; mkpage 2 100 9
SALA_MOCKUP_REFERENCES=none $S clean --days 40 >/dev/null 2>&1; [ "$(pages)" = "1 2 " ] && ok "--days sets the keep time" || bad "--days: $(pages)"

reset; mkpage 1 100 30; mkpage 2 100 1
for spec in "$T/nonexistent-reader" "false"; do
    out=$(SALA_MOCKUP_REFERENCES="$spec" $S clean 2>&1); rc=$?
    [ "$rc" = 1 ] && [ "$(pages)" = "1 2 " ] && ok "a reader that cannot run ($spec) keeps every page and exits 1" || bad "failing reader $spec: rc=$rc pages=[$(pages)] $out"
done
printf '#!/bin/sh\nexit 0\n' > "$T/silent"; chmod +x "$T/silent"
out=$(SALA_MOCKUP_REFERENCES="$T/silent" $S clean 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(pages)" = "2 " ] && ok "a reader that succeeds and names nothing means nothing is linked" || bad "silent reader: rc=$rc pages=[$(pages)]"
reset; mkpage 1 100 30
printf '#!/bin/sh\nexec sleep 1000\n' > "$T/slow"; chmod +x "$T/slow"
# a timeout of 60 s would stall the suite: the module's constant is patched through python for this one case
out=$(python3 -I -S - "$ROOT/lib" "$D" "$T/slow" <<'PY' 2>&1
import sys
sys.path.insert(0, sys.argv[1])
import mockup
mockup.REF_TIMEOUT_S = 1
lines = []
rc = mockup.clean(sys.argv[2], 2000000000, 7, sys.argv[3], say=lines.append)
print(rc, " ".join(lines))
PY
)
case "$out" in "1 "*took*) [ "$(pages)" = "1 " ] && ok "a reader that times out keeps every page (exit 1)" || bad "timeout deleted";; *) bad "timeout case: $out";; esac
# the reader never gets a shell
reset; mkpage 1 100 30; touch "$T/shell-ran"; rm "$T/shell-ran"
SALA_MOCKUP_REFERENCES="true; touch $T/shell-ran" $S clean >/dev/null 2>&1; [ ! -e "$T/shell-ran" ] && ok "the reader command runs without a shell" || bad "reader ran through a shell"

# a stale half-written page is removed, a fresh one is left
reset; mkpage 1 100 0; echo x > "$D/.tmp-1-aa"; touch -d "@$((NOW - 2 * DAY))" "$D/.tmp-1-aa"; echo x > "$D/.tmp-2-bb"; touch -d "@$((NOW - 60))" "$D/.tmp-2-bb"
$S clean >/dev/null 2>&1; [ ! -e "$D/.tmp-1-aa" ] && [ -e "$D/.tmp-2-bb" ] && ok "clean removes a half-written page older than a day and leaves a fresh one" || bad "temp cleanup"
$S clean 2>&1 | grep -q 'nothing to do' && ok "a folder with nothing old and under the cap says nothing to do" || bad "nothing-to-do text"

# -- the cap -------------------------------------------------------------------------------------------------------------------------------
# cap 1000 bytes; the counter file holds 4 bytes ("100\n") and counts toward the folder
CAPARGS="--max-bytes 1000"
reset; for n in 1 2 3 4 5; do mkpage $n 300 $((6 - n)); done      # 5 pages x 300 = 1500: ages 5,4,3,2,1 days (young: no age rule)
SALA_MOCKUP_REFERENCES=none $S clean $CAPARGS >/dev/null 2>&1
[ "$(pages)" = "3 4 5 " ] && ok "cap: over the cap, the oldest pages go first until the folder is under it" || bad "cap order: [$(pages)]"
total=$(find "$D" -maxdepth 1 -type f -printf '%s\n' | awk '{s+=$1} END {print s}'); [ "$total" -le 1000 ] && ok "cap: the folder ends at $total bytes, under 1000" || bad "cap: $total bytes left"

reset; for n in 1 2 3 4 5; do mkpage $n 300 $((6 - n)); done; printf '1\n2\n' > "$T/linked"
out=$(SALA_MOCKUP_REFERENCES="$T/refs" $S clean $CAPARGS 2>&1)
[ "$(pages)" = "1 2 5 " ] && ok "cap: pages an open item links go last (oldest unlinked 3 and 4 go, the old linked 1 and 2 stay)" || bad "cap linked last: [$(pages)] $out"
echo "$out" | grep -q 'deleted 3 (folder over its 1000 byte cap)' && ok "cap: the delete line names the cap as the reason" || bad "cap line: $out"

reset; for n in 1 2 3 4 5; do mkpage $n 300 $((6 - n)); done; printf '1\n2\n3\n4\n5\n' > "$T/linked"
out=$(SALA_MOCKUP_REFERENCES="$T/refs" $S clean $CAPARGS 2>&1)
[ "$(pages)" = "3 4 5 " ] && echo "$out" | grep -q 'last resort' && ok "cap: when only linked pages are left and the folder is still over, the oldest linked go (last resort)" || bad "cap all linked: [$(pages)] $out"

reset; mkpage 1 600 30; mkpage 2 600 20; mkpage 3 600 1; printf '1\n' > "$T/linked"     # 1800: age rule frees 600 (page 2), cap 1000 -> 1204 left? see below
out=$(SALA_MOCKUP_REFERENCES="$T/refs" $S clean $CAPARGS 2>&1)
# age rule: 2 is old and unlinked -> deleted (1 kept, linked). left: 1 (600) + 3 (600) + counter = 1204 > 1000: cap deletes unlinked 3 before linked 1... 3 is young but unlinked
[ "$(pages)" = "1 " ] && ok "cap: an unlinked young page goes before a linked old one; the age rule ran first" || bad "age then cap: [$(pages)] $out"
echo "$out" | grep -q 'deleted 2 (older than 7 days)' && echo "$out" | grep -q 'deleted 3 (folder over' && ok "cap: the output tells which rule deleted each page" || bad "rule lines: $out"

reset; for n in 1 2 3; do mkpage $n 300 $((6 - n)); done      # 900 + counter = 904: under the cap
SALA_MOCKUP_REFERENCES=none $S clean $CAPARGS >/dev/null 2>&1; [ "$(pages)" = "1 2 3 " ] && ok "cap: a folder under the cap loses nothing (young pages)" || bad "under cap: [$(pages)]"

reset; for n in 1 2 3 4 5; do mkpage $n 300 $((6 - n)); done
out=$($S clean $CAPARGS 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(pages)" = "1 2 3 4 5 " ] && echo "$out" | grep -q 'SALA_MOCKUP_REFERENCES is not set' && echo "$out" | grep -q 'over the 1000 byte cap' && ok "cap, reference unset: keeps everything, exits 0 and says the folder is over the cap and why" || bad "cap unset: rc=$rc [$(pages)] $out"
out=$(SALA_MOCKUP_REFERENCES=false $S clean $CAPARGS 2>&1); rc=$?
[ "$rc" = 1 ] && [ "$(pages)" = "1 2 3 4 5 " ] && ok "cap, reader failing: keeps everything and exits 1" || bad "cap failing reader: rc=$rc [$(pages)]"
SALA_MOCKUP_REFERENCES=none $S clean --dry-run $CAPARGS 2>&1 | grep -q 'would delete 1 (folder over' && [ "$(pages)" = "1 2 3 4 5 " ] && ok "cap: --dry-run names the pages it would delete and deletes none" || bad "cap dry-run"
SALA_MOCKUP_REFERENCES=none SALA_MOCKUP_MAX_BYTES=1000 $S clean >/dev/null 2>&1; [ "$(pages)" = "3 4 5 " ] && ok "SALA_MOCKUP_MAX_BYTES sets the cap" || bad "env cap: [$(pages)]"

# sizes and ages are read per page: a big young page does not shield older small ones; ties on age go by number
reset; mkpage 1 100 3; mkpage 2 100 3; mkpage 3 900 1
SALA_MOCKUP_REFERENCES=none $S clean --max-bytes 1010 >/dev/null 2>&1; [ "$(pages)" = "2 3 " ] && ok "cap: equal ages go by number; stops as soon as the folder fits" || bad "tie order: [$(pages)]"

# the default cap is 1 GB and the pass reads it
python3 -I -S -c "
import sys; sys.path.insert(0, '$ROOT/lib'); import mockup
assert mockup.CAP_BYTES_DEFAULT == 1024**3, mockup.CAP_BYTES_DEFAULT
assert mockup.KEEP_DAYS_DEFAULT == 7" && ok "defaults: keep 7 days, cap 1 GB (1073741824 bytes)" || bad "defaults"
reset; mkpage 1 100 0
$S clean 2>&1 | grep -q '1073741824' && ok "the default cap shows in the pass's output" || bad "default cap not shown"
SALA_MOCKUP_MAX_BYTES=abc $S clean >/dev/null 2>&1; [ $? = 1 ] && ok "a bad SALA_MOCKUP_MAX_BYTES is refused" || bad "bad cap env"
$S clean --max-bytes >/dev/null 2>&1; [ $? = 2 ] && ok "--max-bytes without a value is a usage error" || bad "--max-bytes usage"

# -- the daily unit ------------------------------------------------------------------------------------------------------------------------
svc=$ROOT/systemd/sala-mockup-clean.service; tm=$ROOT/systemd/sala-mockup-clean.timer
grep -q '^ExecStart=%h/.local/bin/salamander mockup clean$' "$svc" && ok "sala-mockup-clean.service runs the clean pass" || bad "service ExecStart"
grep -q '^X-Model-Lane=none$' "$svc" && grep -q '^X-Project=' "$svc" && grep -q '^Description=' "$svc" && ok "the service names its lane (none: no model call) and project" || bad "service headers"
grep -q '^OnCalendar=\*-\*-\* [0-9:]* UTC$' "$tm" && grep -q '^Persistent=true$' "$tm" && ok "the timer is daily and persistent" || bad "timer schedule"

echo "mockup: $([ $fail = 0 ] && echo pass || echo FAIL)"
exit $fail
