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
#   NO ROLE: a registry row with no role counts as a back agent when the project record (stackshot's projects.json) lists it under background:
#     (a front-listed row, an unlisted one, a side session and a row whose stored role says otherwise do not; no or a stale record: nobody extra);
#     a real `watch --back-lanes` pass writes those roles into the registry, its dry run writes nothing. A row the record places nowhere takes the
#     front or back entry of the roles file (stackshot's roles.json) and moves with that role (the keeper is a mark on one front or back agent, "keeper": true on its entry, and moves with that agent's role; an entry whose role is the old keeper, a retired one, a stale file: nobody).
#   CATCH-UP: while the back agents are off home, one that is still on the wrong side (spawned or tagged after the step, not live then) is queued onto
#     the rule's lane at the next pass, once per window (the state's queued list), never twice; a state without the list queues those still home once;
#     step 3 clears the list; nothing at home.
#   NEVER ONTO A DORMANT LANE: a step whose target lane is dormant moves the agents to that lane's fallback (the lane fallback table) and says so, in the
#     operation, the rule's lane, the log and the dry run; nobody moves, with one notice per window, when the fallback is dormant too, not ready, outside the
#     order, the home lane or unset (also in the dry run); an unrelated dormant lane changes nothing; step 2 and the catch-up follow the same rule.
#   SPAWN: a back agent spawned while the rule has them off home takes the rule's lane (back_lane_spawn_lane; `spawn --dry-run` says so).
#   DRY RUN: `watch --back-lanes --dry-run` prints what each step would do and queues and writes nothing.
#   FRONT HOME CATCH-UP: at home after step 3, a live front agent left off home is queued onto the home lane once per window (state hqueued); not when
#     step 3 has not fired in this window, with a stale, missing, at-threshold or above-threshold reading, a dormant or not ready home lane, the front step
#     off or invalid; a pinned one is held out and named; the front agents step 3 itself took are not queued again in the same pass or the next; a
#     refused operation gives a blocked line and a retry; the dry run names the agent and writes nothing; the next step 1 clears hqueued.
# Isolated HOME in a temp folder (locked while the suite runs, removed at the end). Usage: bash tests/backlane.sh   (exit 0 = pass; a few seconds)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
unset SALA_ROLES_FILE_MAX_AGE SALA_SET SALA_SET_SELF SALA_RECYCLE SALA_NO_RELAUNCH SALA_BACK_LANE_RULE SALA_BACK_LANE_ORDER SALA_BACK_LANE_THRESHOLD SALA_BACK_LANE_MAX_AGE \
      SALA_BACK_LANE_WORDS SALA_BACK_LANE_STATE SALA_BACK_LANE_FRONT_THRESHOLD SALA_LANE_FALLBACK SALA_FABLE_LANES TMUX TMUX_PANE
export SALA_FABLE_LANES="subscription-1 aws-platform"   # the rule's mechanics are tested with a second Fable-capable lane; the default list (Ultra only) is the last section
export SALA_BACK_LANE_FRONT_THRESHOLD=off  # the sections up to THE FRONT STEP test the back agents' steps with a front agent registered at the same 95%: that step is off for them
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
export SALA_WEB_STATE_DIR="$T/web" SALA_LIMIT_STATE="$T/limit.json" SALA_OWNER_NAME=Rowan SALA_PROJECT_RECORD="$T/projects.json"   # no project record unless a case writes one
# the refresh asks the local sala-web: off for every case but its own section, and never the real socket
export SALA_BACK_LANE_REFRESH_URL=off SALA_BACK_LANE_REFRESH_WAIT=1 XDG_RUNTIME_DIR="$T/run" PATH="$T/fakebin:$PATH"
unset SALA_WEB_SOCKET
export FAKE_OPLOG="$T/ops.log" FAKE_LIVE="$T/tmux-live" FAKE_OP_RC="$T/op.rc" FAKE_LC="$T/lane-check-fail" FAKE_NOMOVE="$T/nomove"
export SALA_ROLES_FILE="$T/roles.json"   # stackshot's roles file: this suite's own (none unless a case writes one), never the real one
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
if [ -e "$FAKE_NOMOVE" ]; then echo "queued op 1760000000-1: lane $lane"; exit 0; fi   # a busy pane: queued, but the lane has not changed yet
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
    rm -f "$ST/lane-state.tsv" "$STATE" "$FAKE_OPLOG" "$FAKE_OP_RC" "$FAKE_LC" "$FAKE_NOMOVE" "$SALA_ROLES_FILE" "$SALA_LIMIT_STATE" "$ST/lane-default" "$ST/lanes.log"
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

echo "== never onto a dormant lane: the fallback takes the agents instead"
dormant() { local l; for l in "$@"; do printf '%s\tdormant\ttest\t%s\t\tx\n' "$l" "$NOW"; done > "$ST/lane-state.tsv"; }
# step 1 with the second lane dormant: the move goes to its fallback (bedrock), the Fable agent stays (bedrock cannot run it)
reg; quota 95 $W1; dormant aws-platform; out=$(tick)
[ "$(ops)" = 1 ] && has "$out" "moved: step 1" && has "$out" "to the bedrock lane" && has "$out" "aws-platform lane is dormant" && has "$out" "its fallback, takes them" && ok "step 1, aws-platform dormant: one operation, onto bedrock, the line says why" || bad "dormant step 1: ops=$(ops) $out"
line=$(head -1 "$FAKE_OPLOG"); case "$line" in "op|lane|bedrock|back-a|back-b|--from|sala-watch|--words|$RULE_WORDS|") ok "the operation names bedrock and the two agents bedrock can run, never aws-platform";; *) bad "dormant step 1 argv: $line";; esac
has "$out" "back-fab" && ok "the Fable agent bedrock cannot run is named and stays" || bad "dormant fable: $out"
[ "$(drv 'back_lane_current')" = bedrock ] && ok "the rule's lane is bedrock, the lane actually used" || bad "dormant current: $(drv 'back_lane_current')"
[ "$(drv 'back_lane_get f1')" != "" ] && [ "$(drv 'back_lane_get f2')" != "" ] && ok "step 1 and the lane it landed on are both recorded as fired in this window" || bad "f1=$(drv 'back_lane_get f1') f2=$(drv 'back_lane_get f2')"
out=$(tick); [ "$(ops)" = 1 ] && ok "a repeat tick queues nothing" || bad "dormant repeat: ops=$(ops) $out"
grep -q "backlane" "$ST/lanes.log" && grep "backlane" "$ST/lanes.log" | grep -q "dormant" && ok "the lane log line says why" || bad "dormant log: $(cat "$ST/lanes.log" 2>&1)"
# the dry run prints the actual target and why, and queues and writes nothing
reg; quota 95 $W1; dormant aws-platform
out=$(ROOT="$ROOT" T="$T" PATH="$T/fakebin:$PATH" bash "$ROOT/bin/salamander" watch --back-lanes --dry-run 2>&1)
has "$out" "would: step 1" && has "$out" "sala op lane bedrock back-a back-b" && has "$out" "aws-platform lane is dormant" && has "$out" "bedrock lane, its fallback, takes them" && ! has "$out" "sala op lane aws-platform" && [ "$(ops)" = 0 ] && [ ! -s "$STATE" ] && ok "dry run: names bedrock as the target and why, queues and writes nothing" || bad "dormant dry run: ops=$(ops) $out"
# a healthy aws-platform: unchanged (the first sections hold the same); a dormant lane that is not the target changes nothing
reg; quota 95 $W1; dormant api; out=$(tick); line=$(head -1 "$FAKE_OPLOG")
case "$line" in "op|lane|aws-platform|"*) has "$out" "moved: step 1" && ! has "$out" "dormant" && ok "aws-platform active, another lane dormant: the move goes to aws-platform as before, no mention of a fallback" || bad "other dormant: $out";; *) bad "other dormant argv: $line";; esac
# the fallback is no use: dormant too, not ready, outside the order, or not further from home
reg; quota 95 $W1; dormant aws-platform bedrock; out=$(tick)
[ "$(ops)" = 0 ] && [ "$(drv 'back_lane_current')" = subscription-1 ] && has "$out" "notice:" && has "$out" "dormant too" && ok "target and fallback both dormant: nothing moves, one notice that says why, the rule's lane unchanged" || bad "both dormant: ops=$(ops) $out"
out=$(tick); [ "$(ops)" = 0 ] && has "$out" "blocked:" && ! has "$out" "notice:" && ok "the next tick: a quiet line, no second notice" || bad "both dormant 2: $out"
out=$(ROOT="$ROOT" T="$T" PATH="$T/fakebin:$PATH" bash "$ROOT/bin/salamander" watch --back-lanes --dry-run 2>&1)
has "$out" "dormant too" && ! has "$out" "would: step 1" && [ "$(ops)" = 0 ] && ok "the dry run says nobody moves and why (no move onto a dormant lane)" || bad "both dormant dry: $out"
rm -f "$ST/lane-state.tsv"; out=$(tick); [ "$(ops)" = 1 ] && has "$out" "moved: step 1" && ok "once aws-platform is active again the rule moves them there" || bad "recovered: ops=$(ops) $out"
reg; quota 95 $W1; dormant aws-platform; echo bedrock > "$FAKE_LC"; out=$(tick)
[ "$(ops)" = 0 ] && has "$out" "notice:" && has "$out" "not ready" && ok "a fallback that cannot launch: nothing moves, one notice" || bad "fallback not ready: ops=$(ops) $out"
rm -f "$FAKE_LC"
reg; quota 95 $W1; dormant aws-platform; out=$(SALA_BACK_LANE_ORDER="subscription-1 aws-platform" tick)
[ "$(ops)" = 0 ] && has "$out" "notice:" && has "$out" "not in SALA_BACK_LANE_ORDER" && ok "a fallback outside the order: nothing moves" || bad "outside order: ops=$(ops) $out"
reg; quota 95 $W1; dormant aws-platform; out=$(SALA_LANE_FALLBACK="aws-platform=subscription-1" tick)
[ "$(ops)" = 0 ] && has "$out" "notice:" && has "$out" "no further from home" && ok "a fallback that is the home lane: nothing moves" || bad "fallback home: ops=$(ops) $out"
reg; quota 95 $W1; dormant aws-platform; out=$(SALA_LANE_FALLBACK="aws-platform=none" tick)
[ "$(ops)" = 0 ] && has "$out" "notice:" && has "$out" "no fallback set" && ok "a lane with no fallback: nothing moves" || bad "no fallback: ops=$(ops) $out"
# step 2 with the third lane dormant: its fallback is the home lane, which is no step forward: nothing moves
reg; quota 95 $W1; tick >/dev/null; drv "back_lane_put moved_at $M" >/dev/null; dormant bedrock; pane_stop aws-platform workspace $((NOW - 60)); out=$(tick)
[ "$(ops)" = 1 ] && has "$out" "notice:" && has "$out" "bedrock lane is dormant" && ok "step 2 with bedrock dormant: nothing moves onto it (its fallback is home)" || bad "step 2 dormant: ops=$(ops) $out"
# the catch-up: the rule's lane went dormant after the move; a straggler goes to the fallback, never onto the dormant lane
reg; quota 95 $W1; tick >/dev/null
python3 -I -S - "$SESSIONS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["sessions"]["back-late"] = {"id": "back-late", "name": "back-late", "state": "live", "role": "back", "side": None, "project": "projects/x", "created": "z"}; json.dump(d, open(sys.argv[1], "w"))
PY
echo back-late >> "$FAKE_LIVE"; printf 'back-late\tsubscription-1\n' >> "$FAKE_LANES"; dormant aws-platform
out=$(ROOT="$ROOT" T="$T" PATH="$T/fakebin:$PATH" bash "$ROOT/bin/salamander" watch --back-lanes --dry-run 2>&1)
has "$out" "would: catch-up: sala op lane bedrock back-a back-b back-late " && ! has "$out" "sala op lane aws-platform" && [ "$(ops)" = 1 ] && ok "catch-up dry run, the rule's lane dormant: the straggler and the agents standing on the dormant lane would go to bedrock" || bad "catch-up dormant dry: ops=$(ops) $out"
out=$(tick); case "$(tail -1 "$FAKE_OPLOG")" in "op|lane|bedrock|back-a|back-b|back-late|--from|sala-watch|--words|$RULE_WORDS|") has "$out" "moved: catch-up" && ok "catch-up, the rule's lane dormant: the straggler is queued onto bedrock";; *) bad "catch-up dormant: $(tail -1 "$FAKE_OPLOG") / $out";; esac
out=$(tick); [ "$(ops)" = 2 ] && ok "the straggler is not queued again" || bad "catch-up dormant repeat: ops=$(ops) $out"
printf 'back-late2\tsubscription-1\n' >> "$FAKE_LANES"; echo back-late2 >> "$FAKE_LIVE"
python3 -I -S - "$SESSIONS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["sessions"]["back-late2"] = {"id": "back-late2", "name": "back-late2", "state": "live", "role": "back", "side": None, "project": "projects/x", "created": "z"}; json.dump(d, open(sys.argv[1], "w"))
PY
dormant aws-platform bedrock; out=$(tick)
[ "$(ops)" = 2 ] && has "$out" "blocked: catch-up waits" && has "$out" "dormant too" && ok "catch-up with the fallback dormant too: nobody is moved onto a dormant lane" || bad "catch-up both dormant: ops=$(ops) $out"
rm -f "$ST/lane-state.tsv"

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
# stackshot's project record (the only thing a spawn's check reads): projects/foo lists lr-back-x as a back agent and lr-front-x as a front agent, written now
python3 - "$T/lr-projects.json" <<'PY'
import datetime, json, sys
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
ag = {"lr-back-x": {"front": False, "role": "back", "mandate_line": "a mandate"}, "lr-front-x": {"front": True, "role": "front", "mandate_line": "a front"}}
json.dump({"schema": 1, "generated": now, "projects": {"prj_foo": {"id": "prj_foo", "key": "projects/foo", "agents": ag}}, "by_key": {"projects/foo": "prj_foo"}}, open(sys.argv[1], "w"))
PY
sp() { OUT=$(ROOT="$ROOT" T="$T" PATH="$T/fakebin:$PATH" SALA_PROJECT_RECORD="$T/lr-projects.json" SALA_BIN="$ROOT/bin/salamander" bash "$ROOT/bin/salamander" spawn "$@" 2>&1); RC=$?; }
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

echo "== a back agent with no role in the registry counts by the project record's agents map"
# rl-back (listed under background:), rl-front (listed as front), rl-none (listed nowhere), rl-side (a side session) and rl-old (a stored role: front, though the record lists it
# as background) have no role in the registry, as the rows of the one-time import had none; the record is stackshot's projects.json (interface 20)
rec() {  # [generated epoch] → the record file
    python3 -I -S - "$SALA_PROJECT_RECORD" "$(iso "${1:-$NOW}")" <<'PY'
import json, sys
ag = lambda front: {"front": front, "role": "x", "mandate_line": "m"}
json.dump({"schema": 1, "generated": sys.argv[2], "by_key": {}, "projects": {"prj_t1": {"id": "prj_t1", "key": "projects/x", "retired": False, "agents": {
    "rl-back": ag(False), "rl-late": ag(False), "rl-front": ag(True), "rl-side": ag(False), "rl-old": ag(False)}}}}, open(sys.argv[1], "w"))
PY
}
regrl() {
    reg
    python3 -I -S - "$SESSIONS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); rows = d["sessions"]
for n, role, side in (("rl-back", None, None), ("rl-front", None, None), ("rl-none", None, None), ("rl-side", None, "fork"), ("rl-old", "front", None)):
    rows[n] = {"id": n, "name": n, "state": "live", "role": role, "side": side, "project": None, "created": n}
json.dump(d, open(sys.argv[1], "w"))
PY
    printf '%s\n' rl-back rl-front rl-none rl-side rl-old >> "$FAKE_LIVE"
    printf 'rl-back\tsubscription-1\nrl-front\tsubscription-1\nrl-none\tsubscription-1\nrl-side\tsubscription-1\nrl-old\tsubscription-1\n' >> "$FAKE_LANES"
}
rm -f "$SALA_PROJECT_RECORD"
regrl; quota 95 $W1; out=$(tick)
[ "$(ops)" = 1 ] && [ "$(op_names | tr ' ' '\n' | sort | paste -sd' ')" = "back-a back-b back-fab" ] && ok "with no project record, a row with no role moves nobody (as before)" || bad "no record: ops=$(ops) names=$(op_names)"
regrl; quota 95 $W1; rec $((NOW - 3600)); out=$(tick)
[ "$(op_names | tr ' ' '\n' | sort | paste -sd' ')" = "back-a back-b back-fab" ] && ok "a stale project record (an hour old) is not read" || bad "stale record: names=$(op_names)"
regrl; quota 95 $W1; rec; out=$(tick)
[ "$(ops)" = 1 ] && [ "$(op_names | tr ' ' '\n' | sort | paste -sd' ')" = "back-a back-b back-fab rl-back" ] && ok "step 1 carries the row with no role that the record lists under background: (rl-back), and no other row with none" || bad "record: ops=$(ops) names=$(op_names)"
case "$(op_names)" in *rl-front*|*rl-none*|*rl-side*|*rl-old*) bad "a front, unlisted, side or role-holding row moved: $(op_names)";; *) ok "a front-listed row, an unlisted one, a side session and a row whose stored role is front stay (a stored role is never overridden)";; esac
regrl; quota 95 $W1; rec; cp "$SESSIONS" "$T/sessions.before"; out=$(ROOT="$ROOT" T="$T" PATH="$T/fakebin:$PATH" bash "$ROOT/bin/salamander" watch --back-lanes --dry-run 2>&1)
has "$out" "would: step 1" && has "$out" "rl-back" && [ "$(ops)" = 0 ] && same_file "$SESSIONS" "$T/sessions.before" && ok "the dry run lists rl-back and writes nothing (the registry is as it was)" || bad "dry run: $out"
regrl; quota 95 $W1; rec; out=$(ROOT="$ROOT" T="$T" PATH="$T/fakebin:$PATH" SALA_BIN="$T/fakebin/salamander" bash "$ROOT/bin/salamander" watch --back-lanes 2>&1)
role=$(python3 -I -S -c 'import json,sys; r=json.load(open(sys.argv[1]))["sessions"]; print(r["rl-back"]["role"], r["rl-front"]["role"], r["rl-none"]["role"], r["rl-side"]["role"], r["rl-old"]["role"], r["rl-back"]["project"])' "$SESSIONS")
[ "$role" = "back front None None front projects/x" ] && ok "a real watch --back-lanes pass also writes the roles the record gives (rl-back back, rl-front front; rl-none, rl-side and the stored front left)" || bad "roles after the pass: $role"

echo "== the catch-up: a back agent the rule's move did not take goes at the next pass, once per window"
regrl; quota 95 $W1; rec; tick >/dev/null
[ "$(ops)" = 1 ] && [ "$(lane_of rl-back)" = aws-platform ] || bad "setup for the catch-up: ops=$(ops)"
q1=$(drv 'back_lane_get queued')
case "$q1" in "aws-platform|"*"|back-a,back-b,back-fab,rl-back") ok "step 1 records who it queued, in the state (<lane>|<window>|<names>)";; *) bad "queued: $q1";; esac
out=$(tick); [ "$(ops)" = 1 ] && has "$out" "idle:" && ok "a repeat pass: nobody is on the wrong side, nothing queued" || bad "no stragglers: ops=$(ops) $out"
python3 -I -S - "$SESSIONS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["sessions"]["back-late"] = {"id": "back-late", "name": "back-late", "state": "live", "role": "back", "side": None, "project": "projects/x", "created": "z"}; json.dump(d, open(sys.argv[1], "w"))
PY
echo back-late >> "$FAKE_LIVE"; printf 'back-late\tsubscription-1\n' >> "$FAKE_LANES"
out=$(ROOT="$ROOT" T="$T" PATH="$T/fakebin:$PATH" bash "$ROOT/bin/salamander" watch --back-lanes --dry-run 2>&1)
has "$out" "would: catch-up: sala op lane aws-platform back-late " && [ "$(ops)" = 1 ] && ok "a back agent still at home after the move: the dry run says it would queue it, and queues nothing" || bad "catch-up dry run: ops=$(ops) $out"
out=$(tick)
[ "$(ops)" = 2 ] && has "$out" "moved: catch-up" && case "$(tail -1 "$FAKE_OPLOG")" in "op|lane|aws-platform|back-late|--from|sala-watch|--words|$RULE_WORDS|") true;; *) false;; esac && ok "the next pass queues exactly that agent onto the rule's lane, with the rule's words" || bad "catch-up: ops=$(ops) $out :: $(tail -1 "$FAKE_OPLOG")"
case "$(drv 'back_lane_get queued')" in *"|back-a,back-b,back-fab,rl-back,back-late") ok "its name joins the window's queued list";; *) bad "queued after: $(drv 'back_lane_get queued')";; esac
printf 'back-late\tsubscription-1\n' > "$T/lanes.back"; grep -v '^back-late	' "$FAKE_LANES" > "$T/lanes.t"; cat "$T/lanes.t" "$T/lanes.back" > "$FAKE_LANES"   # the pane could not be closed: still at home
out=$(tick); [ "$(ops)" = 2 ] && has "$out" "idle:" && ok "a pane that stays at home is not queued a second time in the same window (the operation retries it itself)" || bad "twice: ops=$(ops) $out"
drv 'back_lane_put queued ""' >/dev/null; out=$(tick)
[ "$(ops)" = 3 ] && has "$out" "moved: catch-up" && ok "a state with no queued list (written before the catch-up): the back agents still at home are queued once" || bad "legacy state: ops=$(ops) $out"
case "$(tail -1 "$FAKE_OPLOG")" in *"|back-late|"*) case "$(tail -1 "$FAKE_OPLOG")" in *back-a*|*back-b*|*rl-back*|*front-a*) bad "legacy catch-up carried a pane already moved: $(tail -1 "$FAKE_OPLOG")";; *) ok "and only the one still at home";; esac;; *) bad "legacy argv: $(tail -1 "$FAKE_OPLOG")";; esac
regrl; quota 95 $W1; rec; tick >/dev/null; drv "back_lane_put moved_at $M" >/dev/null; quota 10 $W2; tick >/dev/null
[ "$(drv 'back_lane_get queued')" = "" ] && ok "step 3 (the way home) clears the queued list" || bad "after step 3: $(drv 'back_lane_get queued')"
regrl; quota 50 $W1; rec; n=$(ops)
out=$(tick)
[ "$(ops)" = "$n" ] && ! has "$out" "catch-up" && ok "the back agents at home (the rule's lane is home): no catch-up" || bad "no catch-up at home: $out"

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

echo "== THE FRONT STEP: the front agents move at the second threshold (default 95), onto the rule's lane"
unset SALA_BACK_LANE_FRONT_THRESHOLD
# regf: reg, then more front agents: b, fab (Fable by the models list), api (a lane outside the order), pin (pinned to home), dead (no pane), side (a side session)
regf() {
    reg; rm -f "$ST/lane-home.tsv" "$ST/lane-pins.tsv"
    python3 -I -S - "$SESSIONS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for n, side in (("front-b", None), ("front-fab", None), ("front-api", None), ("front-pin", None), ("front-dead", None), ("front-side", "fork")):
    d["sessions"][n] = {"id": n, "name": n, "state": "live", "role": "front", "side": side, "project": "projects/x", "created": n}
json.dump(d, open(sys.argv[1], "w"))
PY
    printf '%s\n' front-b front-fab front-api front-pin front-side >> "$FAKE_LIVE"
    printf 'front-b\tsubscription-1\nfront-fab\tsubscription-1\nfront-api\tapi\nfront-pin\tsubscription-1\nfront-dead\tsubscription-1\nfront-side\tsubscription-1\n' >> "$FAKE_LANES"
    printf 'front-fab\tfable\txhigh\n' >> "$ST/models.tsv"
    printf 'front-pin\tsubscription-1\n' > "$ST/lane-pins.tsv"
}
fop() { sed -n "${1}p" "$FAKE_OPLOG"; }
model_of() { awk -F'\t' -v n="$1" '$1 == n { m = $2 } END { print m }' "$ST/models.tsv"; }
home_of() { awk -F'\t' -v n="$1" '$1 == n { print $2 "|" $4 }' "$ST/lane-home.tsv" 2>/dev/null; }
BACK3="op|lane|aws-platform|back-a|back-b|back-fab|--from|sala-watch|--words|$RULE_WORDS|"
FRONT3="op|lane|aws-platform|front-a|front-b|front-fab|--from|sala-watch|--words|$RULE_WORDS|"
[ "$(drv 'echo "$SALA_BACK_LANE_FRONT_THRESHOLD"')" = 95 ] && ok "SALA_BACK_LANE_FRONT_THRESHOLD defaults to 95" || bad "default: $(drv 'echo "$SALA_BACK_LANE_FRONT_THRESHOLD"')"
out=$(SALA_BACK_LANE_WORDS= drv 'echo "$SALA_BACK_LANE_WORDS"'); has "$out" "the front agents too, at a second, higher threshold" && ok "the default words of the rule carry the clause about the front agents" || bad "words: $out"
# below the front threshold only the back agents move; the same window's rise to 95 then moves the front agents, alone
regf; quota 94 $W1; out=$(tick)
[ "$(ops)" = 1 ] && has "$out" "moved: step 1" && ! has "$out" "front step" && [ "$(lane_of front-a)" = subscription-1 ] && [ -z "$(drv 'back_lane_get front_window')" ] && ok "94%: step 1 moves the back agents; no front agent moves, no front state" || bad "94%: ops=$(ops) $out"
quota 95 $W1; out=$(tick)
[ "$(ops)" = 2 ] && has "$out" "moved: front step" && [ "$(fop 2)" = "$FRONT3" ] && ok "then 95% in the same window: the front step alone, onto aws-platform, with the rule's words" || bad "94 then 95: ops=$(ops) $(fop 2) / $out"
# from home at 95: step 1 first, then the front step on the lane step 1 chose
regf; quota 95 $W1; out=$(tick)
[ "$(ops)" = 2 ] && has "$out" "moved: step 1" && has "$out" "moved: front step" && [ "$(fop 1)" = "$BACK3" ] && [ "$(fop 2)" = "$FRONT3" ] && ok "95% from home: two operations, the back agents first, then the front agents, both onto aws-platform" || bad "95%: ops=$(ops) $(fop 1) $(fop 2) / $out"
has "$out" "3 front agent(s)" && has "$out" "skipped (pinned to subscription-1): front-pin" && ! has "$out" "notice:" && ok "the line counts the front agents and names the pinned one held out (no notice)" || bad "front line: $out"
[ "$(lane_of front-api)" = api ] && [ "$(lane_of front-dead)" = subscription-1 ] && [ "$(lane_of front-side)" = subscription-1 ] && [ "$(lane_of front-pin)" = subscription-1 ] && [ "$(lane_of back-api)" = api ] && ok "a front agent on a lane outside the order, with no pane, a side session and the pinned one stay" || bad "front others: api $(lane_of front-api) dead $(lane_of front-dead) side $(lane_of front-side) pin $(lane_of front-pin)"
[ "$(model_of front-fab)" = fable ] && [ -z "$(home_of front-fab)" ] && ok "a Fable front agent bound for aws-platform (which runs Fable) gets no model change and no home record" || bad "fable on aws: model $(model_of front-fab) home $(home_of front-fab)"
case "$(drv 'back_lane_get fqueued')" in "aws-platform|"*"|front-a,front-b,front-fab") ok "the state records who the front step queued (fqueued) and the window (front_window)";; *) bad "fqueued: $(drv 'back_lane_get fqueued')";; esac
[ -n "$(drv 'back_lane_get front_window')" ] && out=$(tick) && [ "$(ops)" = 2 ] && has "$out" "front step already fired in this weekly window" && ok "a repeat tick queues nothing and says the front step already fired" || bad "repeat: ops=$(ops) $out"
grep -q "front step" "$ST/lanes.log" && ok "the front move is in the lane log" || bad "no lane log line for the front step"
# the dry run: both steps, from home, nothing queued or written
regf; quota 95 $W1
out=$(ROOT="$ROOT" T="$T" PATH="$T/fakebin:$PATH" bash "$ROOT/bin/salamander" watch --back-lanes --dry-run 2>&1)
has "$out" "would: step 1" && has "$out" "would: front step" && has "$out" "sala op lane aws-platform front-a front-b front-fab" && has "$out" "skipped (pinned to subscription-1): front-pin" && [ "$(ops)" = 0 ] && [ ! -s "$STATE" ] && ok "watch --back-lanes --dry-run: what step 1 would do and what the front step would do on that lane; nothing queued or written" || bad "front dry run: $out"
# the threshold: off, 0, invalid, under the back threshold, over the reading, equal to the back threshold
for v in off 0; do regf; quota 95 $W1; out=$(SALA_BACK_LANE_FRONT_THRESHOLD=$v tick); [ "$(ops)" = 1 ] && ! has "$out" "front" && [ "$(lane_of front-a)" = subscription-1 ] && ok "SALA_BACK_LANE_FRONT_THRESHOLD=$v: the front agents never move and the real pass says nothing about it" || bad "front $v: ops=$(ops) $out"; done
out=$(SALA_BACK_LANE_FRONT_THRESHOLD=off drv 'back_lane_tick --dry-run'); has "$out" "the front step is off" && ok "the dry run says the front step is off" || bad "front off dry: $out"
regf; quota 95 $W1; out=$(SALA_BACK_LANE_FRONT_THRESHOLD=abc tick); [ "$(ops)" = 1 ] && has "$out" "the front step cannot run: SALA_BACK_LANE_FRONT_THRESHOLD is not a whole number or off (abc)" && ok "an invalid value: the back step runs, the front step is idle with a clear line" || bad "front abc: ops=$(ops) $out"
regf; quota 95 $W1; out=$(SALA_BACK_LANE_FRONT_THRESHOLD=85 tick); [ "$(ops)" = 1 ] && has "$out" "(85) is lower than SALA_BACK_LANE_THRESHOLD (90)" && ok "a front threshold under the back threshold: idle with a clear line" || bad "front 85: ops=$(ops) $out"
regf; quota 95 $W1; out=$(SALA_BACK_LANE_FRONT_THRESHOLD=98 tick); [ "$(ops)" = 1 ] && ok "98% front threshold, reading 95: only the back agents move" || bad "front 98: ops=$(ops) $out"
regf; quota 90 $W1; out=$(SALA_BACK_LANE_FRONT_THRESHOLD=90 tick); [ "$(ops)" = 2 ] && ok "a front threshold equal to the back threshold: both fire at 90%" || bad "front 90: ops=$(ops) $out"
# step 1 that cannot be taken leaves the rule's lane at home: the front step waits, with a line
regf; quota 95 $W1; echo aws-platform > "$FAKE_LC"; out=$(tick)
[ "$(ops)" = 0 ] && has "$out" "notice:" && has "$out" "the front agents stay" && ok "step 1 blocked: nothing moves; the front step says the back agents are still home" || bad "blocked step 1: ops=$(ops) $out"
rm -f "$FAKE_LC"; out=$(tick); [ "$(ops)" = 2 ] && ok "once step 1 can run, the same pass moves the back agents and the front agents" || bad "unblocked: ops=$(ops) $out"
# the target cannot take them: one notice per window, then a quiet line, then the move
regf; quota 92 $W1; tick >/dev/null; quota 96 $W1; echo aws-platform > "$FAKE_LC"; out=$(tick)
[ "$(ops)" = 1 ] && has "$out" "notice: the front agents should move to the aws-platform lane" && has "$out" "cannot take them" && ok "the rule's lane not ready: one notice, no front operation, the state unchanged" || bad "not ready: ops=$(ops) $out"
out=$(tick); [ "$(ops)" = 1 ] && has "$out" "blocked: front step waits" && ! has "$out" "notice:" && ok "the next tick: a quiet line, no second notice" || bad "not ready 2: $out"
rm -f "$FAKE_LC"; out=$(tick); [ "$(ops)" = 2 ] && has "$out" "moved: front step" && ok "when the lane is ready the front step moves" || bad "ready: ops=$(ops) $out"
# a failed operation: one notice, nothing recorded as queued, the next pass retries
regf; quota 92 $W1; tick >/dev/null; quota 96 $W1; echo 1 > "$FAKE_OP_RC"; out=$(tick)
[ "$(ops)" = 2 ] && has "$out" "notice: the front agents should move to the aws-platform lane" && has "$out" "not queued" && [ -z "$(drv 'back_lane_get front_window')" ] && ok "a refused operation: one notice, front_window not written" || bad "refused: $out"
out=$(tick); has "$out" "blocked: front step not queued" && ! has "$out" "notice:" && ok "the next tick: a quiet line" || bad "refused 2: $out"
rm -f "$FAKE_OP_RC"; out=$(tick); has "$out" "moved: front step" && ok "once the queue takes it, the front step moves" || bad "refused 3: $out"
# a dormant rule lane: the fallback takes the front agents too, and says why; with the fallback dormant too, one notice
regf; quota 92 $W1; tick >/dev/null; dormant aws-platform; quota 96 $W1; out=$(tick)
has "$out" "moved: front step" && has "$out" "aws-platform lane is dormant" && has "$out" "bedrock lane, its fallback, takes them" && [ "$(fop 2)" = "op|lane|bedrock|front-a|front-b|front-fab|--from|sala-watch|--words|$RULE_WORDS|" ] && ok "the rule's lane dormant: the front agents go to its fallback, never onto it, and the line says why" || bad "front dormant: $(fop 2) / $out"
regf; quota 92 $W1; tick >/dev/null; dormant aws-platform bedrock; quota 96 $W1; out=$(tick)
[ "$(ops)" = 1 ] && has "$out" "notice: the front agents should move" && has "$out" "dormant too" && ok "target and fallback both dormant: nobody moves, one notice that says why" || bad "front both dormant: ops=$(ops) $out"
out=$(tick); [ "$(ops)" = 1 ] && has "$out" "blocked: front step waits" && ! has "$out" "notice:" && ok "the next tick: a quiet line" || bad "front both dormant 2: $out"
rm -f "$ST/lane-state.tsv"

echo "== the front step's model swap: a Fable front agent bound for a lane that cannot run it"
# step 1's target dormant: the back agents and the front agents go to bedrock, which cannot run Fable
regf; quota 95 $W1; dormant aws-platform; out=$(tick)
[ "$(ops)" = 2 ] && [ "$(fop 2)" = "op|lane|bedrock|front-a|front-b|front-fab|--from|sala-watch|--words|$RULE_WORDS|" ] && ok "the Fable front agent is in the move to bedrock (the back one is left, as before)" || bad "swap move: ops=$(ops) $(fop 2) / $out"
has "$out" "model fable -> opus on the bedrock lane (it cannot run Fable): front-fab" && ok "the outcome line names the swap" || bad "swap line: $out"
[ "$(model_of front-fab)" = opus ] && ok "its model override is written (opus) before the move was queued" || bad "override: $(model_of front-fab)"
[ "$(home_of front-fab)" = "subscription-1|fable" ] && ok "lane-home records the lane it came from and the model it had" || bad "home: $(home_of front-fab)"
[ "$(model_of front-a)" = "" ] && [ -z "$(home_of front-a)" ] && ok "a front agent that is not on Fable gets no override and no home record" || bad "non-fable: $(model_of front-a) $(home_of front-a)"
[ "$(model_of back-fab)" = fable ] && [ -z "$(home_of back-fab)" ] && ok "the Fable back agent is untouched (it stays, as before)" || bad "back fable: $(model_of back-fab) $(home_of back-fab)"
rm -f "$ST/lane-state.tsv"
# the dry run names the swap and writes nothing
regf; quota 95 $W1; dormant aws-platform
out=$(ROOT="$ROOT" T="$T" PATH="$T/fakebin:$PATH" bash "$ROOT/bin/salamander" watch --back-lanes --dry-run 2>&1)
has "$out" "would: front step" && has "$out" "model fable -> opus on the bedrock lane" && [ "$(model_of front-fab)" = fable ] && [ -z "$(home_of front-fab)" ] && [ "$(ops)" = 0 ] && ok "dry run: says model fable -> opus on bedrock; no override, no home record, nothing queued" || bad "swap dry: $out"
rm -f "$ST/lane-state.tsv"
# a model change that cannot be written: that session is left out, with a notice; the others move; no trace of the swap
regf; quota 95 $W1; dormant aws-platform; out=$(SALA_FALLBACK_FABLE_MODEL=nonsense tick)
[ "$(fop 2)" = "op|lane|bedrock|front-a|front-b|--from|sala-watch|--words|$RULE_WORDS|" ] && ok "a failed model write leaves the Fable front agent out of the operation; the others move" || bad "failed write: $(fop 2) / $out"
has "$out" "notice: 1 front agent(s) did not move to the bedrock lane" && has "$out" "front-fab" && ok "one notice names it and why" || bad "failed write notice: $out"
[ "$(model_of front-fab)" = fable ] && [ -z "$(home_of front-fab)" ] && ok "no override and no home record are left behind" || bad "failed write residue: $(model_of front-fab) $(home_of front-fab)"
case "$(drv 'back_lane_get fqueued')" in *"|front-a,front-b") ok "it is not in the queued list, so the catch-up retries it";; *) bad "fqueued: $(drv 'back_lane_get fqueued')";; esac
out=$(SALA_FALLBACK_FABLE_MODEL=nonsense tick); [ "$(ops)" = 2 ] && has "$out" "blocked:" && ! has "$out" "notice:" && ok "the next pass still cannot write it: a quiet line, no second notice, nothing queued" || bad "failed write 2: ops=$(ops) $out"
out=$(tick); [ "$(ops)" = 3 ] && has "$out" "moved: front catch-up" && [ "$(fop 3)" = "op|lane|bedrock|front-fab|--from|sala-watch|--words|$RULE_WORDS|" ] && [ "$(model_of front-fab)" = opus ] && [ "$(home_of front-fab)" = "subscription-1|fable" ] && ok "once the model can be written the catch-up swaps it and moves it" || bad "failed write 3: ops=$(ops) $(fop 3) $(model_of front-fab) / $out"
rm -f "$ST/lane-state.tsv"
# the catch-up after step 2: the rule's lane moves on to bedrock, the front agents on aws-platform follow, the Fable one with its swap
regf; quota 95 $W1; tick >/dev/null; drv "back_lane_put moved_at $M" >/dev/null; pane_stop aws-platform workspace $((NOW - 60)); out=$(tick)
[ "$(ops)" = 4 ] && has "$out" "moved: step 2" && has "$out" "moved: front catch-up" && [ "$(fop 4)" = "op|lane|bedrock|front-a|front-b|front-fab|--from|sala-watch|--words|$RULE_WORDS|" ] && ok "step 2: the back agents go to bedrock and the front agents follow in the same pass (catch-up)" || bad "step 2 front: ops=$(ops) $(fop 4) / $out"
has "$out" "model fable -> opus on the bedrock lane" && [ "$(model_of front-fab)" = opus ] && [ "$(home_of front-fab)" = "aws-platform|fable" ] && ok "the Fable front agent: override written, home recorded as aws-platform with the model it had" || bad "step 2 swap: $(model_of front-fab) $(home_of front-fab) / $out"
out=$(tick); [ "$(ops)" = 4 ] && ok "a repeat pass queues nothing" || bad "step 2 repeat: ops=$(ops) $out"
rm -f "$SALA_LIMIT_STATE"

echo "== the front step home, the catch-up and the spawn"
# step 3 takes the front agents standing off home in the same operation as the back agents
regf; quota 95 $W1; tick >/dev/null; quota 10 $W2; out=$(tick)
[ "$(ops)" = 3 ] && has "$out" "moved: step 3" && has "$out" "3 back agent(s) and 3 front agent(s)" && [ "$(fop 3)" = "op|lane|subscription-1|back-a|back-b|back-fab|front-a|front-b|front-fab|--from|sala-watch|--words|$RULE_WORDS|" ] && ok "step 3: one operation carries the back agents and the front agents off home" || bad "step 3: ops=$(ops) $(fop 3) / $out"
[ "$(lane_of front-api)" = api ] && [ "$(lane_of back-api)" = api ] && ok "a lane outside the order stays" || bad "step 3 others"
[ -z "$(drv 'back_lane_get front_window')" ] && [ -z "$(drv 'back_lane_get fqueued')" ] && [ -z "$(drv 'back_lane_get fblocked')" ] && ok "step 3 clears the front step's record" || bad "step 3 state: $(cat "$STATE")"
quota 95 $W2; out=$(tick); [ "$(ops)" = 5 ] && ok "the next window can start it again: step 1 and the front step" || bad "next window: ops=$(ops) $out"
regf; quota 95 $W1; tick >/dev/null; drv 'back_lane_put moved_at 1' >/dev/null
out=$(ROOT="$ROOT" T="$T" PATH="$T/fakebin:$PATH" bash "$ROOT/bin/salamander" watch --back-lanes --dry-run 2>&1); n=$(ops); quota 10 $W2
out=$(ROOT="$ROOT" T="$T" PATH="$T/fakebin:$PATH" bash "$ROOT/bin/salamander" watch --back-lanes --dry-run 2>&1)
has "$out" "would: step 3" && has "$out" "the front agent(s) among them: front-a front-b front-fab" && [ "$(ops)" = "$n" ] && ok "dry run of step 3 names the front agents it takes home" || bad "dry step 3: $out"
# with the front step off and never fired, step 3 leaves a front agent off home where it is
regf; quota 95 $W1; SALA_BACK_LANE_FRONT_THRESHOLD=off tick >/dev/null; grep -v '^front-a	' "$FAKE_LANES" > "$T/lanes.t"; printf 'front-a\taws-platform\n' >> "$T/lanes.t"; cp "$T/lanes.t" "$FAKE_LANES"
quota 10 $W2; out=$(SALA_BACK_LANE_FRONT_THRESHOLD=off tick)
[ "$(fop 2)" = "op|lane|subscription-1|back-a|back-b|back-fab|--from|sala-watch|--words|$RULE_WORDS|" ] && [ "$(lane_of front-a)" = aws-platform ] && ok "front step off: step 3 carries only the back agents (the old behavior, byte for byte)" || bad "step 3 off: $(fop 2) front-a on $(lane_of front-a)"
# the catch-up: a front agent spawned after the front step fired is queued once per window
regf; quota 95 $W1; tick >/dev/null
python3 -I -S - "$SESSIONS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["sessions"]["front-late"] = {"id": "front-late", "name": "front-late", "state": "live", "role": "front", "side": None, "project": "projects/x", "created": "z"}; json.dump(d, open(sys.argv[1], "w"))
PY
echo front-late >> "$FAKE_LIVE"; printf 'front-late\tsubscription-1\n' >> "$FAKE_LANES"
out=$(ROOT="$ROOT" T="$T" PATH="$T/fakebin:$PATH" bash "$ROOT/bin/salamander" watch --back-lanes --dry-run 2>&1)
has "$out" "would: front catch-up: sala op lane aws-platform front-late " && [ "$(ops)" = 2 ] && ok "front catch-up dry run: says it would queue the late front agent, queues nothing" || bad "front catch-up dry: ops=$(ops) $out"
out=$(tick); [ "$(ops)" = 3 ] && has "$out" "moved: front catch-up" && [ "$(fop 3)" = "op|lane|aws-platform|front-late|--from|sala-watch|--words|$RULE_WORDS|" ] && ok "the next pass queues exactly that front agent onto the rule's lane" || bad "front catch-up: ops=$(ops) $(fop 3) / $out"
grep -v '^front-late	' "$FAKE_LANES" > "$T/lanes.t"; printf 'front-late\tsubscription-1\n' >> "$T/lanes.t"; cp "$T/lanes.t" "$FAKE_LANES"   # the pane could not be closed: still home
out=$(tick); [ "$(ops)" = 3 ] && ok "a pane that stays at home is not queued a second time in the same window" || bad "front catch-up twice: ops=$(ops) $out"
# a window that is over: no catch-up
drv 'back_lane_put front_window 1000' >/dev/null; drv 'back_lane_put fqueued ""' >/dev/null; quota 50 $W1; out=$(tick); [ "$(ops)" = 3 ] && ok "a front_window that is over: no catch-up" || bad "front window over: ops=$(ops) $out"
# the role from the project record: a front-listed row with no role and a stored-front row move with the front agents
regrl; quota 95 $W1; rec; out=$(tick)
[ "$(ops)" = 2 ] && [ "$(fop 2)" = "op|lane|aws-platform|front-a|rl-front|rl-old|--from|sala-watch|--words|$RULE_WORDS|" ] && ok "front names count a row with no role by the record (rl-front) and a stored front (rl-old); not rl-back, rl-none, rl-side" || bad "front record: ops=$(ops) $(fop 2)"
rm -f "$SALA_PROJECT_RECORD"
# spawn: a new front agent takes the rule's lane while the front step is engaged
regf; quota 95 $W1; tick >/dev/null
out=$(drv 'back_lane_front_spawn_lane; echo "rc=$?"'); [ "$out" = $'aws-platform\nrc=0' ] && ok "after the front step: a new front agent takes aws-platform" || bad "front spawn: $out"
out=$(SALA_BACK_LANE_FRONT_THRESHOLD=off drv 'back_lane_front_spawn_lane; echo "rc=$?"'); [ "$out" = "rc=1" ] && ok "front step off: the default lane" || bad "front spawn off: $out"
regf; quota 94 $W1; tick >/dev/null; out=$(drv 'back_lane_front_spawn_lane; echo "rc=$?"'); [ "$out" = "rc=1" ] && ok "the back agents off home but the front step not fired: a new front agent takes the default lane" || bad "front spawn not engaged: $out"
regf; quota 95 $W1; tick >/dev/null; drv 'back_lane_put front_window 1000' >/dev/null; out=$(drv 'back_lane_front_spawn_lane; echo "rc=$?"'); [ "$out" = "rc=1" ] && ok "a front_window that is over: the default lane" || bad "front spawn window over: $out"
regf; quota 95 $W1; tick >/dev/null; echo aws-platform > "$FAKE_LC"; out=$(drv 'back_lane_front_spawn_lane; echo "rc=$?"'); rm -f "$FAKE_LC"; [ "$out" = "rc=1" ] && ok "the rule's lane not ready: the default lane" || bad "front spawn not ready: $out"
regf; quota 95 $W1; tick >/dev/null
sp lr-front-x --project projects/foo --role front --dry-run
[ "$RC" = 0 ] && has "$OUT" "[dry-run] lane: the lane rule's front step is engaged and has the front agents on the aws-platform lane" && ok "spawn --dry-run of a front agent says it launches on aws-platform" || bad "spawn front dry: rc=$RC $OUT"
sp lr-front-x --project projects/foo --role front --model fable --dry-run
[ "$RC" = 0 ] && has "$OUT" "front step" && ! has "$OUT" "launches on opus" && ok "a Fable model on aws-platform (which runs it) is kept" || bad "spawn front fable aws: rc=$RC $OUT"
sp lr-front-x --project projects/foo --role front --lane bedrock --dry-run
[ "$RC" = 0 ] && ! has "$OUT" "front step" && ok "--lane wins over the rule" || bad "spawn front --lane: rc=$RC $OUT"
sp lr-side-quiet01 --side --project projects/foo --item s1 --dry-run
[ "$RC" = 0 ] && ! has "$OUT" "front step" && ok "a side session is not the rule's" || bad "spawn front side: rc=$RC $OUT"
sp lr-back-x --project projects/foo --role back --mandate "a mandate" --dry-run
[ "$RC" = 0 ] && has "$OUT" "the back agents' lane rule has them on the aws-platform lane" && ! has "$OUT" "front step" && ok "a back agent's spawn note is the old one" || bad "spawn back: rc=$RC $OUT"
regf; quota 95 $W1; dormant aws-platform; tick >/dev/null
sp lr-front-x --project projects/foo --role front --model fable --dry-run
[ "$RC" = 0 ] && has "$OUT" "the bedrock lane cannot run Fable, so it launches on opus" && ok "a Fable front agent on bedrock launches on opus, and the note says so" || bad "spawn front fable bedrock: rc=$RC $OUT"
rm -f "$ST/lane-state.tsv"

echo "== the roles file: a row the project record places nowhere takes its front or back entry"
# the row has no role; stackshot's roles.json (the Overview's Role column) names it: front moves with the front agents, back with the back agents; a flagged front or back entry (the keeper mark) moves with its role; the old keeper role, retired and stale: nobody
nr() {  # <name> → add a live row with no role, a pane and a lane on home
    python3 -I -S - "$SESSIONS" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); n = sys.argv[2]
d["sessions"][n] = {"id": n, "name": n, "state": "live", "role": None, "side": None, "project": None, "created": n}; json.dump(d, open(sys.argv[1], "w"))
PY
    echo "$1" >> "$FAKE_LIVE"; printf '%s\tsubscription-1\n' "$1" >> "$FAKE_LANES"
}
mkroles() {  # [generated epoch] → the roles file: rr-front front, rr-back back, rr-keeper keeper (the old form), rr-gone front but retired, rr-rec front (the record says back);
    # the keeper as a mark on one agent ("keeper": true beside a front or back role): rr-kfront front, rr-kback back, rr-kold the old keeper role with the flag, rr-kgone front, flagged and retired
    python3 -I -S - "$SALA_ROLES_FILE" "$(iso "${1:-$NOW}")" <<'PY'
import json, sys
e = lambda role, **kw: dict({"role": role, "project": "projects/x", "live": True}, **kw)
json.dump({"generated": sys.argv[2], "ids": {}, "sessions": {"rr-front": e("front"), "rr-back": e("back"), "rr-keeper": e("keeper"), "rr-gone": e("front", retired=True), "rr-rec": e("front"),
    "rr-kfront": e("front", keeper=True), "rr-kback": e("back", keeper=True), "rr-kold": e("keeper", keeper=True), "rr-kgone": e("front", keeper=True, retired=True)}},
          open(sys.argv[1], "w"))
PY
}
RRNAMES="rr-front rr-back rr-keeper rr-gone rr-rec rr-kfront rr-kback rr-kold rr-kgone"
regroles() { regf; for n in $RRNAMES; do nr "$n"; done; }
rr_rows() {  # the setup above discards its errors: an absent row would look like a row correctly refused a role, so each fixture row must exist, be live and have no role
    python3 -I -S - "$SESSIONS" $RRNAMES <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["sessions"]
bad = [n for n in sys.argv[2:] if n not in d or d[n].get("state") != "live" or d[n].get("role") is not None]
print(" ".join(bad) if bad else "ok")
PY
}
rec_rr() {  # the project record lists rr-rec as a background agent
    python3 -I -S - "$SALA_PROJECT_RECORD" "$(iso "$NOW")" <<'PY'
import json, sys
json.dump({"schema": 1, "generated": sys.argv[2], "by_key": {}, "projects": {"prj_t1": {"id": "prj_t1", "key": "projects/x", "retired": False, "agents": {"rr-rec": {"front": False, "role": "x", "mandate_line": "m"}}}}}, open(sys.argv[1], "w"))
PY
}
BACKRR="op|lane|aws-platform|back-a|back-b|back-fab|rr-rec|--from|sala-watch|--words|$RULE_WORDS|"   # rr-rec is listed under background: by the record
regroles; rec_rr; quota 95 $W1; out=$(tick)
[ "$(ops)" = 2 ] && [ "$(fop 1)" = "$BACKRR" ] && [ "$(fop 2)" = "$FRONT3" ] && ok "no roles file: the row the record lists moves (rr-rec); the other rows with no role move nobody (as before)" || bad "no roles file: ops=$(ops) $(fop 1) $(fop 2)"
regroles; rec_rr; mkroles; quota 95 $W1; out=$(tick)
[ "$(ops)" = 2 ] && [ "$(fop 1)" = "op|lane|aws-platform|back-a|back-b|back-fab|rr-back|rr-kback|rr-rec|--from|sala-watch|--words|$RULE_WORDS|" ] && ok "the roles file's back entry moves with the back agents, and the record's own listing (rr-rec, back) comes first" || bad "roles back: ops=$(ops) $(fop 1)"
[ "$(fop 2)" = "op|lane|aws-platform|front-a|front-b|front-fab|rr-front|rr-kfront|--from|sala-watch|--words|$RULE_WORDS|" ] && ok "its front entry moves with the front agents; a keeper entry, a retired entry and the back-listed rr-rec do not" || bad "roles front: $(fop 2)"
[ "$(rr_rows)" = ok ] && ok "the nine fixture rows exist, are live and have no role of their own" || bad "fixture rows missing or not as intended: $(rr_rows)"
case " $(fop 1) " in *"|rr-kback|"*) ok "a flagged back entry (the keeper mark on a builder, rr-kback) moves with the back agents though the row has no role";; *) bad "flagged back entry: $(fop 1)";; esac
case " $(fop 2) " in *"|rr-kfront|"*) ok "a flagged front entry (the keeper mark on a -main agent, rr-kfront) moves with the front agents though the row has no role";; *) bad "flagged front entry: $(fop 2)";; esac
case "$(fop 1) $(fop 2)" in *rr-kold*|*rr-kgone*|*rr-keeper*|*rr-gone*) bad "an uncounted entry moved: $(fop 1) / $(fop 2)";; *) ok "an entry whose role is the old keeper (flagged or not) and a flagged entry that is retired move nobody";; esac
regroles; rec_rr; mkroles $((NOW - 7200)); quota 95 $W1; out=$(tick)
[ "$(fop 1)" = "$BACKRR" ] && [ "$(fop 2)" = "$FRONT3" ] && ok "a stale roles file (2 h old) is not read" || bad "stale roles: $(fop 1) / $(fop 2)"
rm -f "$SALA_ROLES_FILE" "$SALA_PROJECT_RECORD"

echo "== the front home catch-up: a front agent step 3 did not take is queued home once per window"
# addfront <name> <lane>: a live front agent with a pane that stands on <lane>
addfront() {
    python3 -I -S - "$SESSIONS" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); n = sys.argv[2]
d["sessions"][n] = {"id": n, "name": n, "state": "live", "role": "front", "side": None, "project": "projects/x", "created": "z" + n}; json.dump(d, open(sys.argv[1], "w"))
PY
    echo "$1" >> "$FAKE_LIVE"; grep -v "^$1	" "$FAKE_LANES" > "$T/lanes.t"; printf '%s\t%s\n' "$1" "$2" >> "$T/lanes.t"; cp "$T/lanes.t" "$FAKE_LANES"
}
HOMEFRONT="op|lane|subscription-1|front-late|--from|sala-watch|--words|$RULE_WORDS|"
# athome: the rule at home after step 3 in the window W2 (the moves applied), then a front agent left on bedrock
athome() { regf; quota 95 $W1; tick >/dev/null; quota 10 $W2; tick >/dev/null; addfront front-late bedrock; }
athome; n=$(ops)
[ "$n" = 3 ] && [ "$(drv 'back_lane_current')" = subscription-1 ] || bad "setup: ops=$n current=$(drv 'back_lane_current')"
touch "$FAKE_NOMOVE"; out=$(tick)
[ "$(ops)" = 4 ] && has "$out" "moved: front catch-up (home): 1 front agent(s) the step home had not taken (front-late) to the Ultra lane" && [ "$(fop 4)" = "$HOMEFRONT" ] && ok "at home after step 3: the front agent left on bedrock is queued home, once, with the rule's words" || bad "home catch-up: ops=$(ops) $(fop 4) / $out"
case "$(drv 'back_lane_get hqueued')" in "subscription-1|"*"|front-a,front-b,front-fab,front-late") ok "the state records it (hqueued: <home>|<window>|<names>), after the front agents step 3 queued";; *) bad "hqueued: $(drv 'back_lane_get hqueued')";; esac
grep -q "front catch-up (home)" "$ST/lanes.log" && ok "the move is in the lane log" || bad "no lane log line"
out=$(tick); [ "$(ops)" = 4 ] && ok "a repeat tick (the pane has not moved yet) queues nothing" || bad "repeat: ops=$(ops) $out"
rm -f "$FAKE_NOMOVE"
# a second late front agent in the same window: queued alone, the first not again
touch "$FAKE_NOMOVE"; addfront front-late2 aws-platform; out=$(tick)
[ "$(ops)" = 5 ] && [ "$(fop 5)" = "op|lane|subscription-1|front-late2|--from|sala-watch|--words|$RULE_WORDS|" ] && ok "a second one in the same window: queued alone, the first is not asked twice" || bad "second: ops=$(ops) $(fop 5) / $out"
rm -f "$FAKE_NOMOVE"
# not in this window
regf; quota 50 $W1; addfront front-late bedrock; out=$(tick)
[ "$(ops)" = 0 ] && ok "step 3 never fired (the rule has been home all along): nothing queued" || bad "no step 3: ops=$(ops) $out"
athome; quota 10 $((W2 + 7 * 86400)); n=$(ops); out=$(tick)
[ "$(ops)" = "$n" ] && ok "a later window in which step 3 has not fired: nothing queued" || bad "later window: ops=$(ops) $out"
# the reading
athome; n=$(ops); quota 10 $W2 7200; out=$(tick); [ "$(ops)" = "$n" ] && ok "a stale reading: nothing queued" || bad "stale: ops=$(ops) $out"
rm -f "$T/web/quota-subscription-1.json"; out=$(tick); [ "$(ops)" = "$n" ] && ok "no reading: nothing queued" || bad "no reading: ops=$(ops) $out"
quota 90 $W2; out=$(drv 'back_lane_front_home_catchup 0'); [ "$(ops)" = "$n" ] && [ -z "$out" ] && ok "a reading at the threshold: nothing queued, nothing printed" || bad "at threshold: ops=$(ops) $out"
quota 99 $W2; out=$(drv 'back_lane_front_home_catchup 0'); [ "$(ops)" = "$n" ] && [ -z "$out" ] && ok "a reading above it: nothing queued" || bad "above: ops=$(ops) $out"
quota 89 $W2; out=$(drv 'back_lane_front_home_catchup 0'); [ "$(ops)" = $((n + 1)) ] && has "$out" "moved: front catch-up (home)" && ok "a reading just under it queues" || bad "89: ops=$(ops) $out"
# the home lane, the front step, the lane
athome; n=$(ops); dormant subscription-1; out=$(tick); [ "$(ops)" = "$n" ] && ok "the home lane dormant: nothing queued" || bad "home dormant: ops=$(ops) $out"
rm -f "$ST/lane-state.tsv"
echo subscription-1 > "$FAKE_LC"; out=$(tick); [ "$(ops)" = "$n" ] && ! has "$out" "catch-up (home)" && ok "the home lane not ready: nothing queued" || bad "home not ready: ops=$(ops) $out"
rm -f "$FAKE_LC"
for v in off 0; do out=$(SALA_BACK_LANE_FRONT_THRESHOLD=$v tick); [ "$(ops)" = "$n" ] && ok "the front step off ($v): nothing queued" || bad "front $v: ops=$(ops) $out"; done
SALA_BACK_LANE_RULE=off drv 'back_lane_tick' >/dev/null; [ "$(ops)" = "$n" ] && ok "the rule off: nothing queued" || bad "rule off: ops=$(ops)"
out=$(SALA_BACK_LANE_FRONT_THRESHOLD=abc tick); [ "$(ops)" = "$n" ] && ok "an invalid front threshold: nothing queued" || bad "front abc: ops=$(ops) $out"
# who: pinned held out and named, a lane outside the order, the side session and a pane-less row left
athome; n=$(ops)
grep -v '^front-pin	' "$FAKE_LANES" > "$T/lanes.t"; printf 'front-pin\tbedrock\n' >> "$T/lanes.t"; cp "$T/lanes.t" "$FAKE_LANES"
grep -v '^front-side	' "$FAKE_LANES" > "$T/lanes.t"; printf 'front-side\tbedrock\n' >> "$T/lanes.t"; cp "$T/lanes.t" "$FAKE_LANES"
grep -v '^front-dead	' "$FAKE_LANES" > "$T/lanes.t"; printf 'front-dead\tbedrock\n' >> "$T/lanes.t"; cp "$T/lanes.t" "$FAKE_LANES"
out=$(tick)
[ "$(ops)" = $((n + 1)) ] && [ "$(fop $((n + 1)))" = "$HOMEFRONT" ] && has "$out" "skipped (pinned to subscription-1): front-pin" && ok "a pinned front agent is held out and named; a side session, a pane-less row and a lane outside the order (front-api) stay" || bad "who: ops=$(ops) $(fop $((n + 1))) / $out"
# step 3's own front agents are not queued again in the same pass (their busy panes have not moved yet)
regf; quota 95 $W1; tick >/dev/null; touch "$FAKE_NOMOVE"; quota 10 $W2; out=$(tick)
[ "$(ops)" = 3 ] && has "$out" "moved: step 3" && ! has "$out" "catch-up (home)" && ok "step 3 and the same pass's catch-up: one operation, the front agents it took are not queued a second time" || bad "same pass: ops=$(ops) $out"
case "$(drv 'back_lane_get hqueued')" in "subscription-1|"*"|front-a,front-b,front-fab") ok "step 3 records the front agents it queued (hqueued)";; *) bad "hqueued after step 3: $(drv 'back_lane_get hqueued')";; esac
out=$(tick); [ "$(ops)" = 3 ] && ok "the next pass (panes still busy): nothing queued either" || bad "next pass: ops=$(ops) $out"
rm -f "$FAKE_NOMOVE"
# a refused operation: a blocked line, nothing recorded, the next pass retries
athome; n=$(ops); echo 1 > "$FAKE_OP_RC"; out=$(tick)
[ "$(ops)" = $((n + 1)) ] && has "$out" "blocked: front catch-up (home) not queued" && ! has "$(drv 'back_lane_get hqueued')" front-late && ok "a refused operation: a blocked line, nothing recorded" || bad "refused: ops=$(ops) $out"
rm -f "$FAKE_OP_RC"; out=$(tick); [ "$(ops)" = $((n + 2)) ] && has "$out" "moved: front catch-up (home)" && ok "once the queue takes it, the next pass queues it" || bad "refused 2: ops=$(ops) $out"
# the dry run: names the agent, writes and queues nothing
athome; n=$(ops); before=$(cat "$STATE")
out=$(ROOT="$ROOT" T="$T" PATH="$T/fakebin:$PATH" bash "$ROOT/bin/salamander" watch --back-lanes --dry-run 2>&1)
has "$out" "would: front catch-up (home): sala op lane subscription-1 front-late " && [ "$(ops)" = "$n" ] && [ "$(cat "$STATE")" = "$before" ] && ok "dry run: says what it would queue and names the agent; queues and writes nothing" || bad "dry: ops=$(ops) $out"
# step 1 in the next window clears the list
athome; touch "$FAKE_NOMOVE"; tick >/dev/null; rm -f "$FAKE_NOMOVE"; [ -n "$(drv 'back_lane_get hqueued')" ] || bad "setup: hqueued empty"
quota 95 $((W2 + 7 * 86400)); tick >/dev/null
[ "$(drv 'back_lane_current')" = aws-platform ] && [ -z "$(drv 'back_lane_get hqueued')" ] && ok "the next step 1 (the agents leave home again) clears hqueued" || bad "step 1 clear: $(drv 'back_lane_current') hq=$(drv 'back_lane_get hqueued')"
# the back catch-up and the front step off home are untouched
regf; quota 95 $W1; tick >/dev/null; out=$(tick); [ "$(ops)" = 2 ] && ! has "$out" "catch-up (home)" && ok "off home: no home catch-up line, the existing behavior" || bad "off home: ops=$(ops) $out"
rm -f "$SALA_ROLES_FILE"

# THE FABLE RULE at its default (SALA_FABLE_LANES=subscription-1): aws-platform cannot run Fable either; everything above ran with it listed, to test the rule's mechanics
echo "== Fable runs only on the Ultra lane: a Fable back agent stays off aws-platform, a Fable front agent is swapped to opus there, a spawn is swapped"
rm -f "$ST/lane-state.tsv"; reg; quota 95 $W1; out=$(SALA_FABLE_LANES=subscription-1 tick)
line=$(head -1 "$FAKE_OPLOG"); [ "$line" = "op|lane|aws-platform|back-a|back-b|--from|sala-watch|--words|$RULE_WORDS|" ] && has "$out" "notice:" && has "$out" "back-fab" && ok "the back step to aws-platform leaves the Fable back agent where it is, with one notice" || bad "default fable lanes, back: $line / $out"
regf; quota 95 $W1; out=$(SALA_FABLE_LANES=subscription-1 tick)
has "$out" "model fable -> opus on the aws-platform lane (it cannot run Fable): front-fab" && [ "$(model_of front-fab)" = opus ] && [ "$(home_of front-fab)" = "subscription-1|fable" ] && ok "the front step to aws-platform swaps the Fable front agent to opus and records what it had" || bad "default fable lanes, front: $(model_of front-fab) $(home_of front-fab) / $out"
SALA_FABLE_LANES=subscription-1 sp lr-front-x --project projects/foo --role front --model fable --dry-run
[ "$RC" = 0 ] && has "$OUT" "the aws-platform lane cannot run Fable, so it launches on opus" && ok "a Fable front agent spawned while the rule has the front agents on aws-platform launches on opus" || bad "default fable lanes, spawn: rc=$RC $OUT"
SALA_FABLE_LANES=subscription-1 sp lr-front-x --project projects/foo --role front --lane aws-platform --model fable --dry-run
[ "$RC" != 0 ] && has "$OUT" "Fable runs only on the Ultra lane (subscription-1)" && ok "an explicit --lane aws-platform --model fable is refused" || bad "default fable lanes, explicit: rc=$RC $OUT"
rm -f "$SALA_ROLES_FILE"

exit $fail
