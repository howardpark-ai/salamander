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
# limit, corrupt = 5, usage = 2, the path under XDG_STATE_HOME and under ~/.local/state; the unit file. Not checked: the real gh and GitHub, systemd.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/sala-cipoll.XXXXXX")
exec 8< "$T"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME/bin"; export PATH="$HOME/bin:$PATH"
unset SALA_CONFIG SALA_LOG_DIR XDG_STATE_HOME XDG_CONFIG_HOME SALA_CIPOLL_REPOS SALA_CIPOLL_CYCLES SALA_CIPOLL_INTERVAL SALA_CIPOLL_BACKOFF_MAX SALA_CIRUNS_DIR
export FAKE_DIR="$T/fake"; mkdir -p "$FAKE_DIR"
REPOS="$T/repos"; export SALA_CIRUNS_DIR="$T/out" SALA_CIPOLL_REPOS="$REPOS"
export SALA_CIPOLL_INTERVAL=0.1

cat > "$HOME/bin/gh" <<'FAKE'
#!/bin/bash
echo "gh $*" >> "$FAKE_DIR/calls"
[ "$1" = api ] || exit 9
path="$2"; inm=
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
fresh() { rm -rf "$FAKE_DIR"/* "$SALA_CIRUNS_DIR"; : > "$FAKE_DIR/calls"; printf 'o/r\n' > "$REPOS"; }
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
[ "$rrc" = 0 ] && [ "$(wc -l < "$T/runs.out")" = 3 ] && grep -q "^102	in_progress/-	b-102	2222222	tests	https://github.com/x/y/actions/runs/102$" "$T/runs.out" && head -1 "$T/runs.out" | grep -q '^# o/r, updated 20.*2 run(s) of 2222222' && ok "--text: a header and one tab-separated line a run" || bad "text: $(cat "$T/runs.out")"
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

echo "== the unit"
U="$ROOT/systemd/sala-cipoll.service"
grep -q '^X-Model-Lane=none$' "$U" && grep -q '^Restart=always$' "$U" && grep -q '^ExecStart=%h/.local/bin/salamander ci-poll$' "$U" && grep -q '^Description=.\+' "$U" && grep -q '^WantedBy=default.target$' "$U" \
    && ok "sala-cipoll.service: Description, lane none, ExecStart salamander ci-poll, Restart=always" || bad "unit: $(cat "$U")"

[ "$fail" = 0 ]
