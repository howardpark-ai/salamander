#!/usr/bin/env bash
# help-review.sh — check 3 of the help-text gates: one small-model call reads
# a pull request's change to the CLI together with the help-snapshot diff and the skills text, and answers JSON
# {"ok": bool, "reason": str}. It FAILS (exit 1, with the reason) when the diff changes a command's shape, words or output
# but neither the help text nor the skills were changed to match. Checks 1 and 2 (tests/help-snapshot.sh, tests/skills-flags.sh)
# are the tokenless part; this is the part only a reader can do: did the help NEED to change.
#
# Usage: help-review.sh [--dry-run] [<from> <to>]
#   <from> <to>   two commits of the checkout: the base and the change (default: on a pull request's merge commit HEAD^1..HEAD,
#                 else origin/main..HEAD)
#   --dry-run     print the prompt that would be sent and exit 0 (no credential needed, nothing called)
# Env:  SALA_REVIEW_MODEL   the model id (default global.anthropic.claude-haiku-5-5, Haiku 5.5 through the global inference profile on Amazon Bedrock)
#       SALA_REVIEW_TIMEOUT seconds one call may take (default 120); a failed or empty call is retried once, no more
#       SALA_REVIEW_DIFF_MAX bytes of the CLI diff sent (default 60000; the snapshot diff and the skills text have their own, smaller caps)
#       PR_BODY             the pull request's description (the workflow passes it), where the skills change is named
#       SKILLS_DIR          the skills plugin's skills directory (no default location is searched); none: the prompt says so
#       ANTHROPIC_AWS_PROFILE       an AWS profile to sign in with when no keys are in the environment (no default; for a run by hand: the workflow does not set it)
#       ANTHROPIC_AWS_REGION        the region (no default: else AWS_REGION or AWS_DEFAULT_REGION; none of them set, the call fails saying so and the review is skipped)
#       SALA_REVIEW_CALL    the command that makes the call (default: uv run --locked --script help_review_call.py beside this file); it reads the
#                           prompt on stdin, prints the model's reply, exits non-zero on failure. The tests put a stub here.
# Credential: an AWS sign-in on Amazon Bedrock, not a lane. In CI the workflow's sign-in step exchanges GitHub's OIDC token for the credentials of
# the IAM role named by the repository secret SALA_REVIEW_AWS_ROLE and leaves AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN and AWS_REGION in
# the environment (the role's policy allows Bedrock invoke of the review model only). By hand: those variables, or the profile named by
# ANTHROPIC_AWS_PROFILE (a [header] in ~/.aws/credentials or ~/.aws/config, AWS_SHARED_CREDENTIALS_FILE honoured). The call itself is
# .github/scripts/help_review_call.py: a POST to https://bedrock-runtime.<region>.amazonaws.com/model/<model id>/invoke signed with botocore
# SigV4 (service bedrock), the Anthropic Messages body with anthropic_version bedrock-2023-05-31; no `claude` CLI and no workspace id.
# Only the credential's presence is tested, no value is read into the log or printed. Anything missing (keys and profile, or uv): SKIP with a
# message naming what, exit 0. Every skip and every verdict is also one markdown line in "$GITHUB_STEP_SUMMARY" when
# that variable is set, so a skipped review is visible on the job's page.
# Never a failure but a verdict: an unparseable answer, an empty one, a timeout or a missing credential skip with a warning.
# Exit: 0 ok or skipped, 1 the model says the help/skills text is out of date, 2 a bad call of this script.
set -u
DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1; shift ;;
        -h|--help) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --) shift; break ;;
        -*) echo "help-review: unknown option $1 (see --help)" >&2; exit 2 ;;
        *) break ;;
    esac
done
[ $# -eq 0 ] || [ $# -eq 2 ] || { echo "help-review: usage: help-review.sh [--dry-run] [<from> <to>]" >&2; exit 2; }
to=${2:-HEAD}
if [ $# -eq 2 ]; then from=$1
elif git rev-parse -q --verify HEAD^2 >/dev/null 2>&1; then from=HEAD^1
else from=origin/main; fi

MODEL=${SALA_REVIEW_MODEL:-global.anthropic.claude-haiku-5-5}
TMO=${SALA_REVIEW_TIMEOUT:-120}
DIFF_MAX=${SALA_REVIEW_DIFF_MAX:-60000}
note() { echo "help-review: $*"; }
warn() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::warning title=help-review::$*"; else echo "help-review: WARNING $*"; fi; }
summary() {  # one markdown line on the job's page, when there is one
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
    printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || :
}
skip() { warn "SKIPPED: $*"; summary "- **help-review: skipped** — $*"; exit 0; }   # a skip is green and visible

git rev-parse -q --verify "$from^{commit}" >/dev/null 2>&1 && git rev-parse -q --verify "$to^{commit}" >/dev/null 2>&1 \
    || skip "no range $from..$to in this checkout"
files=$(git diff --name-only "$from" "$to" -- bin/salamander lib/)
if [ -z "$files" ]; then
    note "the change touches neither bin/salamander nor lib/: nothing to review"
    summary "- **help-review: nothing to review** — the change touches neither bin/salamander nor lib/"
    exit 0
fi

W=$(mktemp -d) || exit 1; trap 'rm -rf "$W"' EXIT
capped() {  # <max> <file> → the file, cut at <max> bytes with a visible marker
    if [ "$(wc -c < "$2")" -gt "$1" ]; then head -c "$1" "$2"; printf '\n[... cut at %s bytes ...]\n' "$1"; else cat "$2"; fi
}
git diff -U3 "$from" "$to" -- bin/salamander lib/ > "$W/cli.diff"
git diff -U3 "$from" "$to" -- tests/help-snapshot.txt > "$W/snap.diff"
git diff --name-only "$from" "$to" > "$W/files"

skills=${SKILLS_DIR:-}
if [ -n "$skills" ] && [ -d "$skills" ]; then
    ( cd "$skills" && grep -rnE '(^|[^[:alnum:]-])(sala|salamander)[[:space:]]' --include='*.md' . ) > "$W/skills.txt" 2>/dev/null || :
    [ -s "$W/skills.txt" ] || echo "(no skill line names sala)" > "$W/skills.txt"
else
    echo "(no skills checkout on this runner: the skills text could not be read; judge by the pull request description)" > "$W/skills.txt"
fi

{
cat <<'EOF'
You review one pull request to salamander ("sala"), a bash CLI that operates Claude Code sessions. Rule: a PR that
changes a sala command's shape, words or output carries, in the same PR, the CLI's help and messages and the matching skills change.
The help is the comment block at the top of bin/salamander (printed by `sala --help`), the usage each verb prints, and the committed
snapshot tests/help-snapshot.txt (regenerated by `bash tests/help-snapshot.sh --update`). The skills are files of the skills plugin that teach
sessions to call sala; they live in another repository, so the pull request description may be the only place that names that change.

"Changes a command's shape, words or output" means: a verb or flag added, removed or renamed; an argument changing meaning or
order; an exit code changing; a message, line or table a user or a session reads changing its words or fields. It does NOT mean:
internal refactors, fixes that restore the documented behaviour, tests, comments that are not help, performance, log-file text
nobody reads as an interface.

Answer ok=false only when the diff DOES change a command's shape, words or output AND (the help text/snapshot were not changed to
match OR the pull request description names no skills change although the changed command is one a skill teaches, judging from
the skills lines below). If unsure, or the change is internal, answer ok=true. Answer with ONE JSON object and nothing else:
{"ok": true|false, "reason": "<one or two plain sentences: what changed and what is missing; for ok=true say why nothing is missing>"}

EOF
echo "=== files changed in the pull request ==="
capped 8000 "$W/files"
echo; echo "=== pull request description (may name the skills change) ==="
printf '%s\n' "${PR_BODY:-(no description given)}" | head -c 4000
echo; echo "=== diff of bin/salamander and lib/ ==="
capped "$DIFF_MAX" "$W/cli.diff"
echo; echo "=== diff of the help snapshot tests/help-snapshot.txt (empty: the help did not change) ==="
if [ -s "$W/snap.diff" ]; then capped 20000 "$W/snap.diff"; else echo "(no change to the snapshot)"; fi
echo; echo "=== skills lines that name sala (file:line:text; a cut copy) ==="
capped 20000 "$W/skills.txt"
echo
} > "$W/prompt"

if [ "$DRY" = 1 ]; then cat "$W/prompt"; exit 0; fi

# --- the sign-in: keys in the environment (in CI, from the workflow's OIDC step) or a profile, present on this runner or not ---
export ANTHROPIC_AWS_PROFILE=${ANTHROPIC_AWS_PROFILE:-}
export ANTHROPIC_AWS_REGION=${ANTHROPIC_AWS_REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}
export SALA_REVIEW_MODEL=$MODEL
profile=$ANTHROPIC_AWS_PROFILE
credfile=${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}
conffile=${AWS_CONFIG_FILE:-$HOME/.aws/config}
has_header() {  # <file> <header line> → 0 when the file has that [header] (a presence test, no value read)
    [ -r "$1" ] && awk -v h="$2" '{ sub(/[ \t\r]+$/, "") } $0 == h { f = 1; exit } END { exit !f }' "$1" 2>/dev/null
}
if [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then :
elif [ -z "$profile" ]; then
    skip "no AWS sign-in: AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY are not in the environment (in CI the workflow's sign-in step sets them from the repository secret SALA_REVIEW_AWS_ROLE and the variable SALA_REVIEW_AWS_REGION; a failed step is only a warning) and ANTHROPIC_AWS_PROFILE names no profile. The review runs where it has one."
elif has_header "$credfile" "[$profile]" || has_header "$conffile" "[profile $profile]"; then :
else
    skip "this runner has no AWS sign-in for Amazon Bedrock (no profile [$profile] in $credfile or $conffile, and no AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY). The review runs where it is."
fi
if [ -n "${SALA_REVIEW_CALL:-}" ]; then read -r -a CALL <<< "$SALA_REVIEW_CALL"
else
    command -v uv >/dev/null 2>&1 || skip "uv is not on this runner's PATH (the call is a uv script)"
    CALL=(uv run --locked --script "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/help_review_call.py")
fi

# --- one bounded call, one retry at most ---
# The HTTPS call gets a little less time than the whole (uv starting the script counts in the whole).
HTMO=60; case "$TMO" in ''|*[!0-9]*) ;; *) HTMO=$(( TMO > 25 ? TMO - 15 : TMO )) ;; esac
export SALA_REVIEW_HTTP_TIMEOUT=$HTMO
answer=""
for attempt in 1 2; do
    ( cd "$W" && timeout "$TMO" "${CALL[@]}" < "$W/prompt" > "$W/answer" 2> "$W/err" ); rc=$?
    answer=$(cat "$W/answer" 2>/dev/null)
    if [ "$rc" = 0 ] && [ -n "${answer//[[:space:]]/}" ]; then break; fi
    why="the call exited $rc"; [ "$rc" = 124 ] && why="no answer within ${TMO}s"
    last=$(tail -n 1 "$W/err" 2>/dev/null | sed -E 's/(AKIA|ASIA)[A-Z0-9]{12,}/<masked>/g; s/[A-Za-z0-9+\/=_-]{32,}/<masked>/g' | cut -c1-200)
    note "attempt $attempt: $why${last:+ ($last)}"
    answer=""
done
if [ -z "${answer//[[:space:]]/}" ]; then skip "the model gave no answer after two tries"; fi
# the call's last stderr line on success (help_review_call.py prints its stop_reason there): shown, masked, so a cut-off reply can be told from prose
stoplast=$(grep '^help_review_call: stop_reason=' "$W/err" 2>/dev/null | tail -n 1 | sed -E 's/(AKIA|ASIA)[A-Z0-9]{12,}/<masked>/g; s/[A-Za-z0-9+\/=_-]{32,}/<masked>/g' | cut -c1-200) || :
if [ -n "$stoplast" ]; then note "model call: ${stoplast#help_review_call: }"; fi

verdict=$(printf '%s' "$answer" | python3 -I -c '
import json, sys
t = sys.stdin.read()
cands = [t.strip()]
a, b = t.find("{"), t.rfind("}")
if 0 <= a < b: cands.append(t[a:b + 1])
for c in cands:
    try:
        o = json.loads(c)
    except Exception:
        continue
    if isinstance(o, dict) and isinstance(o.get("ok"), bool):
        r = o.get("reason", "")
        print(("ok" if o["ok"] else "bad") + "\t" + " ".join(str(r).split())[:600])
        sys.exit(0)
print("unparseable\t")
')
kind=${verdict%%$'\t'*}; reason=${verdict#*$'\t'}
case "$kind" in
    ok) note "ok ($MODEL): ${reason:-no reason given}"; summary "- **help-review: pass** ($MODEL) — ${reason:-no reason given}"; exit 0 ;;
    bad)
        if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error title=help text out of date::${reason:-no reason given}"; fi
        note "FAIL ($MODEL): ${reason:-no reason given}"
        summary "- **help-review: FAIL** ($MODEL) — ${reason:-no reason given}"
        note "fix: update the help (bin/salamander's header and the verb's usage), run 'bash tests/help-snapshot.sh --update', and carry the matching skills change (name it in the PR description). If the review is wrong, say why in the PR and ask the maintainer to merge."
        exit 1 ;;
    *)
        # show WHY: the first 400 characters of the reply on one line, masked like the error text above (shown only here, never on a verdict)
        shown=$(printf '%s' "$answer" | tr -s '[:space:]' ' ' | sed -E 's/(AKIA|ASIA)[A-Z0-9]{12,}/<masked>/g; s/[A-Za-z0-9+\/=_-]{32,}/<masked>/g' | cut -c1-400) || :
        note "unparsed answer (first 400 chars, masked): $shown"
        skip "the answer was not the JSON {ok, reason} asked for" ;;
esac
