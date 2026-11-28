#!/usr/bin/env bash
# The CI-run poller and its reader (lib/cipoll.py, lib/cipoll.sh, lib/ci-repos, systemd/sala-cipoll.service, docs/ci-runs.md), run through
# the real verbs (`salamander ci-poll`, `salamander ci-runs`) against a fake `gh` on PATH that serves canned workflow-run lists with an ETag (a matching
# If-None-Match gets 304 and exit 1, as gh does), can answer the n-th ask with a raw error (status line and headers), and logs every call. A poller run
# is bounded by SALA_CIPOLL_CYCLES, so nothing is ever killed; the timings are shortened by SALA_CIPOLL_INTERVAL / _BACKOFF_MAX. No network.
# Kept because release.sh waits on this file instead of GitHub: a torn or never-aging file would make a release wait on a ghost. Checks: the first look
# writes the file (keys, fields cut to the list, no tmp left); a second look sends the ETag, gets 304, and writes the file again with `updated` bumped and
# the same runs; a changed list replaces the runs; a reader never sees a torn file while the poller rewrites it fast; an error (HTTP 500, no answer) keeps
# the old file byte for byte, backs off by doubling (the log says how long), is capped by SALA_CIPOLL_BACKOFF_MAX and logs the recovery; a rate limit
# (403 with x-ratelimit-remaining 0 and a reset in the future) waits for the reset before ANY repo is read; a token-shaped string in gh's error is not
# logged; the repo list (comments, blanks, an invalid line named once, two repos = two files, a repo removed from the list no longer asked, the default
# lib/ci-repos when the box has none, ~/.config/salamander/ci-repos winning when it has); a tmp file a killed poller left is removed at start; `ci-runs`:
# fresh = exit 0 and the JSON, --sha cuts to the prefix (none = [] and exit 0), --text, missing = 3, stale = 4 with nothing on stdout, --max-age 0 = no
# limit, corrupt = 5, usage = 2, the path under XDG_STATE_HOME and under ~/.local/state; the unit file. A STUCK run (queued past the limit with an
# empty job list): flagged exactly once through the real inbox push (a private tmux server, a stand-in claude and its inbox socket), kept pending
# while the builder is not live or paused, sent once across restarts, nothing written to GitHub; not flagged: a run with a job, a young or running or
# superseded one, a jobs read that fails, is unreadable or hangs; a repo with no builder (logged once, no read); the bound of reads in a pass, a rate
# limit met by such a read, a run that left the list, one that only the conditional read of the queued runs holds (a 304 repeat, its failure, its rate
# limit), a record that is not one. Not checked: the real gh and GitHub, systemd, a real Claude's inbox.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/sala-cipoll.XXXXXX")
exec 8< "$T"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
SOCK="sala-cipoll-$$"; listener=
cleanup() {
    touch "$T/stop"; [ -z "$listener" ] || wait "$listener" 2>/dev/null   # the stand-in inbox ends itself on the stop file
    command tmux -L "$SOCK" -f /dev/null kill-server 2>/dev/null; tmux_socket_rm "$SOCK"; rm -rf "$T"
}
trap cleanup EXIT
export HOME="$T/home"; mkdir -p "$HOME/bin"; export PATH="$HOME/bin:$PATH"
unset SALA_CONFIG SALA_LOG_DIR XDG_STATE_HOME XDG_CONFIG_HOME SALA_CIPOLL_REPOS SALA_CIPOLL_CYCLES SALA_CIPOLL_INTERVAL SALA_CIPOLL_BACKOFF_MAX SALA_CIRUNS_DIR
unset SALA_CIPOLL_STUCK_AFTER SALA_CIPOLL_STUCK_READS SALA_CIPOLL_STUCK_RECHECK SALA_CIPOLL_STUCK_TIMEOUT SALA_CIPOLL_STUCK_LIST SALA_JOB_REPOS
# every tmux call of the inbox push goes to this suite's private server, which stands in for the fleet's
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux
export FAKE_DIR="$T/fake"; mkdir -p "$FAKE_DIR"
REPOS="$T/repos"; export SALA_CIRUNS_DIR="$T/out" SALA_CIPOLL_REPOS="$REPOS"
export SALA_CIPOLL_INTERVAL=0.1

cat > "$HOME/bin/gh" <<'FAKE'
#!/bin/bash
echo "gh $*" >> "$FAKE_DIR/calls"
[ "$1" = api ] || exit 9
path="$2"; inm=
case "$path" in */actions/runs/*)   # an extra read of the stuck-run look: jobs.<id> or run.<id> holds the answer's body (.raw: a whole answer; .sleep: no answer for that long)
    id=${path#*/actions/runs/}; id=${id%%[/?]*}; f="$FAKE_DIR/run.$id"; [[ $path == */jobs* ]] && f="$FAKE_DIR/jobs.$id"
    [ -f "$f.sleep" ] && exec sleep "$(cat "$f.sleep")"
    if [ -f "$f.raw" ]; then cat "$f.raw"; exit 1; fi
    [ -f "$f" ] || { printf 'HTTP/2.0 404 Not Found\r\n\r\n{}\n'; exit 1; }
    printf 'HTTP/2.0 200 OK\r\n\r\n'; cat "$f"; exit 0 ;;
*status=queued*)    # the queued runs of a repo: queued.<k>.json (none: an empty list), with an ETag; queued.<k>.raw: a whole answer
    repo=${path#repos/}; repo=${repo%%/actions*}; f="$FAKE_DIR/queued.${repo//\//__}"
    if [ -f "$f.raw" ]; then cat "$f.raw"; exit 1; fi
    body='{"total_count":0,"workflow_runs":[]}'; [ -f "$f.json" ] && body=$(cat "$f.json")
    etag="\"$(printf '%s' "$body" | md5sum | cut -c1-32)\""
    case " $* " in *"If-None-Match: $etag "*) printf 'HTTP/2.0 304 Not Modified\r\nEtag: %s\r\n\r\n' "$etag"; exit 1 ;; esac
    printf 'HTTP/2.0 200 OK\r\nEtag: %s\r\n\r\n%s\n' "$etag" "$body"; exit 0 ;;
esac
while [ $# -gt 0 ]; do [ "$1" = -H ] && inm="${2#If-None-Match: }"; shift; done
repo=${path#repos/}; repo=${repo%%/actions*}; k=${repo//\//__}
n=$(( $(cat "$FAKE_DIR/$k.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_DIR/$k.count"
echo "$inm" >> "$FAKE_DIR/$k.inm"            # one line per ask: the If-None-Match it sent, empty for none
if [ -f "$FAKE_DIR/$k.err.$n" ]; then          # the n-th ask answered with a raw status line and headers (and exit 1, as gh does for a non-2xx)
    cat "$FAKE_DIR/$k.err.$n"; [ -f "$FAKE_DIR/$k.errmsg" ] && cat "$FAKE_DIR/$k.errmsg" >&2
    exit 1
fi
m=$n; while [ "$m" -gt 0 ] && [ ! -f "$FAKE_DIR/$k.$m.json" ]; do m=$((m - 1)); done   # the n-th ask gets <k>.<n>.json, or the last one there is
body=$(cat "$FAKE_DIR/$k.$m.json")
etag="\"$(printf '%s' "$body" | md5sum | cut -c1-32)\""
if [ -n "$inm" ] && [ "$inm" = "$etag" ]; then
    printf 'HTTP/2.0 304 Not Modified\r\nEtag: %s\r\n\r\n' "$etag"; echo "gh: HTTP 304" >&2; exit 1
fi
printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json\r\nEtag: %s\r\n\r\n%s\n' "$etag" "$body"
FAKE
chmod +x "$HOME/bin/gh"

SHA1=1111111aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SHA2=2222222bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
mkruns() {  # <repo> <n> <id:status:conclusion:sha>… → <repo>.<n>.json, a workflow-run list with a field the poller must drop
    local k="${1//\//__}" n="$2"; shift 2
    python3 - "$FAKE_DIR/$k.$n.json" "$@" <<'PY'
import json, sys
runs = []
for spec in sys.argv[2:]:
    i, st, co, sha = spec.split(":")
    runs.append({"id": int(i), "name": "tests", "head_sha": sha, "head_branch": "b-" + i, "event": "push", "status": st, "conclusion": None if co == "-" else co,
                 "created_at": "2026-10-28T01:00:00Z", "updated_at": "2026-10-28T01:02:00Z", "html_url": "https://github.com/x/y/actions/runs/" + i, "run_attempt": 1,
                 "actor": {"login": "dropme"}, "pull_requests": [{"number": 7}]})
json.dump({"total_count": len(runs), "workflow_runs": runs}, open(sys.argv[1], "w"))
PY
}
errask() {  # <repo> <n> <status line text> [header…] → the n-th ask of that repo answered with this raw response
    local k="${1//\//__}" n="$2" st="$3" h; shift 3
    { printf 'HTTP/2.0 %s\r\n' "$st"; for h in "$@"; do printf '%s\r\n' "$h"; done; printf '\r\n{"message":"x"}\n'; } > "$FAKE_DIR/$k.err.$n"
}
fresh() { rm -rf "$FAKE_DIR"/* "$SALA_CIRUNS_DIR" "$T"/ci-stuck.json*; : > "$FAKE_DIR/calls"; printf 'o/r\n' > "$REPOS"; }
poll() { SALA_CIPOLL_CYCLES="$1" bash "$ROOT/bin/salamander" ci-poll > "$T/poll.log" 2>&1; prc=$?; }   # <cycles>
runs() { bash "$ROOT/bin/salamander" ci-runs "$@" > "$T/runs.out" 2> "$T/runs.err"; rrc=$?; }
jq_() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }   # <file> <expr over d>
F="$SALA_CIRUNS_DIR/o__r.json"
asks() { wc -l < "$FAKE_DIR/o__r.inm" 2>/dev/null || echo 0; }

echo "== the first look writes the file"
fresh; mkruns o/r 1 "101:completed:success:$SHA1" "102:in_progress:-:$SHA2"
poll 1
[ "$prc" = 0 ] && [ -f "$F" ] && ok "one pass: the file o__r.json exists under the ci-runs folder" || bad "no file: rc=$prc $(cat "$T/poll.log")"
[ "$(jq_ "$F" 'd["repo"]')" = o/r ] && [ "$(jq_ "$F" 'len(d["runs"])')" = 2 ] && [ "$(jq_ "$F" 'sorted(d["runs"][0].keys())')" = "['conclusion', 'created_at', 'event', 'head_branch', 'head_sha', 'html_url', 'id', 'name', 'run_attempt', 'status', 'updated_at']" ] \
    && ok "repo, two runs, each with exactly the eleven fields (the actor and pull_requests the API sends are dropped)" || bad "shape: $(cat "$F")"
[ "$(jq_ "$F" 'd["runs"][1]["conclusion"]')" = None ] && [ "$(jq_ "$F" 'd["runs"][0]["head_sha"]')" = "$SHA1" ] && ok "a run in progress has conclusion null, the head sha is whole" || bad "values: $(cat "$F")"
now=$(date +%s); upd=$(jq_ "$F" 'd["updated"]')
[ "$upd" -le "$now" ] && [ $((now - upd)) -lt 30 ] && [[ "$(jq_ "$F" 'd["updated_iso"]')" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]] && ok "updated is epoch seconds (now), updated_iso its ISO form" || bad "updated=$upd iso=$(jq_ "$F" 'd["updated_iso"]')"
[ -z "$(ls "$SALA_CIRUNS_DIR" | grep -v '\.json$')" ] && ok "no tmp file is left beside it" || bad "folder: $(ls "$SALA_CIRUNS_DIR")"
[ "$(head -1 "$FAKE_DIR/o__r.inm")" = "" ] && grep -q 'gh api repos/o/r/actions/runs?per_page=30 -i$' "$FAKE_DIR/calls" && ok "the call is gh api repos/o/r/actions/runs?per_page=30 -i, with no ETag the first time" || bad "call: $(cat "$FAKE_DIR/calls")"
grep -q 'cipoll: o/r: 2 runs, 1 not completed' "$T/poll.log" && ok "one log line for the first look" || bad "log: $(cat "$T/poll.log")"

echo "== a second look sends the ETag; a 304 renews the file"
fresh; mkruns o/r 1 "101:completed:success:$SHA1"
# one process, two looks 1.05 s apart (updated is whole seconds): watch the file's updated from outside, the first value seen against the last
python3 - "$ROOT" "$F" "$FAKE_DIR" <<'PY'
import json, os, subprocess, sys, time
root, f, fake = sys.argv[1:]
env = dict(os.environ, SALA_CIPOLL_INTERVAL="1.05", SALA_CIPOLL_CYCLES="2")
p = subprocess.Popen(["bash", root + "/bin/salamander", "ci-poll"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
first = None
t0 = time.time()
while time.time() - t0 < 60 and p.poll() is None:
    try:
        u = json.load(open(f))["updated"]
        if first is None: first = u
    except (OSError, ValueError): pass
    time.sleep(0.05)
p.wait()
last = json.load(open(f))["updated"]
open(os.path.join(fake, "bump"), "w").write("%s %s\n" % (first, last))
PY
a=$(sed -n 2p "$FAKE_DIR/o__r.inm")
[ "$(asks)" = 2 ] && [[ "$a" == \"*\" ]] && grep -q 'If-None-Match' "$FAKE_DIR/calls" && ok "two asks; the second sent If-None-Match with the ETag of the first answer ($a), the first sent none" || bad "asks: $(cat "$FAKE_DIR/o__r.inm") $(cat "$FAKE_DIR/calls")"
read -r b1 b2 < "$FAKE_DIR/bump"
[ -n "$b1" ] && [ "$b2" -gt "$b1" ] && [ "$(jq_ "$F" 'len(d["runs"])')" = 1 ] && [ "$(jq_ "$F" 'd["runs"][0]["id"]')" = 101 ] \
    && ok "a 304 look rewrites the file: updated $b1 → $b2, the same run kept" || bad "bump: '$b1' '$b2' $(cat "$F")"

echo "== a changed list replaces the runs (200 again, with a new ETag)"
fresh; mkruns o/r 1 "101:in_progress:-:$SHA1"; mkruns o/r 2 "101:completed:success:$SHA1" "103:queued:-:$SHA2"
poll 3
[ "$(jq_ "$F" 'len(d["runs"])')" = 2 ] && [ "$(jq_ "$F" 'd["runs"][0]["status"]')" = completed ] && ok "the second answer's runs are in the file" || bad "replace: $(cat "$F")"
[ "$(grep -c 'cipoll: o/r: ' "$T/poll.log")" = 2 ] && ok "one log line per CHANGE (two), none for the unchanged looks" || bad "log: $(cat "$T/poll.log")"

echo "== a reader never sees a torn file while the poller rewrites it fast"
fresh; python3 - "$FAKE_DIR/o__r.1.json" <<'PY'
import json, sys
json.dump({"total_count": 30, "workflow_runs": [{"id": i, "name": "tests", "head_sha": "a" * 40, "head_branch": "x" * 200, "event": "push", "status": "completed", "conclusion": "success",
    "created_at": "t", "updated_at": "t", "html_url": "u" * 200, "run_attempt": 1} for i in range(30)]}, open(sys.argv[1], "w"))
PY
( SALA_CIPOLL_INTERVAL=0.05 SALA_CIPOLL_CYCLES=60 bash "$ROOT/bin/salamander" ci-poll > "$T/poll.log" 2>&1; touch "$T/done" ) &
bgpid=$!
python3 - "$F" "$T/done" <<'PY'
import json, os, sys, time
f, done = sys.argv[1:]
good = torn = 0
t0 = time.time()
while not os.path.exists(done) and time.time() - t0 < 60:
    try:
        d = json.load(open(f))
        assert len(d["runs"]) == 30
        good += 1
    except FileNotFoundError:
        pass
    except Exception:
        torn += 1
open(done + ".res", "w").write("%d %d\n" % (good, torn))
PY
wait "$bgpid"; rm -f "$T/done"
read -r good torn < "$T/done.res"; rm -f "$T/done.res"
[ "$torn" = 0 ] && [ "$good" -gt 20 ] && ok "$good reads while the file was replaced 60 times: every one whole, none torn" || bad "good=$good torn=$torn"
[ -z "$(ls "$SALA_CIRUNS_DIR" | grep -v '\.json$')" ] && ok "no tmp file left after 60 rewrites" || bad "folder: $(ls "$SALA_CIRUNS_DIR")"
fresh; mkdir -p "$SALA_CIRUNS_DIR"; : > "$SALA_CIRUNS_DIR/o__r.json.99999.tmp"; mkruns o/r 1 "101:completed:success:$SHA1"
poll 1
[ ! -e "$SALA_CIRUNS_DIR/o__r.json.99999.tmp" ] && [ -f "$F" ] && ok "a tmp file a killed poller left is removed at start" || bad "tmp: $(ls "$SALA_CIRUNS_DIR")"

echo "== an error keeps the old file, backs off by doubling, and recovers"
# ask 1 ok, 2 and 3 fail, 4 ok again: all in one process, so the failures count up and the recovery is seen
fresh; mkruns o/r 1 "101:completed:success:$SHA1"; errask o/r 2 "500 Server Error"; errask o/r 3 "500 Server Error"; mkruns o/r 4 "101:completed:success:$SHA1" "104:queued:-:$SHA2"
printf 'gh: HTTP 500 (Server Error)\n' > "$FAKE_DIR/o__r.errmsg"
poll 14
grep -q 'o/r: HTTP 500 gh: HTTP 500 (Server Error); file kept; backing off 0.2s (failure 1)' "$T/poll.log" && grep -q 'backing off 0.4s (failure 2)' "$T/poll.log" \
    && ok "failure 1 backs off 0.2 s (twice the 0.1 s interval), failure 2 0.4 s; the log line says HTTP 500 and that the file was kept" || bad "log: $(cat "$T/poll.log")"
grep -q 'o/r: reachable again, 2 runs' "$T/poll.log" && [ "$(jq_ "$F" 'len(d["runs"])')" = 2 ] && ok "the next good look logs the recovery and the file has the new runs" || bad "recovery: $(cat "$T/poll.log") $(cat "$F")"
# a process whose every look fails leaves the file another process wrote byte for byte as it was (updated not bumped: a reader sees it age)
fresh; mkruns o/r 1 "101:completed:success:$SHA1"
poll 1
cp "$F" "$T/before.json"; rm -f "$FAKE_DIR"/*.count "$FAKE_DIR"/*.inm; for n in 1 2 3 4 5 6; do errask o/r $n "502 Bad Gateway"; done
SALA_CIPOLL_INTERVAL=0.05 poll 12
cmp -s "$F" "$T/before.json" && [ "$(asks)" -ge 2 ] && ok "failing looks ($(asks) asks): the file is byte for byte the old one" || bad "file changed or not asked: asks=$(asks) $(cat "$F") vs $(cat "$T/before.json")"
[ -z "$(ls "$SALA_CIRUNS_DIR" | grep -v '\.json$')" ] && ok "no tmp file left behind by the failures" || bad "folder: $(ls "$SALA_CIRUNS_DIR")"
# the cap
fresh; mkruns o/r 1 "101:completed:success:$SHA1"; for n in 1 2 3 4 5 6; do errask o/r $n "503 Service Unavailable"; done
SALA_CIPOLL_BACKOFF_MAX=0.3 poll 6
grep -q 'backing off 0.2s (failure 1)' "$T/poll.log" && grep -q 'backing off 0.3s (failure 2)' "$T/poll.log" && ! grep -q 'backing off 0.4s' "$T/poll.log" \
    && ok "SALA_CIPOLL_BACKOFF_MAX caps the wait (0.2 s, then 0.3 s, never 0.4 s)" || bad "cap: $(cat "$T/poll.log")"
[ ! -e "$F" ] && ok "a repo that never answered has no file (a reader gets exit 3)" || bad "file from nowhere: $(cat "$F")"
# no answer at all
fresh; printf '#!/bin/bash\necho "gh $*" >> "$FAKE_DIR/calls"\necho "dial tcp: lookup api.github.com: no such host" >&2\nexit 1\n' > "$HOME/bin/gh.down"; chmod +x "$HOME/bin/gh.down"
SALA_CIPOLL_GH="$HOME/bin/gh.down" poll 2
grep -q 'o/r: HTTP ? dial tcp: lookup api.github.com: no such host; file kept; backing off 0.2s (failure 1)' "$T/poll.log" && ok "gh printing no HTTP status (the network is down): HTTP ?, the last stderr line, backoff" || bad "down: $(cat "$T/poll.log")"
rm -f "$HOME/bin/gh.down"

echo "== a rate limit waits for the reset before any repo is read"
fresh; printf 'o/r\np/q\n' > "$REPOS"; mkruns p/q 1 "201:completed:success:$SHA1"
margin=$(scale 10)   # the reset is set this far ahead: setup that takes a few seconds on a loaded box must not eat the wait or let the reset pass before the poller's four passes are done
reset=$(( $(date +%s) + margin ))
errask o/r 1 "403 Forbidden" "X-Ratelimit-Remaining: 0" "X-Ratelimit-Reset: $reset" "Etag: \"zzz\""
SALA_CIPOLL_CYCLES=4 poll 4
rl=$(sed -n 's/^cipoll: o\/r: HTTP 403 .*(rate limit; waiting for it to reset); file kept; backing off \([0-9.]*\)s .*/\1/p' "$T/poll.log")   # reset − now + 1: at most margin + 1 (+ the fraction of a second), and over 3 s however long the setup took
[ -n "$rl" ] && awk -v w="$rl" -v m="$margin" 'BEGIN { exit !(w >= 3 && w <= m + 1.2) }' && ok "403 with remaining 0: the log says rate limit and waits until the reset (${margin} s ahead, the wait is over 3 s and at most $((margin + 1)) s)" || bad "rl log: $(cat "$T/poll.log")"
[ ! -e "$FAKE_DIR/p__q.count" ] && ok "the other repo (p/q) was not asked during the wait: the budget is the account's" || bad "p/q asked: $(cat "$FAKE_DIR/calls")"
fresh; errask o/r 1 "429 Too Many Requests" "Retry-After: 20"
poll 3
grep -q 'o/r: HTTP 429 .*(rate limit; waiting for it to reset); file kept; backing off 20s' "$T/poll.log" && [ "$(asks)" = 1 ] && ok "429 with Retry-After: 20: waits 20 s, no second ask meanwhile (the three passes end in well under a second)" || bad "429: $(cat "$T/poll.log") asks=$(asks)"
fresh; errask o/r 1 "403 Forbidden"
poll 2
! grep -q 'rate limit' "$T/poll.log" && grep -q 'backing off 0.2s' "$T/poll.log" && ok "a 403 without rate-limit headers is an ordinary error (plain backoff)" || bad "403: $(cat "$T/poll.log")"

echo "== no token in the log"
fresh; errask o/r 1 "401 Unauthorized"; printf 'gh: HTTP 401: Bad credentials ghp_abcdefghijklmnopqrstuvwxyz0123456789 (https://api.github.com/x)\n' > "$FAKE_DIR/o__r.errmsg"
poll 1
! grep -q 'ghp_abcdefgh' "$T/poll.log" && grep -q '<hidden>' "$T/poll.log" && ok "a token-shaped string in gh's stderr is replaced in the log" || bad "token: $(cat "$T/poll.log")"

echo "== the repo list"
fresh; printf '# comment\n\no/r   # trailing comment\nnot a repo\n../x/y\np/q\no/r\n' > "$REPOS"; mkruns o/r 1 "101:completed:success:$SHA1"; mkruns p/q 1 "201:completed:success:$SHA2"
poll 3
[ -f "$F" ] && [ -f "$SALA_CIRUNS_DIR/p__q.json" ] && [ "$(ls "$SALA_CIRUNS_DIR" | wc -l)" = 2 ] && ok "comments and blanks skipped, a repeat once: two repos, two files (o__r.json, p__q.json)" || bad "files: $(ls "$SALA_CIRUNS_DIR")"
[ "$(grep -c "is not owner/name" "$T/poll.log")" = 2 ] && grep -q "'not a repo' is not owner/name" "$T/poll.log" && grep -q "'../x/y' is not owner/name" "$T/poll.log" && ok "each invalid line named once in the log (three passes), never turned into a path" || bad "invalid: $(cat "$T/poll.log")"
[ "$(wc -l < "$FAKE_DIR/o__r.inm")" -ge 2 ] && [ "$(wc -l < "$FAKE_DIR/p__q.inm")" -ge 2 ] && ok "both repos asked every pass (o/r once, however often the list names it)" || bad "asks: $(cat "$FAKE_DIR/calls")"
# a repo added or removed while the poller runs: the list is read every pass
fresh; printf 'o/r\n' > "$REPOS"; mkruns o/r 1 "101:completed:success:$SHA1"; mkruns p/q 1 "201:completed:success:$SHA2"
( SALA_CIPOLL_CYCLES=40 SALA_CIPOLL_INTERVAL=0.1 bash "$ROOT/bin/salamander" ci-poll > "$T/poll.log" 2>&1 ) & bgpid=$!
waitfor '[ -f "$F" ]' 100
printf 'o/r\np/q\n' > "$REPOS"
waitfor '[ -f "$SALA_CIRUNS_DIR/p__q.json" ]' 100
printf 'p/q\n' > "$REPOS"
waitfor '[ "$(wc -l < "$FAKE_DIR/o__r.inm")" -ge 1 ]' 20
n_o=$(wc -l < "$FAKE_DIR/o__r.inm"); nap 1
n_o2=$(wc -l < "$FAKE_DIR/o__r.inm")
wait "$bgpid"
[ -f "$SALA_CIRUNS_DIR/p__q.json" ] && [ "$n_o2" -le $((n_o + 1)) ] && ok "a repo added to the list is polled from the next pass; one removed is no longer asked (o/r asked $n_o, then $n_o2 times)" || bad "live list: n_o=$n_o n_o2=$n_o2 $(cat "$T/poll.log")"
# the default list and the user's
fresh; unset SALA_CIPOLL_REPOS; mkruns alice/app-a 1 "301:completed:success:$SHA1"; mkruns alice/app-b 1 "302:completed:success:$SHA1"
poll 1
grep -q "repo list $ROOT/lib/ci-repos" "$T/poll.log" && grep -q "names no repo" "$T/poll.log" && [ -z "$(ls "$SALA_CIRUNS_DIR" 2>/dev/null)" ] \
    && ok "no ~/.config/salamander/ci-repos: the tracked lib/ci-repos names no repo, nothing is polled and the log says so" || bad "default list: $(cat "$T/poll.log") $(ls "$SALA_CIRUNS_DIR" 2>&1)"
fresh; unset SALA_CIPOLL_REPOS; mkdir -p "$HOME/.config/salamander"; printf 'o/r\n' > "$HOME/.config/salamander/ci-repos"; mkruns o/r 1 "101:completed:success:$SHA1"
poll 1
grep -q "repo list $HOME/.config/salamander/ci-repos" "$T/poll.log" && [ -f "$F" ] && [ "$(ls "$SALA_CIRUNS_DIR" | wc -l)" = 1 ] && ok "a ~/.config/salamander/ci-repos replaces the default" || bad "user list: $(cat "$T/poll.log") $(ls "$SALA_CIRUNS_DIR")"
rm -rf "$HOME/.config"; export SALA_CIPOLL_REPOS="$REPOS"

echo "== ci-runs, the reader"
fresh; mkruns o/r 1 "101:completed:success:$SHA1" "102:in_progress:-:$SHA2" "103:completed:failure:$SHA2"
poll 1
runs o/r
[ "$rrc" = 0 ] && [ "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["repo"], len(d["runs"]))' "$T/runs.out")" = "o/r 3" ] && [ ! -s "$T/runs.err" ] && ok "fresh: exit 0, the file's JSON (repo, updated, updated_iso, runs) on stdout" || bad "fresh: rc=$rrc $(cat "$T/runs.out" "$T/runs.err")"
runs o/r --sha "${SHA2:0:7}"
[ "$rrc" = 0 ] && [ "$(python3 -c 'import json,sys; print(sorted(r["id"] for r in json.load(open(sys.argv[1]))["runs"]))' "$T/runs.out")" = "[102, 103]" ] && ok "--sha with a 7-character prefix: the runs of that head commit only" || bad "sha: rc=$rrc $(cat "$T/runs.out")"
runs o/r --sha 9999999
[ "$rrc" = 0 ] && [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["runs"])' "$T/runs.out")" = "[]" ] && ok "--sha of a commit with no run in the file: exit 0 and an empty list (the file is fresh; absence is the caller's to judge)" || bad "sha none: rc=$rrc $(cat "$T/runs.out")"
runs o/r --sha 123
[ "$rrc" = 2 ] && ok "--sha shorter than 7 characters: usage, exit 2" || bad "short sha: rc=$rrc"
runs o/r --text --sha "${SHA2:0:7}"
[ "$rrc" = 0 ] && [ "$(wc -l < "$T/runs.out")" = 3 ] && grep -q "^102	in_progress/-	b-102	2222222	tests$" "$T/runs.out" && ! grep -q 'https://github.com/x/y/actions/runs/102' <(tail -n +2 "$T/runs.out") && head -1 "$T/runs.out" | grep -q '^# o/r, updated 20.*2 run(s) of 2222222, run url = https://github.com/x/y/actions/runs/<id>$' && ok "--text: a header with the run url prefix once and one tab-separated line a run (id, status/conclusion, branch, sha, name)" || bad "text: $(cat "$T/runs.out")"
python3 - "$F" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["runs"][0]["html_url"] = "https://github.com/other/name/actions/runs/" + str(d["runs"][0]["id"]); json.dump(d, open(sys.argv[1], "w"))
PY
runs o/r --text
[ "$rrc" = 0 ] && head -1 "$T/runs.out" | grep -qv 'run url =' && [ "$(tail -n +2 "$T/runs.out" | awk -F'\t' 'NF==6' | wc -l)" = "$(tail -n +2 "$T/runs.out" | wc -l)" ] && ok "--text: a url that is not the prefix and the id on some row keeps the url column on every row and no prefix in the header" || bad "text odd url: $(cat "$T/runs.out")"
runs o/nothing
[ "$rrc" = 3 ] && [ ! -s "$T/runs.out" ] && grep -q "ci-runs: no file for o/nothing" "$T/runs.err" && ok "no file for the repo: exit 3, nothing on stdout, the reason on stderr" || bad "missing: rc=$rrc $(cat "$T/runs.out" "$T/runs.err")"
python3 - "$F" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1])); d["updated"] = int(time.time()) - 300; json.dump(d, open(sys.argv[1], "w"))
PY
runs o/r
[ "$rrc" = 4 ] && [ ! -s "$T/runs.out" ] && grep -q "30[0-9]s old (more than --max-age 120s)" "$T/runs.err" && ok "a file 300 s old: exit 4 (stale, default --max-age 120), nothing on stdout" || bad "stale: rc=$rrc $(cat "$T/runs.out" "$T/runs.err")"
runs o/r --max-age 400
[ "$rrc" = 0 ] && ok "--max-age 400 accepts it" || bad "max-age 400: rc=$rrc $(cat "$T/runs.err")"
runs o/r --max-age 0
[ "$rrc" = 0 ] && ok "--max-age 0: no limit" || bad "max-age 0: rc=$rrc"
runs o/r --max-age 100
[ "$rrc" = 4 ] && ok "--max-age 100 refuses it" || bad "max-age 100: rc=$rrc"
printf '{"repo":"o/r","updated":' > "$F"
runs o/r
[ "$rrc" = 5 ] && [ ! -s "$T/runs.out" ] && ok "a file that is not JSON: exit 5" || bad "corrupt: rc=$rrc $(cat "$T/runs.err")"
printf '{"repo":"o/r","runs":[]}\n' > "$F"
runs o/r
[ "$rrc" = 5 ] && ok "a file with no updated: exit 5, never treated as fresh" || bad "no updated: rc=$rrc"
runs; [ "$rrc" = 2 ] && grep -q "usage: salamander ci-runs" "$T/runs.err" && ok "no argument: the usage, exit 2" || bad "no arg: rc=$rrc $(cat "$T/runs.err")"
runs notarepo; [ "$rrc" = 2 ] && ok "a repo that is not owner/name: exit 2" || bad "bad repo: rc=$rrc"
runs ../../etc/x; [ "$rrc" = 2 ] && ok "no path out of the folder through the repo name" || bad "traversal: rc=$rrc"
runs --help; [ "$rrc" = 0 ] && grep -q "usage: salamander ci-runs" "$T/runs.out" && grep -q "ci-poll" "$T/runs.out" && ok "--help: the usage, exit 0" || bad "help: rc=$rrc"

echo "== the folder: XDG_STATE_HOME, else ~/.local/state"
unset SALA_CIRUNS_DIR
fresh2() { rm -rf "$FAKE_DIR"/*; : > "$FAKE_DIR/calls"; mkruns o/r 1 "101:completed:success:$SHA1"; }
fresh2; XDG_STATE_HOME="$T/xdg" poll 1
[ -f "$T/xdg/salamander/ci-runs/o__r.json" ] && XDG_STATE_HOME="$T/xdg" bash "$ROOT/bin/salamander" ci-runs o/r > /dev/null 2>&1 && ok "XDG_STATE_HOME/salamander/ci-runs/<owner>__<repo>.json, and the reader finds it" || bad "xdg: $(find "$T/xdg" 2>&1)"
fresh2; poll 1
[ -f "$HOME/.local/state/salamander/ci-runs/o__r.json" ] && ok "with XDG_STATE_HOME unset: ~/.local/state/salamander/ci-runs/o__r.json" || bad "default: $(find "$HOME/.local" 2>&1)"
export SALA_CIRUNS_DIR="$T/out"

echo "== a stuck run: queued past the limit with no jobs, flagged once"
S="$T/ci-stuck.json"; TABLE="$T/table"; export SALA_JOB_REPOS="$TABLE"
printf '# repo\tcheckout\tuser\tsystem\tflow\tproject\tbuilder\tnote\tgithub\nr\t-\t-\t-\tpr\t-\tex-builder\t-\to/r\n*\t-\t-\t-\t-\t-\tex-general\t-\tp/q\n' > "$TABLE"
stuckruns() {  # <n> <id|status|age s|workflow|event|branch|pr>… → o/r's n-th run list; the ages count back from now, \n in a name is a newline
    local n="$1"; shift
    python3 - "$FAKE_DIR/o__r.$n.json" "$@" <<'PY'
import json, sys, time
runs = []
for spec in sys.argv[2:]:
    i, st, age, name, event, branch, pr = spec.split("|")
    at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - int(age)))
    runs.append({"id": int(i), "name": name.replace("\\n", "\n"), "head_sha": "a" * 40, "head_branch": branch, "event": event, "status": st,
                 "conclusion": "success" if st == "completed" else None, "created_at": at, "run_started_at": at, "updated_at": at, "html_url": "u", "run_attempt": 1,
                 "pull_requests": [{"number": int(pr)}] if pr else []})
json.dump({"total_count": len(runs), "workflow_runs": runs}, open(sys.argv[1], "w"))
PY
}
nojobs() { local i; for i in "$@"; do echo '{"total_count":0,"jobs":[]}' > "$FAKE_DIR/jobs.$i"; done; }
hasjobs() { local i; for i in "$@"; do echo '{"total_count":2,"jobs":[{"id":1,"status":"queued"}]}' > "$FAKE_DIR/jobs.$i"; done; }
jobreads() { grep -c "actions/runs/${1:-[0-9]*}/jobs" "$FAKE_DIR/calls"; }
state() { jq_ "$S" 'd["repos"]["o/r"].get("'"$1"'", {}).get("state")'; }
# the stand-in builder: an inbox socket that writes one line per message, and a process named claude in a pane of the private server
mkdir -p "$T/fakebin" "$HOME/.claude/sessions"; cp "$(command -v bash)" "$T/fakebin/claude"; : > "$T/inbox"
python3 - "$T/s.sock" "$T/inbox" "$T/stop" <<'PY' &
import os, socket, sys, time
path, out, stop = sys.argv[1:]
s = socket.socket(socket.AF_UNIX); s.bind(path); s.listen(8); s.settimeout(0.2)
end = time.time() + 600
while not os.path.exists(stop) and time.time() < end:
    try:
        c, _ = s.accept()
    except socket.timeout:
        continue
    c.settimeout(5); data = b""
    while True:
        part = c.recv(65536)
        if not part: break
        data += part
    c.close()
    open(out, "ab").write(data)
PY
listener=$!
builder_up() {
    command tmux -L "$SOCK" -f /dev/null new-session -d -s ex-builder "exec '$T/fakebin/claude' -c 'sleep 600; true'"
    bpid=$(command tmux -L "$SOCK" -f /dev/null list-panes -t '=ex-builder:' -F '#{pane_pid}')
    waitfor '[ "$(cat "/proc/$bpid/comm" 2>/dev/null)" = claude ] && [ -S "$T/s.sock" ]' 40
    printf '{"pid":%s,"sessionId":"fake-session-1","status":"idle","messagingSocketPath":"%s"}\n' "$bpid" "$T/s.sock" > "$HOME/.claude/sessions/$bpid.json"
}
builder_down() { command tmux -L "$SOCK" -f /dev/null kill-server 2>/dev/null; rm -f "$HOME"/.claude/sessions/*.json; }
msgs() { wc -l < "$T/inbox"; }
text() { python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readlines()[int(sys.argv[2])])["message"]["content"])' "$T/inbox" "$1"; }

fresh
stuckruns 1 "101|queued|2700|tests|pull_request|feat-a|12" "102|queued|2700|lint|pull_request|feat-b|13" "103|queued|600|build|push|main|" "104|in_progress|2700|e2e|push|main|" \
    "105|queued|2700|nightly|schedule|main|" "106|queued|2700|docs|push|dev|" "108|completed|2000|pack|pull_request|feat-c|14" "107|queued|3000|pack|pull_request|feat-c|14"
nojobs 101 103 104 107; hasjobs 102; printf 'HTTP/2.0 500 Server Error\r\n\r\n{}\n' > "$FAKE_DIR/jobs.105.raw"; echo '{}' > "$FAKE_DIR/jobs.106"
poll 8
[ "$prc" = 0 ] && [ "$(state 101)" = pending ] && [ "$(msgs)" = 0 ] && grep -q 'stuck run o/r 101: kept pending, ex-builder is not live' "$T/poll.log" \
    && ok "the staged run (queued 45 min, no jobs) is found; its builder is not live: kept pending, nothing sent" || bad "pending: rc=$prc $(cat "$T/poll.log" "$S")"
[ "$(jobreads 101) $(jobreads 102) $(jobreads 105) $(jobreads 106) $(jobreads)" = "1 1 1 1 4" ] && ok "one jobs read each for the four runs past the limit over eight passes; none for the young, the running and the superseded one" || bad "reads: $(cat "$FAKE_DIR/calls")"
[ "$(state 102) $(state 105) $(state 106)" = "queued queued queued" ] && [ "$(state 103)" = queued ] && [ "$(state 104) $(state 107)" = "None superseded" ] \
    && ok "not flagged: a run with a job, a failed jobs read, an unreadable one, a young one, a running one (not remembered), a superseded one (marked)" || bad "states: $(cat "$S")"
grep -q 'stuck run o/r 105: not judged, HTTP 500' "$T/poll.log" && grep -q 'stuck run o/r 106: not judged, HTTP 200' "$T/poll.log" && ok "a failed and an unreadable jobs read are logged as not judged" || bad "log: $(cat "$T/poll.log")"
builder_up
mkdir -p "$HOME/.local/state/salamander/pause"; printf 'pid=%s\nat=%s\n' "$bpid" "$(date +%s)" > "$HOME/.local/state/salamander/pause/fake-session-1.paused"
poll 3
[ "$(msgs)" = 0 ] && [ "$(state 101)" = pending ] && grep -q 'kept pending, ex-builder is paused' "$T/poll.log" && ok "a restarted poller keeps it; a paused builder gets nothing yet" || bad "paused: $(cat "$T/poll.log")"
rm -rf "$HOME/.local/state/salamander/pause"
poll 5
waitfor '[ "$(msgs)" -ge 1 ]' 20
[ "$(msgs)" = 1 ] && [ "$(state 101)" = sent ] && grep -q 'stuck run o/r 101: told ex-builder' "$T/poll.log" && ok "the builder live: the pending message is delivered, once" || bad "deliver: msgs=$(msgs) $(cat "$T/poll.log" "$S")"
m=$(text 0)
[[ "$m" == "[sala ci] A GitHub Actions run of o/r is stuck: queued for over 30 min with no jobs. Workflow \"tests\", run 101, branch \"feat-a\", PR #12, event pull_request: https://github.com/o/r/actions/runs/101"* ]] \
    && [[ "$m" == *"cannot be cancelled or rerun. Make a new run: close and reopen PR #12, or push a commit to it"* ]] && ok "the message names the repo, workflow, run, branch, PR, URL and how to make a new run" || bad "message: $m"
poll 6; SALA_CIPOLL_STUCK_RECHECK=0 poll 6
[ "$(msgs)" = 1 ] && [ "$(jobreads 101)" = 1 ] && ok "two more restarts, every other run read again: no second message, run 101 not read again" || bad "repeat: msgs=$(msgs) $(cat "$FAKE_DIR/calls")"
[ -z "$(grep -vE '^gh api repos/[^ ]+ -i( -H If-None-Match: [^ ]+)?$' "$FAKE_DIR/calls")" ] && ok "flag only: every gh call is a plain GET of the API" || bad "calls: $(grep -vE '^gh api repos/[^ ]+ -i' "$FAKE_DIR/calls")"
[ -z "$(ls "$T" | grep 'ci-stuck.json.')" ] && [ "$(ls "$SALA_CIRUNS_DIR")" = o__r.json ] && [ "$(jq_ "$F" 'sorted(d["runs"][0].keys())==sorted(["conclusion","created_at","event","head_branch","head_sha","html_url","id","name","run_attempt","status","updated_at"])')" = True ] \
    && ok "the record is ci-stuck.json beside the ci-runs folder; the runs file keeps its shape" || bad "files: $(ls "$T" "$SALA_CIRUNS_DIR")"
: > "$T/inbox"; fresh; stuckruns 1 "111|queued|2700|tests|pull_request|feat-a|12"; nojobs 111
SALA_CIPOLL_STUCK_RECHECK=0 poll 10
waitfor '[ "$(msgs)" -ge 1 ]' 20
[ "$(msgs)" = 1 ] && [ "$(jobreads 111)" = 1 ] && ok "one poller, ten passes, builder live from the start: one message" || bad "once: msgs=$(msgs) $(cat "$T/poll.log")"

echo "== no known builder"
: > "$T/inbox"; fresh; printf 'o/r\np/q\n' > "$REPOS"; stuckruns 1 "121|queued|2700|tests|push|main|" "122|queued|2700|lint|push|main|"; cp "$FAKE_DIR/o__r.1.json" "$FAKE_DIR/p__q.1.json"; nojobs 121 122
printf 'x\t-\t-\t-\tpr\t-\tex-builder\t-\to/other\n*\t-\t-\t-\t-\t-\tex-builder\t-\to/r\nq\t-\t-\t-\tpr\t-\t-\t-\tp/q\n' > "$TABLE"
SALA_CIPOLL_STUCK_RECHECK=0 poll 6
[ "$(grep -c 'no builder for o/r in the repo table' "$T/poll.log")" = 1 ] && [ "$(grep -c 'no builder for p/q' "$T/poll.log")" = 1 ] && [ "$(jobreads)" = 0 ] && [ "$(msgs)" = 0 ] && ! grep -q 'status=queued' "$FAKE_DIR/calls" \
    && ok "a repo the table gives no builder (the * row and a - do not count) is logged once: no jobs or queued-runs read, no message" || bad "nobuilder: $(cat "$T/poll.log" "$FAKE_DIR/calls")"
printf 'r\t-\t-\t-\tpr\t-\tex-builder\t-\tO/R\n' > "$TABLE"
poll 4
waitfor '[ "$(msgs)" -ge 2 ]' 20
[ "$(msgs)" = 2 ] && [[ "$(text 0)" == *'run 121, branch "main", event push'*"push a new commit to that branch"* ]] && ok "the line added later (any letter case): both runs are flagged, a push run with its own advice" || bad "added: msgs=$(msgs) $(cat "$T/poll.log")"
printf 'r\t-\t-\t-\tpr\t-\tex-builder\t-\to/r\n' > "$TABLE"

echo "== bounds: reads in a pass, a rate limit, a hang"
builder_down
many=(); for i in 1 2 3 4 5 6 7 8; do many+=("13$i|queued|2700|w$i|push|main|"); done
fresh; stuckruns 1 "${many[@]}"; hasjobs 131 132 133 134 135 136 137 138
SALA_CIPOLL_STUCK_READS=3 poll 1
[ "$(jobreads)" = 3 ] && ok "eight runs past the limit, a bound of 3: one pass makes 3 extra reads" || bad "bound: $(jobreads)"
fresh; stuckruns 1 "${many[@]}"; hasjobs 131 132 133 134 135 136 137 138
poll 5
[ "$(jobreads)" = 8 ] && ok "the default bound (5) over five passes: each of the eight read once, then none until the recheck time" || bad "bound: $(jobreads)"
fresh; stuckruns 1 "141|queued|2700|a|push|main|" "142|queued|2700|b|push|main|"; nojobs 142
printf 'HTTP/2.0 403 Forbidden\r\nRetry-After: 30\r\n\r\n{}\n' > "$FAKE_DIR/jobs.141.raw"
poll 4
[ "$(jobreads)" = 1 ] && [ "$(asks)" = 1 ] && grep -q 'stuck run o/r 141: not judged, HTTP 403.*rate limit; waiting for it to reset' "$T/poll.log" \
    && ok "a rate limit met by a jobs read: no further read of any kind during the wait" || bad "rate: asks=$(asks) $(cat "$T/poll.log" "$FAKE_DIR/calls")"
fresh; stuckruns 1 "151|queued|2700|a|push|main|"; echo 60 > "$FAKE_DIR/jobs.151.sleep"
t0=$(date +%s); SALA_CIPOLL_STUCK_TIMEOUT=0.5 poll 3; took=$(( $(date +%s) - t0 ))
[ "$prc" = 0 ] && [ "$took" -lt "$(scale 25)" ] && [ "$(asks)" -ge 2 ] && [ "$(state 151)" = queued ] && grep -q 'stuck run o/r 151: not judged, HTTP ? TimeoutExpired' "$T/poll.log" \
    && ok "a jobs read that hangs is cut off (${took} s), flags nothing, and the polling goes on" || bad "hang: rc=$prc took=$took $(cat "$T/poll.log")"

echo "== a run that left the list"
: > "$T/inbox"; fresh; builder_up
stuckruns 1 "161|queued|0|ci|merge_group|gh-readonly-queue/main/pr-7-abc|" "162|queued|0|done|push|main|" "163|queued|0|old|push|main|"
python3 - "$FAKE_DIR/o__r.1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["workflow_runs"][0]["name"] = 'c"i\nsecond line'; json.dump(d, open(sys.argv[1], "w"))
PY
stuckruns 2 "164|completed|0|old|push|main|"
echo '{"status":"queued"}' > "$FAKE_DIR/run.161"; echo '{"status":"completed"}' > "$FAKE_DIR/run.162"; echo '{"status":"queued"}' > "$FAKE_DIR/run.163"; nojobs 161 162 163
SALA_CIPOLL_STUCK_AFTER=5 poll 80   # the first pass is well inside 5 s of the lists, the last well past it
waitfor '[ "$(msgs)" -ge 1 ]' 20
[ "$(msgs)" = 1 ] && [ "$(state 161)" = sent ] && [ "$(state 162) $(state 163)" = "None superseded" ] && [ "$(jobreads)" = 1 ] && [ "$(grep -cE 'actions/runs/163( |/)' "$FAKE_DIR/calls")" = 0 ] \
    && ok "a run seen queued that left the list is still judged (its status, then its jobs); one that completed is forgotten, a superseded one is not read" || bad "left: msgs=$(msgs) $(cat "$T/poll.log" "$FAKE_DIR/calls" "$S")"
m=$(text 0)
[[ "$m" == *'Workflow "c?i?second line", run 161, branch "gh-readonly-queue/main/pr-7-abc", PR #7, event merge_group'*"remove PR #7 from the merge queue"* ]] && ok "a merge queue run: the PR from its branch, the queue's advice; a name from GitHub stays one line with no quote" || bad "queue message: $m"

echo "== a run never in the list: the read of the queued runs"
queuedlist() { stuckruns q "$@"; mv "$FAKE_DIR/o__r.q.json" "$FAKE_DIR/queued.o__r.json"; }
qreads() { grep -c 'actions/runs?status=queued&per_page=100' "$FAKE_DIR/calls"; }
: > "$T/inbox"; fresh; stuckruns 1 "190|completed|100|tests|push|main|" "191|completed|200|lint|push|main|"
queuedlist "181|queued|259200|nightly|schedule|main|" "182|queued|259300|tests|push|main|"
echo '{"status":"queued"}' > "$FAKE_DIR/run.181"; echo '{"status":"queued"}' > "$FAKE_DIR/run.182"; nojobs 181 182
poll 8
waitfor '[ "$(msgs)" -ge 1 ]' 20
[ "$(msgs)" = 1 ] && [[ "$(text 0)" == *'Workflow "nightly", run 181, '* ]] && [ "$(state 181)" = sent ] && [ "$(jobreads 181)" = 1 ] && [ "$(qreads)" = 1 ] \
    && ok "a run queued for three days that the 30-run list never held is found by the queued-runs read (one in eight passes) and flagged once" || bad "queued read: msgs=$(msgs) q=$(qreads) $(cat "$T/poll.log" "$S")"
[ "$(state 182)" = superseded ] && [ "$(jobreads 182)" = 0 ] && ok "one found there with a newer run of its workflow in the list is superseded: not read, not flagged" || bad "superseded: $(cat "$S")"
stuckruns 1 "192|completed|100|other|push|main|"
SALA_CIPOLL_STUCK_LIST=0 poll 4
[ "$(msgs)" = 1 ] && [ "$(state 182)" = superseded ] && [ "$(jobreads 182) $(jobreads 181)" = "0 1" ] && [ "$(qreads)" = 5 ] && [ "$(grep -c 'status=queued.*If-None-Match' "$FAKE_DIR/calls")" = 3 ] \
    && ! grep -q 'queued runs not read' "$T/poll.log" && ok "after a restart, with the newer run gone: asked again with the ETag (304), still superseded, no second message" || bad "304: q=$(qreads) $(cat "$T/poll.log" "$FAKE_DIR/calls")"
fresh; stuckruns 1 "193|completed|100|tests|push|main|"; printf 'HTTP/2.0 500 Server Error\r\n\r\n{}\n' > "$FAKE_DIR/queued.o__r.raw"
SALA_CIPOLL_STUCK_LIST=0 poll 3
[ "$prc" = 0 ] && [ "$(asks)" -ge 2 ] && [ "$(qreads)" -ge 2 ] && grep -q 'o/r: queued runs not read, HTTP 500' "$T/poll.log" && [ "$(jobreads)" = 0 ] \
    && ok "a failed queued-runs read is logged and flags nothing; the polling goes on" || bad "queued 500: $(cat "$T/poll.log")"
fresh; stuckruns 1 "194|completed|100|tests|push|main|"; printf 'HTTP/2.0 429 Too Many Requests\r\nRetry-After: 30\r\n\r\n{}\n' > "$FAKE_DIR/queued.o__r.raw"
SALA_CIPOLL_STUCK_LIST=0 poll 4
[ "$(qreads)" = 1 ] && [ "$(asks)" = 1 ] && grep -q 'queued runs not read, HTTP 429.*rate limit; waiting for it to reset' "$T/poll.log" \
    && ok "a rate limit met by the queued-runs read: no read of any kind during the wait" || bad "queued 429: asks=$(asks) $(cat "$T/poll.log" "$FAKE_DIR/calls")"
builder_down
fresh; stuckruns 1 "171|queued|2700|a|push|main|"; hasjobs 171; printf 'not json' > "$S"
poll 2
[ -f "$S.bad" ] && [ "$(state 171)" = queued ] && grep -q 'is not a stuck-run record: moved to' "$T/poll.log" && ok "a record that is not one is moved aside and a new one started" || bad "bad record: $(cat "$T/poll.log")"
unset SALA_JOB_REPOS

echo "== the unit"
U="$ROOT/systemd/sala-cipoll.service"
grep -q '^X-Model-Lane=none$' "$U" && grep -q '^Restart=always$' "$U" && grep -q '^ExecStart=%h/.local/bin/salamander ci-poll$' "$U" && grep -q '^Description=.\+' "$U" && grep -q '^WantedBy=default.target$' "$U" \
    && ok "sala-cipoll.service: Description, lane none, ExecStart salamander ci-poll, Restart=always" || bad "unit: $(cat "$U")"

[ "$fail" = 0 ]
