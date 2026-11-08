#!/usr/bin/env bash
# The mod (mod/, lib/common.sh "the mod"): sala's side of it against a fake mod — a unix socket that takes
# session_push's line, as the mod's session.receive hook does, and writes the reply file the way the mod does.
# Checks: mod_request with no stamp (no push at all), a stamp (draft text back, the reply file removed, the line marked
# and explained), a stamp older than the process, an old protocol version, the state-dir fallback when XDG_RUNTIME_DIR is
# unset, no messaging socket, no reply (rc 4 within SALA_MOD_WAIT); pane_draft: either the mod or the screen counts, the
# mod's text first, the screen alone when the mod does not answer; pane_exit: background → 2, a draft → 3 with its text,
# a running turn → 4 (what holds it on stdout, when the mod names it; mod_hold, the `busy` probe, says it as a skip reason),
# no mod → /exit typed; pane_rename: through the mod, the keys when it does not answer; the log line per request.
# The launch line: mod_env_prefix appends the mod's folder to what the pane's shell already has, is empty when switched
# off or the path needs quoting; `sala spawn` and a `revive --only` resume start claude with it (the fake logs its env);
# a recycle of a pane whose mod takes the exit relaunches it through the mod (no keys typed), and one whose mod refuses
# for background work is left alone with today's background row, one it refuses for a running turn with a retried skip;
# an older mod refusing for an artifact watch alone (auto-armed, or armed on request) is answered by keys when
# the busy record agrees; an unknown label on the monitor is not.
# The message marker (Mon Oct 12th, the board's quote-origin check): tui_send types a message with `<!-- sala -->` in
# front and a slash command bare (the fake logs every line that reaches its composer, FAKE_TYPED_LOG); a marked leftover in
# the box is cleared before the next command, someone's draft still refuses it; spawn's brief line carries the marker.
# Isolated HOME and XDG_RUNTIME_DIR, a private tmux server started with -f /dev/null, the compiled fake claude.
# Usage: bash tests/mod.sh   (exit 0 = pass; ~20 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SET SALA_RECYCLE SALA_RETRY_WORKER CLAUDE_CODE_PLUGIN_DIRS SALA_MOD_DIR
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, tmux_socket_rm
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC XDG_RUNTIME_DIR="$HOME/run"
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$XDG_RUNTIME_DIR"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log" FAKE_ENV_LOG="$HOME/env.log"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off SALA_MOD_WAIT=1
SALA="$ROOT/bin/salamander"; SOCK="sala-mod-$$"; T="tmux -L $SOCK -f /dev/null"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's (common.sh, on_fleet_server)
KID=""; FAKEMOD=""
cleanup() {
    local f p; for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done
    [ -n "$KID" ] && kill "$KID" 2>/dev/null; [ -n "$FAKEMOD" ] && kill "$FAKEMOD" 2>/dev/null
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    for p in $(pgrep -x claude); do [ "$HOME/.local/share/claude/versions/9.9.9" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux
. "$ROOT/lib/common.sh"
RUN="$XDG_RUNTIME_DIR/sala/mod"; MODE="$HOME/fakemod.mode"; HEARD="$HOME/fakemod.heard"; MSOCK="$HOME/fakemod.sock"
now_ms() { echo "$(date +%s)000"; }
stamp() {  # <dir> <uuid> [at ms] [version] — a presence stamp as the mod writes it
    mkdir -p "$1"; printf '{"present":true,"version":%s,"sessionId":"%s","at":%s}\n' "${4:-1}" "$2" "${3:-$(now_ms)}" > "$1/$2.json"
}
point_socket() {  # <pid> — the registry row's messaging socket → the fake mod's
    python3 -c 'import json,sys; f=sys.argv[1]; d=json.load(open(f)); d["messagingSocketPath"]=sys.argv[2]; json.dump(d,open(f,"w"))' "$HOME/.claude/sessions/$1.json" "$MSOCK"
}
# the fake mod: one session at a time (its id in $HOME/fakemod.sid), the behaviour from the mode file:
#   ok · silent (never answers) · background, turn (refuse exit) · bgwatch (refuses exit for one monitor, as an older mod
#   does for an artifact watch) · draft:<text> (that text in the box; exit refused over it)
# ok and exit with a pane named in $HOME/fakemod.pane: the exit "runs" as /exit typed there, as the CLI would act on it
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
    m = rd(mode, "ok"); sid = rd(os.path.join(home, "fakemod.sid")); box = m[6:] if m.startswith("draft:") else ""
    if m == "silent": return
    out = {"reqid": req, "ok": True}
    if verb == "draft": out["text"] = box
    elif verb in ("exit", "busy"):   # `busy` is the exit's gates with nothing run
        if box: out = {"reqid": req, "ok": False, "reason": "draft", "text": box}
        elif m == "background": out = {"reqid": req, "ok": False, "reason": "background", "tasks": ["shell running"]}
        elif m == "turn": out = {"reqid": req, "ok": False, "reason": "turn"}
        elif m == "named": out = {"reqid": req, "ok": False, "reason": "turn", "holders": "subagent builder: Build the package move"}   # a mod from this release names what holds it
        elif m == "bgwatch": out = {"reqid": req, "ok": False, "reason": "background", "tasks": ["monitor running"]}   # an older mod
    # the reply goes beside the stamp, as the mod writes both in its one directory
    d = next((x for x in run.split(":") if os.path.exists(os.path.join(x, sid + ".json"))), run.split(":")[0])
    os.makedirs(d, exist_ok=True); put(os.path.join(d, "%s.%s.reply.json" % (sid, req)), out)
    pane = rd(os.path.join(home, "fakemod.pane"))
    if verb == "exit" and out["ok"] and pane:
        time.sleep(0.3)
        subprocess.run(["tmux", "-L", tsock, "-f", "/dev/null", "send-keys", "-t", pane, "/exit", "Enter"])
while True:
    c, _ = s.accept(); threading.Thread(target=serve, args=(c,), daemon=True).start()
PY
python3 "$HOME/fakemod.py" "$MSOCK" "$RUN:$SALA_STATE_DIR/mod" "$MODE" "$HEARD" "$HOME" "$SOCK" & FAKEMOD=$!
waitfor '[ -S "$MSOCK" ]' 20 || { echo "the fake mod did not start"; exit 1; }
heard_n() { grep -c . "$HEARD" 2>/dev/null || echo 0; }

echo "== mod_request: stamp absent / present / stale / old version / fallback dir / no socket / no reply"
sleep 900 & KID=$!
U1=11111111-0000-4000-8000-000000000001; echo "$U1" > "$HOME/fakemod.sid"; echo ok > "$MODE"
printf '{"pid":%s,"sessionId":"%s","name":"t","status":"idle","messagingSocketPath":"%s"}\n' "$KID" "$U1" "$MSOCK" > "$HOME/.claude/sessions/$KID.json"
n0=$(heard_n); mod_request "$KID" draft; rc=$?
[ "$rc" = 3 ] && [ "$MOD_WHY" = "no stamp" ] && [ "$(heard_n)" = "$n0" ] && ok "no stamp: rc 3 (no stamp), nothing pushed" || bad "no stamp: rc=$rc why='$MOD_WHY' heard $(heard_n)"
stamp "$RUN" "$U1"; echo "draft:half a thought" > "$MODE"
mod_request "$KID" draft; rc=$?
[ "$rc" = 0 ] && [ "$(mod_reply_field "$MOD_REPLY" text)" = "half a thought" ] && ok "a stamp: rc 0, the box's text back" || bad "stamp: rc=$rc why='$MOD_WHY' reply='$MOD_REPLY'"
[ -z "$(ls "$RUN"/*.reply.json 2>/dev/null)" ] && ok "the reply file is removed once read" || bad "reply left: $(ls "$RUN")"
python3 -c 'import json,sys; t=json.loads(open(sys.argv[1]).read().splitlines()[-1]); l=t.split("\n"); sys.exit(0 if l[0].startswith("[sala-mod] draft ") and len(l[0].split(" "))==3 and "mod is not loaded" in l[1] else 1)' "$HEARD" \
    && ok "the line: '[sala-mod] draft <reqid>', then a line telling a model to ignore it" || bad "pushed: $(tail -1 "$HEARD")"
stamp "$RUN" "$U1" "$(( $(date +%s) - 3600 ))000"; mod_request "$KID" draft; rc=$?
[ "$rc" = 3 ] && [ "$MOD_WHY" = "a stamp older than the process" ] && ok "a stamp older than the process: rc 3 (a pane resumed without the mod)" || bad "stale: rc=$rc why='$MOD_WHY'"
stamp "$RUN" "$U1" "" 0; mod_request "$KID" draft; rc=$?
[ "$rc" = 3 ] && [ "$MOD_WHY" = "mod version 0" ] && ok "protocol version 0: rc 3" || bad "version: rc=$rc why='$MOD_WHY'"
rm -f "$RUN/$U1.json"; stamp "$SALA_STATE_DIR/mod" "$U1"
( unset XDG_RUNTIME_DIR; mod_request "$KID" draft; echo "$?|$(mod_reply_field "$MOD_REPLY" text)" > "$HOME/sub.out" )
[ "$(<"$HOME/sub.out")" = "0|half a thought" ] && ok "XDG_RUNTIME_DIR unset: the state dir's mod/ (the mod's own fallback)" || bad "fallback dir: $(<"$HOME/sub.out")"
mod_request "$KID" draft; [ $? = 0 ] && ok "a stamp in the fallback dir is found with XDG_RUNTIME_DIR set too" || bad "fallback dir with XDG set: $MOD_WHY"
rm -f "$SALA_STATE_DIR/mod/$U1.json"; stamp "$RUN" "$U1"
# THE TIME BOUND (CI, many suites side by side: "silent: rc=4 why='no reply in 1s' 2866ms" against a bound of
# 2500 ms on the whole call): the call's own overhead — ps for the process's start, a python3 for the registry row and the
# stamp, another for the push — is about 0.1 s on an idle box and near 2 s under the suites' load, and the default wait is
# only 3 s (common.sh, SALA_MOD_WAIT: its loop alone is 30 polls, 3000 ms at the least), so no bound on the whole call can
# both tolerate the load and stay under the default. The overhead is measured instead: the same request answered at once,
# right before, and the silent one must take under 2.8 s more than it (the 1 s loop: 10 polls, about 1 s more; the default's:
# 30 polls, about 3 s more, whatever the load, since both calls carry it). Under 2 s that bound failed once the polls
# stretched (seen in CI with 48 suites at once: 2437 ms against an answered 396 ms, 2041 ms
# more, one poll about 0.2 s): the default's silent call is never under about 2900 ms more than an answered one (which
# returns within a poll), however light the load, so 2800 still fails it. MOD_WHY's "1s" is the second witness that the knob
# reached the function.
t0=$(date +%s%N); mod_request "$KID" draft; brc=$?; base=$(( ($(date +%s%N) - t0) / 1000000 ))
echo silent > "$MODE"; t0=$(date +%s%N); mod_request "$KID" draft; rc=$?; ms=$(( ($(date +%s%N) - t0) / 1000000 ))
[ "$brc" = 0 ] && [ "$rc" = 4 ] && [ "$MOD_WHY" = "no reply in 1s" ] && [ $((ms - base)) -lt 2800 ] && ok "no reply: rc 4 after ${ms} ms, ${base} ms for an answered one (SALA_MOD_WAIT=1; the default's loop alone is 3 s)" || bad "silent: rc=$rc why='$MOD_WHY' ${ms}ms (an answered one right before: rc=$brc ${base}ms)"
printf '{"pid":%s,"sessionId":"%s","name":"t","status":"idle","messagingSocketPath":"%s"}\n' "$KID" "$U1" "$HOME/nope.sock" > "$HOME/.claude/sessions/$KID.json"
mod_request "$KID" draft; rc=$?; [ "$rc" = 3 ] && [ "$MOD_WHY" = "no messaging socket" ] && ok "no socket: rc 3" || bad "no socket: rc=$rc why='$MOD_WHY'"
mod_request 999999 draft; rc=$?; [ "$rc" = 3 ] && [ "$MOD_WHY" = "no claude process" ] && ok "no process: rc 3" || bad "no process: rc=$rc why='$MOD_WHY'"
kill "$KID" 2>/dev/null; KID=""

echo "== the launch line: mod_env_prefix"
P=$(mod_env_prefix)
got=$(env -u CLAUDE_CODE_PLUGIN_DIRS bash -c "${P}sh -c 'echo \$CLAUDE_CODE_PLUGIN_DIRS'")
[ "$got" = "$ROOT/mod" ] && ok "a shell without the variable: just the mod's folder" || bad "no var: '$got'"
got=$(CLAUDE_CODE_PLUGIN_DIRS=/other/mods bash -c "${P}sh -c 'echo \$CLAUDE_CODE_PLUGIN_DIRS'")
[ "$got" = "/other/mods:$ROOT/mod" ] && ok "a shell that has one: appended, never clobbered ($got)" || bad "append: '$got'"
[ -z "$(SALA_MOD_DIR= bash -c ". '$ROOT/lib/common.sh'; mod_env_prefix")" ] && ok "SALA_MOD_DIR empty: no prefix (the switch)" || bad "switch off still prefixes"
[ -z "$(SALA_MOD_DIR="$HOME/nowhere" bash -c ". '$ROOT/lib/common.sh'; mod_env_prefix")" ] && ok "no mod folder there: no prefix" || bad "missing folder prefixes"
mkdir -p "$HOME/a dir/.claude-plugin"; touch "$HOME/a dir/.claude-plugin/plugin.json"
[ -z "$(SALA_MOD_DIR="$HOME/a dir" bash -c ". '$ROOT/lib/common.sh'; mod_env_prefix")" ] && ok "a path that needs quoting: no prefix" || bad "quoted path prefixed"
case "$(resume_cmd 22222222-0000-4000-8000-000000000002)" in "${P}claude --resume 22222222-0000-4000-8000-000000000002") ok "resume_cmd carries it (now in common.sh, where unpark reaches it)";; *) bad "resume_cmd: $(resume_cmd 22222222-0000-4000-8000-000000000002)";; esac

echo "== spawn: claude starts with the mod's folder appended to the pane's own"
$T new-session -d -s keep-alive; $T set-environment -g CLAUDE_CODE_PLUGIN_DIRS /other/mods
UM=33333333-0000-4000-8000-000000000003
TYPED="$HOME/typed.log"   # every line that reaches a fake's composer (FAKE_TYPED_LOG): what tui_send typed, marker and all
$T set-environment -g FAKE_SESSION_ID "$UM"; $T set-environment -g FAKE_NAME sala-test-m; $T set-environment -g FAKE_LOG "$FAKE_LOG"; $T set-environment -g FAKE_ENV_LOG "$FAKE_ENV_LOG"; $T set-environment -g FAKE_TYPED_LOG "$TYPED"
out=$("$SALA" spawn sala-test-m --cwd "$HOME" 2>&1); echo "$out" | grep -E '^✅|⚠|✗' | sed 's/^/    /'
[ "$(grep "^$UM " "$FAKE_ENV_LOG" | tail -1)" = "$UM /other/mods:$ROOT/mod" ] && ok "spawn: CLAUDE_CODE_PLUGIN_DIRS=/other/mods:$ROOT/mod" || bad "spawn env: $(slurp "$FAKE_ENV_LOG") / $out"
PANE=$(tmux list-panes -t =sala-test-m -F '#{pane_id}' | head -1)
cpid() { claude_pid_under "$(tmux display -p -t "$PANE" '#{pane_pid}')"; }
C=$(cpid); [ -n "$C" ] || bad "no fake claude in sala-test-m"

echo "== the message marker (Mon Oct 12th, the board's quote-origin check): a message typed carries '$SALA_MSG_MARK', a slash command does not"
# the CLI records a typed message with origin "human", as the owner's own; stackshot refuses a quote from a message carrying
# the marker. A marker on /exit or /rename would turn the command into a message: the pane never exits, the name never takes.
waitfor 'grep -q "^$UM /rename sala-test-m$" "$TYPED"' 10 && ! grep -qF "$SALA_MSG_MARK" "$TYPED" && ok "spawn's /rename typed bare, no marker" || bad "spawn's keystrokes: $(typed_ctx "$TYPED" "$UM")"
tui_send "$PANE" "a message from sala"; rc=$?
[ "$rc" = 0 ] && waitfor 'grep -qxF "$UM $SALA_MSG_MARK a message from sala" "$TYPED"' 10 && ok "a message: typed as '$SALA_MSG_MARK a message from sala', one line, taken on the first Enter" || bad "message: rc=$rc $(typed_ctx "$TYPED" "$UM")"
tui_send "$PANE" "/rename sala-test-m"; rc=$?
[ "$rc" = 0 ] && waitfor '[ "$(tail -1 "$TYPED")" = "$UM /rename sala-test-m" ]' 10 && ok "a slash command after it: bare" || bad "command: rc=$rc $(typed_ctx "$TYPED" "$UM")"
tmux send-keys -t "$PANE" -l "$SALA_MSG_MARK a line sala left behind"; waitfor '[ "$(pane_draft_screen "$PANE")" = "$SALA_MSG_MARK a line sala left behind" ]' 10
tui_send "$PANE" "/rename sala-test-m"; rc=$?
[ "$rc" = 0 ] && waitfor '[ "$(tail -1 "$TYPED")" = "$UM /rename sala-test-m" ]' 10 && ! grep -q "left behind" "$TYPED" && ok "a marked line left in the box is sala's own: cleared, the command typed" || bad "marked leftover: rc=$rc $(typed_ctx "$TYPED" "$UM")"
tmux send-keys -t "$PANE" -l 'half a thought'; waitfor '[ "$(pane_draft_screen "$PANE")" = "half a thought" ]' 10; n0=$(grep -c . "$TYPED")
tui_send "$PANE" "a message from sala" 2>/dev/null; rc=$?
[ "$rc" = 1 ] && [ "$(grep -c . "$TYPED")" = "$n0" ] && [ "$(pane_draft_screen "$PANE")" = "half a thought" ] && ok "someone's draft: refused, nothing typed, the draft kept" || bad "draft refusal: rc=$rc typed=$(grep -c . "$TYPED") box='$(pane_draft_screen "$PANE")'"
tmux send-keys -t "$PANE" C-u; waitfor '[ -z "$(pane_draft_screen "$PANE")" ]' 10
# spawn --brief: the brief line is a message (the one stackshot asked about: a line of a brief would pass as the owner's)
UB=66666666-0000-4000-8000-000000000006; printf 'the brief\n' > "$HOME/brief.md"
$T set-environment -g FAKE_SESSION_ID "$UB"; $T set-environment -g FAKE_NAME sala-test-b
out=$("$SALA" spawn sala-test-b --cwd "$HOME" --brief "$HOME/brief.md" 2>&1); echo "$out" | grep -E '^✅|⚠|✗' | sed 's/^/    /'
$T set-environment -g FAKE_SESSION_ID "$UM"; $T set-environment -g FAKE_NAME sala-test-m   # back to sala-test-m's for the resumes below
# 120 half-seconds, a deadline only (a held wait returns at once): on a CI runner this line never came, 10 or 20 half-seconds or not;
# typed_ctx now prints the fake's state, stdin and pane (tests/lib.sh typed_diag) so the next failing log says why
waitfor 'grep -qF "$UB $SALA_MSG_MARK Read $HOME/brief.md in full" "$TYPED"' 120 && ok "spawn --brief: the brief line typed as '$SALA_MSG_MARK Read … in full …'" || bad "brief line: $(typed_ctx "$TYPED" "$UB")"
[ "$(grep "^$UB " "$TYPED" | grep -v "^$UB /rename sala-test-b$" | grep -vcF "$UB $SALA_MSG_MARK ")" = 0 ] && ok "every other line into sala-test-b was a slash command" || bad "typed into sala-test-b: $(typed_ctx "$TYPED" "$UB")"

echo "== pane_draft: the mod or the screen, either one counts"
echo "$UM" > "$HOME/fakemod.sid"; point_socket "$C"; stamp "$RUN" "$UM"; echo ok > "$MODE"; : > "$SALA_MOD_LOG"
[ -z "$(pane_draft "$PANE")" ] && ok "mod empty, screen empty: no draft" || bad "empty: '$(pane_draft "$PANE")'"
tmux send-keys -t "$PANE" -l 'typed here'; waitfor '[ "$(pane_draft_screen "$PANE")" = "typed here" ]' 10
[ "$(pane_draft "$PANE")" = "typed here" ] && ok "the mod says empty, the screen shows text: a draft (either counts)" || bad "screen-only draft: '$(pane_draft "$PANE")'"
tmux send-keys -t "$PANE" C-u; waitfor '[ -z "$(pane_draft_screen "$PANE")" ]' 10
echo "draft:typed on claude.ai" > "$MODE"
[ "$(pane_draft "$PANE")" = "typed on claude.ai" ] && ok "the mod has text the screen does not: a draft, the mod's text" || bad "mod draft: '$(pane_draft "$PANE")'"
echo silent > "$MODE"; : > "$SALA_MOD_LOG"
[ -z "$(pane_draft "$PANE")" ] && grep -q "draft sala-test-m via screen only (no reply in 1s)" "$SALA_MOD_LOG" && ok "no reply: the screen alone, logged so" || bad "silent draft: $(<"$SALA_MOD_LOG")"

echo "== pane_exit and pane_rename through the mod"
echo background > "$MODE"; : > "$SALA_MOD_LOG"
pane_exit "$PANE" "$C" >/dev/null; rc=$?
[ "$rc" = 2 ] && grep -q "exit sala-test-m via mod (refused: background work)" "$SALA_MOD_LOG" && ok "background work: rc 2, logged" || bad "background: rc=$rc $(<"$SALA_MOD_LOG")"
echo turn > "$MODE"; : > "$SALA_MOD_LOG"
pane_exit "$PANE" "$C" >/dev/null; rc=$?
[ "$rc" = 4 ] && grep -q "exit sala-test-m via mod (refused: a turn is running)" "$SALA_MOD_LOG" && ok "a running turn: rc 4, logged, no /exit typed" || bad "turn: rc=$rc $(<"$SALA_MOD_LOG")"
echo named > "$MODE"; : > "$SALA_MOD_LOG"
out=$(pane_exit "$PANE" "$C"); rc=$?
[ "$rc" = 4 ] && [ "$out" = "subagent builder: Build the package move" ] && grep -q "exit sala-test-m via mod (refused: a turn is running; held by subagent builder: Build the package move)" "$SALA_MOD_LOG" \
    && ok "a turn the mod names: rc 4, the holder on stdout and in the log" || bad "named turn: rc=$rc out='$out' $(<"$SALA_MOD_LOG")"
out=$(mod_hold "$C"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "a turn is running: subagent builder: Build the package move" ] && ok "mod_hold (the busy probe): the same holder, as a skip reason" || bad "mod_hold named: rc=$rc '$out'"
echo turn > "$MODE"; mod_hold "$C" >/dev/null; rc=$?
[ "$rc" = 1 ] && ok "mod_hold: a turn the mod cannot name is no holder (sala's own checks and the refusal memory take it from there)" || bad "mod_hold unnamed: rc=$rc"
echo ok > "$MODE"; mod_hold "$C" >/dev/null; rc=$?
[ "$rc" = 1 ] && ok "mod_hold: a free pane is no holder" || bad "mod_hold free: rc=$rc"
echo "draft:not sent yet" > "$MODE"
out=$(pane_exit "$PANE" "$C"); rc=$?
[ "$rc" = 3 ] && [ "$out" = "not sent yet" ] && ok "a draft: rc 3, its text on stdout" || bad "draft: rc=$rc out='$out'"
echo ok > "$MODE"; tmux send-keys -t "$PANE" -l 'on the screen only'; waitfor '[ "$(pane_draft_screen "$PANE")" = "on the screen only" ]' 10; n0=$(heard_n)
out=$(pane_exit "$PANE" "$C"); rc=$?
[ "$rc" = 3 ] && [ "$out" = "on the screen only" ] && [ "$(heard_n)" = "$n0" ] && ok "the screen shows a draft, the mod would say empty: rc 3, the mod not even asked" || bad "screen draft: rc=$rc out='$out'"
tmux send-keys -t "$PANE" C-u; waitfor '[ -z "$(pane_draft_screen "$PANE")" ]' 10
proc_alive "$C" && ok "all four refusals: the session is untouched" || bad "the fake claude died on a refusal"
DEAD=$(sh -c 'echo $$'); echo silent > "$MODE"; : > "$SALA_MOD_LOG"
pane_exit "$PANE" "$DEAD"; rc=$?
[ "$rc" = 0 ] && grep -q "exit sala-test-m not sent (the claude is gone)" "$SALA_MOD_LOG" && proc_alive "$C" \
    && ok "a claude already gone: no /exit typed (it would have hit whatever runs in the pane now)" || bad "gone: rc=$rc alive=$(proc_alive "$C" && echo y) $(<"$SALA_MOD_LOG")"
echo ok > "$MODE"; : > "$SALA_MOD_LOG"
pane_rename "$PANE" "$C" sala-test-renamed; rc=$?
[ "$rc" = 0 ] && grep -q '^"\[sala-mod\] rename [0-9-]* sala-test-renamed' "$HEARD" && grep -q "rename sala-test-m via mod (ok)" "$SALA_MOD_LOG" && ok "rename via the mod: the name in the request, logged" || bad "rename: rc=$rc $(tail -1 "$HEARD") $(<"$SALA_MOD_LOG")"
echo silent > "$MODE"; : > "$SALA_MOD_LOG"
pane_rename "$PANE" "$C" sala-test-renamed; rc=$?
[ "$rc" = 0 ] && grep -q "rename sala-test-m via keys (no reply in 1s)" "$SALA_MOD_LOG" && ok "no reply: /rename typed instead (tui_send took it), logged via keys" || bad "rename fallback: rc=$rc $(<"$SALA_MOD_LOG")"

echo "== recycle of one pane: the exit through the mod, the resume with the mod's folder"
echo background > "$MODE"; : > "$SALA_MOD_LOG"
out=$(SALA_RETRY_WORKER=1 "$SALA" revive --only sala-test-m --force 2>&1); echo "$out" | grep -E 'sala-test-m|phase' | sed 's/^/    /'
echo "$out" | grep -q "sala-test-m:0: background work is running (a shell, monitor or subagent), which /exit would stop — /exit not sent" && proc_alive "$C" \
    && ok "the mod refuses (background): today's background row, the session untouched" || bad "background recycle: $out"
# a turn that started after the idle check (the /exit the mod ran mid-turn reached the model as a
# prompt, and the pane never exited): no /exit, a skip the retry worker takes up
echo turn > "$MODE"; : > "$SALA_MOD_LOG"
out=$(SALA_RETRY_WORKER=1 "$SALA" revive --only sala-test-m --force 2>&1); echo "$out" | grep -E 'sala-test-m|phase' | sed 's/^/    /'
echo "$out" | grep -q "sala-test-m:0: a turn is running (it started after the idle check) — /exit not sent" && proc_alive "$C" \
    && ok "the mod refuses (a turn): skipped as transient, the session untouched" || bad "turn recycle: $out"
# the stamp as written 1 s after C started (C has run for many seconds by now): fresh for C, older than any process after it
stamp "$RUN" "$UM" "$(( $(date +%s) - $(proc_etime "$C") + 1 ))000"
echo ok > "$MODE"; echo "$PANE" > "$HOME/fakemod.pane"; : > "$SALA_MOD_LOG"; n0=$(grep -c "^$UM " "$FAKE_ENV_LOG")
out=$(SALA_RETRY_WORKER=1 "$SALA" revive --only sala-test-m --force 2>&1); echo "$out" | grep -E 'sala-test-m|phase' | sed 's/^/    /'
echo "$out" | grep -q 'sala-test-m:0: 9.9.9 → 9.9.9' && ok "relaunched" || bad "recycle: $out"
grep -q "exit sala-test-m via mod (ok)" "$SALA_MOD_LOG" && ! grep -q "exit sala-test-m via keys" "$SALA_MOD_LOG" && ok "the exit went through the mod (logged; no keys)" || bad "exit path: $(<"$SALA_MOD_LOG")"
[ "$(grep -c "^$UM " "$FAKE_ENV_LOG")" = $((n0 + 1)) ] && [ "$(grep "^$UM " "$FAKE_ENV_LOG" | tail -1)" = "$UM /other/mods:$ROOT/mod" ] \
    && ok "the resume line started claude with the mod's folder appended" || bad "resume env: $(<"$FAKE_ENV_LOG")"
C2=$(cpid); [ -n "$C2" ] && [ "$C2" != "$C" ] || bad "no new process after the recycle"
mod_request "$C2" draft; rc=$?; [ "$rc" = 3 ] && ok "the old stamp does not count for the new process ($MOD_WHY): the next request takes the keys" || bad "stale after relaunch: rc=$rc $MOD_WHY"
rm -f "$HOME/fakemod.pane"; : > "$SALA_MOD_LOG"
out=$(SALA_RETRY_WORKER=1 "$SALA" revive --only sala-test-m --force 2>&1)
echo "$out" | grep -q 'sala-test-m:0: 9.9.9 → 9.9.9' && grep -q "exit sala-test-m via keys (a stamp older than the process)" "$SALA_MOD_LOG" \
    && ok "no fresh stamp: /exit typed as before, relaunched, logged via keys" || bad "keys recycle: $out / $(<"$SALA_MOD_LOG")"

echo "== an older mod refusing for an artifact watch alone (auto-armed, requested): the exit by keys, the pane relaunched"
# the mod is read at a process's start, so every pane launched before the fix still refuses for the watch; the busy record
# (this stretch's) says it is all there is, so pane_exit types /exit, which the CLI's exit dialog does not hold for a watch
C3=$(cpid); point_socket "$C3"; stamp "$RUN" "$UM"; echo bgwatch > "$MODE"; : > "$SALA_MOD_LOG"
W='{"id":"w","type":"monitor","status":"running","description":"live updates for artifact https://claude.ai/artifact/EXAMPLEARTIFACTID (auto-armed on publish)"}'
printf '{"session_id":"%s","background_tasks":[%s,{"id":"t","type":"shell","status":"running","description":"x"}]}' "$UM" "$W" | "$SALA" hook stop
mod_refused_watch_only '{"reqid":"r","ok":false,"reason":"background","tasks":["monitor running"]}' "$C3" && bad "the watch and a shell in the record: taken as the watch alone" || ok "the record has a shell beside the watch: the refusal stands"
printf '{"session_id":"%s","background_tasks":[%s]}' "$UM" "$W" | "$SALA" hook stop
mod_refused_watch_only '{"reqid":"r","ok":false,"reason":"background","tasks":["shell running"]}' "$C3" && bad "a refusal naming a shell: taken as the watch" || ok "a refusal naming a shell: the refusal stands, whatever the record"
# every label the CLI writes for a watch (Sun Oct 11th): a mod loaded before this refuses for a watch armed on request too
WR=${W/auto-armed on publish/watch requested}; WN=${W/auto-armed on publish/watch started}
printf '{"session_id":"%s","background_tasks":[%s]}' "$UM" "$WN" | "$SALA" hook stop
mod_refused_watch_only '{"reqid":"r","ok":false,"reason":"background","tasks":["monitor running"]}' "$C3" && bad "an unknown label: taken as a watch" || ok "an unknown label on the monitor: the refusal stands"
printf '{"session_id":"%s","background_tasks":[%s]}' "$UM" "$WR" | "$SALA" hook stop
mod_refused_watch_only '{"reqid":"r","ok":false,"reason":"background","tasks":["monitor running"]}' "$C3" && ok "a requested watch alone by the record: the refusal is the watch's" || bad "a requested watch: the refusal stands"
out=$(SALA_RETRY_WORKER=1 "$SALA" revive --only sala-test-m --force 2>&1); echo "$out" | grep -E 'sala-test-m|phase' | sed 's/^/    /'
C4=$(cpid)
[ -n "$C4" ] && [ "$C4" != "$C3" ] && grep -q "exit sala-test-m via keys (the mod refused for the artifact watch alone" "$SALA_MOD_LOG" \
    && ok "only a requested watch by the record: /exit by keys, relaunched as it is" || bad "old-mod bridge: $out / $(<"$SALA_MOD_LOG")"

echo "== resume_send: the resume line goes only into a shell, and once (two retry workers)"
UR=55555555-0000-4000-8000-000000000005; $T new-session -d -s sala-test-r -c "$HOME"; RP=$(tmux list-panes -t =sala-test-r -F '#{pane_id}' | head -1)
waitfor '[ "$(tmux display -p -t "$RP" "#{pane_current_command}")" = bash ]' 10
why=$(resume_send "$PANE" "$UR" "$(resume_cmd "$UR")"); rc=$?
[ "$rc" = 1 ] && echo "$why" | grep -q "not a shell — resume not typed" && ! grep -q "^start $UR " "$FAKE_LOG" \
    && ok "a pane running claude: not typed (it would sit in claude's prompt box)" || bad "into claude: rc=$rc '$why'"
why=$(resume_send "$RP" "$UM" "$(resume_cmd "$UM")"); rc=$?
[ "$rc" = 1 ] && echo "$why" | grep -q "is already live" && ok "a conversation live elsewhere: not typed" || bad "live: rc=$rc '$why'"
( resume_send "$RP" "$UR" "$(resume_cmd "$UR")" >/dev/null; echo $? > "$HOME/r1.rc" ) & R1=$!; ( resume_send "$RP" "$UR" "$(resume_cmd "$UR")" >/dev/null; echo $? > "$HOME/r2.rc" ) & R2=$!; wait "$R1" "$R2"
waitfor 'grep -q "^start $UR " "$FAKE_LOG"' 20; sleep 2
[ "$(grep -c "^start $UR " "$FAKE_LOG")" = 1 ] && [ "$(cat "$HOME/r1.rc" "$HOME/r2.rc" | sort | tr -d '\n')" = 01 ] && [ -z "$(pane_draft_screen "$RP")" ] \
    && ok "two at once into one shell: one typed, one refused, nothing left in the box" || bad "race: starts=$(grep -c "^start $UR " "$FAKE_LOG") rc=$(cat "$HOME/r1.rc" "$HOME/r2.rc" | tr '\n' ' ') box='$(pane_draft_screen "$RP")'"

echo "== spawn: a claude that comes up and dies is a failure, not a session (resume_wait)"
# a --fork spawn runs `claude --resume <uuid> --fork-session`: the fake's resume comes up, runs a few seconds and dies, as a CLI broken
# by its update would; until Oct 9th `wait_for … claude` passed in those 3 s and spawn went on to rename and map a dead pane
UD=44444444-0000-4000-8000-000000000004; echo '{"type":"user"}' > "$HOME/.claude/projects/x/$UD.jsonl"   # spawn --fork wants a transcript
# the fake lives 10 s, not 3: resume_wait sees it only if one poll (tmux display, claude_pid_under, sleep 1) lands inside its life,
# and on a loaded runner a poll outlasts 3 s (seen in CI with 47
# suites at once, "claude did not start … within 45s"). On this fail path the fake never writes a registry row, so a longer life
# cannot read as a started session; spawn waits 45 s, so 10 s fits with room. phases.sh and sets-master.sh keep 3 s: their resume
# wait is 5 s (SALA_RESUME_WAIT) and a longer life there would flip their verdict.
$T set-environment -g FAKE_RESUME_FAIL 1; $T set-environment -g FAKE_RESUME_DELAY 10000
out=$("$SALA" spawn sala-test-dead --fork "$UD" --cwd "$HOME" 2>&1); rc=$?
$T set-environment -gu FAKE_RESUME_FAIL; $T set-environment -gu FAKE_RESUME_DELAY
[ "$rc" != 0 ] && echo "$out" | grep -q 'claude started and died in sala-test-dead:0' && ok "spawn fails: claude started and died" || bad "dying spawn: rc=$rc $out"
! grep -qs 'sala-test-dead' "$SALA_SIDECAR" && ok "no pane-map row for the dead pane" || bad "mapped: $(grep sala-test-dead "$SALA_SIDECAR")"

echo "mod: $([ "$fail" = 0 ] && echo pass || echo FAIL)"
exit $fail
