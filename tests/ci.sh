#!/usr/bin/env bash
# The CI gate's helpers (.github/scripts/, Wed Oct 14th 2026), which decide what the runners run. They stay tested
# because a wrong `sala=false` merges a sala change with no suite run (release.sh reads a skipped job as a verdict).
# changed.sh against a throwaway repo with a tests/suites.map of its own:
# a sala-only change, the CI's own files without and with web/, web/ created, a web-only change, both, docs (no suite), web/
# removed, an empty diff, no range: `sala=`, `web=` and `suites=` exactly.
# tests/suitemap.sh (Tue Oct 27th 2026), which names the suites a pull request runs, against another throwaway repo
# with a hand-made map of three suites: --select for each rule (a suite file, a mapped file, a full file, comments only in a
# full file, a code line beside the comments, a shebang, a mode change, docs, an unmapped file, a changed suite line, a changed
# full line, a deleted mapped file, .github/, web/, no range, no map) and --check clean and for each kind of problem.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME=$(mktemp -d); mkdir -p "$HOME/bin"; export PATH="$HOME/bin:$PATH"
trap 'rm -rf "$HOME"' EXIT
CHANGED="$ROOT/.github/scripts/changed.sh"

echo "== changed.sh"
R="$HOME/repo"; git init -q -b main "$R"; git -C "$R" config user.email t@t; git -C "$R" config user.name t
commit() {  # <message> <file>… → the commit; each file written with the message as its content
    local m="$1"; shift; local f
    for f in "$@"; do mkdir -p "$R/$(dirname "$f")"; echo "$m $f" > "$R/$f"; done
    git -C "$R" add -A; git -C "$R" commit -q -m "$m"; git -C "$R" rev-parse HEAD
}
remove() { git -C "$R" rm -q -r "$1"; git -C "$R" commit -q -m "rm $1"; git -C "$R" rev-parse HEAD; }
expect() {  # <from> <to> <sala> <web> <suites> <label>: the three output lines, exactly
    local out rc; out=$(cd "$R" && bash "$CHANGED" "$1" "$2" 2>"$HOME/changed.err"); rc=$?
    [ "$rc" = 0 ] && [ "$out" = "sala=$3"$'\n'"web=$4"$'\n'"suites=$5" ] && ok "$6: sala=$3 web=$4 suites=${5:-<none>}" \
        || bad "$6: rc=$rc out=$(echo "$out" | paste -sd' ') log=$(paste -sd' ' "$HOME/changed.err")"
}
mkdir -p "$R/tests"; cat > "$R/tests/suites.map" <<'MAP'
full tests/lib.sh
none docs/* *.md
text gamma
suite alpha lib/a.sh
suite beta lib/a.sh lib/b.sh
suite gamma lib/c.sh
MAP
c0=$(commit base lib/a.sh lib/b.sh lib/c.sh README.md tests/alpha.sh tests/beta.sh tests/gamma.sh tests/lib.sh)
c1=$(commit sala lib/a.sh)
c2=$(commit ci .github/workflows/tests.yml)
c3=$(commit webadd web/pyproject.toml web/src/x.py)
c4=$(commit webonly web/src/x.py)
c5=$(commit both lib/a.sh web/src/x.py)
c6=$(commit ci2 .github/scripts/changed.sh)
c7=$(commit docs README.md CONTRIBUTING.md)
c8=$(remove web)
expect "$c0" "$c1" true false "alpha beta" "a sala change: the suites that open the file"
expect "$c1" "$c2" true false all "the CI's own files, no web/ yet: every suite"
expect "$c2" "$c3" false true "" "web/ created: the web tests alone, no suite names it"
expect "$c3" "$c4" false true "" "a web-only change: the web tests alone"
expect "$c4" "$c5" true true "alpha beta" "a change to both: both"
expect "$c5" "$c6" true true all "the CI's own files with web/ present: both, every suite"
expect "$c6" "$c7" false false "" "docs: no suite, no web test"
expect "$c7" "$c8" false false "" "web/ removed: nothing to test"
expect "$c0" "$c0" false false "" "an empty diff: nothing to test"
expect 0000000000000000000000000000000000000000 "$c7" true true all "no range (a zero sha), web/ present: everything"
expect none "$c8" true false all "no range, web/ absent: every suite"
expect "$c0" "$c7" true true all "the whole range: both"
expect HEAD^1 HEAD false false "" "HEAD^1 HEAD, the form tests.yml passes for a PR's merge commit (here web/ removed): resolved"

echo "== suitemap.sh"
TOOL="$ROOT/tests/suitemap.sh"
S="$HOME/sm"; git init -q -b main "$S"; git -C "$S" config user.email t@t; git -C "$S" config user.name t
put() { mkdir -p "$S/$(dirname "$1")"; cat > "$S/$1"; }   # <file>: the content on stdin
mkdir -p "$S/docs"; echo x > "$S/docs/root.txt"; git -C "$S" add -A; git -C "$S" commit -q -m root; root=$(git -C "$S" rev-parse HEAD)   # a commit with no map
for f in lib/a.sh lib/b.sh lib/c.sh bin/salamander tests/alpha.sh tests/beta.sh tests/gamma.sh tests/lib.sh; do
    printf '#!/usr/bin/env bash\n# a comment\n\necho %s\n' "$f" | put "$f"
done
echo "print('x')" | put web/src/x.py; echo "# docs" | put docs/x.md; echo "# readme" | put README.md; echo "# notes" | put NOTES.md; echo "name: w" | put .github/workflows/w.yml
put tests/suites.map <<'MAP'
# a hand-made map of three suites
full bin/salamander tests/lib.sh
none docs/* NOTES.md
text gamma
firstline beta
suite alpha lib/a.sh
suite beta lib/a.sh lib/b.sh
suite gamma lib/c.sh web/src/x.py README.md
MAP
git -C "$S" add -A; git -C "$S" commit -q -m base; B=$(git -C "$S" rev-parse HEAD)
variant() {  # <commands run inside the repo, on top of base> → the commit they make (additions, changes and deletions)
    git -C "$S" checkout -q -f "$B"; git -C "$S" clean -fdq
    ( cd "$S" && eval "$1" ) >/dev/null 2>&1; git -C "$S" add -A; git -C "$S" commit -q --allow-empty -m v; git -C "$S" rev-parse HEAD
}
sel() { SUITEMAP_ROOT="$S" bash "$TOOL" --select "$1" "$2" 2>"$HOME/sel.err"; }
want() {  # <label> <expected stdout> <commands>: --select base..variant prints the expected line and exits 0
    local v out rc; v=$(variant "$3"); out=$(sel "$B" "$v"); rc=$?
    [ "$rc" = 0 ] && [ "$out" = "$2" ] && ok "select: $1 → ${2:-<none>}" || bad "select: $1: rc=$rc out='$out' want '$2' log=$(paste -sd'|' "$HOME/sel.err")"
}
want "a suite file (tests/beta.sh, code added)" "beta" 'echo "echo more" >> tests/beta.sh'
want "a mapped lib file (lib/b.sh)" "beta" 'echo "echo more" >> lib/b.sh'
want "a lib file two suites open (lib/a.sh)" "alpha beta" 'echo "echo more" >> lib/a.sh'
want "a full file (bin/salamander)" "all" 'echo "echo more" >> bin/salamander'
want "a full file, comments and blank lines only: the text suites" "gamma" 'printf "\n# a note\n   # another\n" >> bin/salamander'
want "comments and a code line together: the normal rule (full → all)" "all" 'printf "# a note\necho more\n" >> bin/salamander'
want "a comment line removed from a mapped file: the text suites" "gamma" "sed -i '/^# a comment/d' lib/b.sh"
want "the shebang changed: not a comment, the normal rule" "alpha beta" "sed -i '1s|.*|#!/bin/bash|' lib/a.sh"
want "a mode change alone is not a comment" "alpha beta" 'chmod +x lib/a.sh'
want "a code line changed beside a comment line" "beta" "sed -i 's/^echo lib.b.sh/echo changed/; s/^# a comment/# another/' lib/b.sh"
want "a comment-only change to a suite file: the text suites" "gamma" 'echo "# note" >> tests/beta.sh'
want "docs (none): no suite" "" 'echo more >> docs/x.md; echo more >> NOTES.md'
want "a README-like file a text suite reads as content: that suite" "gamma" 'echo more >> README.md'
want "a new unmapped file: everything" "all" 'echo "echo n" > lib/new.sh'
want "a new file that matches none: nothing" "" 'echo n > docs/new.md'
want "a suite line changed in the map: that suite" "alpha" "sed -i 's|^suite alpha .*|suite alpha lib/a.sh lib/b.sh|' tests/suites.map"
want "a suite line added for a new suite: that suite" "delta" "echo 'echo d' > tests/delta.sh; echo 'suite delta lib/c.sh' >> tests/suites.map"
want "the map's header changed: nothing" "" "sed -i '1s/.*/# another header/' tests/suites.map"
want "a full line changed in the map: everything" "all" "sed -i 's|^full .*|full bin/salamander|' tests/suites.map"
want "a none line changed in the map: everything" "all" "sed -i 's|^none .*|none docs/*|' tests/suites.map"
want "a text line changed in the map: everything" "all" "sed -i 's|^text .*|text alpha|' tests/suites.map"
want "a firstline line changed in the map: everything" "all" "sed -i 's|^firstline .*|firstline alpha|' tests/suites.map"
want "a mapped file deleted and dropped from the map (named only at the from end)" "beta" "git rm -q lib/b.sh; sed -i 's|^suite beta .*|suite beta lib/a.sh|' tests/suites.map"
want "a mapped file deleted, the map unchanged" "beta" 'git rm -q lib/b.sh'
want "a mapped file renamed is both names: the old one selects its suites, the new one is unmapped" "all" 'git mv lib/b.sh lib/b2.sh'
want "a change under .github/: everything" "all" 'echo more >> .github/workflows/w.yml'
want "a web file a suite names: that suite" "gamma" 'echo "print(2)" >> web/src/x.py'
want "a web file no suite names: nothing" "" 'echo "print(3)" > web/src/y.py'
want "two files whose union is every suite" "all" 'echo more >> lib/a.sh; echo more >> lib/c.sh'
want "two files, a union of two" "alpha beta" 'echo more >> lib/a.sh; echo more >> lib/b.sh'
want "a deleted suite file, named by no line: everything" "all" 'git rm -q tests/gamma.sh'
v=$(variant 'echo more >> lib/a.sh')
out=$(sel "$root" "$v"); [ "$out" = all ] && ok "select: no map at the from end → all" || bad "no map at from: '$out'"
out=$(sel "$B" "$root"); [ "$out" = all ] && ok "select: no map at the to end → all" || bad "no map at to: '$out'"
out=$(sel 0000000000000000000000000000000000000000 "$v"); [ "$out" = all ] && ok "select: a from that does not resolve → all" || bad "bad from: '$out'"
out=$(sel "$B" nonsense); [ "$out" = all ] && ok "select: a to that does not resolve → all" || bad "bad to: '$out'"
out=$(sel "$B" "$B"); [ -z "$out" ] && ok "select: an empty diff → none" || bad "empty diff: '$out'"
v=$(variant 'echo more >> lib/b.sh'); sel "$B" "$v" >/dev/null
grep -q 'lib/b.sh: named by the suites beta' "$HOME/sel.err" && ok "select: the reason for each file goes to stderr" || bad "stderr: $(paste -sd'|' "$HOME/sel.err")"

echo "== suitemap.sh --check"
chk() {  # <label> <expected line, as a substring> <commands run inside the repo, on the base tree>: exit 1 and that line
    local out rc; git -C "$S" checkout -q -f "$B"; git -C "$S" clean -fdq; ( cd "$S" && eval "$3" ) >/dev/null 2>&1; git -C "$S" add -A
    out=$(SUITEMAP_ROOT="$S" bash "$TOOL" --check 2>&1); rc=$?
    [ "$rc" = 1 ] && [[ $out == *"$2"* ]] && ok "check: $1" || bad "check: $1: rc=$rc want '$2' got '$out'"
}
git -C "$S" checkout -q -f "$B"; out=$(SUITEMAP_ROOT="$S" bash "$TOOL" --check 2>&1); rc=$?
[ "$rc" = 0 ] && [[ $out == "suitemap: ok (3 suites,"* ]] && ok "check: a clean map passes" || bad "check clean: rc=$rc $out"
chk "a suite with no line" "missing: no suite line for gamma: measure it (bash tests/suitemap.sh --measure gamma)" "sed -i '/^suite gamma/d' tests/suites.map"
chk "a suite line twice" "duplicate: alpha has more than one suite line" "echo 'suite alpha lib/a.sh' >> tests/suites.map"
chk "a suite line for a suite that is gone" "extra: a suite line for delta but no tests/delta.sh: delete the line" "echo 'suite delta lib/c.sh' >> tests/suites.map"
chk "a tracked file no line or glob covers" "unmapped: lib/new.sh: measure the suites that use it" "echo n > lib/new.sh"
chk "a file a line names that is not tracked" "stale: lib/gone.sh on alpha's line: re-measure (bash tests/suitemap.sh --measure alpha)" "sed -i 's|^suite alpha .*|suite alpha lib/a.sh lib/gone.sh|' tests/suites.map"
chk "a file removed while a line still names it" "stale: lib/b.sh on beta's line" "git rm -q lib/b.sh"
chk "a text name that is not a suite" "bad text name: nosuch is not a suite" "sed -i 's|^text .*|text gamma nosuch|' tests/suites.map"
chk "a non-text suite whose line names a none file" "none but used: docs/x.md is on alpha's line and matches a none pattern" "sed -i 's|^suite alpha .*|suite alpha lib/a.sh docs/x.md|' tests/suites.map"
chk "a text suite that is not firstline names a none file" "none but used: docs/x.md is on gamma's line and matches a none pattern" "sed -i 's|^suite gamma .*|suite gamma lib/c.sh web/src/x.py README.md docs/x.md|' tests/suites.map"
chk "a firstline name that is not a suite" "bad firstline name: nosuch is not a suite" "sed -i 's|^firstline .*|firstline beta nosuch|' tests/suites.map"
chk "a line that is none of the four kinds" "unknown line: 'nope lib/a.sh'" "echo 'nope lib/a.sh' >> tests/suites.map"
chk "a new suite file with no line" "missing: no suite line for delta" "echo 'echo d' > tests/delta.sh"
git -C "$S" checkout -q -f "$B"; git -C "$S" clean -fdq; sed -i 's|^suite beta .*|suite beta lib/a.sh lib/b.sh docs/x.md|' "$S/tests/suites.map"
out=$(SUITEMAP_ROOT="$S" bash "$TOOL" --check 2>&1); rc=$?
[ "$rc" = 0 ] && ok "check: a firstline suite may name a none file (it opens everything for line 1)" || bad "text suite none: rc=$rc $out"
git -C "$S" checkout -q -f "$B"; SUITEMAP_ROOT="$S" bash "$TOOL" --bogus >/dev/null 2>&1; [ $? = 2 ] && ok "an unknown subcommand: usage, exit 2" || bad "usage exit"

[ "$fail" = 0 ] && echo "ci: pass" || echo "ci: FAIL"
exit $fail
