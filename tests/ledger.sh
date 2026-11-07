#!/usr/bin/env bash
# The pane-map ledger (after a reboot brought back only some of the sessions): only honored paths change it,
# absence never removes a row, an observation may only follow a conversation switch; `adopt`; the freeze; the reboot dry
# run's freeze; `sala restore`; the migration of the 3-column map to the XDG state dir. Compare and restore at the end of a
# recycle and of a reboot, and the map gaps of 2026-10-08 (a rename never adds a row, a follow never duplicates a
# conversation, the fleet's tmux server only, retire of an orphan row, no archive by a shared conversation id) are
# tests/ledger-recycle.sh, split out so the two run side by side. Isolated HOME, a private tmux socket, the compiled fake
# claude (tests/fake-claude.c); every Slack post lands in a file.
# Usage: bash tests/ledger.sh   (exit 0 = pass; ~50 s, much of it spawn's own waits)
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
SALA="$ROOT/bin/salamander"; SOCK="sala-ledger-$$"; T="tmux -L $SOCK -f /dev/null"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's (common.sh, on_fleet_server)
cleanup() {  # drivers and retry workers the tests may have left, the tmux server (its panes take the fakes with it), the HOME
    local f p
    for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done
    [ -n "${DRIVER:-}" ] && kill -TERM -- -"$DRIVER" 2>/dev/null
    [ -n "${DPID:-}" ] && kill "$DPID" 2>/dev/null   # the decoy revive of the busy_elsewhere case
    $T kill-server 2>/dev/null; env -u 'BASH_FUNC_tmux%%' tmux -L "$SOCK-probe" kill-server 2>/dev/null; tmux_socket_rm; tmux_socket_rm "$SOCK-probe"; sleep 1
    for p in $(pgrep -x claude); do [ "$HOME/.local/bin/claude" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done   # only our fakes
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
UM=aaaaaaaa-0000-4000-8000-00000000000a UM2=aaaaaaaa-0000-4000-8000-00000000000b UA=bbbbbbbb-0000-4000-8000-000000000001
UB=cccccccc-0000-4000-8000-000000000002 UC=dddddddd-0000-4000-8000-000000000003 UX=eeeeeeee-0000-4000-8000-000000000004
row() { awk -F'\t' -v s="$1" '$1==s' "$MAP" 2>/dev/null; }            # the session's row
logn() { grep -c "	$1	$2	" "$LOG" 2>/dev/null || true; }           # ledger-log lines for op + session
regfile() { echo "$HOME/.claude/sessions/$(claude_pid_under "$(tmux display -p -t "$1" '#{pane_pid}')").json"; }
hand() { $T new-session -d -s "$1" -c "$3" -e FAKE_SESSION_ID="$2" -e FAKE_NAME="$1" -e FAKE_LOG="$FAKE_LOG"; $T send-keys -t "$1" 'claude' Enter; }
spawn() { $T set-environment -g FAKE_SESSION_ID "$2"; $T set-environment -g FAKE_NAME "$1"; $T set-environment -g FAKE_LOG "$FAKE_LOG"; "$SALA" spawn "$1" --cwd "$3" 2>&1; }

echo "== setup: a session made by hand (the master of the watch tests), then the library"
hand sala-test-m "$UM" "$HOME/work-m"; fake_up sala-test-m
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
[ -n "$(claude_pid_under "$(tmux display -p -t sala-test-m '#{pane_pid}')")" ] && ok "the fake claude is up in sala-test-m" || { echo "no fake claude under sala-test-m"; exit 1; }

echo "== migration: a 3-column map at the old path → 4 columns in the state dir, a symlink behind, map-history/ along"
H1="$HOME"; H2="$HOME/home2"; OLD2="$H2/.local/share/tmux/resurrect"; NEW2="$H2/.local/state/salamander"   # a second HOME sharing the live registry
mkdir -p "$H2/.claude" "$OLD2/map-history"; ln -s "$H1/.claude/sessions" "$H2/.claude/sessions"
printf 'sala-test-m\t%s\tsala-test-m\nsala-test-dead\t%s\tdead\n' "$UM" "$UX" > "$OLD2/claude-pane-map.tsv"
printf 'sala-test-old\t%s\told\n' "$UX" > "$OLD2/map-history/claude-pane-map.20250101T000000.tsv"
( export HOME="$H2"; unset SALA_SIDECAR SALA_RESURRECT_DIR SALA_LOG_DIR SALA_RESURRECT_SAVE SALA_INBOX_HOLD_DIR; fail=0
  . "$ROOT/lib/common.sh"; MAP="$SALA_SIDECAR"; LOG="$SALA_LEDGER_LOG"     # the end of common.sh runs ledger_migrate
  [ "$MAP" = "$NEW2/pane-map.tsv" ] && ok "SALA_SIDECAR defaults to the state dir" || bad "SALA_SIDECAR=$MAP"
  [ -f "$MAP" ] && [ ! -L "$MAP" ] && ok "the map is at the new path" || bad "no map at $MAP"
  [ "$(readlink "$OLD2/claude-pane-map.tsv")" = "$MAP" ] && ok "a symlink stays at the old path" || bad "old path: $(ls -l "$OLD2")"
  [ "$(row sala-test-m)" = "sala-test-m	$UM	sala-test-m	$H1/work-m" ] && ok "a live session's row gets its cwd from the registry" || bad "row: '$(row sala-test-m)'"
  [ "$(row sala-test-dead)" = "sala-test-dead	$UX	dead	$H2" ] && ok "a dead one gets \$HOME" || bad "row: '$(row sala-test-dead)'"
  [ "$(wc -l < "$MAP")" = 2 ] && ok "no row lost" || bad "map: $(<"$MAP")"
  [ -f "$NEW2/map-history/claude-pane-map.20250101T000000.tsv" ] && [ ! -e "$OLD2/map-history" ] && ok "map-history/ moved along" || bad "history: $(ls -R "$H2/.local" 2>/dev/null)"
  h=$(ls "$NEW2"/map-history/pane-map.*.tsv 2>/dev/null | head -1); [ -n "$h" ] && awk -F'\t' 'NF!=3 {bad=1} END {exit bad}' "$h" && ok "the 3-column map was kept in map-history/ before the fill" || bad "no 3-column copy: $(ls "$NEW2/map-history")"
  [ "$(logn migrate -)" = 2 ] && grep -q "	migrate	-	$OLD2/claude-pane-map.tsv → $MAP (2 rows, a symlink left at the old path, map-history/ with it)	" "$LOG" \
      && grep -q "	migrate	-	2 row(s) without a cwd → filled in: 1 from a live session, 1 with $H2	" "$LOG" && ok "two ledger-log lines: the move, the fill" || bad "log: $(<"$LOG")"
  cp "$MAP" "$H2/before"; . "$ROOT/lib/common.sh"
  same_file "$MAP" "$H2/before" && [ "$(logn migrate -)" = 2 ] && ok "sourcing again changes nothing (done once)" || bad "a second source changed the map or logged again: $(tail -2 "$LOG")"
  ledger_write add sala-test-n "$UC" sala-test-n "$H2" >/dev/null 2>&1
  [ "$(wc -l < "$OLD2/claude-pane-map.tsv")" = 3 ] && ok "a write lands at the new path and shows through the symlink" || bad "old path after a write: $(<"$OLD2/claude-pane-map.tsv")"
  [ "$fail" = 0 ] ) || fail=1
[ ! -e "$MAP" ] && [ ! -e "$HOME/.local/share/tmux/resurrect/claude-pane-map.tsv" ] && ok "the sandbox's own HOME, with no old map, got nothing (the ledger starts empty)" || bad "something made a map in the main HOME: $(ls -la "$HOME/.local/share/tmux/resurrect" "$(dirname "$MAP")" 2>/dev/null)"

echo "== an unmapped live session: watch reports it (once), never adds it"
# busy_elsewhere counts only this instance's revive (2026-10-08 flake: another suite's or the fleet's revive on the box
# made this watch skip its run): a decoy revive under another HOME stays alive through this case. No /proc environ:
# the check is machine-wide by design, so no decoy.
DECOY="$HOME/decoy/bin/salamander"; mkdir -p "${DECOY%/*}"; printf '#!/usr/bin/env bash\nwhile sleep 1; do :; done\n' > "$DECOY"
decoy() {  # <HOME> → a long-running `bash …/bin/salamander revive --only x` with that HOME; its pid in DPID
    HOME="$1" bash "$DECOY" revive --only x </dev/null >/dev/null 2>&1 & DPID=$!
    local i; for i in $(seq 30); do pgrep -f "$DECOY revive" >/dev/null && return 0; sleep 0.1; done; return 1
}
undecoy() { kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; DPID=""; }
PROC_ENV=0; [ -r "/proc/$$/environ" ] && PROC_ENV=1
if [ "$PROC_ENV" = 1 ]; then decoy "$HOME/elsewhere" && ok "a decoy revive runs under another HOME" || bad "the decoy did not start"; fi
SALA_MASTER=sala-test-m "$SALA" watch >/dev/null 2>&1; rc=$?
[ -n "${DPID:-}" ] && undecoy
[ "$rc" = 0 ] && ok "watch ran (rc 0)" || bad "watch rc=$rc: $(tail -3 "$HOME/.claude/salamander-watch.log" 2>/dev/null)"
[ "$(grep -c 'sala-test-m is not in the pane map' "$POSTS" 2>/dev/null)" = 1 ] && ok "one post: sala-test-m is not in the pane map" || bad "posts: $(slurp "$POSTS")"
[ -z "$(row sala-test-m)" ] && ok "watch did not add the row" || bad "watch added a row: $(row sala-test-m)"
if [ "$PROC_ENV" = 1 ]; then
    n=$(grep -c 'skip: a resurrect restore or a salamander revive is running' "$HOME/.claude/salamander-watch.log")
    decoy "$HOME" || bad "the same-HOME decoy did not start"
    SALA_MASTER=sala-test-m "$SALA" watch >/dev/null 2>&1; undecoy
    [ "$(grep -c 'skip: a resurrect restore or a salamander revive is running' "$HOME/.claude/salamander-watch.log")" = $((n + 1)) ] \
        && ok "a revive under this HOME still makes watch skip its run" || bad "watch did not skip for this HOME's revive: $(tail -3 "$HOME/.claude/salamander-watch.log")"
else ok "no /proc environ: busy_elsewhere stays machine-wide (the same-HOME check needs /proc)"; fi

echo "== adopt: the honored path for a hand-made session"
out=$("$SALA" adopt sala-test-m 2>&1); echo "$out" | sed 's/^/    /'
[ "$(row sala-test-m)" = "sala-test-m	$UM	sala-test-m	$HOME/work-m" ] && ok "row: session, uuid, name, cwd (from the process)" || bad "row: '$(row sala-test-m)'"
[ "$(logn adopt sala-test-m)" = 1 ] && grep -q "	adopt	sala-test-m	— → $UM (sala-test-m, $HOME/work-m)	" "$LOG" && ok "one ledger-log line: adopt, — → uuid (name, cwd)" || bad "log: $(<"$LOG")"
out=$("$SALA" adopt sala-test-m 2>&1); echo "$out" | grep -q 'already in the pane map' && [ "$(logn adopt sala-test-m)" = 1 ] && ok "adopting it again changes nothing" || bad "second adopt: $out"
SALA_MASTER=sala-test-m "$SALA" watch >/dev/null 2>&1; grep -q '^unmapped\.' "$HOME/.claude/salamander-watch.state" && bad "watch kept the unmapped key" || ok "watch dropped its unmapped key once the session was mapped"

echo "== spawn adds exactly its row"
out=$(spawn sala-test-a "$UA" "$HOME/work-a"); echo "$out" | grep -E '^✅|⚠' | sed 's/^/    /'
[ "$(row sala-test-a)" = "sala-test-a	$UA	sala-test-a	$HOME/work-a" ] && ok "row for sala-test-a" || bad "row: '$(row sala-test-a)' / $out"
[ "$(wc -l < "$MAP")" = 2 ] && [ "$(logn add sala-test-a)" = 1 ] && ok "two rows, one add line" || bad "map: $(<"$MAP") / log: $(<"$LOG")"
out=$(spawn sala-test-b "$UB" "$HOME/work-b"); [ "$(row sala-test-b)" = "sala-test-b	$UB	sala-test-b	$HOME/work-b" ] && ok "row for sala-test-b" || bad "row: '$(row sala-test-b)' / $out"
out=$(spawn sala-test-c "$UC" "$HOME/work-c"); [ "$(row sala-test-c)" = "sala-test-c	$UC	sala-test-c	$HOME/work-c" ] && ok "row for sala-test-c" || bad "row: '$(row sala-test-c)' / $out"
[ "$(wc -l < "$MAP")" = 4 ] && ok "four rows" || bad "map: $(<"$MAP")"

echo "== rename changes exactly its row (the pane already /renamed by hand, so nothing is typed)"
python3 - "$(regfile sala-test-a)" <<'PY'
import json, sys; p = sys.argv[1]; d = json.load(open(p)); d["name"] = "sala-test-a2"; json.dump(d, open(p, "w"))
PY
out=$(SALA_SESSION_URL='https://sala.example.test/#s={name}' "$SALA" rename sala-test-a sala-test-a2 2>&1); echo "$out" | grep -E '^✅|^⚠|^✗' | sed 's/^/    /'
# Tue Oct 13th 2026: the notice gives the session's web UI link under its new name, the one the heartbeat publishes
echo "$out" | grep -qx "✅ 'sala-test-a' is now 'sala-test-a2' · https://sala.example.test/#s=sala-test-a2" && ok "the notice prints the web UI's link for the new name" || bad "rename notice: $(echo "$out" | grep -E '^✅|^⚠' | tail -1)"
[ "$(row sala-test-a2)" = "sala-test-a2	$UA	sala-test-a2	$HOME/work-a" ] && [ -z "$(row sala-test-a)" ] && ok "row renamed, name column too" || bad "rows: $(<"$MAP")"
[ "$(logn rename sala-test-a)" = 1 ] && grep -q "	rename	sala-test-a	sala-test-a → sala-test-a2	" "$LOG" && ok "one log line: rename, old → new" || bad "log: $(<"$LOG")"
[ "$(wc -l < "$MAP")" = 4 ] && [ "$(row sala-test-b)" = "sala-test-b	$UB	sala-test-b	$HOME/work-b" ] && ok "the other rows untouched" || bad "map: $(<"$MAP")"

echo "== retire is the only path that drops a row"
out=$("$SALA" retire sala-test-c --keep-web 2>&1); echo "$out" | grep -E "pane map|retired" | sed 's/^/    /'
[ -z "$(row sala-test-c)" ] && [ "$(wc -l < "$MAP")" = 3 ] && ok "row gone, three left" || bad "map: $(<"$MAP")"
[ "$(logn retire sala-test-c)" = 1 ] && grep -q "	retire	sala-test-c	$UC (sala-test-c, $HOME/work-c) → —	" "$LOG" && ok "one log line: retire, uuid → —" || bad "log: $(<"$LOG")"
tmux has-session -t =sala-test-c 2>/dev/null && bad "tmux session sala-test-c still there" || ok "tmux session gone"

echo "== absence never removes a row: a killed claude, a killed tmux session"
cp "$MAP" "$HOME/map.before"
c=$(pane_claude sala-test-a2); kill -9 "$c"; waitfor "! kill -0 $c 2>/dev/null" 20
out=$("$SALA" revive --save-map 2>&1); same_file "$MAP" "$HOME/map.before" && ok "claude killed in sala-test-a2 → --save-map keeps the map ($out)" || bad "map changed after the kill: $(<"$MAP")"
kill_wait sala-test-b
out=$("$SALA" revive --save-map 2>&1); same_file "$MAP" "$HOME/map.before" && ok "tmux session sala-test-b killed → --save-map keeps the map ($out)" || bad "map changed after kill-session: $(<"$MAP")"
nlog=$(wc -l < "$LOG"); [ "$nlog" = 6 ] && ok "no ledger-log line for either (still adopt, add ×3, rename, retire = $nlog)" || bad "log has $nlog lines: $(<"$LOG")"

echo "== an unmapped live session is never added by a save"
hand sala-test-h "$UX" "$HOME"; fake_up sala-test-h
out=$("$SALA" revive --save-map 2>&1); [ -z "$(row sala-test-h)" ] && echo "$out" | grep -q '3 row(s), 2 live pane(s) seen, 0 followed' && ok "--save-map: $out" || bad "save-map: $out / $(<"$MAP")"

echo "== a conversation switch in a live pane: the row follows the live process"
relaunch_on sala-test-m "$UM2"
[ "$(registry_field "$(claude_pid_under "$(tmux display -p -t sala-test-m '#{pane_pid}')")" sessionId)" = "$UM2" ] || bad "the fake did not come back on $UM2"
out=$("$SALA" revive --save-map 2>&1); echo "    $out"
[ "$(row sala-test-m)" = "sala-test-m	$UM2	sala-test-m	$HOME/work-m" ] && ok "row follows: $UM → $UM2 (name and cwd kept)" || bad "row: '$(row sala-test-m)'"
[ "$(logn follow sala-test-m)" = 1 ] && grep -q "	follow	sala-test-m	$UM → $UM2	" "$LOG" && ok "one log line: follow, old uuid → new uuid" || bad "log: $(<"$LOG")"
out=$("$SALA" revive --save-map 2>&1); [ "$(logn follow sala-test-m)" = 1 ] && ok "a second save follows nothing (no change, no line)" || bad "followed again: $(<"$LOG")"
ls "$SALA_LEDGER_HISTORY"/pane-map.*.tsv >/dev/null 2>&1 && ok "map-history keeps the previous maps ($(ls "$SALA_LEDGER_HISTORY" | wc -l) copies)" || bad "no map-history copies"

echo "== freeze: no add, rename, retire or adopt; a follow waits; lifted → applied"
ledger_freeze recycle $$ && ok "froze the map (owner $$)" || bad "ledger_freeze failed"
[ -s "$SALA_LEDGER_FREEZE" ] && same_file "$SALA_LEDGER_FROZEN" "$MAP" && ok "freeze file + a roster copy equal to the map" || bad "freeze files: $(ls "${MAP%.tsv}"* 2>/dev/null)"
grep -q '^reason=recycle$' "$SALA_LEDGER_FREEZE" && grep -q "^owner_pid=$$\$" "$SALA_LEDGER_FREEZE" && grep -q "^boot_id=$(boot_id)\$" "$SALA_LEDGER_FREEZE" && grep -q '^time=[0-9]' "$SALA_LEDGER_FREEZE" && ok "header: owner pid, boot id, reason, time" || bad "header: $(<"$SALA_LEDGER_FREEZE")"
out=$("$SALA" spawn sala-test-z --cwd "$HOME" 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -q 'frozen' && ! tmux has-session -t =sala-test-z 2>/dev/null && ok "spawn refused up front, no session made" || bad "spawn under freeze: rc=$rc $out"
out=$("$SALA" adopt sala-test-h 2>&1); rc=$?; [ "$rc" != 0 ] && echo "$out" | grep -q frozen && [ -z "$(row sala-test-h)" ] && ok "adopt refused" || bad "adopt under freeze: $out"
out=$("$SALA" retire sala-test-h --keep-web 2>&1); rc=$?; [ "$rc" != 0 ] && tmux has-session -t =sala-test-h 2>/dev/null && ok "retire refused, the session untouched" || bad "retire under freeze: rc=$rc $out"
out=$("$SALA" rename sala-test-h sala-test-h2 2>&1); rc=$?; [ "$rc" != 0 ] && echo "$out" | grep -q frozen && tmux has-session -t =sala-test-h 2>/dev/null && ok "rename refused" || bad "rename under freeze: rc=$rc $out"
ledger_write add sala-test-z "$UX" 2>/dev/null; rc=$?
[ "$rc" = 2 ] && [ -z "$(row sala-test-z)" ] && grep -q "	refused(add)	sala-test-z	" "$LOG" && ok "a direct add is refused (rc 2) with a log line" || bad "direct add under freeze: rc=$rc log: $(tail -1 "$LOG")"
relaunch_on sala-test-m "$UM"
out=$("$SALA" revive --save-map 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(row sala-test-m | cut -f2)" = "$UM2" ] && grep -q "^sala-test-m	$UM	" "$SALA_LEDGER_DEFERRED" && grep -q "	deferred(follow)	sala-test-m	" "$LOG" && ok "a conversation switch meanwhile: the follow is deferred, the row unchanged ($out)" || bad "deferred follow: rc=$rc row=$(row sala-test-m) deferred=$(slurp "$SALA_LEDGER_DEFERRED")"
ledger_unfreeze test && ok "unfroze" || bad "ledger_unfreeze failed"
[ ! -e "$SALA_LEDGER_FREEZE" ] && [ ! -e "$SALA_LEDGER_DEFERRED" ] && [ "$(row sala-test-m | cut -f2)" = "$UM" ] && ok "freeze gone, the deferred follow applied ($UM2 → $UM)" || bad "after the unfreeze: row=$(row sala-test-m)"
grep -q "	unfreeze	-	.*1 deferred follow(s) applied" "$LOG" && [ "$(logn follow sala-test-m)" = 2 ] && ok "log: freeze, unfreeze and the applied follow" || bad "log: $(tail -4 "$LOG")"
ledger_unfreeze again; [ "$(grep -c '	unfreeze	' "$LOG")" = 1 ] && ok "unfreezing an open map does nothing" || bad "a second unfreeze logged a line"

echo "== a stale freeze (owner dead on this boot) is cleared by watch"
sleep 0.2 & dead=$!; wait $dead
ledger_freeze recycle "$dead" && [ -s "$SALA_LEDGER_FREEZE" ] && ok "a freeze owned by dead pid $dead" || bad "could not write the stale freeze"
ledger_freeze_stale && ok "ledger_freeze_stale says so" || bad "ledger_freeze_stale missed it"
SALA_MASTER=sala-test-m "$SALA" watch >/dev/null 2>&1
[ ! -e "$SALA_LEDGER_FREEZE" ] && ok "watch cleared it" || bad "stale freeze still there: $(<"$SALA_LEDGER_FREEZE")"
ledger_freeze recycle $$ >/dev/null; ledger_freeze_stale && bad "a live freeze read as stale" || ok "a live freeze (owner alive) is not stale"
SALA_MASTER=sala-test-m "$SALA" watch >/dev/null 2>&1; [ -s "$SALA_LEDGER_FREEZE" ] && ok "watch leaves a live freeze alone" || bad "watch cleared a live freeze"
ledger_unfreeze test >/dev/null

echo "== reboot --dry-run: frozen from the pause, lifted at the end; a halt lifts it too (a sandbox hook)"
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
out=$(SALA_REBOOT_HOOKS="t=$HOME/hook" "$SALA" reboot --dry-run 2>&1); rc=$?
echo "$out" | grep -q '✅ dry run complete' && [ "$rc" = 0 ] && ok "dry run complete (rc 0)" || bad "dry run: rc=$rc $(echo "$out" | tail -3)"
grep -q '^flush-stop frozen=yes' "$HOME/hook.log" && grep -q '^resume frozen=yes' "$HOME/hook.log" && ok "the map was frozen from the pause through the resume" || bad "hook log: $(<"$HOME/hook.log")"
[ ! -e "$SALA_LEDGER_FREEZE" ] && grep -q '	unfreeze	-	.*dry run complete' "$LOG" && ok "lifted when the dry run completed" || bad "freeze after the dry run: $(slurp "$SALA_LEDGER_FREEZE") log: $(tail -1 "$LOG")"
touch "$HOME/hook.fail"; : > "$HOME/hook.log"
out=$(SALA_REBOOT_HOOKS="t=$HOME/hook" "$SALA" reboot --dry-run 2>&1); rc=$?
echo "$out" | grep -q 'HALTED' && [ "$rc" != 0 ] && ok "a failing flush-stop halts the run" || bad "halt: rc=$rc $(echo "$out" | tail -3)"
[ ! -e "$SALA_LEDGER_FREEZE" ] && grep -q '	unfreeze	-	.*reboot halted' "$LOG" && ok "the halt lifted the freeze" || bad "after the halt: freeze=$([ -e "$SALA_LEDGER_FREEZE" ] && echo yes || echo no) log: $(tail -1 "$LOG")"
rm -f "$HOME/hook.fail"
ledger_freeze recycle $$ >/dev/null; out=$(SALA_REBOOT_HOOKS="t=$HOME/hook" "$SALA" reboot --dry-run 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -q 'already frozen' && [ ! -e "$HOME/hook.state" -o "$(<"$HOME/hook.state")" = running ] && ok "no reboot under another run's freeze (nothing paused)" || bad "reboot under a freeze: rc=$rc $out"
ledger_unfreeze test >/dev/null

echo "== sala restore NAME: the tmux session in the row's cwd, then resumed by uuid"
n0=$(grep -c "^start $UB" "$FAKE_LOG")
out=$("$SALA" restore sala-test-b 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
[ "$rc" = 0 ] && tmux has-session -t =sala-test-b 2>/dev/null && [ "$(tmux display -p -t sala-test-b '#{pane_current_path}')" = "$HOME/work-b" ] && ok "sala-test-b is back, in $HOME/work-b (rc 0)" || bad "restore: rc=$rc"
[ "$(registry_field "$(claude_pid_under "$(tmux display -p -t sala-test-b '#{pane_pid}')")" sessionId)" = "$UB" ] && ok "on its conversation" || bad "wrong conversation in sala-test-b"
[ "$(grep -c "^start $UB" "$FAKE_LOG")" = $((n0+1)) ] && ok "resumed exactly once" || bad "starts of UB: $(grep -c "^start $UB" "$FAKE_LOG") (was $n0)"
out=$("$SALA" restore sala-test-b 2>&1); rc=$?; [ "$rc" != 0 ] && echo "$out" | grep -q 'tmux session exists' && ok "a session that exists is refused" || bad "second restore: rc=$rc $out"
out=$("$SALA" restore sala-test-nope 2>&1); rc=$?; [ "$rc" != 0 ] && echo "$out" | grep -q 'not in the pane map' && ok "an unknown name is refused" || bad "unknown name: rc=$rc $out"
echo "== restore refuses a conversation that is live elsewhere"
kill_wait sala-test-b; hand sala-test-y "$UB" "$HOME"; fake_up sala-test-y
out=$("$SALA" restore sala-test-b 2>&1); rc=$?
echo "$out" | grep -q 'live already' && ! tmux has-session -t =sala-test-b 2>/dev/null && ok "left alone: its conversation is live in sala-test-y ($(echo "$out" | tail -1))" || bad "live elsewhere: rc=$rc $out"
kill_wait sala-test-y
echo "== sala restore --missing"
out=$("$SALA" restore --missing 2>&1); rc=$?; echo "$out" | sed 's/^/    /'
[ "$rc" = 0 ] && tmux has-session -t =sala-test-b 2>/dev/null && echo "$out" | grep -q '1 session(s) in the pane map have no tmux session: sala-test-b' && ok "--missing found and restored sala-test-b" || bad "--missing: rc=$rc"
out=$("$SALA" restore --missing 2>&1); echo "$out" | grep -q 'nothing missing' && ok "--missing with nothing missing: $out" || bad "--missing again: $out"
[ "$fail" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
