#!/usr/bin/env bash
# `salamander codex-review <owner/repo> <pr>` (lib/codex-review.sh, lib/codex-review.py, docs/codex-review.md), run through the real verb against a
# stub `codex`, a stub `gh` and a stub public scan on PATH, each logging every call and steered by files in $FAKE_DIR. No network, no real Codex, no
# sign-in. Kept because this verb posts text on public repos and runs beside every release: a wrong answer here is a public comment with something private
# in it, a second post for one commit, or a release that waits on it. Checks: the wrong calls (no arguments, a bad pr, three arguments: exit 2 and the shape
# of the call on stderr; --help: exit 0); a repo outside the two the trial covers and SALA_CODEX_REVIEW=off (exit 0, nothing called, one log line); not
# signed in (no gh call, no comment, the log says "not logged in"); a good answer (one comment headed with the seven-character sha, the exact codex
# command line, CODEX_HOME from SALA_CODEX_HOME and no API key variable in codex's environment, the prompt and the diff on stdin, an EMPTY working root) and
# a second run for the same sha posting nothing, a new sha reviewed again; two runs at once for one PR (one codex run, one comment); a codex exit status, a
# timeout (the stub's child gone), a limit message, a refusal, an empty answer: exit 0, no comment, and the next good run still posts; a long real review that
# mentions the usage limit is posted; an over-size diff skipped without a codex run; a gh failure; a comment that fails to post leaves no marker; the
# privacy check on a public repo (PASS posts; a hit, a scan that exits 1 with a PASS line, a scan that cannot run, no scan command, a scan that times out and
# an unreadable visibility each post only the withheld note, keep the text in the state folder with mode 600, and a re-run posts nothing more; a private
# repo is posted without it); a body cut to 60000 characters; a state folder that cannot be written still exits 0. TMPDIR is the suite's own folder and is
# asserted empty at the end. Not checked: the real codex, gh and public scan, GitHub.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/sala-codex-review.XXXXXX")
exec 8< "$T"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME/bin" "$T/tmp"; export PATH="$HOME/bin:$PATH"
export TMPDIR="$T/tmp"   # what the verb's scratch folders go under: empty again at the end
unset SALA_CONFIG SALA_LOG_DIR XDG_CONFIG_HOME SALA_CODEX_REVIEW SALA_CODEX_BIN SALA_CODEX_HOME SALA_CODEX_MAX_DIFF SALA_CODEX_TIMEOUT SALA_CODEX_PUBLIC_SCAN SALA_CODEX_SCAN_TIMEOUT
export XDG_STATE_HOME="$T/state" FAKE_DIR="$T/fake"; mkdir -p "$FAKE_DIR"
STATE="$XDG_STATE_HOME/salamander/codex-review"
export SALA_CODEX_BIN="$HOME/bin/codex" SALA_CODEX_HOME="$T/codexhome"
export OPENAI_API_KEY=dummy-not-a-key CODEX_API_KEY=dummy-not-a-key   # must never reach codex

cat > "$HOME/bin/codex" <<'FAKE'
#!/bin/bash
echo "codex $*" >> "$FAKE_DIR/calls"
case "$1" in
    login) echo "CODEX_HOME=${CODEX_HOME:-}" >> "$FAKE_DIR/login-env"
           if [ -e "$FAKE_DIR/loggedout" ]; then echo "Not logged in"; exit 1; fi
           echo "Logged in using ChatGPT"; exit 0 ;;
    exec)  echo "CODEX_HOME=${CODEX_HOME:-} OPENAI_API_KEY=${OPENAI_API_KEY-unset} CODEX_API_KEY=${CODEX_API_KEY-unset} PWD=$PWD" > "$FAKE_DIR/exec-env"
           ls -A "$PWD" > "$FAKE_DIR/exec-cwd-listing"
           cat > "$FAKE_DIR/stdin"
           out=; while [ $# -gt 0 ]; do [ "$1" = --output-last-message ] && out="$2"; shift; done
           case "$(cat "$FAKE_DIR/mode" 2>/dev/null || echo good)" in
               good)    printf -- '- lib/x.sh:12: a possible bug\n- tests: none for the new branch\n' > "$out" ;;
               slow)    sleep 1; printf -- '- lib/x.sh:12: a possible bug\n' > "$out" ;;
               nofind)  echo "No findings." > "$out" ;;
               exit3)   echo "boom: something broke" >&2; exit 3 ;;
               sleep)   sleep 8 & echo $! > "$FAKE_DIR/sleeppid"; wait ;;   # a child that only the process-group kill reaches
               limit)   echo "You've hit your usage limit. Try again later." > "$out" ;;
               refusal) echo "I'm sorry, but I can't help with that." > "$out" ;;
               empty)   : > "$out" ;;
               long)    { echo "- src/limits.py:10: the check never resets the usage limit counter."; head -c 1300 /dev/zero | tr '\0' 'x'; echo; } > "$out" ;;
               huge)    head -c 70000 /dev/zero | tr '\0' 'y' > "$out" ;;
           esac ;;
esac
FAKE
cat > "$HOME/bin/gh" <<'FAKE'
#!/bin/bash
echo "gh $*" >> "$FAKE_DIR/calls"
case "$1 $2" in
    "pr view")    [ -e "$FAKE_DIR/viewfail" ] && { echo "gh: no such PR" >&2; exit 1; }
                  printf '{"headRefOid":"%s","title":"Fix the thing"}\n' "$(cat "$FAKE_DIR/sha")" ;;
    "pr diff")    cat "$FAKE_DIR/diff" ;;
    "repo view")  [ -e "$FAKE_DIR/visfail" ] && { echo "gh: HTTP 502" >&2; exit 1; }; cat "$FAKE_DIR/visibility" ;;
    "pr comment") [ -e "$FAKE_DIR/commentfail" ] && { echo "gh: HTTP 502" >&2; exit 1; }
                  f=; while [ $# -gt 0 ]; do [ "$1" = --body-file ] && f="$2"; shift; done
                  n=$(( $(cat "$FAKE_DIR/comment.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_DIR/comment.count"
                  cp "$f" "$FAKE_DIR/comment.$n" ;;
    *) echo "unexpected: $*" >> "$FAKE_DIR/bad"; exit 1 ;;
esac
FAKE
cat > "$HOME/bin/public-scan" <<'FAKE'
#!/bin/bash
echo "public-scan $*" >> "$FAKE_DIR/calls"
d="$2"; cp "$d/review.md" "$FAKE_DIR/scanned"
git -C "$d" log --oneline 2>/dev/null | wc -l > "$FAKE_DIR/scanned-commits"   # the text sits in a git repo of one commit
case "$(cat "$FAKE_DIR/scan" 2>/dev/null || echo pass)" in
    pass)    echo "public-scan: PASS scope: refs=1 blobs=1"; exit 0 ;;
    hit)     echo "public-scan: FAIL 1 hit"; exit 1 ;;
    passexit1) echo "public-scan: PASS scope: refs=1"; exit 1 ;;
    sleep)   sleep 8 ;;
esac
FAKE
chmod +x "$HOME/bin/codex" "$HOME/bin/gh" "$HOME/bin/public-scan"

SHA=0123456789abcdef0123456789abcdef01234567
SHA2=fedcba9876543210fedcba9876543210fedcba98
REPO=howardpark-ai/salamander
LOG="$STATE/howardpark-ai__salamander-pr-5.log"
HEAD7="Codex review (trial, read-only, a second opinion and not a gate) of 0123456"
reset() {
    rm -rf "$FAKE_DIR"/* "$XDG_STATE_HOME"; : > "$FAKE_DIR/calls"
    echo "$SHA" > "$FAKE_DIR/sha"; printf 'diff --git a/x b/x\n+hello\n' > "$FAKE_DIR/diff"; echo PUBLIC > "$FAKE_DIR/visibility"
    echo pass > "$FAKE_DIR/scan"; echo good > "$FAKE_DIR/mode"
    export SALA_CODEX_PUBLIC_SCAN="$HOME/bin/public-scan"; unset SALA_CODEX_MAX_DIFF SALA_CODEX_TIMEOUT SALA_CODEX_SCAN_TIMEOUT SALA_CODEX_REVIEW
}
cr() { out=$(bash "$ROOT/bin/salamander" codex-review "$@" 2>"$T/err"); rc=$?; }
calls() { cat "$FAKE_DIR/calls"; }
called() { calls | grep -q -- "$1"; }
ncalls() { calls | grep -c -- "$1" || true; }
ncomments() { cat "$FAKE_DIR/comment.count" 2>/dev/null || echo 0; }
logtext() { cat "$LOG" 2>/dev/null; }
quiet() { [ ! -e "$FAKE_DIR/bad" ]; }

echo "== a wrong call: the shape, exit 2; --help: exit 0"
reset
cr; [ "$rc" = 2 ] && [ -z "$out" ] && grep -q "usage: salamander codex-review <owner/repo> <pr>" "$T/err" && ok "no arguments: exit 2, the usage on stderr, nothing on stdout" || bad "no args: rc=$rc out=$out err=$(cat "$T/err")"
cr "$REPO" abc; [ "$rc" = 2 ] && grep -q "<owner/repo> <pr>" "$T/err" && ok "a pr that is not a number: exit 2" || bad "abc: rc=$rc"
cr "$REPO" 5 6; [ "$rc" = 2 ] && ok "three arguments: exit 2" || bad "three: rc=$rc"
cr notarepo 5; [ "$rc" = 2 ] && ok "a repo that is not owner/name: exit 2" || bad "notarepo: rc=$rc"
cr --help; [ "$rc" = 0 ] && [[ "$out" == *"usage: salamander codex-review <owner/repo> <pr>"* ]] && ok "--help: exit 0 and the usage" || bad "--help: rc=$rc"
[ "$(calls | wc -l)" = 0 ] && ok "no wrong call started a tool" || bad "calls: $(calls)"

echo "== a repo outside the trial, and SALA_CODEX_REVIEW=off"
reset
cr other/repo 5
[ "$rc" = 0 ] && [ "$(calls | wc -l)" = 0 ] && grep -q "not one of the repos" "$STATE/other__repo-pr-5.log" && ok "another repo: exit 0, nothing called, one log line, one short line on stdout" || bad "other repo: rc=$rc out=$out calls=$(calls)"
[ "$(printf '%s\n' "$out" | wc -l)" = 1 ] && ok "a single line is printed" || bad "stdout: $out"
reset; export SALA_CODEX_REVIEW=off
cr "$REPO" 5
[ "$rc" = 0 ] && [ "$(calls | wc -l)" = 0 ] && logtext | grep -q "SALA_CODEX_REVIEW=off" && ok "SALA_CODEX_REVIEW=off: exit 0, nothing called, the log says so" || bad "off: rc=$rc calls=$(calls) log=$(logtext)"
unset SALA_CODEX_REVIEW

echo "== not signed in"
reset; touch "$FAKE_DIR/loggedout"
cr "$REPO" 5
[ "$rc" = 0 ] && [ "$(ncomments)" = 0 ] && ! called "^gh " && ! called "codex exec" && logtext | grep -q " not logged in" && [ ! -d "$STATE/done" ] && ok "not logged in: exit 0, no gh call, no review run, no comment, no marker, the log says 'not logged in'" || bad "logged out: rc=$rc calls=$(calls) log=$(logtext)"

echo "== a good answer: one comment; the same sha again: nothing; a new sha: reviewed again"
reset
cr "$REPO" 5
[ "$rc" = 0 ] && [ "$(ncomments)" = 1 ] && quiet && ok "a good answer: exit 0, one comment" || bad "good: rc=$rc calls=$(calls) bad=$(cat "$FAKE_DIR/bad" 2>/dev/null) log=$(logtext)"
called "gh pr comment 5 --repo $REPO --body-file" && head -1 "$FAKE_DIR/comment.1" | grep -qF "$HEAD7" && grep -q "lib/x.sh:12: a possible bug" "$FAKE_DIR/comment.1" \
    && ok "the comment is headed 'Codex review (trial, read-only, a second opinion and not a gate) of <sha7>' and carries the answer" || bad "comment: $(cat "$FAKE_DIR/comment.1" 2>/dev/null)"
called "^codex exec --sandbox read-only --skip-git-repo-check -C $T/tmp/sala-codex-review\.[^ ]*/work --output-last-message $T/tmp/sala-codex-review\.[^ ]*/last-message.txt -$" \
    && ok "codex runs read-only, outside a git repo check, in a work folder of its own, the answer to a file, the prompt on stdin" || bad "exec line: $(calls | grep 'codex exec')"
[ "$(cat "$FAKE_DIR/exec-cwd-listing")" = "" ] && ok "codex's working root is EMPTY: it sees the diff and nothing else" || bad "cwd listing: $(cat "$FAKE_DIR/exec-cwd-listing")"
grep -q "^CODEX_HOME=$T/codexhome OPENAI_API_KEY=unset CODEX_API_KEY=unset " "$FAKE_DIR/exec-env" && grep -q "^CODEX_HOME=$T/codexhome$" "$FAKE_DIR/login-env" \
    && ok "CODEX_HOME is SALA_CODEX_HOME for the login check and the run, and no API key variable reaches codex" || bad "env: $(cat "$FAKE_DIR/exec-env" "$FAKE_DIR/login-env")"
grep -q "Review it for correctness bugs, risky changes, and missing tests or docs" "$FAKE_DIR/stdin" && grep -q "at most 40 lines\|at most 40 lines in all\|Write at most 40 lines" "$FAKE_DIR/stdin" && grep -q "No findings." "$FAKE_DIR/stdin" && grep -q "^+hello$" "$FAKE_DIR/stdin" \
    && ok "stdin holds the prompt and then the diff" || bad "stdin: $(head -c 600 "$FAKE_DIR/stdin")"
[ "$(cat "$FAKE_DIR/scanned-commits")" -ge 1 ] && head -1 "$FAKE_DIR/scanned" | grep -qF "$HEAD7" && ok "the text was checked by the public scan first, in a git repo that held only the text" || bad "scan: $(calls | grep public-scan)"
[ "$(printf '%s\n' "$out" | wc -l)" = 1 ] && ok "one short line on stdout" || bad "stdout: $out"
cr "$REPO" 5
[ "$rc" = 0 ] && [ "$(ncomments)" = 1 ] && [ "$(ncalls '^codex exec')" = 1 ] && logtext | grep -q "already reviewed 0123456" && ok "a second run for the same head sha: no second codex run, no second comment" || bad "again: comments=$(ncomments) execs=$(ncalls '^codex exec') log=$(logtext)"
echo "$SHA2" > "$FAKE_DIR/sha"
cr "$REPO" 5
[ "$rc" = 0 ] && [ "$(ncomments)" = 2 ] && head -1 "$FAKE_DIR/comment.2" | grep -q "of fedcba9\$" && ok "a new head sha is reviewed again" || bad "new sha: comments=$(ncomments) $(head -1 "$FAKE_DIR/comment.2" 2>/dev/null)"
ls "$STATE"/*.lock >/dev/null 2>&1 && [ "$(stat -c %a "$STATE")" = 700 ] && ok "the state folder is private (700) and holds the PR's lock file" || bad "state: $(ls -la "$STATE")"

echo "== two runs at once for one PR: one review, one comment"
reset; echo slow > "$FAKE_DIR/mode"
bash "$ROOT/bin/salamander" codex-review "$REPO" 5 > "$T/o1" 2>&1 &
p1=$!
bash "$ROOT/bin/salamander" codex-review "$REPO" 5 > "$T/o2" 2>&1 &
p2=$!
wait "$p1" "$p2"
[ "$(ncomments)" = 1 ] && [ "$(ncalls '^codex exec')" = 1 ] && ok "under the PR's flock the second run waited and found the marker: one codex run, one comment" || bad "concurrent: comments=$(ncomments) execs=$(ncalls '^codex exec') log=$(logtext)"

echo "== a failed or useless answer posts nothing, and the next good run still posts"
for m in exit3 sleep limit refusal empty; do
    reset; echo "$m" > "$FAKE_DIR/mode"; [ "$m" = sleep ] && export SALA_CODEX_TIMEOUT=1
    cr "$REPO" 5
    if [ "$rc" = 0 ] && [ "$(ncomments)" = 0 ] && [ ! -d "$STATE/done" ]; then ok "$m: exit 0, no comment, no marker"; else bad "$m: rc=$rc comments=$(ncomments) log=$(logtext)"; fi
    case "$m" in
        exit3) logtext | grep -q "codex exited 3: nothing posted (boom: something broke)" && ok "exit3: the log names the exit status and the error's tail" || bad "exit3 log: $(logtext)" ;;
        sleep) logtext | grep -q "codex timed out after 1 s" && ok "timeout: the log says so" || bad "timeout log: $(logtext)"
               pid=$(cat "$FAKE_DIR/sleeppid" 2>/dev/null)
               [ -n "$pid" ] && waitfor '! kill -0 '"$pid"' 2>/dev/null' 40 && ok "timeout: the stub's child process was ended with its group" || bad "timeout: child $pid still alive" ;;
        limit|refusal) logtext | grep -q "refusal or a limit message" && ok "$m: the log says it was no review" || bad "$m log: $(logtext)" ;;
        empty) logtext | grep -q "empty answer" && ok "empty: the log says so" || bad "empty log: $(logtext)" ;;
    esac
    unset SALA_CODEX_TIMEOUT
    echo good > "$FAKE_DIR/mode"; cr "$REPO" 5
    [ "$(ncomments)" = 1 ] && ok "$m: the next run (codex fine again) posts the review" || bad "$m retry: comments=$(ncomments)"
done
reset; echo long > "$FAKE_DIR/mode"; cr "$REPO" 5
[ "$(ncomments)" = 1 ] && grep -q "usage limit counter" "$FAKE_DIR/comment.1" && ok "a long real review that mentions the usage limit is posted, not mistaken for a limit message" || bad "long: comments=$(ncomments) log=$(logtext)"
reset; echo nofind > "$FAKE_DIR/mode"; cr "$REPO" 5
[ "$(ncomments)" = 1 ] && grep -q "^No findings\.$" "$FAKE_DIR/comment.1" && ok "'No findings.' is posted as the review" || bad "nofind: comments=$(ncomments)"

echo "== an over-size diff, a gh failure, a comment that fails to post"
reset; export SALA_CODEX_MAX_DIFF=10
cr "$REPO" 5
[ "$rc" = 0 ] && [ "$(ncomments)" = 0 ] && ! called "codex exec" && logtext | grep -q "over SALA_CODEX_MAX_DIFF=10: skipped" && ok "a diff over SALA_CODEX_MAX_DIFF: skipped, no codex run, no comment, the log says so" || bad "oversize: rc=$rc calls=$(calls) log=$(logtext)"
unset SALA_CODEX_MAX_DIFF
reset; touch "$FAKE_DIR/viewfail"; cr "$REPO" 5
[ "$rc" = 0 ] && [ "$(ncomments)" = 0 ] && ! called "codex exec" && logtext | grep -q "gh pr view failed" && ok "gh cannot read the PR: exit 0, nothing posted, the log says so" || bad "viewfail: rc=$rc log=$(logtext)"
reset; touch "$FAKE_DIR/commentfail"; cr "$REPO" 5
[ "$rc" = 0 ] && [ ! -d "$STATE/done" ] && logtext | grep -q "gh pr comment failed" && ok "a comment that fails to post: exit 0, no marker" || bad "commentfail: rc=$rc log=$(logtext)"
rm -f "$FAKE_DIR/commentfail"; cr "$REPO" 5
[ "$(ncomments)" = 1 ] && ok "and the next run posts it" || bad "after commentfail: comments=$(ncomments)"

echo "== the privacy check on a public repo"
check_withheld() {  # <label>: only the withheld note was posted, the text kept at mode 600, a re-run posts nothing more
    local kept
    kept=$(ls "$STATE"/*.withheld.md 2>/dev/null | head -1)
    if [ "$(ncomments)" = 1 ] && grep -qF "Codex review withheld: the text needed a privacy check it did not pass" "$FAKE_DIR/comment.1" && ! grep -q "possible bug" "$FAKE_DIR/comment.1" \
       && head -1 "$FAKE_DIR/comment.1" | grep -qF "$HEAD7" && [ -n "$kept" ] && grep -q "possible bug" "$kept" && [ "$(stat -c %a "$kept")" = 600 ]; then
        ok "$1: the withheld note posted instead of the text, which is kept in the state folder (mode 600)"
    else bad "$1: comments=$(ncomments) comment=$(cat "$FAKE_DIR/comment.1" 2>/dev/null) kept=$kept log=$(logtext)"; fi
    cr "$REPO" 5
    [ "$(ncomments)" = 1 ] && ok "$1: a re-run posts nothing more" || bad "$1: re-run comments=$(ncomments)"
}
reset; echo hit > "$FAKE_DIR/scan"; cr "$REPO" 5; [ "$rc" = 0 ] && check_withheld "a hit" || bad "hit: rc=$rc"
logtext | grep -q "privacy check did not pass" && ok "a hit: the log says the check did not pass" || bad "hit log: $(logtext)"
reset; echo passexit1 > "$FAKE_DIR/scan"; cr "$REPO" 5; check_withheld "a PASS line with exit 1"
reset; export SALA_CODEX_PUBLIC_SCAN="$T/no-such-scan"; cr "$REPO" 5; check_withheld "a scan command that cannot run"
logtext | grep -q "privacy check did not pass" && ok "cannot run: the log says so" || bad "cannot-run log: $(logtext)"
reset; unset SALA_CODEX_PUBLIC_SCAN; cr "$REPO" 5; check_withheld "no scan command set"
logtext | grep -q "SALA_CODEX_PUBLIC_SCAN is not set" && ok "no command: the log names the setting" || bad "unset log: $(logtext)"
reset; echo sleep > "$FAKE_DIR/scan"; export SALA_CODEX_SCAN_TIMEOUT=1; cr "$REPO" 5; check_withheld "a scan that times out"
reset; touch "$FAKE_DIR/visfail"; cr "$REPO" 5
[ "$(ncomments)" = 1 ] && called "public-scan scan" && grep -q "possible bug" "$FAKE_DIR/comment.1" && logtext | grep -q "unreadable (treated as public)" && ok "visibility that cannot be read is treated as public: the scan ran, and its PASS posted the text" || bad "visfail: comments=$(ncomments) log=$(logtext)"
reset; touch "$FAKE_DIR/visfail"; echo hit > "$FAKE_DIR/scan"; cr "$REPO" 5; check_withheld "an unreadable visibility with a hit"
reset; echo PRIVATE > "$FAKE_DIR/visibility"; echo hit > "$FAKE_DIR/scan"; cr "$REPO" 5
[ "$(ncomments)" = 1 ] && ! called "public-scan scan" && grep -q "possible bug" "$FAKE_DIR/comment.1" && ok "a private repo is posted without the check" || bad "private: comments=$(ncomments) calls=$(calls)"
reset; cr howardpark-ai/stackshot 7
[ "$(ncomments)" = 1 ] && called "gh pr comment 7 --repo howardpark-ai/stackshot" && called "public-scan scan" && ok "the second repo of the trial is reviewed and checked the same way" || bad "stackshot repo: comments=$(ncomments) calls=$(calls)"

echo "== a body over 60000 characters is cut"
reset; echo huge > "$FAKE_DIR/mode"; cr "$REPO" 5
n=$(wc -c < "$FAKE_DIR/comment.1" 2>/dev/null || echo 0)
[ "$(ncomments)" = 1 ] && [ "$n" -le 60001 ] && [ "$n" -gt 59000 ] && grep -q "\[cut: the review was longer\]" "$FAKE_DIR/comment.1" && ok "a 70000-character answer is posted cut to 60000 characters with a marker" || bad "huge: comments=$(ncomments) bytes=$n"

echo "== a state folder that cannot be written still exits 0"
reset; : > "$T/afile"
out=$(XDG_STATE_HOME="$T/afile" bash "$ROOT/bin/salamander" codex-review "$REPO" 5 2>"$T/err"); rc=$?
[ "$rc" = 0 ] && [ "$(ncomments)" = 0 ] && ok "no state folder: exit 0, one line, no comment, no tool called" || bad "unwritable: rc=$rc out=$out calls=$(calls)"

echo "== nothing is left in the scratch folder"
leftover=$(ls -A "$TMPDIR" 2>/dev/null)
[ -z "$leftover" ] && ok "TMPDIR is empty after every run, the timeout and the stops included" || bad "left behind in TMPDIR: $leftover"

[ "$fail" = 0 ]
