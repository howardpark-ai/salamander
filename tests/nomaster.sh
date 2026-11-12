#!/usr/bin/env bash
# No master session (the master, demo-master,
# is retired once the operation queue works). What is checked guards against the two ways this goes wrong, and covers the
# one operation that ends the master:
#  - `salamander master --unset` on a real temporary config: the line commented out, the file still parsing and naming no
#    master, the other lines intact, `salamander config` reading none, the watchdog's records of the master dropped (the
#    records watch would recreate, resume or bridge it from), master_unset recorded, the last-good copy refreshed to the
#    unset config (a restore from it must never bring the master back), idempotent; `master`, `--name`, `--json` reading
#    "unset"; `--set` again clearing the record.
#  - `sala op retire <the master>` as one operation: a plain `retire <the master>` and its dry run refuse outside the queue;
#    `op --plan` says "would unset SALA_MASTER, then retire"; the unit unsets first and then retires (the log order, the
#    marker's unset_master, the config, the session gone, done, the post naming the unset); a retire that fails after the
#    unset → stuck with SALA_MASTER unset, the session alive, the post saying how to put it back; an unset that fails →
#    stuck, the retire never started, the config untouched.
#  - the guards with no master (lib/common.sh, claude_caller): a Claude ancestor refused with the `sala op` pointer and
#    nothing run; the queue's cgroup admitted; a tmux-launched caller (the resurrect boot hook, a human's pane shell)
#    passes; a sala-test-* target, --dry-run, --not-master and --check pass; a verb the queue has no shape for refused with
#    that said; `model` (the queue has the verb) refused with the `sala op model` pointer, its --dry-run and the
#    no-argument table form left open; the control: a master set and a Claude caller outside tmux passes as before.
#  - `sala cue` with a master (delivered to its inbox) and without (the pointer, the verb table, one example, exit 1,
#    nothing delivered, nothing logged).
#  - `watch` with no master: `--check` healthy and exit 0; a state that remembers a master with no unset record is the lost
#    config (exit 1), healthy again once master_unset is back; a plain tick heals, recreates and bridges nothing and types
#    nothing; the post-boot report as one Slack post per boot, not twice; the tmux server down with no tmux.service and no
#    master: reported, no bare session made.
#  - the boot hook's revive with no master: launched by tmux (no Claude ancestor), it passes the guard, relaunches the
#    panes and leaves the boot record the report reads.
# Isolated HOME, a private tmux socket, the compiled fake claude; systemd-run and systemctl are stubs (the unit runs
# detached, in the queue's cgroup as the real unit does), the claude -p is a stub, Slack is a file; nothing real is
# touched. A Claude ancestor is modelled by a script named `claude` (comm = claude, what the ancestry walk reads), so each
# verdict holds by construction whether the suite runs from a Claude session's pane or in CI.
# Usage: bash tests/nomaster.sh   (exit 0 = pass; ~70 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_MASTER SALA_SET SALA_SET_SELF SALA_RECYCLE SALA_RETRY_WORKER SALA_LOCK_WHO SALA_LOCK_WAIT SALA_RELAUNCH_KIND \
      SALA_FLEET_HOSTS SALA_CGROUP_FILE SALA_OP_QUEUE SALA_OP_REBOOT SALA_OP_STUCK SALA_REBOOT_HOOKS SALA_NO_RELAUNCH SALA_BOOT_ID SALA_CUE_TARGET SALA_CONFIG
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, fake_up, tmux_socket_rm; the lane variables unset
export HOME=$(mktemp -d); export SALA_TZ=Etc/UTC
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOME/anc" "$HOME/.config/salamander"
export SALA_CONFIG="$HOME/.config/salamander/config"   # a real config file, the one --unset edits
cat > "$SALA_CONFIG" <<'EOF'
# a test config (tests/nomaster.sh): the master line is the one sala writes and unsets; the rest must survive untouched
SALA_MASTER=sala-test-m   # the master
SALA_KEEP_ONE="kept one"
SALA_KEEP_TWO=kept-two
EOF
cp "$SALA_CONFIG" "$HOME/config.orig"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"
# a Claude ancestor: a script named claude that runs its arguments as a child (never exec), so the walk meets comm "claude"
printf '#!/bin/bash\n"$@"\n' > "$HOME/anc/claude"; chmod +x "$HOME/anc/claude"
under_claude() { "$HOME/anc/claude" "$@"; }
# the queue's cgroup, for the unit the stub launches and for the one guard check that models the runner
echo "0::/user.slice/user-$EUID.slice/user@$EUID.service/app.slice/sala-op-1760000000-1.service" > "$HOME/op-unit.cgroup"
LAUNCHES="$HOME/systemd-run.txt"
cat > "$HOME/.local/bin/systemd-run" <<'EOF'
#!/bin/bash
# the stub unit (tests/op.sh): records the line; a sala-op-<id> launch runs its command detached in the queue's cgroup, unless
# $HOME/norun exists; the stuck handler's unit always runs
echo "$*" >> "$HOME/systemd-run.txt"
case " $* " in *" --on-active="*) exit 0;; esac
case "$*" in *--unit=sala-op-*) ;; *) exit 0;; esac
case "$*" in *-stuck\ *) ;; *) [ -e "$HOME/norun" ] && exit 0;; esac
cmd="${@: -1}"; SALA_CGROUP_FILE="$HOME/op-unit.cgroup" setsid bash -c "$cmd" </dev/null >/dev/null 2>&1 &
exit 0
EOF
cat > "$HOME/.local/bin/systemctl" <<'EOF'
#!/bin/bash
echo "$*" >> "$HOME/systemctl.txt"
case "$*" in
    *is-active*) exit 3 ;;
    *is-system-running*) echo running; exit 0 ;;
    *cat*tmux.service*) exit 1 ;;   # no tmux.service on this box: watch's other branch
    *) exit 0 ;;
esac
EOF
cat > "$HOME/fake-helper" <<'EOF'
#!/bin/bash
# the stub claude -p: says it could not (the stuck path is op.sh's; here only that it ran and the result holds)
echo "run $(date +%s)" >> "$HOME/helper-runs.txt"
echo "SALA-OP: stuck the test helper does nothing"
EOF
chmod +x "$HOME/.local/bin/systemd-run" "$HOME/.local/bin/systemctl" "$HOME/fake-helper"
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log" FAKE_TYPED_LOG="$HOME/typed.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"   # one post per record, '%%' between them
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off
export SALA_LIMIT_ALERT=off SALA_LIMIT_RESUME=off SALA_STUCK_POST=off   # the other watches: not under test
export SALA_OP_CLAUDE="$HOME/fake-helper" SALA_OP_POLL=1 SALA_OP_LOCK_WAIT=5 SALA_OP_SWEEP_WAIT=120 SALA_OP_SETTLE_WAIT=120 \
       SALA_OP_STUCK_TURNS=3 SALA_OP_STUCK_TIME=30 SALA_OP_HELPER_CWD="$HOME"
SALA="$ROOT/bin/salamander"; SOCK="sala-nomaster-$$"; T="tmux -L $SOCK -f /dev/null"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's
cleanup() {
    local f p; for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done
    for p in $(pgrep -f "salamander op --settle" 2>/dev/null); do grep -qz "HOME=$HOME" "/proc/$p/environ" 2>/dev/null && kill "$p" 2>/dev/null; done
    chmod 755 "$HOME/.config/salamander" 2>/dev/null
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    for p in $(pgrep -x claude); do [ "$HOME/.local/share/claude/versions/9.9.9" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux    # literal socket: the children run set -u
# lib/common.sh is not sourced here: it would source the config into this shell, and the config changes under the checks
OPS="$HOME/.local/state/salamander/ops"; DONE="$OPS/done"; SOCKLOG="$HOME/sock-h.log"; MSOCKLOG="$HOME/sock-m.log"
ST="$HOME/.claude/salamander-watch.state"; WLOG="$HOME/.claude/salamander-watch.log"; LASTGOOD="$HOME/.claude/salamander-config.last-good"
REC="$HOME/.claude/salamander-boot-revive"; CUELOG="$HOME/.claude/salamander-cue.log"; LOCK="$HOME/.claude/salamander-recycle.lock"
mk() { local n="$1" u="$2"; shift 2; $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="sala-test-$n" -e FAKE_LOG="$FAKE_LOG" "$@"; $T send-keys -t "sala-test-$n" 'claude' Enter; }
cpid() { local pp; pp=$(tmux display -p -t "$1" '#{pane_pid}' 2>/dev/null); [ -n "$pp" ] && pgrep -P "$pp" -x claude | head -1; }   # <tmux session> → its claude's pid (the pane shell's child)
regstatus() { local c; c=$(cpid "$1"); set_reg_status "$c" "$2"; }   # <tmux session> <status>
posts() { local n; n=$(grep -c '^%%$' "$POSTS" 2>/dev/null); echo "${n:-0}"; }   # grep -c prints 0 and exits 1 on no match: never `|| echo 0`
mval() { local f="$OPS/$1.op"; [ -f "$f" ] || f="$DONE/$1.op"; awk -F= -v k="$2" '$1==k {print substr($0, length(k)+2); exit}' "$f" 2>/dev/null; }   # <id> <key>
queued() { ls "$OPS"/*.op 2>/dev/null | wc -l; }
tick() { "$SALA" watch --ops >/dev/null 2>&1; }
oplog() { cat "$HOME/.claude/salamander-op-$1.log" 2>/dev/null; }   # the unit's own log (op_oplog)
wait_lock() { lock_wait "$LOCK" 120; }
stv() { awk -F= -v k="$1" '$1==k {print substr($0, length(k)+2); exit}' "$ST" 2>/dev/null; }
lines() { local n; n=$(grep -c . "$1" 2>/dev/null); echo "${n:-0}"; }
starts() { local n; n=$(grep -c "^start $1" "$FAKE_LOG" 2>/dev/null); echo "${n:-0}"; }

echo "== setup: the master m, the hearing session h, a and b on the fake claude"
mk m "$(uuid 1)" -e FAKE_SOCK_LOG="$MSOCKLOG"; mk h "$(uuid 2)" -e FAKE_SOCK_LOG="$SOCKLOG"; mk a "$(uuid 3)"; mk b "$(uuid 4)"
fake_up sala-test-m sala-test-h sala-test-a sala-test-b || exit 1
for n in m h a b; do "$SALA" adopt "sala-test-$n" >/dev/null 2>&1 || bad "adopt sala-test-$n failed"; done   # into the pane map, as spawned sessions are: the tick's unmapped report is not under test
[ "$("$SALA" master --name 2>/dev/null)" = sala-test-m ] && "$SALA" master >/dev/null 2>&1 && ok "the config names sala-test-m as the master, and it is live" || bad "master: $("$SALA" master 2>&1)"

echo "== with a master (the control): cue delivers to its inbox; a Claude caller outside tmux passes the guard as before"
out=$("$SALA" cue --from sala-test-h --dry-run "recycle claude" 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "would deliver to 'sala-test-m'" && ok "cue --dry-run: would deliver to the master" || bad "cue dry run ($rc): $out"
out=$("$SALA" cue --from sala-test-h "recycle claude" 2>&1); rc=$?
[ "$rc" = 0 ] && waitfor "grep -q 'recycle claude' '$MSOCKLOG' 2>/dev/null" 20 && grep -q 'cue delivered → sala-test-m' "$CUELOG" && ok "cue: delivered into the master's inbox, logged" || bad "cue ($rc): $out / $(slurp "$MSOCKLOG")"
out=$(under_claude "$SALA" retire nosuch 2>&1); rc=$?
[ "$rc" != 0 ] && ! has "$out" "fleet operation" && ! has "$out" "sala op" && ok "a master set, a Claude caller outside tmux: the guard passes (retire goes on to its own refusal)" || bad "control ($rc): $out"

echo "== sala retire <the master> outside the queue: refused, its dry run too; op --plan shows the one operation"
out=$("$SALA" retire sala-test-m 2>&1); rc=$?
[ "$rc" != 0 ] && has "$out" "the queue does it in one operation" && has "$out" "sala op retire sala-test-m" && ok "retire <the master>: refused, the queue named" || bad "retire master ($rc): $out"
out=$("$SALA" retire sala-test-m --dry-run 2>&1); rc=$?
[ "$rc" != 0 ] && has "$out" "the queue does it in one operation" && ok "its dry run outside the queue: refused too" || bad "retire master --dry-run ($rc): $out"
out=$("$SALA" op --plan retire sala-test-m 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "would unset SALA_MASTER, then retire" && has "$out" "then retire it as below" && [ "$(queued)" = 0 ] && ok "op --plan retire <the master>: would unset SALA_MASTER, then retire; nothing queued" || bad "plan ($rc): $out"
tmux has-session -t =sala-test-m 2>/dev/null && [ "$("$SALA" master --name 2>/dev/null)" = sala-test-m ] && ok "nothing happened to the master" || bad "the master changed"

echo "== salamander master --unset on the config"
printf 'master=sala-test-m\nuuid=%s\nbridge=session_01FAKE\nlane_norc=api\ncwd.sala-test-m=%s\nlast_server=1\n' "$(uuid 1)" "$HOME" > "$ST"   # as a watch tick leaves them
"$SALA" master --name >/dev/null 2>&1   # a call with the master set refreshes the last-good copy (common.sh) — the copy to be replaced
same_file "$LASTGOOD" "$HOME/config.orig" || bad "the last-good copy is not the config with the master before the unset"
out=$("$SALA" master --unset 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "master unset (was 'sala-test-m')" && ok "--unset: exit 0" || bad "--unset ($rc): $out"
grep -q '^#SALA_MASTER=' "$SALA_CONFIG" && ! grep -q '^SALA_MASTER=' "$SALA_CONFIG" && grep -q 'was sala-test-m' "$SALA_CONFIG" && ok "the line commented out, the old name noted on it" || bad "config: $(<"$SALA_CONFIG")"
bash -n "$SALA_CONFIG" && grep -q '^SALA_KEEP_ONE="kept one"$' "$SALA_CONFIG" && grep -q '^SALA_KEEP_TWO=kept-two$' "$SALA_CONFIG" && [ "$(lines "$SALA_CONFIG")" = "$(lines "$HOME/config.orig")" ] \
    && ok "the file parses; the other lines intact; no line added or lost" || bad "config after unset: $(<"$SALA_CONFIG")"
[ -z "$("$SALA" config 2>/dev/null | awk '$1=="SALA_MASTER"{print $2}')" ] && ok "salamander config reads no master" || bad "config view: $("$SALA" config | grep SALA_MASTER)"
"$SALA" master --name >/dev/null 2>&1; rc=$?; [ "$rc" = 1 ] && [ -z "$("$SALA" master --name 2>/dev/null)" ] && ok "master --name: empty, exit 1" || bad "--name: rc=$rc"
out=$("$SALA" master --json 2>/dev/null); rc=$?; [ "$rc" = 1 ] && [ "$out" = '{"name": "", "live": false}' ] && ok "master --json: name empty, live false, exit 1" || bad "--json ($rc): $out"
out=$("$SALA" master 2>&1); rc=$?
[ "$rc" = 1 ] && has "$out" "unset on purpose" && has "$out" "was 'sala-test-m'" && has "$out" "sala op" && ! has "$out" "lost or truncated" && ok "master: unset on purpose, the queue named, never 'config lost'" || bad "master ($rc): $out"
for k in master uuid bridge lane_norc cwd.sala-test-m; do grep -q "^$k=" "$ST" && bad "the state still holds $k (watch would act on it)"; done
grep -q '^last_server=1$' "$ST" && [ "$(stv master_unset | cut -d' ' -f1)" = sala-test-m ] && ok "the master's records dropped from the watch state, the others kept, master_unset recorded" || bad "state: $(<"$ST")"
same_file "$SALA_CONFIG" "$LASTGOOD" && ok "the last-good copy is the unset config (a restore from it brings no master back)" || bad "last-good: $(<"$LASTGOOD")"
cp "$SALA_CONFIG" "$HOME/config.unset"; out=$("$SALA" master --unset 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "no master to unset" && same_file "$SALA_CONFIG" "$HOME/config.unset" && ok "idempotent: a second --unset changes nothing, exit 0" || bad "second unset ($rc): $out"
tmux has-session -t =sala-test-m 2>/dev/null && [ -n "$(cpid sala-test-m)" ] && ok "the session itself is untouched by --unset" || bad "the session m changed"
out=$("$SALA" master --set sala-test-m 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$("$SALA" master --name 2>/dev/null)" = sala-test-m ] && [ -z "$(stv master_unset)" ] && bash -n "$SALA_CONFIG" && ok "--set again: the config names it, master_unset dropped" || bad "--set ($rc): $out / $(<"$SALA_CONFIG")"

echo "== sala op retire <the master>: the unit unsets SALA_MASTER first, then retires — one operation"
: > "$POSTS"
enq retire sala-test-m --from sala-test-h --words "retire the master"; R="$ID"
[ -n "$R" ] && has "$OUT" "would unset SALA_MASTER, then retire" && ok "queued op $R, the plan says it unsets first" || bad "enqueue: $OUT"
tick; waitfor "[ -f '$DONE/$R.op' ]" 120 || bad "op $R did not end: $(slurp "$OPS/$R.op")"
L=$(oplog "$R"); u=$(grep -n "unsetting SALA_MASTER first" <<< "$L" | head -1 | cut -d: -f1); r=$(grep -n "running: salamander retire sala-test-m" <<< "$L" | head -1 | cut -d: -f1)
[ -n "$u" ] && [ -n "$r" ] && [ "$u" -lt "$r" ] && has "$L" "master unset (was 'sala-test-m')" && ok "the unit's log: the unset (its output included) before the retire" || bad "unit log: $L"
[ "$(mval "$R" state)" = done ] && [ "$(mval "$R" unset_master)" = sala-test-m ] && ok "done; unset_master=sala-test-m on the marker" || bad "marker: $(slurp "$DONE/$R.op")"
! tmux has-session -t =sala-test-m 2>/dev/null && ok "the session is gone" || bad "sala-test-m still lives"
"$SALA" master --name >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q '^#SALA_MASTER=' "$SALA_CONFIG" && ! grep -q '^SALA_MASTER=' "$SALA_CONFIG" && [ "$(stv master_unset | cut -d' ' -f1)" = sala-test-m ] && ok "the config names no master; master_unset recorded" || bad "after the op: rc=$rc config: $(<"$SALA_CONFIG") state: $(<"$ST")"
P=$(post "retire sala-test-m · done"); [ -n "$P" ] && has "$P" "SALA_MASTER was unset first: 'sala-test-m' is no longer the session the watchdog keeps alive" && ! has "$P" "makes it so again" && ok "one post: done, the unset named" || bad "post: [$P] posts file: [$(<"$POSTS")] unit log tail: $(oplog "$R" | tail -6)"
wait_lock

echo "== a retire that fails after the unset: stuck, SALA_MASTER stays unset, the session alive, the post says how to put it back"
"$SALA" master --set sala-test-a >/dev/null 2>&1 || bad "could not make a the master"
: > "$POSTS"; rm -f "$HOME/helper-runs.txt"
touch "$HOME/norun"; enq retire sala-test-a --from sala-test-h --words "retire a"; R2="$ID"; [ -n "$R2" ] || bad "retire a not queued: $OUT"
regstatus sala-test-a busy; rm -f "$HOME/norun"   # busy by the time it runs: the retire refuses, after the unset
tick; waitfor "[ -f '$DONE/$R2.op' ]" 120 || bad "op $R2 did not end: $(slurp "$OPS/$R2.op")"
[ "$(mval "$R2" state)" = stuck ] && [ "$(mval "$R2" unset_master)" = sala-test-a ] && tmux has-session -t =sala-test-a 2>/dev/null && [ -n "$(cpid sala-test-a)" ] && ok "stuck; the session alive; unset_master on the marker" || bad "marker: $(slurp "$DONE/$R2.op")"
"$SALA" master --name >/dev/null 2>&1; rc=$?; [ "$rc" = 1 ] && ! grep -q '^SALA_MASTER=' "$SALA_CONFIG" && ok "SALA_MASTER stays unset" || bad "master after the failed retire: rc=$rc"
P=$(post "retire sala-test-a · stuck"); [ -n "$P" ] && has "$P" "SALA_MASTER was unset first: 'sala-test-a'" && has "$P" "salamander master --set sala-test-a makes it so again" && ok "the post: unset first, and how to make it the master again" || bad "post: $P"
regstatus sala-test-a idle; wait_lock

echo "== an unset that fails: stuck, the retire never started, the config untouched"
"$SALA" master --set sala-test-a >/dev/null 2>&1 || bad "could not make a the master again"
cp "$SALA_CONFIG" "$HOME/config.a"; : > "$POSTS"
touch "$HOME/norun"; enq retire sala-test-a --from sala-test-h --words "retire a"; R3="$ID"; [ -n "$R3" ] || bad "retire a not queued: $OUT"
chmod 555 "$HOME/.config/salamander"; rm -f "$HOME/norun"   # the config's directory read-only: the edit cannot be made
tick; waitfor "[ -f '$DONE/$R3.op' ]" 120 || bad "op $R3 did not end: $(slurp "$OPS/$R3.op")"
chmod 755 "$HOME/.config/salamander"
L=$(oplog "$R3")
[ "$(mval "$R3" state)" = stuck ] && has "$L" "master --unset exited 1" && has "$L" "did not start" && [ -z "$(mval "$R3" unset_master)" ] && ok "stuck: the unset failed, said so; no unset_master on the marker" || bad "marker: $(slurp "$DONE/$R3.op") log: $L"
! has "$L" "running: salamander retire" && tmux has-session -t =sala-test-a 2>/dev/null && same_file "$SALA_CONFIG" "$HOME/config.a" && [ "$("$SALA" master --name 2>/dev/null)" = sala-test-a ] && ok "the retire never ran; the config untouched; a still the master" || bad "after the failed unset: config $(<"$SALA_CONFIG")"
wait_lock

echo "== no master from here on"
"$SALA" master --unset >/dev/null 2>&1 || bad "the unset failed"
"$SALA" master --name >/dev/null 2>&1; rc=$?; [ "$rc" = 1 ] && tmux has-session -t =sala-test-a 2>/dev/null && ok "unset; a is a plain session" || bad "unset: rc=$rc"

echo "== the guards with no master: a Claude caller is refused and pointed to the queue; everyone else passes"
n0=$(starts "$(uuid 3)")
out=$(under_claude "$SALA" retire nosuch 2>&1); rc=$?
[ "$rc" != 0 ] && has "$out" "retire is a fleet operation, and a session never runs one itself" && has "$out" 'sala op retire … --from <you> --words "<Rowan'"'"'s words>"' && ok "retire under a claude: refused, the queue's line in the message" || bad "retire under claude ($rc): $out"
out=$(under_claude "$SALA" recycle --force 2>&1); rc=$?
[ "$rc" != 0 ] && has "$out" "sala op recycle" && [ "$(starts "$(uuid 3)")" = "$n0" ] && ok "recycle --force under a claude: refused, no pane relaunched" || bad "recycle under claude ($rc): $out"
out=$(under_claude "$SALA" restore nosuch 2>&1); rc=$?
[ "$rc" != 0 ] && has "$out" "restore is a fleet operation" && has "$out" "sala op restore --only NAME --why" && ok "a raw restore under claude: refused, and the text points to the queued verb" || bad "restore under claude ($rc): $out"
# model: the queue has the verb now. The target must exist and not be a sala-test-* name (those pass the guard),
# so a plain tmux session stands in for a fleet pane; its record is never written, nothing relaunched.
$T new-session -d -s nomodel-x -c "$HOME"
out=$(under_claude "$SALA" model nomodel-x opus --effort high 2>&1); rc=$?
[ "$rc" != 0 ] && has "$out" "model is a fleet operation, and a session never runs one itself" && has "$out" 'sala op model … --from <you> --words "<Rowan'"'"'s words>"' && ! has "$out" "no 'model' verb yet" \
    && [ ! -s "$HOME/.local/state/salamander/models.tsv" ] && ok "model under a claude: refused with the queue's pointer (the queue has the verb), no record written" || bad "model under claude ($rc): $out / $(slurp "$HOME/.local/state/salamander/models.tsv")"
mkdir -p "$HOME/.local/state/salamander"; printf 'nomodel-x\topus\t-\n' > "$HOME/.local/state/salamander/models.tsv"
out=$(under_claude "$SALA" model nomodel-x --clear 2>&1); rc=$?
[ "$rc" != 0 ] && has "$out" "sala op model … --from" && grep -q '^nomodel-x' "$HOME/.local/state/salamander/models.tsv" && ok "model --clear under a claude: refused with the queue's pointer, the record kept" || bad "model --clear ($rc): $out"
rm -f "$HOME/.local/state/salamander/models.tsv"
out=$(under_claude "$SALA" model nomodel-x opus --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && ! has "$out" "fleet operation" && has "$out" "DRY RUN" && ok "model --dry-run under a claude: passes (the queue's plan runs it)" || bad "model --dry-run ($rc): $out"
out=$(under_claude "$SALA" model 2>&1); rc=$?
[ "$rc" = 0 ] && ! has "$out" "fleet operation" && has "$out" "nothing recorded" && ok "the table form (no argument) under a claude: read-only, stays open" || bad "model table ($rc): $out"
$T kill-session -t nomodel-x 2>/dev/null
out=$(under_claude env SALA_CGROUP_FILE="$HOME/op-unit.cgroup" "$SALA" retire nosuch 2>&1)
! has "$out" "fleet operation" && ok "the queue's cgroup: admitted (retire goes on to its own refusal)" || bad "cgroup: $out"
out=$(under_claude "$SALA" retire sala-test-nosuch 2>&1); ! has "$out" "fleet operation" && ok "a sala-test-* target: passes" || bad "sala-test target: $out"
out=$(under_claude "$SALA" retire nosuch --dry-run 2>&1); ! has "$out" "fleet operation" && ok "--dry-run: passes" || bad "dry-run: $out"
out=$(under_claude "$SALA" retire nosuch --not-master 2>&1); ! has "$out" "fleet operation" && ok "--not-master: passes" || bad "not-master: $out"
under_claude bash -c ". '$ROOT/lib/common.sh'; master_guard recycle --check" >/dev/null 2>&1 && ok "--check: passes" || bad "--check refused"
tmux new-session -d -s sala-test-shell -c "$HOME" "'$SALA' retire nosuch > '$HOME/shell.out' 2>&1; echo rc=\$? >> '$HOME/shell.out'; sleep 300"
waitfor "grep -q '^rc=' '$HOME/shell.out' 2>/dev/null" 40 || bad "the pane shell's call did not end"
! grep -q "fleet operation" "$HOME/shell.out" && ok "a human's pane shell (TMUX_PANE set, no claude in it, tmux above): passes" || bad "pane shell: $(<"$HOME/shell.out")"
tmux run-shell "env -u TMUX_PANE '$SALA' retire nosuch > '$HOME/hook.out' 2>&1; echo rc=\$? >> '$HOME/hook.out'"
grep -q '^rc=' "$HOME/hook.out" && ! grep -q "fleet operation" "$HOME/hook.out" && ok "a tmux run-shell (the resurrect hook's way): passes" || bad "run-shell: $(slurp "$HOME/hook.out")"

echo "== sala cue with no master: the pointer, nothing delivered"
c0=$(lines "$CUELOG"); s0=$(lines "$SOCKLOG"); m0=$(lines "$MSOCKLOG")
out=$("$SALA" cue --from sala-test-h "recycle claude" 2>&1); rc=$?
[ "$rc" = 1 ] && has "$out" "no master session is configured: a cue has nobody to go to" && has "$out" "sala op <verb> [args…] --from sala-test-h --words" && has "$out" "verbs:" && has "$out" "recycle" && has "$out" "retire" \
    && has "$out" 'e.g.   sala op recycle --update --force --from sala-test-h --words "recycle claude"' && ok "cue: exit 1, the pointer, the verb table, one example" || bad "cue ($rc): $out"
[ "$(lines "$CUELOG")" = "$c0" ] && [ "$(lines "$SOCKLOG")" = "$s0" ] && [ "$(lines "$MSOCKLOG")" = "$m0" ] && ok "nothing delivered to any inbox, nothing logged" || bad "cue delivered or logged something"

echo "== the boot hook's revive with no master: launched by tmux, it passes the guard, relaunches the panes, leaves the boot record"
rm -f "$REC"; h0=$(starts "$(uuid 2)"); a0=$(starts "$(uuid 3)")
tmux run-shell -b "env -u TMUX_PANE '$SALA' revive --force > '$HOME/boot.out' 2>&1; echo rc=\$? >> '$HOME/boot.out'"
waitfor "grep -q '^rc=' '$HOME/boot.out' 2>/dev/null" 160 || bad "the boot revive did not end: $(slurp "$HOME/boot.out")"
grep -q '^rc=0' "$HOME/boot.out" && ! grep -q "fleet operation" "$HOME/boot.out" && ok "passed the guard (no claude above tmux), exit 0" || bad "boot revive: $(<"$HOME/boot.out")"
waitfor "[ \"\$(starts $(uuid 2))\" = $((h0 + 1)) ] && [ \"\$(starts $(uuid 3))\" = $((a0 + 1)) ]" 60 && ok "the panes relaunched (h and a resumed once more)" || bad "starts: h $(starts "$(uuid 2)") a $(starts "$(uuid 3)")"
[ "$(head -1 "$REC" 2>/dev/null)" = "$(cat /proc/sys/kernel/random/boot_id)" ] && sed -n 3p "$REC" | grep -q 'resumed' && ok "the boot record left for the report: this boot's id, the summary" || bad "boot record: $(slurp "$REC")"
wait_lock; fake_up sala-test-h sala-test-a sala-test-b || bad "the panes did not come back"

echo "== watch with no master: --check, the lost config, a plain tick that heals nothing"
out=$("$SALA" watch --check 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "healthy: no master session" && has "$out" "on purpose" && ok "--check: healthy, exit 0, the unset named" || bad "--check ($rc): $out"
cp "$ST" "$HOME/st.keep"; sed -i '/^master_unset=/d' "$ST"; echo "master=sala-test-a" >> "$ST"
out=$("$SALA" watch --check 2>&1); rc=$?
[ "$rc" = 1 ] && has "$out" "lost or truncated" && ok "a state that remembers a master with no unset record: the lost config, --check fails" || bad "lost config ($rc): $out"
cp "$HOME/st.keep" "$ST"; "$SALA" watch --check >/dev/null 2>&1 && ok "healthy again with master_unset back" || bad "--check after restoring the state"
: > "$WLOG"; : > "$POSTS"; n0=$(starts "$(uuid 3)"); t0=$(lines "$FAKE_TYPED_LOG")
"$SALA" watch >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ! grep -q 'HEAL' "$WLOG" && ! tmux has-session -t =sala-test-m 2>/dev/null && ok "a plain tick: exit 0, no heal, the retired master not recreated" || bad "plain tick (rc=$rc): $(<"$WLOG")"
[ "$(starts "$(uuid 3)")" = "$n0" ] && [ "$(lines "$FAKE_TYPED_LOG")" = "$t0" ] && ok "nothing relaunched, nothing typed into a pane (no /remote-control)" || bad "starts $(starts "$(uuid 3)") vs $n0; typed: $(tail -3 "$FAKE_TYPED_LOG" 2>/dev/null)"
[ "$(posts)" = 0 ] && ! grep -q '^master=' "$ST" && ok "nothing posted, no master record written to the state" || bad "posts $(posts): $(<"$POSTS"); state: $(<"$ST")"

echo "== the post-boot report with no master: one Slack post per boot, at once, not twice"
printf 'boot-test-1\n%s\n2 resumed · 0 updated · 1 already running · 0 skipped (target 9.9.9)\n' "$(date +%s)" > "$REC"
: > "$POSTS"; SALA_BOOT_ID=boot-test-1 "$SALA" watch >/dev/null 2>&1
P=$(post "came back up"); [ "$(posts)" = 1 ] && has "$P" "the post-boot report" && has "$P" "no master session is configured, so it comes here" && has "$P" "2 resumed · 0 updated" && ok "one post: the report, with revive's summary" || bad "boot post: $(<"$POSTS")"
SALA_BOOT_ID=boot-test-1 "$SALA" watch >/dev/null 2>&1
[ "$(posts)" = 1 ] && [ "$(stv boot_announced)" = boot-test-1 ] && ok "the next tick: no second post; the boot recorded as announced" || bad "second tick: $(posts) posts, boot_announced=$(stv boot_announced)"

echo "== the tmux server down, no tmux.service, no master: reported, no bare session made"
tmux kill-server 2>/dev/null; sleep 1; : > "$WLOG"; : > "$POSTS"
"$SALA" watch >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'tmux server down: no tmux.service to start, and no master session' "$WLOG" && ! tmux has-session 2>/dev/null && [ "$(posts)" = 0 ] && ok "logged; nothing started, nothing posted" || bad "server down (rc=$rc): $(<"$WLOG") / $(<"$POSTS")"

[ "$fail" = 0 ] && echo "nomaster: pass" || echo "nomaster: FAIL"
exit $fail
