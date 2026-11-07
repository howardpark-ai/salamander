#!/usr/bin/env bash
# The pane-map ledger, the second half (split out of tests/ledger.sh so the two run side by side; the ledger's honored
# paths, the freeze, `sala restore` and the migration are ledger.sh's): compare and restore at the end of a recycle (the
# real driver: freeze → sweep → compare → unfreeze) and of a reboot (`reboot --resume` standing in for the boot half); the
# map gaps of 2026-10-08 (a rename never adds a row, a follow never duplicates a conversation, the fleet's tmux server
# only, a probe server's claude sharing a fleet pane's id, retire of an orphan row, no archive by a shared conversation
# id). The setup mirrors where ledger.sh leaves its map: three rows (m, a2, b), each adopted from a session made by hand
# in its own directory. Isolated HOME, a private tmux socket, the compiled fake claude (tests/fake-claude.c); every Slack
# post lands in a file.
# Usage: bash tests/ledger-recycle.sh   (exit 0 = pass; ~50 s)
set -u
unset TMUX_PANE XDG_STATE_HOME   # never a pane of the real server; the default state path is what is under test
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, tmux_socket_rm
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null
as_op_unit   # no master: the guarded verbs this suite runs itself stand for the queue's runner (tests/lib.sh, 5)
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOME/work-a" "$HOME/work-b" "$HOME/work-c" "$HOME/work-m"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
cc -o "$HOME/.local/bin/claude" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
export PATH="$HOME/.local/bin:$PATH"; export FAKE_LOG="$HOME/fake.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="cat >> $POSTS"   # no post leaves the box
export SALA_AUTO_UPDATE=off SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT"
SALA="$ROOT/bin/salamander"; SOCK="sala-ledger-recycle-$$"; T="tmux -L $SOCK -f /dev/null"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's (common.sh, on_fleet_server)
cleanup() {  # drivers and retry workers the tests may have left, the tmux server (its panes take the fakes with it), the HOME
    local f p
    for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done
    [ -n "${DRIVER:-}" ] && kill -TERM -- -"$DRIVER" 2>/dev/null
    $T kill-server 2>/dev/null; env -u 'BASH_FUNC_tmux%%' tmux -L "$SOCK-probe" kill-server 2>/dev/null; tmux_socket_rm; tmux_socket_rm "$SOCK-probe"; sleep 1
    for p in $(pgrep -x claude); do [ "$HOME/.local/bin/claude" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done   # only our fakes
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
UM=aaaaaaaa-0000-4000-8000-00000000000a UA=bbbbbbbb-0000-4000-8000-000000000001 UB=cccccccc-0000-4000-8000-000000000002 UX=eeeeeeee-0000-4000-8000-000000000004
row() { awk -F'\t' -v s="$1" '$1==s' "$MAP" 2>/dev/null; }            # the session's row
logn() { grep -c "	$1	$2	" "$LOG" 2>/dev/null || true; }           # ledger-log lines for op + session
regfile() { echo "$HOME/.claude/sessions/$(claude_pid_under "$(tmux display -p -t "$1" '#{pane_pid}')").json"; }
hand() { $T new-session -d -s "$1" -c "$3" -e FAKE_SESSION_ID="$2" -e FAKE_NAME="$1" -e FAKE_LOG="$FAKE_LOG"; $T send-keys -t "$1" 'claude' Enter; }

echo "== setup: three sessions made by hand (m, a2, b, each in its directory), adopted: the map ledger.sh leaves behind"
hand sala-test-m "$UM" "$HOME/work-m"; hand sala-test-a2 "$UA" "$HOME/work-a"; hand sala-test-b "$UB" "$HOME/work-b"; fake_up sala-test-m sala-test-a2 sala-test-b
. "$ROOT/lib/common.sh"; MAP="$SALA_SIDECAR"; LOG="$SALA_LEDGER_LOG"
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux   # literal socket: the children run set -u
pane_claude() { claude_pid_under "$(tmux display -p -t "$1" '#{pane_pid}' 2>/dev/null)"; }   # <session> → its claude's pid
kill_wait() {  # <session>… — kill each tmux session and wait until the claude it ran is gone
    local s c; for s in "$@"; do c=$(pane_claude "$s"); tmux kill-session -t "=$s"; [ -n "$c" ] && waitfor "! kill -0 $c 2>/dev/null" 20; done; return 0; }
relaunch_on() {  # <session> <uuid> — /exit the fake claude in <session>, then `claude --resume <uuid>` there; waits for each step
    local s="$1" u="$2" c; c=$(pane_claude "$s")
    tmux send-keys -t "$s" '/exit' Enter; waitfor "! kill -0 $c 2>/dev/null" 20
    tmux send-keys -t "$s" "claude --resume $u" Enter
    waitfor "[ \"\$(registry_field \"\$(pane_claude $s)\" sessionId 2>/dev/null)\" = $u ]" 20; }
for s in sala-test-m sala-test-a2 sala-test-b; do "$SALA" adopt "$s" >/dev/null 2>&1; done
[ "$(row sala-test-m)" = "sala-test-m	$UM	sala-test-m	$HOME/work-m" ] && [ "$(row sala-test-a2)" = "sala-test-a2	$UA	sala-test-a2	$HOME/work-a" ] && [ "$(row sala-test-b)" = "sala-test-b	$UB	sala-test-b	$HOME/work-b" ] && [ "$(wc -l < "$MAP")" = 3 ] \
    && ok "three rows, each with its session's cwd" || bad "map: $(slurp "$MAP")"
# a reboot hook for the test (the reboot --resume case): state in $HOME/hook.state; every verb records whether the pane map was frozen when it ran
export FREEZE_PATH="$SALA_LEDGER_FREEZE"
cat > "$HOME/hook" <<'EOF'
#!/usr/bin/env bash
# a reboot hook for the test: state in $HOME/hook.state; flush-stop fails while $HOME/hook.fail exists; every verb records
# whether the pane map was frozen when it ran
st="$HOME/hook.state"; echo "$1 frozen=$([ -s "$FREEZE_PATH" ] && echo yes || echo no)" >> "$HOME/hook.log"
case "$1" in
  pause) echo paused > "$st"; echo "paused";;
  flush-stop) [ -e "$HOME/hook.fail" ] && { echo "flush failed (test)"; exit 1; }; echo stopped > "$st"; echo "flushed and stopped";;
  start) echo running > "$st"; echo "started";;
  status) [ "$(cat "$st" 2>/dev/null)" = stopped ] && { echo "stopped"; exit 3; }; echo "running";;
  resume) echo running > "$st"; echo "resumed";;
esac; exit 0
EOF
chmod +x "$HOME/hook"

echo "== compare + restore at the end of a recycle: the real driver (freeze → sweep → compare → unfreeze)"
kill_wait sala-test-a2 sala-test-b
nA=$(grep -c "^start $UA" "$FAKE_LOG"); nB=$(grep -c "^start $UB" "$FAKE_LOG")
out=$(SALA_LOCK_WHO=test-driver "$SALA" recycle --force 2>&1); echo "$out" | grep -q 'recycle started as a detached driver' && ok "recycle detached" || bad "recycle: $out"
LOCK="$HOME/.claude/salamander-recycle.lock"; waitfor '[ -s "$SALA_LEDGER_FREEZE" ] && [ -n "$(cut -f1 "$LOCK" 2>/dev/null)" ]' 20; DRIVER=$(cut -f1 "$LOCK" 2>/dev/null)
[ -s "$SALA_LEDGER_FREEZE" ] && [ "$(ledger_freeze_field owner_pid)" = "$DRIVER" ] && [ "$(ledger_freeze_field reason)" = recycle ] && [ "$(grep -c . "$SALA_LEDGER_FROZEN")" = 3 ] && ok "frozen by the driver (pid $DRIVER), roster of 3 rows" || bad "freeze during the recycle: $(slurp "$SALA_LEDGER_FREEZE") roster: $(slurp "$SALA_LEDGER_FROZEN")"
for ((i=0; i<150; i++)); do flock -n "$LOCK" true 2>/dev/null && break; sleep 1; done; DRIVER=""
flock -n "$LOCK" true 2>/dev/null && ok "driver done in ${i}s" || bad "driver still running after 150 s"
[ ! -e "$SALA_LEDGER_FREEZE" ] && ok "unfrozen at the end" || bad "still frozen: $(<"$SALA_LEDGER_FREEZE")"
for s in sala-test-a2 sala-test-b; do tmux has-session -t "=$s" 2>/dev/null && ok "$s recreated" || bad "$s not recreated"; done
[ "$(tmux display -p -t sala-test-a2 '#{pane_current_path}' 2>/dev/null)" = "$HOME/work-a" ] && [ "$(tmux display -p -t sala-test-b '#{pane_current_path}' 2>/dev/null)" = "$HOME/work-b" ] && ok "each in its own cwd" || bad "cwd: a2=$(tmux display -p -t sala-test-a2 '#{pane_current_path}' 2>/dev/null) b=$(tmux display -p -t sala-test-b '#{pane_current_path}' 2>/dev/null)"
[ "$(registry_field "$(claude_pid_under "$(tmux display -p -t sala-test-a2 '#{pane_pid}' 2>/dev/null)" 2>/dev/null)" sessionId)" = "$UA" ] && [ "$(registry_field "$(claude_pid_under "$(tmux display -p -t sala-test-b '#{pane_pid}' 2>/dev/null)" 2>/dev/null)" sessionId)" = "$UB" ] && ok "each on its own conversation" || bad "conversations wrong after the recycle"
[ "$(grep -c "^start $UA" "$FAKE_LOG")" = $((nA+1)) ] && [ "$(grep -c "^start $UB" "$FAKE_LOG")" = $((nB+1)) ] && ok "each resumed exactly once (no double resume)" || bad "starts: UA $(grep -c "^start $UA" "$FAKE_LOG") (was $nA), UB $(grep -c "^start $UB" "$FAKE_LOG") (was $nB)"
[ "$(wc -l < "$MAP")" = 3 ] && ok "the map still has its 3 rows (the recycle added none)" || bad "map: $(<"$MAP")"
grep -q "	freeze	-	open → recycle" "$LOG" && grep -q "	unfreeze	-	.*recycle done" "$LOG" && ok "log: freeze and unfreeze lines for the recycle" || bad "log: $(tail -3 "$LOG")"
ledger_freeze recycle $$ >/dev/null; out=$(ledger_compare_restore Recycle); ledger_unfreeze test >/dev/null
echo "$out" | grep -q 'every session of the frozen roster (3) exists' && ok "nothing missing → nothing recreated, no post" || bad "compare with nothing missing: $out"

echo "== reboot --resume standing in for the boot half: compare + restore, then unfreeze"
ledger_freeze reboot $$ >/dev/null; kill_wait sala-test-b
printf 'boot_id=not-this-boot\nwritten=%s\npaused_at=%s\npanes=%s\n' "$(date +%s)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$HOME/.claude/salamander-reboot-panes.tsv" > "$HOME/.claude/salamander-reboot.marker"
out=$(SALA_REBOOT_HOOKS="t=$HOME/hook" "$SALA" reboot --resume 2>&1); rc=$?; echo "$out" | grep -E 'Reboot|unfrozen|back in' | sed 's/^/    /'
tmux has-session -t =sala-test-b 2>/dev/null && echo "$out" | grep -q 'Reboot: 1 of the roster' && ok "the missing session was recreated (rc $rc)" || bad "reboot --resume: rc=$rc $out"
[ ! -e "$SALA_LEDGER_FREEZE" ] && ok "unfrozen after the restore" || bad "after --resume: still frozen: $(<"$SALA_LEDGER_FREEZE")"
ls "$HOME/.claude/salamander-reboot.marker.done-"* >/dev/null 2>&1 && ok "marker retired" || bad "marker not retired"


echo "== map gaps (2026-10-08): a rename of a session the map does not have is refused, up front"
UR=ffffffff-0000-4000-8000-000000000005 UR2=ffffffff-0000-4000-8000-000000000006 UD=ffffffff-0000-4000-8000-000000000007 UO=ffffffff-0000-4000-8000-000000000008
setname() { python3 - "$(regfile "$1")" "$2" <<'PY'
import json, sys; p = sys.argv[1]; d = json.load(open(p)); d["name"] = sys.argv[2]; json.dump(d, open(p, "w"))
PY
}
hand sala-test-r "$UR" "$HOME"; fake_up sala-test-r; setname sala-test-r sala-test-r2   # /renamed by hand: nothing to type
out=$("$SALA" rename sala-test-r sala-test-r2 2>&1); rc=$?
[ "$rc" = 4 ] && echo "$out" | grep -q "'sala-test-r' is not in the pane map .*sala adopt sala-test-r first" && ok "refused (rc 4): $(echo "$out" | tail -1 | cut -c1-90)…" || bad "rename of an unmapped session: rc=$rc $out"
tmux has-session -t =sala-test-r 2>/dev/null && ! tmux has-session -t =sala-test-r2 2>/dev/null && [ -z "$(row sala-test-r)$(row sala-test-r2)" ] && ok "nothing half done: the tmux session keeps its name, no row added" || bad "after the refusal: $(tmux ls -F '#{session_name}' | paste -sd' ') / $(row sala-test-r2)"
ledger_write rename sala-test-r sala-test-r2 "$UR" "$HOME" 2>/dev/null; rc=$?
[ "$rc" = 2 ] && [ -z "$(row sala-test-r2)" ] && [ "$(logn 'refused(rename)' sala-test-r)" = 1 ] && ok "the ledger refuses it too (rc 2, a refused(rename) line), no row" || bad "direct rename: rc=$rc row=$(row sala-test-r2) log: $(tail -1 "$LOG")"
echo "== adopt, then the rename works"
"$SALA" adopt sala-test-r >/dev/null 2>&1
out=$(SALA_SESSION_URL= "$SALA" rename sala-test-r sala-test-r2 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(row sala-test-r2)" = "sala-test-r2	$UR	sala-test-r2	$HOME" ] && [ -z "$(row sala-test-r)" ] && ok "adopted, then renamed: one row, under the new name" || bad "adopt then rename: rc=$rc $out / $(row sala-test-r2)"
echo "$out" | grep -qx "✅ 'sala-test-r' is now 'sala-test-r2' · https://claude.ai/code/session_01FAKE" && ok "SALA_SESSION_URL empty: the notice keeps the claude.ai link" || bad "rename notice, empty template: $(echo "$out" | grep -E '^✅|^⚠' | tail -1)"

echo "== follow: never onto a conversation another row carries"
hand sala-test-d "$UD" "$HOME/work-c"; fake_up sala-test-d; "$SALA" adopt sala-test-d >/dev/null 2>&1
relaunch_on sala-test-r2 "$UD"
out=$("$SALA" revive --save-map 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(row sala-test-r2 | cut -f2)" = "$UR" ] && [ "$(row sala-test-d | cut -f2)" = "$UD" ] && ok "refused: sala-test-r2 keeps $UR, rc 0 ($out)" || bad "dup follow: rc=$rc $out / $(row sala-test-r2)"
[ "$(logn 'refused(follow)' sala-test-r2)" = 1 ] && grep -q "	refused(follow)	sala-test-r2	$UR → $UD: that conversation is already the row of sala-test-d	" "$LOG" && ok "one refused(follow) line naming both sessions" || bad "log: $(tail -2 "$LOG")"
"$SALA" revive --save-map >/dev/null 2>&1; [ "$(logn 'refused(follow)' sala-test-r2)" = 1 ] && ok "a second save refuses again without a second line" || bad "refused lines: $(logn 'refused(follow)' sala-test-r2)"
ledger_write follow sala-test-r2 "$UD" 2>/dev/null; rc=$?; [ "$rc" = 2 ] && [ "$(row sala-test-r2 | cut -f2)" = "$UR" ] && ok "a direct follow is refused (rc 2)" || bad "direct follow: rc=$rc"
ledger_freeze recycle $$ >/dev/null; "$SALA" revive --save-map >/dev/null 2>&1
grep -q "^sala-test-r2	$UD	" "$SALA_LEDGER_DEFERRED" 2>/dev/null && ok "under a freeze the follow is deferred" || bad "not deferred: $(slurp "$SALA_LEDGER_DEFERRED")"
ledger_unfreeze test >/dev/null 2>&1
[ "$(row sala-test-r2 | cut -f2)" = "$UR" ] && grep '	unfreeze	' "$LOG" | tail -1 | grep -q '; 0 deferred follow(s) applied' && ok "and refused at the unfreeze: 0 deferred follow(s) applied" || bad "after the unfreeze: $(row sala-test-r2) / $(grep '	unfreeze	' "$LOG" | tail -1)"

echo "== the fleet's tmux server only: revive, snapshot and map writes leave any other server alone"
relaunch_on sala-test-r2 "$UR2"   # a follow is due
cp "$MAP" "$HOME/map.before"
out=$(SALA_TMUX_SOCKET=/nonexistent/fleet "$SALA" revive --save-map 2>&1); rc=$?
[ "$rc" = 0 ] && same_file "$MAP" "$HOME/map.before" && grep -q "	skipped(revive --save-map)	-	not the fleet's tmux server: .*$SOCK (the fleet's is /nonexistent/fleet)	" "$LOG" && ok "another fleet socket: --save-map leaves (rc 0), map untouched, one skipped line" || bad "save-map off the fleet: rc=$rc $out / log: $(tail -1 "$LOG")"
# the 22:03 shape: a hook job of a probe server (tmux gives it TMUX=<probe socket>); started without the suite's tmux wrapper
PT="env -u BASH_FUNC_tmux%% tmux -L $SOCK-probe -f /dev/null"
$PT new-session -d -s probe -c "$HOME" && $PT run-shell "'$SALA' revive --save-map; echo rc=\$? > '$HOME/probe.rc'"
[ "$(slurp "$HOME/probe.rc")" = rc=0 ] && same_file "$MAP" "$HOME/map.before" && grep -q "	skipped(revive --save-map)	-	not the fleet's tmux server: .*$SOCK-probe " "$LOG" && ok "run as a probe server's hook: skipped, map untouched" || bad "probe hook: $(slurp "$HOME/probe.rc") / log: $(tail -1 "$LOG")"
$PT kill-server 2>/dev/null; tmux_socket_rm "$SOCK-probe"
out=$("$SALA" revive --save-map 2>&1); [ "$(row sala-test-r2 | cut -f2)" = "$UR2" ] && ok "on the fleet's server the same save follows ($out)" || bad "fleet save-map: $out / $(row sala-test-r2)"
rm -f "$HOME/snap.done"; SALA_TMUX_SOCKET=/nonexistent/fleet SALA_SNAPSHOT_CMD="touch $HOME/snap.done" "$SALA" snapshot --now; rc=$?
[ "$rc" = 0 ] && [ ! -e "$HOME/snap.done" ] && grep -q "	skipped(snapshot)	-	" "$LOG" && ok "snapshot --now off the fleet: nothing saved (rc 0), one skipped line" || bad "snapshot off the fleet: rc=$rc saved=$([ -e "$HOME/snap.done" ] && echo yes || echo no)"
SALA_SNAPSHOT_CMD="touch $HOME/snap.done" "$SALA" snapshot --now; [ -e "$HOME/snap.done" ] && ok "on the fleet's server it saves" || bad "snapshot on the fleet did not save"
SALA_TMUX_SOCKET=/nonexistent/fleet ledger_write add sala-test-z "$UX" 2>/dev/null; rc=$?
[ "$rc" = 2 ] && [ -z "$(row sala-test-z)" ] && grep -q "	refused(add)	sala-test-z	not the fleet's tmux server: " "$LOG" && ok "a map write off the fleet is refused (rc 2) with a log line" || bad "add off the fleet: rc=$rc log: $(tail -1 "$LOG")"

echo "== a claude on a probe server whose pane id is a fleet pane's (a probe's %1 read as a fleet session)"
UPF=ffffffff-0000-4000-8000-000000000011 UPR=ffffffff-0000-4000-8000-000000000012
hand sala-test-pf "$UPF" "$HOME"; fake_up sala-test-pf; "$SALA" adopt sala-test-pf >/dev/null 2>&1
FP=$(tmux list-panes -t =sala-test-pf -F '#{pane_id}' | head -1)
PT="env -u BASH_FUNC_tmux%% tmux -L $SOCK-probe -f /dev/null"; pp=""
for i in $(seq 0 60); do $PT new-session -d -s "p$i" -c "$HOME" -e FAKE_SESSION_ID="$UPR" -e FAKE_NAME=sala-test-probe -e FAKE_LOG="$FAKE_LOG"; pp=$($PT list-panes -t "=p$i" -F '#{pane_id}'); [ "$pp" = "$FP" ] && break; done
[ "$pp" = "$FP" ] && $PT send-keys -t "$pp" claude Enter && fake_up sala-test-probe && ok "a probe claude in the probe server's $pp, the fleet's sala-test-pf is $FP" || bad "no probe pane $FP (last $pp)"
pf=$(grep -l "\"sessionId\":\"$UPR\"" "$HOME"/.claude/sessions/*.json | head -1)
python3 - "$pf" <<'PY2'
import json, sys; p = sys.argv[1]; d = json.load(open(p)); d["name"] = "sala-test-probe"; d["nameSource"] = "user"; json.dump(d, open(p, "w"))
PY2
SALA_MASTER= "$SALA" rename --sync >/dev/null 2>&1
tmux has-session -t =sala-test-pf 2>/dev/null && ! grep -q "'sala-test-pf' → " "$SALA_LOG_DIR/salamander-rename.log" 2>/dev/null \
    && ok "rename --sync: the probe's name is not taken for a hand rename of sala-test-pf" || bad "sync followed the probe: $(grep sala-test-pf "$SALA_LOG_DIR/salamander-rename.log" | tail -1)"
"$SALA" revive --save-map >/dev/null 2>&1
[ "$(row sala-test-pf | cut -f2)" = "$UPF" ] && ok "--save-map: sala-test-pf's row keeps its conversation (no follow onto the probe's)" || bad "row followed the probe: $(row sala-test-pf)"
$PT kill-server 2>/dev/null; tmux_socket_rm "$SOCK-probe"

echo "== forget-row of an orphan row (its tmux session gone): the row alone; retire refuses it and names forget-row"
hand sala-test-o "$UO" "$HOME"; fake_up sala-test-o; "$SALA" adopt sala-test-o >/dev/null 2>&1; kill_wait sala-test-o
[ -n "$(row sala-test-o)" ] || bad "no row for sala-test-o to start from"
out=$("$SALA" retire sala-test-o 2>&1); rc=$?
[ "$rc" != 0 ] && [ -n "$(row sala-test-o)" ] && echo "$out" | grep -q "sala forget-row sala-test-o" && ok "retire of an orphan row: refused, forget-row named, the row kept" || bad "retire orphan: rc=$rc $out"
out=$("$SALA" forget-row sala-test-o 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
[ "$rc" = 0 ] && [ -z "$(row sala-test-o)" ] && echo "$out" | grep -q "its pane-map row removed (nothing killed, no /exit, nothing archived on claude.ai)" && echo "$out" | grep -q "claude --resume $UO" && ok "row dropped, said so, the transcript named" || bad "orphan forget-row: rc=$rc"
[ "$(logn retire sala-test-o)" = 1 ] && ok "one retire line in the ledger log" || bad "retire lines: $(logn retire sala-test-o)"
out=$("$SALA" forget-row sala-test-o 2>&1); rc=$?; [ "$rc" != 0 ] && echo "$out" | grep -q "no pane-map row for 'sala-test-o'" && ok "neither a session nor a row: still an error" || bad "forget-row of nothing: rc=$rc $out"

echo "== retire never archives by a map conversation id another row carries"
mkdir -p "$HOME/.claude/projects/-shared"; printf '{"type":"remote_session_change","url":"https://claude.ai/code/session_01SHARED"}\n' > "$HOME/.claude/projects/-shared/$UD.jsonl"
hand sala-test-s ffffffff-0000-4000-8000-000000000020 "$HOME"; fake_up sala-test-s
python3 - "$(regfile sala-test-s)" <<'PY3'   # a Claude whose registry file names no conversation: retire falls back to the map's id
import json, sys; p = sys.argv[1]; d = json.load(open(p)); d.pop("sessionId", None); json.dump(d, open(p, "w"))
PY3
printf 'sala-test-s\t%s\tsala-test-s\t%s\n' "$UD" "$HOME" >> "$MAP"   # by hand: the duplicate a scrambled follow left (2026-10-08)
out=$("$SALA" retire sala-test-s 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
echo "$out" | grep -q "not archiving on claude.ai: conversation $UD (from the pane map) is also the row of sala-test-d" && ! echo "$out" | grep -q session_01SHARED && ok "warned, nothing archived" || bad "shared uuid retire: rc=$rc"
[ -z "$(row sala-test-s)" ] && [ "$(row sala-test-d | cut -f2)" = "$UD" ] && ! tmux has-session -t =sala-test-s 2>/dev/null && ok "sala-test-s retired (session killed, row gone); sala-test-d's row kept" || bad "after the retire: $(<"$MAP")"
[ "$fail" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
