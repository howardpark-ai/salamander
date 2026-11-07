#!/usr/bin/env bash
# The operation queue (lib/op.sh): fleet operations run by `watch`
# with no model, one at a time under the recycle lock, each as its own sala-op-<id> unit; a one-off `claude -p` only when
# one is stuck. What is checked guards a session or the fleet from a wrong operation, never the wording of a post: a verb
# that does not fit its shape, an unresolvable or busy target, or a marker without the owner's words is refused before anything
# is queued (a queued operation runs unattended, so the plan is the last look); `--auto` under a Claude process is refused
# (a relayed message is never the owner's words); reboot is refused while its switch is off; a recycle about to start absorbs the
# queued recycles and this box's updates (two drivers would race the same panes) and their hearers are told; a runner gone
# without a result is settled, with the one claude -p run once and never again; the end-to-end recycle through the queue on
# sala-test-* panes: enqueued → the dry-run plan → the unit under the lock (holder op-<id>) → the sweep, a busy pane handed
# to the retry worker → `waiting` → relaunched → done, one post, one inbox line to the hearing session, the marker archived;
# a set that gave a pane up → stuck, the claude -p called on the subscription-1 lane (no key, no custom headers, no entrypoint, no
# config dir), default permissions, bounded turns and tools, with the operation, the log tails and what was tried in its
# brief; its `done` checked against the fleet (a retire whose session still lives is not done; one that really ended it is);
# two queued operations naming one session → stuck, neither run; the guards admitting a sala-op-<id> unit by its cgroup and
# nothing else; the waiter's deadline. The rename verb's plan for the asker's own pane (run without TMUX_PANE, as the unit does): the runner's
# "type /rename NEW (pane now: …)" line and the note that nothing is left to type, never the direct run's "type it here yourself". The model verb for several sessions: one operation, one marker, one sweep, one Slack post and one inbox line that count the
# sessions through and name only the failed or skipped ones with their reason (a single session is named as before); the old single-session shape unchanged; one unknown session refuses the lot; a failed session ends it stuck, named, with no claude -p. The end of every operation is reported to stackshot once (client.py event --kind fleet_op: verb, machine, sessions, result ok / partial / failed) through tests/fake-stackshot-client.py, a client that fails, hangs past the timeout or is missing changing nothing about the op. systemd-run and systemctl are stubs (the unit runs detached, in the queue's cgroup as
# the real unit does — the stub exports SALA_CGROUP_FILE naming a sala-op-<id> unit, since with no master the guards refuse a
# Claude caller; `is-active` answers from a file), the claude -p is a stub (SALA_OP_CLAUDE: no suite ever calls
# the API), Slack is a file. Isolated HOME, a private tmux socket, the compiled fake claude; no real session, pane or unit
# is touched. The master's own retire through the queue and the guards with no master are tests/nomaster.sh's.
# Usage: bash tests/op.sh   (exit 0 = pass; ~90 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_MASTER SALA_SET SALA_SET_SELF SALA_RECYCLE SALA_RETRY_WORKER SALA_LOCK_WHO SALA_LOCK_WAIT SALA_RELAUNCH_KIND \
      SALA_FLEET_HOSTS SALA_CGROUP_FILE SALA_OP_QUEUE SALA_OP_REBOOT SALA_OP_STUCK SALA_REBOOT_HOOKS SALA_NO_RELAUNCH
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, fake_up, tmux_socket_rm; the lane variables unset
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOME/anc"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"   # as the CLI installs it: the launcher target's name is the version
LAUNCHES="$HOME/systemd-run.txt"; KICKS="$HOME/systemctl.txt"
cat > "$HOME/.local/bin/systemd-run" <<'EOF'
#!/bin/bash
# the stub unit: records the line; a sala-op-<id> launch runs its command detached (as the unit would), unless $HOME/norun
# exists (a runner that dies at once); the stuck handler's unit (sala-op-<id>-stuck) always runs
echo "$*" >> "$HOME/systemd-run.txt"
case " $* " in *" --on-active="*) exit 0;; esac
case "$*" in *--unit=sala-op-*) ;; *) exit 0;; esac
case "$*" in *-stuck\ *) ;; *) [ -e "$HOME/norun" ] && exit 0;; esac
# the unit runs in the queue's cgroup (a sala-op-<id> unit's line, which op_unit_caller reads): what the real unit has
cmd="${@: -1}"; SALA_CGROUP_FILE="$HOME/op-unit.cgroup" setsid bash -c "$cmd" </dev/null >/dev/null 2>&1 &
exit 0
EOF
echo "0::/user.slice/user-$EUID.slice/user@$EUID.service/app.slice/sala-op-1760000000-1.service" > "$HOME/op-unit.cgroup"
cat > "$HOME/.local/bin/systemctl" <<'EOF'
#!/bin/bash
echo "$*" >> "$HOME/systemctl.txt"
case "$*" in
    *is-active*sala-watch.service*) if [ -e "$HOME/active" ]; then echo active; exit 0; else echo inactive; exit 3; fi ;;
    *is-active*) exit 3 ;;
    *is-system-running*) echo running; exit 0 ;;
    *) exit 0 ;;
esac
EOF
cat > "$HOME/fake-helper" <<'EOF'
#!/bin/bash
# the stub claude -p: records how it was called (its arguments, the lane's env, the brief), acts when told to, says its verdict
echo "run $(date +%s)" >> "$HOME/helper-runs.txt"
printf '%s\n' "$@" > "$HOME/helper-args.txt"
echo "key=${ANTHROPIC_API_KEY:-unset} hdr=${ANTHROPIC_CUSTOM_HEADERS:-unset} entry=${CLAUDE_CODE_ENTRYPOINT:-unset} cfg=${CLAUDE_CONFIG_DIR:-unset} cwd=$PWD" > "$HOME/helper-env.txt"
while [ $# -gt 0 ]; do [ "$1" = -p ] && { printf '%s\n' "$2" > "$HOME/helper-brief.txt"; break; }; shift; done
[ -x "$HOME/helper-act.sh" ] && "$HOME/helper-act.sh"
echo "some thinking first"
cat "$HOME/helper-verdict.txt" 2>/dev/null || echo "SALA-OP: stuck the test helper does nothing"
EOF
chmod +x "$HOME/.local/bin/systemd-run" "$HOME/.local/bin/systemctl" "$HOME/fake-helper"
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"   # one post per record, '%%' between them
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off
export SALA_LIMIT_ALERT=off SALA_LIMIT_RESUME=off SALA_STUCK_POST=off   # the other watches: not under test
export SALA_OP_CLAUDE="$HOME/fake-helper" SALA_OP_POLL=1 SALA_OP_LOCK_WAIT=5 SALA_OP_SWEEP_WAIT=120 SALA_OP_SETTLE_WAIT=120 \
       SALA_OP_STUCK_TURNS=7 SALA_OP_STUCK_TIME=30 SALA_OP_HELPER_CWD="$HOME" SALA_RETRY_EVERY=2 SALA_RETRY_WINDOW=120
SALA="$ROOT/bin/salamander"; SOCK="sala-op-$$"; T="tmux -L $SOCK -f /dev/null"; RLOG="$HOME/.claude/salamander-revive.log"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's
cleanup() {
    local f p; for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done
    for p in $(pgrep -f "salamander op --settle" 2>/dev/null); do grep -qz "HOME=$HOME" "/proc/$p/environ" 2>/dev/null && kill "$p" 2>/dev/null; done
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    for p in $(pgrep -x claude); do [ "$HOME/.local/share/claude/versions/9.9.9" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux    # literal socket: the children run set -u
. "$ROOT/lib/common.sh"
OPS="$SALA_STATE_DIR/ops"; DONE="$OPS/done"; SOCKLOG="$HOME/sock.log"
mk() { local n="$1" u="$2"; shift 2; $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="sala-test-$n" -e FAKE_LOG="$FAKE_LOG" "$@"; $T send-keys -t "sala-test-$n" 'claude' Enter; }
pane() { tmux display -p -t "sala-test-$1" '#{pane_id}'; }
regstatus() {  # <tmux session> <status>: what the registry says about that pane's claude
    local c; c=$(claude_pid_under "$(tmux display -p -t "$1" '#{pane_pid}')"); set_reg_status "$c" "$2"; }
mval() { local f="$OPS/$1.op"; [ -f "$f" ] || f="$DONE/$1.op"; awk -F= -v k="$2" '$1==k {print substr($0, length(k)+2); exit}' "$f" 2>/dev/null; }   # <id> <key>
mvals() { local f="$OPS/$1.op"; [ -f "$f" ] || f="$DONE/$1.op"; awk -F= -v k="$2" '$1==k {print substr($0, length(k)+2)}' "$f" 2>/dev/null; }
queued() { ls "$OPS"/*.op 2>/dev/null | wc -l; }
tick() { "$SALA" watch --ops >/dev/null 2>&1; }
workers() { local f n=0; for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill -0 "$(<"$f")" 2>/dev/null && n=$((n+1)); done; echo $n; }
runs() { grep -c '^run' "$HOME/helper-runs.txt" 2>/dev/null || echo 0; }
wait_lock() { lock_wait "$SALA_RECYCLE_LOCK" 120; }

echo "== setup: four panes on the fake claude — the hearing session h (its inbox logged), a, b and d"
mk h "$(uuid 1)" -e FAKE_SOCK_LOG="$SOCKLOG"; mk a "$(uuid 2)"; mk b "$(uuid 3)"; mk d "$(uuid 4)"
fake_up sala-test-h sala-test-a sala-test-b sala-test-d || exit 1

echo "== the shape table: a verb or an argument it does not know is refused, nothing queued"
for args in "frob --from t --words x" "recycle --bogus --from t --words x" "rename only-one --from t --words x" "retire --from t --words x" \
            "lane nolane sala-test-a --from t --words x" "lane default --from t --words x" "update nohost --from t --words x" "update --fleet solo-x --from t --words x" \
            "provision --only 'bad step' --from t --words x" "reboot --go --from t --words x" "revive --only --from t --words x" "retire 'a b' --from t --words x" \
            "model --from t --words x" "model sala-test-a --from t --words x" "model sala-test-a gpt5 --from t --words x" "model sala-test-a 'claude-opus[1m]' --from t --words x" \
            "model sala-test-a opus --effort ultra --from t --words x" "model sala-test-a opus --effort --from t --words x" "model sala-test-a opus --effort low --effort high --from t --words x" \
            "model sala-test-a opus --record-only --from t --words x" "model sala-test-a opus --dry-run --from t --words x" "model sala-test-a opus --not-master --from t --words x" \
            "model sala-test-a --clear opus --from t --words x" "model sala-test-a --effort high --from t --words x" "model 'a b' opus --from t --words x"; do
    eval "enq $args"; [ "$RC" = 2 ] && has "$OUT" "✗" && ok "refused (exit 2): op $args" || bad "op $args: rc=$RC — $OUT"
done
[ "$(queued)" = 0 ] && ok "nothing queued by any of them" || bad "markers: $(ls "$OPS")"

echo "== the words: none → refused; blank → refused; --auto from a shell → queued; --auto under a claude process → refused"
enq retire sala-test-d --from t; [ "$RC" != 0 ] && has "$OUT" "no --words" && ok "no --words: refused" || bad "no words: rc=$RC — $OUT"
enq retire sala-test-d --from t --words "   "; [ "$RC" != 0 ] && has "$OUT" "no --words" && ok "blank words: refused" || bad "blank: rc=$RC — $OUT"
touch "$HOME/norun"
# from a shell with no claude above it: an orphan (double fork, reparented to init or the nearest subreaper); the orphan records
# its own ancestry first, since a suite run from a Claude session's pane may still sit under a claude, where the refusal is right
( ( sleep 0.5; p=$BASHPID; anc=""; while [ "$p" -gt 1 ] 2>/dev/null; do anc="$anc $(cat /proc/$p/comm 2>/dev/null)"; p=$(awk '{print $4}' /proc/$p/stat 2>/dev/null); done; echo "$anc" > "$HOME/auto.anc"
    "$SALA" op retire sala-test-d --from t --auto > "$HOME/auto.out" 2>&1; echo "rc=$?" >> "$HOME/auto.out" ) & )
waitfor "grep -q '^rc=' '$HOME/auto.out' 2>/dev/null" 40 || bad "the orphaned --auto call did not end: $(slurp "$HOME/auto.out")"
AOUT=$(<"$HOME/auto.out"); AID=$(sed -n 's/^queued op \([0-9-]*\):.*/\1/p' <<< "$AOUT" | head -1)
if grep -qw claude "$HOME/auto.anc"; then
    has "$AOUT" "--auto is for markers sala writes itself" && [ "$(queued)" = 0 ] && ok "--auto (this shell's orphans still sit under a claude process: $(<"$HOME/auto.anc")): refused" || bad "--auto under claude: $AOUT"
else
    [ -n "$AID" ] && grep -q '^rc=0$' <<< "$AOUT" && [ "$(mval "$AID" auto)" = 1 ] && [ -z "$(mval "$AID" words)" ] && ok "--auto from a shell: queued with no words (auto=1)" || bad "--auto: $AOUT"
    [ -n "$AID" ] && "$SALA" op --cancel "$AID" >/dev/null 2>&1
fi
# a script named claude (comm = claude, as tests/guard.sh does it) running the call as its child — never exec, which would
# replace the process named claude with the call itself and leave no claude above it (CI, Wed Oct 14th 2026: the call was
# queued on the runner, which has no claude anywhere; on the coordinator machine the suite's own session's claude had hidden the mistake)
printf '#!/bin/bash\n"%s" op retire sala-test-d --from t --auto\n' "$SALA" > "$HOME/anc/claude"; chmod +x "$HOME/anc/claude"
out=$("$HOME/anc/claude" 2>&1); rc=$?
[ "$rc" != 0 ] && has "$out" "--auto is for markers sala writes itself" && [ "$(queued)" = 0 ] && ok "--auto under a claude process: refused, nothing queued" || bad "auto under claude: rc=$rc — $out"

echo "== reboot: not queued while SALA_OP_REBOOT is off (the default; on is unsupported until a confirmation path is built, and still works)"
enq reboot --from t --words "reboot t-host-a"; [ "$RC" != 0 ] && has "$OUT" "reboot is not queued: Rowan runs \`sala reboot --go\` in the web UI's Shell; a session shows \`sala reboot --status\` and waits for the word" && [ "$(queued)" = 0 ] && ok "off: refused as not queued (Rowan runs it), nothing queued" || bad "reboot off: rc=$RC — $OUT"
SALA_OP_REBOOT=on enq reboot --from t --words "reboot t-host-a"
[ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(mval "$ID" verb)" = reboot ] && [ "$(mval "$ID" state)" = queued ] && has "$OUT" "no SALA_REBOOT_HOOKS configured" && ok "on: queued, the plan was reboot --status" || bad "reboot on: rc=$RC — $OUT"
"$SALA" op --cancel "$ID" >/dev/null 2>&1; [ "$(mval "$ID" state)" = cancelled ] && [ -f "$DONE/$ID.op" ] && ok "cancelled: archived as cancelled" || bad "cancel: $(slurp "$DONE/$ID.op")"

echo "== the plan: the verb's dry run runs first, and its refusal refuses the operation before anything is queued"
enq retire sala-test-nope --from t --words "retire nope"; [ "$RC" != 0 ] && has "$OUT" "nothing queued" && [ "$(queued)" = 0 ] && ok "retire of no such session: refused" || bad "no such session: rc=$RC — $OUT"
regstatus sala-test-d busy
enq retire sala-test-d --from t --words "retire d"; [ "$RC" != 0 ] && has "$OUT" "would refuse" && has "$OUT" "nothing queued" && [ "$(queued)" = 0 ] && ok "retire of a busy pane: the dry run's refusal refuses it" || bad "busy: rc=$RC — $OUT"
regstatus sala-test-d idle
enq revive --only sala-test-nope --force --from t --words "revive nope"; [ "$RC" != 0 ] && has "$OUT" "nothing queued" && [ "$(queued)" = 0 ] && ok "revive --only of no such session: refused" || bad "revive nope: rc=$RC — $OUT"
enq --plan retire sala-test-d; [ "$RC" = 0 ] && has "$OUT" "plan: salamander retire sala-test-d" && has "$OUT" "[dry-run] would" && has "$OUT" "plan only: nothing queued" && [ "$(queued)" = 0 ] && ok "--plan: the dry run shown, nothing queued, no words needed" || bad "--plan: rc=$RC — $OUT"
enq --plan recycle --update; [ "$RC" = 0 ] && has "$OUT" "would update the CLI first" && has "$OUT" "phase 1 (check)" && ok "--plan recycle --update: the CLI note and the sweep's verdicts, no claude update run" || bad "--plan recycle: rc=$RC — $OUT"

echo "== enqueue: the marker's fields, the kick, --list, --status, --cancel; the words folded; --stdin; the kick after a tick already running"
: > "$KICKS"
enq retire sala-test-d --from sala-test-h --words "retire d please"
[ "$RC" = 0 ] && [ -n "$ID" ] && ok "queued op $ID" || { bad "enqueue: rc=$RC — $OUT"; exit 1; }
[ "$(mval "$ID" verb)" = retire ] && [ "$(mvals "$ID" arg)" = sala-test-d ] && [ "$(mval "$ID" from)" = sala-test-h ] && [ "$(mval "$ID" words)" = "retire d please" ] \
    && [ "$(mval "$ID" state)" = queued ] && [ -n "$(mval "$ID" time)" ] && [ "$(mval "$ID" id)" = "$ID" ] && ok "the marker: id, time, from, words verbatim, verb and arg as fields, state queued" || bad "marker: $(<"$OPS/$ID.op")"
grep -q -- '--user start --no-block sala-watch.service' "$KICKS" && has "$OUT" "sala-watch.service started" && ok "the kick: sala-watch.service started at once" || bad "kick: $(<"$KICKS"); $OUT"
"$SALA" op --list | grep -q "^$ID	queued	retire sala-test-d	sala-test-h	" && ok "--list shows it" || bad "list: $("$SALA" op --list)"
"$SALA" op --status "$ID" | grep -q '^words: retire d please' && ok "--status prints its record" || bad "status: $("$SALA" op --status "$ID")"
enq retire sala-test-d --from sala-test-h --words $'  first line\nsecond\tline  '; [ "$RC" = 0 ] && [ "$(mval "$ID" words)" = "first line second line" ] && ok "words folded to one line" || bad "fold: '$(mval "$ID" words)'"
"$SALA" op --cancel "$ID" >/dev/null
ID2=$(printf 'from stdin\n' | "$SALA" op retire sala-test-d --from x --stdin 2>/dev/null | sed -n 's/^queued op \([0-9-]*\):.*/\1/p'); [ -n "$ID2" ] && [ "$(mval "$ID2" words)" = "from stdin" ] && ok "--stdin: the words from stdin" || bad "stdin: $ID2 '$(mval "$ID2" words)'"
"$SALA" op --cancel "$ID2" >/dev/null
touch "$HOME/active"; : > "$LAUNCHES"
enq retire sala-test-d --from sala-test-h --words "again"; [ "$RC" = 0 ] && has "$OUT" "a watch tick is running now" && grep -q -- "--on-active=10 --unit=sala-op-kick-$ID .* watch --ops" "$LAUNCHES" && ok "a tick already running: a one-off watch --ops scheduled 10 s on" || bad "active kick: $OUT / $(<"$LAUNCHES")"
rm -f "$HOME/active"; "$SALA" op --cancel "$ID" >/dev/null
enq revive --only sala-test-d --force --from t --words "revive d"; [ "$RC" != 0 ] && has "$OUT" "names the same session" && [ "$(queued)" = 1 ] && ok "another verb on a session already queued: refused" || bad "conflict at enqueue: rc=$RC — $OUT"
: > "$KICKS"; SALA_OP_QUEUE=off enq retire sala-test-a --from t --words "retire a"; [ "$RC" = 0 ] && has "$OUT" "SALA_OP_QUEUE is off" && ! grep -q start "$KICKS" && ok "SALA_OP_QUEUE=off: queued, not kicked" || bad "queue off: $OUT / $(<"$KICKS")"
"$SALA" op --cancel "$ID" >/dev/null
ID=$(ls "$OPS"/*.op | head -1 | xargs -n1 basename | sed 's/\.op$//'); "$SALA" op --cancel "$ID" >/dev/null; [ "$(queued)" = 0 ] && ok "the queue is empty again" || bad "left: $(ls "$OPS")"

echo "== the guards admit a caller inside a sala-op-<id> unit, by its cgroup, and nothing else"
PA=$(pane a); CG="$HOME/cgroup"
echo "0::/user.slice/user-1000.slice/user@1000.service/app.slice/sala-op-1760000000-1234.service" > "$CG"
( export SALA_MASTER=sala-test-h TMUX_PANE="$PA"; master_guard recycle --force ) >/dev/null 2>&1; [ $? != 0 ] && ok "another pane than the master's: master_guard refuses (as before)" || bad "master_guard let another pane through"
( export SALA_MASTER=sala-test-h TMUX_PANE="$PA" SALA_CGROUP_FILE="$CG"; master_guard recycle --force ) >/dev/null 2>&1 && ok "inside unit sala-op-<id>: master_guard admits it" || bad "master_guard refused the unit"
( export SALA_MASTER=sala-test-h TMUX_PANE="$PA" SALA_CGROUP_FILE="$CG"; ops_guard retire example-x ) >/dev/null 2>&1 && ok "inside unit sala-op-<id>: ops_guard admits it" || bad "ops_guard refused the unit"
echo "0::/user.slice/user-1000.slice/user@1000.service/app.slice/sala-auto-recycle-1760000000.service" > "$CG"
( export SALA_MASTER=sala-test-h TMUX_PANE="$PA" SALA_CGROUP_FILE="$CG"; master_guard recycle --force ) >/dev/null 2>&1; [ $? != 0 ] && ok "another unit's cgroup: refused" || bad "master_guard admitted a sala-auto-* unit"
echo "0::/user.slice/user-1000.slice/user@1000.service/app.slice/sala-op-kick-1760000000-1.service" > "$CG"
( export SALA_MASTER=sala-test-h TMUX_PANE="$PA" SALA_CGROUP_FILE="$CG"; master_guard recycle --force ) >/dev/null 2>&1; [ $? != 0 ] && ok "the kick unit's cgroup: refused" || bad "master_guard admitted the kick unit"

echo "== a recycle about to start absorbs the queued recycle and this box's update: one unit, the flags folded, the hearers told"
touch "$HOME/norun"; : > "$LAUNCHES"; : > "$POSTS"; rm -f "$HOME/helper-runs.txt"
enq recycle --from sala-test-h --words "recycle claude"; R1="$ID"; [ -n "$R1" ] || bad "recycle not queued: $OUT"
sleep 1; enq update --from sala-test-h --words "update claude"; U1="$ID"; [ -n "$U1" ] && has "$OUT" "claude update" && ok "update (this box) queued, its plan a note (no claude update run)" || bad "update: $OUT"
sleep 1; enq recycle --force --from x --words "force it"; R2="$ID"; [ -n "$R2" ] || bad "recycle --force not queued: $OUT"
"$SALA" watch >/dev/null 2>&1   # a plain tick (no master configured): the queue runs all the same
[ "$(grep -c -- "--unit=sala-op-$R1 " "$LAUNCHES")" = 1 ] && grep -q -- "-p KillMode=process" "$LAUNCHES" && [ "$(grep -c -- '--unit=sala-op-' "$LAUNCHES")" = 1 ] && ok "a plain watch tick started the oldest as unit sala-op-$R1 (KillMode=process), and only that one" || bad "launches: $(<"$LAUNCHES")"
[ "$(mval "$R1" state)" = running ] && [ "$(mval "$R1" unit)" = "sala-op-$R1" ] && [ -n "$(mval "$R1" boot)" ] && [ "$(mvals "$R1" arg | paste -sd' ' -)" = "--update --force" ] && ok "its marker: running, unit, boot; the flags folded in: --update --force" || bad "marker: $(<"$OPS/$R1.op")"
[ "$(mval "$U1" state)" = absorbed ] && [ "$(mval "$U1" into)" = "$R1" ] && [ -f "$DONE/$U1.op" ] && [ "$(mval "$R2" state)" = absorbed ] && [ -f "$DONE/$R2.op" ] && [ "$(mvals "$R1" absorbed | grep -c .)" = 2 ] && ok "the update and the second recycle: absorbed into $R1, archived, named on its marker" || bad "absorbed: $(cat "$DONE/$U1.op" "$DONE/$R2.op" 2>/dev/null)"
waitfor "grep -q 'folded into op $R1' '$SOCKLOG'" 20 && ok "the update's hearer (h) was told in its inbox" || bad "sock log: $(slurp "$SOCKLOG")"
out=$("$SALA" op --cancel "$R1" 2>&1); [ $? != 0 ] && has "$out" "cannot be dropped" && [ "$(mval "$R1" state)" = running ] && ok "--cancel of a running operation: refused" || bad "cancel running: $out"
export ANTHROPIC_API_KEY="dummy-key-NOT-REAL-$$" ANTHROPIC_CUSTOM_HEADERS="x-test: 1" CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CONFIG_DIR="$HOME/.claude-other"   # the api lane's env on the watch: the claude -p must not see it
tick   # the unit never ran (norun): a runner gone without a result
unset ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS CLAUDE_CODE_ENTRYPOINT CLAUDE_CONFIG_DIR
grep -q -- "--unit=sala-op-$R1-stuck " "$LAUNCHES" && ok "the next tick: the stuck handler started as its own unit sala-op-$R1-stuck (never inside the tick)" || bad "launches: $(<"$LAUNCHES")"
waitfor "[ -f '$DONE/$R1.op' ]" 60
[ "$(mval "$R1" state)" = stuck ] && [ -f "$DONE/$R1.op" ] && has "$(mval "$R1" result)" "ended without a result" && ok "stuck (its runner ended without a result), archived" || bad "dead runner: $(cat "$OPS/$R1.op" "$DONE/$R1.op" 2>/dev/null)"
[ "$(runs)" = 1 ] && [ -n "$(mval "$R1" helper)" ] && ok "the one claude -p ran once (helper= on the marker)" || bad "helper runs: $(runs); marker: $(mval "$R1" helper)"
grep -q '^key=unset hdr=unset entry=unset cfg=unset cwd=' "$HOME/helper-env.txt" && ok "on the subscription-1 lane: no API key, custom headers, entrypoint or config dir in its environment" || bad "helper env: $(<"$HOME/helper-env.txt")"
A=$(<"$HOME/helper-args.txt"); has "$A" "-p" && has "$A" "--max-turns" && grep -qx 7 "$HOME/helper-args.txt" && grep -q '^Bash(sala:\*),Bash(salamander:\*),.*,Read,Grep,Glob$' "$HOME/helper-args.txt" \
    && grep -qx -- '--allowedTools' "$HOME/helper-args.txt" && ! has "$A" "dangerously" && ! has "$A" "permission-mode" && ok "claude -p: --max-turns 7, --allowedTools sala's verbs and read-only looks, no bypass flag" || bad "helper args: $A"
B=$(<"$HOME/helper-brief.txt"); has "$B" "op $R1" && has "$B" "recycle --update --force" && has "$B" "\"recycle claude\"" && has "$B" "What happened: its runner (unit sala-op-$R1) ended without a result" && has "$B" "Already tried:" \
    && has "$B" "SALA-OP: done" && has "$B" "SALA-OP: stuck" && has "$B" "Never --not-master" && ok "the brief: the operation, Rowan's words, what happened, what was tried, the verdict line contract" || bad "brief: $B"
P=$(post "sala op: recycle --update --force · stuck"); [ -n "$P" ] && has "$P" "🚨" && has "$P" "ended without a result" && has "$P" "nothing retries it" && [ "$(grep -c 'folded in:' <<< "$P")" = 2 ] && has "$P" "one-off claude -p" && has "$P" "Details: ~/.claude/salamander-op-$R1.log" \
    && [ "$(nposts 'sala op:')" = 1 ] && ok "one post: stuck, the exact failure, the two folded in, the claude -p named" || bad "post: $P"
waitfor "grep -q 'sala op $R1\] salamander recycle --update --force .*stuck: its runner' '$SOCKLOG'" 20 && ok "the hearing session (h) got the result in its inbox" || bad "sock log: $(<"$SOCKLOG")"
tick; [ "$(runs)" = 1 ] && [ "$(nposts 'sala op:')" = 1 ] && ok "a later tick: nothing retries it, no second claude -p, no second post" || bad "retried: runs=$(runs) posts=$(nposts 'sala op:')"

echo "== a reboot marker whose runner is gone and whose boot id changed: the box is back → done"
RB="1700000000-1"; printf 'id=%s\ntime=1700000000\nfrom=x shell\nwords=reboot t-host-a\nverb=reboot\nstate=running\nunit=sala-op-%s\nstarted=1700000000\nboot=not-this-boot\n' "$RB" "$RB" > "$OPS/$RB.op"
tick; [ "$(mval "$RB" state)" = done ] && has "$(mval "$RB" result)" "rebooted and is back" && [ -f "$DONE/$RB.op" ] && ok "done: rebooted and is back" || bad "reboot marker: $(cat "$OPS/$RB.op" "$DONE/$RB.op" 2>/dev/null)"
rm -f "$HOME/norun"

echo "== end to end: recycle --force through the queue, b busy → the retry worker → waiting → b idle → done, one post, the hearer told"
: > "$POSTS"; : > "$LAUNCHES"; : > "$KICKS"; : > "$SOCKLOG"; rm -f "$HOME/helper-runs.txt"
regstatus sala-test-b busy
enq recycle --force --from sala-test-h --words "recycle claude now"; E="$ID"
[ "$RC" = 0 ] && [ -n "$E" ] && has "$OUT" "phase 1 (check)" && has "$OUT" "sala-test-b" && grep -q 'start --no-block sala-watch.service' "$KICKS" && ok "queued op $E with the sweep's verdicts shown, the watch kicked" || { bad "enqueue: rc=$RC — $OUT"; exit 1; }
tick
waitfor "[ \"\$(mval $E state)\" = waiting ]" 240 && ok "running → waiting: the sweep done, b outstanding with a retry worker" || { bad "state: $(mval "$E" state) — $(cat "$HOME/.claude/salamander-op-$E.log" 2>/dev/null | tail -5)"; }
SET=$(mval "$E" set); [ -n "$SET" ] && [ "$(set_val "$SET" kind)" = Recycle ] && grep -qx 'out=sala-test-b' "$SALA_SET_DIR/$SET" && [ "$(set_val "$SET" done)" = 3 ] && ok "its set: the recycle's, 3 relaunched (h, a, d), b outstanding" || bad "set $SET: $(slurp "$SALA_SET_DIR/$SET")"
[ "$(awk -F'\t' '{print $3}' "$SALA_RECYCLE_LOCK")" = "op-$E" ] && ok "the recycle lock's holder line names op-$E" || bad "lock holder: $(<"$SALA_RECYCLE_LOCK")"
[ "$(grep -c "^start $(uuid 2)" "$FAKE_LOG")" = 2 ] && [ "$(grep -c "^start $(uuid 1)" "$FAKE_LOG")" = 2 ] && [ "$(grep -c "^start $(uuid 3)" "$FAKE_LOG")" = 1 ] && ok "h and a relaunched, b (busy) not" || bad "fake log: $(<"$FAKE_LOG")"
regstatus sala-test-b idle
waitfor "[ -f '$DONE/$E.op' ]" 240 && [ "$(mval "$E" state)" = done ] && ok "b relaunched by the worker, the set closed, the waiter judged: done, archived" || bad "state: $(mval "$E" state) — $(tail -5 "$HOME/.claude/salamander-op-$E.log" 2>/dev/null; tail -5 "$RLOG")"
has "$(mval "$E" result)" "4/4 relaunched" && [ -n "$(mval "$E" waiter)" ] && ok "the result: 4/4 relaunched, judged by the waiter" || bad "marker: $(slurp "$DONE/$E.op")"
P=$(post "sala op: recycle --force · done"); [ -n "$P" ] && has "$P" "✅" && has "$P" "4/4 relaunched" && has "$P" "asked by sala-test-h" && has "$P" "\"recycle claude now\"" && [ "$(nposts 'sala op:')" = 1 ] && ok "one post: done, the set's count, who asked with the words" || bad "post: $P / $(<"$POSTS")"
waitfor "grep -q 'sala op $E\] salamander recycle --force .*done: Recycle' '$SOCKLOG'" 20 && ok "h (relaunched meanwhile) got the result in its inbox" || bad "sock log: $(<"$SOCKLOG")"
L=$(grep "sala op $E\] salamander recycle --force .*done: Recycle" "$SOCKLOG" | head -1); has "$L" "queued at" && ! has "$L" "said at" && has "$P" "queued at" && ! has "$P" "said at" && ok "the done message and the post stamp the quote as queued at, never said at (the marker's time is the queue time)" || bad "quote stamp: $L / $P"
[ "$(runs)" = 0 ] && ok "no claude -p for a clean run" || bad "helper ran: $(<"$HOME/helper-runs.txt")"
waitfor '[ "$(workers)" = 0 ]' 40; wait_lock

echo "== a pane the set gave up (its pane gone; the window's end defers): stuck, the claude -p once with the set in its brief, one post, the hearer told"
: > "$POSTS"; : > "$SOCKLOG"; rm -f "$HOME/helper-runs.txt" "$HOME/helper-verdict.txt"
regstatus sala-test-b busy
enq revive --only sala-test-b --force --from sala-test-h --words "bring b back"; G="$ID"; [ -n "$G" ] || bad "revive not queued: $OUT"
tick
waitfor '[ "$(workers)" = 1 ]' 120 && $T kill-session -t sala-test-b   # b vanishes while the worker waits for it: a real give-up
waitfor "[ -f '$DONE/$G.op' ]" 240 && [ "$(mval "$G" state)" = stuck ] && ok "stuck once the worker gave b up, archived" || bad "state: $(mval "$G" state) — $(tail -5 "$HOME/.claude/salamander-op-$G.log" 2>/dev/null)"
R=$(mval "$G" result); has "$R" "given up" && has "$R" "sala-test-b" && has "$R" "— the one-off claude -p could not finish it: the test helper does nothing" && ! has "$R" "[20" && ok "the result: the pane given up, then the claude -p's own verdict, no log lines in it" || bad "result: $R"
[ "$(runs)" = 1 ] && ok "the claude -p ran once" || bad "runs: $(runs)"
B=$(<"$HOME/helper-brief.txt"); has "$B" "op $G" && has "$B" "revive --only sala-test-b --force" && has "$B" "\"bring b back\"" && has "$B" "its set $(mval "$G" set)" && has "$B" "given up: sala-test-b" && has "$B" "revive --only <session> --force --rescue" \
    && ok "the brief: the operation, the words, its set and what it gave up, the rescue allowed" || bad "brief: $B"
P=$(post "sala op: revive --only sala-test-b --force · stuck"); [ -n "$P" ] && has "$P" "🚨" && has "$P" "given up" && [ "$(nposts 'sala op:')" = 1 ] && ok "one post: stuck with the exact failure" || bad "post: $P / $(<"$POSTS")"
waitfor "grep -q 'sala op $G\] salamander revive --only sala-test-b --force .*stuck: Revive' '$SOCKLOG'" 20 && ok "h got it in its inbox" || bad "sock log: $(<"$SOCKLOG")"
waitfor '[ "$(workers)" = 0 ]' 40; wait_lock
mk b "$(uuid 3)"; fake_up sala-test-b   # b is back for the sections below

echo "== the claude -p's 'done' is checked: a retire whose session still lives is not done; one that really ended it is"
: > "$POSTS"; rm -f "$HOME/helper-runs.txt"; echo "SALA-OP: done retired it" > "$HOME/helper-verdict.txt"
touch "$HOME/norun"; enq retire sala-test-d --from sala-test-h --words "retire d"; V1="$ID"; [ -n "$V1" ] || bad "retire not queued: $OUT"
regstatus sala-test-d busy; rm -f "$HOME/norun"   # busy by the time it runs: the verb fails, the claude -p says done and did nothing
tick; waitfor "[ -f '$DONE/$V1.op' ]" 120
[ "$(mval "$V1" state)" = stuck ] && has "$(mval "$V1" result)" "exited 1" && has "$(mval "$V1" result)" "the check says otherwise: 'sala-test-d' is still a tmux session" && [ "$(runs)" = 1 ] && tmux has-session -t =sala-test-d 2>/dev/null \
    && ok "a false 'done': stuck, the check named, the session untouched" || bad "false done: $(slurp "$DONE/$V1.op")"
regstatus sala-test-d idle; : > "$POSTS"; rm -f "$HOME/helper-runs.txt"
printf '#!/bin/bash\ntmux kill-session -t =sala-test-d\n' > "$HOME/helper-act.sh"; chmod +x "$HOME/helper-act.sh"; echo "SALA-OP: done ended the session" > "$HOME/helper-verdict.txt"
touch "$HOME/norun"; enq retire sala-test-d --from sala-test-h --words "retire d"; V2="$ID"; [ -n "$V2" ] || bad "retire not queued: $OUT"
regstatus sala-test-d busy; rm -f "$HOME/norun"
tick; waitfor "[ -f '$DONE/$V2.op' ]" 120
[ "$(mval "$V2" state)" = done ] && has "$(mval "$V2" result)" "ended the session (the one-off claude -p finished it" && [ "$(runs)" = 1 ] && ! tmux has-session -t =sala-test-d 2>/dev/null \
    && ok "a real 'done': the session gone, the operation done through the claude -p, its first try in the result" || bad "real done: $(slurp "$DONE/$V2.op")"
P=$(post "sala op: retire sala-test-d · done"); [ -n "$P" ] && has "$P" "✅" && has "$P" "one-off claude -p" && ok "one post: done, the claude -p named" || bad "post: $P"
rm -f "$HOME/helper-act.sh" "$HOME/helper-verdict.txt"

echo "== two queued operations naming one session (markers written past the enqueue check): the first is stuck, neither runs, no claude -p with SALA_OP_STUCK=off"
: > "$POSTS"; rm -f "$HOME/helper-runs.txt"; now=$(date +%s)
C1="$now-1"; C2="$((now+1))-2"
printf 'id=%s\ntime=%s\nfrom=sala-test-h\nwords=retire a\nverb=retire\narg=sala-test-a\nstate=queued\n' "$C1" "$now" > "$OPS/$C1.op"
printf 'id=%s\ntime=%s\nfrom=x shell\nwords=bring a back\nverb=revive\narg=--only\narg=sala-test-a\narg=--force\nstate=queued\n' "$C2" "$((now+1))" > "$OPS/$C2.op"
SALA_OP_STUCK=off tick; waitfor "[ -f '$DONE/$C1.op' ]" 60
[ "$(mval "$C1" state)" = stuck ] && has "$(mval "$C1" result)" "conflicts with queued op $C2" && [ "$(mval "$C2" state)" = queued ] && tmux has-session -t =sala-test-a 2>/dev/null && [ "$(grep -c "^start $(uuid 2)" "$FAKE_LOG")" = 2 ] \
    && ok "the first stuck on the conflict, the second still queued, a untouched" || bad "conflict: $(cat "$DONE/$C1.op" "$OPS/$C2.op" 2>/dev/null)"
[ "$(runs)" = 0 ] && [ -z "$(mval "$C1" helper)" ] && ! has "$(post 'sala op: retire sala-test-a · stuck')" "one-off claude -p" && ok "SALA_OP_STUCK=off: no claude -p, and the post says none" || bad "helper ran: $(slurp "$HOME/helper-runs.txt")"
"$SALA" op --cancel "$C2" >/dev/null; [ "$(queued)" = 0 ] && ok "the second cancelled" || bad "left: $(ls "$OPS")"

echo "== the waiter's deadline: a set still outstanding when SALA_OP_SETTLE_WAIT is out → stuck, the worker goes on by itself"
: > "$POSTS"; rm -f "$HOME/helper-runs.txt"
regstatus sala-test-b busy; export SALA_OP_SETTLE_WAIT=3
enq revive --only sala-test-b --force --from sala-test-h --words "b again"; W="$ID"; [ -n "$W" ] || bad "revive not queued: $OUT"
tick; waitfor "[ -f '$DONE/$W.op' ]" 120
[ "$(mval "$W" state)" = stuck ] && has "$(mval "$W" result)" "still outstanding after 3 s" && has "$(mval "$W" result)" "sala-test-b" && [ "$(runs)" = 1 ] && ok "stuck: b still outstanding after 3 s, the claude -p once" || bad "deadline: $(slurp "$DONE/$W.op")"
export SALA_OP_SETTLE_WAIT=120; regstatus sala-test-b idle; waitfor '[ "$(workers)" = 0 ]' 60 && ok "the retry worker finished on its own once b was idle" || bad "workers: $(workers)"
wait_lock

echo "== the model verb: the shape's refusals say why; the plan; the marker; one session one driver; the notice when the asker names itself; --clear"
MODELS="$SALA_STATE_DIR/models.tsv"; mrow() { awk -F'\t' -v s="$1" '$1==s {print $2 "/" $3}' "$MODELS" 2>/dev/null; }
enq model sala-test-a gpt5 --from t --words x; [ "$RC" = 2 ] && has "$OUT" "'gpt5' is not a model (one of: opus sonnet haiku fable" && ok "a bad model: refused at queue time, the choices named" || bad "bad model: rc=$RC — $OUT"
enq model sala-test-a opus --effort ultra --from t --words x; [ "$RC" = 2 ] && has "$OUT" "'ultra' is not an effort (one of: low medium high xhigh max)" && ok "a bad effort: refused at queue time, the choices named" || bad "bad effort: rc=$RC — $OUT"
enq model sala-test-a opus --record-only --from t --words x; [ "$RC" = 2 ] && has "$OUT" "not '--record-only'" && ok "--record-only is not a queue argument" || bad "record-only: rc=$RC — $OUT"
enq model sala-test-nope opus --from t --words x; [ "$RC" = 1 ] && has "$OUT" "unknown session 'sala-test-nope'" && has "$OUT" "nothing queued" && ok "no such session: the plan (model --dry-run) refuses it before anything is queued" || bad "no session: rc=$RC — $OUT"
enq model sala-test-nope --clear --from t --words x; [ "$RC" = 1 ] && has "$OUT" "unknown session 'sala-test-nope'" && [ "$(queued)" = 0 ] && ok "--clear of no such session: refused by the plan" || bad "clear no session: rc=$RC — $OUT"
enq --plan model sala-test-a haiku --effort high; [ "$RC" = 0 ] && has "$OUT" "plan: salamander model sala-test-a haiku --effort high" && has "$OUT" "[dry-run] would record sala-test-a → haiku/high" && has "$OUT" "plan only: nothing queued" \
    && [ "$(queued)" = 0 ] && [ -z "$(mrow sala-test-a)" ] && ok "--plan: the row it would record and the relaunch verdict, nothing queued, nothing recorded" || bad "plan: rc=$RC — $OUT / row '$(mrow sala-test-a)'"
enq --plan model sala-test-a haiku; [ "$RC" = 0 ] && has "$OUT" "would record the model, then switch the pane in place when it is idle with an empty input box" && has "$OUT" "[dry-run] would relaunch — it cannot be switched in place: in-place switching is off" && ok "--plan: the note names both paths, and the dry run says which applies (this suite has the in-place switch off: tests/modelinplace.sh's)" || bad "plan note: rc=$RC — $OUT"
enq --plan model sala-test-a --clear; [ "$RC" = 0 ] && has "$OUT" "plan: salamander model sala-test-a --clear" && has "$OUT" "would drop the model record" && ok "--plan --clear: the note, nothing queued" || bad "plan clear: rc=$RC — $OUT"
touch "$HOME/active"
enq model sala-test-a haiku --effort high --from sala-test-h --words "put a on haiku, high effort"; M1="$ID"
[ "$RC" = 0 ] && [ -n "$M1" ] && [ "$(mval "$M1" verb)" = model ] && [ "$(mvals "$M1" arg | paste -sd' ' -)" = "sala-test-a haiku --effort high" ] && [ "$(mval "$M1" state)" = queued ] && [ "$(mval "$M1" words)" = "put a on haiku, high effort" ] \
    && [ -z "$(mrow sala-test-a)" ] && ok "queued: the marker holds the verb, session, model and effort as arg lines and Rowan's words; the record is written only when it runs" || bad "model marker: rc=$RC — $OUT / $(slurp "$OPS/$M1.op")"
! has "$OUT" "will have its model switched once it is idle" && ok "another session as the target: no notice about this pane" || bad "notice for another session: $OUT"
enq revive --only sala-test-a --force --from t --words "revive a"; [ "$RC" != 0 ] && has "$OUT" "names the same session" && has "$OUT" "$M1" && ok "a second verb on the same session: refused (one driver per pane)" || bad "conflict with model: rc=$RC — $OUT"
enq lane subscription-1 sala-test-a --from t --words "a on subscription-1"; [ "$RC" != 0 ] && has "$OUT" "names the same session" && ok "a lane move of the same session: refused too" || bad "conflict with lane: rc=$RC — $OUT"
enq retire sala-test-a --from t --words "retire a"; [ "$RC" != 0 ] && has "$OUT" "names the same session" && ok "a retire of the same session: refused too" || bad "conflict with retire: rc=$RC — $OUT"
"$SALA" op --cancel "$M1" >/dev/null; rm -f "$HOME/active"
TMUX_PANE=$(pane h) enq model sala-test-h sonnet --effort low --from sala-test-h --words "h on sonnet, low effort"; M2="$ID"
[ "$RC" = 0 ] && has "$OUT" "this pane ('sala-test-h') will have its model switched once it is idle (in place when its input box is empty, else relaunched) — finish or hand off anything half-done now" && ok "the asker names its own session: the notice, as recycle prints it" || bad "self notice: rc=$RC — $OUT"
has "$OUT" "then: salamander revive --force --only sala-test-h" && ! has "$OUT" "revive --self" && ok "and the plan shows the path the unit takes (revive --force --only, there being no pane in the unit), not model.sh's --self" || bad "self plan: $OUT"
"$SALA" op --cancel "$M2" >/dev/null
TMUX_PANE=$(pane h) enq model sala-test-a sonnet --from sala-test-h --words "a on sonnet"; M3="$ID"
[ "$RC" = 0 ] && ! has "$OUT" "will have its model switched once it is idle" && ok "a pane asking for another session: no notice" || bad "notice for another: rc=$RC — $OUT"
"$SALA" op --cancel "$M3" >/dev/null
TMUX_PANE=$(pane h) enq model sala-test-h --clear --from sala-test-h --words "h back on its transcript"; M4="$ID"
[ "$RC" = 0 ] && ! has "$OUT" "will have its model switched once it is idle" && ok "--clear on the asker's own session: no notice (nothing is relaunched)" || bad "notice for clear: rc=$RC — $OUT"
"$SALA" op --cancel "$M4" >/dev/null
[ "$(queued)" = 0 ] && ok "the queue is empty again" || bad "left: $(ls "$OPS")"

echo "== the rename verb's plan: the asker's own pane is typed into from outside once idle (the runner has no TMUX_PANE), not left to the owner"
mk r "$(uuid 9)"; fake_up sala-test-r || exit 1; "$SALA" adopt sala-test-r >/dev/null 2>&1   # a pane of its own, adopted: a rename needs its row in the pane map
TMUX_PANE=$(pane r) enq --plan rename sala-test-r sala-test-r2; RN="$OUT"
[ "$RC" = 0 ] && has "$RN" "plan: salamander rename sala-test-r sala-test-r2" && has "$RN" "type /rename sala-test-r2 (pane now:" && ! has "$RN" "type /rename sala-test-r2 here yourself" && ! has "$RN" "it is this pane" \
    && has "$RN" "'sala-test-r' is the pane asking. The queued operation runs outside every pane, so it types /rename sala-test-r2 into it itself once the pane is idle" && has "$RN" "every minute for up to 2 hours" && has "$RN" "Nothing is left for" && has "$RN" "plan only: nothing queued" && [ "$(queued)" = 0 ] \
    && ok "--plan rename of the asker's own pane (TMUX_PANE set): the runner's path ('type /rename … (pane now: …') and the note, never 'type it here yourself'" || bad "own-pane rename plan: rc=$RC — $RN"
echo "$RN" | sed 's/^/    | /'
enq --plan rename sala-test-r sala-test-r2 --from sala-test-r; [ "$RC" = 0 ] && has "$OUT" "'sala-test-r' is the pane asking" && has "$OUT" "type /rename sala-test-r2 (pane now:" \
    && ok "the same from a shell with --from naming the pane: the same note" || bad "own-pane rename plan by --from: rc=$RC — $OUT"
TMUX_PANE=$(pane h) enq --plan rename sala-test-r sala-test-r3 --from sala-test-h; [ "$RC" = 0 ] && has "$OUT" "type /rename sala-test-r3 (pane now:" && ! has "$OUT" "is the pane asking" \
    && ok "another session's rename: the runner's line and no note about the asker" || bad "other-pane rename plan: rc=$RC — $OUT"
TMUX_PANE=$(pane r) enq rename sala-test-r sala-test-r2 --from sala-test-r --words "rename r to r2"; RQ="$ID"; RQO="$OUT"
[ "$RC" = 0 ] && [ -n "$RQ" ] && has "$RQO" "this pane ('sala-test-r') will have /rename sala-test-r2 typed into it once it is idle, right after this turn ends" && ! has "$RQO" "yourself" \
    && ok "queued: the closing line tells the asker nothing is left to type" || bad "own-pane rename queued: rc=$RC — $RQO"
"$SALA" op --cancel "$RQ" >/dev/null; [ "$(queued)" = 0 ] && ok "cancelled; the queue is empty again" || bad "left: $(ls "$OPS")"
$T kill-session -t =sala-test-r 2>/dev/null; "$SALA" forget-row sala-test-r >/dev/null 2>&1   # this section's own pane goes; the later sections run on the others

echo "== the model verb end to end: a (idle) on haiku/high through the unit, then h (the asker, busy → the retry worker → idle) on sonnet, then --clear"
: > "$POSTS"; : > "$SOCKLOG"; rm -f "$HOME/helper-runs.txt"
enq model sala-test-a haiku --effort high --from sala-test-h --words "put a on haiku, high effort"; M5="$ID"; [ -n "$M5" ] || bad "model not queued: $OUT"
tick; waitfor "[ -f '$DONE/$M5.op' ]" 240
[ "$(mval "$M5" state)" = done ] && [ "$(mrow sala-test-a)" = haiku/high ] && ok "done: the row haiku/high recorded by the unit" || bad "model run: $(slurp "$DONE/$M5.op") / row '$(mrow sala-test-a)' / $(tail -8 "$HOME/.claude/salamander-op-$M5.log" 2>/dev/null)"
waitfor "[ \"\$(grep -c \"^start $(uuid 2) \" \"\$FAKE_LOG\")\" -ge 3 ]" 40; fake_up sala-test-a
case "$(proc_args "$(claude_pid_under "$(tmux display -p -t sala-test-a '#{pane_pid}')")")" in *"--model haiku --effort high"*) ok "a's claude was relaunched on --model haiku --effort high" ;; *) bad "a's args: $(proc_args "$(claude_pid_under "$(tmux display -p -t sala-test-a '#{pane_pid}')")")" ;; esac
P=$(post "sala op: model sala-test-a haiku --effort high · done"); [ -n "$P" ] && has "$P" "✅" && has "$P" "asked by sala-test-h" && [ "$(nposts 'sala op:')" = 1 ] && ok "one post: done, who asked with the owner's words" || bad "post: $P / $(<"$POSTS")"
waitfor "grep -q 'sala op $M5\] salamander model sala-test-a haiku --effort high .*done' '$SOCKLOG'" 20 && ok "the hearing session (h) got the result in its inbox" || bad "sock log: $(<"$SOCKLOG")"
HS0=$(grep -c "^start $(uuid 1) " "$FAKE_LOG"); : > "$POSTS"; : > "$SOCKLOG"; wait_lock
regstatus sala-test-h busy   # the asker works while the operation runs: the unit has no TMUX_PANE, so h is relaunched like any pane, once idle
enq model sala-test-h sonnet --from sala-test-h --words "h on sonnet"; M6="$ID"; [ -n "$M6" ] || bad "self model not queued: $OUT"
tick
waitfor "[ \"\$(mval $M6 state)\" = waiting ]" 240 && [ "$(mrow sala-test-h)" = sonnet/- ] && ok "the asker busy: the row recorded at once, the operation waiting on h's relaunch (a retry worker holds it)" || bad "self run: state $(mval "$M6" state) row '$(mrow sala-test-h)' / $(tail -8 "$HOME/.claude/salamander-op-$M6.log" 2>/dev/null)"
[ "$(grep -c "^start $(uuid 1) " "$FAKE_LOG")" = "$HS0" ] && ok "h itself is not relaunched while it is busy" || bad "h relaunched early: $(grep -c "^start $(uuid 1) " "$FAKE_LOG") vs $HS0"
regstatus sala-test-h idle
waitfor "[ -f '$DONE/$M6.op' ]" 240 && [ "$(mval "$M6" state)" = done ] && ok "h idle: relaunched by the worker, the operation done" || bad "self end: $(cat "$OPS/$M6.op" "$DONE/$M6.op" 2>/dev/null) / $(tail -8 "$HOME/.claude/salamander-op-$M6.log" 2>/dev/null)"
[ "$(grep -c "^start $(uuid 1) " "$FAKE_LOG")" = "$((HS0+1))" ] && ok "h relaunched exactly once" || bad "h starts: $(grep -c "^start $(uuid 1) " "$FAKE_LOG") vs $HS0+1"
fake_up sala-test-h; case "$(proc_args "$(claude_pid_under "$(tmux display -p -t sala-test-h '#{pane_pid}')")")" in *"--model sonnet"*) ok "h's claude runs --model sonnet, no --effort of its own" ;; *) bad "h args: $(proc_args "$(claude_pid_under "$(tmux display -p -t sala-test-h '#{pane_pid}')")")" ;; esac
waitfor "grep -q 'sala op $M6\] salamander model sala-test-h sonnet .*done' '$SOCKLOG'" 40 && ok "the asker, relaunched on its new model, got the result in its inbox" || bad "sock log: $(<"$SOCKLOG")"
waitfor '[ "$(workers)" = 0 ]' 40; wait_lock
AS0=$(grep -c "^start $(uuid 2) " "$FAKE_LOG"); : > "$POSTS"
enq model sala-test-a --clear --from sala-test-h --words "a back on its transcript"; M7="$ID"; [ -n "$M7" ] || bad "clear not queued: $OUT"
tick; waitfor "[ -f '$DONE/$M7.op' ]" 120
[ "$(mval "$M7" state)" = done ] && [ -z "$(mrow sala-test-a)" ] && [ "$(mrow sala-test-h)" = sonnet/- ] && sleep 2 && [ "$(grep -c "^start $(uuid 2) " "$FAKE_LOG")" = "$AS0" ] && ok "--clear through the queue: done, a's row gone, h's kept, nothing relaunched" || bad "clear: $(slurp "$DONE/$M7.op") / row '$(mrow sala-test-a)' starts $(grep -c "^start $(uuid 2) " "$FAKE_LOG") vs $AS0"
[ "$(runs)" = 0 ] && ok "no claude -p for any of them" || bad "helper ran: $(<"$HOME/helper-runs.txt")"

echo "== the reply when the asking pane is gone (the project-name panes retire): live → as before; dead + a live <name>-main → there, [for Rowan] first, logged; neither → a failure line"
mk zq-main "$(uuid 9)" -e FAKE_SOCK_LOG="$SOCKLOG"; fake_up sala-test-zq-main || exit 1   # sala-test-zq itself never exists: the retired project-name pane
OPLOG="$SALA_LOG_DIR/salamander-op.log"; : > "$SOCKLOG"; : > "$OPLOG" 2>/dev/null
tell() { bash -c '. "$1/lib/common.sh"; . "$1/lib/op.sh"; op_tell "$2" "$3"; echo "rc=$?"' _ "$ROOT" "$1" "$2" 2>&1; }
out=$(tell sala-test-h "[sala op 1-1] result one")
has "$out" "rc=0" && waitfor "grep -q 'result one' '$SOCKLOG'" 20 && [ "$(grep -c 'result one' "$SOCKLOG")" = 1 ] && grep 'result one' "$SOCKLOG" | grep -q "^$(uuid 1) .*\"content\": \"\[sala op 1-1\] result one\"" \
    && ! grep -q 'for Rowan' "$SOCKLOG" && ! grep -q 'reply' "$OPLOG" && ok "a live asking pane: the line goes to it, unchanged, nothing about a fallback in the log" || bad "live: $out / $(<"$SOCKLOG") / $(<"$OPLOG")"
: > "$SOCKLOG"
out=$(tell sala-test-zq "[sala op 1-2] result two")
has "$out" "rc=0" && waitfor "grep -q 'result two' '$SOCKLOG'" 20 && [ "$(grep -c 'result two' "$SOCKLOG")" = 1 ] && grep 'result two' "$SOCKLOG" | grep -q "^$(uuid 9) .*\"content\": \"\[for Rowan\]\\\\n\[sala op 1-2\] result two\"" \
    && ! grep -q 'told sala-test-zq (' "$OPLOG" && grep -q 'reply: sala-test-zq has no live pane; sent to sala-test-zq-main' "$OPLOG" && ok "a dead asking pane with a live <name>-main: sent there with [for Rowan] on line 1, and the log says so" || bad "dead + main: $out / $(<"$SOCKLOG") / $(<"$OPLOG")"
: > "$SOCKLOG"
out=$(tell sala-test-yy "[sala op 1-3] result three")
has "$out" "rc=0" && ! grep -q 'result three' "$SOCKLOG" && grep -q 'reply FAILED: sala-test-yy has no live pane and sala-test-yy-main has none either; nobody was told' "$OPLOG" \
    && ok "neither live: nothing delivered, a failure line in the op log (the Slack post stands, rc 0)" || bad "neither: $out / $(<"$SOCKLOG") / $(<"$OPLOG")"
out=$(tell sala-test-yy-main "[sala op 1-4] result four")
has "$out" "rc=0" && ! grep -q 'result four' "$SOCKLOG" && grep -q 'reply FAILED: sala-test-yy-main has no live pane; nobody was told' "$OPLOG" && ! grep -q 'yy-main-main' "$OPLOG" \
    && ok "a dead *-main asker: no second fallback (no -main-main), a failure line" || bad "dead main: $out / $(<"$OPLOG")"

echo "== the model verb for several sessions: one operation, one combined notice; the old single-session shape unchanged; an unknown session refuses the lot"
waitfor '[ "$(workers)" = 0 ]' 40; wait_lock; : > "$POSTS"; : > "$SOCKLOG"; rm -f "$HOME/helper-runs.txt"
mk e "$(uuid 6)"; mk f "$(uuid 7)"; mk g "$(uuid 8)"; fake_up sala-test-e sala-test-f sala-test-g || exit 1
enq model haiku --from t --words x; [ "$RC" = 2 ] && has "$OUT" "✗" && ok "model <model> with no session: refused (exit 2)" || bad "batch no session: rc=$RC — $OUT"
enq model haiku --effort high --from t --words x; [ "$RC" = 2 ] && has "$OUT" "needs at least one session" && ok "model <model> --effort <level> with no session: refused, says why" || bad "batch effort no session: rc=$RC — $OUT"
enq model haiku sala-test-e --record-only --from t --words x; [ "$RC" = 2 ] && has "$OUT" "not '--record-only'" && ok "the batch takes no --record-only at the queue either" || bad "batch record-only: rc=$RC — $OUT"
enq model haiku --effort ultra sala-test-e sala-test-f --from t --words x; [ "$RC" = 2 ] && has "$OUT" "'ultra' is not an effort" && ok "the batch: a bad effort refused, the choices named" || bad "batch bad effort: rc=$RC — $OUT"
enq model haiku sala-test-e 'a b' --from t --words x; [ "$RC" = 2 ] && has "$OUT" "is not a session name" && ok "the batch: a session name with a space refused" || bad "batch bad name: rc=$RC — $OUT"
enq model haiku --effort high sala-test-e sala-test-nope sala-test-f --from t --words x
[ "$RC" = 1 ] && has "$OUT" "unknown session 'sala-test-nope'" && has "$OUT" "nothing queued" && [ "$(queued)" = 0 ] && [ -z "$(mrow sala-test-e)" ] && [ -z "$(mrow sala-test-f)" ] \
    && ok "one unknown session among three: the whole operation refused by name, nothing queued, no row written" || bad "batch unknown session: rc=$RC — $OUT / queued $(queued) rows '$(mrow sala-test-e)' '$(mrow sala-test-f)'"
enq model --clear sala-test-e sala-test-nope --from t --words x; [ "$RC" = 1 ] && has "$OUT" "unknown session 'sala-test-nope'" && [ "$(queued)" = 0 ] && ok "--clear <session>… with an unknown one: refused the same way" || bad "batch clear unknown: rc=$RC — $OUT"
enq --plan model haiku --effort high sala-test-e sala-test-f sala-test-g
[ "$RC" = 0 ] && has "$OUT" "plan: salamander model haiku --effort high sala-test-e sala-test-f sala-test-g" && has "$OUT" "[dry-run] would record sala-test-e → haiku/high" && has "$OUT" "[dry-run] would record sala-test-g → haiku/high" \
    && has "$OUT" "relaunch it; the relaunches go together, in one sweep, and the result is one notice" && has "$OUT" "plan only: nothing queued" && [ "$(queued)" = 0 ] && ok "--plan: the dry run of every session in one plan, the note says one sweep and one notice, nothing queued" || bad "batch plan: rc=$RC — $OUT"
enq --plan model sala-test-e haiku --effort high; [ "$RC" = 0 ] && has "$OUT" "plan: salamander model sala-test-e haiku --effort high" && ! has "$OUT" "model batch" && ok "the rule: a first word that is not a model is the session of the old shape (planned as it always was)" || bad "old shape plan: rc=$RC — $OUT"
enq --plan model haiku sala-test-e; [ "$RC" = 0 ] && has "$OUT" "plan: salamander model haiku sala-test-e" && has "$OUT" "model batch: 1 session(s) → haiku" && ok "and a first word that is a model is the many-session shape, even with one session" || bad "new shape one session: rc=$RC — $OUT"
enq --plan model --clear sala-test-e sala-test-f; [ "$RC" = 0 ] && has "$OUT" "plan: salamander model --clear sala-test-e sala-test-f" && has "$OUT" "would drop the model record of sala-test-e sala-test-f" && ok "--plan --clear <session>…: one plan for the lot" || bad "batch clear plan: rc=$RC — $OUT"
touch "$HOME/active"
enq model haiku --effort high sala-test-e sala-test-f sala-test-g --from sala-test-h --words "put e, f and g on haiku, high effort"; MB="$ID"
[ "$RC" = 0 ] && [ -n "$MB" ] && [ "$(queued)" = 1 ] && [ "$(mval "$MB" verb)" = model ] && [ "$(mvals "$MB" arg | paste -sd' ' -)" = "haiku --effort high sala-test-e sala-test-f sala-test-g" ] && [ "$(mval "$MB" state)" = queued ] \
    && [ -z "$(mrow sala-test-e)" ] && ok "three sessions: ONE marker (verb model, the model, the effort and the three sessions as arg lines), nothing recorded until it runs" || bad "batch marker: rc=$RC (queued $(queued)) — $OUT / $(slurp "$OPS/$MB.op")"
! has "$OUT" "will have its model switched once it is idle" && ok "the asker (h) is not among them: no notice about this pane" || bad "batch notice for another: $OUT"
enq revive --only sala-test-f --force --from t --words "revive f"; [ "$RC" != 0 ] && has "$OUT" "names the same session" && has "$OUT" "$MB" && ok "another verb on any one of the sessions is refused while the batch is queued (one driver per pane)" || bad "batch conflict: rc=$RC — $OUT"
rm -f "$HOME/active"
: > "$POSTS"; : > "$SOCKLOG"
tick; waitfor "[ -f '$DONE/$MB.op' ]" 240
[ "$(mval "$MB" state)" = done ] && [ "$(mrow sala-test-e)" = haiku/high ] && [ "$(mrow sala-test-f)" = haiku/high ] && [ "$(mrow sala-test-g)" = haiku/high ] && ok "done: all three rows haiku/high recorded by the one unit" || bad "batch run: $(slurp "$DONE/$MB.op") / rows '$(mrow sala-test-e)' '$(mrow sala-test-f)' '$(mrow sala-test-g)' / $(tail -12 "$HOME/.claude/salamander-op-$MB.log" 2>/dev/null)"
[ "$(mvals "$MB" detail | wc -l)" = 3 ] && [ "$(grep -c 'relaunch sweep: one revive for 3 pane' "$SALA_LOG_DIR/salamander-op-$MB.out" 2>/dev/null)" = 1 ] && ok "one line per session on the marker, and ONE sweep for the three relaunches" || bad "batch detail: $(mvals "$MB" detail) / $(slurp "$SALA_LOG_DIR/salamander-op-$MB.out")"
waitfor "[ \"\$(starts $(uuid 6))\" -ge 2 ] && [ \"\$(starts $(uuid 7))\" -ge 2 ] && [ \"\$(starts $(uuid 8))\" -ge 2 ]" 60 || true
wait_lock; fake_up sala-test-e sala-test-f sala-test-g
bs=0; for n in e f g; do case "$(proc_args "$(claude_pid_under "$(tmux display -p -t sala-test-$n '#{pane_pid}')")")" in *"--model haiku --effort high"*) bs=$((bs+1));; esac; done
[ "$bs" = 3 ] && [ "$(starts "$(uuid 6)")" = 2 ] && [ "$(starts "$(uuid 7)")" = 2 ] && [ "$(starts "$(uuid 8)")" = 2 ] && ok "each pane relaunched exactly once, on --model haiku --effort high" || bad "batch relaunches: $bs on haiku/high, starts $(starts "$(uuid 6)") $(starts "$(uuid 7)") $(starts "$(uuid 8)")"
[ "$(nposts 'sala op:')" = 1 ] && P=$(post "✅ *sala op: model haiku --effort high · done* · 3 sessions") && [ -n "$P" ] && has "$P" "asked by sala-test-h" && ! has "$P" "sala-test-e" && ! has "$P" "sala-test-f" && ! has "$P" "sala-test-g" \
    && ok "ONE Slack post for the three: done, a count of the sessions (none named), who asked" || bad "batch post: $(nposts 'sala op:') posts — $(<"$POSTS")"
waitfor "grep -q 'sala op $MB\] salamander model haiku --effort high .* done (3 sessions)' '$SOCKLOG'" 30 \
    && [ "$(grep -c "sala op $MB\]" "$SOCKLOG")" = 1 ] && L=$(grep "sala op $MB\]" "$SOCKLOG") && ! has "$L" "sala-test-e" && ! has "$L" "sala-test-f" && ! has "$L" "sala-test-g" \
    && ok "ONE notice into the asker's inbox, with the count and no session named" || bad "batch notice: $(grep -c "sala op $MB\]" "$SOCKLOG") lines — $(<"$SOCKLOG")"
[ "$(runs)" = 0 ] && ok "no claude -p" || bad "helper ran: $(<"$HOME/helper-runs.txt")"
wait_lock; : > "$POSTS"; : > "$SOCKLOG"
# the old single-session shape through the same unit: still one session, no batch lines (its end to end is the section above)
enq model sala-test-e --clear --from sala-test-h --words "e back on its transcript"; MC="$ID"; tick; waitfor "[ -f '$DONE/$MC.op' ]" 120
[ "$(mval "$MC" state)" = done ] && [ -z "$(mrow sala-test-e)" ] && [ "$(mrow sala-test-f)" = haiku/high ] && [ -z "$(mvals "$MC" detail)" ] && ok "the single-session --clear: e's row gone, f's kept, no detail lines (the old shape as it was)" || bad "old --clear: $(slurp "$DONE/$MC.op") / rows '$(mrow sala-test-e)' '$(mrow sala-test-f)'"
: > "$POSTS"; : > "$SOCKLOG"
enq model --clear sala-test-f sala-test-g --from sala-test-h --words "f and g back on their transcripts"; MD="$ID"; tick; waitfor "[ -f '$DONE/$MD.op' ]" 120
[ "$(mval "$MD" state)" = done ] && [ -z "$(mrow sala-test-f)" ] && [ -z "$(mrow sala-test-g)" ] && [ "$(mvals "$MD" detail | wc -l)" = 2 ] && [ "$(nposts 'sala op:')" = 1 ] && ok "--clear <session>… through the queue: both rows dropped, one operation, one post" || bad "batch clear: $(slurp "$DONE/$MD.op") / rows '$(mrow sala-test-f)' '$(mrow sala-test-g)' posts $(nposts 'sala op:')"
waitfor "[ \"\$(grep -c \"sala op $MD\\]\" \"$SOCKLOG\")\" = 1 ]" 30 && L=$(grep "sala op $MD\]" "$SOCKLOG") && has "$L" "salamander model --clear " && has "$L" "done (2 sessions)" && ! has "$L" "sala-test-f" && ! has "$L" "sala-test-g" && ok "and one inbox notice: the count, no session named" || bad "batch clear notice: $(<"$SOCKLOG")"
# a session that fails: a stand-in model.sh (a copy of the entry point whose lib/model.sh prints what a batch with a failure prints and exits 1)
BSTUB="$HOME/batchstub"; mkdir -p "$BSTUB/bin" "$BSTUB/lib"; cp "$ROOT/bin/salamander" "$BSTUB/bin/salamander"
for f in "$ROOT"/lib/*; do ln -s "$f" "$BSTUB/lib/$(basename "$f")"; done; ln -s "$ROOT/mod" "$BSTUB/mod"; rm -f "$BSTUB/lib/model.sh"
printf '%s\n' 'echo "RESULT sala-test-e: switched in place to haiku/high"' 'echo "RESULT sala-test-f: FAILED: boom (exit 1)"' 'echo "model batch: 2 session(s) → haiku/high: 1 switched in place, 1 FAILED (sala-test-f)"' 'exit 1' > "$BSTUB/lib/model.sh"
MF="$(( $(date +%s) + 500 ))-77"; { printf 'id=%s\ntime=%s\nfrom=sala-test-h\nwords=partial test\nverb=model\n' "$MF" "${MF%%-*}"; printf 'arg=%s\n' haiku --effort high sala-test-e sala-test-f; echo state=queued; } > "$OPS/$MF.op"
: > "$POSTS"; : > "$SOCKLOG"; rm -f "$HOME/helper-runs.txt"
SALA_CGROUP_FILE="$HOME/op-unit.cgroup" "$BSTUB/bin/salamander" op --run "$MF" >/dev/null 2>&1
[ "$(mval "$MF" state)" = stuck ] && has "$(mval "$MF" result)" "1 FAILED (sala-test-f)" && [ "$(mvals "$MF" detail | wc -l)" = 2 ] && [ "$(runs)" = 0 ] && ok "a batch with a failed session: stuck, the failure named in the result, a line per session, no claude -p" || bad "batch failure: $(slurp "$DONE/$MF.op") / helper runs $(runs)"
P=$(post "🚨 *sala op: model haiku --effort high · stuck · 1/2 succeeded*"); [ "$(nposts 'sala op:')" = 1 ] && [ -n "$P" ] && has "$P" "sala-test-f: FAILED: boom (exit 1)" && ! has "$P" "sala-test-e:" && ok "one 🚨 post: the count, the failed session named with its reason, the one that stood not listed" || bad "batch failure post: $(<"$POSTS")"
waitfor "grep -q 'sala op $MF\] .*stuck (1/2 succeeded): model batch: 2 session(s)' '$SOCKLOG'" 30 && [ "$(grep -c "sala op $MF\]" "$SOCKLOG")" = 1 ] && L=$(grep "sala op $MF\]" "$SOCKLOG") && has "$L" "sala-test-f: FAILED: boom (exit 1)" && ! has "$L" "sala-test-e:" && ok "one inbox notice: the count and the failure line" || bad "batch failure notice: $(<"$SOCKLOG")"
rm -rf "$BSTUB"

echo "== the post of a many-session operation: a count of the sessions through, the failed and skipped ones named with their reason; one session named as before"
# op_finish called on markers written by hand (nothing is run: the result, the lines and the set are what a run would leave)
fin() { bash -c '. "$1/lib/common.sh"; . "$1/lib/op.sh"; op_finish "$2" "$3" "$4"' _ "$ROOT" "$@" >/dev/null 2>&1; }   # <id> done|stuck <result>
mkfin() {  # <id> <from> <verb> <arg>… — a running marker
    local i="$1" fr="$2" v="$3" a; shift 3
    { printf 'id=%s\ntime=%s\nfrom=%s\nwords=post test\nverb=%s\n' "$i" "${i%%-*}" "$fr" "$v"; for a in "$@"; do printf 'arg=%s\n' "$a"; done; echo state=running; } > "$OPS/$i.op"
}
FK=$(( $(date +%s) + 900 ))
# many sessions, every one through: a count, no name
: > "$POSTS"; : > "$SOCKLOG"; F1="$FK-81"; NN=(); for k in $(seq -w 1 17); do NN+=("sala-test-n$k"); done
mkfin "$F1" sala-test-h lane subscription-1 "${NN[@]}"; fin "$F1" done "Lane subscription-1: 17/17 relaunched"
P=$(post "sala op:"); [ "$(nposts 'sala op:')" = 1 ] && has "$P" "✅ *sala op: lane subscription-1 · done* · 17 sessions" && has "$P" "17/17 relaunched" && ! has "$P" "sala-test-n" && has "$P" "asked by sala-test-h" \
    && ok "17 sessions, all through: the title says '· done* · 17 sessions' and names none" || bad "17 post: $(<"$POSTS")"
waitfor "grep -q 'sala op $F1\]' '$SOCKLOG'" 30 && L=$(grep "sala op $F1\]" "$SOCKLOG") && has "$L" "salamander lane subscription-1 " && has "$L" "done (17 sessions): Lane subscription-1: 17/17 relaunched" && ! has "$L" "sala-test-n" \
    && ok "and the inbox line: the count, no session named" || bad "17 inbox: $(<"$SOCKLOG")"
# a relaunch set that gave one pane up, deferred another and never got it back (stuck): the count, those two named with their reason
: > "$POSTS"; : > "$SOCKLOG"; F2="$FK-82"; FS="opposttest-$$"
mkfin "$F2" sala-test-h revive --only sala-test-q1 --only sala-test-q2 --only sala-test-q3 --only sala-test-q4 --only sala-test-q5 --force
printf '%s\n' kind=Revive label=opposttest done=3 total=5 "skip=sala-test-q1: busy, deferred" back=sala-test-q1 "gave=sala-test-q3: its pane is gone" "skip=sala-test-q3: its pane is gone" "skip=sala-test-q4: busy, deferred" out=sala-test-q4 > "$SALA_SET_DIR/$FS"
echo "set=$FS" >> "$OPS/$F2.op"; fin "$F2" stuck "Revive opposttest: 3/5 relaunched, 1 pane given up: sala-test-q3: its pane is gone"
P=$(post "sala op:"); has "$P" "🚨 *sala op: revive --force · stuck · 3/5 succeeded*" && has "$P" "sala-test-q3: its pane is gone" && has "$P" "sala-test-q4: busy, deferred" \
    && ! has "$P" "sala-test-q1" && ! has "$P" "sala-test-q2" && ! has "$P" "sala-test-q5" \
    && ok "some failed, some skipped: '3/5 succeeded', the given-up and the deferred pane each named with its reason, the rest not listed" || bad "partial post: $(<"$POSTS")"
waitfor "grep -q 'sala op $F2\]' '$SOCKLOG'" 30 && L=$(grep "sala op $F2\]" "$SOCKLOG") && has "$L" "salamander revive --force " && has "$L" "stuck (3/5 succeeded)" && has "$L" "sala-test-q4: busy, deferred" && ! has "$L" "sala-test-q2" \
    && ok "and the inbox line: the count and the two named" || bad "partial inbox: $(<"$SOCKLOG")"
rm -f "$SALA_SET_DIR/$FS"
# the lane fallback (sessions read off its RESULT lines): one NOT moved, one that stays; the default lane's line kept; queued by the watch (no inbox line)
: > "$POSTS"; F3="$FK-83"; mkfin "$F3" sala-watch lane fallback subscription-1
printf 'detail=%s\n' "sala-test-r1: subscription-1 → bedrock" "sala-test-r2: subscription-1 → bedrock (NOT moved: still recorded on subscription-1)" "sala-test-r3: stays on subscription-1 (managed outside sala)" "default lane: subscription-1 → bedrock" >> "$OPS/$F3.op"
fin "$F3" done "the subscription-1 lane is dormant: 2 sessions and the default moved to the bedrock lane"
P=$(post "sala op:"); has "$P" "✅ *sala op: lane fallback subscription-1 · done · 1/3 succeeded*" && has "$P" "sala-test-r2: subscription-1 → bedrock (NOT moved" && has "$P" "sala-test-r3: stays on subscription-1 (managed outside sala)" \
    && has "$P" "default lane: subscription-1 → bedrock" && ! has "$P" "sala-test-r1" && ok "the lane fallback: '1/3 succeeded', the one not moved and the one that stays named, the default lane's line kept" || bad "fallback post: $(<"$POSTS")"
# one session: named in the title as before, no count
: > "$POSTS"; : > "$SOCKLOG"; F4="$FK-84"; mkfin "$F4" sala-test-h lane subscription-1 sala-test-z1; fin "$F4" done "Lane subscription-1: 1/1 relaunched"
P=$(post "sala op:"); has "$P" "✅ *sala op: lane subscription-1 sala-test-z1 · done*" && ! has "$P" "1 session" && ! has "$P" "succeeded" && ok "one session: named in the title, no count" || bad "single post: $(<"$POSTS")"
waitfor "grep -q 'sala op $F4\]' '$SOCKLOG'" 30 && L=$(grep "sala op $F4\]" "$SOCKLOG") && has "$L" "salamander lane subscription-1 sala-test-z1 " && has "$L" " done: Lane" && ok "and its inbox line names it, as before" || bad "single inbox: $(<"$SOCKLOG")"
: > "$POSTS"; F5="$FK-85"; mkfin "$F5" sala-test-h model haiku sala-test-z2; echo "detail=sala-test-z2: switched in place to haiku" >> "$OPS/$F5.op"; fin "$F5" done "model batch: 1 session(s) → haiku: 1 switched in place"
P=$(post "sala op:"); has "$P" "✅ *sala op: model haiku sala-test-z2 · done*" && has "$P" "sala-test-z2: switched in place to haiku" && ok "a model batch of one: named, with its line, as before" || bad "batch of one post: $(<"$POSTS")"

echo "== the end of an operation is reported to stackshot: one client.py event per op (verb, machine, sessions, result), never changing the op"
# op_finish on hand-written markers, as above; the client is tests/fake-stackshot-client.py (it logs every call), the op log is SALA_OP_LOG
EVD="$HOME/evc"; mkdir -p "$EVD"; cp "$ROOT/tests/fake-stackshot-client.py" "$EVD/client.py"; chmod +x "$EVD/client.py"
export FAKE_CLIENT_DIR="$EVD" SALA_STACKSHOT_CLIENT="$EVD/client.py"; unset FAKE_CLIENT_FAIL FAKE_CLIENT_HANG
evn() { grep -c '"argv": \["event"' "$EVD/calls.jsonl" 2>/dev/null || echo 0; }   # → how many event calls the client has had
evlast() {  # → the last event call, one "--flag=value" per line
    python3 -I -c 'import json,sys
last=None
for l in open(sys.argv[1]):
    d=json.loads(l)
    if d["argv"][:1]==["event"]: last=d["argv"][1:]
for i in range(0,len(last or []),2): print("%s=%s" % (last[i], last[i+1]))' "$EVD/calls.jsonl"
}
evf() { evlast | sed -n "s/^--$1=//p"; }   # <flag> → the last event's value
finrc() { bash -c '. "$1/lib/common.sh"; . "$1/lib/op.sh"; op_finish "$2" "$3" "$4"' _ "$ROOT" "$@" >/dev/null 2>&1; echo $?; }   # <id> done|stuck <result> → op_finish's exit status
OPLOG="$SALA_LOG_DIR/salamander-op.log"; HN=$_SALA_HN; : > "$POSTS"; : > "$SOCKLOG"
# one session, done: sessions 1, ok, this box
E1="$FK-91"; n0=$(evn); mkfin "$E1" sala-test-h retire sala-test-z9; fin "$E1" done "retired sala-test-z9"
[ "$(( $(evn) - n0 ))" = 1 ] && [ "$(evf kind)" = fleet_op ] && [ "$(evf verb)" = retire ] && [ "$(evf machine)" = "$HN" ] && [ "$(evf sessions)" = 1 ] && [ "$(evf result)" = ok ] \
    && has "$(evf text)" "retire sala-test-z9" && has "$(evf text)" "retired sala-test-z9" && ! has "$(evf text)" "post test" \
    && ok "a retire of one session: ONE event, kind fleet_op, verb retire, this box, sessions 1, result ok, a one-line text (not the owner's words)" || bad "one-session event: $(evn) calls; $(evlast | paste -sd' ')"
grep -q "op $E1: reported to stackshot: fleet_op retire on $HN, 1 sessions, ok" "$OPLOG" && ok "and the op log says it was reported" || bad "reported line: $(tail -3 "$OPLOG")"
# the same op finishing twice (a second call on the same marker) reports once
n0=$(evn); fin "$E1" done "retired sala-test-z9"; [ "$(evn)" = "$n0" ] && ok "once per operation: a second op_finish on the same marker posts no second event" || bad "twice: $(evn) vs $n0"
# many sessions with one failure (a model batch): sessions 4, partial
E2="$FK-92"; n0=$(evn); mkfin "$E2" sala-test-h model haiku --effort high sala-test-e1 sala-test-e2 sala-test-e3 sala-test-e4
printf 'detail=%s\n' "sala-test-e1: switched in place to haiku/high" "sala-test-e2: switched in place to haiku/high" "sala-test-e3: FAILED: boom (exit 1)" "sala-test-e4: switched in place to haiku/high" >> "$OPS/$E2.op"
fin "$E2" stuck "model batch: 4 session(s) -> haiku/high: 3 switched in place, 1 FAILED (sala-test-e3)"
[ "$(( $(evn) - n0 ))" = 1 ] && [ "$(evf verb)" = model ] && [ "$(evf sessions)" = 4 ] && [ "$(evf result)" = partial ] \
    && ok "a 4-session batch with one failed: ONE event, sessions 4, result partial" || bad "partial event: $(evn) calls; $(evlast | paste -sd' ')"
# many sessions, every one through: sessions N, ok
E3="$FK-93"; n0=$(evn); mkfin "$E3" sala-test-h lane subscription-1 "${NN[@]}"; fin "$E3" done "Lane subscription-1: 17/17 relaunched"
[ "$(( $(evn) - n0 ))" = 1 ] && [ "$(evf verb)" = lane ] && [ "$(evf sessions)" = 17 ] && [ "$(evf result)" = ok ] && ok "17 sessions all through: sessions 17, ok" || bad "17 event: $(evlast | paste -sd' ')"
# many sessions, stuck with nothing per session to go on: failed
E4="$FK-94"; n0=$(evn); mkfin "$E4" sala-test-h lane subscription-1 sala-test-y1 sala-test-y2 sala-test-y3; fin "$E4" stuck "salamander lane exited 1: boom"
[ "$(( $(evn) - n0 ))" = 1 ] && [ "$(evf sessions)" = 3 ] && [ "$(evf result)" = failed ] && ok "3 sessions, stuck with none confirmed: sessions 3, result failed" || bad "none-confirmed event: $(evlast | paste -sd' ')"
# a failed op (one session): failed
E5="$FK-95"; n0=$(evn); mkfin "$E5" sala-test-h rename sala-test-w1 sala-test-w2; fin "$E5" stuck "rename exited 1: no such session"
[ "$(( $(evn) - n0 ))" = 1 ] && [ "$(evf verb)" = rename ] && [ "$(evf sessions)" = 1 ] && [ "$(evf result)" = failed ] && has "$(evf text)" "stuck" && ok "a stuck rename: sessions 1, result failed, the text says stuck" || bad "failed event: $(evlast | paste -sd' ')"
# a fleet-wide recycle: the relaunch set's total; done → ok, a pane given up → partial, all given up → failed
ES="opevent-$$"; E6="$FK-96"; n0=$(evn); mkfin "$E6" sala-test-h recycle --update --force
printf '%s\n' kind=Recycle label=opevent done=5 total=5 closed=1 > "$SALA_SET_DIR/$ES"; echo "set=$ES" >> "$OPS/$E6.op"; fin "$E6" done "Recycle opevent: 5/5 relaunched"
[ "$(( $(evn) - n0 ))" = 1 ] && [ "$(evf verb)" = recycle ] && [ "$(evf sessions)" = 5 ] && [ "$(evf result)" = ok ] && ok "a recycle of 5 panes, all relaunched: sessions 5 (the set's total), ok" || bad "recycle ok event: $(evlast | paste -sd' ')"
E7="$FK-97"; n0=$(evn); mkfin "$E7" sala-test-h recycle --update --force
printf '%s\n' kind=Recycle label=opevent done=4 total=5 closed=1 "gave=sala-test-q3: its pane is gone" "skip=sala-test-q3: its pane is gone" > "$SALA_SET_DIR/$ES"; echo "set=$ES" >> "$OPS/$E7.op"
fin "$E7" stuck "Recycle opevent: 4/5 relaunched, 1 pane given up"
[ "$(( $(evn) - n0 ))" = 1 ] && [ "$(evf sessions)" = 5 ] && [ "$(evf result)" = partial ] && ok "a recycle with one pane given up: sessions 5, partial" || bad "recycle partial event: $(evlast | paste -sd' ')"
rm -f "$SALA_SET_DIR/$ES"
# update naming one other host: that host is the machine; no set and no session: sessions 0
E8="$FK-98"; n0=$(evn); mkfin "$E8" sala-test-h update t-host-b; fin "$E8" done "t-host-b updated"
[ "$(( $(evn) - n0 ))" = 1 ] && [ "$(evf verb)" = update ] && [ "$(evf machine)" = t-host-b ] && [ "$(evf sessions)" = 0 ] && [ "$(evf result)" = ok ] && ok "update t-host-b: machine t-host-b, sessions 0, ok" || bad "update event: $(evlast | paste -sd' ')"
# a plan queues nothing and ends nothing: no event
n0=$(evn); enq --plan retire sala-test-d --from t --words x; [ "$(evn)" = "$n0" ] && ok "a plan (--plan) reports no event" || bad "plan event: $(evn) vs $n0"
# a failing client: the op ends the same (exit 0, state done, the Slack post and the inbox line made), the failure is in the op log
: > "$POSTS"; : > "$SOCKLOG"; E9="$FK-99"; mkfin "$E9" sala-test-h lane subscription-1 sala-test-z1
rc=$(FAKE_CLIENT_FAIL=1 finrc "$E9" done "Lane subscription-1: 1/1 relaunched")
[ "$rc" = 0 ] && [ "$(mval "$E9" state)" = done ] && [ -f "$DONE/$E9.op" ] && has "$(post 'sala op:')" "✅ *sala op: lane subscription-1 sala-test-z1 · done*" \
    && grep -q "op $E9: ⚠ the fleet_op event was not reported (client exit 1" "$OPLOG" \
    && ok "a client that exits 1: the op still ends done (exit 0), archived and posted; the failure is logged" || bad "failing client: rc=$rc state=$(mval "$E9" state) log: $(tail -2 "$OPLOG")"
waitfor "grep -q 'sala op $E9\]' '$SOCKLOG'" 30 && ok "and the hearing session still gets its inbox line" || bad "failing client inbox: $(<"$SOCKLOG")"
# a client that hangs: cut off at SALA_OP_EVENT_TIMEOUT, the op unaffected
EA="$FK-100"; mkfin "$EA" sala-test-h retire sala-test-z8; t0=$(date +%s)
rc=$(FAKE_CLIENT_HANG=30 SALA_OP_EVENT_TIMEOUT=1 finrc "$EA" stuck "retire exited 1: boom"); t1=$(date +%s)
[ "$rc" = 0 ] && [ "$(mval "$EA" state)" = stuck ] && [ "$(( t1 - t0 ))" -lt 15 ] && grep -q "op $EA: ⚠ the fleet_op event was not reported: stackshot's client did not answer within 1 s" "$OPLOG" \
    && ok "a client that hangs: cut off after the timeout ($(( t1 - t0 )) s here), the op ends stuck as it would, the timeout is logged" || bad "hanging client: rc=$rc state=$(mval "$EA" state) took $(( t1 - t0 )) s; log: $(tail -2 "$OPLOG")"
# no client on the box: nothing posted, the op fine, one line in the op log
n0=$(evn); EB="$FK-101"; mkfin "$EB" sala-test-h retire sala-test-z7
rc=$(SALA_STACKSHOT_CLIENT="" SALA_STACKSHOT_DIR="$HOME/no-such-stackshot" finrc "$EB" done "retired sala-test-z7")
[ "$rc" = 0 ] && [ "$(mval "$EB" state)" = done ] && [ "$(evn)" = "$n0" ] && grep -q "op $EB: no stackshot client.py on this box" "$OPLOG" \
    && ok "no client: no event, the op ends done, one line in the op log" || bad "no client: rc=$rc state=$(mval "$EB" state) events $(evn) vs $n0; log: $(tail -2 "$OPLOG")"
unset FAKE_CLIENT_DIR SALA_STACKSHOT_CLIENT; : > "$POSTS"

export SALA_OP_KICK_END=5   # the default, named so the stub's record is matched on it
echo "== the end of an operation kicks the queue: one watch --ops $SALA_OP_KICK_END s on, only while another is queued, for a done and a stuck op alike; the next starts after the end"
waitfor '[ "$(workers)" = 0 ]' 40; wait_lock; : > "$POSTS"
kicks() { grep -c -- "--on-active=$SALA_OP_KICK_END --unit=sala-op-kick-end .* watch --ops" "$LAUNCHES"; }   # → how many end-of-op kicks were requested
mkop() {  # <id> <verb> <arg>… — a queued marker written by hand (model --clear is a quick, harmless verb; retire with no argument fits no shape: stuck)
    local i="$1" v="$2" a; shift 2
    { printf 'id=%s\ntime=%s\nfrom=sala-test-h\nwords=kick test\nverb=%s\n' "$i" "${i%%-*}" "$v"; for a in "$@"; do printf 'arg=%s\n' "$a"; done; echo state=queued; } > "$OPS/$i.op"
}
runop() { SALA_CGROUP_FILE="$HOME/op-unit.cgroup" "$SALA" op --run "$1" >/dev/null 2>&1; }   # the unit's main process, run by hand once a tick started it (norun)
touch "$HOME/norun"; K0=$(( $(date +%s) + 100 ))
for mode in done stuck; do
    : > "$LAUNCHES"; K1="$K0-1"; K2="$((K0+1))-2"; K3="$((K0+2))-3"; K0=$((K0+10))
    if [ "$mode" = done ]; then mkop "$K1" model sala-test-a --clear; else mkop "$K1" retire; fi
    mkop "$K2" model sala-test-b --clear; mkop "$K3" model sala-test-zq-main --clear
    SALA_OP_STUCK=off tick; [ "$(mval "$K1" state)" = running ] && [ "$(kicks)" = 0 ] && ok "$mode: op 1 started by the tick; no kick yet" || bad "$mode start: $(mval "$K1" state) kicks=$(kicks) / $(<"$LAUNCHES")"
    SALA_OP_STUCK=off runop "$K1"; [ "$(mval "$K1" state)" = "$mode" ] && [ -f "$DONE/$K1.op" ] && ok "$mode: op 1 ended $mode and was archived" || bad "$mode end: $(cat "$OPS/$K1.op" "$DONE/$K1.op" 2>/dev/null)"
    [ "$(kicks)" = 1 ] && grep -q -- "--user --quiet --collect --on-active=$SALA_OP_KICK_END --unit=sala-op-kick-end " "$LAUNCHES" && ok "$mode: two queued behind it: the kick was requested once, not twice (finish and exit both ask)" || bad "$mode kicks: $(kicks) / $(<"$LAUNCHES")"
    [ "$(mval "$K2" state)" = queued ] && ok "$mode: op 2 waits for the kick (the tick), not started by the end itself" || bad "$mode op 2: $(mval "$K2" state)"
    tick; [ "$(mval "$K2" state)" = running ] && [ "$(mval "$K2" started)" -ge "$(mval "$K1" ended)" ] && ok "$mode: the tick the kick runs starts op 2, strictly after op 1 ended ($(mval "$K1" ended) <= $(mval "$K2" started))" || bad "$mode tick: $(cat "$OPS/$K2.op")"
    [ "$(mval "$K3" state)" = queued ] && ok "$mode: still one at a time (op 3 queued while op 2 runs)" || bad "$mode op 3: $(mval "$K3" state)"
    : > "$LAUNCHES"; runop "$K2"; [ "$(kicks)" = 1 ] && ok "$mode: op 2 ended with op 3 still queued: one more kick" || bad "$mode kick 2: $(kicks) / $(<"$LAUNCHES")"
    tick; : > "$LAUNCHES"; runop "$K3"
    [ "$(mval "$K3" state)" = done ] && [ "$(kicks)" = 0 ] && ! grep -q 'sala-op-kick-end' "$LAUNCHES" && [ "$(queued)" = 0 ] && ok "$mode: op 3 was the last: empty queue, no kick requested" || bad "$mode last: $(mval "$K3" state) $(mval "$K3" result) kicks=$(kicks) / $(<"$LAUNCHES")"
done
: > "$LAUNCHES"; K7="$((K0+5))-7"; mkop "$K7" retire; SALA_OP_STUCK=off tick; SALA_OP_STUCK=off runop "$K7"
[ "$(mval "$K7" state)" = stuck ] && ! grep -q 'sala-op-kick-end' "$LAUNCHES" && ok "a lone stuck op with nothing behind it: no kick" || bad "lone: $(mval "$K7" state) / $(<"$LAUNCHES")"
K8="$((K0+6))-8"; K9="$((K0+7))-9"; mkop "$K8" retire; mkop "$K9" model sala-test-a --clear; : > "$LAUNCHES"
SALA_OP_QUEUE=off SALA_OP_STUCK=off runop "$K8"; [ "$(kicks)" = 0 ] && ok "SALA_OP_QUEUE=off: an op that ends kicks nothing" || bad "queue off kick: $(<"$LAUNCHES")"
"$SALA" op --cancel "$K9" >/dev/null 2>&1; rm -f "$HOME/norun"

[ "$fail" = 0 ] && echo "op: pass" || echo "op: FAIL"
exit $fail
