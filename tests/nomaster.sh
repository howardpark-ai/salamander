#!/usr/bin/env bash
# No master session: the master path is retired (sala no longer keeps, heals, bridges, hands work to or unsets one), and a
# SALA_MASTER line still in a config only draws one notice. What is checked is the guards and the watch with and without a
# left-over line:
#  - the guards with no master (lib/common.sh, claude_caller): a Claude ancestor refused with the `sala op` pointer and
#    nothing run; the queue's cgroup admitted; a tmux-launched caller (the resurrect boot hook, a human's pane shell)
#    passes; a sala-test-* target, --dry-run and --check pass; a verb the queue has no shape for refused with
#    that said; `model` (the queue has the verb) refused with the `sala op model` pointer, its --dry-run and the
#    no-argument table form left open; the control: a SALA_MASTER line left in the config exempts no one.
#  - `sala master` and `sala cue` are unknown subcommands (exit 2, nothing delivered).
#  - `watch` with no master: `--check` healthy and exit 0; a plain tick heals, recreates and bridges nothing and types
#    nothing; the post-boot report as one Slack post per boot, not twice; the tmux server down with no tmux.service:
#    reported, no bare session made.
#  - a SALA_MASTER line left in the config: the tick says once per value that the master path is retired (one post, one
#    log line, the state key master_retired_warned) and never exits 1; a second tick posts nothing; a changed value says it
#    again; an emptied one drops the key so the line added again warns again; `watch --check` prints the same line,
#    writes no state and exits 0 ending on "healthy:"; that session is revived by the bare-pane revive like any other.
#  - the boot hook's revive with no master: launched by tmux (no Claude ancestor), it passes the guard, relaunches the
#    panes and leaves the boot record the report reads.
# Isolated HOME, a private tmux socket, the compiled fake claude; systemd-run and systemctl are stubs (the unit runs
# detached, in the queue's cgroup as the real unit does), the claude -p is a stub, Slack is a file; nothing real is
# touched. A Claude ancestor is modelled by a script named `claude` (comm = claude, what the ancestry walk reads), so each
# verdict holds by construction whether the suite runs from a Claude session's pane or in CI.
# Usage: bash tests/nomaster.sh   (exit 0 = pass; ~15 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_MASTER SALA_SET SALA_SET_SELF SALA_RECYCLE SALA_RETRY_WORKER SALA_LOCK_WHO SALA_LOCK_WAIT SALA_RELAUNCH_KIND \
      SALA_FLEET_HOSTS SALA_CGROUP_FILE SALA_OP_QUEUE SALA_OP_REBOOT SALA_OP_STUCK SALA_REBOOT_HOOKS SALA_NO_RELAUNCH SALA_BOOT_ID SALA_CONFIG
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, fake_up, tmux_socket_rm; the lane variables unset
export HOME=$(mktemp -d); export SALA_TZ=Etc/UTC
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOME/anc" "$HOME/.config/salamander"
export SALA_CONFIG="$HOME/.config/salamander/config"   # a real config file, the one --unset edits
cat > "$SALA_CONFIG" <<'EOF'
# a test config (tests/nomaster.sh): a left-over master line, commented out where the checks need none
SALA_MASTER=sala-test-m   # the master
SALA_KEEP_ONE="kept one"
SALA_KEEP_TWO=kept-two
EOF
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
OPS="$HOME/.local/state/salamander/ops"; DONE="$OPS/done"
ST="$HOME/.claude/salamander-watch.state"; WLOG="$HOME/.claude/salamander-watch.log"
REC="$HOME/.claude/salamander-boot-revive"; LOCK="$HOME/.claude/salamander-recycle.lock"
mk() { local n="$1" u="$2"; shift 2; $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="sala-test-$n" -e FAKE_LOG="$FAKE_LOG" "$@"; $T send-keys -t "sala-test-$n" 'claude' Enter; }
posts() { local n; n=$(grep -c '^%%$' "$POSTS" 2>/dev/null); echo "${n:-0}"; }   # grep -c prints 0 and exits 1 on no match: never `|| echo 0`
wait_lock() { lock_wait "$LOCK" 120; }
stv() { awk -F= -v k="$1" '$1==k {print substr($0, length(k)+2); exit}' "$ST" 2>/dev/null; }
lines() { local n; n=$(grep -c . "$1" 2>/dev/null); echo "${n:-0}"; }
starts() { local n; n=$(grep -c "^start $1" "$FAKE_LOG" 2>/dev/null); echo "${n:-0}"; }

echo "== setup: the sessions h, a and b on the fake claude (no session m: the config names one that is not running)"
mk h "$(uuid 2)"; mk a "$(uuid 3)"; mk b "$(uuid 4)"
fake_up sala-test-h sala-test-a sala-test-b || exit 1
for n in h a b; do "$SALA" adopt "sala-test-$n" >/dev/null 2>&1 || bad "adopt sala-test-$n failed"; done   # into the pane map, as spawned sessions are: the tick's unmapped report is not under test

echo "== a master line left in the config (the control): it exempts no one, a Claude caller outside tmux is refused as with none"
out=$(under_claude "$SALA" retire nosuch 2>&1); rc=$?
[ "$rc" != 0 ] && has "$out" "fleet operation" && has "$out" "sala op" && ok "a SALA_MASTER line in the config, a Claude caller outside tmux: refused and pointed to the queue, as with none" || bad "control ($rc): $out"

unset_master_line() { sed -i 's/^SALA_MASTER=/#SALA_MASTER=/' "$SALA_CONFIG"; }   # the line a config still carries, commented out (sala neither writes nor unsets it)
set_master() { printf 'SALA_MASTER=%s\n' "$1" >> "$SALA_CONFIG"; }   # <name> - the line put back by hand; the later line wins
echo "== no master from here on: the line commented out"; unset_master_line

echo "== sala master and sala cue are gone: unknown subcommands, with or without a master line"
for v in master cue; do
    out=$("$SALA" "$v" 2>&1); rc=$?
    [ "$rc" = 2 ] && has "$out" "unknown subcommand '$v'" && ok "sala $v: unknown subcommand, exit 2" || bad "sala $v ($rc): $out"
done
out=$("$SALA" master --unset 2>&1); rc=$?; [ "$rc" = 2 ] && has "$out" "unknown subcommand 'master'" && grep -q '^#SALA_MASTER=' "$SALA_CONFIG" && ok "sala master --unset: unknown too, the config untouched" || bad "master --unset ($rc): $out"
out=$("$SALA" cue --from sala-test-h "recycle claude" 2>&1); rc=$?; [ "$rc" = 2 ] && has "$out" "unknown subcommand 'cue'" && ok "sala cue \"<words>\": unknown, nothing delivered" || bad "cue ($rc): $out"

echo "== the guards with no master: a Claude caller is refused and pointed to the queue; everyone else passes"
n0=$(starts "$(uuid 3)")
out=$(under_claude "$SALA" retire nosuch 2>&1); rc=$?
[ "$rc" != 0 ] && has "$out" "retire is a fleet operation, and a session never runs one itself" && has "$out" 'sala op retire … --from <you> --words "<Rowan'"'"'s words>"' && ok "retire under a claude: refused, the queue's line in the message" || bad "retire under claude ($rc): $out"
out=$(under_claude "$SALA" recycle --force 2>&1); rc=$?
[ "$rc" != 0 ] && has "$out" "sala op recycle" && [ "$(starts "$(uuid 3)")" = "$n0" ] && ok "recycle --force under a claude: refused, no pane relaunched" || bad "recycle under claude ($rc): $out"
out=$(under_claude "$SALA" restore nosuch 2>&1); rc=$?
[ "$rc" != 0 ] && has "$out" "restore is a fleet operation" && has "$out" "sala op restore --only NAME --why" && ok "a raw restore under claude: refused, and the text points to the queued verb" || bad "restore under claude ($rc): $out"
out=$(under_claude "$SALA" adopt nosuch 2>&1); rc=$?
[ "$rc" != 0 ] && has "$out" "adopt is a fleet operation" && ! has "$out" "--not-master" && ! has "$out" "--master" && ! has "$out" "override" && ok "a raw adopt under claude (no queue shape): refused, and the reply names no flag" || bad "adopt under claude ($rc): $out"
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
under_claude bash -c ". '$ROOT/lib/common.sh'; fleet_guard recycle --check" >/dev/null 2>&1 && ok "--check: passes" || bad "--check refused"
tmux new-session -d -s sala-test-shell -c "$HOME" "'$SALA' retire nosuch > '$HOME/shell.out' 2>&1; echo rc=\$? >> '$HOME/shell.out'; sleep 300"
waitfor "grep -q '^rc=' '$HOME/shell.out' 2>/dev/null" 40 || bad "the pane shell's call did not end"
! grep -q "fleet operation" "$HOME/shell.out" && ok "a human's pane shell (TMUX_PANE set, no claude in it, tmux above): passes" || bad "pane shell: $(<"$HOME/shell.out")"
tmux run-shell "env -u TMUX_PANE '$SALA' retire nosuch > '$HOME/hook.out' 2>&1; echo rc=\$? >> '$HOME/hook.out'"
grep -q '^rc=' "$HOME/hook.out" && ! grep -q "fleet operation" "$HOME/hook.out" && ok "a tmux run-shell (the resurrect hook's way): passes" || bad "run-shell: $(slurp "$HOME/hook.out")"

echo "== the boot hook's revive with no master: launched by tmux, it passes the guard, relaunches the panes, leaves the boot record"
rm -f "$REC"; h0=$(starts "$(uuid 2)"); a0=$(starts "$(uuid 3)")
tmux run-shell -b "env -u TMUX_PANE '$SALA' revive --force > '$HOME/boot.out' 2>&1; echo rc=\$? >> '$HOME/boot.out'"
waitfor "grep -q '^rc=' '$HOME/boot.out' 2>/dev/null" 160 || bad "the boot revive did not end: $(slurp "$HOME/boot.out")"
grep -q '^rc=0' "$HOME/boot.out" && ! grep -q "fleet operation" "$HOME/boot.out" && ok "passed the guard (no claude above tmux), exit 0" || bad "boot revive: $(<"$HOME/boot.out")"
waitfor "[ \"\$(starts $(uuid 2))\" = $((h0 + 1)) ] && [ \"\$(starts $(uuid 3))\" = $((a0 + 1)) ]" 60 && ok "the panes relaunched (h and a resumed once more)" || bad "starts: h $(starts "$(uuid 2)") a $(starts "$(uuid 3)")"
[ "$(head -1 "$REC" 2>/dev/null)" = "$(cat /proc/sys/kernel/random/boot_id)" ] && sed -n 3p "$REC" | grep -q 'resumed' && ok "the boot record left for the report: this boot's id, the summary" || bad "boot record: $(slurp "$REC")"
wait_lock; fake_up sala-test-h sala-test-a sala-test-b || bad "the panes did not come back"

echo "== watch with no master: --check, a plain tick that heals nothing"
out=$("$SALA" watch --check 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(tail -1 <<< "$out" | cut -c1-8)" = "healthy:" ] && [ "$(tail -1 <<< "$out" | wc -c)" -le 61 ] && ! has "$out" "retired" && ok "--check: exit 0, the last line leads with healthy: and is at most 60 characters (provision's step cuts it there), no warning" || bad "--check ($rc): $out"
: > "$WLOG"; : > "$POSTS"; n0=$(starts "$(uuid 3)"); t0=$(lines "$FAKE_TYPED_LOG")
"$SALA" watch >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ! grep -q 'HEAL' "$WLOG" && ! tmux has-session -t =sala-test-m 2>/dev/null && ok "a plain tick: exit 0, no heal, the retired master not recreated" || bad "plain tick (rc=$rc): $(<"$WLOG")"
[ "$(starts "$(uuid 3)")" = "$n0" ] && [ "$(lines "$FAKE_TYPED_LOG")" = "$t0" ] && ok "nothing relaunched, nothing typed into a pane (no /remote-control)" || bad "starts $(starts "$(uuid 3)") vs $n0; typed: $(tail -3 "$FAKE_TYPED_LOG" 2>/dev/null)"
[ "$(posts)" = 0 ] && ! grep -q '^master=' "$ST" && [ -z "$(stv master_retired_warned)" ] && ok "nothing posted, no master record and no warning key in the state" || bad "posts $(posts): $(<"$POSTS"); state: $(<"$ST")"
! grep -q 'inbox:' "$WLOG" && ok "no held key, no inbox line in the watch log" || bad "inbox line with nothing held: $(grep 'inbox:' "$WLOG")"
# a held key no ledger row accounts for, seen 700 s ago, is freed by the tick and the watch logs it once with the count; a younger one stays
HOLDD=$(. "$ROOT/lib/common.sh" >/dev/null 2>&1; printf %s "$SALA_INBOX_HOLD_DIR"); mkdir -p "$HOLDD" "$HOME/.local/state/salamander"
printf 'orphan-old\norphan-young\n' | tee "$HOLDD/held-msg.txt" > "$HOLDD/held-hub.txt"
printf '%s\torphan-old\n%s\torphan-young\n' "$(( $(date +%s) - 700 ))" "$(( $(date +%s) - 20 ))" > "$HOME/.local/state/salamander/inbox-held-unaccounted.tsv"
: > "$WLOG"; "$SALA" watch >/dev/null 2>&1
[ "$(grep -c 'inbox: freed 1 held key(s) that no hold-ledger row accounts for' "$WLOG")" = 1 ] && grep -q 'inbox: freed 1 .*: orphan-old$' "$WLOG" && ok "the tick logged one line: the count and the key" || bad "watch log: $(<"$WLOG")"
[ "$(cat "$HOLDD/held-msg.txt" "$HOLDD/held-hub.txt" | tr '\n' ' ')" = "orphan-young orphan-young " ] && ok "the old key left both held files, the young one stayed" || bad "held files: $(cat "$HOLDD/held-msg.txt" "$HOLDD/held-hub.txt" | tr '\n' ' ')"
: > "$WLOG"; "$SALA" watch >/dev/null 2>&1
! grep -q 'inbox:' "$WLOG" && ok "the next tick logs nothing about it" || bad "second tick: $(grep 'inbox:' "$WLOG")"
rm -rf "$HOME/.local/state/stackshot"; rm -f "$HOME/.local/state/salamander/inbox-held-unaccounted.tsv"   # nothing of stackshot was here before: the later holds are no-ops again

echo "== the post-boot report with no master: one Slack post per boot, at once, not twice"
printf 'boot-test-1\n%s\n2 resumed · 0 updated · 1 already running · 0 skipped (target 9.9.9)\n' "$(date +%s)" > "$REC"
: > "$POSTS"; SALA_BOOT_ID=boot-test-1 "$SALA" watch >/dev/null 2>&1
P=$(post "came back up"); [ "$(posts)" = 1 ] && has "$P" "the post-boot report" && has "$P" "2 resumed · 0 updated" && ok "one post: the report, with revive's summary" || bad "boot post: $(<"$POSTS")"
SALA_BOOT_ID=boot-test-1 "$SALA" watch >/dev/null 2>&1
[ "$(posts)" = 1 ] && [ "$(stv boot_announced)" = boot-test-1 ] && ok "the next tick: no second post; the boot recorded as announced" || bad "second tick: $(posts) posts, boot_announced=$(stv boot_announced)"

echo "== a SALA_MASTER line left in the config: one notice per value, never an exit 1, nothing healed for it"
export SALA_BOOT_ID=boot-test-1   # the boot already announced above: a tick on a box up past the report's grace posts no boot report of its own in the middle of these counts
set_master sala-test-a
: > "$WLOG"; : > "$POSTS"; n0=$(starts "$(uuid 3)")
"$SALA" watch >/dev/null 2>&1; rc=$?
P=$(post "master path is retired")
[ "$rc" = 0 ] && [ "$(posts)" = 1 ] && has "$P" "SALA_MASTER=sala-test-a" && grep -q 'the watchdog no longer keeps, heals or restarts the master' "$WLOG" && [ "$(stv master_retired_warned)" = sala-test-a ] && ok "one tick: exit 0, one post naming the value, one log line, the state key set" || bad "warn tick (rc=$rc): posts $(posts): $(<"$POSTS") / $(<"$WLOG") / $(<"$ST")"
! grep -q 'HEAL' "$WLOG" && [ "$(starts "$(uuid 3)")" = "$n0" ] && ok "nothing healed or relaunched for the line" || bad "a heal for the left-over line: $(<"$WLOG")"
out=$("$SALA" op --plan retire sala-test-a 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "plan: salamander retire sala-test-a" && ! has "$out" "unset" && ! has "$out" "master" && ok "op --plan retire <the left-over line's session>: an ordinary retire, nothing unset first" || bad "plan ($rc): $out"
out=$("$SALA" retire sala-test-a --dry-run 2>&1); rc=$?
! has "$out" "master session" && ! has "$out" "unset" && ok "retire --dry-run <that session>: no master refusal" || bad "retire dry run ($rc): $out"
"$SALA" watch >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(posts)" = 1 ] && [ "$(grep -v NOTIFY "$WLOG" | grep -c 'the watchdog no longer keeps, heals or restarts the master')" = 1 ] && ok "a second tick: no second post, no second log line" || bad "second tick (rc=$rc): posts $(posts) / $(<"$WLOG")"
cp "$ST" "$HOME/st.warned"; out=$("$SALA" watch --check 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "SALA_MASTER=sala-test-a is set" && has "$out" "will be removed in a later change" && ! has "$out" "does nothing" && [ "$(tail -1 <<< "$out" | cut -c1-8)" = "healthy:" ] && [ "$(tail -1 <<< "$out" | wc -c)" -le 61 ] && same_file "$ST" "$HOME/st.warned" && [ "$(posts)" = 1 ] && ok "--check: prints the line, exit 0, ends on healthy:, writes no state, posts nothing" || bad "--check with the line ($rc): $out"
sed -i '/^master_retired_warned=/d' "$ST"; "$SALA" watch --check >/dev/null 2>&1; [ -z "$(stv master_retired_warned)" ] && ok "--check on a state without the key leaves it without" || bad "--check wrote the key"
: > "$POSTS"; "$SALA" watch >/dev/null 2>&1   # the key was removed above: this tick says it once more
[ "$(posts)" = 1 ] && [ "$(stv master_retired_warned)" = sala-test-a ] || bad "re-warn after the key was dropped: posts $(posts), key [$(stv master_retired_warned)]"
set_master sala-test-b; : > "$POSTS"; "$SALA" watch >/dev/null 2>&1
P=$(post "master path is retired"); [ "$(posts)" = 1 ] && has "$P" "SALA_MASTER=sala-test-b" && [ "$(stv master_retired_warned)" = sala-test-b ] && ok "a changed value says it again, once" || bad "changed value: posts $(posts): $(<"$POSTS")"
unset_master_line; : > "$POSTS"; "$SALA" watch >/dev/null 2>&1
[ -z "$(stv master_retired_warned)" ] && [ "$(posts)" = 0 ] && ok "the line emptied: the key dropped, nothing posted" || bad "emptied: key [$(stv master_retired_warned)] posts $(posts): $(<"$POSTS")"
set_master sala-test-b; : > "$POSTS"; "$SALA" watch >/dev/null 2>&1
[ "$(posts)" = 1 ] && [ "$(stv master_retired_warned)" = sala-test-b ] && ok "the line added again after it was dropped: warns again" || bad "re-added: posts $(posts): $(<"$POSTS")"

unset_master_line   # the bare-pane revive of a pane named like the former master is tests/barepane.sh's

echo "== the tmux server down, no tmux.service: reported, no bare session made"
tmux kill-server 2>/dev/null; sleep 1; : > "$WLOG"; : > "$POSTS"
"$SALA" watch >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'tmux server down: no tmux.service to start' "$WLOG" && ! tmux has-session 2>/dev/null && [ "$(posts)" = 0 ] && ok "logged; nothing started, nothing posted" || bad "server down (rc=$rc): $(<"$WLOG") / $(<"$POSTS")"

[ "$fail" = 0 ] && echo "nomaster: pass" || echo "nomaster: FAIL"
exit $fail
