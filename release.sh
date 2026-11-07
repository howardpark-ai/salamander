#!/usr/bin/env bash
# release.sh — merge a PR and deploy it, detached: the releaser starts it and leaves, and the result comes back as one
# stackshot message to projects/salamander (modelled on stackshot's). Runs on the production machine, from the production
# checkout (~/salamander), which sala runs from directly.
#
#   ./release.sh <pr>             start: a transient user unit (salamander-release-<pr>) runs the steps below; prints the unit
#                                 and the log path, returns at once. A PR that is ALREADY MERGED (by hand, or by a merge helper:
#                                 main moved but the production checkout was not deployed) is found at step 1 and released the
#                                 other way, below
#   ./release.sh --merged <pr>    the same start, but the PR must already be merged: an open one is refused, never merged
#   ./release.sh --status [<pr>]  the unit's state and the log's tail (the latest release when no pr is given)
#   ./release.sh --run [--merged] <pr>
#                                 the steps themselves (what the unit runs):
#                                 1. the PR is open and mergeable; 2. the production checkout has not drifted
#                                 (./deploy.sh --check), so a merge never lands where it cannot be deployed; 3. its checks
#                                 pass (waits up to 45 min for a pending one, looking every SALA_RELEASE_POLL s, 60 by default); 4. `gh pr merge --merge --delete-branch --admin`;
#                                 5. ./deploy.sh (drift check, fast-forward, bash -n, install.sh when needed; waits up to
#                                 15 min for a recycle that holds the recycle lock); 6. one message to projects/salamander:
#                                 green with the PR, the commit and what changed, or red with the step that failed and the log.
#                                 The live release is also reported to stackshot (`client.py released --pr <PR url> --sha <merge commit>`, just
#                                 before that message), which settles the items whose step is `release PR #N`; stackshot refuses it until its
#                                 server accepts this repo (then it is only logged), and it never fails the release.
#   An already merged PR (state MERGED at step 1) skips the mergeable test and step 4, and step 3 waits instead for the check
#   runs on the PR's merge commit on main (`gh api repos/<repo>/commits/<sha>/check-runs`, the same 45 min; all must
#   pass, a failing one stops the release before the deploy). When none show up it waits a 2 min grace, then goes on only if
#   GitHub lists no workflow run for that commit at all (`actions/runs?head_sha=<sha>`). The message says it was already merged.
#   A check is judged by its newest run: when one commit carries several runs of the same check (same app and name; a
#   workflow run again after the PR body was edited, a re-run), only the newest (highest check-run id) counts, an older run is ignored
#   whether it passed or failed; a newest run still going still waits, a newest one that failed still fails.
#   The CI-run poller: while the file `salamander ci-poll` keeps for this repo (<state>/ci-runs/<owner>__<repo>.json, docs/ci-runs.md)
#   is fresh (SALA_RELEASE_CIFILE_MAX_AGE s, 120; 0 = ignore it) and shows a workflow run of the commit still going, the loop waits on it and
#   makes no check-runs call. It only ever says "still going": a finished run, no run of the sha, a missing or stale file all go to the
#   check-runs read below, which alone decides pass or fail, so the file can make a release wait longer but never pass or fail it earlier.
#   GitHub's API budget: the checks are read with `gh api -i` and the url's last ETag (If-None-Match), so a 304, which
#   GitHub does not count against the owner's 5,000 calls an hour, costs nothing; an open PR's checks are the check runs of its head
#   commit (`pulls/<pr>` for the head, then `commits/<head>/check-runs`), not `gh pr checks`. Every read is kept per url in
#   <state>/gh-cache and reused for SALA_RELEASE_GH_TTL s (the poll interval) by every release on the box, under a flock, so
#   six releases waiting on one commit read it once a minute between them, never more than once per interval per url.
#
# Never restarts the tmux server, a session or a unit of sala's (deploy.sh does not either; the web app's sala-web.service
# is the one unit deploy.sh restarts, for a file under web/). Log: ~/.local/state/salamander/releases/pr-<n>.log
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; cd "$HERE"
REPO="$(git remote get-url origin | sed -E 's#(git@github.com:|https://github.com/|ssh://git@github.com/)##; s#\.git$##')"
LOGDIR="${XDG_STATE_HOME:-$HOME/.local/state}/salamander/releases"; mkdir -p "$LOGDIR"
# stackshot's client: STACKSHOT_CLIENT, else SALA_STACKSHOT_DIR/client.py (from the environment only: this script reads no config;
# unset: ~/stackshot; set empty: no stackshot, nothing is sent and each message is only logged)
SS_DIR="${SALA_STACKSHOT_DIR-$HOME/stackshot}"
CLIENT="${STACKSHOT_CLIENT:-${SS_DIR:+$SS_DIR/client.py}}"
WAIT_CHECKS="${SALA_RELEASE_WAIT:-2700}"   # 45 min: a runner may queue jobs, and a PR's suites can queue behind other PRs' and smoke runs
POLL="${SALA_RELEASE_POLL:-60}"      # seconds between two looks at the checks (was 20; every look is GitHub REST calls from the owner's 5,000 an hour, shared by every tool and agent on the box)
GH_CACHE="$LOGDIR/gh-cache"          # the checks reads below, kept per url (body + ETag) and shared by every release on this box
GH_TTL="${SALA_RELEASE_GH_TTL:-$POLL}"   # seconds a read is reused before GitHub is asked again: the poll interval, so a url is read at most once per interval however many releases wait on it (0 = never reuse; the tests set it)
GRACE="${SALA_RELEASE_GRACE:-120}"   # an already merged PR: how long main's commit may show no check run before "no workflow ran" is believed
CIFILE_MAX_AGE="${SALA_RELEASE_CIFILE_MAX_AGE:-120}"   # how old the CI-run poller's file (<state>/ci-runs/<owner>__<repo>.json) may be and still be believed about a run that is going; 0 = never use it
# ci_file_pending <sha>: exit 0 (and one line on stdout) when the poller's file for this repo is fresh and shows a workflow run of <sha> that has not completed; any other case (no file, stale, no run of the sha, all completed, no poller code in this checkout) exit 1: ask GitHub
ci_file_pending() { [ -f "$HERE/lib/cipoll.py" ] && python3 -I "$HERE/lib/cipoll.py" pending "$REPO" "$1" --max-age "$CIFILE_MAX_AGE" 2>/dev/null; }

# gh_read <REST path>: GET it with `gh api -i`, conditionally and shared. The answer is kept in $GH_CACHE per url with
# its ETag, under a flock on that url, so two releases asking for the same url one after the other make one call: the second finds
# the first's answer younger than GH_TTL s. Older, the ETag goes out as If-None-Match, and a 304 (which GitHub does not count against
# the 5,000 an hour; gh exits 1 on it, so the status line is read, not the exit status) gives the kept body back and renews its age.
# A failed call prints one line on stderr (the log) and returns 1, with nothing on stdout.
gh_read() {
    GH_CACHE="$GH_CACHE" GH_TTL="$GH_TTL" python3 -c '
import fcntl, hashlib, os, re, subprocess, sys, time
path, cd, ttl = sys.argv[1], os.environ["GH_CACHE"], float(os.environ.get("GH_TTL") or 0)
os.makedirs(cd, mode=0o700, exist_ok=True)
base = os.path.join(cd, hashlib.sha1(path.encode()).hexdigest())
lk = open(base + ".lock", "a")
fcntl.flock(lk, fcntl.LOCK_EX)              # one reader per url at a time; the lock goes with the process
def rd(p):
    try:
        with open(p, encoding="utf-8") as f: return f.read()
    except OSError: return None
body, etag = rd(base + ".body"), (rd(base + ".etag") or "").strip()
if body is not None and ttl > 0:
    try:
        if time.time() - os.stat(base + ".body").st_mtime < ttl: sys.stdout.write(body); sys.exit(0)
    except OSError: pass
cmd = ["gh", "api", path, "-i"] + (["-H", "If-None-Match: " + etag] if body is not None and etag else [])
try: r = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
except Exception as e: print("gh_read %s: %s" % (path, type(e).__name__), file=sys.stderr); sys.exit(1)
sep = "\r\n\r\n" if "\r\n\r\n" in r.stdout else "\n\n"
head, _, rest = r.stdout.partition(sep)
m = re.match(r"HTTP/\S+\s+(\d+)", head)
status = int(m.group(1)) if m else 0
if status == 304 and body is not None:
    os.utime(base + ".body", None); sys.stdout.write(body); sys.exit(0)
if status == 200 and rest.strip():
    em = re.search(r"^etag:\s*(.+?)\s*$", head, re.I | re.M)
    for suffix, text in ((".body", rest), (".etag", em.group(1) if em else "")):
        t = "%s%s.%d.tmp" % (base, suffix, os.getpid())
        with open(t, "w", encoding="utf-8") as f: f.write(text)
        os.replace(t, base + suffix)
    for n in os.listdir(cd):                # answers older than an hour go (a lock file a day: it is never unlinked under a holder): the folder stays a few files
        q = os.path.join(cd, n)
        try:
            if time.time() - os.stat(q).st_mtime > (86400 if n.endswith(".lock") else 3600): os.unlink(q)
        except OSError: pass
    sys.stdout.write(rest); sys.exit(0)
print("gh_read %s: HTTP %s %s" % (path, status or "?", "".join((r.stderr or "").strip().splitlines()[-1:])), file=sys.stderr); sys.exit(1)
' "$1"
}

say() { echo "$(date -u +%FT%TZ) $*"; }
tell() {  # one message to the project; never fails the run
    [ -n "$CLIENT" ] && python3 "$CLIENT" message projects/salamander "$1" --sender release >/dev/null 2>&1 || say "message not sent: $1"
}

# report_live <pr> <merge commit>: the release is live, so tell stackshot (client.py released --pr <PR url> --sha <merge commit>): the server settles
# the open items whose step is `release PR #N` (closes one whose only open step it is, ticks the step of another and tells its mover). A repo
# stackshot does not accept yet is refused by it, which is only a log line here. Never fails the run: no client, a refusal or an unreachable
# server is one line in the log, and the one `tell` after it still goes out. The fds above 4 are closed for the client, as stackshot's own release.sh does.
report_live() {
    local out
    if [ -z "$CLIENT" ]; then say "stackshot not configured: live release not reported"; return 0; fi
    if out="$(python3 "$CLIENT" released --pr "https://github.com/$REPO/pull/$1" --sha "$2" 2>&1 9>&- 8>&- 7>&- 6>&- 5>&-)"; then
        say "items of PR #$1: $(echo "$out" | sed 's/^stackshot: //' | paste -sd ';' -)"
    else
        out="$(echo "$out" | tr '\n' ' ')"; say "live release not reported to stackshot: ${out:0:300}"
    fi
    return 0
}

run() {
    local pr="$1" want_merged="${2:-}" log="$LOGDIR/pr-$1.log" title sha changed live_sha
    exec > >(tee -a "$log") 2>&1
    say "release of PR #$pr starts in $HERE ($REPO)"
    fail() { say "FAILED at $1: $2"; tell "[release] PR #$pr FAILED at $1: $2 · log $log"; exit 1; }
    # UNKNOWN is GitHub still computing mergeability (right after another merge to main): ask again, up to 2 min
    local view tries=0
    while :; do
        view="$(gh pr view "$pr" --repo "$REPO" --json state,mergeable,title,headRefName,mergeCommit 2>&1)" || fail "pr view" "$(echo "$view" | tail -1)"
        echo "$view" | grep -q '"state":"OPEN"' && echo "$view" | grep -q '"mergeable":"UNKNOWN"' && [ "$tries" -lt 12 ] || break
        tries=$((tries + 1)); sleep 10
    done
    title="$(echo "$view" | python3 -c 'import json,sys; print(json.load(sys.stdin)["title"])')"
    local state mergeable; state="$(echo "$view" | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])')"; mergeable="$(echo "$view" | python3 -c 'import json,sys; print(json.load(sys.stdin)["mergeable"])')"
    # MERGED: somebody merged it already (by hand, a merge helper), so main moved and the production checkout may not have
    # followed. The merge is skipped and the checks that matter are the ones on main's merge commit.
    local mode=open merge_sha= msha= what=checks
    if [ "$state" = MERGED ]; then
        mode=merged
        merge_sha="$(echo "$view" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("mergeCommit") or {}).get("oid") or "")')"
        [ -n "$merge_sha" ] || fail "merge commit" "the PR is MERGED but GitHub names no merge commit"
        msha="${merge_sha:0:7}"; what="checks on main ($msha)"
    elif [ -n "$want_merged" ]; then
        fail "pr state" "the PR is $state, not merged (--merged is for a PR somebody already merged; release.sh <pr> merges an open one)"
    else
        [ "$state" = OPEN ] || fail "pr state" "the PR is $state"
        [ "$mergeable" = MERGEABLE ] || fail "mergeable" "GitHub says $mergeable (a conflict with main, or still computing)"
    fi
    say "PR #$pr: $title$([ "$mode" = merged ] && echo " (already merged as $msha)")"
    local out; out="$(./deploy.sh --check 2>&1)" || { echo "$out"; fail "drift" "the production checkout has drifted, so nothing was $([ "$mode" = merged ] && echo deployed || echo merged): $(echo "$out" | sed -n 2p | sed 's/^ *//')"; }
    say "production checkout clean"
    # The buckets gh pr checks sorts a check into: pass, fail, pending, skipping, cancel. A job tests.yml's `changes` job
    # did not need (the web tests for a sala change, the suites for a web-only one) reports as skipping, which is a
    # verdict: it counts as neither a pass nor a pending. Only a pass settles the PR, so a PR whose every check were
    # skipped would wait like one with none (it cannot happen while `changes` itself reports, but a gate that merges on
    # nothing is the wrong default).
    local waited=0 checks head_sha
    while :; do
        # Conditional, shared reads: gh_read sends the url's last ETag, a 304 is not counted by GitHub, and a read made
        # in the last GH_TTL s by any release on this box is reused. An open PR: its head commit (the PR can be pushed to while it
        # waits) and then that commit's check runs, which is what `gh pr checks` listed, in the same buckets.
        if [ "$mode" = merged ]; then head_sha="$merge_sha"
        else head_sha="$(gh_read "repos/$REPO/pulls/$pr" | python3 -c '
import json,sys
try: print(json.load(sys.stdin)["head"]["sha"])
except Exception: print("")')" || head_sha=""
        fi
        if [ -z "$head_sha" ]; then checks="[]"
        elif ci_note="$(ci_file_pending "$head_sha")"; then
            # the CI-run poller's file (lib/cipoll.py) shows a workflow run of this commit still going, so there is nothing to
            # ask GitHub: wait, exactly as a pending check run would make this loop wait. Only a "still going" can come from the file; a
            # finished, absent or stale answer falls to the check-runs read below, which alone gives a pass or a fail.
            say "$what: $ci_note; waiting on the ci-runs file, no GitHub call"
            checks='[{"name":"ci-runs file","bucket":"pending"}]'
        else
            # a check run put into gh pr checks' buckets: not completed = pending; success = pass; neutral and skipped = skipping;
            # cancelled = cancel; anything else (failure, timed_out, …) = fail
            checks="$(gh_read "repos/$REPO/commits/$head_sha/check-runs?per_page=100" | python3 -c '
import json,sys
try: runs=json.load(sys.stdin)["check_runs"]
except Exception: runs=[]
def bucket(r):
    if r.get("status")!="completed": return "pending"
    c=r.get("conclusion")
    return "pass" if c=="success" else "skipping" if c in ("neutral","skipped") else "cancel" if c=="cancelled" else "fail"
# a check is judged by its newest run only: the same check (app + name) can have several runs on one commit (a
# workflow run again after the PR body was edited, a re-run), and an older one, passed or failed, is superseded
newest={}
for r in runs:
    k=((r.get("app") or {}).get("id"),r.get("name",""))
    t=(r.get("id") or 0,r.get("started_at") or "")   # ids grow with creation, and a queued run has no started_at yet; the start time orders only runs with no id
    if k not in newest or t>=newest[k][0]: newest[k]=(t,r)
print(json.dumps([{"name":r.get("name",""),"bucket":bucket(r)} for t,r in newest.values()]))')" || checks="[]"
        fi
        local verdict; verdict="$(echo "$checks" | python3 -c '
import json,sys
cs=json.load(sys.stdin)
b={c["bucket"] for c in cs}
print("fail" if "fail" in b or "cancel" in b else "pending" if "pending" in b else "pass" if "pass" in b else "none")')"
        case "$verdict" in
            pass) say "$what pass: $(echo "$checks" | python3 -c '
import json,sys
cs=json.load(sys.stdin)
passed=[c["name"] for c in cs if c["bucket"]=="pass"]; skipped=[c["name"] for c in cs if c["bucket"]=="skipping"]
print(", ".join(passed) + ("; skipped, not needed by this change: " + ", ".join(skipped) if skipped else ""))')"; break ;;
            none) say "no check with a verdict yet$(echo "$checks" | python3 -c 'import json,sys; cs=json.load(sys.stdin); print(" (skipped: "+", ".join(c["name"] for c in cs)+")" if cs else "")')"
                # main's commit with no check run at all: believed only after the grace, and only when GitHub also lists no
                # workflow run for the commit (a run that was queued but has no job yet keeps the wait going)
                if [ "$mode" = merged ] && [ $waited -ge "$GRACE" ]; then
                    local nruns; nruns="$(gh_read "repos/$REPO/actions/runs?head_sha=$merge_sha&per_page=1" | python3 -c '
import json,sys
try: print(int(json.load(sys.stdin)["total_count"]))
except Exception: print("?")')"
                    [ "$nruns" = 0 ] && { say "no workflow run on $msha either: nothing to wait for"; break; }
                fi ;;
            fail) fail "checks" "a check failed$([ "$mode" = merged ] && echo " on main ($msha), so nothing was deployed"): $(echo "$checks" | python3 -c 'import json,sys; print(", ".join(c["name"]+"="+c["bucket"] for c in json.load(sys.stdin)))')" ;;
        esac
        [ $waited -lt $WAIT_CHECKS ] || fail "checks" "still pending after $((WAIT_CHECKS/60)) min$([ "$mode" = merged ] && echo " on main ($msha), so nothing was deployed")"
        sleep "$POLL"; waited=$((waited+POLL))
    done
    if [ "$mode" = merged ]; then
        say "PR #$pr was already merged (main's commit $msha); no merge, on to the deploy"
    else
        # --admin: a ruleset limits who may update branches, so GitHub reports the PR as BLOCKED and gh refuses a plain merge client-side.
        # It does not skip the required checks (administrators are not exempt from them): a failing or unfinished one still refuses it.
        out="$(gh pr merge "$pr" --repo "$REPO" --merge --delete-branch --admin 2>&1)" || fail "merge" "$(echo "$out" | tail -1)"
        say "merged"
    fi
    out="$(SALA_DEPLOY_LOCK_WAIT=900 ./deploy.sh 2>&1)"; local rc=$?; echo "$out"
    sha="$(git rev-parse --short HEAD)"
    [ $rc -eq 0 ] || fail "deploy" "$(echo "$out" | tail -1) (main is merged; the production checkout is at $sha; run ./deploy.sh there once the cause is fixed)"
    changed="$(echo "$out" | sed -n 's/^changed: //p' | tail -1)"; changed="${changed:-see the log}"
    say "done: $sha — $changed"
    # the PR's merge commit: main's commit when it was already merged, else what GitHub names after our merge, else the first-parent
    # merge in this checkout (the deploy just fast-forwarded it to main)
    live_sha="$merge_sha"
    if [ -z "$live_sha" ]; then
        live_sha="$(gh pr view "$pr" --repo "$REPO" --json mergeCommit --jq '.mergeCommit.oid // empty' 2>/dev/null)"; [ "$live_sha" = null ] && live_sha=
        [ -n "$live_sha" ] || live_sha="$(git -C "$HERE" log --first-parent --merges --format=%H --grep "Merge pull request #$pr from" -n1 2>/dev/null)"
    fi
    if [ -n "$live_sha" ]; then report_live "$pr" "$live_sha"; else say "live release not reported to stackshot: neither GitHub nor this checkout names the merge commit of PR #$pr"; fi
    tell "[release] PR #$pr merged and deployed$([ "$mode" = merged ] && echo " (it was already merged; the checks on main passed)") — $title — main at $sha; changed: $changed · log $log"
}

case "${1:-}" in
    --run)
        shift; want_merged=; [ "${1:-}" = --merged ] && { want_merged=1; shift; }
        [[ "${1:-}" =~ ^[0-9]+$ ]] || { echo "usage: release.sh --run [--merged] <pr>" >&2; exit 2; }; run "$1" "$want_merged" ;;
    --status)
        pr="${2:-}"; [ -n "$pr" ] || pr="$(ls -t "$LOGDIR"/pr-*.log 2>/dev/null | head -1 | sed -E 's/.*pr-([0-9]+)\.log/\1/')"
        [ -n "$pr" ] || { echo "no release yet"; exit 0; }
        st="$(systemctl --user is-active "salamander-release-$pr.service" 2>/dev/null)"   # prints "inactive" and exits 3 once the unit is gone
        case "$st" in active|activating|deactivating) ;; *) st=finished ;; esac
        echo "unit salamander-release-$pr: $st"
        tail -n 15 "$LOGDIR/pr-$pr.log" 2>/dev/null ;;
    ''|-h|--help) sed -n '2,27p' "$0"; exit 2 ;;
    *)
        flag=; [ "$1" = --merged ] && { flag=--merged; shift; }
        pr="${1:-}"; [[ "$pr" =~ ^[0-9]+$ ]] || { echo "usage: release.sh [--merged] <pr> | --status [pr] | --run [--merged] <pr>" >&2; exit 2; }
        if systemctl --user is-active --quiet "salamander-release-$pr.service" 2>/dev/null; then echo "release of PR #$pr is already running (release.sh --status $pr)"; exit 1; fi
        systemd-run --user --quiet --collect --unit "salamander-release-$pr" -p WorkingDirectory="$HERE" \
            --setenv=PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" "$HERE/release.sh" --run $flag "$pr"     # gh and python3 as the shell sees them
        echo "started salamander-release-$pr: $([ -n "$flag" ] && echo "deploys the already merged PR #$pr once the checks on main pass" || echo "merges PR #$pr when its checks pass (an already merged one is only deployed)"), and reports to projects/salamander · log $LOGDIR/pr-$pr.log" ;;
esac
