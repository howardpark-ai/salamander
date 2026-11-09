#!/usr/bin/env bash
# The monthly usage cap (lib/watch.sh "THE MONTHLY CAP", ld_cap_tick, ld_cap_expire; lib/common.sh lane_dormant_capped; lib/lane.sh
# pane_cut_turn and the lane fallback). A lane can be stopped by a MONTHLY cap: the provider's 429 says the account crossed its monthly
# usage threshold and when access returns. The limit watch used to treat it as a passing rate limit: the lane never went dormant, so no
# fallback ran, every pane was told again and again to handle its last message (which restarts the 429 retry loop) and the same
# "lane working again" post came over and over.
# Checked here, on fakes only (the compiled fake claude on sala-test-* panes in a private tmux server, systemd-run and systemctl stubs,
# Slack a file; nothing real is started, stopped or called). The EVENT IS STAGED: a fixture 429 (tests/fixtures/limit-monthly.jsonl) is
# written to the transcripts of two panes on the Team lane (subscription-2), and the real watch, queue and fallback run on it.
#   DETECTION: the lane goes dormant by signal until the regain time the text names (UTC, the seventh column of lane-state.tsv); one
#     pane's text is worded and spaced differently (the match is tolerant); the stop needs no SALA_LIMIT_CONFIRM wait.
#   THE FALLBACK IS QUEUED: ONE operation from sala-watch, `lane fallback subscription-2`, however many ticks run.
#   NO POKES, NO POSTS WHILE IT WAITS: with the move still queued, repeated ticks post nothing and tell no pane on the dormant lane to
#     handle its last message (the retry loop's restart).
#   THE MOVE: the fixture sessions move to the fallback lane (the lane map's, not a name in the code); a session already on the
#     fallback stays (not relaunched); a session of another lane stays; a pane that is MID-TURN (busy for ever, a retry loop) is moved
#     too, its turn cut by one Escape (pane_cut_turn), a pane that was idle gets no Escape; a PINNED session on the capped lane (also mid-turn)
#     is neither cut nor moved and is listed as skipped (pinned), in the plan and in the operation's log.
#   ONE POST: exactly one post across the whole episode, naming the lane, the regain day and the fallback; more ticks after the move add none.
#   THE END: the regain time passing brings the lane back by itself (the record alone, no probe); no post of its own.
#   NO FALLBACK: with the automatic move off, the episode's one post says when access returns and that moving is the operator's call;
#     repeated ticks post nothing more.
# Usage: bash tests/monthlycap.sh   (exit 0 = pass; ~90 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_MASTER SALA_SET SALA_SET_SELF SALA_RECYCLE SALA_RETRY_WORKER SALA_LOCK_WHO SALA_LOCK_WAIT SALA_RELAUNCH_KIND \
      SALA_FLEET_HOSTS SALA_CGROUP_FILE SALA_OP_QUEUE SALA_OP_REBOOT SALA_OP_STUCK SALA_REBOOT_HOOKS SALA_NO_RELAUNCH SALA_RESCUE SALA_CLAUDE SALA_TZ
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_CUSTOM_HEADERS CLAUDE_CONFIG_DIR CLAUDE_CODE_OAUTH_TOKEN SALA_LANE_API_KEY_FILE SALA_LANE_API_WORKSPACE_FILE \
      SALA_LANE_API_MCP_CONFIG SALA_LANE_TEAM_DIR SALA_WEB_STATE_DIR SALA_LANE_FALLBACK SALA_FALLBACK_NO_FABLE SALA_FALLBACK_FABLE_MODEL
unset AWS_PROFILE AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_BEARER_TOKEN_BEDROCK CLAUDE_CODE_USE_BEDROCK ANTHROPIC_BEDROCK_REGION_PREFIX \
      SALA_LANE_BEDROCK_PROFILE SALA_LANE_BEDROCK_CREDENTIALS_FILE
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export SALA_LANE_FALLBACK_AUTO=on SALA_SIGNIN_ALERT=off   # this suite is about the fallback; the sign-in watch is not under test
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
exec 7< "$HOME"; flock -n 7 || true   # the temp folder is locked while the suite runs (systemd-tmpfiles ageing honours it)
TEAM="$HOME/.claude-team"; P="$HOME/.claude/projects/x"
mkdir -p "$HOME/.claude/sessions" "$P" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOME/work" "$HOME/.aws" "$TEAM" "$HOME/.local/state/sala-web"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" -lpthread || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (the EXIT trap does not exist yet)
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
printf '{"fake":true}\n' > "$TEAM/.credentials.json"
printf '[example-bedrock]\naws_access_key_id = [masked secret]%s\naws_secret_access_key = dummy-not-real-%s\n' "$$" "$$" > "$HOME/.aws/credentials"   # bedrock is ready
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log" FAKE_SOCK_LOG="$HOME/sock.log" FAKE_LANE_LOG="$HOME/fake-lane.log" FAKE_TYPED_LOG="$HOME/typed.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"   # one post per record, '%%' between them
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off SALA_STUCK_POST=off
export SALA_LIMIT_PSTART="*=0"   # the records here are dated before the fake claudes started: every pane's process "started" at 0
export SALA_IDLE_SETTLE=3 SALA_CUT_WAIT=30   # short, so the cut pane is idle for the relaunch after seconds, not ten
export SALA_LANE_BEDROCK_CREDENTIALS_FILE="$HOME/.aws/credentials"
export SALA_OP_CLAUDE="$HOME/fake-helper" SALA_OP_POLL=1 SALA_OP_LOCK_WAIT=5 SALA_OP_SWEEP_WAIT=120 SALA_OP_SETTLE_WAIT=120 \
       SALA_OP_STUCK_TURNS=7 SALA_OP_STUCK_TIME=30 SALA_OP_HELPER_CWD="$HOME" SALA_RETRY_EVERY=2 SALA_RETRY_WINDOW=120 SALA_LANE_FALLBACK_WAIT=240
SALA="$ROOT/bin/salamander"; SOCK="sala-monthlycap-$$"; T="tmux -L $SOCK -f /dev/null"; RLOG="$HOME/.claude/salamander-revive.log"
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
as_op_unit   # this suite's own fleet verbs run as the queue's runner would
OPS="$SALA_STATE_DIR/ops"; DONE="$OPS/done"; REC="$SALA_LANE_STATE"; WLOG="$HOME/.claude/salamander-watch.log"
mkdir -p "$SALA_STATE_DIR"; : > "$POSTS"

# a fake claude pane; extra tmux -e VAR=val after the uuid. FAKE_ESC_IDLE: an Escape ends a busy turn, as the CLI's does.
mk() { local n="$1" u="$2"; shift 2; $T new-session -d -s "sala-test-$n" -c "$HOME/work" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="sala-test-$n" -e FAKE_LOG="$FAKE_LOG" \
         -e FAKE_SOCK_LOG="$FAKE_SOCK_LOG" -e FAKE_LANE_LOG="$FAKE_LANE_LOG" -e FAKE_TYPED_LOG="$FAKE_TYPED_LOG" -e FAKE_ESC_IDLE=1 "$@"; $T send-keys -t "sala-test-$n" 'claude' Enter; }
mval() { local f="$OPS/$1.op"; [ -f "$f" ] || f="$DONE/$1.op"; awk -F= -v k="$2" '$1==k {print substr($0, length(k)+2); exit}' "$f" 2>/dev/null; }   # <id> <key>
queued() { ls "$OPS"/*.op 2>/dev/null | wc -l; }
tick() { "$SALA" watch --ops >/dev/null 2>&1; }
lw() { "$SALA" watch --limit >/dev/null 2>&1; }   # the usage-limit watch and the dormant record's one post
wait_lock() { lock_wait "$SALA_RECYCLE_LOCK" 120; }
f() { lane_state_field "$1" "$2"; }
user_rec() { printf '{"type":"user","uuid":"%s","timestamp":"%s","message":{"role":"user","content":"a message"}}\n' "$(rid)" "$(iso "$2")" >> "$P/$1.jsonl"; }
cap_rec() {  # <uuid> <epoch> <regain epoch> [variant]: the sanitized monthly-cap record (tests/fixtures/limit-monthly.jsonl), its regain time rewritten;
             # a variant words and spaces the text differently (capitals, doubled spaces, a line break inside the phrases)
    local d; d=$(date -u -d "@$3" '+%Y-%m-%d at %H:%M'); local e=(-e "s/regain access on 2099-01-01 at 00:00 UTC/regain access on $d UTC/")
    [ -n "${4:-}" ] && e=(-e "s/monthly API usage threshold/Monthly  API  usage\\\\nthreshold/" -e "s/regain access on 2099-01-01 at 00:00 UTC/regain  access on\\\\n$d  UTC/")
    sed -e "s|@UUID@|$(rid)|" -e "s|@TS@|$(iso "$2")|" -e "s|@CWD@|$HOME/work|" -e "s|@SESSION@|$1|" "${e[@]}" "$ROOT/tests/fixtures/limit-monthly.jsonl" >> "$P/$1.jsonl"; }
told() { local n; n=$(grep -c "^$1 .*Your lane" "$FAKE_SOCK_LOG" 2>/dev/null); echo "${n:-0}"; }   # lifter pushes to a pane's messaging socket
pushed() { local n; n=$(grep -c "^$1 " "$FAKE_SOCK_LOG" 2>/dev/null); echo "${n:-0}"; }          # anything at all pushed to that pane
escs() { local n; n=$(grep -c "^esc $1 " "$FAKE_LOG" 2>/dev/null); echo "${n:-0}"; }             # the Escapes the fake got
NOW=$(date +%s); R=$(( NOW / 60 * 60 + 2 * 86400 ))   # the regain time: a whole minute, two days ahead
RISO=$(date -u -d "@$R" +%Y-%m-%dT%H:%M:%SZ)
UA=$(uuid 1); UB=$(uuid 2); UC=$(uuid 3); UK=$(uuid 4); UP=$(uuid 5)

echo "== setup: a (Team, idle), b (Team, mid-turn for ever), c (already on bedrock), k (Ultra); the Team lane is the one the cap hits"
mk a "$UA" -e CLAUDE_CONFIG_DIR="$TEAM"; mk b "$UB" -e CLAUDE_CONFIG_DIR="$TEAM"; mk c "$UC" -e CLAUDE_CODE_USE_BEDROCK=1; mk k "$UK"; mk p "$UP" -e CLAUDE_CONFIG_DIR="$TEAM"
fake_up sala-test-a sala-test-b sala-test-c sala-test-k sala-test-p || exit 1
lane_write sala-test-a subscription-2; lane_write sala-test-b subscription-2; lane_write sala-test-c bedrock; lane_write sala-test-k subscription-1; lane_write sala-test-p subscription-2
"$SALA" lane pin sala-test-p subscription-2 >/dev/null 2>&1   # p is pinned to the capped lane: a bulk move (the fallback) must leave it alone
[ "$(proc_lane "$(cpid a)")|$(proc_lane "$(cpid b)")|$(proc_lane "$(cpid c)")|$(proc_lane "$(cpid k)")" = "subscription-2|subscription-2|bedrock|subscription-1" ] \
    && ok "a and b run on subscription-2, c on bedrock, k on subscription-1" || bad "lanes: $(proc_lane "$(cpid a)") $(proc_lane "$(cpid b)") $(proc_lane "$(cpid c)") $(proc_lane "$(cpid k)")"
set_reg_status "$(cpid p)" busy; set_reg_status "$(cpid b)" busy   # b is in the retry loop: the registry says busy and nothing ends it but an Escape
[ -n "$(is_idle_reason "$(cpid b)")" ] && [ -z "$(is_idle_reason "$(cpid a)")" ] && ok "b reads as busy, a as idle (the idle-aware relaunch would skip b)" || bad "idle reasons: b '$(is_idle_reason "$(cpid b)")' a '$(is_idle_reason "$(cpid a)")'"
[ "$(lane_fallback_of subscription-2)" = bedrock ] && ok "the Team lane's fallback (the lane map) is bedrock" || bad "fallback: $(lane_fallback_of subscription-2)"

echo "== the event: a and b's last turns ended on the monthly-cap 429 (b's text worded and spaced differently); the move is queued but not yet run"
touch "$HOME/norun"
for u in $UA $UB $UC $UK $UP; do user_rec "$u" $((NOW-900)); done
cap_rec "$UA" $((NOW-600)) "$R"; cap_rec "$UP" $((NOW-595)) "$R"; cap_rec "$UB" $((NOW-590)) "$R" variant
lw
[ "$(f subscription-2 2)|$(f subscription-2 6)" = "dormant|signal" ] && ok "the watch marks the Team lane dormant, by signal (no SALA_LIMIT_CONFIRM wait)" || bad "record: $(slurp "$REC")"
[ "$(f subscription-2 7)" = "$RISO" ] && ok "dormant until the regain time the text names ($RISO, the seventh column), the variant's text included" || bad "until column '$(f subscription-2 7)', expected $RISO: $(slurp "$REC")"
[ "$(lane_dormant_until subscription-2)" = "$R" ] && lane_dormant_capped subscription-2 && ok "lane_dormant_until reads it back as an epoch; lane_dormant_capped is true while it is ahead" || bad "until epoch '$(lane_dormant_until subscription-2)' vs $R"
! lane_dormant subscription-1 && ! lane_dormant bedrock && ok "no other lane was touched" || bad "other lanes dormant: $(slurp "$REC")"
[ "$(queued)" = 1 ] && W1=$(ls "$OPS"/*.op | head -1) && W1=${W1##*/} && W1=${W1%.op} && [ "$(mval "$W1" from)" = sala-watch ] && grep -qx 'arg=fallback' "$OPS/$W1.op" && grep -qx 'arg=subscription-2' "$OPS/$W1.op" \
    && ok "ONE operation queued, from sala-watch: lane fallback subscription-2" || bad "queue: $(ls "$OPS"; cat "$OPS"/*.op 2>/dev/null)"
[ "$(lane_row sala-test-a)|$(lane_row sala-test-b)" = "subscription-2|subscription-2" ] && ok "queued only: nobody has moved yet" || bad "moved early"

echo "== while the move waits: more ticks post nothing, queue nothing more, and tell no pane on the dormant lane to handle its last message"
lw; lw; lw
[ "$(nposts '')" = 0 ] && ok "no post over four ticks (the move's own notice will be the one)" || bad "posts: $(nposts ''): $(<"$POSTS")"
[ "$(queued)" = 1 ] && ok "still ONE operation" || bad "queued: $(queued)"
[ "$(pushed "$UA")$(pushed "$UB")$(pushed "$UP")" = 000 ] && [ "$(told "$UA")$(told "$UB")" = 00 ] && ok "nothing pushed to a or b: the lifter does not poke the dormant lane's panes" || bad "pushed a $(pushed "$UA") b $(pushed "$UB"): $(grep -E "^($UA|$UB) " "$FAKE_SOCK_LOG" 2>/dev/null)"
# a success after the error on the dormant lane (a stray answer) still does not lift or poke a pane while the lane is held
user_rec "$UA" $((NOW-300)); printf '{"type":"assistant","uuid":"%s","timestamp":"%s","cwd":"%s","message":{"model":"claude-opus-5-5","role":"assistant","content":[{"type":"text","text":"done"}]},"sessionId":"%s"}\n' "$(rid)" "$(iso $((NOW-290)))" "$HOME/work" "$UA" >> "$P/$UA.jsonl"
lw; lw
[ "$(pushed "$UA")$(pushed "$UB")" = 00 ] && [ "$(nposts '')" = 0 ] && ok "a success record after the error: still no poke, no post" || bad "after a success: pushed a $(pushed "$UA") b $(pushed "$UB"), posts $(nposts '')"

out=$("$SALA" lane fallback subscription-2 --dry-run 2>&1)
has "$out" "skipped (pinned to subscription-2): sala-test-p" && ! has "$out" "sala-test-p: subscription-2 →" && has "$out" "sala-test-b: subscription-2 → bedrock" && ok "the plan lists the pinned session p as skipped and plans a and b" || bad "plan: $out"

echo "== the move, end to end through the queue"
rm -f "$HOME/norun"
sp=$(starts "$UP"); sa=$(starts "$UA"); sb=$(starts "$UB"); sc=$(starts "$UC"); sk=$(starts "$UK")
tick
waitfor "[ -f '$DONE/$W1.op' ]" 480 && ok "the operation ran and was archived" || bad "op: $(cat "$OPS/$W1.op" "$DONE/$W1.op" 2>/dev/null) / $(tail -12 "$HOME/.claude/salamander-op-$W1.log" 2>/dev/null)"
[ "$(mval "$W1" state)" = done ] && ok "state done" || bad "state $(mval "$W1" state): $(mval "$W1" result)"
wait_lock
[ "$(lane_row sala-test-a)|$(lane_row sala-test-b)|$(lane_row sala-test-c)|$(lane_row sala-test-k)" = "bedrock|bedrock|bedrock|subscription-1" ] \
    && ok "a and b recorded on the fallback lane (bedrock); c was there; k (Ultra) untouched" || bad "rows: $(lane_row sala-test-a) $(lane_row sala-test-b) $(lane_row sala-test-c) $(lane_row sala-test-k)"
waitfor "[ \"\$(proc_lane \"\$(cpid a)\")\" = bedrock ] && [ \"\$(proc_lane \"\$(cpid b)\")\" = bedrock ]" 240 && ok "a and b run on bedrock (proc_lane)" || bad "running lanes: a $(proc_lane "$(cpid a)") b $(proc_lane "$(cpid b)")"
[ "$(escs "$UB")" -ge 1 ] && [ "$(starts "$UB")" -gt "$sb" ] && ok "b, mid-turn, was moved: its turn cut by an Escape, then relaunched on bedrock" || bad "b: escapes $(escs "$UB"), starts $(starts "$UB")/$sb"
[ "$(escs "$UA")" = 0 ] && [ "$(starts "$UA")" -gt "$sa" ] && ok "a, idle, was relaunched with no Escape sent to it" || bad "a: escapes $(escs "$UA"), starts $(starts "$UA")/$sa"
[ "$(starts "$UC")" = "$sc" ] && [ "$(escs "$UC")" = 0 ] && ok "c, already on the fallback lane, was not relaunched or touched" || bad "c: starts $(starts "$UC")/$sc escapes $(escs "$UC")"
[ "$(lane_row sala-test-p)" = subscription-2 ] && [ "$(starts "$UP")" = "$sp" ] && [ "$(escs "$UP")" = 0 ] && [ -n "$(is_idle_reason "$(cpid p)")" ] && ok "p, pinned and mid-turn on the capped lane, was neither cut nor moved nor relaunched" || bad "p: row $(lane_row sala-test-p), starts $(starts "$UP")/$sp, escapes $(escs "$UP")"
grep -rqF "skipped (pinned to subscription-2): sala-test-p" "$HOME/.claude/salamander-op-$W1.log" 2>/dev/null && ok "the operation's log lists p as skipped (pinned)" || bad "op log: $(tail -12 "$HOME/.claude/salamander-op-$W1.log" 2>/dev/null)"
[ "$(starts "$UK")" = "$sk" ] && [ "$(escs "$UK")" = 0 ] && ok "k, on another lane, was not relaunched or touched" || bad "k: starts $(starts "$UK")/$sk"
[ "$(awk -F'\t' '$1=="sala-test-a" {print $2}' "$SALA_LANE_HOME" 2>/dev/null)" = subscription-2 ] && ok "the home record says a came from subscription-2 (the way back is the ordinary one)" || bad "home: $(cat "$SALA_LANE_HOME" 2>/dev/null)"

echo "== one post for the whole episode, naming the lane, the day access returns and the fallback; more ticks add none"
[ "$(nposts '')" = 1 ] && ok "exactly ONE post after the move" || bad "posts: $(nposts ''): $(<"$POSTS")"
p=$(post "sala op: lane fallback")
has "$p" "Team" && has "$p" "Bedrock" && has "$p" "monthly usage cap" && has "$p" "access returns" && has "$p" "$(TZ=Etc/UTC date -d "@$R" '+%a %b')" && ok "it names the Team lane, the monthly cap, the day access returns and the Bedrock lane" || bad "post: $p"
lw; lw; lw; tick; lw
[ "$(nposts '')" = 1 ] && ok "still ONE post over five more ticks (no repeated 'working again')" || bad "posts after more ticks: $(nposts ''): $(<"$POSTS")"
[ "$(queued)" = 0 ] && ok "no second operation" || bad "queued: $(ls "$OPS")"
[ "$(told "$UA")" -le 1 ] && [ "$(told "$UB")" -le 1 ] && ! grep -q 'working again' "$POSTS" && ok "no 'lane working again' post; a pane that moved is told at most ONCE, on the lane it moved to (a $(told "$UA"), b $(told "$UB"))" || bad "told a $(told "$UA") b $(told "$UB"); posts: $(<"$POSTS")"
lane_dormant subscription-2 && [ "$(lane_dormant_until subscription-2)" = "$R" ] && ok "the lane stays dormant until the regain time" || bad "record: $(slurp "$REC")"

echo "== the regain time passes: the lane is active again by itself, from the record alone, with no post of its own"
# p (pinned, so still on the lane) is ended first: with it gone, the only stop left in the state is over, and nothing lifts at the end
$T kill-session -t sala-test-p 2>/dev/null; lw
awk -F'\t' -v OFS='\t' -v u="$(date -u -d "@$((NOW-5))" +%Y-%m-%dT%H:%M:%SZ)" '$1=="subscription-2" {$7=u} {print}' "$REC" > "$REC.new" && mv -f "$REC.new" "$REC"
lw
! lane_dormant subscription-2 && ok "the Team lane is active again once the regain time has passed" || bad "still dormant: $(slurp "$REC")"
grep -q 'regain time of its monthly usage cap passed' "$WLOG" 2>/dev/null && ok "the watch log says why" || bad "watch log: $(tail -4 "$WLOG" 2>/dev/null)"
lw; lw
[ "$(nposts '')" = 1 ] && [ "$(queued)" = 0 ] && ok "no post, no operation from the lane coming back" || bad "posts $(nposts ''), queued $(queued): $(<"$POSTS")"

echo "== no fallback to move to: the episode's one post says when access returns and that moving is the operator's call"
R2=$(( NOW / 60 * 60 + 5 * 86400 ))
user_rec "$UK" $((NOW-100)); cap_rec "$UK" $((NOW-90)) "$R2"
SALA_LANE_FALLBACK_AUTO=off lw
[ "$(f subscription-1 2)|$(f subscription-1 6)|$(lane_dormant_until subscription-1)" = "dormant|signal|$R2" ] && [ "$(queued)" = 0 ] && ok "Ultra goes dormant until its regain time; with the automatic move off nothing is queued" || bad "Ultra: $(slurp "$REC") queued $(queued)"
[ "$(nposts '')" = 2 ] && p=$(post "Ultra") && has "$p" "Ultra" && has "$p" "access returns" && has "$p" "moving them is your call" && ok "ONE post: the lane, when access returns, and that moving them is the operator's call" || bad "posts $(nposts ''): $(<"$POSTS")"
SALA_LANE_FALLBACK_AUTO=off lw; SALA_LANE_FALLBACK_AUTO=off lw
[ "$(nposts '')" = 2 ] && [ "$(pushed "$UK")" = 0 ] && ok "more ticks: no second post, k not poked" || bad "posts $(nposts ''), pushed to k $(pushed "$UK")"

[ "${fail:-0}" = 0 ] && echo "monthlycap: pass" || { echo "monthlycap: FAIL"; exit 1; }
