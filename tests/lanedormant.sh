#!/usr/bin/env bash
# The dormant record (lib/common.sh "THE DORMANT RECORD", lib/watch.sh "THE DORMANT RECORD'S
# SIGNALS", lib/lane.sh, lib/spawn.sh): one record per lane, active or dormant, with a reason and since, kept by sala's watch
# (plain shell and python3, no Claude turn) and read by everything that touches a lane. Checked here:
#   THE RECORD: lane-state.tsv beside lanes.tsv, one row per lane (lane, state, reason, since ISO, posted, by); absent = active;
#     keyed by lane id (sdk is api's alias, a lane id from the table needs nothing more); one line per change in lanes.log; no
#     temp file left behind; two writers in turn lose nothing.
#   THE SIGNALS (set dormant once, with a reason, by the watch, from detections it already makes): Team — the sign-in watch's
#     verdict is wrong (a Team directory signed in without a seat's subscription, or signed out), or sala-web's saved usage answer
#     says "refused"; Ultra — the login no longer reports Max; api and sdk — the limit watch has a pane stopped on the real
#     "Credit balance is too low" record (tests/fixtures/limit-billing.jsonl). A second tick changes nothing (reason and since
#     of the first stand); an old refusal / an old credit stop (older than the lane's last change) is not a new signal.
#   THE EFFECTS: `sala lane <lane> <session>`, `lane default <lane>`, `lane --rescue <lane>` and `spawn --lane <lane>` refuse to
#     move onto a dormant lane in plain words, and a spawn with a dormant default refuses too; spawn's list of lanes hides it;
#     `sala lane` shows it with its reason and since (and a note on a session still on it); lane_out counts it out; the web
#     side is web/tests/test_lane_dormant.py. The sessions still on it are posted ONCE per dormant episode (plain words, no
#     alarming word, the count and "moving them is your call"), never twice, a new episode posts again, none posted while no
#     session is on it; nothing is moved, relaunched or stopped.
#   COMING BACK: a login lane (subscription-1, subscription-2) the watch set dormant comes back on its own at the daily look, with the existing
#     sign-in check and a line in the log, not before (SALA_LANE_REVIVE_EVERY), and not while the look still finds it wrong; one
#     set by hand is held; the API lane (api, sdk) comes back only on `sala lane active api` — no check ever brings it back, and
#     no test call is made. `sala lane dormant|active <lane>` set any lane by hand; --dry-run writes nothing.
# UNVERIFIED by design: what the live Team sign-in check prints without a seat. The fake `claude auth status --json` here answers
# the shapes the sign-in watch already reads (signed in with another subscription, signed in with no subscription, signed out).
# Slack is a file (SALA_NOTIFY_CMD); the API of the sign-in watch is never reached (no key file; its URL points at a closed port);
# a private tmux socket that is never started, so no real pane is touched except the throwaway fake claude of the credit case.
# Isolated HOME. Usage: bash tests/lanedormant.sh   (exit 0 = pass; ~40 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_TZ CLAUDE_CONFIG_DIR ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_CUSTOM_HEADERS CLAUDE_CODE_OAUTH_TOKEN
unset SALA_LANE_API_KEY_FILE SALA_LANE_API_WORKSPACE_FILE SALA_LANE_API_MCP_CONFIG SALA_LANE_TEAM_DIR SALA_MASTER SALA_CLAUDE SALA_SIGNIN_ALERT SALA_WEB_STATE_DIR SALA_LANE_REVIVE_EVERY
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export SALA_SIGNIN_ALERT=on   # lib.sh turns the step off for every other suite; the signals live in it
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
TEAM="$HOME/.claude-team"; P="$HOME/.claude/projects/x"
mkdir -p "$HOME/.claude/sessions" "$P" "$TEAM" "$HOME/.local/bin" "$HOME/work" "$HOME/.local/state/sala-web"
touch "$HOME/.claude/salamander-rc.stopped"
export PATH="$HOME/.local/bin:$PATH"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="cat >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_LIMIT_RESUME=off SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off
export SALA_SIGNIN_EVERY=0 SALA_SIGNIN_API_EVERY=0 SALA_SIGNIN_API_URL="http://127.0.0.1:9/v1/messages"   # every tick looks; the API is never reached (no key file here)
export SALA_WEB_STATE_DIR="$HOME/.local/state/sala-web"
SOCK="sala-lanedormant-$$"; unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux
SALA="$ROOT/bin/salamander"; WLOG="$HOME/.claude/salamander-watch.log"
cleanup() {
    local p; command tmux -L "$SOCK" kill-server 2>/dev/null; tmux_socket_rm
    for p in $(pgrep -x claude 2>/dev/null); do [ "$HOME/fakebin/claude" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
# the fake claude of the sign-in cases: `auth status --json` answers from <config dir>/auth.json (the shapes CLI 2.1.299 printed);
# swapped for the compiled fake in the credit case, which needs a pane that looks like a claude
cat > "$HOME/.local/bin/claude" <<'EOF'
#!/bin/bash
d="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
case "$1 $2" in "auth status") cat "$d/auth.json" 2>/dev/null; rc=$(cat "$d/auth.rc" 2>/dev/null); exit "${rc:-0}";; esac
exit 0
EOF
chmod +x "$HOME/.local/bin/claude"
signed_in() {  # <dir> <subscriptionType or ""> <orgName>
    local sub=""; [ -n "$2" ] && sub=",
  \"subscriptionType\": \"$2\""
    printf '{\n  "loggedIn": true,\n  "authMethod": "claude.ai",\n  "apiProvider": "firstParty",\n  "configDirectory": "%s",\n  "email": "someone@example.com",\n  "orgId": "00000000-0000-4000-8000-000000000000",\n  "orgName": "%s"%s\n}\n' "$1" "$3" "$sub" > "$1/auth.json"; rm -f "$1/auth.rc"; }
signed_out() { printf '{\n  "loggedIn": false,\n  "authMethod": "none",\n  "apiProvider": "firstParty",\n  "configDirectory": "%s"\n}\n' "$1" > "$1/auth.json"; echo 1 > "$1/auth.rc"; }
printf '{"fake":true}\n' > "$TEAM/.credentials.json"
signed_in "$HOME/.claude" max "someone@example.com's Organization"; signed_in "$TEAM" team ExampleOrg
. "$ROOT/lib/common.sh"
REC="$SALA_LANE_STATE"; LOGF="$SALA_LANE_LOG"
sw() { "$SALA" watch --signin >/dev/null 2>&1; }
lw() { SALA_LIMIT_CONFIRM=0 SALA_LIMIT_PSTART="*=0" "$SALA" watch --limit >/dev/null 2>&1; }
dposts() { local n; n=$(grep -c 'lane is dormant' "$POSTS" 2>/dev/null); echo "${n:-0}"; }   # the dormant posts (the sign-in watch posts its own alerts beside them)
dpost() { awk -v h="*The $1 lane is dormant*" '/^[^ ]/ {on = index($0, h) > 0} on {print}' "$POSTS" 2>/dev/null; }   # <Label> → that lane's dormant posts, each whole
f() { lane_state_field "$1" "$2"; }   # <lane> <column>: 2 state, 3 reason, 4 since, 5 posted, 6 by
logn() { local n; n=$(grep -c -- "$1" "$LOGF" 2>/dev/null); echo "${n:-0}"; }   # lines of lanes.log with that text
wl() { grep -c -- "$1" "$WLOG" 2>/dev/null || true; }
backdate() {  # <lane> <seconds>: the record's since moved that far into the past (a day passing)
    local iso; iso=$(lane_iso $(( $(date +%s) - $2 )))
    awk -F'\t' -v OFS='\t' -v l="$1" -v t="$iso" '$1==l {$4=t} {print}' "$REC" > "$REC.x" && mv -f "$REC.x" "$REC"; }
reset_all() { rm -f "$REC" "$REC.lock" "$LOGF" "$POSTS" "$HOME/.local/state/salamander/lane-signin.state" "$HOME/.local/state/salamander/lanes.tsv" "$SALA_WEB_STATE_DIR"/quota-*.json "$WLOG"; : > "$POSTS"; }
mkdir -p "$SALA_STATE_DIR"; : > "$POSTS"

echo "== the record: absent is active; one row per lane; set once; sdk is api's"
lane_dormant subscription-2 && bad "no file: subscription-2 reads dormant" || ok "no file: every lane is active"
[ "$(lane_choices)" = "$SALA_LANES_KNOWN" ] && ok "no file: the picker offers every lane ($SALA_LANES_KNOWN)" || bad "lane_choices: $(lane_choices)"
lane_dormant_set subscription-2 "no seat" signal "$(( $(date +%s) - 90000 ))"; rc=$?
[ "$rc" = 0 ] && lane_dormant subscription-2 && ok "lane_dormant_set: the lane is dormant (rc 0 when this call made it)" || bad "set rc=$rc"
[ "$(f subscription-2 2)|$(f subscription-2 3)|$(f subscription-2 6)|$(f subscription-2 5)" = "dormant|no seat|signal|" ] && ok "the row: dormant, the reason, by signal, not posted" || bad "row: $(<"$REC")"
case "$(f subscription-2 4)" in 20[0-9][0-9]-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]Z) ok "since is an ISO time (UTC)";; *) bad "since: $(f subscription-2 4)";; esac
s0=$(f subscription-2 4); lane_dormant_set subscription-2 "another reason" hand; rc=$?
[ "$rc" = 3 ] && [ "$(f subscription-2 3)|$(f subscription-2 4)|$(f subscription-2 6)" = "no seat|$s0|signal" ] && ok "set again: nothing changes (rc 3), the first reason, since and signer stand" || bad "second set rc=$rc row: $(<"$REC")"
[ "$(logn dormant)" = 1 ] && ok "one lanes.log line for the change" || bad "lanes.log: $(<"$LOGF")"
[ "$(awk -F'\t' '$1=="subscription-2"' "$REC" | wc -l)" = 1 ] && [ "$(ls "$SALA_STATE_DIR" | grep -c 'lane-state.tsv.t\.')" = 0 ] && ok "one row for the lane, no temp file left" || bad "files: $(ls "$SALA_STATE_DIR")"
lane_dormant sdk && bad "sdk reads dormant while api is not" || ok "sdk is api's alias: not dormant while api is not"
lane_dormant_set sdk "credit used up" signal; rc=$?
[ "$rc" = 0 ] && lane_dormant api && lane_dormant sdk && [ "$(awk -F'\t' '$1=="api" || $1=="sdk"' "$REC" | cut -f1 | paste -sd,)" = api ] && ok "a signal on sdk is the api lane's row (one record for the shared key)" || bad "alias: $(<"$REC")"
[ "$(lane_choices)" = "subscription-1 bedrock aws-platform" ] && ok "the picker hides subscription-2, api and sdk while dormant: $(lane_choices)" || bad "lane_choices: $(lane_choices)"
lane_dormant_set nosuchlane x hand && bad "an unknown lane was recorded" || ok "a word that is no lane is refused"
lane_dormant_set bedrock "not set up" hand && lane_dormant bedrock && ok "a lane id from the table needs nothing more (bedrock)" || bad "bedrock"
lane_dormant_clear bedrock "test"; lane_dormant bedrock && bad "bedrock still dormant" || ok "cleared: active again (the row says active, not gone)"
[ "$(f bedrock 2)" = active ] && [ -n "$(f bedrock 4)" ] && ok "the active row keeps when it came back" || bad "bedrock row: $(awk -F'\t' '$1=="bedrock"' "$REC")"
lane_dormant_clear subscription-1 x; rc=$?; [ "$rc" = 3 ] && ok "clearing a lane that was not dormant: rc 3, nothing written" || bad "clear rc=$rc"
w=$(lane_dormant_words subscription-2); [ "$w" = "Team: dormant, no seat since $(lane_day "$(f subscription-2 4)")" ] && ok "the words: '$w'" || bad "words: $w"
case "$w" in *" since "[A-Z][a-z][a-z]" "[A-Z][a-z][a-z]" "[0-9]*[a-z][a-z]) ok "the day reads 'Wed Jan 7th'";; *) bad "day format: $w";; esac
[ "$(lane_day 2026-01-07T03:00:00Z)|$(lane_day 2026-01-08T15:30:00Z)|$(lane_day 2026-01-02T00:00:00Z)|$(lane_day 2026-01-13T00:00:00Z)" = "Wed Jan 7th|Thu Jan 8th|Fri Jan 2nd|Tue Jan 13th" ] && ok "the day is in the suite zone with the ordinal" || bad "lane_day: $(lane_day 2026-01-07T03:00:00Z)|$(lane_day 2026-01-08T15:30:00Z)|$(lane_day 2026-01-02T00:00:00Z)|$(lane_day 2026-01-13T00:00:00Z)"
# two writers in turn lose nothing, and a concurrent pair keeps both
for l in subscription-1 bedrock; do ( lane_dormant_set "$l" "w-$l" hand ) & done; wait
[ "$(lane_dormant subscription-1 && lane_dormant bedrock && lane_dormant subscription-2 && lane_dormant api && echo 4)" = 4 ] && ok "four writers, two at once: four rows, none lost" || bad "rows: $(<"$REC")"
reset_all

echo "== the verbs by hand: dormant / active, --reason, --dry-run, the table"
out=$("$SALA" lane dormant subscription-2 --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "[dry-run] would mark the Team lane dormant (set by hand)" && [ ! -e "$REC" ] && ok "dormant --dry-run: says what it would do, writes nothing" || bad "dry-run ($rc): $out"
out=$("$SALA" lane dormant subscription-2 --reason "no seat since the plan change" 2>&1); rc=$?
[ "$rc" = 0 ] && lane_dormant subscription-2 && [ "$(f subscription-2 3)|$(f subscription-2 6)" = "no seat since the plan change|hand" ] && has "$out" "Team: dormant, no seat since the plan change since" && ok "dormant --reason: recorded by hand, said back in words" || bad "dormant ($rc): $out; row: $(slurp "$REC")"
out=$("$SALA" lane dormant subscription-2 2>&1); has "$out" "already dormant" && ok "dormant again: 'already dormant', nothing written" || bad "again: $out"
sum0=$(md5sum < "$REC")
out=$("$SALA" lane active subscription-2 --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "[dry-run] would mark the Team lane active again" && [ "$(md5sum < "$REC")" = "$sum0" ] && ok "active --dry-run: the record is byte for byte the same" || bad "active dry-run ($rc): $out"
out=$("$SALA" lane dormant api --reason "credit used up" 2>&1); lane_dormant sdk && ok "dormant api: sdk reads dormant too" || bad "api/sdk: $out"
out=$("$SALA" lane dormant sdk 2>&1); has "$out" "alias of api" && ok "dormant sdk: says it is api's record" || bad "sdk verb: $out"
out=$("$SALA" lane dormant 2>&1); rc=$?; [ "$rc" != 0 ] && has "$out" "usage" && ok "dormant with no lane: usage" || bad "no lane ($rc): $out"
out=$("$SALA" lane dormant nosuch 2>&1); rc=$?; [ "$rc" != 0 ] && has "$out" "unknown lane" && ok "dormant with a word that is no lane: refused" || bad "unknown ($rc): $out"
out=$("$SALA" lane active subscription-2 --reason x 2>&1); rc=$?; [ "$rc" != 0 ] && ok "--reason belongs to dormant: active refuses it" || bad "active --reason ($rc): $out"
out=$("$SALA" lane subscription-2 --reason x 2>&1); rc=$?; [ "$rc" != 0 ] && ok "--reason on a switch: refused" || bad "switch --reason ($rc): $out"
printf 'sala-test-s1\tsubscription-2\nsala-test-s2\tsubscription-2\nsala-test-s3\tapi\nsala-test-s4\tsubscription-1\n' > "$SALA_LANES"
tbl=$("$SALA" lane 2>&1)
has "$tbl" "dormant: Team: dormant, no seat since the plan change since $(lane_day "$(f subscription-2 4)") (set by hand; 2 sessions still on it" && ok "sala lane: the dormant line with the reason and since, and how many sessions are still on it" || bad "table: $tbl"
has "$tbl" "dormant: API: dormant, credit used up since" && has "$tbl" "back only with: salamander lane active api" && ok "sala lane: the API lane's line says it comes back only on 'lane active api'" || bad "api line: $tbl"
has "$tbl" "subscription-2 ready (dormant)" || has "$tbl" "subscription-2 not ready (dormant)" && ok "the lanes line marks it (dormant)" || bad "lanes line: $tbl"
grep -E '^sala-test-s1 ' <<< "$tbl" | grep -q "the Team lane is dormant (no seat since the plan change since" && ok "a session on it carries a note: it stays where it is, moving it is your call" || bad "session note: $tbl"
has "$(<"$SALA_LANES")" "sala-test-s1	subscription-2" && ok "the table touched no lane row" || bad "lanes.tsv changed"
usage=$("$SALA" lane --help 2>&1); has "$usage" "lanes: subscription-1 bedrock aws-platform; dormant: api subscription-2 sdk" && ok "the usage line lists the lanes a pick may take and names the dormant ones" || bad "usage: $(grep -m1 'lanes:' <<< "$usage")"
reset_all; printf 'sala-test-s1\tsubscription-2\n' > "$SALA_LANES"

echo "== refusals: nothing is moved onto a dormant lane"
"$SALA" lane dormant subscription-2 --reason "no seat" >/dev/null 2>&1
default0=$(slurp "$SALA_LANE_DEFAULT_FILE"); sumL=$(md5sum < "$SALA_LANES")
out=$("$SALA" lane subscription-2 sala-test-s1 2>&1); rc=$?
[ "$rc" != 0 ] && has "$out" "the Team lane is dormant (no seat since" && has "$out" "nothing is moved onto it" && has "$out" "salamander lane active subscription-2" && ok "lane subscription-2 <session>: refused in plain words, with the way back" || bad "switch ($rc): $out"
out=$("$SALA" lane subscription-2 sala-test-s1 --dry-run 2>&1); rc=$?
[ "$rc" != 0 ] && has "$out" "is dormant" && ok "… also with --dry-run" || bad "switch dry ($rc): $out"
out=$("$SALA" lane subscription-2 --all --dry-run 2>&1); rc=$?; [ "$rc" != 0 ] && has "$out" "is dormant" && ok "lane subscription-2 --all: refused" || bad "all ($rc): $out"
out=$("$SALA" lane default subscription-2 2>&1); rc=$?
[ "$rc" != 0 ] && has "$out" "the Team lane is dormant" && [ "$(slurp "$SALA_LANE_DEFAULT_FILE")" = "$default0" ] && ok "lane default subscription-2: refused, the default untouched" || bad "default ($rc): $out"
out=$("$SALA" lane --rescue subscription-2 2>&1); rc=$?; [ "$rc" != 0 ] && has "$out" "is dormant" && ok "lane --rescue subscription-2: refused too" || bad "rescue ($rc): $out"
[ "$(md5sum < "$SALA_LANES")" = "$sumL" ] && ok "no lane row was written by any refusal" || bad "lanes.tsv changed"
out=$("$SALA" lane subscription-1 sala-test-nosuch 2>&1); rc=$?; has "$out" "dormant" && bad "a lane that is not dormant was refused as dormant" || ok "a lane that is not dormant is not refused for it (subscription-1 reaches its own checks: $(head -c 60 <<< "$out"))"
out=$("$SALA" spawn sala-test-x --lane subscription-2 --dry-run 2>&1); rc=$?
[ "$rc" != 0 ] && has "$out" "is dormant" && has "$out" "pick one of: subscription-1 api sdk bedrock aws-platform" && ok "spawn --lane subscription-2: refused, and the list it offers leaves subscription-2 out" || bad "spawn lane ($rc): $out"
out=$("$SALA" spawn sala-test-x --lane nosuch --dry-run 2>&1); has "$out" "(one of: subscription-1 api sdk bedrock aws-platform)" && ok "spawn --lane <typo>: the list it prints has no dormant lane" || bad "spawn typo: $out"
"$SALA" lane dormant subscription-1 >/dev/null 2>&1; printf 'subscription-1\n' > "$SALA_LANE_DEFAULT_FILE"
out=$("$SALA" spawn sala-test-x --dry-run 2>&1); rc=$?
[ "$rc" != 0 ] && has "$out" "the default lane is where a new session goes" && ok "spawn with a dormant default lane: refused, says to pick one or move the default" || bad "spawn default ($rc): $out"
"$SALA" lane active subscription-1 >/dev/null 2>&1; printf 'subscription-1\n' > "$SALA_LANE_DEFAULT_FILE"
lane_out subscription-2 >/dev/null && ok "lane_out: a dormant lane is out" || bad "lane_out subscription-2"
lane_out subscription-2 | grep -q "dormant" && ok "… and says why" || bad "lane_out text: $(lane_out subscription-2)"
case " $(lanes_working) " in *" subscription-2 "*) bad "lanes_working lists the dormant subscription-2: $(lanes_working)";; *" subscription-1 "*) ok "lanes_working leaves the dormant subscription-2 out: $(lanes_working)";; *) bad "lanes_working: $(lanes_working)";; esac
"$SALA" lane active subscription-2 >/dev/null 2>&1
out=$("$SALA" lane subscription-2 sala-test-nosuch 2>&1); has "$out" "dormant" && bad "refused after active" || ok "after 'lane active subscription-2' the refusal is gone"
reset_all

echo "== signals: Team, from the sign-in watch's own verdict"
printf 'sala-test-t1\tsubscription-2\nsala-test-t2\tsubscription-2\nsala-test-m1\tsubscription-1\n' > "$SALA_LANES"
sw
lane_dormant subscription-2 && bad "a Team seat in order read dormant" || ok "Team signed in with its seat: nothing recorded"
[ ! -s "$REC" ] && [ "$(posts)" = 0 ] && ok "… no record, no post" || bad "record: $(slurp "$REC")"
signed_in "$TEAM" "" ExampleOrg   # signed in, but no subscription: what a seat taken away may print
sw
[ "$(f subscription-2 2)|$(f subscription-2 3)|$(f subscription-2 6)" = "dormant|no seat|signal" ] && ok "signed in with no subscription: Team dormant, 'no seat', by signal" || bad "no-subscription: $(slurp "$REC"); log: $(tail -3 "$WLOG")"
s1=$(f subscription-2 4); sw; sw
[ "$(f subscription-2 4)" = "$s1" ] && [ "$(logn 'dormant')" = 1 ] && [ "$(wl 'the subscription-2 lane is dormant')" = 1 ] && ok "two more ticks: once only (the first since stands, one lanes.log line, one watch-log line)" || bad "repeat: since $(f subscription-2 4) vs $s1; $(<"$LOGF")"
has "$(<"$WLOG")" "lanes: the subscription-2 lane is dormant — no seat" && ok "the watch log says why" || bad "watch log: $(tail -3 "$WLOG")"
[ "$(dposts)" = 1 ] && ok "one dormant post for the episode (the sign-in watch's own alert is another post)" || bad "dormant posts: $(dposts)"
p=$(dpost Team)
has "$p" "The Team lane is dormant" && has "$p" "no seat since $(lane_day "$s1"), 2 sessions are still on it; moving them is your call" && has "$p" "on it: sala-test-t1, sala-test-t2" && ok "the post: the lane, 'no seat since …, 2 sessions are still on it; moving them is your call', their names" || bad "post: $p"
grep -qiE 'leak|breach|quota|credential|kill|incident|compromis' <<< "$p" && bad "an alarming word in the post: $p" || ok "no alarming word in the post"
grep -q "sala-test-m1" <<< "$p" && bad "a subscription-1 session named in the Team post" || ok "only the sessions on the lane are named"
[ "$(f subscription-2 5)" != "" ] && ok "the post is remembered in the record (posted)" || bad "posted empty: $(<"$REC")"
[ "$(cat "$SALA_LANES" | wc -l)" = 3 ] && [ "$(awk -F'\t' '$1=="sala-test-t1"{print $2}' "$SALA_LANES")" = subscription-2 ] && ok "the sessions stay where they are: lanes.tsv untouched" || bad "lanes.tsv: $(<"$SALA_LANES")"
signed_out "$TEAM"; sw
[ "$(dposts)" = 1 ] && [ "$(f subscription-2 3)" = "no seat" ] && ok "a different wrong state while dormant: still the one episode, no second dormant post" || bad "signed out: dormant posts $(dposts), $(<"$REC")"

echo "== signals: Ultra, the login no longer reports Max"
signed_in "$HOME/.claude" pro "someone@example.com's Organization"; sw
[ "$(f subscription-1 2)|$(f subscription-1 3)|$(f subscription-1 6)" = "dormant|login no longer reports Max|signal" ] && ok "Ultra signed in as Pro: Ultra dormant, 'login no longer reports Max'" || bad "subscription-1: $(<"$REC")"
[ "$(dposts)" = 2 ] && has "$(dpost Ultra)" "The Ultra lane is dormant" && has "$(dpost Ultra)" "1 session is still on it" && ok "its own post: '1 session is still on it'" || bad "subscription-1 post: $(dposts) $(dpost Ultra)"
signed_in "$HOME/.claude" max "someone@example.com's Organization"; signed_in "$TEAM" team ExampleOrg

echo "== coming back: a login lane at the daily look, not before"
sw
lane_dormant subscription-2 && lane_dormant subscription-1 && ok "sign-in right again, but under a day: both stay dormant" || bad "revived early: $(<"$REC")"
backdate subscription-2 90000; backdate subscription-1 90000   # more than a day since each went dormant
sw
lane_dormant subscription-2 && bad "subscription-2 still dormant after the daily look found it right" || ok "a day on, the sign-in is right: Team is active again by itself"
lane_dormant subscription-1 && bad "subscription-1 still dormant" || ok "… and Ultra"
[ "$(f subscription-2 2)" = active ] && has "$(<"$WLOG")" "lanes: the subscription-2 lane is active again" && ok "a line in the watch log, the row says active" || bad "revival log: $(grep lanes: "$WLOG")"
[ "$(logn 'dormant → active')" = 2 ] && ok "lanes.log has the two returns" || bad "lanes.log: $(<"$LOGF")"
before=$(dposts); sw; sw; [ "$(dposts)" = "$before" ] && ok "coming back posts no dormant post" || bad "dormant posts after revival"
echo "-- a look that still finds it wrong keeps it dormant and does not look again for a day"
signed_in "$TEAM" "" ExampleOrg; sw
lane_dormant subscription-2 && ok "wrong again: dormant again (a new episode)" || bad "not dormant again"
[ "$(dposts)" = $((before + 1)) ] && ok "a new episode posts again, once" || bad "dormant posts: $(dposts) vs $before"
backdate subscription-2 90000; sw
lane_dormant subscription-2 && has "$(<"$WLOG")" "the daily look: the subscription-2 lane is still wrong" && ok "the daily look finds it still wrong: stays dormant, says so" || bad "still-wrong look: $(grep -i 'daily' "$WLOG")"
signed_in "$TEAM" team ExampleOrg; sw
lane_dormant subscription-2 && ok "right again an hour later: the next look is a day on, so it waits" || bad "revived inside the day after a look"

echo "== a lane set by hand is held; sign-in does not bring it back"
"$SALA" lane active subscription-2 >/dev/null 2>&1; "$SALA" lane dormant subscription-2 --reason "parked" >/dev/null 2>&1
backdate subscription-2 200000; sw; sw
lane_dormant subscription-2 && [ "$(f subscription-2 6)" = hand ] && ok "dormant by hand, sign-in right, days old: still dormant (only 'lane active subscription-2' brings it back)" || bad "hand lane revived: $(<"$REC")"
"$SALA" lane active subscription-2 >/dev/null 2>&1; lane_dormant subscription-2 && bad "active did not clear" || ok "'sala lane active subscription-2' brings it back"

echo "== signals: Team, the usage check refused (sala-web's saved answer)"
reset_all; signed_in "$TEAM" team ExampleOrg; printf 'sala-test-t1\tsubscription-2\n' > "$SALA_LANES"
printf '{"lane":"subscription-2","limits":[],"errorKind":"refused","nextTry":%s}\n' "$(( ($(date +%s) + 3600) * 1000 ))" > "$SALA_WEB_STATE_DIR/quota-team.json"
sw
[ "$(f subscription-2 2)|$(f subscription-2 3)|$(f subscription-2 6)" = "dormant|usage check refused|signal" ] && ok "a saved 'refused' usage answer: Team dormant, 'usage check refused'" || bad "refused: $(slurp "$REC")"
[ "$(dposts)" = 1 ] && has "$(dpost Team)" "usage check refused since" && ok "posted once, with the reason" || bad "post: $(dposts) $(dpost Team)"
printf '{"lane":"subscription-2","limits":[],"errorKind":"rate_limited","nextTry":1}\n' > "$SALA_WEB_STATE_DIR/quota-team.json"
"$SALA" lane active subscription-2 >/dev/null 2>&1; sw
lane_dormant subscription-2 && bad "a rate-limited answer set Team dormant" || ok "a 429 ('rate_limited') or any other kind is no signal"
printf '{"lane":"subscription-2","limits":[],"errorKind":"refused","nextTry":1}\n' > "$SALA_WEB_STATE_DIR/quota-team.json"; touch -d '2 days ago' "$SALA_WEB_STATE_DIR/quota-team.json"
sw
lane_dormant subscription-2 && bad "an old refusal (older than the lane's last change) set it again" || ok "a refusal saved before the lane was last set active is the old episode, not a signal"
touch "$SALA_WEB_STATE_DIR/quota-team.json"; sleep 1; touch "$SALA_WEB_STATE_DIR/quota-team.json"; sw
lane_dormant subscription-2 && ok "a newer refusal is a new signal" || bad "newer refusal ignored (record: $(<"$REC"))"

echo "== signals: the API credit, from the limit watch's own record (no network, no test call)"
reset_all
mkdir -p "$HOME/fakebin"; cc -o "$HOME/fakebin/claude" "$ROOT/tests/fake-claude.c" -lpthread || { echo "  FAIL cc"; exit 1; }   # the panes run this one; sala's own CLI (SALA_CLAUDE, the sign-in stub) stays the script above
export FAKE_LOG="$HOME/fake.log" FAKE_SOCK_LOG="$HOME/sock.log"
UD=dddddddd-0000-4000-8000-0000000000d1; UE=eeeeeeee-0000-4000-8000-0000000000e1
for n in d e; do
    u=UD; [ $n = e ] && u=UE
    tmux new-session -d -s "sala-test-$n" -c "$HOME/work" -e FAKE_SESSION_ID="${!u}" -e FAKE_NAME="sala-test-$n" -e FAKE_LOG="$FAKE_LOG" -e FAKE_SOCK_LOG="$FAKE_SOCK_LOG" -e ANTHROPIC_API_KEY="dummy-not-real-$$"
    tmux send-keys -t "sala-test-$n" "$HOME/fakebin/claude" Enter
done
fake_up sala-test-d sala-test-e || { echo "  FAIL the fake claudes did not come up"; exit 1; }
printf 'sala-test-d\tapi\nsala-test-e\tsdk\n' > "$SALA_LANES"
NOW=$(date +%s)
credit_rec() {  # <uuid> <epoch>: the REAL billing_error record (tests/fixtures/limit-billing.jsonl), its placeholders filled
    sed -e "s|@UUID@|eeeeeeee-0000-4000-8000-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')|" -e "s|@TS@|$(iso "$2")|" -e "s|@CWD@|$HOME/work|" -e "s|@SESSION@|$1|" "$ROOT/tests/fixtures/limit-billing.jsonl" >> "$P/$1.jsonl"; }
lw
lane_dormant api && bad "api dormant with no error anywhere" || ok "no credit error: api stays active"
credit_rec "$UD" $((NOW - 3000)); credit_rec "$UE" $((NOW - 2900))
lw
[ "$(f api 2)|$(f api 3)|$(f api 6)" = "dormant|credit used up|signal" ] && ok "the real 'Credit balance is too low' record on api panes: the api lane is dormant, 'credit used up'" || bad "credit: $(slurp "$REC"); log: $(tail -3 "$WLOG")"
[ "$(lane_iso_epoch "$(f api 4)")" -le $((NOW - 2850)) ] && [ "$(lane_iso_epoch "$(f api 4)")" -ge $((NOW - 3100)) ] && ok "since is the stop's first error ($(f api 4)), not the time of the tick" || bad "since: $(f api 4) vs $(iso $((NOW - 3000)))"
lane_dormant sdk && ok "sdk reads dormant with it (one key)" || bad "sdk"
lw; lw
[ "$(logn 'dormant')" = 1 ] && ok "two more ticks: still the one record, one lanes.log line" || bad "lanes.log: $(<"$LOGF")"
[ "$(dposts)" = 1 ] && ok "one 'API lane is dormant' post (besides the limit watch's own stop post)" || bad "api dormant posts: $(dposts)"
has "$(dpost API)" "credit used up since $(lane_day "$(f api 4)"), 2 sessions are still on it; moving them is your call" && ok "the post names the reason, the day and '2 sessions' (api and sdk rows)" || bad "api post: $(dpost API)"
backdate api 200000
for i in 1 2 3; do sw; done
lane_dormant api && ok "the daily look never brings the API lane back (no check of the key is made at all)" || bad "api revived by a sign-in look"
[ ! -e "$HOME/.config/anthropic/api-key" ] && ok "no key file was ever needed or read; no test call exists in this path" || bad "key file appeared"
"$SALA" lane active api >/dev/null 2>&1
lane_dormant api && bad "lane active api did not clear" || ok "'sala lane active api' brings it back"
lw
lane_dormant api && bad "the old credit stop (still in the limit watch's state) made it dormant again" || ok "the stop that began before 'lane active' is the old episode: not dormant again one tick later"
credit_rec "$UD" $((NOW + 120)); sleep 1
# a fresh error after activation: its stop's first error is still the old episode's (the state keeps the pane's since), so nothing flips by itself
lw
lane_dormant api && bad "a new error on a pane still in the old stop episode set it dormant again" || ok "a new error on a pane still in the old stop episode keeps that episode's since: 'active api' is not undone by it"

echo "== the post: only while sessions are on the lane, once per episode"
reset_all; : > "$SALA_LANES"
"$SALA" lane dormant bedrock --reason "test" >/dev/null 2>&1; sw
[ "$(dposts)" = 0 ] && [ -z "$(f bedrock 5)" ] && ok "no session on the lane: no post, and the episode stays unposted" || bad "post with no sessions: $(dpost Bedrock)"
printf 'sala-test-b1\tbedrock\n' > "$SALA_LANES"; sw
[ "$(dposts)" = 1 ] && has "$(dpost Bedrock)" "1 session is still on it" && ok "a session on it later: the one post then ('1 session is still on it')" || bad "late post: $(dposts) $(dpost Bedrock)"
sw; sw; [ "$(dposts)" = 1 ] && ok "never twice for the episode" || bad "dormant posts: $(dposts)"
"$SALA" lane active bedrock >/dev/null 2>&1; "$SALA" lane dormant bedrock --reason "again" >/dev/null 2>&1; sw
[ "$(dposts)" = 2 ] && ok "a new dormant episode posts again" || bad "new episode: $(dposts)"
: > "$SALA_LANES"; before=$(dposts); "$SALA" lane active bedrock >/dev/null 2>&1; "$SALA" lane dormant bedrock >/dev/null 2>&1; sw
[ "$(dposts)" = "$before" ] && ok "a third episode with no session on the lane: nothing posted" || bad "posted with none"

echo "== the signal reads existing detections only: no new network call"
awk '/^# THE DORMANT RECORD.S SIGNALS/,/^# SIGN-IN WATCH/' "$ROOT/lib/watch.sh" | grep -v '^#' | grep -qE 'curl|urllib|http|wget|nc ' && bad "the signals' code makes a network call" || ok "the dormant signals' code has no curl, urllib or http call"

[ "$fail" = 0 ] && echo "lanedormant: pass" || echo "lanedormant: FAIL"
exit $fail
