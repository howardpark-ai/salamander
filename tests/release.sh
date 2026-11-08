#!/usr/bin/env bash
# release.sh's two ways to a deploy (Tue Oct 27th 2026): an open PR is merged and deployed as before; a PR that is
# ALREADY MERGED (by hand or by a merge script, so main moved but the production checkout was not deployed) is not merged again:
# the check runs on its merge commit on main are waited for, and only when all passed does the deploy run. Kept because
# the gate is what stands between a merge and a deploy under every live session's feet: a wrong verdict deploys a main whose
# own checks failed, or merges twice. release.sh --run is run against a copy of the script in a throwaway git checkout (its
# origin url names a made-up repo), with a fake `gh` on PATH serving canned JSON and logging every call, a fake `systemd-run` (the start path; no unit is started), a fake deploy.sh
# that only logs, and a fake stackshot client that logs the message; the waits are shortened by SALA_RELEASE_POLL /
# _WAIT / _GRACE. No network, no real merge or deploy. Checks: an open PR (merged, then deployed, as before); a merged PR
# (no `gh pr merge`, the check runs on main's commit asked for and waited through while pending, deployed, one message that
# says it was already merged); a failing check on main (exit 1, the deploy never run, the message names the step); no
# check run and no workflow run on main (goes on after the grace) but a workflow run still queued (keeps waiting, fails at the
# wait's end); --merged on an open PR (refused, nothing merged); a drifted checkout (nothing merged or deployed either way);
# the usage lines. GitHub's API budget (Wed Oct 28th 2026): the poll defaults to 60 s (SALA_RELEASE_POLL overrides it, checked
# through a fake `sleep`); the checks are read with `gh api -i` and an ETag (a 304 answers from the kept body; `gh pr checks` and
# `gh run list` are never called, the fake fails the run if they are); an open PR's checks follow its head commit when it moves;
# two releases waiting on one commit make one read between them (SALA_RELEASE_GH_TTL), and a TTL of 0 reads every time.
# The CI-run poller's file: while a fresh <state>/ci-runs/o__r.json shows a workflow run of the commit not completed, the wait asks GitHub for
# no check runs (and fails at its end like a pending check); a completed run, no run of the sha, a stale file, SALA_RELEASE_CIFILE_MAX_AGE=0, a missing
# file or a checkout with no lib/cipoll.py all take the check-runs read as before; the file turning completed while a release waits gives the
# check-runs read, and that alone decides pass or fail (a stale 'completed' file never passes a release whose check runs fail).
# A check is judged by its newest run: an old failed run + a newer pass of the same check passes (in either list order), an old pass + a newer
# fail fails with nothing merged, an old pass + a newer run in progress keeps waiting, an old fail + a newer queued run (no start time) waits, and a failed run of a different check is not hidden.
# The live release is reported to stackshot (client.py released --pr <PR url> --sha <merge commit>; the fake client logs it apart from the messages) after
# a successful deploy and before the final message: the merge commit is the open PR's from `gh pr view --json mergeCommit` after the merge, else the first-parent
# merge in the checkout, else a log line and no call; an already merged PR passes the merge commit its checks ran on; the client's lines are logged as 'items of PR #n: …';
# a failing client (cut to 300 characters), no client at all, or no merge commit never fails the release; a failed release (deploy, checks) never calls it.
# Not checked: the systemd-run start (a real user unit), the real gh and deploy.sh.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME=$(mktemp -d); mkdir -p "$HOME/bin"; export PATH="$HOME/bin:$PATH"
unset SALA_CONFIG SALA_LOG_DIR
export SALA_STACKSHOT_DIR= XDG_STATE_HOME="$HOME/state"   # empty: nothing is sent to the board, only logged; the state dir is the temp HOME (never ~/.local/state/salamander/releases)
trap 'rm -rf "$HOME"' EXIT
export FAKE_DIR="$HOME/fake"; mkdir -p "$FAKE_DIR"
export STACKSHOT_CLIENT="$HOME/client.py"
export SALA_RELEASE_POLL=1 SALA_RELEASE_WAIT=3 SALA_RELEASE_GRACE=1 SALA_RELEASE_GH_TTL=0   # TTL 0: every look asks GitHub (the fake); the cache cases below set their own

cat > "$HOME/bin/gh" <<'FAKE'
#!/bin/bash
echo "gh $*" >> "$FAKE_DIR/calls"
case "$1 $2" in
    "pr view") if [[ "$*" == *--jq* ]]; then cat "$FAKE_DIR/mergeoid" 2>/dev/null; exit 0; fi   # the merge commit asked for by itself: what the test put in mergeoid (nothing: GitHub names none)
               cat "$FAKE_DIR/view.json"; exit ;;
    "pr checks"|"run list") echo "gh $1 $2 must not be used" >> "$FAKE_DIR/bad"; exit 1 ;;
    "pr merge") exit 0 ;;
esac
if [ "$1" = api ]; then   # gh api <path> -i [-H "If-None-Match: <etag>"]: headers, a blank line, the body; a matching ETag answers 304 and exit 1, as gh does
    path="$2"; inm=; allargs="$*"
    while [ $# -gt 0 ]; do [ "$1" = -H ] && inm="${2#If-None-Match: }"; shift; done
    if [ "$path" = graphql ]; then   # GitHub's merge queue: main's queue (mq: 1 or 0), the enqueue mutation, the PR's state and queue entry (gq.<n>.json, the n-th read or the last), the removal reason
        [ -e "$FAKE_DIR/gqfail" ] && { echo "gh: HTTP 502" >&2; exit 1; }
        case "$allargs" in
            *"mergeQueue(branch"*) echo "{\"data\":{\"repository\":{\"mergeQueue\":$([ "$(cat "$FAKE_DIR/mq" 2>/dev/null)" = 1 ] && echo '{"id":"MQ_1"}' || echo null),\"pullRequest\":{\"id\":\"PR_node_1\"}}}}"; exit 0 ;;
            *"enqueuePullRequest"*) if [ -e "$FAKE_DIR/enqfail" ]; then echo '{"errors":[{"message":"Required status check missing"}]}'; echo "gh: GraphQL error" >&2; exit 1; fi
                                    echo '{"data":{"enqueuePullRequest":{"mergeQueueEntry":{"state":"QUEUED","position":1}}}}'; exit 0 ;;
            *"REMOVED_FROM_MERGE_QUEUE_EVENT"*) cat "$FAKE_DIR/reason.json" 2>/dev/null || echo '{"data":{"repository":{"pullRequest":{"timelineItems":{"nodes":[]}}}}}'; exit 0 ;;
            *"mergeQueueEntry{state position}"*) n=$(( $(cat "$FAKE_DIR/gq.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_DIR/gq.count"
                                    while [ "$n" -gt 0 ] && [ ! -f "$FAKE_DIR/gq.$n.json" ]; do n=$((n - 1)); done
                                    cat "$FAKE_DIR/gq.$n.json"; exit 0 ;;
        esac
        echo "unexpected graphql: $allargs" >> "$FAKE_DIR/bad"; exit 1
    fi
    case "$path" in
        */git/refs/heads/*) [ -e "$FAKE_DIR/delfail" ] && exit 1; exit 0 ;;   # the head branch deleted after a queue merge (the call is logged above)
        */pulls/*) k=pr ;;
        */check-runs*) k=cr ;;
        */actions/runs*) k=wr ;;
        *) echo "unexpected: $path" >> "$FAKE_DIR/bad"; exit 1 ;;
    esac
    # the n-th ask of a kind gets <kind>.<n>.json, or the last one there is
    n=$(( $(cat "$FAKE_DIR/$k.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_DIR/$k.count"
    [ -x "$FAKE_DIR/on-$k-$n" ] && "$FAKE_DIR/on-$k-$n"     # a hook for the n-th ask of a kind: the poller's file changes while a release waits
    while [ "$n" -gt 0 ] && [ ! -f "$FAKE_DIR/$k.$n.json" ]; do n=$((n - 1)); done
    if [ "$n" -gt 0 ]; then body=$(cat "$FAKE_DIR/$k.$n.json"); else body='{"total_count":0,"check_runs":[]}'; fi
    etag="\"$(printf '%s' "$body" | md5sum | cut -c1-32)\""
    if [ -n "$inm" ] && [ "$inm" = "$etag" ]; then
        echo "$path" >> "$FAKE_DIR/c304"
        printf 'HTTP/2.0 304 Not Modified\r\nEtag: %s\r\n\r\n' "$etag"; echo "gh: HTTP 304" >&2; exit 1
    fi
    echo "$path" >> "$FAKE_DIR/c200"
    printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json\r\nEtag: %s\r\n\r\n%s\n' "$etag" "$body"
fi
FAKE
cat > "$HOME/client.py" <<'FAKE'
import os, sys
d, a = os.environ["FAKE_DIR"], sys.argv[1:]
open(os.path.join(d, "all"), "a").write(" ".join(a) + "\n")     # every call, in order
if a[:1] == ["released"]:                                        # client.py released --pr <PR url> --sha <merge commit>: its own file, so "messages" stays the messages
    open(os.path.join(d, "released"), "a").write(" ".join(a[1:]) + "\n")
    f = os.environ.get("FAKE_RELEASED_FAIL")
    if f:                                                        # a refusal or an unreachable server: one line on stdout, exit 1, as the real client does
        print("stackshot: items not settled [403] repo not accepted" if f == "1" else "E" * 400); sys.exit(1)
    n = a[2].rsplit("/", 1)[1]
    print("stackshot: PR #" + n + ": closed item-a (outcome done: shipped) — Fix the thing")
    print("stackshot: PR #" + n + ": left item-b alone: another step is open")
    sys.exit(0)
open(os.path.join(d, "messages"), "a").write(" ".join(a) + "\n")
FAKE
cat > "$HOME/bin/systemd-run" <<'FAKE'
#!/bin/bash
echo "systemd-run $*" >> "$FAKE_DIR/calls"
FAKE
printf '#!/bin/bash\nexit 3\n' > "$HOME/bin/systemctl"   # no unit is active
chmod +x "$HOME/bin/gh" "$HOME/bin/systemd-run" "$HOME/bin/systemctl"

# the production checkout stand-in: a copy of release.sh next to a deploy.sh that only logs
CO="$HOME/co"; mkdir -p "$CO/lib"; cp "$ROOT/release.sh" "$CO/release.sh"; cp "$ROOT/lib/cipoll.py" "$CO/lib/cipoll.py"; cp "$ROOT/lib/stackshot-path.sh" "$CO/lib/stackshot-path.sh"
cat > "$CO/deploy.sh" <<'FAKE'
#!/bin/bash
echo "deploy.sh $*" >> "$FAKE_DIR/calls"
[ "${1:-}" = --check ] && exit "${FAKE_DRIFT:-0}"
[ -n "${FAKE_DEPLOY_FAIL:-}" ] && { echo "deploy boom"; exit 1; }
echo "changed: lib/common.sh"
FAKE
chmod +x "$CO/deploy.sh" "$CO/release.sh"
git -C "$CO" init -q -b main; git -C "$CO" config user.email t@t; git -C "$CO" config user.name t
git -C "$CO" remote add origin https://github.com/o/r.git; git -C "$CO" add -A; git -C "$CO" commit -q -m base
SHA=0123456789abcdef0123456789abcdef01234567

view() { printf '{"state":"%s","mergeable":"%s","title":"Fix the thing","headRefName":"b","mergeCommit":%s}\n' "$1" "$2" "$3" > "$FAKE_DIR/view.json"; }
cruns() {  # <n> <name:status:conclusion>… → cr.<n>.json, the check runs GitHub lists for main's commit
    local n="$1" body="" r; shift
    for r in "$@"; do IFS=: read -r a b c <<< "$r"; body="$body${body:+,}{\"name\":\"$a\",\"status\":\"$b\",\"conclusion\":$([ "$c" = - ] && echo null || echo "\"$c\"")}"; done
    echo "{\"total_count\":$#,\"check_runs\":[$body]}" > "$FAKE_DIR/cr.$n.json"
}
prhead() { echo "{\"head\":{\"sha\":\"$2\"}}" > "$FAKE_DIR/pr.$1.json"; }   # <n> <sha> → pr.<n>.json, the PR's n-th read
wruns() { echo "{\"total_count\":$1,\"workflow_runs\":[]}" > "$FAKE_DIR/wr.1.json"; }   # the workflow runs GitHub lists for main's commit
n200() { grep -c -- "$1" "$FAKE_DIR/c200" 2>/dev/null || true; }
n304() { grep -c -- "$1" "$FAKE_DIR/c304" 2>/dev/null || true; }
reset() { rm -f "$FAKE_DIR"/*; : > "$FAKE_DIR/calls"; wruns 0; rm -rf "$HOME/state"; unset FAKE_DRIFT FAKE_DEPLOY_FAIL FAKE_RELEASED_FAIL; }
release() { out=$(bash "$CO/release.sh" "$@" 2>&1); rc=$?; }
calls() { cat "$FAKE_DIR/calls"; }
called() { calls | grep -q -- "$1"; }
msgs() { cat "$FAKE_DIR/messages" 2>/dev/null; }
MERGED_C="{\"oid\":\"$SHA\"}"
PASS3=("changes:completed:success" "suites:completed:success" "web:completed:skipped")

echo "== an open PR: merged, then deployed (as before)"
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"
release --run 12
[ "$rc" = 0 ] && called "gh pr merge 12 --repo o/r --merge --delete-branch --admin" && called "^deploy.sh $" && [[ "$(msgs)" == *"[release] PR #12 merged and deployed — Fix the thing"* ]] && [[ "$(msgs)" != *"already merged"* ]] \
    && ok "open: gh pr merge ran, then deploy.sh, one plain 'merged and deployed' message" || bad "open: rc=$rc calls=$(calls) msgs=$(msgs) $out"
called "gh api repos/o/r/pulls/12 " && called "gh api repos/o/r/commits/$SHA/check-runs" && [ ! -e "$FAKE_DIR/bad" ] \
    && ok "open: the PR's head commit and that commit's check runs are read through gh api (no gh pr checks)" || bad "open: calls=$(calls) bad=$(cat "$FAKE_DIR/bad" 2>/dev/null)"

echo "== an already merged PR: no merge, the checks on main waited for, then deployed"
reset; view MERGED "" "$MERGED_C"; cruns 1 "changes:completed:success" "suites:in_progress:-" "web:queued:-"; cruns 2 "${PASS3[@]}"
release --run 13
[ "$rc" = 0 ] && ! called "pr merge" && ! called "pr checks" && called "gh api repos/o/r/commits/$SHA/check-runs" && [ "$(grep -c check-runs "$FAKE_DIR/calls")" -ge 2 ] && [ ! -e "$FAKE_DIR/bad" ] \
    && ok "merged: no gh pr merge, no PR checks; main's check runs asked for twice (pending, then green)" || bad "merged: rc=$rc calls=$(calls) $out"
called "^deploy.sh $" && [[ "$out" == *"checks on main (0123456) pass: changes, suites; skipped, not needed by this change: web"* ]] \
    && ok "merged: deploy.sh ran after the checks on main passed" || bad "merged: no deploy or no verdict line: $out"
[ "$(msgs | wc -l)" = 1 ] && [[ "$(msgs)" == *"[release] PR #13 merged and deployed (it was already merged; the checks on main passed) — Fix the thing"* ]] \
    && ok "merged: one message, saying it was already merged" || bad "merged: messages=$(msgs)"

echo "== an already merged PR whose check fails on main: no deploy"
reset; view MERGED "" "$MERGED_C"; cruns 1 "changes:completed:success" "suites:completed:failure"
release --run 14
[ "$rc" = 1 ] && ! called "^deploy.sh $" && ! called "pr merge" && [[ "$(msgs)" == *"[release] PR #14 FAILED at checks: a check failed on main (0123456), so nothing was deployed: changes=pass, suites=fail"* ]] \
    && ok "failing check on main: exit 1, deploy never run, the message names the step and the checks" || bad "failing: rc=$rc calls=$(calls) msgs=$(msgs) $out"
reset; view MERGED "" "$MERGED_C"; cruns 1 "changes:completed:success" "suites:completed:cancelled"
release --run 14; [ "$rc" = 1 ] && ! called "^deploy.sh $" && ok "a cancelled check run counts as a failure too" || bad "cancelled: rc=$rc $out"

echo "== an already merged PR with nothing on main"
reset; view MERGED "" "$MERGED_C"
release --run 15
[ "$rc" = 0 ] && called "gh api repos/o/r/actions/runs?head_sha=$SHA" && [ ! -e "$FAKE_DIR/bad" ] && called "^deploy.sh $" && [[ "$out" == *"no workflow run on 0123456 either: nothing to wait for"* ]] \
    && ok "no check run and no workflow run on main's commit: goes on after the grace" || bad "none: rc=$rc calls=$(calls) $out"
reset; view MERGED "" "$MERGED_C"; wruns 1
release --run 15
[ "$rc" = 1 ] && ! called "^deploy.sh $" && [[ "$(msgs)" == *"FAILED at checks: still pending after 0 min on main (0123456), so nothing was deployed"* ]] \
    && ok "no check run yet but a workflow run is listed: keeps waiting, fails at the end of the wait, no deploy" || bad "queued: rc=$rc calls=$(calls) msgs=$(msgs) $out"

echo "== --merged"
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "suites:completed:success"
release --run --merged 16
[ "$rc" = 1 ] && ! called "pr merge" && ! called "^deploy.sh $" && [[ "$(msgs)" == *"FAILED at pr state: the PR is OPEN, not merged"* ]] \
    && ok "--merged on an open PR: refused, nothing merged or deployed" || bad "--merged open: rc=$rc calls=$(calls) msgs=$(msgs) $out"
reset; view MERGED "" "$MERGED_C"; cruns 1 "${PASS3[@]}"
release --run --merged 17
[ "$rc" = 0 ] && ! called "pr merge" && called "^deploy.sh $" && ok "--merged on a merged PR: deployed like the plain form" || bad "--merged merged: rc=$rc $out"

echo "== a drifted checkout"
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "suites:completed:success"; export FAKE_DRIFT=1
release --run 18
[ "$rc" = 1 ] && ! called "pr merge" && [ "$(grep -c '^deploy.sh' "$FAKE_DIR/calls")" = 1 ] && ok "open + drift: nothing merged" || bad "drift open: rc=$rc calls=$(calls) $out"
reset; view MERGED "" "$MERGED_C"; cruns 1 "${PASS3[@]}"; export FAKE_DRIFT=1
release --run 18
[ "$rc" = 1 ] && [ "$(grep -c '^deploy.sh' "$FAKE_DIR/calls")" = 1 ] && [[ "$(msgs)" == *"FAILED at drift: the production checkout has drifted, so nothing was deployed"* ]] \
    && ok "merged + drift: the real deploy never ran, the message says nothing was deployed" || bad "drift merged: rc=$rc calls=$(calls) msgs=$(msgs) $out"

echo "== the live release is reported to stackshot (client.py released), before the final message, never failing the release"
MSHA=89abcdef0123456789abcdef0123456789abcdef
released_of() { cat "$FAKE_DIR/released" 2>/dev/null; }
lineno() { grep -n -- "$1" "$FAKE_DIR/calls" | head -1 | cut -d: -f1; }
# an open PR: the merge commit is read from GitHub after our merge
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"; echo "$MSHA" > "$FAKE_DIR/mergeoid"
release --run 12
[ "$rc" = 0 ] && [ "$(released_of)" = "--pr https://github.com/o/r/pull/12 --sha $MSHA" ] \
    && ok "open: the fake client got released --pr https://github.com/o/r/pull/12 --sha <the merge sha>, once" || bad "open released: rc=$rc released=$(released_of) $out"
[[ "$out" == *"items of PR #12: PR #12: closed item-a (outcome done: shipped) — Fix the thing;PR #12: left item-b alone: another step is open"* ]] \
    && ok "open: the log carries the client's lines as 'items of PR #12: …', joined with ';'" || bad "open items line: $out"
[ "$(sed -n 1p "$FAKE_DIR/all" | cut -d' ' -f1)" = released ] && [[ "$(sed -n 2p "$FAKE_DIR/all")" == "message projects/salamander [release] PR #12 merged and deployed — Fix the thing"* ]] && [ "$(wc -l < "$FAKE_DIR/all")" = 2 ] \
    && ok "open: released first, then the final message (still sent, exactly one)" || bad "open order: $(cat "$FAKE_DIR/all")"
[ "$(lineno 'pr merge 12')" -lt "$(lineno 'json mergeCommit --jq')" ] \
    && ok "open: the merge commit is asked for only after the merge" || bad "open: the merge commit was read out of order: $(calls)"
# an already merged PR: main's merge commit, no extra read
reset; view MERGED "" "$MERGED_C"; cruns 1 "${PASS3[@]}"
release --run 13
[ "$rc" = 0 ] && [ "$(released_of)" = "--pr https://github.com/o/r/pull/13 --sha $SHA" ] && ! called "--jq" && [[ "$(msgs)" == *"[release] PR #13 merged and deployed (it was already merged"* ]] \
    && ok "merged: released with main's merge commit (the one the checks ran on); GitHub is not asked for it again" || bad "merged released: rc=$rc released=$(released_of) calls=$(calls) $out"
# a client that fails: the release goes on
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"; echo "$MSHA" > "$FAKE_DIR/mergeoid"; export FAKE_RELEASED_FAIL=1
release --run 12
[ "$rc" = 0 ] && called "^deploy.sh $" && [[ "$out" == *"live release not reported to stackshot: stackshot: items not settled [403] repo not accepted"* ]] && [[ "$out" != *"items of PR #12"* ]] \
    && [[ "$(msgs)" == *"[release] PR #12 merged and deployed"* ]] && ok "a refused report: exit 0, deployed, 'live release not reported to stackshot: …' in the log, the final message still sent" || bad "refused: rc=$rc msgs=$(msgs) $out"
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"; echo "$MSHA" > "$FAKE_DIR/mergeoid"; export FAKE_RELEASED_FAIL=long
release --run 12
[ "$rc" = 0 ] && printf '%s\n' "$out" | grep -Eq 'live release not reported to stackshot: E{300}$' && ok "a long error is cut to its first 300 characters" || bad "long error: rc=$rc $out"
# no client configured (SALA_STACKSHOT_DIR is empty in this suite): nothing sent, one line
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"; echo "$MSHA" > "$FAKE_DIR/mergeoid"
out=$(STACKSHOT_CLIENT= bash "$CO/release.sh" --run 12 2>&1); rc=$?
[ "$rc" = 0 ] && called "^deploy.sh $" && [ ! -e "$FAKE_DIR/all" ] && [ "$(printf '%s\n' "$out" | grep -c 'stackshot not configured: live release not reported')" = 1 ] && [[ "$out" == *"message not sent: [release] PR #12 merged and deployed"* ]] \
    && ok "no client (STACKSHOT_CLIENT and SALA_STACKSHOT_DIR empty): nothing sent, one 'stackshot not configured' line, the release goes on" || bad "no client: rc=$rc all=$(cat "$FAKE_DIR/all" 2>/dev/null) $out"
# the client from the stackshot checkout (STACKSHOT_CLIENT unset): the package path of a new checkout, the root path of an old one, the package path when both are there
for lay in new old both; do
    SST="$HOME/sstree-$lay"; rm -rf "$SST"; mkdir -p "$SST/stackshot/fleet"
    case "$lay" in new|both) cp "$HOME/client.py" "$SST/stackshot/fleet/client.py" ;; esac
    case "$lay" in old) cp "$HOME/client.py" "$SST/client.py" ;; both) printf 'import sys; sys.exit(9)\n' > "$SST/client.py" ;; esac   # the old root file of "both" is a forwarder: it must not be the one called
    reset; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"; echo "$MSHA" > "$FAKE_DIR/mergeoid"
    out=$(env -u STACKSHOT_CLIENT SALA_STACKSHOT_DIR="$SST" bash "$CO/release.sh" --run 12 2>&1); rc=$?
    [ "$rc" = 0 ] && [ "$(released_of)" = "--pr https://github.com/o/r/pull/12 --sha $MSHA" ] \
        && ok "SALA_STACKSHOT_DIR with a $lay checkout: the release was reported through the client the probe found" || bad "dir $lay: rc=$rc released=$(released_of) $out"
done
# a failed release never reports
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"; echo "$MSHA" > "$FAKE_DIR/mergeoid"; export FAKE_DEPLOY_FAIL=1
release --run 12
[ "$rc" = 1 ] && [ ! -e "$FAKE_DIR/released" ] && [[ "$(msgs)" == *"FAILED at deploy"* ]] && [[ "$out" != *"live release"* ]] && ok "deploy fails: exit 1, released never called, only the FAILED message" || bad "deploy fail: rc=$rc released=$(released_of) msgs=$(msgs) $out"
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "changes:completed:success" "suites:completed:failure"
release --run 12
[ "$rc" = 1 ] && [ ! -e "$FAKE_DIR/released" ] && ok "a failing check: released never called" || bad "check fail: rc=$rc $(released_of)"
reset; view MERGED "" "$MERGED_C"; cruns 1 "${PASS3[@]}"; export FAKE_DEPLOY_FAIL=1
release --run 13
[ "$rc" = 1 ] && [ ! -e "$FAKE_DIR/released" ] && ok "merged mode, deploy fails: released never called" || bad "merged deploy fail: rc=$rc $(released_of)"
# GitHub names no merge commit: the first-parent merge of this checkout is used; with neither, a line and no call
git -C "$CO" checkout -q -b side; echo x > "$CO/x"; git -C "$CO" add x; git -C "$CO" commit -q -m side; git -C "$CO" checkout -q main
git -C "$CO" merge -q --no-ff side -m "Merge pull request #70 from o/side"; GITSHA=$(git -C "$CO" rev-parse HEAD)
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"
release --run 70
[ "$rc" = 0 ] && [ "$(released_of)" = "--pr https://github.com/o/r/pull/70 --sha $GITSHA" ] && ok "GitHub names none: the PR's merge in the checkout's first-parent history is reported" || bad "git fallback: rc=$rc released=$(released_of) $out"
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"
release --run 71
[ "$rc" = 0 ] && [ ! -e "$FAKE_DIR/released" ] && [[ "$out" == *"live release not reported to stackshot: neither GitHub nor this checkout names the merge commit of PR #71"* ]] && [[ "$(msgs)" == *"[release] PR #71 merged and deployed"* ]] \
    && ok "no merge commit anywhere: nothing reported, the reason in the log, the final message sent" || bad "no sha: rc=$rc released=$(released_of) $out"

echo "== GitHub's API budget: the poll interval"
# a fake sleep that logs its argument and returns at once, so the real default (60 s) can be observed without waiting; the wait is 3 s, so the first sleep ends it
printf '#!/bin/bash\necho "$*" >> "$FAKE_DIR/sleeps"\n' > "$HOME/bin/sleep"; chmod +x "$HOME/bin/sleep"
reset; view MERGED "" "$MERGED_C"; cruns 1 "changes:completed:success" "suites:in_progress:-"
out=$(env -u SALA_RELEASE_POLL bash "$CO/release.sh" --run 30 2>&1); rc=$?
[ "$rc" = 1 ] && [ "$(cat "$FAKE_DIR/sleeps" 2>/dev/null)" = 60 ] && ok "no SALA_RELEASE_POLL: the checks are looked at every 60 s" || bad "default poll: rc=$rc sleeps=$(cat "$FAKE_DIR/sleeps" 2>/dev/null) $out"
reset; view MERGED "" "$MERGED_C"; cruns 1 "changes:completed:success" "suites:in_progress:-"
out=$(SALA_RELEASE_POLL=7 bash "$CO/release.sh" --run 30 2>&1); rc=$?
[ "$rc" = 1 ] && [ "$(cat "$FAKE_DIR/sleeps" 2>/dev/null)" = 7 ] && ok "SALA_RELEASE_POLL still overrides it" || bad "override poll: rc=$rc sleeps=$(cat "$FAKE_DIR/sleeps" 2>/dev/null) $out"
rm -f "$HOME/bin/sleep"

echo "== a read repeated on a timer sends its ETag; a 304 gives the kept answer"
# pending, pending, pending, then green: 4 looks = a 200, two 304s (nothing changed), a 200 (it changed)
reset; view MERGED "" "$MERGED_C"; cruns 1 "changes:completed:success" "suites:in_progress:-"; cp "$FAKE_DIR/cr.1.json" "$FAKE_DIR/cr.2.json"; cp "$FAKE_DIR/cr.1.json" "$FAKE_DIR/cr.3.json"; cruns 4 "${PASS3[@]}"
release --run 31
[ "$rc" = 0 ] && called "^deploy.sh $" && [ "$(n200 check-runs)" = 2 ] && [ "$(n304 check-runs)" = 2 ] && [ "$(grep -c 'If-None-Match' "$FAKE_DIR/calls")" = 3 ] \
    && ok "check runs: first look 200, two unchanged looks 304 (If-None-Match sent), a changed one 200; the verdict followed the kept body, then the new one" \
    || bad "etag: rc=$rc 200=$(n200 check-runs) 304=$(n304 check-runs) calls=$(calls) $out"
first=$(grep -m1 check-runs "$FAKE_DIR/calls")
[[ "$first" != *"If-None-Match"* ]] && ok "the first look sends no ETag" || bad "first look sent one: $first"
reset; view MERGED "" "$MERGED_C"; cruns 1 "changes:completed:success" "suites:in_progress:-"
release --run 31
[ "$rc" = 1 ] && [[ "$(msgs)" == *"still pending after 0 min on main (0123456)"* ]] && [ "$(n304 check-runs)" -ge 2 ] \
    && ok "a 304 on a pending run keeps the wait going to its end (the kept body is the verdict)" || bad "304 pending: rc=$rc msgs=$(msgs) $out"

echo "== an open PR follows its head commit when it moves"
OTHER=fedcba9876543210fedcba9876543210fedcba98
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"; prhead 2 "$OTHER"; cruns 1 "suites:in_progress:-"; cruns 2 "suites:completed:success"
release --run 32
[ "$rc" = 0 ] && called "commits/$SHA/check-runs" && called "commits/$OTHER/check-runs" && called "pr merge 32" \
    && ok "a push while it waits: the new head's check runs decide, then it is merged" || bad "head moves: rc=$rc calls=$(calls) $out"
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "changes:completed:success" "suites:completed:failure"
release --run 32
[ "$rc" = 1 ] && ! called "pr merge" && [[ "$(msgs)" == *"FAILED at checks: a check failed: changes=pass, suites=fail"* ]] && ok "open PR with a failing check: not merged" || bad "open fail: rc=$rc msgs=$(msgs) $out"

echo "== shared reads: releases waiting on one commit read it once between them"
# TTL far longer than the test: the first look asks GitHub, every other look of either release reuses it
reset; view MERGED "" "$MERGED_C"; cruns 1 "changes:completed:success" "suites:in_progress:-"
( export SALA_RELEASE_GH_TTL=1000; bash "$CO/release.sh" --run 40 > "$HOME/r40.out" 2>&1 ) & p1=$!
( export SALA_RELEASE_GH_TTL=1000; bash "$CO/release.sh" --run 41 > "$HOME/r41.out" 2>&1 ) & p2=$!
wait $p1; r1=$?; wait $p2; r2=$?
[ "$r1" = 1 ] && [ "$r2" = 1 ] && [ "$(grep -c "gh api repos/o/r/commits/$SHA/check-runs" "$FAKE_DIR/calls")" = 1 ] \
    && ok "two releases, four looks each: one call to GitHub in all" || bad "shared: r1=$r1 r2=$r2 calls=$(calls)"
ls "$HOME/state/salamander/releases/gh-cache" 2>/dev/null | grep -q '\.body$' && ok "the answer is kept under <state>/gh-cache" || bad "no cache folder: $(ls -R "$HOME/state" 2>&1 | head)"
reset; view MERGED "" "$MERGED_C"; cruns 1 "changes:completed:success" "suites:in_progress:-"
release --run 40
[ "$rc" = 1 ] && [ "$(grep -c "gh api repos/o/r/commits/$SHA/check-runs" "$FAKE_DIR/calls")" = 4 ] && ok "TTL 0: every look asks (4 looks, 4 calls), the rest of the suite's setting" || bad "ttl 0: rc=$rc calls=$(calls)"
# a cached answer is reused across releases only while it is younger than the TTL; an old one is asked again, with its ETag
reset; view MERGED "" "$MERGED_C"; cruns 1 "${PASS3[@]}"
SALA_RELEASE_GH_TTL=1000 release --run 42; first_calls=$(grep -c check-runs "$FAKE_DIR/calls")
touch -d '2 hours ago' "$HOME"/state/salamander/releases/gh-cache/*.body
SALA_RELEASE_GH_TTL=1000 release --run 43
[ "$first_calls" = 1 ] && [ "$(grep -c check-runs "$FAKE_DIR/calls")" = 2 ] && [ "$(n304 check-runs)" = 1 ] && [ "$rc" = 0 ] \
    && ok "an answer older than the TTL is asked again with its ETag (304), and used" || bad "stale: first=$first_calls calls=$(calls) $out"

echo "== the CI-run poller's file"
CIF="$HOME/state/salamander/ci-runs/o__r.json"
cifile() {  # <age seconds> <sha:status>… → the poller's file for o/r, last refreshed <age> s ago, one workflow run per spec
    local age="$1"; shift
    mkdir -p "$(dirname "$CIF")"
    python3 - "$CIF" "$age" "$@" <<'PY'
import json, os, sys, time
f, age, specs = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
runs = [{"id": 900 + i, "name": "tests", "head_sha": sp.split(":")[0], "head_branch": "b", "event": "pull_request", "status": sp.split(":")[1],
         "conclusion": None if sp.split(":")[1] != "completed" else "success", "created_at": "t", "updated_at": "t", "html_url": "u", "run_attempt": 1} for i, sp in enumerate(specs)]
t = int(time.time()) - age
json.dump({"repo": "o/r", "updated": t, "updated_iso": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t)), "runs": runs}, open(f + ".tmp", "w"))
os.replace(f + ".tmp", f)
PY
}
ncr() { grep -c "check-runs" "$FAKE_DIR/calls" 2>/dev/null || true; }
# a fresh file shows the head commit's run going: no check-runs call at all; the wait runs to its end like a pending check
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"; cifile 5 "$SHA:in_progress"
release --run 50
[ "$rc" = 1 ] && [ "$(ncr)" = 0 ] && ! called "pr merge" && ! called "^deploy.sh $" && [[ "$(msgs)" == *"FAILED at checks: still pending after 0 min"* ]] && [[ "$out" == *"1 of 1 run(s) of 0123456 not completed"* ]] \
    && ok "fresh file, run in progress: no check-runs call, waited to the end of the wait, not merged (even though the check runs would have passed: the file only ever says 'going')" || bad "going: rc=$rc cr=$(ncr) calls=$(calls) msgs=$(msgs) $out"
# the same file, merged mode (the commit is main's merge commit)
reset; view MERGED "" "$MERGED_C"; cruns 1 "${PASS3[@]}"; cifile 5 "$SHA:queued"
release --run 51
[ "$rc" = 1 ] && [ "$(ncr)" = 0 ] && ! called "^deploy.sh $" && ok "merged mode: the same, nothing deployed while the file shows the run going" || bad "merged going: rc=$rc cr=$(ncr) $out"
# the run completed: the check-runs read decides (pass here)
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"; cifile 5 "$SHA:completed"
release --run 52
[ "$rc" = 0 ] && [ "$(ncr)" = 1 ] && called "pr merge 52" && ok "file says completed: one check-runs read, which passes; merged and deployed" || bad "completed: rc=$rc cr=$(ncr) $out"
# a completed file never passes what the check runs fail
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "changes:completed:success" "suites:completed:failure"; cifile 5 "$SHA:completed"
release --run 53
[ "$rc" = 1 ] && [ "$(ncr)" = 1 ] && ! called "pr merge" && [[ "$(msgs)" == *"FAILED at checks: a check failed: changes=pass, suites=fail"* ]] && ok "file says completed, check runs fail: not merged (the file cannot pass a release)" || bad "completed+fail: rc=$rc msgs=$(msgs) $out"
# a stale file is not believed: the check-runs read as before
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"; cifile 600 "$SHA:in_progress"
release --run 54
[ "$rc" = 0 ] && [ "$(ncr)" = 1 ] && called "pr merge 54" && ok "a 600 s old file (limit 120): ignored, the check-runs read passes" || bad "stale: rc=$rc cr=$(ncr) $out"
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"; cifile 100 "$SHA:in_progress"
SALA_RELEASE_CIFILE_MAX_AGE=60 release --run 54
[ "$rc" = 0 ] && [ "$(ncr)" = 1 ] && ok "SALA_RELEASE_CIFILE_MAX_AGE=60 turns a 100 s old file away" || bad "max-age knob: rc=$rc cr=$(ncr) $out"
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"; cifile 5 "$SHA:in_progress"
SALA_RELEASE_CIFILE_MAX_AGE=0 release --run 54
[ "$rc" = 0 ] && [ "$(ncr)" = 1 ] && ok "SALA_RELEASE_CIFILE_MAX_AGE=0: the file is never used" || bad "max-age 0: rc=$rc cr=$(ncr) $out"
# no run of this sha in the file, no file, a corrupt file, no poller code: all fall back
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"; cifile 5 "$OTHER:in_progress"
release --run 55
[ "$rc" = 0 ] && [ "$(ncr)" = 1 ] && ok "a fresh file with no run of this commit: absence is not believed (it lists only the latest 30 runs), the check-runs read" || bad "other sha: rc=$rc cr=$(ncr) $out"
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"
release --run 56
[ "$rc" = 0 ] && [ "$(ncr)" = 1 ] && ok "no file: the check-runs read, as before" || bad "no file: rc=$rc cr=$(ncr) $out"
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"; cifile 5 "$SHA:in_progress"; printf '{"repo":"o/r","updated":' > "$CIF"
release --run 56
[ "$rc" = 0 ] && [ "$(ncr)" = 1 ] && ok "a torn or corrupt file: the check-runs read" || bad "corrupt: rc=$rc cr=$(ncr) $out"
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"; cifile 5 "$SHA:in_progress"; mv "$CO/lib/cipoll.py" "$CO/lib/cipoll.py.off"
release --run 56
mv "$CO/lib/cipoll.py.off" "$CO/lib/cipoll.py"
[ "$rc" = 0 ] && [ "$(ncr)" = 1 ] && ok "a checkout with no lib/cipoll.py: the check-runs read" || bad "no code: rc=$rc cr=$(ncr) $out"
# the file turns completed while the release waits (the poller saw the run finish): going → one check-runs read → pass
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"; cifile 5 "$SHA:in_progress"
cat > "$FAKE_DIR/on-pr-2" <<FLIP
#!/bin/bash
python3 - "$CIF" <<'PY'
import json, os, sys, time
f = sys.argv[1]
d = json.load(open(f)); d["updated"] = int(time.time())
for r in d["runs"]: r["status"], r["conclusion"] = "completed", "success"
json.dump(d, open(f + ".tmp", "w")); os.replace(f + ".tmp", f)
PY
FLIP
chmod +x "$FAKE_DIR/on-pr-2"
SALA_RELEASE_WAIT=30 release --run 57
[ "$rc" = 0 ] && [ "$(ncr)" = 1 ] && called "pr merge 57" && [[ "$out" == *"waiting on the ci-runs file, no GitHub call"* ]] && ok "the file turns completed during the wait: the going look made no check-runs call, the next one made one and passed" || bad "flip: rc=$rc cr=$(ncr) calls=$(calls) $out"

echo "== a check is judged by its newest run (same check, several runs on one commit)"
# <n> <name|status|conclusion|started_at|id>… → cr.<n>.json with start times, ids and the app, as GitHub lists them (in any order)
cruns_t() {
    local n="$1" body="" r; shift
    for r in "$@"; do IFS='|' read -r a b c d e <<< "$r"; body="$body${body:+,}{\"id\":$e,\"name\":\"$a\",\"status\":\"$b\",\"conclusion\":$([ "$c" = - ] && echo null || echo "\"$c\""),\"started_at\":$([ "$d" = - ] && echo null || echo "\"$d\""),\"app\":{\"id\":15368}}"; done
    echo "{\"total_count\":$#,\"check_runs\":[$body]}" > "$FAKE_DIR/cr.$n.json"
}
OLD=2026-11-02T01:32:35Z; NEW=2026-11-02T01:33:24Z
# an old failed run + a newer passing run of the same check: the newer one counts, the PR is merged and deployed
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"
cruns_t 1 "clean-text|completed|failure|$OLD|1" "changes|completed|success|$OLD|2" "clean-text|completed|success|$NEW|3"
release --run 61
[ "$rc" = 0 ] && called "pr merge 61" && called "^deploy.sh $" && [[ "$out" != *"clean-text=fail"* ]] && ok "old failed + newer passing run of one check: passes, merged and deployed" || bad "old fail/new pass: rc=$rc calls=$(calls) $out"
# the same, listed newest first (the order does not matter)
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"
cruns_t 1 "clean-text|completed|success|$NEW|3" "clean-text|completed|failure|$OLD|1" "changes|completed|success|$OLD|2"
release --run 62
[ "$rc" = 0 ] && called "pr merge 62" && ok "the same listed newest first: passes" || bad "order: rc=$rc $out"
# an old passing run + a newer failed run: the newer one counts, the release fails and merges nothing
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"
cruns_t 1 "clean-text|completed|success|$OLD|1" "changes|completed|success|$OLD|2" "clean-text|completed|failure|$NEW|3"
release --run 63
[ "$rc" = 1 ] && ! called "pr merge" && ! called "^deploy.sh $" && [[ "$out" == *"a check failed"* ]] && [[ "$out" == *"clean-text=fail"* ]] && [[ "$out" != *"clean-text=pass"* ]] && ok "old passing + newer failed run: fails, nothing merged or deployed" || bad "old pass/new fail: rc=$rc calls=$(calls) $out"
# an old passing run + a newer run still going: the release waits (to the end of the wait here), never passes on the old run
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"
cruns_t 1 "clean-text|completed|success|$OLD|1" "changes|completed|success|$OLD|2" "clean-text|in_progress|-|$NEW|3"
release --run 64
[ "$rc" = 1 ] && ! called "pr merge" && [[ "$out" == *"still pending after 0 min"* ]] && ok "old passing + newer run in progress: waits (still pending at the end), not merged" || bad "old pass/new pending: rc=$rc calls=$(calls) $out"
# an old failed run + a newer run still queued (started_at null): the queued one is the newest, so the release waits rather than failing on the old run
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"
cruns_t 1 "clean-text|completed|failure|$OLD|1" "changes|completed|success|$OLD|2" "clean-text|queued|-|-|3"
release --run 66
[ "$rc" = 1 ] && ! called "pr merge" && [[ "$out" == *"still pending after 0 min"* ]] && [[ "$out" != *"a check failed"* ]] && ok "old failed + newer queued run (started_at null): waits, does not fail on the old run" || bad "old fail/new queued: rc=$rc calls=$(calls) $out"
# runs of two different checks are never folded into one: a failed run of another check still fails
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"
cruns_t 1 "clean-text|completed|success|$NEW|3" "suites|completed|failure|$OLD|1"
release --run 65
[ "$rc" = 1 ] && ! called "pr merge" && [[ "$out" == *"suites=fail"* ]] && ok "a failed run of a different check is not superseded by another check's newer pass" || bad "other check: rc=$rc $out"

echo "== GitHub's merge queue on main: the PR is put in the queue, GitHub merges it, the merge commit is deployed"
# mq=1 in the fake's folder: main has a merge queue. gq <n> <STATE> <merge oid|-> [entry state] [position] → the n-th read of the PR (the last one repeats)
gq() { printf '{"data":{"repository":{"pullRequest":{"state":"%s","mergeCommit":%s,"mergeQueueEntry":%s}}}}\n' "$2" "$([ "$3" = - ] && echo null || echo "{\"oid\":\"$3\"}")" "$([ -n "${4:-}" ] && echo "{\"state\":\"$4\",\"position\":${5:-1}}" || echo null)" > "$FAKE_DIR/gq.$1.json"; }
mqon() { echo 1 > "$FAKE_DIR/mq"; }
QSHA=76543210fedcba9876543210fedcba9876543210
reset; mqon; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"; gq 1 OPEN - QUEUED 1; gq 2 OPEN - AWAITING_CHECKS 1; gq 3 MERGED "$QSHA"
release --run 80
[ "$rc" = 0 ] && ! called "pr merge" && called "^deploy.sh $" && [ ! -e "$FAKE_DIR/bad" ] && called "enqueuePullRequest" && called "-f id=PR_node_1" && called "-f h=$SHA" \
    && ok "queue on: the PR is enqueued with the node id and pinned to the head the checks passed on (expectedHeadOid), no gh pr merge, deployed after GitHub merged it" || bad "queue on: rc=$rc calls=$(calls) bad=$(cat "$FAKE_DIR/bad" 2>/dev/null) $out"
[[ "$out" == *"enqueued: the merge queue accepted the head 0123456"* ]] && [[ "$out" == *"in the merge queue (QUEUED position 1)"* ]] && [[ "$out" == *"merged by GitHub's merge queue as 7654321"* ]] \
    && ok "queue on: the log says enqueued, where the PR is in the queue, and the merge commit GitHub made" || bad "queue log: $out"
[ "$(released_of)" = "--pr https://github.com/o/r/pull/80 --sha $QSHA" ] && [[ "$(msgs)" == *"[release] PR #80 merged and deployed through GitHub's merge queue — Fix the thing"* ]] \
    && ok "queue on: stackshot is told the merge commit GitHub made (no extra read), and the message says it went through the merge queue" || bad "queue report: released=$(released_of) msgs=$(msgs)"
called "gh api repos/o/r/git/refs/heads/b -X DELETE" && [[ "$out" == *"deleted the head branch b"* ]] && ok "queue on: the head branch is deleted after the merge, as --delete-branch does" || bad "queue branch: calls=$(calls) $out"
! called "commits/$QSHA/check-runs" && ok "queue on: no wait on main's check runs (the entry's checks were the merge group's)" || bad "queue waited on main: $(calls)"
# the branch of a fork is never deleted; a refused delete is only a log line
reset; mqon; printf '{"state":"OPEN","mergeable":"MERGEABLE","title":"Fix the thing","headRefName":"b","isCrossRepository":true,"mergeCommit":null}\n' > "$FAKE_DIR/view.json"; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"; gq 1 MERGED "$QSHA"
release --run 80
[ "$rc" = 0 ] && ! called "-X DELETE" && called "^deploy.sh $" && ok "a PR from a fork: merged by the queue, deployed, its branch not touched" || bad "fork: rc=$rc calls=$(calls) $out"
reset; mqon; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"; gq 1 MERGED "$QSHA"; : > "$FAKE_DIR/delfail"
release --run 80
[ "$rc" = 0 ] && called "^deploy.sh $" && [[ "$out" == *"head branch b not deleted"* ]] && ok "a refused branch delete: one log line, the release goes on" || bad "delfail: rc=$rc $out"

echo "== GitHub's merge queue: a PR the queue removes, closes or keeps"
# removed after it was seen: believed on the second look without the entry, with GitHub's reason from the timeline
reset; mqon; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"; gq 1 OPEN - QUEUED 1; gq 2 OPEN -
echo '{"data":{"repository":{"pullRequest":{"timelineItems":{"nodes":[{"reason":"FAILED_CHECKS","createdAt":"2099-01-01T00:00:00Z"}]}}}}}' > "$FAKE_DIR/reason.json"
release --run 81
[ "$rc" = 1 ] && ! called "^deploy.sh $" && ! called "pr merge" && ! called "-X DELETE" \
    && [[ "$(msgs)" == *"[release] PR #81 FAILED at merge queue: removed from the merge queue: the merge group failed its required checks; nothing was merged or deployed"* ]] \
    && ok "removed from the queue: exit 1, the reason GitHub gave in the message, nothing deployed or deleted" || bad "removed: rc=$rc calls=$(calls) msgs=$(msgs) $out"
# an entry that never showed: three looks
reset; mqon; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"; gq 1 OPEN -
release --run 82
[ "$rc" = 1 ] && ! called "^deploy.sh $" && [[ "$(msgs)" == *"FAILED at merge queue: the PR did not show in the merge queue after the enqueue call and is not merged; nothing was merged or deployed"* ]] \
    && ok "an entry that never shows: failed after three looks, nothing deployed" || bad "never showed: rc=$rc msgs=$(msgs) $out"
# a PR merged a moment after its entry was gone is merged, not removed
reset; mqon; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"; gq 1 OPEN - QUEUED 1; gq 2 OPEN -; gq 3 MERGED "$QSHA"
release --run 83
[ "$rc" = 0 ] && called "^deploy.sh $" && ok "the entry gone for one look and then MERGED: carried on and deployed" || bad "vanish then merged: rc=$rc msgs=$(msgs) $out"
# closed while waiting
reset; mqon; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"; gq 1 CLOSED -
release --run 84
[ "$rc" = 1 ] && ! called "^deploy.sh $" && [[ "$(msgs)" == *"FAILED at pr state: the PR was closed while it waited for the merge queue"* ]] && ok "closed while waiting: failed at pr state" || bad "closed: rc=$rc msgs=$(msgs) $out"
# still in the queue at the end of the wait: it may merge later; --merged deploys it
reset; mqon; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"; gq 1 OPEN - QUEUED 1
SALA_RELEASE_QUEUE_WAIT=2 release --run 85
[ "$rc" = 1 ] && ! called "^deploy.sh $" && [[ "$(msgs)" == *"FAILED at merge queue: still in the queue or not merged 0 min after the enqueue"* ]] && [[ "$(msgs)" == *"release.sh --merged 85 deploys it"* ]] \
    && ok "still queued at the end of the wait: failed, nothing deployed, the message names release.sh --merged" || bad "queue wait: rc=$rc msgs=$(msgs) $out"
# GitHub merged it after all: the merged mode deploys it, no queue call at all
reset; mqon; view MERGED "" "{\"oid\":\"$QSHA\"}"; cruns 1 "${PASS3[@]}"
release --run --merged 85
[ "$rc" = 0 ] && called "^deploy.sh $" && ! called "graphql" && ok "an already merged PR is deployed as before and never asks GitHub about the queue" || bad "merged after the wait: rc=$rc calls=$(calls) $out"

echo "== GitHub's merge queue: the enqueue call"
reset; mqon; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"; gq 1 OPEN -; : > "$FAKE_DIR/enqfail"
release --run 86
[ "$rc" = 1 ] && ! called "^deploy.sh $" && [[ "$(msgs)" == *"FAILED at merge: the merge queue refused the PR: Required status check missing"* ]] && ok "the enqueue refused and the PR not in the queue: failed with GitHub's message" || bad "enq refused: rc=$rc msgs=$(msgs) $out"
reset; mqon; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"; gq 1 OPEN - QUEUED 2; gq 2 MERGED "$QSHA"; : > "$FAKE_DIR/enqfail"
release --run 86
[ "$rc" = 0 ] && called "^deploy.sh $" && [[ "$out" == *"the enqueue call errored (Required status check missing) but the PR is OPEN, in the merge queue (QUEUED position 2): carrying on"* ]] \
    && ok "the enqueue errored but the PR is in the queue already (an earlier run, a 504): carried on and deployed" || bad "enq errored, queued: rc=$rc msgs=$(msgs) $out"

echo "== the way back and the switch: no queue on main, SALA_RELEASE_MERGE"
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"
release --run 87
[ "$rc" = 0 ] && called "gh pr merge 87 --repo o/r --merge --delete-branch --admin" && ! called "enqueuePullRequest" && called "mergeQueue(branch" && [[ "$(msgs)" != *"merge queue"* ]] \
    && ok "no merge queue on main (the ruleset is off): merged at once with --admin, as before, the queue never entered" || bad "no queue: rc=$rc calls=$(calls) msgs=$(msgs) $out"
reset; mqon; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"
SALA_RELEASE_MERGE=direct release --run 88
[ "$rc" = 0 ] && called "gh pr merge 88 --repo o/r --merge --delete-branch --admin" && ! called "graphql" && ok "SALA_RELEASE_MERGE=direct: GitHub is not asked about the queue, the PR is merged at once" || bad "direct: rc=$rc calls=$(calls) $out"
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"
SALA_RELEASE_MERGE=queue release --run 89
[ "$rc" = 1 ] && ! called "pr merge" && ! called "^deploy.sh $" && [[ "$(msgs)" == *"FAILED at merge queue: SALA_RELEASE_MERGE=queue, and main has no merge queue"* ]] && ok "SALA_RELEASE_MERGE=queue with no queue on main: failed, nothing merged" || bad "queue-only: rc=$rc msgs=$(msgs) $out"
reset; mqon; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"; gq 1 MERGED "$QSHA"
SALA_RELEASE_MERGE=queue release --run 89
[ "$rc" = 0 ] && ! called "pr merge" && called "^deploy.sh $" && ok "SALA_RELEASE_MERGE=queue with a queue on main: the queue path" || bad "queue-only ok: rc=$rc $out"
reset; view OPEN MERGEABLE null; prhead 1 "$SHA"; cruns 1 "${PASS3[@]}"; : > "$FAKE_DIR/gqfail"
release --run 90
[ "$rc" = 1 ] && ! called "pr merge" && ! called "^deploy.sh $" && [[ "$(msgs)" == *"FAILED at merge: GitHub's answer about main's merge queue and the PR cannot be read"* ]] && [[ "$(msgs)" == *"SALA_RELEASE_MERGE=direct merges at once"* ]] \
    && ok "GitHub's queue answer unreadable: failed before any merge, the message names the direct switch" || bad "gq unreadable: rc=$rc msgs=$(msgs) $out"
out=$(SALA_RELEASE_MERGE=sideways bash "$CO/release.sh" --status 2>&1); rc=$?
[ "$rc" = 2 ] && [[ "$out" == *"SALA_RELEASE_MERGE is 'sideways': auto, direct or queue"* ]] && ok "a bad SALA_RELEASE_MERGE: exit 2 with the three values" || bad "bad mode: rc=$rc $out"

echo "== the start: a transient unit that runs the steps (systemd-run is a fake; nothing starts)"
reset; release 20
[ "$rc" = 0 ] && called "systemd-run .*--unit salamander-release-20 .*release.sh --run 20\$" && ok "release.sh <pr>: one unit running --run <pr> (it finds a merged PR itself)" || bad "start: rc=$rc calls=$(calls) $out"
reset; release --merged 21
[ "$rc" = 0 ] && called "release.sh --run --merged 21\$" && [[ "$out" == *"deploys the already merged PR #21"* ]] && ok "release.sh --merged <pr>: the unit runs --run --merged <pr>" || bad "start --merged: rc=$rc calls=$(calls) $out"

echo "== usage"
release; [ "$rc" = 2 ] && [[ "$out" == *"--merged <pr>"* ]] && [[ "$out" == *"ALREADY MERGED"* ]] && ok "no argument: the header with the merged mode, exit 2" || bad "help: rc=$rc $out"
release --merged; [ "$rc" = 2 ] && [[ "$out" == *"usage: release.sh [--merged] <pr>"* ]] && ok "--merged without a pr: the usage line, exit 2" || bad "usage: rc=$rc $out"
release --run --merged; [ "$rc" = 2 ] && [[ "$out" == *"usage: release.sh --run [--merged] <pr>"* ]] && ok "--run --merged without a pr: its usage line, exit 2" || bad "run usage: rc=$rc $out"

[ "$fail" = 0 ]
