#!/usr/bin/env bash
# The operation queue (lib/op.sh): fleet operations run by `watch`
# with no model, one at a time under the recycle lock, each as its own sala-op-<id> unit; a one-off `claude -p` only when
# one is stuck. What is checked guards a session or the fleet from a wrong operation, never the wording of a post: a verb
# that does not fit its shape, an unresolvable or busy target, or a marker without the owner's words is refused before anything
# is queued (a queued operation runs unattended, so the plan is the last look); `--auto` under a Claude process is refused
# (a relayed message is never the owner's words); reboot is queued with the owner's words only (one at a time, none with a broken hook, off with SALA_OP_REBOOT=off); a recycle about to start absorbs the
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
# the real unit does — the stub exports SALA_CGROUP_FILE naming a sala-op-<id> unit, since the guards refuse a
# Claude caller; `is-active` answers from a file), the claude -p is a stub (SALA_OP_CLAUDE: no suite ever calls
# the API), Slack is a file. Isolated HOME, a private tmux socket, the compiled fake claude; no real session, pane or unit
# is touched. The guards with no session special to them are tests/nomaster.sh's.
# Usage: bash tests/op.sh   (exit 0 = pass; ~90 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SET SALA_SET_SELF SALA_RECYCLE SALA_RETRY_WORKER SALA_LOCK_WHO SALA_LOCK_WAIT SALA_RELAUNCH_KIND \
      SALA_SESSION_URL SALA_FLEET_HOSTS SALA_CGROUP_FILE SALA_OP_QUEUE SALA_OP_REBOOT SALA_OP_STUCK SALA_REBOOT_HOOKS SALA_NO_RELAUNCH
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
LG=" · log ~/.claude/salamander-op-"   # what every operation post ends in (the asked-by line), with its id and ".log" after it
nops() { nposts "$LG"; }   # how many operation posts (each one ends in the asked-by and log line)
lines_in() { grep -c . <<< "$1"; }   # how many lines a post has
plain_post() {  # <post> → 0 when it carries none of what the old post carried: a raw argument, an exit code, a Details line, a queue stamp, the owner's words
    case "$1" in *"--force"*|*"--update"*|*"--only"*|*"exit "*|*"exited"*|*"Details:"*|*"queued at"*|*"nothing retries it: once"*|*Rowan*|*"post test"*) return 1;; esac; return 0; }

echo "== setup: four panes on the fake claude — the hearing session h (its inbox logged), a, b and d"
mk h "$(uuid 1)" -e FAKE_SOCK_LOG="$SOCKLOG"; mk a "$(uuid 2)"; mk b "$(uuid 3)"; mk d "$(uuid 4)"
fake_up sala-test-h sala-test-a sala-test-b sala-test-d || exit 1

echo "== the shape table: a verb or an argument it does not know is refused, nothing queued"
for args in "frob --from t --words x" "recycle --bogus --from t --words x" "rename only-one --from t --words x" "retire --from t --words x" \
            "lane nolane sala-test-a --from t --words x" "lane default --from t --words x" "update nohost --from t --words x" "update --fleet solo-x --from t --words x" \
            "provision --only 'bad step' --from t --words x" "reboot --go --from t --words x" "revive --only --from t --words x" "retire 'a b' --from t --words x" \
            "model --from t --words x" "model sala-test-a --from t --words x" "model sala-test-a gpt5 --from t --words x" "model sala-test-a 'claude-opus[1m]' --from t --words x" \
            "model sala-test-a opus --effort ultra --from t --words x" "model sala-test-a opus --effort --from t --words x" "model sala-test-a opus --effort low --effort high --from t --words x" \
            "model sala-test-a opus --record-only --from t --words x" "model sala-test-a opus --dry-run --from t --words x" "model sala-test-a opus --bogus --from t --words x" \
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

echo "== reboot: queued with the owner's words (reboot --go in the runner's own unit); refused with no words, with a reason only, with a blocker, while another is queued, and when switched off"
printf '#!/bin/bash\ncase "$1" in status) echo running;; *) echo ok;; esac\nexit 0\n' > "$HOME/rbhook"; chmod +x "$HOME/rbhook"
export SALA_REBOOT_HOOKS="t=$HOME/rbhook"
enq reboot --from t; [ "$RC" != 0 ] && has "$OUT" "no --words" && [ "$(queued)" = 0 ] && ok "reboot with no words: refused" || bad "reboot no words: rc=$RC — $OUT"
enq reboot --from t --why "the box needs a reboot now"; [ "$RC" != 0 ] && [ "$(queued)" = 0 ] && ok "reboot with a reason only: refused, nothing queued" || bad "reboot why: rc=$RC — $OUT"
enq --plan reboot; [ "$RC" = 0 ] && has "$OUT" "t: running" && has "$OUT" "plan only: nothing queued" && [ "$(queued)" = 0 ] && ok "--plan reboot: reboot --status shown, nothing queued" || bad "reboot plan: rc=$RC — $OUT"
enq reboot --from t --words "reboot t-host-a"
[ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(mval "$ID" verb)" = reboot ] && [ "$(mval "$ID" state)" = queued ] && [ "$(mval "$ID" words)" = "reboot t-host-a" ] && ok "reboot with words: queued, the words verbatim in the marker" || bad "reboot queued: rc=$RC — $OUT"
RB1=$ID
enq reboot --from t --words "reboot again"; [ "$RC" != 0 ] && has "$OUT" "one reboot at a time" && [ "$(queued)" = 1 ] && ok "a second reboot while one is queued: refused" || bad "second reboot: rc=$RC — $OUT"
"$SALA" op --cancel "$RB1" >/dev/null 2>&1; [ "$(mval "$RB1" state)" = cancelled ] && [ -f "$DONE/$RB1.op" ] && ok "cancelled: archived as cancelled" || bad "cancel: $(slurp "$DONE/$RB1.op")"
printf '#!/bin/bash\ncase "$1" in status) echo broken; exit 1;; *) echo ok;; esac\nexit 0\n' > "$HOME/rbhook"
enq reboot --from t --words "reboot t-host-a"; [ "$RC" != 0 ] && has "$OUT" "blocker" && [ "$(queued)" = 0 ] && ok "a broken hook in reboot --status: refused, nothing queued" || bad "reboot blocker: rc=$RC — $OUT"
SALA_OP_REBOOT=off enq reboot --from t --words "reboot t-host-a"; [ "$RC" != 0 ] && has "$OUT" "SALA_OP_REBOOT=off" && [ "$(queued)" = 0 ] && ok "SALA_OP_REBOOT=off: refused (the kill switch)" || bad "reboot off: rc=$RC — $OUT"
unset SALA_REBOOT_HOOKS

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
out=$("$SALA" op 2>&1); rc=$?; [ "$rc" = 2 ] && [ "$(wc -l <<< "$out")" = 1 ] && has "$out" "usage: sala op <verb>" && has "$out" "sala op --help" && ok "a bare op: one usage line, exit 2" || bad "bare op: rc=$rc $out"
out=$("$SALA" op --from t 2>&1); rc=$?; [ "$rc" = 2 ] && [ "$(wc -l <<< "$out")" = 1 ] && ok "flags with no verb: the same one line, exit 2" || bad "no verb: rc=$rc $out"
out=$("$SALA" op --help 2>&1); rc=$?; [ "$rc" = 0 ] && has "$out" "salamander op --list" && has "$out" "verbs: recycle" && has "$out" "sala op --help --full" && ! has "$out" "NO words" && [ "$(wc -c <<< "$out")" -lt 1500 ] && ok "op --help: the short help (forms, verbs, a pointer), none of the per-verb shapes" || bad "op --help short: rc=$rc $out"
out=$("$SALA" op --help --full 2>&1); rc=$?; [ "$rc" = 0 ] && has "$out" "NO words" && has "$out" "close-shell NAME" && ok "op --help --full: the whole usage and every verb's shape" || bad "op --help --full: rc=$rc"
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
( export TMUX_PANE="$PA"; claude_caller() { return 0; }; fleet_guard recycle --force ) >/dev/null 2>&1; [ $? != 0 ] && ok "a Claude session's pane: fleet_guard refuses (as before)" || bad "fleet_guard let a Claude session's pane through"
( export TMUX_PANE="$PA" SALA_CGROUP_FILE="$CG"; claude_caller() { return 0; }; fleet_guard recycle --force ) >/dev/null 2>&1 && ok "inside unit sala-op-<id>: fleet_guard admits it" || bad "fleet_guard refused the unit"
gout=$( export TMUX_PANE="$PA"; claude_caller() { return 0; }; fleet_guard reboot --go 2>&1 ); grc=$?
[ "$grc" != 0 ] && has "$gout" "sala op reboot --from" && has "$gout" "--words" && ok "a Claude session's raw reboot --go: fleet_guard refuses and names sala op reboot ... --words" || bad "reboot guard: rc=$grc — $gout"
( export TMUX_PANE="$PA" SALA_CGROUP_FILE="$CG"; claude_caller() { return 0; }; fleet_guard reboot --go ) >/dev/null 2>&1 && ok "inside unit sala-op-<id>: fleet_guard admits reboot --go" || bad "reboot guard refused the unit"
( export TMUX_PANE="$PA" SALA_CGROUP_FILE="$CG"; claude_caller() { return 0; }; ops_guard retire example-x ) >/dev/null 2>&1 && ok "inside unit sala-op-<id>: ops_guard admits it" || bad "ops_guard refused the unit"
echo "0::/user.slice/user-1000.slice/user@1000.service/app.slice/sala-auto-recycle-1760000000.service" > "$CG"
( export TMUX_PANE="$PA" SALA_CGROUP_FILE="$CG"; claude_caller() { return 0; }; fleet_guard recycle --force ) >/dev/null 2>&1; [ $? != 0 ] && ok "another unit's cgroup: refused" || bad "fleet_guard admitted a sala-auto-* unit"
echo "0::/user.slice/user-1000.slice/user@1000.service/app.slice/sala-op-kick-1760000000-1.service" > "$CG"
( export TMUX_PANE="$PA" SALA_CGROUP_FILE="$CG"; claude_caller() { return 0; }; fleet_guard recycle --force ) >/dev/null 2>&1; [ $? != 0 ] && ok "the kick unit's cgroup: refused" || bad "fleet_guard admitted the kick unit"

echo "== a recycle about to start absorbs the queued recycle and this box's update: one unit, the flags folded, the hearers told"
touch "$HOME/norun"; : > "$LAUNCHES"; : > "$POSTS"; rm -f "$HOME/helper-runs.txt"
enq recycle --from sala-test-h --words "recycle claude"; R1="$ID"; [ -n "$R1" ] || bad "recycle not queued: $OUT"
sleep 1; enq update --from sala-test-h --words "update claude"; U1="$ID"; [ -n "$U1" ] && has "$OUT" "claude update" && ok "update (this box) queued, its plan a note (no claude update run)" || bad "update: $OUT"
sleep 1; enq recycle --force --from x --words "force it"; R2="$ID"; [ -n "$R2" ] || bad "recycle --force not queued: $OUT"
"$SALA" watch >/dev/null 2>&1   # a plain tick: the queue runs all the same
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
    && has "$B" "SALA-OP: done" && has "$B" "SALA-OP: stuck" && has "$B" "Never stop a process" && ok "the brief: the operation, Rowan's words, what happened, what was tried, the verdict line contract" || bad "brief: $B"
P=$(post " · log ~/.claude/salamander-op-$R1.log"); [ -n "$P" ] && [ "$(lines_in "$P")" = 3 ] && [ "$(sed -n 1p <<< "$P")" = "🚨 *update and recycle on $_SALA_HN is stuck*" ] && [ "$(sed -n 2p <<< "$P")" = "The test helper does nothing." ] \
    && [ "$(sed -n 3p <<< "$P")" = "asked by sala-test-h · log ~/.claude/salamander-op-$R1.log" ] && plain_post "$P" && ! has "$P" "recycle claude" && ! has "$P" "folded in" && [ "$(nops)" = 1 ] \
    && ok "one 3-line post: the headline, the helper's one sentence, who asked and the log; no words, no argv, no folded-in list" || bad "post: $P"
waitfor "grep -q 'sala op $R1\] salamander recycle --update --force .*stuck: its runner' '$SOCKLOG'" 20 && ok "the hearing session (h) got the result in its inbox" || bad "sock log: $(<"$SOCKLOG")"
tick; [ "$(runs)" = 1 ] && [ "$(nops)" = 1 ] && ok "a later tick: nothing retries it, no second claude -p, no second post" || bad "retried: runs=$(runs) posts=$(nops)"

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
P=$(post " · log ~/.claude/salamander-op-$E.log"); [ "$P" = "✅ *recycled 4 sessions* · asked by sala-test-h · log ~/.claude/salamander-op-$E.log" ] && plain_post "$P" && [ "$(nops)" = 1 ] \
    && ok "one post, ONE line: done, the set's count of sessions, who asked, the log" || bad "post: $P / $(<"$POSTS")"
waitfor "grep -q 'sala op $E\] salamander recycle --force .*done: Recycle' '$SOCKLOG'" 20 && ok "h (relaunched meanwhile) got the result in its inbox" || bad "sock log: $(<"$SOCKLOG")"
L=$(grep "sala op $E\] salamander recycle --force .*done: Recycle" "$SOCKLOG" | head -1); has "$L" "queued at" && ! has "$L" "said at" && ! has "$P" "queued at" && ! has "$P" "said at" && ok "the done message stamps the quote as queued at, never said at (the marker's time is the queue time); the post carries no quote and no stamp" || bad "quote stamp: $L / $P"
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
B=$(<"$HOME/helper-brief.txt"); has "$B" "op $G" && has "$B" "revive --only sala-test-b --force" && has "$B" "\"bring b back\"" && has "$B" "its set $(mval "$G" set)" && has "$B" "given up: sala-test-b" && has "$B" "never type /feedback" && has "$B" "revive --only <session> --force --rescue" \
    && ok "the brief: the operation, the words, its set and what it gave up, the rescue allowed" || bad "brief: $B"
P=$(post " · log ~/.claude/salamander-op-$G.log"); [ -n "$P" ] && [ "$(sed -n 1p <<< "$P")" = "🚨 *revive of sala-test-b is stuck*" ] && has "$P" "• sala-test-b" && plain_post "$P" && [ "$(nops)" = 1 ] && ok "one post: stuck, the pane given up named with its reason" || bad "post: $P / $(<"$POSTS")"
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
P=$(post " · log ~/.claude/salamander-op-$V2.log"); [ "$P" = "✅ *retired sala-test-d* · asked by sala-test-h · log ~/.claude/salamander-op-$V2.log" ] && ok "one post, one line: done (the helper finished it; the log says how)" || bad "post: $P"
rm -f "$HOME/helper-act.sh" "$HOME/helper-verdict.txt"

echo "== two queued operations naming one session (markers written past the enqueue check): the first is stuck, neither runs, no claude -p with SALA_OP_STUCK=off"
: > "$POSTS"; rm -f "$HOME/helper-runs.txt"; now=$(date +%s)
C1="$now-1"; C2="$((now+1))-2"
printf 'id=%s\ntime=%s\nfrom=sala-test-h\nwords=retire a\nverb=retire\narg=sala-test-a\nstate=queued\n' "$C1" "$now" > "$OPS/$C1.op"
printf 'id=%s\ntime=%s\nfrom=x shell\nwords=bring a back\nverb=revive\narg=--only\narg=sala-test-a\narg=--force\nstate=queued\n' "$C2" "$((now+1))" > "$OPS/$C2.op"
SALA_OP_STUCK=off tick; waitfor "[ -f '$DONE/$C1.op' ]" 60
[ "$(mval "$C1" state)" = stuck ] && has "$(mval "$C1" result)" "conflicts with queued op $C2" && [ "$(mval "$C2" state)" = queued ] && tmux has-session -t =sala-test-a 2>/dev/null && [ "$(grep -c "^start $(uuid 2)" "$FAKE_LOG")" = 2 ] \
    && ok "the first stuck on the conflict, the second still queued, a untouched" || bad "conflict: $(cat "$DONE/$C1.op" "$OPS/$C2.op" 2>/dev/null)"
PC=$(post " · log ~/.claude/salamander-op-$C1.log"); [ "$(runs)" = 0 ] && [ -z "$(mval "$C1" helper)" ] && [ "$(sed -n 1p <<< "$PC")" = "🚨 *retire of sala-test-a is stuck*" ] && ! has "$PC" "one-off" && has "$PC" "nothing retries it" && plain_post "$PC" && ok "SALA_OP_STUCK=off: no claude -p; the post says nothing retries it (no helper line to tell who acts)" || bad "helper ran: $(slurp "$HOME/helper-runs.txt") / $PC"
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
# Fable only on the Ultra lane (common.sh, lane_runs_model): refused by the plan, at queue time, with the reason; the batch refuses the lot
lane_write sala-test-a bedrock
enq model sala-test-a fable --from t --words x; [ "$RC" = 1 ] && has "$OUT" "Fable runs only on the Ultra lane (subscription-1)" && has "$OUT" "sala-test-a is on the bedrock lane" && has "$OUT" "nothing queued" && [ "$(queued)" = 0 ] && ok "model <session> fable on bedrock: refused at queue time, the reason names the lane" || bad "fable bedrock: rc=$RC — $OUT"
enq --plan model sala-test-a fable; [ "$RC" = 1 ] && has "$OUT" "Fable runs only on the Ultra lane" && [ -z "$(mrow sala-test-a)" ] && ok "--plan shows the refusal; nothing recorded" || bad "plan fable bedrock: rc=$RC — $OUT"
enq model fable sala-test-a sala-test-h --from t --words x; [ "$RC" = 1 ] && has "$OUT" "sala-test-a: Fable runs only on the Ultra lane" && [ "$(queued)" = 0 ] && ok "the batch shape: one session off the Ultra lane refuses the whole batch" || bad "batch fable bedrock: rc=$RC — $OUT"
lane_write sala-test-a aws-platform
enq model sala-test-a claude-fable-5-1 --from t --words x; [ "$RC" = 1 ] && has "$OUT" "the aws-platform lane" && ok "a full Fable id on aws-platform: refused" || bad "fable aws: rc=$RC — $OUT"
lane_write sala-test-a subscription-1
enq --plan model sala-test-a fable; [ "$RC" = 0 ] && has "$OUT" "[dry-run] would record sala-test-a → fable" && [ "$(queued)" = 0 ] && ok "on subscription-1 the plan passes" || bad "plan fable ultra: rc=$RC — $OUT"
lane_drop sala-test-a
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
P=$(post " · log ~/.claude/salamander-op-$M5.log"); [ "$P" = "✅ *set sala-test-a to haiku* · asked by sala-test-h · log ~/.claude/salamander-op-$M5.log" ] && [ "$(nops)" = 1 ] && ok "one post, one line: done, who asked, no words" || bad "post: $P / $(<"$POSTS")"
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
P=$(post " · log ~/.claude/salamander-op-$MB.log"); [ "$(nops)" = 1 ] && [ "$P" = "✅ *set 3 sessions to haiku* · asked by sala-test-h · log ~/.claude/salamander-op-$MB.log" ] && ! has "$P" "sala-test-e" && ! has "$P" "sala-test-f" && ! has "$P" "sala-test-g" \
    && ok "ONE Slack post for the three, ONE line: done, a count of the sessions (none named), who asked" || bad "batch post: $(nops) posts — $(<"$POSTS")"
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
[ "$(mval "$MD" state)" = done ] && [ -z "$(mrow sala-test-f)" ] && [ -z "$(mrow sala-test-g)" ] && [ "$(mvals "$MD" detail | wc -l)" = 2 ] && [ "$(nops)" = 1 ] && ok "--clear <session>… through the queue: both rows dropped, one operation, one post" || bad "batch clear: $(slurp "$DONE/$MD.op") / rows '$(mrow sala-test-f)' '$(mrow sala-test-g)' posts $(nops)"
waitfor "[ \"\$(grep -c \"sala op $MD\\]\" \"$SOCKLOG\")\" = 1 ]" 30 && L=$(grep "sala op $MD\]" "$SOCKLOG") && has "$L" "salamander model --clear " && has "$L" "done (2 sessions)" && ! has "$L" "sala-test-f" && ! has "$L" "sala-test-g" && ok "and one inbox notice: the count, no session named" || bad "batch clear notice: $(<"$SOCKLOG")"
# a session that fails: a stand-in model.sh (a copy of the entry point whose lib/model.sh prints what a batch with a failure prints and exits 1)
BSTUB="$HOME/batchstub"; mkdir -p "$BSTUB/bin" "$BSTUB/lib"; cp "$ROOT/bin/salamander" "$BSTUB/bin/salamander"
for f in "$ROOT"/lib/*; do ln -s "$f" "$BSTUB/lib/$(basename "$f")"; done; ln -s "$ROOT/mod" "$BSTUB/mod"; rm -f "$BSTUB/lib/model.sh"
printf '%s\n' 'echo "RESULT sala-test-e: switched in place to haiku/high"' 'echo "RESULT sala-test-f: FAILED: boom (exit 1)"' 'echo "model batch: 2 session(s) → haiku/high: 1 switched in place, 1 FAILED (sala-test-f)"' 'exit 1' > "$BSTUB/lib/model.sh"
MF="$(( $(date +%s) + 500 ))-77"; { printf 'id=%s\ntime=%s\nfrom=sala-test-h\nwords=partial test\nverb=model\n' "$MF" "${MF%%-*}"; printf 'arg=%s\n' haiku --effort high sala-test-e sala-test-f; echo state=queued; } > "$OPS/$MF.op"
: > "$POSTS"; : > "$SOCKLOG"; rm -f "$HOME/helper-runs.txt"
SALA_CGROUP_FILE="$HOME/op-unit.cgroup" "$BSTUB/bin/salamander" op --run "$MF" >/dev/null 2>&1
[ "$(mval "$MF" state)" = stuck ] && has "$(mval "$MF" result)" "1 FAILED (sala-test-f)" && [ "$(mvals "$MF" detail | wc -l)" = 2 ] && [ "$(runs)" = 0 ] && ok "a batch with a failed session: stuck, the failure named in the result, a line per session, no claude -p" || bad "batch failure: $(slurp "$DONE/$MF.op") / helper runs $(runs)"
P=$(post " · log ~/.claude/salamander-op-$MF.log"); [ "$(nops)" = 1 ] && [ "$(sed -n 1p <<< "$P")" = "🚨 *set 1 of 2 sessions to haiku*" ] && [ "$(sed -n 2p <<< "$P")" = "• sala-test-f: failed: boom" ] && ! has "$P" "sala-test-e:" && [ "$(lines_in "$P")" = 3 ] && plain_post "$P" \
    && ok "one 🚨 post: the count, the failed session named with its reason (no exit code), the one that stood not listed" || bad "batch failure post: $(<"$POSTS")"
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
P=$(post " · log ~/.claude/salamander-op-$F1.log"); [ "$(nops)" = 1 ] && [ "$P" = "✅ *moved 17 sessions to subscription-1* · asked by sala-test-h · log ~/.claude/salamander-op-$F1.log" ] && ! has "$P" "sala-test-n" && plain_post "$P" \
    && ok "17 sessions, all through: ONE line, the count in the headline, none named" || bad "17 post: $(<"$POSTS")"
waitfor "grep -q 'sala op $F1\]' '$SOCKLOG'" 30 && L=$(grep "sala op $F1\]" "$SOCKLOG") && has "$L" "salamander lane subscription-1 " && has "$L" "done (17 sessions): Lane subscription-1: 17/17 relaunched" && ! has "$L" "sala-test-n" \
    && ok "and the inbox line: the count, no session named" || bad "17 inbox: $(<"$SOCKLOG")"
# a relaunch set that gave one pane up, deferred another and never got it back (stuck): the count, those two named with their reason
: > "$POSTS"; : > "$SOCKLOG"; F2="$FK-82"; FS="opposttest-$$"
mkfin "$F2" sala-test-h revive --only sala-test-q1 --only sala-test-q2 --only sala-test-q3 --only sala-test-q4 --only sala-test-q5 --force
printf '%s\n' kind=Revive label=opposttest done=3 total=5 "skip=sala-test-q1: busy, deferred" back=sala-test-q1 "gave=sala-test-q3: its pane is gone" "skip=sala-test-q3: its pane is gone" "skip=sala-test-q4: busy, deferred" out=sala-test-q4 > "$SALA_SET_DIR/$FS"
echo "set=$FS" >> "$OPS/$F2.op"; fin "$F2" stuck "Revive opposttest: 3/5 relaunched, 1 pane given up: sala-test-q3: its pane is gone"
P=$(post " · log ~/.claude/salamander-op-$F2.log"); [ "$(lines_in "$P")" = 4 ] && [ "$(sed -n 1p <<< "$P")" = "🚨 *revived 3 of 5 sessions*" ] && [ "$(sed -n 2p <<< "$P")" = "• sala-test-q3: its pane is gone" ] && [ "$(sed -n 3p <<< "$P")" = "• sala-test-q4: busy, deferred" ] \
    && [ "$(sed -n 4p <<< "$P")" = "asked by sala-test-h · log ~/.claude/salamander-op-$F2.log" ] && plain_post "$P" \
    && ok "some failed, some skipped: '3 of 5', the given-up and the deferred pane each named with its reason, the rest not listed" || bad "partial post: $(<"$POSTS")"
waitfor "grep -q 'sala op $F2\]' '$SOCKLOG'" 30 && L=$(grep "sala op $F2\]" "$SOCKLOG") && has "$L" "salamander revive --force " && has "$L" "stuck (3/5 succeeded)" && has "$L" "sala-test-q4: busy, deferred" && ! has "$L" "sala-test-q2" \
    && ok "and the inbox line: the count and the two named" || bad "partial inbox: $(<"$SOCKLOG")"
rm -f "$SALA_SET_DIR/$FS"
# the lane fallback (sessions read off its RESULT lines): one NOT moved, one that stays; the default lane's line kept; queued by the watch (no inbox line)
: > "$POSTS"; F3="$FK-83"; mkfin "$F3" sala-watch lane fallback subscription-1
printf 'detail=%s\n' "sala-test-r1: subscription-1 → bedrock" "sala-test-r2: subscription-1 → bedrock (NOT moved: still recorded on subscription-1)" "sala-test-r3: stays on subscription-1 (managed outside sala)" "default lane: subscription-1 → bedrock" >> "$OPS/$F3.op"
fin "$F3" done "the subscription-1 lane is dormant: 2 sessions and the default moved to the bedrock lane"
P=$(post " · log ~/.claude/salamander-op-$F3.log"); [ "$(sed -n 1p <<< "$P")" = "⚠️ *moved 1 of 3 sessions off the dormant lane subscription-1*" ] && has "$P" "• sala-test-r2: subscription-1 → bedrock (NOT moved" && has "$P" "• sala-test-r3: stays on subscription-1 (managed outside sala)" \
    && has "$P" "• default lane: subscription-1 → bedrock" && ! has "$P" "sala-test-r1" && has "$P" "asked by sala-watch" && plain_post "$P" && ok "the lane fallback: '1 of 3', the one not moved and the one that stays named, the default lane's line kept" || bad "fallback post: $(<"$POSTS")"
# a lane fallback names why the lane is dormant on ONE line under the headline: a monthly cap with the day access returns (the verb's own last line), another cause with no day (the lane's own record), none when nothing says why
: > "$POSTS"; F3A="$FK-83a"; mkfin "$F3A" sala-watch lane fallback subscription-2
printf 'detail=%s\n' "sala-test-r1: subscription-2 → bedrock" "sala-test-r2: subscription-2 → bedrock" "default lane: subscription-2 → bedrock" >> "$OPS/$F3A.op"
fin "$F3A" done "the Team lane is dormant (monthly usage cap, access returns Tue Dec 1st 09:00): 2 sessions and the default moved to the bedrock lane"
P=$(post " · log ~/.claude/salamander-op-$F3A.log"); [ "$(lines_in "$P")" = 4 ] && [ "$(sed -n 1p <<< "$P")" = "✅ *moved 2 sessions off the dormant lane subscription-2*" ] && [ "$(sed -n 2p <<< "$P")" = "• reason: monthly usage cap; access returns Tue Dec 1st 09:00" ] && [ "$(sed -n 3p <<< "$P")" = "• default lane: subscription-2 → bedrock" ] && [ "$(sed -n 4p <<< "$P")" = "asked by sala-watch · log ~/.claude/salamander-op-$F3A.log" ] && plain_post "$P" \
    && ok "a capped lane: the headline, ONE reason line (the cap and the day access returns), the default lane's line, who asked and the log" || bad "capped fallback post: $P"
: > "$POSTS"; "$SALA" lane dormant subscription-2 --no-fallback --reason "no seat" >/dev/null 2>&1; F3B="$FK-83b"; mkfin "$F3B" sala-watch lane fallback subscription-2
printf 'detail=%s\n' "sala-test-r1: subscription-2 → bedrock" "sala-test-r2: subscription-2 → bedrock" >> "$OPS/$F3B.op"
fin "$F3B" done "the Team lane is dormant: 2 sessions moved to the bedrock lane"
P=$(post " · log ~/.claude/salamander-op-$F3B.log"); [ "$(lines_in "$P")" = 3 ] && [ "$(sed -n 2p <<< "$P")" = "• reason: no seat" ] && ! has "$P" "access returns" && plain_post "$P" && ok "another cause: one plain phrase for it, no day" || bad "other-cause fallback post: $P"
"$SALA" lane active subscription-2 >/dev/null 2>&1
: > "$POSTS"; F3C="$FK-83c"; mkfin "$F3C" sala-watch lane fallback subscription-2
printf 'detail=%s\n' "sala-test-r1: subscription-2 → bedrock" "sala-test-r2: subscription-2 → bedrock" >> "$OPS/$F3C.op"
fin "$F3C" done "the Team lane is dormant: 2 sessions moved to the bedrock lane"
P=$(post " · log ~/.claude/salamander-op-$F3C.log"); [ "$P" = "✅ *moved 2 sessions off the dormant lane subscription-2* · asked by sala-watch · log ~/.claude/salamander-op-$F3C.log" ] && ok "no cause on record: no reason line, the finished post stays ONE line" || bad "no-cause fallback post: $P"
# one session: named in the title as before, no count
: > "$POSTS"; : > "$SOCKLOG"; F4="$FK-84"; mkfin "$F4" sala-test-h lane subscription-1 sala-test-z1; fin "$F4" done "Lane subscription-1: 1/1 relaunched"
P=$(post " · log ~/.claude/salamander-op-$F4.log"); [ "$P" = "✅ *moved sala-test-z1 to subscription-1* · asked by sala-test-h · log ~/.claude/salamander-op-$F4.log" ] && ok "one session: named in the headline, no count, one line" || bad "single post: $(<"$POSTS")"
waitfor "grep -q 'sala op $F4\]' '$SOCKLOG'" 30 && L=$(grep "sala op $F4\]" "$SOCKLOG") && has "$L" "salamander lane subscription-1 sala-test-z1 " && has "$L" " done: Lane" && ok "and its inbox line names it, as before" || bad "single inbox: $(<"$SOCKLOG")"
: > "$POSTS"; F5="$FK-85"; mkfin "$F5" sala-test-h model haiku sala-test-z2; echo "detail=sala-test-z2: switched in place to haiku" >> "$OPS/$F5.op"; fin "$F5" done "model batch: 1 session(s) → haiku: 1 switched in place"
P=$(post " · log ~/.claude/salamander-op-$F5.log"); [ "$P" = "✅ *set sala-test-z2 to haiku* · asked by sala-test-h · log ~/.claude/salamander-op-$F5.log" ] && ok "a model batch of one: named, one line" || bad "batch of one post: $(<"$POSTS")"

echo "== the post's shapes: a stuck op with its step, without one, with no helper line, cut to one plain sentence; a long failure list capped; nothing of the old post"
sid() { echo "$FK-$1"; }   # a fresh marker id per case
stuckwhy() { echo "stuckwhy=$2" >> "$OPS/$1.op"; }   # <id> <the helper's one line>: what op_helper leaves on the marker
# stuck, a step named in the verb's output: the headline carries it, then the helper's one sentence, then who asked and the log
: > "$POSTS"; S1=$(sid 201); mkfin "$S1" sala-test-h provision demo-host; printf '%s\n' "  demo-host: provisioned — sala: ❌ demo-step: a check that cannot pass · 4 steps ok" > "$SALA_LOG_DIR/salamander-op-$S1.out"
stuckwhy "$S1" "Its check expects a timer that only runs on another machine, so a rerun can't pass; the check needs a fix."
fin "$S1" stuck "salamander provision demo-host exited 1: demo-host: provisioned — sala: ❌ demo-step: a check that cannot pass (no claude -p: the check needs a fix)"
P=$(post "$LG$S1.log"); [ "$(lines_in "$P")" = 3 ] && [ "$(sed -n 1p <<< "$P")" = "🚨 *provision on demo-host is stuck* (step demo-step)" ] && [ "$(sed -n 2p <<< "$P")" = "Its check expects a timer that only runs on another machine, so a rerun can't pass; the check needs a fix." ] \
    && [ "$(sed -n 3p <<< "$P")" = "asked by sala-test-h · log ~/.claude/salamander-op-$S1.log" ] && plain_post "$P" && ok "stuck with a step: the headline names it, ONE sentence why, who asked and the log" || { bad "stuck with step: $P"; }
echo "   rendered:"; sed 's/^/      | /' <<< "$P"
# stuck, no step in the output; the helper's line carries an exit code, a path, a backtick command and a second sentence: one plain sentence is left
: > "$POSTS"; S2=$(sid 202); mkfin "$S2" sala-test-h retire sala-test-zz; stuckwhy "$S2" "the one-off helper found \`salamander retire sala-test-zz\` held by another run (exit 1) and logged it in ~/.claude/x/run.log. A second sentence, which stays out."
fin "$S2" stuck "salamander retire sala-test-zz exited 1: held — the one-off claude -p could not finish it: held"
P=$(post "$LG$S2.log"); [ "$(lines_in "$P")" = 3 ] && [ "$(sed -n 1p <<< "$P")" = "🚨 *retire of sala-test-zz is stuck*" ] && has "$(sed -n 2p <<< "$P")" "The one-off helper found held by another run" && ! has "$P" "salamander retire" && ! has "$P" "sala-test-zz held" && ! has "$P" "exit" && ! has "$P" "run.log" && ! has "$P" "A second sentence" && ! has "$P" '`' && ! has "$P" "(step" && plain_post "$P" \
    && ok "stuck without a step: no step in the headline; the helper's line cut to its first sentence, no exit code, no path, and the backtick-enclosed command gone whole" || bad "stuck without step: $P"
# the stuck helper's line missing (no helper ran, or it gave no verdict): the fixed sentence, which says nothing retries it and a person finishes it
: > "$POSTS"; S3=$(sid 203); mkfin "$S3" sala-test-h rename sala-test-zz sala-test-zy
fin "$S3" stuck "no tmux session 'sala-test-zz' (exit 1)"
P=$(post "$LG$S3.log"); [ "$(lines_in "$P")" = 3 ] && [ "$(sed -n 1p <<< "$P")" = "🚨 *rename of sala-test-zz is stuck*" ] && [ "$(sed -n 2p <<< "$P")" = "It did not finish, and nothing retries it: finish it by hand or ask again." ] && plain_post "$P" && ! has "$P" "no tmux session" \
    && ok "no helper line: the fixed sentence (nothing retries it, a person finishes it); the raw failure stays in the log" || bad "no helper line: $P"
# many sessions, failures: five lines at most, then "and N more"
: > "$POSTS"; S5=$(sid 205); MM=(); for k in 1 2 3 4 5 6 7 8 9; do MM+=("sala-test-m$k"); done
mkfin "$S5" sala-test-h lane subscription-1 "${MM[@]}"
for k in 1 2 3 4 5 6 7; do echo "detail=sala-test-m$k: FAILED: no pane (exit 1)" >> "$OPS/$S5.op"; done; for k in 8 9; do echo "detail=sala-test-m$k: subscription-1" >> "$OPS/$S5.op"; done
fin "$S5" stuck "lane: 7 sessions FAILED"
P=$(post "$LG$S5.log"); [ "$(lines_in "$P")" = 8 ] && [ "$(sed -n 1p <<< "$P")" = "🚨 *moved 2 of 9 sessions to subscription-1*" ] && [ "$(sed -n 2p <<< "$P")" = "• sala-test-m1: failed: no pane" ] && [ "$(sed -n 6p <<< "$P")" = "• sala-test-m5: failed: no pane" ] \
    && [ "$(sed -n 7p <<< "$P")" = "and 2 more" ] && [ "$(sed -n 8p <<< "$P")" = "asked by sala-test-h · log ~/.claude/salamander-op-$S5.log" ] && ! has "$P" "sala-test-m6" && ! has "$P" "sala-test-m8" && plain_post "$P" \
    && ok "7 of 9 failed: the count in the headline, five sessions named, 'and 2 more', no exit code, the ones that went through not listed" || bad "capped post: $P"
# exactly five failures: no "and N more"
: > "$POSTS"; S6=$(sid 206); mkfin "$S6" sala-test-h lane subscription-1 "${MM[@]:0:6}"
for k in 1 2 3 4 5; do echo "detail=sala-test-m$k: FAILED: no pane" >> "$OPS/$S6.op"; done
fin "$S6" stuck "lane: 5 sessions FAILED"
P=$(post "$LG$S6.log"); [ "$(lines_in "$P")" = 7 ] && ! has "$P" "more" && ok "five failures: all named, no 'and N more'" || bad "five post: $P"
# every session through: one line; (the recycle's own set and the 17-session case above are the other counts)
: > "$POSTS"; S7=$(sid 207); mkfin "$S7" sala-test-h model haiku "${MM[@]:0:4}"; fin "$S7" done "model batch: 4 session(s) → haiku: 4 switched in place"
P=$(post "$LG$S7.log"); [ "$P" = "✅ *set 4 sessions to haiku* · asked by sala-test-h · log ~/.claude/salamander-op-$S7.log" ] && ok "many sessions, all done: ONE line with the count" || bad "all done: $P"
# a stuck operation with the helper's verdict: the whole post is read as a phone would, and none of the old post's parts are in it
: > "$POSTS"; S8=$(sid 208); mkfin "$S8" sala-test-h update demo-a demo-b; stuckwhy "$S8" "Demo-b is offline, so it needs a person to start it."
fin "$S8" stuck "salamander update demo-a demo-b exited 1: demo-b: offline"
P=$(post "$LG$S8.log"); [ "$(sed -n 1p <<< "$P")" = "🚨 *update on 2 machines is stuck*" ] && [ "$(sed -n 2p <<< "$P")" = "Demo-b is offline, so it needs a person to start it." ] && plain_post "$P" && ! has "$P" "board item" && ! has "$P" "folded in" && ! has "$P" "reason:" \
    && ok "an update over two boxes: the count of machines, the helper's sentence; no words, no board item, no folded-in list" || bad "update post: $P"

echo "== the plain sentence's filter: no path of any depth (/tmp, ~/file, ~/a/b, /etc/hosts), no backtick-enclosed span, the first sentence only; plain slashes in the text stay"
plain() { bash -c '. "$1/lib/common.sh"; . "$1/lib/op.sh"; op_plain "$2"' _ "$ROOT" "$1"; }   # <text> → op_plain's one sentence
for pc in "it could not write to /tmp and stopped|it could not write to and stopped" \
          "it could not read ~/settings.json and stopped|it could not read and stopped" \
          "the unit file /etc/hosts was changed|the unit file was changed" \
          "the copy in ~/a/b/c.log failed|the copy in failed" \
          "the copy (/etc) failed|the copy failed" \
          "it ran \`rm -rf demo-dir\` and failed|it ran and failed" \
          "it ran \`salamander lane x. y\` and failed. A second sentence.|it ran and failed." \
          "3/5 sessions and a/b stay put|3/5 sessions and a/b stay put" \
          "it failed (exit 1) at /tmp.|it failed at" \
          "it ran \`\`salamander retire x\`\` and failed|it ran and failed" \
          "it ran \`\`\`x\`\`\` and failed|it ran and failed" \
          "it ran \`a\`\`b\` and failed|it ran and failed" \
          "it ran \`\`x. and failed|it ran" \
          "it could not read \"/tmp\" at all|it could not read at all" \
          "it could not read '/tmp' at all|it could not read at all" \
          "it failed on file=/tmp today|it failed on today" \
          "it failed on key:/etc/x today|it failed on today" \
          "it failed (path=/var/log) today|it failed today" \
          "it failed [/var/log] today|it failed today" \
          "it failed on <~/f> today|it failed on today" \
          "see https://host/x and http://h:80/y.|see https://host/x and http://h:80/y." \
          "the timer runs at 04:00 and 14:30|the timer runs at 04:00 and 14:30" \
          "it failed at file:/tmp and https://h/p?q=a:b|it failed at and https://h/p?q=a:b" \
          "it could not read \"/tmp/customer records.csv\" at all|it could not read at all" \
          "it could not read '/tmp/customer records.csv' at all|it could not read at all" \
          "it wrote \"/tmp/a b. c.csv\" today and stopped|it wrote today and stopped" \
          "it set file=/ and path:~/ and dir=./ today|it set and and today" \
          "it failed on /tmp/customer]records.csv today|it failed on today" \
          "it failed on [/tmp/a] and (path=/var/log/x) today|it failed on and today" \
          "retry() returned [] and [3] today|retry() returned [] and [3] today" \
          "it read \"/tmp/customer\\\" records.csv\" today|it read today" \
          "it read '/tmp/a\\' b.csv' today|it read today" \
          "it failed on [/tmp/customer]records.csv] today|it failed on today" \
          "it failed on (/tmp/a]b) and [~/x]y] today|it failed on and today" \
          "ok (see [/tmp/a]) now|ok (see ) now" \
          "[/tmp/a][3] now|[3] now" \
          "(see (/tmp/a)) end|(see ) end" \
          "a [/tmp/a],[b] c|a,[b] c" \
          "[x][/tmp/a][y] z|[x][y] z" \
          "(a (b [/tmp/c]) d) e|(a (b ) d) e" \
          "it set [path=/x/y][2] ok|it set [2] ok" \
          "[/tmp/a] [/tmp/b][4] z|[4] z" \
          "[[/tmp/a]] z|[] z" \
          "it set file=/ dir=./ path:~/ today|it set today" \
          "it set a:~/ b:./ c:~/ d:~/ today|it set today" \
          "it saw file=//srv/share today|it saw today" \
          "it saw key://srv/x and https://h/x today|it saw key://srv/x and https://h/x today" \
          "[path:/][3] now|[3] now" \
          "(see [path:/]) end|(see ) end" \
          "ok [/tmp/customer]@records.csv] today|ok today" \
          "ok [/tmp/customer]+x.csv] today|ok today" \
          "ok [path:/tmp/a]@b] now|ok now" \
          "ok [/tmp/a)] now|ok now" \
          "read /tmp/a[1] now|read now" \
          "read [/tmp/a[1]] now|read now" \
          "read (/tmp/a(1)) x|read x" \
          "see /tmp/a) now|see now" \
          "see /tmp/a))) ok|see ok" \
          "set file=\"/tmp/a b\" now|set now" \
          "set file='/tmp/a b' now|set now" \
          "set path:\"/tmp/a b\" now|set now" \
          "read (file=\"/tmp/a b\"), ok|read, ok" \
          "ok (/tmp/a] now|ok ( now" \
          "list [/tmp/a]and[/tmp/b] z|list [ z" \
          "[/tmp/a]s ok|[ ok" \
          "[/tmp/a]/tmp/b ok|[ ok" \
          "read \"/tmp/a now|read \" now" \
          "read '/tmp/a now|read ' now" \
          "read [/tmp/a now|read [ now" \
          "read (/tmp/a|read (" \
          "read /tmp/a|read" \
          "read /|read" \
          "read /tmp/my\\ file.txt now|read now" \
          "read /tmp/a, then stop|read then stop" \
          "read /tmp/a. Next sentence|read" \
          "x [/tmp/a]. y|x." \
          "read /tmp/a /tmp/b now|read now" \
          "read \"/tmp/a\" \"/tmp/b c\" now|read now" \
          "read [\"/tmp/a b\"] now|read now" \
          "x [file=\"/tmp/a b\"] y|x y" \
          "mixed (\"/tmp/a b\") ok|mixed ok" \
          "x [ \"/tmp/a b\" ] y|x [ ] y" \
          "x [\"/tmp/a b\"]z y|x z y" \
          "read [[/tmp/a]] z|read [] z" \
          "(a (b [/tmp/c]) d) e|(a (b ) d) e" \
          "[x][/tmp/a][y] z|[x][y] z" \
          "a:~/f b:./g c:../h now|now" \
          "see ../up and ./here and ~/home now|see and and now" \
          "and/or a/b c/d now|and/or a/b c/d now" \
          "see <file:///tmp/x> now|see <file:///tmp/x> now" \
          "read \"/tmp/a\\\" b\" ok|read ok" \
          "read it's /tmp/a and 'x' ok|read it's and 'x' ok" \
          "日本語 /tmp/a 日本語 now|日本語 日本語 now"; do
    pin=${pc%%|*}; pwant=${pc#*|}; pgot=$(plain "$pin")
    [ "$pgot" = "$pwant" ] && ok "plain: '$pin' → '$pgot'" || bad "plain: '$pin' → '$pgot' (wanted '$pwant')"
done
pgot=$(plain "a \`one span\` here and a lone \` tick"); [ "$pgot" = "a here and a lone" ] && ok "plain: an unpaired tick drops the rest of the text, a span goes whole" || bad "plain, ticks: '$pgot'"
# the pass over a long line is linear: 200000 characters in one token, in the shapes that made a path rule scan back (a quote or a bracket opened and never closed,
# a run of openers, a run of backtick runs), each in a bounded wait, each ending with the path gone and the text before it kept
longrep() { local o=$1 k=$2; while [ ${#o} -lt "$k" ]; do o=$o$o; done; printf '%s' "${o:0:$k}"; }   # <unit> <chars> → the unit repeated to that many characters
longtest() {  # <label> <text> <wanted prefix of the answer>
    local t0 t1 r rc; t0=$SECONDS; r=$(timeout 60 bash -c '. "$1/lib/common.sh"; . "$1/lib/op.sh"; read -r x < "$2"; op_plain "$x"' _ "$ROOT" "$HOME/long.in"); rc=$?; t1=$SECONDS
    [ "$rc" = 0 ] && [ $((t1 - t0)) -lt 40 ] && [ "${r:0:${#3}}" = "$3" ] && ok "plain, $1: done in $((t1 - t0)) s, '${r:0:20}'" || bad "plain, $1: rc=$rc after $((t1 - t0)) s, '${r:0:40}'"
}
LA=$(longrep a 200000)
for lc in "a 200000-character path|read /$LA now|read now" "an unclosed double quote 100000 times|read $(longrep '"/' 200000)|" \
          "100000 openers each with a slash|read $(longrep '[/' 200000)|read [" \
          "50000 backtick runs|read $(longrep '``a`' 200000)|read" "200000 non-ASCII characters and then a path|$(longrep '日' 200000) /tmp/a now|日日日"; do
    IFS='|' read -r ll lt lw <<< "$lc"
    printf '%s\n' "$lt" > "$HOME/long.in"; longtest "$ll" "$lt" "$lw"
done
rm -f "$HOME/long.in"
# a step of the filter failing (awk or sed missing, or a helper that returns an error): one fixed sentence, never the text (it holds a path and a command here) and never nothing
SECRET='failed reading /tmp/secret/x.txt with `cmd --token abc` now'; FIXED="the reason is not shown here: see the log"
FBA=$HOME/failawk; FBS=$HOME/failsed; mkdir -p "$FBA" "$FBS"
printf '#!/bin/sh\nexit 127\n' > "$FBA/awk"; printf '#!/bin/sh\nexit 127\n' > "$FBS/sed"; chmod +x "$FBA/awk" "$FBS/sed"
for fc in "the tick filter (op_drop_ticks) failing|op_drop_ticks() { return 1; }" "the path filter (op_drop_paths) failing|op_drop_paths() { return 1; }" \
          "awk missing from the PATH|PATH=$FBA:\$PATH" "sed missing from the PATH|PATH=$FBS:\$PATH"; do
    fl=${fc%%|*}; fcode=${fc#*|}
    pgot=$(bash -c '. "$1/lib/common.sh"; . "$1/lib/op.sh"; eval "$3"; hash -r; op_plain "$2"' _ "$ROOT" "$SECRET" "$fcode")
    [ "$pgot" = "$FIXED" ] && ok "plain, $fl: the fixed sentence, no path and no command in it" || bad "plain, $fl: '$pgot'"
done
rm -rf "$FBA" "$FBS"
# the path pass itself failing without an error: no program at all (awk "" exits 0 and prints nothing), or a program that prints nothing: the fixed sentence again; a text that is only a path is still an empty sentence
for fc in "no awk program at all|op_paths_awk() { :; }" "a program that prints nothing|op_paths_awk() { echo '{}'; }"; do
    fl=${fc%%|*}; fcode=${fc#*|}
    pgot=$(bash -c '. "$1/lib/common.sh"; . "$1/lib/op.sh"; eval "$3"; op_plain "$2"' _ "$ROOT" "$SECRET" "$fcode")
    [ "$pgot" = "$FIXED" ] && ok "plain, the path pass with $fl: the fixed sentence" || bad "plain, $fl: '$pgot'"
done
pgot=$(plain "/tmp/only/a/path"); [ -z "$pgot" ] && ok "plain: a text that is only a path is an empty sentence, not a failed step" || bad "plain, only a path: '$pgot'"
pgot=$(plain ""); [ -z "$pgot" ] && ok "plain: an empty text is an empty sentence" || bad "plain, empty: '$pgot'"
# deep nests: a closer per level around a path, and bracket text with no path at all, at 20000 and at 80000 levels, under mawk where it is available (the line built by
# concatenation, or a copy of the stack per closer, cost four times as much per doubling there): the time of the larger is bounded, and bounded against the smaller
MB=$HOME/mawkbin; mkdir -p "$MB"; ln -sf "$(command -v mawk || command -v awk)" "$MB/awk"
nrep() { awk -v u="$1" -v n="$2" 'BEGIN { for (i = 0; i < n; i++) printf "%s", u }'; }   # <unit> <times> → the unit written that many times (to a file, never held in a variable)
nesttime() {  # <levels> <shape c|d|g|i> → $NT, the milliseconds op_drop_paths takes on it, $NRC its exit status, and $NGOT / $NWANT the cksum (checksum and byte count) of the
    # whole answer and of the answer it must give (written by nrep and printf, not by the filter): every byte of it is compared, the end of it included
    local n=$1 txt t0 t1
    case $2 in c) txt="$(longrep '[(' $((n * 2)))/b$(longrep ')]' $((n * 2)))";; d) txt="ok $(longrep '(' "$n")x$(longrep ')' "$n") z"
        ;; g) txt="read /a$(longrep '(' "$n")b$(longrep ')' "$n") z";; i) txt="read \"/a$(longrep '[' "$n")\"$(longrep ']' "$n") z";; esac
    printf '%s\n' "$txt" > "$HOME/nest.in"; t0=${EPOCHREALTIME//[.,]/}
    PATH="$MB:$PATH" timeout 60 bash -c '. "$1/lib/common.sh"; . "$1/lib/op.sh"; read -r x < "$2"; op_drop_paths "$x" > "$3"' _ "$ROOT" "$HOME/nest.in" "$HOME/nest.out"; NRC=$?; t1=${EPOCHREALTIME//[.,]/}
    NT=$(( (t1 - t0) / 1000 ))
    case $2 in c) { nrep '[(' $((n - 1)); printf '[]'; nrep ')]' $((n - 1)); printf '\n'; };; d) { printf 'ok '; nrep '(' "$n"; printf x; nrep ')' "$n"; printf ' z\n'; };;
        g) printf 'read  z\n';; i) { printf 'read '; nrep ']' "$n"; printf ' z\n'; };; esac > "$HOME/nest.want"
    NGOT=$(cksum < "$HOME/nest.out"); NWANT=$(cksum < "$HOME/nest.want")
}
for nc in "c|a path inside 20000 nested pairs, then the closers" "d|20000 openers around plain text, then the closers"; do
    IFS='|' read -r nsh nl <<< "$nc"
    nesttime 20000 "$nsh"; na=$NT; nga=$NGOT; nwa=$NWANT; nra=$NRC; nesttime 80000 "$nsh"; nb=$NT
    [ "$nra" = 0 ] && [ "$NRC" = 0 ] && [ "$nga" = "$nwa" ] && [ "$NGOT" = "$NWANT" ] && [ "$nb" -lt 8000 ] && [ "$nb" -lt $((na * 8 + 500)) ] \
        && ok "plain, $nl: the whole answer at both depths, $na ms, and $nb ms at four times the depth (linear)" \
        || bad "plain, nest '$nsh': exit $nra/$NRC, answer '$nga' wanted '$nwa', then '$NGOT' wanted '$NWANT', $na ms then $nb ms at four times the depth"
done
# the same inside a path (the stack of the path's own end): a path with N openers in its body and N closers after it, and a quoted path whose body holds N
# openers with the N closers after it, at 80000 and at 160000: the larger is bounded against the smaller
for nc in "g|a path with 80000 openers in its body and the closers after it" "i|a quoted path with 80000 openers in its body, the closers after it"; do
    IFS='|' read -r nsh nl <<< "$nc"
    nesttime 80000 "$nsh"; na=$NT; nga=$NGOT; nwa=$NWANT; nra=$NRC; nesttime 160000 "$nsh"; nb=$NT
    [ "$nra" = 0 ] && [ "$NRC" = 0 ] && [ "$nga" = "$nwa" ] && [ "$NGOT" = "$NWANT" ] && [ "$nb" -lt 8000 ] && [ "$nb" -lt $((na * 3 + 500)) ] \
        && ok "plain, $nl: the whole answer at both depths, $na ms, and $nb ms at twice the depth (linear)" \
        || bad "plain, nest '$nsh': exit $nra/$NRC, answer '$nga' wanted '$nwa', then '$NGOT' wanted '$NWANT', $na ms then $nb ms at twice the depth"
done
rm -f "$HOME/nest.in" "$HOME/nest.out" "$HOME/nest.want"; rm -rf "$MB"
# a stuck post whose helper line names a single-segment path and a command: neither reaches Slack
: > "$POSTS"; S9=$(sid 209); mkfin "$S9" sala-test-h rename sala-test-zz sala-test-zy; stuckwhy "$S9" "It could not write /tmp or ~/settings.json, and \`salamander rename sala-test-zz sala-test-zy\` stopped. Second sentence."
fin "$S9" stuck "no tmux session (exit 1)"
P=$(post "$LG$S9.log"); [ "$(lines_in "$P")" = 3 ] && [ "$(sed -n 2p <<< "$P")" = "It could not write or and stopped." ] && ! has "$P" "/tmp" && ! has "$P" "settings.json" && ! has "$P" "salamander rename" && ! has "$P" '`' && plain_post "$P" \
    && ok "a stuck post: the single-segment and the ~/file paths and the enclosed command stay out of it" || bad "path/command post: $P"

echo "== a lane move over every session that skipped or failed some: the count stays partial, never 'every session'; the default lane's line is outside the cap"
# lane <lane> --all: the sessions are not on the marker, the relaunch set carries the total and the pane it gave up
: > "$POSTS"; A1=$(sid 301); AS="oplaneall-$$"; mkfin "$A1" sala-test-h lane subscription-1 --all
printf '%s\n' kind=Recycle label=oplaneall done=2 total=3 closed=1 "gave=sala-test-w3: its pane is gone" "skip=sala-test-w3: its pane is gone" > "$SALA_SET_DIR/$AS"
echo "set=$AS" >> "$OPS/$A1.op"; fin "$A1" stuck "Recycle oplaneall: 2/3 relaunched, 1 pane given up: sala-test-w3: its pane is gone"
P=$(post "$LG$A1.log"); [ "$(lines_in "$P")" = 3 ] && [ "$(sed -n 1p <<< "$P")" = "🚨 *moved 2 of 3 sessions to subscription-1*" ] && [ "$(sed -n 2p <<< "$P")" = "• sala-test-w3: its pane is gone" ] && ! has "$P" "every session" && plain_post "$P" \
    && ok "lane --all with a pane given up: '2 of 3 sessions' and the pane named, not 'every session'" || bad "lane --all partial: $P"
rm -f "$SALA_SET_DIR/$AS"
# the same move with nothing failed or skipped keeps its own headline
: > "$POSTS"; A2=$(sid 302); AS="oplaneall2-$$"; mkfin "$A2" sala-test-h lane subscription-1 --all
printf '%s\n' kind=Recycle label=oplaneall2 done=3 total=3 closed=1 > "$SALA_SET_DIR/$AS"; echo "set=$AS" >> "$OPS/$A2.op"; fin "$A2" done "Recycle oplaneall2: 3/3 relaunched"
P=$(post "$LG$A2.log"); [ "$P" = "✅ *moved every session to subscription-1* · asked by sala-test-h · log ~/.claude/salamander-op-$A2.log" ] && ok "lane --all with nothing failed: 'every session', one line" || bad "lane --all clean: $P"
rm -f "$SALA_SET_DIR/$AS"
# the lane fallback: five real failures and the default lane's line: all five named, no "and 1 more", the default line present
: > "$POSTS"; A3=$(sid 303); mkfin "$A3" sala-watch lane fallback subscription-1
for k in 1 2 3 4 5; do echo "detail=sala-test-v$k: subscription-1 → bedrock (NOT moved: still recorded on subscription-1)" >> "$OPS/$A3.op"; done
printf 'detail=%s\n' "sala-test-v6: subscription-1 → bedrock" "default lane: subscription-1 → bedrock" >> "$OPS/$A3.op"
fin "$A3" done "the subscription-1 lane is dormant: 1 session and the default moved to the bedrock lane"
P=$(post "$LG$A3.log"); [ "$(sed -n 1p <<< "$P")" = "⚠️ *moved 1 of 6 sessions off the dormant lane subscription-1*" ] && [ "$(sed -n 2p <<< "$P")" = "• default lane: subscription-1 → bedrock" ] && [ "$(grep -c 'NOT moved' <<< "$P")" = 5 ] && ! has "$P" " more" && ! has "$P" "sala-test-v6" && [ "$(lines_in "$P")" = 8 ] && plain_post "$P" \
    && ok "five failures and the default lane: the default line stays, all five named, no 'and 1 more'" || bad "five + default: $P"
# seven failures and the default line: the cap counts the seven only ("and 2 more"), the default line is still there
: > "$POSTS"; A4=$(sid 304); mkfin "$A4" sala-watch lane fallback subscription-1
for k in 1 2 3 4 5 6 7; do echo "detail=sala-test-v$k: subscription-1 → bedrock (NOT moved: still recorded on subscription-1)" >> "$OPS/$A4.op"; done
printf 'detail=%s\n' "default lane: subscription-1 → bedrock" >> "$OPS/$A4.op"
fin "$A4" done "the subscription-1 lane is dormant: the default moved to the bedrock lane"
P=$(post "$LG$A4.log"); [ "$(sed -n 2p <<< "$P")" = "• default lane: subscription-1 → bedrock" ] && [ "$(grep -c 'NOT moved' <<< "$P")" = 5 ] && has "$P" "and 2 more" && ! has "$P" "and 3 more" && ! has "$P" "sala-test-v6" && [ "$(lines_in "$P")" = 9 ] && plain_post "$P" \
    && ok "seven failures and the default lane: 'and 2 more' (the seven only), the default line present and never cut" || bad "seven + default: $P"

# the lane fallback that moved the default lane and none, one or two sessions: the default-lane line is in the post for every count
: > "$POSTS"; A5=$(sid 305); mkfin "$A5" sala-watch lane fallback subscription-1
printf 'detail=%s\n' "default lane: subscription-1 → bedrock" >> "$OPS/$A5.op"
fin "$A5" done "the subscription-1 lane is dormant: the default moved to the bedrock lane"
P=$(post "$LG$A5.log"); [ "$(lines_in "$P")" = 3 ] && has "$P" "• default lane: subscription-1 → bedrock" && has "$P" "asked by sala-watch" && plain_post "$P" \
    && ok "fallback, no session moved, the default lane moved: its line is in the post" || bad "fallback n=0: $P"
: > "$POSTS"; A6=$(sid 306); mkfin "$A6" sala-watch lane fallback subscription-1
printf 'detail=%s\n' "sala-test-v1: subscription-1 → bedrock" "default lane: subscription-1 → bedrock" >> "$OPS/$A6.op"
fin "$A6" done "the subscription-1 lane is dormant: 1 session and the default moved to the bedrock lane"
P=$(post "$LG$A6.log"); [ "$(lines_in "$P")" = 3 ] && [ "$(sed -n 1p <<< "$P")" = "✅ *moved sala-test-v1 off the dormant lane subscription-1*" ] && [ "$(sed -n 2p <<< "$P")" = "• default lane: subscription-1 → bedrock" ] && plain_post "$P" \
    && ok "fallback, one session moved, the default lane moved: the session named, the default line present" || bad "fallback n=1: $P"
: > "$POSTS"; A7=$(sid 307); mkfin "$A7" sala-watch lane fallback subscription-1
printf 'detail=%s\n' "sala-test-v1: subscription-1 → bedrock" "sala-test-v2: subscription-1 → bedrock" "default lane: subscription-1 → bedrock" >> "$OPS/$A7.op"
fin "$A7" done "the subscription-1 lane is dormant: 2 sessions and the default moved to the bedrock lane"
P=$(post "$LG$A7.log"); [ "$(lines_in "$P")" = 3 ] && [ "$(sed -n 1p <<< "$P")" = "✅ *moved 2 sessions off the dormant lane subscription-1*" ] && [ "$(sed -n 2p <<< "$P")" = "• default lane: subscription-1 → bedrock" ] && plain_post "$P" \
    && ok "fallback, two sessions moved, the default lane moved: the count, the default line present" || bad "fallback n=2: $P"

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
# THE STUCK POST'S NUMBERS: the closing post's (done of total). Panes the first post left behind and that came back after it (skip=,
# no back=) are neither counted nor listed.
: > "$POSTS"; B1=$(sid 311); n0=$(evn); mkfin "$B1" sala-test-h recycle --force
printf '%s\n' kind=Recycle label=opstale done=2 total=3 closed=1 reported=1 "skip=sala-test-q1: busy for 26 min; sala relaunches it once it is free" \
    "skip=sala-test-q2: busy for 2 h; sala relaunches it once it is free" "skip=sala-test-q3: its pane is gone" "gave=sala-test-q3: its pane is gone" > "$SALA_SET_DIR/$ES"; echo "set=$ES" >> "$OPS/$B1.op"
fin "$B1" stuck "Recycle opstale: 2/3 relaunched, 1 pane given up: sala-test-q3: its pane is gone"
P=$(post "$LG$B1.log"); has "$(sed -n 1p <<< "$P")" "2 of 3" && has "$P" "sala-test-q3" && ! has "$P" "sala-test-q1" && ! has "$P" "sala-test-q2" \
    && ok "a stuck recycle whose first-post panes came back: 2 of 3, only the pane given up named" || bad "stale post: $P"
[ "$(( $(evn) - n0 ))" = 1 ] && [ "$(evf sessions)" = 3 ] && [ "$(evf result)" = partial ] && ok "and its event counts the same one pane: partial" || bad "stale event: $(evlast | paste -sd' ')"
rm -f "$SALA_SET_DIR/$ES"
# NO ALARM FOR WHAT SALA STILL HANDLES: a pane on the deferred list at the waiter's deadline, or given up only at that list's limit
cp "$SALA_DEFERRED" "$HOME/deferred.bak" 2>/dev/null || : > "$HOME/deferred.bak"
later_row() { printf '%s\t%s\tstill busy\t0\t0\t%s\n' "$1" "$(date +%s)" "$2" >> "$SALA_DEFERRED"; }   # <session> <set id>
judge() { SALA_OP_STUCK="${3:-on}" bash -c '. "$1/lib/common.sh"; . "$1/lib/op.sh"; op_judge_set "$2" "$3"' _ "$ROOT" "$1" "$2" >/dev/null 2>&1; }   # <op> <set> [helper on|off]
: > "$POSTS"; : > "$SALA_DEFERRED"; rm -f "$HOME/helper-runs.txt"; n0=$(evn); C1=$(sid 312); CS="$(date +%s)-9312"; mkfin "$C1" sala-test-h recycle --force
printf '%s\n' kind=Recycle label=oplater done=2 total=3 closed=0 reported=1 out=sala-test-q2 "skip=sala-test-q2: busy for 2 h; sala relaunches it once it is free" > "$SALA_SET_DIR/$CS"; echo "set=$CS" >> "$OPS/$C1.op"
later_row sala-test-q2 "$CS"; SALA_OP_SETTLE_WAIT=0 "$SALA" op --settle "$C1" "$CS" >/dev/null 2>&1
P=$(post "$LG$C1.log"); [ "$(mval "$C1" state)" = done ] && [ "$(runs)" = 0 ] && has "$(sed -n 1p <<< "$P")" "2 of 3" && has "$P" "sala-test-q2" && ! grep -q '🚨' "$POSTS" \
    && [ "$(evf result)" = partial ] && ok "the deadline with the pane on the deferred list: done, the pane named, no alarm, no claude -p" || bad "later at the deadline: state=$(mval "$C1" state) runs=$(runs) $(<"$POSTS")"
rm -f "$SALA_SET_DIR/$CS"
D1=$(sid 313); DS="$(date +%s)-9313"; : > "$SALA_DEFERRED"; mkfin "$D1" sala-test-h recycle --force
printf '%s\n' kind=Recycle label=oplimit done=2 total=3 closed=0 reported=1 out=sala-test-q3 > "$SALA_SET_DIR/$DS"; echo "set=$DS" >> "$OPS/$D1.op"; later_row sala-test-q3 "$DS"
bash -c '. "$1/lib/common.sh"; set_giveup_pane sala-test-q3 "held for 3 h, so this recycle stopped waiting for it; sala still relaunches it once it is free"' _ "$ROOT" >/dev/null 2>&1
: > "$POSTS"; judge "$D1" "$DS"
P=$(post "$LG$D1.log"); grep -qx 'later=sala-test-q3' "$SALA_SET_DIR/$DS" && [ "$(mval "$D1" state)" = done ] && [ "$(runs)" = 0 ] && has "$P" "sala-test-q3" && ! grep -q '🚨' "$POSTS" \
    && ok "a pane given up at the deferred list's limit: done, no alarm, the pane named" || bad "limit give-up: state=$(mval "$D1" state) set: $(slurp "$SALA_SET_DIR/$DS") $(<"$POSTS")"
rm -f "$SALA_SET_DIR/$DS"
# a pane nothing brings back is still stuck: listed first; a row alone (a give-up that was not the limit's) is not a relaunch to come
: > "$POSTS"; : > "$SALA_DEFERRED"; M1=$(sid 314); MS="$(date +%s)-9314"; mkfin "$M1" sala-test-h recycle --force
printf '%s\n' kind=Recycle label=opmixed done=1 total=3 closed=0 reported=1 out=sala-test-q2 out=sala-test-q4 > "$SALA_SET_DIR/$MS"; echo "set=$MS" >> "$OPS/$M1.op"; later_row sala-test-q2 "$MS"
SALA_OP_SETTLE_WAIT=0 SALA_OP_STUCK=off "$SALA" op --settle "$M1" "$MS" >/dev/null 2>&1
P=$(post "$LG$M1.log"); [ "$(mval "$M1" state)" = stuck ] && has "$(sed -n 1p <<< "$P")" "1 of 3" && has "$(sed -n 2p <<< "$P")" "sala-test-q4" && has "$(sed -n 3p <<< "$P")" "sala-test-q2" \
    && ok "one pane nothing brings back beside a deferred one: stuck, the first listed first" || bad "mixed: state=$(mval "$M1" state) $(<"$POSTS")"
rm -f "$SALA_SET_DIR/$MS"
: > "$POSTS"; : > "$SALA_DEFERRED"; G1=$(sid 315); GS="$(date +%s)-9315"; mkfin "$G1" sala-test-h recycle --force
printf '%s\n' kind=Recycle label=opgone done=2 total=3 closed=1 reported=1 "gave=sala-test-q5: its tmux session is gone" > "$SALA_SET_DIR/$GS"; echo "set=$GS" >> "$OPS/$G1.op"; later_row sala-test-q5 "$GS"
judge "$G1" "$GS" off
[ "$(mval "$G1" state)" = stuck ] && ok "a pane given up for another reason is stuck even while its row is still on the list" || bad "gone with a row: state=$(mval "$G1" state) $(<"$POSTS")"
rm -f "$SALA_SET_DIR/$GS"; cp "$HOME/deferred.bak" "$SALA_DEFERRED"; rm -f "$HOME/helper-runs.txt"
# update naming one other host: that host is the machine; no set and no session: sessions 0
E8="$FK-98"; n0=$(evn); mkfin "$E8" sala-test-h update t-host-b; fin "$E8" done "t-host-b updated"
[ "$(( $(evn) - n0 ))" = 1 ] && [ "$(evf verb)" = update ] && [ "$(evf machine)" = t-host-b ] && [ "$(evf sessions)" = 0 ] && [ "$(evf result)" = ok ] && ok "update t-host-b: machine t-host-b, sessions 0, ok" || bad "update event: $(evlast | paste -sd' ')"
# a plan queues nothing and ends nothing: no event
n0=$(evn); enq --plan retire sala-test-d --from t --words x; [ "$(evn)" = "$n0" ] && ok "a plan (--plan) reports no event" || bad "plan event: $(evn) vs $n0"
# a failing client: the op ends the same (exit 0, state done, the Slack post and the inbox line made), the failure is in the op log
: > "$POSTS"; : > "$SOCKLOG"; E9="$FK-99"; mkfin "$E9" sala-test-h lane subscription-1 sala-test-z1
rc=$(FAKE_CLIENT_FAIL=1 finrc "$E9" done "Lane subscription-1: 1/1 relaunched")
[ "$rc" = 0 ] && [ "$(mval "$E9" state)" = done ] && [ -f "$DONE/$E9.op" ] && has "$(post ' · log ~/.claude/salamander-op-')" "✅ *moved sala-test-z1 to subscription-1*" \
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
runop() { : >> "$SALA_LOG_DIR/salamander-op-$1.log"; SALA_CGROUP_FILE="$HOME/op-unit.cgroup" "$SALA" op --run "$1" >/dev/null 2>&1; }   # the unit's main process, run by hand once a tick started it (norun); the real unit's redirect has made the log by then
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

echo "== the post's closing line: with sala's web address set the log is a link to sala-web's page of it (/op/<id>); with none, or an address that is not http(s), the path as before"
touch "$HOME/norun"; KL=$((K0+30))
for tpl in 'https://sala.example/s/{name}' 'https://sala.example:8443/x/s/{name}' UNSET '' 'ssh://sala.example/s/{name}'; do
    KL=$((KL+1)); KI="$KL-$KL"; mkop "$KI" model sala-test-a --clear; : > "$POSTS"; SALA_OP_STUCK=off tick
    if [ "$tpl" = UNSET ]; then SALA_OP_STUCK=off runop "$KI"; else SALA_SESSION_URL="$tpl" SALA_OP_STUCK=off runop "$KI"; fi
    P=$(post "asked by sala-test-h"); L=$(sed -n '$p' <<< "$P")
    case "$tpl" in
        'https://sala.example/s/{name}') want="✅ *cleared the model of sala-test-a* · asked by sala-test-h · <https://sala.example/op/$KI|log>" ;;
        'https://sala.example:8443/x/s/{name}') want="✅ *cleared the model of sala-test-a* · asked by sala-test-h · <https://sala.example:8443/op/$KI|log>" ;;
        *) want="✅ *cleared the model of sala-test-a* · asked by sala-test-h · log ~/.claude/salamander-op-$KI.log" ;;
    esac
    [ "$P" = "$want" ] && [ "$(nposts "asked by sala-test-h")" = 1 ] && ok "SALA_SESSION_URL='${tpl:-<empty>}': one line, the log as expected" || bad "post for '$tpl': [$P] want [$want]"
done
echo "== …the log folder is sala's one setting SALA_LOG_DIR: the link is given only when it is what sala-web reads (the default config file's line, a relative folder under \$HOME); a CLI-only SALA_CONFIG or SALA_LOG_DIR gets the path"
DEFCFG="$HOME/.config/salamander/config"; mkdir -p "$(dirname "$DEFCFG")"; printf 'SALA_LOG_DIR=~/custom-logs  # moved\n' > "$DEFCFG"; printf 'SALA_LOG_DIR=~/cli-only\n' > "$HOME/cli.conf"
oplink() {  # <name> <want: link|path> <folder under $HOME> <cwd> <address> <env words…> → one operation run with that environment, its post and files checked
    local nm="$1" want="$2" dir="$3" cwd="$4" tpl="$5" P w; shift 5
    KL=$((KL+1)); KI="$KL-$KL"; mkop "$KI" model sala-test-a --clear; : > "$POSTS"; SALA_OP_STUCK=off tick
    : >> "$HOME/$dir/salamander-op-$KI.log"   # (the unit's redirect makes the log before the runner starts)
    ( cd "$cwd" && env "$@" SALA_SESSION_URL="$tpl" SALA_OP_STUCK=off SALA_CGROUP_FILE="$HOME/op-unit.cgroup" "$SALA" op --run "$KI" >/dev/null 2>&1 )
    P=$(post "asked by sala-test-h"); w="✅ *cleared the model of sala-test-a* · asked by sala-test-h · "
    if [ "$want" = link ] && [ -n "$tpl" ]; then w+="<https://sala.example/op/$KI|log>"; else w+="log ~/$dir/salamander-op-$KI.log"; fi
    [ "$P" = "$w" ] && [ -f "$HOME/$dir/salamander-op-$KI.out" ] && ok "$nm" || bad "$nm: [$P] want [$w] / $(ls "$HOME/$dir" 2>&1 | tr '\n' ' ')"
}
mkdir -p "$HOME/custom-logs" "$HOME/rel-logs" "$HOME/cli-only" "$HOME/env-logs"
oplink "SALA_LOG_DIR moved in the default config, address set: the link" link custom-logs "$HOME" 'https://sala.example/s/{name}' SALA_CONFIG="$DEFCFG"
oplink "SALA_LOG_DIR moved in the default config, no address: the path in the moved folder" link custom-logs "$HOME" '' SALA_CONFIG="$DEFCFG"
printf 'SALA_LOG_DIR=rel-logs\n' > "$DEFCFG"
oplink "a relative SALA_LOG_DIR in the config, run from another folder: under \$HOME, and the link" link rel-logs / 'https://sala.example/s/{name}' SALA_CONFIG="$DEFCFG"
oplink "a CLI-only SALA_CONFIG naming another folder: the path, no link to a page that would 404" path cli-only "$HOME" 'https://sala.example/s/{name}' SALA_CONFIG="$HOME/cli.conf"
rm -f "$DEFCFG"
oplink "a CLI-only SALA_LOG_DIR in the environment: the path, no link" path env-logs "$HOME" 'https://sala.example/s/{name}' SALA_CONFIG=/dev/null SALA_LOG_DIR="$HOME/env-logs"
oplink "a CLI-only relative SALA_LOG_DIR in the environment: under \$HOME, the path, no link" path env-logs / 'https://sala.example/s/{name}' SALA_CONFIG=/dev/null SALA_LOG_DIR=env-logs
rm -f "$HOME/norun"

[ "$fail" = 0 ] && echo "op: pass" || echo "op: FAIL"
exit $fail
