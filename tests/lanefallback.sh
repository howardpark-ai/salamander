#!/usr/bin/env bash
# The automatic lane fallback (lib/common.sh "THE AUTOMATIC LANE FALLBACK", lib/lane.sh `lane fallback`,
# `lane dormant`, `lane exec`, lib/op.sh `lane fallback`, lib/watch.sh ld_fallback). The automatic fallback: a lane that turns dormant
# has its sessions moved to its fallback lane on their own, and they stay there until the owner or a session moves them back.
# Checked here, on fakes only (the compiled fake claude on sala-test-* panes in a private tmux server, systemd-run and systemctl stubs,
# Slack a file, the sign-in `claude auth status` a stub that never runs in a pane; nothing real is started, stopped or called):
#   THE MAP: the defaults (subscription-1, subscription-2, aws-platform, api, sdk → bedrock; bedrock → subscription-1), the old and alias names, `none`, a map from the
#     config; the fallback is used only if it is active and ready (a dormant one, one that cannot launch: one plain reason, rc 1).
#   THE PLAN: `lane fallback <lane> --dry-run` names the dormant lane, the fallback, each session, a Fable session's model change, the
#     default and the jobs, and writes nothing (lanes, homes, models, relaunches); a lane that is not dormant is refused.
#   THE TRIGGERS: `lane dormant` by hand queues ONE operation through `sala op lane fallback … --from sala-watch` with the standing words
#     of the fallback as the words (--no-fallback and SALA_LANE_FALLBACK_AUTO=off queue nothing); the watch's own detection
#     (Team's refused usage answer through `watch --signin`) queues the same and claims the "your call" post; with no usable fallback
#     nothing is queued and the one post carries "not moved automatically: <why>".
#   THE MOVE, end to end through the queue: every session recorded on the lane (the Fable one on opus, recorded in models.tsv and in the
#     home record; the master last, by the rescue), the default switched with its home kept under "(default)"; a session of another
#     lane stays; ONE Slack post naming the dead lane, the fallback, each session and the model change; no inbox line to sala-watch.
#   STAY: `lane active` moves nothing; the table's HOME column says where each came from and how to go back; `lane <home> <session>`
#     moves one back and clears its home row; `lane default <home>` clears the default's; moving back restores no model.
#   JOBS: `lane exec <dormant lane> -- …` runs on the fallback and says so on stderr (one line), as it is when there is none, and as it
#     is with the switch off; no unit file is read or written.
#   A queued move that finds its fallback gone dormant ends stuck (exit 4), named, with no claude -p.
# Usage: bash tests/lanefallback.sh   (exit 0 = pass; ~150 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_MASTER SALA_SET SALA_SET_SELF SALA_RECYCLE SALA_RETRY_WORKER SALA_LOCK_WHO SALA_LOCK_WAIT SALA_RELAUNCH_KIND \
      SALA_FLEET_HOSTS SALA_CGROUP_FILE SALA_OP_QUEUE SALA_OP_REBOOT SALA_OP_STUCK SALA_REBOOT_HOOKS SALA_NO_RELAUNCH SALA_RESCUE SALA_CLAUDE
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_CUSTOM_HEADERS CLAUDE_CONFIG_DIR CLAUDE_CODE_OAUTH_TOKEN SALA_LANE_API_KEY_FILE SALA_LANE_API_WORKSPACE_FILE \
      SALA_LANE_API_MCP_CONFIG SALA_LANE_TEAM_DIR SALA_WEB_STATE_DIR SALA_LANE_FALLBACK SALA_FALLBACK_NO_FABLE SALA_FALLBACK_FABLE_MODEL
unset AWS_PROFILE AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_BEARER_TOKEN_BEDROCK CLAUDE_CODE_USE_BEDROCK ANTHROPIC_BEDROCK_REGION_PREFIX \
      SALA_LANE_BEDROCK_PROFILE SALA_LANE_BEDROCK_CREDENTIALS_FILE
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, fake_up, tmux_socket_rm; SALA_LANE_FALLBACK_AUTO=off, SALA_SIGNIN_ALERT=off for the other suites
export SALA_LANE_FALLBACK_AUTO=on SALA_SIGNIN_ALERT=on   # this suite is about them
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
exec 7< "$HOME"; flock -n 7 || true   # the temp folder is locked while the suite runs (systemd-tmpfiles ageing honours it)
TEAM="$HOME/.claude-team"
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOME/anc" "$HOME/.aws" "$HOME/stubbin" "$TEAM" "$HOME/.local/state/sala-web"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"
cat > "$HOME/.local/bin/systemd-run" <<'EOF'
#!/bin/bash
# the stub unit: records the line; a sala-op-<id> launch runs its command detached (as the unit would), unless $HOME/norun exists
echo "$*" >> "$HOME/systemd-run.txt"
case " $* " in *" --on-active="*) exit 0;; esac
case "$*" in *--unit=sala-op-*) ;; *) exit 0;; esac
case "$*" in *-stuck\ *) ;; *) [ -e "$HOME/norun" ] && exit 0;; esac
cmd="${@: -1}"; SALA_CGROUP_FILE="$HOME/op-unit.cgroup" setsid bash -c "$cmd" </dev/null >/dev/null 2>&1 &
exit 0
EOF
echo "0::/user.slice/user-$EUID.slice/user@$EUID.service/app.slice/sala-op-1760000000-1.service" > "$HOME/op-unit.cgroup"
cat > "$HOME/.local/bin/systemctl" <<'EOF'
#!/bin/bash
echo "$*" >> "$HOME/systemctl.txt"
case "$*" in
    *is-active*sala-watch.service*) echo inactive; exit 3 ;;
    *is-active*) exit 3 ;;
    *is-system-running*) echo running; exit 0 ;;
    *) exit 0 ;;
esac
EOF
cat > "$HOME/fake-helper" <<'EOF'
#!/bin/bash
echo "run" >> "$HOME/helper-runs.txt"
echo "SALA-OP: stuck the test helper does nothing"
EOF
chmod +x "$HOME/.local/bin/systemd-run" "$HOME/.local/bin/systemctl" "$HOME/fake-helper"
# the sign-in watch's `claude auth status --json`: a stub of its own on a PATH the watch alone gets (a pane's `claude` is the compiled fake)
cat > "$HOME/stubbin/claude" <<'EOF'
#!/bin/bash
d="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
case "$1 $2" in "auth status") cat "$d/auth.json" 2>/dev/null; rc=$(cat "$d/auth.rc" 2>/dev/null); exit "${rc:-0}";; esac
exit 0
EOF
chmod +x "$HOME/stubbin/claude"
signed_in() {  # <dir> <subscriptionType> <orgName>
    printf '{\n  "loggedIn": true,\n  "authMethod": "claude.ai",\n  "apiProvider": "firstParty",\n  "configDirectory": "%s",\n  "email": "someone@example.com",\n  "orgId": "00000000-0000-4000-8000-000000000000",\n  "orgName": "%s",\n  "subscriptionType": "%s"\n}\n' "$1" "$3" "$2" > "$1/auth.json"; }
printf '{"fake":true}\n' > "$TEAM/.credentials.json"; signed_in "$HOME/.claude" max "someone@example.com's Organization"; signed_in "$TEAM" team ExampleOrg
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log" FAKE_LANE_LOG="$HOME/fake-lane.log" FAKE_TYPED_LOG="$HOME/typed.log" FAKE_BEDROCK_LOG="$HOME/fake-bedrock.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"   # one post per record, '%%' between them
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off
export SALA_LIMIT_ALERT=off SALA_LIMIT_RESUME=off SALA_STUCK_POST=off   # the other watches: not under test
export SALA_SIGNIN_EVERY=0 SALA_SIGNIN_API_EVERY=0 SALA_SIGNIN_API_URL="http://127.0.0.1:9/v1/messages" SALA_WEB_STATE_DIR="$HOME/.local/state/sala-web"
export SALA_OP_CLAUDE="$HOME/fake-helper" SALA_OP_POLL=1 SALA_OP_LOCK_WAIT=5 SALA_OP_SWEEP_WAIT=120 SALA_OP_SETTLE_WAIT=120 \
       SALA_OP_STUCK_TURNS=7 SALA_OP_STUCK_TIME=30 SALA_OP_HELPER_CWD="$HOME" SALA_RETRY_EVERY=2 SALA_RETRY_WINDOW=120 SALA_LANE_FALLBACK_WAIT=240
SALA="$ROOT/bin/salamander"; SOCK="sala-lanefallback-$$"; T="tmux -L $SOCK -f /dev/null"; RLOG="$HOME/.claude/salamander-revive.log"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's
cleanup() {
    local f p; for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done
    for p in $(pgrep -f "salamander op --settle" 2>/dev/null); do grep -qz "HOME=$HOME" "/proc/$p/environ" 2>/dev/null && kill "$p" 2>/dev/null; done
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    kill_fake_claude "$HOME/.local/share/claude/versions/9.9.9"
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux    # literal socket: the children run set -u
. "$ROOT/lib/common.sh"
as_op_unit   # this suite's own fleet verbs run as the queue's runner would (no master: the guards refuse a Claude caller otherwise)
OPS="$SALA_STATE_DIR/ops"; DONE="$OPS/done"; REC="$SALA_LANE_STATE"; WLOG="$HOME/.claude/salamander-watch.log"; MODELS="$SALA_STATE_DIR/models.tsv"
CRED="$HOME/.aws/credentials"; export SALA_LANE_BEDROCK_CREDENTIALS_FILE="$CRED"
mk() { local n="$1" u="$2"; shift 2; $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="sala-test-$n" -e FAKE_LOG="$FAKE_LOG" -e FAKE_LANE_LOG="$FAKE_LANE_LOG" -e FAKE_TYPED_LOG="$FAKE_TYPED_LOG" -e FAKE_BEDROCK_LOG="$FAKE_BEDROCK_LOG" "$@"; $T send-keys -t "sala-test-$n" 'claude' Enter; }
mval() { local f="$OPS/$1.op"; [ -f "$f" ] || f="$DONE/$1.op"; awk -F= -v k="$2" '$1==k {print substr($0, length(k)+2); exit}' "$f" 2>/dev/null; }   # <id> <key>
queued() { ls "$OPS"/*.op 2>/dev/null | wc -l; }
tick() { "$SALA" watch --ops >/dev/null 2>&1; }
sw() { PATH="$HOME/stubbin:$PATH" "$SALA" watch --signin >/dev/null 2>&1; }   # the sign-in watch, with the stub `claude auth status`
mrow() { awk -F'\t' -v s="$1" '$1==s {print $2}' "$MODELS" 2>/dev/null; }                 # <session> → its model in models.tsv
hrow() { awk -F'\t' -v s="$1" '$1==s {print $2 "/" $4}' "$SALA_LANE_HOME" 2>/dev/null; }  # <session> → "<home lane>/<model before or ->"
f() { lane_state_field "$1" "$2"; }
dposts() { local n; n=$(grep -c 'lane is dormant' "$POSTS" 2>/dev/null); echo "${n:-0}"; }
sumfiles() { cksum "$SALA_LANES" "$SALA_LANE_DEFAULT_FILE" "$SALA_LANE_HOME" "$MODELS" 2>&1 | paste -sd' '; }   # what a dry run must leave as it was
reset_posts() { : > "$POSTS"; }
wait_lock() { lock_wait "$SALA_RECYCLE_LOCK" 120; }
mkdir -p "$SALA_STATE_DIR"; : > "$POSTS"

echo "== the map: the defaults, the aliases, none, a config map; the fallback must be active and ready"
[ "$(lane_fallback_of subscription-1)|$(lane_fallback_of subscription-2)|$(lane_fallback_of aws-platform)|$(lane_fallback_of api)|$(lane_fallback_of sdk)|$(lane_fallback_of bedrock)" = "bedrock|bedrock|bedrock|bedrock|bedrock|subscription-1" ] \
    && ok "defaults: subscription-1, subscription-2, aws-platform, api, sdk → bedrock; bedrock → subscription-1" || bad "defaults: $(lane_fallback_of subscription-1)|$(lane_fallback_of subscription-2)|$(lane_fallback_of aws-platform)|$(lane_fallback_of api)|$(lane_fallback_of sdk)|$(lane_fallback_of bedrock)"
[ "$(lane_fallback_of awsplatform)" = bedrock ] && ok "the old name of aws-platform reads as aws-platform" || bad "awsplatform: $(lane_fallback_of awsplatform)"
lane_fallback_of nosuch >/dev/null && bad "a word that is no lane has a fallback" || ok "a word that is no lane: none"
[ "$(SALA_LANE_FALLBACK="subscription-1=subscription-2 subscription-2=none" lane_fallback_of subscription-1)" = subscription-2 ] && ! SALA_LANE_FALLBACK="subscription-1=subscription-2 subscription-2=none" lane_fallback_of subscription-2 >/dev/null && ! SALA_LANE_FALLBACK="subscription-1=subscription-2" lane_fallback_of api >/dev/null \
    && ok "a configured map: its pairs, 'none' and a lane with no pair have no fallback" || bad "configured map"
! SALA_LANE_FALLBACK="subscription-1=subscription-1" lane_fallback_of subscription-1 >/dev/null && ok "a lane that falls back to itself has none (one hop, never a loop)" || bad "self fallback"
out=$(lane_fallback_pick subscription-1); rc=$?
[ "$rc" = 1 ] && has "$out" "fallback, Bedrock, is not ready" && has "$out" "[example-bedrock]" && ok "bedrock without its profile: not ready, one plain reason (rc 1)" || bad "pick without credentials ($rc): $out"
printf '[example-bedrock]\naws_access_key_id = AKIADUMMYNOTREAL%s\naws_secret_access_key = dummy-not-real-%s\n' "$$" "$$" > "$CRED"
out=$(lane_fallback_pick subscription-1); rc=$?; [ "$rc" = 0 ] && [ "$out" = bedrock ] && ok "bedrock with its profile: picked" || bad "pick ($rc): $out"
lane_dormant_set bedrock "test: no access" hand
out=$(lane_fallback_pick subscription-1); rc=$?; [ "$rc" = 1 ] && has "$out" "fallback, Bedrock, is dormant too" && ok "a dormant fallback is not used: the reason names it" || bad "pick dormant ($rc): $out"
lane_dormant_clear bedrock "test"
out=$(lane_fallback_pick bedrock); rc=$?; [ "$rc" = 0 ] && [ "$out" = subscription-1 ] && ok "bedrock falls back to subscription-1" || bad "bedrock pick ($rc): $out"
lane_dormant_set subscription-1 "test: login gone" hand
out=$(lane_fallback_pick bedrock); rc=$?; [ "$rc" = 1 ] && has "$out" "fallback, Ultra, is dormant too" && ok "bedrock → subscription-1 with subscription-1 dormant: nothing" || bad "bedrock pick, subscription-1 dormant ($rc): $out"
out=$(lane_fallback_pick subscription-1); rc=$?; [ "$rc" = 0 ] && ok "subscription-1 dormant, bedrock fine: subscription-1 falls back to bedrock (one hop each way, never a chain)" || bad "subscription-1 pick ($rc): $out"
lane_dormant_clear subscription-1 "test"

echo "== setup: a (subscription-1), f (subscription-1, on Fable), m (the master, subscription-1), k (subscription-2); the default lane is subscription-1"
mk a "$(uuid 1)"; mk f "$(uuid 2)"; mk m "$(uuid 3)"; mk k "$(uuid 4)"
fake_up sala-test-a sala-test-f sala-test-m sala-test-k || exit 1
export SALA_MASTER=sala-test-m
lane_write sala-test-a subscription-1; lane_write sala-test-f subscription-1; lane_write sala-test-m subscription-1; lane_write sala-test-k subscription-2
model_write sala-test-f fable
[ "$(lane_default)" = subscription-1 ] && [ "$(lane_sessions_on subscription-1 | paste -sd' ')" = "sala-test-a sala-test-f sala-test-m" ] && ok "three sessions on subscription-1, one on subscription-2, the default is subscription-1" || bad "setup: $(lane_sessions_on subscription-1 | paste -sd' ') / default $(lane_default)"

echo "== the plan: a lane that is not dormant is refused; a dormant lane's plan names everything and writes nothing"
out=$("$SALA" lane fallback subscription-1 --dry-run 2>&1); rc=$?
[ "$rc" != 0 ] && has "$out" "the Ultra lane is not dormant" && ok "lane fallback subscription-1 while subscription-1 is active: refused, in plain words" || bad "active ($rc): $out"
"$SALA" lane dormant subscription-1 --no-fallback --reason "test: login gone" >/dev/null 2>&1
before=$(sumfiles); starts0=$(starts "$(uuid 1)")$(starts "$(uuid 2)")$(starts "$(uuid 3)")
out=$("$SALA" lane fallback subscription-1 --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "lane fallback: the Ultra lane is dormant" && has "$out" "to the Bedrock lane" && has "$out" "one hop" && ok "the plan header names the dead lane and the fallback" || bad "plan ($rc): $out"
has "$out" "sala-test-a: subscription-1 → bedrock" && has "$out" "sala-test-f: subscription-1 → bedrock, model fable → opus" && has "$out" "sala-test-m: subscription-1 → bedrock" && has "$out" "the master: by the rescue, last" \
    && ok "each session is named, the Fable one with its model change, the master last by the rescue" || bad "plan lines: $out"
! has "$out" "sala-test-k:" && ok "the subscription-2 session is not in subscription-1's plan" || bad "k in the plan: $out"
has "$out" "default lane: subscription-1 → bedrock" && has "$out" "jobs: a sala job whose lane is subscription-1 runs on bedrock while subscription-1 is dormant" && has "$out" "[dry-run]" && ok "the default and the jobs are in the plan, marked dry run" || bad "plan default/jobs: $out"
[ "$(sumfiles)" = "$before" ] && [ ! -e "$SALA_LANE_HOME" ] && [ "$(starts "$(uuid 1)")$(starts "$(uuid 2)")$(starts "$(uuid 3)")" = "$starts0" ] && [ "$(queued)" = 0 ] \
    && ok "the dry run wrote nothing: no lane row, default, home or model changed; no relaunch; nothing queued" || bad "the dry run changed something: $before → $(sumfiles); $(ls "$SALA_STATE_DIR")"
out=$("$SALA" lane fallback subscription-1 --bogus 2>&1); rc=$?; [ "$rc" != 0 ] && ok "an unknown flag is refused" || bad "lane fallback --bogus ($rc): $out"
out=$("$SALA" lane fallback --dry-run 2>&1); rc=$?; [ "$rc" != 0 ] && has "$out" "usage: salamander lane fallback" && ok "no lane: the usage line" || bad "lane fallback with no lane ($rc): $out"
"$SALA" lane active subscription-1 >/dev/null 2>&1

echo "== no usable fallback: nothing is queued, one alert line says why (by hand, and in the watch's one post)"
touch "$HOME/norun"; lane_dormant_set bedrock "test: no access" hand
out=$("$SALA" lane dormant subscription-1 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "no fallback: the Ultra lane's fallback, Bedrock, is dormant too" && [ "$(queued)" = 0 ] && ok "lane dormant subscription-1 with bedrock dormant: marked dormant, nothing queued, the reason said" || bad "no fallback ($rc, queued $(queued)): $out"
out=$("$SALA" lane fallback subscription-1 2>&1); rc=$?; [ "$rc" = 4 ] && has "$out" "no fallback move" && [ ! -e "$SALA_LANE_HOME" ] && ok "lane fallback subscription-1 by hand: exit 4, nothing recorded" || bad "lane fallback with no fallback ($rc): $out"
"$SALA" lane active subscription-1 >/dev/null 2>&1
reset_posts; signed_in "$TEAM" team ExampleOrg
printf '{"lane":"subscription-2","limits":[],"errorKind":"refused","nextTry":%s}\n' "$(( ($(date +%s) + 3600) * 1000 ))" > "$SALA_WEB_STATE_DIR/quota-team.json"
sw
[ "$(f subscription-2 2)|$(f subscription-2 6)" = "dormant|signal" ] && [ "$(queued)" = 0 ] && ok "the watch sees Team refused with bedrock dormant: Team dormant, nothing queued" || bad "watch signal without fallback: $(slurp "$REC") queued $(queued)"
grep -q 'the subscription-2 lane is dormant and nothing is moved' "$WLOG" 2>/dev/null && ok "the watch log says nothing is moved, and why" || bad "watch log: $(tail -3 "$WLOG" 2>/dev/null)"
sw
p=$(post "The Team lane is dormant"); [ "$(dposts)" = 1 ] && has "$p" "not moved automatically: the Team lane's fallback, Bedrock, is dormant too" && has "$p" "sala lane fallback subscription-2" && ok "the one post carries 'not moved automatically: <why>' and the hand form" || bad "post ($(dposts)): $(<"$POSTS")"
lane_dormant_clear subscription-2 "test"; lane_dormant_clear bedrock "test"; rm -f "$SALA_WEB_STATE_DIR/quota-team.json" "$SALA_STATE_DIR/lane-signin.state"; reset_posts

echo "== the watch's own detection queues the move: one operation from sala-watch with Rowan's words, and the post is claimed"
nap 2   # the saved usage answer must be newer than the lane's last change (the clear above)
printf '{"lane":"subscription-2","limits":[],"errorKind":"refused","nextTry":%s}\n' "$(( ($(date +%s) + 3600) * 1000 ))" > "$SALA_WEB_STATE_DIR/quota-team.json"
sw
[ "$(f subscription-2 2)|$(f subscription-2 6)" = "dormant|signal" ] && [ "$(queued)" = 1 ] && ok "Team refused: dormant by signal, ONE operation queued" || bad "watch signal: $(slurp "$REC") queued $(queued)"
W1=$(ls "$OPS"/*.op 2>/dev/null | head -1); W1=${W1##*/}; W1=${W1%.op}
[ "$(mval "$W1" from)" = sala-watch ] && [ "$(mval "$W1" verb)" = lane ] && [ "$(grep -c '^arg=' "$OPS/$W1.op")" = 2 ] && grep -qx 'arg=fallback' "$OPS/$W1.op" && grep -qx 'arg=subscription-2' "$OPS/$W1.op" && ok "the marker: verb lane, args fallback subscription-2, from sala-watch" || bad "marker: $(cat "$OPS/$W1.op")"
w=$(mval "$W1" words); has "$w" "Move automatically, stay" && has "$w" "Move them to the fallback on their own; they stay there until Rowan or a session moves them back." && has "$w" "Rowan's standing pick" \
    && ok "the words: Rowan's pick quoted verbatim" || bad "words: $w"
sw; sw
[ "$(dposts)" = 0 ] && [ "$(queued)" = 1 ] && ok "further ticks: no 'your call' post (the move's own notice says it), no second operation" || bad "after more ticks: posts $(dposts), queued $(queued)"
rm -f "$OPS/$W1.op"; lane_dormant_clear subscription-2 "test"; rm -f "$SALA_WEB_STATE_DIR/quota-team.json" "$SALA_STATE_DIR/lane-signin.state"; reset_posts

echo "== lane dormant by hand: --no-fallback and the switch queue nothing; the plain form queues the move"
"$SALA" lane dormant subscription-1 --no-fallback >/dev/null 2>&1
[ "$(queued)" = 0 ] && lane_dormant subscription-1 && ok "--no-fallback: dormant, nothing queued" || bad "--no-fallback queued: $(ls "$OPS")"
"$SALA" lane active subscription-1 >/dev/null 2>&1
out=$(SALA_LANE_FALLBACK_AUTO=off "$SALA" lane dormant subscription-1 2>&1); [ "$(queued)" = 0 ] && has "$out" "SALA_LANE_FALLBACK_AUTO is off" && ok "SALA_LANE_FALLBACK_AUTO=off: dormant, nothing queued, said so" || bad "auto off: queued $(queued): $out"
"$SALA" lane active subscription-1 >/dev/null 2>&1
out=$("$SALA" lane dormant subscription-1 --dry-run 2>&1); lane_dormant subscription-1 && bad "dry run marked it" || { has "$out" "then queue their move onto the Bedrock lane" && [ "$(queued)" = 0 ] && ok "lane dormant subscription-1 --dry-run: says it would queue the move, writes nothing"; } || bad "dormant dry run: $out"
out=$("$SALA" lane dormant subscription-1 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(queued)" = 1 ] && has "$out" "is queued (op " && ok "lane dormant subscription-1: marked dormant and the move queued (the op id said)" || bad "lane dormant ($rc, queued $(queued)): $out"
W2=$(ls "$OPS"/*.op 2>/dev/null | head -1); W2=${W2##*/}; W2=${W2%.op}
[ "$(mval "$W2" from)" = sala-watch ] && has "$(mval "$W2" words)" "Rowan's standing pick" && ok "queued from sala-watch with the standing-pick words" || bad "by-hand marker: $(cat "$OPS/$W2.op")"
[ -n "$(f subscription-1 5)" ] && ok "the dormant post is claimed (the move's own notice stands in for it)" || bad "subscription-1 posted column empty: $(slurp "$REC")"
[ ! -e "$SALA_LANE_HOME" ] && [ "$(lane_row sala-test-a)" = subscription-1 ] && ok "queued only: nobody has moved yet" || bad "moved before the runner: $(lane_row sala-test-a)"

echo "== the move, end to end through the queue"
rm -f "$HOME/norun"; : > "$POSTS"
starts_a=$(starts "$(uuid 1)"); starts_f=$(starts "$(uuid 2)"); starts_m=$(starts "$(uuid 3)"); starts_k=$(starts "$(uuid 4)")
tick
waitfor "[ -f '$DONE/$W2.op' ]" 480 && ok "the operation ran and was archived" || bad "op: $(cat "$OPS/$W2.op" "$DONE/$W2.op" 2>/dev/null) / $(tail -8 "$HOME/.claude/salamander-op-$W2.log" 2>/dev/null)"
[ "$(mval "$W2" state)" = done ] && ok "state done" || bad "state $(mval "$W2" state): $(mval "$W2" result)"
wait_lock
[ "$(lane_row sala-test-a)|$(lane_row sala-test-f)|$(lane_row sala-test-m)|$(lane_row sala-test-k)" = "bedrock|bedrock|bedrock|subscription-2" ] && ok "a, f and the master recorded on bedrock; the subscription-2 session untouched" || bad "rows: $(lane_row sala-test-a)|$(lane_row sala-test-f)|$(lane_row sala-test-m)|$(lane_row sala-test-k)"
waitfor "[ \"\$(proc_lane \"\$(cpid a)\")\" = bedrock ]" 240 && waitfor "[ \"\$(proc_lane \"\$(cpid f)\")\" = bedrock ]" 240 && waitfor "[ \"\$(proc_lane \"\$(cpid m)\")\" = bedrock ]" 240 \
    && ok "relaunched: a, f and the master (by the rescue) run on bedrock (proc_lane)" || bad "running lanes: $(proc_lane "$(cpid a)") $(proc_lane "$(cpid f)") $(proc_lane "$(cpid m)")"
[ "$(proc_lane "$(cpid k)")" = subscription-1 ] && [ "$(starts "$(uuid 4)")" = "$starts_k" ] && ok "k was not relaunched" || bad "k: starts $(starts "$(uuid 4)") vs $starts_k"
[ "$(starts "$(uuid 1)")" -gt "$starts_a" ] && [ "$(starts "$(uuid 2)")" -gt "$starts_f" ] && [ "$(starts "$(uuid 3)")" -gt "$starts_m" ] && ok "each moved session was relaunched" || bad "starts: a $(starts "$(uuid 1)")/$starts_a f $(starts "$(uuid 2)")/$starts_f m $(starts "$(uuid 3)")/$starts_m"
[ "$(hrow sala-test-a)|$(hrow sala-test-m)" = "subscription-1/-|subscription-1/-" ] && ok "the home record: a and the master came from subscription-1" || bad "homes: $(cat "$SALA_LANE_HOME")"
[ "$(hrow sala-test-f)" = "subscription-1/fable" ] && [ "$(mrow sala-test-f)" = opus ] && ok "the Fable session: runs on opus (models.tsv), and the home record keeps the model it had (fable)" || bad "f: home $(hrow sala-test-f) model $(mrow sala-test-f)"
[ "$(mrow sala-test-a)" = "" ] && ok "a session not on Fable gets no model override" || bad "a model: $(mrow sala-test-a)"
[ "$(lane_default)" = bedrock ] && [ "$(hrow '(default)')" = "subscription-1/-" ] && ok "the default lane moved to bedrock, and its home (subscription-1) is kept" || bad "default: $(lane_default) / $(hrow '(default)')"
n=$(nposts 'sala op: lane fallback')
[ "$n" = 1 ] && [ "$(nposts '')" = 1 ] && ok "ONE Slack post for the whole batch" || bad "posts: $n — $(<"$POSTS")"
p=$(post "sala op: lane fallback")
has "$p" "Ultra" && has "$p" "Bedrock" && has "$p" "sala op: lane fallback subscription-1 · done* · 3 sessions" && ok "the post names the dead lane and the fallback, and counts the sessions moved" || bad "post: $p"
! has "$p" "sala-test-a" && ! has "$p" "sala-test-f" && ! has "$p" "sala-test-m" && has "$p" "default lane: subscription-1 → bedrock" && ok "the sessions that moved are counted, not listed; the default lane's line stays" || bad "post names: $p"
! has "$p" "sala-test-k" && ok "the subscription-2 session is not in it" || bad "post names k: $p"
! grep -q 'sala-watch' "$HOME/.claude/salamander-inbox"* 2>/dev/null && ok "no inbox line to sala-watch (no session waits on a watch-queued operation)" || bad "inbox line to sala-watch"
grep -q $'\tfallback\t' "$SALA_LANE_LOG" && ok "a 'fallback' line in lanes.log" || bad "lanes.log: $(tail -5 "$SALA_LANE_LOG")"

echo "== stay: nothing moves back by itself; the table says where each came from and how to go back"
before=$(sumfiles); sf=$(starts "$(uuid 1)")
"$SALA" lane active subscription-1 >/dev/null 2>&1; tick; nap 3
[ "$(lane_row sala-test-a)" = bedrock ] && [ "$(sumfiles)" = "$before" ] && [ "$(starts "$(uuid 1)")" = "$sf" ] && [ "$(queued)" = 0 ] && ok "lane active subscription-1: no session, default or model moves back; nothing queued" || bad "after active: $(lane_row sala-test-a) $before → $(sumfiles) queued $(queued)"
tbl=$("$SALA" lane 2>&1)
has "$tbl" "HOME" && has "$tbl" "moved off subscription-1 by the lane fallback — back: salamander lane subscription-1 sala-test-a" && ok "the table: a HOME column, and the way back for a" || bad "table: $tbl"
has "$tbl" "the lane fallback moved it off subscription-1 (back: salamander lane default subscription-1)" && ok "the table: the default says it was moved off subscription-1" || bad "table default: $tbl"
echo "== back by hand: lane <home> <session> clears its home row, restores no model; lane default <home> clears the default's"
out=$("$SALA" lane subscription-1 sala-test-a 2>&1); rc=$?; wait_lock
[ "$rc" = 0 ] && [ "$(lane_row sala-test-a)" = subscription-1 ] && [ -z "$(hrow sala-test-a)" ] && ok "lane subscription-1 sala-test-a: back on subscription-1, its home row gone" || bad "back ($rc): $(lane_row sala-test-a) home '$(hrow sala-test-a)': $out"
waitfor "[ \"\$(proc_lane \"\$(cpid a)\")\" = subscription-1 ]" 240 && ok "a runs on subscription-1 again" || bad "a runs on $(proc_lane "$(cpid a)")"
out=$("$SALA" lane subscription-1 sala-test-f 2>&1); wait_lock
[ -z "$(hrow sala-test-f)" ] && [ "$(mrow sala-test-f)" = opus ] && ok "f back on subscription-1 keeps opus: moving back restores no model" || bad "f after back: home '$(hrow sala-test-f)' model $(mrow sala-test-f)"
out=$("$SALA" lane default subscription-1 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(lane_default)" = subscription-1 ] && [ -z "$(hrow '(default)')" ] && ok "lane default subscription-1: the default is back, its home row gone" || bad "default back ($rc): $(lane_default) '$(hrow '(default)')': $out"
[ "$(hrow sala-test-m)" = "subscription-1/-" ] && ok "the master's home row stays until it is moved back (the rescue clears it only when it lands on its home)" || bad "m home: $(hrow sala-test-m)"

echo "== bedrock → subscription-1: a Fable session needs no model change on subscription-1"
lane_write sala-test-a bedrock; model_write sala-test-a fable
lane_dormant_set bedrock "test: no access" hand
out=$("$SALA" lane fallback bedrock --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "the Bedrock lane is dormant" && has "$out" "to the Ultra lane" && has "$out" "sala-test-a: bedrock → subscription-1" && ! has "$out" "model fable → opus" && ok "bedrock → subscription-1: planned, no model line (only bedrock cannot run Fable)" || bad "bedrock plan ($rc): $out"
lane_dormant_clear bedrock "test"; lane_write sala-test-a subscription-1; model_drop sala-test-a

echo "== jobs: a dormant lane's job runs on the fallback, said once on stderr; with no fallback, or the switch off, it runs as it is"
lane_dormant_set subscription-1 "test: login gone" hand
out=$("$SALA" lane exec subscription-1 -- sh -c 'echo "profile=${AWS_PROFILE:-none}"' 2>"$HOME/exec.err"); err=$(slurp "$HOME/exec.err")
[ "$out" = "profile=example-bedrock" ] && has "$err" "lane exec: the Ultra lane is dormant" && has "$err" "runs on its fallback, the Bedrock lane" && [ "$(wc -l < "$HOME/exec.err")" = 1 ] \
    && ok "lane exec subscription-1 while dormant: runs with the bedrock profile, one stderr line" || bad "exec fallback: out '$out' err '$err'"
out=$(SALA_LANE_FALLBACK_AUTO=off "$SALA" lane exec subscription-1 -- sh -c 'echo "profile=${AWS_PROFILE:-none}"' 2>"$HOME/exec.err"); err=$(slurp "$HOME/exec.err")
[ "$out" = "profile=none" ] && [ -z "$err" ] && ok "SALA_LANE_FALLBACK_AUTO=off: the job runs on subscription-1 as it is, no line" || bad "exec off: out '$out' err '$err'"
lane_dormant_set bedrock "test: no access" hand
out=$("$SALA" lane exec subscription-1 -- sh -c 'echo "profile=${AWS_PROFILE:-none}"' 2>"$HOME/exec.err"); err=$(slurp "$HOME/exec.err")
[ "$out" = "profile=none" ] && has "$err" "has no usable fallback" && has "$err" "runs on it as it is" && ok "bedrock dormant too: the job runs on subscription-1 as it is, one line saying so" || bad "exec no fallback: out '$out' err '$err'"
lane_dormant_clear bedrock "test"; lane_dormant_clear subscription-1 "test"
out=$("$SALA" lane exec subscription-1 -- sh -c 'echo "profile=${AWS_PROFILE:-none}"' 2>"$HOME/exec.err"); err=$(slurp "$HOME/exec.err")
[ "$out" = "profile=none" ] && [ -z "$err" ] && ok "subscription-1 active: the job runs on subscription-1, no line" || bad "exec active: out '$out' err '$err'"

echo "== a queued move whose fallback went dormant meanwhile ends stuck (exit 4), named, with no claude -p"
touch "$HOME/norun"; lane_dormant_set subscription-1 "test: login gone" hand
enq lane fallback subscription-1 --from sala-test-a --words "test: move subscription-1's sessions"; S1="$ID"
[ "$RC" = 0 ] && [ -n "$S1" ] && ok "queued by a person with the lane fallback verb" || bad "queue ($RC): $OUT"
lane_dormant_set bedrock "test: no access" hand; rm -f "$HOME/norun"; : > "$HOME/helper-runs.txt"
tick; waitfor "[ -f '$DONE/$S1.op' ]" 240
[ "$(mval "$S1" state)" = stuck ] && has "$(mval "$S1" result)" "exited 4" && ok "the operation ends stuck with the exit and the reason" || bad "stuck: $(mval "$S1" state) / $(mval "$S1" result)"
[ "$(grep -c run "$HOME/helper-runs.txt" 2>/dev/null)" = 0 ] && ok "no claude -p helper was run (a person's call)" || bad "helper ran: $(<"$HOME/helper-runs.txt")"
enq lane fallback bedrock --from t --words x; [ "$RC" != 0 ] && ok "queue time: the plan of a lane with no usable fallback refuses it" || bad "queued with no usable fallback: $OUT"
enq lane fallback nosuch --from t --words x; [ "$RC" = 2 ] && has "$OUT" "not a lane" && ok "an unknown lane: refused at queue time" || bad "unknown lane ($RC): $OUT"
enq lane fallback subscription-1 sala-test-a --from t --words x; [ "$RC" = 2 ] && ok "extra words after the lane: refused" || bad "extra words ($RC): $OUT"

[ "${fail:-0}" = 0 ] && echo "lanefallback: pass" || { echo "lanefallback: FAIL"; exit 1; }
