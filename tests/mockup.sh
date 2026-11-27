#!/usr/bin/env bash
# tests/mockup.sh — `sala mockup` (lib/mockup.sh, lib/mockup.py, systemd/sala-mockup-clean.{service,timer}; docs/mockup.md). Everything runs in one temporary
# tree (locked while the suite runs, removed at its end); nothing touches the real state folder, systemd or the board. No process is killed, no tmux.
#   add       numbering from 1, one URL on stdout and nothing else, parallel adds taking different numbers (the counter under its lock), a number never
#             given again after a page is deleted (also with the counter file lost), modes 700/600, stdin, the refusals (empty, over 5 MiB, not UTF-8, NUL byte,
#             a missing file, a directory, a page that letters its designs) writing nothing and taking no number, the viewport note, the address from SALA_SESSION_URL (path only without it)
#   lettered  a page whose visible text letters its designs (Variant A, Option B, Design C, Layout D, a non-breaking space, the Korean words built from
#             escapes) is refused naming the phrases and saying to name the designs; named designs, a design word with no letter, a sentence ending before a
#             capital, a lowercase letter, and "Variant A" inside script, style, a comment or a class/id attribute are taken
#   newwin    a link, area, form, base (target) or button, input (formtarget) naming a window other than this one (_blank, _new, a frame name, any case or
#             spacing) is refused by add and by update, one line naming the tag, nothing written, no number taken, no version saved; _self, _top, _parent,
#             no target or an empty one are taken, and _blank inside a script string, a comment or plain text is taken
#   list      table and --json; the versions folder is not a page
#   update    replaces page N in place (same number and address, the same output, the same checks) and saves the page it replaces
#             as a version (versions/N/<UTC time>.html); history lists the versions, newest first; undo restores the newest one and saves
#             what it replaces; a page with no version is refused; remove and clean delete the versions with the page; the cap counts them
#   remove    refused for a page a linked item names (SALA_MOCKUP_REFERENCES), also when the reader fails; --force removes it; unset, empty, none as before
#   clean     the age rule (old and unlinked deleted, old and linked kept, young kept), SALA_MOCKUP_REFERENCES unset = keep everything and say why, `none`,
#             a failing or silent-unreadable command = keep everything + exit 1, --dry-run, a stale half-written page removed
#   cap       the 1 GB rule (here a small cap, fake sizes and ages, the clock injected): oldest first, a linked page last, an unlinked young page before a
#             linked old one, stopping as soon as the folder is under the cap, the age rule running first, the cap's own unconfigured case, a folder still
#             over with only linked pages left going down to the last one, --max-bytes and SALA_MOCKUP_MAX_BYTES, the 1 GB default
#   config    SALA_MOCKUP_REFERENCES / _KEEP_DAYS / _MAX_BYTES set in the config file only (not the environment), as under the daily service
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
export SALA_SESSION_URL='https://sala.example.com/s/{name}'
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

# a page that letters its designs: refused, naming the phrases; nothing written, no number taken
lettered() {   # NAME CONTENT: write the page, add it; refused = exit 1, a sentence naming the designs, the counter and the pages unchanged
    local name=$1 want=$2 c0 n0 rc
    c0=$(cat "$D/counter"); n0=$(ls "$D" | grep -c '\.html$')
    printf '%s' "$3" > "$T/in/$name.html"
    $S add "$T/in/$name.html" >"$T/out" 2>"$T/err"; rc=$?
    if [ "$rc" = 1 ] && [ ! -s "$T/out" ] && grep -q "$want" "$T/err" && grep -q 'name each design' "$T/err" \
        && [ "$(cat "$D/counter")" = "$c0" ] && [ "$(ls "$D" | grep -c '\.html$')" = "$n0" ]; then ok "lettered: $name is refused (names the phrase, says to name the designs, no number, no page)"
    else bad "lettered $name: rc=$rc err=[$(cat "$T/err")] counter $c0 -> $(cat "$D/counter")"; fi
}
accepted() {   # NAME CONTENT: the page is stored (and removed again, so the counter alone moves)
    local name=$1 out
    printf '%s' "$2" > "$T/in/$name.html"
    out=$($S add "$T/in/$name.html" 2>/dev/null); rc=$?
    if [ "$rc" = 0 ] && [ -n "$out" ]; then ok "lettered: $name is taken"; $S remove "${out##*/}" >/dev/null; else bad "lettered $name: rc=$rc"; fi
}
lettered let-variant 'Variant A' '<!doctype html><title>t</title><h1>Variant A</h1><p>x</p>'
lettered let-option 'Option B' '<title>t</title><p>Option B: a panel</p>'
lettered let-design 'design C' '<title>t</title><div><b>design C</b></div>'
lettered let-layout 'Layout D' '<title>t</title><li>Layout D'
lettered let-nbsp 'Variant A' "<title>t</title><p>Variant$(printf '\302\240')A</p>"
lettered let-entity 'Option B' '<title>t</title><p>Option&nbsp;B</p>'
lettered let-markup 'Proposal C' '<title>t</title><p>Proposal <b>C</b></p>'
ko_opt=$(python3 -c 'print(chr(0xC635) + chr(0xC158) + " A", end="")'); ko_draft=$(python3 -c 'print(chr(0xC2DC) + chr(0xC548) + "B", end="")')
ko_design=$(python3 -c 'print(chr(0xB514) + chr(0xC790) + chr(0xC778) + " C", end="")')   # the Korean words for option, draft design, design: code points, no Hangul in the file
lettered let-ko-option "$ko_opt" "<title>t</title><p>$ko_opt</p>"
lettered let-ko-draft "$ko_draft" "<title>t</title><p>$ko_draft</p>"
lettered let-ko-design "$ko_design" "<title>t</title><p>$ko_design</p>"
printf '%s' '<title>t</title><p>Variant A, Option B, Design C, Layout D, Variant A</p>' > "$T/in/let-many.html"
$S add "$T/in/let-many.html" >/dev/null 2>"$T/err"
grep -q '"Variant A", "Option B", "Design C")' "$T/err" && ! grep -q 'Layout D' "$T/err" && ok "lettered: at most 3 distinct phrases are listed, as the page words them" || bad "lettered list: [$(cat "$T/err")]"
accepted let-named '<title>t</title><h2>One-line strip</h2><h2>Fuller panel</h2>'
accepted let-noletter '<title>t</title><p>The design is final. The variant, the option and the layout stay.</p>'
accepted let-period '<title>t</title><p>Pick from the options. A new line follows.</p>'
accepted let-lower '<title>t</title><p>Option a and variant b</p>'
accepted let-script '<title>t</title><script>var s="Variant A"; // Option B</script><p>x</p>'
accepted let-style '<title>t</title><style>/* Design C */ .x::after{content:"Layout D"}</style><p>x</p>'
accepted let-comment '<title>t</title><!-- Variant A --><p>x</p>'
accepted let-attr '<title>t</title><p class="variant-a" id="option-B" title="x">x</p>'
accepted let-word '<title>t</title><p>Optional A or the Variants B</p>'

# a page that opens a new window (a target or formtarget naming a window other than this one): refused by add, nothing written, no number taken;
# the message names the tag and the attribute as written, one line
newwin() {   # NAME CONTENT WANT: refused = exit 1, one line holding WANT, the counter and the pages unchanged
    local name=$1 want=$3 c0 n0 rc
    c0=$(cat "$D/counter"); n0=$(ls "$D" | grep -c '\.html$')
    printf '%s' "$2" > "$T/in/$name.html"
    $S add "$T/in/$name.html" >"$T/out" 2>"$T/err"; rc=$?
    if [ "$rc" = 1 ] && [ ! -s "$T/out" ] && [ "$(wc -l < "$T/err")" = 1 ] && grep -qF "$want" "$T/err" \
        && grep -q 'cannot open a new window' "$T/err" && grep -q 'remove the' "$T/err" \
        && [ "$(cat "$D/counter")" = "$c0" ] && [ "$(ls "$D" | grep -c '\.html$')" = "$n0" ]; then ok "new window: $name is refused by add (names $want)"
    else bad "new window $name: rc=$rc err=[$(cat "$T/err")] counter $c0 -> $(cat "$D/counter")"; fi
}
newwin nw-a '<title>t</title><a href="x" target="_blank">x</a>' '<a target="_blank">'
newwin nw-area '<map><area href="x" target="_blank"></map>' '<area target="_blank">'
newwin nw-form '<form target="_new"></form>' '<form target="_new">'
newwin nw-base '<base href="x" target="_blank">' '<base target="_blank">'
newwin nw-button '<button formtarget="_blank">x</button>' '<button formtarget="_blank">'
newwin nw-input '<input type="submit" formtarget=" _Blank ">' '<input formtarget="_Blank">'
newwin nw-caps '<a href="x" target="_BLANK">x</a>' '<a target="_BLANK">'
newwin nw-named '<a href="x" target="frame1">x</a>' '<a target="frame1">'
newwin nw-second '<a href="x" target="_self">x</a><a href="y" target="_blank">y</a>' '<a target="_blank">'
accepted tgt-self '<title>t</title><a href="x" target="_self">x</a>'
accepted tgt-top-parent '<title>t</title><a href="x" target="_top">x</a><a href="y" target=" _PARENT ">y</a>'
accepted tgt-none '<title>t</title><a href="x">x</a><a href="y" target="">y</a><a href="z" target>z</a><button formtarget="_self">b</button><input formtarget="_top">'
accepted tgt-script '<title>t</title><script>var s = "<a target=\"_blank\">"; window.open("x", "_blank")</script><p>x</p>'
accepted tgt-comment '<title>t</title><!-- <a href="x" target="_blank">x</a> --><p>x</p>'
accepted tgt-text '<title>t</title><p>Use target="_blank" in your link, or formtarget=_blank.</p>'

# update refuses the same page: the stored page and its versions are unchanged, no number taken
out=$($S add "$T/in/a.html" 2>/dev/null); u=${out##*/}
printf '%s' '<title>t</title><a href="x" target="_blank">x</a>' > "$T/in/upd-new-window.html"
v0=$(ls "$D/versions/$u" 2>/dev/null | wc -l); c0=$(cat "$D/counter")
$S update "$u" "$T/in/upd-new-window.html" >"$T/out" 2>"$T/err"; rc=$?
if [ "$rc" = 1 ] && [ ! -s "$T/out" ] && grep -qF '<a target="_blank">' "$T/err" && grep -q 'cannot open a new window' "$T/err" \
    && cmp -s "$D/$u.html" "$T/in/a.html" && [ "$(ls "$D/versions/$u" 2>/dev/null | wc -l)" = "$v0" ] && [ "$(cat "$D/counter")" = "$c0" ]; then
    ok "new window: update refuses a page that opens a new window (page $u unchanged, no version, no number)"
else bad "new window update: rc=$rc err=[$(cat "$T/err")]"; fi
$S remove "$u" >/dev/null
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

# -- the three settings from the config file alone ------------------------------------------------------------------------------------------
# The config is sourced by the shell (common.sh): a `NAME=value` line there is not in the environment unless lib/mockup.sh exports it. The daily
# service has only PATH in its environment, so here none of the three is in the environment (the unset at the top) and each comes from SALA_CONFIG.
printf 'SALA_MOCKUP_REFERENCES="%s"\n' "$T/refs" > "$T/cfg-ref"
printf 'SALA_MOCKUP_REFERENCES=none\nSALA_MOCKUP_KEEP_DAYS=10\n' > "$T/cfg-days"
printf 'SALA_MOCKUP_REFERENCES=none\nSALA_MOCKUP_MAX_BYTES=1000\n' > "$T/cfg-cap"
reset; mkpage 1 100 30; mkpage 2 100 1; mkpage 3 100 30; printf '3\n' > "$T/linked"
out=$(SALA_CONFIG="$T/cfg-ref" $S clean 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(pages)" = "2 3 " ] && ! echo "$out" | grep -q 'is not set' && ok "config file only: SALA_MOCKUP_REFERENCES (a command) reaches the pass: an old linked page stays, an old unlinked one goes" || bad "config REFERENCES: rc=$rc pages=[$(pages)] $out"
reset; mkpage 1 100 30; mkpage 2 100 9
SALA_CONFIG="$T/cfg-days" $S clean >/dev/null 2>&1; [ "$(pages)" = "2 " ] && ok "config file only: SALA_MOCKUP_KEEP_DAYS=10 keeps a 9-day-old page and drops a 30-day-old one" || bad "config KEEP_DAYS: [$(pages)]"
reset; for n in 1 2 3 4 5; do mkpage $n 300 $((6 - n)); done
SALA_CONFIG="$T/cfg-cap" $S clean >/dev/null 2>&1; [ "$(pages)" = "3 4 5 " ] && ok "config file only: SALA_MOCKUP_MAX_BYTES=1000 caps the folder, oldest first" || bad "config MAX_BYTES: [$(pages)]"
reset; mkpage 1 100 30
out=$(SALA_CONFIG="$T/cfg-ref" $S clean --dry-run 2>&1); [ "$(pages)" = "1 " ] && echo "$out" | grep -q 'would delete 1' && ok "config file only: --dry-run sees the setting too and deletes nothing" || bad "config dry-run: $out"

# -- the daily unit ------------------------------------------------------------------------------------------------------------------------
svc=$ROOT/systemd/sala-mockup-clean.service; tm=$ROOT/systemd/sala-mockup-clean.timer
grep -q '^ExecStart=%h/.local/bin/salamander mockup clean$' "$svc" && ok "sala-mockup-clean.service runs the clean pass" || bad "service ExecStart"
grep -q '^X-Model-Lane=none$' "$svc" && grep -q '^X-Project=' "$svc" && grep -q '^Description=' "$svc" && ok "the service names its lane (none: no model call) and project" || bad "service headers"
grep -q '^OnCalendar=\*-\*-\* [0-9:]* UTC$' "$tm" && grep -q '^Persistent=true$' "$tm" && ok "the timer is daily and persistent" || bad "timer schedule"

# -- update, undo, history, remove refusal ------------------------------------------------------------------------------------------------
# update saves the page it replaces as a version (versions/N/<UTC time>.html); history lists the versions; undo restores the newest one
# and saves what it replaces; remove refuses a page an open board item links (SALA_MOCKUP_REFERENCES); --force overrides it.
# The reader here is a stand-in script.
cat > "$T/rd" <<'SH'
#!/bin/sh
# a stand-in for the host's board reader: prints a link for each number listed in $REFS_FILE
for n in $(cat "$REFS_FILE" 2>/dev/null); do echo "  https://sala.example.com/mockup/$n (the draft)"; done
SH
chmod +x "$T/rd"; export REFS_FILE=$T/linked
unset SALA_SESSION_URL
M='<meta name="viewport" content="width=device-width, initial-scale=1">'
V="$D/versions/1"
reset 0
printf '%s' "$M<title>t</title><p>first</p>" > "$T/in/v1.html"; printf '%s' "$M<title>t</title><p>second</p>" > "$T/in/v2.html"
printf '%s' "$M<title>t</title><p>third</p>" > "$T/in/v3.html"
out=$($S add "$T/in/v1.html" 2>/dev/null); [ "$out" = "/mockup/1" ] && ok "update setup: page 1 added" || bad "update setup: [$out]"
out=$($S update 1 "$T/in/v2.html" 2>"$T/err"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "/mockup/1" ] && [ -z "$(grep -v "SALA_SESSION_URL is not set" "$T/err")" ] && ok "update: prints the same address as add (/mockup/1) and no other message" || bad "update out: rc=$rc out=[$out] err=[$(cat "$T/err")]"
[ "$(cat "$D/1.html")" = "$M<title>t</title><p>second</p>" ] && [ "$(ls "$V" | wc -l)" = 1 ] && [ "$(cat "$V/$(ls "$V")")" = "$M<title>t</title><p>first</p>" ] && ok "update: the page is replaced in place; the one it replaced is saved as its one version" || bad "update files: [$(cat "$D/1.html")] versions=[$(ls "$V" 2>/dev/null)]"
f=$(ls "$V"); echo "$f" | grep -Eq '^[0-9]{8}T[0-9]{6}\.[0-9]{6}Z\.html$' && [ "$(stat -c %a "$V/$f")" = 600 ] && [ "$(stat -c %a "$V")" = 700 ] && [ "$(stat -c %a "$D/versions")" = 700 ] && ! find "$D" -name '.tmp-*' | grep -q . && ok "update: the version is named by its UTC time, mode 600 in a 700 folder, and no temporary file is left" || bad "update names or modes: f=[$f] file=[$(stat -c %a "$V/$f" 2>/dev/null)] dir=[$(stat -c %a "$V" 2>/dev/null)]"
out=$($S add "$T/in/v3.html" 2>/dev/null); [ "$out" = "/mockup/2" ] && ok "update takes no number: the next add is 2" || bad "update took a number: [$out]"
$S update 99 "$T/in/v3.html" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ ! -e "$D/99.html" ] && [ ! -e "$D/versions/99" ] && ok "update of an unknown page exits 1 and writes nothing" || bad "update unknown: rc=$rc"
$S update 99 "$T/in/v3.html" 2>&1 >/dev/null | grep -q 'no page 99' && $S update 99 "$T/in/v3.html" 2>&1 >/dev/null | grep -q 'add' && ok "update of an unknown page says no page 99 and that a new page is add" || bad "update unknown text"
before=$(ls "$V" | wc -l)
$S update 1 "$T/in/empty.html" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(cat "$D/1.html")" = "$M<title>t</title><p>second</p>" ] && [ "$(ls "$V" | wc -l)" = "$before" ] && ok "update refused (unreadable source): the page and its versions are unchanged" || bad "update refused source changed the page: rc=$rc"
printf '%s' "$M<title>t</title><p>from stdin</p>" | $S update 1 - >/dev/null 2>&1 && [ "$(cat "$D/1.html")" = "$M<title>t</title><p>from stdin</p>" ] && [ "$(ls "$V" | wc -l)" = 2 ] && ok "update -: stdin replaces the page and the one it replaced is a second version" || bad "update stdin"
$S update abc "$T/in/v1.html" >/dev/null 2>&1; [ "$?" = 2 ] && ok "update with a non-number N is a usage error (exit 2)" || bad "update non-number exit"
out=$(SALA_SESSION_URL='https://sala.example.com/s/{name}' $S update 1 "$T/in/v1.html" 2>/dev/null); [ "$out" = "https://sala.example.com/mockup/1" ] && [ "$(ls "$V" | wc -l)" = 3 ] && ok "update prints the address from SALA_SESSION_URL as add does, and saves a third version" || bad "update address: [$out] versions=$(ls "$V" | wc -l)"

# history: the versions of page 1, newest first, one line each: when saved (UTC), size, file name
out=$($S history 1 2>/dev/null); rc=$?
printf '%s\n' "$out" | python3 -I -c 'import re,sys
l = sys.stdin.read().splitlines()
assert len(l) == 3, l
assert all(re.fullmatch(r"\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{6} UTC\t\d+ bytes\t\d{8}T\d{6}\.\d{6}Z\.html", x) for x in l), l' 2>/dev/null && names=$(printf '%s\n' "$out" | cut -f3) && [ "$rc" = 0 ] && [ "$names" = "$(printf '%s\n' "$names" | sort -r)" ] && [ "$(printf '%s\n' "$names" | sort -u | wc -l)" = 3 ] && ok "history: three versions, newest first, each with its UTC time, size and name; the names are unique" || bad "history: rc=$rc out=[$out]"
out=$($S history 2 2>/dev/null); rc=$?; [ "$rc" = 0 ] && [ -z "$out" ] && ok "history of a page with no versions prints nothing and exits 0" || bad "history empty: rc=$rc out=[$out]"
$S history abc >/dev/null 2>&1; [ "$?" = 2 ] && ok "history with a non-number N is a usage error (exit 2)" || bad "history non-number exit"

# undo restores the newest version (page 1 now = the SESSION_URL revision, the newest version = the stdin page) and saves what it replaces
out=$($S undo 1 2>/dev/null); rc=$?
[ "$rc" = 0 ] && [ "$out" = "/mockup/1" ] && [ "$(cat "$D/1.html")" = "$M<title>t</title><p>from stdin</p>" ] && [ "$(ls "$V" | wc -l)" = 3 ] && [ "$(cat "$V/$(ls "$V" | tail -1)")" = "$M<title>t</title><p>first</p>" ] && ok "undo: page 1 is the newest version (the stdin one), and what it replaced is saved as the newest version" || bad "undo: rc=$rc out=[$out] page=[$(cat "$D/1.html")] versions=$(ls "$V" | wc -l)"
$S undo 1 >/dev/null 2>&1 && [ "$(cat "$D/1.html")" = "$M<title>t</title><p>first</p>" ] && [ "$(ls "$V" | wc -l)" = 3 ] && [ "$(cat "$V/$(ls "$V" | tail -1)")" = "$M<title>t</title><p>from stdin</p>" ] && ok "undo twice goes back to where it started (and the version list still has three)" || bad "undo twice: page=[$(cat "$D/1.html")]"
$S undo 99 >/dev/null 2>&1; [ "$?" = 1 ] && ok "undo of an unknown page exits 1" || bad "undo unknown"
$S undo 2 >/dev/null 2>"$T/err"; rc=$?
[ "$rc" = 1 ] && grep -q 'no earlier version' "$T/err" && ok "undo of a page with no version exits 1 and says so" || bad "undo no version: rc=$rc [$(cat "$T/err")]"

# list ignores the versions folder
$S list --json | python3 -I -c 'import json,sys; r=json.load(sys.stdin); assert [p["n"] for p in r]==[1,2]' 2>/dev/null && ok "list: the versions folder is not listed as a page" || bad "list shows versions"

# clean deletes a page's versions with the page; a version of a page that is gone goes once it is past the keep time
V_OLD=20200101T000000.000000Z.html; V_NEW=20260101T000000.000000Z.html
mkver() {       # mkver N NAME BYTES AGE_DAYS: one saved version of page N
    mkdir -p "$D/versions/$1"; chmod 700 "$D/versions/$1"; head -c "$3" /dev/zero > "$D/versions/$1/$2"; touch -d "@$((NOW - $4 * DAY))" "$D/versions/$1/$2"; }
reset 0; mkpage 1 100 30; mkver 1 $V_OLD 100 30
mkpage 2 100 1; mkver 2 $V_OLD 100 1
mkver 9 $V_OLD 1 30
SALA_MOCKUP_REFERENCES=none $S clean >/dev/null 2>&1
[ "$(pages)" = "2 " ] && [ ! -e "$D/versions/1" ] && [ -e "$D/versions/2/$V_OLD" ] && [ ! -e "$D/versions/9" ] && ok "clean: an old page's versions go with it; a young page's versions stay; the versions of a gone page go past the keep time" || bad "clean versions: pages=[$(pages)] $(find "$D" | tr '\n' ' ')"

# the size cap counts versions: page 1 with its 300-byte version is the oldest and goes first, both together
reset 0; mkpage 1 300 3; mkver 1 $V_OLD 300 3; mkpage 2 300 2; mkpage 3 100 1
SALA_MOCKUP_REFERENCES=none $S clean --max-bytes 1000 >/dev/null 2>&1
[ "$(pages)" = "2 3 " ] && [ ! -e "$D/versions/1" ] && ok "cap: versions count toward the folder size and go with their page" || bad "cap versions: pages=[$(pages)] $(find "$D" | tr '\n' ' ')"

# remove: refused for a linked page (its versions stay); --force removes both; unset, empty or none removes as before
reset 0; $S add "$T/in/v1.html" >/dev/null 2>&1; $S add "$T/in/v2.html" >/dev/null 2>&1; $S update 1 "$T/in/v3.html" >/dev/null 2>&1
printf '1\n' > "$T/linked"
out=$(SALA_MOCKUP_REFERENCES="$T/rd" $S remove 1 2>&1); rc=$?
[ "$rc" = 1 ] && echo "$out" | grep -q 'linked by an open board item' && [ -e "$D/1.html" ] && [ -d "$D/versions/1" ] && ok "remove: a page an open board item links is refused (exit 1); the page and its versions stay" || bad "remove linked: rc=$rc out=[$out]"
SALA_MOCKUP_REFERENCES="$T/rd" $S remove 2 >/dev/null 2>&1 && [ ! -e "$D/2.html" ] && ok "remove: a page nothing links is removed under a reader" || bad "remove unlinked under reader"
SALA_MOCKUP_REFERENCES="$T/rd" $S remove --force 1 >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -e "$D/1.html" ] && [ ! -e "$D/versions/1" ] && ok "remove --force: a linked page and its versions are removed" || bad "remove --force: rc=$rc"
reset 0; $S add "$T/in/v1.html" >/dev/null 2>&1; $S update 1 "$T/in/v2.html" >/dev/null 2>&1; printf '1\n' > "$T/linked"
SALA_MOCKUP_REFERENCES=none $S remove 1 >/dev/null 2>&1 && [ ! -e "$D/1.html" ] && [ ! -e "$D/versions/1" ] && ok "remove: SALA_MOCKUP_REFERENCES=none removes a linked-looking page and its versions as before" || bad "remove none"
reset 0; $S add "$T/in/v1.html" >/dev/null 2>&1
env -u SALA_MOCKUP_REFERENCES $S remove 1 >/dev/null 2>&1 && [ ! -e "$D/1.html" ] && ok "remove: SALA_MOCKUP_REFERENCES unset removes a page as before" || bad "remove unset"
reset 0; $S add "$T/in/v1.html" >/dev/null 2>&1
SALA_MOCKUP_REFERENCES="$T/nonexistent-reader" $S remove 1 >"$T/out" 2>"$T/err"; rc=$?
[ "$rc" = 1 ] && [ -e "$D/1.html" ] && grep -q 'not removed' "$T/err" && ok "remove: a reader that cannot run refuses the removal (exit 1), page stays" || bad "remove failing reader: rc=$rc [$(cat "$T/err")]"
SALA_MOCKUP_REFERENCES=false $S remove --force 1 >/dev/null 2>&1 && [ ! -e "$D/1.html" ] && ok "remove --force: skips a failing reader and removes the page" || bad "remove --force skips reader"
reset 0; $S remove 1 >/dev/null 2>&1; [ "$?" = 1 ] && ok "remove of a page that is not there still exits 1" || bad "remove missing"

echo "mockup: $([ $fail = 0 ] && echo pass || echo FAIL)"
exit $fail
