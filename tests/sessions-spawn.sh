#!/usr/bin/env bash
# The session registry, phase 2, the parts that need a tmux server and a claude (Thu Oct 22nd 2026; lib/spawn.sh THE
# SESSION REGISTRY'S ID, lib/unpark.sh, docs/session-registry.md; the record verb, the prepare/abandon helpers and the SessionStart
# hook are tests/sessions.sh, which needs neither). Checked here: `sala spawn` makes the registry row BEFORE the pane's claude
# starts and the id reaches the pane (tmux session environment) and the claude process (its environment) as SALA_SESSION_ID, equal
# to the row's id, with the first conversation on that row (one live row, why add); a name that already has a live row keeps its id
# (one live row per name); SALA_SESSIONS=off exports nothing and writes nothing; a spawn whose claude dies leaves no row behind;
# `sala unpark` appends the resumed conversation to the row as why=resume (the same record call the hook uses), once. The compiled
# fake claude (tests/fake-claude.c), a private tmux socket standing in for the fleet's, an isolated HOME: no real session is touched.
# Usage: bash tests/sessions-spawn.sh   (exit 0 = pass; ~40 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SESSION_ID
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, fake_up, tmux_socket_rm
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null
as_op_unit   # no master: the guarded verbs this suite runs itself stand for the queue's runner (tests/lib.sh, 5)
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOME/work" "$HOME/deadbin"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
cc -o "$HOME/.local/bin/claude" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
export PATH="$HOME/.local/bin:$PATH"; export FAKE_LOG="$HOME/fake.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="cat >> $POSTS"   # no post leaves the box
export SALA_AUTO_UPDATE=off SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_LEDGER_CALLER=sessions-spawn-test
SALA="$ROOT/bin/salamander"; SOCK="sala-sessions-spawn-$$"; T="tmux -L $SOCK -f /dev/null"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's (common.sh, on_fleet_server)
cleanup() {
    local p; $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    for p in $(pgrep -x claude); do [ "$HOME/.local/bin/claude" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done   # only our fakes
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux
. "$ROOT/lib/common.sh"; MAP="$SALA_SIDECAR"; REG="$SALA_SESSIONS_FILE"; RLOG="$SALA_SESSIONS_LOG"
UA=aaaaaaaa-0000-4000-8000-0000000000a1; UB=bbbbbbbb-0000-4000-8000-0000000000b1; UD=dddddddd-0000-4000-8000-0000000000d1; UD2=dddddddd-0000-4000-8000-0000000000d2
UP=eeeeeeee-0000-4000-8000-0000000000e1; UF=eeeeeeee-0000-4000-8000-0000000000e2
tmux new-session -d -s keep-alive; tmux set-environment -g FAKE_LOG "$FAKE_LOG"
spawn() { tmux set-environment -g FAKE_SESSION_ID "$2"; tmux set-environment -g FAKE_NAME "$1"; "$SALA" spawn "$1" --cwd "${3:-$HOME/work}" 2>&1; }   # <name> <uuid> [cwd]
pane_claude() { claude_pid_under "$(tmux display -p -t "$1" '#{pane_pid}' 2>/dev/null)"; }
procenv() { tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null | sed -n 's/^SALA_SESSION_ID=//p'; }   # <pid> → the SALA_SESSION_ID the process carries
rowq() {  # <name> <state|id|ntr|trs|count> → a fact about the NEWEST row of that name
    python3 - "$REG" "$1" "$2" <<'PY'
import json, sys
f, name, what = sys.argv[1:4]
try: rows = [r for r in json.load(open(f))["sessions"].values() if r["name"] == name]
except Exception: rows = []
rows.sort(key=lambda r: r["created"])
if what == "count": print(len(rows)); sys.exit()
if not rows: print("<none>"); sys.exit()
r = rows[-1]
if what == "ntr": print(len(r["transcripts"]))
elif what == "trs": print(" ".join("%s:%s" % (t["id"], t["why"]) for t in r["transcripts"]))
else: print(r[what])
PY
}

echo "== spawn: the row is made first, its id reaches the pane and the claude as SALA_SESSION_ID, the first conversation lands on it"
out=$(spawn sala-test-a "$UA"); rc=$?
[ "$rc" = 0 ] && tmux has-session -t =sala-test-a 2>/dev/null && ok "spawned sala-test-a" || { bad "spawn a: rc=$rc $out"; }
RA=$(rowq sala-test-a id)
[[ "$RA" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] && [ "$(rowq sala-test-a count)" = 1 ] && [ "$(rowq sala-test-a state)" = live ] && ok "one live registry row with a uuid4 id" || bad "row: $RA $(slurp "$REG")"
CA=$(pane_claude sala-test-a)
[ -n "$CA" ] && [ "$(procenv "$CA")" = "$RA" ] && ok "the pane's claude process carries SALA_SESSION_ID = the row's id" || bad "claude env: '$(procenv "${CA:-0}")' vs $RA"
[ "$(tmux show-environment -t =sala-test-a SALA_SESSION_ID 2>/dev/null)" = "SALA_SESSION_ID=$RA" ] && ok "the tmux session's environment has it too (a claude typed into the pane later inherits it)" || bad "tmux env: $(tmux show-environment -t =sala-test-a SALA_SESSION_ID 2>&1)"
[ "$(rowq sala-test-a trs)" = "$UA:add" ] && ok "transcripts[0] is the pane's first conversation (why: add), on the row made before the claude started" || bad "transcripts: $(rowq sala-test-a trs)"
[ "$(awk -F'\t' '$1=="sala-test-a" {print $2}' "$MAP")" = "$UA" ] && ok "the pane map has its row as before" || bad "map: $(<"$MAP")"

echo "== a name that already has a live row keeps its id (one live row per name)"
ledger_write add sala-test-d "$UD" sala-test-d "$HOME/work" >/dev/null 2>&1
RD=$(rowq sala-test-d id)
out=$(spawn sala-test-d "$UD2"); rc=$?
CD=$(pane_claude sala-test-d)
[ "$rc" = 0 ] && [ "$(rowq sala-test-d count)" = 1 ] && [ "$(rowq sala-test-d id)" = "$RD" ] && [ -n "$CD" ] && [ "$(procenv "$CD")" = "$RD" ] && ok "the same row: same id exported, still one live row" || bad "reuse: rc=$rc rows=$(rowq sala-test-d count) id=$(rowq sala-test-d id) vs $RD env=$(procenv "${CD:-0}")"
[ "$(rowq sala-test-d trs)" = "$UD:add $UD2:add" ] && ok "the new conversation joined the old row" || bad "transcripts: $(rowq sala-test-d trs)"

echo "== SALA_SESSIONS=off: no id, no export, no registry write"
cp "$REG" "$HOME/reg.before"; cp "$RLOG" "$HOME/log.before" 2>/dev/null
tmux set-environment -g FAKE_SESSION_ID "$UB"; tmux set-environment -g FAKE_NAME sala-test-b
out=$(SALA_SESSIONS=off "$SALA" spawn sala-test-b --cwd "$HOME/work" 2>&1); rc=$?
CB=$(pane_claude sala-test-b)
[ "$rc" = 0 ] && [ -n "$CB" ] && [ -z "$(procenv "$CB")" ] && [ -z "$(tmux show-environment -t =sala-test-b SALA_SESSION_ID 2>/dev/null | grep =)" ] && ok "spawned; the claude and the tmux session carry no SALA_SESSION_ID" || bad "off: rc=$rc env='$(procenv "${CB:-0}")' $out"
same_file "$REG" "$HOME/reg.before" && [ "$(slurp "$RLOG")" = "$(slurp "$HOME/log.before")" ] && grep -q "^sala-test-b	$UB	" "$MAP" && ok "sessions.json and sessions.log untouched; the pane map has the row" || bad "off wrote: $(diff "$REG" "$HOME/reg.before" | head -3)"

echo "== a spawn whose claude dies leaves no row behind"
cat > "$HOME/deadbin/claude" <<'EOF'
#!/bin/bash
echo "dead claude: refusing to start" >&2
exit 1
EOF
chmod +x "$HOME/deadbin/claude"
n0=$(rowq sala-test-c count)
out=$(SALA_CLAUDE="$HOME/deadbin/claude" "$SALA" spawn sala-test-c --cwd "$HOME/work" 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -q "died\|did not start" && ok "the spawn fails (exit $rc)" || bad "dead claude: rc=$rc $out"
[ "$n0" = 0 ] && [ "$(rowq sala-test-c count)" = 0 ] && ok "no registry row for it: the prepared row was taken back" || bad "rows for sala-test-c: $(rowq sala-test-c count) :: $(<"$REG")"
grep -q "	abandon	sala-test-c	" "$RLOG" && ok "sessions.log says it was dropped" || bad "log: $(tail -3 "$RLOG")"
[ -z "$(awk -F'\t' '$1=="sala-test-c"' "$MAP")" ] && ok "and nothing in the pane map" || bad "map: $(<"$MAP")"
[ "$(rowq sala-test-a count)" = 1 ] && [ "$(rowq sala-test-d count)" = 1 ] && ok "the other rows are as they were" || bad "other rows changed"
tmux kill-session -t =sala-test-c 2>/dev/null

echo "== unpark: the resumed conversation joins the row (why: resume), once"
spawn sala-test-p "$UP" >/dev/null
CP=$(pane_claude sala-test-p); RP=$(rowq sala-test-p id)
[ -n "$CP" ] && [ "$(rowq sala-test-p trs)" = "$UP:add" ] && ok "setup: sala-test-p is up on $UP with its row" || bad "setup p: $(rowq sala-test-p trs)"
# park it: the registry row names a fork whose transcript is on disk, no fork process running (unpark skips the fork's end then)
sed -i "s/\"version\"/\"parkedJobId\":\"$UF\",\"version\"/" "$HOME/.claude/sessions/$CP.json"
echo '{"type":"summary"}' > "$HOME/.claude/projects/x/$UF.jsonl"
[ "$(registry_field "$CP" parkedJobId)" = "$UF" ] && ok "setup: the pane's registry row says it is parked on $UF" || bad "parkedJobId: $(<"$HOME/.claude/sessions/$CP.json")"
out=$("$SALA" unpark sala-test-p 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "is on $UF" && ok "unpark finished (exit 0): the pane is on the fork" || bad "unpark: rc=$rc $out"
[ "$(rowq sala-test-p trs)" = "$UP:add $UF:resume" ] && [ "$(rowq sala-test-p id)" = "$RP" ] && [ "$(rowq sala-test-p count)" = 1 ] && ok "the row (same id) lists the fork once, why=resume (not add)" || bad "after unpark: $(rowq sala-test-p trs) rows=$(rowq sala-test-p count)"
[ "$(awk -F'\t' '$1=="sala-test-p" {print $2}' "$MAP")" = "$UF" ] && ok "the pane map moved to the fork as before" || bad "map: $(<"$MAP")"
"$SALA" sessions record sala-test-p --transcript "$UF" --why resume >/dev/null 2>&1
[ "$(rowq sala-test-p trs)" = "$UP:add $UF:resume" ] && ok "recording the fork again (the SessionStart hook of the resumed claude does) is a no-op" || bad "repeat: $(rowq sala-test-p trs)"

[ "$fail" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
