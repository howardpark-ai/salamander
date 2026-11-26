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
#   Step 4 has two ways, chosen by what GitHub says about main (SALA_RELEASE_MERGE: auto, the default; direct; queue). With NO merge queue on main
#   (the ruleset is off or disabled) the PR is merged at once as above. With GitHub's merge queue ON, `gh pr merge` cannot merge it (it asks for auto-merge,
#   which this repository does not allow): the PR is put in the queue (GraphQL enqueuePullRequest, pinned to the head the checks passed on), the release waits
#   for GitHub to merge it (SALA_RELEASE_QUEUE_WAIT s, 7200 by default; the queue tests the entry on its own branch with tests.yml's merge_group run), deletes the
#   branch, and deploys the merge commit GitHub made. A PR the queue removes (but for ONE RETRY, below), closes or leaves waiting fails the release, nothing deployed (a PR
#   that merges after the wait gave up is deployed by `release.sh --merged <pr>`). `direct` never asks GitHub and always merges at once (--admin); `queue` fails
#   when main has no queue. docs/merge-queues.md.
#   ONE RETRY of the queue, once per release run: a PR removed because the merge group failed its required checks (GitHub's removal reason `failed_checks`, no
#   other) is put in the queue again when all of this, read again after the removal, holds: the merge group GitHub removed it with was built from the queued head
#   and shows a failed job of a workflow run; the PR is open, not a draft and mergeable; its head is still the queued commit; its own checks pass; main still has
#   the queue. When one does not hold the release fails as for any removal, the line ending "not queued again: <why>". No retry for a conflict, a removal by hand,
#   any other reason or none, a closed PR, the queue wait running out, a refused or errored enqueue call, or a deploy. Nothing is hidden by it: the log names the
#   failed run (id and url) and its failed jobs and says the PR is queued again, the final report says it was queued twice (a later failure's line says so too),
#   and a second drop for failed checks fails the release naming both runs. SALA_RELEASE_QUEUE_WAIT counts for each of the two passes from its own enqueue, so a
#   release waits at most twice that for the queue.
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
#   The Codex trial review: right after step 1 finds the PR OPEN (never for an already merged PR or `--merged`), `salamander codex-review <repo> <pr>` is
#   started detached (its own transient unit salamander-codex-review-<pr>-<time>, else `setsid nohup`) with its output in <state>/releases/codex-review-pr-<pr>.log,
#   and never waited for: it is a second opinion posted as a PR comment (docs/codex-review.md), and neither its start failing nor its run can change this
#   script's steps or exit status. One line in the release log says it was started or why not.
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
# stackshot's client: STACKSHOT_CLIENT, else stackshot/fleet/client.py under SALA_STACKSHOT_DIR (client.py there on an older checkout: lib/stackshot-path.sh; from the environment only: this script reads no config;
# unset: ~/stackshot; set empty: no stackshot, nothing is sent and each message is only logged)
SS_DIR="${SALA_STACKSHOT_DIR-$HOME/stackshot}"
. "$HERE/lib/stackshot-path.sh"
stackshot_prog_r _SS_CLIENT "$SS_DIR" client
CLIENT="${STACKSHOT_CLIENT:-$_SS_CLIENT}"
WAIT_CHECKS="${SALA_RELEASE_WAIT:-2700}"   # 45 min: a runner may queue jobs, and a PR's suites can queue behind other PRs' and smoke runs
POLL="${SALA_RELEASE_POLL:-60}"      # seconds between two looks at the checks (was 20; every look is GitHub REST calls from the owner's 5,000 an hour, shared by every tool and agent on the box)
GH_CACHE="$LOGDIR/gh-cache"          # the checks reads below, kept per url (body + ETag) and shared by every release on this box
GH_TTL="${SALA_RELEASE_GH_TTL:-$POLL}"   # seconds a read is reused before GitHub is asked again: the poll interval, so a url is read at most once per interval however many releases wait on it (0 = never reuse; the tests set it)
GRACE="${SALA_RELEASE_GRACE:-120}"   # an already merged PR: how long main's commit may show no check run before "no workflow ran" is believed
CIFILE_MAX_AGE="${SALA_RELEASE_CIFILE_MAX_AGE:-120}"   # how old the CI-run poller's file (<state>/ci-runs/<owner>__<repo>.json) may be and still be believed about a run that is going; 0 = never use it
MERGE_MODE="${SALA_RELEASE_MERGE:-auto}"   # step 4: auto (ask GitHub whether main has a merge queue), direct (never ask: always `gh pr merge --admin`), queue (the queue or a failure)
QUEUE_WAIT="${SALA_RELEASE_QUEUE_WAIT:-7200}"   # seconds a PR may stay in GitHub's merge queue, per pass (the one retry is a second pass), before the release gives up waiting (an entry's checks time out well before)
case "$MERGE_MODE" in auto|direct|queue) ;; *) echo "SALA_RELEASE_MERGE is '$MERGE_MODE': auto, direct or queue" >&2; exit 2 ;; esac
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

# checks_of <sha>: the commit's check runs as JSON [{name, bucket, url}], put into gh pr checks' buckets: not completed = pending; success = pass; neutral and
# skipped = skipping; cancelled = cancel; anything else (failure, timed_out, …) = fail. A check is judged by its newest run only: the same check (app + name) can
# have several runs on one commit (a workflow run again after the PR body was edited, a re-run), and an older one, passed or failed, is superseded. An unreadable
# answer prints [] and returns non-zero.
checks_of() {
    gh_read "repos/$REPO/commits/$1/check-runs?per_page=100" | python3 -c '
import json,sys
try: runs=json.load(sys.stdin)["check_runs"]
except Exception: runs=[]
def bucket(r):
    if r.get("status")!="completed": return "pending"
    c=r.get("conclusion")
    return "pass" if c=="success" else "skipping" if c in ("neutral","skipped") else "cancel" if c=="cancelled" else "fail"
newest={}
for r in runs:
    k=((r.get("app") or {}).get("id"),r.get("name",""))
    t=(r.get("id") or 0,r.get("started_at") or "")   # ids grow with creation, and a queued run has no started_at yet; the start time orders only runs with no id
    if k not in newest or t>=newest[k][0]: newest[k]=(t,r)
print(json.dumps([{"name":r.get("name",""),"bucket":bucket(r),"url":r.get("details_url") or r.get("html_url") or ""} for t,r in newest.values()]))'
}
# checks_verdict: checks_of's JSON on stdin → fail | pending | pass | none (no check, or only skipped ones)
checks_verdict() {
    python3 -c '
import json,sys
cs=json.load(sys.stdin)
b={c["bucket"] for c in cs}
print("fail" if "fail" in b or "cancel" in b else "pending" if "pending" in b else "pass" if "pass" in b else "none")'
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

# ---- GitHub's merge queue (step 4). release.sh puts the PR in (the enqueuePullRequest mutation; a second time only for the one retry below) and only reads the queue's
# state; it never takes a PR out of it. The three reads are GraphQL, one call each, from the same hourly budget as the rest; none is cached.
# ghq_target <pr>: $gq_mq = 1 when main has a merge queue (the ruleset is on), 0 when not; $gq_prid = the PR's node id. 1 when GitHub's answer cannot be read.
ghq_target() {
    local out
    out="$(gh api graphql -f query='query($o:String!,$n:String!,$p:Int!){repository(owner:$o,name:$n){mergeQueue(branch:"main"){id} pullRequest(number:$p){id}}}' \
        -f o="${REPO%%/*}" -f n="${REPO##*/}" -F p="$1" 2>/dev/null)" || return 1
    out="$(echo "$out" | python3 -c '
import json, sys
try:
    r = json.load(sys.stdin)["data"]["repository"]
    print(1 if r.get("mergeQueue") else 0, r["pullRequest"]["id"])
except Exception: sys.exit(1)' 2>/dev/null)" || return 1
    read -r gq_mq gq_prid <<< "$out"
    [[ "$gq_mq" =~ ^[01]$ ]] && [ -n "$gq_prid" ] || { gq_mq=""; return 1; }
}
# ghq_read <pr>: $gq_state (OPEN | MERGED | CLOSED), $gq_oid (the merge commit, "" until there is one), $gq_entry ("" when the PR is not in the queue, else "<STATE> position <n>"). 1 when the answer cannot be read.
ghq_read() {
    local out es ep
    out="$(gh api graphql -f query='query($o:String!,$n:String!,$p:Int!){repository(owner:$o,name:$n){pullRequest(number:$p){state mergeCommit{oid} mergeQueueEntry{state position}}}}' \
        -f o="${REPO%%/*}" -f n="${REPO##*/}" -F p="$1" 2>/dev/null)" || return 1
    out="$(echo "$out" | python3 -c '
import json, sys
try:
    p = json.load(sys.stdin)["data"]["repository"]["pullRequest"]
    e = p.get("mergeQueueEntry") or {}
    pos = e.get("position")
    print(p["state"], (p.get("mergeCommit") or {}).get("oid") or "-", e.get("state") or "-", "-" if pos is None else pos)
except Exception: sys.exit(1)' 2>/dev/null)" || return 1
    read -r gq_state gq_oid es ep <<< "$out"
    [ -n "$gq_state" ] || return 1
    [ "$gq_oid" != "-" ] || gq_oid=""
    if [ "$es" = "-" ] || [ -z "$es" ]; then gq_entry=""; else gq_entry="$es position $ep"; fi
}
# ghq_reason <pr> <epoch>: GitHub's latest removal of the PR from the queue (the timeline's RemovedFromMergeQueueEvent) dated at or after <epoch> (an older one belongs to an earlier enqueue):
# $gq_reason = the reason in words; $gq_checks = 1 only when GitHub's own reason is `failed_checks`, else 0; $gq_mg = the event's beforeCommit, which for such a removal is the commit the queue built
# and tested (the merge group), "-" when none; $gq_parents = that commit's parents, comma-separated, "-" when none; $gq_at = the event's epoch. 1 when there is none yet or it cannot be read.
# A word a log waiter looks for (" FAILED ", " done: ") is softened.
ghq_reason() {
    local out
    out="$(gh api graphql -f query='query($o:String!,$n:String!,$p:Int!){repository(owner:$o,name:$n){pullRequest(number:$p){timelineItems(last:10,itemTypes:[REMOVED_FROM_MERGE_QUEUE_EVENT]){nodes{... on RemovedFromMergeQueueEvent{reason createdAt beforeCommit{oid parents(first:5){nodes{oid}}}}}}}}}' \
        -f o="${REPO%%/*}" -f n="${REPO##*/}" -F p="$1" 2>/dev/null)" || return 1
    out="$(echo "$out" | SINCE="${2:-0}" python3 -c '
import json, os, re, sys, datetime
since = int(os.environ["SINCE"])
try: nodes = [x for x in json.load(sys.stdin)["data"]["repository"]["pullRequest"]["timelineItems"]["nodes"] if x]
except Exception: sys.exit(1)
def epoch(x):
    try: return int(datetime.datetime.fromisoformat(x["createdAt"].replace("Z", "+00:00")).timestamp())
    except Exception: return -1
nodes = sorted((n for n in nodes if epoch(n) >= since), key=epoch)
if not nodes: sys.exit(1)
WORDS = {"failed_checks": "the merge group failed its required checks", "merge_conflict": "a merge conflict with main", "manual": "removed from the queue by hand",
         "branch_protection_failure": "branch protection failed for the merge group"}
last = nodes[-1]
raw = " ".join((last.get("reason") or "no reason given").split())[:300]
def oid(c):
    v = str((c or {}).get("oid") or "")
    return v if re.fullmatch("[0-9a-f]{40}", v) else ""
try:
    group = last.get("beforeCommit") or {}
    mg, parents = oid(group), ",".join(filter(None, (oid(p) for p in (group.get("parents") or {}).get("nodes") or [])))
except Exception: mg, parents = "", ""
print(1 if raw.lower() == "failed_checks" else 0, mg or "-", parents or "-", epoch(last))
print(WORDS.get(raw.lower(), raw).replace(" FAILED ", " failed ").replace(" done: ", " done "))' 2>/dev/null)" || return 1
    { read -r gq_checks gq_mg gq_parents gq_at; IFS= read -r gq_reason; } <<< "$out"
}
# wait_queue <pr> <epoch of the enqueue call>: reads the PR every POLL s until it is MERGED (0, the merge commit in $merge_sha), or has left the queue without merging (1, the reason in $removed_why), or is CLOSED (2), or
# QUEUE_WAIT s have passed (3). GitHub shows a new entry a moment late and a merged PR a moment after its entry is gone, so "left the queue" is believed on the second look after the entry was seen,
# and "never showed" on the third look without it. A look that cannot be read is waited out like a pending one.
wait_queue() {
    local waited=0 seen=0 absent=0 said=-1
    gq_checks=0 gq_mg=- gq_parents=- gq_at=0
    while :; do
        if ghq_read "$1"; then
            case "$gq_state" in
                MERGED) if [ -n "$gq_oid" ]; then merge_sha="$gq_oid"; return 0; fi ;;
                CLOSED) return 2 ;;
            esac
            if [ -n "$gq_entry" ]; then seen=1; absent=0; else absent=$((absent + 1)); fi
            if [ "$gq_state" = OPEN ] && [ -z "$gq_entry" ] && [ "$absent" -ge $((seen ? 2 : 3)) ]; then
                if ghq_reason "$1" "$2"; then removed_why="removed from the merge queue: $gq_reason"
                elif [ "$seen" = 1 ]; then removed_why="left the merge queue, and GitHub's timeline gives no reason"
                else removed_why="the PR did not show in the merge queue after the enqueue call and is not merged"; fi
                return 1
            fi
            if [ -n "$gq_entry" ] && { [ "$said" -lt 0 ] || [ $((waited - said)) -ge 300 ]; }; then said=$waited; say "in the merge queue ($gq_entry): $((waited/60)) min since the enqueue, up to $((QUEUE_WAIT/60)) min"; fi
        fi
        [ "$waited" -lt "$QUEUE_WAIT" ] || return 3
        sleep "$POLL"; waited=$((waited + POLL))
    done
}

# enqueue <pr> <head>: put the PR in the queue, pinned to <head> (the node id is ghq_target's $gq_prid). Returns when GitHub accepted it, or when the call
# errored and the PR is queued or merged all the same; else fails the release (`fail` exits).
enqueue() {
    local pr="$1" head="$2" out enq_err
    if out="$(gh api graphql -f query='mutation($id:ID!,$h:GitObjectID!){enqueuePullRequest(input:{pullRequestId:$id,expectedHeadOid:$h}){mergeQueueEntry{state position}}}' -f id="$gq_prid" -f h="$head" 2>&1)" \
       && echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if not d.get("errors") and (d.get("data") or {}).get("enqueuePullRequest") else 1)' 2>/dev/null; then
        say "enqueued: the merge queue accepted the head ${head:0:7}"
        return 0
    fi
    # the call can error after the PR was queued or merged (a 504, a PR queued already by an earlier run of this release): read it once more before believing the error
    enq_err="$(echo "$out" | python3 -c '
import json, sys
lines = [l for l in sys.stdin.read().splitlines() if l.strip()]
msgs = []
for l in lines:
    try: msgs += [e.get("message", "") for e in (json.loads(l).get("errors") or [])]
    except Exception: pass
print("; ".join(m for m in msgs if m) or (lines[-1] if lines else "no answer"))' 2>/dev/null)"
    if ghq_read "$pr" && { [ "$gq_state" = MERGED ] || [ -n "$gq_entry" ]; }; then
        say "the enqueue call errored ($enq_err) but the PR is ${gq_state}${gq_entry:+, in the merge queue ($gq_entry)}: carrying on"
    else fail "merge" "the merge queue refused the PR: $enq_err"; fi
}

# ---- the one retry of the queue (the header, ONE RETRY). A drop for failed required checks is most often a flaky test: the same head passes the next time.
# Everything the retry rests on is read again. A job or check name comes from GitHub, so the words a log waiter looks for ("FAILED", "done:") are softened
# wherever one is written.
# mg_failed_run <commit>: what failed on the merge group's commit, read now: $mg_desc = "run <id> <url>, failed jobs: <names>[ (<n> still running when read)]".
# 1, with $mg_desc empty, when that cannot be read (3 tries) or no failed job of a workflow run is on it.
mg_failed_run() {
    local tries
    mg_desc=""
    [[ "$1" =~ ^[0-9a-f]{40}$ ]] || return 1
    for tries in 1 2 3; do
        mg_desc="$(GH_TTL=0 checks_of "$1" | python3 -c '
import json, re, sys
repo = sys.argv[1]
cs = json.load(sys.stdin)
bad = [c for c in cs if c["bucket"] == "fail"]
ids = sorted({m.group(1) for m in (re.search("/actions/runs/([0-9]+)", c["url"]) for c in bad) if m}, key=int)
if not ids: sys.exit(1)
names = sorted(" ".join(c["name"].split()).replace("FAILED", "failed").replace("done:", "done")[:60] for c in bad)
running = sum(c["bucket"] == "pending" for c in cs)
print(", ".join("run %s https://github.com/%s/actions/runs/%s" % (i, repo, i) for i in ids) + ", failed jobs: " + ", ".join(names[:8])
      + (" and %d more" % (len(names) - 8) if len(names) > 8 else "") + (" (%d still running when read)" % running if running else ""))' "$REPO")" && return 0
        mg_desc=""
        [ $tries = 3 ] || sleep "$((POLL < 10 ? POLL : 10))"
    done
    return 1
}
# retry_check <pr> <queued head>: may the PR, just removed for failed checks (ghq_reason's and mg_failed_run's answers in hand), go into the queue a second
# time? 0: yes, with $gq_prid read again for the enqueue. 1: no, with why in $retry_no. Anything that cannot be read is a no.
retry_check() {
    local pr="$1" head="$2" view vals state= mergeable= draft= oid= tries=0 checks verdict
    retry_no=""
    [[ ",$gq_parents," == *",$head,"* ]] || { retry_no="GitHub does not show the removed merge group as built from the queued head ${head:0:7}"; return 1; }
    [ -n "$mg_desc" ] || { retry_no="no failed job of a workflow run can be read on the merge group's commit"; return 1; }
    while :; do
        view="$(gh pr view "$pr" --repo "$REPO" --json state,mergeable,isDraft,headRefOid 2>/dev/null)" && vals="$(echo "$view" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(d["state"], d["mergeable"], "no" if d["isDraft"] is False else "yes", d["headRefOid"])' 2>/dev/null)" || vals=""
        read -r state mergeable draft oid <<< "$vals"
        # unreadable, or mergeability still being computed (main may just have moved): ask again
        { [ -z "$vals" ] || { [ "$state" = OPEN ] && [ "$mergeable" = UNKNOWN ]; }; } && [ "$tries" -lt 12 ] || break
        tries=$((tries + 1)); sleep "$((POLL < 10 ? POLL : 10))"
    done
    [ -n "$vals" ] || { retry_no="the PR cannot be read again"; return 1; }
    [ "$state" = OPEN ] || { retry_no="the PR is $state"; return 1; }
    [ "$draft" = no ] || { retry_no="the PR is a draft"; return 1; }
    [ "$oid" = "$head" ] || { retry_no="the PR head is now ${oid:0:7}, not the queued ${head:0:7}"; return 1; }
    [ "$mergeable" = MERGEABLE ] || { retry_no="GitHub says $mergeable (a conflict with main, or still computing)"; return 1; }
    checks="$(GH_TTL=0 checks_of "$head")" || checks="[]"
    verdict="$(echo "$checks" | checks_verdict)"
    if [ "$verdict" != pass ]; then
        retry_no="$(echo "$checks" | python3 -c 'import json,sys; print(", ".join(c["name"]+"="+c["bucket"] for c in json.load(sys.stdin) if c["bucket"] not in ("pass","skipping")))')"
        retry_no="${retry_no//FAILED/failed}"; retry_no="${retry_no//done:/done}"
        retry_no="the PR's own checks are not green now (${retry_no:-none with a verdict, or they cannot be read})"
        return 1
    fi
    gq_mq=""; gq_prid=""
    for tries in 1 2 3; do ghq_target "$pr" && break; [ $tries = 3 ] || sleep "$((POLL < 10 ? POLL : 10))"; done
    [ "$gq_mq" = 1 ] || { retry_no="main's merge queue is off, or GitHub's answer about it cannot be read"; return 1; }
}

# codex_review_start <pr>: start `salamander codex-review <repo> <pr>` (the trial review, docs/codex-review.md) detached and leave it. It gets its own transient user
# unit, because this script runs in one and systemd ends a unit's whole cgroup when its main process exits, which would cut a review that outlives the release; with
# no user manager (or no systemd-run) it falls back to `setsid nohup`. The output goes to its own log, never into the release's. Always returns 0 and says one line.
codex_review_start() {
    local pr="$1" crlog="$LOGDIR/codex-review-pr-$1.log" unit v; local -a senv=()
    unit="salamander-codex-review-$pr-$(date +%s)"
    if [ ! -x "$HERE/bin/salamander" ]; then say "codex-review not started: no bin/salamander in $HERE"; return 0; fi
    for v in PATH XDG_STATE_HOME SALA_CONFIG SALA_CODEX_REVIEW SALA_CODEX_BIN SALA_CODEX_HOME SALA_CODEX_MAX_DIFF SALA_CODEX_TIMEOUT SALA_CODEX_PUBLIC_SCAN SALA_CODEX_SCAN_TIMEOUT; do
        [ -n "${!v+x}" ] && senv+=("--setenv=$v=${!v}")
    done
    if systemd-run --user --quiet --collect --unit "$unit" -p "StandardOutput=append:$crlog" -p "StandardError=append:$crlog" "${senv[@]}" \
           "$HERE/bin/salamander" codex-review "$REPO" "$pr" </dev/null >/dev/null 2>&1; then
        say "codex-review started for PR #$pr (unit $unit, output $crlog)"
    elif (setsid nohup "$HERE/bin/salamander" codex-review "$REPO" "$pr" >> "$crlog" 2>&1 </dev/null &) 2>/dev/null; then
        say "codex-review started for PR #$pr (detached, no user unit; output $crlog)"
    else
        say "codex-review not started: neither systemd-run nor setsid could start it"
    fi
    return 0
}

run() {
    local pr="$1" want_merged="${2:-}" log="$LOGDIR/pr-$1.log" title sha changed live_sha
    local retry_note=""   # set once the PR is queued a second time: every later failure's line carries it
    exec > >(tee -a "$log") 2>&1
    say "release of PR #$pr starts in $HERE ($REPO)"
    fail() { say "FAILED at $1: $2$retry_note"; tell "[release] PR #$pr FAILED at $1: $2$retry_note · log $log"; exit 1; }
    # UNKNOWN is GitHub still computing mergeability (right after another merge to main): ask again, up to 2 min
    local view tries=0
    while :; do
        view="$(gh pr view "$pr" --repo "$REPO" --json state,mergeable,title,headRefName,isCrossRepository,mergeCommit 2>&1)" || fail "pr view" "$(echo "$view" | tail -1)"
        echo "$view" | grep -q '"state":"OPEN"' && echo "$view" | grep -q '"mergeable":"UNKNOWN"' && [ "$tries" -lt 12 ] || break
        tries=$((tries + 1)); sleep 10
    done
    title="$(echo "$view" | python3 -c 'import json,sys; print(json.load(sys.stdin)["title"])')"
    local state mergeable; state="$(echo "$view" | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])')"; mergeable="$(echo "$view" | python3 -c 'import json,sys; print(json.load(sys.stdin)["mergeable"])')"
    # MERGED: somebody merged it already (by hand, a merge helper), so main moved and the production checkout may not have
    # followed. The merge is skipped and the checks that matter are the ones on main's merge commit.
    local mode=open merge_sha= msha= what=checks via=direct via_note= twice_note= branch= removed_why=
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
    if [ "$mode" = open ]; then codex_review_start "$pr" || true; else say "codex-review not started: the PR is already merged"; fi
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
            checks="$(checks_of "$head_sha")" || checks="[]"
        fi
        local verdict; verdict="$(echo "$checks" | checks_verdict)"
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
        # 4. How the PR goes in is decided by what GitHub says about main: a merge queue on it (its ruleset is on) -> the PR is put in the queue and GitHub merges it once the entry's checks pass; none (no
        # such ruleset, or it is disabled) -> merged at once. SALA_RELEASE_MERGE=direct never asks (the way back with no API call), =queue refuses the direct merge.
        via=direct
        if [ "$MERGE_MODE" != direct ]; then
            local tries; gq_mq=""; gq_prid=""
            for tries in 1 2 3; do ghq_target "$pr" && break; [ $tries = 3 ] || sleep "$((POLL < 10 ? POLL : 10))"; done
            [ -n "$gq_mq" ] || fail "merge" "GitHub's answer about main's merge queue and the PR cannot be read, so it is not known whether the PR is put in the queue or merged at once (SALA_RELEASE_MERGE=direct merges at once)"
            [ "$gq_mq" = 1 ] && via=queue
            [ "$MERGE_MODE" != queue ] || [ "$via" = queue ] || fail "merge queue" "SALA_RELEASE_MERGE=queue, and main has no merge queue (the ruleset is off or disabled)"
        fi
        if [ "$via" = queue ]; then
            # one pass through the queue, and a second one only after a drop for failed required checks that retry_check allows (the header, ONE RETRY)
            local pass=1 since first_run="" first_at=0 rcq
            while :; do
                # a removal counts for a pass when it is dated at or after its enqueue, and after the removal that ended the first pass
                since="$(date +%s)"; [ "$since" -gt "$first_at" ] || since=$((first_at + 1))
                enqueue "$pr" "$head_sha"
                wait_queue "$pr" "$since"; rcq=$?
                case "$rcq" in
                    0) break ;;
                    1) [ "$gq_checks" = 1 ] || fail "merge queue" "$removed_why; nothing was merged or deployed"
                       if mg_failed_run "$gq_mg"; then say "the merge group GitHub removed (commit ${gq_mg:0:7}): $mg_desc"; fi
                       if [ "$pass" = 2 ]; then
                           retry_note=""
                           fail "merge queue" "$removed_why twice, the second time after the one retry (first: $first_run; second: ${mg_desc:-its failed run cannot be read}); nothing was merged or deployed"
                       fi
                       retry_check "$pr" "$head_sha" || fail "merge queue" "$removed_why; nothing was merged or deployed; not queued again: $retry_no"
                       pass=2; first_run="$mg_desc"; first_at="$gq_at"
                       retry_note=" (this release queued the PR a second time, after the first merge group failed its required checks: $first_run)"
                       say "queuing PR #$pr again, the one retry of this release, because the merge group failed its required checks ($first_run); the head is still ${head_sha:0:7}, the PR is open, ready and mergeable and its own checks pass" ;;
                    2) fail "pr state" "the PR was closed while it waited for the merge queue" ;;
                    *) fail "merge queue" "still in the queue or not merged $((QUEUE_WAIT/60)) min after the enqueue, which is as long as this release waits; if GitHub merges it later, release.sh --merged $pr deploys it" ;;
                esac
            done
            msha="${merge_sha:0:7}"; via_note=" through GitHub's merge queue"
            [ "$pass" = 1 ] || twice_note=" · queued twice: the first merge group failed its required checks ($first_run)"
            say "merged by GitHub's merge queue as $msha (the entry's checks ran on that commit); on to the deploy"
            # the head branch, as `gh pr merge --delete-branch` removes it: best effort, and never a branch of a fork
            if [ "$(echo "$view" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("isCrossRepository") and "fork" or "")')" != fork ]; then
                branch="$(echo "$view" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("headRefName") or "")')"
                if [ -n "$branch" ] && gh api "repos/$REPO/git/refs/heads/$branch" -X DELETE >/dev/null 2>&1; then say "deleted the head branch $branch"
                else say "head branch ${branch:-?} not deleted (GitHub refused, or it is gone)"; fi
            fi
        else
            # --admin: a ruleset limits who may update branches, so GitHub reports the PR as BLOCKED and gh refuses a plain merge client-side.
            # It does not skip the required checks (administrators are not exempt from them): a failing or unfinished one still refuses it.
            out="$(gh pr merge "$pr" --repo "$REPO" --merge --delete-branch --admin 2>&1)" || fail "merge" "$(echo "$out" | tail -1)"
            say "merged"
        fi
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
    tell "[release] PR #$pr merged and deployed$via_note$([ "$mode" = merged ] && echo " (it was already merged; the checks on main passed)") — $title — main at $sha; changed: $changed$twice_note · log $log"
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
    ''|-h|--help) sed -n '2,44p' "$0"; exit 2 ;;
    *)
        flag=; [ "$1" = --merged ] && { flag=--merged; shift; }
        pr="${1:-}"; [[ "$pr" =~ ^[0-9]+$ ]] || { echo "usage: release.sh [--merged] <pr> | --status [pr] | --run [--merged] <pr>" >&2; exit 2; }
        if systemctl --user is-active --quiet "salamander-release-$pr.service" 2>/dev/null; then echo "release of PR #$pr is already running (release.sh --status $pr)"; exit 1; fi
        systemd-run --user --quiet --collect --unit "salamander-release-$pr" -p WorkingDirectory="$HERE" \
            --setenv=PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" "$HERE/release.sh" --run $flag "$pr"     # gh and python3 as the shell sees them
        echo "started salamander-release-$pr: $([ -n "$flag" ] && echo "deploys the already merged PR #$pr once the checks on main pass" || echo "merges PR #$pr when its checks pass (an already merged one is only deployed)"), and reports to projects/salamander · log $LOGDIR/pr-$pr.log" ;;
esac
