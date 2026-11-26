#!/usr/bin/env bash
# One idea of "busy" for the recycle, the in-session mod and watch (lib/common.sh subagent_holders, mod_hold, the refusal memory,
# pane_exit; lib/revive.sh check_pane and close_pane; lib/watch.sh deferred_revive; lib/ready.sh; mod/hooks/register.ts).
# The case behind it, in general terms: a session said `sala ready`, was told the recycle would relaunch it as soon as its turn
# ended, and was not relaunched. A subagent it could not stop (no task list showed it) kept running; the in-session mod refused
# the exit for it ("a turn is running"), sala's own idle check could not see it, and watch's deferred list tried again every
# tick, logging "is free now" over a hundred times with the same refusal. Later `sala ready` said no recycle was waiting, because the
# set had given the pane up (SALA_LATER_LIMIT) while the deferred list still wanted it. Three observations, each reproduced here:
#  1. A running subagent is seen. Its transcript (<projects>/<slug>/<uuid>/subagents/agent-<id>.jsonl, with a .meta.json that says
#     "finished" once it ends) is read: an unfinished one written since this claude started, and not older than SALA_SUBAGENT_STALE, that
#     wrote within SALA_SUBAGENT_QUIET (30 min) or has a process under the pane that it started (a longer-quiet one with none stopped
#     without saying so), holds the pane, even for a session that said ready. A finished one, one from before this process (a resume
#     leaves them behind) and a pane with none do not. `sala ready` names it and does not promise a relaunch "as soon as this turn ends"; the relaunch notice
#     (relaunch_text) names it too.
#  2. watch's deferred list asks the mod first (the `busy` probe, mod_hold): a turn the mod names holds the pane, said ONCE in the
#     log with the holder, and no exit is tried against it, so no "is free now" line and no retry worker per tick. A pane held only by a
#     running subagent (old mod, no holder named) is held the same way and never cut, however many ticks pass. A pane the mod keeps
#     refusing for a turn it cannot name, while the registry, the Stop record, the children and the subagent transcripts all read it as
#     idle, is tried every tick SALA_STALE_TURN_AFTER times, counted in the refusal memory (refused/<uuid>); the next try goes by keys,
#     is logged so, and relaunches it; the memory goes with the relaunch.
#  3. `sala ready` sees a pane on the deferred list as waiting, also after the limit post and the set's partial clear.
# Part 1 uses bash stand-ins for a claude (a registry row, no tmux); part 2 a tmux server of its own, the compiled fake claude and
# a fake mod (a unix socket that answers the mod's lines, as in tests/mod.sh). Slack stubbed to a file. Isolated HOME.
# Usage: bash tests/holdmatch.sh   (exit 0 = pass)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SET SALA_SET_SELF SALA_RECYCLE SALA_RETRY_WORKER SALA_RELAUNCH_KIND SALA_RELAUNCH_WAITING_TEXT SALA_LATER_LIMIT SALA_LATER_RETELL SALA_LATER_RETELL_MAX SALA_MOD_DIR SALA_STALE_TURN_AFTER SALA_SUBAGENT_STALE
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC XDG_RUNTIME_DIR="$HOME/run"
exec {HOME_LOCK}< "$HOME"; flock -n "$HOME_LOCK" 2>/dev/null   # the temp folder is locked while the suite runs (systemd-tmpfiles ageing honors it)
as_op_unit
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$XDG_RUNTIME_DIR"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
FAKEBIN="$HOME/.local/share/claude/versions/9.9.9"
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$FAKEBIN" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }
ln -s "$FAKEBIN" "$HOME/.local/bin/claude"
printf '#!/bin/sh\necho "$*" >> "%s/systemd-run.txt"\n' "$HOME" > "$HOME/.local/bin/systemd-run"; chmod +x "$HOME/.local/bin/systemd-run"   # watch launches nothing
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log" FAKE_SOCK_LOG="$HOME/sock.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off SALA_MOD_WAIT=1
SALA="$ROOT/bin/salamander"; SOCK="sala-holdm-$$"; T="tmux -L $SOCK -f /dev/null"; WLOG="$HOME/.claude/salamander-watch.log"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"
PIDS=(); FP=""; FAKEMOD=""
killtree() { local k; _children_r k "$2"; [ -z "$k" ] || kill "$1" $k 2>/dev/null; kill "$1" "$2" 2>/dev/null; true; }   # <signal> <pid> → its children, then it (no pkill)
cleanup() {
    local p
    for p in ${PIDS[@]+"${PIDS[@]}"}; do killtree -TERM "$p"; done
    [ -n "$FAKEMOD" ] && kill "$FAKEMOD" 2>/dev/null
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    for p in ${PIDS[@]+"${PIDS[@]}"}; do killtree -KILL "$p"; done
    kill_fake_claude "$FAKEBIN"
    rm -rf "${HOME:?}" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux
. "$ROOT/lib/common.sh"
cd "$HOME" || exit 1
SLUG=$(slug_for_cwd "$HOME")
row() { local now; printf -v now '%(%s)T' -1; printf '{"pid":%s,"sessionId":"%s","name":"t","status":"%s","startedAt":%s,"statusUpdatedAt":%s,"version":"9.9.9"}\n' "$1" "$2" "$3" "$(( (now - 3600) * 1000 ))" "$(( (now - 60) * 1000 ))" > "$HOME/.claude/sessions/$1.json"; }   # a claude that started an hour ago
fake() { bash -c "$1" & FP=$!; PIDS+=("$FP"); row "$FP" "$2" "${3:-idle}"; nap 0.4; }   # a claude stand-in running $1, registered under $2; its pid in FP
subdir() { echo "$HOME/.claude/projects/$SLUG/$1/subagents"; }   # <uuid> → where its subagents' transcripts are
mksub() {  # <uuid> <id> <type> <description> [finished] — a subagent's transcript and its meta, as the CLI writes them
    local d; d=$(subdir "$1"); mkdir -p "$d"; printf '{"type":"user"}\n' > "$d/agent-$2.jsonl"
    printf '{"agentType":"%s","description":"%s","requestShape":"background"%s}\n' "$3" "$4" "${5:+,\"finished\":true}" > "$d/agent-$2.meta.json"
}
slurp() { local c=""; [ -r "$1" ] && { IFS= read -r -d '' c < "$1"; } 2>/dev/null; printf '%s' "$c"; }
nlog() { local n=0 l; [ -r "$2" ] || { echo 0; return; }; while IFS= read -r l || [ -n "$l" ]; do [[ $l == *"$1"* ]] && n=$((n + 1)); done < "$2"; echo "$n"; }   # <needle> <file> → how many lines hold it

echo "== 1. a running subagent is seen, also for a session that said ready"
U1=$(uuid 51); U2=$(uuid 52)
fake "while [ ! -e $HOME/go1 ]; do sleep 0.2; done; \"$SALA\" ready > $HOME/ready1.txt 2>&1; : > $HOME/ready1.done; wait" "$U1"; K1=$FP
mkdir -p "$SALA_READY_DIR"; date +%s > "$SALA_READY_DIR/$U1"
[ -z "$(is_idle_reason "$K1")" ] && is_idle "$K1" && ok "said ready, no subagent: idle (as before)" || bad "baseline: '$(is_idle_reason "$K1")'"
mksub "$U1" s1 builder "Build the package move"
why=$(is_idle_reason "$K1")
[ "$why" = "a subagent is running: subagent builder: Build the package move (last wrote under 1 min ago)" ] && ok "an unfinished subagent holds a pane that said ready, named with its type and description" || bad "subagent reason: '$why'"
is_idle "$K1"; [ $? = 1 ] && ok "is_idle agrees (busy)" || bad "is_idle: $?"
grep -q '"a subagent is running"' "$ROOT/lib/revive.sh" && ok "the sweep reads it as transient (retried), not a failure" || bad "transient_skip lacks the subagent reason"
mksub "$U1" s1 builder "Build the package move" finished
[ -z "$(is_idle_reason "$K1")" ] && ok "the subagent finished: idle again" || bad "finished: '$(is_idle_reason "$K1")'"
mksub "$U1" s1 builder "Build the package move"; touch -d '3 hours ago' "$(subdir "$U1")/agent-s1.jsonl"
[ -z "$(is_idle_reason "$K1")" ] && ok "a transcript older than this claude (a resume leaves them behind): not running" || bad "old transcript: '$(is_idle_reason "$K1")'"
mksub "$U1" s1 builder "Build the package move"; touch -d '10 minutes ago' "$(subdir "$U1")"/agent-s1.*
[ "$(is_idle_reason "$K1")" = "a subagent is running: subagent builder: Build the package move (last wrote under 15 min ago)" ] && ok "quiet for 10 minutes (a long tool call) and not finished: still running" || bad "quiet subagent: '$(is_idle_reason "$K1")'"
mksub "$U1" s1 builder "Build the package move"; touch -d '45 minutes ago' "$(subdir "$U1")"/agent-s1.*
[ -z "$(is_idle_reason "$K1")" ] && ok "quiet for 45 min (over SALA_SUBAGENT_QUIET, 30 min) with no process under the pane: a subagent that stopped without a finish line is not live" || bad "45 min quiet, no process: '$(is_idle_reason "$K1")'"
[ "$(SALA_SUBAGENT_QUIET=7200 is_idle_reason "$K1")" = "a subagent is running: subagent builder: Build the package move (last wrote under 60 min ago)" ] && ok "SALA_SUBAGENT_QUIET=7200: the same 45 min is live again" || bad "QUIET=7200: '$(SALA_SUBAGENT_QUIET=7200 is_idle_reason "$K1")'"
ORIG_HR=$(declare -f holders_run)
holders_run() { printf '1\npid 99, up 2400 s, task tk1, started by a subagent (s1): sleep 5000\n'; }   # a process of this subagent runs under the pane
[ "$(is_idle_reason "$K1")" = "a subagent is running: subagent builder: Build the package move (last wrote under 60 min ago)" ] && ok "quiet for 45 min but a process under the pane was started by it: live (the process is the proof)" || bad "45 min quiet, its process: '$(is_idle_reason "$K1")'"
holders_run() { printf '1\npid 99, up 2400 s, task tk1, started by a subagent (zz9): sleep 5000\n'; }   # another subagent's process
[ -z "$(is_idle_reason "$K1")" ] && ok "a process started by ANOTHER subagent does not make this one live" || bad "other subagent's process: '$(is_idle_reason "$K1")'"
holders_run() { printf '1\npid 99, up 2400 s, task tk1: sleep 5000\n'; }   # a process no subagent started
[ -z "$(is_idle_reason "$K1")" ] && ok "a process no subagent started does not either" || bad "plain process: '$(is_idle_reason "$K1")'"
eval "$ORIG_HR"
mksub "$U1" s1 builder "Build the package move"; touch -d '4 minutes ago' "$(subdir "$U1")"/agent-s1.*
[ "$(is_idle_reason "$K1")" = "a subagent is running: subagent builder: Build the package move (last wrote under 5 min ago)" ] && ok "wrote 4 min ago: live with no process lookup" || bad "4 min: '$(is_idle_reason "$K1")'"
mksub "$U1" s1 builder "Build the package move"
n=$(relaunch_text recycle "$K1"); has "$n" "Holding the relaunch: 1 subagent running in this session" && has "$n" "subagent builder: Build the package move" \
    && has "$n" "sala never cuts a running subagent" && ok "the relaunch notice names it and says it is not cut" || bad "notice: $n"
bash -c 'trap : USR1; while :; do sleep 1; done' & WK=$!; PIDS+=("$WK"); echo "$WK" > "$HOME/.claude/salamander-retry.$WK.pid"   # a pending recycle's retry worker, so ready_wake succeeds
# wait for the `sala ready` process to exit (its .done marker), not for the file's first byte: it writes the holder block, then the ready: line
: > "$HOME/go1"; waitfor '[ -e "$HOME/ready1.done" ]' 20
r=$(slurp "$HOME/ready1.txt")
has "$r" "Holding the relaunch: 1 subagent running in this session" && has "$r" "subagent builder: Build the package move" \
    && has "$r" "ready: t ($U1) — held by the subagent(s) above; the relaunch follows within minutes after they end, not when this turn does" \
    && ! has "$r" "as soon as this turn ends" && ok "sala ready names the subagent and does not promise a relaunch when the turn ends" || bad "ready: $r"
kill "$WK" 2>/dev/null; rm -f "$HOME/.claude/salamander-retry.$WK.pid"

echo "== 4. the skip line names its cause, never only 'busy'"
[ "$(_count_words 1 0 0 0)" = "1 subagent" ] && [ "$(_count_words 4 6 1 0)" = "4 subagents, 6 monitors and 1 shell" ] && [ "$(_count_words 0 2 1 0)" = "2 monitors and 1 shell" ] \
    && [ "$(_count_words 0 0 0 3)" = "3 other tasks" ] && [ -z "$(_count_words 0 0 0 0)" ] && ok "the counts in words: one kind, two, three, other tasks, nothing" || bad "count words: $(_count_words 4 6 1 0) / $(_count_words 0 2 1 0)"
[ "$(_inflight_words 1 0 0 0)" = "1 subagent is in flight" ] && [ "$(_inflight_words 4 6 1 0)" = "4 subagents, 6 monitors and 1 shell are in flight" ] && ok "with the verb: is for one, are for several" || bad "inflight words: $(_inflight_words 4 6 1 0)"
U4=$(uuid 71); fake "sleep 300" "$U4" busy; K4=$FP
[ "$(is_idle_reason "$K4")" = "registry says 'busy' (a turn is running for 1 min)" ] && ok "a busy row with no record: the turn and its age" || bad "busy, bare: '$(is_idle_reason "$K4")'"
mksub "$U4" b1 builder "Build the package move"
[ "$(is_idle_reason "$K4")" = "registry says 'busy' (a turn is running for 1 min; 1 subagent running)" ] && ok "no record, a subagent running by its transcript: it is named" || bad "busy, subagent: '$(is_idle_reason "$K4")'"
rm -f "$(subdir "$U4")"/agent-b1.*
mkdir -p "$SALA_BUSY_DIR"
{ printf 'id=1-1\nepoch=1\nseen=1\nseen_status=busy\ntasks=12\ncrons=0\n'
  for i in 1 2 3 4; do echo "task=subagent running: step $i (worker-agent)"; done
  for i in 1 2 3 4 5 6; do echo "task=monitor running: watch $i (mcp/tool)"; done
  echo "task=shell running: wait for CI (sleep 60)"
  echo "task=monitor running: live updates for artifact https://claude.ai/artifact/EXAMPLE1 (auto-armed on publish)"
} > "$SALA_BUSY_DIR/$U4"
why=$(is_idle_reason "$K4")
[ "$why" = "registry says 'busy' (a turn is running for 1 min; in flight when its last turn ended: 4 subagents, 6 monitors and 1 shell)" ] && ok "the Stop hook's record counted: 4 subagents, 6 monitors and 1 shell (an artifact watch is not counted)" || bad "busy, record: '$why'"
case "$why" in *"a background task is running"*|*"background work in flight"*|*"background work is running"*) bad "the busy cause reads as background work to hold_bullet";; *) ok "the words never match what hold_bullet and the retry worker read as background work";; esac
b=$(hold_bullet sala-q "$K4" "$why"); case "$b" in "sala-q: busy for "*"; sala relaunches it once it is free") ok "a recycle's post keeps its short 'busy for <age>' form";; *) bad "bullet: $b";; esac
case "$why" in "registry says 'busy' ("*) ok "it still opens with the registry says head, which transient_skip (revive.sh) reads as a retry";; *) bad "head: $why";; esac
U5=$(uuid 72); fake "sleep 300" "$U5" waiting; K5=$FP
[ "$(is_idle_reason "$K5")" = "registry says 'waiting' (a dialog is open: the pane waits for an answer)" ] && ok "a waiting row is a dialog, said so" || bad "waiting: '$(is_idle_reason "$K5")'"
rm -f "$SALA_BUSY_DIR/$U4"

echo "== 3. sala ready sees a pane on the deferred list as waiting"
rm -f "$(subdir "$U1")"/agent-s1.*; rm -f "$SALA_DEFERRED"
fake "while [ ! -e $HOME/go2 ]; do sleep 0.2; done; \"$SALA\" ready > $HOME/ready2.txt 2>&1; : > $HOME/ready2.done; wait" "$U2"
: > "$HOME/go2"; waitfor '[ -e "$HOME/ready2.done" ]' 20; r=$(slurp "$HOME/ready2.txt")
has "$r" "no recycle is waiting right now" && ok "nothing waiting, nothing on the list: the old line" || bad "ready, no row: $r"
U3=$(uuid 53)
fake "while [ ! -e $HOME/go3 ]; do sleep 0.2; done; \"$SALA\" ready > $HOME/ready3.txt 2>&1; : > $HOME/ready3.done; wait" "$U3"; K3=$FP
# held 4 h: past SALA_LATER_LIMIT, the limit post sent, the recycle's sets gave the pane up (set_giveup_pane) — and watch still means to relaunch it
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' sala-test-x "$(( $(date +%s) - 14400 ))" "background work is running" "$K3" 1 - 0 3 "$(date +%s)" > "$SALA_DEFERRED"
: > "$HOME/go3"; waitfor '[ -e "$HOME/ready3.done" ]' 20; r=$(slurp "$HOME/ready3.txt")
has "$r" "this pane is on the deferred list since" && ! has "$r" "no recycle is waiting right now" && ok "a pane on the deferred list is waiting, whatever its sets said" || bad "ready, row: $r"
rm -f "$SALA_DEFERRED"

echo "== 2. watch's deferred list: the mod's answer, one line with the holder, the tries thin out, a running subagent is never cut"
UH=$(uuid 61); UM=$(uuid 62)
MODE="$HOME/fakemod.mode"; HEARD="$HOME/fakemod.heard"; MSOCK="$HOME/fakemod.sock"; RUN="$XDG_RUNTIME_DIR/sala/mod"
cat > "$HOME/fakemod.py" <<'PY'
import json, os, socket, subprocess, sys, threading, time
sock, run, mode, heard, home, tsock = sys.argv[1:7]
try: os.unlink(sock)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX); s.bind(sock); s.listen(8)
def rd(p, d=""):
    try: return open(p).read().strip()
    except Exception: return d
def put(path, obj):
    tmp = path + ".tmp"; open(tmp, "w").write(json.dumps(obj) + "\n"); os.replace(tmp, path)
HOLD = "subagent builder: Build the package move"
def serve(c):
    data = b""
    while not data.endswith(b"\n"):
        b = c.recv(65536)
        if not b: break
        data += b
    c.close()
    try: text = json.loads(data)["message"]["content"]
    except Exception: return
    open(heard, "a").write(json.dumps(text) + "\n")
    if not text.startswith("[sala-mod] "): return
    verb, req, *rest = text[len("[sala-mod] "):].split("\n")[0].split(" ")
    m = rd(mode, "ok"); sid = rd(os.path.join(home, "fakemod.sid"))
    out = {"reqid": req, "ok": True}
    if verb == "draft": out["text"] = ""
    elif verb in ("exit", "busy"):
        if m == "named": out = {"reqid": req, "ok": False, "reason": "turn", "holders": HOLD}
        elif m == "background": out = {"reqid": req, "ok": False, "reason": "background", "tasks": ["subagent running", "subagent running", "monitor running", "shell running"]}
        elif m == "turnold":   # a mod loaded before this release: its turn list is stale, it names nothing and does not know `busy`
            out = {"reqid": req, "ok": False, "reason": "turn"} if verb == "exit" else {"reqid": req, "ok": False, "reason": "unknown"}
    d = next((x for x in run.split(":") if os.path.exists(os.path.join(x, sid + ".json"))), run.split(":")[0])
    os.makedirs(d, exist_ok=True); put(os.path.join(d, "%s.%s.reply.json" % (sid, req)), out)
while True:
    c, _ = s.accept(); threading.Thread(target=serve, args=(c,), daemon=True).start()
PY
echo named > "$MODE"; echo "$UH" > "$HOME/fakemod.sid"
python3 "$HOME/fakemod.py" "$MSOCK" "$RUN:$SALA_STATE_DIR/mod" "$MODE" "$HEARD" "$HOME" "$SOCK" & FAKEMOD=$!
waitfor '[ -S "$MSOCK" ]' 20 || { echo "the fake mod did not start"; exit 1; }
mk() { local n="$1" u="$2"; shift 2; $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="$n" -e FAKE_LOG="$FAKE_LOG" -e FAKE_SOCK_LOG="$FAKE_SOCK_LOG" "$@"; $T send-keys -t "sala-test-$n" 'claude' Enter; }
watch_tick() { "$SALA" watch >/dev/null 2>&1; }
heard_n() { nlog "$1" "$HEARD"; }
mk hm "$UH" -e FAKE_STARTED_AT=$(( $(date +%s) - 3600 )); mk mm "$UM"; fake_up hm mm
HP=$(cpid hm); PANE=$($T list-panes -t =sala-test-hm -F '#{pane_id}' | head -1)
python3 -c 'import json,sys; f=sys.argv[1]; d=json.load(open(f)); d["messagingSocketPath"]=sys.argv[2]; json.dump(d,open(f,"w"))' "$HOME/.claude/sessions/$HP.json" "$MSOCK"
mkdir -p "$RUN"; printf '{"present":true,"version":%s,"sessionId":"%s","at":%s000}\n' "$SALA_MOD_VERSION" "$UH" "$(date +%s)" > "$RUN/$UH.json"
defer_row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' sala-test-hm "$(( $(date +%s) - 600 ))" "said ready, but background shell(s) are still running (registry state 'shell')" "$HP" 1 - 0 0 0 > "$SALA_DEFERRED"; }
: > "$POSTS"; : > "$HEARD"; : > "$WLOG"; rm -f "$SALA_DEFERRED"
defer_row
HOLDER="a turn is running: subagent builder: Build the package move"

echo "-- the mod names the holder (a mod from this release): ticks say it once and try no exit"
watch_tick; watch_tick; watch_tick
[ "$(nlog "deferred: sala-test-hm held — $HOLDER" "$WLOG")" = 1 ] && ok "three ticks, ONE log line, with the holder" || bad "held lines: $(grep deferred "$WLOG")"
[ "$(nlog "is free now" "$WLOG")" = 0 ] && [ "$(heard_n '[sala-mod] exit')" = 0 ] && [ "$(heard_n '[sala-mod] busy')" -ge 3 ] && ok "no 'is free now', no exit asked of the mod: only the probe" || bad "free now: $(nlog "is free now" "$WLOG"), exits $(heard_n '[sala-mod] exit'), probes $(heard_n '[sala-mod] busy')"
[ "$(cpid hm)" = "$HP" ] && grep -q "^sala-test-hm	" "$SALA_DEFERRED" && ok "the pane is untouched and stays on the list" || bad "moved: $(cpid hm) / $(<"$SALA_DEFERRED")"
out=$(SALA_RETRY_WORKER=1 "$SALA" revive --only sala-test-hm --force 2>&1)
has "$out" "sala-test-hm:0: $HOLDER — left on 9.9.9" && [ "$(heard_n '[sala-mod] exit')" = 0 ] && ok "a sweep's check says what holds it, before anything is held or typed" || bad "sweep: $out"
refusal_get rf "$UH"; [ "${rf%%$'\t'*}" -ge 1 ] 2>/dev/null && ok "the refusal is remembered (count $(printf '%s' "${rf%%$'\t'*}"))" || bad "no refusal memory: '$rf'"
refusal_clear "$UH"

echo "-- the mod lists background work (shells, monitors, subagents no check of sala's sees): held and named, never 'free now'"
echo background > "$MODE"; : > "$WLOG"; : > "$HEARD"; rm -f "$SALA_REFUSED_DIR/$UH.said"
BGW="background work is running: 2 subagents, 1 monitor and 1 shell are in flight"
for i in 1 2 3 4 5 6; do watch_tick; done
[ "$(nlog "deferred: sala-test-hm held — $BGW" "$WLOG")" = 1 ] && ok "six ticks, ONE log line, with what is in flight" || bad "held lines: $(grep deferred "$WLOG")"
[ "$(nlog "is free now" "$WLOG")" = 0 ] && [ "$(heard_n '[sala-mod] exit')" = 0 ] && [ "$(heard_n '[sala-mod] busy')" -ge 6 ] && [ "$(cpid hm)" = "$HP" ] \
    && ok "no 'is free now', no sweep and no exit tried against it: only the probe, the pane untouched" || bad "free now $(nlog "is free now" "$WLOG"), exits $(heard_n '[sala-mod] exit'), probes $(heard_n '[sala-mod] busy'), pid $(cpid hm)"
out=$(SALA_RETRY_WORKER=1 "$SALA" revive --only sala-test-hm --force 2>&1)
has "$out" "sala-test-hm:0: $BGW — left on 9.9.9" && [ "$(heard_n '[sala-mod] exit')" = 0 ] && ok "a sweep's check says it too, before anything is held or typed" || bad "sweep: $out"
refusal_get rf "$UH"; [ -z "$rf" ] && ok "work in flight is not counted in the refusal memory (it only thins out a mod's stale turns)" || bad "refusal memory: '$rf'"
echo named > "$MODE"; rm -f "$SALA_REFUSED_DIR/$UH.said"

echo "-- an older mod's refusal, a subagent running: never cut, however many ticks"
echo turnold > "$MODE"; : > "$WLOG"; : > "$HEARD"; mksub "$UH" h1 builder "Build the package move"; touch -d "10 minutes ago" "$(subdir "$UH")"/agent-h1.*   # quiet for 10 min: the 2-minute scratch test does not see it, the transcript does
for i in 1 2 3 4 5 6; do watch_tick; done
[ "$(nlog "deferred: sala-test-hm held — a subagent is running: subagent builder: Build the package move" "$WLOG")" = 1 ] && ok "six ticks, ONE log line, naming the subagent" || bad "held lines: $(grep deferred "$WLOG")"
[ "$(heard_n '[sala-mod] exit')" = 0 ] && [ "$(cpid hm)" = "$HP" ] && [ "$(nlog "is free now" "$WLOG")" = 0 ] && ok "no exit tried, the pane untouched: a running subagent is never cut" || bad "cut: exits $(heard_n '[sala-mod] exit') pid $(cpid hm)"

echo "-- the subagent finished, the old mod still refuses: three refusals, then the exit by keys"
mksub "$UH" h1 builder "Build the package move" finished; touch -d "10 minutes ago" "$(subdir "$UH")"/agent-h1.*
: > "$WLOG"; : > "$HEARD"; rm -f "$SALA_REFUSED_DIR/$UH" "$SALA_REFUSED_DIR/$UH.said"
watch_tick; watch_tick; watch_tick
refusal_get rf "$UH"; n=${rf%%$'\t'*}
[ "$(nlog "is free now" "$WLOG")" = 3 ] && [ "$n" = 3 ] && [ "$(cpid hm)" = "$HP" ] && ok "three ticks: tried each time, refused each time, counted ($n)" || bad "tries: free now $(nlog "is free now" "$WLOG"), count '$n', pid $(cpid hm)"
[ "$(nlog "a turn is running (it started after the idle check)" "$WLOG")" = 3 ] && ok "each refusal is the mod's, the pane untouched" || bad "refusals: $(grep -c 'a turn is running' "$WLOG")"
[ "$(nlog "retry worker started" "$WLOG")" = 0 ] && ! ls "$HOME"/.claude/salamander-retry*.pid >/dev/null 2>&1 && ok "no retry worker per try (the list is the retry)" || bad "a try started a retry worker: $(grep "retry worker" "$WLOG")"
watch_tick
waitfor '[ -n "$(cpid hm)" ] && [ "$(cpid hm)" != "$HP" ]' 60 && ok "the fourth tick: relaunched" || bad "not relaunched: $(grep -E 'deferred|exit' "$WLOG" | tail -5)"
[ "$(nlog "via keys (the mod refused for a turn it could not name, 3 times" "$SALA_MOD_LOG")" = 1 ] && ok "the exit by keys, logged with why" || bad "mod log: $(<"$SALA_MOD_LOG")"
[ ! -s "$SALA_DEFERRED" ] && [ ! -e "$SALA_REFUSED_DIR/$UH" ] && ok "the row and the refusal memory are gone with the relaunch" || bad "left: $(slurp "$SALA_DEFERRED") / $(ls "$SALA_REFUSED_DIR" 2>&1)"
[ "$(nlog "is free now" "$WLOG")" = 4 ] && ok "four 'is free now' lines in all, not one per tick for ever" || bad "free now lines: $(nlog "is free now" "$WLOG")"

echo "holdmatch: $([ "$fail" = 0 ] && echo pass || echo FAIL)"
exit $fail
