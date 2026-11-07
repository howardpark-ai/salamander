#!/usr/bin/env bash
# The clean-text check (.github/scripts/clean_text.py, run by .github/workflows/clean-text.yml; CONTRIBUTING.md, "Clean commit and
# PR text"): a pull request's branch name, title, body and commit messages carry no private data. Outside the rule's letter in
# docs/test-coverage.md (no session, draft or map is at stake), kept because the check is the only thing between a commit message
# and a public-facing GitHub page, and a pattern that silently stops matching is invisible until the data is already out.
# The script against throwaway repos, nothing on the network, no variable of GitHub's: the CI mode (the texts in CLEAN_TEXT_*) and
# `--local <base>`. Checked: each rule (a board id of both shapes; the owner's name, the board host, a host below the owner's domain
# and the bare domain, all lines of the deny data with made-up values; a word of the deny variable) in each place it is read (branch, title, body line, commit);
# the allowed forms (a bare #123, the org `quillworks-org`, a Claude session URL, a Co-Authored-By line, bare initials) passing; the deny
# variable unset, empty, and set (one regex per line, newline-separated only, comments and blank lines skipped, an invalid regex
# exiting 2 by line number, any case, ASCII word boundaries so Japanese next to a name does not hide it, a hyphen being part of a
# word; every rule, built-in ones too, on ASCII boundaries); the base fetched as the full refs/remotes/origin/<ref> (a same-named tag does not stand in) with a timeout; a merge
# commit skipped while its parents' commits are scanned; the output carrying the matched text and never the surrounding text or
# a whole body; a call it cannot answer (a missing variable, a base that does not resolve) exiting 2, not 0.
# The temporary folder is made first under a trap, locked for the run, and removed on the way out, pass or fail.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
T=""
trap '[ -n "$T" ] && rm -rf "$T"' EXIT
T=$(mktemp -d "${TMPDIR:-/tmp}/sala-cleantext.XXXXXX")
exec 8< "$T"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
export HOME="$T/home"; mkdir -p "$HOME"
unset XDG_CONFIG_HOME CLEAN_TEXT_DENY CLEAN_TEXT_BRANCH CLEAN_TEXT_TITLE CLEAN_TEXT_BODY CLEAN_TEXT_BASE CLEAN_TEXT_BASE_REF CLEAN_TEXT_HEAD
CT="$ROOT/.github/scripts/clean_text.py"
# The code holds no owner value: the owner's first name and domain are lines of the deny data. Made-up ones here.
OWN=$'quill\nquillworks\\.example'
R="$T/repo"; git init -q -b main "$R"; git -C "$R" config user.email t@t; git -C "$R" config user.name t; git -C "$R" config commit.gpgsign false

cm() { git -C "$R" commit -q --allow-empty "$@"; }   # cm -m subject [-m body]
rev() { git -C "$R" rev-parse HEAD; }
short() { git -C "$R" rev-parse --short=7 HEAD; }

# ci: the CI mode. B branch, TT title, BD body, BASE/HEAD the range; DENY set (even empty) = the variable set, unset = not set;
# BREF set = the base branch name is passed (CLEAN_TEXT_BASE_REF); LOC set = the run's LC_ALL.
B=topic; TT="a clean title"; BD="a clean body"; BASE=""; HEAD=""
ci() {
    local envs=(CLEAN_TEXT_BRANCH="$B" CLEAN_TEXT_TITLE="$TT" CLEAN_TEXT_BODY="$BD" CLEAN_TEXT_BASE="$BASE" CLEAN_TEXT_HEAD="$HEAD")
    [ -n "${DENY+x}" ] && envs+=(CLEAN_TEXT_DENY="$DENY")
    [ -n "${BREF+x}" ] && envs+=(CLEAN_TEXT_BASE_REF="$BREF")
    [ -n "${LOC+x}" ] && envs+=(LC_ALL="$LOC")
    [ -n "${PATHX+x}" ] && envs+=(PATH="$PATHX:$PATH")
    [ -n "${FT+x}" ] && envs+=(CLEAN_TEXT_FETCH_TIMEOUT="$FT")
    out=$(cd "$R" && env "${envs[@]}" python3 -I "$CT" 2>&1); rc=$?
}
expect_hit() {  # <line> <label>: exit 1 and the exact line is in the output
    if [ "$rc" = 1 ] && grep -qxF -- "$1" <<< "$out"; then ok "$2"; else bad "$2: rc=$rc out=$(paste -sd'|' <<< "$out")"; fi
}
expect_clean() {  # <label>: exit 0 and no hit line
    if [ "$rc" = 0 ] && ! grep -Eq '\((board id|deny list)\)' <<< "$out"; then ok "$1"; else bad "$1: rc=$rc out=$(paste -sd'|' <<< "$out")"; fi; }

cm -m "base"; c0=$(rev)
git -C "$R" checkout -q -b topic

echo "== clean text passes, the allowed forms with it"
BASE=$c0; cm -m "add the thing" -m "it fixes #123 and follows PR #45"; HEAD=$(rev); unset DENY
B=topic; TT="a clean title (#7)"; BD=$'a clean body\nsecond line, closes #12'
ci; expect_clean "clean branch, title, body and commit; bare #123 and #12 are GitHub's own references"
grep -q 'CLEAN_TEXT_DENY is not set or empty' <<< "$out" && ok "the deny variable unset: one notice line says the rule is skipped" || bad "no notice: $out"
[ "$(grep -c 'CLEAN_TEXT_DENY' <<< "$out")" = 1 ] && ok "the notice is one line" || bad "notice count: $out"
DENY="$OWN"
BASE=$c0; cm -m "link the org" -m $'see https://github.com/quillworks-org/salamander/pull/9 and quillworks-org/stackshot\n\nCo-Authored-By: Quill Sample <noreply@example.invalid>\nClaude-Session: https://claude.ai/code/session_01AbC-xyz_9'; HEAD=$(rev)
BD=$'repo quillworks-org/salamander\n\nhttps://claude.ai/code/session_01AbC-xyz_9\nco-authored-by: Quill <x@example.invalid>'
ci; expect_clean "the org quillworks-org (hyphen), a session URL and a Co-Authored-By line (even naming the owner) are allowed"
TT="QS asked for it, qs style"; BD="QS"; ci; expect_clean "bare initials are not matched"
TT="a clean title"; BD="a clean body"

echo "== each rule, in each place (the owner's name and domain are deny lines)"
BASE=$c0; cm -m "fix the thing" -m "tracks board#15"; HEAD=$(rev); S=$(short)
ci; expect_hit "commit $S line 3: board#15 (board id)" "board#<digits> in a commit message body (line 3: subject, blank, body): commit, line, text, rule"
BASE=$(rev); cm -m "see board-tmp-demo#7 for why"; HEAD=$(rev); S=$(short)
ci; expect_hit "commit $S: board-tmp-demo#7 (board id)" "board-tmp-<word>#<digits> in a commit subject (a one-line message carries no line number)"
BASE=$c0; HEAD=$c0; TT="Board#9009: rename"; ci; expect_hit "title: Board#9009 (board id)" "a board id in any case, in the title"
TT="a clean title"; BD=$'intro\nnothing here\nclosing board#31 now'; ci; expect_hit "body line 3: board#31 (board id)" "a board id on line 3 of the body"
BD="a clean body"; TT="tell quill about it"; ci; expect_hit "title: quill (deny list)" "the owner's name, any case, in the title"
TT="a clean title"; BD="QUILL's call"; ci; expect_hit "body: QUILL (deny list)" "the owner's name in capitals in the body"
BD="see https://stackshot.quillworks.example/item/3"; ci; expect_hit "body: quillworks.example (deny list)" "the board host"
BD="a.b.quillworks.example and quillworks.example"; ci
[ "$rc" = 1 ] && [ "$(grep -cxF "body: quillworks.example (deny list)" <<< "$out")" = 2 ] && ok "a host below the owner's domain, and the bare domain" || bad "domain: rc=$rc $out"
BD="a clean body"; B="quill/fix"; ci; expect_hit "branch: quill (deny list)" "the owner's name in the branch name"
B="fix-board#9005"; ci; expect_hit "branch: board#9005 (board id)" "a board id in the branch name"
B=topic
BD=$'ok\nboard#9001 and Quill and board#9002'; ci
[ "$rc" = 1 ] && grep -qxF 'body line 2: board#9001 (board id)' <<< "$out" && grep -qxF 'body line 2: board#9002 (board id)' <<< "$out" && grep -qxF 'body line 2: Quill (deny list)' <<< "$out" && ok "three hits on one line: three report lines, and the count line after them" || bad "multi: $out"
grep -q '3 hit(s)' <<< "$out" && ok "the last line counts the hits" || bad "count: $out"
BASE=$c0; HEAD=$c0; BD="a clean body"
TT="Quillは分かる"; ci; expect_hit "title: Quill (deny list)" "the owner's name directly followed by Japanese is caught"
TT="ノードQuill"; ci; expect_hit "title: Quill (deny list)" "the owner's name directly after Japanese is caught"
TT="stackshot.quillworks.exampleは開く"; ci; expect_hit "title: quillworks.example (deny list)" "the owner's domain directly followed by Japanese is caught"
TT="ノードquillworks.example"; ci; expect_hit "title: quillworks.example (deny list)" "the owner's domain directly after Japanese is caught"
TT="ノードboard#9005は"; ci; expect_hit "title: board#9005 (board id)" "a board id between Japanese words is caught"
TT="Quillson, xquill, quillworks-org/x, quillworks.examplex"; ci; expect_clean "ASCII letters next to the name still make another word, and the org quillworks-org stays allowed"
TT="a clean title"

echo "== the deny variable (machine and session names, read at run time, never in the repo)"
BASE=$(rev); cm -m "move the job to node-alpha" -m $'then node-beta\nand Node-Alpha again'; HEAD=$(rev); S=$(short)
DENY=""; ci
[ "$rc" = 0 ] && grep -q 'CLEAN_TEXT_DENY is not set or empty' <<< "$out" && ok "empty variable: the rule is skipped with the notice, nothing flagged" || bad "empty: rc=$rc $out"
DENY=$' \n# node-alpha is only a comment here\n\n'; ci
[ "$rc" = 0 ] && grep -q 'CLEAN_TEXT_DENY is not set or empty' <<< "$out" && ok "a variable of blank lines and # comment lines counts as empty (a commented word is not applied)" || bad "comments only: rc=$rc $out"
unset DENY; ci
[ "$rc" = 0 ] && grep -q 'CLEAN_TEXT_DENY is not set or empty' <<< "$out" && ok "unset variable: the rule is skipped with the notice" || bad "unset: rc=$rc $out"
DENY=$'node-alpha\nnode-beta'; ci
expect_hit "commit $S line 1: node-alpha (deny list)" "newline-separated words: a hit on line 1 of the commit"
grep -qxF "commit $S line 3: node-beta (deny list)" <<< "$out" && grep -qxF "commit $S line 4: Node-Alpha (deny list)" <<< "$out" && ok "the second word, and the first again in another case (reported as written)" || bad "deny lines: $out"
! grep -q 'CLEAN_TEXT_DENY is not set' <<< "$out" && ok "no notice once the variable is set" || bad "notice with a set variable: $out"
DENY="node-beta, node-alpha"; ci; expect_clean "a comma is not a separator: the one line 'node-beta, node-alpha' is a single pattern and matches no text here"
DENY="node-(alpha){1,1}"; ci; expect_hit "commit $S line 1: node-alpha (deny list)" "a comma can be part of a regex (a repeat count): the line is kept whole"
BASE=$(rev); cm -m "node-alpha-2 and xnode-alpha and node-alphaes and node-alpha-x/y"; HEAD=$(rev)
DENY="node-alpha"; ci; expect_clean "whole words only: node-alpha-2, xnode-alpha, node-alphaes, node-alpha-x do not match node-alpha"
BASE=$(rev); cm -m "the host node-alpha, the other node-gamma-alpha"; HEAD=$(rev)
DENY="alpha"; ci; expect_clean "a hyphen is part of a word: alpha does not match inside node-alpha"
BASE=$(rev); cm -m "path /srv/node-alpha/x and (node-alpha) and node-alpha."; HEAD=$(rev); S=$(short)
DENY="node-alpha"; ci; [ "$(grep -c "deny list" <<< "$out")" = 3 ] && ok "a slash, parentheses and a full stop end a word: three hits" || bad "boundaries: $out"
DENY="node.alpha"; BASE=$c0; HEAD=$c0; TT="nodeXalpha and node.alpha"; ci; expect_hit "title: node.alpha (deny list)" "a line is a regex: node.alpha matches node.alpha"
grep -qxF "title: nodeXalpha (deny list)" <<< "$out" && [ "$(grep -c "deny list" <<< "$out")" = 2 ] && ok "and nodeXalpha, the dot being any character" || bad "regex: $out"
DENY=$'the-session'; TT="clean"; B="the-session/topic"; ci; expect_hit "branch: the-session (deny list)" "a deny word in the branch name"
B=topic; TT="a clean title"
DENY="x-y"; BASE=$(rev); cm -m "Co-Authored-By: x-y <a@b.invalid>"; HEAD=$(rev); ci; expect_clean "a Co-Authored-By line naming a deny word is allowed"
DENY="node-alpha"
BASE=$(rev); cm -m "run it with --node-alpha now"; HEAD=$(rev); S=$(short)
ci; expect_hit "commit $S: node-alpha (deny list)" "a leading dash is not part of the word: --node-alpha is caught"
BASE=$(rev); cm -m "the name node-alpha- ends a sentence"; HEAD=$(rev); S=$(short)
ci; expect_hit "commit $S: node-alpha (deny list)" "a trailing dash is not part of the word: node-alpha- is caught"
BASE=$(rev); cm -m "the unit node-alpha-ci and a-node-alpha and node-alpha-9"; HEAD=$(rev)
ci; expect_clean "a dash with a word character on its other side still continues the word: node-alpha-ci, a-node-alpha, node-alpha-9 are other names"

echo "== deny lines are regexes (one list serves the stackshot checker too)"
BASE=$c0; HEAD=$c0; B=topic; TT="host node-gamma and NODE-EPSILON, node-delta, host9 and host"
DENY=$'# machine names\n\nnode-(gamma|epsilon)\n  host[0-9]+  \n'; ci
expect_hit "title: node-gamma (deny list)" "a regex line with an alternation matches"
expect_hit "title: NODE-EPSILON (deny list)" "the match is case-insensitive, reported as written"
grep -qxF "title: host9 (deny list)" <<< "$out" && ok "a second regex line matches (its spaces trimmed)" || bad "second line: $out"
[ "$(grep -c "deny list" <<< "$out")" = 3 ] && ok "the comment and blank lines add nothing; node-delta and a bare host are not matched" || bad "count: $out"
DENY=$'node-gamma\nnode-(gamma|zeta)'; ci
[ "$(grep -c "deny list" <<< "$out")" = 1 ] && ok "two lines matching the same text report it once" || bad "dedupe: $out"
TT="the node-alphaは host and ノードnode-alpha and node-alpha-ciは"; DENY="node-alpha"; ci
[ "$rc" = 1 ] && [ "$(grep -cxF "title: node-alpha (deny list)" <<< "$out")" = 2 ] && ok "ASCII boundaries: Japanese right after (node-alphaは) or right before (ノードnode-alpha) the name does not hide it; node-alpha-ci still is another name" || bad "japanese boundary: rc=$rc $out"
TT="a clean title"
DENY=$'node-alpha\ra'; BASE=$c0; HEAD=$c0; TT="x node-alpha y"; ci
expect_clean "the list is split on newlines only: a carriage return inside a line stays in its pattern (node-alpha<CR>a), it does not cut the line in two"
TT="a clean title"
DENY=$'node-alpha\na)|(b'; ci
[ "$rc" = 2 ] && grep -qxF "clean-text: CLEAN_TEXT_DENY line 2 is not a valid regular expression" <<< "$out" && ok "a line that is only valid once wrapped (a)|(b) is invalid on its own: exit 2, not a way past the boundaries" || bad "unbalanced: rc=$rc $out"
DENY=$'node-alpha\nnode-(zq9secret'; ci
[ "$rc" = 2 ] && grep -qxF "clean-text: CLEAN_TEXT_DENY line 2 is not a valid regular expression" <<< "$out" && ok "an invalid regex exits 2 naming the variable and the line number" || bad "invalid regex: rc=$rc $out"
! grep -q 'zq9secret' <<< "$out" && ok "and never echoes the line" || bad "line echoed: $out"
DENY=$'# a comment (\n\nnode-(zq9secret'; ci
[ "$rc" = 2 ] && grep -qF "CLEAN_TEXT_DENY line 3 " <<< "$out" && ok "the line number counts blank and comment lines" || bad "line number: rc=$rc $out"
unset DENY

echo "== a merge commit is skipped, the commits it merged are not"
git -C "$R" checkout -q -b side "$c0"; cm -m "side work with board#44"; side=$(short)
git -C "$R" checkout -q topic; BASE=$(rev); cm -m "topic work"
git -C "$R" merge -q --no-ff -m "Merge branch 'side' of board#99 for Quill" side; HEAD=$(rev); DENY="$OWN"
ci
[ "$rc" = 1 ] && grep -qxF "commit $side: board#44 (board id)" <<< "$out" && ok "the merged branch's own commit is scanned" || bad "merged commit: rc=$rc $out"
! grep -q 'board#99\|(deny list)' <<< "$out" && ok "the merge commit's message (board#99, Quill) is not" || bad "merge commit scanned: $out"
[ "$(grep -c '^commit ' <<< "$out")" = 1 ] && ok "one commit hit, from three commits in the range" || bad "count: $out"

echo "== the range starts at the base branch fetched fresh, so a merge of the base back in blames nothing of the base's"
git init -q --bare -b main "$T/origin.git"
git -C "$R" remote add origin "$T/origin.git"; git -C "$R" push -q origin main
git clone -q "$T/origin.git" "$T/other"; git -C "$T/other" config user.email t@t; git -C "$T/other" config user.name t; git -C "$T/other" config commit.gpgsign false
git -C "$T/other" commit -q --allow-empty -m "main moves on, see board#9001"; git -C "$T/other" push -q origin HEAD:main; mainc=$(git -C "$T/other" rev-parse --short=7 HEAD)
git -C "$R" checkout -q -b merged-back "$c0"; cm -m "branch work"
git -C "$R" fetch -q origin; git -C "$R" merge -q --no-ff -m "Merge main into merged-back" origin/main; HEAD=$(rev)
git -C "$R" update-ref refs/remotes/origin/main "$c0"   # the checkout's own origin/main is stale: only a fresh fetch moves it
BASE=$c0; B=merged-back; unset DENY
BREF=main; ci; expect_clean "main moved on with a commit carrying a board id and the branch merged it in: not blamed (origin/main fetched fresh)"
[ "$(git -C "$R" rev-parse --short=7 refs/remotes/origin/main)" = "$mainc" ] && ok "the check fetched origin/main itself (the stale local ref moved)" || bad "no fetch: origin/main stayed stale"
git -C "$R" update-ref refs/remotes/origin/main "$c0"; git -C "$R" tag origin/main "$c0"   # a tag named like the remote branch: `origin/main` would resolve to it first
ci; expect_clean "a tag named origin/main does not stand in for the fetched base: the full refs/remotes/origin/main is used"
git -C "$R" tag -d origin/main >/dev/null
echo "== a fetch that hangs is cut off, and the base sha is the fallback"
mkdir -p "$T/fakebin"; realgit=$(command -v git)
printf '#!/bin/sh\nif [ "$1" = fetch ]; then exec sleep 30; fi\nexec %s "$@"\n' "$realgit" > "$T/fakebin/git"; chmod +x "$T/fakebin/git"
PATHX="$T/fakebin"; FT=1; t0=$SECONDS; ci; el=$((SECONDS - t0)); unset PATHX FT
[ "$rc" = 1 ] && grep -q 'timed out fetching origin/main, scanning from the base sha' <<< "$out" && grep -qxF "commit $mainc: board#9001 (board id)" <<< "$out" && ok "a fetch past CLEAN_TEXT_FETCH_TIMEOUT: said on stderr, the base sha is the fallback" || bad "fetch timeout: rc=$rc $out"
[ "$el" -lt 20 ] && ok "and it came back in ${el}s, not the fake fetch's 30" || bad "timeout took ${el}s"
unset BREF; ci; expect_hit "commit $mainc: board#9001 (board id)" "without the base branch name the base sha is the start: main's own commit is in the range (the fallback)"
BREF=no-such-branch; ci
[ "$rc" = 1 ] && grep -q 'cannot fetch origin/no-such-branch, scanning from the base sha' <<< "$out" && grep -qxF "commit $mainc: board#9001 (board id)" <<< "$out" && ok "a base branch that cannot be fetched: said on stderr, the base sha is the fallback" || bad "fallback: rc=$rc $out"
unset BREF; B=topic

echo "== the output never carries a whole body, nor the text around a hit"
BASE=$c0; HEAD=$c0; BD=""; for i in $(seq 1 40); do BD+="unrelated filler line $i with ordinary words"$'\n'; done
BD+="the note about board#9005 and more words after it"$'\n'
for i in $(seq 41 60); do BD+="unrelated filler line $i with ordinary words"$'\n'; done
ci
[ "$rc" = 1 ] && grep -qxF 'body line 41: board#9005 (board id)' <<< "$out" && ok "a 61-line body: the one hit, by line number" || bad "long body: rc=$rc $out"
! grep -q 'filler' <<< "$out" && ! grep -q 'the note about' <<< "$out" && ! grep -q 'more words after' <<< "$out" && ok "no filler line, and not even the words around the hit, are printed" || bad "body echoed: $out"
[ "$(wc -l <<< "$out")" -le 3 ] && ok "the output is the notice, the hit and the count: ${#out} characters for a ${#BD}-character body" || bad "long output: $out"
BD="one line with board#9005 in a long sentence of other words"; ci
[[ $out != *"long sentence"* ]] && grep -qxF 'body: board#9005 (board id)' <<< "$out" && ok "a one-line body: the matched text alone" || bad "one-line body: $out"
BD="a clean body"

echo "== non-ASCII text under a C locale: read and printed, never a crash"
git -C "$R" checkout -q -b japanese "$c0"
BASE=$c0; cm -m "日本語の題 board#9005" -m "本文です ノードアルファ もある"; HEAD=$(rev); S=$(short); B=topic; LOC=C; DENY="ノードアルファ"
ci
[ "$rc" = 1 ] && grep -qxF "commit $S line 1: board#9005 (board id)" <<< "$out" && grep -qxF "commit $S line 3: ノードアルファ (deny list)" <<< "$out" && ok "a Japanese commit message under LC_ALL=C: hits reported, the hit text printed whole" || bad "japanese C locale: rc=$rc $out"
! grep -q 'Traceback' <<< "$out" && ok "no traceback" || bad "traceback: $out"
unset LOC DENY

echo "== a call it cannot answer fails, not passes"
out=$(cd "$R" && env CLEAN_TEXT_TITLE=x python3 -I "$CT" 2>&1); rc=$?
[ "$rc" = 2 ] && grep -q 'missing CLEAN_TEXT_BASE' <<< "$out" && ok "CI mode without the range variables: exit 2 naming them" || bad "missing env: rc=$rc $out"
for miss in CLEAN_TEXT_TITLE CLEAN_TEXT_BODY; do
    envs=(CLEAN_TEXT_BRANCH=topic CLEAN_TEXT_BASE="$c0" CLEAN_TEXT_HEAD="$c0")
    [ "$miss" = CLEAN_TEXT_TITLE ] || envs+=(CLEAN_TEXT_TITLE=)   # the other one is present and empty
    [ "$miss" = CLEAN_TEXT_BODY ] || envs+=(CLEAN_TEXT_BODY=)
    out=$(cd "$R" && env "${envs[@]}" python3 -I "$CT" 2>&1); rc=$?
    [ "$rc" = 2 ] && grep -q "missing $miss" <<< "$out" && ok "CI mode without $miss in the environment: exit 2 naming it" || bad "absent $miss: rc=$rc $out"
done
B=topic; TT=""; BD=""; BASE=$c0; HEAD=$c0; ci
[ "$rc" = 0 ] && ok "an empty title and body are present, not absent: exit 0" || bad "empty title/body: rc=$rc $out"
TT="a clean title"; BD="a clean body"
BASE=0000000000000000000000000000000000000001; HEAD=$(rev); ci
[ "$rc" = 2 ] && grep -q 'failed' <<< "$out" && ok "a base that does not resolve: exit 2, not a pass" || bad "bad base: rc=$rc $out"
out=$(cd "$R" && python3 -I "$CT" --local no-such-base 2>&1); rc=$?
[ "$rc" = 2 ] && ok "--local with a base that does not resolve: exit 2" || bad "local bad base: rc=$rc $out"

echo "== the client-side hooks (.githooks/): a commit and a push refused before anything leaves"
H="$T/hooked"; HR="$T/hremote.git"
git init -q -b main "$H"; git -C "$H" config user.email t@t; git -C "$H" config user.name t; git -C "$H" config commit.gpgsign false
git -C "$H" config core.hooksPath "$ROOT/.githooks"
git init -q --bare -b main "$HR"; git -C "$H" remote add origin "$HR"
export CLEAN_TEXT_DENY="$OWN"   # the hooks read the deny data from the environment (a deny file is exercised below)
hc() { out=$(git -C "$H" commit -q --allow-empty "$@" 2>&1); rc=$?; }
hshort() { git -C "$H" rev-parse --short=7 HEAD; }
hn() { git -C "$H" rev-list --count HEAD 2>/dev/null || echo 0; }
hp() { out=$(git -C "$H" push "$@" 2>&1); rc=$?; }
for f in commit-msg pre-push; do [ -x "$ROOT/.githooks/$f" ] && ok ".githooks/$f is executable" || bad ".githooks/$f is not executable"; done
hc -m "start the project"
[ "$rc" = 0 ] && [ "$(hn)" = 1 ] && ok "commit-msg: a clean message commits" || bad "clean commit: rc=$rc $out"
hc -m "fix the thing for board#9003"
[ "$rc" != 0 ] && grep -qxF "message: board#9003 (board id)" <<< "$out" && [ "$(hn)" = 1 ] && ok "commit-msg: a board id refuses the commit, names the hit, and no commit is made" || bad "bad commit: rc=$rc n=$(hn) $out"
hc -m "subject" -m "ask Quill first"
[ "$rc" != 0 ] && grep -qxF "message line 3: Quill (deny list)" <<< "$out" && ok "commit-msg: a hit on a body line carries its line number" || bad "bad body: rc=$rc $out"
hc -m "attribution only" -m $'Co-Authored-By: Quill <a@b.invalid>\nClaude-Session: https://claude.ai/code/session_01AbC-xyz_9'
[ "$rc" = 0 ] && ok "commit-msg: the allowed trailers pass" || bad "trailers: rc=$rc $out"
printf 'clean subject\n# board#9009 is a comment git drops\n' > "$T/msg1"
out=$(cd "$H" && python3 -I "$CT" --message-file "$T/msg1" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "--message-file: a # line is not scanned, as git drops it" || bad "comment line: rc=$rc $out"
printf 'clean subject\n\n# ------------------------ >8 ------------------------\ndiff of board#9009 and Quill\n' > "$T/msg2"
out=$(cd "$H" && python3 -I "$CT" --message-file "$T/msg2" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "--message-file: nothing under the scissors line (git commit -v's diff) is scanned" || bad "scissors: rc=$rc $out"
out=$(cd "$H" && python3 -I "$CT" --message-file "$T/no-such-file" 2>&1); rc=$?
[ "$rc" = 2 ] && ok "--message-file: a file it cannot read exits 2" || bad "unreadable message: rc=$rc $out"
git -C "$H" checkout -q -b side; hc -m "side work"; git -C "$H" checkout -q main; hc -m "main work"
out=$(git -C "$H" merge --no-ff -m "Merge side for board#77" side 2>&1); rc=$?
[ "$rc" = 0 ] && ok "commit-msg: a merge commit's message is not scanned (as in CI)" || bad "merge: rc=$rc $out"
hp origin main
[ "$rc" = 0 ] && [ "$(git -C "$HR" rev-parse main)" = "$(git -C "$H" rev-parse main)" ] && grep -q 'clean (1 ref and 4 commit messages pushed)' <<< "$out" && ok "pre-push: a first push of clean commits goes through, and says what it read (the merge commit is not counted)" || bad "clean push: rc=$rc $out"
hc --no-verify -m "later fix for board#12"; S=$(hshort)
hp origin main
[ "$rc" != 0 ] && grep -qxF "commit $S: board#12 (board id)" <<< "$out" && [ "$(git -C "$HR" rev-parse main)" = "$(git -C "$H" rev-parse main~1)" ] && ok "pre-push: a bad commit not yet on the remote refuses the push; the remote keeps its old main" || bad "bad push: rc=$rc $out"
git -C "$H" reset -q --hard HEAD~1; hc -m "the fix, in plain words"; hp origin main
[ "$rc" = 0 ] && grep -q 'clean (1 ref and 1 commit message pushed)' <<< "$out" && ok "pre-push: after rewriting, only the commit the remote lacks is read" || bad "fixed push: rc=$rc $out"
hc --no-verify -m "old mistake board#13"
out=$(git -C "$H" -c core.hooksPath=/dev/null push origin main 2>&1); rc=$?; [ "$rc" = 0 ] || bad "setup: the bypassed push failed: $out"
hc -m "one more clean commit"; hp origin main
[ "$rc" = 0 ] && grep -q 'clean (1 ref and 1 commit message pushed)' <<< "$out" && ok "pre-push: a bad commit the remote already has (a bypassed push) is not read again: remote sha..local sha" || bad "remote has it: rc=$rc $out"
git -C "$H" checkout -q -b feature; hc -m "feature work"; hp origin feature
[ "$rc" = 0 ] && grep -q 'clean (1 ref and 1 commit message pushed)' <<< "$out" && ok "pre-push: a new branch is read from the commits no remote-tracking branch reaches (one, not the whole history)" || bad "new branch: rc=$rc $out"
git -C "$H" checkout -q -b feat2; hc --no-verify -m "see board#9005 for why"; S=$(hshort)
hp -u origin feat2
[ "$rc" != 0 ] && grep -qxF "commit $S: board#9005 (board id)" <<< "$out" && ! git -C "$HR" rev-parse -q --verify refs/heads/feat2 >/dev/null && ok "pre-push: a new branch with a bad commit is refused and not created on the remote" || bad "new bad branch: rc=$rc $out"
git -C "$H" checkout -q feature; git -C "$H" branch -q quill/fix; hp origin quill/fix
[ "$rc" != 0 ] && grep -qxF "branch: quill (deny list)" <<< "$out" && ok "pre-push: the branch name is read (quill/fix)" || bad "branch name: rc=$rc $out"
hp origin --delete feature
unset CLEAN_TEXT_DENY
[ "$rc" = 0 ] && ! git -C "$HR" rev-parse -q --verify refs/heads/feature >/dev/null && ok "pre-push: a branch deletion passes and deletes" || bad "delete: rc=$rc $out"
mkdir -p "$T/xdg/salamander"; printf '# machine names, one regex per line\nnode-alpha\n\n' >"$T/xdg/salamander/clean-text-deny"
git -C "$H" checkout -q main
hc -m "move the job to node-alpha"
[ "$rc" = 0 ] && ok "no variable and no file: a deny word is not refused (the rule is skipped)" || bad "deny skipped: rc=$rc $out"
hc -m "node-alpha and board#9004"
[ "$rc" != 0 ] && grep -q 'CLEAN_TEXT_DENY is not set or empty.*no deny file at' <<< "$out" && grep -qxF "message: board#9004 (board id)" <<< "$out" && ok "no variable and no file: the deny rule is skipped with the notice (naming the file), the other rules still run" || bad "no deny source: rc=$rc $out"
export XDG_CONFIG_HOME="$T/xdg"
hc -m "move the job to node-alpha"
[ "$rc" != 0 ] && grep -qxF "message: node-alpha (deny list)" <<< "$out" && ok "the deny file is read (XDG_CONFIG_HOME/salamander/clean-text-deny)" || bad "deny file: rc=$rc $out"
hc -m "machine names, one regex per line"
[ "$rc" = 0 ] && ok "the file's # comment lines are not patterns" || bad "deny comment: rc=$rc $out"
export CLEAN_TEXT_DENY="node-beta"
hc -m "move the job to node-alpha"; r1=$rc
hc -m "move the job to node-beta"
[ "$r1" = 0 ] && [ "$rc" != 0 ] && grep -qxF "message: node-beta (deny list)" <<< "$out" && ok "CLEAN_TEXT_DENY, when it holds a word, wins over the file" || bad "env over file: r1=$r1 rc=$rc $out"
unset CLEAN_TEXT_DENY XDG_CONFIG_HOME
mkdir -p "$HOME/.config/salamander"; cp "$T/xdg/salamander/clean-text-deny" "$HOME/.config/salamander/clean-text-deny"
hc -m "move the job to node-alpha"
[ "$rc" != 0 ] && grep -qxF "message: node-alpha (deny list)" <<< "$out" && ok "without XDG_CONFIG_HOME the file is ~/.config/salamander/clean-text-deny" || bad "default deny file: rc=$rc $out"
hc --no-verify -m "run it on node-alpha"; S=$(hshort)
hp origin main
[ "$rc" != 0 ] && grep -qxF "commit $S: node-alpha (deny list)" <<< "$out" && ok "pre-push reads the deny file too" || bad "push deny: rc=$rc $out"
printf 'node-alpha\n# a comment\nnode-(zq9secret\n' > "$HOME/.config/salamander/clean-text-deny"
hc -m "any plain message"
[ "$rc" != 0 ] && grep -qF "clean-text: $HOME/.config/salamander/clean-text-deny line 3 is not a valid regular expression" <<< "$out" && ! grep -q 'zq9secret' <<< "$out" && ok "an invalid regex in the deny file: the hook refuses (exit 2), naming the file and the line, not its content" || bad "invalid file regex: rc=$rc $out"
rm -rf "$HOME/.config"

echo "== --local <base>: this checkout's branch and the commits since the base"
export CLEAN_TEXT_DENY="$OWN"
git -C "$R" checkout -q -b local-demo "$c0"; cm -m "clean local work"
out=$(cd "$R" && python3 -I "$CT" --local main 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'clean (branch, title, body and 1 commit message)' <<< "$out" && ok "a clean branch: exit 0; the title and body are not scanned unless given" || bad "local clean: rc=$rc $out"
cm -m "local fix for board#9008"; S=$(short)
out=$(cd "$R" && python3 -I "$CT" --local main 2>&1); rc=$?
[ "$rc" = 1 ] && grep -qxF "commit $S: board#9008 (board id)" <<< "$out" && ok "a hit in a commit since the base" || bad "local hit: rc=$rc $out"
printf 'text\nfor Quill\n' > "$T/body.txt"
out=$(cd "$R" && python3 -I "$CT" --local main --title "about board#9002" --body-file "$T/body.txt" 2>&1); rc=$?
grep -qxF 'title: board#9002 (board id)' <<< "$out" && grep -qxF 'body line 2: Quill (deny list)' <<< "$out" && ok "--title and --body-file are scanned" || bad "local title/body: rc=$rc $out"
printf 'from stdin: stackshot.quillworks.example\n' | { out=$(cd "$R" && python3 -I "$CT" --local main --body-file - 2>&1); echo "$out" > "$T/stdin.out"; }
grep -qxF 'body: quillworks.example (deny list)' "$T/stdin.out" && ok "--body-file - reads the body from stdin" || bad "stdin: $(cat "$T/stdin.out")"
git -C "$R" checkout -q -b quill/branch "$c0"
out=$(cd "$R" && python3 -I "$CT" --local main 2>&1); rc=$?
grep -qxF 'branch: quill (deny list)' <<< "$out" && ok "--local reads the branch name from the checkout" || bad "local branch: rc=$rc $out"
git -C "$R" checkout -q --detach "$c0"
out=$(cd "$R" && python3 -I "$CT" --local main 2>&1); rc=$?
[ "$rc" = 0 ] && ok "a detached HEAD has no branch name to scan: no hit, no crash" || bad "detached: rc=$rc $out"

[ "$fail" = 0 ] && echo "cleantext: pass" || echo "cleantext: FAIL"
exit $fail
