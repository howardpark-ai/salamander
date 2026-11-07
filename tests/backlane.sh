#!/usr/bin/env bash
# The back agents' lane rule (lib/common.sh "THE BACK AGENTS' LANE RULE", lib/watch.sh back_lane_run and `watch --back-lanes`, lib/spawn.sh).
# A standing rule for the background agents (registry rows with role back, never a side session): off the home lane near its weekly limit,
# onto the next lane when that one runs out, home when the weekly window resets. Checked on fakes only: a staged sala-web quota answer
# (quota-subscription-1.json), a staged limit-watch state, a fake `sala` that records the queued operation and applies its lane move to
# lanes.tsv, a tmux function that answers has-session from a list, and a lane_check stub; no real lane move, operation, network or tmux server.
#   OFF: the rule is off by default; with it off nothing is read or queued, at any percent.
#   STEP 1: the home lane's "This week" limit at the threshold queues ONE `sala op lane aws-platform <back agents> --from sala-watch --words <the
#     rule's words>`; below it, with a model-scoped limit ("Fable this week") high, with a stale, failed (errorKind), missing, window-over or
#     "This week"-less reading, or with the home lane dormant, nothing moves. A repeat tick queues nothing. Front agents, side sessions, a back
#     agent on a lane outside the order, a back agent with no tmux session, jobs and the default lane are untouched.
#   STEP 2: a pane running on the second lane stopped on its cap (workspace or credit kind, after the move) queues the move to the third lane,
#     once; a stop on another lane, of another kind or from before the move moves nobody; a Fable session stays where it is with one notice.
#   STEP 3: a fresh reading in a later window under the threshold queues every back agent in the order home, wherever it stands, once; the same
#     window, a reading at the threshold, a stale one or a dormant home lane moves nobody.
#   ONCE PER WINDOW, FAILURES: a step fires once per weekly window (a second tick says so); an operation that is not queued, or a target lane
#     that cannot launch, gives one notice per window and leaves the state as it was; the next tick that can, moves.
#   REFRESH: sala-web refreshes the saved answer only when something asks its /api/quota, so a reading missing or older than half the max age is asked for
#     first by a plain GET (a stub curl; the fake "sala-web" puts a fresh file in place): fresh, the step fires; the call fails or writes nothing, it stays stale
#     and nobody moves; asked at most every SALA_BACK_LANE_REFRESH_EVERY; no GET for a young reading, a dormant home lane or URL=off; the default is sala-web's
#     socket; --dry-run says it would refresh and asks nobody. The suite never reaches a real socket.
#   SPAWN: a back agent spawned while the rule has them off home takes the rule's lane (back_lane_spawn_lane; `spawn --dry-run` says so).
#   DRY RUN: `watch --back-lanes --dry-run` prints what each step would do and queues and writes nothing.
# Isolated HOME in a temp folder (locked while the suite runs, removed at the end). Usage: bash tests/backlane.sh   (exit 0 = pass; a few seconds)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
unset SALA_MASTER SALA_SET SALA_SET_SELF SALA_RECYCLE SALA_NO_RELAUNCH SALA_BACK_LANE_RULE SALA_BACK_LANE_ORDER SALA_BACK_LANE_THRESHOLD SALA_BACK_LANE_MAX_AGE \
      SALA_BACK_LANE_WORDS SALA_BACK_LANE_STATE SALA_LANE_FALLBACK SALA_FALLBACK_NO_FABLE TMUX TMUX_PANE
T=""
trap '[ -n "$T" ] && rm -rf "$T"' EXIT
T=$(mktemp -d "${TMPDIR:-/tmp}/sala-backlane.XXXXXX")
exec 8< "$T"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
export HOME="$T/home"; export SALA_CONFIG=/dev/null XDG_STATE_HOME="$T/state"
mkdir -p "$HOME/.claude" "$HOME/.aws" "$XDG_STATE_HOME/salamander" "$T/web" "$T/fakebin"
# the real lane_check must pass for aws-platform and bedrock: a dummy profile header (no key), a workspace id, a launcher; one lane the test fails on purpose
printf '[example-bedrock]\naws_access_key_id = dummy\naws_secret_access_key = dummy\n' > "$HOME/.aws/credentials"
printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/claude"; chmod +x "$T/fakebin/claude"
export SALA_CLAUDE="$T/fakebin/claude" SALA_LANE_AWSPLATFORM_WORKSPACE_ID=wrkspc_01EXAMPLE
export SALA_WEB_STATE_DIR="$T/web" SALA_LIMIT_STATE="$T/limit.json" SALA_OWNER_NAME=Rowan
# the refresh asks the local sala-web: off for every case but its own section, and never the real socket
export SALA_BACK_LANE_REFRESH_URL=off SALA_BACK_LANE_REFRESH_WAIT=1 XDG_RUNTIME_DIR="$T/run" PATH="$T/fakebin:$PATH"
unset SALA_WEB_SOCKET
export FAKE_OPLOG="$T/ops.log" FAKE_LIVE="$T/tmux-live" FAKE_OP_RC="$T/op.rc" FAKE_LC="$T/lane-check-fail"
ST="$XDG_STATE_HOME/salamander"; STATE="$ST/back-lane.state"
RULE_WORDS="Sam: when lane A reaches 80%, move all back agents to lane B"

# the fake sala: records `op …` (one line, arguments joined by |), applies a `lane <lane> <session>… --from` move to lanes.tsv as the real switch would
cat > "$T/fakebin/salamander" <<'EOF'
#!/bin/bash
[ "$1" = op ] || exit 0
printf '%s|' "$@" >> "$FAKE_OPLOG"; echo >> "$FAKE_OPLOG"
if [ -s "$FAKE_OP_RC" ]; then echo "sala op: refused for the test"; exit "$(cat "$FAKE_OP_RC")"; fi
[ "$2" = lane ] || exit 0
lane=$3; shift 3
while [ $# -gt 0 ] && [ "$1" != --from ]; do
    grep -v "^$1	" "$FAKE_LANES" > "$FAKE_LANES.t" 2>/dev/null; printf '%s\t%s\n' "$1" "$lane" >> "$FAKE_LANES.t"; mv "$FAKE_LANES.t" "$FAKE_LANES"; shift
done
echo "queued op 1760000000-1: lane $lane"
EOF
cat > "$T/fakebin/tmux" <<'EOF2'
#!/bin/bash
[ "${1:-}" = has-session ] && grep -qx -- "${3#=}" "$FAKE_LIVE" 2>/dev/null
EOF2
# the fake curl: records its arguments; fails when $T/curl-fail exists; otherwise stands for sala-web's refresh by putting $T/payload.json in place of the saved answer
cat > "$T/fakebin/curl" <<'EOF2'
#!/bin/bash
echo "$*" >> "$T/curl.log"
[ -e "$T/curl-fail" ] && exit 22
[ -e "$T/payload.json" ] && cp "$T/payload.json" "$T/web/quota-subscription-1.json"
echo '{"lanes": []}'
EOF2
chmod +x "$T/fakebin/salamander" "$T/fakebin/tmux" "$T/fakebin/curl"
export FAKE_LANES="$ST/lanes.tsv"
# the driver: sources lib/common.sh, then stubs the three things that need a machine (tmux, the lane's readiness, the notification), and runs its argument
cat > "$T/drv.sh" <<'EOF'
#!/bin/bash
export SALA_ROOT="$ROOT"
. "$ROOT/lib/common.sh"
SALA_BIN="$T/fakebin/salamander"
tmux() { [ "${1:-}" = has-session ] && grep -qx -- "${3#=}" "$FAKE_LIVE" 2>/dev/null; }
eval "real_$(declare -f lane_check)"
lane_check() { local l; l=$(lane_state_id "${1:-}") || return 1; if grep -qx -- "$l" "$FAKE_LC" 2>/dev/null; then echo "$l lane: not ready (the test says so)"; return 1; fi; real_lane_check "$l"; }
eval "$1"
EOF
drv() { ROOT="$ROOT" T="$T" bash "$T/drv.sh" "$1" 2>&1; }
SESSIONS=$(drv 'echo "$SALA_SESSIONS_FILE"')

NOW=$(date +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
W1=$((NOW + 3 * 86400)); W2=$((W1 + 7 * 86400))   # this week's reset, the next one
# quota <pct> <window reset epoch> [age secs] [extra top-level json]: the saved answer sala-web writes for the home lane
quota() {
    local ms=$(( (NOW - ${3:-0}) * 1000 ))
    cat > "${QFILE:-$T/web/quota-subscription-1.json}" <<JSON
{"fetchedAt": $ms${4:+, $4}, "limits": [
 {"label": "This week", "percent": $1, "resetsAt": "$(iso "$2")"},
 {"label": "Fable this week", "percent": 97, "resetsAt": "$(iso "$2")"}]}
JSON
}
# the registry: back agents a b fab (Fable) api (a lane outside the order) dead (no tmux session), a front agent, a side session
reg() {
    python3 -I -S - "$SESSIONS" <<'PY'
import json, sys
rows = {}
def add(name, role, side=None):
    rows[name] = {"id": name, "name": name, "state": "live", "role": role, "side": side, "project": "projects/x", "created": name}
for n in ("back-a", "back-b", "back-fab", "back-api", "back-dead"): add(n, "back")
add("front-a", "front"); add("side-a", "back", "fork")
json.dump({"schema": 1, "sessions": rows}, open(sys.argv[1], "w"))
PY
    printf '%s\n' back-a back-b back-fab back-api back-dead front-a side-a sala-job-x > "$FAKE_LIVE"; sed -i '/^back-dead$/d' "$FAKE_LIVE"
    printf 'back-fab\tfable\txhigh\n' > "$ST/models.tsv"
    printf 'back-a\tsubscription-1\nback-b\tsubscription-1\nback-fab\tsubscription-1\nback-api\tapi\nfront-a\tsubscription-1\nside-a\tsubscription-1\n' > "$FAKE_LANES"
    rm -f "$ST/lane-state.tsv" "$STATE" "$FAKE_OPLOG" "$FAKE_OP_RC" "$FAKE_LC" "$SALA_LIMIT_STATE" "$ST/lane-default" "$ST/lanes.log"
    : > "$FAKE_OPLOG"
}
ops() { local n; n=$(grep -c . "$FAKE_OPLOG" 2>/dev/null); echo "${n:-0}"; }
has() { case "$1" in *"$2"*) return 0;; esac; return 1; }
lane_of() { awk -F'\t' -v n="$1" '$1 == n { l = $2 } END { print l }' "$FAKE_LANES"; }
tick() { drv 'back_lane_tick'; }
on() { export SALA_BACK_LANE_RULE=on SALA_BACK_LANE_WORDS="$RULE_WORDS"; }
# pane_stop <lane the pane runs on> <kind> <since epoch>: the limit watch's state with one stopped pane
pane_stop() { printf '{"panes": {"u1": {"s": "back-a", "since": %s, "reset": 0, "lane": "api", "lim": "%s", "e": "x", "rlane": "%s"}}}\n' "$3" "$2" "$1" > "$SALA_LIMIT_STATE"; }
op_names() { sed -n 's/^op|lane|[a-z0-9-]*|\(.*\)|--from|.*/\1/p' "$FAKE_OPLOG" | tr '|' ' '; }

echo "== off by default"
reg; quota 95 $W1
[ "$(drv 'echo "$SALA_BACK_LANE_RULE"')" = off ] && ok "SALA_BACK_LANE_RULE defaults to off" || bad "default: $(drv 'echo "$SALA_BACK_LANE_RULE"')"
out=$(tick); [ -z "$out" ] && [ "$(ops)" = 0 ] && [ ! -e "$STATE" ] && ok "off: a 95% reading queues nothing, writes nothing" || bad "off: $out / ops $(ops)"
out=$(ROOT="$ROOT" T="$T" PATH="$T/fakebin:$PATH" bash "$ROOT/bin/salamander" watch --back-lanes --dry-run 2>&1); has "$out" "the rule is off" && ok "watch --back-lanes --dry-run says the rule is off" || bad "watch off: $out"
on

echo "== nothing moves without a good reading, or below the threshold"
for p in 0 50 89; do reg; quota $p $W1; out=$(tick); [ "$(ops)" = 0 ] && has "$out" "idle:" && ok "$p%: idle, nothing queued" || bad "$p%: $out"; done
reg; quota 95 $W1 7200; out=$(tick); [ "$(ops)" = 0 ] && has "$out" "minutes old" && ok "a stale reading (2 h) moves nobody" || bad "stale: $out"
reg; quota 95 $W1 0 '"errorKind": "http"'; out=$(tick); [ "$(ops)" = 0 ] && has "$out" "failed" && ok "a failed refresh (errorKind) moves nobody" || bad "errorKind: $out"
reg; rm -f "$T/web/quota-subscription-1.json"; out=$(tick); [ "$(ops)" = 0 ] && has "$out" "no saved quota answer" && ok "no saved answer moves nobody" || bad "missing: $out"
reg; echo '{"fetchedAt": 1, "limits": [' > "$T/web/quota-subscription-1.json"; out=$(tick); [ "$(ops)" = 0 ] && ok "an unreadable answer moves nobody" || bad "garbled: $out"
reg; quota 95 $((NOW - 60)); out=$(tick); [ "$(ops)" = 0 ] && has "$out" "window is over" && ok "a window already over moves nobody" || bad "expired: $out"
reg; cat > "$T/web/quota-subscription-1.json" <<JSON
{"fetchedAt": $((NOW * 1000)), "limits": [{"label": "Fable this week", "percent": 99, "resetsAt": "$(iso $W1)"}]}
JSON
out=$(tick); [ "$(ops)" = 0 ] && has "$out" 'no "This week" limit' && ok "a scoped weekly limit (Fable this week) at 99% does not trigger it" || bad "scoped: $out"
reg; quota 95 $W1; printf 'subscription-1\tdormant\ttest\t%s\t\tx\n' "$NOW" > "$ST/lane-state.tsv"; out=$(tick); [ "$(ops)" = 0 ] && has "$out" "dormant" && ok "a dormant home lane moves nobody" || bad "dormant: $out"

echo "== step 1: the home lane's weekly limit at 90%"
reg; quota 90 $W1; out=$(tick)
[ "$(ops)" = 1 ] && has "$out" "moved: step 1" && ok "90% (the threshold): one operation queued" || bad "step 1: ops=$(ops) $out"
line=$(head -1 "$FAKE_OPLOG")
case "$line" in "op|lane|aws-platform|"*"|--from|sala-watch|--words|$RULE_WORDS|") ok "the operation: sala op lane aws-platform … --from sala-watch --words <the rule, quoted>";; *) bad "argv: $line";; esac
[ "$(op_names | tr ' ' '\n' | sort | paste -sd' ')" = "back-a back-b back-fab" ] && ok "it carries the live back agents on the home lane (a, b, the Fable one)" || bad "names: $(op_names)"
case "$line" in *front-a*|*side-a*|*back-api*|*back-dead*|*sala-job-x*) bad "a front agent, side session, other-lane agent, dead pane or job in the move: $line";; *) ok "front agent, side session, api agent, dead pane and a job are not in it";; esac
[ "$(lane_of front-a)" = subscription-1 ] && [ "$(lane_of back-api)" = api ] && [ ! -e "$ST/lane-default" ] && ok "their lanes and the default lane are unchanged" || bad "lanes: front $(lane_of front-a) api $(lane_of back-api)"
out=$(tick); [ "$(ops)" = 1 ] && has "$out" "idle:" && ok "a repeat tick queues nothing" || bad "repeat: ops=$(ops) $out"
out=$(drv 'back_lane_current'); [ "$out" = aws-platform ] && ok "the rule's lane is now aws-platform" || bad "current: $out"
grep -q backlane "$ST/lanes.log" 2>/dev/null && ok "the move is in the lane log" || bad "no lane log line"
# once per window even when the state says home again (a hand move back): the same window does not fire twice
drv 'back_lane_put lane subscription-1' >/dev/null; out=$(tick); [ "$(ops)" = 1 ] && has "$out" "already fired" && ok "the same window does not fire step 1 twice" || bad "same window: ops=$(ops) $out"

echo "== step 2: a pane on aws-platform stopped on its cap"
reg; quota 95 $W1; tick >/dev/null; M=$((NOW - 600)); drv "back_lane_put moved_at $M" >/dev/null
for case_ in "bedrock workspace $((NOW - 60))" "api workspace $((NOW - 60))" "aws-platform rate $((NOW - 60))" "aws-platform workspace $((M - 100))"; do
    set -- $case_; pane_stop "$1" "$2" "$3"; out=$(tick)
    [ "$(ops)" = 1 ] && ok "no move for a stop of $2 on $1 since $(( NOW - $3 )) s ago (before: another lane, another kind or from before the move)" || bad "stop $case_: ops=$(ops) $out"
done
pane_stop aws-platform workspace $((NOW - 60)); out=$(tick)
[ "$(ops)" = 2 ] && has "$out" "moved: step 2" && ok "a workspace-cap stop on aws-platform: the second operation" || bad "step 2: ops=$(ops) $out"
line=$(tail -1 "$FAKE_OPLOG"); case "$line" in "op|lane|bedrock|back-a|back-b|--from|sala-watch|--words|$RULE_WORDS|") ok "it moves a and b to bedrock; the Fable one is left (bedrock cannot run it)";; *) bad "step 2 argv: $line";; esac
has "$out" "notice:" && has "$out" "back-fab" && ok "one notice names the Fable agent left behind" || bad "fable notice: $out"
out=$(tick); [ "$(ops)" = 2 ] && ok "a repeat tick queues nothing" || bad "step 2 repeat: ops=$(ops) $out"
reg; quota 95 $W1; tick >/dev/null; drv "back_lane_put moved_at $M" >/dev/null; pane_stop aws-platform credit $((NOW - 60)); out=$(tick)
[ "$(ops)" = 2 ] && has "$out" "moved: step 2" && ok "a credit stop (billing) counts too" || bad "credit: ops=$(ops) $out"

echo "== step 3: the weekly window resets"
reg; quota 95 $W1; tick >/dev/null; drv "back_lane_put moved_at $M" >/dev/null; pane_stop aws-platform workspace $((NOW - 60)); tick >/dev/null
[ "$(ops)" = 2 ] && [ "$(lane_of back-a)" = bedrock ] || bad "setup for step 3: ops=$(ops) a on $(lane_of back-a)"
quota 40 $W1; out=$(tick); [ "$(ops)" = 2 ] && ok "the same window, back under 90%: nobody goes home" || bad "same window: ops=$(ops) $out"
quota 95 $W2; out=$(tick); [ "$(ops)" = 2 ] && ok "a new window but at the threshold: nobody goes home" || bad "new window at 95: ops=$(ops) $out"
quota 10 $W2 7200; out=$(tick); [ "$(ops)" = 2 ] && ok "a stale reading of the new window: nobody goes home" || bad "stale new: ops=$(ops) $out"
printf 'subscription-1\tdormant\ttest\t%s\t\tx\n' "$NOW" > "$ST/lane-state.tsv"; quota 10 $W2; out=$(tick); [ "$(ops)" = 2 ] && ok "a dormant home lane: nobody goes home" || bad "dormant home: ops=$(ops) $out"
rm -f "$ST/lane-state.tsv"
quota 10 $W2; out=$(tick)
[ "$(ops)" = 3 ] && has "$out" "moved: step 3" && ok "a fresh reading of a new window under 90%: one operation" || bad "step 3: ops=$(ops) $out"
line=$(tail -1 "$FAKE_OPLOG"); case "$line" in "op|lane|subscription-1|back-a|back-b|back-fab|--from|sala-watch|--words|$RULE_WORDS|") ok "all three go home wherever they stood (a, b from bedrock; the Fable one from aws-platform)";; *) bad "step 3 argv: $line";; esac
[ "$(lane_of back-api)" = api ] && [ "$(lane_of front-a)" = subscription-1 ] && ok "the api agent and the front agent are untouched" || bad "others moved"
out=$(tick); [ "$(ops)" = 3 ] && ok "a repeat tick queues nothing" || bad "step 3 repeat: ops=$(ops) $out"
quota 95 $W2; out=$(tick); [ "$(ops)" = 4 ] && has "$out" "moved: step 1" && ok "the next window can start the cycle again" || bad "cycle: ops=$(ops) $out"

echo "== jobs are never touched"
grep -q 'lane|exec\|job' "$FAKE_OPLOG" && bad "a job or exec in the queued operations" || ok "no queued operation is a job or an exec"
[ ! -e "$ST/lane-default" ] && ok "the default lane (where jobs and new sessions start) was never written" || bad "lane-default written"

echo "== failures: one notice per window, the state unchanged, the next tick moves"
reg; quota 95 $W1; echo 1 > "$FAKE_OP_RC"; out=$(tick)
has "$out" "notice:" && has "$out" "not queued" && [ "$(drv 'back_lane_current')" = subscription-1 ] && ok "an operation that is refused: one notice, the rule's lane unchanged" || bad "refused: $out"
out=$(tick); has "$out" "blocked:" && ! has "$out" "notice:" && ok "the next tick: a quiet line, no second notice" || bad "second: $out"
rm -f "$FAKE_OP_RC"; out=$(tick); has "$out" "moved: step 1" && ok "once the queue takes it, the move happens" || bad "recover: $out"
reg; quota 95 $W1; echo aws-platform > "$FAKE_LC"; out=$(tick)
[ "$(ops)" = 0 ] && has "$out" "notice:" && has "$out" "cannot take them" && ok "a target lane that cannot launch: one notice, nothing queued" || bad "not ready: ops=$(ops) $out"
out=$(tick); [ "$(ops)" = 0 ] && ! has "$out" "notice:" && ok "the second tick does not repeat the notice" || bad "not ready 2: $out"
rm -f "$FAKE_LC"; out=$(tick); [ "$(ops)" = 1 ] && ok "when the lane is ready the move is queued" || bad "ready: ops=$(ops) $out"
reg; quota 95 $W1; : > "$FAKE_LIVE"; out=$(tick); [ "$(ops)" = 0 ] && has "$out" "advanced:" && [ "$(drv 'back_lane_current')" = aws-platform ] && ok "with no back agent alive the rule's lane still advances (a new one spawns on it), no operation" || bad "nobody: ops=$(ops) $out"

echo "== a due reading is asked for from the local sala-web first"
ncurl() { local n; n=$(grep -c . "$T/curl.log" 2>/dev/null); echo "${n:-0}"; }
rreset() { reg; rm -f "$T/curl.log" "$T/curl-fail" "$T/payload.json"; }
export T; HTTPURL=http://127.0.0.1:9
rreset; quota 95 $W1 7200; QFILE="$T/payload.json" quota 95 $W1; out=$(SALA_BACK_LANE_REFRESH_URL=$HTTPURL tick)
[ "$(ncurl)" = 1 ] && grep -q -e "-fsS" "$T/curl.log" && grep -q -e "--max-time 5" "$T/curl.log" && grep -q "$HTTPURL/api/quota\$" "$T/curl.log" && ok "a two-hour-old reading: one plain GET of <url>/api/quota with a short timeout" || bad "curl: $(cat "$T/curl.log" 2>&1)"
grep -qi -e "authorization" -e "bearer" -e "token" -e " -H " "$T/curl.log" && bad "the GET carries a credential or header: $(cat "$T/curl.log")" || ok "the GET carries no header, token or credential"
[ "$(ops)" = 1 ] && has "$out" "refresh: asked the local sala-web" && has "$out" "moved: step 1" && ok "the file is read again: it is fresh, step 1 fires" || bad "refresh then move: ops=$(ops) $out"
rreset; quota 95 $W1 7200; touch "$T/curl-fail"; out=$(SALA_BACK_LANE_REFRESH_URL=$HTTPURL tick)
[ "$(ncurl)" = 1 ] && [ "$(ops)" = 0 ] && has "$out" "idle:" && ok "the call fails: the reading stays stale, nobody moves" || bad "fail: curl=$(ncurl) ops=$(ops) $out"
out=$(SALA_BACK_LANE_REFRESH_URL=$HTTPURL tick); [ "$(ncurl)" = 1 ] && ok "asked again within SALA_BACK_LANE_REFRESH_EVERY: no second call" || bad "throttle: curl=$(ncurl)"
rreset; quota 95 $W1 7200; out=$(SALA_BACK_LANE_REFRESH_URL=$HTTPURL tick)
[ "$(ncurl)" = 1 ] && [ "$(ops)" = 0 ] && ok "the call works but sala-web writes nothing new: still stale, nobody moves" || bad "no new file: curl=$(ncurl) ops=$(ops) $out"
rreset; rm -f "$T/web/quota-subscription-1.json"; QFILE="$T/payload.json" quota 95 $W1; out=$(SALA_BACK_LANE_REFRESH_URL=$HTTPURL tick)
[ "$(ncurl)" = 1 ] && [ "$(ops)" = 1 ] && ok "no saved answer at all: asked for, then step 1 fires" || bad "missing: curl=$(ncurl) ops=$(ops) $out"
rreset; quota 95 $W1 60; out=$(SALA_BACK_LANE_REFRESH_URL=$HTTPURL tick)
[ "$(ncurl)" = 0 ] && [ "$(ops)" = 1 ] && ok "a reading younger than half the max age: no call" || bad "fresh: curl=$(ncurl) ops=$(ops) $out"
rreset; quota 95 $W1 1000; touch "$T/curl-fail"; out=$(SALA_BACK_LANE_REFRESH_URL=$HTTPURL tick)
[ "$(ncurl)" = 1 ] && [ "$(ops)" = 1 ] && ok "older than half the max age but not past it: asked for; the call fails; the still-valid reading is used" || bad "half: curl=$(ncurl) ops=$(ops) $out"
rreset; quota 95 $W1 7200; out=$(SALA_BACK_LANE_REFRESH_URL=off tick)
[ "$(ncurl)" = 0 ] && [ "$(ops)" = 0 ] && ok "SALA_BACK_LANE_REFRESH_URL=off: no call, a stale reading moves nobody" || bad "off: curl=$(ncurl) ops=$(ops)"
rreset; quota 95 $W1 7200; printf 'subscription-1\tdormant\ttest\t%s\t\tx\n' "$NOW" > "$ST/lane-state.tsv"; out=$(SALA_BACK_LANE_REFRESH_URL=$HTTPURL tick)
[ "$(ncurl)" = 0 ] && ok "a dormant home lane: no call" || bad "dormant: curl=$(ncurl)"
rm -f "$ST/lane-state.tsv"
rreset; quota 95 $W1 7200; QFILE="$T/payload.json" quota 95 $W1; out=$(SALA_BACK_LANE_REFRESH_URL=$HTTPURL drv 'back_lane_tick --dry-run')
[ "$(ncurl)" = 0 ] && [ "$(ops)" = 0 ] && [ ! -s "$STATE" ] && has "$out" "would ask the local sala-web for a fresh one" && ok "--dry-run says it would refresh, asks nobody, writes nothing" || bad "dry refresh: curl=$(ncurl) ops=$(ops) $out"
# a unix socket: a path in the setting, or the default (sala-web's own socket under XDG_RUNTIME_DIR, or SALA_WEB_SOCKET)
mkdir -p "$T/run/sala-web"; python3 -I -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$T/run/sala-web/sala-web.sock"
rreset; quota 95 $W1 7200; QFILE="$T/payload.json" quota 95 $W1; out=$(SALA_BACK_LANE_REFRESH_URL= tick)
[ "$(ncurl)" = 1 ] && grep -q -e "--unix-socket $T/run/sala-web/sala-web.sock http://localhost/api/quota" "$T/curl.log" && [ "$(ops)" = 1 ] && ok "the default is sala-web's socket under XDG_RUNTIME_DIR (--unix-socket, http://localhost/api/quota)" || bad "default socket: $(cat "$T/curl.log" 2>&1) ops=$(ops)"
python3 -I -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$T/other.sock"
rreset; quota 95 $W1 7200; QFILE="$T/payload.json" quota 95 $W1; out=$(SALA_BACK_LANE_REFRESH_URL= SALA_WEB_SOCKET="$T/other.sock" tick)
grep -q -e "--unix-socket $T/other.sock " "$T/curl.log" && ok "SALA_WEB_SOCKET moves the default" || bad "SALA_WEB_SOCKET: $(cat "$T/curl.log" 2>&1)"
rreset; quota 95 $W1 7200; out=$(SALA_BACK_LANE_REFRESH_URL=$T/nosuch.sock tick)
[ "$(ncurl)" = 0 ] && [ "$(ops)" = 0 ] && ok "a socket that is not there: no call, nobody moves" || bad "no socket: curl=$(ncurl) ops=$(ops)"
rm -f "$T/payload.json"

echo "== spawn takes the rule's lane"
reg; quota 95 $W1
out=$(drv 'back_lane_spawn_lane; echo "rc=$?"'); [ "$out" = "rc=1" ] && ok "at home: no rule lane (rc 1)" || bad "spawn at home: $out"
tick >/dev/null
out=$(drv 'back_lane_spawn_lane; echo "rc=$?"'); [ "$out" = $'aws-platform\nrc=0' ] && ok "after step 1: a new back agent takes aws-platform" || bad "spawn aws: $out"
echo aws-platform > "$FAKE_LC"; out=$(drv 'back_lane_spawn_lane; echo "rc=$?"'); [ "$out" = "rc=1" ] && ok "the rule's lane not ready: the default lane" || bad "spawn not ready: $out"
rm -f "$FAKE_LC"; printf 'aws-platform\tdormant\ttest\t%s\t\tx\n' "$NOW" > "$ST/lane-state.tsv"
out=$(drv 'back_lane_spawn_lane; echo "rc=$?"'); [ "$out" = "rc=1" ] && ok "the rule's lane dormant: the default lane" || bad "spawn dormant: $out"
rm -f "$ST/lane-state.tsv"
out=$(SALA_BACK_LANE_RULE=off drv 'back_lane_spawn_lane; echo "rc=$?"'); [ "$out" = "rc=1" ] && ok "rule off: the default lane" || bad "spawn off: $out"

echo "== spawn --dry-run names the rule's lane"
cat > "$T/fake-pages.py" <<'PY'
import sys
if sys.argv[1] == "resolve": print(sys.argv[2], True); sys.exit(0)
if sys.argv[1] == "agent-listed": print("listed on projects/foo: the test's page"); sys.exit(0)
sys.exit(1)
PY
sp() { OUT=$(ROOT="$ROOT" T="$T" PATH="$T/fakebin:$PATH" SALA_AGENT_CHECK_SCRIPT="$T/fake-pages.py" SALA_BIN="$ROOT/bin/salamander" bash "$ROOT/bin/salamander" spawn "$@" 2>&1); RC=$?; }
reg; quota 95 $W1; tick >/dev/null
sp lr-back-x --project projects/foo --role back --mandate "a mandate" --dry-run
[ "$RC" = 0 ] && has "$OUT" "[dry-run] lane: the back agents' lane rule has them on the aws-platform lane" && ok "a back agent: the dry run says it launches on aws-platform" || bad "spawn back: rc=$RC $OUT"
sp lr-front-x --project projects/foo --role front --dry-run
[ "$RC" = 0 ] && ! has "$OUT" "lane rule" && ok "a front agent: the rule is not mentioned, the default lane" || bad "spawn front: rc=$RC $OUT"
sp lr-back-x --project projects/foo --role back --mandate "a mandate" --lane bedrock --dry-run
[ "$RC" = 0 ] && ! has "$OUT" "lane rule" && ok "--lane wins over the rule" || bad "spawn --lane: rc=$RC $OUT"
sp lr-back-x --project projects/foo --role back --mandate "a mandate" --model fable --dry-run
[ "$RC" = 0 ] && has "$OUT" "lane rule" && ok "a Fable model on aws-platform follows the rule (aws-platform runs Fable)" || bad "spawn fable: rc=$RC $OUT"
drv 'back_lane_put lane subscription-1' >/dev/null
sp lr-back-x --project projects/foo --role back --mandate "a mandate" --dry-run
[ "$RC" = 0 ] && ! has "$OUT" "lane rule" && ok "with the back agents home: the default lane, no note" || bad "spawn home: rc=$RC $OUT"

echo "== the watch's dry run"
reg; quota 95 $W1
out=$(ROOT="$ROOT" T="$T" PATH="$T/fakebin:$PATH" bash "$ROOT/bin/salamander" watch --back-lanes --dry-run 2>&1)
has "$out" "would: step 1" && has "$out" "sala op lane aws-platform" && [ "$(ops)" = 0 ] && [ ! -s "$STATE" ] && ok "step 1 dry run: says what it would queue; queues and writes nothing" || bad "dry step 1: $out"
reg; quota 95 $W1; tick >/dev/null; drv "back_lane_put moved_at $M" >/dev/null; pane_stop aws-platform workspace $((NOW - 60)); before=$(cat "$STATE"); n=$(ops)
out=$(ROOT="$ROOT" T="$T" PATH="$T/fakebin:$PATH" bash "$ROOT/bin/salamander" watch --back-lanes --dry-run 2>&1)
has "$out" "would: step 2" && [ "$(ops)" = "$n" ] && [ "$(cat "$STATE")" = "$before" ] && ok "step 2 dry run: nothing queued, the state file as it was" || bad "dry step 2: $out"
rm -f "$SALA_LIMIT_STATE"; quota 10 $W2
out=$(ROOT="$ROOT" T="$T" PATH="$T/fakebin:$PATH" bash "$ROOT/bin/salamander" watch --back-lanes --dry-run 2>&1)
has "$out" "would: step 3" && [ "$(ops)" = "$n" ] && ok "step 3 dry run: nothing queued" || bad "dry step 3: $out"

exit $fail
