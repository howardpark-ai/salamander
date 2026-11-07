#!/usr/bin/env bash
# A pane parked on a background job (Wed Oct 28th 2026; lib/common.sh "a pane parked on a background job",
# lib/revive.sh close_pane, lib/map.sh, lib/heartbeat.sh; the web app's side is web/tests/test_parked_sessions.py).
# The CLI's "← for agents" view moves a conversation into a background job: the pane's claude stays as a viewer and the
# registry holds TWO rows under one name. The shapes are the ones the CLI (2.1.312) writes, with fake
# values: the pane's row (tmux, status "shell", sessionId = the conversation before the move, parkedJobId = the 8-character job
# id) and the job's row (kind "bg", no tmux, jobId, sessionId = the live conversation, status idle/busy). The job is a `sleep`
# with a row; the panes are the compiled fake claude (tests/fake-claude.c) on a private tmux socket in an isolated HOME.
# Covered: the resolution (job pid, live conversation, an older CLI's whole-uuid parkedJobId, a dead job's transcript, a pane
# that is not parked); idleness by the job's state (idle, busy, a job gone, an unparked session unchanged); the pane map and
# `salamander map` and the heartbeat following the job; a revive's dry run naming the job's conversation; a real revive ending
# the idle job, leaving the viewer and resuming the JOB's conversation in the pane; a busy job leaving its pane alone; an
# unparked pane relaunched as before; an ordinary revive naming the pane (`--name <session>`) when its row's name differs from the session and
# its nameSource is not "user" (a stored job title), and not when the names match or the rename is a hand one; the parked resume's line carrying `--name <session>` (an ordinary one not, an unsafe name
# never typed: the job's conversation holds the job's own title, which the registry would otherwise take). Every process this suite kills is a pid it started (the job stand-ins) or a fake claude
# of its own HOME (kill_fake_claude); no real pane is touched. Usage: bash tests/parked.sh   (exit 0 = pass)
set -u
unset TMUX_PANE XDG_STATE_HOME
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null
exec {LK}< "$HOME" && flock -s "$LK"      # the temp folder is locked while the suite runs (systemd-tmpfiles ageing honors it)
as_op_unit
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect"
touch "$HOME/.claude/salamander-rc.stopped"
cc -o "$HOME/.local/bin/claude" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="cat >> $POSTS" SALA_AUTO_UPDATE=off SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT"
SALA="$ROOT/bin/salamander"; SOCK="sala-parked-$$"; T="tmux -L $SOCK -f /dev/null"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"
JOBS=()
cleanup() {
    local p f
    for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done
    for p in ${JOBS[@]+"${JOBS[@]}"}; do kill "$p" 2>/dev/null; done      # the job stand-ins: pids this suite started
    $T kill-server 2>/dev/null; tmux_socket_rm; kill_fake_claude "$HOME/.local/bin/claude"; sleep 1
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
UP=aaaaaaaa-0000-4000-8000-0000000000a1; UPJ=eeeeeeee-0000-4000-8000-0000000000e3      # p: before the move, and the job's conversation
UB=bbbbbbbb-0000-4000-8000-0000000000b1; UBJ=b0b0b0b0-0000-4000-8000-0000000000b2      # b: the same, its job busy
UC=cccccccc-0000-4000-8000-0000000000c1                                                 # c: never parked
UD=eeeeeeee-0000-4000-8000-0000000000e1; UE=ffffffff-0000-4000-8000-0000000000f1         # d: a derived title in the row; e: a hand rename
UX=dddddddd-0000-4000-8000-0000000000d1                                                 # an older CLI's fork (synthetic rows below)
mk() { local n="$1" u="$2"; $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="sala-test-$n" -e FAKE_LOG="$FAKE_LOG"; $T send-keys -t "sala-test-$n" claude Enter; }
mk p "$UP"; mk b "$UB"; mk c "$UC"
for u in $UP $UPJ $UB $UBJ $UC $UX; do : > "$HOME/.claude/projects/x/$u.jsonl"; done
fake_up sala-test-p sala-test-b sala-test-c
. "$ROOT/lib/common.sh"; MAP="$SALA_SIDECAR"
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux
cp_of() { claude_pid_under "$(tmux display -p -t "sala-test-$1" '#{pane_pid}')"; }       # <suffix> → the pane's claude pid
rowfile() { echo "$HOME/.claude/sessions/$1.json"; }
now_ms() { local n; printf -v n '%(%s)T' -1; echo $(( (n - ${1:-60}) * 1000 )); }
# job_of <name> <job id> <job uuid> <status> [extra json] → a job stand-in (a sleep) with a bg row, as CLI 2.1.312 writes it; its pid in JP
job_of() {
    sleep 900 & JP=$!; JOBS+=("$JP")
    printf '{"pid":%s,"sessionId":"%s","kind":"bg","entrypoint":"cli","name":"%s","jobId":"%s","status":"%s","statusUpdatedAt":%s,"updatedAt":%s,"cwd":"%s","bridgeSessionId":"cse_job%s"%s}\n' \
        "$JP" "$3" "$1" "$2" "$4" "$(now_ms 60)" "$(now_ms 60)" "$HOME" "${2:0:4}" "${5:-}" > "$(rowfile "$JP")"
}
# park <suffix> <job id> → the pane's row as it reads while the viewer shows the job: status shell, parkedJobId, no bridge
park() { python3 - "$(rowfile "$(cp_of "$1")")" "$2" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["status"] = "shell"; d["parkedJobId"] = sys.argv[2]; d.pop("bridgeSessionId", None)
open(p + ".tmp", "w").write(json.dumps(d)); import os; os.replace(p + ".tmp", p)
PY
}
reg() { registry_field "$1" "$2" 2>/dev/null; }

echo "== the pane map holds the conversations before the move"
for n in p b c; do "$SALA" adopt "sala-test-$n" >/dev/null 2>&1; done
mrow() { awk -F'\t' -v s="sala-test-$1" '$1==s {print $2}' "$MAP"; }
[ "$(mrow p)" = "$UP" ] && [ "$(mrow b)" = "$UB" ] && [ "$(mrow c)" = "$UC" ] && ok "adopt: p, b, c mapped to their own conversations" || bad "map: $(<"$MAP")"

BRIDGE_P="cse_"job"eeee"   # the bridge id the job row holds (the same four first characters of the job id), built from pieces
job_of sala-test-p eeeeeeee "$UPJ" idle; JPP=$JP; park p eeeeeeee
job_of sala-test-b b0b0b0b0 "$UBJ" busy; JPB=$JP; park b b0b0b0b0
CP=$(cp_of p); CB=$(cp_of b); CC=$(cp_of c)

echo "== the resolution"
parked_job_pid_r r "$CP" && [ "$r" = "$JPP" ] && ok "parked_job_pid_r: p's job row found by jobId (pid $r)" || bad "job pid '$r', want $JPP"
registry_conv_r c "$CP"; [ "$c" = "$UPJ" ] && ok "registry_conv_r: p resolves to the job's conversation, not the one before the move" || bad "conv '$c'"
registry_conv_r c "$CC"; [ "$c" = "$UC" ] && ! parked_job_pid_r r "$CC" && ok "an unparked pane: its own sessionId, no job" || bad "unparked: conv '$c' job '$r'"
# an older CLI: parkedJobId is the fork's whole uuid and the fork's row has no jobId
sleep 900 & OLD=$!; JOBS+=("$OLD"); sleep 900 & VIEW=$!; JOBS+=("$VIEW")
printf '{"pid":%s,"sessionId":"%s","name":"old","status":"busy"}\n' "$OLD" "$UX" > "$(rowfile "$OLD")"
printf '{"pid":%s,"sessionId":"%s","name":"old","status":"shell","tmux":"old:@1.%%9","parkedJobId":"%s"}\n' "$VIEW" "$UB" "$UX" > "$(rowfile "$VIEW")"
parked_job_pid_r r "$VIEW" && [ "$r" = "$OLD" ] && ok "the whole-uuid form (CLI 2.1.28x): the row whose sessionId is it" || bad "old form: '$r'"
printf '{"pid":%s,"sessionId":"%s","name":"old","status":"shell","tmux":"old:@1.%%9","parkedJobId":"%s"}\n' "$VIEW" "$UB" "${UX:0:8}" > "$(rowfile "$VIEW")"
parked_job_pid_r r "$VIEW" && [ "$r" = "$OLD" ] && ok "a short id with no jobId on the job row: the row whose sessionId starts with it" || bad "prefix form: '$r'"
kill "$OLD"; waitfor "! kill -0 $OLD 2>/dev/null" 20
! parked_job_pid_r r "$VIEW" && ok "the job's process gone: no job pid" || bad "a dead job resolved to '$r'"
registry_conv_r c "$VIEW"; [ "$c" = "$UX" ] && ok "a dead job: the one transcript that carries the job's id is the conversation" || bad "dead job conv '$c'"
printf '{"pid":%s,"sessionId":"%s","name":"old","status":"shell","tmux":"old:@1.%%9","parkedJobId":"%s"}\n' "$VIEW" "$UB" "0123abcd" > "$(rowfile "$VIEW")"
registry_conv_r c "$VIEW"; [ "$c" = "$UB" ] && ok "a dead job with no transcript: the row's own sessionId, as before" || bad "no transcript: '$c'"

echo "== idleness follows the job"
why=$(is_idle_reason "$CP"); is_idle "$CP"; rc=$?
[ -z "$why" ] && [ "$rc" = 0 ] && ok "job idle → the parked pane is idle (its own status is 'shell'; reason empty, is_idle 0)" || bad "idle job: why='$why' rc=$rc"
why=$(is_idle_reason "$CB"); is_idle "$CB"; rc=$?
has "$why" "parked in background job b0b0b0b0" && has "$why" "registry says 'busy'" && [ "$rc" = 1 ] && ok "job working → waiting: \"$why\"; is_idle 1" || bad "busy job: why='$why' rc=$rc"
[ "$(reg "$CP" status)" = shell ] && ok "(the pane's own row still says shell: the redirect is in the readers, nothing was rewritten)" || bad "pane row: $(<"$(rowfile "$CP")")"
why=$(is_idle_reason "$CC"); [ -z "$why" ] && ok "an unparked idle session: idle as before" || bad "unparked: '$why'"
set_reg_status "$CC" shell; why=$(is_idle_reason "$CC")
has "$why" "registry says 'shell'" && ! has "$why" "parked in" && ok "an unparked 'shell' pane reads as it did (not a parked one)" || bad "unparked shell: '$why'"
set_reg_status "$CC" idle
printf '{"pid":%s,"sessionId":"%s","name":"old","status":"shell","tmux":"old:@1.%%9","parkedJobId":"%s"}\n' "$VIEW" "$UB" "$UX" > "$(rowfile "$VIEW")"
why=$(is_idle_reason "$VIEW"); has "$why" "registry says 'shell'" && ! has "$why" "parked in" && ok "a parked pane whose job is gone keeps the old reading (shell, not idle)" || bad "job gone: '$why'"

echo "== the pane map follows the job"
out=$("$SALA" revive --save-map 2>&1)
[ "$(mrow p)" = "$UPJ" ] && ok "--save-map: p's row now names the job's conversation ($out)" || bad "p row: '$(mrow p)' want $UPJ ($out)"
[ "$(mrow b)" = "$UBJ" ] && [ "$(mrow c)" = "$UC" ] && ok "b followed its job, c (never parked) unchanged" || bad "map: $(<"$MAP")"

echo "== the lists: one entry per session"
out=$("$SALA" map 2>&1); n=0; while IFS= read -r l; do [[ $l == *'`sala-test-p`'* ]] && n=$((n + 1)); done <<< "$out"
[ "$n" = 1 ] && has "$out" "https://claude.ai/code/${BRIDGE_P}" && ok "salamander map: p listed once, with the bridge the job row holds" || bad "map: $n lines, $out"
HB="$HOME/live"; printf 'box\tq\n' > "$HOME/fleet.tsv"
SALA_HEARTBEAT_STATE_DIR="$HB" SALA_HEARTBEAT_GIT=off SALA_HEARTBEAT_REPO= SALA_HEARTBEAT_LETTER=q SALA_HEARTBEAT_NAME=box SALA_FLEET_NAMES="$HOME/fleet.tsv" "$SALA" heartbeat --no-push >/dev/null 2>&1
python3 - "$HB/q/sessions.json" "$UP" "$UPJ" "$UC" <<'PY' && ok "heartbeat: one entry for p, keyed by the job's conversation; c keyed as before" || bad "heartbeat sessions.json"
import json, sys
s = json.load(open(sys.argv[1])); up, upj, uc = sys.argv[2:5]
assert up not in s and upj in s and uc in s, sorted(s)
assert s[upj]["name"] == "sala-test-p", s[upj]
assert sum(1 for v in s.values() if v["name"] == "sala-test-p") == 1
PY

echo "== a revive: the dry run names the job's conversation"
out=$("$SALA" revive --dry-run --only sala-test-p 2>&1)
has "$out" "would /exit" && has "$out" "resume $UPJ" && ! has "$out" "resume $UP " && ok "dry run: p would resume $UPJ" || bad "dry run p: $out"
out=$("$SALA" revive --dry-run --only sala-test-b 2>&1)
has "$out" "parked in background job b0b0b0b0" && ok "dry run: b skipped, its job is working" || bad "dry run b: $out"

echo "== a revive of the busy one leaves pane and job alone"
out=$("$SALA" revive --only sala-test-b 2>&1)
has "$out" "sala-test-b:0: parked in background job b0b0b0b0" && kill -0 "$JPB" 2>/dev/null && kill -0 "$CB" 2>/dev/null && ok "b: skipped with the job's reason; the job and the viewer still run" || bad "b: $out"
[ "$(starts "$UBJ")" = 0 ] && [ "$(starts "$UB")" = 1 ] && ok "(nothing resumed for b)" || bad "b starts: $(<"$FAKE_LOG")"
for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done   # the retry worker b's skip started

echo "== a revive of the idle one: the job ends, the viewer leaves, the job's conversation resumes in the pane"
out=$("$SALA" revive --only sala-test-p 2>&1); echo "$out" | grep -E 'sala-test-p|phase' | sed 's/^/    /'
has "$out" "sala-test-p:0: parked on background job $JPP" && ok "the sweep says it ended the job" || bad "no parked line: $out"
has "$out" "sala-test-p:0: 9.9.9 → 9.9.9" && ok "p: an UPDATED row" || bad "p: no UPDATED row: $out"
! kill -0 "$JPP" 2>/dev/null && ok "the job's process is gone" || bad "the job (pid $JPP) still runs"
[ "$(starts "$UPJ")" = 1 ] && [ "$(starts "$UP")" = 1 ] && ok "the fake started on $UPJ once, and not again on $UP" || bad "starts: $(<"$FAKE_LOG")"
NP=$(cp_of p); [ -n "$NP" ] && [ "$NP" != "$CP" ] && [ "$(reg "$NP" sessionId)" = "$UPJ" ] && [ -z "$(reg "$NP" parkedJobId)" ] && ok "the pane runs a new claude on $UPJ, parked no more" || bad "pane claude '$NP': $(<"$(rowfile "${NP:-0}")" 2>/dev/null)"
[ "$(mrow p)" = "$UPJ" ] && ok "the pane map still names $UPJ" || bad "map p: $(mrow p)"
args_of() { tr '\0' ' ' < "/proc/$1/cmdline"; }
a=$(args_of "$NP"); has "$a" "--resume $UPJ --name sala-test-p" && ok "the resumed claude carries --name sala-test-p (the job's own title must not become the pane's registry name)" || bad "parked resume args: $a"
[ -s "$HOME/.claude/salamander-inbox-holds.tsv" ] && bad "inbox ledger not empty" || ok "no inbox hold left behind"

echo "== an unparked pane is relaunched as before"
out=$("$SALA" revive --only sala-test-c 2>&1)
has "$out" "sala-test-c:0: 9.9.9 → 9.9.9" && [ "$(starts "$UC")" = 2 ] && ok "c: relaunched on its own conversation" || bad "c: $out / $(<"$FAKE_LOG")"
a=$(args_of "$(cp_of c)"); has "$a" "--resume $UC" && ! has "$a" "--name" && ok "c: no --name on an ordinary revive's line" || bad "ordinary revive args: $a"

echo "== an ordinary revive names the pane when its row holds another, not hand-made, name (a stored job title)"
mk2() { $T new-session -d -s "sala-test-$1" -c "$HOME" -e FAKE_SESSION_ID="$2" -e FAKE_NAME="$3" -e FAKE_LOG="$FAKE_LOG"; $T send-keys -t "sala-test-$1" claude Enter; }
mk2 d "$UD" background-4a; mk2 e "$UE" my-hand-name
: > "$HOME/.claude/projects/x/$UD.jsonl"; : > "$HOME/.claude/projects/x/$UE.jsonl"
fake_up background-4a my-hand-name
src() { python3 - "$(rowfile "$(cp_of "$1")")" "$2" <<'PY'
import json, os, sys
p = sys.argv[1]; d = json.load(open(p)); d["nameSource"] = sys.argv[2]
open(p + ".tmp", "w").write(json.dumps(d)); os.replace(p + ".tmp", p)
PY
}
src d derived; src e user; src c derived
for n in d e; do "$SALA" adopt "sala-test-$n" >/dev/null 2>&1; done
"$SALA" revive --only sala-test-d >/dev/null 2>&1
a=$(args_of "$(cp_of d)"); has "$a" "--resume $UD --name sala-test-d" && ok "d: row name background-4a != session, nameSource derived: the resume carries --name sala-test-d" || bad "d args: $a"
"$SALA" revive --only sala-test-e >/dev/null 2>&1
a=$(args_of "$(cp_of e)"); has "$a" "--resume $UE" && ! has "$a" "--name" && ok "e: nameSource user (a hand rename): no --name" || bad "e args: $a"
"$SALA" revive --only sala-test-c >/dev/null 2>&1
a=$(args_of "$(cp_of c)"); has "$a" "--resume $UC" && ! has "$a" "--name" && ok "c: name == session (nameSource derived): no --name" || bad "c args: $a"

echo "== resume_cmd: --name only for a parked or named resume, only for a safe name"
r=$(resume_cmd "$UPJ" sala-test-p parked); has "$r" "claude --resume $UPJ --name sala-test-p" && ok "parked: --name <session> right after --resume <uuid>" || bad "parked: $r"
r=$(resume_cmd "$UPJ" sala-test-p named); has "$r" "claude --resume $UPJ --name sala-test-p" && ok "named: the same line as parked" || bad "named: $r"
r=$(resume_cmd "$UPJ" 'x y;$(id)' named); ! has "$r" "--name" && ok "named: an unsafe name is never typed" || bad "named unsafe: $r"
r=$(resume_cmd "$UPJ" sala-test-p); ! has "$r" "--name" && ok "no third argument: the line is as before, no --name" || bad "ordinary: $r"
r=$(resume_cmd "$UPJ" 'x y;$(id)' parked); ! has "$r" "--name" && ok "a name outside [a-z0-9-] is never typed" || bad "unsafe name: $r"
for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done
[ "$fail" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
