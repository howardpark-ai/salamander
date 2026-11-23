#!/usr/bin/env bash
# `sala rename OLD NEW` of a SLEEPING session whose tmux session is gone (lib/rename.sh, lib/op.sh op_verify; lib/common.sh THE SLEEPING SESSIONS). A host move leaves the
# sleepers in the pane map, each with its sleeping marker and no tmux session; a rename used to stop at "no tmux session 'OLD'" (the plan, `sala op --plan rename`, with it).
# Wake recreates the session at its shell; a rename must not: it renames the records that carry the name and leaves the session asleep and its tmux session absent. What is
# checked, on a private tmux server (no claude runs anywhere in this suite: a sleeper has none, and the refusals need none):
#  - the plan: `rename OLD NEW --dry-run` and `sala op --plan rename OLD NEW` of a sleeper with no tmux session pass, say that no tmux session is made and nothing is typed, and
#    change nothing (the row, the marker, the tmux sessions);
#  - the refusals that stay: a session that is NOT sleeping with no tmux session ("no tmux session"), a name that is no row at all, a NEW that is already a pane-map row of
#    another sleeper, a NEW that is a live tmux session, a name that does not fit; each leaves every record as it was;
#  - the run (the queue's runner stands in, tests/lib.sh as_op_unit): the pane-map row is rewritten under NEW with the same conversation id and directory, the old name no
#    longer resolves (the row, is_sleeping, the conversation lookup) and the new one resolves to the same id; the marker (keyed by the conversation id, so the file stays) carries
#    NEW in its name text and keeps its time; the lane row, the model row and an open note follow; the rename record (renames.jsonl) names both; the sleeper is still asleep and NO
#    tmux session was made under either name; the other sleeper's records are untouched;
#  - a sleeper that still has its tmux session is renamed as before, the tmux session with it (the session stays a shell: nothing is woken);
#  - the queue: `sala op rename OLD NEW --words …` queues one marker, the runner (op --run) renames the sleeper, op_verify accepts a session with no tmux session only for a
#    sleeper (the operation ends done, archived, the post says "renamed"), and the same operation for a non-sleeping row with no tmux session ends stuck, nothing renamed.
# SAFETY: the tmux server is a private socket (tmux -L sala-renamesleeper-<pid> -f /dev/null, SALA_TMUX_SOCKET pointing at it); HOME is a mktemp -d held with flock; there is no kill
# in this suite but the private server's own kill-server; no real pane, server, ~/.claude or claude process is read or touched. Posts go to a file.
# Usage: bash tests/renamesleeper.sh   (exit 0 = pass)
set -u
unset TMUX TMUX_PANE XDG_STATE_HOME SALA_MASTER SALA_SET SALA_SET_SELF SALA_RECYCLE SALA_RETRY_WORKER SALA_LOCK_WHO SALA_LOCK_WAIT SALA_RELAUNCH_KIND SALA_SLEEP_DIR \
      SALA_FLEET_HOSTS SALA_CGROUP_FILE SALA_OP_QUEUE SALA_NO_RELAUNCH SALA_BOOT_ID SALA_CONFIG SALA_BARE_REVIVE SALA_IDLE_WRAPUP SALA_SESSION_ID SALA_STACKSHOT_INBOX \
      SALA_STACKSHOT_DIR SALA_STACKSHOT_CLIENT SALA_AGENT_CHECK_SCRIPT SALA_PROJECT_RECORD SALA_ROLES_FILE SALA_OP_ID SALA_OP_FROM SALA_OP_PLAN SALA_OP_REASON_FROM
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
SANDBOX=""; SOCK="sala-renamesleeper-$$"; T="tmux -L $SOCK -f /dev/null"
cleanup() {
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    [ -z "$SANDBOX" ] || { exec 8<&-; rm -rf "$SANDBOX" 2>/dev/null; }
    true
}; trap cleanup EXIT   # set before the temp folder exists
SANDBOX=$(mktemp -d); export HOME=$SANDBOX SALA_TZ=Etc/UTC SALA_CONFIG=/dev/null
case "$HOME" in /tmp/*|"${TMPDIR:-/tmp}"/*) ;; *) echo "renamesleeper: HOME is not a temporary directory ($HOME) - refusing to run"; exit 1;; esac
exec 8< "$SANDBOX"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
as_op_unit   # the guarded verbs this suite runs itself stand for the queue's runner (tests/lib.sh, 5)
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOME/.claude-team" "$HOME/work"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
printf '{"fake":true}\n' > "$HOME/.claude-team/.credentials.json"   # the team lane is signed in, so a lane record for it is accepted
printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/systemd-run"
cat > "$HOME/.local/bin/systemctl" <<'EOF'
#!/bin/bash
case "$*" in *is-active*) exit 3 ;; *is-system-running*) echo running; exit 0 ;; *cat*tmux.service*) exit 1 ;; *) exit 0 ;; esac
EOF
chmod +x "$HOME/.local/bin/systemd-run" "$HOME/.local/bin/systemctl"
export PATH="$HOME/.local/bin:$PATH"
POSTS="$HOME/posts.txt"; : > "$POSTS"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off SALA_SNAPSHOT_CMD="touch $HOME/snap.done"
export SALA_LIMIT_ALERT=off SALA_LIMIT_RESUME=off SALA_STUCK_POST=off   # the other watches: not under test
export SALA_OP_STUCK=off SALA_OP_QUEUE=off SALA_BARE_REVIVE=off   # a queued marker is written and nothing starts it
SALA="$ROOT/bin/salamander"
export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's
case "$SOCK" in sala-renamesleeper-*) ;; *) echo "renamesleeper: not a private socket - refusing to run"; exit 1;; esac
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux    # literal socket: the children run set -u
$T new-session -d -s sala-test-keep -x 200 -y 50 -c "$HOME"; $T set -g exit-empty off   # a server that outlives its last session
. "$ROOT/lib/common.sh"
MAP="$SALA_SIDECAR"; OPS="$SALA_STATE_DIR/ops"; DONE="$OPS/done"
export SALA_SLEEP_DIR   # the children read the same directory (its default under SALA_STATE_DIR)
row() { awk -F'\t' -v s="$1" '$1==s' "$MAP" 2>/dev/null; }
run() { OUT=$("$SALA" "$@" 2>&1); RC=$?; }   # → OUT, RC (stderr in OUT)
mval() { awk -F= -v k="$2" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$1" 2>/dev/null; }   # <marker file> <key> → its first value
opfiles() { ls "$OPS"/*.op 2>/dev/null; }
tmuxnames() { $T list-sessions -F '#{session_name}' 2>/dev/null | sort | paste -sd, -; }
hastmux() { $T has-session -t "=$1" 2>/dev/null; }
snap() { { cat "$MAP"; ls -A "$SALA_SLEEP_DIR" 2>/dev/null; cat "$SALA_SLEEP_DIR"/* 2>/dev/null; tmuxnames; } | cksum; }   # the records a refused or planned rename must leave as they were

UA=$(uuid 1); UB=$(uuid 2); UG=$(uuid 3); UD=$(uuid 4)
NOTES="$SALA_LOG_DIR/salamander-notes.tsv"

echo "== setup: sleepers alpha and beta (map row and marker, no tmux session), gamma (a row, not sleeping, no tmux session), delta (a sleeper that kept its shell)"
mkdir -p "$SALA_SLEEP_DIR" "$SALA_LOG_DIR"
ledger_write add sala-test-alpha "$UA" sala-test-alpha "$HOME/work" || bad "map row alpha"
ledger_write add sala-test-beta  "$UB" sala-test-beta  "$HOME/work" || bad "map row beta"
ledger_write add sala-test-gamma "$UG" sala-test-gamma "$HOME/work" || bad "map row gamma"
ledger_write add sala-test-delta "$UD" sala-test-delta "$HOME/work" || bad "map row delta"
$T new-session -d -s sala-test-delta -c "$HOME"   # a shell, no claude: a sleeper that still has its tmux session
sleeping_mark "$UA" sala-test-alpha; sleeping_mark "$UB" sala-test-beta; sleeping_mark "$UD" sala-test-delta
run lane team sala-test-alpha;  [ "$RC" = 0 ] && [ "$(lane_row sala-test-alpha)" = subscription-2 ] || bad "lane row alpha: rc=$RC $OUT"
run model sala-test-alpha sonnet --effort medium; [ "$RC" = 0 ] && [ -n "$(model_row sala-test-alpha)" ] || bad "model row alpha: rc=$RC $OUT"
printf 'n1\tsala-test-alpha\t%s\tan open note\n' "$UA" > "$NOTES"
cp "$MAP" "$HOME/map.before"; ALPHA_ROW=$(row sala-test-alpha); ALPHA_MARK=$(<"$SALA_SLEEP_DIR/$UA"); TM0=$(tmuxnames)
is_sleeping sala-test-alpha && is_sleeping sala-test-beta && ! is_sleeping sala-test-gamma && ! hastmux sala-test-alpha && ! hastmux sala-test-gamma && hastmux sala-test-delta \
    && ok "alpha and beta sleep with no tmux session, gamma does not sleep, delta sleeps in its shell" || bad "the setup: tmux=$TM0"

echo "== the plan: a sleeper with no tmux session passes, says so, and changes nothing"
s0=$(snap)
run rename sala-test-alpha sala-test-alpha-main --dry-run
[ "$RC" = 0 ] && has "$OUT" "tmux session is gone" && has "$OUT" "no tmux session is made" && has "$OUT" "nothing is typed" && ! has "$OUT" "no tmux session 'sala-test-alpha'" && ok "rename --dry-run: passes, no tmux session is made, nothing typed" || bad "dry run: rc=$RC — $OUT"
run op --plan rename sala-test-alpha sala-test-alpha-main
[ "$RC" = 0 ] && has "$OUT" "plan: salamander rename sala-test-alpha sala-test-alpha-main" && has "$OUT" "no tmux session is made" && has "$OUT" "plan only: nothing queued" && ok "sala op --plan rename: the same plan, nothing queued" || bad "op plan: rc=$RC — $OUT"
[ -z "$(opfiles)" ] && [ "$(snap)" = "$s0" ] && ok "the plans changed no row, no marker and no tmux session" || bad "a plan changed something: $(snap) vs $s0"

echo "== the refusals that stay"
s0=$(snap)
run op --plan rename sala-test-gamma sala-test-gamma-main
[ "$RC" != 0 ] && has "$OUT" "no tmux session 'sala-test-gamma'" && ok "a session that is not sleeping, with no tmux session: still refused" || bad "gamma plan: rc=$RC — $OUT"
run rename sala-test-gamma sala-test-gamma-main
[ "$RC" != 0 ] && has "$OUT" "no tmux session 'sala-test-gamma'" && ok "and the real run refuses it too" || bad "gamma run: rc=$RC — $OUT"
run rename sala-test-nobody sala-test-nobody-main
[ "$RC" != 0 ] && has "$OUT" "no tmux session 'sala-test-nobody'" && ok "a name that is no row and no session: still refused" || bad "nobody: rc=$RC — $OUT"
run rename sala-test-alpha sala-test-beta
[ "$RC" != 0 ] && has "$OUT" "'sala-test-beta' is already in the pane map" && ok "a NEW that is another sleeper's row: refused" || bad "alpha to beta: rc=$RC — $OUT"
run rename sala-test-alpha sala-test-delta
[ "$RC" != 0 ] && has "$OUT" "a tmux session 'sala-test-delta' already exists" && ok "a NEW that is a live tmux session: refused" || bad "alpha to delta: rc=$RC — $OUT"
run rename sala-test-alpha "bad name"
[ "$RC" != 0 ] && has "$OUT" "invalid name" && ok "a name that does not fit: refused" || bad "bad name: rc=$RC — $OUT"
[ "$(snap)" = "$s0" ] && [ "$(row sala-test-alpha)" = "$ALPHA_ROW" ] && ok "every refusal left the rows, the markers and the tmux sessions as they were" || bad "a refusal changed something"

echo "== the run: the records follow the name, nothing is woken, no tmux session is made"
run rename sala-test-alpha sala-test-alpha-main
[ "$RC" = 0 ] && has "$OUT" "✅ 'sala-test-alpha' is now 'sala-test-alpha-main'" && ! has "$OUT" "⚠" && ok "rename of the sleeper: done, no warning" || bad "rename alpha: rc=$RC — $OUT"
[ "$(tmuxnames)" = "$TM0" ] && ! hastmux sala-test-alpha && ! hastmux sala-test-alpha-main && ok "no tmux session was made under either name (the sessions are as before)" || bad "tmux sessions: $(tmuxnames) vs $TM0"
[ -z "$(row sala-test-alpha)" ] && [ "$(sidecar_uuid_for_session sala-test-alpha-main)" = "$UA" ] && [ "$(row sala-test-alpha-main | cut -f2,4)" = "$(printf '%s\t%s' "$UA" "$HOME/work")" ] && ok "the map row moved to the new name with the same conversation id and directory" || bad "rows: $(cat "$MAP")"
[ -z "$(sidecar_uuid_for_session sala-test-alpha)" ] && ! is_sleeping sala-test-alpha && ok "the old name no longer resolves (no id, not asleep)" || bad "old name still resolves: $(sidecar_uuid_for_session sala-test-alpha)"
is_sleeping sala-test-alpha-main && [ "$(ls "$SALA_SLEEP_DIR" | grep -c .)" = 3 ] && ls "$SALA_SLEEP_DIR/$UA" >/dev/null && ok "the new name resolves to the sleeping marker of the same conversation (the file is the same: keyed by the id)" || bad "marker dir: $(ls -A "$SALA_SLEEP_DIR")"
[[ $(<"$SALA_SLEEP_DIR/$UA") =~ ^${ALPHA_MARK%% *}\ sala-test-alpha-main$ ]] && ok "the marker's name text is the new name and its time is kept" || bad "marker: $(<"$SALA_SLEEP_DIR/$UA") (was $ALPHA_MARK)"
[ "$(lane_row sala-test-alpha-main)" = subscription-2 ] && [ -z "$(lane_row sala-test-alpha)" ] && has "$(model_row sala-test-alpha-main)" sonnet && [ -z "$(model_row sala-test-alpha)" ] && ok "the lane row and the model row followed" || bad "lane=$(lane_row sala-test-alpha-main) model=$(model_row sala-test-alpha-main)"
[ "$(cut -f2 "$NOTES")" = sala-test-alpha-main ] && ok "the open note is labelled with the new name" || bad "notes: $(<"$NOTES")"
grep -q "\"uuid\": *\"$UA\".*\"from\": *\"sala-test-alpha\".*\"to\": *\"sala-test-alpha-main\"" "$SALA_LOG_DIR/salamander-renames.jsonl" 2>/dev/null && ok "the rename record names both names and the conversation" || bad "renames.jsonl: $(cat "$SALA_LOG_DIR/salamander-renames.jsonl" 2>/dev/null)"
[ "$(row sala-test-beta | cut -f2)" = "$UB" ] && [ "$(<"$SALA_SLEEP_DIR/$UB")" != "" ] && is_sleeping sala-test-beta && ok "the other sleeper's row and marker are untouched" || bad "beta: $(row sala-test-beta)"
run rename sala-test-alpha-main sala-test-alpha
[ "$RC" = 0 ] && is_sleeping sala-test-alpha && ! hastmux sala-test-alpha && ok "renamed back: the same, no tmux session" || bad "rename back: rc=$RC — $OUT"

echo "== a sleeper that kept its tmux session is renamed as before, and stays a shell"
run rename sala-test-delta sala-test-delta-main
[ "$RC" = 0 ] && hastmux sala-test-delta-main && ! hastmux sala-test-delta && is_sleeping sala-test-delta-main && [ "$(sidecar_uuid_for_session sala-test-delta-main)" = "$UD" ] && ok "delta: the tmux session, the map row and the marker follow" || bad "delta: rc=$RC — $OUT"

echo "== the queue: the runner renames a sleeper with no tmux session, and the verify step knows it"
run op rename sala-test-beta sala-test-beta-main --words "rename beta" --from sala-test-keep
M=$(opfiles | head -1)
if [ "$RC" = 0 ] && [ -n "$M" ]; then
    ok "op rename beta beta-main: queued ($(printf '%s' "$OUT" | grep -m1 '^queued' | cut -c1-90))"
    OPID=$(basename "$M" .op)
    SALA_OP_STUCK=off "$SALA" op --run "$OPID" >/dev/null 2>&1
    is_sleeping sala-test-beta-main && [ -z "$(row sala-test-beta)" ] && ! hastmux sala-test-beta-main && ok "the runner renamed it: asleep under the new name, no tmux session" || bad "after the run: $(cat "$MAP")"
    [ -f "$DONE/$OPID.op" ] && [ "$(mval "$DONE/$OPID.op" state)" = done ] && ok "the operation ended done and was archived (the verify step took a sleeper with no tmux session)" || bad "after the run: $(cat "$M" "$DONE/$OPID.op" 2>/dev/null | tr '\n' ' ')"
    grep -q "renamed sala-test-beta to sala-test-beta-main" "$POSTS" 2>/dev/null && ok "the post says it renamed beta" || bad "post: $(tail -4 "$POSTS" | tr '\n' ' ')"
else bad "op rename beta: rc=$RC — $OUT"; fi
# the verify step on its own: it takes a session with no tmux session only when it sleeps
. "$ROOT/lib/op.sh" 2>/dev/null || true
if declare -F op_verify >/dev/null; then
    mkdir -p "$OPS"; printf 'id=v1\nverb=rename\narg=sala-test-gamma-old\narg=sala-test-gamma\nstate=running\n' > "$OPS/v1.op"
    ! op_verify v1 && has "$OP_VERIFY_WHY" "no tmux session 'sala-test-gamma'" && ok "op_verify: a NEW that is no sleeper and no tmux session fails" || bad "op_verify gamma: why=$OP_VERIFY_WHY"
    printf 'id=v2\nverb=rename\narg=sala-test-alpha-old\narg=sala-test-alpha\nstate=running\n' > "$OPS/v2.op"
    op_verify v2 && ok "op_verify: a sleeper with a map row and no tmux session passes" || bad "op_verify alpha: why=$OP_VERIFY_WHY"
    printf 'id=v3\nverb=rename\narg=sala-test-alpha\narg=sala-test-beta-main\nstate=running\n' > "$OPS/v3.op"
    ! op_verify v3 && has "$OP_VERIFY_WHY" "still holds a row for 'sala-test-alpha'" && ok "op_verify: a sleeper whose old name still has a row fails" || bad "op_verify v3: why=$OP_VERIFY_WHY"
    rm -f "$OPS"/v?.op
else bad "op_verify is not defined after sourcing lib/op.sh"; fi

[ "$fail" = 0 ] && echo "renamesleeper: pass" || echo "renamesleeper: FAIL"
exit $fail
