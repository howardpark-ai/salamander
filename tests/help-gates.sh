#!/usr/bin/env bash
# tests/help-gates.sh — the three help-text gates' own tests, each on a DELIBERATE DRIFT. The gates themselves:
#   check 1  tests/help-snapshot.sh         sala's help text against the committed snapshot (a suite of its own)
#   check 2  .github/scripts/skills-flags.py (+ tests/skills-flags.sh)   the verbs and flags the skills files name exist in the help
#   check 3  .github/scripts/help-review.sh  one model call on a CLI-touching pull request (here: a fake call command, SALA_REVIEW_CALL)
# 1. a copy of bin/ and lib/ in another directory with one help line edited (top-level, then a verb's own usage): the snapshot
#    check fails with the unified diff and the one-line fix, `--update` into a throwaway snapshot makes it pass; the unedited copy
#    passes from its other path (the paths are normalised, nothing else varies); an unprobed verb is listed, not failed.
# 2. fixture help text and fixture skills: a good mention passes, a new unmentioned flag only WARNs, a stale flag and a removed verb
#    FAIL naming skill file:line, prose / pipes / quoted words are not read; with no skills directory the check SKIPs (exit 0);
#    the real regenerated help against a fixture skills directory with a stale `sala lane` flag fails.
# 3. a throwaway repo with a CLI change and a fake call command (SALA_REVIEW_CALL, no network, no uv) answering ok / not ok / garbage /
#    nothing / a failure / too slowly: ok and skipped answers exit 0, not ok exits 1 with the reason (and the ::error annotation on
#    Actions), nothing, a failing call and a timeout are tried twice (a call that fails once and answers on the retry counts), a
#    missing review-ci profile (in credentials or config) and a missing uv skip with the reason and never call the model, keys in
#    the environment are enough, no range or no CLI change never calls the model, --dry-run prints the prompt and calls nothing, the
#    call gets the profile, region, model (the Bedrock global inference profile) and HTTP timeout, needs no workspace id and never
#    sees the lane's Bedrock flag, every skip and verdict is one line in $GITHUB_STEP_SUMMARY, and no secret value reaches the output;
#    the real helper (help_review_call.py) needs no workspace id and refuses an empty prompt before any network.
# Usage: bash tests/help-gates.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
T=$(mktemp -d); export HOME=$T/home; mkdir -p "$HOME"
trap 'rm -rf "$T"' EXIT
SNAPSH="$ROOT/tests/help-snapshot.sh"; SKIPY="$ROOT/.github/scripts/skills-flags.py"; REVIEW="$ROOT/.github/scripts/help-review.sh"

echo "== check 1: the help snapshot"
C=$T/copy; mkdir -p "$C"; cp -r "$ROOT/bin" "$ROOT/lib" "$C/"
out=$(HELP_SNAPSHOT_ROOT="$C" bash "$SNAPSH" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "a copy of the tree in another directory matches the committed snapshot (paths normalised)" || bad "the copy drifted by itself: rc=$rc $(echo "$out" | head -20)"
a=$(bash "$SNAPSH" --generate); b=$(bash "$SNAPSH" --generate)
[ "$a" = "$b" ] && ok "two generations are byte for byte the same" || bad "the generation is not deterministic"
case "$a" in *"$ROOT"*|*"$T"*|*"$HOME"*) bad "the generated text holds a checkout or temporary path" ;; *) ok "no checkout path, temporary path or HOME in the text" ;; esac
grep -q '^### verbs with no help path of their own.*spawn' <<< "$a" && ok "a verb with no safe help path (spawn) is listed, not probed" || bad "the unprobed verbs are not listed"

sed -i 's/rename a live pane end to end/rename a live pane from start to end/' "$C/bin/salamander"
out=$(HELP_SNAPSHOT_ROOT="$C" bash "$SNAPSH" 2>&1); rc=$?
[ "$rc" = 1 ] && ok "a top-level help line edited: the check fails" || bad "drift not caught: rc=$rc"
grep -q '^    -.*rename a live pane end to end' <<< "$out" && grep -q '^    +.*rename a live pane from start to end' <<< "$out" && ok "the failure prints the unified diff (old and new line)" || bad "no diff in: $out"
grep -q 'bash tests/help-snapshot.sh --update' <<< "$out" && ok "and the one-line fix" || bad "no fix line"
cp "$ROOT/tests/help-snapshot.txt" "$T/snap.txt"
HELP_SNAPSHOT_ROOT="$C" HELP_SNAPSHOT_FILE="$T/snap.txt" bash "$SNAPSH" --update >/dev/null 2>&1
out=$(HELP_SNAPSHOT_ROOT="$C" HELP_SNAPSHOT_FILE="$T/snap.txt" bash "$SNAPSH" 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'from start to end' "$T/snap.txt" && ok "--update rewrites the snapshot, and the check then passes" || bad "--update did not fix it: rc=$rc"

sed -i 's/^usage="usage: salamander restore NAME… | --missing"/usage="usage: salamander restore NAME… | --missing | --all"/' "$C/lib/restore.sh"
out=$(HELP_SNAPSHOT_ROOT="$C" HELP_SNAPSHOT_FILE="$ROOT/tests/help-snapshot.txt" bash "$SNAPSH" 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q '^    +usage: salamander restore NAME… | --missing | --all' <<< "$out" && ok "a verb's own usage edited (restore): caught in its section" || bad "a verb's usage drift is not caught: rc=$rc $(echo "$out" | head -12)"
out=$(HELP_SNAPSHOT_ROOT="$T/none" bash "$SNAPSH" 2>&1); [ "$?" = 1 ] && ok "a root with no sala fails, never passes silently" || bad "a missing root passed"

echo "== check 2: the skills name only flags the help has"
cat > "$T/help.txt" <<'EOF'
### sala --help (exit 0)
usage text

  salamander foo [--alpha] [--beta]   do foo
                                     (--gamma: more)
  salamander bar NAME [--delta]       do bar

### sala foo --help (exit 0)
usage: salamander foo [--alpha] [--beta] [--epsilon]

### verbs with no help path of their own (listed, not probed; their usage is the sala --help text above): bar
EOF
S=$T/skills; mkdir -p "$S/good" "$S/stale"
cat > "$S/good/SKILL.md" <<'EOF'
---
name: good
---
Run `sala foo --alpha` first, or `~/.local/bin/sala foo --gamma` in a pinch.
Prose: sala foo --nonexistent is not read, and `sala foo --alpha | grep --nonexistent` stops at the pipe.
Quoted: `sala bar X --delta "do --nonexistent now"`.
```bash
$ sala bar NAME --delta   # a comment
FOO=1 sala foo --beta && echo --nonexistent
```
EOF
out=$(python3 -I "$SKIPY" "$T/help.txt" "$S" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "a good skill passes (inline span, path prefix, fenced block, pipe, quotes and prose left alone)" || bad "good skill failed: $out"
grep -q '^WARN sala foo: .*--epsilon' <<< "$out" && ! grep -q '^FAIL' <<< "$out" && ok "a flag in the help that no skill mentions (--epsilon) only WARNs" || bad "no WARN for the unmentioned flag: $out"
cat > "$S/stale/SKILL.md" <<'EOF'
line two
Use `sala foo --alpha --removed` to do it.
```
sala frobnicate --alpha
```
EOF
out=$(python3 -I "$SKIPY" "$T/help.txt" "$S" 2>&1); rc=$?
[ "$rc" = 1 ] && ok "a stale flag and a removed verb: the check fails" || bad "stale skill passed: rc=$rc"
grep -q '^FAIL stale/SKILL.md:2 .*--removed' <<< "$out" && ok "FAIL names the skill file and line, and the flag" || bad "no file:line for the stale flag: $out"
grep -q '^FAIL stale/SKILL.md:4 .*frobnicate' <<< "$out" && ok "FAIL names the removed verb, file and line" || bad "no verb FAIL: $out"
! grep -q 'good/SKILL.md' <<< "$(grep '^FAIL' <<< "$out")" && ok "the good file is not blamed" || bad "good file blamed"

out=$(SKILLS_DIR="$T/no-such-dir" bash "$ROOT/tests/skills-flags.sh" 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'SKIP' <<< "$out" && ok "no skills directory: SKIP with a message, exit 0" || bad "missing skills dir: rc=$rc $out"
out=$(env -u SKILLS_DIR bash "$ROOT/tests/skills-flags.sh" 2>&1); rc=$?   # HOME is the empty temporary one; no directory is looked for by itself
[ "$rc" = 0 ] && grep -q 'SKIP' <<< "$out" && ok "SKILLS_DIR unset: SKIP, exit 0 (no default location is searched)" || bad "no SKILLS_DIR: rc=$rc $out"
mkdir -p "$HOME/.claude/plugins/synced/demo/skills/x"   # a plugin copy where a default search would have looked: it must stay unread
echo '`sala lane --removed-flag`' > "$HOME/.claude/plugins/synced/demo/skills/x/SKILL.md"
out=$(env -u SKILLS_DIR bash "$ROOT/tests/skills-flags.sh" 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'SKIP' <<< "$out" && ok "a plugin copy under ~/.claude/plugins is not read unless SKILLS_DIR names it" || bad "plugin copy read: rc=$rc $out"
mkdir -p "$T/skills-new/x"
echo '`sala lane --removed-flag`' > "$T/skills-new/x/SKILL.md"
out=$(SKILLS_DIR="$T/skills-new" bash "$ROOT/tests/skills-flags.sh" 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q "skills-new" <<< "$out" && grep -q '^FAIL x/SKILL.md:1 .*--removed-flag' <<< "$out" && ok "SKILLS_DIR is read, and the real regenerated help rejects its stale flag" || bad "SKILLS_DIR: rc=$rc $out"
echo '`sala lane --list` and `sala model --effort X`' > "$T/skills-new/x/SKILL.md"
out=$(SKILLS_DIR="$T/skills-new" bash "$ROOT/tests/skills-flags.sh" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "real flags of the real help pass" || bad "real flags failed: $out"

echo "== check 3: the model review (a fake call command, no network)"
R=$T/repo; git init -q -b main "$R"; git -C "$R" config user.email t@t; git -C "$R" config user.name t
mkdir -p "$R/bin" "$R/lib" "$R/tests"
printf '#!/usr/bin/env bash\n#   salamander rename OLD NEW   rename a pane\n' > "$R/bin/salamander"
printf 'echo "renamed"\n' > "$R/lib/rename.sh"; echo snap > "$R/tests/help-snapshot.txt"; echo readme > "$R/README.md"
git -C "$R" add -A; git -C "$R" commit -q -m base; base=$(git -C "$R" rev-parse HEAD)
printf '#!/usr/bin/env bash\n#   salamander rename OLD NEW [--force]   rename a pane\n' > "$R/bin/salamander"
printf 'echo "renamed it (forced)"\n' > "$R/lib/rename.sh"
git -C "$R" commit -q -am "cli change"; cli=$(git -C "$R" rev-parse HEAD)
echo more >> "$R/README.md"; git -C "$R" commit -q -am docs; docs=$(git -C "$R" rev-parse HEAD)
# a pane or a runner may leave any of these in the environment
unset AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_USE_BEDROCK ANTHROPIC_AWS_WORKSPACE_ID ANTHROPIC_AWS_PROFILE ANTHROPIC_AWS_REGION SALA_REVIEW_CALL GITHUB_STEP_SUMMARY GITHUB_ACTIONS
export ANTHROPIC_AWS_PROFILE=review-ci   # a profile has no default: it is for a run by hand (in CI the OIDC step puts keys in the environment instead)
mkdir -p "$T/bin"; export STUB_LOG=$T/stub.log
cat > "$T/bin/fakecall" <<'EOF'
#!/usr/bin/env bash
# stands in for help_review_call.py: logs its call and the variables it is given, reads the prompt on stdin, answers by STUB_MODE
echo "call: $*" >> "$STUB_LOG"
for v in ANTHROPIC_AWS_WORKSPACE_ID ANTHROPIC_AWS_PROFILE ANTHROPIC_AWS_REGION SALA_REVIEW_MODEL SALA_REVIEW_HTTP_TIMEOUT CLAUDE_CODE_USE_BEDROCK; do
    [ -n "${!v+x}" ] && echo "env: $v=${!v}" >> "$STUB_LOG"
done
[ -n "${AWS_SESSION_TOKEN:-}" ] && echo "env: AWS_SESSION_TOKEN is set" >> "$STUB_LOG"   # presence only, never the value
cat > "$STUB_LOG.prompt"
case "${STUB_MODE:-ok}" in
    ok) echo "help_review_call: stop_reason=end_turn" >&2; echo '{"ok": true, "reason": "the help changed with the flag"}' ;;
    prose) tok=$(printf 'Ab1%.0s' {1..14}); echo "help_review_call: stop_reason=max_tokens" >&2   # made-up token-shaped strings, built here so no literal sits in the file
           printf 'Sure, the change looks fine to me. AKIA%s and %s\nare made-up values. %s ENDMARK\n' ABCDEFGHIJKLMNOP "$tok" "$(printf 'filler %.0s' {1..70})" ;;
    fenced) printf 'Here you go:\n```json\n{"ok": true, "reason": "fine"}\n```\n' ;;
    notok) echo '{"ok": false, "reason": "rename gained --force but the help and the skills still show the old shape"}' ;;
    garbage) echo 'I think the change looks fine, no JSON from me.' ;;
    nokey) echo '{"reason": "no ok field"}' ;;
    empty) : ;;
    fail) echo "help_review_call: HTTP 500: overloaded" >&2; exit 1 ;;
    flaky) n=$(grep -c '^call:' "$STUB_LOG"); if [ "$n" = 1 ]; then echo "help_review_call: HTTP 529: busy" >&2; exit 1; fi; echo '{"ok": true, "reason": "second try"}' ;;
    slow) exec sleep 20 ;;
esac
EOF
chmod +x "$T/bin/fakecall"
# the runner user's credentials file: the CI profile (and a lane's, which must not be taken for it); the values are made up
printf '[default]\naws_access_key_id=dummyvalue\naws_secret_access_key=dummysecretvalue123\n\n[example-bedrock]\naws_access_key_id=dummyvalue\naws_secret_access_key=dummysecretvalue123\n\n[review-ci]\naws_access_key_id=dummyvalue\naws_secret_access_key=dummysecretvalue123\n' > "$T/credentials"
printf '[default]\naws_access_key_id=dummyvalue\naws_secret_access_key=dummysecretvalue123\n\n[example-bedrock]\naws_access_key_id=dummyvalue\naws_secret_access_key=dummysecretvalue123\n' > "$T/credentials-noci"
review() {  # <fake mode> <args…> → output in $out, exit code in $rc, the fake's calls in $calls; the CI profile present
    local mode="$1"; shift; : > "$STUB_LOG"
    out=$(cd "$R" && STUB_MODE="$mode" SALA_REVIEW_CALL="$T/bin/fakecall" AWS_SHARED_CREDENTIALS_FILE="$T/credentials" ANTHROPIC_AWS_REGION=us-east-1 \
          SALA_REVIEW_TIMEOUT=3 PR_BODY="rename --force; skills PR 12" bash "$REVIEW" "$@" 2>&1); rc=$?
    calls=$(grep -c '^call:' "$STUB_LOG")
}
review ok "$base" "$cli"
[ "$rc" = 0 ] && [ "$calls" = 1 ] && grep -q 'help-review: ok' <<< "$out" && ok "the model says ok: exit 0, one call" || bad "ok: rc=$rc calls=$calls $out"
grep -q 'env: ANTHROPIC_AWS_PROFILE=review-ci' "$STUB_LOG" && grep -q 'env: ANTHROPIC_AWS_REGION=us-east-1' "$STUB_LOG" \
    && grep -q 'env: SALA_REVIEW_MODEL=global.anthropic.claude-haiku-5-5$' "$STUB_LOG" && grep -q 'env: SALA_REVIEW_HTTP_TIMEOUT=[0-9]' "$STUB_LOG" \
    && ok "the call gets the profile review-ci, the region us-east-1, the Bedrock Haiku 5.5 id (global.anthropic.claude-haiku-5-5) and an HTTP timeout" || bad "call env: $(cat "$STUB_LOG")"
! grep -q 'ANTHROPIC_AWS_WORKSPACE_ID' "$STUB_LOG" && ok "no workspace id is passed to the call (Bedrock needs none)" || bad "a workspace id reached the call"
! grep -q 'CLAUDE_CODE_USE_BEDROCK' "$STUB_LOG" && ok "the lane's Claude Code Bedrock flag does not reach the call (it goes to Bedrock directly, not through the bedrock lane)" || bad "a Bedrock variable reached the call"
grep -q 'salamander rename OLD NEW \[--force\]' "$STUB_LOG.prompt" && grep -q 'renamed it (forced)' "$STUB_LOG.prompt" && grep -q 'rename --force; skills PR 12' "$STUB_LOG.prompt" \
    && grep -q '(no change to the snapshot)' "$STUB_LOG.prompt" && ok "the prompt (on stdin) carries the CLI diff, the PR description and says the snapshot did not change" || bad "prompt content"
review ok --dry-run "$base" "$cli"
[ "$rc" = 0 ] && [ "$calls" = 0 ] && grep -q 'diff of bin/salamander and lib/' <<< "$out" && grep -q 'Answer with ONE JSON object' <<< "$out" && ok "--dry-run prints the prompt and calls nothing" || bad "dry run: rc=$rc calls=$calls"
review fenced "$base" "$cli"; [ "$rc" = 0 ] && grep -q 'help-review: ok' <<< "$out" && ok "an answer in a code fence is read" || bad "fenced: rc=$rc $out"

review notok "$base" "$cli"
[ "$rc" = 1 ] && grep -q 'rename gained --force but the help and the skills still show the old shape' <<< "$out" && grep -q 'help-snapshot.sh --update' <<< "$out" && ok "a verdict fail (ok=false): exit 1, the reason and the fix are printed" || bad "notok: rc=$rc $out"
! grep -q 'dummysecretvalue123\|dummyvalue' <<< "$out" && ok "no key value in the output" || bad "a secret reached the output"
out=$(cd "$R" && GITHUB_ACTIONS=true STUB_MODE=notok SALA_REVIEW_CALL="$T/bin/fakecall" AWS_SHARED_CREDENTIALS_FILE="$T/credentials" bash "$REVIEW" "$base" "$cli" 2>&1)
grep -q '^::error title=help text out of date::rename gained' <<< "$out" && ok "on Actions the failure is an ::error annotation with the reason" || bad "no annotation: $out"

review garbage "$base" "$cli"; [ "$rc" = 0 ] && [ "$calls" = 1 ] && grep -q 'SKIPPED: the answer was not the JSON' <<< "$out" && ok "an unparseable answer: skip with a warning, exit 0, no retry" || bad "garbage: rc=$rc calls=$calls $out"
review prose "$base" "$cli"
[ "$rc" = 0 ] && [ "$calls" = 1 ] && grep -q '^help-review: unparsed answer (first 400 chars, masked): Sure, the change looks fine' <<< "$out" && grep -q 'SKIPPED: the answer was not the JSON' <<< "$out" \
    && ok "a prose answer: one 'unparsed answer' line with its start, then the skip" || bad "prose: rc=$rc calls=$calls $out"
shown=$(grep '^help-review: unparsed answer' <<< "$out")
[ "$(wc -l <<< "$shown")" = 1 ] && grep -q '<masked>' <<< "$shown" && ! grep -q 'AKIA' <<< "$shown" && ! grep -q 'Ab1Ab1Ab1Ab1' <<< "$shown" \
    && ok "the shown answer is one line and a key id and a long token in it are masked" || bad "prose masking: $shown"
! grep -q 'ENDMARK' <<< "$shown" && [ "${#shown}" -le 480 ] && ok "the shown answer is cut at 400 characters" || bad "prose cut: ${#shown} chars"
grep -q '^help-review: model call: stop_reason=max_tokens$' <<< "$out" && ok "the call's stop_reason is shown after a call that answered" || bad "stop_reason: $out"
review ok "$base" "$cli"
! grep -q 'unparsed answer' <<< "$out" && grep -q '^help-review: model call: stop_reason=end_turn$' <<< "$out" && ok "a valid verdict prints no 'unparsed answer' line" || bad "ok printed unparsed: $out"
review nokey "$base" "$cli"; [ "$rc" = 0 ] && grep -q 'SKIPPED'<<< "$out" && ok "JSON without ok: skip, exit 0" || bad "nokey: rc=$rc $out"
review empty "$base" "$cli"; [ "$rc" = 0 ] && [ "$calls" = 2 ] && grep -q 'SKIPPED: the model gave no answer' <<< "$out" && ok "no answer: tried twice (one retry), then skip, exit 0" || bad "empty: rc=$rc calls=$calls $out"
review fail "$base" "$cli"; [ "$rc" = 0 ] && [ "$calls" = 2 ] && grep -q 'attempt 1: the call exited 1 (help_review_call: HTTP 500: overloaded)' <<< "$out" && grep -q 'SKIPPED: the model gave no answer' <<< "$out" && ok "a failing call: its last stderr line is shown, tried twice, then skip, exit 0" || bad "fail: rc=$rc calls=$calls $out"
review flaky "$base" "$cli"; [ "$rc" = 0 ] && [ "$calls" = 2 ] && grep -q 'attempt 1: the call exited 1' <<< "$out" && grep -q 'help-review: ok' <<< "$out" && ok "a call that fails once and answers on the retry: the retry's verdict counts (two calls)" || bad "flaky: rc=$rc calls=$calls $out"
review slow "$base" "$cli"; [ "$rc" = 0 ] && [ "$calls" = 2 ] && grep -q 'no answer within 3s' <<< "$out" && ok "a timeout: the call is stopped, retried once, then skipped" || bad "slow: rc=$rc calls=$calls $out"

review ok "$cli" "$docs"; [ "$rc" = 0 ] && [ "$calls" = 0 ] && grep -q 'nothing to review' <<< "$out" && ok "a change outside bin/ and lib/: no call" || bad "docs-only: rc=$rc calls=$calls"
review ok "$cli" "$cli"; [ "$rc" = 0 ] && [ "$calls" = 0 ] && ok "an empty diff: no call" || bad "empty diff: rc=$rc calls=$calls"
review ok nosuchcommit "$cli"; [ "$rc" = 0 ] && [ "$calls" = 0 ] && grep -q 'SKIPPED\|skipped' <<< "$out" && ok "an unresolvable range: skipped, exit 0" || bad "bad range: rc=$rc $out"

# the skips: the sign-in is not there; green, with the reason, and the model is never called
: > "$STUB_LOG"
out=$(cd "$R" && STUB_MODE=ok SALA_REVIEW_CALL="$T/bin/fakecall" AWS_SHARED_CREDENTIALS_FILE="$T/credentials" bash "$REVIEW" "$base" "$cli" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(grep -c '^call:' "$STUB_LOG")" = 1 ] && grep -q 'help-review: ok' <<< "$out" && ! grep -q 'SKIPPED' <<< "$out" && ok "no workspace id set anywhere: the review still runs (one call, no skip)" || bad "no workspace id: rc=$rc $out"
: > "$STUB_LOG"
out=$(cd "$R" && STUB_MODE=notok SALA_REVIEW_CALL="$T/bin/fakecall" AWS_SHARED_CREDENTIALS_FILE="$T/credentials-noci" bash "$REVIEW" "$base" "$cli" 2>&1); rc=$?
[ "$rc" = 0 ] && [ ! -s "$STUB_LOG" ] && grep -q 'SKIPPED: this runner has no AWS sign-in' <<< "$out" && grep -q 'profile \[review-ci\]' <<< "$out" && ok "the profile review-ci missing (another lane's profile is there): skip naming the profile, no call" || bad "no profile: rc=$rc $out"
out=$(cd "$R" && STUB_MODE=notok SALA_REVIEW_CALL="$T/bin/fakecall" AWS_SHARED_CREDENTIALS_FILE="$T/none" AWS_CONFIG_FILE="$T/none" bash "$REVIEW" "$base" "$cli" 2>&1); rc=$?
[ "$rc" = 0 ] && [ ! -s "$STUB_LOG" ] && grep -q 'SKIPPED: this runner has no AWS sign-in' <<< "$out" && ok "no credentials file at all: skip, no call" || bad "no file: rc=$rc $out"
out=$(cd "$R" && STUB_MODE=ok SALA_REVIEW_CALL="$T/bin/fakecall" AWS_SHARED_CREDENTIALS_FILE="$T/none" AWS_CONFIG_FILE="$T/none" AWS_ACCESS_KEY_ID=x AWS_SECRET_ACCESS_KEY=y bash "$REVIEW" "$base" "$cli" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(grep -c '^call:' "$STUB_LOG")" = 1 ] && grep -q 'help-review: ok' <<< "$out" && ok "keys in the runner's own environment are enough (no profile needed)" || bad "env keys: rc=$rc $out"
printf '[profile review-ci]\nregion=us-east-1\n' > "$T/config"
: > "$STUB_LOG"
out=$(cd "$R" && STUB_MODE=ok SALA_REVIEW_CALL="$T/bin/fakecall" AWS_SHARED_CREDENTIALS_FILE="$T/none" AWS_CONFIG_FILE="$T/config" bash "$REVIEW" "$base" "$cli" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(grep -c '^call:' "$STUB_LOG")" = 1 ] && ok "the profile in ~/.aws/config alone is found too" || bad "config profile: rc=$rc $out"
out=$(cd "$R" && STUB_MODE=ok SALA_REVIEW_CALL="$T/bin/fakecall" ANTHROPIC_AWS_PROFILE=other AWS_SHARED_CREDENTIALS_FILE="$T/credentials" bash "$REVIEW" "$base" "$cli" 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'profile \[other\]' <<< "$out" && ok "ANTHROPIC_AWS_PROFILE names another profile: that one is looked for" || bad "other profile: rc=$rc $out"
: > "$STUB_LOG"
out=$(cd "$R" && env -u ANTHROPIC_AWS_PROFILE STUB_MODE=ok SALA_REVIEW_CALL="$T/bin/fakecall" AWS_SHARED_CREDENTIALS_FILE="$T/credentials" bash "$REVIEW" "$base" "$cli" 2>&1); rc=$?
[ "$rc" = 0 ] && [ ! -s "$STUB_LOG" ] && grep -q 'SKIPPED: no AWS sign-in: AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY are not in the environment' <<< "$out" && grep -q 'repository secret SALA_REVIEW_AWS_ROLE' <<< "$out" && ok "no keys and no profile named (it has no default): skip saying there is no AWS sign-in and naming the repository secret SALA_REVIEW_AWS_ROLE, no call" || bad "profile unset: rc=$rc $out"
out=$(cd "$R" && env -u ANTHROPIC_AWS_PROFILE STUB_MODE=ok SALA_REVIEW_CALL="$T/bin/fakecall" AWS_SHARED_CREDENTIALS_FILE="$T/none" AWS_CONFIG_FILE="$T/none" AWS_ACCESS_KEY_ID=x AWS_SECRET_ACCESS_KEY=y bash "$REVIEW" "$base" "$cli" 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'help-review: ok' <<< "$out" && ok "no profile named but keys in the environment: the review still runs" || bad "unset profile, env keys: rc=$rc $out"
: > "$STUB_LOG"
out=$(cd "$R" && env -u ANTHROPIC_AWS_PROFILE STUB_MODE=ok SALA_REVIEW_CALL="$T/bin/fakecall" AWS_SHARED_CREDENTIALS_FILE="$T/none" AWS_CONFIG_FILE="$T/none" AWS_ACCESS_KEY_ID=x AWS_SECRET_ACCESS_KEY=y AWS_SESSION_TOKEN=z AWS_REGION=us-east-1 bash "$REVIEW" "$base" "$cli" 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'help-review: ok' <<< "$out" && grep -q 'env: AWS_SESSION_TOKEN is set' "$STUB_LOG" && grep -q 'env: ANTHROPIC_AWS_REGION=us-east-1' "$STUB_LOG" && ok "the OIDC step's variables (keys, session token, AWS_REGION): the review runs, the call keeps the session token and gets the region" || bad "oidc env: rc=$rc $out $(cat "$STUB_LOG")"
mkdir -p "$T/nouv"; for t in bash env awk sed cut tail cat head wc grep git python3 mktemp rm timeout dirname date; do p=$(command -v "$t") && ln -sf "$p" "$T/nouv/$t"; done
out=$(cd "$R" && PATH="$T/nouv" AWS_SHARED_CREDENTIALS_FILE="$T/credentials" "$T/nouv/bash" "$REVIEW" "$base" "$cli" 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q "SKIPPED: uv is not on this runner's PATH" <<< "$out" && ok "the default call without uv on the PATH: skip naming uv" || bad "no uv: rc=$rc $out"

# the job summary: a line for a skip and for each verdict, nothing written when GITHUB_STEP_SUMMARY is unset
S=$T/summary.md; : > "$S"
out=$(cd "$R" && GITHUB_STEP_SUMMARY="$S" SALA_REVIEW_CALL="$T/bin/fakecall" AWS_SHARED_CREDENTIALS_FILE="$T/credentials-noci" bash "$REVIEW" "$base" "$cli" 2>&1)
[ "$(wc -l < "$S")" = 1 ] && grep -q '^- \*\*help-review: skipped\*\* — this runner has no AWS sign-in for Amazon Bedrock' "$S" && ok "a skip writes one line to the job summary" || bad "summary on skip: $(cat "$S")"
: > "$S"
out=$(cd "$R" && GITHUB_STEP_SUMMARY="$S" STUB_MODE=ok SALA_REVIEW_CALL="$T/bin/fakecall" AWS_SHARED_CREDENTIALS_FILE="$T/credentials" bash "$REVIEW" "$base" "$cli" 2>&1)
[ "$(wc -l < "$S")" = 1 ] && grep -q '^- \*\*help-review: pass\*\* (global.anthropic.claude-haiku-5-5) — the help changed with the flag' "$S" && ok "a pass writes one line: pass, the model, the finding" || bad "summary on pass: $(cat "$S")"
: > "$S"
out=$(cd "$R" && GITHUB_STEP_SUMMARY="$S" STUB_MODE=notok SALA_REVIEW_CALL="$T/bin/fakecall" AWS_SHARED_CREDENTIALS_FILE="$T/credentials" bash "$REVIEW" "$base" "$cli" 2>&1)
[ "$(wc -l < "$S")" = 1 ] && grep -q '^- \*\*help-review: FAIL\*\* (global.anthropic.claude-haiku-5-5) — rename gained --force' "$S" && ok "a fail writes one line: FAIL, the model, the reason" || bad "summary on fail: $(cat "$S")"
: > "$S"
out=$(cd "$R" && GITHUB_STEP_SUMMARY="$S" STUB_MODE=empty SALA_REVIEW_CALL="$T/bin/fakecall" AWS_SHARED_CREDENTIALS_FILE="$T/credentials" SALA_REVIEW_TIMEOUT=3 bash "$REVIEW" "$base" "$cli" 2>&1)
grep -q '^- \*\*help-review: skipped\*\* — the model gave no answer after two tries' "$S" && ok "a skip after a failed call is on the summary too" || bad "summary on empty: $(cat "$S")"
: > "$S"
out=$(cd "$R" && GITHUB_STEP_SUMMARY="$S" STUB_MODE=ok SALA_REVIEW_CALL="$T/bin/fakecall" AWS_SHARED_CREDENTIALS_FILE="$T/credentials" bash "$REVIEW" "$cli" "$docs" 2>&1)
grep -q 'nothing to review' "$S" && ok "a change with nothing to review is on the summary as well" || bad "summary on no-op: $(cat "$S")"
! grep -rq 'dummysecretvalue123\|dummyvalue' "$S" && ok "no key value in the summary" || bad "a secret reached the summary"
review ok "$base" "$cli"; [ "$rc" = 0 ] && ok "no GITHUB_STEP_SUMMARY: nothing is written, nothing breaks" || bad "no summary var: rc=$rc"
out=$(cd "$R" && SALA_REVIEW_CALL="$T/bin/fakecall" STUB_MODE=ok AWS_SHARED_CREDENTIALS_FILE="$T/credentials" SALA_REVIEW_MODEL=claude-test-model bash "$REVIEW" "$base" "$cli" 2>&1)
grep -q 'env: SALA_REVIEW_MODEL=claude-test-model' "$STUB_LOG" && ok "SALA_REVIEW_MODEL picks the model id" || bad "model override: $(cat "$STUB_LOG")"

# the real helper, up to the point where it would use the network (stdlib only: it stops before importing botocore)
H="$ROOT/.github/scripts/help_review_call.py"
out=$(printf '  \n' | ANTHROPIC_AWS_REGION=us-east-1 python3 -B -I "$H" 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'the prompt is empty' <<< "$out" && ok "the helper refuses an empty prompt (and asks for no workspace id)" || bad "helper empty prompt: rc=$rc $out"

# the real diff cap: a CLI diff over the cap is cut with a marker
python3 -c 'print("\n".join("echo line %d" % i for i in range(9000)))' > "$R/lib/big.sh"; git -C "$R" add -A; git -C "$R" commit -q -m big
out=$(cd "$R" && SALA_REVIEW_DIFF_MAX=2000 bash "$REVIEW" --dry-run "$docs" HEAD 2>&1)
grep -q 'cut at 2000 bytes' <<< "$out" && [ "${#out}" -lt 12000 ] && ok "a large diff is cut at the cap, with a marker" || bad "no cap: ${#out} bytes"

[ "$fail" = 0 ] && echo "help-gates: pass" || echo "help-gates: FAIL"
exit $fail
